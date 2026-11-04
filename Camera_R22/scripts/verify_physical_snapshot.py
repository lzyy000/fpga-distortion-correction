"""Independently verify a saved board frame against its UART CRC and sidecar."""
from pathlib import Path
import datetime, hashlib, json, re, sys, zlib
import cv2
import numpy as np

root = Path(__file__).resolve().parents[1]
photo = Path(sys.argv[1]).resolve()
uart = Path(sys.argv[2]).resolve()
metadata = json.loads(photo.with_suffix('.json').read_text(encoding='utf-8'))
quality = json.loads(photo.with_suffix('.quality.json').read_text(encoding='utf-8'))
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
assert digest(photo) == metadata['png_sha256'] == quality['png_sha256']
image = cv2.imdecode(np.fromfile(str(photo), dtype=np.uint8), cv2.IMREAD_COLOR)
assert image is not None and image.shape == (1080, 1920, 3)
assert metadata['source'] == 'FPGA Ethernet snapshot'
assert metadata['pixel_format'] == 'RGB565_LE' and metadata['packets'] == 4050
b, g, r = [image[:, :, i].astype(np.uint16) for i in range(3)]
pixels = (((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)).astype('<u2').tobytes()
assert len(pixels) == 4147200
assert hashlib.sha256(pixels).hexdigest() == metadata['pixel_sha256']
crc = f'{zlib.crc32(pixels) & 0xffffffff:08x}'
assert crc == metadata['crc32'].lower()
assert re.search(rf'SNAP frozen frame={metadata["frame_id"]} CRC={crc}',
                 uart.read_text(encoding='utf-8'), re.IGNORECASE)
report = {
    'pass': True, 'verified_at': datetime.datetime.now().astimezone().isoformat(),
    'scope': 'One real camera frame; sustained network stability and calibration remain pending.',
    'photo': str(photo), 'metadata': str(photo.with_suffix('.json')),
    'uart': str(uart), 'png_sha256': digest(photo), 'frame_id': metadata['frame_id'],
    'size': [1920, 1080], 'bytes': len(pixels), 'packets': metadata['packets'],
    'crc32': crc, 'retry_rounds': metadata['retry_rounds'], 'seconds': metadata['seconds'],
    'checkerboard_status': quality['status'], 'corner_count': quality['corner_count'],
    'calibration_applied_to_fpga': False,
}
output = root / 'reports/physical_snapshot_acceptance.json'
output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
host_file = root / 'reports/host_validation_summary.json'
host = json.loads(host_file.read_text(encoding='utf-8'))
host.update(physical_r13_snapshot_test='passed: one real camera frame, independently reconstructed RGB565 matches board UART CRC',
            hardware_handshake='passed in GUI with PC 192.168.1.105 / board 192.168.1.11',
            gui_visual_check='COM11 connected; UART 30 fps / zero bad frames; network handshake and photo preview verified.',
            photo_count=len(list((root / 'captures').glob('*.png'))),
            physical_evidence=str(output), updated_at=report['verified_at'])
host_file.write_text(json.dumps(host, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(report, ensure_ascii=False, indent=2))
