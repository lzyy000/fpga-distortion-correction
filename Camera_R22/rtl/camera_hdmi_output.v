// Camera output and fallback test pattern share identical sync/DE latency.
// Source changes only in vertical blank, never part way through a picture.
module camera_hdmi_output(
 input clk,resetn,vs,hs,de,display_valid,force_pattern,
 input pixel_de,input [15:0] pixel,
 output reg pattern_active=1,
 output reg vs_out=0,hs_out=0,de_out=0,
 output reg [7:0] r_out=0,g_out=0,b_out=0);
(* ASYNC_REG="TRUE" *) reg valid_meta=0,valid_sync=0;
(* ASYNC_REG="TRUE" *) reg force_meta=0,force_sync=0;
reg vs_d=0;
reg [1:0] hs_delay=0,vs_delay=0,de_delay=0;
reg [10:0] pattern_x=0;
reg [23:0] pattern_p1=0,pattern_p2=0;
wire [23:0] pattern_rgb = pattern_x<160 ? 24'hffffff :
 pattern_x<320 ? 24'hffff00 : pattern_x<480 ? 24'h00ffff :
 pattern_x<640 ? 24'h00ff00 : pattern_x<800 ? 24'hff00ff :
 pattern_x<960 ? 24'hff0000 : pattern_x<1120 ? 24'h0000ff : 24'h000000;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  valid_meta<=0;valid_sync<=0;force_meta<=0;force_sync<=0;
  vs_d<=0;pattern_active<=1;hs_delay<=0;vs_delay<=0;de_delay<=0;
  pattern_x<=0;pattern_p1<=0;pattern_p2<=0;
  vs_out<=0;hs_out<=0;de_out<=0;r_out<=0;g_out<=0;b_out<=0;
 end else begin
  valid_meta<=display_valid;valid_sync<=valid_meta;
  force_meta<=force_pattern;force_sync<=force_meta;
  vs_d<=vs;
  if(vs&&!vs_d)pattern_active<=force_sync||!valid_sync;
  hs_delay<={hs_delay[0],hs};vs_delay<={vs_delay[0],vs};de_delay<={de_delay[0],de};
  if(de)pattern_x<=pattern_x+1'b1;else pattern_x<=0;
  pattern_p1<=de?pattern_rgb:24'b0;pattern_p2<=pattern_p1;
  hs_out<=hs_delay[1];vs_out<=vs_delay[1];
  de_out<=pattern_active?de_delay[1]:pixel_de;
  if(pattern_active&&de_delay[1])begin
   r_out<=pattern_p2[23:16];g_out<=pattern_p2[15:8];b_out<=pattern_p2[7:0];
  end else if(!pattern_active&&pixel_de)begin
   r_out<={pixel[15:11],3'b0};g_out<={pixel[10:5],2'b0};b_out<={pixel[4:0],3'b0};
  end else begin r_out<=0;g_out<=0;b_out<=0;end
 end
end
endmodule
