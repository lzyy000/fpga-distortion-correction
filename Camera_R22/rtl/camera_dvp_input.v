// R4 keep-wire: sample all ten inputs together on falling IO PCLK.
// The top delays both clock branches by the same static Gray70 primitive.
// Rising regional bridge + rising regional output retain full bus alignment.
module camera_dvp_input(input io_clk,clk,input [9:0] pins,output reg [9:0] data=0);
reg [9:0] sampled=0,half_stage=0;
always @(negedge io_clk)sampled<=pins;
always @(posedge clk)half_stage<=sampled;
always @(posedge clk)data<=half_stage;
endmodule
