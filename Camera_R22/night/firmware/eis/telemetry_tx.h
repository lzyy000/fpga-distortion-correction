/* Single-producer nonblocking run-time logger. Startup remains synchronous. */
static u8 tx_ring[2048];
static u32 tx_head=0,tx_tail=0,tx_async=0,tx_dropped=0;
static void tx_poll(void){
 // At most 64 nonblocking FIFO writes; never wait for serial bit timing.
 for(unsigned n=0;n<64&&tx_head!=tx_tail&&!(REG(0x8070u)&1u);n++){
  REG(UART)=tx_ring[tx_tail];tx_tail=(tx_tail+1)&2047u;
 }
}
static void putc_(char c){
 if(!tx_async){REG(UART)=(u32)c;return;}
 u32 n=(tx_head+1)&2047u;
 if(n==tx_tail){tx_dropped++;return;}
 tx_ring[tx_head]=(u8)c;tx_head=n;
}
