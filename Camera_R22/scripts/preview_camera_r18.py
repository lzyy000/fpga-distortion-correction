"""Reproduce the fixed-point HDL transform on saved RGB images (offline only)."""
from pathlib import Path
import json
import numpy as np
from PIL import Image,ImageDraw
P=Path(__file__).resolve().parents[1]
SAMPLES=['camera_20261020_190334_804311_f3719.png','camera_20261019_200523_573975_f2321.png']
GAMMAS=[.55,.6,.65,.7,.75,.8,.9,1.,1.1,1.2]
def main():
 rom=np.array([int(s,16) for s in (P/'rtl/night_gain.hex').read_text().split()],dtype=np.uint32)
 canvas=Image.new('RGB',(1280,832),'#152032');draw=ImageDraw.Draw(canvas);records=[]
 for row,name in enumerate(SAMPLES):
  path=P/'captures/retake_20261011_152448'/name
  original=np.asarray(Image.open(path).convert('RGB'));a=original.astype(np.uint32)
  pix=((a[:,:,0]>>3)<<11)|((a[:,:,1]>>2)<<5)|(a[:,:,2]>>3)
  r=(pix>>11)&31;g=(pix>>5)&63;b=pix&31
  v=np.maximum(np.maximum(r*8,g*4),b*8);mean=float(v.mean())
  c=next((c for limit,c in [(24,0),(32,1),(44,2),(60,3),(76,4),(94,5),(112,6)] if mean<limit),9 if mean>220 else 8 if mean>195 else 7)
  q=rom[c*256+v]
  rr=np.minimum(31,(r*q+128)>>8);gg=np.minimum(63,(g*q+128)>>8);bb=np.minimum(31,(b*q+128)>>8)
  rgb=np.stack([rr*8,gg*4,bb*8],axis=2).astype(np.uint8)
  y=row*416;draw.text((12,y+12),'Offline software check: '+name,fill='white')
  draw.text((12,y+32),'Original captured frame',fill='white');draw.text((652,y+32),f'Adaptive Gamma {GAMMAS[c]:.2f}, curve {c}, mean V {mean:.1f}',fill='white')
  canvas.paste(Image.fromarray(original).resize((640,360)),(0,y+56));canvas.paste(Image.fromarray(rgb).resize((640,360)),(640,y+56))
  records.append({'input':str(path),'mean_v_before':mean,'curve':c,'gamma':GAMMAS[c],'mean_v_after':float(rgb.max(axis=2).mean()),'scope':'Offline fixed-point software preview only; not board output or denoising.'})
 canvas.save(P/'reports/r18_night_offline_preview.jpg',quality=90)
 (P/'reports/r18_night_offline_preview.json').write_text(json.dumps(records,indent=2),encoding='utf-8')
 print('Saved offline fixed-point previews; not physical acceptance evidence.')
if __name__=='__main__':main()
