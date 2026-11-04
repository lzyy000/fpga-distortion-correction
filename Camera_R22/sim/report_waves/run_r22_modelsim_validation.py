from pathlib import Path
import subprocess,os,json,hashlib,time

HERE=Path(__file__).resolve().parent
VSIM=Path(r'D:\Quartus\modelsim_ase\win32aloem\vsim.exe')
m=json.loads((HERE/'r22_inputs.json').read_text(encoding='utf-8'))
results={}
for case in ['render','cache32','manager']:
    out=HERE/(case+'_run')
    logfile=out/f'{case}_modelsim_validation.log'
    cmd=[str(VSIM),'-c','-l',str(logfile),'-do','do {'+(HERE/f'validate_r22_{case}.do').as_posix()+'}']
    start=time.monotonic()
    with (out/'batch_console.log').open('w',encoding='utf-8') as stream:
        run=subprocess.run(cmd,cwd=out,stdout=stream,stderr=subprocess.STDOUT,timeout=90)
    text=logfile.read_text(encoding='utf-8',errors='replace') if logfile.exists() else ''
    print(case,'exit',run.returncode,flush=True)
    print('\n'.join(line for line in text.splitlines() if 'PASS R22' in line or '** Error' in line or '** Fatal' in line or 'Errors:' in line or 'R22 RENDER' in line),flush=True)
    assert run.returncode==0 and 'PASS R22' in text and '** Error' not in text and '** Fatal' not in text and 'Error:' not in text,(case,text[-6000:])
    vcd=out/f'{case}_validation.vcd'
    assert vcd.stat().st_size>100
    results[case]={'pass':True,'elapsed_s':round(time.monotonic()-start,3),'log':str(logfile),'vcd':str(vcd),'vcd_bytes':vcd.stat().st_size,'vcd_sha256':hashlib.sha256(vcd.read_bytes()).hexdigest(),'scope':m['cases'][case]['scope']}
assert all(hashlib.sha256(Path(f).read_bytes()).hexdigest()==h for f,h in m['source_sha256'].items())
(HERE/'r22_modelsim_verification.json').write_text(json.dumps({'date':'2026-11-03','simulator':'ModelSim Intel FPGA Starter Edition 10.5b','project':m['project'],'cases':results,'inputs_unchanged':True,'gui_user_confirmation':'pending','board_access':False,'pds_build':False},ensure_ascii=False,indent=2),encoding='utf-8')
print('PASS all three R22 ModelSim finite unit tests; source inputs unchanged',flush=True)
