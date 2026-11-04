// Geometry faults are recoverable only after all complete DDR write bursts drain.
// Residual (<16 beat) FIFO data belongs to the incomplete frame and is cancelled.
// No DDR reset or truncation of an accepted native transaction is permitted.
module camera_recovery(input clk,resetn,enabled,fault,
 input [3:0] reason,input [31:0] geometry,pixels,
 input dma_idle,input [9:0] fifo_count,input capture_ready,fifo_ready,
 output capture_hold,manager_hold,
 output reg [31:0] recoveries=0,last_geometry=0,last_pixels=0,
 output reg [3:0] last_reason=0,output [31:0] status);
localparam IDLE=0,DRAIN=1,RESET=2,REARM=3;
reg [1:0] state=IDLE;
(* ASYNC_REG="TRUE" *) reg [1:0] fault_sync=0,ready_sync=0;
reg [4:0] grace=0;reg [3:0] hold_cycles=0;
reg [22:0] wait_cycles=0;reg wait_saturated=0;
assign capture_hold=state==RESET;
assign manager_hold=state==RESET||state==REARM;
assign status={28'b0,wait_saturated,state!=IDLE,state};
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  state<=IDLE;fault_sync<=0;ready_sync<=0;grace<=0;hold_cycles<=0;
  wait_cycles<=0;wait_saturated<=0;recoveries<=0;last_geometry<=0;last_pixels<=0;last_reason<=0;
 end else begin
  fault_sync<={fault_sync[0],fault};ready_sync<={ready_sync[0],capture_ready};
  case(state)
   IDLE:if(enabled&&fault_sync[1]&&(reason==2||reason==3||reason==4))begin
    state<=DRAIN;grace<=0;wait_cycles<=0;wait_saturated<=0;
   end
   DRAIN:begin
    if(grace!=31)grace<=grace+1'b1;
    if(wait_cycles!=23'h7fffff)wait_cycles<=wait_cycles+1'b1;else wait_saturated<=1;
    if(grace>=16&&dma_idle&&fifo_count<16)begin
     last_geometry<=geometry;last_pixels<=pixels;last_reason<=reason;
     state<=RESET;hold_cycles<=0;
    end
   end
   RESET:if(hold_cycles==7)state<=REARM;else hold_cycles<=hold_cycles+1'b1;
   REARM:if(ready_sync[1]&&fifo_ready)begin state<=IDLE;recoveries<=recoveries+1'b1;end
  endcase
 end
end
endmodule
