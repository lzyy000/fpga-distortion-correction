"""Inspect floating-point candidate maps; this does not validate FPGA arithmetic."""
from pathlib import Path
import json,sys
import cv2,numpy as np
root=Path(__file__).resolve().parents[1]
candidate=Path(sys.argv[1]);cal=json.loads(candidate.read_text(encoding='utf-8'))
K=np.array(cal['K'],np.float64);D=np.array(cal['D'],np.float64)
mx,my=cv2.initUndistortRectifyMap(K,D,None,K,(1920,1080),cv2.CV_32FC1)
finite=bool(np.isfinite(mx).all() and np.isfinite(my).all())
inside=(mx>=0)&(mx<=1919)&(my>=0)&(my<=1079)
row_span=np.floor(my.max(axis=1))-np.floor(my.min(axis=1))+2
dxdu=np.diff(mx,axis=1)[:-1];dxdv=np.diff(mx,axis=0)[:,:-1]
dydu=np.diff(my,axis=1)[:-1];dydv=np.diff(my,axis=0)[:,:-1]
jacobian=dxdu*dydv-dxdv*dydu
result={'candidate':str(candidate.resolve()),'scope':'OpenCV floating-point map only; fixed-point, cache residency, bandwidth and FPGA timing not verified.',
    'finite':finite,'x_range':[float(mx.min()),float(mx.max())],'y_range':[float(my.min()),float(my.max())],
    'source_out_of_bounds_fraction':float(1-inside.mean()),'min_local_jacobian_determinant':float(jacobian.min()),
    'max_source_rows_needed_per_output_row':int(row_span.max()),
    'candidate_status':cal['status'],'stability_map_change_pixels':cal['stability']['max_mapping_change_pixels'],
    'ready_for_fpga':False,'reasons':([*cal['stability'].get('warnings', []),
        'R13 camera top does not instantiate the distortion remap path.',
        'Legacy board_map.h does not represent measured principal point and nonzero k3.'])}
output=Path(sys.argv[2]).resolve() if len(sys.argv)>2 else root/'reports/candidate_mapping_check.json'
assert root in output.parents, 'Report output must be inside the project'
output.parent.mkdir(parents=True,exist_ok=True)
output.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(result,ensure_ascii=False,indent=2))
