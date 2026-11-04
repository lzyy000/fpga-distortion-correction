/* R27: integrate every queued WT901C gyro sample, then interpolate at the
 * source frame time. Packet arrival is NOT physical sample/exposure time:
 * imu_delay_us and frame_offset_us require rig calibration. No display lead.
 * Independent implementation of the integration/interpolation stages described
 * by RidgeRun; no proprietary library source or GPU runtime is included. */
#define GYRO_HISTORY 12
typedef signed long long gyro_i64;
#define GYRO_ONE 1073741824
static float gyro_bias[3]={0,0,0};
static i32 gyro_q30[4]={GYRO_ONE,0,0,0},gyro_previous[3],gyro_bias_q16[3]={0,0,0};
static float bias_sum[3],bias_anchor[4]={1,0,0,0};
static u32 bias_start_ms=0,bias_count=0,bias_updates=0,gyro_ready=0;
static u32 gyro_last_us=0,gyro_samples=0,gyro_overflows=0,gyro_gaps=0;
static float gyro_history[GYRO_HISTORY][4];static u32 gyro_times[GYRO_HISTORY];
static u32 gyro_head=0,gyro_count=0,gyro_epoch=0;
/* 0 ms was preferred to 16 ms in live comparison; exposure calibration
 * remains pending. This changes the sampling time, not camera exposure. */
static i32 imu_delay_us=0,frame_offset_us=0;
static u32 frame_token=0,frame_target_us=0,frame_pose_valid=0,frame_sync_failures=0;
static u32 frame_clock_ms=0,previous_frame_us=0;
static void unit4_(float*q){
 float n=0;for(unsigned i=0;i<4;i++)n+=q[i]*q[i];
 float s=inverse_root_(n);for(unsigned i=0;i<4;i++)q[i]*=s;
}
static void gyro_turn_(const float*q,const float*g,float dt,float*out){
 float x=g[0]*dt*.5f,y=g[1]*dt*.5f,z=g[2]*dt*.5f;
 float n=x*x+y*y+z*z,w=1-.5f*n,s=1-n*(1.0f/6);x*=s;y*=s;z*=s;
 float a[4]={q[0]*w-q[1]*x-q[2]*y-q[3]*z,q[0]*x+q[1]*w+q[2]*z-q[3]*y,
  q[0]*y-q[1]*z+q[2]*w+q[3]*x,q[0]*z+q[1]*y-q[2]*x+q[3]*w};
 for(unsigned i=0;i<4;i++)out[i]=a[i];
}
static void gyro_bias_step_(u32 now,const float*raw){
 float d2=0;for(unsigned i=0;i<4;i++){float d=latest_qv[i]-bias_anchor[i];d2+=d*d;}
 u32 quiet=1;for(unsigned i=0;i<3;i++)if(absolute(raw[i]-gyro_bias[i])>(bias_updates?8:64)||absolute(raw[i])>64)quiet=0;
 if(!bias_count||!quiet||d2>0.0000002742f){
  bias_start_ms=now;bias_count=0;for(unsigned i=0;i<3;i++)bias_sum[i]=0;
  for(unsigned i=0;i<4;i++)bias_anchor[i]=latest_qv[i];
 }
 if(!quiet)return;
 for(unsigned i=0;i<3;i++)bias_sum[i]+=raw[i];
 bias_count++;
 if(now-bias_start_ms>=2000&&bias_count>=60){
  for(unsigned i=0;i<3;i++){float mean=bias_sum[i]/(float)bias_count;gyro_bias[i]=bias_updates?gyro_bias[i]+.2f*(mean-gyro_bias[i]):mean;}
  if(!bias_updates)gyro_ready=gyro_count=0;
  bias_updates++;bias_count=0;
 }
}
/* Q30 quaternion, Q16 raw-LSB bias/rate. Integer RV32IM products avoid
 * software-float integration at every IMU sample. Conversion to float happens
 * only when retaining history / applying slow quiet gravity correction.
 * Checked domain: <32700 raw LSB, <=50ms gap, <=0.25rad half increment. */
static void gyro_sample_(u32 t,u32 xy,u32 zz,u32 acc_xy,u32 acc_zz,u32 acc_age){
 i32 raw[3]={(short)xy,(short)(xy>>16),(short)zz},g[3],d[3];
 for(unsigned i=0;i<3;i++)if(raw[i]<=-32700||raw[i]>=32700){gyro_ready=gyro_count=0;gyro_gaps++;return;}
 if(!(gyro_samples&1u)){
  float v[3]={(float)raw[0],(float)raw[1],(float)raw[2]};gyro_bias_step_(t/1000,v);
  for(unsigned i=0;i<3;i++)gyro_bias_q16[i]=(i32)(gyro_bias[i]*65536);
 }
 u32 gap=t-gyro_last_us,quiet=1;
 for(unsigned i=0;i<3;i++){
  g[i]=raw[i]*65536-gyro_bias_q16[i];
  if(g[i]<-1200000||g[i]>1200000)quiet=0;
 }
 if(!gyro_ready||gap>50000){
  gyro_epoch++;gyro_count=0;
  float q[4]={1,0,0,0};
  if(eis_horizon){
   if(acc_age>30)return;
   float ax=(short)acc_xy,ay=(short)(acc_xy>>16),az=(short)acc_zz,n=ax*ax+ay*ay+az*az;
   if(n<2684354||n>6039798)return;
   q[0]=n*inverse_root_(n)+az;q[1]=ay;q[2]=-ax;
   if(absolute(q[0])+absolute(q[1])+absolute(q[2])<.01f)q[1]=1;
   unit4_(q);
  }
  /* The arbitrary world basis cancels from camera^-1 * virtual-camera.
   * Linear acceleration / gravity polarity must not turn the output over. */
  for(unsigned i=0;i<4;i++)gyro_q30[i]=(i32)(q[i]*GYRO_ONE);
  eis_ready=0;
  if(gyro_ready)gyro_gaps++;
  gyro_ready=1;
 }else if(gap){
  for(unsigned i=0;i<3;i++){
   i32 mean_q8=(i32)(((gyro_i64)g[i]+gyro_previous[i])>>9);
   d[i]=(i32)(((gyro_i64)mean_q8*gap*599691)>>28);
  }
  gyro_i64 n=((gyro_i64)d[0]*d[0]+(gyro_i64)d[1]*d[1]+(gyro_i64)d[2]*d[2])>>30;
  if(n>GYRO_ONE/16){gyro_ready=gyro_count=0;gyro_gaps++;return;}
  i32 w=GYRO_ONE-(i32)(n>>1),scale=GYRO_ONE-(i32)n/6;
  for(unsigned i=0;i<3;i++)d[i]=(i32)(((gyro_i64)d[i]*scale)>>30);
  i32 a=gyro_q30[0],b=gyro_q30[1],c=gyro_q30[2],e=gyro_q30[3],x=d[0],y=d[1],z=d[2];
  gyro_q30[0]=(i32)(((gyro_i64)a*w-(gyro_i64)b*x-(gyro_i64)c*y-(gyro_i64)e*z)>>30);
  gyro_q30[1]=(i32)(((gyro_i64)a*x+(gyro_i64)b*w+(gyro_i64)c*z-(gyro_i64)e*y)>>30);
  gyro_q30[2]=(i32)(((gyro_i64)a*y-(gyro_i64)b*z+(gyro_i64)c*w+(gyro_i64)e*x)>>30);
  gyro_q30[3]=(i32)(((gyro_i64)a*z+(gyro_i64)b*y-(gyro_i64)c*x+(gyro_i64)e*w)>>30);
 }
 gyro_i64 norm=0;for(unsigned i=0;i<4;i++)norm+=(gyro_i64)gyro_q30[i]*gyro_q30[i];
 i32 scale=(i32)(((3LL<<30)-(norm>>30))>>1);
 float q[4];for(unsigned i=0;i<4;i++){
  gyro_q30[i]=(i32)(((gyro_i64)gyro_q30[i]*scale)>>30);q[i]=(float)gyro_q30[i]*(1.0f/GYRO_ONE);
 }
 if(eis_horizon&&quiet&&gap&&gap<=50000&&gyro_count&&bias_count>=60&&acc_age<=30){
  float ax=(short)acc_xy,ay=(short)(acc_xy>>16),az=(short)acc_zz,n=ax*ax+ay*ay+az*az;
  if(n>=2684354&&n<=6039798){
   float inv=inverse_root_(n);ax*=inv;ay*=inv;az*=inv;
   float w=q[0],x=q[1],y=q[2],z=q[3],up[3]={2*(x*z-w*y),2*(y*z+w*x),1-2*(x*x+y*y)};
   float gain=(float)gap/((float)gap+750000),c[3]={gain*(ay*up[2]-az*up[1]),gain*(az*up[0]-ax*up[2]),gain*(ax*up[1]-ay*up[0])};
   gyro_turn_(q,c,1,q);unit4_(q);
   for(unsigned i=0;i<4;i++)gyro_q30[i]=(i32)(q[i]*GYRO_ONE);
  }
 }
 gyro_last_us=t;for(unsigned i=0;i<3;i++)gyro_previous[i]=g[i];
 for(unsigned i=0;i<4;i++)gyro_history[gyro_head][i]=q[i];
 gyro_times[gyro_head]=t;
 if(++gyro_head==GYRO_HISTORY)gyro_head=0;
 if(gyro_count<GYRO_HISTORY)gyro_count++;
 gyro_samples++;
}
static __attribute__((noinline)) void gyro_fifo_poll_(void){
 u32 overflow=REG(DS+0x114),n=REG(DS+0x100),now=REG(DS+0x118)-(u32)imu_delay_us;
 if(overflow!=gyro_overflows){gyro_overflows=overflow;gyro_ready=gyro_count=0;bias_count=0;}
 if(n>64)n=64;
 for(u32 i=0;i<n;i++){
  u32 t=REG(DS+0x104)-(u32)imu_delay_us,xy=REG(DS+0x108),zz=REG(DS+0x10c);
  u32 ax=REG(DS+0x120),az=REG(DS+0x124),aa=REG(DS+0x128);
  REG(DS+0x110)=1;
  if(have_q&&(i32)(now-t)>=0&&now-t<=150000)gyro_sample_(t,xy,zz,ax,az,aa);
 }
 if(gyro_ready&&(i32)(now-gyro_last_us)>80000){gyro_ready=gyro_count=0;bias_count=0;}
}
/* 1=bracketed, 0=wait for the next sample, -1=history unavailable.
 * Short-arc normalized quaternion interpolation; no unbounded extrapolation. */
static __attribute__((noinline)) int frame_pose_(u32 t,float*out){
 prediction_ms=0;prediction_gyro_fresh=0;frame_yaw_rate=0;
 if(!gyro_ready||gyro_count<2)return 0;
 u32 a=(gyro_head+GYRO_HISTORY-gyro_count)%GYRO_HISTORY;
 if((i32)(t-gyro_times[a])<0)return -1;
 for(u32 n=1;n<gyro_count;n++){
  u32 b=a+1;if(b==GYRO_HISTORY)b=0;
  if((i32)(gyro_times[b]-t)>=0){
   u32 gap=gyro_times[b]-gyro_times[a];if(!gap||gap>50000)return -1;
   float f=(float)(t-gyro_times[a])/(float)gap,q[4],dot=0;
   for(unsigned i=0;i<4;i++)dot+=gyro_history[a][i]*gyro_history[b][i];
   for(unsigned i=0;i<4;i++){float v=gyro_history[b][i];if(dot<0)v=-v;q[i]=gyro_history[a][i]+f*(v-gyro_history[a][i]);}
   const float *qa=gyro_history[a],*qb=gyro_history[b];
   float rate[3]={qa[0]*qb[1]-qa[1]*qb[0]-qa[2]*qb[3]+qa[3]*qb[2],
    qa[0]*qb[2]-qa[2]*qb[0]-qa[3]*qb[1]+qa[1]*qb[3],
    qa[0]*qb[3]-qa[3]*qb[0]-qa[1]*qb[2]+qa[2]*qb[1]};
   frame_yaw_rate=(mount[1]*rate[0]+mount[4]*rate[1]+mount[7]*rate[2])*(2000000.0f/(float)gap)*(dot<0?-1:1);
   unit4_(q);prediction_gyro_fresh=1;return quaternion(q,out)?1:-1;
  }a=b;
 }return 0;
}
