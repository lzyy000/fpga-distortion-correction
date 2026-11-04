// Full-size 1920x1080 RGB565 raw display; each DDR row is 120 beats.
module camera_line_reader #(parameter W=1920)(
 input clk,resetn,line_req,input [11:0] line_index,input display_valid,input [1:0] display_slot,
 output reg line_done=0,line_valid=0,output reg [255:0] line_data=0,
 output req,output [31:0] addr,output [15:0] beats,input accept,valid,done,input [255:0] data,
 output reg overrun=0);
localparam IDLE=0,BLACK=1,CMD=2,DATA=3;
reg [1:0] st=0;reg [15:0] count=0;reg [31:0] base=0;
assign req=st==CMD;assign addr=base;assign beats=W/16;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin st<=IDLE;line_done<=0;line_valid<=0;line_data<=0;count<=0;overrun<=0;end
 else begin
  line_done<=0;line_valid<=0;
  if(line_req)begin
   if(st!=IDLE)overrun<=1;
   else if(!display_valid)begin st<=BLACK;count<=0;end
   else begin base<=32'h01000000+({30'b0,display_slot}<<22)+line_index*(W*2);st<=CMD;end
  end
  case(st)
   BLACK:begin line_data<=0;line_valid<=1;count<=count+1;if(count==W/16-1)begin st<=IDLE;line_done<=1;end end
   CMD:if(accept)st<=DATA;
   DATA:begin if(valid)begin line_valid<=1;line_data<=data;end if(done)begin line_done<=1;st<=IDLE;end end
  endcase
 end
end
endmodule
