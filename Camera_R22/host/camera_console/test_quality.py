"""Native-pixel quality, actual bundled MTF, export and R22 UI integration."""
from pathlib import Path
import hashlib,json,queue,sys,tempfile,threading,time,unittest
from unittest.mock import patch
import numpy as np
import cv2
from PIL import Image
from quality_analysis import (load_asset,fit_grid,analyze,export_pair,find_mtf,Cancelled,check_cancel,opencv_reference)
from quality_readout import curvature_profile,quality_narrative
from storage import save_snapshot
P=Path(__file__).resolve().parents[2];W=P/'work/host_ui_migration';W.mkdir(parents=True,exist_ok=True)


def chart():
    image=np.full((800,1200,3),235,np.uint8)
    for row in range(7):
        for col in range(10):image[120+row*80:120+(row+1)*80,200+col*80:200+(col+1)*80]=28 if (row+col)%2==0 else 220
    matrix=cv2.getRotationMatrix2D((600,400),5,1)
    image=cv2.warpAffine(image,matrix,(1200,800),flags=cv2.INTER_LINEAR,borderValue=(235,235,235))
    return Image.fromarray(cv2.GaussianBlur(image,(5,5),.8))


class QualityMathTests(unittest.TestCase):
    def test_orthogonal_grid_error_and_native_units(self):
        y,x=np.mgrid[:6,:9];points=np.stack([x*40+120,y*40+90],axis=-1).astype(float)
        straight=fit_grid(points,(9,6));bent=points.copy();bent[:,:,1]+=.006*(points[:,:,0]-280)**2
        curved=fit_grid(bent,(9,6))
        self.assertLess(straight['rms_px'],.0001);self.assertGreater(curved['rms_px'],5)
        scaled=fit_grid(bent*2,(9,6));self.assertAlmostEqual(scaled['rms_px'],2*curved['rms_px'],places=3)
        self.assertEqual(curved['corner_count'],54);self.assertEqual(curved['sample_count'],108)

    def test_saved_r22_geometry_and_tamper_detection(self):
        with tempfile.TemporaryDirectory(dir=W) as directory:
            for flags,title in [(0,'无几何处理标记'),(3,'IMU防抖'),(8,'旋转稳像'),(10,'Brown矫正'),(12,'鱼眼')]:
                result=dict(pixels=b'\x10\x42'*64,width=8,height=8,frame_id=flags,crc32='1',retry_rounds=0,geometry_flags=flags,processing='fpga_rotation_frame_with_selected_algorithms')
                _,path,_=save_snapshot(result,directory,{})
                asset=load_asset(path);self.assertIn(title,asset['source']);self.assertEqual(asset['metadata']['geometry_flags'],flags)
                self.assertNotIn('无增强原图',asset['source'])
            with path.open('ab') as f:f.write(b'changed')
            with self.assertRaisesRegex(ValueError,'SHA256'):load_asset(path)

    def test_external_photo_and_cancel(self):
        with tempfile.TemporaryDirectory(dir=W) as directory:
            p=Path(directory)/'outside.png';Image.new('RGB',(80,60),'gray').save(p)
            self.assertIn('未核验',load_asset(p)['source'])
        event=threading.Event();event.set()
        with self.assertRaises(Cancelled):check_cancel(event)

    def test_software_reference_is_explicit_and_dimension_checked(self):
        with tempfile.TemporaryDirectory(dir=W) as directory:
            d=Path(directory);photo=d/'original.png';Image.new('RGB',(160,100),'gray').save(photo);asset=load_asset(photo)
            calibration=d/'calibration.json';data={'calibration_size':[160,100],'K':[[150,0,80],[0,150,50],[0,0,1]],'D':[0,0,0,0,0]}
            calibration.write_text(json.dumps(data));result=opencv_reference(asset,calibration,d)
            self.assertEqual(result['source'],'OpenCV 软件参考');self.assertEqual(result['metadata']['input_sha256'],asset['sha256'])
            data['calibration_size']=[80,50];calibration.write_text(json.dumps(data))
            with self.assertRaises(ValueError):opencv_reference(asset,calibration,d)

    def test_missing_mtf_reports_unavailable_without_fabricated_zero(self):
        with tempfile.TemporaryDirectory(dir=W) as directory:
            p=Path(directory)/'chart.png';chart().save(p)
            with patch('quality_analysis.find_mtf',return_value=''):
                result=analyze(load_asset(p),do_mtf=True)
            self.assertEqual(result['straightness']['corner_count'],54)
            self.assertEqual(result['mtf']['status'],'NOT_INSTALLED');self.assertIsNone(result['mtf']['median_mtf50_cpp'])

    def test_bundled_mtf_native_measurement_and_complete_report(self):
        exe=find_mtf();self.assertTrue(Path(exe).is_relative_to(P/'tools/mtf_mapper'))
        with tempfile.TemporaryDirectory(dir=W) as directory:
            d=Path(directory);p=d/'synthetic.png';chart().save(p);before=hashlib.sha256(p.read_bytes()).hexdigest()
            asset=load_asset(p);result=analyze(asset,executable=exe)
            self.assertEqual(result['straightness']['corner_count'],54);self.assertEqual(result['mtf']['status'],'OK',result['mtf'])
            self.assertGreater(result['mtf']['edge_count'],20);self.assertGreater(result['mtf']['median_mtf50_cpp'],.01)
            report=export_pair([asset,asset],[result,result],d,layers={'fitted':True,'corners':True,'residuals':True,'mtf':True},display={'mode':'偏差放大','gain':50})
            for name in ('report.html','report.json','analysis.txt','comparison.png','curvature_comparison.png','curvature_samples.csv','straightness.csv','mtf_edges.csv','sfr_comparison.png'):
                self.assertTrue((report/name).is_file(),name)
            self.assertEqual(hashlib.sha256(p.read_bytes()).hexdigest(),before)
            self.assertIn('未核验',quality_narrative([asset,asset],[result,result]))
            evidence={'pass':True,'fixture':'synthetic rotated checkerboard; no board image','size':asset['size'],'corner_count':54,'mtf_version':'0.7.40','mtf_edges':result['mtf']['edge_count'],'median_mtf50_cpp':result['mtf']['median_mtf50_cpp'],'original_file_unchanged':True,'report_export':'PASS'}
            (P/'reports/host_quality_measurement.json').write_text(json.dumps(evidence,indent=2),encoding='utf-8')


class QualityGuiTests(unittest.TestCase):
    def setUp(self):
        argv=sys.argv;sys.argv=[str(P/'host/camera_console/console.py')]
        import console
        sys.argv=argv;self.console=console
        import tkinter as tk
        self.root=tk.Tk();self.root.withdraw();self.app=console.CameraConsole(self.root,discover=False)
        self.tmp=tempfile.TemporaryDirectory(dir=W);self.app.output.set(self.tmp.name)
        self.app.quality_panel.auto_analyze.set(False)
    def tearDown(self):
        self.app.quality_panel.close();self.app.closing=True;self.app.serial_stop.set()
        if self.app.network_client:self.app.network_client.close()
        for token in self.root.tk.call('after','info'):self.root.after_cancel(token)
        self.root.destroy();self.tmp.cleanup()
    def wait(self,condition):
        deadline=time.monotonic()+4
        while not condition() and time.monotonic()<deadline:
            self.root.update();time.sleep(.02)
        self.assertTrue(condition())
    def test_workspace_layout_and_analysis_independent_of_devices(self):
        self.root.geometry('1060x720');self.root.deiconify();self.root.update()
        self.app.workspace.select(self.app.quality_tab);self.root.update()
        self.assertFalse(self.app.sidebar_frame.winfo_ismapped());self.assertFalse(self.app.header_frame.winfo_ismapped())
        self.assertIn('disabled',self.app.quality_panel.capture_buttons[0].state())
        self.assertNotIn('disabled',self.app.quality_panel.analyze_button.state())
        self.assertEqual(len(self.app.mode_buttons),8)
        self.app.show_photo_devices();self.root.update();self.assertTrue(self.app.sidebar_frame.winfo_ismapped())
    def test_window_icon_and_logo_remain_visible_in_all_layouts(self):
        app=self.app
        self.assertTrue(app.logo_loaded)
        self.assertEqual((app.window_icon.width(),app.window_icon.height()),(64,64))
        self.root.geometry('1060x720');self.root.deiconify();self.root.update()
        for page in (app.photo_tab,app.quality_tab,app.calib_tab):
            app.workspace.select(page);self.root.update()
            self.assertTrue(app.compact_logo_label.winfo_ismapped() or app.header_frame.winfo_ismapped())
        app.workspace.select(app.photo_tab);self.root.geometry('1280x900');self.root.update()
        self.assertTrue(app.header_frame.winfo_ismapped())
        # Tk default icon applies to newly created photo/analysis windows, too.
        from tkinter import Toplevel
        window=Toplevel(self.root);window.withdraw();self.root.update_idletasks();window.destroy()

    def test_current_photo_to_b_and_synchronized_views(self):
        p=Path(self.tmp.name)/'source.png';chart().save(p)
        self.app.open_photo(p);self.app.send_quality(1)
        panel=self.app.quality_panel;self.wait(lambda:panel.assets[1] is not None and not panel.busy)
        self.assertEqual(Path(panel.assets[1]['path']),p);self.assertIsNone(panel.assets[0])
        panel.set_zoom('1:1');self.root.update();self.assertEqual(panel.zoom.get(),'1:1')
        self.assertTrue(self.app.tuning_requests.empty())
    def test_capture_to_a_uses_existing_client_without_mode_changes(self):
        class Client:
            def capture(self,progress):
                progress(128,128)
                return dict(pixels=b'\x10\x42'*64,width=8,height=8,frame_id=8,crc32='ABCD',retry_rounds=0,geometry_flags=12)
            def close(self):pass
        app=self.app;app.network_client=Client();app.connection={};app.net_ready=True
        with patch.object(self.console,'assess_file',return_value=({'status':'REVIEW','corner_count':0,'advice':[],'warnings':[]},None)):
            app.capture_quality(0);self.assertTrue(app.quality_panel.capture_pending)
            self.wait(lambda:app.quality_panel.assets[0] is not None and not app.quality_panel.busy)
        self.assertIn('旋转稳像',app.quality_panel.assets[0]['source']);self.assertIn('鱼眼',app.quality_panel.assets[0]['source'])
        self.assertFalse(app.quality_panel.capture_pending);self.assertIsNone(app.quality_capture_side)
        self.assertTrue(app.last_photo_path.is_file());self.assertTrue(app.tuning_requests.empty())
    def test_cancel_and_late_photo_do_not_replace_comparison(self):
        class Client:
            def close(self):self.closed=True
        app=self.app;client=Client();app.network_client=client;app.net_ready=True;app.network_busy=True
        app.quality_capture_side=1;app.quality_panel.capture_pending=True;generation=app.network_generation
        app.cancel_network();self.assertTrue(client.closed);self.assertFalse(app.quality_panel.capture_pending)
        app.emit('photo',(generation,Image.new('RGB',(8,8)),Path('unused.png'),{}));app.poll_events()
        self.assertIsNone(app.quality_panel.assets[1]);self.assertIsNone(app.last_photo_path)

if __name__=='__main__':unittest.main()
