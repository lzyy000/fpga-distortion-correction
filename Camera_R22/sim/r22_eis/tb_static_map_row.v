`timescale 1ns/1ps
module tb_static_map_row;
reg clk=0;always #4 clk=~clk;reg rst=0,start=0,active=0,done=0;integer ticks=0,remaining=0,checked=0,j;
wire req,ready;wire [31:0] addr;wire [15:0] beats;wire [255:0] data;
reg [31:0] gold[0:1919];wire accept=req&&!active&&ticks%5!=0;wire take=active&&ticks%3!=0;
camera_map_init #(.FIRST_ROW(1070),.LAST_ROW(1070),.PACKED_MAP(1)) dut(.clk(clk),.resetn(rst),.start(start),.busy(),.ready(ready),.cycles(),.progress(),.req(req),.write(),.addr(addr),.beats(beats),.accept(accept),.wdata(data),.take(take),.mem_done(done));
always @(posedge clk)begin
 ticks<=ticks+1;done<=0;
 if(rst)begin
  if(accept)begin if(beats!=16||addr!=32'h03000000+1070*1920*4+checked*4)$fatal(1,"map packet address");active<=1;remaining<=16;end
  if(take)begin
   for(j=0;j<8;j=j+1)if(data[j*32+:32]!==gold[checked+j])$fatal(1,"map integer replica differs at x=%0d got=%h expected=%h",checked+j,data[j*32+:32],gold[checked+j]);
   checked<=checked+8;remaining<=remaining-1;if(remaining==1)begin active<=0;done<=1;end
  end
 end
end
initial begin
 $readmemh("map_init_gold.hex",gold);repeat(5)@(negedge clk);rst=1;start=1;@(negedge clk);start=0;
 wait(ready);#1;if(checked!=1920)$fatal(1,"missing map samples");
 $display("PASS R22 integer bound model: worst row1070 matches actual map generator, 1920 Q5 coordinate pairs");$finish;
end
initial begin #3000000;$fatal(1,"map row timeout");end
endmodule
