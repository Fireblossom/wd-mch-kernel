# WD My Cloud Home (RTD1295) 主线内核移植

把 WD My Cloud Home（Realtek RTD1295）从厂商 Android/4.9 内核迁移到主线
Linux 6.18.2 + Debian 13。**2026-07-27 起设备可用**：B 槽跑自建内核，**四核 SMP（v32 起）+
UART 真中断（v34 起）**，Debian 13 trixie 约 34 秒进 graphical.target，
串口 **root autologin** 直接进 shell。剩余大项只有以太网（见「遗留项」）。

**总日志（最详细、含全部根因和踩坑）在 Mac 上：`~/.wd-debug/WORKLOG.md`。**
本 README 只负责让新会话/新人在这个仓库里快速定位。

## 硬件

| 项 | 值 |
|---|---|
| SoC | Realtek RTD1295，Cortex-A53 ×4（v32 起全核可用） |
| RAM / 盘 | 1 GiB / Intel SSDSC2KW256G8 256G SATA |
| 串口 | 115200 8N1，UART0 @ 0x98007800（Mac 侧 /dev/cu.usbserial-AY4PF6MZ） |
| 引导 | 两阶段 U-Boot 2015.07（1st AArch32 → 2nd AArch64），`bootr` |
| 网络 | Mac/TFTP 192.168.123.191（DHCP 会漂，刷机前确认）、设备 192.168.123.164 |

## 仓库布局

| 路径 | 说明 |
|---|---|
| `linux-6.18.2/` | 构建树（**含本地补丁**，见下）。`.config` 已强制入库 |
| `initramfs/` | 内嵌 initramfs 源（BusyBox + mdadm + init 脚本，含 `apply_rootfs_fixups`） |
| `rtd1295_*.config` | merge_config 片段：cmdline/initramfs/compat32/mdraid/irqmux/systemd |
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

刷机在 Mac 上全自动：`python3 ~/.wd-debug/bin/flash_v23.py`（复制改 FILES 表），
断电→bootcode banner 后连发 Esc 进一阶段 `Realtek>`→TFTP→`sata write`→抓首启。
B 槽地址：FW_TABLE `0x22/0x10`、FDT_B `0x31000/0x38`、KERNEL_B `0x33800/按大小`。
**永不写 Gold 槽（sda9/10/16）**——那是 `sgboot` 救援路径。

## 在役版本

| 件 | 版本 | 校验和 |
|---|---|---|
| 内核 | #23（v34：+ mux handler 静默化）cksum 0x3fde8232 | ✅ 实机验证 |
| DTB | v18（spin-table ×4 + mux okay + uart0 挂 ISO mux <1 2>）cksum 0x000484fd | ✅ |
| fw_table | v34 | ✅ |

实测：ttyS0 at irq 34（RTK_IRQ_MUX 分发，/proc/interrupts 正常计数）、
`smp: Brought up 1 node, 4 CPUs`、零风暴、autologin root shell。

回滚链：v31（#20+v16，稳态可登录）→ v27（#19+v14）→ v21（#15+v11，4 月老稳态）。
产物都在 Mac `~/.wd-debug/tftp/`。

## 遗留项

1. ✅ ~~SMP 单核~~ —— v32 修复（`smp_spin_table.c`，git 0406c4e6c）
2. ✅ ~~UART 轮询~~ —— v34 修复（git cc2bb90b4）。当年"bit2 清不掉"是探针假象：
   ISO_ISR 是正常 W1C 事件锁存（bit0=WRITE_DATA，见厂商 rtk_iso.h），但 devmem
   命令本身的串口流量会重新置位；真凶是 mux handler 里的 printk 在 console 串口上
   自我喂养。教训：**console 所在总线的中断处理器里永远不要 printk**
3. 以太网无驱动：厂商 GMAC 在 GPL 包 `drivers/net/ethernet/realtek/`，或 USB 网卡过渡
4. Debian 侧：串口已配 **root autologin**（`/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf`，
   拿到串口线即 root——调试期便利，收尾时删掉该文件并 `passwd` 设口令）；
   serial-getty 的 /dev/null mask 已由 initramfs fixup 自动解除
