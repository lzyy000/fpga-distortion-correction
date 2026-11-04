// Native DDR word addresses, 256-bit beats. Four-beat cached reads and
// byte-masked engine write combining. CPU writes remain strongly ordered.
module pango_word_master(input clk,resetn,
 input cpu_req,input [31:0] cpu_addr,cpu_data,input [3:0] cpu_strb,
 output cpu_ready,output [31:0] cpu_result,
 input eng_req,input [31:0] eng_addr,eng_data,input [3:0] eng_strb,
 input eng_flush,output eng_flushed,
 output eng_ready,output [31:0] eng_result,eng_next,
 input line_req,input [27:0] line_addr,input [15:0] line_beats,
 output line_done,output line_data_valid,output [255:0] line_data,output reg overrun=0,
 output reg [27:0] awaddr,output [3:0] awid,awlen,output awvalid,input awready,
 output [255:0] wdata,output [31:0] wstrb,output wvalid,input wready,
 output reg [27:0] araddr,output [3:0] arid,output reg [3:0] arlen,output arvalid,input arready,
 input [255:0] rdata,input rvalid,rlast);
localparam IDLE=0,WADDR=1,WDATA=2,RADDR=3,RDATA=4,RESP=5,LADDR=6,LDATA=7,LOOKUP=8,HIT=9;
reg [3:0] st=0;
reg owner,flushing=0;
reg [63:0] result;
reg [255:0] direct_data;
reg [31:0] direct_mask;
reg [2:0] lane;
reg pending=0;
reg [27:0] pending_addr,next_line;
reg [15:0] pending_beats,remaining;
// 64 complete 32-byte lines (2 KiB). Synchronous data read infers block RAM.
reg [255:0] cache_data[0:63];
reg [20:0] cache_tag[0:63];
reg [63:0] cache_valid=0;
reg [5:0] lookup_index,fill_index;
reg [20:0] lookup_tag;
reg [255:0] cache_q;
reg [1:0] critical_beat,read_beat;
// Only one dirty beat; engine stores may acknowledge before native completion.
// eng_flush is a barrier: COMMIT must wait for eng_flushed.
reg wb_valid=0;
reg [26:0] wb_addr;
reg [255:0] wb_data;
reg [31:0] wb_mask;
wire select_engine=eng_req;
wire [31:0] request_addr=select_engine?eng_addr:cpu_addr;
wire [31:0] request_data=select_engine?eng_data:cpu_data;
wire [3:0] request_mask=select_engine?eng_strb:cpu_strb;
wire [5:0] request_index=request_addr[10:5];
wire [20:0] request_tag=request_addr[31:11];
wire dirty_conflict=eng_req && (eng_addr[31:5]==wb_addr);
wire need_flush=wb_valid && (eng_flush || cpu_req ||
 (eng_req && ((|eng_strb)?!dirty_conflict:dirty_conflict)));
assign awid=4'd1;assign awlen=0;assign awvalid=(st==WADDR);
assign wdata=flushing?wb_data:direct_data;
assign wstrb=flushing?wb_mask:direct_mask;
assign wvalid=(st==WDATA);
assign arid=(st==LADDR || st==LDATA)?4'd0:4'd1;
assign arvalid=(st==RADDR || st==LADDR);
assign cpu_ready=(st==RESP && !owner);assign eng_ready=(st==RESP && owner);
assign cpu_result=result[31:0];assign eng_result=result[31:0];assign eng_next=result[63:32];
assign eng_flushed=(st==IDLE && !wb_valid);
assign line_data=rdata;assign line_data_valid=(st==LDATA && rvalid);
assign line_done=(st==LDATA && rvalid && rlast && remaining<=16);
integer j;
always @(posedge clk)begin
 cache_q<=cache_data[lookup_index];
 if(st==RDATA && rvalid)cache_data[fill_index]<=rdata;
end
always @(posedge clk or negedge resetn) begin
 if(!resetn)begin
  st<=IDLE;pending<=0;overrun<=0;awaddr<=0;araddr<=0;arlen<=0;remaining<=0;
  cache_valid<=0;wb_valid<=0;wb_mask<=0;flushing<=0;
 end else begin
  if(line_req)begin
   if(pending || st==LADDR || st==LDATA)overrun<=1;
   else begin pending<=1;pending_addr<=line_addr;pending_beats<=line_beats;end
  end
  case(st)
   IDLE:if(need_flush)begin
    awaddr<=wb_addr[26:0]<<3;flushing<=1;st<=WADDR;
   end else if(pending)begin
    pending<=0;next_line<=pending_addr;araddr<=pending_addr;
    remaining<=pending_beats;arlen<=pending_beats>16?15:pending_beats-1'b1;st<=LADDR;
   end else if(eng_req || cpu_req)begin
    owner<=select_engine;lane<=request_addr[4:2];flushing<=0;
    if(|request_mask)begin
     // Invalidate both on buffered acceptance and on flush. Prefetches of
     // adjacent lines between these events must not leave a stale cache hit.
     if(cache_valid[request_index] && cache_tag[request_index]==request_tag)
      cache_valid[request_index]<=0;
     if(select_engine)begin
      wb_valid<=1;wb_addr<=request_addr[31:5];
      wb_mask<=wb_valid?(wb_mask|({28'b0,eng_strb}<<(eng_addr[4:2]*4))):({28'b0,eng_strb}<<(eng_addr[4:2]*4));
      for(j=0;j<32;j=j+1)if(eng_addr[4:2]==j/4 && eng_strb[j%4])
       wb_data[j*8+:8]<=eng_data[(j%4)*8+:8];
      result<=0;st<=RESP;
     end else begin
      awaddr<={3'b0,cpu_addr[28:5],3'b0};
      direct_data<={224'b0,cpu_data}<<(cpu_addr[4:2]*32);
      direct_mask<={28'b0,cpu_strb}<<(cpu_addr[4:2]*4);st<=WADDR;
     end
    end else begin
     lookup_index<=request_index;lookup_tag<=request_tag;
     critical_beat<=request_addr[6:5];fill_index<={request_addr[10:7],2'b0};read_beat<=0;
     // 128-byte aligned prefetch, four native beats, no crossing a cache group.
     araddr<={3'b0,request_addr[28:7],5'b0};arlen<=3;st<=LOOKUP;
    end
   end
   LOOKUP:if(cache_valid[lookup_index] && cache_tag[lookup_index]==lookup_tag)st<=HIT;else st<=RADDR;
   HIT:begin result<=cache_q>>(lane*32);st<=RESP;end
   WADDR:if(awready)st<=WDATA;
   WDATA:if(wready)begin
    if(flushing)begin
     wb_valid<=0;wb_mask<=0;
     if(cache_valid[wb_addr[5:0]] && cache_tag[wb_addr[5:0]]==wb_addr[26:6])cache_valid[wb_addr[5:0]]<=0;
     st<=IDLE;flushing<=0;
    end else begin result<=0;st<=RESP;end
   end
   RADDR:if(arready)st<=RDATA;
   RDATA:if(rvalid)begin
    cache_valid[fill_index]<=1;cache_tag[fill_index]<=lookup_tag;
    if(read_beat==critical_beat)result<=rdata>>(lane*32);
    fill_index<=fill_index+1'b1;read_beat<=read_beat+1'b1;
    if(rlast)st<=RESP;
   end
   RESP:st<=IDLE;
   LADDR:if(arready)st<=LDATA;
   LDATA:if(rvalid && rlast)begin
    if(remaining<=16)st<=IDLE;
    else begin remaining<=remaining-16;next_line<=next_line+128;araddr<=next_line+128;
     arlen<=(remaining-16)>16?15:(remaining-16)-1'b1;st<=LADDR;end
   end
  endcase
 end
end
endmodule
