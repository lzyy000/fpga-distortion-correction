"""Correct saved full frames with a measured calibration, without changing inputs."""
from pathlib import Path
import datetime, hashlib, json, sys
import cv2
import numpy as np

root=Path(__file__).resolve().parents[1]
candidate, source, output=[Path(value).resolve() for value in sys.argv[1:4]]
assert root in output.parents, 'Outputs must stay inside the project'
cal=json.loads(candidate.read_text(encoding='utf-8-sig'))
K=np.asarray(cal['K'],np.float64); D=np.asarray(cal['D'],np.float64)
newK=np.asarray(cal.get('K_prime',cal['K']),np.float64)
R=np.asarray(cal.get('R',np.eye(3)),np.float64)
size=tuple(cal['calibration_size'])
assert K.shape==newK.shape==R.shape==(3,3) and D.shape==(5,)
assert all(np.isfinite(a).all() for a in (K,D,newK,R))
assert K[0,0]>0 and K[1,1]>0 and size==(1920,1080)
photos=sorted(source.glob('*.png')) if source.is_dir() else [source]
assert photos, 'No PNG images found'
mx,my=cv2.initUndistortRectifyMap(K,D,R,newK,size,cv2.CV_32FC1)
assert np.isfinite(mx).all() and np.isfinite(my).all()
output.mkdir(parents=True,exist_ok=True)
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
records=[]
for photo in photos:
    target=output/(photo.stem+'_undistorted.png')
    assert target.resolve()!=photo.resolve(), 'Cannot overwrite original image'
    original_hash=digest(photo)
    image=cv2.imdecode(np.fromfile(str(photo),np.uint8),cv2.IMREAD_COLOR)
    if image is None or image.shape[:2]!=(size[1],size[0]):
        raise ValueError(f'Wrong image size: {photo}; calibration expects {size}')
    corrected=cv2.remap(image,mx,my,cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
    ok, encoded=cv2.imencode('.png',corrected)
    assert ok
    encoded.tofile(str(target))
    assert digest(photo)==original_hash
    records.append(dict(source=str(photo),source_sha256=original_hash,output=str(target),output_sha256=digest(target)))
    print('CORRECTED '+target.name,flush=True)
(output/'calibration_used.json').write_text(json.dumps(cal,ensure_ascii=False,indent=2),encoding='utf-8')
report=dict(generated_at=datetime.datetime.now().astimezone().isoformat(),candidate=str(candidate),candidate_sha256=digest(candidate),size=list(size),interpolation='OpenCV bilinear',border='black',originals_unchanged=True,applied_to_fpga=False,scope='PC correction using the measured model; visual and independent photo validation still required.',photos=records)
(output/'correction_manifest.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print('OUTPUT '+str(output),flush=True)
