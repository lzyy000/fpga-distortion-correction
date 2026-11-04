// R14 on-board Brown-Conrady map generator. One shared pipelined multiplier.
// All five measured coefficients; fractional fx/fy and noncentral cx/cy.
// Writes signed Q5 x/y pairs to DDR. Original display/capture run during init.
module camera_map_init #(parameter W=1920,H=1080,FIRST_ROW=0,LAST_ROW=H-1,MAP_BASE=32'h03000000,PACKED_MAP=0)(
 input clk,resetn,start,output reg busy=0,ready=0,output reg [31:0] cycles=0,
 output [31:0] progress,
 output req,write,output [31:0] addr,output [15:0] beats,input accept,
 output reg [255:0] wdata,input take,mem_done);
`include "camera_calibration.vh"
localparam IDLE=0,CALC=1,CMD=2,DATA=3;
reg [1:0] state=0;reg [2:0] phase=0;
reg [4:0] step=0;reg [11:0] u=0,v=0;
localparam MAP_BITS=PACKED_MAP?32:64,MAP_SHIFT=PACKED_MAP?3:2;
localparam PACKET_PIXELS=PACKED_MAP?128:64;
reg [31:0] offset=0;reg [6:0] pixel_count=0;reg [3:0] tx_count=0;
reg last_packet=0;
reg signed [31:0] x,y,xx,yy,xy,r2,t,radial,xr,yr,tx,ty,xd,yd,qx;
reg signed [31:0] a,b,ma,mb;
wire signed [63:0] product_p;
camera_mul32_pipe multiplier(.clk(clk),.a(ma),.b(mb),.result(product_p));
wire signed [31:0] rounded=(product_p+64'sd536870912)>>>30;
wire signed [63:0] cx_bias=$signed(CX16)*64'sd1073741824;
wire signed [63:0] cy_bias=$signed(CY16)*64'sd1073741824;
wire signed [31:0] coord_x=(product_p+cx_bias+64'sd1099511627776)>>>41;
wire signed [31:0] coord_y=(product_p+cy_bias+64'sd1099511627776)>>>41;
// Compact Q5: preserve [-32, size*32) exactly, including the -1 pixel
// border used by bilinear interpolation. All other coordinates have zero
// contribution and use positive size*32 as their out-of-range sentinel.
// The code space 0xffe0..0xffff is reserved for -32..-1; W/H <= 2046.
function [15:0] pack_axis;
 input signed [31:0] q;input [31:0] size;
 begin pack_axis=(q>=-32&&q<$signed(size*32))?q[15:0]:(size*32);end
endfunction
wire [3:0] packet_index=pixel_count>>MAP_SHIFT;
wire [2:0] packet_lane=PACKED_MAP?pixel_count[2:0]:{1'b0,pixel_count[1:0]};
reg [255:0] packet[0:15];
// Synchronous packet output, with a registered index one word ahead.
// CMD preloads word zero. Acceptance advances only the index to word one.
// Each TAKE consumes the old output and loads the already addressed next word.
// TAKE drives clock enables only, never the packet read address or data mux.
assign req=state==CMD;assign write=1'b1;assign addr=MAP_BASE+offset;assign beats=16;
assign progress={8'b0,v,u};
always @*begin
 a=0;b=0;
 if(!resetn)begin a=0;b=0;end else case(step)
  0:begin a=$signed({20'b0,u});b=INV_FX;end
  1:begin a=$signed({20'b0,v});b=INV_FY;end
  2:begin a=x;b=x;end
  3:begin a=y;b=y;end
  4:begin a=x;b=y;end
  5:begin a=r2;b=K3;end
  6:begin a=r2;b=K2+t;end
  7:begin a=r2;b=K1+t;end
  8:begin a=x;b=radial;end
  9:begin a=y;b=radial;end
  10:begin a=P1;b=xy<<<1;end
  11:begin a=P2;b=r2+(xx<<<1);end
  12:begin a=P1;b=r2+(yy<<<1);end
  13:begin a=P2;b=xy<<<1;end
  14:begin a=xd;b=FX16;end
  15:begin a=yd;b=FY16;end
 endcase
end
// No resets on multiplier or packet RAM: DSP/BRAM inference remains enabled.
always @(posedge clk)begin
 if(state==CMD||(state==DATA&&take))wdata<=packet[tx_count];
 if(state==CALC&&phase==0)begin ma<=a;mb<=b;end
 if(state==CALC&&phase==6&&step==15)begin
  if(PACKED_MAP)packet[packet_index][packet_lane*32+:32]<={pack_axis(coord_y,H),pack_axis(qx,W)};
  else packet[packet_index][packet_lane*64+:64]<={coord_y,qx};
 end

end
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin state<=IDLE;busy<=0;ready<=0;cycles<=0;phase<=0;step<=0;u<=0;v<=0;offset<=0;pixel_count<=0;tx_count<=0;last_packet<=0;end
 else begin
  if(busy)cycles<=cycles+1;
  case(state)
   IDLE:if(start&&!ready)begin busy<=1;cycles<=0;u<=0;v<=FIRST_ROW;offset<=FIRST_ROW*W*(MAP_BITS/8);pixel_count<=0;phase<=0;step<=0;state<=CALC;end
   CALC:begin
    phase<=phase==6?0:phase+1'b1;
    if(phase==6)begin
     step<=step+1'b1;
     case(step)
      0:x<=product_p-$signed(CX_NORM);
      1:y<=product_p-$signed(CY_NORM);
      2:xx<=rounded;
      3:begin yy<=rounded;r2<=xx+rounded;end
      4:xy<=rounded;
      5,6:t<=rounded;
      7:radial<=32'sd1073741824+rounded;
      8:xr<=rounded;
      9:yr<=rounded;
      10:tx<=rounded;
      11:xd<=xr+tx+rounded;
      12:ty<=rounded;
      13:yd<=yr+ty+rounded;
      14:qx<=coord_x;
      15:begin
       step<=0;pixel_count<=pixel_count==PACKET_PIXELS-1?0:pixel_count+1'b1;
       if(u==W-1)begin u<=0;v<=v+1'b1;end else u<=u+1'b1;
       if(pixel_count==PACKET_PIXELS-1)begin tx_count<=0;last_packet<=(v==LAST_ROW&&u==W-1);state<=CMD;end
      end
     endcase
    end
   end
   CMD:if(accept)begin tx_count<=1;state<=DATA;end
   DATA:begin
    if(take)tx_count<=tx_count+1'b1;
    if(mem_done)begin
     if(last_packet)begin ready<=1;busy<=0;state<=IDLE;end
     else begin offset<=offset+512;state<=CALC;end
    end
   end
  endcase
 end
end
endmodule
