// DVP control transitions must persist for four byte clocks. Data is delayed
// by the identical amount so qualified HREF retains the first and last byte.
// Short control glitches are rejected; real short/extra lines still fail capture.
module camera_dvp_qualifier #(parameter N=4)(
 input clk,resetn,input [9:0] raw,
 output [9:0] qualified,
 output reg [15:0] vs_glitch_gray=0,href_glitch_gray=0);
localparam B=(N>1)?$clog2(N):1;
reg stable_vs=0,stable_href=0;
reg [B-1:0] vs_run=0,href_run=0;
reg [15:0] vs_glitches=0,href_glitches=0;
reg [7:0] data_pipe[0:N-1];integer i;
wire [15:0] next_vs=vs_glitches+1'b1,next_href=href_glitches+1'b1;
assign qualified={stable_vs,stable_href,data_pipe[N-1]};
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  stable_vs<=0;stable_href<=0;vs_run<=0;href_run<=0;
  vs_glitches<=0;href_glitches<=0;vs_glitch_gray<=0;href_glitch_gray<=0;
  for(i=0;i<N;i=i+1)data_pipe[i]<=0;
 end else begin
  data_pipe[0]<=raw[7:0];for(i=1;i<N;i=i+1)data_pipe[i]<=data_pipe[i-1];
  if(raw[9]==stable_vs)begin
   if(vs_run!=0)begin vs_glitches<=next_vs;vs_glitch_gray<=next_vs^(next_vs>>1);end
   vs_run<=0;
  end else if(vs_run==N-1)begin stable_vs<=raw[9];vs_run<=0;end
  else vs_run<=vs_run+1'b1;
  if(raw[8]==stable_href)begin
   if(href_run!=0)begin href_glitches<=next_href;href_glitch_gray<=next_href^(next_href>>1);end
   href_run<=0;
  end else if(href_run==N-1)begin stable_href<=raw[8];href_run<=0;end
  else href_run<=href_run+1'b1;
 end
end
endmodule
