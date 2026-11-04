// Exact signed32 x signed32 -> signed64. Registered16-bit partial products
// avoid a long cascaded32-bit DSP/combinational recombination path.
// Input a/b at an edge appears on result after five registered stages.
module camera_mul32_pipe(input clk,input signed [31:0] a,b,output reg signed [63:0] result);
reg [31:0] ll;
reg signed [32:0] lh,hl;
reg signed [31:0] hh;
reg signed [33:0] cross_term;
reg [31:0] ll_d;
reg signed [31:0] hh_d;
reg [16:0] middle;
reg [15:0] low;
reg signed [31:0] high;
reg signed [63:0] assembled;
wire signed [33:0] lh_w=lh,hl_w=hl;
wire signed [33:0] hh_w=hh_d;
wire signed [31:0] high_final=high+$signed({31'b0,middle[16]});
always @(posedge clk)begin
 ll<=a[15:0]*b[15:0];
 lh<=$signed({1'b0,a[15:0]})*$signed(b[31:16]);
 hl<=$signed(a[31:16])*$signed({1'b0,b[15:0]});
 hh<=$signed(a[31:16])*$signed(b[31:16]);
 cross_term<=lh_w+hl_w;ll_d<=ll;hh_d<=hh;
 middle<={1'b0,ll_d[31:16]}+{1'b0,cross_term[15:0]};
 high<=hh_w+(cross_term>>>16);low<=ll_d[15:0];
 assembled<={high_final,middle[15:0],low};
 result<=assembled;
end
endmodule
