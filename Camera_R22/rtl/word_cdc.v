// One outstanding CPU word transaction. Payload remains stable until ack.
module word_cdc(input cpu_clk,cpu_rstn,input cpu_valid,input [31:0] cpu_addr,cpu_wdata,
 input [3:0] cpu_wstrb,output cpu_ready,output [31:0] cpu_rdata,
 input mem_clk,mem_rstn,output mem_valid,output [31:0] mem_addr,mem_wdata,
 output [3:0] mem_wstrb,input mem_ready,input [31:0] mem_rdata);
reg req_toggle=0,ack_toggle=0;
reg [31:0] held_addr,held_data,result;
reg [3:0] held_strb;
reg [1:0] ack_sync=0,req_sync=0;
reg [1:0] cs=0,ms=0;
always @(posedge cpu_clk or negedge cpu_rstn) begin
 if(!cpu_rstn) begin cs<=0;req_toggle<=0;ack_sync<=0; end
 else begin
  ack_sync<={ack_sync[0],ack_toggle};
  case(cs)
   0:if(cpu_valid) begin held_addr<=cpu_addr;held_data<=cpu_wdata;held_strb<=cpu_wstrb;req_toggle<=~req_toggle;cs<=1;end
   1:if(ack_sync[1]==req_toggle) cs<=2;
   2:cs<=3;
   3:if(!cpu_valid) cs<=0;
  endcase
 end
end
assign cpu_ready=(cs==2);assign cpu_rdata=result;
always @(posedge mem_clk or negedge mem_rstn) begin
 if(!mem_rstn) begin ms<=0;ack_toggle<=0;req_sync<=0;end
 else begin
  req_sync<={req_sync[0],req_toggle};
  case(ms)
   0:if(req_sync[1]!=ack_toggle) ms<=1;
   1:if(mem_ready) begin result<=mem_rdata;ack_toggle<=req_sync[1];ms<=0;end
  endcase
 end
end
assign mem_valid=(ms==1);assign mem_addr=held_addr;assign mem_wdata=held_data;assign mem_wstrb=held_strb;
endmodule
