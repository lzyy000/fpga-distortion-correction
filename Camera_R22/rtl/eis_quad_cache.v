// Read-only frame cache. Four parity banks provide a bilinear quad each hit cycle.
// 64 KiB, 16 retained rows. Burst64 for shallow rays, block16 for diagonal
// and vertical rays. Four synchronous parity banks sustain one quad per hit.
module eis_quad_cache #(parameter W=1920,H=1080)(
 input clk,resetn,flush,input [31:0] source_base,input vertical,shallow,
 input point_valid,input signed [31:0] point_x,point_y,
 input [11:0] point_next_x,point_next_y,input point_in_view,output point_ready,
 output reg quad_valid=0,output reg [15:0] p00=0,p10=0,p01=0,p11=0,
 output reg [7:0] fx=0,fy=0,
 output req,output [31:0] addr,output [15:0] fetch_beats,input accept,done,valid,input [255:0] rdata,
 output reg [31:0] misses=0);
 // Bank metadata by source row parity and cache-block parity. A bilinear
 // footprint addresses at most one entry in each bank, including block edges.
 // Valid and tag share the same RAM word. Sequential clear avoids four large
 // asynchronous valid-bit muxes on the hit path. Queries wait for clear.
 reg [8:0] tagEE[0:511],tagEO[0:511],tagOE[0:511],tagOO[0:511];
 reg scrubbing=1;reg [8:0] scrub_addr=0;
 reg [127:0] ee[0:1023],eo[0:1023],oe[0:1023],oo[0:1023];
 reg loading=0,accepted=0;reg [11:0] load_y,load_x;reg [1:0] beat=0;
 wire burst64=shallow&&!vertical;
 function [8:0] meta_;input [11:0] xx,yy;input vv,ss;begin
  meta_=vv?yy[9:1]:ss?{2'b0,yy[3:1],xx[10:7]}:{yy[3:1],xx[10:5]};end endfunction
 function [7:0] tag_;input [11:0] xx,yy;input vv,ss;begin tag_=vv?{yy[11:10],xx[10:5]}:yy[11:4];end endfunction
 function [9:0] bank_;input [11:0] xx,yy;input vv,ss;begin
  bank_=vv?{yy[9:1],xx[4]}:ss?{yy[3:1],xx[10:6],xx[5:4]}:{yy[3:1],xx[10:4]};end endfunction
 wire [11:0] ix=point_x[19:8],iy=point_y[19:8],ix1=point_next_x,iy1=point_next_y;
 wire ibp=burst64?ix[6]:ix[4],ibp1=burst64?ix1[6]:ix1[4];
 wire [11:0] aligned=burst64?{ix[11:6],6'b0}:{ix[11:4],4'b0};
 wire [11:0] next_block=aligned+(burst64?12'd64:12'd16);
 wire [11:0] blockE=ibp?next_block:aligned,blockO=ibp?aligned:next_block;
 wire [11:0] evenY=iy[0]?iy1:iy,oddY=iy[0]?iy:iy1;
 // One elastic stage stores the complete lookup, rather than recomputing
 // mode/address muxes on the hit -> mesh-generator enable feedback path.
 reg query_valid=0,in_view=0;reg [11:0] x,y,x1,y1;
 reg [8:0] iEE,iEO,iOE,iOO;reg [7:0] tEE,tEO,tOE,tOO;
 reg qbp,qbp1,qyp;reg [7:0] qfx,qfy;
 reg [9:0] ae,ao,be,bo;reg [2:0] qle,qlo;
 wire mEE=tagEE[iEE]=={1'b1,tEE},mEO=tagEO[iEO]=={1'b1,tEO},
      mOE=tagOE[iOE]=={1'b1,tOE},mOO=tagOO[iOO]=={1'b1,tOO};
 wire h00=qyp?(qbp?mOO:mOE):(qbp?mEO:mEE),h10=qyp?(qbp1?mOO:mOE):(qbp1?mEO:mEE),
      h01=qyp?(qbp?mEO:mEE):(qbp?mOO:mOE),h11=qyp?(qbp1?mEO:mEE):(qbp1?mOO:mOE);
 wire fire=query_valid&&!loading&&!scrubbing&&(!in_view||(h00&&h10&&h01&&h11));
 assign point_ready=!scrubbing&&(!query_valid||fire);
 wire input_fire=point_valid&&point_ready;
 assign req=loading&&!accepted;
 assign addr=source_base+load_y*(W*2)+{load_x,1'b0};
 assign fetch_beats=burst64?16'd4:16'd1;
 wire [11:0] xe=ix[0]?ix1:ix,xo=ix[0]?ix:ix1;
 reg [127:0] re,ro,se,so;reg [2:0] le,lo;reg xp,yp,hit_valid=0,hit_in_view;
 reg [7:0] fx1,fy1;
 wire [15:0] a=re>>(le*16),b=ro>>(lo*16),c=se>>(le*16),d=so>>(lo*16);
 wire [11:0] fill_x=load_x+{beat,4'b0};
 wire [9:0] wa=bank_(fill_x,load_y,vertical,shallow);
 wire [8:0] mwa=meta_(load_x,load_y,vertical,shallow);
 wire load_odd=burst64?load_x[6]:load_x[4];
 wire [127:0] even_word={rdata[239:224],rdata[207:192],rdata[175:160],rdata[143:128],rdata[111:96],rdata[79:64],rdata[47:32],rdata[15:0]};
 wire [127:0] odd_word={rdata[255:240],rdata[223:208],rdata[191:176],rdata[159:144],rdata[127:112],rdata[95:80],rdata[63:48],rdata[31:16]};
 // Explicit synchronous ports: each parity bank has one read and one fill write.
 always @(posedge clk)begin
  // Speculative synchronous read. Only fire may assert hit_valid, so fill/read
  // collisions while a miss is outstanding can never publish a stale pixel.
  // Keeping the large tag lookup off the DRM clock-enable path is essential.
  if(query_valid)begin re<=ee[ae];ro<=eo[ao];se<=oe[be];so<=oo[bo];end
  if(loading&&valid)begin
   if(!load_y[0])begin ee[wa]<=even_word;eo[wa]<=odd_word;end
   else begin oe[wa]<=even_word;oo[wa]<=odd_word;end
  end
  if(scrubbing)begin
   tagEE[scrub_addr]<=0;tagEO[scrub_addr]<=0;tagOE[scrub_addr]<=0;tagOO[scrub_addr]<=0;
  end else if(loading&&valid&&(!burst64||beat==3))begin
   if(!load_y[0]&&!load_odd)tagEE[mwa]<={1'b1,tag_(load_x,load_y,vertical,shallow)};
   if(!load_y[0]&&load_odd)tagEO[mwa]<={1'b1,tag_(load_x,load_y,vertical,shallow)};
   if(load_y[0]&&!load_odd)tagOE[mwa]<={1'b1,tag_(load_x,load_y,vertical,shallow)};
   if(load_y[0]&&load_odd)tagOO[mwa]<={1'b1,tag_(load_x,load_y,vertical,shallow)};
  end
 end
 always @(posedge clk or negedge resetn)begin
  if(!resetn)begin scrubbing<=1;scrub_addr<=0;query_valid<=0;loading<=0;accepted<=0;quad_valid<=0;hit_valid<=0;misses<=0;beat<=0;end
  else begin
   if(scrubbing)begin
    if(scrub_addr==511)scrubbing<=0;else scrub_addr<=scrub_addr+1'b1;
   end
   hit_valid<=fire;quad_valid<=hit_valid;
   if(input_fire)begin
    query_valid<=1;in_view<=point_in_view;x<=ix;y<=iy;x1<=ix1;y1<=iy1;
    iEE<=meta_(blockE,evenY,vertical,shallow);iEO<=meta_(blockO,evenY,vertical,shallow);
    iOE<=meta_(blockE,oddY,vertical,shallow);iOO<=meta_(blockO,oddY,vertical,shallow);
    tEE<=tag_(blockE,evenY,vertical,shallow);tEO<=tag_(blockO,evenY,vertical,shallow);
    tOE<=tag_(blockE,oddY,vertical,shallow);tOO<=tag_(blockO,oddY,vertical,shallow);
    qbp<=ibp;qbp1<=ibp1;qyp<=iy[0];qfx<=point_x[7:0];qfy<=point_y[7:0];
    ae<=bank_(xe,evenY,vertical,shallow);ao<=bank_(xo,evenY,vertical,shallow);
    be<=bank_(xe,oddY,vertical,shallow);bo<=bank_(xo,oddY,vertical,shallow);
    qle<=xe[3:1];qlo<=xo[3:1];
   end else if(fire)query_valid<=0;
   if(fire)begin xp<=x[0];yp<=y[0];le<=qle;lo<=qlo;fx1<=qfx;fy1<=qfy;hit_in_view<=in_view;end
   if(hit_valid)begin
    fx<=fx1;fy<=fy1;
    p00<=!hit_in_view?0:(yp?(xp?d:c):(xp?b:a));
    p10<=!hit_in_view?0:(yp?(xp?c:d):(xp?a:b));
    p01<=!hit_in_view?0:(yp?(xp?b:a):(xp?d:c));
    p11<=!hit_in_view?0:(yp?(xp?a:b):(xp?c:d));
   end
   if(flush)begin scrubbing<=1;scrub_addr<=0;query_valid<=0;loading<=0;accepted<=0;hit_valid<=0;quad_valid<=0;end
   else if(!scrubbing&&!loading&&query_valid&&in_view&&!(h00&&h10&&h01&&h11))begin
    loading<=1;accepted<=0;beat<=0;misses<=misses+1;
    if(!h00)begin load_y<=y;load_x<=burst64?{x[11:6],6'b0}:{x[11:4],4'b0};end
    else if(!h10)begin load_y<=y;load_x<=burst64?{x1[11:6],6'b0}:{x1[11:4],4'b0};end
    else if(!h01)begin load_y<=y1;load_x<=burst64?{x[11:6],6'b0}:{x[11:4],4'b0};end
    else begin load_y<=y1;load_x<=burst64?{x1[11:6],6'b0}:{x1[11:4],4'b0};end
   end
   if(loading&&accept)accepted<=1;
   if(loading&&valid)begin
    beat<=beat+1'b1;
    if(!burst64||beat==3)begin
     loading<=0;
    end
   end
  end
 end
endmodule
