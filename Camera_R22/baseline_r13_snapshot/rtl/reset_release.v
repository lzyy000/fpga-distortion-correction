module reset_release(input clk,input arstn,output resetn);
reg [2:0] sync=0;
always @(posedge clk or negedge arstn)
 if(!arstn) sync<=0; else sync<={sync[1:0],1'b1};
assign resetn=sync[2];
endmodule
