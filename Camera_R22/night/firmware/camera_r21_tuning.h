#ifndef CAMERA_R21_TUNING_H
#define CAMERA_R21_TUNING_H
static u32 net_ungray(u32 x){x&=65535u;x^=x>>1;x^=x>>2;x^=x>>4;x^=x>>8;return x&65535u;}
static void net_diag_print(void){
 u32 rx=REG(0x9020u),tx=REG(0x9024u),state=REG(0x9028u);
 puts_("NET mailbox=");hex(REG(0x9000u));puts_(" state=");hex(state);
 puts_(" rx_frames=");dec(net_ungray(rx));puts_(" rx_bytes=");dec(net_ungray(rx>>16));
 puts_(" tx_frames=");dec(net_ungray(tx>>16));puts_(" udp_frames=");dec(net_ungray(tx));
 puts_(" mailbox_drop=");dec(REG(0x900cu));puts_(" rxstep=");dec(REG(0x903cu));
 puts_(" head0=");hex(REG(0x902cu));puts_(" head1=");hex(REG(0x9030u));puts_("\r\n");
}

/* One-byte idempotent commands survive the single-byte UART RX register.
 * 0..100=denoise, 128..228=night, 112..127=mode mask, 240=query.
 * GHE: 241..247 stage high nibble; 229..239/250..254 apply low nibble.
 * 248/249 turn GHE on/off. Every byte is acknowledged and retry-idempotent.
 * Host sends one command and waits for the echoed, applied-state ACK. */
static u32 tune_night=100,tune_denoise=100,tune_ghe=100,tune_ghe_high=6;
static void tuning_reply(u32 cmd){
 puts_("TUNE v=21 cmd=");hex(cmd);puts_(" night=");dec(tune_night);puts_(" denoise=");dec(tune_denoise);
 puts_(" night_q8=");dec(REG(CTRL+216));puts_(" denoise_q8=");dec(REG(CTRL+220));
 puts_(" night_on=");dec((REG(CTRL+204)>>1)&1);puts_(" denoise_on=");dec((REG(CTRL+184)>>5)&1);
 puts_(" modes=");dec(REG(CTRL+228)&31u);puts_(" applied=");dec(REG(CTRL+232)&31u);
 puts_(" ghe=");dec(tune_ghe);puts_(" ghe_q8=");dec(REG(CTRL+236));
 puts_(" ghe_on=");dec((REG(CTRL+228)>>4)&1u);puts_(" ghe_ready=");dec((REG(CTRL+240)>>2)&1u);puts_("\r\n");
}
static void tuning_service(void){
 u32 c=REG(UART);if(c==0xffffffffu)return;
 if(c<=100){tune_denoise=c;REG(CTRL+220)=(c*256u+50u)/100u;tuning_reply(c);}
 else if(c>=112&&c<=127){REG(CTRL+228)=(REG(CTRL+228)&16u)|(c-112u);tuning_reply(c);}
 else if(c>=128&&c<=228){tune_night=c-128;REG(CTRL+216)=(tune_night*256u+50u)/100u;tuning_reply(c);}
 else if(c==240)tuning_reply(c);
 else if(c>=241&&c<=247){tune_ghe_high=c-241u;tuning_reply(c);}
 else if(c==248||c==249){REG(CTRL+228)=(REG(CTRL+228)&15u)|(c==248?16u:0u);tuning_reply(c);}
 else if((c>=229&&c<=239)||(c>=250&&c<=254)){
  u32 low=c<=239?c-229u:c-250u+11u;
  u32 value=(tune_ghe_high<<4)|low;
  if(value<=100){tune_ghe=value;REG(CTRL+236)=(value*256u+50u)/100u;}
  tuning_reply(c);
 }
 else if(c=='n')net_diag_print();
}
#endif
