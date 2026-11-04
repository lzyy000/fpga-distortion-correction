/* R8 full-resolution RAW8 -> FPGA bilinear RGB565, original wires. */
typedef unsigned int u32;typedef unsigned char u8;
#define REG(a) (*(volatile u32 *)(a))
#define UART 0x8010u
#define CTRL 0xb000u
#define GPIO 0xaff0u
#define PINS 0xaff4u
#define MSEC 0x8040u
#ifndef CAMERA_DENOISE_CONFIG
#define CAMERA_DENOISE_CONFIG 3u
#endif
static u32 gpio=8,nack_phase=0,active_readback_ok=0;
#include "eis/telemetry_tx.h"
static void puts_(const char*s){while(*s)putc_(*s++);}
static void hex(u32 x){const char*d="0123456789ABCDEF";for(int i=7;i>=0;i--)putc_(d[(x>>(i*4))&15]);}
static void dec(u32 x){char b[11];unsigned n=0;do{b[n++]=(char)('0'+x%10);x/=10;}while(x);while(n)putc_(b[--n]);}
static u32 cycle(void){u32 v;__asm__ volatile("rdcycle %0":"=r"(v));return v;}
static void delay_us(u32 n){u32 t=cycle();while((u32)(cycle()-t)<n*27u){}}
static void delay_ms(u32 n){u32 t=REG(MSEC);while((u32)(REG(MSEC)-t)<n){}}
static void out(u32 v){gpio=v;REG(GPIO)=v;delay_us(5);}
static void sda(int low){out((gpio&~2u)|(low?2u:0u));}
static void scl(int low){out((gpio&~1u)|(low?1u:0u));}
static void fail(const char*s,u32 a){puts_(s);hex(a);puts_("\r\n");tx_poll();out(8);REG(0x8020u)=128;for(;;){}}
static void high(void){
 scl(0);u32 t=REG(MSEC);
 while(!(REG(PINS)&2)){if(REG(MSEC)-t>2)fail("SCCB SCL stuck at ",REG(PINS));}
}
static void start(void){sda(0);high();sda(1);scl(1);}
static void stop(void){sda(1);high();sda(0);}
static int send(u8 x){
 for(unsigned i=0;i<8;i++){sda(!(x&0x80));high();scl(1);x<<=1;}
 sda(0);high();int ack=!(REG(PINS)&1);scl(1);return ack;
}
static u8 receive(void){
 u8 x=0;sda(0);
 for(unsigned i=0;i<8;i++){high();x=(u8)((x<<1)|(REG(PINS)&1));scl(1);}
 sda(0);high();scl(1);return x; /* final byte: NACK */
}
static int write_reg(unsigned a,u8 v){
 start();int ok=send(0x78)&&send((u8)(a>>8))&&send((u8)a)&&send(v);stop();return ok;
}
static int read_reg(unsigned a,u8*v){
 start();nack_phase=1;if(!send(0x78))goto address_nack;
 nack_phase=2;if(!send((u8)(a>>8)))goto address_nack;
 nack_phase=3;if(!send((u8)a))goto address_nack;
 stop();delay_us(20);
 start();nack_phase=4;int ok=send(0x79);if(ok)*v=receive();stop();
 if(ok){nack_phase=0;}
 return ok;
 address_nack:stop();return 0;
}
#include "camera_regs.h"
static void must_write(unsigned a,u8 v){if(!write_reg(a,v))fail("SCCB NACK register=",a);}
static void verify(unsigned a,u8 expected){
 u8 actual=0;if(!read_reg(a,&actual))fail("SCCB READ NACK register=",a);
 if(actual!=expected){puts_("READBACK expected=");hex(expected);puts_(" actual=");hex(actual);fail(" register=",a);}
 puts_("CFG register=");hex(a);puts_(" value=");hex(actual);puts_("\r\n");tx_poll();
}
/* Active SCCB read diagnostics are distinct from mandatory standby mode checks.
 * An unacknowledged read is logged and retried; it cannot suppress DVP telemetry.
 * A positively read reset/standby or MIPI-only mode remains a hard failure. */
static int probe_stream(unsigned address){
 u8 value=0;unsigned trial;
 for(trial=1;trial<=3;trial++){
  if(read_reg(address,&value))break;
  puts_("STREAM NACK register=");hex(address);puts_(" phase=");dec(nack_phase);
  puts_(" attempt=");dec(trial);puts_(" pins=");hex(REG(PINS));puts_(" gpio=");hex(REG(GPIO));puts_("\r\n");tx_poll();
  if(trial<3)delay_ms(20);
 }
 if(trial>3){puts_("WARN ACTIVE SCCB READ UNVERIFIED register=");hex(address);puts_("; DVP diagnostics continue\r\n");return 0;}
 puts_("STREAM READ register=");hex(address);puts_(" value=");hex(value);puts_("\r\n");tx_poll();
 if((address==0x3008&&(value&0xc0))||(address==0x300e&&(value&4)))fail("STREAM MODE NOT READY register=",address);
 return 1;
}
#include "eis/dynamic_control.h"
#include "snapshot_service_r22.h"
#include "camera_r22_tuning.h"
int main(void){
 REG(0x8000u)=232;
 puts_("\r\n100Pro+ ATK OV1 1920x1080 RAW8->RGB565 TARGET29.977fps | HDMI1080p60 REPEAT | DVP R22 HOST MODES FISHEYE RAW-LEFT SPLIT NIGHT SNAPSHOT PACKEDMAP32 RAW74 CNP1 DRIVE2 VFLIP R13NET RXSTEP247\r\n");
 if(REG(0x8050u)!=0x52563332u)fail("CPU ID=",REG(0x8050u));
 /* GPIO: SCL-low, SDA-low, RESETn, PWDN, acquisition-configured. */
 out(8);delay_ms(10);out(0);delay_ms(2);out(4);delay_ms(25);
 u8 hi=0,lo=0;if(!read_reg(0x300a,&hi)||!read_reg(0x300b,&lo))fail("OV5640 ID read failed, pins=",REG(PINS));
 u32 id=((u32)hi<<8)|lo;puts_("OV1 ID=");hex(id);puts_("\r\n");tx_poll();if(id!=0x5640)fail("OV1 ID mismatch=",id);
 for(unsigned i=0;i<sizeof(camera_regs)/sizeof(camera_regs[0]);i++){
  must_write(camera_regs[i].address,camera_regs[i].value);
  if(camera_regs[i].address==0x3008&&camera_regs[i].value==0x82)delay_ms(5);
 }
 /* KEY1 now selects corrected video; sensor pad drive stays at calibrated 2x. */
 u8 drive=0;if(!read_reg(0x302c,&drive))fail("PAD drive read NACK=",0x302c);
 drive=(drive&0x3fu)|0x40u;
 must_write(0x302c,drive);verify(0x302c,drive);
 puts_("DIAG MODE nominal_camera_fps_milli=29977 assumed_pclk_khz=74400 RAW8_BGGR=1 filter_clocks=16 pad_302c=");hex(drive);
 puts_(" HDMI=1080p60 repeat; falling-IO direct-clock; host controls correction/split/denoise/night/ghe; KEY0 resets\r\n");
 u8 night;if(!read_reg(0x3a00,&night))fail("AEC read NACK=",0x3a00);
 must_write(0x3a00,night&~4u); /* no dark-scene frame-rate extension */
 /* Verify geometry, timing, DVP polarity and byte order before streaming. */
 static const unsigned short addr[]={0x3034,0x3035,0x3036,0x3037,0x3108,0x3808,0x3809,0x380a,0x380b,0x380c,0x380d,0x380e,0x380f,0x4300,0x501f,0x4740,0x460b,0x460c,0x3824,0x3612,0x3820,0x3821};
 static const u8 expected[]={0x1a,0x11,0x5d,0x13,0x01,0x07,0x80,0x04,0x38,0x08,0xc0,0x04,0x54,0x00,0x03,0x00,0x37,0x22,0x02,0x2b,0x46,0x00};
 for(unsigned i=0;i<sizeof(expected);i++){
  u8 value=expected[i];
  verify(addr[i],value);
 }
 puts_("OV1 CONFIG READBACK OK; night-mode extension disabled; fallback bars until complete frame\r\n");
 puts_("ORIENTATION VFLIP=1 HMIRROR=0; 3820=46 3821=00; full-frame/new-frame-rate acceptance required\r\n");
 while(!(REG(CTRL)&1)){}
 volatile u32*t=(volatile u32*)0x10f00000u;
 for(u32 i=0;i<16;i++)t[i]=0x12345678u^(i*0x10203u);
 for(u32 i=0;i<16;i++)if(t[i]!=(0x12345678u^(i*0x10203u)))fail("DDR SELFTEST word=",i);
 ((volatile u8*)t)[5]=0x3c;if(t[1]!=0x12353c7bu)fail("DDR BYTE MASK=",t[1]);
 /* Enable DVP monitoring before waking the sensor, independently of active readback. */
 REG(CTRL+216)=256;REG(CTRL+220)=256;REG(CTRL+236)=256;REG(CTRL+228)=0;
 REG(CTRL+180)=CAMERA_DENOISE_CONFIG;
 if(REG(CTRL+180)!=CAMERA_DENOISE_CONFIG)fail("DENOISE CONFIG=",REG(CTRL+180));
 puts_("DENOISE CONFIG medium spatial5x5=1 temporal motion-adaptive=1 config=");hex(REG(CTRL+180));puts_(" host toggle; default OFF; history warm-up one frame\r\n");
 out(20);puts_("DDR OK; DVP MONITOR ENABLED; starting sensor stream\r\n");
 must_write(0x3008,0x02);delay_ms(300);
 int stream_ok=probe_stream(0x3008);stream_ok=probe_stream(0x300e)&&stream_ok;
 active_readback_ok=(u32)stream_ok;
 if(stream_ok)puts_("OV1 STREAM MODE READBACK OK\r\n");
 else {u8 id=0;int ok=read_reg(0x300a,&id);puts_("ACTIVE ID PROBE ack=");dec(ok);puts_(" value=");hex(id);puts_(" phase=");dec(nack_phase);puts_("\r\n");tx_poll();}
 puts_("DVP BOOT flags=");hex(REG(CTRL));puts_(" ticks256=");dec(REG(CTRL+76));puts_(" sync_edges=");hex(REG(CTRL+80));
 puts_(" line=");hex(REG(CTRL+84));puts_(" geometry=");hex(REG(CTRL+40));puts_("\r\n");tx_poll();
 REG(CTRL)=1;puts_("RAW8 CAPTURE ENABLED (1920 raw bytes/line -> 1920 RGB565 pixels/line; complete frames only)\r\n");
 puts_("VIEW KEY0=RESET; HOST corrected/split/denoise/night/ghe/eis; SPLIT LEFT PRISTINE RIGHT PROCESSED; ALL DEFAULT OFF\r\n");
 u32 last_ms=REG(MSEC),last_sensor=REG(CTRL+72),last_cap=REG(CTRL+4),last_disp=REG(CTRL+12),last_drop=REG(CTRL+16);
 puts_("R16 R13NET UART n=read-only state; PLL and RXSTEP247 match frozen R13\r\n");
 u32 last_hdmi=REG(CTRL+172);
 u32 last_probe_ticks=REG(CTRL+152);
 u32 last_raw_g=REG(CTRL+136),last_raw_b=REG(CTRL+140);
 u32 last_ticks=REG(CTRL+76),last_edges=REG(CTRL+80),last_pin_edges=REG(CTRL+96),last_glitches=REG(CTRL+108);
 tx_async=1;
 for(;;){
  tx_poll();dynamic_poll();
  u32 now=REG(MSEC);
  tuning_service();
  snapshot_service(now);tx_poll();
  if(now-last_ms>=1000){
   tuning_reply(240);tx_poll();
   net_diag_print();
   puts_("GHE status=");hex(REG(CTRL+240));puts_(" strength_q8=");dec(REG(CTRL+236));puts_(" frames=");dec(REG(CTRL+244));puts_(" dropped_stats=");dec(REG(CTRL+248));puts_(" updates=");dec(REG(CTRL+252));puts_("\r\n");tx_poll();
   puts_("NIGHT status=");hex(REG(CTRL+204));puts_(" frames=");hex(REG(CTRL+208));puts_(" sum_v=");hex(REG(CTRL+212));puts_("\r\n");tx_poll();
   puts_("DENOISE config=");hex(REG(CTRL+180));puts_(" status=");u32 ds=REG(CTRL+184);hex(ds);
   puts_(" requested=");dec((ds>>5)&1u);puts_(" active=");dec((ds>>6)&1u);
   puts_(" fused_pixels=");dec(REG(CTRL+188));puts_(" total_pixels=");dec(REG(CTRL+192));
   puts_(" history_frames=");dec(REG(CTRL+196));puts_("\r\n");tx_poll();
   puts_("CORRECT map_flags=");hex(REG(CTRL+156));puts_(" view=");hex(REG(CTRL+160));puts_(" processed=");dec(REG(CTRL+8));puts_(" map_row=");dec((REG(CTRL+168)>>12)&4095u);puts_(" map_ms=");dec(REG(CTRL+164)/125000u);puts_(" process_us=");dec(REG(CTRL+20)/125u);puts_("\r\n");tx_poll();
   u32 flags=REG(CTRL),sensor=REG(CTRL+72),cap=REG(CTRL+4),disp=REG(CTRL+12),drop=REG(CTRL+16),fifo=REG(CTRL+48);
   puts_("CAM dt_ms=");dec(now-last_ms);puts_(" sensor=");dec(sensor-last_sensor);puts_(" cap=");dec(cap-last_cap);
   puts_(" display_new=");dec(disp-last_disp);puts_(" skipped=");dec(drop-last_drop);puts_(" flags=");hex(flags);
   puts_(" fifo_peak=");dec((fifo>>10)&1023);puts_("\r\n");tx_poll();
   u32 hdmi=REG(CTRL+172);
   puts_("HDMI dt_ms=");dec(now-last_ms);puts_(" refresh=");dec(hdmi-last_hdmi);
   puts_(" pipeline=");hex(REG(CTRL+176));puts_(" buffers=4\r\n");last_hdmi=hdmi;
   if(flags&0xc0){puts_("FAULT reason=");hex(REG(CTRL+32));puts_(" pixels=");dec(REG(CTRL+36));puts_(" geometry=");hex(REG(CTRL+40));puts_("\r\n");tx_poll();}
   u32 ticks=REG(CTRL+76),edges=REG(CTRL+80),line=REG(CTRL+84),geom=REG(CTRL+40);
   puts_("DVP dt_ms=");dec(now-last_ms);puts_(" pclk_khz=");dec((((ticks-last_ticks)&0xffffffu)*256u)/(now-last_ms));
   puts_(" vs_edges=");dec(((edges>>16)-(last_edges>>16))&65535u);
   puts_(" href_edges=");dec((edges-last_edges)&65535u);
   puts_(" last_line_bytes=");dec(line&8191u);puts_(" rows_at_vs=");dec((geom>>13)&8191u);
   puts_(" pixels_at_vs=");dec(geom&8191u);puts_(" levels=");hex(line>>13);
   puts_(" gpio=");hex(REG(GPIO));puts_("\r\n");tx_poll();
   u32 probe=REG(CTRL+152);
   puts_("CLK hard_pclk_khz=");dec((((probe-last_probe_ticks)&0xffffffu)*256u)/(now-last_ms));puts_(" divided_by=2 clock_delay=BYPASS\r\n");
   last_probe_ticks=probe;
   u32 pin_edges=REG(CTRL+96),pin_high=REG(CTRL+88),pin_period=REG(CTRL+92),diag=REG(CTRL+100);
   puts_("REF dt_ms=");dec(now-last_ms);puts_(" href_high_core_cycles=");dec(pin_high);
   puts_(" href_period_core_cycles=");dec(pin_period);
   puts_(" vs_edges=");dec(((pin_edges>>16)-(last_pin_edges>>16))&65535u);
   puts_(" href_edges=");dec((pin_edges-last_pin_edges)&65535u);
   puts_(" valid=");hex(diag>>1);puts_(" display_source=");puts_((diag&1)?"BARS":"CAMERA");
   puts_(" active_sccb_verified=");dec(active_readback_ok);puts_("\r\n");tx_poll();
   u32 glitches=REG(CTRL+108),first_geom=REG(CTRL+104);
   puts_("SYNC rejected_vs=");dec(((glitches>>16)-(last_glitches>>16))&65535u);
   puts_(" rejected_href=");dec((glitches-last_glitches)&65535u);
   puts_(" first_fault_rows=");dec((first_geom>>13)&8191u);puts_(" first_fault_line_pixels=");dec(first_geom&8191u);puts_("\r\n");tx_poll();
   u32 raw_g=REG(CTRL+136),raw_b=REG(CTRL+140),raw_geom=REG(CTRL+144),raw_error=REG(CTRL+148);
   puts_("RAW good_new=");dec(raw_g-last_raw_g);puts_(" bad_new=");dec(raw_b-last_raw_b);puts_(" good_total=");dec(raw_g);puts_(" bad_total=");dec(raw_b);
   puts_(" rows=");dec((raw_geom>>13)&8191u);puts_(" tail_bytes=");dec(raw_geom&8191u);
   puts_(" first_reason=");dec(raw_error>>28);puts_(" first_row=");dec((raw_error>>12)&4095u);
   puts_(" first_bytes=");dec(raw_error&4095u);puts_(" state=");hex((raw_error>>24)&15u);puts_("\r\n");tx_poll();
   u32 recovery=REG(CTRL+116),rg=REG(CTRL+124);
   puts_("RECOVER total=");dec(recovery);puts_(" aborted=");dec(REG(CTRL+112));
   puts_(" status=");hex(REG(CTRL+120));puts_(" last_reason=");hex(REG(CTRL+132));
   puts_(" last_rows=");dec((rg>>13)&8191u);puts_(" last_line_bytes=");dec(rg&8191u);
   puts_(" last_pixels=");dec(REG(CTRL+128));puts_("\r\n");tx_poll();
   last_raw_g=raw_g;last_raw_b=raw_b;
   last_glitches=glitches;
   last_pin_edges=pin_edges;
   last_ticks=ticks;last_edges=edges;
   last_ms=now;last_sensor=sensor;last_cap=cap;last_disp=disp;last_drop=drop;
   REG(0x8020u)=2|((flags&32)?1:0)|((cap&1)<<3)|((disp&1)<<4)|((flags&0xc0)?128:0);
  }
 }
}
