`timescale 1ns/1ps
module tb_cpu;
reg clk=0;always #18.5 clk=~clk;reg [4:0] keys=30;wire rst,ev;wire [31:0] a,wd;wire [3:0] ws;reg [31:0] rd;
image_cpu_r22 #(.RESET_BITS(3),.FIRMWARE_FILE("cpu.hex")) cpu(clk,keys,1'b1,,,rst,ev,a,wd,ws,1'b1,rd);
reg [31:0] q01[0:4],q23[0:4],accxy[0:4],accz[0:4];integer n=0,ticks=0,start_tick=0,maximum=0,count=0,left=0,k;
integer min_sp=8192,mode_checks=0,header_checks=0;reg [31:0] mode_mask=63,legacy_byte=32'hffffffff,tx_header=0;
reg [31:0] commit_token=0;reg committed=0;reg [31:0] last_status=0,row_flags=0;wire [31:0] token=((n+1)<<2)|(n%4);
always @*begin
 rd=0;
 case(a)
 'h8040:rd=1000+n*34;
 'hb0e4:rd=mode_mask;'had30:rd=legacy_byte;
 'hac08:rd=2;'hac14:rd=q01[n];'hac18:rd=q23[n];'hac1c:rd=n+1;'hac4c:rd=2;
 'had00:rd=left;'had04:rd=1000000+n*34000+(4-left)*10000;'had08:rd=32'h000007d0;'had0c:rd=1200;'had18:rd=1000000+n*34000+35000;
 'had20:rd=accxy[n];'had24:rd=accz[n];'had28:rd=0;
 'hb0d8:rd=256;'hb0dc:rd=256;'hb0ec:rd=256;
 'hb26c:rd=row_flags;'hb2c4:rd=32000;
 'hb2b0:rd=committed?0:token;'hb2b4:rd=1000000+n*34000;
 endcase
end
always @(posedge clk)begin
 ticks<=ticks+1;
 if(rst&&cpu.cpu.trap)$fatal(1,"CPU trap");
 if(rst&&cpu.cpu.cpuregs.regs[29]>0&&cpu.cpu.cpuregs.regs[29]<=8192)begin
  if(cpu.cpu.cpuregs.regs[29]<6144)$fatal(1,"stack exceeded 2 KiB reserve");
  if(cpu.cpu.cpuregs.regs[29]<min_sp)min_sp=cpu.cpu.cpuregs.regs[29];
 end
 if(rst&&ev&&|ws)begin
  if(a=='hb0e4)mode_mask=wd;
  if(a=='h9224)legacy_byte=wd;
  if(a=='had34)legacy_byte=32'hffffffff;
  if(a=='h9228)begin if(mode_mask!=wd)$fatal(1,"C tuning mode mask clobbered unrelated bits");mode_checks=mode_checks+1;end
  if(a=='h9804)tx_header=wd;
  if(a=='h9014)begin
   if(header_checks==0&&tx_header!=32'h03000401)$fatal(1,"EIS DATA geometry flags endian");
   if(header_checks==1&&tx_header!=32'h00000201)$fatal(1,"HELLO flags polluted");
   header_checks=header_checks+1;
  end
  if(a=='h920c)begin n=wd;mode_mask=wd==2?31:63;start_tick=ticks;left=4;committed=0;end
  if(a=='had10)begin if(left==0)$fatal(1,"empty gyro pop");left=left-1;end
  if(a=='hb2a0)last_status=wd;
  if(a=='hb26c)row_flags=wd;
  if(a=='hb2b8)commit_token=wd;
  if(a=='hb280)begin if(commit_token!=token)$fatal(1,"wrong frame generation");committed=1;end
  if(a=='h9210)begin
   if(wd!=n+1||left!=0||!committed||!last_status[0]||last_status[3]||!row_flags[2])$fatal(1,"missing solve/queued samples");
   $display("R22 SOLVE pose=%0d cycles=%0d",n,ticks-start_tick);$fflush();
   if(ticks-start_tick>maximum)maximum=ticks-start_tick;count=count+1;
  end
  if(a=='h9208)begin if(count!=5||mode_checks!=3||header_checks!=2)$fatal(1,"missing integrated cases");$display("R22 STACK maximum_bytes=%0d C_MODE_CHECKS=%0d C_PACKET_HEADERS=%0d",8192-min_sp,mode_checks,header_checks);$display("PASS R22 CPU integrated polling/ACK/network idle maximum_cycles=%0d",maximum);$finish;end
 end
end
real ax,by,cz,ca,sa,cb,sb,cc,sc;integer qw,qx,qy,qz,acx,acy,acz;
initial begin
 for(k=0;k<5;k=k+1)begin
  ax=0;by=0;cz=0;if(k==1)begin ax=0.3;by=0.65;cz=1.2;end
  if(k==2)cz=0.7853981634;if(k==3)cz=1.5707963268;if(k==4)ax=1.4;
  ca=$cos(ax/2);sa=$sin(ax/2);cb=$cos(by/2);sb=$sin(by/2);cc=$cos(cz/2);sc=$sin(cz/2);
  qw=$rtoi((cc*cb*ca+sc*sb*sa)*32767);qx=$rtoi((cc*cb*sa-sc*sb*ca)*32767);qy=$rtoi((cc*sb*ca+sc*cb*sa)*32767);qz=$rtoi((sc*cb*ca-cc*sb*sa)*32767);
  acx=$rtoi(2*((qx/32767.0)*(qy/32767.0)+(qw/32767.0)*(qz/32767.0))*2048);
  acy=$rtoi((1-2*((qx/32767.0)*(qx/32767.0)+(qz/32767.0)*(qz/32767.0)))*2048);
  acz=$rtoi(2*((qy/32767.0)*(qz/32767.0)-(qw/32767.0)*(qx/32767.0))*2048);
  accxy[k]=(acx&65535)|((acy&65535)<<16);accz[k]=acz&65535;
  q01[k]=(qw&65535)|((qx&65535)<<16);q23[k]=(qy&65535)|((qz&65535)<<16);
 end
 repeat(8)@(negedge clk);keys=31;
end
initial begin #12000000000;$fatal(1,"timeout");end
endmodule
