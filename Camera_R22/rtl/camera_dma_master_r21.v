// Serialized native DDR transactions, arbitrated at <=16-beat boundaries.
// Every write source holds a complete packet before AW. This controller's
// native interface has no WVALID and no read back-pressure.
module camera_dma_master_r21 #(parameter CAP_TEMPORAL=0,HISTORY_BASE=32'h05000000,HISTORY_IN_CAPTURE=0)(input clk,resetn,
 input temporal_enable,history_clear,input [8:0] temporal_strength,output reg history_valid=0,
 output reg [31:0] temporal_fused=0,temporal_pixels=0,history_frames=0,
 input cpu_req,input [31:0] cpu_addr,cpu_data,input [3:0] cpu_strb,
 output cpu_ready,output reg [31:0] cpu_result,
 input eng_req,eng_write,input [31:0] eng_addr,input [15:0] eng_beats,
 output eng_accept,output eng_done,eng_valid,output [255:0] eng_rdata,
 input [255:0] eng_wdata,output eng_take,
 input disp_req,input [31:0] disp_addr,input [15:0] disp_beats,
 output disp_accept,disp_done,disp_valid,output [255:0] disp_data,
 input [546:0] cap_head,input [9:0] cap_count,output cap_pop,
 output reg cap_done=0,output reg [1:0] cap_slot=0,
 output reg [27:0] awaddr,araddr,output [3:0] awid,arid,
 output reg [3:0] awlen,arlen,output awvalid,arvalid,input awready,arready,
 output [255:0] wdata,output [31:0] wstrb,input wready,
 input [255:0] rdata,input rvalid,rlast,output idle);
localparam IDLE=0,RA=1,RD=2,WA=3,WD=4,RESP=5,
 T_LOAD=6,T_READ_CMD=7,T_READ=8,T_FEED=9,T_DRAIN=10,T_AWH=11,T_WH=12,T_AWC=13,T_WC=14,E_LOAD=15,E_WA=16,E_WD=17,E_DRAIN=18,RAW_AW=19,RAW_W=20;
reg [4:0] st=0;reg [1:0] owner;
// Separate native read registers by transaction owner. Distinct enables keep
// display, engine, history and CPU data from merging into one distant fanout.
// Payload, valid and last retain the existing one-clock native-read latency.
reg [255:0] rx_display,rx_engine,rx_history,rx_cpu;
reg rx_valid=0,rx_last=0;
always @(posedge clk)if(rvalid)begin
 if(st==RD&&owner==0)rx_display<=rdata;
 if(st==RD&&owner==1)rx_engine<=rdata;
 if(st==T_READ)rx_history<=rdata;
 if(st==RD&&owner==3)rx_cpu<=rdata;
end
always @(posedge clk or negedge resetn)
 if(!resetn)begin rx_valid<=0;rx_last<=0;end
 else begin rx_valid<=rvalid;rx_last<=rvalid&&rlast;end

reg ep=0,dp=0,ew;reg [31:0] ea,da;reg [15:0] en,dn;
reg [4:0] left;reg [2:0] lane;reg [255:0] cdata;reg [31:0] cmask;
// A block is popped completely before native DDR requests, so payload never
// changes underneath a stalled transaction. History is a separate 4-MiB region.
// Sixteen-entry staging packets are too shallow for 36-Kbit block RAM.
// PDS select_ram keeps the exact synchronous read registers and packet timing,
// but implements the 3 x 4096 data bits in distributed RAM instead of 12 DRMs.
reg [255:0] capture_block[0:15] /* synthesis syn_ramstyle="select_ram" */;
reg [255:0] filtered_block[0:15] /* synthesis syn_ramstyle="select_ram" */;
reg [255:0] raw_block[0:15] /* synthesis syn_ramstyle="select_ram" */;
reg [255:0] current_q,filtered_q,raw_q;
reg [255:0] write_sample;reg [3:0] write_sample_index;reg write_sample_valid=0;
always @(posedge clk or negedge resetn)
 if(!resetn)write_sample_valid<=0;else write_sample_valid<=st==E_LOAD||st==T_LOAD;
reg [3:0] load_index=0,read_index=0,feed_index=0,filter_index=0,tx_index=0;
reg [31:0] block_address=0;reg [1:0] block_slot=0;reg block_last=0,block_history=0,block_temporal=0;
// Latch filter choice at the first block of each captured frame. A new input
// frame may start while the previous frame's final FIFO beat is still pending.
reg frame_temporal=0,frame_history_usable=0;reg [8:0] frame_strength=256;
// The most recently committed capture slot remains owned by the frame manager
// until a newer complete frame exists. It already contains the filtered result.
// Reusing it avoids a redundant full-frame history write. Never read an alias
// of the current destination, even if a caller violates the slot contract.
reg [31:0] history_source=HISTORY_BASE,frame_history_source=HISTORY_BASE;
wire [31:0] capture_base={cap_head[543:534],22'b0};
wire next_history_usable=history_valid&&frame_temporal&&
 (!HISTORY_IN_CAPTURE||history_source!=capture_base)&&!history_clear;
wire [31:0] history_read_base=HISTORY_IN_CAPTURE?frame_history_source:HISTORY_BASE;
wire first_capture_block=cap_head[533:512]==22'b0;
wire requested_temporal=temporal_enable&&temporal_strength!=0;
wire capture_temporal=first_capture_block?requested_temporal:frame_temporal;
wire tf_valid=(st==T_READ&&rx_valid)||(st==T_FEED);
wire tf_done;wire [255:0] tf_result;wire [4:0] tf_fused;
wire [3:0] next_read=(st==T_READ)?(rx_valid?read_index+4'd1:read_index):
                              (st==T_FEED)?feed_index+4'd1:4'd0;
wire [3:0] next_write=(wready&&(st==RAW_W||st==T_WH||st==T_WC||st==E_WD))?tx_index+4'd1:tx_index;
always @(posedge clk)begin
 if(st==T_LOAD)begin capture_block[load_index]<=cap_head[255:0];raw_block[load_index]<=cap_head[511:256];end
 current_q<=capture_block[next_read];
 // Stage both preload sources before the shared result RAM input mux.
 if(st==E_LOAD||st==T_LOAD)begin write_sample<=st==T_LOAD?cap_head[255:0]:eng_wdata;write_sample_index<=load_index;end
 if(write_sample_valid)filtered_block[write_sample_index]<=write_sample;
 else if(tf_done)filtered_block[filter_index]<=tf_result;

 filtered_q<=filtered_block[next_write];raw_q<=raw_block[next_write];
end
generate if(CAP_TEMPORAL)begin:temporal
 camera_temporal_rgb565_r19 filter(.clk(clk),.resetn(resetn),.valid(tf_valid),
  .use_history(st==T_READ&&block_history),.strength(frame_strength),.current(current_q),.history(rx_history),
  .out_valid(tf_done),.result(tf_result),.fused_pixels(tf_fused));
end else begin:no_temporal
 assign tf_done=1'b0;assign tf_result=256'b0;assign tf_fused=5'b0;
end endgenerate
assign idle=st==IDLE;
assign eng_accept=eng_req&&!ep;
assign disp_accept=disp_req&&!dp;
assign awvalid=st==WA||st==T_AWH||st==T_AWC||st==E_WA||st==RAW_AW;assign arvalid=st==RA||st==T_READ_CMD;assign awid=owner;assign arid=owner;
// All engine/capture writes are preloaded before AW. WD is reached only by
// CPU writes; engine writes use E_WD, capture writes use RAW_W/T_WH/T_WC.
// Keep the native data mux entirely on registered/RAM-read sources, including
// idle/address cycles: a live eng_wdata fallback creates a snapshot request ->
// arbiter -> 256-bit write-mux -> DDR timing path even when no beat is consumed.
assign wdata=st==RAW_W?raw_q:(st==T_WH||st==T_WC||st==E_WD)?filtered_q:cdata;
assign wstrb=owner==3?cmask:32'hffffffff;
assign eng_rdata=rx_engine;assign disp_data=rx_display;
assign eng_valid=st==RD&&owner==1&&rx_valid;
assign disp_valid=st==RD&&owner==0&&rx_valid;
assign eng_take=st==E_LOAD;
assign cap_pop=st==T_LOAD;
wire cap_complete=st==T_WC&&wready&&tx_index==15&&block_last;
// Register the qualified commit notification and its slot together.
// Clients observe completion only after the final native write edge.
always @(posedge clk or negedge resetn)
 if(!resetn)begin cap_done<=0;cap_slot<=0;end
 else begin
  cap_done<=cap_complete;
  cap_slot<=(st==T_WC)?block_slot:cap_head[545:544];
 end
assign eng_done=(owner==1)&&((st==RD&&rx_valid&&rx_last)||(st==E_WD&&wready&&left==1))&&en<=16;
assign disp_done=owner==0&&st==RD&&rx_valid&&rx_last&&dn<=16;
assign cpu_ready=st==RESP;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
 frame_strength<=256;st<=IDLE;ep<=0;dp<=0;awaddr<=0;araddr<=0;awlen<=0;arlen<=0;cpu_result<=0;
 load_index<=0;read_index<=0;feed_index<=0;filter_index<=0;tx_index<=0;
 block_address<=0;block_slot<=0;block_last<=0;block_history<=0;block_temporal<=0;history_valid<=0;frame_temporal<=0;frame_history_usable<=0;history_source<=HISTORY_BASE;frame_history_source<=HISTORY_BASE;
 temporal_fused<=0;temporal_pixels<=0;history_frames<=0;
 end
 else begin
  if(eng_accept)begin ep<=1;ea<=eng_addr;en<=eng_beats;ew<=eng_write;end
  if(disp_accept)begin dp<=1;da<=disp_addr;dn<=disp_beats;end
  case(st)
   IDLE:if(dp)begin owner<=0;araddr<=da>>2;arlen<=dn>16?15:dn-1;st<=RA;end
    else if(cap_count>=16)begin
     owner<=2;
     if(CAP_TEMPORAL&&first_capture_block)begin
      frame_strength<=temporal_strength;frame_temporal<=requested_temporal;frame_history_source<=history_source;frame_history_usable<=next_history_usable;
      // An OFF frame invalidates history; the first ON frame always warms up.
      if(!requested_temporal||!frame_temporal)history_valid<=0;
     end
     begin
      block_address<=cap_head[543:512];block_slot<=cap_head[545:544];block_last<=0;block_temporal<=CAP_TEMPORAL&&capture_temporal;
      block_history<=history_valid&&(first_capture_block?next_history_usable:frame_history_usable);load_index<=0;filter_index<=0;tx_index<=0;st<=T_LOAD;
     end
    end
    else if(ep)begin
     owner<=1;left<=en>16?16:en;
     if(ew)begin awaddr<=ea>>2;awlen<=en>16?15:en-1;load_index<=0;tx_index<=0;st<=E_LOAD;end
     else begin araddr<=ea>>2;arlen<=en>16?15:en-1;st<=RA;end
    end else if(cpu_req)begin
     owner<=3;lane<=cpu_addr[4:2];left<=1;
     if(|cpu_strb)begin
      awaddr<={3'b0,cpu_addr[28:5],3'b0};awlen<=0;
      cdata<={224'b0,cpu_data}<<(cpu_addr[4:2]*32);cmask<={28'b0,cpu_strb}<<(cpu_addr[4:2]*4);st<=WA;
     end else begin araddr<={3'b0,cpu_addr[28:5],3'b0};arlen<=0;st<=RA;end
    end
   RA:if(arready)st<=RD;
   RD:if(rx_valid)begin
    if(owner==3)cpu_result<=rx_cpu>>(lane*32);
    if(rx_last)begin
     if(owner==0)begin if(dn<=16)dp<=0;else begin dn<=dn-16;da<=da+512;end end
     if(owner==1)begin if(en<=16)ep<=0;else begin en<=en-16;ea<=ea+512;end end
     st<=owner==3?RESP:IDLE;
    end
   end
   WA:if(awready)st<=WD;
   WD:if(wready)begin
    left<=left-1;
    if(left==1)begin
     if(owner==1)begin if(en<=16)ep<=0;else begin en<=en-16;ea<=ea+512;end end
     st<=owner==3?RESP:IDLE;
    end
   end
   // Clients supply the complete subburst before AW. Local preload take
   // has no combinational DDR WREADY->arbiter->client-RAM address path.
   E_LOAD:begin
    if({1'b0,load_index}+5'd1==left)begin tx_index<=0;st<=E_DRAIN;end
    else load_index<=load_index+1'b1;
   end
   E_DRAIN:st<=E_WA; // Commit the last sampled beat before AW, including one-beat packets.
   E_WA:if(awready)st<=E_WD;
   E_WD:if(wready)begin
    left<=left-1;tx_index<=tx_index+1'b1;
    if(left==1)begin
     if(en<=16)ep<=0;else begin en<=en-16;ea<=ea+512;end
     st<=IDLE;
    end
   end
   RESP:st<=IDLE;
   T_LOAD:begin
    if(load_index==15)begin
     block_last<=cap_head[546];read_index<=0;feed_index<=0;tx_index<=0;
     awaddr<={8'h06,block_slot,block_address[21:0]}>>2;awlen<=15;st<=RAW_AW;
    end else load_index<=load_index+1'b1;
   end
   RAW_AW:if(awready)st<=RAW_W;
   RAW_W:if(wready)begin
    if(tx_index==15)begin
     tx_index<=0;
     if(block_temporal)begin
      if(block_history)begin araddr<=(history_read_base+{10'b0,block_address[21:0]})>>2;arlen<=15;st<=T_READ_CMD;end
      else st<=T_FEED;
     end else begin awaddr<=block_address>>2;awlen<=15;st<=T_AWC;end
    end else tx_index<=tx_index+1'b1;
   end
   T_READ_CMD:if(arready)st<=T_READ;
   T_READ:if(rx_valid)begin read_index<=read_index+1'b1;if(rx_last)st<=T_DRAIN;end
   T_FEED:begin feed_index<=feed_index+1'b1;if(feed_index==15)st<=T_DRAIN;end
   T_DRAIN:begin end
   T_AWH:if(awready)st<=T_WH;
   T_WH:if(wready)begin
    if(tx_index==15)begin
     tx_index<=0;awaddr<=block_address>>2;awlen<=15;st<=T_AWC;
    end else tx_index<=tx_index+1'b1;
   end
   T_AWC:if(awready)st<=T_WC;
   T_WC:if(wready)begin
    if(tx_index==15)begin
     st<=IDLE;
     if(block_last&&block_temporal)begin history_valid<=1;history_frames<=history_frames+1'b1;history_source<={block_address[31:22],22'b0};end
    end else tx_index<=tx_index+1'b1;
   end
  endcase
  if(tf_done)begin
   temporal_fused<=temporal_fused+{27'b0,tf_fused};temporal_pixels<=temporal_pixels+32'd16;
   filter_index<=filter_index+1'b1;
   if(filter_index==15)begin
    tx_index<=0;awlen<=15;
    if(HISTORY_IN_CAPTURE)begin awaddr<=block_address>>2;st<=T_AWC;end
    else begin awaddr<=(HISTORY_BASE+{10'b0,block_address[21:0]})>>2;st<=T_AWH;end
   end
  end
  // Recovery cancels history even if the aborted frame overwrote some lines.
  if(history_clear)history_valid<=0;
 end
end
endmodule
