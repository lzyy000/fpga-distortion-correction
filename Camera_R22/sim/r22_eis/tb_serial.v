`timescale 1ns/1ps
module tb_serial;
reg clk=0;always #1 clk=~clk;reg rst=0,imu=1,host=1,sel=0;reg [8:0] a=0;reg [31:0] wd=0;reg [3:0] ws=0;
wire [31:0] rd,gray;integer i;reg [7:0] sum;
camera_eis_serial_r22 dut(.clk(clk),.resetn(rst),.imu_rx(imu),.host_rx(host),.sel(sel),.address(a),.wdata(wd),.wstrb(ws),.rdata(rd),.clock_us_gray(gray));
task byte_host(input [7:0] v);integer b;begin host=0;repeat(234)@(negedge clk);for(b=0;b<8;b=b+1)begin host=v[b];repeat(234)@(negedge clk);end host=1;repeat(234)@(negedge clk);repeat(8)@(negedge clk);end endtask
task byte_imu(input [7:0] v);integer b;begin imu=0;repeat(234)@(negedge clk);for(b=0;b<8;b=b+1)begin imu=v[b];repeat(234)@(negedge clk);end imu=1;repeat(234)@(negedge clk);repeat(8)@(negedge clk);end endtask
task pop(input [7:0] value);begin a=9'h130;#1;if(rd!={24'b0,value})$fatal(1,"legacy FIFO order");@(negedge clk);sel=1;a=9'h134;ws=15;wd=1;@(negedge clk);sel=0;ws=0;end endtask
initial begin
 repeat(5)@(negedge clk);rst=1;
 byte_host(127);byte_host(248);byte_host(101);
 // Binary payload intentionally contains legacy toggles. They must stay isolated.
 byte_host(255);byte_host(69);byte_host(8);byte_host(8);byte_host(7);sum=255+69+8+8+7;
 for(i=0;i<8;i=i+1)begin byte_host(112+i);sum=sum+112+i;end byte_host(sum);
 byte_host(102);repeat(30)@(negedge clk);
 if(dut.hc!=1||dut.header!=32'h00070808||dut.lc!=4||dut.mail[0]!=32'h73727170)$fatal(1,"mixed host routing");
 pop(127);pop(248);pop(101);pop(102);a=9'h130;#1;if(rd!=32'hffffffff)$fatal(1,"legacy FIFO not drained");
 byte_imu(8'h55);byte_imu(8'h52);sum=8'h55+8'h52;
 for(i=0;i<8;i=i+1)begin byte_imu(i+1);sum=sum+i+1;end byte_imu(sum);repeat(20)@(negedge clk);
 a=9'h100;#1;if(rd!=1||dut.gn!=1||dut.gyro_head[31:0]!=32'h04030201)$fatal(1,"gyro queue/packet");
 // Bad binary checksum neither commits a mailbox nor leaks mode commands.
 byte_host(255);byte_host(69);byte_host(8);byte_host(0);byte_host(9);byte_host(0);
 if(dut.hc!=1||dut.hbad!=1||dut.lc!=0)$fatal(1,"bad binary frame accepted/leaked");
 $display("PASS R22 serial: legacy/binary isolation, FIFO order, WIT gyro queue, checksum rejection");$finish;
end
initial begin #3000000;$fatal(1,"timeout");end
endmodule
