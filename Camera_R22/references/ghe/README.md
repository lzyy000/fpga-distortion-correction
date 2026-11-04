# GitHub 均衡化实现评审

检索和核查日期：2026-10-25。这里的上游文件是参考资料，不加入PDS。没有运行其脚本或构建工程。

| 仓库 | 固定提交 | 许可 | 评审结论 |
|---|---|---|---|
| [Passionate0424/CLAHE_verilog](https://github.com/Passionate0424/CLAHE_verilog) | `739f7122230c0917cafe2bbf4372a05e7ccb3473` | Apache-2.0 | 选作架构参考：直方图读改写冲突、CDF-min归一化、双缓冲。上游是分块CLAHE，本项目不直接实例化它的模块。 |
| [mdavide99/histogram-equalization-fpga](https://github.com/mdavide99/histogram-equalization-fpga) | `ceedd8d9630180e0de831fc864ba8f09cd5023b3` | MIT | 已读 `code.vhd`；采用SEARCH_MINMAX/CALC_SHIFTLEVEL进行范围拉伸，不是本次所需的256桶CDF均衡化，不采用。 |
| [TingKaiHsu0525/histogram-equalization](https://github.com/TingKaiHsu0525/histogram-equalization) | `9fab3802c31d9914fe4d5a3e6cf243c769f9b84f` | 未发现明确许可证 | 了解功能描述，不复制源代码。 |

选中参考的原始路径为 `projects/16tile/rtl/clahe_histogram_stat_v2.v`、`projects/16tile/rtl/clahe_clipper_cdf.v`，保留下载原文及 `clahe_LICENSE.txt`。MIT评审源码与其许可证分别保存为 `mit_code.vhd`、`mit_LICENSE.txt`。

当前 `rtl/camera_ghe_r21.v` 是适配本项目的独立RTL实现：256桶单块全局直方图，不含CLAHE分块、裁剪重分配、Xilinx RAM/IP或其整帧缓存。参考思想与数学公式，不把上游RTL直接拼接进相机流水线。
