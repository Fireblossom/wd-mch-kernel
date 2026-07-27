# WD My Cloud Home (RTD1295) 主线内核 6.18.2 刷机包 r1

为已运行 **Debian 13 (trixie) arm64** 的 WD My Cloud Home 提供主线 Linux 6.18.2
内核（替代厂商 4.9），刷入 **B 槽**，不碰引导链和 Gold 救援槽。

## 功能清单（全部实机验证）

| 能力 | 状态 |
|---|---|
| 四核 SMP（Cortex-A53 ×4） | ✅ |
| 千兆以太网（集成 GMAC，出厂 MAC） | ✅ |
| USB 3.0 扩展盘（后置 Type-A，5Gbps，实测 137 MB/s） | ✅ |
| 串口真中断（irq mux 驱动） | ✅ |
| 软重启（`reboot` 可用，看门狗复位通道） | ✅ |
| NFS 服务端/客户端、SMB 所需 ext4 ACL/xattr、配额 | ✅ |
| Docker/容器全套（netfilter 双栈、cgroups、overlayfs、IPv6） | ✅ |
| OpenMediaVault 8 兼容 | ✅ |
| TUN/WireGuard、dm-crypt(LUKS)、FUSE、zram | ✅ |
| vfat/exFAT/NTFS3/CIFS | ✅ |
| SoC 温度传感（/sys/class/thermal，105°C 保护） | ✅ |
| 已知限制 | RTC 不走针（NTP 兜底）；内核日志偶现 rtl_csiar_cond 提示（无害） |

## 前置条件

1. 设备已按社区方案安装 Debian 13 arm64（根文件系统在 /dev/md1）
2. TTL 串口线（115200 8N1）+ 局域网内一台 TFTP 服务器
3. 刷机走 U-Boot，全程只写 B 槽（sda1/sda6/sda8）

安装步骤见 `docs/FLASHING.md`，出问题回滚见同文件末尾。

## 版权与源码

Linux 内核为 GPL-2.0。本包含对 6.18.2 的板级补丁（DTS、irq mux、r8169soc、
dwc3-rtk quirk、thermal 等）。依 GPL 要求，二进制分发需附源码获取方式——
发布者请同时公开对应内核源码树（见 SOURCES.md）。

---
溯源：内部构建 v42（内核 #31，DTB v22），源码树提交 a3d1a69。
三个文件是一套：fw_table 内记录内核与 DTB 的校验和，必须同时刷入。
