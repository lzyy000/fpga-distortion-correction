// Stop-and-wait UDP mailbox. RX bytes owned by network until publication;
// CPU read ownership until it releases the slot. Held multibit payloads cross
// with a toggle plus 2FF synchronizers; ACK words are held until transmission.
module udp_mailbox(input cpu_clk,cpu_rstn,input sel,input [31:0] addr,wdata,input [3:0] wstrb,
 output ready,output reg [31:0] rdata,output reg [7:0] rx_delay_step=8'd247,
 input net_clk,net_rstn,input rx_valid,input [7:0] rx_data,input [15:0] rx_length,
 output ack_req,output [191:0] ack_words,input ack_done,input net_lock,
 input [31:0] diag_rx_gray,diag_tx_gray,diag_state,diag_head0,diag_head1);
reg [31:0] rxmem[0:511] /* synthesis syn_ramstyle="block_ram" */;
reg [191:0] ack=0;
reg publish=0,release_t=0,ack_t=0,ack_finished=0;
reg [1:0] pub_sync=0,rel_sync=0,ack_sync=0,finish_sync=0;
reg [15:0] len_hold=0;
reg [11:0] count=0;
reg prev=0,dropping=0,overflow=0;
reg [31:0] drops=0;
reg [1:0] access_state=0;
reg [31:0] ram_read;
reg [31:0] drx1=0,drx2=0,dtx1=0,dtx2=0,ds1=0,ds2=0,dh01=0,dh02=0,dh11=0,dh12=0;
function [15:0] ungray(input [15:0] g);integer k;begin
 ungray[15]=g[15];for(k=14;k>=0;k=k-1)ungray[k]=ungray[k+1]^g[k];end endfunction
always @(posedge cpu_clk)begin
 drx1<=diag_rx_gray;drx2<=drx1;dtx1<=diag_tx_gray;dtx2<=dtx1;
 ds1<=diag_state;ds2<=ds1;dh01<=diag_head0;dh02<=dh01;dh11<=diag_head1;dh12<=dh11;
end
wire packet_pending=pub_sync[1]!=release_t;
wire tx_busy=ack_t!=finish_sync[1];
wire cpu_write=|wstrb;
wire data_sel=addr>=32'ha000 && addr<32'ha800;
assign ready=(access_state==1);
assign ack_req=ack_sync[1]!=ack_finished;
assign ack_words=ack;
wire store_byte=net_rstn && rx_valid && (!prev ? publish==rel_sync[1] : (!dropping && count<2048));
wire [8:0] write_index=prev?count[10:2]:9'b0;
wire [1:0] byte_lane=prev?count[1:0]:2'b0;
// Keep RAM ports free of asynchronous reset for DRM inference.
always @(posedge net_clk)if(store_byte)begin
 case(byte_lane)
  0:rxmem[write_index][7:0]<=rx_data;
  1:rxmem[write_index][15:8]<=rx_data;
  2:rxmem[write_index][23:16]<=rx_data;
  3:rxmem[write_index][31:24]<=rx_data;
 endcase
end
always @(posedge cpu_clk)if(sel && data_sel && access_state==0)ram_read<=rxmem[addr[10:2]];
always @(posedge net_clk or negedge net_rstn)begin
 if(!net_rstn)begin publish<=0;rel_sync<=0;ack_sync<=0;ack_finished<=0;count<=0;prev<=0;dropping<=0;overflow<=0;drops<=0;len_hold<=0;end
 else begin
  rel_sync<={rel_sync[0],release_t};ack_sync<={ack_sync[0],ack_t};prev<=rx_valid;
  if(ack_done)ack_finished<=ack_sync[1];
  if(rx_valid)begin
   if(!prev)begin
    count<=1;overflow<=0;dropping<=(publish!=rel_sync[1]);
    
   end else begin
    
    if(count<4095)count<=count+1;else overflow<=1;
    if(count>=2048)overflow<=1;
   end
  end
  if(prev && !rx_valid)begin
   if(!dropping && !overflow && count==rx_length && count>=24)begin len_hold<=count;publish<=~publish;end
   else drops<=drops+1;
  end
 end
end
always @(posedge cpu_clk or negedge cpu_rstn)begin
 if(!cpu_rstn)begin pub_sync<=0;finish_sync<=0;release_t<=0;ack_t<=0;ack<=0;access_state<=0;rdata<=0;rx_delay_step<=8'd247;end
 else begin
  pub_sync<={pub_sync[0],publish};finish_sync<={finish_sync[0],ack_finished};
  case(access_state)
   0:if(sel)begin
    if(data_sel)begin access_state<=2;end
    else begin
     case(addr[7:0])
      8'h00:rdata<={29'b0,net_lock,tx_busy,packet_pending};
      8'h04:rdata<={16'b0,len_hold};
      8'h0c:rdata<=drops;
      8'h28:rdata<={ungray(drx2[31:16]),ungray(drx2[15:0])};
      8'h2c:rdata<={ungray(dtx2[31:16]),ungray(dtx2[15:0])};
      8'h30:rdata<=ds2;
      8'h34:rdata<=dh02;
      8'h38:rdata<=dh12;
      8'h3c:rdata<={24'b0,rx_delay_step};
      default:rdata<=0;
     endcase
     if(cpu_write)begin
      if(addr[7:0]==8'h3c && wdata[7:0]<=8'd247)rx_delay_step<=wdata[7:0];
      if(addr[7:0]>=8'h10 && addr[7:0]<=8'h24 && !tx_busy)ack[((addr[7:0]-8'h10)>>2)*32+:32]<=wdata;
      if(addr[7:0]==8'h08 && wdata[0] && !tx_busy)begin ack_t<=~ack_t;release_t<=pub_sync[1];end
     end
     access_state<=1;
    end
   end
   2:begin rdata<=ram_read;access_state<=1;end
   1:access_state<=3;
   3:if(!sel)access_state<=0;
  endcase
 end
end
endmodule
