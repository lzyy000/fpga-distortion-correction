#ifndef CAMERA_NET_DIAG_H
#define CAMERA_NET_DIAG_H
/* Diagnostics stay on CPU/UART; image ownership and DDR arbitration are unchanged. */
static u32 net_ungray(u32 x){x&=65535u;x^=x>>1;x^=x>>2;x^=x>>4;x^=x>>8;return x&65535u;}
static void net_diag_print(void){
 u32 rx=REG(0x9020u),tx=REG(0x9024u),state=REG(0x9028u);
 puts_("NET mailbox=");hex(REG(0x9000u));puts_(" state=");hex(state);
 puts_(" rx_frames=");dec(net_ungray(rx));puts_(" rx_bytes=");dec(net_ungray(rx>>16));
 puts_(" tx_frames=");dec(net_ungray(tx>>16));puts_(" udp_frames=");dec(net_ungray(tx));
 puts_(" mailbox_drop=");dec(REG(0x900cu));puts_(" rxstep=");dec(REG(0x903cu));
 puts_(" head0=");hex(REG(0x902cu));puts_(" head1=");hex(REG(0x9030u));puts_("\r\n");
}
/* R16 has no receive-delay writes or scanning commands. */
static void net_diag_service(void){
 u32 ch=REG(UART);if(ch=='n'||ch=='N')net_diag_print();
}
#endif
