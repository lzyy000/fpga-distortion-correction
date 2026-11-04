"""Elaborate reachable user RTL; enumerate expected PDS IP/vendor black boxes."""
from pathlib import Path
import re,json,subprocess,os,hashlib
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from local_tools import iverilog_root
P=Path(__file__).resolve().parents[1];I=P/'pnr_camera_r21_modes';W=P/'work/r22_eis';T=iverilog_root()/'bin/iverilog.exe'
files=[]
for name in re.findall(r'_file "([^"\n]+)"',(I/'camera_1080p30_raw8.pds').read_text(encoding='utf-8-sig')):
 f=(I/name).resolve()
 # Legacy unused module redeclares an ANSI output: PDS accepts the original;
 # Icarus rejects it even when uninstantiated. It is not on the active hierarchy.
 if f.suffix=='.v' and f.name!='video_ms72xx_ctl.v':files.append(f)
env=dict(os.environ,TEMP=str(W),TMP=str(W),PYTHONDONTWRITEBYTECODE='1')
cmd=[str(T),'-g2012','-I',str(P/'rtl'),'-I',str(P/'baseline_r13_snapshot/reuse/ethernet/source'),'-s','camera_1080p_top','-o',str(W/'top.vvp'),*map(str,files)]
r=subprocess.run(cmd,cwd=I,env=env,capture_output=True,text=True);unknown=set(re.findall(r'Unknown module type: (\w+)',r.stderr))
ips={'cfg_pll','ddr3_test','ref_clock','udp_shift_register','icmp_rx_ram_8_256','rd_fram_buf'}
assert not {n for n in unknown if not n.startswith('GTP_') and n not in ips},r.stderr
r=subprocess.run(cmd[:2]+['-i']+cmd[2:],cwd=I,env=env,capture_output=True,text=True)
(W/'top_elaboration.log').write_text(r.stdout+r.stderr,encoding='utf-8');assert r.returncode==0,r.stderr
report={'pass':True,'synthesis':False,'expected_vendor_primitives':sorted(n for n in unknown if n.startswith('GTP_')),'expected_pds_ip_blackboxes':sorted(unknown&ips),'unused_legacy_file_excluded_from_icarus_only':'rtl/video_ms72xx_ctl.v','source_sha256':{f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in files}}
(P/'reports/r22_hierarchy_check.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print('PASS R22 reachable user RTL elaboration; no missing EIS module. PDS IP/vendor primitives enumerated, not synthesized.')
