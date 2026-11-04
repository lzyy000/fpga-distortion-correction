"""R19 control protocol and actual Tk slider layout checks, without devices."""
import unittest,sys,json,hashlib,ast,time
from pathlib import Path
from tuning import StrengthControl
P=Path(__file__).resolve().parents[2]

def reply(cmd,n=100,d=100,no=0,do=0):
 return f'TUNE v=19 cmd={cmd:08X} night={n} denoise={d} night_q8={(n*256+50)//100} denoise_q8={(d*256+50)//100} night_on={no} denoise_on={do}'

class ProtocolTests(unittest.TestCase):
 def setUp(self):self.events=[];self.c=StrengthControl(lambda k,v:self.events.append((k,v)))
 def ready(self):
  self.assertEqual(self.c.tick(0),b'\xf0');self.assertTrue(self.c.receive(reply(240)))
 def test_query_does_not_change_algorithm(self):
  self.c.request('night',0,0);self.assertFalse(self.c.pending);self.ready();self.assertEqual(self.c.confirmed,{'night':100,'denoise':100})
 def test_coalesces_slider_and_confirms(self):
  self.ready()
  for i in range(50):self.c.request('night',i,.01*i)
  self.assertIsNone(self.c.tick(.5));self.assertEqual(self.c.tick(.7),bytes([128+49]))
  self.assertTrue(self.c.receive(reply(177,n=49)));self.assertFalse(self.c.pending)
 def test_pending_value_survives_old_ack(self):
  self.ready();self.c.request('night',30,.1);self.assertEqual(self.c.tick(.3),bytes([158]))
  self.c.request('night',70,.31);self.c.receive(reply(158,n=30))
  self.assertEqual(self.c.tick(.6),bytes([198]));self.c.receive(reply(198,n=70));self.assertFalse(self.c.pending)
 def test_axes_and_endpoints(self):
  self.ready();self.c.request('night',0,.1);self.c.request('denoise',100,.1)
  self.assertEqual(self.c.tick(.3),bytes([128]));self.c.receive(reply(128,n=0));self.assertIsNone(self.c.tick(.4))
  self.c.request('denoise',0,.5);self.assertEqual(self.c.tick(.7),bytes([0]));self.c.receive(reply(0,n=0,d=0,no=1,do=1))
  self.assertEqual(self.events[-1][1]['night_on'],True)
 def test_ack_must_match_command_and_q8(self):
  self.ready();self.c.request('denoise',50,.1);self.c.tick(.3)
  self.assertFalse(self.c.receive(reply(49,d=49)));self.assertFalse(self.c.receive(reply(50,d=50).replace('denoise_q8=128','denoise_q8=129')))
  self.assertFalse(self.c.receive(reply(50,d=49)));self.assertTrue(self.c.receive(reply(50,d=50)))
 def test_retry_and_old_firmware_timeout(self):
  self.assertEqual(self.c.tick(0),b'\xf0');self.assertIsNone(self.c.tick(1));self.assertEqual(self.c.tick(1.5),b'\xf0');self.assertEqual(self.c.tick(3),b'\xf0')
  self.assertIsNone(self.c.tick(4.5));self.assertTrue(self.c.failed);self.assertFalse(self.c.ready);self.assertEqual(self.events[-1][0],'tune_error')
 def test_set_retries_are_idempotent(self):
  self.ready();self.c.request('night',75,.1);self.assertEqual(self.c.tick(.3),bytes([203]));self.assertEqual(self.c.tick(1.8),bytes([203]));self.assertTrue(self.c.receive(reply(203,n=75)))
 def test_invalid_input(self):
  self.ready()
  for key,n in [('night',101),('night',-1),('unknown',50)]:
   with self.assertRaises(ValueError):self.c.request(key,n,0)
  self.assertFalse(self.c.receive('TUNE v=18 cmd=000000F0'))

class GuiTests(unittest.TestCase):
 def test_actual_sliders_and_layout(self):
  argv=sys.argv;sys.argv=[str(P/'host/camera_console/console.py')]
  import console
  sys.argv=argv
  import tkinter as tk
  root=tk.Tk();root.withdraw()
  app=console.CameraConsole(root,discover=False)
  try:
   self.assertEqual(set(app.strength_scales),{'night','denoise','ghe'})
   self.assertEqual(set(app.mode_buttons),{'correct','split','denoise','night','ghe','eis','fisheye','rotation'})
   for scale in app.strength_scales.values():self.assertIn('disabled',scale.state())
   app.tuning_ready=True;app.strength_changed('night','42.3')
   self.assertEqual(app.tuning_requests.get_nowait(),('night',42));self.assertEqual(app.strength_labels['night'].get(),'42%')
   # Lay out the actual tab and verify controls fit the minimum supported window.
   root.geometry('1060x720');root.deiconify()
   tab=app.tuning_canvas.master
   notebook=tab.master;notebook.select(tab);root.update()
   for scale in app.strength_scales.values():self.assertFalse(scale.winfo_ismapped())
   for key in ('night','denoise'):app.show_strength(key,True)
   root.update()
   for key in ('night','denoise'):
    scale=app.strength_scales[key]
    self.assertGreater(scale.winfo_width(),100);self.assertTrue(scale.winfo_ismapped())
   card=app.strength_scales['night'].master
   children=card.winfo_children();last=children[-1]
   self.assertLessEqual(last.winfo_y()+last.winfo_height(),card.winfo_height())
   app.disable_tuning('test disconnected')
   for scale in app.strength_scales.values():self.assertIn('disabled',scale.state())
  finally:
   app.closing=True;app.serial_stop.set()
   for token in root.tk.call('after','info'):root.after_cancel(token)
   root.destroy()

if __name__=='__main__':
 result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
 files=['host/camera_console/console.py','host/camera_console/tuning.py','host/camera_console/test_tuning.py']
 for f in files:ast.parse((P/f).read_text(encoding='utf-8-sig'))
 report={'pass':result.wasSuccessful(),'tests':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'physical_serial_test':False,'source_sha256':{f:hashlib.sha256((P/f).read_bytes()).hexdigest() for f in files}}
 (P/'reports/r19_host_validation.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
 sys.exit(0 if result.wasSuccessful() else 1)
