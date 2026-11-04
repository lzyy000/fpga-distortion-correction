// Six row banks: process a 5-row neighbourhood while the next row writes.
// Right/bottom replication is real pixel data, never zero padding.
module camera_spatial_stream_r21 #(parameter W=1920,H=1080)(
 input clk,resetn,enable,input [8:0] strength,input in_ce,in_vs,in_de,in_bad,input [23:0] in_rgb,
 output reg out_vs=0,output reg out_de=0,output reg [15:0] out_rgb=0,
 output reg out_bad=0,output frame_start,output reg [15:0] out_raw=0);
reg [12:0] ix=0,iy=0,oy=0,oy_d=0,col=0,col_d=0;
reg vd=0,hd=0,seen=0,frame_bad=0,active=0,valid_d=0;
reg pending_vs=0,pending_bad=0;reg [1:0] tails=0;
reg [2:0] write_base=0,read_base=0,read_base_d=0;
wire vs_edge=in_ce&&in_vs&&!vd;
wire invalid_vs=in_bad||frame_bad||(seen&&(iy!=H||ix!=0||in_de));
wire kill=vs_edge&&invalid_vs;
wire [12:0] ra=col>=W?W-1:col;
wire write_pixel=in_ce&&seen&&in_de&&!frame_bad&&ix<W&&iy<H;
wire row_finished=in_ce&&seen&&!in_de&&hd&&!vs_edge;
wire launch_line=row_finished&&!frame_bad&&ix==W&&iy<H&&iy>=2&&(!active||col==W+1);
function [2:0] bank;input [12:0] row;begin bank=row%6;end endfunction
reg [23:0] ram0[0:W-1];reg [23:0] q0;
always @(posedge clk)begin
 if(write_pixel&&bank(iy+write_base)==0)ram0[ix]<=in_rgb;
 if(active)q0<=ram0[ra];
end
reg [23:0] ram1[0:W-1];reg [23:0] q1;
always @(posedge clk)begin
 if(write_pixel&&bank(iy+write_base)==1)ram1[ix]<=in_rgb;
 if(active)q1<=ram1[ra];
end
reg [23:0] ram2[0:W-1];reg [23:0] q2;
always @(posedge clk)begin
 if(write_pixel&&bank(iy+write_base)==2)ram2[ix]<=in_rgb;
 if(active)q2<=ram2[ra];
end
reg [23:0] ram3[0:W-1];reg [23:0] q3;
always @(posedge clk)begin
 if(write_pixel&&bank(iy+write_base)==3)ram3[ix]<=in_rgb;
 if(active)q3<=ram3[ra];
end
reg [23:0] ram4[0:W-1];reg [23:0] q4;
always @(posedge clk)begin
 if(write_pixel&&bank(iy+write_base)==4)ram4[ix]<=in_rgb;
 if(active)q4<=ram4[ra];
end
reg [23:0] ram5[0:W-1];reg [23:0] q5;
always @(posedge clk)begin
 if(write_pixel&&bank(iy+write_base)==5)ram5[ix]<=in_rgb;
 if(active)q5<=ram5[ra];
end
function [23:0] select_q;input [2:0] b;input [23:0] a,c,d,e,f,g;
begin case(b)0:select_q=a;1:select_q=c;2:select_q=d;3:select_q=e;4:select_q=f;default:select_q=g;endcase end
endfunction
function [12:0] clamped;input signed [14:0] y;
begin clamped=y<0?0:y>=H?H-1:y[12:0];end endfunction
wire [599:0] taps;
wire [23:0] z0=select_q(bank(clamped($signed({2'b0,oy_d})+15'sd0-15'sd2)+read_base_d),q0,q1,q2,q3,q4,q5);
reg [23:0] h00=0,h01=0,h02=0,h03=0;
always @(posedge clk)if(valid_d)begin
 if(col_d==0)begin h00<=z0;h01<=z0;h02<=z0;h03<=z0;end
 else begin h00<=h01;h01<=h02;h02<=h03;h03<=z0;end
end
assign taps[0+:120]={z0,h03,h02,h01,h00};
wire [23:0] z1=select_q(bank(clamped($signed({2'b0,oy_d})+15'sd1-15'sd2)+read_base_d),q0,q1,q2,q3,q4,q5);
reg [23:0] h10=0,h11=0,h12=0,h13=0;
always @(posedge clk)if(valid_d)begin
 if(col_d==0)begin h10<=z1;h11<=z1;h12<=z1;h13<=z1;end
 else begin h10<=h11;h11<=h12;h12<=h13;h13<=z1;end
end
assign taps[120+:120]={z1,h13,h12,h11,h10};
wire [23:0] z2=select_q(bank(clamped($signed({2'b0,oy_d})+15'sd2-15'sd2)+read_base_d),q0,q1,q2,q3,q4,q5);
reg [23:0] h20=0,h21=0,h22=0,h23=0;
always @(posedge clk)if(valid_d)begin
 if(col_d==0)begin h20<=z2;h21<=z2;h22<=z2;h23<=z2;end
 else begin h20<=h21;h21<=h22;h22<=h23;h23<=z2;end
end
assign taps[240+:120]={z2,h23,h22,h21,h20};
wire [23:0] z3=select_q(bank(clamped($signed({2'b0,oy_d})+15'sd3-15'sd2)+read_base_d),q0,q1,q2,q3,q4,q5);
reg [23:0] h30=0,h31=0,h32=0,h33=0;
always @(posedge clk)if(valid_d)begin
 if(col_d==0)begin h30<=z3;h31<=z3;h32<=z3;h33<=z3;end
 else begin h30<=h31;h31<=h32;h32<=h33;h33<=z3;end
end
assign taps[360+:120]={z3,h33,h32,h31,h30};
wire [23:0] z4=select_q(bank(clamped($signed({2'b0,oy_d})+15'sd4-15'sd2)+read_base_d),q0,q1,q2,q3,q4,q5);
reg [23:0] h40=0,h41=0,h42=0,h43=0;
always @(posedge clk)if(valid_d)begin
 if(col_d==0)begin h40<=z4;h41<=z4;h42<=z4;h43<=z4;end
 else begin h40<=h41;h41<=h42;h42<=h43;h43<=z4;end
end
assign taps[480+:120]={z4,h43,h42,h41,h40};
wire core_de,core_busy;wire [15:0] core_rgb,core_raw;
camera_spatial_core_r21 filter(.clk(clk),.resetn(resetn),.clear(kill||frame_bad),.enable(enable),.strength(strength),
 .valid(valid_d&&col_d>=2&&!frame_bad&&!kill),.pixels(taps),
 .out_valid(core_de),.out_pixel(core_rgb),.out_original(core_raw),.busy(core_busy));
reg vs_i=0,bad_i=0;
// Previous frame, including replicated bottom rows and core pipeline, is drained.
// External mode registers can change here before any new-frame pixels issue.
assign frame_start=pending_vs&&!active&&!valid_d&&tails==0&&!core_busy&&!core_de;
wire de_i=core_de&&!frame_bad&&!kill;
always @(posedge clk or negedge resetn)
 if(!resetn)begin out_vs<=0;out_de<=0;out_bad<=0;out_rgb<=0;out_raw<=0;end
 else begin out_vs<=vs_i;out_de<=de_i;out_bad<=bad_i;out_rgb<=core_rgb;out_raw<=core_raw;end
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  ix<=0;iy<=0;oy<=0;oy_d<=0;col<=0;col_d<=0;vd<=0;hd<=0;seen<=0;frame_bad<=0;
  active<=0;valid_d<=0;tails<=0;pending_vs<=0;pending_bad<=0;vs_i<=0;bad_i<=0;write_base<=0;read_base<=0;read_base_d<=0;
 end else begin
  if(in_ce)begin vd<=in_vs;hd<=in_de;end
  valid_d<=active;col_d<=col;oy_d<=oy;read_base_d<=read_base;vs_i<=0;bad_i<=frame_bad;
  if(frame_start)begin
   vs_i<=1;bad_i<=pending_bad;pending_vs<=0;
  end
  if(vs_edge)begin
   pending_vs<=1;pending_bad<=invalid_vs;ix<=0;iy<=0;seen<=1;frame_bad<=0;
   if(seen)write_base<=bank(write_base+H);
   if(invalid_vs)begin active<=0;valid_d<=0;tails<=0;end
  end else begin
   if(in_ce&&seen&&in_de)begin
    if(ix>=W||iy>=H)frame_bad<=1;else ix<=ix+1'b1;
   end
   if(in_ce&&seen&&!in_de&&hd)begin
    ix<=0;iy<=iy+1'b1;
    if(ix!=W||iy>=H||(iy>=2&&active&&col!=W+1))frame_bad<=1;
    else if(!frame_bad&&iy==H-1)tails<=2;
   end
  end
  if(active)begin
   if(col==W+1)begin active<=0;col<=0;end else col<=col+1'b1;
  end
  // The demosaic emits its final two rows only two clocks apart. Row issue
  // therefore chains without an idle cycle; delayed row tags follow RAM data.
  if(launch_line)begin
   active<=1;col<=0;oy<=iy-2;if(iy==2)read_base<=write_base;
  end else if((!active||col==W+1)&&tails!=0&&!frame_bad&&!kill)begin
   tails<=tails-1'b1;oy<=oy+1'b1;active<=1;col<=0;
  end
  // Invalid geometry cancels all buffered work from the preceding frame.
  if(kill)begin active<=0;valid_d<=0;tails<=0;end
 end
end
endmodule
