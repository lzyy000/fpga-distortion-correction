/* R30: retained 1920x1080 Brown profile; effective UART axes calibrated
 * by level-yaw recording and live user comparison. Physical shell markings
 * and current reported sensor axes must be documented separately. */
typedef signed int i32;
#define DS 0xac00u
#define DC 0xb200u
static float brown_intr[9]={4383.048459913422f,4397.110808230781f,618.7274456760334f,473.1526544327547f,
 -0.3997741926679854f,0.09760729232094031f,-0.0004826990017120017f,-0.0025286659938627922f,1.227618554012662f};
#include "fisheye_profile.h"
static float *intr=brown_intr;
/* Measured UART axes: reported Z is camera yaw, X is pitch.
 * Camera right=+X, down=-Z, optical forward=+Y in reported coordinates. */
static float mount[9]={1,0,0,0,0,1,0,-1,0};
static u32 mount_standard=0;
static float pose[9]={1,0,0,0,1,0,0,0,1},reference[9]={1,0,0,0,1,0,0,0,1};
static float map_pose[9]={1,0,0,0,1,0,0,0,1};
static float map_camera[9]={1,0,0,0,-1,0,0,0,-1};
static float latest_qv[4]={1,0,0,0};
static u32 have_q=0,prediction_ms=0;
/* Small-shake mode uses relative rotation, with no absolute gravity horizon. */
static const u32 eis_horizon=0;
static u32 eis_ready=0;
static float eis_yaw_tau=.50f,rs_strength=1,frame_yaw_rate=0;
static i32 rs_readout_override_us=0;

static u32 prediction_gyro_fresh=0;
static float manual_h[9]={1,0,0,0,1,0,0,0,1};
static u32 mode=0,have_ref=0,have_pose=0,pose_ms=0,last_q=0,last_q_ms=0,host_seen=0;
static u32 dirty=1,ref_request=1,config_version=0,pose_timeout=1;
static u32 pose_serial=0,solve_ms=0,solve_max_ms=0;
static u32 job_lens=0,job_fisheye=0,job_rotation=0,host_command_ok=1;
static void tuning_reply(u32 cmd);
static u32 trace_primary_h[9];

static float absolute(float x){return x<0?-x:x;}
static int finite_(float x){union{float f;u32 u;}v;v.f=x;return (v.u&0x7f800000u)!=0x7f800000u;}
static float inverse_root_(float n){
 union{float f;u32 u;}a;a.f=n;
 /* Already-unit vectors dominate this controller. One Newton step from 1
  * has <4e-7 relative error on [0.999,1.001]; avoid three general iterations. */
 if(a.u>=0x3f7fbe77u&&a.u<=0x3f8020c4u)return 1.5f-.5f*n;
 a.u=0x5f375a86u-(a.u>>1);float x=a.f;
 for(unsigned i=0;i<3;i++)x*=1.5f-.5f*n*x*x;
 return x;
}
static void mul3(const float*a,const float*b,float*c){
 /* Fixed-size dot products avoid nine add-to-zero operations and the inner
  * loop in software floating point. Keep the temporary for alias safety. */
 float out[9];
 out[0]=(a[0]*b[0]+a[1]*b[3])+a[2]*b[6];
 out[1]=(a[0]*b[1]+a[1]*b[4])+a[2]*b[7];
 out[2]=(a[0]*b[2]+a[1]*b[5])+a[2]*b[8];
 out[3]=(a[3]*b[0]+a[4]*b[3])+a[5]*b[6];
 out[4]=(a[3]*b[1]+a[4]*b[4])+a[5]*b[7];
 out[5]=(a[3]*b[2]+a[4]*b[5])+a[5]*b[8];
 out[6]=(a[6]*b[0]+a[7]*b[3])+a[8]*b[6];
 out[7]=(a[6]*b[1]+a[7]*b[4])+a[8]*b[7];
 out[8]=(a[6]*b[2]+a[7]*b[5])+a[8]*b[8];
 for(unsigned i=0;i<9;i++)c[i]=out[i];
}
static void transpose(const float*a,float*b){for(unsigned i=0;i<3;i++)for(unsigned j=0;j<3;j++)b[i*3+j]=a[j*3+i];}
static void camera_mount_(const float*p,float*c){
 if(mount_standard){for(unsigned i=0;i<3;i++){
  float x=p[i*3],y=p[i*3+1],z=p[i*3+2];c[i*3]=x;c[i*3+1]=-y;c[i*3+2]=-z;
 }}else mul3(p,mount,c);
}
static void right_intrinsic_(const float*h,const float*k,float*out){
 /* k has only diagonal focal terms, a principal-point column and k[8]=1.
  * Omit products with known zeros; preserve the original addition order. */
 for(unsigned r=0;r<3;r++){
  out[r*3]=h[r*3]*k[0];out[r*3+1]=h[r*3+1]*k[4];
  out[r*3+2]=(h[r*3]*k[2]+h[r*3+1]*k[5])+h[r*3+2];
 }
}
static __attribute__((noinline)) int quaternion(float*q,float*r){
 float n=0;for(unsigned i=0;i<4;i++){if(!finite_(q[i]))return 0;n+=q[i]*q[i];}
 if(n<0.25f||n>2.0f)return 0;
 float w=q[0],x=q[1],y=q[2],z=q[3],s=2/n;
 r[0]=1-s*(y*y+z*z);r[1]=s*(x*y-w*z);r[2]=s*(x*z+w*y);
 r[3]=s*(x*y+w*z);r[4]=1-s*(x*x+z*z);r[5]=s*(y*z-w*x);
 r[6]=s*(x*z-w*y);r[7]=s*(y*z+w*x);r[8]=1-s*(x*x+y*y);return 1;
}
static void set_pose(const float*r,u32 sample_ms){for(unsigned i=0;i<9;i++)pose[i]=r[i];pose_ms=sample_ms;have_pose=1;pose_serial++;}
static void remember_quaternion_(float*q,u32 sample_ms){
 (void)sample_ms;
 if(have_q){
  float dot=0;for(unsigned i=0;i<4;i++)dot+=q[i]*latest_qv[i];
  if(dot<0)for(unsigned i=0;i<4;i++)q[i]=-q[i];
 }
 for(unsigned i=0;i<4;i++)latest_qv[i]=q[i];
 have_q=1;
}
#include "gyro_pose.h"
#include "eis_horizon.h"
#include "rotation_control.h"
static void select_lens_profile_(void){
 float *wanted=job_fisheye?fisheye_intr:brown_intr;
 if(intr!=wanted){intr=wanted;eis_bounds_ready=0;eis_bounds_valid=0;eis_ready=0;rot_ready=0;}
}
static __attribute__((noinline)) void control_commit(u32 now){
 float hn[9],h[9],rt[9],camera[9],inversek[9]={1/intr[0],0,-intr[2]/intr[0],0,1/intr[1],-intr[3]/intr[1],0,0,1};
 if(job_fisheye&&!eis_enabled&&!job_rotation){
  inversek[0]=1/fisheye_output[0];inversek[4]=1/fisheye_output[1];
  inversek[2]=-fisheye_output[2]/fisheye_output[0];inversek[5]=-fisheye_output[3]/fisheye_output[1];
 }
 u32 timed=mode==0&&(!frame_pose_valid||!have_pose||now-pose_ms>500);
 if(timed!=pose_timeout){pose_timeout=timed;dirty=1;}
 if(!dirty)return;
 int active=(eis_enabled||job_rotation)&&mode==0&&!timed&&(job_rotation?rot_ready:eis_ready);
 float base_zoom=job_rotation?rot_zoom_base:eis_zoom_base,current_zoom=job_rotation?rot_zoom:eis_zoom;
 float safe_zoom=job_rotation?rot_safe_zoom:eis_safe_zoom;
 const float *target=job_rotation?rot_virtual:eis_virtual,*safe_target=job_rotation?rot_safe:eis_safe;
 u32 limited=job_rotation?rot_limited:eis_limited;
 if(eis_enabled||job_rotation)crop_inverse_(active?current_zoom:base_zoom,inversek);
 if(mode==2){ /* Explicit inverse pixel homography / affine command. */
  for(unsigned i=0;i<3;i++){
   hn[i]=(manual_h[i]-intr[2]*manual_h[6+i])/intr[0];
   hn[3+i]=(manual_h[3+i]-intr[3]*manual_h[6+i])/intr[1];hn[6+i]=manual_h[6+i];
  }
 } else if(mode==3||timed||!have_ref||(mode==0&&!active)){for(unsigned i=0;i<9;i++)hn[i]=inversek[i];}
 else {
  if(active){for(unsigned i=0;i<9;i++)camera[i]=map_camera[i];}else camera_mount_(pose,camera);
  transpose(camera,rt);mul3(rt,active?target:reference,h);right_intrinsic_(h,inversek,hn);
 }
 /* A positive projective scale keeps integer coefficients in signed Q24. */
 float scale=absolute(hn[8])/(mode==2?1:8);if(scale<0.0625f)scale=0.0625f;
 for(unsigned i=0;i<9;i++){
  float f=hn[i]/scale;if(!finite_(f)||absolute(f)>120)return;
  trace_primary_h[i]=(u32)(i32)(f*16777216.0f);REG(DC+i*4)=trace_primary_h[i];
 }
 for(unsigned i=0;i<4;i++)REG(DC+(9+i)*4)=(u32)(i32)(intr[i]*256);
 for(unsigned i=0;i<5;i++)REG(DC+(13+i)*4)=job_fisheye?(i==4?FISHEYE_CONFIG_TAG:(u32)(i32)(fisheye_dist[i]*1048576)):(u32)(i32)((job_lens?intr[4+i]:0)*1048576);
 /* Frame-local fallback keeps source orientation and the measured lens in shake mode. */
 float safe[9],ki[9];
 if(active&&safe_zoom==current_zoom){for(unsigned i=0;i<9;i++)ki[i]=inversek[i];}
 else crop_inverse_(active?safe_zoom:((eis_enabled||job_rotation)?base_zoom:1),ki);
 if(active){mul3(rt,safe_target,h);right_intrinsic_(h,ki,safe);}else for(unsigned i=0;i<9;i++)safe[i]=ki[i];
 for(unsigned i=0;i<9;i++)REG(DC+(18+i)*4)=(u32)(i32)(safe[i]*134217728.0f);
 /* cfg[27]: enable, hard LIMIT, RS, reason[3:0], RS-rate clip, slope[23:0].
  * Reasons: angle=1, crop retreat=2, safe fallback=4, soft yaw feedback=8. */
 u32 flags=active?(1u|((limited&7)?2u:0u)|((limited&15)<<3)):0;
 i32 span=rs_readout_override_us?rs_readout_override_us:(i32)REG(0xb2c4u);
 float row_strength=job_rotation?rot_rs_strength:rs_strength;
 if(active&&row_strength>0&&span>=-50000&&span<=50000&&absolute((float)span)>=5000){
  float total=frame_yaw_rate*(float)span*.000001f*row_strength;
  if(absolute(total)>.0261799388f)flags|=128u;
  float angle=clamp_(total,-.0261799388f,.0261799388f);
  i32 slope=(i32)(angle*(1073741824.0f/1079.0f));
  if(slope)flags|=4u|((u32)slope<<8);
 }
 REG(DC+27*4)=flags;
 REG(0xb2a0u)=(timed?8u:0u)|(active?1u:0u)|((limited&7)?2u:0u);
 REG(0xb280u)=++config_version;dirty=0;
}
/* Framed FF45 commands are isolated by hardware from legacy one-byte modes.
 * Only the reviewed small-shake controls are exposed in this integration. */
static __attribute__((noinline)) void host_poll_(u32 now){
 (void)now;u32 hc=REG(DS+64);
 if(hc==host_seen)return;
 u32 hd=REG(DS+68),op=hd&255,len=(hd>>8)&255,seq=(hd>>16)&255;float v[24];int ok=1;
 for(unsigned i=0;i<(len+3)/4;i++){union{u32 u;float f;}a;a.u=REG(DS+128+i*4);v[i]=a.f;}
 if(op==8&&len==20){
  for(unsigned i=0;i<5;i++)if(!finite_(v[i]))ok=0;
  if(v[0]!=0||v[1]!=0||v[2]<1.05f||v[2]>1.60f||v[3]!=2.4f||v[4]<.1f||v[4]>1.5f)ok=0;
  if(ok){eis_zoom_base=v[2];eis_zoom_max=v[3];eis_tau=v[4];eis_ready=0;dirty=1;}
 }else if(op==11&&len==4){
  if(!finite_(v[0])||v[0]<.1f||v[0]>1.5f)ok=0;
  else {eis_yaw_tau=v[0];eis_ready=0;}
 }else if(op==12&&len==8){
  if(!finite_(v[0])||!finite_(v[1])||absolute(v[0])>50000||v[1]<0||v[1]>1)ok=0;
  else {rs_readout_override_us=(i32)v[0];rs_strength=v[1];}
 }else if(op==13&&len==20){
  for(unsigned i=0;i<5;i++)if(!finite_(v[i]))ok=0;
  if(v[0]<1.05f||v[0]>2.5f||v[1]<v[0]||v[1]>3||v[2]<.1f||v[2]>3||(v[3]!=0&&v[3]!=1)||v[4]<0||v[4]>1)ok=0;
  if(ok){rot_zoom_base=v[0];rot_zoom_max=v[1];rot_tau=v[2];rot_horizon=(u32)v[3];rot_rs_strength=v[4];rot_zoom_milli=(u32)(v[0]*1000+.5f);rot_max_zoom_milli=(u32)(v[1]*1000+.5f);rot_tau_ms=(u32)(v[2]*1000+.5f);rot_rs_milli=(u32)(v[4]*1000+.5f);rot_ready=0;}
 }else if(op==10&&len==8){
  if(!finite_(v[0])||!finite_(v[1])||absolute(v[0])>50000||absolute(v[1])>50000)ok=0;
  else {imu_delay_us=(i32)v[0];frame_offset_us=(i32)v[1];gyro_ready=gyro_count=0;eis_ready=0;}
 }else ok=0;
 host_seen=hc;host_command_ok=ok;tuning_reply(0x100u|seq);
}
static void dynamic_poll(void){
#ifndef EIS_PHASE
#define EIS_PHASE(a) ((void)0)
#endif
 EIS_PHASE(0x9240u);
 u32 now=REG(MSEC),did_solve=0;
 u32 requested=(REG(CTRL+228)>>5)&1u;
 if(requested!=eis_enabled){eis_enabled=requested;eis_ready=0;ref_request=1;dirty=1;}
 u32 rotation_request=(REG(CTRL+228)>>7)&1u;
 if(rotation_request&&!rot_enabled){rot_ready=0;rotation_up_ready=0;rotation_pose_seen=0;}rot_enabled=rotation_request;
 tx_poll();
 if(mode==0&&REG(DS+8)<=500){
  u32 qn=REG(DS+28);float r[9];
  if(qn!=last_q){
   u32 a=REG(DS+20),b=REG(DS+24);
   if(qn==REG(DS+28)){
    float q[4]={(short)a/32768.0f,(short)(a>>16)/32768.0f,(short)b/32768.0f,(short)(b>>16)/32768.0f};
    if(quaternion(q,r)){
     u32 qa=REG(DS+76);u32 sample_ms=qa<=500?now-qa:now;
     remember_quaternion_(q,sample_ms);set_pose(r,sample_ms);last_q_ms=now;
    }last_q=qn;
   }
  }
 }
 if(mode==0)gyro_fifo_poll_();
 host_poll_(now);
 if(ref_request&&have_pose){camera_mount_(pose,reference);have_ref=1;ref_request=0;dirty=1;eis_ready=0;puts_("REFERENCE SET\r\n");}
 /* Solve only completed source-frame jobs. The job's generation guards
  * against stale CPU writes after slot reuse. All modes obey this rendezvous. */
 u32 job=REG(0xb2b0u);
 if(job){
  u32 sof=REG(0xb2b4u);if(job!=REG(0xb2b0u))return;
  u32 job_flags=REG(0xb2d0u);job_lens=job_flags&1u;job_fisheye=(job_flags>>1)&1u;select_lens_profile_();
  job_rotation=(job_flags>>3)&1u;
  u32 job_eis=!job_rotation&&(!job_fisheye||((job_flags>>2)&1u)),job_motion=job_eis||job_rotation;frame_token=job;frame_target_us=sof+(u32)frame_offset_us;
  int aligned=job_motion?(mode==0?frame_pose_(frame_target_us,map_pose):1):0;
  if(job_motion&&mode==0&&aligned==0&&gyro_ready&&gyro_count>=2&&(i32)(REG(DS+0x118)-sof)<120000)return;
  // Jobs capture EIS and/or fisheye. A later host OFF must
  // affect new grants, not silently turn an already leased frame into bypass.
  u32 live_enabled=eis_enabled,live_rotation=rot_enabled;eis_enabled=job_eis;rot_enabled=job_rotation;
  frame_pose_valid=aligned==1;
  if(job_motion&&mode==0){
   if(frame_pose_valid){
    u32 step=frame_target_us-previous_frame_us;previous_frame_us=frame_target_us;
    frame_clock_ms+=step<=500000?step/1000:1000;
    camera_mount_(map_pose,map_camera);
    if(job_rotation){
     if(rotation_gravity_(REG(MSEC))){float world_pose[9];mul3(rotation_basis,map_pose,world_pose);camera_mount_(world_pose,map_camera);rotation_step_(map_camera,job,frame_clock_ms);rot_actual_zoom_milli=(u32)(rot_zoom*1000+.5f);}else rot_ready=0;
    }else eis_step_(map_camera,job,frame_clock_ms);
   }else {if(job_rotation)rot_ready=0;else eis_ready=0;frame_sync_failures++;}
  }
  dirty=1;REG(0xb2b8u)=job;control_commit(now);eis_enabled=live_enabled;rot_enabled=live_rotation;did_solve=1;
 }
 EIS_PHASE(0x9258u);
 if(did_solve){solve_ms=REG(MSEC)-now;if(solve_ms>solve_max_ms)solve_max_ms=solve_ms;}
 tx_poll();EIS_PHASE(0x925cu);
}
