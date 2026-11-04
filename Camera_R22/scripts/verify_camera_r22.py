"""Current R22 input/ROM checks and explicit user-build evidence; no build startup."""
from pathlib import Path
import argparse,datetime,hashlib,json,re,sys
import verify_camera_r21_modes as base
from check_r22_static_cache import check as check_static_cache
P=Path(__file__).resolve().parents[1];I=P/'pnr_camera_r21_modes'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def sources():
 result=base.sources()
 extra=[P/'night/firmware/camera_r22_main.c',P/'night/firmware/camera_r22_tuning.h',P/'night/firmware/snapshot_service_r22.h',*list((P/'night/firmware/eis').glob('*.h'))]
 extra+=list((P/'host/camera_console').glob('*.py'))
 extra += [P/'sim/fisheye/run_validation.py',P/'sim/fisheye/cpu_fisheye.c',P/'scripts/test_fisheye.ps1',P/'docs/鱼眼畸变处理.md']
 extra += [P/'rtl/camera_fisheye_scale.hex',P/'rtl/camera_fisheye_scale.vh',I/'camera_fisheye_scale.hex',P/'scripts/export_fisheye_profile.py',P/'firmware/camera_fisheye_calibration.json',P/'calibration/fisheye_local_pc_20261030/fisheye_calibration.json']
 extra += [P/'night/firmware/eis/rotation_control.h',P/'sim/rotation/run_validation.py',P/'sim/rotation/cpu_rotation.c',P/'sim/rotation/tb_rotation_cpu.v',P/'scripts/test_rotation.ps1',P/'docs/旋转稳像集成.md']
 extra += [P/'host/preflight.py',P/'host/measure_camera_r21.py',P/'sim/local_tools.py',P/'scripts/check_r22_static_cache.py',P/'sim/r22_eis/test_static_cache32.py',P/'sim/r22_eis/tb_static_cache32.v',P/'sim/r22_eis/tb_static_map_row.v']
 extra+=[P/'scripts/build_camera_r22_firmware.ps1',P/'scripts/build_camera_r22.ps1',P/'scripts/verify_camera_r22.py',P/'scripts/check_r22_hierarchy.py',P/'scripts/test_camera_r22.ps1']
 # This delivered package uses 00-06 launchers, rather than the old development
 # tree's 27-31 launchers/AGENTS.md. Keep freezing all actual package entry points.
 extra += [P/name for name in ('README.md','docs/R22_防抖迁移与接线.md',
  'scripts/open_camera_r21.ps1','scripts/build_camera_r21_firmware.ps1','scripts/build_camera_r21_modes.ps1',
  'scripts/test_camera_r21_modes.ps1','scripts/verify_release.ps1','scripts/local_tool_paths.ps1',
  'scripts/local_tools.json','scripts/start_camera_console.ps1','scripts/run_python.ps1',
  'scripts/configure_package.ps1','00_本机预检.cmd','00_配置解压路径.cmd',
  '01_打开工程.cmd','02_重新编译.cmd','03_串口测帧率.cmd','04_离线验证.cmd',
  '05_核对发布.cmd','06_相机上位机.cmd')]
 for path in extra:result[path.relative_to(P).as_posix()]=sha(path)
 assert 'rtl/camera_calibration.vh' in result
 assert 'baseline_r13_snapshot/reuse/ethernet/source/check_sum.vh' in result
 return dict(sorted(result.items()))
def check():
 assert (P/'rtl/camera_fisheye_scale.hex').read_bytes()==(I/'camera_fisheye_scale.hex').read_bytes(),'Fisheye ROM copies differ'
 bounds=check_static_cache();current=sources();image=(P/'firmware/camera_r22_build/firmware.bin').read_bytes()
 rom=b''.join(int(v,16).to_bytes(4,'little') for v in (I/'firmware_camera.hex').read_text().split())
 expected=bytearray(65536);expected[8192:8192+len(image)]=image
 assert len(image)<=0xe000 and rom==expected and b'DVP R22 HOST MODES' in image,'R22 firmware ROM mismatch'
 assert b'AXIS_RS_R30' not in image or b'R22' in image
 assert b'fisheye_supported=1' in image and b'fisheye_correction' in image,'Current ROM lacks the new fisheye control/protocol'
 assert b'rotation_supported=1' in image and b'snapshot_rotation' in image,'Current ROM lacks independent rotation support'
 fdc=(I/'camera_1080p_top.fdc').read_text(encoding='utf-8-sig')
 assert re.search(r'p:imu_rx[^\n]+PAP_IO_LOC[^\n]+U22',fdc),'IMU pin not connected'
 locs=re.findall(r'define_attribute\s+\{p:([^}]+)\}\s+\{?PAP_IO_LOC\}?\s+\{?([A-Z]+\d+)\}?',fdc)
 assert [port for port,pin in locs if pin=='U22']==['imu_rx'],'U22 pin collision'
 top=(P/'rtl/camera_1080p_top_r21.v').read_text()
 for name in ('image_cpu_r22','camera_eis_serial_r22','camera_eis_jobs_r22','camera_eis_manager_r22','camera_eis_remap_r22','camera_snapshot_eis_r22'):
  assert name in top and any(name in n for n in current),name
 data=(P/'firmware/camera_r22_build/firmware.map').read_text(encoding='ascii',errors='replace')
 end=re.search(r'0x([0-9a-f]+)\s+_ebss\s*=',data);assert end and int(end[1],16)<=0x1800,'data/stack overlap'
 return current,{'pass':True,'inputs':len(current),'static_cache_rows':bounds['cache_rows'],'max_calibrated_source_rows':bounds['max_source_rows'],'firmware_bytes':len(image),'rom_words':len(rom)//4,'data_bss_end':int(end[1],16),'stack_reserved_bytes':2048,'imu_pin':'U22 / ATK J1-7 / LA18_P_CC','physical_acceptance':'PENDING','synthesis':'NOT RUN BY AGENT','source_sha256':current}
def main():
 p=argparse.ArgumentParser();p.add_argument('--prepare',action='store_true');p.add_argument('--check-build',action='store_true');p.add_argument('--check-inputs',action='store_true');a=p.parse_args()
 current,result=check();result['time']=datetime.datetime.now().astimezone().isoformat()
 frozen=P/'reports/r22_build_inputs.json'
 if a.prepare:frozen.write_text(json.dumps({'time':result['time'],'files':current},indent=2),encoding='utf-8')
 if a.check_build:
  before=json.loads(frozen.read_text());assert current==before['files'],'inputs changed during build'
  start=datetime.datetime.fromisoformat(before['time']).timestamp()
  bit=I/'generate_bitstream/camera_1080p_top.sbit';timing=I/'report_timing/camera_1080p_top.rtr'
  assert bit.is_file() and timing.is_file() and bit.stat().st_mtime>=start and timing.stat().st_mtime>=start,'bitstream/timing is stale'
  assert 'Design Summary : All Constraints Met.' in timing.read_text(errors='replace'),'new R22 timing not closed'
  result.update(bitstream=str(bit),bitstream_sha256=sha(bit),final_timing_pass=True,timing_sha256=sha(timing),built_from_current_inputs=True)
  (P/'reports/r22_build_result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
 else:
  result['existing_bitstream_is_r22_verified']=False
  (P/'reports/r22_source_check.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
 print(f"PASS R22 inputs={len(current)}, firmware={result['firmware_bytes']} bytes, ROM={result['rom_words']} words, data/BSS={result['data_bss_end']} bytes")
 print('PDS:',I/'camera_1080p30_raw8.pds')
 print('R22 build evidence verified; physical pending' if a.check_build else 'SOURCE ONLY: existing bitstream/timing do not verify current R22+fisheye+rotation sources. User rebuild required.')
if __name__=='__main__':main()
