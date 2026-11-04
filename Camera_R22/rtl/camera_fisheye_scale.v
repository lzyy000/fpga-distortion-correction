// OpenCV fisheye: atan(r)/r * (1+k1 theta^2+...+k4 theta^8).
// A single synchronous ROM port reads neighboring samples over two cycles.
module camera_fisheye_scale #(parameter LUT_FILE="camera_fisheye_scale.hex")(
 input clk,resetn,start,input signed [31:0] r_squared,
 output reg done=0,output reg signed [31:0] scale=32'sd1048576);
`include "camera_fisheye_scale.vh"
reg [31:0] rom[0:1023];initial $readmemh(LUT_FILE,rom);
reg [2:0] st=0;reg [9:0] index=0;reg [12:0] fraction=0;
reg [31:0] q=0;reg signed [31:0] low_value=0,high_value=0;
reg signed [45:0] product=0;
wire [9:0] address=st==2 ? (index==1023?10'd1023:index+10'd1):index;
always @(posedge clk)if(st==1||st==2)q<=rom[address];
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin st<=0;done<=0;index<=0;fraction<=0;scale<=32'sd1048576;end
 else begin
  done<=0;
  case(st)
   0:if(start)begin
    if(r_squared>=32'sd8388608)begin scale<=FISHEYE_SCALE_END;done<=1;end
    else if(r_squared<=0)begin scale<=32'sd1048576;done<=1;end
    else begin index<=r_squared[22:13];fraction<=r_squared[12:0];st<=1;end
   end
   1:st<=2;
   2:begin low_value<=$signed(q);st<=3;end
   3:begin high_value<=index==1023?FISHEYE_SCALE_END:$signed(q);st<=4;end
   4:begin product<=($signed({high_value[31],high_value})-$signed({low_value[31],low_value}))*$signed({1'b0,fraction});st<=5;end
   5:begin scale<=low_value+((product+46'sd4096)>>>13);done<=1;st<=0;end
  endcase
 end
end
endmodule
