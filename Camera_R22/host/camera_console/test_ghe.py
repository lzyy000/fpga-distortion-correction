"""GHE extension, retry safety, capability gating, GUI and photo preservation."""
import sys,unittest,json,tempfile,hashlib
from pathlib import Path
from tuning import StrengthControl,MODE_BITS,ghe_low_command
from test_r21_modes import reply
from test_r20_host import NightBoard
from transport import SnapshotClient
from storage import save_snapshot
P=Path(__file__).resolve().parents[2]
class Board:
    def __init__(self):self.modes=0;self.ghe=100;self.high=6;self.night=100;self.denoise=100
    def apply(self,c):
        if c<=100:self.denoise=c
        elif 112<=c<=127:self.modes=(self.modes&16)|(c-112)
        elif 128<=c<=228:self.night=c-128
        elif 241<=c<=247:self.high=c-241
        elif c in (248,249):self.modes=(self.modes&15)|(16 if c==248 else 0)
        elif 229<=c<=239 or 250<=c<=254:
            low=c-229 if c<=239 else c-250+11
            value=(self.high<<4)|low
            if value<=100:self.ghe=value
        return self.ack(c)
    def ack(self,c):
        return reply(c,self.modes,self.modes,self.night,self.denoise)+f' ghe={self.ghe} ghe_q8={(self.ghe*256+50)//100} ghe_on={bool(self.modes&16):d} ghe_ready=1'
class GheProtocolTests(unittest.TestCase):
    def setUp(self):
        self.b=Board();self.events=[];self.c=StrengthControl(lambda *x:self.events.append(x))
        self.assertEqual(self.c.tick(0),bytes([240]));self.assertTrue(self.c.receive(self.b.apply(240)))
    def execute(self,now):
        cmd=self.c.tick(now);self.assertIsNotNone(cmd);self.assertTrue(self.c.receive(self.b.apply(cmd[0])));return cmd[0]
    def test_all_101_strengths_and_idempotent_each_byte(self):
        now=.1
        for value in list(range(100))+[100]:
            self.c.request('ghe',value,now);now+=.2
            high=self.c.tick(now);self.assertEqual(high,bytes([241+(value>>4)]))
            self.b.apply(high[0]);now+=1.51
            self.assertEqual(self.c.tick(now),high);self.assertTrue(self.c.receive(self.b.apply(high[0])))
            now+=.01;low=self.c.tick(now);self.assertEqual(low,bytes([ghe_low_command(value)]))
            self.b.apply(low[0]);now+=1.51
            self.assertEqual(self.c.tick(now),low);self.assertTrue(self.c.receive(self.b.apply(low[0])))
            self.assertEqual(self.c.confirmed['ghe'],value);self.assertEqual(self.b.denoise,100);self.assertEqual(self.b.night,100)
            now+=.01
    def test_fifth_mode_and_legacy_mask_preserve_each_other(self):
        for key in (k for k in MODE_BITS if k not in ('eis','fisheye','rotation')):self.assertTrue(self.c.request_mode(key,True,.1))
        self.assertEqual(self.execute(.3),127);self.assertEqual(self.b.modes,15)
        self.assertEqual(self.execute(.31),248);self.assertEqual(self.b.modes,31)
        self.c.request_mode('night',False,.4);self.assertEqual(self.execute(.6),119);self.assertEqual(self.b.modes,23)
        self.c.request_mode('ghe',False,.7);self.assertEqual(self.execute(.9),249);self.assertEqual(self.b.modes,7)
    def test_slider_coalesces_changes_during_high_low_transaction(self):
        self.c.request('ghe',35,.1);high=self.c.tick(.3)
        self.c.request('ghe',100,.31);self.assertTrue(self.c.receive(self.b.apply(high[0])))
        self.assertEqual(self.execute(.32),ghe_low_command(35))
        self.assertEqual(self.execute(.6),247);self.assertEqual(self.execute(.61),ghe_low_command(100))
        self.assertEqual(self.b.ghe,100);self.assertFalse(self.c.pending)
    def test_reject_wrong_strength_q8_and_unsupported_old_r21(self):
        self.c.request('ghe',35,.1);self.execute(.3);cmd=self.c.tick(.31);good=self.b.apply(cmd[0])
        self.assertFalse(self.c.receive(good.replace('ghe_q8=90','ghe_q8=91')))
        self.assertTrue(self.c.receive(good))
        old=StrengthControl(lambda *x:None);old.tick(0);self.assertTrue(old.receive(reply(240)))
        self.assertFalse(old.request_mode('ghe',True,.1));self.assertFalse(old.request('ghe',35,.1))
class GheGuiTests(unittest.TestCase):
    def test_fifth_switch_slider_and_scroll_at_minimum_window(self):
        argv=sys.argv;sys.argv=[str(P/'host/camera_console/console.py')]
        import console
        sys.argv=argv
        import tkinter as tk
        root=tk.Tk();root.withdraw();app=console.CameraConsole(root,discover=False)
        try:
            self.assertIn('ghe',app.mode_buttons);self.assertIn('ghe',app.strength_scales)
            value=dict(night=100,denoise=100,ghe=100,night_on=False,denoise_on=False,ghe_on=False,ghe_supported=True,ghe_ready=True,modes=0,applied_modes=0,firmware_version=21,first=True)
            app.emit('tune_ack',value);app.poll_events();root.geometry('1060x720');root.deiconify()
            tab=app.tuning_canvas.master;tab.master.select(tab);root.update()
            self.assertFalse(app.strength_scales['ghe'].winfo_ismapped())
            app.mode_clicked('ghe');self.assertEqual(app.tuning_requests.get_nowait(),('mode','ghe',True));root.update()
            self.assertTrue(app.strength_scales['ghe'].winfo_ismapped())
            value.update(modes=16,applied_modes=16,ghe_on=True,first=False);app.emit('tune_ack',value);app.poll_events()
            self.assertEqual(app.mode_buttons['ghe'].cget('text'),'关闭');self.assertFalse(app.mode_pending)
            app.strength_changed('ghe',42);self.assertEqual(app.tuning_requests.get_nowait(),('ghe',42))
            for key in ('night','denoise','ghe'):app.show_strength(key,True)
            root.update();app.tuning_canvas.yview_moveto(1);root.update()
            self.assertLess(app.tuning_canvas.yview()[0],1);self.assertEqual(app.tuning_canvas.yview()[1],1)
            scale=app.strength_scales['ghe'];self.assertGreater(scale.winfo_width(),100)
            self.assertLess(scale.winfo_rooty()-app.tuning_canvas.winfo_rooty(),app.tuning_canvas.winfo_height())
            # A legacy ACK must disable only the unsupported GHE control.
            value.update(ghe_supported=False,modes=0,applied_modes=0,first=True)
            app.emit('tune_ack',value);app.poll_events();root.update()
            self.assertIn('disabled',app.mode_buttons['ghe'].state());self.assertFalse(scale.winfo_ismapped())
        finally:
            app.closing=True;app.serial_stop.set()
            for token in root.tk.call('after','info'):root.after_cancel(token)
            root.destroy()
class GhePhotoTests(unittest.TestCase):
    def test_ghe_pixels_crc_and_png_metadata_preserved(self):
        sys.path.insert(0,str(P/'sim/r21_modes'))
        from ghe_oracle import fixtures
        with tempfile.TemporaryDirectory(dir=P/'work/r21') as vectors:
            fixtures(Path(vectors))
            words=[int(v,16) for v in (Path(vectors)/'ghe_expected.hex').read_text().split()][1024:1536]
        pixels=b''.join(v.to_bytes(2,'little') for v in words)
        board=NightBoard(pixels,(64,8));board.host_modes=True;board.ghe=True
        client=SnapshotClient('127.0.0.1','127.0.0.1',0,board.port,(64,8))
        try:
            info=client.hello(timeout=1);self.assertIn('global_histogram',info['capabilities'])
            result=client.capture(timeout=3,retry_interval=.15);self.assertEqual(result['pixels'],pixels)
            self.assertEqual(result['processing'],'fpga_frame_ghe_night_follow_host_mode')
            with tempfile.TemporaryDirectory(dir=P/'work/r21') as folder:
                image,path,metadata=save_snapshot(result,folder,{'mode':'R21 GHE TEST'})
                self.assertEqual(metadata['pixel_sha256'],hashlib.sha256(pixels).hexdigest())
                self.assertEqual(metadata['processing'],'fpga_frame_ghe_night_follow_host_mode')
        finally:client.close();board.close()
