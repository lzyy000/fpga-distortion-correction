"""Bound the current static calibration with the exact map-generator integer arithmetic."""
from pathlib import Path
import sys,re,json,hashlib
P=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(P/'tools/python_packages'))
import numpy as np

def i32(v):return np.asarray(v).astype(np.int32).astype(np.int64)
def mul(a,b):return i32((a*b+(1<<29))>>30)
def calibrated_map():
 vh=P/'rtl/camera_calibration.vh';d={}
 for name,sign,value in re.findall(r'\b(\w+)\s*=\s*(-?)32\x27sd(\d+)',vh.read_text(encoding='utf-8-sig')):d[name]=(-1 if sign else 1)*int(value)
 u=np.arange(1920,dtype=np.int64)[None,:];v=np.arange(1080,dtype=np.int64)[:,None]
 x=i32(u*d['INV_FX']-d['CX_NORM']);y=i32(v*d['INV_FY']-d['CY_NORM'])
 xx=mul(x,x);yy=mul(y,y);xy=mul(x,y);r2=i32(xx+yy)
 t=mul(r2,d['K3']);t=mul(r2,i32(d['K2']+t));radial=i32((1<<30)+mul(r2,i32(d['K1']+t)))
 xr=mul(x,radial);yr=mul(y,radial)
 xd=i32(xr+mul(d['P1'],i32(xy*2))+mul(d['P2'],i32(r2+xx*2)))
 yd=i32(yr+mul(d['P1'],i32(r2+yy*2))+mul(d['P2'],i32(xy*2)))
 qx=i32((xd*d['FX16']+d['CX16']*(1<<30)+(1<<40))>>41)
 qy=i32((yd*d['FY16']+d['CY16']*(1<<30)+(1<<40))>>41)
 return np.where((qx>=-32)&(qx<1920*32),qx,1920*32),np.where((qy>=-32)&(qy<1080*32),qy,1080*32)

def check(write=True):
 qx,qy=calibrated_map();sy=qy>>5;valid=(sy>=-1)&(sy<1080)
 lo=np.min(np.where(valid,np.maximum(sy,0),1080),axis=1)
 hi=np.max(np.where(valid,np.minimum(sy+1,1079),-1),axis=1)
 span=hi-lo+1;worst=int(np.argmax(span));capacity=32
 assert int(span.max())<=capacity,'Static calibration exceeds 32-row cache; re-evaluate cache capacity before building'
 top=(P/'rtl/camera_1080p_top_r21.v').read_text(encoding='utf-8')
 assert '.CACHE_ROW_BITS(5)' in top,'Active static cache capacity differs from this bound check'
 report={'pass':True,'calibration_sha256':hashlib.sha256((P/'rtl/camera_calibration.vh').read_bytes()).hexdigest(),
 'pixels_checked':1920*1080,'output_rows':1080,'max_source_rows':int(span.max()),'cache_rows':capacity,
 'worst_output_row':worst,'worst_source_rows':[int(lo[worst]),int(hi[worst])],
 'scope':'Exact Q30/Q16 map-generator arithmetic with signed Q5 packing and both bilinear rows; numeric bounds, not full-frame RTL or PDS placement.'}
 if write:(P/'reports/r22_static_cache_bounds.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
 return report

if __name__=='__main__':
 r=check();print(f"PASS R22 static cache: all {r['pixels_checked']} coordinates, max {r['max_source_rows']}/{r['cache_rows']} source rows")
