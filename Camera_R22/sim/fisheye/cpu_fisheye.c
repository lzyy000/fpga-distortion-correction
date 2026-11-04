#define main camera_application_main
#include "../../night/firmware/camera_r22_main.c"
#undef main
static void command(u32 c,u32 expected){REG(0x9224)=c;tuning_service();REG(0x9228)=expected;}
int main(void){tx_async=1;
 command(103,80);command(104,16);REG(0x920c)=0;dynamic_poll();REG(0x9210)=1;
 command(103,80);command(101,112);REG(0x920c)=1;dynamic_poll();REG(0x9210)=2;
 command(127,63);REG(0x920c)=2;dynamic_poll();REG(0x9210)=3;
 command(102,31);command(103,94);command(249,78);command(54,78);command(112,64);command(104,0);
 snapshot_geometry=4;packet_header(4,1,77,0,4050,1024,123,456);REG(0x9208)=1;for(;;){} }
