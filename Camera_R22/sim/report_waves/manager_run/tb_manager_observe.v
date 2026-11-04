`timescale 1ns/1ps
module tb_manager;
reg clk=0;always #4 clk=~clk;reg resetn=0,enable=0,request=0,cap_done=0,edge_in=0,pdone=0,pbusy=0,sreq=0,srel=0;
reg eis=0;reg [3:0] ready=0;wire pe;wire [1:0] pslt;wire [3:0] ef,lf;wire de;
reg [1:0] cap_slot=0;wire gt,gv,ps,dvalid,corrected,locked,fatal;wire [1:0] gs,ds,ss;
wire [31:0] captured,processed,displayed;integer starts=0,i;reg [1:0] pending_slot;
camera_eis_manager_r22 dut(.clk(clk),.resetn(resetn),.enabled(1'b1),.lut_ready(1'b1),.correction_enable(enable),.eis_enable(eis),.fisheye_enable(1'b0),.display_fisheye(),.slot_fisheye(),.rotation_enable(1'b0),.slot_rotation(),.display_rotation(),.config_ready(ready),.process_eis(pe),.process_slot(pslt),.slot_eis(ef),.slot_lens(lf),.display_eis(de),.capture_request(request),.geometry_ok(1'b1),.capture_fatal(1'b0),.recover(1'b0),.grant_toggle(gt),.grant_valid(gv),.grant_slot(gs),.cap_done(cap_done),.cap_slot(cap_slot),.display_edge(edge_in),.display_valid(dvalid),.display_slot(ds),.display_corrected(corrected),.captured(captured),.processed(processed),.displayed(displayed),.dropped(),.aborted(),.fatal(fatal),.fault_reason(),.process_start(ps),.source_base(),.result_base(),.process_busy(pbusy),.process_done(pdone),.process_error(1'b0),.process_cycles(32'd99),.last_cycles(),.snapshot_request(sreq),.snapshot_release(srel),.snapshot_locked(locked),.snapshot_slot(ss),.snapshot_frame());
always @(posedge clk)if(resetn)begin if(ps)starts<=starts+1;if(fatal)$fatal(1,"frame ownership fault");end
task capture;begin
 @(negedge clk);request=~request;repeat(6)@(negedge clk);if(!gv)$fatal(1,"missing capture slot");
 cap_slot=gs;cap_done=1;@(negedge clk);cap_done=0;repeat(4)@(negedge clk);
end endtask
task display_edge;begin @(negedge clk);edge_in=1;@(negedge clk);edge_in=0;repeat(3)@(negedge clk);end endtask
task finish;begin @(negedge clk);pbusy=0;pdone=1;@(negedge clk);pdone=0;repeat(3)@(negedge clk);end endtask
initial begin
 repeat(5)@(negedge clk);resetn=1;repeat(5)@(negedge clk);
 for(i=0;i<12;i=i+1)begin capture();display_edge();display_edge();end
 if(starts!=0||processed!=0||captured!=12||displayed!=12||corrected)$fatal(1,"OFF mode wasted remap or dropped frames");
 enable=1;capture();if(!dut.running||starts!=1)$fatal(1,"ON mode did not schedule correction");pbusy=1;
 capture();pending_slot=cap_slot;enable=0;repeat(4)@(negedge clk);
 if(dut.state[pending_slot]!=2||starts!=1)$fatal(1,"accepted frame lost its captured lens mode");
 finish();pbusy=1;repeat(3)@(negedge clk);if(starts!=2)$fatal(1,"queued static frame lost");finish();display_edge();display_edge();display_edge();display_edge();
 sreq=1;repeat(4)@(negedge clk);sreq=0;if(!locked||ss!=ds)$fatal(1,"snapshot lock");
 capture();display_edge();display_edge();if(ss!=ds)$fatal(1,"frozen display overwritten");
 srel=1;@(negedge clk);srel=0;display_edge();display_edge();
 if(locked||starts!=2||processed!=2)$fatal(1,"mode toggle cancelled accepted remap or leaked work");
 enable=1;capture();pbusy=1;finish();display_edge();display_edge();
 if(!corrected||starts!=3||processed!=3)$fatal(1,"correction did not resume");
 eis=1;enable=0;ready=0;capture();pending_slot=cap_slot;
 if(dut.running||starts!=3||!ef[pending_slot]||lf[pending_slot])$fatal(1,"EIS frame must await exact coefficients");
 eis=0;ready[pending_slot]=1;repeat(4)@(negedge clk);if(!pe||pslt!=pending_slot||starts!=4)$fatal(1,"EIS metadata lost on OFF");
 pbusy=1;finish();display_edge();display_edge();if(!de||!corrected)$fatal(1,"EIS display identity missing");
 capture();display_edge();display_edge();if(de||corrected||starts!=4)$fatal(1,"OFF did not restore bypass");
 $display("PASS R22 frame scheduling: 12 bypass frames, ON/OFF during active and queued remap, snapshot lock/release, correction resumes");$finish;
end
initial begin #100000;$fatal(1,"schedule timeout");end
wire [2:0] trace_state0=dut.state[0];
endmodule
