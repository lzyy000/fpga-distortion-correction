// OV5640 DVP: two bytes/pixel, HREF marks a complete line.
// Hold the final beat until next VS proves the whole frame geometry.
// Grants and payload are held through a toggle handshake; FIFO crosses clocks.
module camera_capture_eis_r22 #(parameter W=1920,H=1080,PIXEL_INPUT=0)(
 input pclk,prstn,stats_resetn,vs,href,input [(PIXEL_INPUT?16:8)-1:0] data,input [15:0] raw_data,input frame_invalid,
 output reg request=0,geometry_ok=0,input grant_toggle,grant_valid,input [1:0] grant_slot,
 output reg fatal=0,output reg [3:0] fault_reason /* synthesis syn_encoding="original" */ =0,
 output [31:0] fault_pixels,output reg [31:0] fault_geometry=0,first_fault_geometry=0,frame_gray=0,
 output [546:0] head,output [9:0] count,
 input clk,resetn,pop,input [31:0] clock_us,
 output reg sof=0,output reg [1:0] sof_slot=0,output reg [31:0] sof_us=0,readout_us=0);
localparam LINE_UNITS=PIXEL_INPUT?W:W*2;
reg vs_d=0,href_d=0,seen_frame=0,bad=0,armed=0,capturing=0,final_pending=0,frame_complete=0;
reg [12:0] line_bytes=0,lines=0;
reg [7:0] high_byte=0;
reg [1:0] slot=0;
reg [21:0] byte_offset=0;
reg [31:0] pixels=0,frame_count=0;
reg frame_tick=0;
reg pixel_tick=0,pixel_clear=0;
(* ASYNC_REG="TRUE" *) reg [1:0] gs=0;
reg grant_seen=0,grant_pending=0,push=0;reg [546:0] payload=0,final_beat=0;
reg [255:0] packed_pixels=0,packed_raw=0;
wire full,empty;
// Pixel count stops on fatal. Export it directly, avoiding a redundant snapshot flop.
assign fault_pixels=pixels;
// Last-line completion is registered, avoiding a wide counter decode in the
// VS-to-fault/commit path. Extra/short lines still set bad; VS during HREF fails.
wire good_frame=(!PIXEL_INPUT||!frame_invalid)&&seen_frame&&!bad&&frame_complete&&!href&&!href_d;
// A grant can only arm during frame blank (lines==0, HREF==0).
// The first HREF byte therefore starts capture without a wide counter decode.
wire first_byte=armed&&href;
wire take_byte=href&&(capturing||armed)&&!fatal;
wire [15:0] pixel=PIXEL_INPUT?data:{high_byte,data[7:0]};
wire pixel_valid=PIXEL_INPUT||line_bytes[0];
wire [3:0] lane=PIXEL_INPUT?line_bytes[3:0]:line_bytes[4:1];
wire last_pixel=lines==H-1&&line_bytes==LINE_UNITS-1;
reg [31:0] row_first_us=0,last_row_us=0;
always @(posedge pclk or negedge prstn)begin
 if(!prstn)begin sof<=0;sof_slot<=0;sof_us<=0;readout_us<=0;row_first_us<=0;last_row_us<=0;end
 else begin
  sof<=0;
  if(take_byte&&first_byte)begin sof<=1;sof_slot<=slot;sof_us<=clock_us;row_first_us<=clock_us;end
  if(take_byte&&!href_d&&lines==H-1)begin last_row_us<=clock_us;readout_us<=H==1?0:clock_us-row_first_us;end
 end
end
video_async_fifo #(.WIDTH(547)) fifo(.wclk(pclk),.wrstn(prstn),.push(push),.din(payload),.full(full),
 .rclk(clk),.rrstn(resetn),.pop(pop),.dout(head),.empty(empty),.count(count));
// Lifetime geometry-qualified frame counter survives local capture recovery.
always @(posedge pclk or negedge stats_resetn)begin
 if(!stats_resetn)begin frame_count<=0;frame_gray<=0;frame_tick<=0;end
 else begin
  // Separate the geometry decision, binary increment and Gray encoding.
  // Only one Gray bit changes per frame; no wide combinatorial enable cone.
  frame_tick<=prstn&&vs&&!vs_d&&good_frame;
  if(frame_tick)frame_count<=frame_count+1;
  frame_gray<=(frame_count>>1)^frame_count;
 end
end
// Pixel statistics are pipelined independently from the capture datapath.
// This removes VS/geometry priority muxes from the 32-bit incrementer.
always @(posedge pclk or negedge prstn)begin
 if(!prstn)pixels<=0;
 else if(pixel_clear)pixels<=0;
 else if(pixel_tick)pixels<=pixels+1;
end
always @(posedge pclk or negedge prstn)begin
 if(!prstn)begin
  vs_d<=0;href_d<=0;seen_frame<=0;bad<=0;armed<=0;capturing<=0;final_pending<=0;frame_complete<=0;
  line_bytes<=0;lines<=0;gs<=0;grant_seen<=0;grant_pending<=0;request<=0;geometry_ok<=0;
  fatal<=0;fault_reason<=0;fault_geometry<=0;first_fault_geometry<=0;push<=0;slot<=0;
  byte_offset<=0;pixel_tick<=0;pixel_clear<=0;packed_pixels<=0;packed_raw<=0;final_beat<=0;high_byte<=0;
 end else begin
  vs_d<=vs;href_d<=href;gs<={gs[0],grant_toggle};push<=0;
  pixel_tick<=take_byte&&pixel_valid;pixel_clear<=0;
  // Register the synchronized grant event before the geometry/fault mux.
  // Keep it pending through a VS edge until its held payload is consumed.
  if(gs[1]!=grant_seen)grant_pending<=1;
  if(vs&&!vs_d)begin
   geometry_ok<=good_frame;
   request<=~request;
   fault_geometry<={6'b0,lines,line_bytes};
   if(capturing&&!fatal)begin
    if(!good_frame||!final_pending)begin fatal<=1;fault_reason<=2;first_fault_geometry<={6'b0,lines,line_bytes};end
    else if(full)begin fatal<=1;fault_reason<=6;first_fault_geometry<={6'b0,lines,line_bytes};end
    else begin payload<=final_beat;push<=1;end
   end
   if(armed&&!fatal)begin fatal<=1;fault_reason<=7;first_fault_geometry<={6'b0,lines,line_bytes};end
   capturing<=0;final_pending<=0;seen_frame<=1;lines<=0;line_bytes<=0;bad<=0;frame_complete<=0;
  end else begin
   if(href)begin
    if(line_bytes>=LINE_UNITS||lines>=H)begin
     bad<=1;if(capturing&&!fatal)begin fatal<=1;fault_reason<=3;first_fault_geometry<={6'b0,lines,line_bytes};fault_geometry<={6'b0,lines,line_bytes};end
    end else line_bytes<=line_bytes+1;
   end
   if(!href&&href_d)begin
    frame_complete<=lines==H-1&&line_bytes==LINE_UNITS;
    if(line_bytes!=LINE_UNITS)begin
     bad<=1;if(capturing&&!fatal)begin fatal<=1;fault_reason<=4;first_fault_geometry<={6'b0,lines,line_bytes};fault_geometry<={6'b0,lines,line_bytes};end
    end
    line_bytes<=0;lines<=lines+1;
   end
   if(grant_pending&&!fatal)begin
    grant_pending<=0;grant_seen<=gs[1];
    if(grant_valid)begin
     if(armed||capturing||href||lines!=0)begin fatal<=1;fault_reason<=7;first_fault_geometry<={6'b0,lines,line_bytes};end
     else begin armed<=1;slot<=grant_slot;byte_offset<=0;pixel_clear<=1;end
    end
   end
   if(take_byte)begin
    if(first_byte)begin armed<=0;capturing<=1;end
    if(!pixel_valid)high_byte<=data[7:0];
    else begin
     packed_pixels[lane*16+:16]<=pixel;packed_raw[lane*16+:16]<=raw_data;
     if(lane==15)begin
      if(last_pixel)begin final_beat<={1'b1,slot,{8'h01,slot,byte_offset},raw_data,packed_raw[239:0],pixel,packed_pixels[239:0]};final_pending<=1;end
      else if(full)begin fatal<=1;fault_reason<=6;first_fault_geometry<={6'b0,lines,line_bytes};end
      else begin payload<={1'b0,slot,{8'h01,slot,byte_offset},raw_data,packed_raw[239:0],pixel,packed_pixels[239:0]};push<=1;end
      byte_offset<=byte_offset+32;
     end
    end
   end
  end
 end
end
endmodule
