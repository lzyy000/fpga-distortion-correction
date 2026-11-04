"""Export the frozen measured R14 camera model to fixed-point hardware constants."""
from pathlib import Path
import json,hashlib
import numpy as np
P=Path(__file__).resolve().parents[1]
file=P/'firmware/camera_calibration.json';cal=json.loads(file.read_text(encoding='utf-8-sig'))
K=np.array(cal['K']);D=np.array(cal['D']);assert cal['calibration_size']==[1920,1080]
assert D.shape==(5,) and np.allclose(cal['R'],np.eye(3)) and np.allclose(cal['K_prime'],K)
assert K[0,1]==0 and K[1,0]==0 and K[0,0]>0 and K[1,1]>0
q30=lambda v:round(v*(1<<30));q16=lambda v:round(v*(1<<16))
params={'INV_FX':q30(1/K[0,0]),'INV_FY':q30(1/K[1,1]),'CX_NORM':q30(K[0,2]/K[0,0]),'CY_NORM':q30(K[1,2]/K[1,1]),'FX16':q16(K[0,0]),'FY16':q16(K[1,1]),'CX16':q16(K[0,2]),'CY16':q16(K[1,2]),**{n:q30(v) for n,v in zip(('K1','K2','P1','P2','K3'),D)}}
assert all(-(1<<31)<=v<1<<31 for v in params.values())
header='// Measured calibration; signed Q30 normalized values and Q16 intrinsics.\n'
for k,v in params.items():header+=f'localparam signed [31:0] {k}='+('-' if v<0 else '')+f"32'sd{abs(v)};\n"
for name in ('rtl/camera_calibration.vh','pnr_camera_r16_rxalign/camera_calibration.vh'):
 path=P/name
 if not path.exists() or path.read_text(encoding='ascii')!=header:path.write_text(header,encoding='ascii')
result={'source':str(file),'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'fixed_constants':params,'format':'Q30 normalized polynomial, Q16 intrinsics, signed Q5 DDR coordinates','map_base':'03000000'}
(P/'reports/camera_r14_calibration_fixed.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print('PASS exported measured R14 calibration; original/corrected output K matches full-frame PC model.')
