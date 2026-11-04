"""Collect board counters only; no video processing is performed here."""
from pathlib import Path
import sys,argparse,re,json,time,datetime
P=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(P/'tools/python_packages'))
import serial
from serial.tools import list_ports
pattern=re.compile(r'VIDEO dt_ms=(\d+) cap=(\d+) proc=(\d+) display=(\d+) skipped=(\d+) process_us=(\d+) flags=([0-9A-Fa-f]+) total=(\d+)')
def parse(line):
 m=pattern.search(line)
 if not m:return None
 keys=['dt_ms','cap','proc','display','skipped','process_us','flags','total']
 return {k:int(v,16 if k=='flags' else 10) for k,v in zip(keys,m.groups())}
def summarize(rows):
 seconds=sum(x['dt_ms'] for x in rows)/1000
 rates={k:sum(x[k] for x in rows)/seconds for k in ['cap','proc','display','skipped']}
 healthy=all((x['flags']&0x3b)==0x3b and not (x['flags']&0xc0) for x in rows)
 return {'seconds':seconds,'rates_fps':rates,'max_process_us':max(x['process_us'] for x in rows),
         'counter_gate_pass':healthy and rates['proc']>=29 and rates['display']>=29,
         'visual_acceptance':'pending: verify frame ID moves and left/right image correctness on physical HDMI',
         'scope':'physical UART frame counters, not semantic unique source-frame recognition'}
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--port');ap.add_argument('--seconds',type=float,default=10);ap.add_argument('--timeout',type=float,default=900)
 a=ap.parse_args()
 if a.seconds<10:ap.error('Use at least 10 seconds to assess 30 fps')
 ports=list(list_ports.comports())
 if not a.port:
  matches=[p.device for p in ports if 'CP210' in p.description.upper()]
  if len(matches)==1:a.port=matches[0]
  else:
   print('Available serial ports:',[(p.device,p.description) for p in ports])
   a.port=input('Board UART COM port: ').strip()
 print('Close other serial assistants first. Waiting for VIDEO ENABLED / healthy frame counters.')
 rows=[];deadline=time.monotonic()+a.timeout
 with serial.Serial(a.port,115200,timeout=1) as uart:
  while time.monotonic()<deadline:
   line=uart.readline().decode('ascii','replace').strip()
   if line:print(line)
   row=parse(line)
   if not row:continue
   if row['flags']&0xc0:raise RuntimeError('Board video fault/line overrun; preserve this log and check input timing')
   if (row['flags']&0x3b)!=0x3b:continue
   rows.append(row)
   if sum(x['dt_ms'] for x in rows)>=a.seconds*1000:break
  else:raise TimeoutError('No complete video measurement; check board map completion and HDMI source')
 summary=summarize(rows)
 report=P/'reports'/('video_uart_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S')+'.json')
 report.write_text(json.dumps({'rows':rows,'summary':summary},indent=2),encoding='utf-8')
 print(json.dumps(summary,indent=2));print('Report:',report)
 if not summary['counter_gate_pass']:raise RuntimeError('Measured counter rate is below the video target')
if __name__=='__main__':
 try:main()
 except Exception as e:print('ERROR:',e);sys.exit(1)
