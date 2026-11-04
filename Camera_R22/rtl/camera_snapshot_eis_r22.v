// R20: slot-frozen night Gamma precedes snapshot storage and all CRCs. All DMA addresses are byte addresses.
// The display slot stays owned until COPY finishes; transport reads only SNAP_BASE.
module camera_snapshot_eis_r22 #(parameter FRAME_BYTES=4147200, parameter FISHEYE_ENABLE=0,ROTATION_ENABLE=0, parameter SNAP_BASE=32'h02000000)(
 input clk,resetn,input cpu_sel,input [11:0] cpu_addr,input [31:0] cpu_wdata,input [3:0] cpu_wstrb,
 output reg cpu_ready=0,output reg [31:0] cpu_rdata=0,
 output lock_request,output reg lock_release=0,input locked,input [1:0] locked_slot,input [31:0] locked_frame,
 input locked_eis,locked_lens,locked_fisheye,input [3:0] locked_night_curve,input [8:0] locked_night_strength,
 output req,write,output [31:0] addr,output [15:0] beats,input accept,
 input [255:0] rdata,input rvalid,mem_done,output [255:0] wdata,input take,input locked_rotation);
localparam IDLE=0,WAIT_LOCK=1,READ_CMD=2,READ_DATA=3,CRC_LOAD=4,CRC_STEP=5,WRITE_CMD=6,WRITE_DATA=7,CRC_PICK=8,CRC_SELECT=9,NIGHT_LOAD=10,NIGHT_RUN=11,NIGHT_DRAIN=12;
reg [3:0] state=0;
reg [3:0] geometry_flags=0;
wire rotation_frame=ROTATION_ENABLE&&locked_rotation;
wire fish_frame=FISHEYE_ENABLE&&locked_fisheye;
wire mapped_frame=locked_eis||rotation_frame||fish_frame;
reg [3:0] frame_curve=7;reg [8:0] frame_strength=0;
reg [8:0] night_issue=0,night_output=0;
reg [255:0] night_packed;
reg gamma_valid=0;reg [15:0] gamma_input;
wire gamma_done;wire [15:0] gamma_result;
wire night_running=state==NIGHT_RUN||state==NIGHT_DRAIN;
camera_night_pixel_r19 gamma(.clk(clk),.resetn(resetn),.in_valid(gamma_valid),
 .curve(frame_curve),.strength(frame_strength),.pixel(gamma_input),.out_valid(gamma_done),.result(gamma_result));

reg copying=0,available=0,chunk_ready=0,error=0,cancel_pending=0;
reg [31:0] offset=0,frame_id=0,whole_crc=0,whole_work=32'hffffffff,payload_crc=0;
reg [31:0] source=0,chunk_index=0;
reg [5:0] rd_count=0,wr_count=0;
reg [9:0] crc_index=0;
reg [31:0] chunk_work=32'hffffffff;
reg [7:0] crc_octet;
reg [255:0] buffer[0:31] /* synthesis syn_ramstyle="block_ram" */;
// One physical synchronous read port, shared by CRC/Gamma, native DMA and CPU.
// The old three read expressions caused three identical block-RAM copies.
reg [255:0] buffer_q;
wire [255:0] crc_word=buffer_q,cpu_word=buffer_q,send_word=buffer_q;
reg buffer_cpu_valid=0;
always @(posedge clk)if(state==NIGHT_RUN)gamma_input<=crc_word[night_issue[3:0]*16+:16];
always @(posedge clk or negedge resetn)
 if(!resetn)gamma_valid<=0;else gamma_valid<=state==NIGHT_RUN;
always @(posedge clk)if(night_running&&gamma_done)night_packed[night_output[3:0]*16+:16]<=gamma_result;

// Register the native DDR read payload before the distant block RAM port.
// Valid and final-read completion travel together so the last word is stored
// before CRC_LOAD. Writes keep their original completion/take protocol.
reg [255:0] read_payload;
reg read_valid=0,read_done=0;
always @(posedge clk)if(state==READ_DATA&&rvalid)read_payload<=rdata;
always @(posedge clk or negedge resetn)
 if(!resetn)begin read_valid<=0;read_done<=0;end
 else begin read_valid<=state==READ_DATA&&rvalid;read_done<=state==READ_DATA&&mem_done;end
reg cpu_seen=0;
wire command=cpu_sel&&!cpu_seen&&|cpu_wstrb&&cpu_addr==12'h100;
wire cancel=command&&cpu_wdata[2];
assign lock_request=(state==WAIT_LOCK);
assign req=(state==READ_CMD||state==WRITE_CMD);
assign write=(state==WRITE_CMD);
assign addr=write?SNAP_BASE+offset:(copying?source+offset:SNAP_BASE+(chunk_index<<10));
assign beats=16'd32;
assign wdata=send_word;
function [31:0] crc_byte;
 input [31:0] crc;input [7:0] value;reg [31:0] c;integer k;
 begin c=crc^{24'b0,value};for(k=0;k<8;k=k+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
endfunction
reg [7:0] crc_candidates[0:3];
wire [31:0] next_chunk=crc_byte(chunk_work,crc_octet);
wire [31:0] next_whole=crc_byte(whole_work,crc_octet);
// A single explicit RAM write port is shared by DMA fill and Gamma output.
// These operations occur in disjoint states; keep the mux outside the RAM.
wire gamma_buffer_we=night_running&&gamma_done&&night_output[3:0]==15;
wire buffer_we=read_valid||gamma_buffer_we;
wire [4:0] buffer_wa=read_valid?rd_count[4:0]:night_output[8:4];
wire [255:0] buffer_wd=read_valid?read_payload:{gamma_result,night_packed[239:0]};
wire buffer_next=state==NIGHT_RUN&&night_issue[3:0]==15&&night_issue!=511;
wire buffer_crc_re=state==CRC_LOAD||state==NIGHT_LOAD||buffer_next;
wire [4:0] buffer_crc_ra=state==CRC_LOAD?crc_index[9:5]:buffer_next?(night_issue[8:4]+5'd1):5'd0;
// Prefetch the first DMA word before WRITE_CMD is exposed. Later words keep
// the existing take-based lookahead, including arbitrary stalls between takes.
wire buffer_send_re=state==WRITE_CMD||state==WRITE_DATA||
 (state==CRC_STEP&&crc_index==1023&&copying);
// Keep the shared word unchanged while Gamma/CRC consumes its pixel/bytes.
// Payload reads wait until IDLE; status registers remain available while busy.
wire buffer_cpu_re=cpu_sel&&cpu_addr>=12'h400&&state==IDLE;
wire [4:0] buffer_ra=buffer_crc_re?buffer_crc_ra:
 buffer_send_re?(take?wr_count[4:0]+5'd1:wr_count[4:0]):cpu_addr[9:5];
// No RAM reset or asynchronous read. CPU data acknowledgements wait for its
// granted synchronous read; CSR polls and cancellation never need this port.
always @(posedge clk)begin
 if(buffer_we)buffer[buffer_wa]<=buffer_wd;
 if(buffer_crc_re||buffer_send_re||buffer_cpu_re)buffer_q<=buffer[buffer_ra];
 buffer_cpu_valid<=buffer_cpu_re;
 if(state==CRC_PICK)begin
  crc_candidates[0]<=crc_word[0+crc_index[2:0]*8+:8];
  crc_candidates[1]<=crc_word[64+crc_index[2:0]*8+:8];
  crc_candidates[2]<=crc_word[128+crc_index[2:0]*8+:8];
  crc_candidates[3]<=crc_word[192+crc_index[2:0]*8+:8];
 end
 if(state==CRC_SELECT)crc_octet<=crc_candidates[crc_index[4:3]];
end
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  frame_curve<=7;frame_strength<=0;geometry_flags<=0;night_issue<=0;night_output<=0;
  state<=IDLE;copying<=0;available<=0;chunk_ready<=0;error<=0;offset<=0;frame_id<=0;
  whole_crc<=0;whole_work<=32'hffffffff;payload_crc<=0;cpu_ready<=0;cpu_seen<=0;
  lock_release<=0;cpu_rdata<=0;rd_count<=0;wr_count<=0;crc_index<=0;chunk_work<=32'hffffffff;cancel_pending<=0;
 end else begin
  lock_release<=0;cpu_ready<=0;
  if(cancel)cancel_pending<=1;
  if(!cpu_sel)cpu_seen<=0;
  else if(!cpu_seen)begin cpu_seen<=1;end
  // One cycle after accepting CSR/data address, return synchronous RAM result.
  if(cpu_sel&&cpu_seen&&!cpu_ready&&(cpu_addr<12'h400||buffer_cpu_valid))begin
   cpu_ready<=1;
   if(cpu_addr>=12'h400)cpu_rdata<=cpu_word[cpu_addr[4:2]*32+:32];
   else case(cpu_addr)
    12'h120:cpu_rdata<={28'b0,geometry_flags};
    12'h104:cpu_rdata<={28'b0,error,chunk_ready,(state!=IDLE),available};
    12'h108:cpu_rdata<=frame_id;
    12'h10c:cpu_rdata<=whole_crc;
    12'h110:cpu_rdata<=chunk_index;
    12'h114:cpu_rdata<=payload_crc;
    12'h118:cpu_rdata<=offset;
    12'h11c:cpu_rdata<={19'b0,frame_strength,frame_curve};
    default:cpu_rdata<=0;
   endcase
  end
  if(cpu_sel&&!cpu_seen&&|cpu_wstrb&&cpu_addr==12'h110&&state==IDLE)chunk_index<=cpu_wdata;
  case(state)
   IDLE:if(command)begin
    if(cpu_wdata[0])begin available<=0;chunk_ready<=0;error<=0;offset<=0;whole_work<=32'hffffffff;copying<=1;state<=WAIT_LOCK;end
    else if(cpu_wdata[1])begin
     if(available&&chunk_index<FRAME_BYTES/1024)begin copying<=0;chunk_ready<=0;rd_count<=0;state<=READ_CMD;end
     else error<=1;
    end
   end
   WAIT_LOCK:if(locked)begin geometry_flags<={rotation_frame,fish_frame,mapped_frame&&locked_lens&&!fish_frame,locked_eis&&!rotation_frame};frame_curve<=mapped_frame?4'd7:locked_night_curve;frame_strength<=mapped_frame?9'd0:locked_night_strength;source<=(mapped_frame?32'h04000000:32'h01000000)+({30'b0,locked_slot}<<22);frame_id<=locked_frame;rd_count<=0;state<=READ_CMD;end
   READ_CMD:if(accept)begin rd_count<=0;state<=READ_DATA;end
   READ_DATA:begin
    if(read_valid)rd_count<=rd_count+1;
    if(read_done)begin crc_index<=0;chunk_work<=32'hffffffff;night_issue<=0;night_output<=0;
     state<=copying&&frame_curve!=7&&frame_strength!=0?NIGHT_LOAD:CRC_LOAD;end
   end
   NIGHT_LOAD:state<=NIGHT_RUN;
   NIGHT_RUN:begin
    night_issue<=night_issue+1'b1;
    if(night_issue==511)state<=NIGHT_DRAIN;
    if(gamma_done)night_output<=night_output+1'b1;
   end
   NIGHT_DRAIN:if(gamma_done)begin
    night_output<=night_output+1'b1;
    if(night_output==511)state<=CRC_LOAD;
   end
   CRC_LOAD:state<=CRC_PICK;
   CRC_PICK:state<=CRC_SELECT;
   CRC_SELECT:state<=CRC_STEP;
   CRC_STEP:begin
    chunk_work<=next_chunk;if(copying)whole_work<=next_whole;
    if(crc_index==1023)begin
     payload_crc<=next_chunk^32'hffffffff;
     if(copying)begin wr_count<=0;state<=WRITE_CMD;end
     else begin chunk_ready<=1;state<=IDLE;end
    end else begin crc_index<=crc_index+1;if(crc_index[4:0]==31)state<=CRC_LOAD;else state<=CRC_PICK;end
   end
   WRITE_CMD:if(accept)state<=WRITE_DATA;
   WRITE_DATA:begin
    if(take)wr_count<=wr_count+1;
    if(mem_done)begin
     offset<=offset+1024;
     if(offset==FRAME_BYTES-1024)begin whole_crc<=whole_work^32'hffffffff;available<=1;copying<=0;lock_release<=1;state<=IDLE;end
     else begin rd_count<=0;state<=READ_CMD;end
    end
   end
  endcase
  // No accepted native DMA is outstanding in these states. A cancellation
  // during READ/WRITE waits until the transaction drains, then releases safely.
  if((cancel||cancel_pending)&&(state==IDLE||state==WAIT_LOCK||state==CRC_LOAD||state==CRC_PICK||state==CRC_SELECT||state==CRC_STEP||state==NIGHT_LOAD||state==NIGHT_RUN||state==NIGHT_DRAIN))begin
   state<=IDLE;available<=0;chunk_ready<=0;copying<=0;lock_release<=1;cancel_pending<=0;
  end
 end
end
endmodule
