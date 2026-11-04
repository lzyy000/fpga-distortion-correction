import argparse,socket,secrets,time
from datetime import datetime,timezone
from common import *
ERROR={1:'format',2:'CRC',3:'sequence/session',4:'dimensions/arguments',5:'busy/not ready',6:'offset/length',7:'incomplete',8:'command'}
class Link:
    def __init__(self,local,board,port=8080):
        self.s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);self.s.bind((local,port));self.peer=(board,port);self.seq=secrets.randbits(32)
        self.stats={'sent_packets':0,'accepted_commands':0,'packet_crc_retries':0,'ack_timeouts':0};self.events=[];self.stats.update(image_payload_bytes=0,map_payload_bytes=0,accepted_commands_by_type={})
    def call(self,cmd,offset=0,data=b'',timeout=1.5,retries=8):
        msg=packet(self.seq,cmd,offset,data)
        for attempt in range(retries):
            self.s.sendto(msg,self.peer);self.stats['sent_packets']+=1;end=time.monotonic()+timeout;crc_rejected=False
            while time.monotonic()<end:
                self.s.settimeout(max(.001,end-time.monotonic()))
                try:raw,peer=self.s.recvfrom(2048)
                except socket.timeout:break
                if peer!=self.peer:continue
                try:status,a,b=ack(raw,self.seq)
                except ValueError:continue
                # Firmware rejects a bad packet before any writes or sequence advancement.
                # A RUN whole-object CRC error has a=b=0 and must stay fatal.
                if status==2 and a!=b:
                    crc_rejected=True
                    self.events.append({'command':cmd,'offset':offset,'sequence':self.seq,'attempt':attempt+1,'calculated_crc':f'{a:08x}','received_crc':f'{b:08x}'})
                    print(f'Packet CRC rejected: command {cmd}, offset {offset}, attempt {attempt+1}/{retries}; retrying identical packet')
                    if attempt+1<retries:self.stats['packet_crc_retries']+=1;time.sleep(.01)
                    break
                if cmd==10 and status:raise RuntimeError('Old bitstream: download image_undistort_1080p.sbit (V3 1080P BOARD MAP)')
                if status:raise RuntimeError(f'Board rejected command {cmd}: {ERROR.get(status,status)}, arg0={a:08x}, arg1={b:08x}')
                self.seq=(self.seq+1)&0xffffffff;self.stats['accepted_commands']+=1
                kinds=self.stats['accepted_commands_by_type'];kinds[str(cmd)]=kinds.get(str(cmd),0)+1
                if cmd==2:self.stats['image_payload_bytes']+=len(data)
                if cmd==3:self.stats['map_payload_bytes']+=len(data)
                return a,b
            if crc_rejected:continue
            self.stats['ack_timeouts']+=1
            print(f'No ACK for command {cmd}, attempt {attempt+1}/{retries}')
        if crc_rejected:raise RuntimeError(f'Packet CRC rejected after {retries} attempts: command {cmd}, offset {offset}; inspect upload report and Ethernet timing')
        raise TimeoutError('No board ACK. Check UART DDR MMIO OK, Ethernet 1Gbps, local IP, firewall and close NetAssist on UDP8080.')
    def close(self):self.s.close()
def read_image(path,resize=False):
    path=Path(path)
    if path.is_dir():path=path/'source.bin'
    if path.suffix.lower()=='.bin':src=path.read_bytes()
    else:
        # Decode and pack pixels only. No calibration/map/remap on the PC path.
        import numpy as np,cv2
        image=cv2.imread(str(path),cv2.IMREAD_COLOR)
        if image is None:raise ValueError('Cannot decode input image')
        if image.shape[:2]!=(1080,1920):
            if not resize:raise ValueError('Input must be 1920x1080; --resize explicitly permits scaling')
            image=cv2.resize(image,(1920,1080),interpolation=cv2.INTER_AREA)
        p=image.astype(np.uint16)
        pixels=((p[:,:,2]>>3)<<11)|((p[:,:,1]>>2)<<5)|(p[:,:,0]>>3)
        src=pixels.astype('<u2').tobytes()
    if len(src)!=4147200:raise ValueError('Expected 1920x1080 RGB565 image, 4147200 bytes')
    return src

def main():
    p=argparse.ArgumentParser(description='Image-only upload; board computes inverse map and corrected pixels')
    p.add_argument('image',type=Path);p.add_argument('--profile',choices=('radial','identity'),default='radial')
    p.add_argument('--resize',action='store_true');p.add_argument('--local',default='192.168.1.105');p.add_argument('--board',default='192.168.1.11')
    p.add_argument('--wait',type=float,default=3600);p.add_argument('--expected-crc');p.add_argument('--expected-map-crc')
    p.add_argument('--require-board-revision',type=int,default=0,help='Require this board capability revision or newer')
    p.add_argument('--require-map-ready',action='store_true',help='Measure reuse only; reject a map that is not ready before image upload')
    p.add_argument('--poll-interval',type=float,default=.5,help='Seconds between processing status checks; minimum 0.01')
    a=p.parse_args()
    if a.poll_interval<.01:p.error('--poll-interval must be at least 0.01 seconds')
    prepare_started=time.monotonic();src=read_image(a.image,a.resize);prepare_seconds=time.monotonic()-prepare_started
    profile=1 if a.profile=='radial' else 0
    link=Link(a.local,a.board);success=False;failure=None;map_crc=None;actual=None;elapsed=None;map_wait=None;crc_match=None
    started=time.monotonic()
    upload_started=upload_finished=run_started=display_done=crc_started=crc_done=None
    previous_incomplete_query=None;completion_window=None;busy_observed=False;reuse_verified=False
    timings={'input_preparation_seconds':prepare_seconds,'processing_poll_interval_seconds':a.poll_interval}
    try:
        version,revision=link.call(10)
        if revision<a.require_board_revision:raise RuntimeError(f'Board revision {revision} is older than required {a.require_board_revision}; download the new cached DDR bitstream')
        if version!=0x424d5033:raise RuntimeError('Wrong bitstream: download image_undistort_1080p.sbit (V3 1080P BOARD MAP)')
        link.call(1,data=struct.pack('<IIII',1920,1080,crc(src),profile))
        if a.require_map_ready:
            flags,_=link.call(5)
            if flags&64:raise RuntimeError('Display DDR line overrun before repeat test')
            if not(flags&128) or flags&256:
                raise RuntimeError('Repeat test cancelled BEFORE image upload: board map is not ready. Wait for the first run and keep the same profile/power.')
            if flags&2:raise RuntimeError('Previous frame is still processing; wait for it to finish')
            before_crc,pixels=link.call(7)
            if pixels!=2073600:raise RuntimeError('Existing map size differs')
            if a.expected_map_crc and before_crc!=int(a.expected_map_crc,16):raise RuntimeError('Existing board map CRC differs')
            reuse_verified=True
            print(f'REUSE confirmed BEFORE upload: board map CRC={before_crc:08x}; pixels={pixels}',flush=True)
        upload_started=time.monotonic()
        for off in range(0,len(src),1024):
            count,_=link.call(2,off,src[off:off+1024])
            if count!=min(off+1024,len(src)):raise RuntimeError('Board image byte count differs')
            if off%(1024*100)==0 or count==len(src):print(f'Image: {count}/{len(src)} bytes',flush=True)
        upload_finished=time.monotonic()
        timings['image_upload_seconds']=upload_finished-upload_started
        print(f"TIME image upload: {timings['image_upload_seconds']:.3f}s",flush=True)
        print('Image complete. Waiting for BOARD-generated map; no map payload was sent.',flush=True)
        wait_start=time.monotonic();deadline=wait_start+a.wait;previous=-1
        while True:
            flags,_=link.call(5)
            if flags&64:raise RuntimeError('Display DDR line overrun; inspect UART and timing')
            if flags&128 and not flags&256:break
            if time.monotonic()>deadline:raise TimeoutError(f'Board map generation timeout, flags={flags:03x}')
            seconds=int(time.monotonic()-wait_start)
            if seconds//5!=previous:print(f'Board map generating: waiting {seconds}s',flush=True);previous=seconds//5
            time.sleep(.5)
        map_wait=time.monotonic()-wait_start
        map_crc,pixels=link.call(7)
        if pixels!=2073600:raise RuntimeError('Board map size differs')
        if a.expected_map_crc and map_crc!=int(a.expected_map_crc,16):raise RuntimeError(f'Board map CRC differs: {map_crc:08x}')
        print(f'BOARD map ready: CRC={map_crc:08x}; pixels={pixels}; host map bytes=0',flush=True)
        if reuse_verified and map_crc!=before_crc:raise RuntimeError('Board map changed during repeat test')
        timings['map_wait_after_upload_seconds']=map_wait
        timings['map_check_after_upload_seconds']=time.monotonic()-upload_finished
        run_started=time.monotonic();link.call(4);deadline=time.monotonic()+a.wait
        while True:
            query_started=time.monotonic();flags,_=link.call(5);query_finished=time.monotonic()
            if flags&64:raise RuntimeError('Display DDR line overrun')
            busy_observed=busy_observed or bool(flags&2)
            if flags&4 and not flags&2:
                display_done=query_finished
                completion_window=display_done-(previous_incomplete_query if previous_incomplete_query is not None else run_started)
                break
            previous_incomplete_query=query_started
            if time.monotonic()>deadline:raise TimeoutError(f'Processing timeout, flags={flags:03x}')
            time.sleep(a.poll_interval)
        timings['run_to_display_commit_observed_seconds']=display_done-run_started
        timings['upload_to_display_commit_observed_seconds']=display_done-upload_started
        timings['display_completion_poll_window_seconds']=completion_window
        print(f"TIME upload -> display commit observed: {timings['upload_to_display_commit_observed_seconds']:.3f}s",flush=True)
        print(f"TIME RUN -> display commit observed: {timings['run_to_display_commit_observed_seconds']:.3f}s; polling window={completion_window:.3f}s",flush=True)
        crc_started=time.monotonic();actual,pixels=link.call(6,timeout=600,retries=2);crc_done=time.monotonic()
        timings['result_crc_query_seconds']=crc_done-crc_started
        print(f"TIME result CRC query (after display): {timings['result_crc_query_seconds']:.3f}s",flush=True)
        if pixels!=2073600:raise RuntimeError('Board result size differs')
        if a.expected_crc:
            crc_match=actual==int(a.expected_crc,16)
            if not crc_match:raise RuntimeError(f'FPGA result CRC differs: actual={actual:08x}, expected={a.expected_crc}')
        elapsed=time.monotonic()-started
        label='FPGA pixel CRC PASS' if crc_match else 'FPGA result CRC'
        print(f'{label}: {actual:08x}; {elapsed:.1f}s. BOARD calculated map + pixels. HDMI: original left, corrected right; 960x540 previews, full 1920x1080 processing.',flush=True)
        success=True
    except Exception as e:
        failure=str(e);raise
    finally:
        link.close()
        report={'mode':'loopback_mock' if a.board.startswith('127.') else 'board_image_only_upload',
                'timestamp':datetime.now(timezone.utc).isoformat(),'image':str(a.image.resolve()),'profile':a.profile,
                'local':a.local,'board':a.board,'success':success,'error':failure,'source_bytes':len(src),
                'map_payload_bytes':0,'map_origin':'board RV32 fixed-point generator','result_origin':'board RTL bilinear engine',
                'map_crc':None if map_crc is None else f'{map_crc:08x}',
                'result_crc':None if actual is None else f'{actual:08x}',
                'reference_crc_matched':crc_match,'elapsed_seconds':elapsed,'map_wait_seconds_after_upload':map_wait,
                'statistics':link.stats,'packet_crc_events':link.events,
                'board_revision':locals().get('revision'),'timing':timings,'map_reuse_verified_before_upload':reuse_verified,'engine_busy_observed':busy_observed,
                'display_timing_method':'PC monotonic clock: first source packet send to board DONE status response; DONE follows frame-bank commit, not optical screen measurement'}
        reports=ROOT/'reports';reports.mkdir(exist_ok=True)
        filename='image_only_upload_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'.json'
        encoded=json.dumps(report,indent=2)
        (reports/filename).write_text(encoded,encoding='utf-8');(reports/'last_image_only_upload.json').write_text(encoded,encoding='utf-8')
        if a.require_map_ready and not a.board.startswith('127.'):
            (reports/'last_repeat_frame_timing.json').write_text(encoded,encoding='utf-8')
        print(f"Transfer: image bytes={link.stats['image_payload_bytes']}, map bytes={link.stats['map_payload_bytes']}, CRC retries={link.stats['packet_crc_retries']}, ACK timeouts={link.stats['ack_timeouts']}; report: {reports/filename}",flush=True)

if __name__=='__main__':
    try:main()
    except (OSError,ValueError,RuntimeError,TimeoutError) as e:print(f'ERROR: {e}');sys.exit(1)
