// Convex RGB565 blend: 0 = exact original, 256 = exact processed.
// Two clocks, one LANES-wide packet per clock; no extra DDR traffic.
module camera_strength_blend_r19 #(parameter LANES=1)(
 input clk,resetn,valid,input [8:0] strength,
 input [LANES*16-1:0] original,processed,
 output reg out_valid=0,output reg [LANES*16-1:0] result=0);
reg v1=0;
genvar k;
generate for(k=0;k<LANES;k=k+1)begin:lane
 wire [15:0] a=original[k*16+:16],b=processed[k*16+:16];
 wire signed [5:0] dr=$signed({1'b0,b[15:11]})-$signed({1'b0,a[15:11]});
 wire signed [6:0] dg=$signed({1'b0,b[10:5]})-$signed({1'b0,a[10:5]});
 wire signed [5:0] db=$signed({1'b0,b[4:0]})-$signed({1'b0,a[4:0]});
 reg [15:0] a1;
 reg signed [16:0] pr,pg,pb;
 always @(posedge clk)begin
  a1<=a;pr<=dr*$signed({1'b0,strength});pg<=dg*$signed({1'b0,strength});pb<=db*$signed({1'b0,strength});
  result[k*16+11+:5]<=$signed({1'b0,a1[15:11]})+((pr+17'sd128)>>>8);
  result[k*16+5+:6]<=$signed({1'b0,a1[10:5]})+((pg+17'sd128)>>>8);
  result[k*16+:5]<=$signed({1'b0,a1[4:0]})+((pb+17'sd128)>>>8);
 end
end endgenerate
always @(posedge clk or negedge resetn)
 if(!resetn)begin v1<=0;out_valid<=0;end
 else begin v1<=valid;out_valid<=v1;end
endmodule
