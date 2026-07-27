# WD My Cloud Home（RTD1295）Linux 6.18.40 候选刷机包 r2-rc1

这是 Linux 6.18.40 LTS 升级的首个候选包，只供真机验证。它已经通过源码完整性、
内核编译、设备树编译、镜像封装和固件表校验，但在标记为正式 `r2` 之前，尚不能
替代经过长期真机验证的 `r1`。

本包只更新 B 槽的内核、设备树和固件表，不安装 Debian，也不会主动写入 A 槽或
GOLD 救援槽。

> [!WARNING]
> 刷写错误的扇区可能导致设备无法启动。测试者必须连接 115200 8N1 串口，提前
> 备份当前 B 槽，并确认 A 槽和 GOLD 救援路径仍然可用。

## 适用范围

- 单盘版 WD My Cloud Home，Realtek RTD1295；
- 已安装 Debian 13 arm64，根文件系统位于 `/dev/md1`；
- 可以进入一阶段 U-Boot 串口控制台；
- 局域网内有 TFTP 服务器。

My Cloud Home Duo、其他 RTD1295 产品和不同的磁盘布局均未验证。

## 当前验证状态

| 项目 | 状态 |
|---|---|
| 官方 Linux 6.18.40 源码校验 | 已通过 |
| 板级补丁应用 | 已通过 |
| `Image` 和 WD My Cloud Home DTB 编译 | 已通过 |
| RTD1295 镜像头、填充和 `fw_table` 内部校验 | 已通过 |
| SHA-256 和归档内容检查 | 已通过 |
| 真机冷启动、SMP、网络、USB、存储和软重启 | **待验证** |

## 包内文件

`flash/` 下的三个固件文件是一套，不能和 `r1` 或旧开发产物混用：

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

首次启动时不要立刻把 B 槽设为永久启动目标。至少验证：

- `uname -r` 显示 `6.18.40`；
- 四个 Cortex-A53 CPU 均上线；
- `/dev/md1` 能正常挂载并进入 Debian/systemd；
- 板载网卡使用出厂 MAC，SSH 和持续传输正常；
- USB 3.0 设备协商到 5 Gbit/s；
- SATA、Docker、NFS/SMB 和温度读取正常；
- 软重启能够再次进入同一系统。

验收失败时不要提交 B 槽，按救援文档切回 A 或 GOLD。

## 已知限制

- RTC 能注册但时钟不走，系统依赖 NTP；
- `r8169soc` 偶尔可能记录 `rtl_csiar_cond` 超时；
- netrescue 提供无密码的 telnet root shell，只能在可信局域网临时使用；
- 当前测试范围只有一台单盘版设备。
