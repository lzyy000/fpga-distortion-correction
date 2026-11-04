"""Read ModelSim VCD, including vector signals split into individual bits."""
from pathlib import Path
from bisect import bisect_right
import json,re,hashlib

HERE=Path(__file__).resolve().parent
class VCD:
    def __init__(self,path):
        self.signals={};self.times={};self.values={};stack=[];header=True;t=0
        with Path(path).open(encoding='ascii') as f:
            for line in f:
                s=line.strip()
                if not s:continue
                if header:
                    p=s.split()
                    if p[0]=='$scope':stack.append(p[2])
                    elif p[0]=='$upscope':stack.pop()
                    elif p[0]=='$var':
                        name='.'.join(stack[1:]+[p[4]]);code=p[3];width=int(p[2]);shift=0
                        if p[5].startswith('['):shift=int(p[5].strip('[]').split(':')[-1])
                        self.signals.setdefault(name,[]).append((code,shift,width))
                        self.times.setdefault(code,[]);self.values.setdefault(code,[])
                    elif p[0]=='$enddefinitions':header=False
                    continue
                if s[0]=='#':t=int(s[1:]);continue
                if s[0] in 'bB':value,code=s[1:].split()
                elif s[0] in '01xXzZ':value,code=s[0],s[1:]
                else:continue
                if code not in self.times:continue
                n=None if any(c in value.lower() for c in 'xz') else int(value,2)
                ts,vs=self.times[code],self.values[code]
                if ts and ts[-1]==t:vs[-1]=n
                elif not ts or vs[-1]!=n:ts.append(t);vs.append(n)
    def at(self,name,t):
        out=0
        for c,shift,width in self.signals[name]:
            idx=bisect_right(self.times[c],t)-1
            if idx<0 or self.values[c][idx] is None:return None
            out|=self.values[c][idx]<<shift
        return out
    def rising(self,name):
        c,shift,width=self.signals[name][0];assert len(self.signals[name])==1 and width==1
        return [t for t,v in zip(self.times[c],self.values[c]) if v==1]

def interp(p,fx,fy):
    out=0
    for shift,mask in [(11,31),(5,63),(0,31)]:
        a,b,c,d=[(x>>shift)&mask for x in p]
        n=((a*(256-fx)+b*fx)*(256-fy)+(c*(256-fx)+d*fx)*fy+32768)>>16
        out|=n<<shift
    return out

r=VCD(HERE/'render_run/render_validation.vcd')
samples=[t for t in r.rising('clk') if r.at('dut.qv',t)==1]
for t in samples:
    expected=interp([r.at('dut.'+p,t) for p in ['p00','p10','p01','p11']],r.at('dut.fx',t),r.at('dut.fy',t))
    assert r.at('dut.vv',t+16000)==1 and r.at('dut.interpolated_pixel',t+16000)==expected,(t,expected)
assert len(samples)==49152
c=VCD(HERE/'cache32_run/cache32_validation.vcd')
handshake=next(t for t in c.rising('clk') if c.at('req',t-1)==1 and c.at('accept',t-1)==1 and c.at('write',t-1)==0 and 0x01000000<=c.at('addr',t-1)<0x03000000)
first_valid=next(t for t in c.rising('valid') if t>handshake)
registered=next(t for t in c.rising('dut.cache_read_valid') if t>handshake)
assert registered-first_valid==8000 and c.at('trace_cache_data0',registered)==c.at('trace_rdata0',first_valid)
m=VCD(HERE/'manager_run/manager_validation.vcd')
ready=3288000;start=3292000
assert m.at('ready',ready-1)==0 and m.at('ready',ready)==1
assert m.at('trace_state0',ready-1)==2 and m.at('trace_state0',start)==3 and m.at('ps',start)==1 and m.at('pe',start)==1 and m.at('eis',start)==0
result={'timescale':'1ps','data_source':'ModelSim Version 10.5b VCD',
 'render':{'valid_samples':len(samples),'bilinear_errors':0,'two_cycle_delay_errors':0,'first_quad_ns':samples[0]/1000,'first_output_ns':(samples[0]+16000)/1000,'first_output_rgb565':f'{r.at("dut.interpolated_pixel",samples[0]+16000):04X}','screenshot_window_ns':[6032,6128]},
 'cache32':{'source_handshake_ns':handshake/1000,'requested_beats':c.at('beats',handshake-1),'source_address':f'{c.at("addr",handshake-1):08X}','return_valid_ns':first_valid/1000,'registered_valid_ns':registered/1000,'register_delay_ns':8,'screenshot_window_ns':[2988,3124]},
 'manager':{'slot':0,'parameter_ready_ns':ready/1000,'process_start_ns':start/1000,'captured_eis_mode_retained':True,'screenshot_window_ns':[3184,3412]}}
(HERE/'r22_wave_window_verification.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(result,ensure_ascii=False,indent=2))
