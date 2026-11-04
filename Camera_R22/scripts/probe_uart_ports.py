from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import datetime,json,time,serial
from serial.tools import list_ports
P=Path(__file__).resolve().parents[1]
ports=list(list_ports.comports());stamp=datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
def listen(port):
 result={'port':port.device,'description':port.description,'vid':port.vid,'pid':port.pid,'baud':115200,'writes_sent':0,'dtr':False,'rts':False}
 uart=None;raw=bytearray()
 try:
  uart=serial.Serial(port=None,baudrate=115200,timeout=.15);uart.dtr=False;uart.rts=False;uart.port=port.device;uart.open()
  result['opened']=True;start=time.monotonic()
  while time.monotonic()-start<12:
   raw.extend(uart.read(max(1,min(uart.in_waiting,4096))))
  result['seconds']=time.monotonic()-start
 except Exception as exc:result.update(opened=False,error=str(exc))
 finally:
  if uart:uart.close()
 text=bytes(raw).decode('utf-8','replace')
 result['bytes_received']=len(raw)
 log=P/'reports'/f'uart_probe_{stamp}_{port.device}.log';log.write_text(text,encoding='utf-8')
 result['log']=str(log)
 lines=text.splitlines();result['diagnostic_lines']=[line for line in lines if any(t in line for t in ('DVP R1','CAM dt_ms','CORRECT map_flags','RAW good_new'))][-12:]
 return result
with ThreadPoolExecutor(max_workers=max(1,len(ports))) as pool:results=list(pool.map(listen,ports))
report={'checked_at':datetime.datetime.now().astimezone().isoformat(),'scope':'Passive 115200 baud, 8N1 listening only; no TX writes; DTR/RTS set false before opening. Occupied ports are not forcibly released.','ports':results}
(P/'reports/uart_probe_latest.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(report,ensure_ascii=False,indent=2),flush=True)
