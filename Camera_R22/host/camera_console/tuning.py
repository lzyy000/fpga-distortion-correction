"""Acknowledged legacy UART controls plus isolated R22 EIS parameter frames."""
import re
import struct
MODE_DEFS=(('correct','畸变矫正',1),('split','双视窗',2),('denoise','滤波',4),
           ('night','夜景',8),('ghe','全局直方图均衡化',16),('eis','IMU 小抖动防抖',32),('fisheye','鱼眼畸变处理',64),('rotation','旋转稳像',128))
MODE_BITS={key:bit for key,_,bit in MODE_DEFS}
EIS_DEFAULTS=dict(zoom_milli=1180,tau_ms=250,yaw_tau_ms=500,rs_milli=1000,frame_offset_us=0,imu_delay_us=0)
ROTATION_DEFAULTS=dict(rot_zoom_milli=1160,rot_max_zoom_milli=2400,rot_tau_ms=750,rot_horizon=1,rot_rs_milli=0)
FIELDS={'night','denoise','night_q8','denoise_q8','night_on','denoise_on'}
def ghe_low_command(percent):
    low=percent&15
    return 229+low if low<11 else 250+low-11

def eis_packet(op,seq,values):
    payload=struct.pack('<'+'f'*len(values),*values)
    frame=bytes([255,69,op,len(payload),seq])+payload
    return frame+bytes([sum(frame)&255])

def signed_hex(value):
    v=int(value,16)
    return v-0x100000000 if v&0x80000000 else v

class StrengthControl:
    TIMEOUT=1.5
    def __init__(self,emit):
        self.emit=emit;self.ready=False;self.failed=False;self.pending={};self.flight=None
        self.last_query=-10.;self.confirmed={};self.version=None
        self.confirmed_modes=None;self.applied_modes=None;self.mode_target=None;self.mode_changed=0.
        self.ghe_supported=False;self.eis_supported=False;self.fisheye_supported=False;self.eis_confirmed={};self.eis_pending={}
        self.rotation_supported=False;self.rotation_confirmed={}
        self.ghe_transaction=None;self.flight_context=None;self.flight_packet=None;self.sequence=0

    def request(self,key,percent,now):
        if key not in ('night','denoise','ghe') or not 0<=int(percent)<=100:raise ValueError('invalid strength')
        if key=='ghe' and not self.ghe_supported:return False
        if self.ready:self.pending[key]=(int(percent),now)
        return self.ready

    def request_mode(self,key,enabled,now):
        if key not in MODE_BITS:raise ValueError('invalid mode')
        if not self.ready or self.version not in (21,22):return False
        if key=='ghe' and not self.ghe_supported or key=='eis' and not self.eis_supported or key=='fisheye' and not self.fisheye_supported or key=='rotation' and not self.rotation_supported:return False
        if self.mode_target is None:self.mode_target=self.confirmed_modes
        bit=MODE_BITS[key]
        self.mode_target=(self.mode_target|bit) if enabled else (self.mode_target&~bit)
        if enabled and key=='fisheye':self.mode_target&=~MODE_BITS['correct']
        if enabled and key=='correct':self.mode_target&=~MODE_BITS['fisheye']
        if enabled and key=='rotation':self.mode_target&=~MODE_BITS['eis']
        if enabled and key=='eis':self.mode_target&=~MODE_BITS['rotation']
        self.mode_changed=now;return True

    def request_eis(self,values,now):
        if not self.ready or not self.eis_supported:return False
        p=dict(self.eis_confirmed)
        if isinstance(self.flight_context,tuple) and self.flight_context[0]=='eis' and self.flight:p.update(self.flight_context[2])
        for target,_ in self.eis_pending.values():p.update(target)
        p.update(values)
        for key,lo,hi in [('zoom_milli',1050,1600),('tau_ms',100,1500),('yaw_tau_ms',100,1500),
                          ('rs_milli',0,1000),('frame_offset_us',-50000,50000),('imu_delay_us',-50000,50000)]:
            if key not in p or not isinstance(p[key],int) or not lo<=p[key]<=hi:raise ValueError('防抖参数超出范围：'+key)
        groups={8:('zoom_milli','tau_ms'),11:('yaw_tau_ms',),12:('rs_milli',),10:('imu_delay_us','frame_offset_us')}
        for op,keys in groups.items():
            in_flight=(isinstance(self.flight_context,tuple) and self.flight_context[0]=='eis' and self.flight and self.flight_context[1]==op)
            baseline=self.flight_context[2] if in_flight else self.eis_confirmed
            if any(p[k]!=baseline.get(k) for k in keys):
                self.eis_pending[op]=({k:p[k] for k in keys},now)
            else:self.eis_pending.pop(op,None)
        return True

    def request_rotation(self,values,now):
        if not self.ready or not self.rotation_supported:return False
        p=dict(self.rotation_confirmed)
        if isinstance(self.flight_context,tuple) and self.flight_context[0]=='rotation' and self.flight:p.update(self.flight_context[2])
        if 13 in self.eis_pending:p.update(self.eis_pending[13][0])
        p.update(values)
        for key,lo,hi in [('rot_zoom_milli',1050,2500),('rot_max_zoom_milli',1050,3000),('rot_tau_ms',100,3000),('rot_horizon',0,1),('rot_rs_milli',0,1000)]:
            if key not in p or not isinstance(p[key],int) or not lo<=p[key]<=hi:raise ValueError('旋转稳像参数超出范围：'+key)
        if p['rot_max_zoom_milli']<p['rot_zoom_milli']:raise ValueError('最大裁切不能小于基准裁切')
        baseline=self.flight_context[2] if self.flight and isinstance(self.flight_context,tuple) and self.flight_context[0]=='rotation' else self.rotation_confirmed
        if p!=baseline:self.eis_pending[13]=(p,now)
        else:self.eis_pending.pop(13,None)
        return True

    def tick(self,now):
        if self.failed:return None
        if self.flight:
            cmd,sent,tries=self.flight
            if now-sent<self.TIMEOUT:return None
            if tries>=3:
                self.flight=None;self.pending.clear();self.eis_pending.clear();self.ghe_transaction=None
                self.ready=False;self.failed=True
                self.emit('tune_error','板卡未确认参数，请检查位流和串口后重新连接');return None
            self.flight=(cmd,now,tries+1);return self.flight_packet
        cmd=None;context='plain';packet=None
        if self.ready:
            if self.ghe_transaction and self.ghe_transaction[1]=='low':
                cmd=ghe_low_command(self.ghe_transaction[0]);context='ghe_low'
            elif self.version in (21,22) and self.mode_target is not None and self.mode_target!=self.confirmed_modes and now-self.mode_changed>=.15:
                delta=self.mode_target^self.confirmed_modes
                cmd=(112+(self.mode_target&15) if delta&15 else (248 if self.mode_target&16 else 249) if delta&16
                     else 105 if delta&160 and self.mode_target&128 else 101 if delta&160 and self.mode_target&32
                     else 102 if delta&32 else (106 if delta&128 else (103 if self.mode_target&64 else 104)))
            for key,(value,changed) in list(self.pending.items()):
                if cmd is not None:break
                if now-changed>=.15:
                    if self.confirmed.get(key)==value:del self.pending[key];continue
                    if key=='ghe':self.ghe_transaction=(value,'high');cmd=241+(value>>4);context='ghe_high'
                    else:cmd=value+(128 if key=='night' else 0)
            if cmd is None:
                for op,(p,changed) in list(self.eis_pending.items()):
                    if now-changed<.15:continue
                    if all(p[k]==(self.rotation_confirmed if op==13 else self.eis_confirmed).get(k) for k in p):del self.eis_pending[op];continue
                    vals=([0.,0.,p['zoom_milli']/1000,2.4,p['tau_ms']/1000] if op==8 else
                          [p['rot_zoom_milli']/1000,p['rot_max_zoom_milli']/1000,p['rot_tau_ms']/1000,float(p['rot_horizon']),p['rot_rs_milli']/1000] if op==13 else
                          [p['yaw_tau_ms']/1000] if op==11 else [0.,p['rs_milli']/1000] if op==12 else
                          [float(p['imu_delay_us']),float(p['frame_offset_us'])])
                    self.sequence=(self.sequence+1)&255;cmd=0x100|self.sequence
                    packet=eis_packet(op,self.sequence,vals);context=('rotation' if op==13 else 'eis',op,dict(p));break
        if cmd is None and now-self.last_query>=2:cmd=240;self.last_query=now
        if cmd is not None:
            self.flight=(cmd,now,1);self.flight_context=context
            self.flight_packet=packet if packet is not None else bytes([cmd]);return self.flight_packet
        return None

    def receive(self,line):
        m=re.fullmatch(r'TUNE v=(19|20|21|22) cmd=([0-9A-Fa-f]{8}) (.+)',line)
        if not m:return False
        parts=m[3].split();raw={}
        for part in parts:
            if '=' not in part:return False
            k,v=part.split('=',1)
            if k in raw:return False
            raw[k]=v
        if not FIELDS<=raw.keys():return False
        try:
            version=int(m[1]);cmd=int(m[2],16)
            r={k:(signed_hex(v) if k in ('imu_delay_us','frame_offset_us') else int(v)) for k,v in raw.items()}
            n,d,nq,dq,no,do=[r[k] for k in ('night','denoise','night_q8','denoise_q8','night_on','denoise_on')]
            modes=r.get('modes');applied=r.get('applied');supported='ghe' in r;eis=version==22;fish=version==22 and r.get('fisheye_supported')==1
            if (version in (21,22))!=(modes is not None) or supported and version not in (21,22):return False
            rotation=version==22 and r.get('rotation_supported')==1
            limit=255 if rotation else 127 if fish else 63 if eis else 31 if supported else 15
            if modes is not None and (applied is None or not 0<=modes<=limit or not 0<=applied<=limit):return False
            if rotation:
                required=set(ROTATION_DEFAULTS)|{'rotation_on','rot_ready','rot_limit','rot_actual_zoom_milli'}
                if not required<=r.keys() or r['rotation_on']!=bool(modes&128) or r['rot_ready'] not in (0,1) or modes&160==160 or applied&160==160:return False
                for key,lo,hi in [('rot_zoom_milli',1050,2500),('rot_max_zoom_milli',1050,3000),('rot_tau_ms',100,3000),('rot_horizon',0,1),('rot_rs_milli',0,1000)]:
                    if not lo<=r[key]<=hi:return False
                if r['rot_max_zoom_milli']<r['rot_zoom_milli'] or not 1000<=r['rot_actual_zoom_milli']<=3000:return False
            if fish and ('fisheye_on' not in r or r['fisheye_on']!=bool(modes&64) or modes&65==65 or applied&65==65):return False
            if not(0<=n<=100 and 0<=d<=100 and nq==(n*256+50)//100 and dq==(d*256+50)//100 and no in (0,1) and do in (0,1)):return False
            if supported:
                he,hq,he_on,he_ready=[r[k] for k in ('ghe','ghe_q8','ghe_on','ghe_ready')]
                if not(0<=he<=100 and hq==(he*256+50)//100 and he_on==bool(modes&16) and he_ready in (0,1)):return False
            if eis:
                required=set(EIS_DEFAULTS)|{'eis_on','eis_ready','imu_age_ms','readout_us','limit','eis_ok'}
                if not required<=r.keys() or r['eis_on']!=bool(modes&32) or r['eis_ready'] not in (0,1) or r['eis_ok'] not in (0,1):return False
                if not(1050<=r['zoom_milli']<=1600 and 100<=r['tau_ms']<=1500 and 100<=r['yaw_tau_ms']<=1500 and 0<=r['rs_milli']<=1000 and abs(r['frame_offset_us'])<=50000 and abs(r['imu_delay_us'])<=50000):return False
        except (ValueError,KeyError):return False
        if not self.flight or cmd!=self.flight[0]:return False
        context=self.flight_context
        if cmd<=100 and d!=cmd or 128<=cmd<=228 and n!=cmd-128:return False
        if 112<=cmd<=127 and (version not in (21,22) or modes&15!=cmd-112):return False
        if context=='ghe_high':
            if not supported or cmd!=241+(self.ghe_transaction[0]>>4):return False
        elif context=='ghe_low':
            if not supported or cmd!=ghe_low_command(self.ghe_transaction[0]) or he!=self.ghe_transaction[0]:return False
        elif isinstance(context,tuple) and context[0] in ('eis','rotation'):
            if not eis or context[0]=='rotation' and not rotation:return False
            if not r['eis_ok']:
                
                for op in list(self.eis_pending):
                    if (op==13)==(context[0]=='rotation'):self.eis_pending.pop(op,None)
                self.flight=None;self.emit('rotation_error' if context[0]=='rotation' else 'eis_error','板卡拒绝参数，已保留回读值');return True
            if any(r[k]!=v for k,v in context[2].items()):return False
            # A newer slider edit may have arrived while this packet was in flight.
            if self.eis_pending.get(context[1],({},None))[0]==context[2]:self.eis_pending.pop(context[1],None)
        elif cmd in (248,249):
            if not supported or bool(modes&16)!=(cmd==248):return False
        elif cmd in (101,102):
            if not eis or bool(modes&32)!=(cmd==101):return False
        elif cmd in (105,106):
            if not rotation or bool(modes&128)!=(cmd==105):return False
        elif cmd in (103,104):
            if not fish or bool(modes&64)!=(cmd==103):return False
        elif cmd!=240 and not(cmd<=100 or 112<=cmd<=127 or 128<=cmd<=228):return False
        previous_modes=self.confirmed_modes
        first=not self.ready;self.ready=True;self.flight=None;self.version=version
        self.confirmed_modes=modes;self.applied_modes=applied;self.ghe_supported=supported;self.eis_supported=eis;self.fisheye_supported=fish;self.rotation_supported=rotation
        if modes is not None:
            # Merge board changes into bits without an outstanding host edit.
            # A polled key toggle must not be written back to the old host mask.
            if first or self.mode_target is None or previous_modes is None:self.mode_target=modes
            else:
                dirty=self.mode_target^previous_modes
                self.mode_target=(modes&~dirty)|(self.mode_target&dirty)
                for chosen,peer in ((1,64),(64,1),(32,128),(128,32)):
                    if dirty&chosen and self.mode_target&chosen:self.mode_target&=~peer
        if context=='ghe_high':self.ghe_transaction=(self.ghe_transaction[0],'low')
        elif context=='ghe_low':self.ghe_transaction=None
        self.confirmed={'night':n,'denoise':d}
        if supported:self.confirmed['ghe']=he
        if eis:self.eis_confirmed={k:r[k] for k in EIS_DEFAULTS}
        self.rotation_confirmed={k:r[k] for k in ROTATION_DEFAULTS} if rotation else {}
        for key,(value,_) in list(self.pending.items()):
            if key=='ghe' and self.ghe_transaction is not None:continue
            if self.confirmed.get(key)==value:del self.pending[key]
        self.emit('tune_ack',dict(self.confirmed,night_on=bool(no),denoise_on=bool(do),
            ghe_on=bool(he_on) if supported else False,ghe_ready=bool(he_ready) if supported else False,
            ghe_supported=supported,eis_supported=eis,fisheye_supported=fish,rotation_supported=rotation,rotation=dict(r) if rotation else {},eis=dict(r) if eis else {},
            modes=modes,target_modes=self.mode_target,applied=applied,applied_modes=applied,first=first,firmware_version=version))
        return True
