// KEY0 resets to RAW. KEY1/KEY2 latch their view after debounce.
// The visible mode commits only at a complete HDMI frame boundary.
module camera_view_control #(parameter DEBOUNCE_CYCLES=1250000)(
 input clk,resetn,input [1:0] key_n,input frame_edge,
 output reg [1:0] mode=0,output reg [1:0] requested=0);
(* ASYNC_REG="TRUE" *) reg [1:0] meta=3,sync=3;
reg [1:0] stable=3;reg [20:0] count=0;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin meta<=3;sync<=3;stable<=3;count<=0;requested<=0;mode<=0;end
 else begin
  meta<=key_n;sync<=meta;
  if(sync==stable)count<=0;
  else if(count==DEBOUNCE_CYCLES-1)begin
   stable<=sync;count<=0;
   if(!sync[1])requested<=2;
   else if(!sync[0])requested<=1;
  end else count<=count+1'b1;
  if(frame_edge)mode<=requested;
 end
end
endmodule

// Independent active-low KEY3: a debounced press toggles once; release only rearms.
module camera_denoise_control #(parameter DEBOUNCE_CYCLES=1250000)(
 input clk,resetn,key_n,output reg requested=0);
(* ASYNC_REG="TRUE" *) reg meta=1,sync=1;
reg stable=1;reg [20:0] count=0;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin meta<=1;sync<=1;stable<=1;count<=0;requested<=0;end
 else begin
  meta<=key_n;sync<=meta;
  if(sync==stable)count<=0;
  else if(count==DEBOUNCE_CYCLES-1)begin
   stable<=sync;count<=0;
   if(!sync)requested<=!requested;
  end else count<=count+1'b1;
 end
end
endmodule
