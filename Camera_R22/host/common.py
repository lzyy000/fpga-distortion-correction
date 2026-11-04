from pathlib import Path
import sys,struct,zlib,json
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools/python_packages'))
def crc(data):return zlib.crc32(data)&0xffffffff
def packet(seq,cmd,offset=0,data=b''):
    h=struct.pack('<4sIIII',b'IMG1',seq,cmd,offset,len(data))
    return h+struct.pack('<I',crc(h+data))+data
def ack(data,seq):
    if len(data)!=24:raise ValueError('ACK length')
    magic,s,status,a,b,c=struct.unpack('<4sIIIII',data)
    if magic!=b'ACK1' or s!=seq or crc(data[:20])!=c:raise ValueError('ACK magic/sequence/CRC')
    return status,a,b
