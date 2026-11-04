"""Assess original frames and calibrate confirmed 9x6 / 25 mm checkerboard views.
No image resize/crop/undistortion occurs before corner detection or calibration.
Quality cutoffs are collection heuristics, not guarantees of calibration accuracy.
"""
from pathlib import Path
import hashlib,json,datetime
import cv2
import numpy as np

PATTERN=(9,6)
SQUARE_MM=25.0
SIZE=(1920,1080)
QUALITY_POLICY='fixed_focus_review_v2'

def load_image(path):
    image=cv2.imdecode(np.fromfile(str(path),dtype=np.uint8),cv2.IMREAD_COLOR)
    if image is None:raise ValueError('无法解码照片')
    return image

def detect(image):
    gray=cv2.cvtColor(image,cv2.COLOR_BGR2GRAY)
    found,corners=cv2.findChessboardCornersSB(gray,PATTERN,flags=cv2.CALIB_CB_NORMALIZE_IMAGE|cv2.CALIB_CB_EXHAUSTIVE|cv2.CALIB_CB_ACCURACY)
    result={'size':[image.shape[1],image.shape[0]],'expected_size':list(SIZE),
            'quality_policy':QUALITY_POLICY,
            'inner_corners':list(PATTERN),'square_mm':SQUARE_MM,'corner_count':0,
            'status':'RETAKE','advice':[],'warnings':[],'usable_for_calibration':False}
    overlay=image.copy()
    if tuple(result['size'])!=SIZE:result['advice'].append('必须保存原始 1920×1080 完整帧，不能用缩放图、截图或裁剪图。')
    if not found or corners is None or len(corners)!=54:
        result['advice'].append('未找到全部 54 个内角点：让整块棋盘格入镜，保持平整，避免反光和运动模糊。')
        return result,overlay
    pts=corners.reshape(-1,2);grid=pts.reshape(PATTERN[1],PATTERN[0],2)
    result['corner_count']=54;result['corners']=pts.tolist()
    cv2.drawChessboardCorners(overlay,PATTERN,corners,True)
    hull=cv2.convexHull(pts.astype(np.float32))
    area=float(cv2.contourArea(hull)/(image.shape[0]*image.shape[1]))
    spacing=np.concatenate([np.linalg.norm(np.diff(grid,axis=1),axis=2).ravel(),np.linalg.norm(np.diff(grid,axis=0),axis=2).ravel()])
    margin=float(min(pts[:,0].min(),pts[:,1].min(),image.shape[1]-1-pts[:,0].max(),image.shape[0]-1-pts[:,1].max()))
    result.update(board_inner_area_fraction=area,min_corner_spacing_px=float(spacing.min()),
                  corner_margin_px=margin,center_normalized=(pts.mean(axis=0)/np.array(SIZE)).tolist())
    try:
        sharpness=[];black=[];white=[]
        for vertical in [False,True]:
            summary,profiles=cv2.estimateChessboardSharpness(gray,PATTERN,corners,vertical=vertical)
            if len(profiles)>0 and np.isfinite(summary[0]) and summary[0]>0:
                sharpness.append(float(summary[0]));black.append(float(summary[1]));white.append(float(summary[2]))
        result['edge_transition_px']=max(sharpness) if sharpness else None
        result['black_level']=float(np.mean(black)) if black else None
        result['white_level']=float(np.mean(white)) if white else None
        result['contrast']=float(np.mean(white)-np.mean(black)) if white else None
    except cv2.error:
        result.update(edge_transition_px=None,contrast=None,black_level=None,white_level=None)
    if area<0.04:result['advice'].append('棋盘格太小，请靠近一些；保持全部方格及白色外边框入镜。')
    if float(spacing.min())<12:result['advice'].append('部分格子投影太小或倾斜过大，请靠近或减少倾斜。')
    if result['edge_transition_px'] is None:
        result['warnings'].append('无法可靠估计清晰度，需要人工复查。')
    elif result['edge_transition_px']>3.0:
        result['warnings'].append('边缘清晰度有限；固定焦点相机可参与试算，需结合逐帧重投影误差和参数稳定性复查。')
    if result['contrast'] is not None and result['contrast']<70:
        result['advice'].append('黑白对比不足，请调整光照并避免反光。')
    if margin<float(spacing.max())*1.05:
        result['warnings'].append('外侧方格可能接近画面边界，请确认整块棋盘格及白边都没有截断。')
    if result['white_level'] is not None and result['white_level']>250:
        result['warnings'].append('白格亮度接近饱和，请检查局部反光和过曝。')
    if result['black_level'] is not None and result['black_level']>110:
        result['warnings'].append('黑格偏亮，请检查反光、照明和打印对比度。')
    result['usable_for_calibration']=not result['advice']
    result['status']='KEEP' if result['usable_for_calibration'] and not result['warnings'] else 'REVIEW' if result['usable_for_calibration'] else 'RETAKE'
    if result['usable_for_calibration']:
        result['advice'].append('可作为候选：接下来改变位置、距离及水平/垂直倾斜，覆盖四角与边缘，避免连续拍同一姿势。')
    return result,overlay

def assess_file(path):
    path=Path(path);image=load_image(path)
    report,overlay=detect(image)
    report.update(file=str(path.resolve()),png_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                  assessed_at=datetime.datetime.now().astimezone().isoformat(),
                  scope='Image quality only; sensor provenance and frame transport CRC require the snapshot JSON.')
    sidecar=path.with_suffix('.json')
    if sidecar.is_file():
        metadata=json.loads(sidecar.read_text(encoding='utf-8'))
        if metadata.get('png_sha256')!=report['png_sha256']:
            report['usable_for_calibration']=False;report['status']='RETAKE';report['advice'].insert(0,'照片与抓拍记录的 SHA256 不匹配，请重新抓拍。')
        if metadata.get('geometry_flags',0) or metadata.get('fisheye_applied') or metadata.get('eis_applied') or metadata.get('distortion_calibration_performed'):
            report['usable_for_calibration']=False;report['status']='RETAKE';report['advice'].insert(0,'此照片已做几何处理，不能作为原始镜头标定照片，请关闭矫正/鱼眼/防抖/旋转稳像后重新拍摄。')
        report['transport']={k:metadata.get(k) for k in ('source','frame_id','crc32','pixel_format','width','height')}
    else:
        report['warnings'].append('缺少抓拍 JSON，无法验证来源和传输记录。')
        if report['status']=='KEEP':report['status']='REVIEW'
    path.with_suffix('.quality.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    return report,overlay

def object_points():
    points=np.zeros((54,3),np.float32)
    points[:,:2]=np.mgrid[0:PATTERN[0],0:PATTERN[1]].T.reshape(-1,2)*SQUARE_MM
    return points

def fit_views(corners,files):
    if len(corners)<12:raise ValueError('至少需要 12 张不同姿势的合格候选照片；建议拍摄更多并覆盖画面边缘。')
    objects=[object_points() for _ in corners]
    rms,K,D,rvecs,tvecs,si,se,errors=cv2.calibrateCameraExtended(objects,corners,SIZE,None,None,
        criteria=(cv2.TERM_CRITERIA_EPS|cv2.TERM_CRITERIA_MAX_ITER,100,1e-9))
    if not np.isfinite(K).all() or not np.isfinite(D).all() or not np.isfinite(errors).all():raise ValueError('标定结果非有限数值')
    per_view=errors.ravel();centers=np.array([c.reshape(-1,2).mean(axis=0)/SIZE for c in corners])
    cells={(min(2,int(x*3)),min(2,int(y*3))) for x,y in centers}
    rotation_vectors=np.array([r.ravel() for r in rvecs])
    rotation_span=np.ptp(rotation_vectors,axis=0)
    warnings=[]
    if rms>0.5:warnings.append('重投影 RMS 超过 0.5 像素，请复查照片及逐帧误差。')
    if per_view.max()>1.0:warnings.append('存在逐帧 RMS 超过 1 像素的照片，请定位并复查，不自动删除。')
    if len(cells)<5:warnings.append('棋盘格中心位置覆盖不足，请补拍左、右、上、下及四角区域。')
    if max(rotation_span[:2])<0.3:warnings.append('倾斜姿势变化不足，请补拍绕水平和垂直方向倾斜的画面。')
    if not (0<K[0,2]<SIZE[0] and 0<K[1,2]<SIZE[1]):warnings.append('主点位于图像范围之外，请检查数据和模型。')
    return {'model':'Brown-Conrady five coefficients','K':K.tolist(),'D':D.ravel()[:5].tolist(),
            'calibration_size':list(SIZE),'K_prime':K.tolist(),'R':np.eye(3).tolist(),
            'checkerboard':{'inner_corners':list(PATTERN),'square_size_mm':SQUARE_MM},
            'rms_pixels':float(rms),'views':[{'file':str(f),'rms_pixels':float(e)} for f,e in zip(files,per_view)],
            'intrinsics_stddev':si.ravel().tolist(),'coverage_cells':len(cells),
            'rotation_span_radians':rotation_span.tolist(),'warnings':warnings,
            'status':'CANDIDATE_NEEDS_REVIEW' if warnings else 'CANDIDATE',
            'applied_to_fpga':False,
            'fpga_changes_required':'Current board_map.h fixes cx/cy to center, integer focal lengths and k3=0; use measured fx/fy/cx/cy and all coefficients with overflow/numerical checks before a new corrected bitstream.'}

def calibrate_directory(directory):
    directory=Path(directory);views=[];files=[];excluded=[];review_views=[]
    # Older capture-only consoles saved PNG/transport JSON without quality reports.
    for image in sorted(directory.glob('*.png')):
        quality_file=image.with_suffix('.quality.json')
        try:previous=json.loads(quality_file.read_text(encoding='utf-8'))
        except (OSError,ValueError):previous={}
        if previous.get('quality_policy')!=QUALITY_POLICY or previous.get('png_sha256')!=hashlib.sha256(image.read_bytes()).hexdigest():
            assess_file(image)
    for file in sorted(directory.glob('*.quality.json')):
        report=json.loads(file.read_text(encoding='utf-8'));image=Path(report['file'])
        if not report.get('usable_for_calibration'):continue
        if not image.is_file() or hashlib.sha256(image.read_bytes()).hexdigest()!=report['png_sha256']:
            excluded.append({'file':str(image),'reason':'照片已变化或不存在'});continue
        corners=np.array(report['corners'],np.float32).reshape(-1,1,2)
        if any(min(np.sqrt(np.mean((corners-old)**2)),np.sqrt(np.mean((corners[::-1]-old)**2)))<12 for old in views):
            excluded.append({'file':str(image),'reason':'与已选照片姿势过于接近'});continue
        views.append(corners);files.append(str(image))
        if report.get('status')=='REVIEW':review_views.append({'file':str(image),'warnings':report['warnings']})
    if len(views)<12:
        raise ValueError(f'已检测 {len(list(directory.glob("*.png")))} 张照片，目前有 {len(views)} 张合格且姿势不同的候选；至少需要 12 张，请补拍清晰完整棋盘格及不同姿势。')
    result=fit_views(views,files);result['excluded']=excluded
    result['quality_review_views']=review_views
    if review_views:
        result['warnings'].append(f'{len(review_views)} 张照片有清晰度或边界等复查提示，参数为试算候选，需验证稳定性与矫正效果。')
        result['status']='CANDIDATE_NEEDS_REVIEW'
    result['stability']=validate_view_stability(views,result)
    result['warnings'].extend(result['stability']['warnings'])
    if result['warnings']:result['status']='CANDIDATE_NEEDS_REVIEW'
    result['generated_at']=datetime.datetime.now().astimezone().isoformat()
    output=directory/'calibration_candidate.json'
    output.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    return result,output

def validate_view_stability(corners,result):
    """Hold out each view's intrinsics, refit its pose, compare the correction map.
    Limits are practical review heuristics, not a calibration accuracy guarantee.
    Grid coordinates use the full-fit K as a common output projection for every fit.
    """
    objects=object_points();baseK=np.array(result['K'],np.float64)
    grid=np.array([(x,y,1) for y in (0,539.5,1079) for x in (0,959.5,1919)],np.float64)
    rays=(np.linalg.inv(baseK)@grid.T).T
    base_map=cv2.projectPoints(rays,np.zeros(3),np.zeros(3),baseK,np.array(result['D']))[0].reshape(-1,2)
    trials=[]
    for index in range(len(corners)):
        training=[c for j,c in enumerate(corners) if j!=index]
        rms,K,D,_,_=cv2.calibrateCamera([objects]*len(training),training,SIZE,None,None,
            criteria=(cv2.TERM_CRITERIA_EPS|cv2.TERM_CRITERIA_MAX_ITER,100,1e-9))
        ok,rvec,tvec=cv2.solvePnP(objects,corners[index],K,D)
        if not ok:raise ValueError('留一法无法估计被保留照片的姿态')
        projected=cv2.projectPoints(objects,rvec,tvec,K,D)[0]
        error=float(np.sqrt(np.mean(np.sum((projected-corners[index])**2,axis=2))))
        mapping=cv2.projectPoints(rays,np.zeros(3),np.zeros(3),K,D)[0].reshape(-1,2)
        if not np.isfinite(K).all() or not np.isfinite(D).all() or not np.isfinite(mapping).all():
            raise ValueError('留一法参数或映射出现非有限值')
        trials.append({'omitted_view':index,'training_rms_pixels':float(rms),'held_out_rms_pixels':error,
            'K':K.tolist(),'D':D.ravel().tolist(),
            'max_mapping_change_pixels':float(np.linalg.norm(mapping-base_map,axis=1).max())})
    Ks=np.array([t['K'] for t in trials]);warnings=[]
    focal_span=max(np.ptp(Ks[:,0,0])/baseK[0,0],np.ptp(Ks[:,1,1])/baseK[1,1])
    mapping_change=max(t['max_mapping_change_pixels'] for t in trials)
    held_out_error=max(t['held_out_rms_pixels'] for t in trials)
    if focal_span>.05:warnings.append('留一法焦距范围超过 5%，请补充不同倾斜、距离和位置的照片。')
    if mapping_change>20:warnings.append('留一法边界映射变化超过 20 像素，矫正参数不稳定，请补拍画面边缘和不同倾斜方向。')
    if held_out_error>1:warnings.append('留一法存在验证 RMS 超过 1 像素的照片，请检查板材平整度、运动和角点定位。')
    return {'method':'Leave-one-view-out intrinsics; refit held-out pose; common-K 3x3 correction-map probes',
            'heuristic_limits':{'focal_span_fraction':.05,'mapping_change_pixels':20,'held_out_rms_pixels':1},
            'max_mapping_change_pixels':mapping_change,'max_held_out_rms_pixels':held_out_error,
            'fx_range':[float(Ks[:,0,0].min()),float(Ks[:,0,0].max())],
            'fy_range':[float(Ks[:,1,1].min()),float(Ks[:,1,1].max())],
            'trials':trials,'warnings':warnings}
