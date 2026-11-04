from pathlib import Path
import sys,unittest,json,hashlib
P=Path(__file__).resolve().parents[2];sys.path.insert(0,str(P/'host/camera_console'))
suite=unittest.defaultTestLoader.discover(str(P/'host/camera_console'),pattern='test_*.py')
r=unittest.TextTestRunner(verbosity=1).run(suite)
files=list((P/'host/camera_console').glob('*.py'))
(P/'reports/r22_host_validation.json').write_text(json.dumps({'pass':r.wasSuccessful(),'tests':r.testsRun,'failures':len(r.failures),'errors':len(r.errors),'real_board_test':False,'source_sha256':{f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in files}},indent=2),encoding='utf-8')
sys.exit(0 if r.wasSuccessful() else 1)
