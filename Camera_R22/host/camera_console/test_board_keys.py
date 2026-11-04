"""Physical mode readback must be adopted without an automatic write-back."""
import unittest
from tuning import StrengthControl
from test_rotation import RotationBoard
class BoardKeyHostTests(unittest.TestCase):
 def test_all_144_external_modes_are_observed_without_rewriting(self):
  b=RotationBoard();events=[];c=StrengthControl(lambda k,v:events.append((k,v)));c.tick(0);self.assertTrue(c.receive(b.ack(240)))
  now=0
  for mask in range(256):
   if mask&65==65 or mask&160==160:continue
   now+=3;self.assertEqual(c.tick(now),bytes([240]));b.modes=mask
   self.assertTrue(c.receive(b.ack(240)));self.assertEqual(c.mode_target,mask)
   self.assertIsNone(c.tick(now+.1));self.assertEqual(events[-1][1]['modes'],mask)
 def test_pending_host_edit_preserves_unrelated_board_change(self):
  b=RotationBoard();c=StrengthControl(lambda *_:None);c.tick(0);c.receive(b.ack(240))
  self.assertEqual(c.tick(3),bytes([240]));c.request_mode('night',True,3.01);b.modes=1
  self.assertTrue(c.receive(b.ack(240)));self.assertEqual(c.mode_target,9)
  packet=c.tick(3.3);self.assertEqual(packet,bytes([121]));self.assertTrue(c.receive(b.apply(packet)));self.assertEqual(c.confirmed_modes,9)
 def test_board_mutual_exclusion_while_host_edits_other_bit(self):
  b=RotationBoard();b.modes=1;c=StrengthControl(lambda *_:None);c.tick(0);c.receive(b.ack(240))
  self.assertEqual(c.tick(3),bytes([240]));c.request_mode('night',True,3.01);b.modes=64
  self.assertTrue(c.receive(b.ack(240)));self.assertEqual(c.mode_target,72)
 def test_gui_pending_edit_finishes_with_merged_board_state(self):
  import sys,tkinter as tk
  argv=sys.argv;sys.argv=[__file__];import console;sys.argv=argv
  root=tk.Tk();root.withdraw();app=console.CameraConsole(root,discover=False)
  try:
   b=RotationBoard();c=StrengthControl(app.emit);c.tick(0);c.receive(b.ack(240));app.poll_events()
   self.assertEqual(c.tick(3),bytes([240]))
   app.mode_clicked('night');c.request_mode('night',True,3.01);b.modes=1
   self.assertTrue(c.receive(b.ack(240)));app.poll_events();self.assertTrue(app.mode_pending)
   self.assertEqual(c.tick(3.3),bytes([121]));self.assertTrue(c.receive(b.apply(bytes([121]))));app.poll_events()
   self.assertFalse(app.mode_pending);self.assertEqual(app.mode_desired,9);self.assertEqual(app.mode_buttons['correct'].cget('text'),'关闭')
  finally:
   app.quality_panel.close();app.closing=True;app.serial_stop.set()
   for token in root.tk.call('after','info'):root.after_cancel(token)
   root.destroy()
