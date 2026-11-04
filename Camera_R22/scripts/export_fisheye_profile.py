"""Generate the separate OpenCV-fisheye profile; leave Brown calibration intact."""
from pathlib import Path
import json,hashlib,math
P=Path(__file__).resolve().parents[1]
SOURCE=P/'firmware/camera_fisheye_calibration.json'
def write_if_changed(path,text):
 if not path.exists() or path.read_text(encoding='ascii')!=text:path.write_text(text,encoding='ascii')
def export():
 c=json.loads(SOURCE.read_text(encoding='utf-8-sig'));assert c['camera_model']=='opencv_fisheye' and c['calibration_size']==[1920,1080]
 K=c['K'];D=c['D'];N=c['K_prime'];assert len(D)==4
 # r^2 step 1/128, Q20 radial scale; two sequential reads on one physical ROM port.
 values=[]
 for i in range(1025):
  r=math.sqrt(i/128);theta=math.atan(r);t2=theta*theta
  scale=1.0 if not i else theta/r*(1+D[0]*t2+D[1]*t2**2+D[2]*t2**3+D[3]*t2**4)
  assert 0<scale<=1.00000001,'EIS conservative fisheye bounds require 0<scale<=1'
  values.append(round(scale*(1<<20)))
 text=''.join(f'{v:08x}\n' for v in values[:1024])
 write_if_changed(P/'rtl/camera_fisheye_scale.hex',text)
 write_if_changed(P/'pnr_camera_r21_modes/camera_fisheye_scale.hex',text)
 header='// Generated independently from the measured OpenCV fisheye candidate.\n'
 header+=f"localparam signed [31:0] FISHEYE_SCALE_END=32'sd{values[-1]};\n"
 write_if_changed(P/'rtl/camera_fisheye_scale.vh',header)
 def f(v):
  t=format(v,'.12g');return t+('.0' if '.' not in t and 'e' not in t else '')+'f'
 source=[K[0][0],K[1][1],K[0][2],K[1][2],0.,0.,0.,0.,0.]
 preview=[N[0][0],N[1][1],N[0][2],N[1][2]]
 header='/* Separate fisheye source K and balance=0 output K; no Brown coefficient reuse. */\n'
 header+='static float fisheye_intr[9]={'+','.join(map(f,source))+'};\n'
 header+='static const float fisheye_output[4]={'+','.join(map(f,preview))+'};\n'
 header+='static const float fisheye_dist[4]={'+','.join(map(f,D))+'};\n'
 header+='#define FISHEYE_CONFIG_TAG 0x46495348u\n'
 write_if_changed(P/'night/firmware/eis/fisheye_profile.h',header)
 out={'source':str(SOURCE),'source_sha256':hashlib.sha256(SOURCE.read_bytes()).hexdigest(),'camera_model':'opencv_fisheye','D_order':['k1','k2','k3','k4'],'LUT_samples':1025,'LUT_ram_words':1024,'LUT_step_r_squared':1/128,'LUT_format':'Q20 scale; linear interpolation; r^2 0..8','endpoint_q20':values[-1],'candidate_warning':'Trial calibration, processed-path inputs and leave-one-out sensitivity; not an independent optical calibration acceptance.','brown_files_modified':False}
 (P/'reports/fisheye_profile.json').write_text(json.dumps(out,ensure_ascii=False,indent=2),encoding='utf-8');print('PASS separate fisheye profile / single-read-port radial ROM generated')
if __name__=='__main__':export()
