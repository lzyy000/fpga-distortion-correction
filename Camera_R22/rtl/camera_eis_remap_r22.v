// Native-resolution samples; 64-pixel geometry mesh, four-bank bilinear cache.
module camera_eis_remap_r22 #(parameter W=1920,H=1080,FISHEYE_ENABLE=0,GW=(W+63)/64+1,GH=(H+63)/64+1)(
 input clk,resetn,start,input [31:0] source_base,result_base,input [895:0] config_words,
 input [3:0] night_curve,input [8:0] night_strength,
 output reg busy=0,source_done=0,output reg display_valid=0,display_bank=0,
 output reg [31:0] completed=0,displayed=0,last_cycles=0,
 output req,write,output [31:0] addr,output [15:0] beats,
 input accept,done,valid,input [255:0] rdata,output [255:0] wdata,input take,
 output reg [31:0] fallbacks=0,rs_fallbacks=0,output reg display_limited=0,display_compare=0);
 localparam IDLE=0,MAP_START=1,MAP_WAIT=2,CELL_READ=3,CELL_WAIT=4,CELL_EDGE=5,CELL_INIT=6,RENDER=7,DRAIN=8,ROW_WAIT=9,FINISH=10,COMMIT=11,CELL_PRODUCT=12,CELL_SUM=13,BLACK_ROW=14,RAW_CMD=15,RAW_DATA=16;
 reg [4:0] st=0;reg [895:0] cfg;reg [575:0] map_cfg;
 reg [31:0] src_base,dst_base,cycles=0;reg out_bank;
 // Selection is immutable while rendering; its display identity commits with
 // the output bank, including requests received while waiting for VS.
 wire frame_compare=0;wire compare_requested=0;wire frame_edge=1;
 reg [5:0] gx=0,gy=0,cx=0;reg [11:0] ox=0,oy=0;
 reg mesh_bad=0,used_fallback=0,rs_retry=0;
 wire md,mi,ray_ok;wire signed [31:0] mx,my;
 reg cache_vertical=0,cache_shallow=0;reg signed [31:0] first_mx,first_my;
 wire signed [32:0] mesh_dx=$signed({mx[31],mx})-$signed({first_mx[31],first_mx});
 wire signed [32:0] mesh_dy=$signed({my[31],my})-$signed({first_my[31],first_my});
 wire [32:0] mesh_adx=mesh_dx<0?-mesh_dx:mesh_dx,mesh_ady=mesh_dy<0?-mesh_dy:mesh_dy;
 wire [11:0] mu=gx*64,mv=gy*64;
 wire [31:0] row_cfg=(used_fallback||rs_retry)?0:cfg[895:864];
 dynamic_map #(.W(W),.H(H),.FISHEYE_ENABLE(FISHEYE_ENABLE)) mapper(clk,resetn,st==MAP_START,mu,mv,{row_cfg,map_cfg},md,mi,mx,my,ray_ok);
 reg [64:0] m00[0:GW*GH-1],m10[0:GW*GH-1],m01[0:GW*GH-1],m11[0:GW*GH-1];
 reg [64:0] q00,q10,q01,q11;
 wire [11:0] view_y=frame_compare?(oy-H/4)*2:oy;
 wire [10:0] node=gy*GW+gx,cell_addr=(view_y>>6)*GW+cx;
 always @(posedge clk)begin
  if(st==MAP_WAIT&&md)begin m00[node]<={ray_ok,my,mx};m10[node]<={ray_ok,my,mx};m01[node]<={ray_ok,my,mx};m11[node]<={ray_ok,my,mx};end
  if(st==CELL_READ)begin q00<=m00[cell_addr];q10<=m10[cell_addr+1];q01<=m01[cell_addr+GW];q11<=m11[cell_addr+GW+1];end
 end
 reg signed [40:0] lx,rx,ly,ry;
 reg signed [47:0] ax,ay;reg signed [41:0] dx,dy;reg cell_ok;
 reg signed [32:0] diffx0,diffx1,diffy0,diffy1;
 reg signed [40:0] basex0,basex1,basey0,basey1,productx0,productx1,producty0,producty1;
 wire signed [31:0] x00=q00[31:0],x10=q10[31:0],x01=q01[31:0],x11=q11[31:0];
 wire signed [31:0] y00=q00[63:32],y10=q10[63:32],y01=q01[63:32],y11=q11[63:32];
 wire signed [6:0] phase=$signed({1'b0,view_y[5:0]});
 wire pv=(st==RENDER);wire pr,qv,cache_ready;
 // Both panes are copied from this leased source frame before source_done.
 // RAW is a full-FOV 2x downsample; EIS uses every second native mesh sample.
 wire raw_pane=frame_compare&&ox<W/2;
 wire signed [31:0] px=raw_pane?($signed({20'b0,ox})<<<9):(cell_ok ? (ax>>>12) : -32'sd256);
 wire signed [31:0] py=raw_pane?($signed({20'b0,view_y})<<<8):(cell_ok ? (ay>>>12) : -32'sd256);
 // Two-entry FIFO makes generator readiness depend only on registered
 // occupancy. Tag-hit routing must not drive the wide mesh accumulators' CE.
 reg [1:0] point_count=0;reg point_read=0,point_write=0;
 reg signed [31:0] point_x_fifo[0:1],point_y_fifo[0:1];
 wire point_push=pv&&pr,point_pop=(point_count!=0)&&cache_ready;
 assign pr=point_count<2;
 wire signed [31:0] cache_x=point_x_fifo[point_read],cache_y=point_y_fifo[point_read];
 wire [11:0] cache_next_x=cache_x[19:8]+12'd1,cache_next_y=cache_y[19:8]+12'd1;
 wire cache_in_view=cache_x>=0&&cache_y>=0&&cache_x<(W-1)*256&&cache_y<(H-1)*256;
 always @(posedge clk or negedge resetn)begin
  if(!resetn)begin point_count<=0;point_read<=0;point_write<=0;end
  else if(st==IDLE&&start)begin point_count<=0;point_read<=0;point_write<=0;end
  else begin
   case({point_push,point_pop})
    2'b10:point_count<=point_count+1'b1;
    2'b01:point_count<=point_count-1'b1;
   endcase
   if(point_push)begin point_x_fifo[point_write]<=px;point_y_fifo[point_write]<=py;point_write<=!point_write;end
   if(point_pop)point_read<=!point_read;
  end
 end
 wire [15:0] p00,p10,p01,p11;wire [7:0] fx,fy;wire cache_req;wire [31:0] cache_addr,cache_misses;
 wire cache_accept,cache_valid,cache_done;wire [15:0] cache_beats;
 eis_quad_cache #(.W(W),.H(H)) cache(.clk(clk),.resetn(resetn),.flush(st==IDLE&&start),.source_base(src_base),.vertical(cache_vertical),.shallow(cache_shallow),
  .point_valid(point_count!=0),.point_x(cache_x),.point_y(cache_y),.point_next_x(cache_next_x),.point_next_y(cache_next_y),.point_in_view(cache_in_view),.point_ready(cache_ready),.quad_valid(qv),.p00(p00),.p10(p10),.p01(p01),.p11(p11),.fx(fx),.fy(fy),
  .req(cache_req),.addr(cache_addr),.fetch_beats(cache_beats),.accept(cache_accept),.done(cache_done),.valid(cache_valid),.rdata(rdata),.misses(cache_misses));
 reg hv=0,vv=0;reg [7:0] fy2;reg [13:0] hr0,hr1,hg0,hg1,hb0,hb1;reg [23:0] vr,vg,vb;
 wire [15:0] interpolated_pixel={vr[20:16],vg[21:16],vb[20:16]};
 wire [15:0] pixel;wire gamma_valid;
 reg [3:0] curve_hold=7;reg [8:0] strength_hold=0;
 camera_night_pixel_r19 gamma(.clk(clk),.resetn(resetn),.in_valid(vv),.pixel(interpolated_pixel),.curve(curve_hold),.strength(strength_hold),.out_valid(gamma_valid),.result(pixel));
 reg [11:0] packed_pixels=0;reg [7:0] packed_beat=0;reg [255:0] packed_word=0;
 reg [255:0] rows[0:2*(W/16)-1];reg [1:0] row_ready=0;
 reg [11:0] write_y=0;reg [7:0] burst_base=0,burst_len=0;
 reg [2:0] writer=0;reg [4:0] fill=0,send_index=0;
 reg [255:0] row_read,packet[0:15];
 reg [1:0] bus=0;
 reg [7:0] raw_base=0,raw_received=0;
 wire [15:0] raw_len=W/16-raw_base>16?16:W/16-raw_base;
 wire raw_req=st==RAW_CMD;
 reg [127:0] raw_half;
 wire [127:0] raw_evens={rdata[239:224],rdata[207:192],rdata[175:160],rdata[143:128],rdata[111:96],rdata[79:64],rdata[47:32],rdata[15:0]};
 always @(posedge clk)begin
  if(st==BLACK_ROW)rows[oy[0]*(W/16)+packed_beat]<=0;
  else if(bus==3&&valid&&raw_received[0])rows[oy[0]*(W/16)+(raw_received>>1)]<={raw_evens,raw_half};
  else if(gamma_valid&&packed_pixels[3:0]==15)rows[oy[0]*(W/16)+packed_beat]<={pixel,packed_word[255:16]};
  if(writer==1)row_read<=rows[write_y[0]*(W/16)+burst_base+fill];
 end
 assign req=bus==0&&(writer==3||raw_req||cache_req);
 assign write=writer==3&&bus==0;
 assign addr=write?dst_base+write_y*(W*2)+burst_base*32:raw_req?src_base+view_y*(W*2)+raw_base*32:cache_addr;
 assign beats=write?{8'b0,burst_len}:raw_req?raw_len:cache_beats;
 assign wdata=packet[send_index[3:0]];
 assign cache_accept=accept&&req&&!write&&!raw_req;
 assign cache_valid=valid&&bus==1;
 assign cache_done=done&&bus==1;
 always @(posedge clk or negedge resetn)begin
  if(!resetn)begin
   st<=IDLE;busy<=0;source_done<=0;display_valid<=0;display_bank<=0;completed<=0;displayed<=0;last_cycles<=0;cycles<=0;
   gx<=0;gy<=0;cx<=0;ox<=0;oy<=0;mesh_bad<=0;used_fallback<=0;rs_retry<=0;fallbacks<=0;rs_fallbacks<=0;display_limited<=0;display_compare<=0;
   hv<=0;vv<=0;row_ready<=0;writer<=0;bus<=0;packed_pixels<=0;packed_beat<=0;packed_word<=0;write_y<=0;
  end else begin
   source_done<=0;if(busy)cycles<=cycles+1;
   hv<=qv;vv<=hv;
   if(qv)begin
    fy2<=fy;
    hr0<=p00[15:11]*(9'd256-{1'b0,fx})+p10[15:11]*{1'b0,fx};hr1<=p01[15:11]*(9'd256-{1'b0,fx})+p11[15:11]*{1'b0,fx};
    hg0<=p00[10:5]*(9'd256-{1'b0,fx})+p10[10:5]*{1'b0,fx};hg1<=p01[10:5]*(9'd256-{1'b0,fx})+p11[10:5]*{1'b0,fx};
    hb0<=p00[4:0]*(9'd256-{1'b0,fx})+p10[4:0]*{1'b0,fx};hb1<=p01[4:0]*(9'd256-{1'b0,fx})+p11[4:0]*{1'b0,fx};
   end
   if(hv)begin
    vr<=hr0*(9'd256-{1'b0,fy2})+hr1*{1'b0,fy2}+24'd32768;
    vg<=hg0*(9'd256-{1'b0,fy2})+hg1*{1'b0,fy2}+24'd32768;
    vb<=hb0*(9'd256-{1'b0,fy2})+hb1*{1'b0,fy2}+24'd32768;
   end
   if(gamma_valid)begin
    packed_word<={pixel,packed_word[255:16]};packed_pixels<=packed_pixels+1;
    if(packed_pixels[3:0]==15)packed_beat<=packed_beat+1;
    if(packed_pixels==W-1)begin row_ready[oy[0]]<=1;packed_pixels<=0;packed_beat<=0;st<=ROW_WAIT;end
   end
   if(req&&accept)begin bus<=write?2:raw_req?3:1;if(write)begin writer<=4;send_index<=0;end end
   if(bus==3&&valid)begin raw_half<=raw_evens;raw_received<=raw_received+1;end
   if(bus==2&&take)send_index<=send_index+1;
   if(bus!=0&&done)begin bus<=0;if(bus==2)writer<=5;end
   case(writer)
    0:if(row_ready[write_y[0]])begin burst_base<=0;burst_len<=W/16>16?16:W/16;fill<=0;writer<=1;end
    1:writer<=2;
    2:begin packet[fill]<=row_read;if(fill+1==burst_len)writer<=3;else begin fill<=fill+1;writer<=1;end end
    5:begin
     fill<=0;
     if(burst_base+burst_len==W/16)begin row_ready[write_y[0]]<=0;write_y<=write_y+1;writer<=0;end
     else begin burst_base<=burst_base+burst_len;burst_len<=W/16-burst_base-burst_len>16?16:W/16-burst_base-burst_len;writer<=1;end
    end
   endcase
   case(st)
    IDLE:if(start)begin
     curve_hold<=night_curve;strength_hold<=night_strength;cfg<=config_words;map_cfg<=config_words[575:0];src_base<=source_base;
     out_bank<=0;dst_base<=result_base;
     gx<=0;gy<=0;ox<=0;oy<=0;cx<=0;write_y<=0;row_ready<=0;writer<=0;cycles<=0;busy<=1;mesh_bad<=0;used_fallback<=0;rs_retry<=0;st<=MAP_START;
    end
    MAP_START:st<=MAP_WAIT;
    MAP_WAIT:if(md)begin
     if(gy==0&&gx==0)begin first_mx<=mx;first_my<=my;end
     // Switch before the 45-degree boundary: lens curvature can make local
     // diagonal slopes steeper than the first row's endpoint estimate.
     if(gy==0&&gx==GW-1)begin
      cache_vertical<=mesh_ady>(mesh_adx>>1);
      cache_shallow<=mesh_adx>(mesh_ady<<2);
     end
     if(!mi)mesh_bad<=1;
     if(gx==GW-1)begin
      gx<=0;
      if(gy==GH-1)begin
       if((mesh_bad||!mi)&&cfg[866]&&!rs_retry&&!used_fallback)begin
        // Preserve the successful frame stabilization if row correction alone
        // exceeds crop headroom: retry the SAME primary matrix with RS off.
        rs_retry<=1;gx<=0;gy<=0;mesh_bad<=0;rs_fallbacks<=rs_fallbacks+1;st<=MAP_START;
       end else if((mesh_bad||!mi)&&cfg[864]&&!used_fallback)begin
        map_cfg[287:0]<=cfg[576+:288];gx<=0;gy<=0;mesh_bad<=0;used_fallback<=1;fallbacks<=fallbacks+1;st<=MAP_START;
       end else st<=frame_compare?BLACK_ROW:CELL_READ;
      end else begin gy<=gy+1;st<=MAP_START;end
     end else begin gx<=gx+1;st<=MAP_START;end
    end
    CELL_READ:st<=CELL_WAIT;
    CELL_WAIT:st<=CELL_EDGE;
    CELL_EDGE:begin
     basex0<=$signed(x00)*64;basex1<=$signed(x10)*64;basey0<=$signed(y00)*64;basey1<=$signed(y10)*64;
     diffx0<=$signed({x01[31],x01})-$signed({x00[31],x00});diffx1<=$signed({x11[31],x11})-$signed({x10[31],x10});
     diffy0<=$signed({y01[31],y01})-$signed({y00[31],y00});diffy1<=$signed({y11[31],y11})-$signed({y10[31],y10});
     cell_ok<=q00[64]&&q10[64]&&q01[64]&&q11[64];st<=CELL_PRODUCT;
    end
    CELL_PRODUCT:begin productx0<=diffx0*phase;productx1<=diffx1*phase;producty0<=diffy0*phase;producty1<=diffy1*phase;st<=CELL_SUM;end
    CELL_SUM:begin lx<=basex0+productx0;rx<=basex1+productx1;ly<=basey0+producty0;ry<=basey1+producty1;st<=CELL_INIT;end
    CELL_INIT:begin ax<=lx<<<6;ay<=ly<<<6;dx<=rx-lx;dy<=ry-ly;st<=RENDER;end
    RENDER:if(pr)begin
     ax<=ax+(frame_compare?(dx<<<1):dx);ay<=ay+(frame_compare?(dy<<<1):dy);ox<=ox+1;
     if(ox==W-1)st<=DRAIN;
     else if(frame_compare)begin
      if(ox==W/2-1)begin cx<=0;st<=CELL_READ;end
      else if(ox>=W/2&&ox[4:0]==31)begin cx<=cx+1;st<=CELL_READ;end
     end else if(ox[5:0]==63)begin cx<=cx+1;st<=CELL_READ;end
    end
    BLACK_ROW:begin
     packed_beat<=packed_beat+1;
     if(packed_beat==W/16-1)begin row_ready[oy[0]]<=1;packed_beat<=0;st<=ROW_WAIT;end
    end
    RAW_CMD:if(req&&accept&&!write)st<=RAW_DATA;
    RAW_DATA:if(bus==3&&done)begin
     if(raw_base+raw_len==W/16)begin
      packed_pixels<=W/2;packed_beat<=W/32;packed_word<=0;st<=CELL_READ;
     end else begin raw_base<=raw_base+raw_len;st<=RAW_CMD;end
    end
    ROW_WAIT:begin
     if(oy==H-1)st<=FINISH;
     else if(!row_ready[~oy[0]])begin
      oy<=oy+1;ox<=frame_compare?W/2:0;cx<=0;raw_base<=0;raw_received<=0;
      st<=frame_compare?((oy+1<H/4||oy+1>=3*H/4)?BLACK_ROW:RAW_CMD):CELL_READ;
     end
    end
    FINISH:if(write_y==H&&writer==0&&bus==0)begin source_done<=1;completed<=completed+1;last_cycles<=cycles;st<=COMMIT;end
    COMMIT:if(frame_edge)begin
     display_bank<=out_bank;display_compare<=frame_compare;display_valid<=1;displayed<=displayed+1;display_limited<=cfg[865]||used_fallback;busy<=0;st<=IDLE;
    end
   endcase
  end
 end
endmodule
