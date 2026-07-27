# WD My Cloud Home（RTD1295）Linux 6.18.2 刷机包 r1

本包把已经安装 Debian 13 的单盘版 WD My Cloud Home 切换到 Linux 6.18.2。
它只写 B 槽，不替换 Debian 根文件系统，不写 A 槽或 GOLD 救援槽。

这不是 WD 官方固件。刷错分区可能使设备无法启动；开始前必须连接 115200 8N1
串口并备份原分区。

## 这个包是否适合你的设备

已验证条件：

- 单盘版 WD My Cloud Home，Realtek RTD1295；
- Debian 13 trixie arm64 已安装，根文件系统为 `/dev/md1`；
- 可以使用 TTL 串口进入一阶段 U-Boot；
- 局域网内有 TFTP 服务器。

My Cloud Home Duo、其他 RTD1295 产品、不同根文件系统布局均未验证。这个包也不能
代替 Debian 安装包。

## 包内文件

`flash/` 中三个文件是一套，必须全部使用，不能与仓库里的历史开发文件混搭：

| 文件 | 内容 |
|---|---|
| `Image-6.18.2-mch` | 带 RTD1295 兼容头和内嵌 initramfs 的 Linux 6.18.2 |
| `mch.dtb` | 本机型的设备树 |
| `fw_table.bin` | 描述并校验以上两个文件的固件表 |
| `SHA256SUMS` | 下载和传输后的完整性校验 |

安装前先核对：

```bash
cd flash
sha256sum -c SHA256SUMS
```

## 安装顺序

1. 按 [`docs/FLASHING.md`](docs/FLASHING.md) 的第 0 步备份当前 B 槽。
2. 阅读 [`docs/RESCUE.md`](docs/RESCUE.md)，确认知道 A、B、GOLD 三条启动路径。
3. 把 `flash/` 中的三个固件文件放到 TFTP 根目录。
4. 严格按 [`docs/FLASHING.md`](docs/FLASHING.md) 刷写；每次 `tftp` 后都核对
   `Bytes transferred`，再执行对应的 `sata write`。
5. 首次启动后验证 CPU、网络、存储和重启。

只写文档列出的 B 槽扇区。不要覆盖 A 槽或 GOLD 槽。

## 已验证功能

| 能力 | 状态 |
|---|---|
| Cortex-A53 四核 SMP | ✅ |
| 千兆以太网及出厂 MAC | ✅ |
| 后置 USB 3.0 Type-A，5 Gbit/s | ✅ |
| UART0 中断模式 | ✅ |
| Debian 13 / systemd | ✅ |
| Docker、OpenMediaVault 8 | ✅ |
| NFS、SMB 所需 ACL/xattr、配额 | ✅ |
| TUN、WireGuard、dm-crypt、FUSE、zram | ✅ |
| 看门狗软重启 | ✅ |
| SoC 温度读取和 thermal zone | ✅ |
| 槽位切换和一次性网络救援 | ✅ |

已知限制：RTC 能注册但不走针，依赖 NTP；`r8169soc` 偶尔打印
`rtl_csiar_cond` 超时提示，当前实测不影响网络；网络救援的 telnet root shell
没有密码，只能在可信局域网临时使用。

## 版本说明

- **r1** 是用户需要关心的刷机包版本。
- **6.18.2** 是上游 Linux 内核版本。
- 源码对应提交为 `aeae8812a`，完整源码地址见 [`SOURCES.md`](SOURCES.md)。

项目开发日志中还会出现 `v21`…`v46`、内核 `#35`、DTB `v22` 等编号。它们只是
开发期间不同层次的内部流水号，不是可供选择的发行版。`r1` 已经把经过验证的组合
固定为上面的三个中性文件名，普通用户可以忽略所有内部编号。

## 版权与源码

Linux 内核及相应修改遵循 GPL-2.0。源码基线、板级修改和完整源码获取方式见
[`SOURCES.md`](SOURCES.md)。
