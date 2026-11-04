`timescale 1ns/1ps
module tb_control;
reg clk=0;always #4 clk=~clk;reg rst=0;reg [1:0] keys=3;reg edge_d=0;
wire [1:0] mode,requested;
camera_view_control #(.DEBOUNCE_CYCLES(4)) vc(.clk(clk),.resetn(rst),.key_n(keys),.frame_edge(edge_d),.mode(mode),.requested(requested));
reg lut=0,request=0,capdone=0,recover=0,snapreq=0,snaprel=0,pdone=0,pbusy=0;
reg [1:0] capslot=0;wire gt,gv,dvalid,dcorr,locked,ps,fatal;wire [1:0] gs,ds,ss;wire [31:0] captured,processed,displayed,aborted,sf,sb,db;
camera_corrected_manager fm(.clk(clk),.resetn(rst),.enabled(1'b1),.lut_ready(lut),.correction_enable(1'b1),.capture_request(request),.geometry_ok(1'b1),.capture_fatal(1'b0),.recover(recover),
 .grant_toggle(gt),.grant_valid(gv),.grant_slot(gs),.cap_done(capdone),.cap_slot(capslot),.display_edge(edge_d),.display_valid(dvalid),.display_slot(ds),.display_corrected(dcorr),
 .captured(captured),.processed(processed),.displayed(displayed),.dropped(),.aborted(aborted),.fatal(fatal),.fault_reason(),
 .process_start(ps),.source_base(sb),.result_base(db),.process_busy(pbusy),.process_done(pdone),.process_error(1'b0),.process_cycles(32'd50),.last_cycles(),
 .snapshot_request(snapreq),.snapshot_release(snaprel),.snapshot_locked(locked),.snapshot_slot(ss),.snapshot_frame(sf));
reg [2:0] reqs=0;wire [2:0] ac,valids,dones,takes;wire bulkreq,wr;wire [31:0] addr;wire [15:0] beats;wire [255:0] wd;
reg memactive=0,memdone=0;integer remain=0,owners=0;wire memaccept=bulkreq&&!memactive;
camera_engine_arbiter arb(.clk(clk),.resetn(rst),.requests(reqs),.writes(3'b111),.addresses({32'h300,32'h200,32'h100}),.lengths({16'd3,16'd2,16'd1}),.payloads({256'd33,256'd22,256'd11}),
 .accepts(ac),.valids(valids),.dones(dones),.takes(takes),.req(bulkreq),.write(wr),.addr(addr),.beats(beats),.wdata(wd),.accept(memaccept),.rvalid(memactive),.done(memdone),.take(memactive));
always @(posedge clk)begin
 memdone<=0;
 if(memaccept)begin
  if(ac!==(3'b001<<owners))$fatal(1,"arbiter priority/accept");
  if(addr!=(owners+1)*256||wd!=(owners+1)*11||beats!=owners+1)$fatal(1,"arbiter payload header");
  reqs[owners]<=0;owners<=owners+1;memactive<=1;remain<=5;
 end
 if(memactive)begin
  if(valids!==(3'b001<<arb.owner)||takes!==(3'b001<<arb.owner))$fatal(1,"interleaved DMA route");
  remain<=remain-1;if(remain==1)begin memactive<=0;memdone<=1;end
 end
 if(dvalid&&fm.state[ds]!=5)$fatal(1,"display owns incomplete frame");
 if(ps&&sb-'h01000000!=db-'h04000000)$fatal(1,"raw/corrected pairing");
 if(locked&&fm.state[ss]!=5)$fatal(1,"snapshot frame overwritten");
 if(fatal)$fatal(1,"unexpected manager fault");
end
task frame_edge;begin @(negedge clk);edge_d=1;@(negedge clk);edge_d=0;repeat(3)@(negedge clk);end endtask
task capture_one;begin
 @(negedge clk);request=~request;repeat(6)@(negedge clk);
 if(!gv)$fatal(1,"capture grant missing");capslot=gs;capdone=1;@(negedge clk);capdone=0;repeat(4)@(negedge clk);
end endtask
reg [1:0] original_slot;
initial begin
 repeat(5)@(negedge clk);rst=1;repeat(5)@(negedge clk);
 if(mode!=0)$fatal(1,"not RAW at startup");
 keys=2;repeat(2)@(negedge clk);keys=3;repeat(8)@(negedge clk);if(requested!=0)$fatal(1,"bounce switched view");
 keys=2;repeat(12)@(negedge clk);if(requested!=1||mode!=0)$fatal(1,"KEY1 latch/frame boundary");frame_edge();if(mode!=1)$fatal(1,"KEY1 corrected");
 keys=3;repeat(12)@(negedge clk);frame_edge();if(mode!=1)$fatal(1,"KEY1 did not persist");
 keys=1;repeat(12)@(negedge clk);frame_edge();if(mode!=2)$fatal(1,"KEY2 split");
 rst=0;repeat(4)@(negedge clk);keys=3;rst=1;repeat(6)@(negedge clk);if(mode!=0)$fatal(1,"KEY0 reset mode");
 capture_one();frame_edge();if(!dvalid||dcorr)$fatal(1,"RAW unavailable during LUT init");original_slot=ds;
 snapreq=1;repeat(3)@(negedge clk);snapreq=0;if(!locked||ss!=original_slot||sf!=1)$fatal(1,"snapshot lock");
 keys=2;repeat(12)@(negedge clk);frame_edge();
 if(mode!=1||!locked||ss!=original_slot||sf!=1)$fatal(1,"KEY1 disturbed frozen snapshot");
 keys=3;repeat(12)@(negedge clk);keys=1;repeat(12)@(negedge clk);frame_edge();
 if(mode!=2||!locked||ss!=original_slot||sf!=1)$fatal(1,"KEY2 disturbed frozen snapshot");
 capture_one();lut=1;capture_one();
 if(!fm.running)$fatal(1,"correction not scheduled");pbusy=1;
 frame_edge();if(ds!=original_slot)$fatal(1,"snapshot did not hold frame");
 pbusy=0;pdone=1;@(negedge clk);pdone=0;repeat(3)@(negedge clk);
 if(processed!=1)$fatal(1,"correction completion");
 snaprel=1;@(negedge clk);snaprel=0;frame_edge();frame_edge();frame_edge();if(!dcorr)$fatal(1,"corrected result not displayed");
 request=~request;repeat(6)@(negedge clk);if(!gv)$fatal(1,"recovery capture grant");
 recover=1;request=0;repeat(4)@(negedge clk);recover=0;repeat(5)@(negedge clk);if(aborted!=1)$fatal(1,"capture recovery ownership");
 reqs=7;wait(owners==3);repeat(20)@(negedge clk);
 $display("PASS R16 concurrent snapshot, KEY1 and KEY2 switching; KEY0/KEY1/KEY2 debounce, latch, frame boundary; raw startup, correction pairing, snapshot freeze, recovery; three-way DMA ownership");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
