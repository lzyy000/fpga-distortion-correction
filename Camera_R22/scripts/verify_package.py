"""Verify the delivered immutable files; optionally include runtime settings/reports."""
from pathlib import Path
import hashlib,json,sys
P=Path(__file__).resolve().parents[1]
d=json.loads((P/'package_manifest.json').read_text(encoding='utf-8'));bad=[];mutable=[]
for n,h in d['files_sha256'].items():
 f=P/n
 changed=not f.is_file() or hashlib.sha256(f.read_bytes()).hexdigest()!=h
 if not changed:continue
 runtime=n in ('scripts/local_tools.json','host/camera_console/settings.json') or n.startswith('reports/') or (n.startswith('work/') and 'baseline' not in f.parts and not n.endswith('baseline.json'))
 if runtime and '--strict' not in sys.argv:mutable.append(n)
 else:bad.append(n)
if bad:raise SystemExit('PACKAGE_CHECK_FAILED: '+repr(bad))
print('PACKAGE_CHECK_PASS',len(d['files_sha256']),'files;',len(mutable),'runtime/config reports changed')
