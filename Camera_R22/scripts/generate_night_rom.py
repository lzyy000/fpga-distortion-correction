"""Generate bounded fixed-point Gamma gain ROM; no third-party dependencies."""
from pathlib import Path
import json,hashlib
ROOT=Path(__file__).resolve().parents[1]
GAMMAS=[0.55,0.60,0.65,0.70,0.75,0.80,0.90,1.0,1.10,1.20]
def make_rom():
 values=[]
 for curve in range(16):
  gamma=GAMMAS[curve] if curve<len(GAMMAS) else 1.0
  for v in range(256):
   gain=(v/255.0)**(gamma-1) if v else 1.0
   # Bound noise amplification and smoothly protect the near-black floor.
   if gamma<1:
    gain=min(4.0,gain)
    gain=1+(gain-1)*min(1.0,max(0.0,(v-4)/12.0))
   values.append(min(1024,max(0,int(gain*256+0.5))))
 return ''.join(f'{v:03x}\n' for v in values)
def main():
 text=make_rom()
 path=ROOT/'rtl/night_gain.hex';path.write_text(text,encoding='ascii')
 for directory in ['pnr_camera_r18_night','sim/r18_night']:
  folder=ROOT/directory;folder.mkdir(parents=True,exist_ok=True)
  (folder/'night_gain.hex').write_text(text,encoding='ascii')
 print('Gamma ROM:',hashlib.sha256(path.read_bytes()).hexdigest())
if __name__=='__main__':main()
