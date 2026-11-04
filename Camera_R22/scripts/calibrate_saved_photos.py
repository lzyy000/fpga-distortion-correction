"""Run the same quality and stability checks as the console's calibration button."""
from pathlib import Path
import json,sys
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'host/camera_console'))
from checkerboard import calibrate_directory
result,path=calibrate_directory(sys.argv[1])
print(json.dumps({'output':str(path),'views':len(result['views']),'rms_pixels':result['rms_pixels'],
    'status':result['status'],'warnings':result['warnings'],'excluded':result['excluded'],
    'max_mapping_change_pixels':result['stability']['max_mapping_change_pixels']},ensure_ascii=False,indent=2))
