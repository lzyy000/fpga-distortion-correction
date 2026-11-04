// Two output pixels per clock after a line has been staged.
// Maps are signed Q5. Cache capacity is checked at run time, not assumed.
// R22 selects 32 rows after verifying the current calibration needs at most 23.
module video_row_remap_r21 #(parameter W=1920,H=1080,MAP_BASE=32'h02000000,PACKED_MAP=0,CACHE_ROW_BITS=6)(
 input clk,resetn,start,input [3:0] night_curve,input [8:0] night_strength,input [31:0] source_base,result_base,
 output reg busy=0,done=0,error=0,output reg [31:0] cycles=0,
 output reg [31:0] map_cycles=0,load_cycles=0,pipe_cycles=0,write_cycles=0,
 output req,output write,output [31:0] addr,output [15:0] beats,input accept,
 input [255:0] rdata,input rvalid,mem_done,
 output reg [255:0] wdata,input take);
localparam LB=W/16,MB=PACKED_MAP?W/8:W/4;
localparam CACHE_ROWS=1<<CACHE_ROW_BITS;
localparam CACHE_ADDR_BITS=CACHE_ROW_BITS-1+$clog2(LB);
localparam CACHE_WORDS=1<<CACHE_ADDR_BITS;
localparam MAP_WIDTH=PACKED_MAP?32:64,MAP_SHIFT=PACKED_MAP?3:2;
localparam IDLE=0,MAP_CMD=1,MAP_DATA=2,CHECK=3,LOAD_CMD=4,LOAD_DATA=5,
 PIPE=6,NEXT=9,FAIL=10,MAP_DRAIN=11;
reg [3:0] st=0;
// Drain only fully produced 16-beat packets while later pixels are computed.
// The two RAM ports never read an uncommitted packet. Native writes still use
// the DMA's complete-packet preload; no WREADY -> pixel-pipeline path is added.
localparam WRITE_IDLE=0,WRITE_REQUEST=1,WRITE_SEND=2;
reg [1:0] write_state=WRITE_IDLE;
reg pipe_done=0;
reg [15:0] produced_beats=0,written_beats=0,write_chunk=0;
wire [15:0] next_chunk=(LB-written_beats>16)?16:LB-written_beats;
// Locally stage the two disjoint engine read destinations. Completion follows
// the same extra clock, so the final RAM write drains before row/state changes.
reg [255:0] map_read_data,cache_read_data;
reg map_read_valid=0,cache_read_valid=0,read_done=0;
always @(posedge clk)begin
 if(st==MAP_DATA&&rvalid)map_read_data<=rdata;
 if(st==LOAD_DATA&&rvalid)cache_read_data<=rdata;
end
always @(posedge clk or negedge resetn)
 if(!resetn)begin map_read_valid<=0;cache_read_valid<=0;read_done<=0;end
 else begin
  map_read_valid<=st==MAP_DATA&&rvalid;
  cache_read_valid<=st==LOAD_DATA&&rvalid;
  read_done<=(st==MAP_DATA||st==LOAD_DATA)&&mem_done;
 end
reg [31:0] src,dst;
reg [11:0] row=0,load_row=0,min_row=0,max_row=0;
reg any_row=0;
reg [15:0] rx_count=0,tx_count=0,issue_x=0,output_x=0;
reg [CACHE_ROWS-1:0] valid_rows=0;
reg [11:0] tags[0:CACHE_ROWS-1];
reg [MAP_WIDTH-1:0] map0[0:MB-1],map1[0:MB-1],map2[0:MB-1],map3[0:MB-1];
reg [MAP_WIDTH-1:0] map4[0:MB-1],map5[0:MB-1],map6[0:MB-1],map7[0:MB-1];
reg [MAP_WIDTH-1:0] mq0,mq1,mq2,mq3,mq4,mq5,mq6,mq7;
reg [1:0] map_lane=0;
function signed [31:0] expand_axis;input [15:0] code;
 begin expand_axis={{16{&code[15:5]}},code};end
endfunction
function [63:0] expand_pair;input [31:0] code;
 begin expand_pair={expand_axis(code[31:16]),expand_axis(code[15:0])};end
endfunction
wire [31:0] compact_0=map_lane==0?mq0:map_lane==1?mq2:map_lane==2?mq4:mq6;
wire [31:0] compact_1=map_lane==0?mq1:map_lane==1?mq3:map_lane==2?mq5:mq7;
// Even/odd column x even/odd row: four independent synchronous read banks.
// Each wide word holds eight pixels of one column parity.
reg [127:0] bank00[0:CACHE_WORDS-1],bank01[0:CACHE_WORDS-1],bank10[0:CACHE_WORDS-1],bank11[0:CACHE_WORDS-1];
reg [127:0] q00_0,q01_0,q10_0,q11_0;
reg [127:0] q00_1,q01_1,q10_1,q11_1;
// Separate cache RAM output from the eight-lane pixel selector.
reg [127:0] qc00_0,qc01_0,qc10_0,qc11_0;
reg [127:0] qc00_1,qc01_1,qc10_1,qc11_1;
reg [255:0] result_line[0:LB-1];
reg [255:0] packed_pixels=0;

// Split packed-map selection from sign expansion without changing throughput.
reg [31:0] selected_compact_0,selected_compact_1;
reg vpacked=0;
reg [63:0] selected_map_0,selected_map_1;
reg va=0,vsel=0,vb=0,vcache=0,vbank=0,vc=0,vc_product=0,vd=0,ve=0;
wire [63:0] mc_0=selected_map_0;
wire signed [31:0] sx_0=$signed(mc_0[31:0])>>>5,sy_0=$signed(mc_0[63:32])>>>5;
wire signed [31:0] xe_0=sx_0[0]?sx_0+1:sx_0,xo_0=sx_0[0]?sx_0:sx_0+1;
wire signed [31:0] ye_0=sy_0[0]?sy_0+1:sy_0,yo_0=sy_0[0]?sy_0:sy_0+1;
function [CACHE_ADDR_BITS-1:0] ca_0;
 input signed [31:0] x,y;
 begin ca_0=((y[CACHE_ROW_BITS-1:1]*LB)+(x[11:4])); end
endfunction
wire [CACHE_ADDR_BITS-1:0] a00_0=ca_0(xe_0,ye_0),a01_0=ca_0(xo_0,ye_0),a10_0=ca_0(xe_0,yo_0),a11_0=ca_0(xo_0,yo_0);
reg bx_0,by_0;
reg [2:0] le_0,lo_0;
reg [3:0] oks_0;
reg [4:0] fx_b_0,fy_b_0,fx_c_0,fy_c_0,fy_d_0;
reg bx_cache_0,by_cache_0;reg [2:0] le_cache_0,lo_cache_0;
reg [3:0] oks_cache_0;reg [4:0] fx_cache_0,fy_cache_0;
// Select within each RAM bank before the parity/bounds mux stage.
reg [15:0] even_even_0,odd_even_0,even_odd_0,odd_odd_0;
reg bx_pick_0,by_pick_0;reg [3:0] oks_pick_0;reg [4:0] fx_pick_0,fy_pick_0;
wire [15:0] upper0_0=bx_pick_0?odd_even_0:even_even_0,upper1_0=bx_pick_0?even_even_0:odd_even_0;
wire [15:0] lower0_0=bx_pick_0?odd_odd_0:even_odd_0,lower1_0=bx_pick_0?even_odd_0:odd_odd_0;
reg [15:0] p0_0,p1_0,p2_0,p3_0;
reg [15:0] pd0_0,pd1_0,pd2_0,pd3_0;
reg [4:0] fx_product_0,fy_product_0;
reg [10:0] hr0_0,hr1_0,hg0_0,hg1_0,hb0_0,hb1_0;
reg [16:0] vr_0,vg_0,vbl_0;
wire [15:0] pixel_0={vr_0[14:10],vg_0[15:10],vbl_0[14:10]};
wire [63:0] mc_1=selected_map_1;
wire signed [31:0] sx_1=$signed(mc_1[31:0])>>>5,sy_1=$signed(mc_1[63:32])>>>5;
wire signed [31:0] xe_1=sx_1[0]?sx_1+1:sx_1,xo_1=sx_1[0]?sx_1:sx_1+1;
wire signed [31:0] ye_1=sy_1[0]?sy_1+1:sy_1,yo_1=sy_1[0]?sy_1:sy_1+1;
function [CACHE_ADDR_BITS-1:0] ca_1;
 input signed [31:0] x,y;
 begin ca_1=((y[CACHE_ROW_BITS-1:1]*LB)+(x[11:4])); end
endfunction
wire [CACHE_ADDR_BITS-1:0] a00_1=ca_1(xe_1,ye_1),a01_1=ca_1(xo_1,ye_1),a10_1=ca_1(xe_1,yo_1),a11_1=ca_1(xo_1,yo_1);
reg bx_1,by_1;
reg [2:0] le_1,lo_1;
reg [3:0] oks_1;
reg [4:0] fx_b_1,fy_b_1,fx_c_1,fy_c_1,fy_d_1;
reg bx_cache_1,by_cache_1;reg [2:0] le_cache_1,lo_cache_1;
reg [3:0] oks_cache_1;reg [4:0] fx_cache_1,fy_cache_1;
// Select within each RAM bank before the parity/bounds mux stage.
reg [15:0] even_even_1,odd_even_1,even_odd_1,odd_odd_1;
reg bx_pick_1,by_pick_1;reg [3:0] oks_pick_1;reg [4:0] fx_pick_1,fy_pick_1;
wire [15:0] upper0_1=bx_pick_1?odd_even_1:even_even_1,upper1_1=bx_pick_1?even_even_1:odd_even_1;
wire [15:0] lower0_1=bx_pick_1?odd_odd_1:even_odd_1,lower1_1=bx_pick_1?even_odd_1:odd_odd_1;
reg [15:0] p0_1,p1_1,p2_1,p3_1;
reg [15:0] pd0_1,pd1_1,pd2_1,pd3_1;
reg [4:0] fx_product_1,fy_product_1;
reg [10:0] hr0_1,hr1_1,hg0_1,hg1_1,hb0_1,hb1_1;
reg [16:0] vr_1,vg_1,vbl_1;
wire [15:0] pixel_1={vr_1[14:10],vg_1[15:10],vbl_1[14:10]};
reg [8:0] frame_strength=0;
always @(posedge clk or negedge resetn)if(!resetn)frame_strength<=0;else if(start&&!busy)frame_strength<=night_strength;
reg [3:0] frame_curve=7;
always @(posedge clk or negedge resetn)if(!resetn)frame_curve<=7;else if(start&&!busy)frame_curve<=night_curve;
wire night_valid0,night_valid1;wire [15:0] night_pixel0,night_pixel1;
camera_night_pixel_r19 gamma0(.clk(clk),.resetn(resetn),.in_valid(ve),.curve(frame_curve),.strength(frame_strength),.pixel(pixel_0),.out_valid(night_valid0),.result(night_pixel0));
camera_night_pixel_r19 gamma1(.clk(clk),.resetn(resetn),.in_valid(ve),.curve(frame_curve),.strength(frame_strength),.pixel(pixel_1),.out_valid(night_valid1),.result(night_pixel1));
assign req=(st==MAP_CMD || st==LOAD_CMD || write_state==WRITE_REQUEST);
assign write=(write_state==WRITE_REQUEST);
assign addr=(st==MAP_CMD)?MAP_BASE+row*(W*(MAP_WIDTH/8)):
 (st==LOAD_CMD)?src+load_row*(W*2):dst+row*(W*2)+({16'b0,written_beats}<<5);
assign beats=(st==MAP_CMD)?MB:(st==LOAD_CMD)?LB:write_chunk;
integer j,k;
reg [2:0] drain=0;
reg yr0=0,yr1=0,yr2=0,yr3=0;
reg [7:0] yok;
reg [11:0] yl[0:7],yh[0:7];
reg [3:0] pok;
reg [11:0] pl[0:3],ph[0:3];
reg [1:0] qok;reg [11:0] ql[0:1],qh[0:1];
reg beat_ok;reg [11:0] beat_lo,beat_hi;
wire signed [31:0] yy0=PACKED_MAP?(expand_axis(map_read_data[31:16])>>>5):($signed(map_read_data[63:32])>>>5);
wire signed [31:0] yy1=PACKED_MAP?(expand_axis(map_read_data[63:48])>>>5):($signed(map_read_data[127:96])>>>5);
wire signed [31:0] yy2=PACKED_MAP?(expand_axis(map_read_data[95:80])>>>5):($signed(map_read_data[191:160])>>>5);
wire signed [31:0] yy3=PACKED_MAP?(expand_axis(map_read_data[127:112])>>>5):($signed(map_read_data[255:224])>>>5);
wire signed [31:0] yy4=PACKED_MAP?(expand_axis(map_read_data[159:144])>>>5):H;
wire signed [31:0] yy5=PACKED_MAP?(expand_axis(map_read_data[191:176])>>>5):H;
wire signed [31:0] yy6=PACKED_MAP?(expand_axis(map_read_data[223:208])>>>5):H;
wire signed [31:0] yy7=PACKED_MAP?(expand_axis(map_read_data[255:240])>>>5):H;
function [11:0] low_y;input signed [26:0] y;
 begin low_y=y<0?0:y[11:0];end
endfunction
function [11:0] high_y;input signed [26:0] y;
 begin high_y=y>=H-1?H-1:y[11:0]+12'd1;end
endfunction
function [11:0] min2;input [11:0] a,b;input av,bv;
 begin min2=!av?b:!bv?a:a<b?a:b;end
endfunction
function [11:0] max2;input [11:0] a,b;input av,bv;
 begin max2=!av?b:!bv?a:a>b?a:b;end
endfunction
reg [127:0] evens,odds;
always @* begin
 evens=0;odds=0;
 for(k=0;k<8;k=k+1)begin
  evens[k*16+:16]=cache_read_data[k*32+:16];odds[k*16+:16]=cache_read_data[k*32+16+:16];
 end
end
// Port A writes cache loads or reads output lane 0. Port B reads lane 1.
// Both addresses of each physical cache bank are independent.
wire load_even=st==LOAD_DATA&&cache_read_valid&&!load_row[0];
wire load_odd=st==LOAD_DATA&&cache_read_valid&&load_row[0];
// Stage the row base before DMA begins, then advance a cache word pointer.
// This removes row multiply plus beat addition from the RAM address path.
reg [CACHE_ADDR_BITS-1:0] cache_write_addr=0;
// Select the cache-load address before the burst starts. Read-valid gates
// writes only; gaps in a burst no longer switch every cache address mux.
reg load_even_mode=0,load_odd_mode=0;
always @(posedge clk or negedge resetn)
 if(!resetn)begin load_even_mode<=0;load_odd_mode<=0;end
 else begin
  load_even_mode<=(st==LOAD_CMD||st==LOAD_DATA)&&!load_row[0];
  load_odd_mode<=(st==LOAD_CMD||st==LOAD_DATA)&&load_row[0];
 end
wire [CACHE_ADDR_BITS-1:0] pa00=load_even_mode?cache_write_addr:a00_0,pa01=load_even_mode?cache_write_addr:a01_0;
wire [CACHE_ADDR_BITS-1:0] pa10=load_odd_mode?cache_write_addr:a10_0,pa11=load_odd_mode?cache_write_addr:a11_0;
always @(posedge clk)begin
 q00_1<=bank00[a00_1];q01_1<=bank01[a01_1];
 q10_1<=bank10[a10_1];q11_1<=bank11[a11_1];
end
// RAM ports are deliberately in reset-free processes for block RAM inference.
always @(posedge clk)begin
 mq0<=map0[issue_x>>MAP_SHIFT];mq1<=map1[issue_x>>MAP_SHIFT];
 mq2<=map2[issue_x>>MAP_SHIFT];mq3<=map3[issue_x>>MAP_SHIFT];
 mq4<=map4[issue_x>>MAP_SHIFT];mq5<=map5[issue_x>>MAP_SHIFT];
 mq6<=map6[issue_x>>MAP_SHIFT];mq7<=map7[issue_x>>MAP_SHIFT];
 selected_compact_0<=compact_0;selected_compact_1<=compact_1;
 selected_map_0<=PACKED_MAP?expand_pair(selected_compact_0):(map_lane[0]?mq2:mq0);
 selected_map_1<=PACKED_MAP?expand_pair(selected_compact_1):(map_lane[0]?mq3:mq1);
 q00_0<=bank00[pa00];q01_0<=bank01[pa01];q10_0<=bank10[pa10];q11_0<=bank11[pa11];
 qc00_0<=q00_0;qc01_0<=q01_0;qc10_0<=q10_0;qc11_0<=q11_0;
 qc00_1<=q00_1;qc01_1<=q01_1;qc10_1<=q10_1;qc11_1<=q11_1;

 if(st==LOAD_DATA && cache_read_valid)begin
  if(!load_row[0])begin
   bank00[pa00]<=evens;
   bank01[pa01]<=odds;
  end else begin
   bank10[pa10]<=evens;
   bank11[pa11]<=odds;
  end
 end
 if(night_valid0 && output_x[3:0]==14)result_line[output_x>>4]<={night_pixel1,night_pixel0,packed_pixels[223:0]};
 // Show-ahead registered read; the native port consumes without WVALID.
 wdata<=result_line[(take?tx_count+1:tx_count)];
end
generate if(PACKED_MAP)begin:packed_rows
 always @(posedge clk)if(st==MAP_DATA&&map_read_valid)begin
  map0[rx_count]<=map_read_data[31:0];map1[rx_count]<=map_read_data[63:32];
  map2[rx_count]<=map_read_data[95:64];map3[rx_count]<=map_read_data[127:96];
  map4[rx_count]<=map_read_data[159:128];map5[rx_count]<=map_read_data[191:160];
  map6[rx_count]<=map_read_data[223:192];map7[rx_count]<=map_read_data[255:224];
 end
end else begin:wide_rows
 always @(posedge clk)if(st==MAP_DATA&&map_read_valid)begin
  map0[rx_count]<=map_read_data[63:0];map1[rx_count]<=map_read_data[127:64];
  map2[rx_count]<=map_read_data[191:128];map3[rx_count]<=map_read_data[255:192];
 end
end endgenerate
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  st<=IDLE;busy<=0;done<=0;error<=0;valid_rows<=0;cycles<=0;
  write_state<=WRITE_IDLE;pipe_done<=0;produced_beats<=0;written_beats<=0;write_chunk<=0;
  map_cycles<=0;load_cycles<=0;pipe_cycles<=0;write_cycles<=0;
  va<=0;vpacked<=0;vsel<=0;vb<=0;vcache<=0;vbank<=0;vc<=0;vc_product<=0;vd<=0;ve<=0;row<=0;issue_x<=0;output_x<=0;tx_count<=0;
  yr0<=0;yr1<=0;yr2<=0;yr3<=0;drain<=0;cache_write_addr<=0;
 end else begin
  done<=0;
  if(busy)begin
   cycles<=cycles+1;
   case(st)
    MAP_CMD,MAP_DATA,MAP_DRAIN:map_cycles<=map_cycles+1;
    CHECK,LOAD_CMD,LOAD_DATA:load_cycles<=load_cycles+1;
    PIPE:if(pipe_done)write_cycles<=write_cycles+1;else pipe_cycles<=pipe_cycles+1;
   endcase
  end
  // Four independent lane bounds, balanced reduction, then accumulation.
  // Drain all stages before validating the configured cache span.
  yr0<=st==MAP_DATA&&map_read_valid;yr1<=yr0;yr2<=yr1;yr3<=yr2;
  if(st==MAP_DATA&&map_read_valid)begin
   yok[0]<=yy0>=-1&&yy0<H;yl[0]<=low_y(yy0);yh[0]<=high_y(yy0);
   yok[1]<=yy1>=-1&&yy1<H;yl[1]<=low_y(yy1);yh[1]<=high_y(yy1);
   yok[2]<=yy2>=-1&&yy2<H;yl[2]<=low_y(yy2);yh[2]<=high_y(yy2);
   yok[3]<=yy3>=-1&&yy3<H;yl[3]<=low_y(yy3);yh[3]<=high_y(yy3);
   yok[4]<=yy4>=-1&&yy4<H;yl[4]<=low_y(yy4);yh[4]<=high_y(yy4);
   yok[5]<=yy5>=-1&&yy5<H;yl[5]<=low_y(yy5);yh[5]<=high_y(yy5);
   yok[6]<=yy6>=-1&&yy6<H;yl[6]<=low_y(yy6);yh[6]<=high_y(yy6);
   yok[7]<=yy7>=-1&&yy7<H;yl[7]<=low_y(yy7);yh[7]<=high_y(yy7);
  end
  if(yr0)begin
   pok[0]<=|yok[1:0];pl[0]<=min2(yl[0],yl[1],yok[0],yok[1]);ph[0]<=max2(yh[0],yh[1],yok[0],yok[1]);
   pok[1]<=|yok[3:2];pl[1]<=min2(yl[2],yl[3],yok[2],yok[3]);ph[1]<=max2(yh[2],yh[3],yok[2],yok[3]);
   pok[2]<=|yok[5:4];pl[2]<=min2(yl[4],yl[5],yok[4],yok[5]);ph[2]<=max2(yh[4],yh[5],yok[4],yok[5]);
   pok[3]<=|yok[7:6];pl[3]<=min2(yl[6],yl[7],yok[6],yok[7]);ph[3]<=max2(yh[6],yh[7],yok[6],yok[7]);
  end
  if(yr1)begin
   qok[0]<=|pok[1:0];ql[0]<=min2(pl[0],pl[1],pok[0],pok[1]);qh[0]<=max2(ph[0],ph[1],pok[0],pok[1]);
   qok[1]<=|pok[3:2];ql[1]<=min2(pl[2],pl[3],pok[2],pok[3]);qh[1]<=max2(ph[2],ph[3],pok[2],pok[3]);
  end
  if(yr2)begin beat_ok<=|qok;beat_lo<=min2(ql[0],ql[1],qok[0],qok[1]);beat_hi<=max2(qh[0],qh[1],qok[0],qok[1]);end
  if(yr3&&beat_ok)begin
   min_row<=min2(min_row,beat_lo,any_row,1'b1);max_row<=max2(max_row,beat_hi,any_row,1'b1);any_row<=1;
  end
  va<=st==PIPE && issue_x<W;vpacked<=va;vsel<=PACKED_MAP?vpacked:va;vb<=vsel;vcache<=vb;vbank<=vcache;vc<=vbank;vc_product<=vc;vd<=vc_product;ve<=vd;
  if(st==PIPE && issue_x<W)begin map_lane<=issue_x[2:1];issue_x<=issue_x+2;end
  if(vsel)begin
   bx_0<=sx_0[0];by_0<=sy_0[0];le_0<=xe_0[3:1];lo_0<=xo_0[3:1];fx_b_0<=mc_0[4:0];fy_b_0<=mc_0[36:32];
   oks_0<={(sx_0+1>=0 && sx_0+1<W && sy_0+1>=0 && sy_0+1<H),
         (sx_0>=0 && sx_0<W && sy_0+1>=0 && sy_0+1<H),
         (sx_0+1>=0 && sx_0+1<W && sy_0>=0 && sy_0<H),
         (sx_0>=0 && sx_0<W && sy_0>=0 && sy_0<H)};
  end
  if(vb)begin
   bx_cache_0<=bx_0;by_cache_0<=by_0;le_cache_0<=le_0;lo_cache_0<=lo_0;
   oks_cache_0<=oks_0;fx_cache_0<=fx_b_0;fy_cache_0<=fy_b_0;
  end
  if(vcache)begin
   even_even_0<=qc00_0[le_cache_0*16+:16];odd_even_0<=qc01_0[lo_cache_0*16+:16];
   even_odd_0<=qc10_0[le_cache_0*16+:16];odd_odd_0<=qc11_0[lo_cache_0*16+:16];
   bx_pick_0<=bx_cache_0;by_pick_0<=by_cache_0;oks_pick_0<=oks_cache_0;
   fx_pick_0<=fx_cache_0;fy_pick_0<=fy_cache_0;
  end
  if(vbank)begin
   p0_0<=oks_pick_0[0]?(by_pick_0?lower0_0:upper0_0):0;p1_0<=oks_pick_0[1]?(by_pick_0?lower1_0:upper1_0):0;
   p2_0<=oks_pick_0[2]?(by_pick_0?upper0_0:lower0_0):0;p3_0<=oks_pick_0[3]?(by_pick_0?upper1_0:lower1_0):0;
   fx_c_0<=fx_pick_0;fy_c_0<=fy_pick_0;
  end
  // Keep a complete registered pixel stage between RAM selection and DSP.
  if(vc)begin
   pd0_0<=p0_0;pd1_0<=p1_0;pd2_0<=p2_0;pd3_0<=p3_0;
   fx_product_0<=fx_c_0;fy_product_0<=fy_c_0;
  end
  if(vc_product)begin
   hr0_0<=pd0_0[15:11]*(6'd32-{1'b0,fx_product_0})+pd1_0[15:11]*{1'b0,fx_product_0};
   hr1_0<=pd2_0[15:11]*(6'd32-{1'b0,fx_product_0})+pd3_0[15:11]*{1'b0,fx_product_0};
   hg0_0<=pd0_0[10:5]*(6'd32-{1'b0,fx_product_0})+pd1_0[10:5]*{1'b0,fx_product_0};
   hg1_0<=pd2_0[10:5]*(6'd32-{1'b0,fx_product_0})+pd3_0[10:5]*{1'b0,fx_product_0};
   hb0_0<=pd0_0[4:0]*(6'd32-{1'b0,fx_product_0})+pd1_0[4:0]*{1'b0,fx_product_0};
   hb1_0<=pd2_0[4:0]*(6'd32-{1'b0,fx_product_0})+pd3_0[4:0]*{1'b0,fx_product_0};fy_d_0<=fy_product_0;
  end
  if(vd)begin
   vr_0<=hr0_0*(6'd32-{1'b0,fy_d_0})+hr1_0*{1'b0,fy_d_0}+17'd512;
   vg_0<=hg0_0*(6'd32-{1'b0,fy_d_0})+hg1_0*{1'b0,fy_d_0}+17'd512;
   vbl_0<=hb0_0*(6'd32-{1'b0,fy_d_0})+hb1_0*{1'b0,fy_d_0}+17'd512;
  end
  if(vsel)begin
   bx_1<=sx_1[0];by_1<=sy_1[0];le_1<=xe_1[3:1];lo_1<=xo_1[3:1];fx_b_1<=mc_1[4:0];fy_b_1<=mc_1[36:32];
   oks_1<={(sx_1+1>=0 && sx_1+1<W && sy_1+1>=0 && sy_1+1<H),
         (sx_1>=0 && sx_1<W && sy_1+1>=0 && sy_1+1<H),
         (sx_1+1>=0 && sx_1+1<W && sy_1>=0 && sy_1<H),
         (sx_1>=0 && sx_1<W && sy_1>=0 && sy_1<H)};
  end
  if(vb)begin
   bx_cache_1<=bx_1;by_cache_1<=by_1;le_cache_1<=le_1;lo_cache_1<=lo_1;
   oks_cache_1<=oks_1;fx_cache_1<=fx_b_1;fy_cache_1<=fy_b_1;
  end
  if(vcache)begin
   even_even_1<=qc00_1[le_cache_1*16+:16];odd_even_1<=qc01_1[lo_cache_1*16+:16];
   even_odd_1<=qc10_1[le_cache_1*16+:16];odd_odd_1<=qc11_1[lo_cache_1*16+:16];
   bx_pick_1<=bx_cache_1;by_pick_1<=by_cache_1;oks_pick_1<=oks_cache_1;
   fx_pick_1<=fx_cache_1;fy_pick_1<=fy_cache_1;
  end
  if(vbank)begin
   p0_1<=oks_pick_1[0]?(by_pick_1?lower0_1:upper0_1):0;p1_1<=oks_pick_1[1]?(by_pick_1?lower1_1:upper1_1):0;
   p2_1<=oks_pick_1[2]?(by_pick_1?upper0_1:lower0_1):0;p3_1<=oks_pick_1[3]?(by_pick_1?upper1_1:lower1_1):0;
   fx_c_1<=fx_pick_1;fy_c_1<=fy_pick_1;
  end
  // Keep a complete registered pixel stage between RAM selection and DSP.
  if(vc)begin
   pd0_1<=p0_1;pd1_1<=p1_1;pd2_1<=p2_1;pd3_1<=p3_1;
   fx_product_1<=fx_c_1;fy_product_1<=fy_c_1;
  end
  if(vc_product)begin
   hr0_1<=pd0_1[15:11]*(6'd32-{1'b0,fx_product_1})+pd1_1[15:11]*{1'b0,fx_product_1};
   hr1_1<=pd2_1[15:11]*(6'd32-{1'b0,fx_product_1})+pd3_1[15:11]*{1'b0,fx_product_1};
   hg0_1<=pd0_1[10:5]*(6'd32-{1'b0,fx_product_1})+pd1_1[10:5]*{1'b0,fx_product_1};
   hg1_1<=pd2_1[10:5]*(6'd32-{1'b0,fx_product_1})+pd3_1[10:5]*{1'b0,fx_product_1};
   hb0_1<=pd0_1[4:0]*(6'd32-{1'b0,fx_product_1})+pd1_1[4:0]*{1'b0,fx_product_1};
   hb1_1<=pd2_1[4:0]*(6'd32-{1'b0,fx_product_1})+pd3_1[4:0]*{1'b0,fx_product_1};fy_d_1<=fy_product_1;
  end
  if(vd)begin
   vr_1<=hr0_1*(6'd32-{1'b0,fy_d_1})+hr1_1*{1'b0,fy_d_1}+17'd512;
   vg_1<=hg0_1*(6'd32-{1'b0,fy_d_1})+hg1_1*{1'b0,fy_d_1}+17'd512;
   vbl_1<=hb0_1*(6'd32-{1'b0,fy_d_1})+hb1_1*{1'b0,fy_d_1}+17'd512;
  end
  if(night_valid0)begin
   packed_pixels[output_x[3:0]*16+:32]<={night_pixel1,night_pixel0};output_x<=output_x+2;
   if(output_x[3:0]==14)produced_beats<=produced_beats+1;
   if(output_x==W-2)pipe_done<=1;
  end
  if(take)tx_count<=tx_count+1;
  if(st==PIPE)begin
   if(write_state==WRITE_IDLE&&written_beats<LB&&produced_beats-written_beats>=next_chunk)begin
    write_chunk<=next_chunk;write_state<=WRITE_REQUEST;
   end
   if(write_state==WRITE_REQUEST&&accept)write_state<=WRITE_SEND;
   if(write_state==WRITE_SEND&&mem_done)begin
    written_beats<=written_beats+write_chunk;write_state<=WRITE_IDLE;
   end
   if(pipe_done&&written_beats==LB&&write_state==WRITE_IDLE)st<=NEXT;
  end
  case(st)
   IDLE:if(start)begin src<=source_base;dst<=result_base;busy<=1;error<=0;cycles<=0;
    valid_rows<=0;row<=0;min_row<=H;max_row<=0;any_row<=0;st<=MAP_CMD;
    map_cycles<=0;load_cycles<=0;pipe_cycles<=0;write_cycles<=0;end
   MAP_CMD:if(accept)begin rx_count<=0;st<=MAP_DATA;end
   MAP_DATA:begin
    if(map_read_valid)rx_count<=rx_count+1;
    if(read_done)begin st<=MAP_DRAIN;drain<=5;end
   end
   MAP_DRAIN:if(drain!=0)drain<=drain-1;
    else begin load_row<=min_row;if(any_row && (max_row-min_row>=CACHE_ROWS))st<=FAIL;else st<=CHECK;end
   CHECK:if(!any_row || load_row>max_row)begin
    issue_x<=0;output_x<=0;tx_count<=0;produced_beats<=0;written_beats<=0;
    pipe_done<=0;write_chunk<=0;write_state<=WRITE_IDLE;st<=PIPE;
   end
    else if(valid_rows[load_row[CACHE_ROW_BITS-1:0]] && tags[load_row[CACHE_ROW_BITS-1:0]]==load_row)load_row<=load_row+1;
    else begin cache_write_addr<=load_row[CACHE_ROW_BITS-1:1]*LB;st<=LOAD_CMD;end
   LOAD_CMD:if(accept)begin rx_count<=0;st<=LOAD_DATA;end
   LOAD_DATA:begin
    if(cache_read_valid)begin rx_count<=rx_count+1;cache_write_addr<=cache_write_addr+1'b1;end
    if(read_done)begin valid_rows[load_row[CACHE_ROW_BITS-1:0]]<=1;tags[load_row[CACHE_ROW_BITS-1:0]]<=load_row;load_row<=load_row+1;st<=CHECK;end
   end
   NEXT:if(row==H-1)begin busy<=0;done<=1;st<=IDLE;end
    else begin row<=row+1;min_row<=H;max_row<=0;any_row<=0;st<=MAP_CMD;end
   FAIL:begin error<=1;busy<=0;done<=1;st<=IDLE;end
  endcase
 end
end
endmodule
