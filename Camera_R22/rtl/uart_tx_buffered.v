// UART serializer runs independently while the CPU solves a camera pose.
// bit 0 of the CPU TX status now means FIFO full, rather than serializer busy.
module uart_tx_buffered #(parameter AW=9)(
 input clk,resetn,output ser_tx,input ser_rx,
 input [3:0] reg_div_we,input [31:0] reg_div_di,output [31:0] reg_div_do,
 input reg_dat_we,reg_dat_re,input [31:0] reg_dat_di,output [31:0] reg_dat_do,
 output reg_dat_wait,tx_busy,tx_active,output reg [AW:0] tx_pending=0);
 localparam DEPTH=1<<AW;
 reg [7:0] fifo[0:DEPTH-1];
 reg [AW-1:0] wp=0,rp=0;reg [7:0] head=0;reg head_valid=0;
 wire push=reg_dat_we&&!tx_busy;
 wire pop=head_valid&&!tx_active;
 assign tx_busy=tx_pending==DEPTH;
 assign reg_dat_wait=reg_dat_we&&tx_busy;
 simpleuart_r22 serializer(.clk(clk),.resetn(resetn),.ser_tx(ser_tx),.ser_rx(ser_rx),
  .reg_div_we(reg_div_we),.reg_div_di(reg_div_di),.reg_div_do(reg_div_do),
  .reg_dat_we(pop),.reg_dat_re(reg_dat_re),.reg_dat_di({24'b0,head}),
  .reg_dat_do(reg_dat_do),.reg_dat_wait(),.tx_busy(tx_active));
 always @(posedge clk)begin
  if(!resetn)begin wp<=0;rp<=0;head_valid<=0;tx_pending<=0;end
  else begin
   if(push)begin fifo[wp]<=reg_dat_di[7:0];wp<=wp+1'b1;end
   // Synchronous RAM read; head_valid reaches the serializer one cycle later.
   if(!head_valid&&tx_pending!=0)begin head<=fifo[rp];head_valid<=1;end
   if(pop)begin rp<=rp+1'b1;head_valid<=0;end
   case({push,pop})2'b10:tx_pending<=tx_pending+1'b1;2'b01:tx_pending<=tx_pending-1'b1;endcase
  end
 end
endmodule
