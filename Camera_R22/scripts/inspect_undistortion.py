"""Compare current saved photos with a calibration; auxiliary reports are optional.
Never refit parameters or require the old training pictures to still be present.
"""
from pathlib import Path
import datetime,hashlib,json,sys,shutil
import cv2,numpy as np
from PIL import Image,ImageDraw,ImageFont

root=Path(__file__).resolve().parents[1]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def line_statistics(points,pattern):
    grid=points.reshape(pattern[1],pattern[0],2);squared=[];groups=[]
    for direction,lines in [('row',grid),('column',np.swapaxes(grid,0,1))]:
        for i,line in enumerate(lines):
            centered=line-line.mean(axis=0)
            _,_,vectors=np.linalg.svd(centered,full_matrices=False)
            distances=centered@vectors[-1]
            squared.extend(distances**2)
            groups.append({'direction':direction,'index':i+1,
                'rms_pixels':float(np.sqrt(np.mean(distances**2))),
                'max_deviation_pixels':float(np.abs(distances).max())})
    return {'rms_pixels':float(np.sqrt(np.mean(squared))),
        'max_deviation_pixels':max(g['max_deviation_pixels'] for g in groups),'lines':groups}

def corners_for(photo,image,pattern,source_hash):
    expected=pattern[0]*pattern[1]
    try:
        q=json.loads(photo.with_suffix('.quality.json').read_text(encoding='utf-8-sig'))
        points=np.asarray(q.get('corners',[]),np.float64).reshape(-1,1,2)
        if (q.get('png_sha256')==source_hash and tuple(q.get('inner_corners',[]))==pattern
            and points.shape==(expected,1,2) and np.isfinite(points).all()
            and (points[:,:,0]>=0).all() and (points[:,:,0]<image.shape[1]).all()
            and (points[:,:,1]>=0).all() and (points[:,:,1]<image.shape[0]).all()):
            return points,'cached corners with matching image hash'
    except (OSError,ValueError,TypeError):
        pass
    gray=cv2.cvtColor(image,cv2.COLOR_BGR2GRAY)
    found,points=cv2.findChessboardCornersSB(gray,pattern,flags=cv2.CALIB_CB_NORMALIZE_IMAGE|cv2.CALIB_CB_EXHAUSTIVE|cv2.CALIB_CB_ACCURACY)
    if found and points is not None and len(points)==expected:
        return points.astype(np.float64),'redetected from current original; no sidecar changes'
    return None,'complete checkerboard not detected; visual comparison only'

def main(candidate,out):
    candidate=Path(candidate).resolve();out=Path(out).resolve()
    assert root in out.parents,'Review output must be inside the project'
    cal=json.loads(candidate.read_text(encoding='utf-8-sig'))
    K=np.array(cal['K'],np.float64);D=np.array(cal['D'],np.float64)
    newK=np.array(cal.get('K_prime',cal['K']),np.float64);R=np.array(cal.get('R',np.eye(3)),np.float64)
    size=tuple(cal['calibration_size']);pattern=tuple(cal['checkerboard']['inner_corners'])
    assert size==(1920,1080) and np.allclose(R,np.eye(3))
    assert all(np.isfinite(a).all() for a in (K,D,newK,R))
    mx,my=cv2.initUndistortRectifyMap(K,D,R,newK,size,cv2.CV_32FC1)
    assert np.isfinite(mx).all() and np.isfinite(my).all()
    photos=sorted(candidate.parent.glob('*.png'))
    if not photos:
        raise ValueError('当前保存目录没有 PNG 照片。参数文件可保留，拍一张新照片后再运行。')
    out.mkdir(parents=True,exist_ok=True);assets=out/'images';assets.mkdir(exist_ok=True)
    fit_views={Path(v['file']).resolve():v for v in cal.get('views',[])}
    missing=[str(p) for p in fit_views if not p.is_file()]
    try:font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',26)
    except OSError:font=ImageFont.load_default()
    rows=[];skipped=[]
    for photo in photos:
        source_hash=digest(photo)
        image=cv2.imdecode(np.fromfile(str(photo),np.uint8),cv2.IMREAD_COLOR)
        if image is None or image.shape!=(1080,1920,3):
            skipped.append({'file':str(photo),'reason':'Cannot decode a full 1920x1080 frame'})
            continue
        points,corner_source=corners_for(photo,image,pattern,source_hash)
        before=after=None;inverse_error=None;roi=[0,0,1920,1080];detail=None
        if points is not None:
            corrected_points=cv2.undistortPointsIter(points,K,D,R,newK,
                (cv2.TERM_CRITERIA_EPS|cv2.TERM_CRITERIA_MAX_ITER,100,1e-10))
            rays=(np.linalg.inv(newK)@np.column_stack([corrected_points.reshape(-1,2),np.ones(len(points))]).T).T
            back=cv2.projectPoints(rays,np.zeros(3),np.zeros(3),K,D)[0]
            inverse_error=float(np.linalg.norm(back-points,axis=2).max())
            if not np.isfinite(corrected_points).all() or inverse_error>=1e-3:
                raise ValueError(f'Inverse distortion failed for {photo.name}: {inverse_error}')
            before=line_statistics(points,pattern);after=line_statistics(corrected_points,pattern)
            allpts=np.vstack([points.reshape(-1,2),corrected_points.reshape(-1,2)])
            lo=np.maximum(np.floor(allpts.min(axis=0)-60).astype(int),[0,0])
            hi=np.minimum(np.ceil(allpts.max(axis=0)+60).astype(int),[1920,1080])
            roi=[int(lo[0]),int(lo[1]),int(hi[0]-lo[0]),int(hi[1]-lo[1])]
            if roi[2]<=0 or roi[3]<=0:roi=[0,0,1920,1080]
        corrected=cv2.remap(image,mx,my,cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
        original_path=assets/(photo.stem+'_original.png');fixed_path=assets/(photo.stem+'_corrected.png')
        shutil.copyfile(photo,original_path)
        ok,encoded=cv2.imencode('.png',corrected);assert ok;encoded.tofile(str(fixed_path))
        assert digest(original_path)==source_hash==digest(photo)
        display=Image.new('RGB',(1920,605),'#e9edf2');draw=ImageDraw.Draw(display)
        for side,(data,label) in enumerate([(image,'原始照片'),(corrected,'当前参数矫正')]):
            preview=Image.fromarray(cv2.cvtColor(data,cv2.COLOR_BGR2RGB));preview.thumbnail((960,540))
            display.paste(preview,(side*960,65));draw.text((side*960+20,10),label,font=font,fill='#17283d')
        comparison=out/('comparison_'+photo.stem+'.png');display.save(comparison)
        if points is not None:
            x0,y0,w,h=roi
            crop_pair=Image.new('RGB',(w*2,h+60),'#e9edf2');crop_draw=ImageDraw.Draw(crop_pair)
            for side,(data,label) in enumerate([(image,'原始棋盘格 · 1:1'),(corrected,'矫正棋盘格 · 1:1')]):
                crop=Image.fromarray(cv2.cvtColor(data[y0:y0+h,x0:x0+w],cv2.COLOR_BGR2RGB))
                crop_pair.paste(crop,(side*w,60));crop_draw.text((side*w+15,8),label,font=font,fill='#17283d')
            detail='checkerboard_detail_'+photo.stem+'.png';crop_pair.save(out/detail)
        fit=fit_views.get(photo.resolve())
        rows.append({'index':len(rows)+1,'file':photo.name,'source':str(photo),'source_sha256':source_hash,
            'original':'images/'+original_path.name,'corrected':'images/'+fixed_path.name,
            'comparison':comparison.name,'detail':detail,'roi':roi,
            'corner_count':len(points) if points is not None else 0,'corner_source':corner_source,
            'before':before,'after':after,'improved':after['rms_pixels']<before['rms_pixels'] if after is not None else None,
            'inverse_roundtrip_max_pixels':inverse_error,'used_for_calibration':fit is not None,
            'calibration_rms_pixels':fit.get('rms_pixels') if fit else None})
        metric=f'{before["rms_pixels"]:.3f} -> {after["rms_pixels"]:.3f} px' if after is not None else 'no full checkerboard; visual comparison available'
        print(photo.name+': '+metric,flush=True)
    result={'generated_at':datetime.datetime.now().astimezone().isoformat(),
        'candidate':str(candidate),'candidate_sha256':digest(candidate),'output_size':list(size),
        'K_prime_equals_K':bool(np.allclose(K,newK)),'interpolation':'OpenCV bilinear',
        'scope':'Current saved photos with fixed calibration. Training-list membership is recorded per photo; transformed detected corners are not independent ground truth.',
        'straightness_method':'PCA orthogonal line fit to checkerboard rows and columns where all inner corners were found.',
        'improved_views':sum(r['improved'] is True for r in rows),
        'measured_views':sum(r['after'] is not None for r in rows),'views':rows,
        'missing_calibration_sources':missing,'skipped_current_photos':skipped,
        'stability_max_mapping_change_pixels':cal.get('stability',{}).get('max_mapping_change_pixels')}
    (out/'review.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    template=(root/'scripts/undistortion_review_template.html').read_text(encoding='utf-8')
    data=json.dumps(result,ensure_ascii=False).replace('<',chr(92)+'u003c')
    (out/'index.html').write_text(template.replace('__REVIEW_DATA__',data),encoding='utf-8')
    print(f'REVIEW {out / "index.html"}; {len(rows)} photos, {len(missing)} old training originals absent; calibration unchanged.',flush=True)
    return result

if __name__=='__main__':
    main(sys.argv[1],sys.argv[2] if len(sys.argv)>2 else root/'calibration-review')
