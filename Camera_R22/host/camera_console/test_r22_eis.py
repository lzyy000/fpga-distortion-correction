"""R22 EIS controls, mixed legacy transactions, snapshot flags, actual GUI; no board."""
from pathlib import Path
import unittest,sys,struct,zlib
from dataclasses import replace
from tuning import StrengthControl,MODE_BITS,EIS_DEFAULTS
from test_ghe import Board
from transport import Packet,Kind,encode,decode,FrameAssembler,SnapshotError,PacketError
P=Path(__file__).resolve().parents[2]
class EisBoard(Board):
 def __init__(self):super().__init__();self.p=dict(EIS_DEFAULTS)
 def ack(self,c):
  line=super().ack(c).replace('v=21','v=22')
  return line+f" eis_on={bool(self.modes&32):d} eis_ready=1 "+' '.join(f'{k}={v&0xffffffff:08X}' if k in ('imu_delay_us','frame_offset_us') else f'{k}={v}' for k,v in self.p.items())+' readout_us=32482 imu_age_ms=3 limit=0 eis_ok=1'
 def apply(self,packet):
  if isinstance(packet,int):packet=bytes([packet])
  if len(packet)==1:
   c=packet[0]
   if c in (101,102):self.modes=(self.modes&31)|(32 if c==101 else 0)
   else:
    eis=self.modes&32;super().apply(c);self.modes|=eis
   return self.ack(c)
  assert packet[:2]==bytes([255,69]) and sum(packet[:-1])&255==packet[-1]
  op,length,seq=packet[2:5];v=struct.unpack('<'+'f'*(length//4),packet[5:-1])
  if op==8:self.p.update(zoom_milli=round(v[2]*1000),tau_ms=round(v[4]*1000))
  elif op==11:self.p['yaw_tau_ms']=round(v[0]*1000)
  elif op==12:self.p['rs_milli']=round(v[1]*1000)
  elif op==10:self.p.update(imu_delay_us=round(v[0]),frame_offset_us=round(v[1]))
  return self.ack(0x100|seq)

class EisProtocolTests(unittest.TestCase):
 def setUp(self):
  self.b=EisBoard();self.events=[];self.c=StrengthControl(lambda *x:self.events.append(x));self.c.tick(0);self.assertTrue(self.c.receive(self.b.ack(240)))
 def execute(self,now):
  p=self.c.tick(now);self.assertIsNotNone(p);self.assertTrue(self.c.receive(self.b.apply(p)));return p
 def test_all_64_independent_mode_combinations(self):
  now=.1
  for mask in range(64):
   for key,bit in MODE_BITS.items():
    if key in ('fisheye','rotation'):continue
    self.assertTrue(self.c.request_mode(key,bool(mask&bit),now))
   now+=.2
   while self.c.confirmed_modes!=mask:self.execute(now);now+=.01
   self.assertEqual(self.b.modes,mask)
 def test_parameter_groups_roundtrip_signed_offsets_and_preserve_modes(self):
  self.b.modes=63;self.c.mode_target=63;self.c.confirmed_modes=63
  values=dict(zoom_milli=1120,tau_ms=350,yaw_tau_ms=700,rs_milli=0,imu_delay_us=-17000,frame_offset_us=-5000)
  self.assertTrue(self.c.request_eis(values,.1))
  for n in range(4):self.execute(.3+n*.1)
  self.assertEqual(self.c.eis_confirmed,values);self.assertFalse(self.c.eis_pending);self.assertEqual(self.b.modes,63)
 def test_binary_retry_is_identical_and_ack_is_required(self):
  self.c.request_eis({'zoom_milli':1100},.1);p=self.c.tick(.3)
  self.assertEqual(p,self.c.tick(1.81));bad=self.b.apply(p).replace('zoom_milli=1100','zoom_milli=1110')
  self.assertFalse(self.c.receive(bad));self.assertTrue(self.c.receive(self.b.ack(0x100|p[4])))
 def test_ghe_high_low_remains_atomic_when_eis_arrives(self):
  self.c.request('ghe',35,.1);self.execute(.3);self.c.request_eis({'rs_milli':0},.31);self.c.request_mode('eis',True,.31)
  self.assertEqual(len(self.execute(.32)),1);self.assertEqual(self.b.ghe,35)
  self.assertEqual(self.execute(.6),bytes([101]));self.assertEqual(self.execute(.61)[:2],bytes([255,69]))
 def test_reject_invalid_and_legacy_board_capability(self):
  with self.assertRaises(ValueError):self.c.request_eis({'zoom_milli':1049},.1)
  old=StrengthControl(lambda *_:None);old.tick(0);self.assertTrue(old.receive(Board().ack(240)))
  self.assertFalse(old.request_mode('eis',True,.1));self.assertFalse(old.request_eis(EIS_DEFAULTS,.1))
 def test_checksum_failure_or_rejected_parameter_does_not_claim_applied(self):
  self.c.request_eis({'rs_milli':0},.1);p=self.c.tick(.3)
  self.assertTrue(self.c.receive(self.b.ack(0x100|p[4]).replace('eis_ok=1','eis_ok=0')))
  self.assertEqual(self.events[-1][0],'eis_error');self.assertEqual(self.c.eis_confirmed['rs_milli'],1000)
 def test_newer_edit_survives_old_inflight_ack(self):
  self.c.request_eis({'tau_ms':300},.1);p=self.c.tick(.3)
  self.c.request_eis({'tau_ms':400},.31);self.assertTrue(self.c.receive(self.b.apply(p)))
  self.execute(.6);self.assertEqual(self.b.p['tau_ms'],400)

 def test_revert_during_flight_is_sent_after_ack(self):
  self.c.request_eis({'tau_ms':300},.1);p=self.c.tick(.3)
  self.c.request_eis({'tau_ms':250},.31);self.assertTrue(self.c.receive(self.b.apply(p)))
  self.execute(.6);self.assertEqual(self.b.p['tau_ms'],250)

class EisPhotoTests(unittest.TestCase):
 def test_data_flags_roundtrip_and_frame_mixing_rejected(self):
  pixels=b'\x10\x42'*1024;crc=zlib.crc32(pixels)
  p=Packet(Kind.DATA,1,77,0,2,64,16,1,crc,pixels[:1024],3)
  self.assertEqual(decode(encode(p)),p);a=FrameAssembler(1,(64,16));self.assertTrue(a.add(p))
  with self.assertRaises(SnapshotError):a.add(replace(p,index=1,payload=pixels[1024:],flags=1))
  a.add(replace(p,index=1,payload=pixels[1024:]));self.assertEqual(a.finish(),pixels)
 def test_unknown_flags_or_lens_without_eis_rejected(self):
  for flags in (2,6,7,9,11,13,65535):
   with self.assertRaises(PacketError):decode(encode(Packet(Kind.DATA,1,flags=flags)))

class EisGuiTests(unittest.TestCase):
 def test_parameters_and_old_firmware_gating(self):
  argv=sys.argv;sys.argv=[str(P/'host/camera_console/console.py')]
  import console
  sys.argv=argv
  import tkinter as tk
  root=tk.Tk();root.withdraw();app=console.CameraConsole(root,discover=False)
  try:
   b=EisBoard();c=StrengthControl(lambda k,v:app.emit(k,v));c.tick(0);c.receive(b.ack(240));app.poll_events()
   self.assertNotIn('disabled',app.mode_buttons['eis'].state());self.assertEqual(set(app.eis_vars),set(EIS_DEFAULTS))
   app.eis_vars['zoom_milli'].set('1.12');app.apply_eis();kind,values=app.tuning_requests.get_nowait();self.assertEqual(kind,'eis_params');self.assertEqual(values['zoom_milli'],1120)
   app.restore_eis();self.assertEqual(app.tuning_requests.get_nowait(),('eis_params',EIS_DEFAULTS))
   root.geometry('1060x720');root.deiconify();tab=app.tuning_canvas.master;tab.master.select(tab);root.update()
   app.tuning_canvas.yview_moveto(0);before=app.tuning_canvas.yview()[0]
   app.tuning_canvas.event_generate('<MouseWheel>',delta=-120);root.update()
   self.assertGreater(app.tuning_canvas.yview()[0],before)
   value=dict(night=100,denoise=100,ghe=100,night_on=False,denoise_on=False,ghe_on=False,ghe_ready=True,ghe_supported=True,modes=0,applied=0,firmware_version=21,first=True)
   app.emit('tune_ack',value);app.poll_events();self.assertIn('disabled',app.mode_buttons['eis'].state());self.assertIn('disabled',app.eis_apply.state())
  finally:
   app.closing=True
   for token in root.tk.call('after','info'):root.after_cancel(token)
   root.destroy()
if __name__=='__main__':unittest.main()
