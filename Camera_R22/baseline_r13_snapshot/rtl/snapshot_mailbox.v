// Held-buffer CDC: CPU owns TX RAM until net_done; network owns RX until release.
module snapshot_mailbox(input cpu_clk,cpu_rstn,input sel,input [31:0] addr,wdata,input [3:0] wstrb,
 output ready,output reg [31:0] rdata,output reg [7:0] rx_delay_step=247,
 input net_clk,net_rstn,input rx_valid,input [7:0] rx_data,input [15:0] rx_length,
 output tx_req,output [15:0] tx_length,input [10:0] tx_index,output reg [7:0] tx_byte,input tx_done,input net_lock);
reg [31:0] rxmem[0:511] /* synthesis syn_ramstyle="block_ram" */;
reg [31:0] txmem[0:511] /* synthesis syn_ramstyle="block_ram" */;
reg pub=0,rel=0,send=0,finished=0;
(* ASYNC_REG="TRUE" *) reg [1:0] ps=0,rs=0,ss=0,fs=0;
(* ASYNC_REG="TRUE" *) reg [1:0] ls=0;
reg [15:0] rxlen=0,txlen=0;reg [11:0] count=0;
reg prev=0,drop=0,overflow=0;reg [31:0] dropped=0;
reg [1:0] access_state=0;reg [31:0] rxword,txword;
reg [1:0] tx_lane;
wire pending=ps[1]!=rel,busy=send!=fs[1];
wire rx_sel=addr>=32'ha000&&addr<32'ha800;
wire tx_sel=addr>=32'h9800&&addr<32'ha000;
assign ready=access_state==1;
assign tx_req=ss[1]!=finished;assign tx_length=txlen;
wire store=net_rstn&&rx_valid&&(!prev?pub==rs[1]:(!drop&&count<2048));
wire [8:0] wi=prev?count[10:2]:0;wire [1:0] lane=prev?count[1:0]:0;
always @(posedge net_clk)begin
 if(store)case(lane)
  0:rxmem[wi][7:0]<=rx_data;1:rxmem[wi][15:8]<=rx_data;
  2:rxmem[wi][23:16]<=rx_data;3:rxmem[wi][31:24]<=rx_data;
 endcase
 txword<=txmem[tx_index[10:2]];tx_lane<=tx_index[1:0];
 tx_byte<=txword[tx_lane*8+:8];
end
always @(posedge cpu_clk)begin
 if(sel&&rx_sel&&access_state==0)rxword<=rxmem[addr[10:2]];
 if(sel&&tx_sel&&access_state==0&&!busy)begin
  if(wstrb[0])txmem[addr[10:2]][7:0]<=wdata[7:0];
  if(wstrb[1])txmem[addr[10:2]][15:8]<=wdata[15:8];
  if(wstrb[2])txmem[addr[10:2]][23:16]<=wdata[23:16];
  if(wstrb[3])txmem[addr[10:2]][31:24]<=wdata[31:24];
 end
end
always @(posedge net_clk or negedge net_rstn)begin
 if(!net_rstn)begin pub<=0;rs<=0;ss<=0;finished<=0;count<=0;prev<=0;drop<=0;overflow<=0;rxlen<=0;dropped<=0;end
 else begin
  rs<={rs[0],rel};ss<={ss[0],send};prev<=rx_valid;
  if(tx_done)finished<=ss[1];
  if(rx_valid)begin
   if(!prev)begin count<=1;drop<=pub!=rs[1];overflow<=0;end
   else begin if(count<4095)count<=count+1;else overflow<=1;if(count>=2048)overflow<=1;end
  end
  if(prev&&!rx_valid)begin
   if(!drop&&!overflow&&count==rx_length&&count>=48)begin rxlen<=count;pub<=~pub;end
   else dropped<=dropped+1;
  end
 end
end
always @(posedge cpu_clk or negedge cpu_rstn)begin
 if(!cpu_rstn)begin ps<=0;fs<=0;ls<=0;rel<=0;send<=0;txlen<=0;access_state<=0;rdata<=0;rx_delay_step<=247;end
 else begin
  ps<={ps[0],pub};fs<={fs[0],finished};ls<={ls[0],net_lock};
  case(access_state)
   0:if(sel)begin
    if(rx_sel)access_state<=2;
    else begin
     case(addr[7:0])
      0:rdata<={29'b0,ls[1],busy,pending};4:rdata<={16'b0,rxlen};
      12:rdata<=dropped;16:rdata<={16'b0,txlen};60:rdata<={24'b0,rx_delay_step};default:rdata<=0;
     endcase
     if(|wstrb&&!tx_sel)begin
      if(addr[7:0]==8&&wdata[0])rel<=ps[1];
      if(addr[7:0]==16&&!busy&&wdata>=48&&wdata<=1072)txlen<=wdata[15:0];
      if(addr[7:0]==20&&wdata[0]&&!busy&&txlen>=48)send<=~send;
      if(addr[7:0]==60&&wdata<=247)rx_delay_step<=wdata[7:0];
     end
     access_state<=1;
    end
   end
   2:begin rdata<=rxword;access_state<=1;end
   1:access_state<=3;
   3:if(!sel)access_state<=0;
  endcase
 end
end
endmodule
