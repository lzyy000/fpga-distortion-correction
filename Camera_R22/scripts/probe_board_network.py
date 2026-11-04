"""FPGA-only Ethernet handshake diagnostics; no image capture or OS changes."""
from pathlib import Path
import sys,time,json,secrets,socket,subprocess,datetime
import ctypes as c
P=Path(__file__).resolve().parents[1]
cfg=json.loads((P/'scripts/local_tools.json').read_text(encoding='utf-8-sig'))
sys.path[:0]=[str(Path(cfg['shared_tools'])/'python_packages'),str(P/'host'),str(P/'host/camera_console')]
from transport import SnapshotClient,SnapshotError,Packet,Kind,encode,decode
from raw_ethernet import RawLink,BPF
result={'checked_at':datetime.datetime.now().astimezone().isoformat()}
try:
 interface_index=int(subprocess.check_output(['powershell.exe','-NoProfile','-Command',"(Get-NetIPAddress -AddressFamily IPv4 -IPAddress '192.168.1.105').InterfaceIndex"],text=True).strip())
 result['selected_interface_index']=interface_index
 client=SnapshotClient('192.168.1.105','192.168.1.11',interface_index=interface_index)
 result['socket_interface_index']=client.sock.getsockopt(socket.IPPROTO_IP,31)
 try:result['udp_handshake']=client.hello(timeout=5)
 except Exception as e:result['udp_error']=str(e)
 finally:client.close()
except Exception as e:result['socket_error']=str(e)
try:
 raw=RawLink();request=secrets.randbits(32)
 try:
  bpf=BPF()
  expression=b'(arp and host 192.168.1.11) or (udp and host 192.168.1.11 and port 8080)'
  if raw.lib.pcap_compile(raw.h,c.byref(bpf),expression,1,0xffffffff)!=0:raise RuntimeError('Diagnostic capture filter compile failed')
  try:
   if raw.lib.pcap_setfilter(raw.h,c.byref(bpf))!=0:raise RuntimeError('Diagnostic capture filter failed')
  finally:raw.lib.pcap_freecode(c.byref(bpf))
  raw.arp();raw.udp(encode(Packet(Kind.HELLO,request)))
  for payload in raw.receive(time.monotonic()+4):
   try:
    packet=decode(payload)
    if packet.request_id==request and packet.kind==Kind.HELLO_REPLY:result['raw_handshake']=json.loads(packet.payload)
   except Exception as e:result.setdefault('raw_payload_errors',[]).append(str(e))
  frames=[bytes.fromhex(frame) for frame in raw.frames]
  result['frames']=[{'source_mac':frame[6:12].hex(':'),'destination_mac':frame[:6].hex(':'),'ethertype':frame[12:14].hex(),'bytes':len(frame)} for frame in frames]
  result['pc_outgoing_frames']=sum(frame[6:12]==raw.pc for frame in frames)
  result['other_incoming_frames']=sum(frame[6:12]!=raw.pc for frame in frames)
 finally:raw.close()
except Exception as e:result['capture_error']=str(e)
(P/'reports/network_probe_latest.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({k:v for k,v in result.items() if k!='board_ethernet_frames'},ensure_ascii=False,indent=2))
