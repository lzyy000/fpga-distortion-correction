// Recover byte pairing from either stable RGMII half-cycle phase.
// Keep both candidates for nine clocks so the SFD decision precedes the first
// preamble byte presented to MAC. PLL settings and IODELAY remain unchanged.
module camera_rgmii_rx_align #(parameter PIPE=9)(
 input clk,resetn,input raw_valid,raw_error,input [7:0] raw_data,
 output valid,output error,output [7:0] data,
 output reg header_seen=0,output reg half_cycle=0);
reg [7:0] last_data=0;
reg last_ctl1=0,any_prev=0,selected=0;
reg [3:0] direct_pre=0,half_pre=0,age=0;
wire ctl1=raw_valid^raw_error;
wire [7:0] half_data={raw_data[3:0],last_data[7:4]};
wire half_valid=last_ctl1;
wire half_error=raw_valid^last_ctl1;
wire any_valid=raw_valid|half_valid;
reg [7:0] direct_pipe[0:PIPE-1],half_pipe[0:PIPE-1];
reg [PIPE-1:0] direct_valid=0,half_valid_pipe=0,direct_error=0,half_error_pipe=0;
integer i;
assign valid=selected&&(half_cycle?half_valid_pipe[PIPE-1]:direct_valid[PIPE-1]);
assign error=half_cycle?half_error_pipe[PIPE-1]:direct_error[PIPE-1];
assign data=half_cycle?half_pipe[PIPE-1]:direct_pipe[PIPE-1];
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  last_data<=0;last_ctl1<=0;any_prev<=0;selected<=0;header_seen<=0;half_cycle<=0;direct_pre<=0;half_pre<=0;age<=0;
  direct_valid<=0;half_valid_pipe<=0;direct_error<=0;half_error_pipe<=0;
  for(i=0;i<PIPE;i=i+1)begin direct_pipe[i]<=0;half_pipe[i]<=0;end
 end else begin
  last_data<=raw_data;last_ctl1<=ctl1;any_prev<=any_valid;
  direct_pipe[0]<=raw_data;half_pipe[0]<=half_data;
  for(i=1;i<PIPE;i=i+1)begin direct_pipe[i]<=direct_pipe[i-1];half_pipe[i]<=half_pipe[i-1];end
  direct_valid<={direct_valid[PIPE-2:0],raw_valid};half_valid_pipe<={half_valid_pipe[PIPE-2:0],half_valid};
  direct_error<={direct_error[PIPE-2:0],raw_error};half_error_pipe<={half_error_pipe[PIPE-2:0],half_error};
  if(any_valid&&!any_prev)begin
   selected<=0;age<=0;
   direct_pre<=(raw_valid&&!raw_error&&raw_data==8'h55)?1:0;
   half_pre<=(half_valid&&!half_error&&half_data==8'h55)?1:0;
  end else begin
   if(any_valid&&age<15)age<=age+1'b1;
   if(!selected&&age<9)begin
   if(raw_valid&&!raw_error&&raw_data==8'h55)begin if(direct_pre<7)direct_pre<=direct_pre+1'b1;end else direct_pre<=0;
   if(half_valid&&!half_error&&half_data==8'h55)begin if(half_pre<7)half_pre<=half_pre+1'b1;end else half_pre<=0;
   if(raw_valid&&!raw_error&&raw_data==8'hd5&&direct_pre==7)begin selected<=1;header_seen<=1;half_cycle<=0;end
   else if(half_valid&&!half_error&&half_data==8'hd5&&half_pre==7)begin selected<=1;header_seen<=1;half_cycle<=1;end
   end
  end
 end
end
endmodule
