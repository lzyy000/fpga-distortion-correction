// Pango RTL adaptation of map-driven remap used by Vitis Vision.
// Signed 32-bit Q5 x/y maps; RGB565 samples; bilinear, constant-black border.
module image_remap #(
 parameter W=1920,H=1080,CW=1920,CH=1080,PANEL_SCALE=2,
 parameter SRC_BASE=32'h01000000,MAP_BASE=32'h02000000,DST_BASE=32'h04000000,
 parameter CANVAS_A=32'h00000000,CANVAS_B=32'h00400000
)(input clk,resetn,start,input display_bank,display_valid,
 output reg busy=0,done=0,commit_req=0,output reg commit_bank=0,
 output reg [31:0] progress=0,
 output reg req,output reg [31:0] addr,wdata,output reg [3:0] wstrb,
 input ready,input [31:0] rdata,rnext,output flush,input flushed);
// Full-resolution processing; each panel samples every PANEL_SCALE pixels.
localparam PW=W/PANEL_SCALE,PH=H/PANEL_SCALE;
localparam XOFF=(CW/2-PW)/2,RIGHT_XOFF=CW/2+XOFF,YOFF=(CH-PH)/2;
localparam IDLE=0,MAP=1,PREP=2,SAMPLE=3,HORIZ=4,VERT=5,ROUND=6,WRITE=7,
 CAN_PREP=8,CAN_READ=9,CAN_WRITE=10,COMMIT=11,MAP_Y=12,CAN_READ_SECOND=13,CAN_ROW=14,CAN_ADDR=15,FLUSH=16;
reg [4:0] state=0;
assign flush=(state==FLUSH);
reg [31:0] index=0;
reg signed [26:0] sx,sy;
reg [15:0] canvas_first;
reg [11:0] panel_x,panel_y;
reg [31:0] panel_row,panel_base;
reg [4:0] fx,fy;
reg [1:0] n;
reg [15:0] p[0:3],pixel;
reg [10:0] hr0,hr1,hg0,hg1,hb0,hb1;
reg [16:0] vr,vg,vb;
reg [11:0] cx,cy;
reg [31:0] sample_addr;
wire signed [27:0] nx=$signed(sx)+$signed({27'b0,n[0]});
wire signed [27:0] ny=$signed(sy)+$signed({27'b0,n[1]});
wire sample_ok=(nx>=0 && nx<W && ny>=0 && ny<H);
wire canvas_y=(cy>=YOFF && cy<YOFF+PH);
wire canvas_left=canvas_y && cx>=XOFF && cx<XOFF+PW;
wire canvas_right=canvas_y && cx>=RIGHT_XOFF && cx<RIGHT_XOFF+PW;
reg [31:0] canvas_pair;
wire [31:0] canvas_base=commit_bank ? CANVAS_B : CANVAS_A;
always @* begin
 req=0;addr=0;wdata=0;wstrb=0;
 case(state)
  MAP:begin req=1;addr=MAP_BASE+(index<<3);end
  MAP_Y:begin req=1;addr=MAP_BASE+(index<<3)+4;end
  SAMPLE:begin req=1;addr=sample_addr&32'hfffffffc;end
  WRITE:begin req=1;addr=DST_BASE+((index<<1)&32'hfffffffc);
   wdata=index[0]?{pixel,16'b0}:{16'b0,pixel};wstrb=index[0]?4'b1100:4'b0011;end
  CAN_READ,CAN_READ_SECOND:begin req=1;addr=sample_addr&32'hfffffffc;end
  CAN_WRITE:begin req=1;addr=canvas_base+((cy*CW+cx)<<1);wdata=canvas_pair;wstrb=4'hf;end
 endcase
end
always @(posedge clk or negedge resetn) begin
 if(!resetn) begin state<=IDLE;busy<=0;done<=0;commit_req<=0;commit_bank<=0;progress<=0;index<=0;end
 else case(state)
  IDLE:if(start) begin busy<=1;done<=0;commit_req<=0;commit_bank<=~display_bank;index<=0;progress<=0;state<=MAP;end
  MAP:if(ready) begin sx<=$signed(rdata)>>>5;fx<=rdata[4:0];
   sy<=$signed(rnext)>>>5;fy<=rnext[4:0];n<=0;state<=PREP;end
  MAP_Y:if(ready)begin sy<=$signed(rdata)>>>5;fy<=rdata[4:0];n<=0;state<=PREP;end
  PREP:if(sample_ok) begin sample_addr<=SRC_BASE+((ny[11:0]*W+nx[11:0])<<1);state<=SAMPLE;end
   else begin p[n]<=0;if(n==3)state<=HORIZ;else n<=n+1'b1;end
  SAMPLE:if(ready) begin p[n]<=sample_addr[1]?rdata[31:16]:rdata[15:0];
   // When the first neighbor is word-aligned, both horizontal samples are
   // already in this word. Never pair across a border or an odd pixel address.
   if(!n[0] && !sample_addr[1] && sx<W-1)begin
    p[n+1'b1]<=rdata[31:16];
    if(n==2)state<=HORIZ;else begin n<=n+2'd2;state<=PREP;end
   end else if(n==3)state<=HORIZ;else begin n<=n+1'b1;state<=PREP;end end
  HORIZ:begin
   hr0<=p[0][15:11]*(6'd32-{1'b0,fx})+p[1][15:11]*{1'b0,fx};
   hr1<=p[2][15:11]*(6'd32-{1'b0,fx})+p[3][15:11]*{1'b0,fx};
   hg0<=p[0][10:5]*(6'd32-{1'b0,fx})+p[1][10:5]*{1'b0,fx};
   hg1<=p[2][10:5]*(6'd32-{1'b0,fx})+p[3][10:5]*{1'b0,fx};
   hb0<=p[0][4:0]*(6'd32-{1'b0,fx})+p[1][4:0]*{1'b0,fx};
   hb1<=p[2][4:0]*(6'd32-{1'b0,fx})+p[3][4:0]*{1'b0,fx};state<=VERT;
  end
  VERT:begin
   vr<=hr0*(6'd32-{1'b0,fy})+hr1*{1'b0,fy}+17'd512;
   vg<=hg0*(6'd32-{1'b0,fy})+hg1*{1'b0,fy}+17'd512;
   vb<=hb0*(6'd32-{1'b0,fy})+hb1*{1'b0,fy}+17'd512;state<=ROUND;
  end
  ROUND:begin pixel<={vr[14:10],vg[15:10],vb[14:10]};state<=WRITE;end
  WRITE:if(ready) begin progress<=index+1;
   if(index==W*H-1)begin cx<=0;cy<=0;state<=CAN_PREP;end
   else begin index<=index+1;state<=MAP;end end
  CAN_PREP:if(canvas_left)begin
   panel_base<=SRC_BASE;panel_x<=(cx-XOFF)*PANEL_SCALE;panel_y<=(cy-YOFF)*PANEL_SCALE;state<=CAN_ROW;
  end else if(canvas_right)begin
   panel_base<=DST_BASE;panel_x<=(cx-RIGHT_XOFF)*PANEL_SCALE;panel_y<=(cy-YOFF)*PANEL_SCALE;state<=CAN_ROW;
  end else begin canvas_pair<=0;state<=CAN_WRITE;end
  CAN_ROW:begin panel_row<=panel_y*W;state<=CAN_ADDR;end
  CAN_ADDR:begin sample_addr<=panel_base+((panel_row+panel_x)<<1);state<=CAN_READ;end
  CAN_READ:if(ready)begin
   if(PANEL_SCALE==1)begin canvas_pair<=rdata;state<=CAN_WRITE;end
   else begin canvas_first<=sample_addr[1]?rdata[31:16]:rdata[15:0];sample_addr<=sample_addr+2*PANEL_SCALE;state<=CAN_READ_SECOND;end
  end
  CAN_READ_SECOND:if(ready)begin canvas_pair<={sample_addr[1]?rdata[31:16]:rdata[15:0],canvas_first};state<=CAN_WRITE;end
  CAN_WRITE:if(ready)begin
   if(cx==CW-2)begin cx<=0;if(cy==CH-1)begin state<=FLUSH;end
    else begin cy<=cy+1'b1;state<=CAN_PREP;end end
   else begin cx<=cx+2;state<=CAN_PREP;end
  end
  FLUSH:if(flushed)begin commit_req<=1;state<=COMMIT;end
  COMMIT:if(display_valid && display_bank==commit_bank)begin commit_req<=0;busy<=0;done<=1;state<=IDLE;end
  default:state<=IDLE;
 endcase
end
endmodule
