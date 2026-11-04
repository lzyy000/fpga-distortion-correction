`timescale 1ns/1ps
module tb_snapshot_eis;
parameter CURVE=2,STRENGTH=128;
localparam BYTES=2048,PIXELS=BYTES/2;
reg clk=0;always #4 clk=~clk;reg resetn=0;
reg cpu_sel=0;reg [11:0] cpu_addr=0;reg [31:0] cpu_wdata=0;reg [3:0] cpu_wstrb=0;
wire cpu_ready;wire [31:0] cpu_rdata;wire lock_request,lock_release;
reg locked=0;wire req,write;wire [31:0] addr;wire [15:0] beats;wire [255:0] wdata;
reg [255:0] rdata=0;reg rvalid=0,mem_done=0;
reg mem_busy=0,mem_write=0;integer mem_index=0,mem_left=0,mem_base=0,ticks=0,j,k,write_count=0;
wire accept=req&&!mem_busy&&ticks%5!=0;
wire take=mem_busy&&mem_write&&ticks%4!=0;
reg [255:0] saved[0:63];reg [10:0] gains[0:4095];
integer polls=0,cpu_waits=0,release_count=0;reg [31:0] value,crc,chunk_crc;integer order,word_index,chunk,seed;
camera_snapshot_eis_r22 #(.FRAME_BYTES(BYTES)) dut(.clk(clk),.resetn(resetn),
 .cpu_sel(cpu_sel),.cpu_addr(cpu_addr),.cpu_wdata(cpu_wdata),.cpu_wstrb(cpu_wstrb),.cpu_ready(cpu_ready),.cpu_rdata(cpu_rdata),
 .lock_request(lock_request),.lock_release(lock_release),.locked(locked),.locked_slot(2'd0),.locked_frame(32'd77),
 .locked_eis(1'b1),.locked_lens(1'b1),.locked_night_curve(4'(CURVE)),.locked_night_strength(9'(STRENGTH)),
 .req(req),.write(write),.addr(addr),.beats(beats),.accept(accept),.rdata(rdata),.rvalid(rvalid),.mem_done(mem_done),.wdata(wdata),.take(take));
function [15:0] original;
 input integer index;
 begin original={5'((index*3+7+(index>>6))&31),6'((index*5+9+(index>>7))&63),5'((index*7+1+(index>>8))&31)};end
endfunction
function [15:0] expected;
 input integer index;integer a,b,c,v,g,ar,ag,ab;
 reg [15:0] px;
 begin
 px=original(index);a=px[15:11];b=px[10:5];c=px[4:0];
 v=a*8;if(b*4>v)v=b*4;if(c*8>v)v=c*8;g=gains[CURVE*256+v];
 ar=(a*g+128)/256;if(ar>31)ar=31;
 ag=(b*g+128)/256;if(ag>63)ag=63;
 ab=(c*g+128)/256;if(ab>31)ab=31;
 if(CURVE==7)begin ar=a;ag=b;ab=c;end
 a=a+(((ar-a)*STRENGTH+128)>>>8);
 b=b+(((ag-b)*STRENGTH+128)>>>8);
 c=c+(((ab-c)*STRENGTH+128)>>>8);
 expected={5'(a),6'(b),5'(c)};
 end
endfunction
function [31:0] crc_byte;
 input [31:0] in_crc;input [7:0] octet;reg [31:0] c;integer bit_index;
 begin c=in_crc^octet;for(bit_index=0;bit_index<8;bit_index=bit_index+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
endfunction
function [31:0] expected_word;
 input integer index;
 begin expected_word={expected(index*2+1),expected(index*2)};end
endfunction
always @(posedge clk)begin
 ticks<=ticks+1;rvalid<=0;mem_done<=0;
 if(!resetn||lock_release)locked<=0;else if(lock_request)locked<=1;
 if(lock_release)release_count<=release_count+1;
 if(resetn)begin
  if(accept)begin
   if(beats!=32)$fatal(1,"snapshot chunk length changed");
   mem_busy<=1;mem_write<=write;mem_left<=32;mem_index<=0;mem_base<=addr;
  end
  if(mem_busy&&!mem_write&&ticks%3!=0)begin
   for(j=0;j<16;j=j+1)begin
    if(mem_base>=32'h04000000)rdata[j*16+:16]<=expected((mem_base-32'h04000000)/2+mem_index*16+j);
    else if(mem_base>=32'h02000000)rdata[j*16+:16]<=saved[(mem_base-32'h02000000)/32+mem_index][j*16+:16];
    else rdata[j*16+:16]<=original((mem_base-32'h01000000)/2+mem_index*16+j);
   end
   rvalid<=1;mem_index<=mem_index+1;mem_left<=mem_left-1;
   if(mem_left==1)begin mem_busy<=0;mem_done<=1;end
  end
  if(take)begin
   for(j=0;j<16;j=j+1)if(wdata[j*16+:16]!==expected((mem_base-32'h02000000)/2+mem_index*16+j))
    $fatal(1,"snapshot write pixel %0d got=%h expected=%h",(mem_base-32'h02000000)/2+mem_index*16+j,wdata[j*16+:16],expected((mem_base-32'h02000000)/2+mem_index*16+j));
   saved[(mem_base-32'h02000000)/32+mem_index]<=wdata;
   write_count<=write_count+1;mem_index<=mem_index+1;mem_left<=mem_left-1;
   if(mem_left==1)begin mem_busy<=0;mem_done<=1;end
  end
 end
end
task cpu_access;
 input [11:0] a;input [31:0] d;input [3:0] strobes;output [31:0] result;
 integer wait_cycles;
 begin
 @(negedge clk);cpu_sel=1;cpu_addr=a;cpu_wdata=d;cpu_wstrb=strobes;wait_cycles=0;
 while(!cpu_ready)begin @(negedge clk);wait_cycles=wait_cycles+1;if(wait_cycles>30000)$fatal(1,"CPU port timeout");end
 result=cpu_rdata;if(a>=12'h400&&wait_cycles>3)cpu_waits=cpu_waits+1;
 cpu_sel=0;cpu_wstrb=0;@(negedge clk);
 end
endtask
task poll_idle;
 reg [31:0] status;
 begin status=2;while(status[1])begin cpu_access(12'h104,0,0,status);polls=polls+1;end end
endtask
initial begin
 $readmemh("night_gain.hex",gains);repeat(6)@(negedge clk);resetn=1;
 cpu_access(12'h100,1,15,value);
 // Payload access during DMA must wait; it must never steal the active CRC,
 // Gamma or native write word. Upon copy completion the last chunk is stable.
 wait(dut.state==7);
 cpu_access(12'h7fc,0,0,value);
 if(value!==expected_word(PIXELS/2-1))$fatal(1,"busy CPU data read returned wrong word");
 poll_idle();cpu_access(12'h104,0,0,value);if(value[3:0]!==1)$fatal(1,"snapshot availability/status");
 if(cpu_waits!=1||write_count!=64)$fatal(1,"shared port stall or two-chunk copy missing");
 crc=32'hffffffff;
 for(k=0;k<PIXELS;k=k+1)begin crc=crc_byte(crc,expected(k)&255);crc=crc_byte(crc,expected(k)>>8);end
 cpu_access(12'h10c,0,0,value);if(value!==(crc^32'hffffffff))$fatal(1,"whole image CRC mismatch");
 cpu_access(12'h108,0,0,value);if(value!=77)$fatal(1,"frame identity");
 cpu_access(12'h11c,0,0,value);if(value!==7)$fatal(1,"frozen night metadata");
 cpu_access(12'h120,0,0,value);if(value!=3)$fatal(1,"EIS photo flags");
 // Reverse chunk order and permuted CPU word addresses exercise all 256 words,
 // including first/last beat, first/last lane, reload and repeated reads.
 for(order=0;order<2;order=order+1)begin
  chunk=1-order;cpu_access(12'h110,chunk,15,value);cpu_access(12'h100,2,15,value);poll_idle();
  cpu_access(12'h104,0,0,value);if(!value[2]||value[3])$fatal(1,"chunk status");
  chunk_crc=32'hffffffff;
  for(k=chunk*512;k<(chunk+1)*512;k=k+1)begin chunk_crc=crc_byte(chunk_crc,expected(k)&255);chunk_crc=crc_byte(chunk_crc,expected(k)>>8);end
  cpu_access(12'h114,0,0,value);if(value!==(chunk_crc^32'hffffffff))$fatal(1,"chunk CRC mismatch");
  for(seed=0;seed<256;seed=seed+1)begin
   word_index=(seed*73+255)%256;
   cpu_access(12'h400+word_index*4,0,0,value);
   if(value!==expected_word(chunk*256+word_index))$fatal(1,"CPU payload mismatch chunk=%d word=%d",chunk,word_index);
  end
 end
 // Cancel a new copy mid-processing; status remains usable independently of
 // the shared payload port, the source frame is released, then a retry works.
 cpu_access(12'h100,1,15,value);wait(dut.state==8);cpu_access(12'h100,4,15,value);poll_idle();
 cpu_access(12'h104,0,0,value);if(value[2:0]!=0)$fatal(1,"cancel did not clear availability/busy");
 cpu_access(12'h100,1,15,value);poll_idle();cpu_access(12'h104,0,0,value);
 if(value[3:0]!==1||release_count<3)$fatal(1,"copy retry after cancellation status=%h release=%d state=%d writes=%d",value,release_count,dut.state,write_count);
 $display("PASS R22 shared snapshot RAM: curve=%0d strength=%0d, exact pixels, 512 CPU words, whole/chunk CRC, DMA gaps, busy read arbitration, cancel/retry",CURVE,STRENGTH);$finish;
end
initial begin #1500000;$fatal(1,"snapshot RAM timeout");end
endmodule
