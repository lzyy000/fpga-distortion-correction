from pathlib import Path
import datetime
import hashlib
import json
import os
import secrets

import numpy as np
from PIL import Image

def rgb565_image(pixels, width, height):
    values = np.frombuffer(pixels, dtype='<u2').reshape(height,width).astype(np.uint32)
    rgb = np.stack((((values>>11)&31)*255//31, ((values>>5)&63)*255//63, (values&31)*255//31),axis=-1).astype(np.uint8)
    return Image.fromarray(rgb)

def save_snapshot(result, directory, connection):
    pixels = result['pixels']
    if len(pixels) != result['width']*result['height']*2:
        raise ValueError('完整图像长度不匹配')
    image = rgb565_image(pixels,result['width'],result['height'])
    directory = Path(directory)
    directory.mkdir(parents=True,exist_ok=True)
    stamp = datetime.datetime.now().astimezone()
    stem = 'camera_'+stamp.strftime('%Y%m%d_%H%M%S_%f')+f"_f{result['frame_id']}"
    png = directory/(stem+'.png')
    metadata_path = directory/(stem+'.json')
    temporary = directory/(stem+'.'+secrets.token_hex(4)+'.part')
    temporary_meta = temporary.with_suffix('.json.part')
    metadata = {k:v for k,v in result.items() if k!='pixels'}
    metadata.update(captured_at=stamp.isoformat(),png=str(png),connection=connection,
                    source='FPGA Ethernet snapshot',pixel_sha256=hashlib.sha256(pixels).hexdigest(),
                    checkerboard={'squares':[10,7],'inner_corners':[9,6],'square_size_mm':25},
                    distortion_calibration_performed=bool(result.get('lens_applied_to_eis') or result.get('lens_applied_to_rotation') or result.get('fisheye_applied')))
    png_committed = False
    try:
        image.save(temporary,format='PNG')
        metadata['png_sha256'] = hashlib.sha256(temporary.read_bytes()).hexdigest()
        temporary_meta.write_text(json.dumps(metadata,ensure_ascii=False,indent=2),encoding='utf-8')
        os.replace(temporary,png)
        png_committed = True
        os.replace(temporary_meta,metadata_path)
    except Exception:
        if png_committed:
            png.unlink(missing_ok=True)
        raise
    finally:
        temporary.unlink(missing_ok=True)
        temporary_meta.unlink(missing_ok=True)
    return image,png,metadata
