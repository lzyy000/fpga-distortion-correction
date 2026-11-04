`timescale 1ns/1ps
module tb_rotation_cpu;
reg clk=0;always #18.5 clk=~clk;reg [4:0] keys=30;wire rst,ev;wire [31:0] a,wd;wire [3:0] ws;reg [31:0] rd;
image_cpu_r22 #(.RESET_BITS(3),.FIRMWARE_FILE("rotation_cpu.hex")) cpu(clk,keys,1'b1,,,rst,ev,a,wd,ws,1'b1,rd);
integer ticks=0,start_tick=0,maximum=0,cases=0,min_sp=8192,commits=0;reg [31:0] modes=31,legacy=32'hffffffff,hc=0;reg pending=0;reg [31:0] words[0:27];
always @*begin rd=0;case(a)
 'h8040:rd=1000;'hb0e4:rd=modes;'had30:rd=legacy;'had18:rd=1000000;'hac50:rd=2;
 'hb0d8,'hb0dc,'hb0ec:rd=256;'hb2c4:rd=32000;'hb2b0:rd=pending?4:0;'hb2b4:rd=990000;'hb2d0:rd=8;
 'hac40:rd=hc;'hac44:rd=32'h0007140d;
 'hac80:rd=32'h3f9eb852;'hac84:rd=32'h40200000;'hac88:rd=32'h3f666666;'hac8c:rd=32'h3f800000;'hac90:rd=0;
 endcase end
always @(posedge clk)begin
 ticks<=ticks+1;
 if(rst&&cpu.cpu.trap)$fatal(1,"CPU trap");
 if(rst&&cpu.cpu.cpuregs.regs[29]>0&&cpu.cpu.cpuregs.regs[29]<=8192)begin
  if(cpu.cpu.cpuregs.regs[29]<6144)$fatal(1,"stack crossed 2KiB reserve");
  if(cpu.cpu.cpuregs.regs[29]<min_sp)min_sp=cpu.cpu.cpuregs.regs[29];
 end
 if(rst&&ev&&|ws)begin
  if(a=='h9204)$fatal(1,"rotation C invariant failed case=%0d",wd);
  if(a=='h920c)start_tick=ticks;
  if(a=='h9210)begin $display("ROTATION SOLVE case=%0d cycles=%0d",wd,ticks-start_tick);$fflush();if(ticks-start_tick>maximum)maximum=ticks-start_tick;cases=cases+1;end
  if(a=='hb0e4)modes=wd;if(a=='h9224)legacy=wd;if(a=='had34)legacy=32'hffffffff;if(a=='h9230)hc=wd;if(a=='h9238)pending=1;
  if(a>='hb200&&a<'hb270)words[(a-'hb200)/4]=wd;
  if(a=='hb280)begin pending=0; if(!words[27][0]||words[27][2])$fatal(1,"rotation main/RS flags");commits=commits+1;end
  if(a=='h9804&&wd!=32'h0a000401)$fatal(1,"rotation snapshot header endian");
  if(a=='h9208)begin
   if(cases!=9||commits!=7)$fatal(1,"missing finite cases");
   $display("PASS rotation actual RV32: horizon, crop, hold/follow, gravity basis invariance, stale IMU, atomic commands, independent parameters, packet flags; maximum_cycles=%0d stack_bytes=%0d",maximum,8192-min_sp);$finish;
  end
 end
end
initial begin force cpu.ms_count=1000;repeat(8)@(negedge clk);keys=31;end
initial begin #16000000000;$fatal(1,"rotation CPU timeout");end
endmodule
