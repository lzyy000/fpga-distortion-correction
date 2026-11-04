# CNP1 单帧照片回传协议 v1

这是本次新增的上位机协议约定，原 R12 板卡固件尚未实现。只支持原始 1920×1080 RGB565_LE，图像不裁剪、不缩放、不做畸变校正。

默认本机 192.168.1.105:8080，板卡 192.168.1.11:8080。全部整数头字段使用网络字节序；RGB565 图像中的 16-bit 像素为小端。

## 公共头（48 字节）

Python struct 格式 `!4sBBH10I`，后跟 0～1024 字节 payload。

| 偏移 | 类型 | 字段 |
|---|---|---|
| 0 | 4 bytes | magic = CNP1 |
| 4 | uint8 | version = 1 |
| 5 | uint8 | kind |
| 6 | uint16 | flags = 0 |
| 8 | uint32 | request_id |
| 12 | uint32 | frame_id |
| 16 | uint32 | packet_index |
| 20 | uint32 | packet_count |
| 24 | uint32 | width |
| 28 | uint32 | height |
| 32 | uint32 | pixel_format = 1 (RGB565_LE) |
| 36 | uint32 | payload_length |
| 40 | uint32 | payload_crc32 |
| 44 | uint32 | whole_frame_crc32 |

CRC32 使用 zlib.crc32 / CRC-32 ISO-HDLC，初始/最终反转按标准库约定。payload 校验只覆盖 payload；whole_frame_crc32 覆盖完整 4147200 字节原始图像。

## 消息与流程

1. HELLO (kind=1)：电脑生成随机 request_id，payload 为空。
2. HELLO_REPLY (kind=2)：板卡回显同一 request_id，payload 是 UTF-8 JSON：`{"device":"100Pro+ OV5640","firmware":"版本名","capabilities":["snapshot_rgb565"],"width":1920,"height":1080,"pixel_format":"RGB565_LE"}`。只有已实现抓拍、分包回传的位流可以声明该能力。
3. CAPTURE (kind=3)：电脑生成新的 request_id，width=1920、height=1080，payload 为空。板卡取得一张完整帧，固定 frame_id、像素数据、整帧 CRC。同一 request_id 重试必须重用这一帧，不能重新拍另一帧。
4. DATA (kind=4)：总计 4050 包，packet_index=0～4049，packet_count=4050，每包 1024 字节。偏移 = packet_index×1024。所有包的尺寸、frame_id、pixel_format、整帧 CRC 保持一致。板卡发包应避免超过接收端缓冲能力。
5. MISSING (kind=6)：payload 是最多 128 个网络序 uint32 缺失包编号。板卡从稳定快照补发对应 DATA 包。电脑约每 650 ms 检查一次缺包；未收到首包时重发相同 CAPTURE 请求。
6. END (kind=5)：电脑收到完整图像且整帧 CRC 正确后发送，回显 request_id / frame_id / whole_frame_crc32，payload 为空。板卡可释放该快照。END 可能丢失，板卡需实现超时释放。
7. CANCEL (kind=7)：电脑中断/关闭连接时发送，payload 为空。允许 frame_id=0（尚未收到首包），板卡按 request_id 释放请求占用。
8. ERROR (kind=8)：板卡回显 request_id，payload 为 UTF-8 错误说明。不得以不完整帧冒充成功响应。

## 缓冲、失败与资源要求

- 电脑只接受配置的板卡 IP 和源 UDP 端口；其它来源、错误版本、过期 request_id 被忽略。
- 板卡在 END/CANCEL 或本地超时前保持快照稳定。建议保留至少 35 秒，并限制同时一个活动请求；超时不得影响相机和 HDMI 主通路。
- 原始 R12 有三个帧槽。增加抓拍时必须显式处理缓冲所有权或新增快照缓冲，不能读取正在被采集覆盖的槽。
- 接收超时 30 秒；同一包重复且内容一致允许，内容冲突或混帧拒绝；完整帧校验错误拒绝保存。
- 不能用固定示例图像冒充实际传感器抓拍。应以真实传感器帧、可追踪 frame_id 和实际 CRC 验收。
- 本机 UDP 回归通过，只能证明上位机接收和保存逻辑；板卡 MAC/DDR/传输时序需另行验证。
