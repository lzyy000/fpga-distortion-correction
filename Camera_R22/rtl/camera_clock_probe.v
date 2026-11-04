// Passive independent frequency reference: hardware-divided PCLK / 2,
// count once per 128 divided clocks (=256 original byte clocks).
module camera_clock_probe(input half_clk,half_resetn,clk,resetn,output [23:0] ticks256);
reg [6:0] prescale=0;
reg [23:0] binary=0,gray=0;
wire [23:0] next_binary=binary+1'b1;
always @(posedge half_clk or negedge half_resetn)begin
 if(!half_resetn)begin prescale<=0;binary<=0;gray<=0;end
 else begin
  prescale<=prescale+1'b1;
  if(&prescale)begin binary<=next_binary;gray<=next_binary^(next_binary>>1);end
 end
end
(* ASYNC_REG="TRUE" *) reg [23:0] meta=0,sync=0;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin meta<=0;sync<=0;end
 else begin meta<=gray;sync<=meta;end
end
function [23:0] decode;input [23:0] g;integer k;
 begin decode[23]=g[23];for(k=22;k>=0;k=k-1)decode[k]=decode[k+1]^g[k];end
endfunction
assign ticks256=decode(sync);
endmodule
