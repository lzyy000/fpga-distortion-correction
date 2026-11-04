import argparse,time,secrets,json,sys,subprocess
from datetime import datetime,timezone
from common import *
import serial
from serial.tools import list_ports
from raw_ethernet import RawLink
STEPS=[0,32,64,96,128,160,192,224,247]
def choose(scores,required):
 runs=[];run=[]
 for i,n in enumerate(scores):
  if n==required:run.append(i)
  else:
   if run:runs.append(run)
   run=[]
 if run:runs.append(run)
 if not runs or max(map(len,runs))<2:raise RuntimeError('No stable adjacent RX delay window. Preserve report; do not upload with an unreliable setting.')
 window=max(runs,key=len);mid=(STEPS[window[0]]+STEPS[window[-1]])/2
 return min(window,key=lambda i:abs(STEPS[i]-mid)),window
def select(ser,index):
 ser.reset_input_buffer();ser.write(bytes([ord('0')+index]));ser.flush()
 expected=f'RGMII RXSTEP={STEPS[index]:08X}'.encode();data=b'';end=time.monotonic()+3
 while time.monotonic()<end:
  data+=ser.read(max(1,ser.in_waiting))
  if expected in data.upper():time.sleep(.2);return data.decode(errors='replace')
 raise RuntimeError('No RXSTEP confirmation. Download RXCAL bitstream and confirm CPU/DDR boot first.')
def probe(raw,samples,detail=None):
 if detail is None:detail={}
 detail.update(crc_rejections=0,other_rejections=0,timeouts=0,bad_result=0)
 raw.arp();passed=0;seq=secrets.randbits(32)
 for i in range(samples):
  payload=bytes(((j*73)^(j>>3)^(i*19))&255 for j in range(1024))
  request=packet(seq,9,data=payload);raw.udp(request);received=False
  for response in raw.receive(time.monotonic()+.15):
   try:status,a,b=ack(response,seq)
   except ValueError:continue
   received=True
   if status==0 and a==crc(payload) and b==1024:passed+=1
   elif status==2:detail['crc_rejections']+=1
   elif status:detail['other_rejections']+=1
   else:detail['bad_result']+=1
   break
  if not received:detail['timeouts']+=1
  seq=(seq+1)&0xffffffff
 return passed
def main():
 p=argparse.ArgumentParser();p.add_argument('--port');p.add_argument('--local',default='192.168.1.105');p.add_argument('--samples',type=int,default=24);p.add_argument('--upload',action='store_true');a=p.parse_args()
 if not a.port:
  ports=[x.device for x in list_ports.comports() if x.vid==0x10c4 or 'CP210' in x.description]
  if len(ports)!=1:raise RuntimeError('Specify CP210x UART with --port COMxx; detected: '+str(ports))
  a.port=ports[0]
 if a.samples<4:raise ValueError('Use at least four probes per step')
 try:ser=serial.Serial(a.port,115200,timeout=.1)
 except serial.SerialException as e:raise RuntimeError(f'Cannot open {a.port}. Close SSCOM/serial assistant first; calibration needs UART control. {e}')
 raw=None;report={'mode':'physical_board_rx_calibration','timestamp':datetime.now(timezone.utc).isoformat(),'serial_port':a.port,'samples_per_step':a.samples,'steps':STEPS,'scores':[],'point_details':[],'uart':[],'pass':False}
 try:
  raw=RawLink(a.local)
  for index,step in enumerate(STEPS):
   report['uart'].append(select(ser,index));detail={};count=probe(raw,a.samples,detail);report['scores'].append(count);report['point_details'].append(detail)
   print(f'RX delay {step:3d}: {count}/{a.samples} valid 1024-byte echoes',flush=True)
  best,window=choose(report['scores'],a.samples);report['uart'].append(select(ser,best))
  confirmation={};count=probe(raw,96,confirmation);report['confirmation_detail']=confirmation
  report.update(selected_step=STEPS[best],passing_window=[STEPS[i] for i in window],confirmation_passes=count,confirmation_samples=96)
  if count!=96:raise RuntimeError('Selected window failed long-packet confirmation; inspect report instead of uploading')
  report['pass']=True
  print(f'Calibration PASS: RXSTEP={STEPS[best]}, 96/96 long probes. Keep board powered; KEY0 resets this setting.',flush=True)
 except Exception as e:report['error']=str(e);raise
 finally:
  if raw:raw.close()
  ser.close();encoded=json.dumps(report,indent=2)
  (ROOT/'reports/rx_calibration.json').write_text(encoded,encoding='utf-8')
  stamp=datetime.now().strftime('%Y%m%d_%H%M%S_%f')
  (ROOT/'reports'/f'rx_calibration_{stamp}.json').write_text(encoded,encoding='utf-8')
 if a.upload:
  subprocess.run([sys.executable,str(ROOT/'host/upload.py'),str(ROOT/'samples/radial'),'--local',a.local,'--expected-crc','dd4ced24','--expected-map-crc','c80a586b'],check=True)
if __name__=='__main__':
 try:main()
 except (OSError,RuntimeError,ValueError,subprocess.CalledProcessError) as e:print('ERROR:',e);sys.exit(1)
