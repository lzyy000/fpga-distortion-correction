"""Finite R22 migration tests; no full-frame/PDS build or board access."""
from pathlib import Path
import os,subprocess,json,math,hashlib,sys
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from local_tools import iverilog_root
P=Path(__file__).resolve().parents[2];W=P/'work/r22_eis';W.mkdir(parents=True,exist_ok=True)
E=dict(os.environ,TEMP=str(W),TMP=str(W),PYTHONDONTWRITEBYTECODE='1');T=(iverilog_root()/'bin')

def s(x):return ((x+(1<<31))%(1<<32))-(1<<31)
def div(a,b):return -(abs(a)//b) if a<0 else a//b

def lens(c,x,y):
 xx=s(x*x>>20);yy=s(y*y>>20);xy=s(x*y>>20);r=s(xx+yy);r4=s(r*r>>20);r6=s(r4*r>>20)
 radial=s((1<<20)+(c[13]*r>>20)+(c[14]*r4>>20)+(c[17]*r6>>20))
 tx=s((c[15]*s(xy*2)>>20)+(c[16]*s(r+2*xx)>>20));ty=s((c[16]*s(xy*2)>>20)+(c[15]*s(r+2*yy)>>20))
 return (s((x*radial>>20)+tx)*c[9]>>20)+c[11],(s((y*radial>>20)+ty)*c[10]>>20)+c[12]
def mapping(c,u,v):
 d=c[6]*u+c[7]*v+c[8];x=div((c[0]*u+c[1]*v+c[2])<<20,d);y=div((c[3]*u+c[4]*v+c[5])<<20,d)
 px,py=lens(c,x,y);flags=c[27]&0xffffffff;sl=s(flags)>>8
 if flags&4 and 0<abs(sl)<=65536 and 0<=px<127*256 and 0<=py<95*256:
  theta=sl*(py-95*128)>>18;d=((1<<20)+(theta*x>>20))<<4
  x,y=div(((x-theta)<<4)<<20,d),div((y<<4)<<20,d);px,py=lens(c,x,y)
 assert 0<=px<127*256 and 0<=py<95*256,(u,v,px,py)
 return px,py

def source(x,y):return (((x*3+y*7)&31)<<11)|(((x*5+y*11)&63)<<5)|((x*7+y*3)&31)
def vectors():
 base=[131072,0,4259840,0,131072,2129920,0,0,16777216,16384,16384,0,0,0,0,0,0,0]
 configs=[]
 for f in range(4):
  c=base[:]
  if f==1:c[13]=int(-.1*(1<<20));c[15]=100;c[16]=-150
  if f==2:c[0],c[1],c[3],c[4]=0,131072,131072,0
  c+=[v*8 for v in base[:9]]+[1|4|(2000<<8) if f==3 else 1];configs.append(c)
 (W/'render_words.hex').write_text(''.join(f'{v&0xffffffff:08x}\n' for c in configs for v in c),encoding='ascii')
 gains=[int(v,16) for v in (P/'rtl/night_gain.hex').read_text().split()];gold=[]
 for f,c in enumerate(configs):
  m=[[mapping(c,x*64,y*64) for x in range(3)] for y in range(3)]
  for y in range(96):
   for x in range(128):
    gx,gy=x//64,y//64;fx,fy=x%64,y%64
    xy=[(m[gy][gx][i]*(64-fy)*(64-fx)+m[gy][gx+1][i]*(64-fy)*fx+m[gy+1][gx][i]*fy*(64-fx)+m[gy+1][gx+1][i]*fy*fx)>>12 for i in (0,1)]
    ix,iy=xy[0]>>8,xy[1]>>8;ax,ay=xy[0]&255,xy[1]&255
    q=[source(ix,iy),source(ix+1,iy),source(ix,iy+1),source(ix+1,iy+1)];values=[]
    for shift,mask in [(11,31),(5,63),(0,31)]:
     z=[(v>>shift)&mask for v in q]
     values.append(((z[0]*(256-ax)+z[1]*ax)*(256-ay)+(z[2]*(256-ax)+z[3]*ax)*ay+32768)>>16)
    curve=2 if f==1 else 0 if f==2 else 7;strength=128 if f==1 else 256
    gain=gains[curve*256+max(values[0]*8,values[1]*4,values[2]*8)]
    out=0
    for value,shift,mask in zip(values,[11,5,0],[31,63,31]):
     b=value if curve==7 else min(mask,(value*gain+128)//256)
     out|=(value+((b-value)*strength+128)//256)<<shift
    gold.append(out)
 (W/'render_gold.hex').write_text(''.join(f'{v:04x}\n' for v in gold),encoding='ascii')
 (W/'night_gain.hex').write_bytes((P/'rtl/night_gain.hex').read_bytes())

mods={
 'serial':['camera_eis_serial_r22'],
 'readout':['camera_capture_eis_r22','video_async_fifo'],
 'rs_retry':['camera_eis_remap_r22','eis_quad_cache','dynamic_map','dynamic_mul32','dynamic_divide','camera_night_pixel_r19','camera_strength_blend_r19'],
 'jobs':['camera_eis_jobs_r22'],
 'capture':['camera_capture_eis_r22','video_async_fifo'],
 'manager':['camera_eis_manager_r22'],
 'snapshot_eis':['camera_snapshot_eis_r22','camera_night_pixel_r19','camera_strength_blend_r19'],
 'render':['camera_eis_remap_r22','eis_quad_cache','dynamic_map','dynamic_mul32','dynamic_divide','camera_night_pixel_r19','camera_strength_blend_r19'],
 'cpu':['image_cpu_r22','picorv32','simpleuart_r22','uart_tx_buffered']}
results={}
if sys.argv[1:] and (P/'reports/r22_eis_finite.json').exists():
 old=json.loads((P/'reports/r22_eis_finite.json').read_text(encoding='utf-8'))
 for name,case in old.get('cases',{}).items():
  if all((P/f).is_file() and hashlib.sha256((P/f).read_bytes()).hexdigest()==h for f,h in case['files'].items()):results[name]=case

def cpu_image():
 config=json.loads((P/'scripts/local_tools.json').read_text(encoding='utf-8-sig'));G=Path(config['riscv_bin'])
 args=[str(G/'riscv-none-embed-gcc.exe'),'-march=rv32imc','-mabi=ilp32','-Os','-ffreestanding','-fno-builtin','-msmall-data-limit=0','-ffunction-sections','-fdata-sections','-nostdlib','-nostartfiles','-Wl,--gc-sections','-T',str(P/'firmware/sections_r22.lds'),str(P/'firmware/start_r22.S'),'-I',str(P/'firmware'),str(P/'sim/r22_eis/cpu_selftest.c'),'-lgcc','-o',str(W/'cpu.elf')]
 subprocess.run(args,env=E,cwd=W,check=True)
 subprocess.run([str(G/'riscv-none-embed-objcopy.exe'),'-O','binary',str(W/'cpu.elf'),str(W/'cpu.bin')],env=E,cwd=W,check=True)
 data=(W/'cpu.bin').read_bytes();assert len(data)<=0xe000
 image=bytearray(65536);image[8192:8192+len(data)]=data
 (W/'cpu.hex').write_text(''.join(f'{int.from_bytes(image[i:i+4],"little"):08x}\n' for i in range(0,65536,4)),encoding='ascii')

def run(case):
 if case=='cpu':cpu_image()
 files=[P/'sim/r22_eis'/('tb_'+case+'.v')]+[P/'rtl'/(n+'.v') for n in mods[case]]
 if case=='cpu':files += [P/'sim/r22_eis/cpu_selftest.c',P/'night/firmware/camera_r22_main.c',P/'night/firmware/camera_r22_tuning.h',P/'night/firmware/snapshot_service_r22.h',*list((P/'night/firmware/eis').glob('*.h'))]
 hdl=[f for f in files if f.suffix=='.v']
 cmd=[str(T/'iverilog.exe'),'-g2012','-s','tb_'+case,'-o',str(W/(case+'.vvp')),*map(str,hdl)]
 r=subprocess.run(cmd,cwd=W,env=E,capture_output=True,text=True)
 (W/(case+'_compile.log')).write_text(r.stdout+r.stderr,encoding='utf-8');assert r.returncode==0,r.stderr
 with(W/(case+'.log')).open('w',encoding='utf-8') as log:
  r=subprocess.run([str(T/'vvp.exe'),str(W/(case+'.vvp'))],cwd=W,env=E,stdout=log,stderr=subprocess.STDOUT,timeout=240)
 log=(W/(case+'.log')).read_text();print(log,flush=True)
 assert r.returncode==0 and 'PASS R22' in log and 'ERROR:' not in log,case
 results[case]={'pass':True,'log':log,'files':{str(f.relative_to(P)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}}

if __name__=='__main__':
 vectors()
 cases=sys.argv[1:] or list(mods)
 for case in cases:run(case)
 (P/'reports/r22_eis_finite.json').write_text(json.dumps({'pass':True,'cases':results,'physical_acceptance':'PENDING','scope':'Finite RTL checks, 128x96 renderer only; CPU external MMIO zero-wait, FPGA IP not synthesized.'},indent=2),encoding='utf-8')
