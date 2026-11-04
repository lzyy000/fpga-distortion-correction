#ifndef BOARD_MAP_H
#define BOARD_MAP_H
/* Brown-Conrady five-coefficient model. All correction calculations execute
 * on the RV32. Internal signed Q31 uses 64-bit containers/products; output
 * matches the RTL's two signed 32-bit Q5 coordinates (8 bytes/pixel). No floating point.
 * Supported profile: K has no skew, R=I, K'=K, fx=1380, fy=1035 at 1920x1080.
 * The image centre is (W-1)/2,(H-1)/2. Profile 0 is an on-board identity map.
 */
#ifndef CAL_FX
#define CAL_FX 1380u
#endif
#ifndef CAL_FY
#define CAL_FY 1035u
#endif
typedef long long bm_i64;
typedef unsigned long long bm_u64;
static bm_i64 bm_mul(bm_i64 a,bm_i64 b){return (a*b+(1LL<<30))>>31;}
static bm_i64 bm_normalize(int twice,unsigned focal){
 unsigned unit=(1u<<30)/focal,rem=(1u<<30)%focal;
 int tail=twice*(int)rem;
 int rounded=tail>=0?(tail+(int)focal/2)/(int)focal:-((-tail+(int)focal/2)/(int)focal);
 return (bm_i64)twice*unit+rounded;
}
static bm_i64 bm_even(bm_i64 value,unsigned shift){
 bm_u64 magnitude=value<0?(bm_u64)(-value):(bm_u64)value;
 bm_u64 whole=magnitude>>shift,rem=magnitude-(whole<<shift),half=1ULL<<(shift-1);
 if(rem>half || (rem==half && (whole&1)))whole++;
 return value<0?-(bm_i64)whole:(bm_i64)whole;
}
static int bm_coord(bm_i64 value){
 /* Emulate CV_32FC1 storage rounding, then nearest-even Q5 quantization.
  * Coordinates in this fixed profile are normal finite float32 values.
  */
 bm_u64 magnitude=value<0?(bm_u64)(-value):(bm_u64)value;
 unsigned drop=0;
 while(magnitude>=(1ULL<<24)){magnitude>>=1;drop++;}
 if(drop)value=bm_even(value,drop)*(1LL<<drop);
 return (int)bm_even(value,26);
}
static void board_map_coords(unsigned u,unsigned v,unsigned profile,unsigned *qx_out,unsigned *qy_out){
 if(profile==0){*qx_out=u<<5;*qy_out=v<<5;return;}
 const bm_i64 one=2147483648LL,k1=-601295421LL,k2=150323855LL;
 const bm_i64 p1=4294967LL,p2=-2147484LL;
 bm_i64 x=bm_normalize((int)(2*u)-(int)(W-1),CAL_FX);
 bm_i64 y=bm_normalize((int)(2*v)-(int)(H-1),CAL_FY);
 bm_i64 x2=bm_mul(x,x),y2=bm_mul(y,y),r2=x2+y2,xy=bm_mul(x,y);
 bm_i64 radial=one+bm_mul(r2,k1+bm_mul(r2,k2)); /* k3=0 */
 bm_i64 xd=bm_mul(x,radial)+bm_mul(2*p1,xy)+bm_mul(p2,r2+2*x2);
 bm_i64 yd=bm_mul(y,radial)+bm_mul(p1,r2+2*y2)+bm_mul(2*p2,xy);
 int qx=bm_coord(xd*CAL_FX+((bm_i64)(W-1)<<30));
 int qy=bm_coord(yd*CAL_FY+((bm_i64)(H-1)<<30));
 *qx_out=(unsigned)qx;*qy_out=(unsigned)qy;
}
#endif
