// Streaming statistics from the unenhanced, spatial-filtered RGB565 source.
// Never accepts partial/bad frames. Selection uses cross-products (no divider).
// First valid frame initializes the curve; then slew one level per four frames.
module camera_night_stats #(parameter W=1920,H=1080)(
 input clk,resetn,in_vs,in_de,in_bad,input [15:0] pixel,
 output reg [3:0] curve=7,output reg valid=0,
 output reg [31:0] frames=0,output reg [31:0] last_sum=0,
 output reg [3:0] target=7);
wire [7:0] r={pixel[15:11],3'b0},g={pixel[10:5],2'b0},b={pixel[4:0],3'b0};
wire [7:0] rg=r>g?r:g,value=rg>b?rg:b;
reg vd=0,seen=0,bad=0,pv=0;
reg [7:0] value_q;
reg [21:0] count=0;
reg [28:0] sum=0;
reg [1:0] pace=0;
reg classify=0,commit=0;
reg [3:0] selected;
always @*begin
 if(last_sum<W*H*24)selected=0;
 else if(last_sum<W*H*32)selected=1;
 else if(last_sum<W*H*44)selected=2;
 else if(last_sum<W*H*60)selected=3;
 else if(last_sum<W*H*76)selected=4;
 else if(last_sum<W*H*94)selected=5;
 else if(last_sum<W*H*112)selected=6;
 else if(last_sum>W*H*220)selected=9;
 else if(last_sum>W*H*195)selected=8;
 else selected=7;
end
always @(posedge clk or negedge resetn)
 if(!resetn)begin
  vd<=0;seen<=0;bad<=0;pv<=0;count<=0;sum<=0;pace<=0;curve<=7;
  valid<=0;frames<=0;last_sum<=0;target<=7;classify<=0;commit<=0;value_q<=0;
 end else begin
  vd<=in_vs;pv<=in_de;value_q<=value;
  classify<=0;commit<=classify;
  if(in_bad)bad<=1;
  if(pv)begin count<=count+1'b1;sum<=sum+value_q;end
  if(in_vs&&!vd)begin
   seen<=1;bad<=in_bad;count<=0;sum<=0;
   if(seen&&!bad&&!in_bad&&count==W*H&&!pv&&!in_de)begin
    last_sum<={3'b0,sum};frames<=frames+1'b1;classify<=1;
   end
  end
  if(classify)target<=selected;
  if(commit)begin
   valid<=1;pace<=pace+1'b1;
   if(!valid)curve<=target;
   else if(pace==3)begin
    if(curve<target)curve<=curve+1'b1;
    else if(curve>target)curve<=curve-1'b1;
   end
  end
 end
endmodule
