`timescale 1ns/1ps
module tb_jobs;
reg clk=0;always #4 clk=~clk;reg rst=0,grant=0,sof=0,cap=0,recover=0,sel=0;
reg [1:0] gs=0,ss=0,cs=0,ps=0;reg [31:0] stamp=0,data=0;reg [7:0] a=0;reg [3:0] ws=0;
wire [3:0] ready;wire [31:0] rd;wire [895:0] cfg;integer k;reg [31:0] tokens[0:3];
camera_eis_jobs_r22 dut(.clk(clk),.resetn(rst),.grant(grant),.grant_slot(gs),.slot_eis(4'b1111),.slot_lens(4'b1010),
 .sof(sof),.sof_slot(ss),.sof_us(stamp),.readout_us(32'd32482),.cap_done(cap),.cap_slot(cs),.recover(recover),
 .cpu_sel(sel),.cpu_addr(a),.cpu_data(data),.cpu_strb(ws),.cpu_result(rd),.process_slot(ps),.process_done(1'b0),
 .processed(32'b0),.displayed(32'b0),.cycles(32'b0),.fallbacks(32'b0),.rs_fallbacks(32'b0),.ready(ready),.process_config(cfg));
task wr(input [7:0] ad,input [31:0] d);begin @(negedge clk);sel=1;a=ad;data=d;ws=15;@(negedge clk);sel=0;ws=0;end endtask
task capture(input [1:0] n,input [31:0] t);begin
 @(negedge clk);gs=n;grant=1;@(negedge clk);grant=0;ss=n;stamp=t;sof=1;@(negedge clk);sof=0;cs=n;cap=1;@(negedge clk);cap=0;tokens[n]=dut.token[n];end endtask
initial begin
 repeat(4)@(negedge clk);rst=1;
 capture(0,32'hfffffff0);capture(1,32'h00000020);capture(2,32'h00000060);capture(3,32'h000000a0);
 a=8'hb0;#1;if(rd!=tokens[0])$fatal(1,"oldest frame failed across 32bit time wrap");
 for(k=0;k<4;k=k+1)begin
  wr(8'h00,32'h12340000+k);wr(8'hb8,tokens[k]);wr(8'h80,k+1);ps=k;#1;
  if(!ready[k]||cfg[31:0]!=32'h12340000+k)$fatal(1,"bank/slot coefficient mismatch");
 end
 if(ready!=15||dut.pending!=0)$fatal(1,"four slot jobs not committed");
 // A stale CPU commit must not make the reused slot ready or overwrite its bank.
 capture(3,32'h00000100);wr(8'hb8,tokens[3]-4);wr(8'h00,32'hbad00000);wr(8'h80,99);
 if(ready[3]||dut.stale!=1||cfg[31:0]!=32'h12340003)$fatal(1,"stale generation accepted");
 wr(8'hb8,tokens[3]);wr(8'h80,6);if(!ready[3]||cfg[31:0]!=32'hbad00000)$fatal(1,"fresh generation lost");
 @(negedge clk);gs=2;grant=1;@(negedge clk);grant=0;recover=1;@(negedge clk);recover=0;ss=2;sof=1;cs=2;cap=1;
 @(negedge clk);sof=0;cap=0;if(dut.pending[2])$fatal(1,"aborted capture became pending");
 $display("PASS R22 jobs: 4 banks, wrap-safe oldest, stale rejection, recovery");$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
