"""Finite integration checks; no PDS, full-HD run or hardware access."""
from pathlib import Path
import os,sys,re,json,subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from local_tools import iverilog_root
P=Path(__file__).resolve().parents[2];W=P/'work/rotation_integration';B=W/'baseline';T=(iverilog_root()/'bin')
E=dict(os.environ,TEMP=str(W),TMP=str(W),PYTHONDONTWRITEBYTECODE='1',PYTHONIOENCODING='utf-8')
G=Path(json.loads((P/'scripts/local_tools.json').read_text(encoding='utf-8-sig'))['riscv_bin']);results={}
def read(f):return f.read_text(encoding='utf-8-sig')
def run(name,tb,mods,top,black=False,cwd=None):
 cwd=cwd or W;f=W/(name+'_tb.v');f.write_text(tb,encoding='utf-8');args=[str(T/'iverilog.exe'),'-g2012','-I',str(P/'rtl'),'-I',str(P/'baseline_r13_snapshot/reuse/ethernet/source')]
 if black:args+=['-i']
 args+=['-s',top,'-o',str(W/(name+'.vvp')),str(f),*[str(P/'rtl'/(m+'.v')) for m in mods]]
 a=subprocess.run(args,cwd=cwd,env=E,capture_output=True,text=True);(W/(name+'_compile.log')).write_text(a.stdout+a.stderr);assert a.returncode==0,a.stderr
 with (W/(name+'.log')).open('w',encoding='utf-8') as out:a=subprocess.run([str(T/'vvp.exe'),str(W/(name+'.vvp'))],cwd=cwd,env=E,stdout=out,stderr=subprocess.STDOUT,timeout=480)
 log=read(W/(name+'.log'));print(log,flush=True);assert a.returncode==0 and 'PASS' in log and 'ERROR:' not in log,name
 results[name]={'pass':True,'log':log}
def image(name,source):
 f=W/(name+'.c');f.write_text(source,encoding='utf-8');args=[str(G/'riscv-none-embed-gcc.exe'),'-march=rv32imc','-mabi=ilp32','-Os','-fstack-usage','-ffreestanding','-fno-builtin','-msmall-data-limit=0','-ffunction-sections','-fdata-sections','-nostdlib','-nostartfiles','-Wl,--gc-sections','-T',str(P/'firmware/sections_r22.lds'),str(P/'firmware/start_r22.S'),'-I',str(P/'firmware'),str(f),'-lgcc','-o',str(W/(name+'.elf'))]
 a=subprocess.run(args,cwd=W,env=E,capture_output=True,text=True);assert a.returncode==0,a.stderr
 subprocess.run([str(G/'riscv-none-embed-objcopy.exe'),'-O','binary',str(W/(name+'.elf')),str(W/(name+'.bin'))],env=E,check=True)
 b=(W/(name+'.bin')).read_bytes();assert len(b)<=0xe000;ram=bytearray(65536);ram[8192:8192+len(b)]=b;(W/(name+'.hex')).write_text(''.join(f'{int.from_bytes(ram[i:i+4],"little"):08x}\n' for i in range(0,65536,4)))
CPU=['image_cpu_r22','picorv32','simpleuart_r22','uart_tx_buffered']
def legacy_cpu():
 for variant,root in [('old',B),('new',P)]:
  name=variant+'_cpu'
  if variant=='old' and (W/'old_cpu_coeff.txt').exists() and (W/'old_cpu.log').exists() and 'PASS R22' in read(W/'old_cpu.log'):
   results['old_cpu']={'pass':True,'log':read(W/'old_cpu.log'),'cached_immutable_baseline':True};continue
  src=read(B/'sim/r22_eis/cpu_selftest.c').replace('../../night/firmware/camera_r22_main.c',(root/'night/firmware/camera_r22_main.c').as_posix());image(name,src)
  tb=read(B/'sim/r22_eis/tb_cpu.v').replace('"cpu.hex"','"'+name+'.hex"')
  monitor='''integer fd,jj;reg [31:0] trace_words[0:27];
initial fd=$fopen("TRACE_FILE","w");
always @(posedge clk)if(rst&&ev&&|ws)begin
 if(a>=32'hb200&&a<32'hb270)trace_words[(a-32'hb200)/4]=wd;
 if(a==32'hb280)begin for(jj=0;jj<28;jj=jj+1)$fwrite(fd,"%08x ",trace_words[jj]);$fwrite(fd,"\\n");$fflush(fd);end
end
'''.replace('TRACE_FILE',name+'_coeff.txt')
  tb=tb.replace('endmodule',monitor+'endmodule');run(name,tb,CPU,'tb_cpu')
 assert read(W/'old_cpu_coeff.txt')==read(W/'new_cpu_coeff.txt'),'Original small-shake coefficients changed'
 results['legacy_coefficients']={'pass':True,'frames':len(read(W/'new_cpu_coeff.txt').splitlines()),'comparison':'All 28 words identical to pre-integration actual RV32 outputs.'}
def metadata():
 tb=read(P/'sim/r22_eis/tb_manager.v').replace('reg eis=0;','reg eis=0,rot=0;wire [3:0] rf;wire dr;').replace('camera_eis_manager_r22 dut','camera_eis_manager_r22 #(.ROTATION_ENABLE(1)) dut').replace('.eis_enable(eis),','.eis_enable(eis),.rotation_enable(rot),.slot_rotation(rf),.display_rotation(dr),')
 marker=' $display("PASS R22 frame scheduling:'
 extra=''' rot=1;eis=1;ready=0;capture();pending_slot=cap_slot;
 if(!rf[pending_slot]||ef[pending_slot]||dut.running)$fatal(1,"rotation did not win/await config");
 rot=0;eis=0;ready[pending_slot]=1;repeat(4)@(negedge clk);
 if(!pe||starts!=5)$fatal(1,"captured rotation lost after live OFF");
 pbusy=1;finish();display_edge();display_edge();if(!dr||de)$fatal(1,"rotation displayed as old EIS");
 capture();display_edge();display_edge();if(dr||corrected)$fatal(1,"rotation OFF failed bypass");
'''
 assert marker in tb;tb=tb.replace(marker,extra+marker);run('rotation_manager',tb,['camera_eis_manager_r22'],'tb_manager')
 tb=read(P/'sim/r22_eis/tb_jobs.v').replace('camera_eis_jobs_r22 dut','camera_eis_jobs_r22 #(.ROTATION_ENABLE(1)) dut').replace(".slot_eis(4'b1111)",".slot_eis(4'b0000),.slot_rotation(4'b1111)")
 marker=" a=8'hb0;#1;";tb=tb.replace(marker," a=8'hd0;#1;if(!rd[3]||rd[2])$fatal(1,\"rotation job identity\");\n"+marker);run('rotation_jobs',tb,['camera_eis_jobs_r22'],'tb_jobs')
 for flags,fish,lens in [(8,0,0),(10,0,1),(12,1,0)]:
  tb=read(P/'sim/r22_eis/tb_snapshot_eis.v').replace('.FRAME_BYTES(BYTES)', '.FRAME_BYTES(BYTES),.FISHEYE_ENABLE(1),.ROTATION_ENABLE(1)').replace(".locked_eis(1'b1),.locked_lens(1'b1)",f".locked_eis(1'b0),.locked_rotation(1'b1),.locked_fisheye(1'b{fish}),.locked_lens(1'b{lens})").replace('if(value!=3)$fatal','if(value!='+str(flags)+')$fatal')
  run('rotation_snapshot_'+str(flags),tb,['camera_snapshot_eis_r22','camera_night_pixel_r19','camera_strength_blend_r19'],'tb_snapshot_eis')
 tb=read(P/'sim/r21_modes/tb_top_modes.v')
 tb=tb.replace('integer modes;','integer modes,valid_modes=0;')
 tb=tb.replace('modes<64','modes<256').replace('  model_eis=(modes>>5)&1;', '  if((modes&65)!=65&&(modes&160)!=160)begin\n  valid_modes=valid_modes+1;model_rotation=(modes>>7)&1;model_fish=(modes>>6)&1;model_eis=(modes>>5)&1;').replace("dut.mode_request!==6'(modes)","dut.mode_request!==8'(modes)")
 tb=tb.replace(' end\n $display("PASS R21 top:', ' end end\n if(valid_modes!=144)$fatal(1,"missing valid modes");\n write_csr(228,160);if(dut.mode_request!=128)$fatal(1,"motion mutual exclusion missing");\n $display("PASS R21 top:')
 tb=tb.replace('all 64 six-mode combinations','all 144 valid eight-mode combinations')
 run('rotation_top',tb,['camera_1080p_top_r21','camera_spatial_core_r21','camera_spatial_stream_r21','camera_strength_blend_r19','camera_night_pixel_r19','camera_night_stats','camera_ghe_r21'],'tb_top_modes',True,P/'pnr_camera_r21_modes')
def gravity_cpu():
 src=read(P/'sim/rotation/cpu_rotation.c').replace('n<6;n++','n<0;n++').replace('config_version==7','config_version==1')
 tb=read(P/'sim/rotation/tb_rotation_cpu.v').replace('rotation_cpu.hex','gravity_cpu.hex').replace('cases!=9||commits!=7','cases!=3||commits!=1')
 image('gravity_cpu',src);run('gravity_cpu',tb,CPU,'tb_rotation_cpu')
def geometry_cpu():
 src=read(P/'sim/rotation/cpu_rotation.c').split(' /* Basis invariance:')[0]+' REG(0x9208)=1;for(;;){} }\n'
 tb=read(P/'sim/rotation/tb_rotation_cpu.v').replace('rotation_cpu.hex','geometry_cpu.hex').replace('cases!=9||commits!=7','cases!=6||commits!=6')
 image('geometry_cpu',src);run('geometry_cpu',tb,CPU,'tb_rotation_cpu')
def rotation_cpu():
 geometry_cpu();gravity_cpu()
if __name__=='__main__':
 W.mkdir(parents=True,exist_ok=True);(W/'night_gain.hex').write_bytes((P/'rtl/night_gain.hex').read_bytes())
 for case in sys.argv[1:] or ['metadata','legacy_cpu','rotation_cpu']:{'metadata':metadata,'legacy_cpu':legacy_cpu,'rotation_cpu':rotation_cpu,'geometry_cpu':geometry_cpu,'gravity_cpu':gravity_cpu}[case]()
 f=P/'reports/rotation_validation.json';d=json.loads(read(f)) if f.exists() else {};d.update(results);f.write_text(json.dumps(d,ensure_ascii=False,indent=2),encoding='utf-8')
