// Dual-clock block RAM FIFO. Gray pointer crossings are constrained in FDC.
module video_async_fifo #(parameter WIDTH=291,ABITS=9)(
 input wclk,wrstn,input push,input [WIDTH-1:0] din,output full,
 input rclk,rrstn,input pop,output reg [WIDTH-1:0] dout,
 output empty,output [ABITS:0] count);
reg [WIDTH-1:0] ram[0:(1<<ABITS)-1];
reg [ABITS:0] wp=0,rp=0,wg=0,rg=0;
(* ASYNC_REG="TRUE" *) reg [ABITS:0] rs1=0,rs2=0,ws1=0,ws2=0;
wire [ABITS:0] wn=wp+(push&&!full),rn=rp+(pop&&!empty);
wire [ABITS:0] wgn=(wn>>1)^wn,rgn=(rn>>1)^rn;
assign full=wg=={~rs2[ABITS:ABITS-1],rs2[ABITS-2:0]};
assign empty=rg==ws2;
function [ABITS:0] ungray;input [ABITS:0] g;integer k;
 begin ungray[ABITS]=g[ABITS];for(k=ABITS-1;k>=0;k=k-1)ungray[k]=ungray[k+1]^g[k];end
endfunction
assign count=ungray(ws2)-rp;
always @(posedge wclk)if(push&&!full)ram[wp[ABITS-1:0]]<=din;
always @(posedge rclk)dout<=ram[rn[ABITS-1:0]];
always @(posedge wclk or negedge wrstn)begin
 if(!wrstn)begin wp<=0;wg<=0;rs1<=0;rs2<=0;end
 else begin wp<=wn;wg<=wgn;rs1<=rg;rs2<=rs1;end
end
always @(posedge rclk or negedge rrstn)begin
 if(!rrstn)begin rp<=0;rg<=0;ws1<=0;ws2<=0;end
 else begin rp<=rn;rg<=rgn;ws1<=wg;ws2<=ws1;end
end
endmodule
