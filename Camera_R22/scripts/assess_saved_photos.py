"""Assess existing camera snapshots without changing their image pixels."""
from pathlib import Path
import datetime, json, sys

root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'host/camera_console'))
from checkerboard import assess_file

directory=Path(sys.argv[1]).resolve()
reports=[]
for photo in sorted(directory.glob('*.png')):
    report,_=assess_file(photo)
    reports.append(report)
    print(photo.name,report['status'],f"{report['corner_count']}/54",
          ' '.join(report['advice']+report['warnings']),flush=True)
summary={'assessed_at':datetime.datetime.now().astimezone().isoformat(),
         'directory':str(directory),'photo_count':len(reports),
         'usable_before_pose_deduplication':sum(bool(r['usable_for_calibration']) for r in reports),
         'photos':reports}
output=root/'reports/existing_checkerboard_photos.json'
output.write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
print('REPORT',output,flush=True)
