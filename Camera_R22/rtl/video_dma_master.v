// Serialized native DDR transactions, arbitrated at <=16-beat boundaries.
// Every write source holds a complete packet before AW. This controller's
// native interface has no WVALID and no read back-pressure.
module video_dma_master(input clk,resetn,
 input cpu_req,input [31:0] cpu_addr,cpu_data,input [3:0] cpu_strb,
 output cpu_ready,output reg [31:0] cpu_result,
 input eng_req,eng_write,input [31:0] eng_addr,input [15:0] eng_beats,
 output eng_accept,output eng_done,eng_valid,output [255:0] eng_rdata,
 input [255:0] eng_wdata,output eng_take,
 input disp_req,input [31:0] disp_addr,input [15:0] disp_beats,
 output disp_accept,disp_done,disp_valid,output [255:0] disp_data,
 input [290:0] cap_head,input [9:0] cap_count,output cap_pop,
 output cap_done,output [1:0] cap_slot,
 output reg [27:0] awaddr,araddr,output [3:0] awid,arid,
 output reg [3:0] awlen,arlen,output awvalid,arvalid,input awready,arready,
 output [255:0] wdata,output [31:0] wstrb,input wready,
 input [255:0] rdata,input rvalid,rlast);
localparam IDLE=0,RA=1,RD=2,WA=3,WD=4,RESP=5;
reg [2:0] st=0;reg [1:0] owner;
reg ep=0,dp=0,ew;reg [31:0] ea,da;reg [15:0] en,dn;
reg [4:0] left;reg [2:0] lane;reg [255:0] cdata;reg [31:0] cmask;
assign eng_accept=eng_req&&!ep;
assign disp_accept=disp_req&&!dp;
assign awvalid=st==WA;assign arvalid=st==RA;assign awid=owner;assign arid=owner;
assign wdata=owner==1?eng_wdata:owner==2?cap_head[255:0]:cdata;
assign wstrb=owner==3?cmask:32'hffffffff;
assign eng_rdata=rdata;assign disp_data=rdata;
assign eng_valid=st==RD&&owner==1&&rvalid;
assign disp_valid=st==RD&&owner==0&&rvalid;
assign eng_take=st==WD&&owner==1&&wready;
assign cap_pop=st==WD&&owner==2&&wready;
assign cap_done=cap_pop&&cap_head[290];assign cap_slot=cap_head[289:288];
assign eng_done=(owner==1)&&((st==RD&&rvalid&&rlast)||(st==WD&&wready&&left==1))&&en<=16;
assign disp_done=owner==0&&st==RD&&rvalid&&rlast&&dn<=16;
assign cpu_ready=st==RESP;
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin st<=IDLE;ep<=0;dp<=0;awaddr<=0;araddr<=0;awlen<=0;arlen<=0;cpu_result<=0;end
 else begin
  if(eng_accept)begin ep<=1;ea<=eng_addr;en<=eng_beats;ew<=eng_write;end
  if(disp_accept)begin dp<=1;da<=disp_addr;dn<=disp_beats;end
  case(st)
   IDLE:if(dp)begin owner<=0;araddr<=da>>2;arlen<=dn>16?15:dn-1;st<=RA;end
    else if(cap_count>=16)begin owner<=2;awaddr<=cap_head[287:256]>>2;awlen<=15;left<=16;st<=WA;end
    else if(ep)begin
     owner<=1;left<=en>16?16:en;
     if(ew)begin awaddr<=ea>>2;awlen<=en>16?15:en-1;st<=WA;end
     else begin araddr<=ea>>2;arlen<=en>16?15:en-1;st<=RA;end
    end else if(cpu_req)begin
     owner<=3;lane<=cpu_addr[4:2];left<=1;
     if(|cpu_strb)begin
      awaddr<={3'b0,cpu_addr[28:5],3'b0};awlen<=0;
      cdata<={224'b0,cpu_data}<<(cpu_addr[4:2]*32);cmask<={28'b0,cpu_strb}<<(cpu_addr[4:2]*4);st<=WA;
     end else begin araddr<={3'b0,cpu_addr[28:5],3'b0};arlen<=0;st<=RA;end
    end
   RA:if(arready)st<=RD;
   RD:if(rvalid)begin
    if(owner==3)cpu_result<=rdata>>(lane*32);
    if(rlast)begin
     if(owner==0)begin if(dn<=16)dp<=0;else begin dn<=dn-16;da<=da+512;end end
     if(owner==1)begin if(en<=16)ep<=0;else begin en<=en-16;ea<=ea+512;end end
     st<=owner==3?RESP:IDLE;
    end
   end
   WA:if(awready)st<=WD;
   WD:if(wready)begin
    left<=left-1;
    if(left==1)begin
     if(owner==1)begin if(en<=16)ep<=0;else begin en<=en-16;ea<=ea+512;end end
     st<=owner==3?RESP:IDLE;
    end
   end
   RESP:st<=IDLE;
  endcase
 end
end
endmodule
