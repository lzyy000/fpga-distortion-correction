module camera_eis_jobs_r22 #(parameter FISHEYE_ENABLE=0,ROTATION_ENABLE=0)(input clk,resetn,grant,input [1:0] grant_slot,input [3:0] slot_eis,slot_lens,slot_fisheye,
 input sof,input [1:0] sof_slot,input [31:0] sof_us,readout_us,input cap_done,input [1:0] cap_slot,input recover,
 input cpu_sel,input [7:0] cpu_addr,input [31:0] cpu_data,input [3:0] cpu_strb,output reg [31:0] cpu_result,
 input [1:0] process_slot,input process_done,input [31:0] processed,displayed,cycles,fallbacks,rs_fallbacks,
 output reg [3:0] ready=0,output [895:0] process_config,input [3:0] slot_rotation);
reg [31:0] token[0:3],stamp[0:3],span[0:3];reg [3:0] pending=0,started=0,capturing=0;
reg [29:0] serial=0;reg [31:0] commit_token=0,stale=0,version=0,status=0;
reg [895:0] shadow=0,bank[0:3];reg [31:0] job,job_us;integer i,j;
wire [1:0] cs=commit_token[1:0];
wire commit=cpu_sel&&|cpu_strb&&cpu_addr==8'h80;
wire accepted=commit&&pending[cs]&&token[cs]==commit_token;
assign process_config=bank[process_slot];
always @*begin
 job=0;job_us=0;
 for(j=0;j<4;j=j+1)if(pending[j]&&(job==0||$signed(stamp[j]-job_us)<0))begin job=token[j];job_us=stamp[j];end
 cpu_result=0;
 if(cpu_addr<8'h70)cpu_result=shadow[cpu_addr[6:2]*32+:32];
 else case(cpu_addr)
  8'h80:cpu_result=version;8'h90:cpu_result=processed;8'h94:cpu_result=displayed;8'h98:cpu_result=cycles;
  8'h9c:cpu_result=version;8'ha0:cpu_result=status;8'ha4:cpu_result=fallbacks;
  8'hb0:cpu_result=job;8'hb4:cpu_result=job_us;8'hb8:cpu_result=commit_token;
  8'hbc:cpu_result={24'b0,ready,pending};8'hc0:cpu_result=stale;8'hc4:cpu_result=span[job[1:0]];
  8'hc8:cpu_result=rs_fallbacks;8'hd0:cpu_result=(ROTATION_ENABLE?{28'b0,slot_rotation[job[1:0]],3'b0}:32'b0) | (FISHEYE_ENABLE?{29'b0,slot_eis[job[1:0]],slot_fisheye[job[1:0]],slot_lens[job[1:0]]}:{31'b0,slot_lens[job[1:0]]});
 endcase
end
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  ready<=0;pending<=0;started<=0;capturing<=0;serial<=0;commit_token<=0;stale<=0;version<=0;status<=0;shadow<=0;
  for(i=0;i<4;i=i+1)begin token[i]<=0;stamp[i]<=0;span[i]<=0;bank[i]<=0;end
 end else begin
  if(recover)begin started<=started&~capturing;capturing<=0;end
  if(grant&&!recover)begin
   serial<=serial==30'h3fffffff ? 30'd1:serial+1'b1;
   token[grant_slot]<={(serial==30'h3fffffff ? 30'd1:serial+30'd1),grant_slot};
   ready[grant_slot]<=0;pending[grant_slot]<=0;started[grant_slot]<=0;capturing[grant_slot]<=1;
  end
  if(sof&&!recover&&capturing[sof_slot])begin stamp[sof_slot]<=sof_us;started[sof_slot]<=1;end
  if(cap_done&&started[cap_slot]&&!recover)begin
   pending[cap_slot]<=(ROTATION_ENABLE&&slot_rotation[cap_slot])||slot_eis[cap_slot]||(FISHEYE_ENABLE&&slot_fisheye[cap_slot]);span[cap_slot]<=readout_us;capturing[cap_slot]<=0;
  end
  if(cpu_sel&&|cpu_strb)begin
   if(cpu_addr<8'h70)shadow[cpu_addr[6:2]*32+:32]<=cpu_data;
   if(cpu_addr==8'hb8)commit_token<=cpu_data;
   if(cpu_addr==8'ha0)status<=cpu_data;
   if(commit)begin
    if(accepted)begin bank[cs]<=shadow;ready[cs]<=1;pending[cs]<=0;version<=cpu_data;end
    else stale<=stale+1'b1;
   end
  end
 end
end
endmodule
