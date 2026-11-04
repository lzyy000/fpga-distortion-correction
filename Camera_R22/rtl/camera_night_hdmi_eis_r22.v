// The split left preview is pristine. The right preview and full processed
// view use Gamma unless correction has already baked it into DDR pixels.
// Whole payload crosses in vertical blank and commits at VS falling edge.
module camera_night_hdmi_eis_r22(input clk,resetn,input [3:0] slot_curve,input [8:0] slot_strength,
 input [1:0] view_mode,input display_corrected,pattern_active,
 input vs,hs,de,input [7:0] r,g,b,
 output vs_out,hs_out,de_out,output [7:0] r_out,g_out,b_out);
(* ASYNC_REG="TRUE" *) reg [15:0] meta=7,sync=7;
reg [8:0] strength=0;reg [3:0] curve=7;reg [1:0] mode=0;reg corrected=0;
reg vd=0;reg [10:0] x=0;
reg [5:0] vs_pipe=0,hs_pipe=0,de_pipe=0;
wire left_original=mode[1]&&x<960;
wire raw_view=!corrected;
wire [3:0] selected=(raw_view&&!left_original&&!pattern_active)?curve:4'd7;
wire [15:0] pixel={r[7:3],g[7:2],b[7:3]};wire [15:0] processed;
wire ov;
camera_night_pixel_r19 filter(.clk(clk),.resetn(resetn),.in_valid(de),.curve(selected),.strength(strength),.pixel(pixel),.out_valid(ov),.result(processed));
always @(posedge clk or negedge resetn)
 if(!resetn)begin meta<=7;sync<=7;strength<=0;curve<=7;mode<=0;corrected<=0;vd<=0;x<=0;vs_pipe<=0;hs_pipe<=0;de_pipe<=0;end
 else begin
  meta<={slot_strength,display_corrected,view_mode,slot_curve};sync<=meta;vd<=vs;
  if(vd&&!vs)begin strength<=sync[15:7];corrected<=sync[6];mode<=sync[5:4];curve<=sync[3:0];end
  if(de)x<=x+1'b1;else x<=0;
  vs_pipe<={vs_pipe[4:0],vs};hs_pipe<={hs_pipe[4:0],hs};de_pipe<={de_pipe[4:0],de};
 end
assign vs_out=vs_pipe[5];assign hs_out=hs_pipe[5];assign de_out=de_pipe[5];
assign r_out=ov?{processed[15:11],3'b0}:8'b0;
assign g_out=ov?{processed[10:5],2'b0}:8'b0;
assign b_out=ov?{processed[4:0],3'b0}:8'b0;
endmodule
