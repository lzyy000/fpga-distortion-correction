// Frame-selected, bounded Gamma on HSV V via common RGB gain (Q8).
// Four clocks latency, one pixel/clock. Curve 7 is bit-exact identity.
module camera_night_pixel_r19 #(parameter ROM_FILE="night_gain.hex")(
 input clk,resetn,in_valid,input [3:0] curve,input [8:0] strength,input [15:0] pixel,
 output out_valid,output [15:0] result);
reg base_valid=0;reg [15:0] base_result=0,base_original;
reg [8:0] s1,s2,s3,s4;
camera_strength_blend_r19 mix(.clk(clk),.resetn(resetn),.valid(base_valid),.strength(s4),.original(base_original),.processed(base_result),.out_valid(out_valid),.result(result));
reg [10:0] gain_rom[0:4095];
initial $readmemh(ROM_FILE,gain_rom);
wire [7:0] r={pixel[15:11],3'b0},g={pixel[10:5],2'b0},b={pixel[4:0],3'b0};
wire [7:0] rg=r>g?r:g;
wire [7:0] value=rg>b?rg:b;
reg [11:0] address;
reg [15:0] p1,p2,p3;
reg [10:0] gain;
reg [15:0] mr,mb;reg [16:0] mg;
reg v1=0,v2=0,v3=0,id1=1,id2=1,id3=1;
wire [16:0] rr={1'b0,mr}+17'd128,bb={1'b0,mb}+17'd128;
wire [17:0] gg={1'b0,mg}+18'd128;
always @(posedge clk)begin
 s1<=strength;s2<=s1;s3<=s2;s4<=s3;base_original<=p3;
 address<={curve,value};p1<=pixel;
 gain<=gain_rom[address];p2<=p1;
 mr<=p2[15:11]*gain;mg<=p2[10:5]*gain;mb<=p2[4:0]*gain;p3<=p2;
 base_result<=id3?p3:{((rr>>8)>31?5'd31:rr[12:8]),((gg>>8)>63?6'd63:gg[13:8]),((bb>>8)>31?5'd31:bb[12:8])};
end
always @(posedge clk or negedge resetn)
 if(!resetn)begin v1<=0;v2<=0;v3<=0;base_valid<=0;id1<=1;id2<=1;id3<=1;end
 else begin v1<=in_valid;v2<=v1;v3<=v2;base_valid<=v3;id1<=curve==7;id2<=id1;id3<=id2;end
endmodule
