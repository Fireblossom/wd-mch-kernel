# WD My Cloud Home (RTD1295) 主线内核移植

把 WD My Cloud Home（Realtek RTD1295）从厂商 Android/4.9 内核迁移到
Linux 6.18.2 + Debian 13。**2026-07-27 达成可用状态**：B 槽自建内核，
四核 SMP、UART 真中断、千兆以太网、USB 3.0、Docker/OMV、NFS/SMB、软重启和
SoC 温度监控均已通过实机验证；v46 又加入了免串口槽位切换和一次性网络救援。
Debian 13 trixie 约 34 秒进入 graphical.target，断电后网络和 SSH 可无人值守恢复。

## 硬件

| 项 | 值 |
|---|---|
| SoC | Realtek RTD1295，Cortex-A53 ×4（v32 起全核可用） |
| RAM / 盘 | 1 GiB / Intel SSDSC2KW256G8 256G SATA |
| 串口 | 115200 8N1，UART0 @ 0x98007800 |
| 引导 | 两阶段 U-Boot 2015.07（1st AArch32 → 2nd AArch64），`bootr` |
| 网络 | 千兆 GMAC；设备与 TFTP 服务端地址由现场网络决定 |

## 仓库布局

| 路径 | 说明 |
|---|---|
| `linux-6.18.2/` | 构建树（**含本地补丁**，见下）。`.config` 已强制入库 |
| `initramfs/` | 内嵌 initramfs 源（BusyBox + mdadm + init 脚本，含 `apply_rootfs_fixups`） |
| `rtd1295_*.config` | merge_config 片段：基础系统、Docker/NAS、网络、USB、thermal 等 |
| `rebuild_package_and_print_flash.sh` | 一键：编内核→patch Image 头→零填充→生成 fw_table（⚠️ 它不打印 DTB 刷写命令，DTB 要手动刷） |
| `fw_table_v*.bin`、`rtd1295-*-v*-padded.dtb` | 历代产物；当前在役见下表 |
| `extracted.dts` | 厂商 4.9 设备树反编译参考（irq mux / uart / i2c 节点照这里抄） |
| `DEBUG_SESSION_2026-04-20.md` | 4 月会话记录，可信 |
| `DRIVER_PORTING_GUIDE.md` 等旧 guide | ⚠️ 结论过时（还说 I2C 是阻塞项），只当历史参考 |
| GPL 厂商包（未入库） | `~/nas/GPL_MCH_Monarch_*/`：spin table、GMAC 驱动等参考实现 |

## 相对 vanilla 6.18.2 的本地改动

- `arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dts` — 本板 DTS（历代演进全在注释里）
- `arch/arm64/kernel/smp_spin_table.c` — release addr 非内存时用厂商访问模式（32 位设备写；v32 起）
- `drivers/irqchip/irq-rtd129x.c/.h` — 厂商 irq mux 移植 + ACK-first 补丁；Kconfig 去掉 `if COMPILE_TEST` 门
- `.config` — 含 `CONFIG_IRQ_RTD129X_MUX=y` + systemd 依赖（cgroups 等） 

## 构建与刷机速查

```bash
# 服务器上打包（自动重编内核 + fw_table）
./rebuild_package_and_print_flash.sh --version vNN --base-fw fw_table_v23.bin \
    --dtb rtd1295-wd-mycloud-home-vNN-padded.dtb

# DTB 手工管线（rebuild 脚本不管 DTB 编译）
make -C linux-6.18.2 ARCH=arm64 dtbs
dtc -I dtb -O dtb -p 16384 linux-6.18.2/.../rtd1295-wd-mycloud-home.dtb -o out.dtb
# 零填充到 28672B；fw_table 里 DTB 校验和 = sum(bytes)&0xFFFFFFFF
```

刷机流程见发布包中的
[`docs/FLASHING.md`](release/wd-mch-kernel-6.18.2-r1/docs/FLASHING.md)；
救援和槽位切换见
[`docs/RESCUE.md`](release/wd-mch-kernel-6.18.2-r1/docs/RESCUE.md)。
流程为断电→bootcode banner 后用 Esc 进入一阶段 `Realtek>`→TFTP→`sata write`→抓首启。
B 槽地址：FW_TABLE `0x22/0x10`、FDT_B `0x31000/0x38`、KERNEL_B `0x33800/按大小`。
**永不写 Gold 槽（sda9/10/16）**——那是 `sgboot` 救援路径。

## 在役版本

| 件 | 版本 | 校验和 |
|---|---|---|
| 内核 | #35（v46：全功能 NAS + netrescue） | ✅ 实机验证 |
| DTB | v22（四核、UART/GMAC、USB3、thermal、RTC 节点） | ✅ |
| fw_table | v46 | ✅ |

实测：4 CPU、ttyS0 irq 34、eth0 RTL8169SOC、USB 3.0 5Gbps（机械盘持续读取
137 MB/s）、Docker/OMV 8、NFS/SMB、软重启和 thermal zone 均工作；断电重启后
网络/SSH 无人值守恢复。发布包为
[`wd-mch-kernel-6.18.2-r1.tar.gz`](release/wd-mch-kernel-6.18.2-r1.tar.gz)。

回滚可走 A 槽厂商 4.9 内核或 GOLD 救援槽；B 槽历史稳定点包括 v42、v38、v36、
v34、v32、v31、v27 和 v21。不要覆盖 A/GOLD 槽。

## 遗留项

1. ✅ ~~SMP 单核~~ —— v32 修复（`smp_spin_table.c`，git 0406c4e6c）
2. ✅ ~~UART 轮询~~ —— v34 修复（git cc2bb90b4）。当年"bit2 清不掉"是探针假象：
   ISO_ISR 是正常 W1C 事件锁存（bit0=WRITE_DATA，见厂商 rtk_iso.h），但 devmem
   命令本身的串口流量会重新置位；真凶是 mux handler 里的 printk 在 console 串口上
   自我喂养。教训：**console 所在总线的中断处理器里永远不要 printk**
3. ✅ ~~以太网~~ —— v36 修复（git 28b3337）：厂商 r8169soc 移植 + 两处漏改的裸
   clk_get 修掉 + NET_VENDOR_REALTEK 的 PCI 门放宽。⚠️ 同类教训第三次出现：
   **驱动移植完成 ≠ 能被选上——每次都要查 Kconfig 依赖链能否成立**
4. ✅ ~~USB/存储/NAS 功能~~ —— v37–v42 完成 Docker、NFS/ACL、软重启、
   USB 3.0、thermal 等；详见对应提交。
5. 当前小项：RTC 已注册但不走针（依赖 NTP）；r8169soc 偶发
   `rtl_csiar_cond` 超时提示但不影响功能；u2host/u3host 是未接物理端口的空根集线器。
6. netrescue 提供无密码 telnet root shell，只应在可信局域网中临时使用；
   引导器不会自动递减尝试次数，槽位失败时也不会自动回滚，详见
   [`docs/RESCUE.md`](release/wd-mch-kernel-6.18.2-r1/docs/RESCUE.md)。
