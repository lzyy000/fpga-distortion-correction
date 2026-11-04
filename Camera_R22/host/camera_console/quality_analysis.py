"""Offline, original-pixel metrology. No camera, serial or FPGA commands.

Straightness is the orthogonal L2 distance to each independently fitted row /
column, not calibration reprojection error. MTF uses the installed MTF Mapper.
"""
from pathlib import Path
import csv, hashlib, html, json, math, os, shutil, subprocess, tempfile, threading, time
from datetime import datetime
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

PALETTE = ('#36C8FF', '#FF77C8', '#60DEB0', '#FFC35A', '#9B9CFF', '#F29268')
METHOD = 'OpenCV fitLine DIST_L2; orthogonal distances; rows and columns independently'


class Cancelled(RuntimeError):
    pass


def check_cancel(cancel):
    if cancel is not None and cancel.is_set():
        raise Cancelled('分析已取消')


def load_asset(path):
    path = Path(path).resolve()
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    with Image.open(path) as im:
        if im.width * im.height > 40_000_000:
            raise ValueError('图像过大，请使用不超过 4000 万像素的测试照片')
        image = im.convert('RGB')
    meta = {}
    sidecar = path.with_suffix('.json')
    if sidecar.is_file():
        try:
            candidate = json.loads(sidecar.read_text(encoding='utf-8-sig'))
        except (OSError, ValueError):
            candidate = {}
        if isinstance(candidate, dict) and 'png_sha256' in candidate:
            if candidate['png_sha256'] != digest:
                raise ValueError('照片与同名 JSON 的 SHA256 不一致，请先检查存档')
            if (candidate.get('width', image.width), candidate.get('height', image.height)) != image.size:
                raise ValueError('照片与同名 JSON 的尺寸不一致')
            keys = ('source','firmware','geometry_flags','eis_applied','rotation_applied','lens_applied_to_eis','lens_applied_to_rotation','fisheye_applied','capture_source', 'capture_source_label', 'processing', 'frame_id',
                    'config_version', 'applied_modes', 'captured_at', 'quality_origin',
                    'input_sha256','input_path','calibration_sha256','calibration_path',
                    'calibration_status','method','K','D','scope',
                    'quality_pair_id','quality_pair_role','quality_pair_same_frame')
            meta = {k: candidate[k] for k in keys if k in candidate}
    source = '外部图像 · 来源未核验'
    if meta.get('quality_origin') == 'opencv_reference':
        source = 'OpenCV 软件参考'
    elif meta.get('capture_source') == 1 and meta.get('processing') == 'fpga_display_result':
        source = 'FPGA 处理结果 · 匹配存档记录'
    elif meta.get('capture_source') == 0:
        source = 'FPGA 无增强原图 · 匹配存档记录'
    elif meta.get('capture_source') == 2:
        source = 'FPGA 增强原图 · 匹配存档记录'
    elif meta.get('source')=='FPGA Ethernet snapshot':
        flags=meta.get('geometry_flags',0);active=[]
        if flags&8:active.append('旋转稳像')
        elif flags&1:active.append('IMU防抖')
        if flags&4:active.append('鱼眼')
        elif flags&2:active.append('Brown矫正')
        source='FPGA 网口完整帧 · '+(' / '.join(active) if active else '无几何处理标记')
    elif meta:
        source = '存档图像 · 匹配记录'
    return {'image': image, 'path': str(path), 'sha256': digest, 'source': source,
            'size': list(image.size), 'rgb_pixel_sha256':hashlib.sha256(image.tobytes()).hexdigest(), 'metadata': meta}


def fit_grid(points, pattern):
    cols, rows = pattern
    grid = np.asarray(points, dtype=np.float64).reshape(rows, cols, 2)
    if not np.isfinite(grid).all():
        raise ValueError('角点含无效坐标')
    lines, distances = [], []
    for axis, count in (('row', rows), ('column', cols)):
        for index in range(count):
            p = grid[index] if axis == 'row' else grid[:, index]
            vx, vy, x, y = cv2.fitLine(p.astype(np.float32), cv2.DIST_L2, 0, .001, .001).ravel().astype(float)
            direction = np.array([vx, vy]); direction /= np.linalg.norm(direction)
            origin = np.array([x, y]); delta = p - origin
            along = delta @ direction
            projections = origin + along[:, None] * direction
            d = np.linalg.norm(p - projections, axis=1)
            distances.extend(d.tolist())
            color = PALETTE[(index + (2 if axis == 'column' else 0)) % len(PALETTE)]
            lines.append({'axis': axis, 'index': index + 1, 'color': color,
                          'points': p.tolist(), 'projections': projections.tolist(),
                          'segment': [list(origin + along.min()*direction), list(origin + along.max()*direction)],
                          'distances_px': d.tolist(), 'rms_px': float(np.sqrt(np.mean(d*d))),
                          'max_px': float(d.max())})
    d = np.asarray(distances)
    return {'status': 'OK', 'pattern': list(pattern), 'corner_count': cols*rows,
            'sample_count': len(d), 'method': METHOD,
            'rms_px': float(np.sqrt(np.mean(d*d))), 'max_px': float(d.max()),
            'p95_px': float(np.percentile(d, 95)), 'lines': lines,
            'corners': grid.reshape(-1, 2).tolist()}


def straightness(image, pattern=(9, 6), cancel=None):
    cols, rows = map(int, pattern)
    if not (3 <= cols <= 30 and 3 <= rows <= 30):
        raise ValueError('棋盘内角点行列数应为 3～30')
    check_cancel(cancel)
    gray = cv2.cvtColor(np.asarray(image), cv2.COLOR_RGB2GRAY)
    # Detect and measure at native resolution; never resize to the UI preview.
    found, corners = cv2.findChessboardCornersSB(gray, (cols, rows), flags=cv2.CALIB_CB_ACCURACY)
    if not found:
        check_cancel(cancel)
        found, corners = cv2.findChessboardCornersSB(gray, (cols, rows), flags=cv2.CALIB_CB_NORMALIZE_IMAGE | cv2.CALIB_CB_EXHAUSTIVE | cv2.CALIB_CB_ACCURACY)
    check_cancel(cancel)
    if not found or corners is None:
        return {'status': 'NOT_FOUND', 'pattern': [cols, rows], 'corner_count': 0,
                'rms_px': None, 'max_px': None, 'lines': [], 'corners': [],
                'message': '未识别完整棋盘；检查内角点数量、清晰度、白边与完整入镜。'}
    return fit_grid(corners, (cols, rows))


def find_mtf(preferred=''):
    candidates = [preferred, str(Path(__file__).resolve().parents[2]/'tools/mtf_mapper/bin/mtf_mapper.exe'), shutil.which('mtf_mapper.exe'), r'D:\MTF Mapper\bin\mtf_mapper.exe']
    for base in (os.environ.get('ProgramFiles'), os.environ.get('ProgramFiles(x86)')):
        if base:
            candidates.extend(str(p) for p in Path(base).glob('*[Mm][Tt][Ff]*/bin/mtf_mapper.exe'))
    for name in candidates:
        if name and Path(name).is_file() and Path(name).name.lower() == 'mtf_mapper.exe':
            return str(Path(name).resolve())
    return ''


def _table(path, columns):
    rows = []
    if not path.is_file():
        return rows
    for text in path.read_text(encoding='utf-8-sig', errors='replace').splitlines():
        if not text.strip() or text.lstrip().startswith('#'):
            continue
        try:
            values = [float(v) for v in text.split()]
        except ValueError:
            continue
        if len(values) == columns and all(math.isfinite(v) for v in values):
            rows.append(values)
    return rows


def parse_mtf(directory, size):
    directory = Path(directory)
    mtfs = _table(directory/'edge_mtf_values.txt', 6)
    sfrs = _table(directory/'edge_sfr_values.txt', 69)
    curves = {(int(r[0]), round(r[1], 3), round(r[2], 3)): r for r in sfrs}
    edges, excluded = [], 0
    for row in mtfs:
        block, x, y, value, cx, cy = row
        sfr = curves.get((int(block), round(x, 3), round(y, 3)))
        angle = abs(sfr[3]) % 90 if sfr is not None else None
        if angle is not None:
            angle = min(angle, 90-angle)
        if not (0 <= x < size[0] and 0 <= y < size[1] and 0 < value <= 1) or sfr is None or not 2 <= angle <= 43:
            excluded += 1
            continue
        edges.append({'x': x, 'y': y, 'mtf50_cpp': value, 'angle_deg': angle,
                      'sfr': sfr[5:], 'frequency_cpp': [i/64 for i in range(64)]})
    values = [e['mtf50_cpp'] for e in edges]
    return {'status': 'OK' if edges else 'NO_VALID_EDGES', 'unit': 'cycles/pixel',
            'median_mtf50_cpp': float(np.median(values)) if values else None,
            'edge_count': len(edges), 'excluded_edges': excluded, 'edges': edges,
            'message': '' if edges else '没有可靠斜边；请让图卡边缘相对画面倾斜约 5°，避免过曝、反光与模糊。'}


def run_mtf(image, executable, checkerboard=True, linear=False, cancel=None, timeout=150):
    executable = find_mtf(executable)
    if not executable:
        return {'status': 'NOT_INSTALLED', 'edges': [], 'median_mtf50_cpp': None,
                'message': '未找到 mtf_mapper.exe，请在设置中选择安装目录 bin 下的命令行程序。'}
    check_cancel(cancel)
    # Old Windows OpenCV inside MTF Mapper cannot reliably open Unicode paths.
    # Lossless RGB copy with an ASCII filename; pixel values are unmodified.
    work_root=Path(__file__).resolve().parents[2]/'work/quality_analysis'
    work_root.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='mtf_',dir=work_root) as temporary:
        work = Path(temporary); source = work/'input.png'
        image.save(source)
        cmd = [executable, '-q', '-v', '1', '--mtf', '50', '--esf-model', 'loess']
        if checkerboard: cmd.append('--checkerboard')
        if linear: cmd.append('-l')
        gnuplot = Path(executable).parent/'gnuplot/gnuplot.exe'
        if gnuplot.is_file(): cmd += ['--gnuplot-executable', str(gnuplot)]
        cmd += [str(source), str(work)]
        started = time.monotonic()
        with (work/'process.log').open('wb') as log:
            proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            try:
                while proc.poll() is None:
                    check_cancel(cancel)
                    if time.monotonic()-started > timeout:
                        raise TimeoutError('MTF 分析超时；可取消后缩小测试区域或换用清晰图卡')
                    time.sleep(.08)
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    try: proc.wait(timeout=3)
                    except subprocess.TimeoutExpired: proc.kill(); proc.wait()
        check_cancel(cancel)
        output = (work/'process.log').read_text(encoding='utf-8', errors='replace')
        if proc.returncode:
            raise RuntimeError('MTF Mapper 执行失败：'+output[-900:])
        result = parse_mtf(work, image.size)
        result.update(executable=executable, executable_sha256=hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                      arguments=cmd[1:-2], seconds=round(time.monotonic()-started, 3),
                      input_transfer='linear' if linear else 'sRGB assumption',
                      raw_files={p.name:p.read_text(encoding='utf-8', errors='replace') for p in work.glob('edge_*_values.txt')},
                      log=output[-12000:])
        return result


def analyze(asset, pattern=(9, 6), executable='', do_mtf=True, checkerboard=True, linear=False, cancel=None):
    geometry = straightness(asset['image'], pattern, cancel) if checkerboard else {
        'status':'NOT_APPLICABLE', 'lines':[], 'corners':[], 'rms_px':None, 'max_px':None,
        'message':'斜边图模式仅测清晰度；直线度需完整棋盘。'}
    mtf = {'status':'SKIPPED', 'edges':[], 'median_mtf50_cpp':None, 'message':'本次未启用 MTF 测量'}
    if do_mtf:
        try:
            mtf = run_mtf(asset['image'], executable, checkerboard, linear, cancel)
        except Cancelled:
            raise
        except Exception as exc:
            mtf = {'status':'ERROR', 'edges':[], 'median_mtf50_cpp':None, 'message':str(exc)}
    return {'image': {k:v for k,v in asset.items() if k!='image'}, 'straightness':geometry, 'mtf':mtf,
            'opencv_version':cv2.__version__, 'measured_at':datetime.now().astimezone().isoformat(),
            'limits':'Sampled corner straightness, not a dense edge guarantee. No competition pass/fail threshold assumed. MTF50 summaries can cover different edges; compare common field, scale and processing.'}


def annotation_shapes(result, fitted=True, corners=True, residuals=True, mtf=True, selected=None):
    """Source-pixel vector geometry. No exaggeration of measured distances."""
    shapes = []
    if not result: return shapes
    geometry = result['straightness']
    lines = geometry.get('lines', [])
    if selected is not None:
        from quality_readout import ordered_lines
        candidates = ordered_lines(result, selected[0])
        lines = candidates[selected[1]-1:selected[1]]
    for line in lines:
        color = '#49BCD6' if selected else line['color']
        if fitted: shapes.append(('line', line['segment'], color, None))
        if residuals:
            for p, q in zip(line['points'], line['projections']):
                shapes.append(('line', [p,q], '#FF5E68', None))
    if corners:
        points = [p for line in lines for p in line['points']] if selected else geometry.get('corners', [])
        for p in points: shapes.append(('point',p,'#FFE169',None))
    if mtf:
        for edge in result['mtf'].get('edges', []):
            shapes.append(('mtf',[edge['x'],edge['y']],'#72E5C2',f"{edge['mtf50_cpp']:.3f}"))
    return shapes


def annotated_image(image, result, **layers):
    from quality_visuals import render_overlay
    out=image.convert('RGBA')
    out.alpha_composite(render_overlay(image.size,annotation_shapes(result,**layers),show_text=True))
    return out.convert('RGB')


def opencv_reference(asset, calibration, directory):
    """Explicit software baseline; never sent to the board or used as FPGA proof."""
    calibration=Path(calibration)
    data=json.loads(calibration.read_text(encoding='utf-8-sig'))
    size=data.get('calibration_size',data.get('image_size',data.get('size')))
    if size is None or list(size)!=asset['size']:
        raise ValueError('标定 JSON 必须包含与左图一致的 calibration_size / image_size / size；不自动缩放内参')
    if 'fisheye' in str(data.get('model','')).lower():
        raise ValueError('此参考使用普通 Brown 模型，鱼眼模型需使用独立工具')
    if 'intr' in data:
        values=np.asarray(data['intr'],dtype=float).ravel()
        if len(values)!=9:raise ValueError('intr 必须为 fx,fy,cx,cy,k1,k2,p1,p2,k3')
        fx,fy,cx,cy=values[:4];K=np.array([[fx,0,cx],[0,fy,cy],[0,0,1.]])
        D=values[4:]
    else:
        K=np.asarray(data['K'],dtype=float);D=np.asarray(data['D'],dtype=float).ravel()
    if K.shape!=(3,3) or len(D) not in (4,5,8,12,14) or not np.isfinite(K).all() or not np.isfinite(D).all() or K[0,0]<=0 or K[1,1]<=0:
        raise ValueError('内参 K / D 的形状或数值无效')
    mx,my=cv2.initUndistortRectifyMap(K,D,None,K,tuple(asset['size']),cv2.CV_32FC1)
    rgb=cv2.remap(np.asarray(asset['image']),mx,my,cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
    directory=Path(directory);directory.mkdir(parents=True,exist_ok=True)
    target=directory/('opencv_reference_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'.png')
    Image.fromarray(rgb).save(target)
    meta={'quality_origin':'opencv_reference','width':rgb.shape[1],'height':rgb.shape[0],
          'png_sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'input_sha256':asset['sha256'],
          'input_path':asset['path'],'calibration_path':str(calibration.resolve()),
          'calibration_sha256':hashlib.sha256(calibration.read_bytes()).hexdigest(),
          'calibration_status':data.get('status','unspecified'),'K':K.tolist(),'D':D.tolist(),
          'method':'OpenCV initUndistortRectifyMap + remap INTER_LINEAR, K_new=K, full image, constant black border',
          'scope':'SOFTWARE_REFERENCE_ONLY; lens correction only, not dynamic/plane mapping or FPGA output'}
    target.with_suffix('.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2),encoding='utf-8')
    return load_asset(target)


def export_pair(assets, results, directory, layers=None, display=None):
    from quality_readout import curvature_profile, render_curvature, metric_text, comparison_text, quality_narrative
    from quality_visuals import diagnostic_image
    directory=Path(directory);directory.mkdir(parents=True,exist_ok=True)
    folder=directory/('quality_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));folder.mkdir()
    model=curvature_profile(results,(layers or {}).get('selected'))
    narrative=quality_narrative(assets,results)
    report={'schema':'fpga_quality_comparison_v1','created_at':datetime.now().astimezone().isoformat(),
            'comparison_note':'Independent measurements; not automatically synchronized or matched in scene, scale, field or edge selection.',
            'overlay_note':'Antialiased overlays. In magnified mode only perpendicular diagnostic displacements are amplified; source pixels and measurements stay unchanged.',
            'display':display, 'analysis_text':narrative,
            'curvature_plot':model, 'visible_layers':layers,
            'panels':results}
    (folder/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2,allow_nan=False),encoding='utf-8')
    (folder/'analysis.txt').write_text(narrative,encoding='utf-8')
    render_curvature(model).save(folder/'curvature_comparison.png')
    with (folder/'curvature_samples.csv').open('w',newline='',encoding='utf-8-sig') as f:
        writer=csv.writer(f);writer.writerow(['panel','screen_axis','screen_line','position_fraction','signed_deviation_px'])
        for side,profile in enumerate(model['profiles']):
            if profile:
                for position,deviation in zip(profile['fraction'],profile['signed_px']):
                    writer.writerow([('left','right')[side],*model['selected'],position,deviation])
    panels=[];summaries=[]
    with (folder/'straightness.csv').open('w',newline='',encoding='utf-8-sig') as f:
        writer=csv.writer(f);writer.writerow(['panel','axis','line','rms_px','max_px','samples'])
        for side,(asset,result) in enumerate(zip(assets,results)):
            if not asset: continue
            name=('left','right')[side]
            asset['image'].save(folder/(name+'_original.png'))
            overlay=(diagnostic_image(asset['image'],result,model['selected'],display['mode'],display['gain'],side,layers)
                     if display else annotated_image(asset['image'],result,**(layers or {})))
            overlay.save(folder/(name+'_annotated.png'));panels.append((side,name,overlay))
            if result:
                for line in result['straightness'].get('lines',[]):
                    writer.writerow([name,line['axis'],line['index'],line['rms_px'],line['max_px'],len(line['points'])])
                for raw_name,content in result['mtf'].get('raw_files',{}).items():
                    (folder/(name+'_'+Path(raw_name).name)).write_text(content,encoding='utf-8')
                g,m=result['straightness'],result['mtf']
                summaries.append(f"{name}: {asset['source']} | {asset['size']}\n"+metric_text(result))
    with (folder/'mtf_edges.csv').open('w',newline='',encoding='utf-8-sig') as f:
        writer=csv.writer(f);writer.writerow(['panel','x_px','y_px','mtf50_cycles_per_pixel','angle_deg'])
        for side,result in enumerate(results):
            if result:
                for e in result['mtf'].get('edges',[]): writer.writerow([('left','right')[side],e['x'],e['y'],e['mtf50_cpp'],e['angle_deg']])
    plot_items=[]
    for side,result in enumerate(results):
        edges=result['mtf'].get('edges',[]) if result else []
        if edges:
            filename=f'sfr_median_{side}.txt'
            np.savetxt(folder/filename,np.column_stack((np.arange(64)/64,np.median([e['sfr']for e in edges],axis=0))))
            plot_items.append(f"'{filename}' using 1:2 with lines lw 2 lc rgb '{('#2563eb','#de568f')[side]}' title '{('A / Left','B / Right')[side]} ({len(edges)} edges)'")
    # Reuse the standard plotting program bundled with MTF Mapper; no new Python dependencies.
    executable=find_mtf(next((r['mtf'].get('executable','')for r in results if r),''))
    gnuplot=Path(executable).parent/'gnuplot/gnuplot.exe' if executable else None
    if gnuplot and gnuplot.is_file():
        script=["set terminal pngcairo size 1200,600 font 'Arial,12'", "set output 'sfr_comparison.png'",
                "set title 'Median SFR per image (edges not automatically matched)'", "set xlabel 'Spatial frequency (cycles/pixel)'",
                "set ylabel 'SFR'", 'set xrange [0:0.5]', 'set yrange [0:1.5]', 'set grid',
                'plot '+(', '.join(plot_items) if plot_items else "0 notitle lw 0")]
        (folder/'sfr_plot.gp').write_text('\n'.join(script),encoding='ascii')
        plot=subprocess.run([str(gnuplot),'sfr_plot.gp'],cwd=folder,capture_output=True,timeout=20,
                            creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        (folder/'sfr_plot.log').write_bytes(plot.stdout+plot.stderr)
    # Standalone annotated comparison, aspect ratios preserved. Originals stay separate.
    if panels:
        width=960;height=max(round(im.height*width/im.width) for _,_,im in panels)
        canvas=Image.new('RGB',(width*len(panels),height+66),'#102238');draw=ImageDraw.Draw(canvas)
        for i,(side,name,im) in enumerate(panels):
            resized=im.resize((width,round(im.height*width/im.width)),Image.Resampling.LANCZOS)
            canvas.paste(resized,(i*width,66+(height-resized.height)//2))
            draw.text((i*width+18,12),name.upper()+' / '+assets[side]['source'],fill='white',font=_font(20))
            draw.text((i*width+18,40),f"Diagnostic overlay / displacement x{display['gain']} only" if display and display['mode']=='偏差放大' else 'Antialiased annotation / source pixels measured',fill='#AFC6DF')
        canvas.save(folder/'comparison.png')
    parts=['<!doctype html><meta charset="utf-8"><title>图像质量对比报告</title>',
           '<style>body{font:16px sans-serif;max-width:1250px;margin:30px auto;color:#173250}img{max-width:100%}pre{white-space:pre-wrap}</style>',
           '<h1>图像质量对比报告</h1><p>测量使用未标注的原尺寸像素。左右为独立图像，需人工确认同场景、倍率与区域；报告不自动判定比赛达标。</p>',
           '<h2>文字分析</h2><pre>'+html.escape(narrative)+'</pre><p>'+html.escape(comparison_text(results))+'</p><pre>'+html.escape('\n'.join(summaries))+'</pre><img src="comparison.png">',
           '<h2>弯曲偏差放大图</h2><p>'+html.escape(model['note'])+'</p><img src="curvature_comparison.png">'+('<img src="sfr_comparison.png">' if (folder/'sfr_comparison.png').is_file() else ''),
           (f'<p>白线为拟合参考；彩色曲线为二阶弯曲趋势 ×{display["gain"]}，点为放大后的实测角点偏差。趋势线仅辅助观察，照片与测量不变；实际偏差图保留原始角点采样。</p>' if display and display['mode']=='偏差放大' else '<p>检测标记采用抗锯齿绘制；几何位置使用原图测量坐标。</p>'),
           '<p>完整逐线数据见 straightness.csv；MTF50 与原始 SFR 数据见 CSV / TXT；来源、SHA256、参数及限制见 report.json。</p>']
    (folder/'report.html').write_text('\n'.join(parts),encoding='utf-8')
    return folder


def _font(size):
    try: return ImageFont.truetype(r'C:\Windows\Fonts\msyh.ttc',size)
    except OSError: return ImageFont.load_default()
