# FPGA 相机图像畸变矫正与稳像（R22）

本仓库整理自 Camera_R22_20261031，包含紫光同创 PDS 工程、Verilog RTL、RISC-V 固件、上位机源码和部分仿真脚本。R22 独立于 R29 版本。

## 目录

- `pnr_camera_r21_modes/camera_1080p30_raw8.pds`：PDS 工程；文件名沿用 R21，实际使用 R22 融合模块。
- `rtl/`、`reuse/`、`baseline_r13_snapshot/`：设计及复用模块。
- `firmware/`：软核固件；`host/`：电脑端程序；`sim/`：部分仿真代码及波形脚本；`docs/`：功能说明。

## 使用说明

使用 Pango Design Suite 2022.2-SP6.4 及有效许可证打开上述工程。仓库不含本机随包 Python、RISC-V GCC、Icarus Verilog 和 MTF Mapper 工具，不含许可证、拍摄照片、个人配置和工作缓存。原命令脚本依赖这些工具与本机配置，不能直接在本仓库开箱运行；参照 `README_本机原始说明.md` 及脚本自行配置，或者使用本机原始完整工程。

`reuse/` 内含厂商 IP，使用和再分发以原权利人许可为准。

## 验证范围

工程原有 R22 局部功能仿真曾通过，测试范围见 `sim/report_waves/README_R22三张截图.md`。这不是完整 1080p30、物理 DDR 时序或当前板卡验收结论。本仓库整理后尚未重新构建或上板验证。

