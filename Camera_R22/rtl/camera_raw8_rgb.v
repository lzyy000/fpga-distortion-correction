// One RAW8 sample per clock -> bilinear RGB565, full W x H.
// Four independent synchronous line RAMs allow three-row reads while writing
// the next row. Reflect borders preserve Bayer parity (no dark/false edge).
// Never manufacture a valid row from short/long input; poison that frame.
module camera_raw8_rgb #(parameter W=1920,H=1080)(
 input clk,resetn,vs,href,input [7:0] raw,
 output reg out_vs=0,out_de=0,output reg [15:0] rgb=0,output reg [23:0] rgb888=0,
 output reg bad_frame=0,
 output reg [31:0] diag_last_geometry=0,diag_last_error=0,good_gray=0,bad_gray=0);
reg frame_bad=0;
reg [31:0] first_error=0,good_count=0,bad_count=0;
reg vs_pending=0,pending_bad=0;
reg [7:0] ram0[0:W-1],ram1[0:W-1],ram2[0:W-1],ram3[0:W-1];
reg [7:0] q0,q1,q2,q3;
reg [12:0] wx=0,wy=0;
reg vd=0,hd=0,seen=0,busy=0,bottom_pending=0;
wire invalid_at_vs=frame_bad||(seen&&(wy!=H||wx!=0||href))||vs_pending;
reg [12:0] col=0,col_d=0,oy=0;
reg valid_d=0;
wire [11:0] ra=(col==W)?W-1:col;
wire we=resetn&&seen&&!frame_bad&&href&&wx<W&&wy<H;
always @(posedge clk)begin
 if(we&&wy[1:0]==0)ram0[wx]<=raw;
 if(we&&wy[1:0]==1)ram1[wx]<=raw;
 if(we&&wy[1:0]==2)ram2[wx]<=raw;
 if(we&&wy[1:0]==3)ram3[wx]<=raw;
 if(busy)begin q0<=ram0[ra];q1<=ram1[ra];q2<=ram2[ra];q3<=ram3[ra];end
end
wire [12:0] upper=(oy==0)?13'd1:oy-1'b1;
wire [12:0] lower=(oy==H-1)?H-2:oy+1'b1;
function [7:0] select_bank;
 input [1:0] bank;input [7:0] a,b,c,d;
 begin case(bank)0:select_bank=a;1:select_bank=b;2:select_bank=c;3:select_bank=d;endcase end
endfunction
wire [7:0] tq=select_bank(upper[1:0],q0,q1,q2,q3);
wire [7:0] mq=select_bank(oy[1:0],q0,q1,q2,q3);
wire [7:0] bq=select_bank(lower[1:0],q0,q1,q2,q3);
reg [7:0] t1=0,t2=0,m1=0,m2=0,b1=0,b2=0;
wire first=col_d==1,last=col_d==W;
wire [7:0] tl=first?tq:t2,tr=last?t2:tq;
wire [7:0] ml=first?mq:m2,mr=last?m2:mq;
wire [7:0] bl=first?bq:b2,br=last?b2:bq;
wire [9:0] cross_sum={2'b0,t1}+{2'b0,b1}+{2'b0,ml}+{2'b0,mr};
wire [9:0] diag_sum={2'b0,tl}+{2'b0,tr}+{2'b0,bl}+{2'b0,br};
wire [8:0] horiz_sum={1'b0,ml}+{1'b0,mr};
wire [8:0] vert_sum={1'b0,t1}+{1'b0,b1};
reg [7:0] r,g,b;
// 4300=00 selects BGGR output. Actual module colour order must be checked.
// col_d is center column + 1, so odd col_d means an even center column.
always @*begin
 r=0;g=0;b=0;
 case({oy[0],!col_d[0]})
  2'b00:begin b=m1;g=cross_sum[9:2];r=diag_sum[9:2];end
  2'b01:begin g=m1;b=horiz_sum[8:1];r=vert_sum[8:1];end
  2'b10:begin g=m1;r=horiz_sum[8:1];b=vert_sum[8:1];end
  2'b11:begin r=m1;g=cross_sum[9:2];b=diag_sum[9:2];end
 endcase
end
always @(posedge clk or negedge resetn)begin
 if(!resetn)begin
  wx<=0;wy<=0;vd<=0;hd<=0;seen<=0;busy<=0;bottom_pending<=0;
  col<=0;col_d<=0;oy<=0;valid_d<=0;frame_bad<=0;bad_frame<=0;out_vs<=0;out_de<=0;rgb<=0;rgb888<=0;
  vs_pending<=0;pending_bad<=0;
  first_error<=0;diag_last_geometry<=0;diag_last_error<=0;good_count<=0;bad_count<=0;good_gray<=0;bad_gray<=0;
  t1<=0;t2<=0;m1<=0;m2<=0;b1<=0;b2<=0;
 end else begin
  good_gray<=(good_count>>1)^good_count;bad_gray<=(bad_count>>1)^bad_count;
  vd<=vs;hd<=href;out_vs<=0;bad_frame<=frame_bad;out_de<=0;valid_d<=busy;col_d<=col;
  // The final interpolated row drains during vertical blank. Delay the output
  // frame boundary until that row and pipeline are complete, preserving it even
  // when sensor VS rises immediately after its last input row.
  if(vs_pending&&!busy&&!valid_d&&!out_de&&!bottom_pending)begin
   out_vs<=1;bad_frame<=pending_bad;vs_pending<=0;
  end
  if(vs&&!vd)begin
   pending_bad<=invalid_at_vs;
   if(seen)begin
    diag_last_geometry<={6'b0,wy,wx};
    diag_last_error<=frame_bad?first_error:invalid_at_vs?{(vs_pending?4'd7:4'd6),busy,bottom_pending,valid_d,vs_pending,wy[11:0],wx[11:0]}:32'b0;
    if(invalid_at_vs)bad_count<=bad_count+1'b1;else good_count<=good_count+1'b1;
   end
   first_error<=0;
   vs_pending<=1;wx<=0;wy<=0;seen<=1;frame_bad<=0;
  end else begin
   if(seen&&href)begin
    if(wx>=W||wy>=H)begin
     frame_bad<=1;
     if(!frame_bad)first_error<={(wy>=H?4'd2:4'd1),busy,bottom_pending,valid_d,vs_pending,wy[11:0],wx[11:0]};
    end
    else wx<=wx+1'b1;
   end
   if(seen&&!href&&hd)begin
    wx<=0;wy<=wy+1'b1;
    if(wx!=W||wy>=H||busy||vs_pending)begin
     frame_bad<=1;
     if(!frame_bad)first_error<={(wx!=W?4'd3:wy>=H?4'd2:busy?4'd4:4'd5),busy,bottom_pending,valid_d,vs_pending,wy[11:0],wx[11:0]};
    end
    else if(!frame_bad&&wy>=1)begin
     busy<=1;col<=0;oy<=wy-1'b1;
     if(wy==H-1)bottom_pending<=1;
    end
   end
  end
   // Drain the previous output row on every clock, including an input VS edge.
   if(busy)begin
    if(col==W)begin busy<=0;col<=0;end else col<=col+1'b1;
   end else if(bottom_pending&&!frame_bad)begin
    bottom_pending<=0;busy<=1;col<=0;oy<=H-1;
   end
   if(valid_d)begin
    t2<=t1;t1<=tq;m2<=m1;m1<=mq;b2<=b1;b1<=bq;
    if(col_d!=0&&!frame_bad&&!(vs&&!vd&&invalid_at_vs))begin out_de<=1;rgb<={r[7:3],g[7:2],b[7:3]};rgb888<={r,g,b};end
   end
   // A malformed preceding frame may leave a pending last row. Discard that
   // work at VS so it cannot leak into a later, otherwise valid frame.
   if(vs&&!vd&&invalid_at_vs)begin busy<=0;bottom_pending<=0;valid_d<=0;out_de<=0;end
 end
end
endmodule
