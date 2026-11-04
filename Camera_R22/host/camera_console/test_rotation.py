"""Rotation capability, independent controls, all valid combinations and geometry identity."""
import unittest,struct,zlib,sys
from tuning import StrengthControl,MODE_BITS,ROTATION_DEFAULTS,EIS_DEFAULTS
from test_fisheye import FisheyeBoard
from transport import Packet,Kind,decode,encode,PacketError
class RotationBoard(FisheyeBoard):
 def __init__(self):super().__init__();self.rot=dict(ROTATION_DEFAULTS)
 def ack(self,c):return super().ack(c)+" rotation_supported=1 rotation_on="+str(int(bool(self.modes&128)))+" rot_ready=1 rot_limit=0 rot_actual_zoom_milli=1160 "+' '.join(f'{k}={v}' for k,v in self.rot.items())
 def apply(self,p):
  if len(p)==1:
   c=p[0]
   if c==105:self.modes=(self.modes&~32)|128
   elif c==106:self.modes&=~128
   elif c==101:self.modes=(self.modes&~128)|32
   else:return super().apply(p)
   return self.ack(c)
  if p[2]==13:
   assert p[:2]==bytes([255,69]) and sum(p[:-1])&255==p[-1]
   v=struct.unpack('<5f',p[5:-1]);self.rot=dict(zip(ROTATION_DEFAULTS,[round(v[0]*1000),round(v[1]*1000),round(v[2]*1000),round(v[3]),round(v[4]*1000)]));return self.ack(0x100|p[4])
  return super().apply(p)
class RotationTests(unittest.TestCase):
 def setUp(self):
  self.b=RotationBoard();self.events=[];self.c=StrengthControl(lambda *e:self.events.append(e));self.c.tick(0);self.assertTrue(self.c.receive(self.b.ack(240)))
 def step(self,t):
  p=self.c.tick(t);self.assertIsNotNone(p);self.assertTrue(self.c.receive(self.b.apply(p)));return p
 def test_all_144_combinations(self):
  now=.1;count=0
  for mask in range(256):
   if mask&65==65 or mask&160==160:continue
   for key,bit in MODE_BITS.items():self.assertTrue(self.c.request_mode(key,bool(mask&bit),now))
   now+=.2;n=0
   while self.c.confirmed_modes!=mask:
    self.step(now);now+=.01;n+=1;self.assertLess(n,6)
   self.assertEqual(self.b.modes,mask);count+=1
  self.assertEqual(count,144)
 def test_atomic_motion_switch_and_preserve_other_algorithms(self):
  self.b.modes=126;self.c.mode_target=self.c.confirmed_modes=126
  self.c.request_mode('rotation',True,.1);self.assertEqual(self.step(.3),bytes([105]));self.assertEqual(self.b.modes,222)
  self.c.request_mode('eis',True,.4);self.assertEqual(self.step(.6),bytes([101]));self.assertEqual(self.b.modes,126)
 def test_separate_parameters_retry_and_newer_edit(self):
  old=dict(self.c.eis_confirmed);self.c.request_rotation(dict(rot_zoom_milli=1300,rot_horizon=0),.1);p=self.c.tick(.3)
  self.assertEqual(p[2],13);self.assertEqual(self.c.tick(1.81),p)
  self.c.request_rotation({'rot_tau_ms':1100},1.82);self.assertTrue(self.c.receive(self.b.apply(p)));self.step(2.1)
  self.assertEqual(self.c.eis_confirmed,old);self.assertEqual(self.c.rotation_confirmed['rot_tau_ms'],1100)
 def test_old_firmware_and_invalid_state_are_rejected(self):
  c=StrengthControl(lambda *_:None);c.tick(0);self.assertTrue(c.receive(FisheyeBoard().ack(240)))
  self.assertFalse(c.request_mode('rotation',True,.1));self.assertFalse(c.request_rotation(ROTATION_DEFAULTS,.1))
  for mask in [160,192+1]:
   b=RotationBoard();b.modes=mask;c=StrengthControl(lambda *_:None);c.tick(0);self.assertFalse(c.receive(b.ack(240)))
  with self.assertRaises(ValueError):self.c.request_rotation({'rot_max_zoom_milli':1100},.1)
 def test_geometry_flags(self):
  for flags in [0,1,3,4,5,8,10,12]:self.assertEqual(decode(encode(Packet(Kind.DATA,1,flags=flags))).flags,flags)
  for flags in [2,6,7,9,11,13,14,15,16]:
   with self.assertRaises(PacketError):decode(encode(Packet(Kind.DATA,1,flags=flags)))
 def test_rotation_gui_gating_parameters_and_mutex(self):
  argv=sys.argv;sys.argv=[str(__file__)];import console;sys.argv=argv
  import tkinter as tk
  root=tk.Tk();root.withdraw();app=console.CameraConsole(root,discover=False)
  try:
   c=StrengthControl(lambda k,v:app.emit(k,v));c.tick(0);c.receive(self.b.ack(240));app.poll_events()
   self.assertNotIn('disabled',app.mode_buttons['rotation'].state());self.assertEqual(set(app.rotation_vars),set(ROTATION_DEFAULTS))
   app.rotation_vars['rot_zoom_milli'].set('1.25');app.apply_rotation();kind,values=app.tuning_requests.get_nowait();self.assertEqual(kind,'rotation_params');self.assertEqual(values['rot_zoom_milli'],1250)
   app.mode_desired=32;app.mode_clicked('rotation');self.assertEqual(app.mode_desired,128)
   old=StrengthControl(lambda k,v:app.emit(k,v));old.tick(0);old.receive(FisheyeBoard().ack(240));app.poll_events();self.assertIn('disabled',app.mode_buttons['rotation'].state())
  finally:
   app.closing=True;app.serial_stop.set()
   for token in root.tk.call('after','info'):root.after_cancel(token)
   root.destroy()
