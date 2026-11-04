"""R20 host compatibility and enhanced-payload preservation tests; no real board."""
from pathlib import Path
import sys,unittest,json,hashlib,socket,time,tempfile
P=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(P/'tools/python_packages'))
import test_tuning,test_transport
from tuning import StrengthControl
from transport import Packet,Kind,encode,decode,SnapshotClient
from storage import save_snapshot

class NightBoard(test_transport.MockBoard):
 def run(self):
  try:
   while not self.stop.is_set():
    try:data,peer=self.sock.recvfrom(2048)
    except socket.timeout:continue
    except OSError:break
    p=decode(data)
    if p.kind==Kind.HELLO:
     capabilities=['snapshot_rgb565','snapshot_night']
     if getattr(self,'host_modes',False):capabilities+=['host_modes','split_raw_left']
     if getattr(self,'ghe',False):capabilities+=['global_histogram']
     info={'device':'R20/R21 RTL oracle fixture','firmware':'TEST ONLY','capabilities':capabilities,'width':self.size[0],'height':self.size[1],'pixel_format':'RGB565_LE'}
     self.sock.sendto(encode(Packet(Kind.HELLO_REPLY,p.request_id,payload=json.dumps(info).encode())),peer)
    elif p.kind==Kind.CAPTURE:self.send_frame(p.request_id,peer)
    elif p.kind==Kind.END:self.completed=True
  except Exception as e:self.error=e

class R20Tests(unittest.TestCase):
 def test_r19_r20_tuning_and_unknown_version(self):
  for version in [19,20]:
   events=[];c=StrengthControl(lambda k,v:events.append((k,v)));self.assertEqual(c.tick(0),b'\xf0')
   self.assertTrue(c.receive(test_tuning.reply(240).replace('v=19',f'v={version}')))
   self.assertEqual(events[-1][1]['firmware_version'],version)
  c=StrengthControl(lambda *x:None);c.tick(0);self.assertFalse(c.receive(test_tuning.reply(240).replace('v=19','v=21')))

 def test_enhanced_payload_reaches_png_without_pc_reprocessing(self):
  words=[int(x,16) for x in (P/'sim/r20_snapshot/snapshot_c2_s128_expected.hex').read_text().split()]
  pixels=b''.join(x.to_bytes(32,'little')for x in words)
  b=NightBoard(pixels,(64,32));c=SnapshotClient('127.0.0.1','127.0.0.1',0,b.port,(64,32))
  try:
   info=c.hello(timeout=1);self.assertIn('snapshot_night',info['capabilities'])
   result=c.capture(timeout=3,retry_interval=.15);self.assertEqual(result['pixels'],pixels)
   self.assertEqual(result['processing'],'fpga_frame_night_follow_key4')
   self.assertEqual(result['firmware'],'TEST ONLY')
   with tempfile.TemporaryDirectory()as folder:
    image,path,metadata=save_snapshot(result,folder,{'mode':'R20 RTL TEST FIXTURE'})
    self.assertEqual(metadata['processing'],'fpga_frame_night_follow_key4')
    self.assertEqual(metadata['pixel_sha256'],hashlib.sha256(pixels).hexdigest())
    self.assertEqual(path.with_suffix('.json').is_file(),True)
  finally:c.close();b.close()

if __name__=='__main__':
 suite=unittest.TestSuite()
 for module in [test_tuning,test_transport,sys.modules[__name__]]:suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(module))
 result=unittest.TextTestRunner(verbosity=2).run(suite)
 files=['host/camera_console/console.py','host/camera_console/tuning.py','host/camera_console/transport.py','host/camera_console/storage.py','host/camera_console/test_r20_host.py','host/camera_console/test_tuning.py','host/camera_console/test_transport.py']
 report={'pass':result.wasSuccessful(),'tests':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'real_board_test':False,'source_sha256':{f:hashlib.sha256((P/f).read_bytes()).hexdigest()for f in files}}
 (P/'reports/r20_host_validation.json').write_text(json.dumps(report,indent=2),encoding='utf-8');sys.exit(0 if result.wasSuccessful()else 1)
