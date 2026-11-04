// Inverse normalized perspective Q24, Brown Q20, source pixel output Q8.
// 19 words: optional row-yaw slope/flags, then legacy 9 homography, fx/fy/cx/cy Q8, k1/k2/p1/p2/k3 Q20.
module dynamic_map #(parameter W=1920,H=1080,FISHEYE_ENABLE=0)(
 input clk,resetn,start,input [11:0] u,v,input [607:0] cfg,
 output reg done=0,in_bounds=0,output reg signed [31:0] px=0,py=0,output reg ray_valid=0);
wire signed [31:0] c[0:18];genvar g;
generate for(g=0;g<19;g=g+1)begin:coeff assign c[g]=cfg[g*32+:32];end endgenerate
reg signed [31:0] ma[0:5],mb[0:5];wire signed [63:0] mp[0:5];
generate for(g=0;g<6;g=g+1)begin:mul dynamic_mul32 m(clk,ma[g],mb[g],mp[g]);end endgenerate
wire signed [31:0] rs_slope={{8{cfg[607]}},cfg[607:584]};
wire rs_enabled=cfg[578]&&rs_slope>=-65536&&rs_slope<=65536;
reg rs_applied=0;reg signed [31:0] rs_theta=0;
reg [5:0] st=0,resume=0;reg [2:0] delay_=0;
reg signed [63:0] radial1,radial2,nx,ny,dz,bx,by;
wire div_done;wire signed [31:0] div_x,div_y;
dynamic_divide divide(clk,resetn,st==4,nx[31:0],ny[31:0],dz[31:0],div_done,div_x,div_y);
reg signed [31:0] x,y,xx,yy,xy,r2,r4,r6,radial,tx,ty,xd,yd;
wire fisheye_selected=FISHEYE_ENABLE&&(c[17]==32'h46495348);
wire fish_done;wire signed [31:0] fish_scale;
generate if(FISHEYE_ENABLE)begin:fish
 camera_fisheye_scale radial_rom(.clk(clk),.resetn(resetn),.start(st==36&&r2>=0&&r2<=32'sd8388608),.r_squared(r2),.done(fish_done),.scale(fish_scale));
end else begin:no_fish assign fish_done=1'b0;assign fish_scale=32'sd1048576;end endgenerate
wire signed [63:0] absnx=nx<0?-nx:nx,absny=ny<0?-ny:ny;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin st<=0;done<=0;in_bounds<=0;px<=0;py<=0;resume<=0;delay_<=0;ray_valid<=0;rs_applied<=0;rs_theta<=0;end
 else begin
  done<=0;
  case(st)
   0:if(start)begin
    ma[0]<=c[0];mb[0]<=$signed({1'b0,u});ma[1]<=c[1];mb[1]<=$signed({1'b0,v});
    ma[2]<=c[3];mb[2]<=$signed({1'b0,u});ma[3]<=c[4];mb[3]<=$signed({1'b0,v});
    ma[4]<=c[6];mb[4]<=$signed({1'b0,u});ma[5]<=c[7];mb[5]<=$signed({1'b0,v});
    in_bounds<=0;ray_valid<=0;rs_applied<=0;delay_<=3;resume<=1;st<=31;
   end
   1:begin nx<=mp[0]+mp[1]+c[2];ny<=mp[2]+mp[3]+c[5];dz<=mp[4]+mp[5]+c[8];st<=2;end
   2:if(dz<1048576||dz>2147483647||absnx>(dz<<<1)||absny>(dz<<<1)||absnx>2147483647||absny>2147483647)begin
    px<=0;py<=0;done<=1;st<=0;
   end else st<=4;
   4:st<=5;
   5:if(div_done)begin x<=div_x;y<=div_y;st<=6;end
   6:begin
    ma[0]<=x;mb[0]<=x;ma[1]<=y;mb[1]<=y;ma[2]<=x;mb[2]<=y;
    delay_<=3;resume<=7;st<=31;
   end
   7:begin xx<=mp[0]>>>20;yy<=mp[1]>>>20;xy<=mp[2]>>>20;st<=8;end
   8:begin r2<=xx+yy;st<=fisheye_selected?36:9;end
   9:begin ma[0]<=r2;mb[0]<=r2;ma[1]<=c[13];mb[1]<=r2;delay_<=3;resume<=10;st<=31;end
   10:begin r4<=mp[0]>>>20;radial1<=mp[1]>>>20;st<=11;end
   11:begin
    ma[0]<=r4;mb[0]<=r2;ma[1]<=c[14];mb[1]<=r4;
    ma[2]<=c[15];mb[2]<=xy<<<1;ma[3]<=c[16];mb[3]<=r2+(xx<<<1);
    ma[4]<=c[16];mb[4]<=xy<<<1;ma[5]<=c[15];mb[5]<=r2+(yy<<<1);
    delay_<=3;resume<=12;st<=31;
   end
   12:begin r6<=mp[0]>>>20;radial2<=mp[1]>>>20;tx<=(mp[2]>>>20)+(mp[3]>>>20);ty<=(mp[4]>>>20)+(mp[5]>>>20);st<=13;end
   13:begin ma[0]<=c[17];mb[0]<=r6;delay_<=3;resume<=14;st<=31;end
   14:begin radial<=32'sd1048576+radial1+radial2+(mp[0]>>>20);st<=15;end
   15:begin ma[0]<=x;mb[0]<=radial;ma[1]<=y;mb[1]<=radial;delay_<=3;resume<=16;st<=31;end
   16:begin xd<=(mp[0]>>>20)+tx;yd<=(mp[1]>>>20)+ty;st<=17;end
   17:begin ma[0]<=xd;mb[0]<=c[9];ma[1]<=yd;mb[1]<=c[10];delay_<=3;resume<=18;st<=31;end
   18:begin bx<=(mp[0]>>>20)+c[11];by<=(mp[1]>>>20)+c[12];st<=19;end
   19:if(rs_enabled&&!rs_applied&&rs_slope!=0&&bx>=0&&by>=0&&bx<(W-1)*256&&by<(H-1)*256)begin
    // Source-row lookup, not output row: pan/tilt/crop can change where a
    // destination node samples the sensor. Reuse the same multipliers/divider.
    ma[0]<=rs_slope;mb[0]<=by-(H-1)*128;delay_<=3;resume<=32;st<=31;
   end else begin px<=bx[31:0];py<=by[31:0];ray_valid<=1;in_bounds<=bx>=0&&by>=0&&bx<(W-1)*256&&by<(H-1)*256;done<=1;st<=0;end
   32:begin rs_theta<=mp[0]>>>18;st<=33;end
   33:begin ma[0]<=rs_theta;mb[0]<=x;delay_<=3;resume<=34;st<=31;end
   34:begin
    // Inverse small yaw: (x-theta,y,1+theta*x). Homogeneous Q24 scale
    // preserves the original divide validity thresholds. One bounded iterate.
    nx<=($signed({x[31],x})-rs_theta)<<<4;ny<=$signed(y)<<<4;
    dz<=(64'sd1048576+(mp[0]>>>20))<<<4;rs_applied<=1;st<=2;
   end
   36:if(r2<0||r2>32'sd8388608)begin px<=0;py<=0;done<=1;ray_valid<=0;in_bounds<=0;st<=0;end else st<=37;
   37:if(fish_done)begin radial<=fish_scale;tx<=0;ty<=0;st<=15;end
   31:if(delay_==0)st<=resume;else delay_<=delay_-1;
   default:st<=0;
  endcase
 end
end
endmodule
