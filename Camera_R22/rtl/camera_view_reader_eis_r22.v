// mode[0] selects correction; mode[1] selects two 960x540 previews.
// The left preview always reads the pristine source frame.
module camera_view_reader_eis_r22(input clk,resetn,line_req,input [11:0] line_index,
 input [1:0] mode,input display_valid,display_corrected,input [1:0] display_slot,
 output reg line_done=0,line_valid=0,output reg [255:0] line_data=0,
 output req,output [31:0] addr,output [15:0] beats,input accept,valid,done,input [255:0] data,
 output reg overrun=0);
localparam IDLE=0,BLACK=1,FULL_CMD=2,FULL_DATA=3,LEFT_CMD=4,LEFT_DATA=5,RIGHT_CMD=6,RIGHT_DATA=7;
reg [2:0] st=0;reg [31:0] raw=0,res=0,full=0;reg [7:0] count=0;
reg half=0;reg [127:0] lower=0;reg [127:0] sampled;
wire [1:0] effective={mode[1],display_corrected};
wire [31:0] raw_slot=32'h06000000+({30'b0,display_slot}<<22);
wire [31:0] processed_slot=32'h01000000+({30'b0,display_slot}<<22);
wire [31:0] corrected_slot=32'h04000000+({30'b0,display_slot}<<22);
integer j;
always @*begin sampled=0;for(j=0;j<8;j=j+1)sampled[j*16+:16]=data[j*32+:16];end
assign req=st==FULL_CMD||st==LEFT_CMD||st==RIGHT_CMD;
assign addr=st==FULL_CMD?full:st==LEFT_CMD?raw:res;assign beats=120;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin st<=IDLE;line_done<=0;line_valid<=0;line_data<=0;overrun<=0;count<=0;half<=0;end
 else begin
  line_done<=0;line_valid<=0;
  if(line_req)begin
   if(st!=IDLE)overrun<=1;
   else if(!display_valid||(effective[1]&&(line_index<270||line_index>=810)))begin st<=BLACK;count<=0;end
   else if(effective[1])begin
    raw<=raw_slot+(line_index-270)*7680;
    res<=(effective[0]?corrected_slot:processed_slot)+(line_index-270)*7680;
    st<=LEFT_CMD;half<=0;
   end else begin full<=(effective[0]?corrected_slot:processed_slot)+line_index*3840;st<=FULL_CMD;end
  end
  case(st)
   BLACK:begin line_data<=0;line_valid<=1;count<=count+1;if(count==119)begin line_done<=1;st<=IDLE;end end
   FULL_CMD:if(accept)st<=FULL_DATA;
   LEFT_CMD:if(accept)st<=LEFT_DATA;
   RIGHT_CMD:if(accept)st<=RIGHT_DATA;
   FULL_DATA:begin if(valid)begin line_data<=data;line_valid<=1;end if(done)begin line_done<=1;st<=IDLE;end end
   LEFT_DATA,RIGHT_DATA:begin
    if(valid)begin half<=~half;if(!half)lower<=sampled;else begin line_data<={sampled,lower};line_valid<=1;end end
    if(done)begin if(st==LEFT_DATA)st<=RIGHT_CMD;else begin line_done<=1;st<=IDLE;end end
   end
  endcase
 end
end
endmodule
