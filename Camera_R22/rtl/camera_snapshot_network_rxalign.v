// Reuses board-demo PHY/PLL/MAC/IP/ARP/UDP. ACK is 24 bytes at UDP8080.
module camera_snapshot_network(input [7:0] rx_delay_step,input resetn,input rgmii_rxc,rgmii_rx_ctl,input [3:0] rgmii_rxd,
 output rgmii_txc,rgmii_tx_ctl,output [3:0] rgmii_txd,output phy_rstn,
 output net_clk,net_resetn,net_lock,output rx_valid,output [7:0] rx_data,output [15:0] rx_length,
 input ack_req,input [15:0] tx_length,output [10:0] tx_index,input [7:0] tx_byte,output ack_done,
 output [31:0] diag_rx_gray,diag_tx_gray,diag_state,output reg [31:0] diag_head0=0,diag_head1=0);
wire delayed_clk,pll_locked,raw_resetn;
ref_clock ref_clock(.clkout0(delayed_clk),.lock(pll_locked),.clkin1(rgmii_rxc));
assign phy_rstn=pll_locked;assign net_lock=pll_locked;
reset_release nr(.clk(net_clk),.arstn(resetn && pll_locked),.resetn(raw_resetn));
assign net_resetn=raw_resetn;
wire mac_rx_valid,mac_rx_error;wire [7:0] mac_rx_data;
wire mac_valid;wire [7:0] mac_data;
reg gmii_tx_valid=0;reg [7:0] gmii_tx_data=0;
reg gmii_rx_valid=0;reg [7:0] gmii_rx_data=0;
reg [7:0] delay_meta=247,delay_sync=247,delay_active=247;
reg [4:0] delay_settle=0;
always @(posedge net_clk or negedge raw_resetn)begin
 if(!raw_resetn)begin delay_meta<=247;delay_sync<=247;delay_active<=247;delay_settle<=0;end
 else begin
  delay_meta<=rx_delay_step;delay_sync<=delay_meta;
  // Control is held until the next UART command; only change in interframe idle.
  if(!mac_rx_valid && !gmii_rx_valid && delay_sync!=delay_active)begin delay_active<=delay_sync;delay_settle<=16;end
  else if(delay_settle!=0)delay_settle<=delay_settle-1'b1;
 end
end
wire aligned_valid,aligned_error,align_seen,align_half;wire [7:0] aligned_data;
camera_rgmii_rx_align rx_align(.clk(net_clk),.resetn(raw_resetn),.raw_valid(mac_rx_valid),.raw_error(mac_rx_error),.raw_data(mac_rx_data),
 .valid(aligned_valid),.error(aligned_error),.data(aligned_data),.header_seen(align_seen),.half_cycle(align_half));
always @(posedge net_clk or negedge raw_resetn)begin
 if(!raw_resetn)begin gmii_tx_valid<=0;gmii_tx_data<=0;gmii_rx_valid<=0;gmii_rx_data<=0;end
 else begin
  gmii_tx_valid<=mac_valid;gmii_tx_data<=mac_data;
  gmii_rx_valid<=aligned_valid && delay_settle==0;gmii_rx_data<=aligned_data;
 end
end
rgmii_interface rgmii_interface(.rst(~raw_resetn),.rx_delay_step(delay_active),.rgmii_clk(net_clk),.rgmii_clk_90p(),
 .mac_tx_data_valid(gmii_tx_valid),.mac_tx_data(gmii_tx_data),.mac_rx_error(mac_rx_error),
 .mac_rx_data_valid(mac_rx_valid),.mac_rx_data(mac_rx_data),.rgmii_rxc(delayed_clk),
 .rgmii_rx_ctl(rgmii_rx_ctl),.rgmii_rxd(rgmii_rxd),.rgmii_txc(rgmii_txc),
 .rgmii_tx_ctl(rgmii_tx_ctl),.rgmii_txd(rgmii_txd));
wire udp_ack,arp_found,mac_missing,send_end;
reg [2:0] state=0;
reg [10:0] byte_index;
// Two-stage synchronous mailbox RAM prefetch, then original app register.
assign tx_index=state==3?byte_index+11'd2:(state==2&&udp_ack)?11'd1:11'd0;
reg [26:0] timeout;
reg app_write=0;reg [7:0] app_byte=0;
// Match original demo registered app-data latency; IP head otherwise loses its first byte.
always @(posedge net_clk or negedge raw_resetn)
 if(!raw_resetn)begin app_write<=0;app_byte<=0;end
 else begin app_write<=state==3;app_byte<=tx_byte;end
wire app_request=(state==2);
wire arp_request=(state==1);
assign ack_done=(state==5);
udp_ip_mac_top #(.LOCAL_MAC(48'ha0_b1_c2_d3_e1_e1),.LOCAL_IP(32'hc0a8010b),
 .LOCL_PORT(16'd8080),.DEST_IP(32'hc0a80169),.DEST_PORT(16'd8080)) stack(
 .rgmii_clk(net_clk),.rstn(raw_resetn),.app_data_in_valid(app_write),
 .app_data_in(app_byte),.app_data_length(tx_length),.app_data_request(app_request),
 .udp_send_ack(udp_ack),.arp_req(arp_request),.arp_found(arp_found),.mac_not_exist(mac_missing),
 .mac_send_end(send_end),.udp_rec_rdata(rx_data),.udp_rec_data_length(rx_length),
 .udp_rec_data_valid(rx_valid),.mac_data_valid(mac_valid),.mac_tx_data(mac_data),
 .rx_en(gmii_rx_valid),.mac_rx_datain(gmii_rx_data));
always @(posedge net_clk or negedge raw_resetn)begin
 if(!raw_resetn)begin state<=0;byte_index<=0;timeout<=0;end
 else begin
  timeout<=timeout+1;
  case(state)
   0:if(ack_req)begin state<=mac_missing?1:2;timeout<=0;end
   1:if(arp_found)begin state<=2;timeout<=0;end
    else if(timeout==27'd124999999)begin state<=0;timeout<=0;end
   2:if(udp_ack)begin state<=3;byte_index<=0;timeout<=0;end
   3:if(byte_index==tx_length-1)state<=4;else byte_index<=byte_index+1;
   4:if(send_end)state<=5;
   5:state<=6;
   6:if(!ack_req)state<=0;
  endcase
  // Recover stalled TX while keeping the pending ACK for retry.
  if((state==2 || state==4) && timeout==27'd124999999)begin state<=0;timeout<=0;end
 end
end

// Counters cross to CPU in reflected Gray code, decoded after two synchronizers.
reg [15:0] rx_bytes=0,rx_frames=0,tx_frames=0,udp_frames=0;
reg rx_prev=0,tx_prev=0,udp_prev=0,rx_error_seen=0;
reg [3:0] head_index=0;
assign diag_rx_gray={rx_bytes^(rx_bytes>>1),rx_frames^(rx_frames>>1)};
assign diag_tx_gray={tx_frames^(tx_frames>>1),udp_frames^(udp_frames>>1)};
assign diag_state={22'b0,align_half,align_seen,rx_error_seen,ack_req,mac_missing,raw_resetn,pll_locked,state};
always @(posedge net_clk or negedge raw_resetn)begin
 if(!raw_resetn)begin rx_bytes<=0;rx_frames<=0;tx_frames<=0;udp_frames<=0;
  rx_prev<=0;tx_prev<=0;udp_prev<=0;rx_error_seen<=0;head_index<=0;diag_head0<=0;diag_head1<=0;end
 else begin
  rx_prev<=gmii_rx_valid;tx_prev<=mac_valid;udp_prev<=rx_valid;
  if(aligned_error && aligned_valid)rx_error_seen<=1;
  if(mac_valid&&!tx_prev)tx_frames<=tx_frames+1'b1;
  if(rx_valid&&!udp_prev)udp_frames<=udp_frames+1'b1;
  if(gmii_rx_valid)begin
   rx_bytes<=rx_bytes+1'b1;
   if(!rx_prev)begin rx_frames<=rx_frames+1'b1;head_index<=1;diag_head0<={24'b0,gmii_rx_data};diag_head1<=0;end
   else if(head_index<8)begin
    if(head_index<4)diag_head0[head_index*8+:8]<=gmii_rx_data;
    else diag_head1[(head_index-4)*8+:8]<=gmii_rx_data;
    head_index<=head_index+1'b1;
   end
  end
 end
end
endmodule
