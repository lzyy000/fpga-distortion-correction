// Signed 32x32, three registered stages, no unregistered DSP cascade.
module dynamic_mul32(input clk,input signed [31:0] a,b,output reg signed [63:0] p);
reg signed [33:0] ll,lh,hl,hh;
reg signed [34:0] cross_sum;reg signed [33:0] low,high;
always @(posedge clk)begin
 ll<=$signed({1'b0,a[15:0]})*$signed({1'b0,b[15:0]});
 lh<=$signed({1'b0,a[15:0]})*$signed(b[31:16]);
 hl<=$signed(a[31:16])*$signed({1'b0,b[15:0]});
 hh<=$signed(a[31:16])*$signed(b[31:16]);
 cross_sum<=$signed(lh)+$signed(hl);low<=ll;high<=hh;
 p<=($signed({{30{high[33]}},high})<<<32)+($signed({{29{cross_sum[34]}},cross_sum})<<<16)+$signed({{30{low[33]}},low});
end
endmodule
