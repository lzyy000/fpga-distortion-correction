// Raw-only step 1. Only DDR-complete slots become visible on HDMI frame edges.
module camera_frame_manager(input clk,resetn,enabled,capture_request,geometry_ok,capture_fatal,recover,
 output reg grant_toggle=0,grant_valid=0,output reg [1:0] grant_slot=0,
 input cap_done,input [1:0] cap_slot,input display_edge,
 output reg display_valid=0,output reg [1:0] display_slot=0,
 output reg [31:0] captured=0,displayed=0,dropped=0,aborted=0,
 output reg fatal=0,output reg [3:0] fault_reason=0,
 input snapshot_request,snapshot_release,output reg snapshot_locked=0,
 output reg [1:0] snapshot_slot=0,output reg [31:0] snapshot_frame=0);
localparam FREE=0,CAPTURE=1,COMPLETE=2,DISPLAY=3;
reg [1:0] state[0:2];
reg [31:0] frame_id[0:2];
(* ASYNC_REG="TRUE" *) reg [1:0] rs=0,fs=0,geo=0;
reg seen=0,was_recovering=0;reg [1:0] abort_slots;
integer j;reg have_free,have_complete;reg [1:0] free_slot,complete_slot;
always @*begin
 have_free=0;have_complete=0;free_slot=0;complete_slot=0;abort_slots=0;
 for(j=2;j>=0;j=j-1)begin
  if(state[j]==CAPTURE)abort_slots=abort_slots+1'b1;
  if(state[j]==FREE)begin have_free=1;free_slot=j;end
  if(state[j]==COMPLETE)begin have_complete=1;complete_slot=j;end
 end
end
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  for(j=0;j<3;j=j+1)begin state[j]<=FREE;frame_id[j]<=0;end
  snapshot_locked<=0;snapshot_slot<=0;snapshot_frame<=0;
  rs<=0;fs<=0;geo<=0;seen<=0;grant_toggle<=0;grant_valid<=0;grant_slot<=0;
  display_valid<=0;display_slot<=0;captured<=0;displayed<=0;dropped<=0;aborted<=0;was_recovering<=0;fatal<=0;fault_reason<=0;
 end else begin
  was_recovering<=recover;
  if(snapshot_release)snapshot_locked<=0;
  else if(snapshot_request&&display_valid&&!snapshot_locked)begin
   snapshot_locked<=1;snapshot_slot<=display_slot;snapshot_frame<=frame_id[display_slot];
  end
  if(recover)begin
   // Controller has drained all accepted writes before entering recovery.
   // Completed/displayed slots stay owned and keep the last good picture.
   rs<=0;fs<=0;geo<=0;seen<=0;grant_toggle<=0;grant_valid<=0;
   fatal<=0;fault_reason<=0;
   if(!was_recovering)begin
    for(j=0;j<3;j=j+1)if(state[j]==CAPTURE)state[j]<=FREE;
    aborted<=aborted+abort_slots;
   end
  end else begin
  rs<={rs[0],capture_request};fs<={fs[0],capture_fatal};geo<={geo[0],geometry_ok};
  if(fs[1])begin fatal<=1;if(!fatal)fault_reason<=1;end
  if(rs[1]!=seen)begin
   seen<=rs[1];grant_toggle<=rs[1];grant_valid<=0;
   if(enabled&&geo[1]&&!fatal&&have_free)begin state[free_slot]<=CAPTURE;grant_slot<=free_slot;grant_valid<=1;end
   else if(enabled&&geo[1])dropped<=dropped+1;
  end
  if(cap_done)begin
   if(state[cap_slot]!=CAPTURE)begin fatal<=1;if(!fatal)fault_reason<=2;end
   else begin state[cap_slot]<=COMPLETE;frame_id[cap_slot]<=captured+1;captured<=captured+1;end
  end
  if(display_edge&&have_complete&&!fatal&&!snapshot_locked&&!(snapshot_request&&display_valid))begin
   if(display_valid)state[display_slot]<=FREE;
   state[complete_slot]<=DISPLAY;display_slot<=complete_slot;display_valid<=1;displayed<=displayed+1;
  end
  end
 end
end
endmodule
