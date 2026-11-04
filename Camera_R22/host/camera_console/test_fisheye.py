"""Separate fisheye capability, ACKs, mutual exclusion, combination and data identity."""
import unittest,sys,zlib,tempfile,json,hashlib
from pathlib import Path
from dataclasses import replace
from tuning import StrengthControl,MODE_BITS,MODE_DEFS
from test_r22_eis import EisBoard
from test_ghe import Board
from transport import Packet,Kind,decode,encode,PacketError,FrameAssembler,SnapshotError
from storage import save_snapshot
P=Path(__file__).resolve().parents[2]
class FisheyeBoard(EisBoard):
 def ack(self,c):return super().ack(c)+f' fisheye_supported=1 fisheye_on={bool(self.modes&64):d}'
 def apply(self,packet):
  if isinstance(packet,int):packet=bytes([packet])
  if len(packet)==1:
   c=packet[0]
   if c in (103,104):self.modes=((self.modes&~1)|64) if c==103 else self.modes&~64
   elif 112<=c<=127:
    self.modes=(self.modes&~15)|(c-112)
    if self.modes&1:self.modes&=~64
   elif c in (101,102):self.modes=(self.modes&~32)|(32 if c==101 else 0)
   elif c in (248,249):self.modes=(self.modes&~16)|(16 if c==248 else 0)
   else:return super().apply(packet)
   return self.ack(c)
  return super().apply(packet)
class FisheyeProtocolTests(unittest.TestCase):
 def setUp(self):
  self.b=FisheyeBoard();self.events=[];self.c=StrengthControl(lambda *x:self.events.append(x));self.c.tick(0);self.assertTrue(self.c.receive(self.b.ack(240)))
 def execute(self,now):
  p=self.c.tick(now);self.assertIsNotNone(p);self.assertTrue(self.c.receive(self.b.apply(p)));return p
 def test_all_96_valid_mode_combinations(self):
  now=.1
  for mask in range(128):
   if mask&65==65:continue
   for key,bit in MODE_BITS.items():
    if key=='rotation':continue
    self.assertTrue(self.c.request_mode(key,bool(mask&bit),now))
   now+=.2;tries=0
   while self.c.confirmed_modes!=mask:
    self.execute(now);now+=.01;tries+=1;self.assertLess(tries,5)
   self.assertEqual(self.b.modes,mask)
 def test_fish_replaces_only_selected_lens_and_off_does_not_enable_brown(self):
  self.b.modes=63;self.c.confirmed_modes=self.c.mode_target=63
  self.assertTrue(self.c.request_mode('fisheye',True,.1));self.execute(.3);self.execute(.31)
  self.assertEqual(self.c.confirmed_modes,126)
  self.c.request_mode('fisheye',False,.4);self.assertEqual(self.execute(.6),bytes([104]));self.assertEqual(self.b.modes,62)
 def test_brown_on_clears_fish_atomically(self):
  self.b.modes=126;self.c.confirmed_modes=self.c.mode_target=126;self.c.request_mode('correct',True,.1)
  self.execute(.3);self.assertEqual(self.b.modes,63);self.assertFalse(self.b.modes&64)
 def test_legacy_r22_and_r21_do_not_enable_fish(self):
  for b in [EisBoard(),Board()]:
   c=StrengthControl(lambda *_:None);c.tick(0);self.assertTrue(c.receive(b.ack(240)));self.assertFalse(c.request_mode('fisheye',True,.1));self.assertFalse(c.fisheye_supported)
 def test_retry_and_wrong_ack(self):
  self.c.request_mode('fisheye',True,.1);p=self.c.tick(.3);self.assertEqual(p,bytes([103]));self.assertEqual(self.c.tick(1.81),p)
  self.assertFalse(self.c.receive(self.b.ack(103)));self.assertTrue(self.c.receive(self.b.apply(p)))
 def test_capability_and_onehot_state_validation(self):
  for text in [self.b.ack(240).replace('fisheye_on=0','fisheye_on=1'),self.b.ack(240).replace('modes=0','modes=65')]:
   c=StrengthControl(lambda *_:None);c.tick(0);self.assertFalse(c.receive(text))
 def test_mode_change_during_inflight_ack(self):
  self.c.request_mode('fisheye',True,.1);packet=self.c.tick(.3)
  self.c.request_mode('correct',True,.31);self.assertTrue(self.c.receive(self.b.apply(packet)))
  self.execute(.6);self.assertEqual(self.c.confirmed_modes,1)
class FisheyePhotoTests(unittest.TestCase):
 def test_flags_and_frame_identity(self):
  for flags in [0,1,3,4,5]:self.assertEqual(decode(encode(Packet(Kind.DATA,1,flags=flags))).flags,flags)
  for flags in [2,6,7,9,11,13,16]:
   with self.assertRaises(PacketError):decode(encode(Packet(Kind.DATA,1,flags=flags)))
  pixels=b'\x10\x42'*1024;p=Packet(Kind.DATA,1,77,0,2,64,16,1,zlib.crc32(pixels),pixels[:1024],4);a=FrameAssembler(1,(64,16));a.add(p)
  with self.assertRaises(SnapshotError):a.add(replace(p,index=1,flags=5,payload=pixels[1024:]))
  a.add(replace(p,index=1,payload=pixels[1024:]));self.assertEqual(a.finish(),pixels)
 def test_saved_fisheye_metadata_marks_geometry(self):
  with tempfile.TemporaryDirectory(dir=P/'work/fisheye_integration') as tmp:
   result=dict(pixels=b'\x10\x42'*(64*16),frame_id=1,width=64,height=16,fisheye_applied=True,geometry_flags=4)
   _,png,meta=save_snapshot(result,Path(tmp),{})
   self.assertTrue(meta['distortion_calibration_performed']);self.assertTrue(meta['fisheye_applied']);self.assertEqual(meta['geometry_flags'],4)
 def test_corrected_photo_cannot_be_used_to_refit_original_lens(self):
  from unittest.mock import patch
  import checkerboard,numpy as np
  with tempfile.TemporaryDirectory(dir=P/'work/fisheye_integration') as tmp:
   f=Path(tmp)/'photo.png';import cv2;cv2.imencode('.png',np.zeros((1080,1920,3),np.uint8))[1].tofile(str(f))
   f.with_suffix('.json').write_text(json.dumps({'png_sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'fisheye_applied':True,'geometry_flags':4}))
   base=dict(advice=[],warnings=[],usable_for_calibration=True,status='KEEP')
   with patch.object(checkerboard,'detect',return_value=(base,None)):r,_=checkerboard.assess_file(f)
   self.assertFalse(r['usable_for_calibration']);self.assertEqual(r['status'],'RETAKE')
class FisheyeGuiTests(unittest.TestCase):
 def test_separate_button_and_legacy_capability(self):
  argv=sys.argv;sys.argv=[str(P/'host/camera_console/console.py')]
  import console
  sys.argv=argv
  import tkinter as tk
  root=tk.Tk();root.withdraw();app=console.CameraConsole(root,discover=False)
  try:
   self.assertIn(('fisheye','鱼眼畸变处理',64),MODE_DEFS)
   b=FisheyeBoard();c=StrengthControl(lambda k,v:app.emit(k,v));c.tick(0);c.receive(b.ack(240));app.poll_events()
   self.assertNotIn('disabled',app.mode_buttons['fisheye'].state());app.mode_clicked('fisheye');self.assertEqual(app.tuning_requests.get_nowait(),('mode','fisheye',True))
   self.assertEqual(app.mode_desired,64)
   old=StrengthControl(lambda k,v:app.emit(k,v));old.tick(0);old.receive(EisBoard().ack(240));app.poll_events()
   self.assertIn('disabled',app.mode_buttons['fisheye'].state())
  finally:
   app.closing=True;app.serial_stop.set()
   for token in root.tk.call('after','info'):root.after_cancel(token)
   root.destroy()
if __name__=='__main__':unittest.main()
