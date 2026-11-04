// Four raw/result pairs: display + waiting presentation + processing + acquisition.
// A frame commits at the next sensor VS; three pairs cannot cover this overlap.
// Before the LUT is ready, or when correction is OFF, present processed
// source frames directly. Never spend a full remap frame on a bypassed view.
module camera_eis_manager_r22 #(parameter FISHEYE_ENABLE=0,ROTATION_ENABLE=0)(input clk,resetn,enabled,lut_ready,correction_enable,
 input eis_enable,fisheye_enable,input [3:0] config_ready,
 output reg [1:0] process_slot=0,output reg process_eis=0,output [3:0] slot_eis,slot_lens,
 output display_eis,display_fisheye,output [3:0] slot_fisheye,input capture_request,geometry_ok,capture_fatal,recover,
 output reg grant_toggle=0,grant_valid=0,output reg [1:0] grant_slot=0,
 input cap_done,input [1:0] cap_slot,input display_edge,
 output reg display_valid=0,output reg [1:0] display_slot=0,output display_corrected,
 output reg [31:0] captured=0,processed=0,displayed=0,dropped=0,aborted=0,
 output reg fatal=0,output reg [3:0] fault_reason=0,
 output reg process_start=0,output reg [31:0] source_base=0,result_base=0,
 input process_busy,process_done,process_error,input [31:0] process_cycles,
 output reg [31:0] last_cycles=0,
 input snapshot_request,snapshot_release,output reg snapshot_locked=0,
 output reg [1:0] snapshot_slot=0,output reg [31:0] snapshot_frame=0,
 input rotation_enable,output [3:0] slot_rotation,output display_rotation);
localparam FREE=0,CAPTURE=1,READY=2,PROCESS=3,COMPLETE=4,DISPLAY=5;
reg [2:0] state[0:3];reg corrected[0:3];reg [31:0] frame_id[0:3];
// Keep the scheduling flag shared: rotation identity does not add another
// OR level to READY/PROCESS selection or the frame-completion path.
reg [3:0] motion_flags=0,lens_flags=0,fish_flags=0,rotation_flags=0;
wire rotation_requested=ROTATION_ENABLE&&rotation_enable;
assign slot_rotation=rotation_flags;assign display_rotation=display_valid&&corrected[display_slot]&&rotation_flags[display_slot];
wire fish_requested=FISHEYE_ENABLE&&fisheye_enable;
assign slot_fisheye=fish_flags;assign display_fisheye=display_valid&&corrected[display_slot]&&fish_flags[display_slot];
 assign slot_eis=motion_flags&~rotation_flags;assign slot_lens=lens_flags;assign display_eis=display_valid&&corrected[display_slot]&&motion_flags[display_slot]&&!rotation_flags[display_slot];
 reg running=0;reg [1:0] current=0;
// At most one new image per two HDMI frames; avoid alternating 1/3 repeats.
reg display_cooldown=0;
(* ASYNC_REG="TRUE" *) reg [1:0] rs=0,fs=0,geo=0;
reg seen=0,was_recovering=0;reg [2:0] abort_slots;
integer j;reg have_free,have_ready,have_complete;reg [1:0] free_slot,ready_slot,complete_slot;
assign display_corrected=display_valid&&corrected[display_slot];
// Balanced oldest-frame selection. Each stage depends only on its inputs;
// avoid a dynamically indexed selector fed back through a procedural loop.
wire [3:0] can_process;
 genvar r;generate for(r=0;r<4;r=r+1)begin
 assign can_process[r]=state[r]==READY&&((motion_flags[r]||fish_flags[r])?config_ready[r]:lut_ready);
 end endgenerate
 wire ready01=can_process[0]||can_process[1];
wire ready23=can_process[2]||can_process[3];
wire complete01=state[0]==COMPLETE||state[1]==COMPLETE;
wire complete23=state[2]==COMPLETE||state[3]==COMPLETE;
wire older10=$signed(frame_id[1]-frame_id[0])<0;
wire older32=$signed(frame_id[3]-frame_id[2])<0;
wire r01=can_process[1]&&(!can_process[0]||older10);
wire r23=can_process[3]&&(!can_process[2]||older32);
wire c01=state[1]==COMPLETE&&(state[0]!=COMPLETE||older10);
wire c23=state[3]==COMPLETE&&(state[2]!=COMPLETE||older32);
wire rhigh=ready23&&(!ready01||$signed(frame_id[{1'b1,r23}]-frame_id[{1'b0,r01}])<0);
wire chigh=complete23&&(!complete01||$signed(frame_id[{1'b1,c23}]-frame_id[{1'b0,c01}])<0);
always @*begin
 have_free=0;free_slot=0;abort_slots=0;
 for(j=3;j>=0;j=j-1)begin
  if(state[j]==CAPTURE)abort_slots=abort_slots+1'b1;
  if(state[j]==FREE)begin have_free=1;free_slot=j;end
 end
 have_ready=ready01||ready23;ready_slot={rhigh,rhigh?r23:r01};
 have_complete=complete01||complete23;complete_slot={chigh,chigh?c23:c01};
end
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  for(j=0;j<4;j=j+1)begin state[j]<=FREE;frame_id[j]<=0;corrected[j]<=0;end
  snapshot_locked<=0;snapshot_slot<=0;snapshot_frame<=0;motion_flags<=0;lens_flags<=0;fish_flags<=0;rotation_flags<=0;process_slot<=0;process_eis<=0;
  rs<=0;fs<=0;geo<=0;seen<=0;grant_toggle<=0;grant_valid<=0;grant_slot<=0;
  display_cooldown<=0;display_valid<=0;display_slot<=0;captured<=0;processed<=0;displayed<=0;dropped<=0;aborted<=0;
  was_recovering<=0;fatal<=0;fault_reason<=0;running<=0;current<=0;process_start<=0;source_base<=0;result_base<=0;last_cycles<=0;
 end else begin
  process_start<=0;was_recovering<=recover;
  if(display_edge)display_cooldown<=0;
  if(snapshot_release)snapshot_locked<=0;
  else if(snapshot_request&&display_valid&&!snapshot_locked)begin
   snapshot_locked<=1;snapshot_slot<=display_slot;snapshot_frame<=frame_id[display_slot];
  end
  if(recover)begin
   rs<=0;fs<=0;geo<=0;seen<=0;grant_toggle<=0;grant_valid<=0;
   if(fault_reason!=3)begin fatal<=0;fault_reason<=0;end
   if(!was_recovering)begin
    for(j=0;j<4;j=j+1)if(state[j]==CAPTURE)state[j]<=FREE;
    aborted<=aborted+abort_slots;
   end
  end else begin
   rs<={rs[0],capture_request};fs<={fs[0],capture_fatal};geo<={geo[0],geometry_ok};
   if(fs[1])begin fatal<=1;if(!fatal)fault_reason<=1;end
   if(rs[1]!=seen)begin
    seen<=rs[1];grant_toggle<=rs[1];grant_valid<=0;
    if(enabled&&geo[1]&&!fatal&&have_free)begin state[free_slot]<=CAPTURE;corrected[free_slot]<=0;motion_flags[free_slot]<=eis_enable||rotation_requested;rotation_flags[free_slot]<=rotation_requested;lens_flags[free_slot]<=correction_enable&&!fish_requested;fish_flags[free_slot]<=fish_requested;grant_slot<=free_slot;grant_valid<=1;end
    else if(enabled&&geo[1])dropped<=dropped+1;
   end
   if(cap_done)begin
    if(state[cap_slot]!=CAPTURE)begin fatal<=1;if(!fatal)fault_reason<=2;end
    else begin state[cap_slot]<=(motion_flags[cap_slot]||fish_flags[cap_slot]||(lut_ready&&lens_flags[cap_slot]))?READY:COMPLETE;corrected[cap_slot]<=0;frame_id[cap_slot]<=captured+1;captured<=captured+1;end
   end
  end
  // Accepted frames finish with their captured modes; OFF affects subsequent grants.
  if(enabled&&!running&&!process_busy&&have_ready&&!fatal)begin
   current<=ready_slot;process_slot<=ready_slot;process_eis<=motion_flags[ready_slot]||fish_flags[ready_slot];state[ready_slot]<=PROCESS;running<=1;process_start<=1;
   source_base<=32'h01000000+({30'b0,ready_slot}<<22);
   result_base<=32'h04000000+({30'b0,ready_slot}<<22);
  end
  if(process_done)begin
   running<=0;last_cycles<=process_cycles;
   if(process_error)begin fatal<=1;if(!fatal)fault_reason<=3;state[current]<=FREE;end
   else begin state[current]<=COMPLETE;corrected[current]<=1;processed<=processed+1;end
  end
  if(display_edge&&!display_cooldown&&have_complete&&!fatal&&!snapshot_locked&&!(snapshot_request&&display_valid))begin
   if(display_valid)state[display_slot]<=FREE;
   display_cooldown<=1;state[complete_slot]<=DISPLAY;display_slot<=complete_slot;display_valid<=1;displayed<=displayed+1;
  end
 end
end
endmodule
