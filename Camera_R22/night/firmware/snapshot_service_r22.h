#ifndef SNAPSHOT_SERVICE_H
#define SNAPSHOT_SERVICE_H
/* CNP1 server. Pixel copy/chunk CRC executes in RTL, packet scheduling on RV32. */
#define NETSTAT 0x9000u
#define NETLEN 0x9004u
#define NETREL 0x9008u
#define NETTXLEN 0x9010u
#define NETSEND 0x9014u
#define SNAPCMD 0xb100u
#define SNAPSTAT 0xb104u
#define SNAPFRAME 0xb108u
#define SNAPCRC 0xb10cu
#define SNAPINDEX 0xb110u
#define SNAPCHUNKCRC 0xb114u
#define SNAPDATA 0xb400u
#define PACKETS 4050u
static volatile u32 *const txbuf=(volatile u32*)0x9800u;
static u32 rxpacket[140],missing[128];
static u32 snapshot_geometry=0;
static u32 request_id,frame_number,frame_crc,stream_index,missing_count,missing_pos;
static u32 session_active,snapshot_pending,snapshot_ready,last_activity,load_index,load_pending;
static u32 swap32(u32 x){return ((x&255u)<<24)|((x&0xff00u)<<8)|((x>>8)&0xff00u)|(x>>24);}
static u32 crc_payload(const u8*p,u32 n){
 u32 c=0xffffffffu;
 while(n--){c^=*p++;for(unsigned k=0;k<8;k++)c=(c>>1)^((c&1)?0xedb88320u:0u);}
 return c^0xffffffffu;
}
static void packet_header(u32 kind,u32 req,u32 fid,u32 index,u32 count,u32 length,u32 payload_crc,u32 whole_crc){
 txbuf[0]=0x31504e43u;txbuf[1]=1u|(kind<<8)|((kind==4?snapshot_geometry:0u)<<24);
 txbuf[2]=swap32(req);txbuf[3]=swap32(fid);txbuf[4]=swap32(index);txbuf[5]=swap32(count);
 txbuf[6]=swap32(1920);txbuf[7]=swap32(1080);txbuf[8]=swap32(1);
 txbuf[9]=swap32(length);txbuf[10]=swap32(payload_crc);txbuf[11]=swap32(whole_crc);
 REG(NETTXLEN)=48+length;REG(NETSEND)=1;
}
static void text_packet(u32 kind,u32 req,const char*s){
 u32 n=0;while(s[n])n++;
 for(u32 i=0;i<(n+3)/4;i++){u32 v=0;for(u32 k=0;k<4;k++)if(i*4+k<n)v|=(u32)(u8)s[i*4+k]<<(8*k);txbuf[12+i]=v;}
 packet_header(kind,req,0,0,0,n,crc_payload((const u8*)s,n),0);
}
static void snapshot_drop(void){
 if(!(REG(SNAPSTAT)&2u))REG(SNAPCMD)=4;
 session_active=snapshot_pending=snapshot_ready=load_pending=0;missing_count=missing_pos=0;
}
static void snapshot_receive(u32 now){
 u32 n=REG(NETLEN);
 if(n<48||n>560){REG(NETREL)=1;return;}
 for(u32 i=0;i<(n+3)/4;i++)rxpacket[i]=REG(0xa000u+i*4);
 REG(NETREL)=1;
 if(rxpacket[0]!=0x31504e43u||(rxpacket[1]&0xffff00ffu)!=1)return;
 u32 kind=(rxpacket[1]>>8)&255u,req=swap32(rxpacket[2]),fid=swap32(rxpacket[3]);
 u32 length=swap32(rxpacket[9]);
 if(length!=n-48||crc_payload((const u8*)&rxpacket[12],length)!=swap32(rxpacket[10]))return;
 if(kind==1&&length==0){
  text_packet(2,req,"{\"device\":\"100Pro+ OV5640\",\"firmware\":\"R22 EIS CNP1 HOST MODES NIGHT SNAPSHOT R13NET\",\"capabilities\":[\"snapshot_rgb565\",\"snapshot_eis\",\"snapshot_rotation\",\"fisheye_correction\",\"stabilization\",\"snapshot_night\",\"global_histogram\",\"host_modes\",\"split_raw_left\"],\"width\":1920,\"height\":1080,\"pixel_format\":\"RGB565_LE\"}");return;
 }
 if(kind==3&&length==0){
  if(swap32(rxpacket[6])!=1920||swap32(rxpacket[7])!=1080||swap32(rxpacket[8])!=1){text_packet(8,req,"Unsupported image format");return;}
  if(session_active){
   if(req!=request_id){text_packet(8,req,"Another snapshot is active; cancel it or wait for timeout");return;}
   last_activity=now;
   if(snapshot_ready&&stream_index>=PACKETS)stream_index=0;
   return; /* Same request always refers to the original frozen image. */
  }
  if(REG(SNAPSTAT)&2u){text_packet(8,req,"Snapshot engine busy");return;}
  request_id=req;session_active=snapshot_pending=1;snapshot_ready=load_pending=0;
  missing_count=missing_pos=0;stream_index=0;last_activity=now;REG(SNAPCMD)=1;
  puts_("SNAP request=");hex(req);puts_(" waiting complete camera frame\r\n");return;
 }
 if(!session_active||req!=request_id)return;
 if(kind==7&&length==0&&(fid==0||fid==frame_number)){last_activity=now;snapshot_pending=2;return;}
 if(kind==5&&length==0&&snapshot_ready&&fid==frame_number&&swap32(rxpacket[11])==frame_crc){snapshot_pending=2;return;}
 if(kind==6&&snapshot_ready&&fid==frame_number&&length>0&&length<=512&&(length&3u)==0){
  missing_count=0;missing_pos=0;
  for(u32 i=0;i<length/4;i++){u32 index=swap32(rxpacket[12+i]);if(index<PACKETS)missing[missing_count++]=index;}
  last_activity=now;
 }
}
static void snapshot_service(u32 now){
 u32 state=REG(SNAPSTAT),net=REG(NETSTAT);
 /* Drain accepted DMA before releasing anything, even on timeout/cancel. */
 if(session_active&&now-last_activity>=35000u)snapshot_pending=2;
 if(snapshot_pending==2){REG(SNAPCMD)=4;if(!(state&2u)){snapshot_drop();puts_("SNAP released\r\n");}return;}
 if(snapshot_pending==1&&(state&1u)&&!(state&2u)){
  snapshot_pending=0;snapshot_ready=1;frame_number=REG(SNAPFRAME);frame_crc=REG(SNAPCRC);snapshot_geometry=REG(0xb120u)&15u;
  u32 ns=REG(0xb11cu);puts_("SNAP night frame=");dec(frame_number);puts_(" curve=");dec(ns&15u);puts_(" strength_q8=");dec((ns>>4)&511u);puts_("\r\n");
  puts_("SNAP frozen frame=");dec(frame_number);puts_(" CRC=");hex(frame_crc);puts_("\r\n");
 }
 if(snapshot_pending==1&&(state&8u)){snapshot_pending=2;return;}
 /* RX mailbox stays owned while a missing batch is sent; overflow can be retried. */
 if((net&1u)&&!(net&2u)&&missing_pos>=missing_count&&!load_pending)snapshot_receive(now);
 if(!session_active||!snapshot_ready||(REG(NETSTAT)&2u))return;
 if(!load_pending){
  if(missing_pos<missing_count)load_index=missing[missing_pos++];
  else if(stream_index<PACKETS)load_index=stream_index++;
  else return;
  REG(SNAPINDEX)=load_index;REG(SNAPCMD)=2;load_pending=1;return;
 }
 state=REG(SNAPSTAT);
 if(state&8u){snapshot_pending=2;return;}
 if((state&4u)&&!(state&2u)){
  for(u32 i=0;i<256;i++)txbuf[12+i]=REG(SNAPDATA+i*4);
  packet_header(4,request_id,frame_number,load_index,PACKETS,1024,REG(SNAPCHUNKCRC),frame_crc);
  load_pending=0;
 }
}
#endif
