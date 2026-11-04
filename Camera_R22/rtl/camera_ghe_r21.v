// R21 global histogram equalization on HSV V = max(expanded RGB565).
// Independent streaming implementation; CDF/ping-pong architecture references:
// Passionate0424/CLAHE_verilog @739f712 (see references/ghe, Apache-2.0).
// No tile clipping, vendor IP, frame buffer, pixel-rate divider or DDR pass.
module camera_ghe_r21 #(parameter W=1920,H=1080)(
 input clk,resetn,enable,input [8:0] strength,
 input in_vs,in_de,in_bad,input [15:0] pixel,raw_pixel,
 output out_vs,out_de,out_bad,output [15:0] result,raw_result,
 output reg active=0,output reg ready=0,output reg history_clear=0,
 output reg [31:0] frames=0,dropped=0,updates=0);
localparam CW=$clog2(W*H+1);
localparam INIT=0,IDLE=1,SCAN=2,WAIT_BIN=3,BIN=4,DIV_CDF=5,
 GAIN_START=6,DIV_GAIN=7,WRITE_GAIN=8,CLEAR=9,IDENTITY=10;
reg [3:0] st=INIT;
reg [CW-1:0] hist0[0:255] /* synthesis syn_ramstyle="block_ram" */;
reg [CW-1:0] hist1[0:255] /* synthesis syn_ramstyle="block_ram" */;
reg [15:0] gain_lut[0:511] /* synthesis syn_ramstyle="block_ram" */;
wire [7:0] r={pixel[15:11],3'b0},g={pixel[10:5],2'b0},b={pixel[4:0],3'b0};
wire [7:0] rg=r>g?r:g,value=rg>b?rg:b;
reg vd=0,seen=0,bad=0,collecting=0,collect_bank=0,build_bank=0;
reg [1:0] free_bank=0;
reg [CW:0] count=0;
reg [7:0] bin=0;
reg [CW-1:0] h0_q,h1_q;
wire vs_edge=in_vs&&!vd;
wire accept_pixel=collecting&&seen&&in_de&&!vs_edge&&!bad&&!in_bad&&count<W*H;
wire [7:0] h0_ra=collect_bank==0?value:bin,h1_ra=collect_bank==1?value:bin;
reg pv=0,pbank=0,last_valid=0,last_bank=0;
reg [7:0] paddr,last_addr;
reg [CW-1:0] last_value;
wire [CW-1:0] hist_base=last_valid&&last_bank==pbank&&last_addr==paddr?
 last_value:(pbank?h1_q:h0_q);
wire [CW-1:0] hist_increment=hist_base+1'b1;
wire clear0=st==INIT||(st==CLEAR&&!build_bank);
wire clear1=st==INIT||(st==CLEAR&&build_bank);
// Each physical histogram has one read and one write expression. Forward the
// last committed increment for same-address read/write (AA and ABA sequences).
always @(posedge clk)begin
 h0_q<=hist0[h0_ra];h1_q<=hist1[h1_ra];
 if(clear0)hist0[bin]<=0;else if(pv&&!pbank)hist0[paddr]<=hist_increment;
 if(clear1)hist1[bin]<=0;else if(pv&&pbank)hist1[paddr]<=hist_increment;
end
reg active_lut_bank=0,build_lut_bank=1,map_pending=0;
reg [15:0] gain_value=256,gain_q;
wire gain_write=st==WRITE_GAIN||st==IDENTITY;
always @(posedge clk)begin
 gain_q<=gain_lut[{active_lut_bank,value}];
 if(gain_write)gain_lut[{build_lut_bank,bin}]<=st==IDENTITY?16'd256:gain_value;
end
reg [CW-1:0] total=0,cdf=0,cdf_min=0,denominator=0;
reg found=0;
wire [CW-1:0] scan_value=build_bank?h1_q:h0_q;
wire [CW-1:0] cdf_next=cdf+scan_value;
wire [31:0] delta32={{(32-CW){1'b0}},(cdf_next-cdf_min)};
reg [7:0] mapped=0;
// One shared restoring divider, used only by the 256-bin background builder.
reg [31:0] dividend=0,quotient=0;
reg [CW-1:0] divisor=1,remainder=0;
reg [5:0] divide_left=0;
wire [CW:0] trial={remainder,dividend[31]};
// A single narrow subtract supplies both comparison and the new remainder.
wire [CW+1:0] divide_difference={1'b0,trial}-{2'b0,divisor};
wire divide_take=!divide_difference[CW+1];
wire [31:0] quotient_next={quotient[30:0],divide_take};
wire [CW-1:0] remainder_next=divide_take?divide_difference[CW-1:0]:trial[CW-1:0];
reg [8:0] frame_strength=0;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  st<=INIT;bin<=0;vd<=0;seen<=0;bad<=0;collecting<=0;collect_bank<=0;build_bank<=0;
  free_bank<=0;count<=0;pv<=0;pbank<=0;paddr<=0;last_valid<=0;last_bank<=0;last_addr<=0;last_value<=0;
  active_lut_bank<=0;build_lut_bank<=1;map_pending<=0;active<=0;ready<=0;history_clear<=0;
  frames<=0;dropped<=0;updates<=0;frame_strength<=0;
  total<=0;cdf<=0;cdf_min<=0;denominator<=0;found<=0;mapped<=0;gain_value<=256;
  dividend<=0;divisor<=1;quotient<=0;remainder<=0;divide_left<=0;
 end else begin
  history_clear<=0;
  vd<=in_vs;pv<=accept_pixel;paddr<=value;pbank<=collect_bank;
  if(pv)begin last_valid<=1;last_bank<=pbank;last_addr<=paddr;last_value<=hist_increment;end
  if(in_bad)bad<=1;
  if(in_de&&seen)begin
   if(count<W*H+1)count<=count+1'b1;
   if(count>=W*H)bad<=1;
  end
  case(st)
   INIT:if(bin==255)begin st<=IDLE;bin<=0;free_bank<=3;end else bin<=bin+1'b1;
   SCAN:st<=WAIT_BIN;
   WAIT_BIN:st<=BIN;
   BIN:begin
    cdf<=cdf_next;
    if(!found&&scan_value!=0)begin
     found<=1;cdf_min<=cdf_next;denominator<=total-cdf_next;
     if(cdf_next==total)begin bin<=0;st<=IDENTITY;end
     else begin mapped<=0;st<=GAIN_START;end
    end else if(!found)begin mapped<=0;st<=GAIN_START;end
    else begin
     dividend<=(delta32<<8)-delta32+(denominator>>1);divisor<=denominator;
     quotient<=0;remainder<=0;divide_left<=31;st<=DIV_CDF;
    end
   end
   DIV_CDF,DIV_GAIN:begin
    dividend<={dividend[30:0],1'b0};quotient<=quotient_next;remainder<=remainder_next;
    if(divide_left==0)begin
     if(st==DIV_CDF)begin mapped<=quotient_next[7:0];st<=GAIN_START;end
     else begin gain_value<=quotient_next[15:0];st<=WRITE_GAIN;end
    end else divide_left<=divide_left-1'b1;
   end
   GAIN_START:begin
    if(bin==0)begin gain_value<=256;st<=WRITE_GAIN;end
    else begin
     dividend<=({24'd0,mapped}<<8)+{25'd0,bin[7:1]};divisor<={24'd0,bin};
     quotient<=0;remainder<=0;divide_left<=31;st<=DIV_GAIN;
    end
   end
   WRITE_GAIN,IDENTITY:if(bin==255)begin
    map_pending<=1;updates<=updates+1'b1;bin<=0;st<=CLEAR;
   end else begin bin<=bin+1'b1;if(st==WRITE_GAIN)st<=SCAN;end
   CLEAR:if(bin==255)begin free_bank[build_bank]<=1;bin<=0;st<=IDLE;end else bin<=bin+1'b1;
  endcase
  if(vs_edge)begin
   seen<=1;bad<=in_bad||in_de;count<=0;pv<=0;last_valid<=0;frame_strength<=strength;
   active<=enable&&strength!=0&&(ready||map_pending);
   history_clear<=active!=(enable&&strength!=0&&(ready||map_pending))||
    (strength!=frame_strength&&(active||enable));
   if(map_pending)begin active_lut_bank<=build_lut_bank;map_pending<=0;ready<=1;end
   // A short/malformed source frame may outrun the background worker. Drop only
   // its statistics; image data never stalls and the previous LUT stays valid.
   if(st==IDLE&&free_bank[!collect_bank])begin
    build_bank<=collect_bank;collect_bank<=!collect_bank;free_bank[!collect_bank]<=0;
    collecting<=1;bin<=0;
    if(seen&&collecting&&!bad&&!in_bad&&!in_de&&!pv&&count==W*H)begin
     frames<=frames+1'b1;total<=count[CW-1:0];cdf<=0;cdf_min<=0;denominator<=0;found<=0;
     build_lut_bank<=map_pending?active_lut_bank:!active_lut_bank;st<=SCAN;
    end else begin st<=CLEAR;if(seen)dropped<=dropped+1'b1;end
   end else begin collecting<=0;if(seen)dropped<=dropped+1'b1;end
  end
 end
end
// Five clocks, one RGB565 pixel per clock. The unprocessed raw tap and all
// geometry/bad-frame tokens have exactly the same delay, even when bypassed.
reg [15:0] p1,p2,p3,processed;
reg [8:0] s1,s2,s3;
reg en1=0,en2=0,v1=0,v2=0,v3=0;
reg [20:0] mr,mb;reg [21:0] mg;
wire [21:0] rr={1'b0,mr}+22'd128,bb={1'b0,mb}+22'd128;
wire [22:0] gg={1'b0,mg}+23'd128;
reg [4:0] vs_pipe=0,bad_pipe=0;
reg [15:0] raw0,raw1,raw2,raw3,raw4;
always @(posedge clk)begin
 p1<=pixel;s1<=frame_strength;
 p2<=p1;s2<=s1;mr<=p1[15:11]*gain_q;mg<=p1[10:5]*gain_q;mb<=p1[4:0]*gain_q;
 p3<=p2;s3<=s2;
 processed<=!en2?p2:{((rr>>8)>31?5'd31:rr[12:8]),((gg>>8)>63?6'd63:gg[13:8]),((bb>>8)>31?5'd31:bb[12:8])};
 raw0<=raw_pixel;raw1<=raw0;raw2<=raw1;raw3<=raw2;raw4<=raw3;
end
always @(posedge clk or negedge resetn)
 if(!resetn)begin v1<=0;v2<=0;v3<=0;en1<=0;en2<=0;vs_pipe<=0;bad_pipe<=0;end
 else begin
  v1<=in_de;v2<=v1;v3<=v2;en1<=active;en2<=en1;
  vs_pipe<={vs_pipe[3:0],in_vs};bad_pipe<={bad_pipe[3:0],in_bad};
 end
camera_strength_blend_r19 blend(.clk(clk),.resetn(resetn),.valid(v3),.strength(s3),
 .original(p3),.processed(processed),.out_valid(out_de),.result(result));
assign out_vs=vs_pipe[4];assign out_bad=bad_pipe[4];assign raw_result=raw4;
endmodule
