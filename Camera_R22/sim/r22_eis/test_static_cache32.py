from pathlib import Path
import sys,json
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from local_tools import iverilog_root
P=Path(__file__).resolve().parents[2];O=P/'work/r22_ram_fix';sys.path.insert(0,str(P/'scripts'))
from check_r22_static_cache import calibrated_map,check
qx,qy=calibrated_map();rows=[1070,35,1070];gold=[];maps=[]
gain=[int(s,16) for s in (P/'rtl/night_gain.hex').read_text().split()]
for row in rows:
 for x,y in zip(qx[row],qy[row]):
  x,y=int(x),int(y);maps.append(((y&65535)<<16)|(x&65535))
  ix,iy=x>>5,y>>5;fx,fy=x&31,y&31
  values=[]
  for shift,mask in [(11,31),(5,63),(0,31)]:
   a=0
   for dx,wx in [(0,32-fx),(1,fx)]:
    for dy,wy in [(0,32-fy),(1,fy)]:
     sx,sy=ix+dx,iy+dy
     if 0<=sx<1920 and 0<=sy<1080:
      value=( (sy*1920+sx)*0x9e3779b9+0x7f4a7c15)&0xffffffff
      value=((value^(value>>16))*0x85ebca6b)&0xffffffff;pixel=(value^(value>>13))&65535
      a+=((pixel>>shift)&mask)*wx*wy
   values.append((a+512)//1024)
  g=gain[2*256+max(values[0]*8,values[1]*4,values[2]*8)]
  out=0
  for value,shift,mask in zip(values,[11,5,0],[31,63,31]):
   b=min(mask,(value*g+128)//256);out|=(value+((b-value)*128+128)//256)<<shift
  gold.append(out)
(O/'cache32_map.hex').write_text(''.join(f'{v:08x}\n' for v in maps),encoding='ascii')
(O/'cache32_gold.hex').write_text(''.join(f'{v:04x}\n' for v in gold),encoding='ascii')
(O/'map_init_gold.hex').write_text(''.join(f'{v:08x}\n' for v in maps[:1920]),encoding='ascii')
(O/'night_gain.hex').write_bytes((P/'rtl/night_gain.hex').read_bytes())
print(check())

import os,subprocess,hashlib
E=dict(os.environ,TEMP=str(O),TMP=str(O),PYTHONDONTWRITEBYTECODE='1');T=(iverilog_root()/'bin')
results={}
for name,top,mods,params in [
 ('static_map_row','tb_static_map_row',['camera_map_init','camera_mul32_pipe'],[]),
 ('cache32','tb_static_cache32',['video_row_remap_r21','camera_night_pixel_r19','camera_strength_blend_r19'],['-Ptb_static_cache32.CACHE_BITS=5']),
 ('cache64_reference','tb_static_cache32',['video_row_remap_r21','camera_night_pixel_r19','camera_strength_blend_r19'],['-Ptb_static_cache32.CACHE_BITS=6']),
 ('cache32_guard','tb_static_cache32',['video_row_remap_r21','camera_night_pixel_r19','camera_strength_blend_r19'],['-Ptb_static_cache32.CACHE_BITS=5','-Ptb_static_cache32.BAD_SPAN=1'])]:
 files=[P/'sim/r22_eis'/(top+'.v')]+[P/'rtl'/(m+'.v') for m in mods]
 cmd=[str(T/'iverilog.exe'),'-g2012','-I',str(P/'rtl'),'-s',top,*params,'-o',str(O/(name+'.vvp')),*map(str,files)]
 r=subprocess.run(cmd,cwd=O,env=E,capture_output=True,text=True);assert r.returncode==0,r.stderr
 r=subprocess.run([str(T/'vvp.exe'),str(O/(name+'.vvp'))],cwd=O,env=E,capture_output=True,text=True,timeout=40)
 (O/(name+'.log')).write_text(r.stdout+r.stderr,encoding='utf-8');print(r.stdout+r.stderr,flush=True)
 assert r.returncode==0 and 'PASS R22' in r.stdout and 'ERROR:' not in r.stdout,name
 results[name]={'pass':True,'output':r.stdout,'source_sha256':{f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in files}}
files=[Path(__file__),P/'scripts/check_r22_static_cache.py',P/'rtl/camera_1080p_top_r21.v',P/'rtl/camera_calibration.vh',P/'rtl/night_gain.hex']
(P/'reports/r22_static_cache_test.json').write_text(json.dumps({'pass':True,'cases':results,'full_frame_rtl':False,'pds_build_started':False,'source_sha256':{f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in files}},indent=2),encoding='utf-8')
