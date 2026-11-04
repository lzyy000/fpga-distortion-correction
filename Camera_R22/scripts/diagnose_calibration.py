"""Inspect actual view coverage and compare model sensitivity on saved corners."""
from pathlib import Path
import json,sys
import cv2,numpy as np
from PIL import Image,ImageDraw
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'host/camera_console'))
from checkerboard import object_points,SIZE
directory=Path(sys.argv[1]);candidate=json.loads((directory/'calibration_candidate.json').read_text(encoding='utf-8'))
reports=[json.loads(Path(v['file']).with_suffix('.quality.json').read_text(encoding='utf-8')) for v in candidate['views']]
corners=[np.array(r['corners'],np.float32).reshape(-1,1,2) for r in reports]
objects=object_points();allpoints=np.concatenate(corners).reshape(-1,2)
baseK=np.array(candidate['K']);baseD=np.array(candidate['D'])
rows=[];sheet=Image.new('RGB',(1920,960),'white');draw=ImageDraw.Draw(sheet)
for i,(report,view) in enumerate(zip(reports,candidate['views'])):
    pts=corners[i].reshape(-1,2)
    ok,rv,tv=cv2.solvePnP(objects,corners[i],baseK,baseD);assert ok
    normal=cv2.Rodrigues(rv)[0][:,2]
    if normal[2]<0:normal=-normal
    rows.append({'index':i+1,'photo':Path(view['file']).name,'center_px':pts.mean(axis=0).tolist(),
        'bounds_px':[pts.min(axis=0).tolist(),pts.max(axis=0).tolist()],
        'rms_pixels':view['rms_pixels'],'held_out_rms_pixels':candidate['stability']['trials'][i]['held_out_rms_pixels'],
        'map_change_pixels':candidate['stability']['trials'][i]['max_mapping_change_pixels'],
        'tilt_x_degrees':float(np.degrees(np.arctan2(normal[0],normal[2]))),
        'tilt_y_degrees':float(np.degrees(np.arctan2(normal[1],normal[2])))})
    original=Image.open(view['file']).convert('RGB');original.thumbnail((480,270))
    x=(i%4)*480;y=(i//4)*320;sheet.paste(original,(x,y))
    for px,py in pts:
        draw.ellipse((x+px/4-1,y+py/4-1,x+px/4+1,y+py/4+1),fill='cyan')
    draw.text((x+8,y+276),f'{i+1}: {Path(view["file"]).name}\nRMS {view["rms_pixels"]:.3f}px; LOO {rows[-1]["held_out_rms_pixels"]:.3f}px',fill='black')
sheet.save(root/'reports/calibration_view_contact_sheet.png')
coverage={'centers_3x3_cells':candidate['coverage_cells'],
    'corner_bounds_px':[allpoints.min(axis=0).tolist(),allpoints.max(axis=0).tolist()],
    'corner_hull_area_fraction':float(cv2.contourArea(cv2.convexHull(allpoints.astype(np.float32)))/(1920*1080))}
models=[]
for name,flags in [('five_coefficients',0),('k3_fixed_zero',cv2.CALIB_FIX_K3),
                   ('radial_only_k1_k2',cv2.CALIB_FIX_K3|cv2.CALIB_ZERO_TANGENT_DIST)]:
    rms,K,D,_,_=cv2.calibrateCamera([objects]*len(corners),corners,SIZE,None,None,flags=flags,
        criteria=(cv2.TERM_CRITERIA_EPS|cv2.TERM_CRITERIA_MAX_ITER,100,1e-9))
    rays=(np.linalg.inv(K)@np.array([(x,y,1) for y in (0,539.5,1079) for x in (0,959.5,1919)]).T).T
    mapping=cv2.projectPoints(rays,np.zeros(3),np.zeros(3),K,D)[0].reshape(-1,2)
    observed_rays=(np.linalg.inv(K)@np.column_stack([allpoints,np.ones(len(allpoints))]).T).T
    observed_map=cv2.projectPoints(observed_rays,np.zeros(3),np.zeros(3),K,D)[0].reshape(-1,2)
    max_boundary=0;max_observed=0
    for i in range(len(corners)):
        subset=[c for j,c in enumerate(corners) if i!=j]
        _,subK,subD,_,_=cv2.calibrateCamera([objects]*len(subset),subset,SIZE,None,None,flags=flags,
            criteria=(cv2.TERM_CRITERIA_EPS|cv2.TERM_CRITERIA_MAX_ITER,100,1e-9))
        submap=cv2.projectPoints(rays,np.zeros(3),np.zeros(3),subK,subD)[0].reshape(-1,2)
        sub_observed=cv2.projectPoints(observed_rays,np.zeros(3),np.zeros(3),subK,subD)[0].reshape(-1,2)
        max_boundary=max(max_boundary,float(np.linalg.norm(submap-mapping,axis=1).max()))
        max_observed=max(max_observed,float(np.linalg.norm(sub_observed-observed_map,axis=1).max()))
    models.append({'model':name,'rms_pixels':float(rms),'K':K.tolist(),'D':D.ravel().tolist(),
        'max_boundary_map_change_pixels':max_boundary,'max_map_change_at_observed_grid_pixels':max_observed})
    print(json.dumps(models[-1],ensure_ascii=False),flush=True)
result={'coverage':coverage,'views':rows,'models':models,'scope':'Diagnostic comparison only; no candidate or FPGA parameters overwritten.'}
(root/'reports/calibration_diagnosis.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'coverage':coverage,'views':rows},ensure_ascii=False,indent=2),flush=True)
