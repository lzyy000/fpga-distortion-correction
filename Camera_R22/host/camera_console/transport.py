"""Versioned UDP snapshot client. This protocol must also be implemented on the FPGA."""
from dataclasses import dataclass
from enum import IntEnum
import json
import secrets
import socket
import struct
import threading
import time
import zlib
import sys

MAGIC = b'CNP1'
VERSION = 1
CHUNK_BYTES = 1024
RGB565_LE = 1
HEADER = struct.Struct('!4sBBH10I')

class Kind(IntEnum):
    HELLO = 1
    HELLO_REPLY = 2
    CAPTURE = 3
    DATA = 4
    END = 5
    MISSING = 6
    CANCEL = 7
    ERROR = 8

class SnapshotError(RuntimeError):
    pass

class PacketError(SnapshotError):
    pass

class Cancelled(SnapshotError):
    pass

@dataclass(frozen=True)
class Packet:
    kind: Kind
    request_id: int
    frame_id: int = 0
    index: int = 0
    count: int = 0
    width: int = 0
    height: int = 0
    pixel_format: int = RGB565_LE
    frame_crc: int = 0
    payload: bytes = b''
    flags: int = 0

def encode(packet):
    if len(packet.payload) > CHUNK_BYTES:
        raise PacketError('数据包超过协议长度')
    return HEADER.pack(MAGIC, VERSION, int(packet.kind), packet.flags, packet.request_id,
                       packet.frame_id, packet.index, packet.count, packet.width,
                       packet.height, packet.pixel_format, len(packet.payload),
                       zlib.crc32(packet.payload), packet.frame_crc) + packet.payload

def decode(data):
    if len(data) < HEADER.size:
        raise PacketError('数据包头不完整')
    magic, version, kind, flags, request, frame, index, count, width, height, fmt, length, crc, frame_crc = HEADER.unpack_from(data)
    payload = data[HEADER.size:]
    if magic != MAGIC or version != VERSION or flags not in (0,1,3,4,5,8,10,12) or flags and kind != int(Kind.DATA):
        raise PacketError('不支持的数据包协议')
    if length != len(payload) or length > CHUNK_BYTES or zlib.crc32(payload) != crc:
        raise PacketError('数据包长度或校验失败')
    try:
        kind = Kind(kind)
    except ValueError as exc:
        raise PacketError('未知消息类型') from exc
    return Packet(kind, request, frame, index, count, width, height, fmt, frame_crc, payload, flags)

class FrameAssembler:
    def __init__(self, request_id, expected_size=(1920, 1080)):
        self.request_id = request_id
        self.expected_size = expected_size
        self.metadata = None
        self.buffer = None
        self.received = set()
        self.duplicates = 0
        self.byte_count = 0

    def add(self, packet):
        if packet.kind != Kind.DATA or packet.request_id != self.request_id:
            return False
        if (packet.width, packet.height) != self.expected_size or packet.pixel_format != RGB565_LE:
            raise SnapshotError('图像尺寸或像素格式与请求不一致')
        if not (0 < packet.width <= 1920 and 0 < packet.height <= 1080):
            raise SnapshotError('图像尺寸超过支持范围')
        total_bytes = packet.width * packet.height * 2
        expected_count = (total_bytes + CHUNK_BYTES - 1) // CHUNK_BYTES
        if packet.count != expected_count or not 0 <= packet.index < expected_count:
            raise SnapshotError('图像分包编号或总数无效')
        start = packet.index * CHUNK_BYTES
        expected_length = min(CHUNK_BYTES, total_bytes - start)
        if len(packet.payload) != expected_length:
            raise SnapshotError('图像分包长度与位置不一致')
        metadata = (packet.frame_id, packet.count, packet.width, packet.height,
                    packet.pixel_format, packet.frame_crc, packet.flags)
        if self.metadata is None:
            self.metadata = metadata
            self.buffer = bytearray(total_bytes)
        elif metadata != self.metadata:
            raise SnapshotError('收到混合帧或变化的图像元数据，已拒绝保存')
        if packet.index in self.received:
            self.duplicates += 1
            if self.buffer[start:start+expected_length] != packet.payload:
                raise SnapshotError('重复分包内容冲突，已拒绝保存')
            return False
        self.buffer[start:start+expected_length] = packet.payload
        self.received.add(packet.index)
        self.byte_count += expected_length
        return True

    @property
    def complete(self):
        return self.metadata is not None and len(self.received) == self.metadata[1]

    def missing(self):
        return [] if self.metadata is None else [i for i in range(self.metadata[1]) if i not in self.received]

    def finish(self):
        if not self.complete:
            raise SnapshotError('图像尚未完整接收')
        if zlib.crc32(self.buffer) != self.metadata[5]:
            raise SnapshotError('整帧校验失败，已拒绝保存')
        return bytes(self.buffer)

class SnapshotClient:
    def __init__(self, local_ip, board_ip, local_port=8080, board_port=8080, expected_size=(1920,1080), interface_index=None):
        socket.inet_aton(local_ip)
        socket.inet_aton(board_ip)
        if not 0 <= local_port <= 65535 or not 1 <= board_port <= 65535:
            raise ValueError('UDP 端口应为 1～65535（本机测试可用 0）')
        self.peer = (board_ip, board_port)
        self.expected_size = expected_size
        self.cancel_event = threading.Event()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8*1024*1024)
            if interface_index is not None:
                if not 1 <= interface_index < 1 << 24:
                    raise ValueError('有线网卡接口编号无效')
                if sys.platform != 'win32':
                    raise ValueError('指定发送网卡当前仅支持 Windows')
                # Windows IP_UNICAST_IF takes an IF_INDEX in network byte order.
                # Binding a source address alone can still pick a VPN route.
                self.sock.setsockopt(socket.IPPROTO_IP, 31, struct.pack('!I',interface_index))
            self.sock.bind((local_ip, local_port))
            self.sock.settimeout(.15)
        except Exception:
            self.sock.close()
            raise
        self.ready = False
        self.device_info = {}
        self.active_request = None

    def _send(self, packet):
        if self.cancel_event.is_set():
            raise Cancelled('已取消接收')
        self.sock.sendto(encode(packet), self.peer)

    def _read(self, request):
        if self.cancel_event.is_set():
            raise Cancelled('已取消接收')
        try:
            data, peer = self.sock.recvfrom(2048)
        except socket.timeout:
            return None
        if peer != self.peer:
            return None
        try:
            packet = decode(data)
        except PacketError:
            return None
        if packet.request_id != request:
            return None
        if packet.kind == Kind.ERROR:
            raise SnapshotError('板卡报告：' + packet.payload.decode('utf-8', 'replace'))
        return packet

    def hello(self, timeout=4.5):
        request = secrets.randbits(32)
        deadline = time.monotonic() + timeout
        next_send = 0
        while time.monotonic() < deadline:
            if time.monotonic() >= next_send:
                self._send(Packet(Kind.HELLO, request))
                next_send = time.monotonic() + 1
            packet = self._read(request)
            if packet is None or packet.kind != Kind.HELLO_REPLY:
                continue
            try:
                info = json.loads(packet.payload.decode('utf-8'))
            except (ValueError, UnicodeError) as exc:
                raise SnapshotError('板卡能力应答无效') from exc
            if not isinstance(info, dict) or not isinstance(info.get('capabilities'), list) or 'snapshot_rgb565' not in info['capabilities']:
                raise SnapshotError('板卡应答未声明图像抓拍能力')
            if info.get('width') != self.expected_size[0] or info.get('height') != self.expected_size[1] or info.get('pixel_format') != 'RGB565_LE':
                raise SnapshotError('板卡声明的图像尺寸或格式不匹配')
            self.ready = True
            self.device_info = info.copy()
            return info
        raise SnapshotError('未收到板卡抓拍能力应答。请检查板卡复位状态、IP、UDP 端口及网口接收链路。')

    def capture(self, progress=lambda done,total:None, timeout=30, retry_interval=.65):
        if not self.ready:
            raise SnapshotError('请先连接并核验板卡抓拍能力')
        request = secrets.randbits(32)
        self.active_request = (request, 0)
        assembler = FrameAssembler(request, self.expected_size)
        width, height = self.expected_size
        command = Packet(Kind.CAPTURE, request, width=width, height=height)
        self._send(command)
        start = time.monotonic()
        deadline = start + timeout
        next_retry = start + retry_interval
        retry_rounds = 0
        last_progress = start
        while time.monotonic() < deadline:
            packet = self._read(request)
            if packet is not None and packet.kind == Kind.DATA:
                added = assembler.add(packet)
                if assembler.metadata:
                    self.active_request = (request, assembler.metadata[0])
                now = time.monotonic()
                if added:
                    # Request missing packets after an idle gap, not while a frame is still streaming.
                    next_retry = now + retry_interval
                if added and (now-last_progress > .08 or assembler.complete):
                    progress(assembler.byte_count, width*height*2)
                    last_progress = now
                if assembler.complete:
                    pixels = assembler.finish()
                    self._send(Packet(Kind.END,request,frame_id=assembler.metadata[0],frame_crc=assembler.metadata[5]))
                    self.active_request = None
                    return {'pixels':pixels, 'request_id':request, 'frame_id':assembler.metadata[0],
                            'width':width, 'height':height, 'pixel_format':'RGB565_LE',
                            'crc32':f'{assembler.metadata[5]:08x}', 'packets':assembler.metadata[1],
                            'eis_applied':bool(assembler.metadata[6]&1),
                            'lens_applied_to_eis':bool(assembler.metadata[6]&1 and assembler.metadata[6]&2),
                            'rotation_applied':bool(assembler.metadata[6]&8),
                            'lens_applied_to_rotation':bool(assembler.metadata[6]&8 and assembler.metadata[6]&2),
                            'geometry_flags':assembler.metadata[6],
                            'fisheye_applied':bool(assembler.metadata[6]&4),
                            'duplicates':assembler.duplicates, 'retry_rounds':retry_rounds,
                            'seconds':time.monotonic()-start,
                            'firmware':self.device_info.get('firmware','unknown'),
                            'processing':('fpga_fisheye_frame_with_selected_algorithms' if assembler.metadata[6]&4 else 'fpga_rotation_frame_with_selected_algorithms' if assembler.metadata[6]&8 else 'fpga_eis_frame_with_selected_algorithms' if assembler.metadata[6]&1 else 'fpga_frame_ghe_night_follow_host_mode' if 'global_histogram' in self.device_info.get('capabilities',[])
                                          else 'fpga_frame_night_follow_host_mode' if 'host_modes' in self.device_info.get('capabilities',[])
                                          else 'fpga_frame_night_follow_key4' if 'snapshot_night' in self.device_info.get('capabilities',[])
                                          else 'capture_slot_without_night')}
            if time.monotonic() >= next_retry:
                retry_rounds += 1
                if assembler.metadata is None:
                    self._send(command)
                else:
                    missing = assembler.missing()
                    for offset in range(0,len(missing),128):
                        batch = missing[offset:offset+128]
                        payload = struct.pack('!'+str(len(batch))+'I',*batch)
                        self._send(Packet(Kind.MISSING,request,frame_id=assembler.metadata[0],payload=payload))
                next_retry = time.monotonic()+retry_interval
        raise SnapshotError(f'拍照接收超时，收到 {assembler.byte_count:,}/{width*height*2:,} 字节；未保存不完整照片')

    def close(self):
        if self.active_request is not None:
            try:
                request,frame = self.active_request
                self.sock.sendto(encode(Packet(Kind.CANCEL,request,frame_id=frame)),self.peer)
            except OSError:
                pass
            self.active_request = None
        self.ready = False
        self.cancel_event.set()
        self.sock.close()
