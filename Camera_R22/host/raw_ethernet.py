import ctypes as c,ipaddress,json,socket,struct,subprocess,time
from pcap_runtime import load_pcap
class HDR(c.Structure):_fields_=[('sec',c.c_long),('usec',c.c_long),('caplen',c.c_uint),('length',c.c_uint)]
class BPF(c.Structure):_fields_=[('length',c.c_uint),('insns',c.c_void_p)]
class RawLink:
 def __init__(self,local='192.168.1.105',board='192.168.1.11'):
  ipaddress.IPv4Address(local);ipaddress.IPv4Address(board)
  cmd=f"$i=Get-NetIPAddress -AddressFamily IPv4 -IPAddress '{local}'; Get-NetAdapter -InterfaceIndex $i.InterfaceIndex | Select-Object InterfaceGuid,MacAddress | ConvertTo-Json -Compress"
  adapter=json.loads(subprocess.check_output(['powershell.exe','-NoProfile','-Command',cmd],text=True))
  self.pc=bytes.fromhex(adapter['MacAddress'].replace('-',''));self.board=bytes.fromhex('a0b1c2d3e1e1')
  self.pi=socket.inet_aton(local);self.bi=socket.inet_aton(board);self.frames=[]
  self.lib=load_pcap();lib=self.lib
  lib.pcap_open_live.argtypes=[c.c_char_p,c.c_int,c.c_int,c.c_int,c.c_char_p];lib.pcap_open_live.restype=c.c_void_p
  lib.pcap_next_ex.argtypes=[c.c_void_p,c.POINTER(c.POINTER(HDR)),c.POINTER(c.POINTER(c.c_ubyte))];lib.pcap_next_ex.restype=c.c_int
  lib.pcap_sendpacket.argtypes=[c.c_void_p,c.c_char_p,c.c_int];lib.pcap_sendpacket.restype=c.c_int
  lib.pcap_compile.argtypes=[c.c_void_p,c.POINTER(BPF),c.c_char_p,c.c_int,c.c_uint];lib.pcap_compile.restype=c.c_int
  lib.pcap_setfilter.argtypes=[c.c_void_p,c.POINTER(BPF)];lib.pcap_setfilter.restype=c.c_int
  lib.pcap_freecode.argtypes=[c.POINTER(BPF)];lib.pcap_close.argtypes=[c.c_void_p]
  err=c.create_string_buffer(512)
  guid=adapter['InterfaceGuid'].strip('{}')
  self.h=lib.pcap_open_live(('\\Device\\NPF_{'+guid+'}').encode(),65535,0,10,err)
  if not self.h:raise RuntimeError('Cannot open Ethernet capture: '+err.value.decode(errors='replace'))
  bpf=BPF()
  if lib.pcap_compile(self.h,c.byref(bpf),b'ether src a0:b1:c2:d3:e1:e1',1,0xffffffff)!=0 or lib.pcap_setfilter(self.h,c.byref(bpf))!=0:
   self.close();raise RuntimeError('Capture filter failed')
  lib.pcap_freecode(c.byref(bpf))
  lib.pcap_setnonblock.argtypes=[c.c_void_p,c.c_int,c.c_char_p];lib.pcap_setnonblock.restype=c.c_int
  if lib.pcap_setnonblock(self.h,1,err)!=0:self.close();raise RuntimeError('Nonblocking capture failed')
 def send(self,b):
  if self.lib.pcap_sendpacket(self.h,b,len(b))!=0:raise RuntimeError('Raw Ethernet transmit failed')
 def arp(self):self.send((b'\xff'*6+self.pc+b'\x08\x06'+struct.pack('>HHBBH',1,0x800,6,4,1)+self.pc+self.pi+b'\0'*6+self.bi).ljust(60,b'\0'))
 def udp(self,msg):
  udp=struct.pack('>HHHH',8080,8080,len(msg)+8,0)+msg
  ip=struct.pack('>BBHHHBBH4s4s',0x45,0,20+len(udp),33,0x4000,64,17,0,self.pi,self.bi)
  sm=sum(struct.unpack('>10H',ip));sm=(sm&65535)+(sm>>16);sm=(sm&65535)+(sm>>16)
  ip=ip[:10]+struct.pack('>H',(~sm)&65535)+ip[12:]
  self.send(self.board+self.pc+b'\x08\x00'+ip+udp)
 def receive(self,deadline):
  hdr=c.POINTER(HDR)();data=c.POINTER(c.c_ubyte)()
  while time.monotonic()<deadline:
   rc=self.lib.pcap_next_ex(self.h,c.byref(hdr),c.byref(data))
   if rc<0:raise RuntimeError('Capture read failed')
   if rc!=1:time.sleep(.002);continue
   b=c.string_at(data,hdr.contents.caplen)
   self.frames.append(b.hex())
   if len(b)>=42 and b[12:14]==b'\x08\x06' and b[20:22]==b'\x00\x01' and b[38:42]==self.pi:
    self.send((b[6:12]+self.pc+b'\x08\x06'+struct.pack('>HHBBH',1,0x800,6,4,2)+self.pc+self.pi+b[22:28]+b[28:32]).ljust(60,b'\0'))
   if len(b)>=42 and b[12:14]==b'\x08\x00' and b[23]==17 and b[30:34]==self.pi:
    ihl=(b[14]&15)*4;off=14+ihl
    if len(b)>=off+8:
     src,dst,n,_=struct.unpack('>HHHH',b[off:off+8])
     if src==8080 and dst==8080 and n>=8 and len(b)>=off+n:yield b[off+8:off+n]
 def close(self):
  if getattr(self,'h',None):self.lib.pcap_close(self.h);self.h=None
