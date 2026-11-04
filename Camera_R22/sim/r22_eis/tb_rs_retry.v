`timescale 1ns/1ps
module tb_rs_retry;
reg clk=0;always #4 clk=~clk;reg rst=0,start=0;reg [895:0] cfg=0;wire [31:0] fallback,rs_fallback;integer i;
camera_eis_remap_r22 #(.W(64),.H(64)) d(.clk(clk),.resetn(rst),.start(start),.source_base(32'h01000000),.result_base(32'h04000000),.night_curve(4'd7),.night_strength(9'd0),.config_words(cfg),
 .accept(1'b0),.done(1'b0),.valid(1'b0),.rdata(256'b0),.take(1'b0),.fallbacks(fallback),.rs_fallbacks(rs_fallback));
initial begin
 cfg[0+:32]=$rtoi(16777216.0/24000.0);cfg[4*32+:32]=$rtoi(16777216.0/24000.0);
 cfg[2*32+:32]=$rtoi(-31.5*16777216.0/24000.0);cfg[5*32+:32]=$rtoi(-31.5*16777216.0/24000.0);cfg[8*32+:32]=16777216;
 cfg[9*32+:32]=20000*256;cfg[10*32+:32]=20000*256;cfg[11*32+:32]=$rtoi(31.5*256);cfg[12*32+:32]=$rtoi(31.5*256);
 cfg[27*32+:32]=32'h01000005;
 repeat(4)@(negedge clk);rst=1;start=1;@(negedge clk);start=0;
 wait(d.st==3);#1;
 if(rs_fallback!=1||fallback||d.used_fallback||!d.rs_retry||d.map_cfg!==cfg[575:0])$fatal(1,"RS-only retry changed the proven primary stabilization");
 $display("PASS R22 RS-only boundary retry preserves primary stabilization");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
