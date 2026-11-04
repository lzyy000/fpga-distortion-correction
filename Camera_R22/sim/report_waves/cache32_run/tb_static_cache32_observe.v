`timescale 1ns/1ps
module tb_static_cache32;
parameter CACHE_BITS=5,BAD_SPAN=0;
localparam W=1920,H=1080,N=W*3;
reg clk=0;always #4 clk=~clk;reg rst=0,start=0;wire busy,finished,error,req,write;
wire [31:0] addr,cycles;wire [15:0] beats;wire [255:0] wd;
reg [255:0] rd=0;reg valid=0,done=0,active=0,is_write=0;integer offset=0,left=0,ticks=0,checked=0,j,index;
wire accept=req&&!active&&ticks%5!=0;wire take=active&&is_write&&ticks%4!=0;
reg [31:0] maps[0:N-1];reg [15:0] gold[0:N-1];
video_row_remap_r21 #(.W(W),.H(H),.MAP_BASE(32'h03000000),.PACKED_MAP(1),.CACHE_ROW_BITS(CACHE_BITS)) dut(
 .clk(clk),.resetn(rst),.start(start),.night_curve(4'd2),.night_strength(9'd128),.source_base(32'h01000000),.result_base(32'h04000000),
 .busy(busy),.done(finished),.error(error),.cycles(cycles),.req(req),.write(write),.addr(addr),.beats(beats),.accept(accept),.rdata(rd),.rvalid(valid),.mem_done(done),.wdata(wd),.take(take),.map_cycles(),.load_cycles(),.pipe_cycles(),.write_cycles());
function [15:0] source(input integer idx);reg [31:0] value;begin
 value=idx*32'h9e3779b9+32'h7f4a7c15;value=(value^(value>>16))*32'h85ebca6b;source=value^(value>>13);
end endfunction
always @(posedge clk)begin
 ticks<=ticks+1;valid<=0;done<=0;
 if(rst)begin
  if(accept)begin
   active<=1;is_write<=write;offset<=addr;left<=beats;
   if(!write&&addr<32'h03000000&&BAD_SPAN)$fatal(1,"over-capacity map started source reads");
  end
  if(active&&!is_write&&ticks%3!=0)begin
   if(offset>=32'h03000000)begin
    index=(offset-32'h03000000)/4;
    for(j=0;j<8;j=j+1)rd[j*32+:32]<=BAD_SPAN?{16'(index+j<W/2?0:32*32),16'((index+j)%W*32)}:maps[index+j];
   end else begin
    if(offset<32'h01000000||offset+32>32'h01000000+W*H*2)$fatal(1,"source bounds");
    index=(offset-32'h01000000)/2;for(j=0;j<16;j=j+1)rd[j*16+:16]<=source(index+j);
   end
   valid<=1;offset<=offset+32;left<=left-1;if(left==1)begin active<=0;done<=1;end
  end
  if(take)begin
   index=(offset-32'h04000000)/2;if(index!=checked)$fatal(1,"output order");
   for(j=0;j<16;j=j+1)if(wd[j*16+:16]!==gold[index+j])$fatal(1,"cache=%0d pixel=%0d got=%h expected=%h",CACHE_BITS,index+j,wd[j*16+:16],gold[index+j]);
   checked<=checked+16;offset<=offset+32;left<=left-1;if(left==1)begin active<=0;done<=1;end
  end
 end
end
initial begin
 $readmemh("cache32_map.hex",maps);$readmemh("cache32_gold.hex",gold);
 repeat(5)@(negedge clk);rst=1;start=1;@(negedge clk);start=0;
 if(BAD_SPAN)begin wait(finished);#1;if(!error||checked!=0)$fatal(1,"oversized source span was not rejected");
  $display("PASS R22 cache guard: 33 source rows rejected before load for 32-row capacity");
 end else begin
  // Only three production-width scanlines: worst calibrated source rows >1024,
  // a distant row, then the first again. This tests ring/tag reuse, not a full frame.
  wait(checked==N);wait(dut.st==9&&dut.row==2);#1;
  if(error)$fatal(1,"legal calibrated span rejected");
  if($size(dut.bank00)!=(1<<(CACHE_BITS+6)))$fatal(1,"cache physical array did not shrink");
  $display("PASS R22 static cache rows=%0d: %0d exact pixels, Brown Q5, bilinear+Gamma, high source rows, ring/tag reuse, DMA gaps",1<<CACHE_BITS,checked);
 end
 $finish;
end
initial begin #3000000;$fatal(1,"cache test timeout");end
wire [15:0] trace_rdata0=rd[15:0], trace_cache_data0=dut.cache_read_data[15:0];
endmodule
