#define main camera_application_main
#include "../../night/firmware/camera_r22_main.c"
#undef main
static const float sample_q[][4]={
{1.0000000000f,0.0000000000f,0.0000000000f,0.0000000000f},
{0.9999998750f,0.0000000000f,0.0005000000f,0.0000000000f},
{0.9971888181f,0.0000000000f,0.0749297073f,0.0000000000f},
{0.9747941071f,0.0000000000f,0.2231063621f,0.0000000000f},
{0.9460811802f,0.0313647614f,0.3208783321f,0.0313647614f},
{0.9920839718f,0.0173244407f,0.1013853483f,0.0720435136f},
{0.9950041653f,0.0000000000f,0.0000000000f,0.0998334166f},
{0.9921976672f,0.0000000000f,0.0000000000f,0.1246747334f},
{0.9887710779f,0.0000000000f,0.0000000000f,0.1494381325f},
{0.9847265389f,0.0000000000f,0.0000000000f,0.1741081376f},
{0.9800665778f,0.0000000000f,0.0000000000f,0.1986693308f},
{0.9800665778f,0.0000000000f,0.0000000000f,0.1986693308f}
};

static void check(int ok,u32 why){if(!ok){REG(0x9204)=why;for(;;){}}}
static void command(u32 c,u32 mask){REG(0x9224)=c;tuning_service();check(REG(CTRL+228)==mask,800+c);tx_poll();}
int main(void){
 tx_async=1;have_ref=have_pose=1;pose_ms=1000;frame_pose_valid=1;rot_enabled=1;rotation_up_ready=1;
 float camera[9];
 static const unsigned selected[6]={0,1,3,4,7,11};
 for(unsigned n=0;n<6;n++){
  REG(0x920c)=n;quaternion((float*)sample_q[selected[n]],pose);camera_mount_(pose,camera);
  rotation_step_(camera,n+1,1000+n*34);
  check(rot_ready&&!rot_safe_failures,100+n);check(crop_fits_(camera,rot_virtual,rot_zoom),200+n);
  check(absolute(rot_virtual[6])<.00002f&&rot_virtual[7]<0,300+n);
  check(rot_zoom>=rot_zoom_base&&rot_zoom<=3,400+n);
  if(n==1)check(rot_path_static,500+n);
  for(unsigned j=0;j<9;j++)map_camera[j]=camera[j];
  job_rotation=1;job_lens=n&1;job_fisheye=0;eis_enabled=0;dirty=1;control_commit(1000);
  check(eis_zoom_base==1.18f&&eis_tau==.25f&&eis_yaw_tau==.5f&&rs_strength==1,600+n);
  REG(0x9210)=n;
 }
 /* Basis invariance: identical physical roll, two arbitrary gyro-world bases.
  * Measured WT gravity establishes a level frame without changing history. */
 float ref[9],r[9],rt[9],world[9],comp[9];
 for(unsigned n=0;n<2;n++){
  REG(0x920c)=6+n;quaternion((float*)sample_q[3],pose);
  const float *a=n?sample_q[4]:sample_q[0];float rel[4];product_q_(a,sample_q[3],rel);
  for(unsigned j=0;j<4;j++){gyro_history[0][j]=rel[j];gyro_history[1][j]=rel[j];}
  gyro_times[0]=990000;gyro_times[1]=1000000;gyro_count=gyro_head=2;gyro_ready=1;gyro_epoch=n+1;pose_serial=n+1;
  check(rotation_gravity_(1000),700+n);quaternion(rel,r);mul3(rotation_basis,r,world);camera_mount_(world,camera);
  rot_ready=0;rotation_step_(camera,100+n,2000+n*34);check(rot_ready,710+n);transpose(camera,rt);mul3(rt,rot_virtual,comp);
  if(!n)for(unsigned j=0;j<9;j++)ref[j]=comp[j];
  else for(unsigned j=0;j<9;j++)check(absolute(ref[j]-comp[j])<.00005f,720+j);
  REG(0x9210)=6+n;
 }
 pose_ms=800;check(!rotation_gravity_(1000),740);pose_ms=1000;
 command(105,159);command(101,63);command(105,159);command(106,31);
 REG(0x9230)=1;host_poll_(1000);check(host_command_ok&&rot_tau==.9f&&rot_zoom_base==1.24f&&eis_tau==.25f,750);
 /* Exercise the actual queued-job path after parameter and live mode changes. */
 REG(0x920c)=8;REG(CTRL+228)=128;gyro_last_us=1000000;REG(0x9238)=1;
 dynamic_poll();check(config_version==7&&rot_ready&&job_rotation,760);REG(0x9210)=8;
 snapshot_geometry=10;packet_header(4,1,77,0,4050,1024,123,456);
 REG(0x9208)=1;for(;;){}
}
