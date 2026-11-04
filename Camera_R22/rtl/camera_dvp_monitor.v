// Passive DVP diagnostics. Gray counters cross to DDR/core clock.
// PCLK is counted in groups of 256; levels bit2=p_resetn, bit1=VS, bit0=HREF.
// Last-line snapshot is diagnostic-only, held between lines (not control data).
module camera_dvp_monitor(
 input pclk,p_resetn,vs,href,clk,resetn,
 output [23:0] ticks256,output [15:0] vs_edges,href_edges,
 output [12:0] last_line_bytes,output [2:0] levels);
reg [7:0] prescale=0;
reg [23:0] ticks=0,tg=0;
reg [15:0] vc=0,hc=0,vg=0,hg=0;
reg vd=0,hd=0;reg [12:0] width=0,last_width=0;
wire [23:0] next_tick=ticks+1'b1;
wire [15:0] next_v=vc+1'b1,next_h=hc+1'b1;
always @(posedge pclk or negedge p_resetn)begin
 if(!p_resetn)begin prescale<=0;ticks<=0;tg<=0;vc<=0;hc<=0;vg<=0;hg<=0;vd<=0;hd<=0;width<=0;last_width<=0;end
 else begin
  prescale<=prescale+1'b1;
  if(&prescale)begin ticks<=next_tick;tg<=next_tick^(next_tick>>1);end
  vd<=vs;hd<=href;
  if(vs&&!vd)begin vc<=next_v;vg<=next_v^(next_v>>1);end
  if(href&&!hd)begin hc<=next_h;hg<=next_h^(next_h>>1);end
  if(href)begin if(width!=13'h1fff)width<=width+1'b1;end
  else begin if(hd)last_width<=width;width<=0;end
 end
end
(* ASYNC_REG="TRUE" *) reg [23:0] t1=0,t2=0;
(* ASYNC_REG="TRUE" *) reg [15:0] v1=0,v2=0,h1=0,h2=0;
(* ASYNC_REG="TRUE" *) reg [12:0] w1=0,w2=0;
(* ASYNC_REG="TRUE" *) reg [2:0] l1=0,l2=0;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin t1<=0;t2<=0;v1<=0;v2<=0;h1<=0;h2<=0;w1<=0;w2<=0;l1<=0;l2<=0;end
 else begin t1<=tg;t2<=t1;v1<=vg;v2<=v1;h1<=hg;h2<=h1;w1<=last_width;w2<=w1;l1<={p_resetn,vs,href};l2<=l1;end
end
function [23:0] decode24;input [23:0] g;integer i;
 begin decode24[23]=g[23];for(i=22;i>=0;i=i-1)decode24[i]=decode24[i+1]^g[i];end
endfunction
function [15:0] decode16;input [15:0] g;integer i;
 begin decode16[15]=g[15];for(i=14;i>=0;i=i-1)decode16[i]=decode16[i+1]^g[i];end
endfunction
assign ticks256=decode24(t2);assign vs_edges=decode16(v2);assign href_edges=decode16(h2);
assign last_line_bytes=w2;assign levels=l2;
endmodule
