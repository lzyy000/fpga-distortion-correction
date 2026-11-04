"""Finite fisheye coordinate/renderer/ownership/snapshot/CPU tests, no FPGA build."""
from pathlib import Path
import json,os,sys,math,hashlib,subprocess,importlib.util
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from local_tools import iverilog_root
P=Path(__file__).resolve().parents[2];W=P/'work/fisheye_integration';W.mkdir(parents=True,exist_ok=True)
sys.dont_write_bytecode=True;sys.path.insert(0,str(P/'tools/python_packages'))
import cv2,numpy as np
E=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',TEMP=str(W),TMP=str(W));T=(iverilog_root()/'bin')
cal=json.loads((P/'calibration/fisheye_local_pc_20261030/fisheye_calibration.json').read_text(encoding='utf-8'))
K=np.array(cal['K']);D=np.array(cal['D']);N=np.array(cal['K_prime']);ROM=[int(v,16) for v in (P/'rtl/camera_fisheye_scale.hex').read_text().split()]
r=math.sqrt(8);theta=math.atan(r);t2=theta*theta;ROM.append(round(theta/r*(1+D[0]*t2+D[1]*t2*t2+D[2]*t2**3+D[3]*t2**4)*(1<<20)))
(W/'camera_fisheye_scale.hex').write_bytes((P/'rtl/camera_fisheye_scale.hex').read_bytes());(W/'night_gain.hex').write_bytes((P/'rtl/night_gain.hex').read_bytes())
results={}
def s(x):return ((x+(1<<31))%(1<<32))-(1<<31)
def div(a,b):return -(abs(a)//b) if a<0 else a//b
def scale(r2):
 if r2>=8*(1<<20):return ROM[-1]
 i=r2>>13;return ROM[i]+((ROM[i+1]-ROM[i])*(r2&8191)+4096>>13)
def lens(c,x,y):
 xx=s(x*x>>20);yy=s(y*y>>20);xy=s(x*y>>20);r2=s(xx+yy)
 if c[17]==0x46495348:
  radial=scale(r2);xd=s(x*radial>>20);yd=s(y*radial>>20)
 else:
  r4=s(r2*r2>>20);r6=s(r4*r2>>20);radial=s((1<<20)+(c[13]*r2>>20)+(c[14]*r4>>20)+(c[17]*r6>>20))
  tx=s((c[15]*s(xy*2)>>20)+(c[16]*s(r2+2*xx)>>20));ty=s((c[16]*s(xy*2)>>20)+(c[15]*s(r2+2*yy)>>20))
  xd=s((x*radial>>20)+tx);yd=s((y*radial>>20)+ty)
 return (xd*c[9]>>20)+c[11],(yd*c[10]>>20)+c[12]
def mapping(c,u,v,H=1080):
 den=c[6]*u+c[7]*v+c[8];x=div((c[0]*u+c[1]*v+c[2])<<20,den);y=div((c[3]*u+c[4]*v+c[5])<<20,den)
 px,py=lens(c,x,y);flags=c[-1]&0xffffffff;sl=s(flags)>>8
 if flags&4 and 0<abs(sl)<=65536 and 0<=px<((128 if H==96 else 1920)-1)*256 and 0<=py<(H-1)*256:
  a=sl*(py-(H-1)*128)>>18;den=((1<<20)+(a*x>>20))<<4;x,y=div(((x-a)<<4)<<20,den),div((y<<4)<<20,den);px,py=lens(c,x,y)
 return px,py

def run(name,tb,mods,top=None):
 top=top or 'tb_'+name;file=W/(name+'_tb.v');file.write_text(tb,encoding='ascii')
 files=[P/'rtl'/(m+'.v') for m in mods]
 cmd=[str(T/'iverilog.exe'),'-g2012','-I',str(P/'rtl'),'-s',top,'-o',str(W/(name+'.vvp')),str(file),*map(str,files)]
 a=subprocess.run(cmd,env=E,cwd=W,capture_output=True,text=True);(W/(name+'_compile.log')).write_text(a.stdout+a.stderr,encoding='utf-8');assert a.returncode==0,a.stderr
 a=subprocess.run([str(T/'vvp.exe'),str(W/(name+'.vvp'))],env=E,cwd=W,capture_output=True,text=True,timeout=180);(W/(name+'.log')).write_text(a.stdout+a.stderr,encoding='utf-8');print(a.stdout,flush=True);assert a.returncode==0 and 'PASS' in a.stdout and 'ERROR:' not in a.stdout,a.stderr
 results[name]={'pass':True,'log':a.stdout}

def coordinate_test():
 hom=np.linalg.inv(N);h=hom*8
 configs=[]
 for h0 in [h,np.array([[1,0,.015],[0,1,-.01],[0,0,1]])@h]:
  configs.append([int(v*(1<<24)) for v in h0.ravel()]+[int(K[0,0]*256),int(K[1,1]*256),int(K[0,2]*256),int(K[1,2]*256)]+[int(v*(1<<20)) for v in D]+[0x46495348,0])
 old=json.loads((P/'firmware/camera_calibration.json').read_text(encoding='utf-8'));bk=np.array(old['K']);bh=np.linalg.inv(bk)*8
 configs.append([int(v*(1<<24)) for v in bh.ravel()]+[int(bk[0,0]*256),int(bk[1,1]*256),int(bk[0,2]*256),int(bk[1,2]*256)]+[int(v*(1<<20)) for v in old['D']]+[0])
 points=[(x,y) for y in range(0,1089,64) for x in range(0,1921,64)]+[(1919,1079),(0,0),(667,380)]
 rng=np.random.default_rng(22);points += [tuple(map(int,q)) for q in rng.integers([0,0],[1920,1080],size=(128,2))]
 (W/'coordinate_cfg.hex').write_text(''.join(f'{v&0xffffffff:08x}\n' for c in configs for v in c))
 (W/'coordinate_points.hex').write_text(''.join(f'{(u<<12)|v:06x}\n' for u,v in points))
 n=len(points);tb=r"""`timescale 1ns/1ps
module tb_coordinate;
reg clk=0;always #4 clk=~clk;reg rst=0,start=0;reg [11:0] u=0,v=0;reg [607:0] cfg=0;wire done,bound,ray;wire signed [31:0] x,y;
reg [31:0] words[0:56];reg [23:0] p[0:POINTS-1];integer i,j,k,fd;
dynamic_map #(.FISHEYE_ENABLE(1)) dut(clk,rst,start,u,v,cfg,done,bound,x,y,ray);
initial begin $readmemh("coordinate_cfg.hex",words);$readmemh("coordinate_points.hex",p);fd=$fopen("coordinate_out.txt","w");repeat(4)@(negedge clk);rst=1;
for(j=0;j<3;j=j+1)begin for(k=0;k<19;k=k+1)cfg[k*32+:32]=words[j*19+k];
for(i=0;i<POINTS;i=i+1)begin @(negedge clk);u=p[i][23:12];v=p[i][11:0];start=1;@(negedge clk);start=0;wait(done);@(negedge clk);if(!ray)$fatal(1,"invalid ray");$fdisplay(fd,"%0d %0d %0d %0d",j,i,x,y);end end
$fclose(fd);$display("PASS finite fish/Brown coordinates");$finish;end
initial begin #100000000;$fatal(1,"coordinate timeout");end
endmodule
""".replace('POINTS',str(n))
 run('coordinate',tb,['dynamic_map','dynamic_mul32','dynamic_divide','camera_fisheye_scale'])
 err=[];max_fixed=0
 for line in (W/'coordinate_out.txt').read_text().splitlines():
  m,i,x,y=map(int,line.split());c=configs[m];u,v=points[i];ref=mapping(c,u,v);max_fixed=max(max_fixed,abs(x-ref[0]),abs(y-ref[1]));assert (x,y)==ref,(m,i,(x,y),ref)
  if m<2:
   hv=np.array(c[:9],np.float64).reshape(3,3)@np.array([u,v,1.]);norm=(hv[:2]/hv[2]).reshape(1,1,2)
   ideal=cv2.fisheye.distortPoints(norm,K,D).reshape(2);err.append(float(np.linalg.norm(np.array([x,y])/256-ideal)))
 assert max(err)<.05,max(err)
 # Sparse numerical mesh check, not a full-HD renderer regression.
 mesh=np.array([[mapping(configs[0],x,y) for x in range(0,1921,64)] for y in range(0,1089,64)],np.float64)/256
 mesherr=[]
 for gy in range(17):
  for gx in range(30):
   for fx,fy in [(16,16),(32,32),(48,48)]:
    u=gx*64+fx;v=gy*64+fy
    if v>=1080:continue
    pred=(mesh[gy,gx]*(64-fx)*(64-fy)+mesh[gy,gx+1]*fx*(64-fy)+mesh[gy+1,gx]*(64-fx)*fy+mesh[gy+1,gx+1]*fx*fy)/4096
    hv=np.array(configs[0][:9],np.float64).reshape(3,3)@np.array([u,v,1.]);ideal=cv2.fisheye.distortPoints((hv[:2]/hv[2]).reshape(1,1,2),K,D).reshape(2)
    mesherr.append(float(np.linalg.norm(pred-ideal)))
 assert max(mesherr)<.6,max(mesherr)
 results['coordinate'].update(samples=3*n,bit_exact_fixed_reference=True,opencv_node_max_error_pixels=max(err),mesh_sample_count=len(mesherr),mesh_max_error_pixels=max(mesherr))

def renderer_test():
 spec=importlib.util.spec_from_file_location('old_validation',P/'sim/r22_eis/run_validation.py');old=importlib.util.module_from_spec(spec);spec.loader.exec_module(old)
 source=old.source;configs=[];base=[131072,0,4259840,0,131072,2129920,0,0,16777216,16384,16384,0,0]+[int(v*(1<<20)) for v in D]+[0x46495348]
 for f in range(4):
  c=base[:]
  if f==2:c[0],c[1],c[3],c[4]=0,131072,131072,0
  c+=[v*8 for v in base[:9]]+[1|4|(2000<<8) if f==3 else 0];configs.append(c)
 (W/'render_words.hex').write_text(''.join(f'{v&0xffffffff:08x}\n' for c in configs for v in c));gains=[int(v,16) for v in (P/'rtl/night_gain.hex').read_text().split()];gold=[]
 for f,c in enumerate(configs):
  nodes=[[mapping(c,x*64,y*64,96) for x in range(3)] for y in range(3)]
  for y in range(96):
   for x in range(128):
    gx,gy=x//64,y//64;fx,fy=x%64,y%64
    p=[(nodes[gy][gx][i]*(64-fy)*(64-fx)+nodes[gy][gx+1][i]*(64-fy)*fx+nodes[gy+1][gx][i]*fy*(64-fx)+nodes[gy+1][gx+1][i]*fy*fx)>>12 for i in (0,1)]
    ix,iy=p[0]>>8,p[1]>>8;ax,ay=p[0]&255,p[1]&255
    q=[source(ix,iy),source(ix+1,iy),source(ix,iy+1),source(ix+1,iy+1)];vs=[]
    for shift,mask in [(11,31),(5,63),(0,31)]:
     z=[(v>>shift)&mask for v in q];vs.append(((z[0]*(256-ax)+z[1]*ax)*(256-ay)+(z[2]*(256-ax)+z[3]*ax)*ay+32768)>>16)
    curve=2 if f==1 else 0 if f==2 else 7;strength=128 if f==1 else 256;gain=gains[curve*256+max(vs[0]*8,vs[1]*4,vs[2]*8)];out=0
    for value,shift,mask in zip(vs,[11,5,0],[31,63,31]):
     b=value if curve==7 else min(mask,(value*gain+128)//256);out|=(value+((b-value)*strength+128)//256)<<shift
    gold.append(out)
 (W/'render_gold.hex').write_text(''.join(f'{v:04x}\n' for v in gold))
 tb=(P/'sim/r22_eis/tb_render.v').read_text().replace('#(.W(W),.H(H))','#(.W(W),.H(H),.FISHEYE_ENABLE(1))')
 run('fish_render',tb,['camera_eis_remap_r22','eis_quad_cache','dynamic_map','dynamic_mul32','dynamic_divide','camera_fisheye_scale','camera_night_pixel_r19','camera_strength_blend_r19'],'tb_render')
 results['fish_render']['pixels_checked']=4*128*96

def slot_tests():
 tb=(P/'sim/r22_eis/tb_manager.v').read_text().replace('reg eis=0;','reg eis=0,fish=0;wire [3:0] ff;wire df;').replace('camera_eis_manager_r22 dut','camera_eis_manager_r22 #(.FISHEYE_ENABLE(1)) dut').replace('.eis_enable(eis),','.eis_enable(eis),.fisheye_enable(fish),.slot_fisheye(ff),.display_fisheye(df),')
 marker=' $display("PASS R22 frame scheduling:'
 assert marker in tb
 extra=''' fish=1;enable=1;ready=0;capture();pending_slot=cap_slot;
 if(!ff[pending_slot]||lf[pending_slot]||ef[pending_slot]||dut.running)$fatal(1,"fish slot identity/wait");
 fish=0;ready[pending_slot]=1;repeat(4)@(negedge clk);if(!pe||starts!=5)$fatal(1,"fish OFF cancelled leased frame");pbusy=1;finish();display_edge();display_edge();
 if(!df||de||!corrected)$fatal(1,"fish displayed as EIS or raw");
 fish=1;eis=1;ready=0;capture();pending_slot=cap_slot;fish=0;eis=0;ready[pending_slot]=1;repeat(4)@(negedge clk);pbusy=1;finish();display_edge();display_edge();
 if(!df||!de||starts!=6)$fatal(1,"combined fish/EIS identity");
'''
 tb=tb.replace(marker,extra+marker);run('fish_manager',tb,['camera_eis_manager_r22'],'tb_manager')
 tb=(P/'sim/r22_eis/tb_jobs.v').read_text().replace('camera_eis_jobs_r22 dut','camera_eis_jobs_r22 #(.FISHEYE_ENABLE(1)) dut').replace(".slot_eis(4'b1111),.slot_lens(4'b1010)",".slot_eis(4'b0101),.slot_lens(4'b0001),.slot_fisheye(4'b1010)")
 tb=tb.replace('a=8\'hb0;#1;',"a=8'hd0;#1;if(rd!=5)$fatal(1,\"captured lens metadata\");a=8'hb0;#1;")
 run('fish_jobs',tb,['camera_eis_jobs_r22'],'tb_jobs')
 tb=(P/'sim/r22_eis/tb_snapshot_eis.v').read_text().replace('#(.FRAME_BYTES(BYTES))','#(.FRAME_BYTES(BYTES),.FISHEYE_ENABLE(1))').replace(".locked_eis(1'b1),.locked_lens(1'b1)",".locked_eis(1'b0),.locked_lens(1'b0),.locked_fisheye(1'b1)").replace('if(value!=3)$fatal','if(value!=4)$fatal')
 run('fish_snapshot',tb,['camera_snapshot_eis_r22','camera_night_pixel_r19','camera_strength_blend_r19'],'tb_snapshot_eis')

def cpu_test():
 config=json.loads((P/'scripts/local_tools.json').read_text(encoding='utf-8-sig'));G=Path(config['riscv_bin'])
 src=r'''#define main camera_application_main
#include "../../night/firmware/camera_r22_main.c"
#undef main
static void command(u32 c,u32 expected){REG(0x9224)=c;tuning_service();REG(0x9228)=expected;}
int main(void){tx_async=1;
 command(103,80);command(104,16);REG(0x920c)=0;dynamic_poll();REG(0x9210)=1;
 command(103,80);command(101,112);REG(0x920c)=1;dynamic_poll();REG(0x9210)=2;
 command(127,63);REG(0x920c)=2;dynamic_poll();REG(0x9210)=3;
 command(102,31);command(103,94);command(249,78);command(54,78);command(112,64);command(104,0);
 snapshot_geometry=4;packet_header(4,1,77,0,4050,1024,123,456);REG(0x9208)=1;for(;;){} }
'''
 # Include resolves relative to this persistent source path inside sim/fisheye.
 f=P/'sim/fisheye/cpu_fisheye.c';f.write_text(src,encoding='ascii')
 cmd=[str(G/'riscv-none-embed-gcc.exe'),'-march=rv32imc','-mabi=ilp32','-Os','-ffreestanding','-fno-builtin','-msmall-data-limit=0','-ffunction-sections','-fdata-sections','-nostdlib','-nostartfiles','-Wl,--gc-sections','-T',str(P/'firmware/sections_r22.lds'),str(P/'firmware/start_r22.S'),'-I',str(P/'firmware'),str(f),'-lgcc','-o',str(W/'fish_cpu.elf')]
 subprocess.run(cmd,cwd=W,env=E,check=True);subprocess.run([str(G/'riscv-none-embed-objcopy.exe'),'-O','binary',str(W/'fish_cpu.elf'),str(W/'fish_cpu.bin')],env=E,check=True)
 b=(W/'fish_cpu.bin').read_bytes();ram=bytearray(65536);ram[8192:8192+len(b)]=b;(W/'fish_cpu.hex').write_text(''.join(f'{int.from_bytes(ram[i:i+4],"little"):08x}\n' for i in range(0,len(ram),4)))
 tb=r"""`timescale 1ns/1ps
module tb_fish_cpu;
reg clk=0;always #18.5 clk=~clk;reg [4:0] keys=30;wire rst,ev;wire [31:0] a,wd;wire [3:0] ws;reg [31:0] rd;
image_cpu_r22 #(.RESET_BITS(3),.FIRMWARE_FILE("fish_cpu.hex")) cpu(clk,keys,1'b1,,,rst,ev,a,wd,ws,1'b1,rd);
reg [31:0] modes=16,legacy=32'hffffffff,token=4;reg committed=1;integer n=0,checks=0,commits=0;reg [31:0] words[0:27];
always @*begin rd=0;case(a)
 'h8040:rd=1000;'hb0e4:rd=modes;'had30:rd=legacy;'hac08:rd=1000;'hac50:rd=1000;
 'hb0d8,'hb0dc,'hb0ec:rd=256;
 'hb2b0:rd=committed?0:token;'hb2b4:rd=1000000;
 'hb2d0:rd=n==0?2:n==1?6:5;
endcase end
always @(posedge clk)if(rst&&ev&&|ws)begin
 if(a=='hb0e4)modes=wd;if(a=='h9224)legacy=wd;if(a=='had34)legacy=32'hffffffff;
 if(a=='h9228)begin if(modes!=wd)$fatal(1,"C mode masks lost other modes got=%d expected=%d",modes,wd);checks=checks+1;end
 if(a=='h920c)begin n=wd;committed=0;token=4*(n+1);end
 if(a>='hb200&&a<'hb270)words[(a-'hb200)/4]=wd;
 if(a=='hb280)begin
  if(n<2&&words[17]!=32'h46495348)$fatal(1,"fish profile missing");
  if(n==2&&words[17]==32'h46495348)$fatal(1,"Brown profile replaced");
  if(n==0&&(words[27]!=0||words[9]<681000||words[9]>681100))$fatal(1,"fish-only depended on IMU or wrong K");
  committed=1;commits=commits+1;
 end
 if(a=='h9804&&wd!=32'h04000401)$fatal(1,"fish packet header flags");
 if(a=='h9208)begin if(checks!=11||commits!=3)$fatal(1,"missing C cases checks=%d commits=%d",checks,commits);$display("PASS actual RV32 fish-only without IMU, captured OFF job, fish+EIS, Brown restore, 11 mode ACKs, fish DATA flags");$finish;end
end
always @(posedge clk)if(rst&&cpu.cpu.trap)$fatal(1,"CPU trap");
initial begin repeat(8)@(negedge clk);keys=31;end
initial begin #1000000000;$fatal(1,"fish CPU timeout");end
endmodule
"""
 run('fish_cpu',tb,['image_cpu_r22','picorv32','simpleuart_r22','uart_tx_buffered'])

def lut_test():
 values=[-1,0,1,8191,8192,8388607,8388608,8388609]+[i*8192+f for i in range(1024) for f in (0,4095,8191)]
 expected=[(1<<20) if v<=0 else scale(v) for v in values]
 (W/'lut_inputs.hex').write_text(''.join(f'{v&0xffffffff:08x}\n' for v in values))
 (W/'lut_expected.hex').write_text(''.join(f'{v:08x}\n' for v in expected))
 tb=r'''`timescale 1ns/1ps
module tb_fish_lut;
reg clk=0;always #4 clk=~clk;reg rst=0,start=0;reg signed [31:0] r2=0;wire done;wire signed [31:0] scale;
reg [31:0] points[0:COUNT-1],gold[0:COUNT-1];integer k;
camera_fisheye_scale dut(clk,rst,start,r2,done,scale);
initial begin $readmemh("lut_inputs.hex",points);$readmemh("lut_expected.hex",gold);repeat(4)@(negedge clk);rst=1;
 for(k=0;k<COUNT;k=k+1)begin @(negedge clk);r2=points[k];start=1;@(negedge clk);start=0;wait(done);@(negedge clk);if(scale!==gold[k])$fatal(1,"radial ROM boundary/interpolation sample %0d got=%h expected=%h",k,scale,gold[k]);end
 $display("PASS single-port fisheye ROM: all intervals, interpolation, r=0, endpoint and bounds");$finish;end
initial begin #10000000;$fatal(1,"LUT timeout");end
endmodule
'''.replace('COUNT',str(len(values)))
 run('fish_lut',tb,['camera_fisheye_scale'])
 error=[]
 for v,q in zip(values,expected):
  if v<0 or v>8*(1<<20):continue
  r=math.sqrt(v/(1<<20));theta=math.atan(r);tt=theta*theta;exact=1 if r==0 else theta/r*(1+D[0]*tt+D[1]*tt**2+D[2]*tt**3+D[3]*tt**4);error.append(abs(q/(1<<20)-exact))
 assert max(error)<1e-5,max(error)
 results['fish_lut'].update(samples=len(values),max_radial_scale_error=max(error))
def top_test():
 tb=(P/'sim/r21_modes/tb_top_modes.v').read_text()
 tb=tb.replace('modes<64','modes<128').replace('model_eis=(modes>>5)&1;', 'if((modes&65)!=65)begin model_fish=(modes>>6)&1;model_eis=(modes>>5)&1;')
 tb=tb.replace("dut.mode_request!==6'(modes)","dut.mode_request!==7'(modes)")
 tb=tb.replace(' end\n $display("PASS R21 top:', ' end end\n write_csr(228,65);if(dut.mode_request!==64)$fatal(1,"both-lens write must choose fish once");\n write_csr(228,256);if(dut.mode_request!==64)$fatal(1,"upper mode bits accepted");\n $display("PASS R21 top:')
 tb=tb.replace('all 64 six-mode combinations','all 96 valid seven-mode combinations')
 # The test forces only core clocks, bus and display identities; other IP is black-boxed.
 f=W/'fish_top_tb.v';f.write_text(tb,encoding='ascii')
 files=[P/'rtl'/n for n in ['camera_1080p_top_r21.v','camera_spatial_core_r21.v','camera_spatial_stream_r21.v','camera_strength_blend_r19.v','camera_night_pixel_r19.v','camera_night_stats.v','camera_ghe_r21.v']]
 cmd=[str(T/'iverilog.exe'),'-g2012','-i','-I',str(P/'rtl'),'-I',str(P/'baseline_r13_snapshot/reuse/ethernet/source'),'-s','tb_top_modes','-o',str(W/'fish_top.vvp'),str(f),*map(str,files)]
 a=subprocess.run(cmd,env=E,cwd=P/'pnr_camera_r21_modes',capture_output=True,text=True);(W/'fish_top_compile.log').write_text(a.stdout+a.stderr);assert a.returncode==0,a.stderr
 a=subprocess.run([str(T/'vvp.exe'),str(W/'fish_top.vvp')],env=E,cwd=P/'pnr_camera_r21_modes',capture_output=True,text=True,timeout=30);print(a.stdout,flush=True);(W/'fish_top.log').write_text(a.stdout+a.stderr);assert a.returncode==0 and 'PASS' in a.stdout,a.stderr
 results['fish_top']={'pass':True,'scope':'Actual current top: 96 valid seven-bit masks, range guard, mutual exclusion, requested/applied CSR and frame boundary; unrelated IP black-boxed and display identity inputs forced.','log':a.stdout}
if __name__=='__main__':
 cases=sys.argv[1:] or ['lut','coordinate','render','slots','top','cpu']
 for case in cases:{'lut':lut_test,'coordinate':coordinate_test,'render':renderer_test,'slots':slot_tests,'top':top_test,'cpu':cpu_test}[case]()
 report=P/'reports/fisheye_validation.json'
 old=json.loads(report.read_text()) if report.exists() else {};old.update(results)
 report.write_text(json.dumps(old,ensure_ascii=False,indent=2),encoding='utf-8')
 print('PASS requested finite fisheye checks:',','.join(cases))