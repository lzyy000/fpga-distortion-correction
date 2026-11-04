`timescale 1ns/1ps
module tb_capture;
reg clk=0;always #4 clk=~clk;
reg resetn=0,vs=0,de=0,bad=0,gt=0,gv=0;
reg [1:0] slot=1;
reg [15:0] processed=0,original=0;
wire request,geometry_ok,fatal;
wire [3:0] reason;
wire [546:0] head;
wire [9:0] count;
integer i;reg [31:0] us=0;wire sof;wire [1:0] ss;wire [31:0] stamp,span;integer sofs=0;
always @(posedge clk)begin us<=us+1;if(sof)begin sofs<=sofs+1;if(ss!=1)$fatal(1,"SOF slot");end end
camera_capture_eis_r22 #(.W(16),.H(1),.PIXEL_INPUT(1)) dut(
 .clock_us(us),.sof(sof),.sof_slot(ss),.sof_us(stamp),.readout_us(span),.pclk(clk),.prstn(resetn),.stats_resetn(resetn),.vs(vs),.href(de),
 .data(processed),.raw_data(original),.frame_invalid(bad),
 .request(request),.geometry_ok(geometry_ok),.grant_toggle(gt),
 .grant_valid(gv),.grant_slot(slot),.fatal(fatal),.fault_reason(reason),
 .fault_pixels(),.fault_geometry(),.first_fault_geometry(),.frame_gray(),
 .head(head),.count(count),.clk(clk),.resetn(resetn),.pop(1'b0));
initial begin
 repeat(5)@(negedge clk);resetn=1;
 vs=1;repeat(3)@(negedge clk);vs=0;
 repeat(3)@(negedge clk);
 @(negedge clk);gt=1;gv=1;
 repeat(8)@(negedge clk);
 for(i=0;i<16;i=i+1)begin
  de=1;original=16'h1000+i;processed=16'h7000+i;
  @(negedge clk);
 end
 de=0;repeat(4)@(negedge clk);
 vs=1;repeat(3)@(negedge clk);vs=0;
 repeat(6)@(negedge clk);
 if(sofs!=1||span!=0||stamp==0)$fatal(1,"SOF/readout for one row");
 if(fatal||count!=1||head[546]!==1'b1||head[545:544]!==2'd1||
    head[543:512]!==32'h01400000)$fatal(1,"raw capture descriptor");
 for(i=0;i<16;i=i+1)begin
  if(head[256+i*16+:16]!==16'h1000+i)$fatal(1,"original lane %0d",i);
  if(head[i*16+:16]!==16'h7000+i)$fatal(1,"processed lane %0d",i);
 end
 $display("PASS R22 capture keeps pristine and processed pixels aligned in one frame");
 $finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
