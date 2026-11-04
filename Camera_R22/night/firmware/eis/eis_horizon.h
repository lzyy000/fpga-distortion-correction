/* R30 calibrated-axis crop-aware small-shake controller: short-arc full-3D orientation smoothing.
 * Fixed crop; reduce correction at the source boundary. No future frames. */
static u32 eis_enabled=0,eis_seen=0,eis_last_ms=0;
static u32 eis_limited=0,eis_limit_events=0,eis_safe_failures=0,eis_pole=0,eis_safety_zooms=0;
static u32 eis_path_static=0;
static float eis_smooth_q[4]={1,0,0,0};
static float eis_tau=0.25f,eis_zoom_base=1.18f,eis_zoom_max=2.40f,eis_zoom=1.18f;
static float eis_virtual[9]={1,0,0,0,0,1,0,-1,0};
static float eis_safe[9]={1,0,0,0,0,1,0,-1,0},eis_safe_zoom=1.16f;
static u32 eis_bounds_ready=0,eis_bounds_valid=0;
static float eis_ix,eis_iy,eis_xlo,eis_xhi,eis_ylo,eis_yhi;
static float eis_center[3],eis_oxlo,eis_oxhi,eis_oylo,eis_oyhi;
static float clamp_(float v,float lo,float hi){return v<lo?lo:(v>hi?hi:v);}
static float root_(float n){
 if(n<1e-20f)return 0;
 return n*inverse_root_(n);
}
static int unit3(float*v){
 float n=v[0]*v[0]+v[1]*v[1]+v[2]*v[2];
 if(!finite_(n)||n<0.000000000001f)return 0;
 /* Reciprocal square-root exponent seed plus three Newton refinements. */
 float x=inverse_root_(n);
 for(unsigned i=0;i<3;i++)v[i]*=x;
 return 1;
}
static void cross_(const float*a,const float*b,float*c){
 c[0]=a[1]*b[2]-a[2]*b[1];c[1]=a[2]*b[0]-a[0]*b[2];c[2]=a[0]*b[1]-a[1]*b[0];
}
static int upright_(const float*f,const float*camera,float*out){
 float z[3]={f[0],f[1],f[2]},up[3]={0,0,1},right[3],down[3];
 if(!unit3(z))return 0;
 if(eis_horizon){
  cross_(z,up,right);
  /* At the gravity pole, carry projected previous right: no unique horizon. */
  if(z[0]*z[0]+z[1]*z[1]<0.0001f){
   for(unsigned i=0;i<3;i++)right[i]=eis_ready?eis_virtual[3*i]:camera[3*i];
   float dot=right[0]*z[0]+right[1]*z[1]+right[2]*z[2];
   for(unsigned i=0;i<3;i++)right[i]-=dot*z[i];
  }
 }else for(unsigned i=0;i<3;i++)right[i]=camera[3*i];
 if(!unit3(right))return 0;
 /* With horizon enabled, normalized right is perpendicular to normalized z,
  * including the projected pole branch. Their cross product is already unit.
  * The free-roll mode still needs one orthogonalization normalization. */
 cross_(z,right,down);if(!eis_horizon&&!unit3(down))return 0;
 cross_(down,z,right);
 for(unsigned i=0;i<3;i++){out[i*3]=right[i];out[i*3+1]=down[i];out[i*3+2]=z[i];}return 1;
}
static void refresh_bounds_(void){
 if(eis_bounds_ready)return;
 eis_bounds_ready=1;eis_bounds_valid=0;
 eis_ix=1/intr[0];eis_iy=1/intr[1];
 float xmax=(intr[2]>1919-intr[2]?intr[2]:1919-intr[2])*eis_ix;
 float ymax=(intr[3]>1079-intr[3]?intr[3]:1079-intr[3])*eis_iy;
 float xx=xmax*xmax,yy=ymax*ymax,rr=xx+yy;
 float delta=absolute(intr[4])*rr+absolute(intr[5])*rr*rr+absolute(intr[8])*rr*rr*rr;
 float tx=2*absolute(intr[6])*xmax*ymax+absolute(intr[7])*(rr+2*xx);
 float ty=2*absolute(intr[7])*xmax*ymax+absolute(intr[6])*(rr+2*yy);
 float marginx=14+tx*intr[0],marginy=14+ty*intr[1];
 if(!finite_(delta)||delta>=0.8f||xmax>2||ymax>2||intr[2]<=marginx||intr[2]>=1919-marginx||intr[3]<=marginy||intr[3]>=1079-marginy)return;
 float upper=1+(intr[4]>0?intr[4]:0)*rr+(intr[5]>0?intr[5]:0)*rr*rr+(intr[8]>0?intr[8]:0)*rr*rr*rr;
 float invbound=1/upper;
 eis_xlo=(marginx-intr[2])*eis_ix*invbound;eis_xhi=(1919-marginx-intr[2])*eis_ix*invbound;
 eis_ylo=(marginy-intr[3])*eis_iy*invbound;eis_yhi=(1079-marginy-intr[3])*eis_iy*invbound;
 /* Center the virtual view in usable source rays, not the off-center K. */
 eis_center[0]=(eis_xlo+eis_xhi)*0.5f;eis_center[1]=(eis_ylo+eis_yhi)*0.5f;eis_center[2]=1;unit3(eis_center);
 eis_oxlo=-959.5f*eis_ix;eis_oxhi=960.5f*eis_ix;
 eis_oylo=-539.5f*eis_iy;eis_oyhi=548.5f*eis_iy;eis_bounds_valid=1;
}
static void crop_inverse_(float zoom,float*out){
 refresh_bounds_();float invzoom=1/zoom;
 for(unsigned i=0;i<9;i++)out[i]=0;
 out[0]=eis_ix*invzoom;out[4]=eis_iy*invzoom;out[8]=1;
 out[2]=-959.5f*out[0];out[5]=-539.5f*out[4];
}
static void crop_planes_(const float*camera,const float*target,float zoom,float*out){
 /* Bounds are initialized by eis_step_ before the hot geometry path. */
 if(!eis_bounds_ready||!eis_bounds_valid||!finite_(zoom)||zoom<=0){for(unsigned j=0;j<5;j++)out[j]=-100;return;}
 float rt[9],r[9];transpose(camera,rt);mul3(rt,target,r);
 /* The same five source half-spaces as required_zoom_. Compare A*zoom+B
  * directly, avoiding four corner projections and all soft-float divides. */
 for(unsigned j=0;j<5;j++){
  float a[3];for(unsigned i=0;i<3;i++){
   if(j==0)a[i]=r[i]-eis_xlo*r[6+i];
   else if(j==1)a[i]=eis_xhi*r[6+i]-r[i];
   else if(j==2)a[i]=r[3+i]-eis_ylo*r[6+i];
   else if(j==3)a[i]=eis_yhi*r[6+i]-r[3+i];
   else a[i]=r[6+i]-(i==2?0.1f:0);
  }
  float x=a[0]*(a[0]<0?eis_oxhi:eis_oxlo),y=a[1]*(a[1]<0?eis_oyhi:eis_oylo);
  float margin=a[2]*zoom+x+y;out[j]=finite_(margin)?margin:-100;
 }
}
static int crop_fits_(const float*camera,const float*target,float zoom){
 float margins[5];crop_planes_(camera,target,zoom,margins);
 for(unsigned j=0;j<5;j++)if(margins[j]<0)return 0;
 return 1;
}
static float required_zoom_(const float*camera,const float*target){
 if(!eis_bounds_ready||!eis_bounds_valid)return 100;
 float rt[9],r[9];transpose(camera,rt);mul3(rt,target,r);float zoom=1;
 /* Each lens edge is A+B/zoom>=0. Solve all five half-spaces directly. */
 for(unsigned j=0;j<5;j++){
  float a[3];for(unsigned i=0;i<3;i++){
   if(j==0)a[i]=r[i]-eis_xlo*r[6+i];
   else if(j==1)a[i]=eis_xhi*r[6+i]-r[i];
   else if(j==2)a[i]=r[3+i]-eis_ylo*r[6+i];
   else if(j==3)a[i]=eis_yhi*r[6+i]-r[3+i];
   else a[i]=r[6+i]-(i==2?0.1f:0);
  }
  if(!finite_(a[2])||a[2]<0.000001f)return 100;
  float x=a[0]*(a[0]<0?eis_oxhi:eis_oxlo),y=a[1]*(a[1]<0?eis_oyhi:eis_oylo);
  float need=-(x+y)/a[2];if(need>zoom)zoom=need;
 }
 return zoom*1.004f+0.008f;
}
/* Largest-component extraction stays well conditioned at 180-degree rolls. */
static int frame_quaternion_(const float*r,float*q){
 float d[4]={1+r[0]+r[4]+r[8],1+r[0]-r[4]-r[8],1-r[0]+r[4]-r[8],1-r[0]-r[4]+r[8]};
 unsigned k=0;for(unsigned i=1;i<4;i++)if(d[i]>d[k])k=i;
 if(!finite_(d[k])||d[k]<.5f)return 0;
 float t=root_(d[k]),s=.5f/t;q[k]=.5f*t;
 if(k==0){q[1]=(r[7]-r[5])*s;q[2]=(r[2]-r[6])*s;q[3]=(r[3]-r[1])*s;}
 else if(k==1){q[0]=(r[7]-r[5])*s;q[2]=(r[1]+r[3])*s;q[3]=(r[2]+r[6])*s;}
 else if(k==2){q[0]=(r[2]-r[6])*s;q[1]=(r[1]+r[3])*s;q[3]=(r[5]+r[7])*s;}
 else {q[0]=(r[3]-r[1])*s;q[1]=(r[2]+r[6])*s;q[2]=(r[5]+r[7])*s;}
 unit4_(q);return 1;
}
static void blend_rotation_(const float*a,const float*b,float t,float*q){
 float dot=0;for(unsigned i=0;i<4;i++)dot+=a[i]*b[i];
 float sign=dot<0?-1:1;
 for(unsigned i=0;i<4;i++)q[i]=a[i]+t*(sign*b[i]-a[i]);
 unit4_(q);
}
static void product_q_(const float*a,const float*b,float*out){
 float q[4]={a[0]*b[0]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3],
 a[0]*b[1]+a[1]*b[0]+a[2]*b[3]-a[3]*b[2],
 a[0]*b[2]+a[2]*b[0]+a[3]*b[1]-a[1]*b[3],
 a[0]*b[3]+a[3]*b[0]+a[1]*b[2]-a[2]*b[1]};
 for(unsigned i=0;i<4;i++)out[i]=q[i];
}
/* Pitch/roll retain the proven tau. Only the error projected onto the actual
 * source-camera Y axis gets the separate yaw retention and wider crop budget. */
static u32 horizontal_smooth_(const float*current,const float*camera,float dt,float*candidate){
 float inv[4]={current[0],-current[1],-current[2],-current[3]},e[4];
 product_q_(candidate,inv,e);if(e[0]<0)for(unsigned i=0;i<4;i++)e[i]=-e[i];
 float yaw=e[1]*camera[1]+e[2]*camera[4]+e[3]*camera[7];
 float extra=eis_yaw_tau*(eis_tau+dt)/(eis_tau*(eis_yaw_tau+dt))-1;
 for(unsigned i=0;i<3;i++)e[i+1]+=extra*yaw*camera[3*i+1];
 unit4_(e);
 yaw=e[1]*camera[1]+e[2]*camera[4]+e[3]*camera[7];
 float v2=e[1]*e[1]+e[2]*e[2]+e[3]*e[3],budget=v2-(5.0f/9)*yaw*yaw;
 u32 limited=budget>.00030458649f;
 if(limited){float gain=.017452406f/root_(budget);for(unsigned i=1;i<4;i++)e[i]*=gain;e[0]=root_(1-v2*gain*gain);}
 product_q_(e,current,candidate);unit4_(candidate);return limited;
}
static __attribute__((noinline)) void eis_step_(const float*camera,u32 serial,u32 now){
 if(!eis_enabled){eis_ready=0;eis_limited=0;eis_zoom=1;return;}
 if(eis_ready&&serial==eis_seen)return;
 refresh_bounds_();
 if(!eis_bounds_valid){eis_ready=0;eis_safe_failures++;return;}
 float dt=clamp_((now-eis_last_ms)*.001f,.005f,.2f);
 u32 reset=!eis_ready||now-eis_last_ms>500;
 eis_seen=serial;eis_last_ms=now;
 float raw[3],current[4],candidate[4],desired[9];
 for(unsigned i=0;i<3;i++)raw[i]=camera[3*i]*eis_center[0]+camera[3*i+1]*eis_center[1]+camera[3*i+2]*eis_center[2];
 /* Horizon OFF takes right/down from this source frame. At initialization the
  * relative mapping is near identity at ANY absolute orientation, not upright
  * in a guessed gravity frame. Roll is then smoothed with pitch and yaw. */
 if(!upright_(raw,camera,eis_safe)||!frame_quaternion_(eis_safe,current)){
  eis_ready=0;eis_safe_failures++;return;
 }
 if(reset)for(unsigned i=0;i<4;i++)candidate[i]=current[i];
 else blend_rotation_(eis_smooth_q,current,dt/(eis_tau+dt),candidate);
 u32 limited=reset?0:horizontal_smooth_(current,camera,dt,candidate);
 if(!quaternion(candidate,desired)){eis_ready=0;eis_safe_failures++;return;}
 /* Fixed crop in normal shake mode. Do not pump zoom with every vibration;
  * spend the reserved pixels and reduce smoothing when they are exhausted. */
 float minimum=required_zoom_(camera,eis_safe);
 eis_zoom=clamp_(minimum>eis_zoom_base?minimum:eis_zoom_base,eis_zoom_base,3);
 eis_safe_zoom=eis_zoom;if(minimum>eis_zoom_max)limited|=1;
 if(minimum>eis_zoom_base)eis_safety_zooms++;
 float inset=(eis_zoom-.008f)/1.004f,hi[5];crop_planes_(camera,desired,inset,hi);
 /* Round the horizontal crop constraint before crossing it. t is the
  * safe-to-requested correction fraction at the actual lens half-space.
  * C1 min(1,t): exact below .8 / above 1.2, quadratic in between.
  * Accepted orientation feeds the next causal step, with no zoom pumping. */
 float lo[5],blend=1;crop_planes_(camera,eis_safe,inset,lo);u32 retreat=0;
 for(unsigned j=0;j<5;j++){
  if(lo[j]<0){blend=0;retreat=1;limited|=2;}
  else if(hi[j]<0||(j<2&&hi[j]<lo[j]/6)){
   float t=lo[j]/(lo[j]-hi[j]);
   if(hi[j]<0)limited|=2;
   if(j<2&&t>.8f){float d=1.2f-t;t=1-d*d*1.25f;limited|=8;}
   if(t<blend)blend=t;
   retreat=1;
  }
 }
 if(retreat){
  float previous[4];for(unsigned i=0;i<4;i++)previous[i]=candidate[i];
  blend_rotation_(current,previous,clamp_(blend*(.98f+.02f*blend),0,1),candidate);
  quaternion(candidate,desired);
  if(!crop_fits_(camera,desired,eis_zoom)){
   for(unsigned i=0;i<4;i++)candidate[i]=current[i];
   for(unsigned i=0;i<9;i++)desired[i]=eis_safe[i];
   limited|=4;
   if(!crop_fits_(camera,desired,eis_zoom)){eis_ready=0;eis_safe_failures++;return;}
  }
 }
 // No retreat: the tighter inset already passed every plane. After retreat:
 // rebuilt target (or safe fallback) was checked above. Avoid duplicate work.
 for(unsigned i=0;i<4;i++)eis_smooth_q[i]=candidate[i];
 for(unsigned i=0;i<9;i++)eis_virtual[i]=desired[i];
 eis_pole=0;eis_path_static=0;
 if((limited&7)&&!(eis_limited&7))eis_limit_events++;
 eis_limited=limited;eis_ready=1;
}
