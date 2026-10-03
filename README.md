# 赛题二：网络资料与 GitHub 参考索引

最后核对：2026-10-03。用途：基于紫光同创 FPGA 做图像畸变矫正；现阶段以 PC HDMI 输入的畸变图片/视频开发，后续接真实摄像头。本目录是**资料索引**，不是可直接综合的工程，也没有复制第三方源码。

本机另有不上传的 `LOCAL.md`，记录本地入口与已验证结果。赛题和七天执行顺序以本工作区的 `赛题二_常用清单.md`、`赛题二_七天执行计划.md` 为准；不要把参考仓库的 README 误当作本板卡的操作说明。

## 先读哪些

1. **现在（软件基准）**：OpenCV 标定 → 输出到输入的映射 → 双线性插值。对照本机已生成的 `calibration.json`、`map_x.npy`、`left12_undistorted.png`。
2. **写 RTL 前**：看 FPGA 论文的输出扫描顺序、查表/定点、存储访问思路；重点不是抄参数数量，而是理解怎样按输出像素找原图的四邻点。
3. **接 DDR3 时**：看 Pango DDR IP 文档并核对本机 `fram_buf/rd_buf`；公开仓库的 Xilinx/Zynq 工程不能直接在 PDS 中打开。
4. **基础版稳定后**：再看旋转、任意角度、CLAHE 和画质测试。不要用增强效果掩盖几何矫正错误。

## P0：当前直接使用的权威资料

| 资料 | 对本项目的用处 | 注意 |
| --- | --- | --- |
| [OpenCV 相机标定教程](https://docs.opencv.org/4.13.0/dc/dbb/tutorial_py_calibration.html) | 棋盘格角点、`K` 与畸变参数、重投影误差、`initUndistortRectifyMap`/`remap`；本机第一步脚本的理论对照。 | 本机示例是 OpenCV 的旧相机数据，不能冒充最终摄像头标定。教程把样图写作 `left01`—`left14`，仓库实际缺 `left10.jpg`。 |
| [OpenCV 几何图像变换参考](https://docs.opencv.org/4.13.0/da/d54/group__imgproc__transform.html) | 说明几何变换按目标图像坐标反查源图像坐标；确认采样、插值、边界处理的方向。 | 与 RTL 比像素时，需统一颜色格式、插值量化和越界规则。 |
| [OpenCV Remapping 教程](https://docs.opencv.org/4.13.0/d1/da0/tutorial_remap.html) | 帮助理解 `map_x/map_y` 表示“输出位置对应的输入位置”。 | `remap` 是软件参考，不是 FPGA 访存架构。 |
| [Pango 官方 DDR IP 用户指南](https://www.pangomicro.com/en/uploads/59186237_1711509831.pdf) | 查 DDR 控制器的 AXI 端口与握手；与本机 IP 配置、RTL、仿真结果互相核对。 | 文档示例配置不等于本工程实际的地址单位、突发长度或吞吐。 |

## P1：FPGA 架构与代码参考

| 资料 | 可以借鉴 | 不能照搬的原因 |
| --- | --- | --- |
| [Johnston/Bailey 2003：实时桶形畸变校正](https://johnston.geek.nz/publications/2003_projectJournal.pdf) | 输出像素按光栅顺序生成、反查输入位置、用查表/插值降低硬件复杂度。 | 论文主要是较简化的径向模型；我们的 `k1,k2,p1,p2` 和 DDR3 细节需自己实现。 |
| [Di Febbo 等：FPGA 兼容的畸变矫正算法评估](https://arxiv.org/abs/1610.09712) | 比较适合硬件的算法、几何误差和资源取舍；选定点/LUT 方案时参考。 | 论文的估算不是盘古 100Pro+ 板上的实测数据。 |
| [thechosenone98/FPGA-OpenCV-Undistort](https://github.com/thechosenone98/FPGA-OpenCV-Undistort) | 参考完整畸变模型在 FPGA 上的模块划分、参数通路和测试方式。 | README 指向 Zybo-Z7、Vivado/Vitis、Zynq CPU，模型达 12 参数；不是 Pango PDS/PG2L100H 可直接导入的工程。仓库标注 MIT 许可；如复用代码须保留许可要求。 |
| [dyzhangzz/FPGA-based-image-rotation-control-system](https://github.com/dyzhangzz/FPGA-based-image-rotation-control-system) | 参考反向映射、双线性插值、旋转角度计算和相关 Verilog 模块。 | 旋转不是镜头径向/切向畸变；只能借鉴局部设计，不能当作基础矫正完成。仓库为 GPL-3.0，复制代码前先评估许可影响。 |

## P2：特定情况才看

| 资料 | 使用时机与边界 |
| --- | --- |
| [OpenCV Homography 教程](https://docs.opencv.org/4.13.0/d9/dab/tutorial_homography.html) | 后续要处理相机俯仰/偏航等视角变化时再研究；平面旋转不等于所有“任意角度”。 |
| [WordZzzz/fisheye_calibration](https://github.com/WordZzzz/fisheye_calibration) | 有普通针孔模型和鱼眼模型的图片/USB 摄像头示例，可作对比阅读；使用较旧的 OpenCV 2/3，鱼眼模型与当前 `k1,k2,p1,p2` 基准不同，不直接替换。 |
| [OpenCV CLAHE 教程](https://docs.opencv.org/4.13.0/d5/daf/tutorial_py_histogram_equalization.html) | 几何矫正通过后做画面增强时看；CLAHE 不修正弯曲直线。 |
| [ISO 12233:2024 标准介绍](https://www.iso.org/standard/88626.html) | 画质评估、SFR/分辨率术语的标准入口；标准全文可能需要购买，别把页面介绍当成完整测试规范。 |

## 怎样把资料转成我们的实现

| 我们要交付的东西 | 优先依据 | 本机目前状态 |
| --- | --- | --- |
| 标定参数与测试图 | OpenCV 标定教程 | 已有 640×480 示例相机数据和独立 `left12` 测试图；最终真实相机未标定。 |
| 坐标映射与插值 RTL | OpenCV 映射语义 + FPGA 论文 | 浮点公式已与 OpenCV 对照；定点 RTL 未完成。 |
| 四邻点读取、缓存、DDR 调度 | Pango DDR 指南 + 本机 `fram_buf/rd_buf` | 现有 Demo 是顺序帧缓存；任意位置读取尚未验证。 |
| HDMI 实机闭环 | 本机 4_12 副本与仿真 | HDMI/DDR3 基线已分别验证；畸变矫正尚未上板。 |
| 任意角度与画质评价 | Homography、CLAHE、ISO 12233 | 高阶/后期工作，不作为现阶段已完成。 |

## 保存与发布约束

- 本索引只保存链接和我们自己的摘要，不打包转载外部论文、厂家手册或第三方仓库源码。
- GitHub 仓库为 [lzyy000/fpga-distortion-correction](https://github.com/lzyy000/fpga-distortion-correction)，目前设为私有，仅上传本资料索引；`LOCAL.md`、厂家 Demo、赛题 PDF、测试图、位流和第三方代码不上传。以后增加内容前，分别核对版权、许可和敏感信息。

