`timescale 1ns/1ps
module tb_render;
localparam W=128,H=96,N=W*H,F=4;
reg clk=0;always #4 clk=~clk;reg rst=0,start=0;
reg [895:0] cfg=0;reg [3:0] curve=7;reg [8:0] strength=256;
wire busy,finished,req,write;wire [31:0] addr,cycles,fallbacks,rs_fallbacks;wire [15:0] beats;wire [255:0] wd;
reg [255:0] rd=0;reg valid=0,done=0;reg active=0,is_write=0;integer left=0,offset=0,ticks=0,seed=12345,j,k,f,writes=0;
wire accept=req&&!active&&(ticks%5!=0);wire take=active&&is_write&&(ticks%4!=0);
reg [31:0] words[0:F*28-1];reg [15:0] gold[0:F*N-1];reg [15:0] saved[0:N-1];
camera_eis_remap_r22 #(.W(W),.H(H)) dut(.clk(clk),.resetn(rst),.start(start),.source_base(32'h01c00000),.result_base(32'h04c00000),.config_words(cfg),
 .night_curve(curve),.night_strength(strength),.busy(busy),.source_done(finished),.last_cycles(cycles),.display_valid(),.display_bank(),.completed(),.displayed(),.display_limited(),.display_compare(),
 .req(req),.write(write),.addr(addr),.beats(beats),.wdata(wd),.rdata(rd),.accept(accept),.take(take),.valid(valid),.done(done),.fallbacks(fallbacks),.rs_fallbacks(rs_fallbacks));
function [15:0] source(input integer index);integer x,y;begin x=index%W;y=index/W;source={5'((x*3+y*7)&31),6'((x*5+y*11)&63),5'((x*7+y*3)&31)};end endfunction
always @(posedge clk)begin
 ticks<=ticks+1;valid<=0;done<=0;
 if(rst)begin
  if(accept)begin
   active<=1;is_write<=write;left<=beats;
   if(write)begin if(addr<32'h04c00000||addr+beats*32>32'h04c00000+N*2)$fatal(1,"result lease address");offset<=(addr-32'h04c00000)/2;end
   else begin if(addr<32'h01c00000||addr+beats*32>32'h01c00000+N*2)$fatal(1,"source lease address");offset<=(addr-32'h01c00000)/2;end
  end
  if(active&&!is_write&&ticks%3!=0)begin
   for(j=0;j<16;j=j+1)rd[j*16+:16]<=source(offset+j);
   valid<=1;offset<=offset+16;left<=left-1;if(left==1)begin active<=0;done<=1;end
  end
  if(take)begin
   for(j=0;j<16;j=j+1)saved[offset+j]<=wd[j*16+:16];
   writes<=writes+16;offset<=offset+16;left<=left-1;if(left==1)begin active<=0;done<=1;end
  end
 end
end
initial begin
 $readmemh("render_words.hex",words);$readmemh("render_gold.hex",gold);
 repeat(5)@(negedge clk);rst=1;
 for(f=0;f<F;f=f+1)begin
  wait(!busy);@(negedge clk);for(k=0;k<28;k=k+1)cfg[k*32+:32]=words[f*28+k];
  curve=f==1?2:f==2?0:7;strength=f==1?128:256;writes=0;start=1;@(negedge clk);start=0;
  wait(finished);@(negedge clk);if(writes!=N)$fatal(1,"incomplete native output");
  for(k=0;k<N;k=k+1)if(saved[k]!==gold[f*N+k])$fatal(1,"pixel f=%d i=%d got=%h expected=%h",f,k,saved[k],gold[f*N+k]);
  $display("R22 RENDER frame=%0d pixels=%0d cycles=%0d",f,N,cycles);$fflush();
  wait(!busy);repeat(3)@(negedge clk);
 end
 $display("PASS R22 remap: four native frames, shared lease addresses, shallow/vertical cache, Brown, RS, bilinear+Gamma exact, DMA stalls");$finish;
end
initial begin #20000000;$fatal(1,"timeout");end
endmodule
