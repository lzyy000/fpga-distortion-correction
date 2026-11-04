// Four horizontal pixels form a coarse motion test; a per-pixel guard also
// rejects large changes. Static: history 3/4 chroma, 1/4 luma. Moving: current.
// No motion compensation is claimed. Warm-up/invalid history is exact bypass.
module camera_temporal_rgb565_r19(
 input clk,resetn,valid,use_history,input [8:0] strength,input [255:0] current,history,
 output out_valid,output [255:0] result,output [4:0] fused_pixels);
reg [3:0] vp=0;
wire [4:0] base_fused;
reg base_valid=0;wire [255:0] base_result,base_original;
reg [8:0] sa,sb,sc,sd,strength_out;reg [4:0] fused1=0,fused2=0;
always @(posedge clk)begin if(valid)sa<=strength;if(vp[0])sb<=sa;if(vp[1])sc<=sb;if(vp[2])sd<=sc;if(vp[3])strength_out<=sd;fused1<=strength_out==0?0:base_fused;fused2<=fused1;end
assign fused_pixels=fused2;
camera_strength_blend_r19 #(.LANES(16)) mix(.clk(clk),.resetn(resetn),.valid(base_valid),.strength(strength_out),.original(base_original),.processed(base_result),.out_valid(out_valid),.result(result));
function [7:0] cy;input [15:0] p;reg [9:0] sum;
 begin sum={2'b0,p[15:11],3'b0}+{1'b0,p[10:5],3'b0}+{2'b0,p[4:0],3'b0}+10'd2;cy=sum[9:2];end
endfunction
function signed [8:0] cu;input [15:0] p;
 begin cu=$signed({1'b0,p[4:0],3'b0})-$signed({1'b0,p[10:5],2'b0});end
endfunction
function signed [8:0] cv;input [15:0] p;
 begin cv=$signed({1'b0,p[15:11],3'b0})-$signed({1'b0,p[10:5],2'b0});end
endfunction
function [31:0] abs32;input signed [31:0] x;begin abs32=x<0?-x:x;end endfunction
function [4:0] q5;input signed [31:0] x;
 begin q5=x<0?0:x>=248?31:(x+4)>>>3;end
endfunction
function [5:0] q6;input signed [31:0] x;
 begin q6=x<0?0:x>=252?63:(x+2)>>>2;end
endfunction
reg [7:0] yc[0:15],yh[0:15];
reg signed [8:0] uc[0:15],vc[0:15],uh[0:15],vh[0:15];
reg [15:0] original_a[0:15],original_b[0:15],original_c[0:15],original_d[0:15];

reg hp=0;
reg [15:0] accept_b=0;
reg signed [31:0] yb[0:15],ub[0:15],vb[0:15];
reg [15:0] accept_c=0,accept_d=0;
reg signed [10:0] green_c[0:15],green_d[0:15];
reg signed [8:0] u_c[0:15],v_c[0:15];
reg signed [11:0] red_d[0:15],blue_d[0:15];
reg [15:0] output_pixel[0:15],original_out[0:15];reg [15:0] fused=0;
wire [3:0] group_static;
genvar k,g;
generate for(g=0;g<4;g=g+1)begin:block_motion
 wire signed [31:0] dy0=$signed({1'b0,yh[g*4]})-$signed({1'b0,yc[g*4]});
 wire signed [31:0] dy1=$signed({1'b0,yh[g*4+1]})-$signed({1'b0,yc[g*4+1]});
 wire signed [31:0] dy2=$signed({1'b0,yh[g*4+2]})-$signed({1'b0,yc[g*4+2]});
 wire signed [31:0] dy3=$signed({1'b0,yh[g*4+3]})-$signed({1'b0,yc[g*4+3]});
 wire signed [31:0] du0=$signed(uh[g*4])-$signed(uc[g*4]);
 wire signed [31:0] du1=$signed(uh[g*4+1])-$signed(uc[g*4+1]);
 wire signed [31:0] du2=$signed(uh[g*4+2])-$signed(uc[g*4+2]);
 wire signed [31:0] du3=$signed(uh[g*4+3])-$signed(uc[g*4+3]);
 wire signed [31:0] dv0=$signed(vh[g*4])-$signed(vc[g*4]);
 wire signed [31:0] dv1=$signed(vh[g*4+1])-$signed(vc[g*4+1]);
 wire signed [31:0] dv2=$signed(vh[g*4+2])-$signed(vc[g*4+2]);
 wire signed [31:0] dv3=$signed(vh[g*4+3])-$signed(vc[g*4+3]);
 assign group_static[g]=(abs32(dy0+dy1+dy2+dy3)<=56)&&
                        (abs32(du0+du1+du2+du3)<=160)&&
                        (abs32(dv0+dv1+dv2+dv3)<=160);
end endgenerate
generate for(k=0;k<16;k=k+1)begin:pixel
 wire signed [31:0] dy=$signed({1'b0,yh[k]})-$signed({1'b0,yc[k]});
 wire signed [31:0] du=$signed(uh[k])-$signed(uc[k]);
 wire signed [31:0] dv=$signed(vh[k])-$signed(vc[k]);
 wire accepted=hp&&group_static[k/4]&&(abs32(dy)<=28)&&(abs32(du)<=72)&&(abs32(dv)<=72);
 wire signed [31:0] green=yb[k]-((ub[k]+vb[k]+32'sd2)>>>2);
 always @(posedge clk)begin
  if(valid)begin
  yc[k]<=cy(current[k*16+:16]);uc[k]<=cu(current[k*16+:16]);vc[k]<=cv(current[k*16+:16]);
  yh[k]<=cy(history[k*16+:16]);uh[k]<=cu(history[k*16+:16]);vh[k]<=cv(history[k*16+:16]);
  original_a[k]<=current[k*16+:16];
  end
  if(vp[0])begin
  original_b[k]<=original_a[k];
  accept_b[k]<=accepted;
  yb[k]<=$signed({1'b0,yc[k]})+((dy+32'sd2)>>>2);
  ub[k]<=$signed(uc[k])+(((du<<<1)+du+32'sd2)>>>2);
  vb[k]<=$signed(vc[k])+(((dv<<<1)+dv+32'sd2)>>>2);
  end
  if(vp[1])begin
  green_c[k]<=green;u_c[k]<=ub[k];v_c[k]<=vb[k];
  original_c[k]<=original_b[k];accept_c[k]<=accept_b[k];
  end
  if(vp[2])begin
  red_d[k]<=$signed(green_c[k])+$signed(v_c[k]);
  blue_d[k]<=$signed(green_c[k])+$signed(u_c[k]);
  green_d[k]<=green_c[k];original_d[k]<=original_c[k];accept_d[k]<=accept_c[k];
  end
  if(vp[3])begin
  original_out[k]<=original_d[k];output_pixel[k]<=accept_d[k]?{q5(red_d[k]),q6(green_d[k]),q5(blue_d[k])}:original_d[k];
  fused[k]<=accept_d[k];
  end
 end
 assign base_result[k*16+:16]=output_pixel[k];assign base_original[k*16+:16]=original_out[k];
end endgenerate
wire [4:0] f0={4'b0,fused[0]}+{4'b0,fused[1]}+{4'b0,fused[2]}+{4'b0,fused[3]};
wire [4:0] f1={4'b0,fused[4]}+{4'b0,fused[5]}+{4'b0,fused[6]}+{4'b0,fused[7]};
wire [4:0] f2={4'b0,fused[8]}+{4'b0,fused[9]}+{4'b0,fused[10]}+{4'b0,fused[11]};
wire [4:0] f3={4'b0,fused[12]}+{4'b0,fused[13]}+{4'b0,fused[14]}+{4'b0,fused[15]};
assign base_fused=f0+f1+f2+f3;
always @(posedge clk or negedge resetn)
 if(!resetn)begin vp<=0;hp<=0;base_valid<=0;end
 else begin vp<={vp[2:0],valid};hp<=use_history;base_valid<=vp[3];end
endmodule
