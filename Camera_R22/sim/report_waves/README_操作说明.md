# 当前窗口恢复步骤

1. 在ModelSim底部的Transcript中输入 `abort` 并回车，结束PDS暂停的宏。
2. 输入 `do {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/control_wave.do}` 并回车。
3. 脚本仅编译camera_view_control.v、camera_corrected_manager.v、camera_engine_arbiter.v和sim/r16/tb_snapshot_views.v，添加波形并运行到1000ns。
4. 后续可在Transcript输入 `wave zoom range 140ns 320ns`，观察按键消抖、requested提前改变、mode在frame_edge边界提交的关系。

本机ModelSim 10.5b控制测试的完整批处理已通过，1960ns出现PASS，编译/加载0错误0警告；这是已有R16控制测试的独立仿真，不等同最终R22像素算法或DDR PHY仿真。control_wave.do的GUI显示结果待用户本次执行确认。

PDS全工程直接仿真失败日志已保存：包括视频/以太网模块重复声明、DDR加密VP文件解析错误，最终tb_control未编译。该单元测试仅依赖上述4个文件，无需编译厂商DDR/PLL IP。新增文件只用于仿真，不修改RTL、约束或位流。本次未重新综合、PDS构建或下载板卡。
