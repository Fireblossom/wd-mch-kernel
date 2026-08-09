# WD My Cloud Home（RTD1295）Linux 6.18.40 刷机包 r7

本包只更新 B 槽的内核、设备树和固件表。它不安装 Debian，不修改 GPT、A 槽、GOLD 槽、
根文件系统、OMV 配置或用户数据。

## 验证范围（请如实理解）

r7 已在一台单盘版设备上刷入并验证：四核 SMP、串口真中断、千兆网、Docker、
OpenMediaVault 8、USB 3.0 5 Gbit/s、md 阵列组装与 `/data` 挂载、硬件看门狗
（systemd 接管，15 秒超时）、pstore 崩溃日志（ramoops）、**CPU 频率调节
（300/600/1100 MHz 三档，schedutil，详见下节）**、AES 硬件加速（dm-crypt aes-xts
实测写 246 / 读 376 MB/s，同轮明文基线 251 / 373——加密已贴平盘速）、温度经
thermal 与 hwmon（`sensors`）双路径可读、**85°C 自动降频热保护**、软重启，以及
连续三次冷断电（26 秒回网）全部自愈。

但请注意这句话的边界：

- **验证时长以小时计，不是长期运行验证。** 本项目的任何主线内核版本都没有
  经历过长期真机使用；唯一经过多年实际使用检验的，是厂商的 4.9 内核。
- 测试样本只有**一台**单盘版设备。My Cloud Home Duo、其他 RTD1295 产品、
  不同磁盘布局均未验证。

如果你的设备承载重要数据，请自行权衡，并确保有可用的回退手段。

> [!WARNING]
> 刷错扇区可能导致设备无法启动。刷写前必须备份当前 B 槽三个分区
> （`docs/FLASHING.md` 有步骤）。这是唯一推荐的回退路径，不是可选项。

## 关于 CPU 频率（r7 的核心变化，请读完再决定）

这台设备出厂以来一直运行在 **600.75 MHz**（bootloader 将 PLL 设为 1201.5 MHz
并把后分频器留在 /2，厂商 4.9 内核从未启用 DVFS）。r6/r7 加入了 cpufreq：

| 档位 | 性质 |
|---|---|
| 300.375 MHz | 空闲档，PLL 不变只改分频，低于出厂点，无条件安全 |
| 600.750 MHz | **出厂工作点**，逐字节保持原状 |
| 1100 MHz | 峰值档，**超出厂商为本板背书的工作点** |

关于 1100 MHz 档的如实说明：cpudvs 供电轨实测 1.0000 V（G2227 PMIC 读回）。
按 Realtek 参考板电压表，1.1 GHz 需要 0.9625 V（裕量 37.5 mV），1.2 GHz 需要
1.0125 V（不满足，故未提供）。**本包不修改任何电压。** 该档位在本项目的设备上
经过 SSC 变频序列、四核满载压测（69.5°C）与三档切换压测验证，并由 85°C
passive trip 自动降频兜底（105°C critical 仍在）。尽管如此，它仍属于超出
WD 出厂验证范围的运行状态——不接受这一点的用户可以
`echo 600750 > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq`
将峰值锁回出厂点，其余功能不受影响。

## 相比 r5（上一个正式发布）的变化

| 版本 | 内容 |
|---|---|
| r6 | cpufreq 基础（发现设备一直半速运行）；MFD_SYSCON 修复 |
| r7 | 1100 MHz 峰值档 + 85°C 热保护；i2c/G2227 PMIC 驱动栈四处潜伏缺陷修复 |

r5 的变化（看门狗、pstore、AES CE、hwmon）见 r5 发布页。

## 适用范围

- 单盘版 WD My Cloud Home，Realtek RTD1295；
- 已安装 Debian 13 arm64，根文件系统位于 `/dev/md1`。

刷写路径有三条，按设备状态选择（详见 `docs/FLASHING.md`）：

1. **免串口 dd**：设备当前能正常启动进 Debian 时最方便，直接从运行中的系统写入；
2. **串口 + U-Boot + TFTP**：任何状态都可用，需要 115200 8N1 TTL 串口和 TFTP 服务器；
3. **USB 免串口刷机包**：见发布页，但该包**尚未经过真机测试**。

## 构建与验证记录

| 项目 | 状态 |
|---|---|
| 官方 Linux 6.18.40 源码校验 | 已通过 |
| 板级补丁应用 | 已通过 |
| `Image` 和 WD My Cloud Home DTB 编译 | 已通过 |
| RTD1295 镜像头、填充和 `fw_table` 内部校验 | 已通过 |
| SHA-256 和归档内容检查 | 已通过 |
| 真机冷断电×3、SMP、网络、USB、存储、加密、cpufreq、热保护、看门狗和软重启 | 已通过（范围见上） |

## 包内文件

`flash/` 下的固件文件是一套，不能和其他版本（`r1`/`r2`/`r5` 或旧 `vNN`）混用：

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
3. `flash/FLASH_COMMANDS.txt`：（串口路径）使用本包实际生成的扇区数量。

## 首次启动验收

刷完后建议逐项确认：

- `uname -a` 显示 `6.18.40 #9`；
- 四个 Cortex-A53 CPU 均上线；
- `/dev/md1` 能正常挂载并进入 Debian/systemd；
- `cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies`
  显示 `300375 600750 1100000`，governor 为 schedutil；
- `/sys/class/thermal/cooling_device0/type` 为 `cpufreq-cpu0`；
- 板载网卡使用出厂 MAC，SSH 和持续传输正常；
- USB 3.0 设备协商到 5 Gbit/s；
- SATA、Docker、NFS/SMB 正常；
- `journalctl -b | grep -i watchdog` 显示 systemd 以 15 秒超时接管硬件看门狗；
- 装有 lm-sensors 时 `sensors` 能读到 SoC 温度；
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

- `poweroff` 没有断电实现（无 `pm_power_off`）：关机会停在 halt，不会切断电源，
  需要外部断电；`reboot` 正常工作；
- 前面板 LED 无驱动，不可控；
- cpufreq 只做频率调节，不做电压调节（cpudvs 恒为 1.0 V）；1100 MHz 档超出
  厂商为本板背书的工作点（见上文专节）；
- pstore 依赖 DRAM 保留区，能跨软重启和 panic 保存日志，**不能**跨断电保存；
- RTC 能注册但时钟不走，系统依赖 NTP；
- RTD129x 无主线时钟驱动（SCPU 除外），网卡与 USB 依赖 bootloader 留下的时钟门
  + probe 期 quirk；
- i2c 总线引脚由 bootloader 留在 GPIO 态，内核未设复用：i2c-rtk/G2227 驱动可编为
  模块但需手工设置引脚复用后方可通信（诊断用途）；
- `r8169soc` 启动时会记录两次无害的 `rtl_csiar_cond` 超时；
- netrescue 提供无密码的 telnet root shell，只能在可信局域网临时使用；
- 当前测试范围只有一台单盘版设备，且未经长期运行验证。
