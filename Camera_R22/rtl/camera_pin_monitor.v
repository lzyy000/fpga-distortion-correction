// Independent reference-clock measurement of raw HREF/VS pins.
// These diagnostic counters do not use PCLK or the capture sampler.
module camera_pin_monitor(
 input clk,resetn,href,vs,
 output reg [15:0] last_high=0,last_period=0,href_edges=0,vs_edges=0,
 output reg high_valid=0,period_valid=0);
(* ASYNC_REG="TRUE" *) reg href_meta=0,vs_meta=0;
(* ASYNC_REG="TRUE" *) reg href_sync=0,vs_sync=0;
reg href_d=0,vs_d=0,seen_href=0;
reg [15:0] high_count=0,period_count=0;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  href_meta<=0;vs_meta<=0;href_sync<=0;vs_sync<=0;href_d<=0;vs_d<=0;
  seen_href<=0;high_count<=0;period_count<=0;
  last_high<=0;last_period<=0;href_edges<=0;vs_edges<=0;high_valid<=0;period_valid<=0;
 end else begin
  href_meta<=href;vs_meta<=vs;href_sync<=href_meta;vs_sync<=vs_meta;
  href_d<=href_sync;vs_d<=vs_sync;
  if(vs_sync&&!vs_d)vs_edges<=vs_edges+1'b1;
  if(period_count!=16'hffff)period_count<=period_count+1'b1;
  if(href_sync&&!href_d)begin
   href_edges<=href_edges+1'b1;
   if(seen_href)begin
    last_period<=(period_count==16'hffff) ? 16'hffff : period_count+1'b1;
    period_valid<=1;
   end
   seen_href<=1;period_count<=0;
  end
  if(href_sync)begin if(high_count!=16'hffff)high_count<=high_count+1'b1;end
  else begin
   if(href_d)begin last_high<=high_count;high_valid<=1;end
   high_count<=0;
  end
 end
end
endmodule
