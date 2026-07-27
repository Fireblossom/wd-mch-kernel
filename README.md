# WD My Cloud Home（RTD1295）Linux 6.18.2 移植

本仓库为单盘版 WD My Cloud Home（Realtek RTD1295）提供 Linux 6.18.2
板级适配源码，以及一套已在真机验证的 B 槽刷机包。

这不是 WD 官方固件，也不是完整的 Debian 安装器。现有刷机包假定设备已经安装
Debian 13（arm64，根文件系统位于 `/dev/md1`）。目前只在一台单盘版
My Cloud Home 上验证；My Cloud Home Duo 和其他 RTD1295 设备不在已验证范围内。

> 刷错分区可能使设备无法启动。首次操作必须连接 115200 8N1 串口、备份原分区，
> 并且只写 B 槽。不要写 A 槽或 GOLD 救援槽。

## 从哪里开始

如果你只是想使用现成内核：

1. 确认设备符合上面的适用条件。
2. 下载 [`wd-mch-kernel-6.18.2-r1.tar.gz`](release/wd-mch-kernel-6.18.2-r1.tar.gz)。
3. 阅读[刷机包说明](release/wd-mch-kernel-6.18.2-r1/README.md)。
4. 按[刷机步骤](release/wd-mch-kernel-6.18.2-r1/docs/FLASHING.md)操作。
5. 开始前先了解[回滚、槽位切换和网络救援](release/wd-mch-kernel-6.18.2-r1/docs/RESCUE.md)。

如果你准备修改或移植内核，请从 `linux-6.18.2/`、本页的“源码与构建”和
[`DEVELOPMENT_HISTORY.md`](DEVELOPMENT_HISTORY.md)开始。仓库中的早期调试笔记记录了
探索过程，可能包含已经失效的结论，不应当作当前操作手册。

## 当前推荐版本

| 项目 | 内容 |
|---|---|
| 面向用户的发行版 | **r1** |
| 上游内核基线 | Linux 6.18.2 |
| 目标设备 | 单盘版 WD My Cloud Home / Realtek RTD1295 |
| 目标启动槽 | B 槽；A 和 GOLD 保持原样 |
| 根文件系统 | 已安装的 Debian 13 arm64，`/dev/md1` |
| 对应源码 | 提交 `aeae8812a`，另加公开发布文档 |
| 验证状态 | 真机冷启动、软重启、网络和 SSH 恢复均通过 |

普通用户只需要选择 `r1`，不需要从仓库里的 `v21`、`v38`、`v46` 等文件中挑选。

## 版本号为什么有好几种

开发日志保留了移植期间使用的内部编号。它们的含义如下：

| 写法 | 含义 | 是否供用户选择 |
|---|---|---|
| `6.18.2` | 上游 Linux 内核版本 | 是，用于了解内核基线 |
| `r1` | 本项目对外发布的整套刷机包版本 | **是，当前应选这个** |
| `v21`…`v46` | 开发期间某次“内核 + DTB + fw_table”组合的流水号 | 否，仅用于追溯实验 |
| 内核 `#35` | 本地编译计数，来自内核版本字符串 | 否 |
| DTB `v22` | 开发期间设备树二进制的迭代号 | 否 |

这些内部编号不是语义化版本、Git tag 或相互兼容性声明。例如开发组合 `v46`
内部使用了 DTB `v22`；数字不同并不表示文件缺失。对外发布时三个文件已经改成
中性文件名并固定为一套，必须一起使用：

```text
Image-6.18.2-mch
mch.dtb
fw_table.bin
```

各内部里程碑解决了什么问题，见
[`DEVELOPMENT_HISTORY.md`](DEVELOPMENT_HISTORY.md)。该文档用于维护和审计，不是下载清单。

## 已验证功能

| 能力 | 状态 |
|---|---|
| Cortex-A53 四核 SMP | ✅ |
| UART0 中断模式，115200 8N1 | ✅ |
| 板载千兆以太网及出厂 MAC | ✅ |
| 后置 USB 3.0 Type-A，5 Gbit/s | ✅ |
| Debian 13 / systemd | ✅ |
| Docker、OpenMediaVault 8 | ✅ |
| NFS、SMB 所需 ACL/xattr、配额 | ✅ |
| TUN、WireGuard、dm-crypt、FUSE、zram | ✅ |
| 看门狗软重启 | ✅ |
| SoC 温度读取和 thermal zone | ✅ |
| B/A/GOLD 槽位切换、一次性网络救援 | ✅，限制见救援文档 |

USB 3.0 使用机械盘实测持续读取约 137 MB/s。实际速度取决于硬盘、文件系统和负载。

## 刷写与回滚边界

`r1` 中的内核、DTB 和 `fw_table` 是一个不可拆分的组合。`fw_table` 记录另外两个
文件的长度和校验和，不能混用不同开发阶段的文件。

刷机只涉及以下 B 槽位置：

| 内容 | SATA 起始扇区 | 写入扇区数 |
|---|---:|---:|
| `fw_table.bin` | `0x22` | `0x10` |
| `mch.dtb` | `0x31000` | `0x38` |
| `Image-6.18.2-mch` | `0x33800` | `0x7e60` |

完整命令、传输大小检查和备份方法以
[`FLASHING.md`](release/wd-mch-kernel-6.18.2-r1/docs/FLASHING.md)为准。
不要覆盖 A 槽或 GOLD 槽；它们是主线内核无法启动时的独立退路。引导器不会自动
递减尝试次数，也不会自动回滚，具体行为见
[`RESCUE.md`](release/wd-mch-kernel-6.18.2-r1/docs/RESCUE.md)。

## 源码与构建

主要目录：

| 路径 | 用途 |
|---|---|
| `linux-6.18.2/` | Linux 6.18.2 源码和本板补丁；`.config` 已入库 |
| `initramfs/` | 内嵌 initramfs：BusyBox、mdadm、根文件系统交接和网络救援 |
| `rtd1295_*.config` | systemd、NAS、网络、USB、thermal 等配置片段 |
| `rebuild_package_and_print_flash.sh` | 维护者打包工具：修补 Realtek Image 头、填充并更新 `fw_table` |
| `release/wd-mch-kernel-6.18.2-r1/` | 面向用户的 r1 文件和文档 |

已入库 `.config` 中的 `CONFIG_INITRAMFS_SOURCE` 是构建服务器的绝对路径。换机器后
先改成当前检出目录，再编译：

```bash
cd /path/to/wd-mch-kernel

linux-6.18.2/scripts/config \
  --file linux-6.18.2/.config \
  --set-str INITRAMFS_SOURCE "$PWD/initramfs"

make -C linux-6.18.2 ARCH=arm64 olddefconfig
make -C linux-6.18.2 ARCH=arm64 -j"$(nproc)" Image dtbs
```

在非 arm64 主机交叉编译时，还需要设置合适的 `CROSS_COMPILE`。上一步生成的是原始
Linux `Image`，**不能直接写盘**；设备要求兼容头、固定填充以及与 DTB 匹配的
`fw_table`。`rebuild_package_and_print_flash.sh` 是当前维护者环境使用的打包工具，
其中仍有 `/home/ubuntu/linux` 绝对路径，外部使用前应先审阅并参数化。

相对原版 Linux 6.18.2，核心板级改动包括：

- WD My Cloud Home 的 RTD1295 DTS；
- RTD129x interrupt mux 及 UART 中断处理；
- RTD1295 CPU release-address 的设备寄存器访问；
- 板载 Realtek GMAC 支持；
- DWC3/PHY、USB 3.0 lane 设置；
- RTD129x thermal 和看门狗重启；
- 适用于 Debian 13、容器和 NAS 的内核配置。

## 已知限制

- RTC 能注册但不走针，系统时间依赖 NTP。
- `r8169soc` 偶尔打印 `rtl_csiar_cond` 超时提示，当前实测不影响网络。
- 网络救援提供无密码 telnet root shell，只能在可信局域网内临时使用。
- 当前测试覆盖一台设备，不能据此保证其他硬件修订或其他 RTD1295 产品兼容。

## 许可证与来源

Linux 内核及本仓库中的相应修改遵循 GPL-2.0。源码基线、厂商参考资料和发布包对应
关系见 [`SOURCES.md`](release/wd-mch-kernel-6.18.2-r1/SOURCES.md)。
