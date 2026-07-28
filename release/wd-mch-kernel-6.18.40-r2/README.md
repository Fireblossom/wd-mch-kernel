# WD My Cloud Home（RTD1295）Linux 6.18.40 刷机包 r2

本包只更新 B 槽的内核、设备树和固件表。它不安装 Debian，不修改 GPT、A 槽、GOLD 槽、
根文件系统、OMV 配置或用户数据。

## 验证范围（请如实理解）

r2 已在一台单盘版设备上刷入并验证：四核 SMP、串口真中断、千兆网、Docker、
OpenMediaVault 8、USB 3.0 5 Gbit/s、温度读取、md 阵列组装与 `/data` 挂载，
连续三次冷断电全部自愈、无失败单元。

但请注意这句话的边界：

- **验证时长以小时计，不是长期运行验证。** 本项目的任何主线内核版本（含更早的
  `r1`）都没有经历过长期真机使用；唯一经过多年实际使用检验的，是厂商的 4.9 内核。
- 测试样本只有**一台**单盘版设备。My Cloud Home Duo、其他 RTD1295 产品、
  不同磁盘布局均未验证。

如果你的设备承载重要数据，请自行权衡，并确保有可用的回退手段。

> [!WARNING]
> 刷错扇区可能导致设备无法启动。建议连接 115200 8N1 串口，并在刷写前备份当前 B 槽
> 三个分区（`docs/FLASHING.md` 有步骤）。

## 适用范围

- 单盘版 WD My Cloud Home，Realtek RTD1295；
- 已安装 Debian 13 arm64，根文件系统位于 `/dev/md1`；
- 可以进入一阶段 U-Boot 串口控制台；
- 局域网内有 TFTP 服务器。

（如果没有串口，可以改用免串口的 USB 刷机包，但那个包**尚未经过真机测试**，
见发布页说明。）

## 构建与验证记录

| 项目 | 状态 |
|---|---|
| 官方 Linux 6.18.40 源码校验 | 已通过 |
| 板级补丁应用 | 已通过 |
| `Image` 和 WD My Cloud Home DTB 编译 | 已通过 |
| RTD1295 镜像头、填充和 `fw_table` 内部校验 | 已通过 |
| SHA-256 和归档内容检查 | 已通过 |
| 真机冷启动、SMP、网络、USB、存储和软重启 | 已通过（范围见上） |

## 包内文件

`flash/` 下的固件文件是一套，不能和 `r1` 或旧开发产物混用：

| 文件 | 用途 |
|---|---|
| `Image-6.18.40-mch` | 带 RTD1295 兼容头和内嵌 initramfs 的内核 |
| `mch.dtb` | 固定填充到 B 槽尺寸的设备树 |
| `fw_table.bin` | 记录以上两个文件尺寸和校验和的固件表 |
| `SHA256SUMS` | 三个固件文件的传输完整性校验 |
| `BUILD-METADATA.json` | 源码提交、尺寸和校验值 |
| `FLASH_COMMANDS.txt` | 根据本次实际产物生成的 U-Boot 命令 |

开始前先执行：

```bash
cd flash
sha256sum -c SHA256SUMS
```

然后依次阅读：

1. [`docs/RESCUE.md`](docs/RESCUE.md)：确认回滚和救援路径；
2. [`docs/FLASHING.md`](docs/FLASHING.md)：备份并刷写 B 槽；
3. `flash/FLASH_COMMANDS.txt`：使用本包实际生成的扇区数量。

## 首次启动验收

刷完后建议逐项确认：

- `uname -r` 显示 `6.18.40`；
- 四个 Cortex-A53 CPU 均上线；
- `/dev/md1` 能正常挂载并进入 Debian/systemd；
- 板载网卡使用出厂 MAC，SSH 和持续传输正常；
- USB 3.0 设备协商到 5 Gbit/s；
- SATA、Docker、NFS/SMB 和温度读取正常；
- 软重启能够再次进入同一系统。

## 出问题怎么办

**回退方式是把刷写前备份的 B 槽三个分区写回去**（`docs/RESCUE.md` 有完整步骤）。
这也是唯一推荐的回退路径。

> [!CAUTION]
> **不要启动 GOLD 槽。** 它不是救援环境，而是出厂重置固件：其 Android recovery
> 用户态在**每次启动时**都会无条件执行出厂重置，包含对分区的 `mke2fs -E discard`。
> 在社区 Debian 的分区布局下，被格式化的正是用户数据分区。本项目开发期间曾因此
> 丢失一个 215 GiB 数据分区，且 `-E discard` 会向 SSD 下发全盘 TRIM，数据在闪存
> 层面即刻不可恢复。
>
> **A 槽也不是可用的回退目标。** 由社区 Debian 包安装的设备，其 A 槽的旧 initramfs
> 会在 `switch_root` 失败后约 43 秒 panic 并无限重启。
>
> 请保持 `bootConfig` 为 `0:F:0:;`。

如果 B 槽启动失败且手上没有备份，本包内核的 initramfs 带一次性网络救援
（netrescue），会自动起 telnet 供你修复根文件系统，详见 `docs/RESCUE.md`。

## 已知限制

- RTC 能注册但时钟不走，系统依赖 NTP；
- RTD129x 无主线时钟驱动，网卡与 USB 依赖 bootloader 留下的时钟门 + probe 期 quirk；
- I2C 与 G2227 PMIC/regulator 已移植但编为模块且未加载，regulator 均为 dummy；
- `r8169soc` 启动时会记录两次无害的 `rtl_csiar_cond` 超时；
- netrescue 提供无密码的 telnet root shell，只能在可信局域网临时使用；
- 当前测试范围只有一台单盘版设备，且未经长期运行验证。
