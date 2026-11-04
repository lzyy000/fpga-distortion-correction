`ifndef CAMERA_MODE_KEYS_VH
`define CAMERA_MODE_KEYS_VH
// Four physical keys, one pulse per gesture. No image/parameter datapath.
module camera_mode_keys #(
 parameter MS_CYCLES=125000, DEBOUNCE_MS=20, LONG_MS=800
)(input clk,resetn,input [3:0] key_n,output reg [7:0] toggle=0);
 localparam DIV_BITS=(MS_CYCLES>1)?$clog2(MS_CYCLES):1;
 localparam DB_BITS=(DEBOUNCE_MS>1)?$clog2(DEBOUNCE_MS+1):1;
 localparam HOLD_BITS=(LONG_MS>1)?$clog2(LONG_MS):1;
 (* ASYNC_REG="TRUE" *) reg [3:0] meta=15,sync=15;
 reg [DIV_BITS-1:0] divider=0;
 reg [3:0] sample=15,stable=15,qualified=0,armed=0,pressed=0,sent=0;
 reg [DB_BITS-1:0] debounce[0:3];
 reg [HOLD_BITS-1:0] held[0:3];
 integer i;
 function integer short_bit(input integer key_index);
  case(key_index)0:short_bit=0;1:short_bit=3;2:short_bit=7;default:short_bit=2;endcase
 endfunction
 function integer long_bit(input integer key_index);
  case(key_index)0:long_bit=6;1:long_bit=4;2:long_bit=5;default:long_bit=1;endcase
 endfunction
 always @(posedge clk or negedge resetn)begin
  if(!resetn)begin
   meta<=15;sync<=15;divider<=0;sample<=15;stable<=15;
   qualified<=0;armed<=0;pressed<=0;sent<=0;toggle<=0;
   for(i=0;i<4;i=i+1)begin debounce[i]<=0;held[i]<=0;end
  end else begin
   meta<=key_n;sync<=meta;toggle<=0;
   if(divider==MS_CYCLES-1)begin
    divider<=0;
    for(i=0;i<4;i=i+1)begin
     if(sync[i]!=sample[i])begin sample[i]<=sync[i];debounce[i]<=0;end
     else if(debounce[i]<DEBOUNCE_MS)begin
      debounce[i]<=debounce[i]+1'b1;
      if(debounce[i]==DEBOUNCE_MS-1)begin stable[i]<=sample[i];qualified[i]<=1;end
     end
     if(qualified[i])begin
      if(stable[i])begin
       if(pressed[i]&&!sent[i])toggle[short_bit(i)]<=1;
       pressed[i]<=0;sent[i]<=0;held[i]<=0;armed[i]<=1;
      end else if(armed[i])begin
       if(!pressed[i])begin pressed[i]<=1;held[i]<=0;end
       else if(!sent[i])begin
        if(held[i]==LONG_MS-1)begin toggle[long_bit(i)]<=1;sent[i]<=1;end
        else held[i]<=held[i]+1'b1;
       end
      end
     end
    end
   end else divider<=divider+1'b1;
  end
 end
endmodule
`endif
