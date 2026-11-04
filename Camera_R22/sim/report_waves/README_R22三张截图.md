# R22：自己在ModelSim中截图

在当前ModelSim的Transcript中，每次执行一条do命令。脚本实际编译并运行对应测试，显示的都是ModelSim原生Wave；不需要重新从PDS全工程编译。

## 第1张：四邻点双线性插值流水线

`do {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/r22_render_wave.do}`

脚本运行4帧，共49152像素，并显示6032～6128ns。6044ns四邻点及fx/fy有效，6052ns水平插值有效，6060ns对应双线性输出有效，首个RGB565结果556A，延迟16ns/2周期。qv/hv/vv依次为四邻点、水平级和最终级有效标志。输入p00/p10/p01/p11和fx/fy、输出interpolated_pixel按十六进制显示。图名可写“四邻点双线性插值流水线仿真波形”，放在2.2.3几何重映射与像素插值模块。

## 第2张：DDR访问和行缓存接收寄存

`do {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/r22_cache32_wave.do}`

显示2988～3124ns。3012ns上升沿接受120拍源图读请求，地址013D2C00；3020ns首拍返回有效，3028ns数据和有效标志经寄存进入缓存接收级，延迟8ns。VCD/波形显示时钟沿后稳定值，req/accept在握手沿后降0。总线地址及数据按十六进制，beats按十进制。这里是带等待的DDR事务应答模型，不是DDR PHY物理引脚时序。图名可写“DDR访问与行缓存接收仿真波形”，放在2.2.3存储与访问调度模块。

## 第3张：R22帧槽参数等待和启动

`do {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/r22_manager_wave.do}`

显示3184～3412ns。槽位0在参数未就绪时处于状态2，3288ns ready就绪，3292ns process_start/ps有效并进入状态3。当前eis已关闭，但已接收帧保留原EIS模式；之后完成并显示。状态1采集中、2等待、3处理、4完成、5显示；ready和ef为四槽位图。图名可写“帧槽参数等待与调度启动仿真波形”，放在2.2.3帧管理与控制模块。

## 截图整理

脚本已按信号分组、选定进制和时间范围。若波形显示范围因窗口布局变化被重置，先调整窗口，再输入对应的`wave zoom range 起点ns 终点ns`，随后`wave refresh`。要减少下方黑色空白，可把Wave和Transcript之间的横向分隔线往上拖，让Wave高度刚好容纳信号和底部时间刻度；布局调整后再重新设一次范围。使用Windows截图工具手动截取信号名称、数值、全部波形和底部时间刻度。截取结果保留ModelSim原生显示。若另有“系统仿真与测试”章，完整图可放该章，硬件章引用。

## 已验证范围

本机ModelSim Intel FPGA Starter Edition 10.5b三组完整批处理均PASS，均0错误0警告。render为128×96四帧；cache32为1920像素行宽、输出行1070/35/1070共5760像素；manager为有限四帧槽控制场景。额外从ModelSim VCD逐采样核验49152次双线性插值及2周期延迟，0错误。日志、VCD、WLF在各*_run目录，哈希和边界见r22_modelsim_verification.json、r22_inputs.json、r22_wave_window_verification.json。

测试向量来自当前工程原始独立参考生成函数。cache32/manager的测试副本只加观测线、显式置0已禁用的鱼眼/旋转输入及声明未使用的输出连接；原始RTL/测试/PDS/约束哈希保持。上述不是完整1080p30实板吞吐或DDR PHY仿真，未运行PDS构建或访问板卡。GUI具体显示效果待用户逐张运行并截图确认。
