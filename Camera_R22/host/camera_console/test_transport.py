"""Local protocol tests. Generated fixtures are explicitly not camera photographs."""
from pathlib import Path
import json
import math
import socket
import struct
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import zlib
import numpy as np
from PIL import Image
from transport import Packet, Kind, encode, decode, FrameAssembler, SnapshotClient, SnapshotError, PacketError, CHUNK_BYTES
from storage import save_snapshot, rgb565_image

class MockBoard:
    def __init__(self,pixels,size,drop=(),bad_packet=(),wrong_frame_crc=False,legacy=False):
        self.pixels=pixels;self.size=size;self.drop=set(drop);self.bad_packet=set(bad_packet)
        self.wrong_frame_crc=wrong_frame_crc;self.legacy=legacy;self.resend_requests=[]
        self.frame_crc=zlib.crc32(self.pixels)^(1 if self.wrong_frame_crc else 0)
        self.sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);self.sock.bind(('127.0.0.1',0));self.port=self.sock.getsockname()[1]
        self.sock.settimeout(.1);self.stop=threading.Event();self.error=None;self.completed=False;self.cancelled=False
        self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()

    def data_packet(self,request,index):
        return Packet(Kind.DATA,request,frame_id=42,index=index,count=math.ceil(len(self.pixels)/CHUNK_BYTES),
                      width=self.size[0],height=self.size[1],frame_crc=self.frame_crc,
                      payload=self.pixels[index*CHUNK_BYTES:(index+1)*CHUNK_BYTES])

    def send_frame(self,request,peer):
        for index in reversed(range(math.ceil(len(self.pixels)/CHUNK_BYTES))):
            if self.stop.is_set():return
            if index in self.drop:continue
            data=bytearray(encode(self.data_packet(request,index)))
            if index in self.bad_packet:data[-1]^=1
            self.sock.sendto(data,peer)
            if index%8==0:time.sleep(.002)
        # Exercise duplicate delivery without changing the frame.
        if 0 not in self.drop:self.sock.sendto(encode(self.data_packet(request,0)),peer)

    def run(self):
        try:
            while not self.stop.is_set():
                try:data,peer=self.sock.recvfrom(2048)
                except socket.timeout:continue
                except OSError:break
                packet=decode(data)
                if packet.kind==Kind.HELLO:
                    if self.legacy:self.sock.sendto(b'ACK1'+b'\0'*20,peer);continue
                    payload=json.dumps({'device':'Protocol test fixture, NOT a camera','firmware':'MOCK TEST ONLY',
                                        'capabilities':['snapshot_rgb565'],'width':self.size[0],'height':self.size[1],
                                        'pixel_format':'RGB565_LE'}).encode()
                    self.sock.sendto(encode(Packet(Kind.HELLO_REPLY,packet.request_id,payload=payload)),peer)
                elif packet.kind==Kind.CAPTURE:self.send_frame(packet.request_id,peer)
                elif packet.kind==Kind.MISSING:
                    indices=struct.unpack('!'+str(len(packet.payload)//4)+'I',packet.payload)
                    self.resend_requests.extend(indices)
                    for position,index in enumerate(indices):
                        self.sock.sendto(encode(self.data_packet(packet.request_id,index)),peer)
                        if position%8==0:time.sleep(.002)
                elif packet.kind==Kind.END:self.completed=True
                elif packet.kind==Kind.CANCEL:self.cancelled=True
        except Exception as exc:self.error=exc

    def close(self):
        self.stop.set();self.thread.join(timeout=1);self.sock.close()
        if self.error:raise self.error

class ProtocolTests(unittest.TestCase):
    def test_windows_outgoing_interface_network_byte_order(self):
        with patch('transport.sys.platform','win32'),patch('transport.socket.socket') as factory:
            client=SnapshotClient('192.168.1.105','192.168.1.11',interface_index=17)
            factory.return_value.setsockopt.assert_any_call(socket.IPPROTO_IP,31,b'\x00\x00\x00\x11')
            factory.return_value.bind.assert_called_once_with(('192.168.1.105',8080))
            client.close()

    def test_invalid_interface_closes_unbound_socket(self):
        with patch('transport.sys.platform','win32'),patch('transport.socket.socket') as factory:
            with self.assertRaises(ValueError):SnapshotClient('192.168.1.105','192.168.1.11',interface_index=0)
            factory.return_value.close.assert_called_once()
            factory.return_value.bind.assert_not_called()

    def fixture(self,size):
        width,height=size;y,x=np.indices((height,width),dtype=np.uint32)
        return (((x%32)<<11)|((y%64)<<5)|((x+y)%32)).astype('<u2').tobytes()

    def client(self,board):
        client=SnapshotClient('127.0.0.1','127.0.0.1',0,board.port,board.size)
        self.addCleanup(client.close);self.addCleanup(board.close)
        return client

    def test_full_1080p_loss_out_of_order_and_corrupt_packet(self):
        size=(1920,1080);pixels=self.fixture(size)
        board=MockBoard(pixels,size,drop=(3,90,800,2100),bad_packet=(42,))
        client=self.client(board);client.hello(timeout=1)
        result=client.capture(timeout=8,retry_interval=.25)
        self.assertEqual(result['pixels'],pixels)
        self.assertEqual(result['packets'],4050)
        self.assertTrue({3,90,800,2100,42}.issubset(set(board.resend_requests)))
        with tempfile.TemporaryDirectory() as folder:
            image,path,metadata=save_snapshot(result,folder,{'mode':'TEST FIXTURE NOT A CAMERA'})
            decoded=np.asarray(Image.open(path))
            for x,y in [(0,0),(31,63),(1500,800),(1919,1079)]:
                self.assertEqual(decoded[y,x].tolist(),[(x%32)*255//31,(y%64)*255//63,((x+y)%32)*255//31])
            self.assertEqual(image.size,size)
            self.assertEqual(len(list(Path(folder).glob('*.part'))),0)
            self.assertEqual(json.loads(path.with_suffix('.json').read_text())['source'],'FPGA Ethernet snapshot')
        time.sleep(.05);self.assertTrue(board.completed)

    def test_wrong_complete_frame_checksum_rejected(self):
        size=(64,48);board=MockBoard(self.fixture(size),size,wrong_frame_crc=True);client=self.client(board)
        client.hello(timeout=1)
        with self.assertRaisesRegex(SnapshotError,'整帧校验'):client.capture(timeout=1,retry_interval=.1)

    def test_legacy_ack_is_not_snapshot_capability(self):
        board=MockBoard(b'',(64,48),legacy=True);client=self.client(board)
        with self.assertRaisesRegex(SnapshotError,'未收到板卡抓拍能力'):client.hello(timeout=.3)
        self.assertFalse(client.ready)

    def test_mixed_frames_and_conflicting_duplicates_rejected(self):
        p=Packet(Kind.DATA,7,frame_id=1,index=0,count=2,width=32,height=32,frame_crc=1,payload=b'a'*1024)
        assembler=FrameAssembler(7,(32,32));assembler.add(p);self.assertFalse(assembler.add(p))
        mixed=Packet(Kind.DATA,7,frame_id=2,index=1,count=2,width=32,height=32,frame_crc=1,payload=b'a'*1024)
        with self.assertRaisesRegex(SnapshotError,'混合帧'):assembler.add(mixed)
        conflict=Packet(Kind.DATA,7,frame_id=1,index=0,count=2,width=32,height=32,frame_crc=1,payload=b'b'*1024)
        with self.assertRaisesRegex(SnapshotError,'内容冲突'):assembler.add(conflict)

    def test_truncated_and_bad_payloads_rejected(self):
        packet=encode(Packet(Kind.HELLO,8,payload=b'abcd'))
        for invalid in [packet[:-1],packet[:4],packet[:-1]+b'z']:
            with self.assertRaises(PacketError):decode(invalid)

    def test_missing_data_never_finishes(self):
        assembler=FrameAssembler(9,(32,32))
        assembler.add(Packet(Kind.DATA,9,count=2,width=32,height=32,payload=b'a'*1024))
        self.assertEqual(assembler.missing(),[1])
        with self.assertRaises(SnapshotError):assembler.finish()

    def test_color_channels_and_endianness(self):
        image=rgb565_image(struct.pack('<4H',0xf800,0x07e0,0x001f,0xffff),4,1)
        self.assertEqual(np.asarray(image).reshape(-1,3).tolist(),[[255,0,0],[0,255,0],[0,0,255],[255,255,255]])

if __name__=='__main__':unittest.main(verbosity=2)
