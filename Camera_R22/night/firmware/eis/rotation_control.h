/* R28 crop-corridor rotation controller, isolated from the original shake state.
 * Uses existing timestamped gyro FIFO/history and the same one-pass mapper.
 * WT quaternion contributes gravity only; absolute magnetic yaw is not followed.
 * All image/lens arithmetic and original small-shake parameters stay shared/unchanged. */
static u32 rot_enabled=0,rot_horizon=1,rot_ready=0,rot_seen=0,rot_last_ms=0;
static u32 rot_limited=0,rot_limit_events=0,rot_safe_failures=0,rot_pole=0,rot_safety_zooms=0,rot_path_static=0;
static float rot_tau=.75f,rot_zoom_base=1.16f,rot_zoom_max=2.4f,rot_zoom=1.16f,rot_safe_zoom=1.16f,rot_rs_strength=0;
/* Cache host units on parameter changes, not in the old-mode telemetry path. */
static u32 rot_zoom_milli=1160,rot_max_zoom_milli=2400,rot_tau_ms=750,rot_rs_milli=0,rot_actual_zoom_milli=1160;
static float rot_forward[3]={0,1,0},rot_last_raw[3]={0,1,0};
static float rot_virtual[9],rot_safe[9];
static float rotation_up[3]={0,0,1};
static float rotation_basis[9]={1,0,0,0,1,0,0,0,1};
static u32 rotation_up_ready=0,rotation_epoch=0,rotation_pose_seen=0,rotation_gravity_ms=0;
/* Transform measured body gravity into the arbitrary relative-gyro world.
 * This avoids resetting or changing the original gyro integrator on mode changes.
 * Match quaternion packet time against gyro history; no display-time prediction.
 * Last-sample fallback is bounded to 20 ms when its upper bracket is not here yet. */
static __attribute__((noinline)) int rotation_gravity_(u32 now){
 if(rotation_epoch!=gyro_epoch){rotation_epoch=gyro_epoch;rotation_up_ready=rot_ready=0;rotation_pose_seen=0;}
 if(!have_pose||!gyro_ready||!gyro_count||now-pose_ms>100)return 0;
 if(rotation_up_ready&&rotation_pose_seen==pose_serial)return 1;
 float r[9],up[3];u32 stamp=REG(DS+0x118)-(REG(MSEC)-pose_ms)*1000u-(u32)imu_delay_us;
 float saved_rate=frame_yaw_rate;int aligned=frame_pose_(stamp,r);frame_yaw_rate=saved_rate;
 if(aligned!=1){
  u32 last=(gyro_head+GYRO_HISTORY-1)%GYRO_HISTORY;
  i32 distance=(i32)(stamp-gyro_times[last]);if(distance<0||distance>20000)return rotation_up_ready;
  if(!quaternion(gyro_history[last],r))return 0;
 }
 for(unsigned j=0;j<3;j++)up[j]=r[j*3]*pose[6]+r[j*3+1]*pose[7]+r[j*3+2]*pose[8];
 if(!unit3(up))return 0;
 if(!rotation_up_ready){for(unsigned j=0;j<3;j++)rotation_up[j]=up[j];rotation_up_ready=1;rot_ready=0;for(unsigned j=0;j<9;j++)rotation_basis[j]=(j%4==0);}
 else {float dt=clamp_((now-rotation_gravity_ms)*.001f,0,.2f),gain=dt/(.75f+dt);
  for(unsigned j=0;j<3;j++){rotation_up[j]+=gain*(up[j]-rotation_up[j]);}
  unit3(rotation_up);}
 /* Carry horizontal heading while the low-frequency gravity basis changes.
  * Camera and virtual view now use a level world; tilt correction cannot leak
  * into the original gyro history or introduce an absolute-yaw reset. */
 float right[3],forward[3],dot=0;
 for(unsigned j=0;j<3;j++)dot+=rotation_basis[j]*rotation_up[j];
 for(unsigned j=0;j<3;j++)right[j]=rotation_basis[j]-dot*rotation_up[j];
 if(!unit3(right)){
  unsigned axis=absolute(rotation_up[0])<.8f?0:1;
  for(unsigned j=0;j<3;j++)right[j]=(j==axis?1.f:0.f)-rotation_up[axis]*rotation_up[j];
  if(!unit3(right))return 0;
 }
 cross_(rotation_up,right,forward);
 for(unsigned j=0;j<3;j++){rotation_basis[j]=right[j];rotation_basis[3+j]=forward[j];rotation_basis[6+j]=rotation_up[j];}
 rotation_pose_seen=pose_serial;rotation_gravity_ms=now;return 1;
}
static int rotation_upright_(const float*f,const float*camera,float*out){
 float z[3]={f[0],f[1],f[2]},up[3]={0,0,1},right[3],down[3];
 if(!unit3(z))return 0;
 if(rot_horizon){
  cross_(z,up,right);
  /* At the gravity pole, carry projected previous right: no unique horizon. */
  if(right[0]*right[0]+right[1]*right[1]+right[2]*right[2]<0.0001f){
   for(unsigned i=0;i<3;i++)right[i]=rot_ready?rot_virtual[3*i]:camera[3*i];
   float dot=right[0]*z[0]+right[1]*z[1]+right[2]*z[2];
   for(unsigned i=0;i<3;i++)right[i]-=dot*z[i];
  }
 }else for(unsigned i=0;i<3;i++)right[i]=camera[3*i];
 if(!unit3(right))return 0;
 /* With horizon enabled, normalized right is perpendicular to normalized z,
  * including the projected pole branch. Their cross product is already unit.
  * The free-roll mode still needs one orthogonalization normalization. */
 cross_(z,right,down);if(!rot_horizon&&!unit3(down))return 0;
 cross_(down,z,right);
 for(unsigned i=0;i<3;i++){out[i*3]=right[i];out[i*3+1]=down[i];out[i*3+2]=z[i];}return 1;
}
static __attribute__((noinline)) void rotation_step_(const float*camera,u32 serial,u32 now){
 if(!rot_enabled){rot_ready=0;rot_limited=0;rot_zoom=1;return;}
 if(rot_ready&&serial==rot_seen)return;
 refresh_bounds_();
 if(!eis_bounds_valid||!rotation_up_ready){rot_ready=0;rot_safe_failures++;return;}
 float dt=clamp_((now-rot_last_ms)*0.001f,0.005f,0.2f);int reset=!rot_ready||now-rot_last_ms>500;
 rot_seen=serial;rot_last_ms=now;float desired[9],wanted[3],raw[3];
 for(unsigned i=0;i<3;i++)raw[i]=camera[3*i]*eis_center[0]+camera[3*i+1]*eis_center[1]+camera[3*i+2]*eis_center[2];
 float raw_step2=0;
 for(unsigned i=0;i<3;i++){float d=raw[i]-rot_last_raw[i];raw_step2+=d*d;rot_last_raw[i]=raw[i];}
 if(reset){for(unsigned i=0;i<3;i++)rot_forward[i]=raw[i];rot_zoom=rot_zoom_base;}
 if(!rotation_upright_(raw,camera,rot_safe)){rot_safe_failures++;rot_ready=0;return;}
 float pole=raw[2];
 rot_pole=pole*pole>.9999f;
 float minimum=required_zoom_(camera,rot_safe),need=minimum;
 if(reset){for(unsigned i=0;i<9;i++)desired[i]=rot_safe[i];}
 else {for(unsigned i=0;i<9;i++)desired[i]=rot_virtual[i];need=required_zoom_(camera,desired);}
 /* Use the geometry at the low crop budget, not the transient current zoom.
  * This avoids holding a distant view that would prevent field-of-view recovery.
  * Reserve a small relative corridor at large roll angles as well. */
 float budget=minimum*1.025f;if(budget<rot_zoom_base)budget=rot_zoom_base;
 if(budget>rot_zoom_max)budget=minimum>rot_zoom_max?minimum:rot_zoom_max;
 float room=budget-minimum,inner=minimum+0.80f*room;
 float outer=minimum+0.98f*room,width=outer-inner;
 float follow=reset?0:clamp_((need-inner)/(width>0.0001f?width:0.0001f),0,1);
 follow=follow*follow*(3-2*follow);
 rot_path_static=!reset&&follow==0;
 for(unsigned i=0;i<3;i++)wanted[i]=rot_forward[i];
 if(follow>0){
  float alpha=follow*dt/(0.025f*(rot_tau/0.75f)+dt);
  for(unsigned i=0;i<3;i++)wanted[i]+=alpha*(raw[i]-rot_forward[i]);
  /* Bound virtual-view catch-up by actual camera movement plus 0.5deg/s.
   * A tiny drift at the inner corridor edge must not release a large fraction
   * of the entire accumulated pointing error in one update. Safety retreat
   * below can still override this limit when crop headroom is exhausted. */
  float max_step=2*root_(raw_step2)+.00872664626f*dt,move2=0;
  for(unsigned i=0;i<3;i++){float d=wanted[i]-rot_forward[i];move2+=d*d;}
  if(move2>max_step*max_step){
   float scale=max_step/root_(move2);
   for(unsigned i=0;i<3;i++)wanted[i]=rot_forward[i]+scale*(wanted[i]-rot_forward[i]);
  }
  if(!rotation_upright_(wanted,camera,desired)){rot_safe_failures++;rot_ready=0;return;}
 }
 /* Keep the crop budget independent of pointing lag. Pans spend the available
  * corridor by following, not by accumulating zoom that later has to unwind.
  * Roll/horizon geometry still raises the necessary safety crop. */
 float goal=clamp_(budget,rot_zoom_base,rot_zoom_max);u32 limited=minimum>rot_zoom_max;
 /* Recover field of view quickly once the measured geometry allows it.
  * Exponential easing removes the long constant-speed tail; keep a bounded
  * velocity for large changes and the existing gradual zoom-in behavior. */
 float delta=goal-rot_zoom;
 float next=reset?goal:rot_zoom+(delta<0?
  clamp_(delta*dt/(0.12f+dt),-2.0f*dt,0):clamp_(delta,0,0.80f*dt));
 if(absolute(next-goal)<0.00001f)next=goal;
 /* A sudden roll can exhaust causal zoom headroom. Prefer an immediate
  * safety crop to black pixels or a tilted raw-camera fallback. */
 if(next<minimum){next=minimum;rot_safety_zooms++;limited=1;}
 rot_zoom=clamp_(next,rot_zoom_base,3.0f);rot_safe_zoom=rot_zoom;
 float inset=(rot_zoom-0.008f)/1.004f,hi[5];u32 retreat=0;
 crop_planes_(camera,desired,inset,hi);
 for(unsigned j=0;j<5;j++)if(hi[j]<0)retreat=1;
 if(retreat){
  rot_path_static=0;
  float test[9],z[3],lo[5],trial[5],blend=1;
  crop_planes_(camera,rot_safe,inset,lo);
  /* Solve each source edge separately. The active limiting edge can change;
   * interpolating one total required-zoom value couples unrelated edges. */
  for(unsigned j=0;j<5;j++){
   if(lo[j]<0)blend=0;
   else if(hi[j]<0){float t=lo[j]/(lo[j]-hi[j]);if(t<blend)blend=t;}
  }
  blend=clamp_(blend,0,1);
  for(unsigned k=0;k<2;k++){
   for(unsigned i=0;i<3;i++)z[i]=raw[i]+blend*(wanted[i]-raw[i]);
   if(!rotation_upright_(z,camera,test)){blend=0;break;}
   crop_planes_(camera,test,inset,trial);float correction=1;
   for(unsigned j=0;j<5;j++)if(trial[j]<0){
    float t=lo[j]<=0?0:lo[j]/(lo[j]-trial[j]);if(t<correction)correction=t;
   }
   if(correction>=1)break;
   blend*=clamp_(correction,0,1);
  }
  for(unsigned i=0;i<3;i++){z[i]=raw[i]+blend*(wanted[i]-raw[i]);}
  rotation_upright_(z,camera,desired);limited=1;
 }
 /* Without retreat the same target already passed every plane at the tighter
  * inset crop. After retreat, check the rebuilt target at the final crop. */
 if(retreat&&!crop_fits_(camera,desired,rot_zoom)){
  rot_path_static=0;
  for(unsigned i=0;i<9;i++){desired[i]=rot_safe[i];}
  limited=1;
  if(!crop_fits_(camera,desired,rot_zoom)){rot_safe_failures++;rot_ready=0;return;}
 }
 for(unsigned i=0;i<9;i++)rot_virtual[i]=desired[i];
 for(unsigned i=0;i<3;i++)rot_forward[i]=desired[3*i+2];
 if(limited&&!rot_limited)rot_limit_events++;
 rot_limited=limited;rot_ready=1;
}
