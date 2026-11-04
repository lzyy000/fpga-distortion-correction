// Fixed medium spatial filter. RGB888 is quantized only after filtering.
// 5x5 binomial weights, jointly gated by luma/chroma. All signed arithmetic
// matches the stage-1 integer model; rejected neighbours contribute zero delta.
module camera_spatial_core_r21(
 input clk,resetn,clear,enable,valid,input [8:0] strength,input [599:0] pixels,
 output out_valid,output [15:0] out_pixel,output reg [15:0] out_original=0,output busy);
reg [23:0] original[0:5];
reg base_valid=0;reg [15:0] base_pixel=0,base_original;
reg [15:0] raw_pipe=0;
always @(posedge clk)begin raw_pipe<=base_original;out_original<=raw_pipe;end
reg [8:0] sp[0:4];reg [8:0] strength_out;integer si;reg [1:0] mix_pending=0;
always @(posedge clk)begin sp[0]<=strength;for(si=1;si<5;si=si+1)sp[si]<=sp[si-1];strength_out<=sp[4];base_original<={original[4][23:19],original[4][15:10],original[4][7:3]};end
always @(posedge clk or negedge resetn)if(!resetn)mix_pending<=0;else mix_pending<={mix_pending[0],base_valid};
camera_strength_blend_r19 mix(.clk(clk),.resetn(resetn&&!clear),.valid(base_valid&&!clear),.strength(strength_out),.original(base_original),.processed(base_pixel),.out_valid(out_valid),.result(out_pixel));
function [7:0] cy; input [23:0] p; reg [9:0] sum;
 begin sum={2'b0,p[23:16]}+{1'b0,p[15:8],1'b0}+{2'b0,p[7:0]}+10'd2;cy=sum[9:2];end
endfunction
function signed [8:0] cu; input [23:0] p;
 begin cu=$signed({1'b0,p[7:0]})-$signed({1'b0,p[15:8]});end
endfunction
function signed [8:0] cv; input [23:0] p;
 begin cv=$signed({1'b0,p[23:16]})-$signed({1'b0,p[15:8]});end
endfunction
function [9:0] abs10; input signed [9:0] x; begin abs10=x<0?-x:x;end endfunction
function [7:0] clip8; input signed [31:0] x;begin clip8=x<0?0:x>255?255:x[7:0];end endfunction
reg [7:0] ya[0:24];reg signed [8:0] ua[0:24],va[0:24];
reg signed [9:0] dy[0:24],du[0:24],dv[0:24];
reg signed [15:0] ry[0:4],ru[0:4],rv[0:4];
reg signed [31:0] sy=0,su=0,sv=0;
reg [7:0] yb=0,yc=0,yd=0;
reg signed [8:0] ub=0,vb=0,uc=0,vc=0,ud=0,vd=0;
reg signed [31:0] ye=0,ue=0,ve=0;
reg [5:0] vp=0,ep=0;

wire signed [31:0] green=ye-((ue+ve+32'sd2)>>>2);
wire [7:0] red8=clip8(green+ve),green8=clip8(green),blue8=clip8(green+ue);
assign busy=(|vp)||base_valid||(|mix_pending)||out_valid;
genvar n;
generate for(n=0;n<25;n=n+1)begin:tap
 wire signed [9:0] ddy=$signed({1'b0,ya[n]})-$signed({1'b0,ya[12]});
 wire signed [9:0] ddu=$signed(ua[n])-$signed(ua[12]);
 wire signed [9:0] ddv=$signed(va[n])-$signed(va[12]);
 wire accept=(abs10(ddy)<=28)&&(abs10(ddu)<=64)&&(abs10(ddv)<=64);
 always @(posedge clk)begin
  ya[n]<=cy(pixels[n*24+:24]);ua[n]<=cu(pixels[n*24+:24]);va[n]<=cv(pixels[n*24+:24]);
  dy[n]<=accept?ddy:10'sd0;du[n]<=accept?ddu:10'sd0;dv[n]<=accept?ddv:10'sd0;
 end
end endgenerate
generate for(n=0;n<5;n=n+1)begin:row
 // Widen before shifting; a Verilog shift retains its left operand's width.
 wire signed [15:0] y0=dy[n*5],y1=dy[n*5+1],y2=dy[n*5+2],y3=dy[n*5+3],y4=dy[n*5+4];
 wire signed [15:0] u0=du[n*5],u1=du[n*5+1],u2=du[n*5+2],u3=du[n*5+3],u4=du[n*5+4];
 wire signed [15:0] v0=dv[n*5],v1=dv[n*5+1],v2=dv[n*5+2],v3=dv[n*5+3],v4=dv[n*5+4];
 always @(posedge clk)begin
  ry[n]<=y0+(y1<<<2)+(y2<<<2)+(y2<<<1)+(y3<<<2)+y4;
  ru[n]<=u0+(u1<<<2)+(u2<<<2)+(u2<<<1)+(u3<<<2)+u4;
  rv[n]<=v0+(v1<<<2)+(v2<<<2)+(v2<<<1)+(v3<<<2)+v4;
 end
end endgenerate
wire signed [31:0] y0=ry[0],y1=ry[1],y2=ry[2],y3=ry[3],y4=ry[4];
wire signed [31:0] u0=ru[0],u1=ru[1],u2=ru[2],u3=ru[3],u4=ru[4];
wire signed [31:0] v0=rv[0],v1=rv[1],v2=rv[2],v3=rv[3],v4=rv[4];
integer i;
always @(posedge clk)begin
 original[0]<=pixels[12*24+:24];for(i=1;i<6;i=i+1)original[i]<=original[i-1];
 yb<=ya[12];ub<=ua[12];vb<=va[12];yc<=yb;uc<=ub;vc<=vb;yd<=yc;ud<=uc;vd<=vc;
 sy<=y0+(y1<<<2)+(y2<<<2)+(y2<<<1)+(y3<<<2)+y4;
 su<=u0+(u1<<<2)+(u2<<<2)+(u2<<<1)+(u3<<<2)+u4;
 sv<=v0+(v1<<<2)+(v2<<<2)+(v2<<<1)+(v3<<<2)+v4;
 ye<=$signed({1'b0,yd})+((sy+32'sd1024)>>>11);
 ue<=$signed(ud)+(((su<<<2)+(su<<<1)+32'sd1024)>>>11);
 ve<=$signed(vd)+(((sv<<<2)+(sv<<<1)+32'sd1024)>>>11);
end
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin vp<=0;ep<=0;base_valid<=0;base_pixel<=0;end
 else if(clear)begin vp<=0;ep<=0;base_valid<=0;end
 else begin
  vp<={vp[4:0],valid};ep<={ep[4:0],enable};base_valid<=vp[4];
  // Stage 5 is the inverse/quantizer. original[4] is its matching centre.
  base_pixel<=ep[4]?{red8[7:3],green8[7:2],blue8[7:3]}:
                          {original[4][23:19],original[4][15:10],original[4][7:3]};
 end
end
endmodule
