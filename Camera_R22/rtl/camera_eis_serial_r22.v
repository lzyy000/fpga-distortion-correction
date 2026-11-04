// Independent 8N1 receiver. Divisor is clocks/bit (27MHz/9600=2813).
module dynamic_uart_rx(input clk,resetn,rx,input [31:0] divisor,
 output reg valid=0,error=0,output reg [7:0] data=0);
(* ASYNC_REG="TRUE" *) reg [1:0] sync=3;
reg [31:0] timer=0;reg [3:0] state=0;reg [7:0] shift=0;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin sync<=3;timer<=0;state<=0;valid<=0;error<=0;shift<=0;data<=0;end
 else begin
  sync<={sync[0],rx};valid<=0;error<=0;
  if(state==0)begin if(!sync[1])begin timer<=divisor>>1;state<=1;end end
  else if(timer!=0)timer<=timer-1;
  else if(state==1)begin
   if(sync[1])state<=0;else begin timer<=divisor-1;state<=2;end
  end else if(state<10)begin shift<={sync[1],shift[7:1]};timer<=divisor-1;state<=state+1;end
  else begin state<=0;if(sync[1])begin data<=shift;valid<=1;end else error<=1;end
 end
end
endmodule

// Atomic WIT packets and a separate PC command mailbox, in sys_clk domain.
// PC: FF 45 opcode length seq payload[length] SUM(all preceding bytes)&255.
module camera_eis_serial_r22 #(parameter CLK_HZ=27000000)(
 input clk,resetn,imu_rx,host_rx,input sel,input [8:0] address,
 input [31:0] wdata,input [3:0] wstrb,output reg [31:0] rdata,output reg [31:0] clock_us_gray=0);
reg [31:0] divisor=(CLK_HZ+57600)/115200;
wire iv,ie,hv,he;wire [7:0] ib,hb;
dynamic_uart_rx iu(clk,resetn,imu_rx,divisor,iv,ie,ib);
dynamic_uart_rx hu(clk,resetn,host_rx,32'd234,hv,he,hb);
reg [31:0] good=0,bad=0,age=32'hffffffff,bytes=0,framing=0,qn=0,en=0;
reg [31:0] xy=0,z=0,q01=0,q23=0,gyro_xy=0,gyro_z=0,gn=0;
reg [31:0] quat_age=32'hffffffff,gyro_age=32'hffffffff;
reg [2:0] available=0;
reg [63:0] acc_payload=0;reg [31:0] acc_age=32'hffffffff;
reg [3:0] wi=0;reg [7:0] wt=0,wsum=0;reg [63:0] wp=0;
reg [31:0] tick=0;reg [7:0] gap=0;
reg [2:0] hs=0;reg [7:0] op=0,len=0,seq=0,hi=0,hsum=0;
reg [31:0] staging[0:23],mail[0:23];reg [31:0] hc=0,hbad=0,header=0;
reg [7:0] hgap=0;integer j;
// R27: packet-arrival clock, same reset/epoch as the camera time base.
// FIFO head is immutable until POP. Drop NEW on overflow; never tear a head.
localparam US_DIV=(CLK_HZ/1000000>0)?CLK_HZ/1000000:1;
reg [31:0] us_div=0,clock_us=0;
reg [167:0] gyro_fifo[0:63];reg [5:0] gw=0,gr=0;reg [6:0] gc=0;
reg [31:0] gyro_overflow=0;
wire gyro_push=iv&&wi==10&&ib==wsum&&wt==8'h52;
wire gyro_pop=sel&&address==9'h110&&|wstrb&&wdata[0]&&gc!=0;
wire gyro_clear=sel&&address==9'h110&&|wstrb&&wdata[1];
wire gyro_store=gyro_push&&(gc<64||gyro_pop);
wire [167:0] gyro_head=gyro_fifo[gr];
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin us_div<=0;clock_us<=0;clock_us_gray<=0;gw<=0;gr<=0;gc<=0;gyro_overflow<=0;end
 else begin
  clock_us_gray<=(clock_us>>1)^clock_us;
  if(us_div==US_DIV-1)begin us_div<=0;clock_us<=clock_us+1'b1;end else us_div<=us_div+1'b1;
  if(gyro_store)begin gyro_fifo[gw]<={(acc_age<255?acc_age[7:0]:8'hff),clock_us,acc_payload,wp[63:0]};gw<=gw+1'b1;end
  if(gyro_push&&!gyro_store)gyro_overflow<=gyro_overflow+1'b1;
  if(gyro_pop)gr<=gr+1'b1;
  case({gyro_store,gyro_pop})2'b10:gc<=gc+1'b1;2'b01:gc<=gc-1'b1;endcase
  if(gyro_clear)begin gw<=0;gr<=0;gc<=0;gyro_overflow<=0;end
 end
end
reg [7:0] legacy_fifo[0:15];reg [3:0] lw=0,lr=0;reg [4:0] lc=0;
reg [31:0] legacy_overflow=0;
wire legacy_push=hv&&hs==0&&hb!=8'hff;
wire legacy_pop=sel&&address==9'h134&&|wstrb&&wdata[0]&&lc!=0;
wire legacy_store=legacy_push&&(lc<16||legacy_pop);
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin lw<=0;lr<=0;lc<=0;legacy_overflow<=0;end
 else begin
  if(legacy_store)begin legacy_fifo[lw]<=hb;lw<=lw+1'b1;end
  if(legacy_pop)lr<=lr+1'b1;
  if(legacy_push&&!legacy_store)legacy_overflow<=legacy_overflow+1'b1;
  case({legacy_store,legacy_pop})2'b10:lc<=lc+1'b1;2'b01:lc<=lc-1'b1;endcase
 end
end
always @*begin
 rdata=0;
 case(address)
  9'h130:rdata=lc==0?32'hffffffff:{24'b0,legacy_fifo[lr]};
  9'h134:rdata={27'b0,lc};9'h138:rdata=legacy_overflow;
  9'h000:rdata=good;9'h004:rdata=bad;9'h008:rdata=age;
  9'h00c:rdata=xy;9'h010:rdata=z;9'h014:rdata=q01;9'h018:rdata=q23;
  9'h01c:rdata=qn;9'h020:rdata=en;9'h024:rdata={29'b0,available};9'h028:rdata=framing;
  9'h02c:rdata=bytes;9'h030:rdata=divisor;
  9'h034:rdata=gyro_xy;9'h038:rdata=gyro_z;9'h03c:rdata=gn;
  9'h040:rdata=hc;9'h044:rdata=header;9'h048:rdata=hbad;
  9'h04c:rdata=quat_age;9'h050:rdata=gyro_age;
  9'h100:rdata={25'b0,gc};9'h104:rdata=gyro_head[159:128];
  9'h108:rdata=gyro_head[31:0];9'h10c:rdata=gyro_head[63:32];
  9'h120:rdata=gyro_head[95:64];9'h124:rdata=gyro_head[127:96];9'h128:rdata={24'b0,gyro_head[167:160]};
  9'h114:rdata=gyro_overflow;9'h118:rdata=clock_us;9'h11c:rdata=32'h52463237;
  default:if(address>=9'h080&&address<9'h0e0)rdata=mail[address[6:2]];
 endcase
end
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  divisor<=(CLK_HZ+57600)/115200;good<=0;bad<=0;age<=32'hffffffff;bytes<=0;framing<=0;qn<=0;en<=0;
  xy<=0;z<=0;q01<=0;q23<=0;gyro_xy<=0;gyro_z<=0;gn<=0;
  quat_age<=32'hffffffff;gyro_age<=32'hffffffff;
  acc_payload<=0;acc_age<=32'hffffffff;available<=0;wi<=0;wt<=0;wsum<=0;wp<=0;tick<=0;gap<=0;
  hs<=0;op<=0;len<=0;seq<=0;hi<=0;hsum<=0;hc<=0;hbad<=0;header<=0;hgap<=0;
  for(j=0;j<24;j=j+1)begin staging[j]<=0;mail[j]<=0;end
 end else begin
  if(sel&&address==9'h030&&|wstrb&&wdata>=32&&wdata<=100000)divisor<=wdata;
  if(ie)begin framing<=framing+1;wi<=0;end
  if(he)begin hbad<=hbad+1;hs<=0;end
  if(tick==CLK_HZ/1000-1)begin
   tick<=0;if(age!=32'hffffffff)age<=age+1;
   if(quat_age!=32'hffffffff)quat_age<=quat_age+1;
   if(gyro_age!=32'hffffffff)gyro_age<=gyro_age+1;
   if(acc_age!=32'hffffffff)acc_age<=acc_age+1;
   if(gap<255)gap<=gap+1;if(hgap<255)hgap<=hgap+1;
   if(gap>=20)wi<=0;if(hgap>=100)hs<=0;
  end else tick<=tick+1;
  if(iv)begin
   gap<=0;bytes<=bytes+1;
   if(wi==0)begin if(ib==8'h55)begin wi<=1;wsum<=ib;end end
   else if(wi==1)begin
    if(ib>=8'h50&&ib<=8'h5f)begin wt<=ib;wsum<=wsum+ib;wi<=2;end
    else begin wi<=ib==8'h55 ? 1 : 0;wsum<=ib;bad<=bad+1;end
   end else if(wi<10)begin wp[(wi-2)*8+:8]<=ib;wsum<=wsum+ib;wi<=wi+1;end
   else begin
    wi<=0;
    if(ib==wsum)begin
     good<=good+1;
     if(wt==8'h51)begin acc_payload<=wp;acc_age<=0;end
     if(wt==8'h53)begin xy<=wp[31:0];z<={16'b0,wp[47:32]};en<=en+1;available[0]<=1;age<=0;end
     if(wt==8'h59)begin q01<=wp[31:0];q23<=wp[63:32];qn<=qn+1;available[1]<=1;age<=0;quat_age<=0;end
     if(wt==8'h52)begin gyro_xy<=wp[31:0];gyro_z<={16'b0,wp[47:32]};gn<=gn+1;available[2]<=1;gyro_age<=0;end
    end else begin bad<=bad+1;if(ib==8'h55)begin wi<=1;wsum<=ib;end end
   end
  end
  if(hv)begin
   hgap<=0;
   case(hs)
    0:if(hb==8'hff)begin hs<=1;hsum<=hb;end
    1:if(hb==8'h45)begin hs<=2;hsum<=hsum+hb;end else begin hs<=hb==8'hff ? 1 : 0;hsum<=hb;end
    2:begin op<=hb;hsum<=hsum+hb;hs<=3;end
    3:begin len<=hb;hsum<=hsum+hb;if(hb<=96)hs<=4;else begin hs<=0;hbad<=hbad+1;end end
    4:begin seq<=hb;hsum<=hsum+hb;hi<=0;hs<=len==0?6:5;end
    5:begin staging[hi[6:2]][hi[1:0]*8+:8]<=hb;hsum<=hsum+hb;hi<=hi+1;if(hi+1==len)hs<=6;end
    6:begin hs<=0;if(hb==hsum)begin
     hc<=hc+1;header<={8'b0,seq,len,op};for(j=0;j<24;j=j+1)mail[j]<=staging[j];
    end else hbad<=hbad+1;end
    default:hs<=0;
   endcase
  end
 end
end
endmodule
