// Two parallel signed (numerator << 20)/positive denominator divisions.
// Valid callers limit normalized rays to abs(n)<=2*d. Restoring 64/32 ->32.
module dynamic_divide(input clk,resetn,start,input signed [31:0] nx,ny,input [31:0] denominator,
 output reg done=0,output reg signed [31:0] x=0,y=0);
reg busy=0,sx=0,sy=0;reg [5:0] left=0;
reg [31:0] qx=0,qy=0,d=0;reg [32:0] rx=0,ry=0;
wire [63:0] ax=({32'b0,(nx[31]?-nx:nx)}<<20);
wire [63:0] ay=({32'b0,(ny[31]?-ny:ny)}<<20);
wire [32:0] tx={rx[31:0],qx[31]},ty={ry[31:0],qy[31]};
wire bx=tx>={1'b0,d},by=ty>={1'b0,d};
wire [31:0] nextx={qx[30:0],bx},nexty={qy[30:0],by};
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin busy<=0;done<=0;x<=0;y<=0;left<=0;qx<=0;qy<=0;rx<=0;ry<=0;d<=0;sx<=0;sy<=0;end
 else begin
  done<=0;
  if(start&&!busy)begin busy<=1;left<=32;d<=denominator;sx<=nx[31];sy<=ny[31];qx<=ax[31:0];qy<=ay[31:0];rx<=ax[63:32];ry<=ay[63:32];end
  else if(busy)begin
   qx<=nextx;qy<=nexty;rx<=bx?tx-{1'b0,d}:tx;ry<=by?ty-{1'b0,d}:ty;left<=left-1;
   if(left==1)begin busy<=0;done<=1;x<=sx?-$signed(nextx):$signed(nextx);y<=sy?-$signed(nexty):$signed(nexty);end
  end
 end
end
endmodule
