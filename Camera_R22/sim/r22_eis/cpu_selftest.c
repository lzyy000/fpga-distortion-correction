#define main camera_application_main
#include "../../night/firmware/camera_r22_main.c"
#undef main
int main(void){
 tx_async=1;
 for(unsigned n=0;n<5;n++){REG(0x920c)=n;
  /* Seed each tested absolute pose, while retaining the previous virtual view.
   * Subsequent poses exercise smoothing, angular cap and crop retreat, instead
   * of accidentally benchmarking only initialization after every FIFO reset. */
  u32 a=REG(DS+20),b=REG(DS+24);
  float q[4]={(short)a/32768.0f,(short)(a>>16)/32768.0f,(short)b/32768.0f,(short)(b>>16)/32768.0f};
  unit4_(q);for(unsigned j=0;j<4;j++)gyro_q30[j]=(i32)(q[j]*GYRO_ONE);
  gyro_ready=1;gyro_count=0;gyro_last_us=1000000+n*34000-10000;
  gyro_previous[0]=2000*65536;gyro_previous[1]=0;gyro_previous[2]=1200*65536;
  dynamic_poll();tuning_service();snapshot_service(REG(MSEC));tuning_reply(240);tx_poll();REG(0x9210)=config_version;}
 REG(0x9224)=112;tuning_service();REG(0x9228)=48;
 REG(0x9224)=249;tuning_service();REG(0x9228)=32;
 REG(0x9224)=102;tuning_service();REG(0x9228)=0;
 snapshot_geometry=3;packet_header(4,1,77,0,4050,1024,123,456);
 packet_header(2,1,0,0,0,0,0,0);
 REG(0x9208)=1;for(;;){}
}
