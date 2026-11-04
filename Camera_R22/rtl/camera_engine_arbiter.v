// Own the entire accepted bulk transaction, including every 16-beat subburst.
// Priority: snapshot, initialization, correction; no interleaved payloads.
module camera_engine_arbiter(input clk,resetn,
 input [2:0] requests,writes,input [95:0] addresses,input [47:0] lengths,
 input [767:0] payloads,output [2:0] accepts,valids,dones,takes,
 output req,write,output [31:0] addr,output [15:0] beats,output [255:0] wdata,
 input accept,rvalid,done,take);
reg active=0;reg [1:0] owner=0;reg [1:0] selected;
always @*begin
 selected=owner;
 if(!active)begin if(requests[0])selected=0;else if(requests[1])selected=1;else selected=2;end
end
assign req=!active&&requests[selected];assign write=writes[selected];
assign addr=addresses[selected*32+:32];assign beats=lengths[selected*16+:16];assign wdata=payloads[selected*256+:256];
assign accepts=(req&&accept)?(3'b001<<selected):3'b0;
assign valids=(active&&rvalid)?(3'b001<<owner):3'b0;
assign dones=(active&&done)?(3'b001<<owner):3'b0;
assign takes=(active&&take)?(3'b001<<owner):3'b0;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin active<=0;owner<=0;end
 else begin
  if(req&&accept)begin active<=1;owner<=selected;end
  if(active&&done)active<=0;
 end
end
endmodule
