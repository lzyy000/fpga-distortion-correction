# R21 模块、算法与目录入口

唯一活动工程：`pnr_camera_r21_modes/camera_1080p30_raw8.pds`。推荐 `26_打开R21时序优化工程.cmd`。当前位流用户上板正常，2026-10-26最终125MHz WNS+0.180ns，All Constraints Met。

## 主数据链

OV5640 RAW8 → Bayer插值/RGB → 时钟域桥接 → 5×5空间滤波 → 全局HE → 原始/处理双路采集 → DDR/时域滤波 → 所选几何矫正 → 夜景/双视窗显示。网口抓拍从处理帧复制，包含滤波、HE及按抓拍帧锁存的夜景效果，输出1920×1080完整单幅；左侧原始旁路与处理路径对齐。

## RTL 与算法

| 功能 | 主要文件（相对工程根目录） | 内容 |
| --- | --- | --- |
| 顶层与控制寄存器 | `rtl/camera_1080p_top_r21.v` | 引脚、时钟复位、模块连接、五模式和强度CSR、帧边界配置锁存 |
| DVP采集与质量检测 | `rtl/camera_dvp_input.v`、`camera_dvp_qualifier.v`、`camera_dvp_monitor.v` | 输入采样、行帧资格、异常计数与帧完整性 |
| Bayer插值 | `rtl/camera_raw8_rgb.v` | RAW8 Bayer转RGB，提供后续图像处理输入 |
| 空间滤波 | `rtl/camera_spatial_stream_r21.v`、`camera_spatial_core_r21.v` | 5×5窗口、二项权重、亮度/色度差阈值门控；处理后量化RGB565，保留中心原图 |
| 时域滤波 | `rtl/camera_temporal_rgb565_r19.v` | 四像素组运动判别及逐像素保护，静止区域融合历史亮度/色度，运动区域使用当前帧 |
| 共用强度混合 | `rtl/camera_strength_blend_r19.v` | Q8强度下原像素/处理像素混合，多算法共用 |
| 全局直方图均衡化 | `rtl/camera_ghe_r21.v` | HSV V=RGB最大值，256桶、CDF-min、双直方图/增益表、公共RGB增益、帧边界切表和强度混合 |
| 夜景 | `rtl/camera_night_stats.v`、`camera_night_pixel_r19.v`、`camera_night_hdmi_r21.v`、`night_gain.hex` | 完整帧V统计、自适应Gamma档位、ROM增益、暗部保护、公共RGB增益与强度混合 |
| 几何矫正 | `rtl/camera_map_init.v`、`camera_mul32_pipe.v`、`camera_calibration.vh`、`video_row_remap_r21.v` | 标定参数、定点坐标映射表、DDR取样、双线性插值与边界处理 |
| 帧管理与显示 | `rtl/camera_corrected_manager.v`、`camera_view_reader_r21.v`、`camera_hdmi_output.v` | 原始/处理帧所有权、矫正任务调度、左原始右处理、显示时序与帧重复 |
| HDMI芯片配置 | `rtl/hdmi_tx_config.v`、`video_ms72xx_ctl.v`等 | HDMI发送器I2C初始化；与摄像头SCCB配置分开 |
| 双路采集缓存 | `rtl/camera_capture_raw_r21.v`、`video_async_fifo.v` | 原始/处理像素对齐、跨时钟域整包传送、完整帧提交 |
| DDR仲裁和DMA | `rtl/camera_engine_arbiter.v`、`camera_dma_master_r21.v` | 抓拍/映射/矫正仲裁，显示/采集/CPU调度，最多16拍子突发、AW前整包预装、历史缓存复用、原生写数据寄存隔离 |
| 抓拍与CRC | `rtl/camera_snapshot_night_r20.v` | 锁定一帧、夜景处理、共享RAM、整图/分块CRC、CPU读回及取消恢复 |
| 以太网 | `rtl/camera_snapshot_network_rxalign.v`、`camera_rgmii_rx_align.v`、`baseline_r13_snapshot/reuse/ethernet/` | RGMII相位对齐、MAC/IP/UDP/ARP、CRC、截断包恢复和照片传输 |
| 软核与总线 | `rtl/image_cpu.v`、`picorv32.v`、`simpleuart.v`、`pango_word_master.v`等 | RISC-V、UART、CPU与核心时钟域桥接和存储映射 |
| 厂商IP | `reuse/video/ipcore/`、`baseline_r13_snapshot/reuse/ethernet/ipcore/` | DDR3、PLL、RAM/FIFO等PDS所需源文件；不是旧版工程副本 |

## 固件、上位机与工程资料

- `night/firmware/camera_r21_main.c`：OV5640 SCCB寄存器初始化、启动流程、帧率/状态统计、串口命令和主循环。
- `night/firmware/camera_r21_tuning.h`：矫正/双视窗/滤波/夜景/HE独立控制与强度协议。
- `night/firmware/snapshot_service_r21.h`：照片抓拍服务、CNP1/网口交互；`firmware/`保留启动、链接脚本、传感器数据和当前固件产物。
- `host/camera_console/console.py`：相机上位机界面；`tuning.py`：模式、滑条及ACK重试；`transport.py`：收包组帧；`storage.py`：PNG与元数据保存。其余host工具用于标定、传输、串口/环境检查。
- `scripts/`：本机工具路径、固件编译、PDS打开/构建、离线检查及照片标定；旧编号入口兼容到当前R21。
- `sim/r21_modes/`：22项轻量RTL检查与完整帧入口；`sim/r16`是PDS使用的仿真控制源，`sim/r19_strength`、`sim/r20_snapshot`、`sim/denoise`仍提供当前验证读取的公共模型/向量。尤其 `snapshot_c2_s128_expected.hex` 仍由上位机照片保存测试读取，不能当旧文件删除。
- `tools/`：Icarus、NumPy/OpenCV等实际依赖，另有工程引用这里的共享仿真器；不作为缓存清理。
- `captures/`：用户照片、标定数据及验收图片，全部保留。
- `pnr_camera_r21_modes/`：唯一PDS、FDC、初始化ROM以及当前综合/映射/布局布线数据库、位流和最终时序；只清理自动备份与历史日志目录。
- `references/ghe/`：算法参考来源与许可证记录；`docs/`：硬件接线和算法说明；`reports/`：当前检查和上板结果。
- `work/`：可重新生成的临时产物，启动/测试脚本负责创建需要的子目录。

## 清理规则

不能按r13/r16/r19/r20等名称判断是否无用。以PDS、IP清单、隐式include、readmemh、固件和Python/脚本引用为准。本次保留 `rtl/camera_calibration.vh` 和 `baseline_r13_snapshot/reuse/ethernet/source/check_sum.vh` 等隐式依赖；未修改任何RTL、固件、上位机源代码或时序约束。
