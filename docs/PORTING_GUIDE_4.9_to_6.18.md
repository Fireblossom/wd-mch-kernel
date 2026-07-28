# 从厂商 Linux 4.9.330 移植到主线 Linux 6.18.40

**目标设备**：WD My Cloud Home（单盘型号，Realtek RTD1295 "Monarch"/"Kamino" 平台，ARM Cortex-A53 ×4，1 GiB DRAM）

**成果**：主线 6.18.40 内核在真机运行完整 Debian 13 + OpenMediaVault 8，四核 SMP、串口中断、千兆网、USB3、温度传感、软重启、NFS/SMB、Docker 全部可用。

本文是**移植过程的技术说明**：每一处源码改动为什么必要、怎么定位、改了什么。它不是刷机说明（见 [README.md](README.md) 与 [docs/FLASHING.md](docs/FLASHING.md)），也不是版本编年史（见 [DEVELOPMENT_HISTORY.md](DEVELOPMENT_HISTORY.md)）。

---

## 0. 先读这一节：这个移植的性质

主线内核对 RTD1295 的支持**比想象的完整得多**。移植工作的实际分布大致是：

| 类别 | 占比 | 说明 |
|---|---|---|
| 让已存在的主线驱动能被选中 | 最大 | 三个驱动躺在主线树里但 Kconfig 依赖不可满足，永远选不上 |
| 适配厂商引导器的约定 | 次之 | Image 头、fw_table、DTB padding——与内核功能无关，但不做就完全不启动 |
| 用主线机制表达厂商私有语义 | 中等 | spin-table、irq mux、reset、时钟门 |
| 真正新写的代码 | 最小 | 一个 ~100 行 thermal 驱动 + 一处 watchdog 补丁 |
| 从厂商树整体搬运 | 一个文件 | `r8169soc.c`（以太网，厂商 platform 版 r8169） |

**最反复踩的一类坑**：驱动代码在主线树里，Makefile 也有，但 Kconfig 的 prompt 被不可满足的条件门住，于是 `.config` 里根本不存在该符号，驱动从未被链接。这一类踩了三次（irq mux 的 `if COMPILE_TEST`、`NET_VENDOR_REALTEK depends on PCI`、`R8169SOC depends on ARCH_RTD129x`）。**排查手法**：`grep` 符号名在 `.config` 里零命中 + `System.map` 零命中 = 驱动没编进去，别再怀疑 DTS。

**厂商 GPL 包是唯一权威参考**，不是可选读物。位置：
```
GPL_MCH_Monarch_9.9.0-102_20251211/   # U-Boot 源码在这里
GPL_MCH_Monarch_9.7.0-104_20241205/kernel/linux-4.9.330/   # 4.9 内核树
```
凡是"寄存器语义猜不出来"的地方（thermal 采样序列、type-c lane switch、ISO_ISR 的 W1C 约定、spin-table 的写宽度），答案都在厂商驱动里，而且往往只有几十行。

---

## 1. 引导链：与内核功能无关，但决定能否出一个字符

这是整个移植最容易卡死人的部分，因为失败模式是**完全静默**——没有 panic、没有 earlycon、没有任何输出。

### 1.1 存储布局

设备只有一块 SATA 盘，21 个分区。固件三槽共用一张固件表：

| 用途 | 分区 | 起始 LBA | 扇区数 |
|---|---|---:|---:|
| FW_TABLE | sda1 | `0x22` | `0x10`（8192 B） |
| **FDT_B** | sda6 | `0x31000` | `0x38`（28672 B） |
| **KERNEL_B** | sda8 | `0x33800` | 随内核大小（6.18.40 r2 为 `0x7ee8`） |

主线内核**只写 B 槽**这三处。A 槽（sda2/5/3）与 GOLD 槽（sda16/10/9）永不触碰——原因见 §1.6，这不是保守，是安全红线。

### 1.2 fw_table 结构（sda1，恰好 8192 字节）

```
偏移      内容
0x00      魔数 "VERONA__"
0x08      u16 头部校验和  ← 算法：sum(fw[0x0A:]) & 0xFFFF（跳过魔数与自身）
0x18      u32 part_list_len = 0xC0 (192)
0x1C      u32 fw_list_len   = 0x1A0 (416 = 13 × 32)
0x20      分区表 192 字节
0xE0      13 条固件描述符，每条 32 字节
```

**条目步长是 32 字节。** 早期文档误记为 0xC0，那是每 6 条采样一次造成的错觉。

单条目内的字段偏移（打包脚本实际使用的）：

```
+0    u8  type（FW_TYPE）
+1    u8  flags（0x80）
+8    u32 载入地址 >> 16
+14   u32 实际字节数
+18   u32 分配字节数
+22   u32 内容附加校验和  ← sum(每个字节) & 0xFFFFFFFF，对补齐后的数据算
```

FW_TYPE 决定条目归属哪个槽：

| 槽 | FW_TYPE |
|---|---|
| A（`BOOT_NORMAL_MODE`） | KERNEL=2, KERNEL_DT=4, KERNEL_ROOTFS=6, AFW=7 |
| **B（`BOOT_RESCUE_MODE`，主线内核住这里）** | **RESCUE_KERNEL=43, RESCUE_DT=3**, RESCUE_ROOTFS=5, RESCUE_AUDIO=44 |
| GOLD（`BOOT_GOLD_MODE`） | 31–34 |

启动 B 槽时 U-Boot **只读取并校验 B 槽条目**，A/GOLD 的条目走 `default: continue`，其分区内容根本不被读。这条源码事实很有用：A/GOLD 分区可以改用，只要 sda1 里的描述符字节保持自洽（整表共用一个头部校验和）。

打包时只改两条：文件偏移 **0x1A0**（RESCUE_DT，type `0x03`）和 **0x260**（RESCUE_KERNEL，type `0x2B`=43）的 `+14/+18/+22`，然后重算头部校验和。A/GOLD 条目逐字节保留。

### 1.3 ARM64 Image 头补丁：静默死机的元凶

**症状**：刷完新内核后完全没有输出，连 earlycon 都没有，像砖了一样。

**根因**：6.18 的 PIE/可重定位内核在 Image 头里写 `text_offset = 0`。而厂商二阶段是 U-Boot 2015.07，它的 `booti` 会把 Image **照字面**拷到 `DRAM_BASE + text_offset` = `0x00000000`——正好覆盖 U-Boot 自己和异常向量表。CPU 在解压前就死了，所以一个字符都出不来。

**修法**：二进制改写 Image 头三个字段（打包脚本已自动化）：

```python
struct.pack_into("<I", kernel,  0, 0x91005A4D)   # code0：一条合法 AArch64 指令，兼容 MZ 头
struct.pack_into("<Q", kernel,  8, 0x200000)     # text_offset = 0x200000
struct.pack_into("<I", kernel, 60, 0x40)         # pe_offset = 0x40
```

改之前先校验偏移 56 处的 arm64 魔数 `0x644D5241`（"ARM\x64"），避免改错文件。

### 1.4 大小限制与不压缩

二阶段 U-Boot 的 `CONFIG_SYS_BOOTM_LEN` 把解压上限卡在约 20 MB，而 6.18 解压后约 22 MB → `inflate() returned -5`。两个应对：

- `CONFIG_CC_OPTIMIZE_FOR_SIZE=y` + 关掉调试选项压缩体积；
- **改走未压缩的 raw Image**——二阶段 U-Boot 被裁到只剩 `booti`/`fdt`，根本没有 `unzip` 命令。

### 1.5 DTB 的两个陷阱

**陷阱一：`FDT_ERR_NOSPACE`。** U-Boot 运行时会往 DTB 里插 `/factory` 节点（序列号、MAC、IP 等）。编译 DTB 必须留头部空间：`dtc -p 16384`。

**陷阱二：padding 不等于可用空间（r2 才修对）。** DTB 补齐到 `0x7000` 字节只是文件变长了；U-Boot/libfdt 判断"还有多少地方能写"看的是 **FDT 头里的大端 `totalsize` 字段（偏移 4）**，不是文件长度。所以补齐后必须把 `totalsize` 一并改写为 `0x7000`，padding 才真正成为运行时可用的 FDT 空间。改完用 `dtc -I dtb -O dts` 反解析验证。

### 1.6 写盘规则与槽位选择

`sata write` 按 512 字节整扇区写，多余扇区里是 RAM 残留垃圾，会破坏附加校验和。规则：**主机侧零填充，扇区数必须恰好等于 padded_bytes / 512**。内核补齐到 4096 字节边界。

写序永远是 **DTB → 内核 → fw_table 最后**。fw_table 是提交点：在它之前任何一步失败，盘上仍是自洽的旧配置，断电重启照旧启动旧内核。

槽位由 sda18（FAT32）上 16 字节的 `bootConfig` 文件决定，格式 `<bootState>:<nbr>:<bna>:;`，正常值 `0:F:0:;`。

| bootState | 行为 |
|---|---|
| 0 NO_OTA | 启动 U-Boot 环境里 `cbr` 指向的槽 |
| 1 INIT | `cbr=A` 并启动 A |
| 2 OTA_TRIGGERED | 启动 `nbr`（需 1≤`bna`≤5） |
| 3 OTA_PASSED | 把 `nbr` 提交为 `cbr` |
| 4 OTA_FAILED | 退回 `cbr` |
| **5 RECOVERY** | **启动 GOLD** |

两条必须知道的事实：

1. **U-Boot 从不递减 `bna`（源码确认无写回）→ 没有自动回滚。** 选中的槽会一直被启动，直到 bootConfig 再次被改。所以不能指望"新内核失败会自己退回来"。
2. **GOLD 不是救援环境，是出厂重置器。** 它的 rootfs 是 Android 6.0.1 recovery，`init.rc` 经硬编码的 `ro.debuggable=1` 属性触发器**无条件**启动 `do_reset.sh`，后者按分区号硬编码出厂布局并执行 `mke2fs -E discard`。在重新分区过的盘上这会抹掉用户数据分区，且 `-E discard` 会对 SSD 下发 TRIM，数据在闪存层面即刻不可恢复（本项目 2026-07-27 实测踩中）。**永远不要启动 GOLD。** 好消息是 Realtek 原本"启动失败自动回退 GOLD"的逻辑被 WD 用 `#if 0` 关掉了（注释 KAM-8762），所有失败路径走 USB 救援 → DHCP 救援 → 串口控制台，不会自己掉进 GOLD。

手动引导（停在二阶段 `Realtek>` 时）：

```
booti 0x03000000 - 0x01f00000
```

打断二阶段 autoboot 要在 `bootr` **之前** `env set bootdelay 5`，否则窗口太短。TFTP 载入地址统一用 `0x04000000`。

---

## 2. 症状 → 根因 → 修法（按时间顺序）

这一节是排错索引。每条都是真机实测确认过的，不是推测。

### 2.1 引导链阶段（2026-04）

**① 完全静默，连 earlycon 都没有**
PIE 内核 `text_offset=0`，U-Boot 2015.07 `booti` 拷到地址 0 覆盖了自己。→ 二进制改 Image 头（§1.3）。

**② `inflate() returned -5`**
`CONFIG_SYS_BOOTM_LEN` ≈20 MB < 22 MB 解压体积。→ 缩小体积 + 改走未压缩 Image（§1.4）。

**③ DTB 里的 `bootargs` 不生效**
默认 `CONFIG_CMDLINE_FROM_BOOTLOADER=y`，U-Boot 传来的空/错 bootargs 赢了。→ `CONFIG_CMDLINE_FORCE=y`，并把 `earlycon=uart8250,mmio32,0x98007800 console=ttyS0,115200 panic=5` 写死进 `CONFIG_CMDLINE`。
⚠️ 遗留隐患：板级 DTS 的 `bootargs` 至今写着 `root=/dev/sda9 rootfstype=ext4`（sda9 其实是 gzip+cpio 流，不是 ext4），目前只是被 `CMDLINE_FORCE` 盖住。哪天去掉 FORCE 就会炸。

**④ AHCI 探测失败 `-EBUSY: can't request region [mem 0x9803f000-...]`**
厂商 DTS 的 `rsvmem-remap` 节点 `rbus@98000000` 圈了 `0x98000000–0x981fffff`，把 SATA 控制器的 MMIO 一起包进去了。→ DTS 里删掉**所有** `rsvmem-remap` 节点。

**⑤ 32 位厂商用户态二进制 `Exec format error`**
→ `CONFIG_COMPAT=y`。

**⑥ `init: required argument missing.` 然后掉进 BusyBox**
Debian 的 `/sbin/init` 是 systemd（usr-merge），systemd 以 system 模式运行时**要求自己是 PID 1**，而 `chroot` 不替换 PID 1。
佐证：厂商自己的 Debian 安装包早期用户态用的就是 `exec switch_root /mnt /sbin/init`——官方路径本来就是 switch_root。
→ initramfs 的 Debian/mdraid 分支改用 `exec /bin/busybox switch_root -c /dev/console "$root" "$init"`，并加 `cleanup_newroot()` 清理失败残留（这同时解决了重试时的 `mounting sysfs on /newroot/sys failed: -EBUSY`）。
⚠️ 厂商 gzip+cpio 救援分支**故意保留 chroot**：那条路径上 vendor init 退出会让 PID1 panic。
⚠️ BusyBox 的 `switch_root` 自身也要求调用者是 PID 1，所以 initramfs 必须保持 PID 1。

### 2.2 功能补全阶段（2026-07）

**⑦ SMP 硬挂在副核唤醒前（无 panic、无输出）**
主线 `smp_spin_table.c` 对 release address 用 `ioremap_cache`（可缓存映射）+ 64 位 `writeq` + dcache 维护；但 `0x9801AA44` 是**设备寄存器区**，这么访问会把总线锁死。厂商 `rtd129x_spin_table.c` 用的是 plain `ioremap` + 32 位 `writel_relaxed`。
→ 见 §3.1 的 `smp_spin_table.c` 补丁。一次命中，四核起来。

**⑧ switch_root 成功但 systemd 冻结：`Failed to mount cgroup v1 hierarchy`**
瘦身配置裁掉了 CGROUPS/SYSVIPC/POSIX_MQUEUE/TMPFS_POSIX_ACL/AUTOFS_FS。→ `rtd1295_systemd.config` 片段。补上后 34 秒到 `graphical.target`。

**⑨ uart0 挂上 irq mux 后控制台彻底死掉（无 ttyS0 → init 死）**
`irq-rtd129x.c` 在主线树里、Makefile 也有，但 Kconfig 的 prompt 被 `if COMPILE_TEST` 门住 → `.config` 里没有 `CONFIG_IRQ_RTD129X_MUX` 这个符号 → 驱动从未链接 → uart0 的 `interrupt-parent` 指向一个永不绑定的 irqchip → fw_devlink 无限 defer。
（此前能用控制台是因为 DTB 没写 `interrupts` 属性，dw8250 报 ENXIO 后退化成轮询模式。）
→ 去掉 COMPILE_TEST 门，`CONFIG_IRQ_RTD129X_MUX=y`。

**⑩ ttyS0 拿到真中断后出现自维持日志风暴（150 秒 607 行）**
两层根因：
- 主线 8250 不会 ACK ISO mux 的状态寄存器（厂商靠自家 8250 fork 配 `interrupts-st-mask` 做这件事）；
- **mux handler 里的 `pr_err` 打到了骑在同一个 UART 上的 console** → 每打一行就产生 TX 中断 → 再进 handler → 再打印。自我喂养。

顺带一个**方法论陷阱**：当时观测到 ISO_ISR bit2"写了清不掉"，判断为硬件卡死。其实是测量假象——devmem 探针命令本身走同一个串口，每条命令的收发就是新的 uart 中断，把刚清掉的位又置回来了。用**同一行命令零流量清+读**，回读是 0，W1C 完全正常（寄存器约定见厂商 `rtk_iso.h`：`BIT(n)|0` 清、`BIT(n)|1` 置）。
→ 见 §3.2：dispatch 前先 W1C ACK + 热路径删除所有 printk + 删掉厂商"强清"死代码。
**教训**：console 所在总线的中断处理器里，永远不要 printk。

**⑪ Debian 起来了但没有登录提示**
镜像里 `/etc/systemd/system/serial-getty@ttyS0.service -> /dev/null`（做镜像时 mask 掉的）。→ initramfs 的 `apply_rootfs_fixups()` 在 switch_root 前删掉该 mask，getty-generator 会自动实例化。

**⑫ 以太网驱动在菜单里根本选不出来**
`NET_VENDOR_REALTEK depends on PCI || (PARPORT && X86)`——这块 SoC 没有 PCI。→ 加 `|| ARCH_REALTEK`。（"驱动已移植但选不上"家族的第三次）

**⑬ 以太网 probe Oops → panic**
`rtl_init_one` 里有两处漏改的裸 `clk_get`，返回的 ERR_PTR 流进 `__clk_is_enabled`。RTD129x 没有主线时钟驱动，时钟只能靠 bootloader 留下的门。→ 换成 `rtl_clk_get_optional` helper，返回 NULL 时走直接寄存器 bring-up 分支。修好后 eth0 从硬件读回出厂 MAC，千兆协商成功。
（已知无害噪声：`rtl_csiar_cond` 超时告警 ×2。）

**⑭ USB：裸 `snps,dwc3` 节点报 `-EBUSY`，资源区间倒挂**
主线 dwc3 把 globals 块硬编码在 0xc100，RTD1295 实际是 **0x8100**（厂商 `fixed_dwc3_globals_regs_start`）。
→ 解法不是打补丁：父节点用 compatible **`realtek,rtd-dwc3`**，触发主线内置的 RTD globals-offset quirk。（dwc3-rtk glue、phy-rtk-usb2/usb3 全都已在主线树里。）

**⑮ dwc3 probe 读 GSNPSID 得到垃圾**
`clk_en_usb`（CRT 0x0c bit4）**bootloader 默认关闭**，而 initramfs 里 poke 这个门的时机晚于 probe。用运行时 rebind 实验确诊（门一开 xHCI 立刻注册）。→ dwc3-rtk probe 对 rtd1295 先开门（无时钟驱动前的 quirk）。

**⑯ 根集线器全起来了但永远枚举不到设备**
物理 USB-A 口挂在 **DRD 块**上（厂商跑 adb gadget + 软件切角色；u2host/u3host 是空焊盘）。→ DRD 按 host 使能（wrapper @13200、核 @20000、GIC SPI 21、双 phy）；VBUS 由 initramfs 拉高 misc-gpio19（0x9801b100 / 0x9801b110 bit19）。4 TB 盘 9 秒枚举。

**⑰ USB 链路只到 High-Speed（38 MB/s）**
Type-C lane switch 寄存器 **0x9801334c 的复位值是"断开"**，尽管物理口是固定 Type-A。→ 置 bit29（使能）+ 清 bit28:27（CC1 方向），立刻跳上 5 Gbps 总线，实测 137 MB/s（已是机械盘极限）。配方出处：厂商 `rtk_usb_rtd129x.c` 的 `TYPE_C_EN_SWITCH BIT(29)` / `TYPE_C_TxRX_sel BIT(28)|BIT(27)`。固化进 dwc3-rtk quirk（与 clk_en_usb 同块，幂等）。

**⑱ 温度传感器**
传感器在 **scpu_wrapper 0x9801d000 + 0x150**。第一次按 CRT+0x150 猜，读回 `0xDEADBEEF`——这是 RBUS 对无效区域的标志性回读，可以当"地址错了"的信号用。
协议：CTRL2（0x9801d158）依次写 `0x01904001` → `0x01924001` 初始化；STATUS1（0x9801d168）读数按 **18 位符号扩展 × 1000 / 1024 = m°C**。厂商驱动仅 83 行。→ 新写 ~100 行 `drivers/thermal/rtd129x_thermal.c`。

**⑲ `reboot` 把机器停住而不是重启**
本固件没有 PSCI，看门狗是唯一复位通道。→ 给 `rtd119x_wdt` 加 `.restart`（1 ms 溢出 + 使能 + 自旋，优先级 192）。`systemctl reboot` 实测 34 秒下线→上线。
⚠️ 踩坑：用 `nohup` 后台发 reboot 会被 sshd 会话清理吞掉（当时误判为"没执行"），同步下发即可。

**⑳ RTC 能 probe 但不走针（搁置）**
DTS 加 `rtc@600`（ISO 块）后 rtc-rtd119x probe 成功、`/dev/rtc0` 出现，但 epoch 冻结——缺厂商的使能序列（ISO_RTC ctrl / RTCEN 魔法值，在厂商 rtk-rtc 驱动里）。此机时间靠 NTP、断电靠智能插座，价值低，主动搁置。想修就去 GPL 包 rtc 驱动抄使能位。

### 2.3 6.18.40 升级阶段（2026-07-28）

**㉑ 全新检出构建出的内核掉进 netrescue，`grep: not found` 刷屏**
**git 不能跟踪空目录。** initramfs 源目录里的 `dev/ proc/ sys/ tmp/ usr/bin/ usr/sbin/` 七个空目录从未进过版本库，全新 worktree 检出后就没了 → `mount -t proc proc /proc` 失败 → **BusyBox 的 standalone shell 靠 `/proc/self/exe` 定位自身来分发内建 applet**，`/proc` 一没，`grep`/`sed`/`tr` 全部"not found" → netrescue 连自己的 IP 都读不出来，误判 DHCP 失败退到备用地址，把自己踢出网段。
→ 加 `.gitkeep` 占位文件让版本库能带上目录；同时让 `init` 自建挂载点（`mkdir -p /proc /sys /tmp /newroot /run`），这样任何残缺检出都不会再复现。
**教训**：任何依赖目录骨架的构建输入，都要有"目录不存在也能自愈"的兜底。

---

## 3. 网络救援（netrescue）：把串口需求降为可选

移植期最贵的成本不是写代码，是**每次验证都要接串口线**。所以 initramfs 里内建了网络救援。

**触发**（两条，都是一次性的）：
- 自动——所有根文件系统交接路径都失败时；
- 手动——`mch-boot rescue` 在 sda18 放一个 `netrescue` marker，**initramfs 消费后立刻删除**。一次性设计是刻意的：救援模式绝不能把机器困住。

**动作**：挂 devpts → 写 `/etc/passwd` → `udhcpc`（失败回落 192.168.1.222/24）→ `mdadm --assemble --scan` → 起 telnetd + ftpd，串口 shell 同时保留。重启后约 20 秒可 telnet。

**四轮迭代的坑**（全部真机测出）：

1. telnet 端口开了，但第一个连接一进来就死 → 缺 `/dev/pts`（devpts 没挂）。busybox telnetd 分配 pty 失败即退出。厂商 rescue init 里正好有这两行，当时漏了。
2. 能反复连接了，但 `/dev/md1` 不存在 → 救援的主要用途就是修根文件系统，必须 `mdadm --assemble --scan`。
3. 实测通过：telnet 进去 `mount /dev/md1 /mnt` → 可读写 `/etc/fstab` → 干净 umount。
4. 救援 banner 增加 IPv6 地址播报。

⚠️ 安全性：这是**无认证的 root telnet**，只适合可信局域网。它是调试设施，不是产品特性。

## 4. 逐文件源码改动说明

基线：**未修改的 Linux 6.18.40**（kernel.org 原版）。本树 42 个文件与之不同：22 个修改、20 个新增，合计 12,994 行差异（其中 `r8169soc.c` 一个文件占 8,906 行）。

厂商对照基线：`GPL_MCH_Monarch_9.7.0-104_20241205/kernel/linux-4.9.330/`。从厂商树搬运的文件另附"相对厂商原版"的差异行数，用来说明搬运时到底改了多少。

复现这些 diff 的脚本在 `porting-guide-material/make-diffs.sh`（构建服务器）。

### 4.0 一览表

| 文件 | 状态 | vs 主线 | vs 厂商 | 一句话 |
|---|---|---:|---:|---|
| `arch/arm64/Kconfig.platforms` | 改 | 18 | — | 新增 `ARCH_RTD129x` 子family 符号 |
| `arch/arm64/kernel/smp_spin_table.c` | 改 | 42 | — | release addr 是 MMIO 时改用 32 位设备写 |
| `arch/arm64/boot/dts/realtek/Makefile` | 改 | 10 | — | 注册板级 dtb |
| `arch/arm64/boot/dts/realtek/rtd129x.dtsi` | 改 | 10 | — | 删掉 rbus 节点的 `reg` |
| `arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dts` | **新** | 514 | — | 板级 DTS |
| `drivers/irqchip/irq-rtd129x.{c,h}` | **新** | 303+127 | 141 / 0 | 厂商 IRQ mux，加 ack-first、去 printk |
| `drivers/irqchip/{Kconfig,Makefile}` | 改 | 16+7 | — | 去掉 `COMPILE_TEST` 门 |
| `drivers/net/ethernet/realtek/r8169soc.c` | **新** | 8,903 | 450 | 厂商 platform 版 r8169，近乎逐字搬运 |
| `drivers/net/ethernet/realtek/{Kconfig,Makefile}` | 改 | 32+7 | — | `NET_VENDOR_REALTEK` 加 `\|\| ARCH_REALTEK` |
| `drivers/usb/dwc3/dwc3-rtk.c` | 改 | 40 | — | 开 clk_en_usb 门 + 钉 type-c lane switch |
| `drivers/watchdog/rtd119x_wdt.c` | 改 | 43 | — | 加 `.restart`（本机唯一复位通道） |
| `drivers/thermal/rtd129x_thermal.c` | **新** | 79 | 144 | 重写的温度传感驱动 |
| `drivers/thermal/{Kconfig,Makefile}` | 改 | 14+7 | — | 新符号 |
| `drivers/soc/realtek/rtk-memory-remap.c` | **新** | 100 | 313 | `rsvmem-remap` 保留内存语义 |
| `drivers/soc/realtek/{Kconfig,Makefile}` + `drivers/soc/{Kconfig,Makefile}` | 新/改 | 各 ~10 | — | 挂上 realtek 子目录 |
| `include/linux/soc/realtek/rtk_rsvmem.h` | **新** | 11 | 无对应 | 本项目自写的 API 头 |
| `include/soc/realtek/rtk_chip.h` | **新** | 47 | 39 | 芯片识别 |
| `drivers/i2c/busses/i2c-rtk.c` + Kconfig/Makefile | **新**/改 | 983 | 211 | 厂商 I2C（编成模块，未加载，见 §4.9） |
| `drivers/mfd/g2227-i2c.c`、`g22xx-core.c` + 2 头文件 | **新** | 133+43+224 | 26 / 0 / 0 | GMT G2227 PMIC |
| `drivers/regulator/g2227-regulator.c`、`g22xx-regulator-core.c` 等 | **新** | 196+342+71 | 0 / 72 / 0 | PMIC 稳压器 |
| `drivers/phy/realtek/phy-rtk-sata.c` + Kconfig/Makefile | **新**/改 | 431 | 809 | SATA PHY（`=y`，启动盘依赖） |

**没有删除任何主线文件；核心内核只动了 `smp_spin_table.c` 一处。**

---

### 4.1 `arch/arm64/kernel/smp_spin_table.c` — 唯一的核心内核改动

**为什么必须改**：厂商用私有 `enable-method = "rtk-spin-table"`，主线不认。改用主线的 `"spin-table"` 并沿用厂商的 release address `0x9801aa44` 后，内核在唤醒副核前**硬挂**，没有 panic、没有输出。

根因是主线实现对 release address 的访问方式：`ioremap_cache`（可缓存映射）+ 64 位 `writeq` + dcache 维护。但 `0x9801AA44` 不是 RAM，是 SoC 寄存器块里的一个 **32 位设备寄存器**。用可缓存映射 + 64 位写 + cache 维护去操作它，会把互连总线锁死。

厂商 `rtd129x_spin_table.c` 的做法是 plain `ioremap` + 32 位 `writel_relaxed`。

**改法**（不用板级 `#ifdef`，而是通用条件判断）：

```c
+#include <linux/memblock.h>
...
+	/*
+	 * RTD1295 quirk: the release address (0x9801AA44) is an MMIO
+	 * register in the SoC block, not RAM. ioremap_cache() + a 64-bit
+	 * write + cache maintenance on that region hard-hangs the
+	 * interconnect ... vendor 4.9 uses a plain device mapping with a
+	 * 32-bit write - the register is 32 bits wide and with 1 GiB of
+	 * RAM the pen address always fits.
+	 */
+	if (!memblock_is_map_memory(cpu_release_addr[cpu])) {
+		void __iomem *rel32 = ioremap(cpu_release_addr[cpu], sizeof(u32));
+		if (!rel32)
+			return -ENOMEM;
+		writel_relaxed((u32)pa_holding_pen, rel32);
+		dsb(sy);
+		sev();
+		iounmap(rel32);
+		return 0;
+	}
```

用 `memblock_is_map_memory()` 判断"这个地址是不是普通内存"：不是就走设备寄存器路径，是就走主线原路径。release addr 在 RAM 里的正常板子行为完全不变。

**注意适用范围**：这只覆盖**冷启动唤醒**（写 pen 地址 + `sev()`），厂商的冷启动协议本来就与主线接近。CPU 热插拔需要 `rtk_cpu_power_up` / SMC 那一整套，本移植没做。

---

### 4.2 `drivers/irqchip/irq-rtd129x.{c,h}` — 厂商 IRQ mux

厂商这块 SoC 的很多外设中断（含 uart0）不直接进 GIC，而是走私有的 `Realtek,rtk-irq-mux` 二级复用器。**主线 6.18.40 里没有这个驱动**（本文件是从厂商树搬来的：厂商 341 行 → 本树 303 行，差异 141 行；头文件与厂商逐字节相同）。

搬运时的两处实质改动：

**① dispatch 前先 W1C ACK 状态位。** 厂商是靠自家 fork 的 8250 驱动通过 `interrupts-st-mask` 属性去 ack 的；主线的外设驱动完全不知道这个寄存器的存在，所以 ack 必须由 mux 自己做：

```c
+			/* Ack the mux status bit before dispatching. The
+			 * ISR latches peripheral interrupt edges (verified
+			 * on ISO_ISR bit2/UR0 by devmem: write-1-to-clear
+			 * with bit0 = WRITE_DATA per rtk_iso.h, stays clear
+			 * while the line is quiet). The vendor tree acked
+			 * from its forked 8250 driver via interrupts-st-mask;
+			 * mainline peripheral drivers know nothing about
+			 * this register, so the mux must ack here.
+			 */
+			spin_lock(&irq_mux_lock);
+			__raw_writel(BIT(i), mux_data->base + reg_st);
+			spin_unlock(&irq_mux_lock);
```

**② 热路径里所有 `printk` 全部删除。** 厂商代码在找不到 irq desc 时 `pr_err`。但 console 就骑在被 mux 的那个 uart 上——打印一行 → 产生 TX 中断 → 再进 handler → 再打印，自维持风暴（实测 150 秒 607 行）。同时把厂商那段"强清"尾巴（含 `irq == 1` 的死代码）整段删掉：

```c
+			/* NEVER printk in this handler: the console may
+			 * ride a muxed uart, so a print here generates a
+			 * fresh uart interrupt event and the handler
+			 * re-enters forever (the v29/v30 log storm). Any
+			 * event without a consumer (e.g. latched before the
+			 * peripheral driver probed) was already acked above -
+			 * drop it silently.
+			 */
```

**Kconfig 侧**：驱动文件其实一度已在树里、Makefile 也有，但 prompt 被 `if COMPILE_TEST` 门住，`CONFIG_IRQ_RTD129X_MUX` 这个符号在 `.config` 里根本不存在，驱动从未被链接。去掉这个门是让它生效的**前提**。

---

### 4.3 `drivers/net/ethernet/realtek/r8169soc.c` — 以太网

主线没有 RTD1295 GMAC 驱动。厂商的 `r8169soc.c` 是 r8169 的 platform 变体（8,897 行）。本树 8,903 行，**相对厂商原版只有 450 行差异**——近乎逐字搬运。

差异集中在四类，全部是 4.9 → 6.18 的 API 迁移：

| 类别 | 出现次数 | 说明 |
|---|---:|---|
| `rtl_clk_get_optional` 替换裸 `clk_get` | 23 | 见下 |
| `ethtool_link_ksettings` 系列 | 4 | 旧 `ethtool_cmd` 接口已删除 |
| `netif_napi_add` 签名变化 | 1 | 6.x 去掉了 weight 参数 |
| `eth_hw_addr` / MAC 设置 | 1 | `dev->dev_addr` 变只读 |

**最重要的一处是时钟**。RTD129x **没有主线时钟驱动**，时钟门是 bootloader 留下的状态。厂商代码里到处是 `clk_get`，在主线上这些调用返回 `ERR_PTR`，一旦流进 `__clk_is_enabled` 就是 Oops → panic（这正是 v35 崩溃的原因，当时 4 月适配漏了两处裸 `clk_get`）。

统一改成 `rtl_clk_get_optional` helper：拿不到时钟时返回 **NULL**（而不是 ERR_PTR），驱动走"直接寄存器 bring-up"分支。23 处调用点全部收敛到这个 helper，避免再漏。

**Kconfig 门**：`NET_VENDOR_REALTEK depends on PCI || (PARPORT && X86)`。这块 SoC 没有 PCI，所以整个 Realtek 网卡子菜单都进不去，`R8169SOC` 自然也选不上。加 `|| ARCH_REALTEK` 解决。DTS 里 gmac 节点的 compatible 是 `"Realtek,r8168"`。

已知无害噪声：`rtl_csiar_cond` 超时告警会打两次，是厂商驱动在这颗 SoC 上的固有现象，不影响功能。

---

### 4.4 `drivers/usb/dwc3/dwc3-rtk.c` — USB

**主线其实全家都在**：`dwc3-rtk` glue、`phy-rtk-usb2`/`phy-rtk-usb3`（都带 rtd1295 compatible）、dwc3 core 里也内置了 RTD 的 globals-offset quirk。所以 USB 的工作**不是写驱动，是配 DTS + 补两个 bootloader 遗留状态**。

三步踩坑与结论：

1. 裸 `snps,dwc3` 节点会报 `-EBUSY`、资源区间倒挂——主线 dwc3 把 globals 硬编码在 0xc100，RTD1295 实为 **0x8100**。**解法不是打补丁，是父节点用 compatible `realtek,rtd-dwc3`** 去触发内置 quirk。
2. wrapper 架构对了以后 probe 读 GSNPSID 仍是垃圾——`clk_en_usb`（CRT `0x9800000c` bit4）**bootloader 默认关闭**。
3. 链路只到 High-Speed——Type-C lane switch（`0x9801334c`）**复位值是"断开"**，尽管物理口是固定 Type-A。

后两条在 probe 里一次性解决（幂等，同一段代码块）：

```c
+	/* RTD1295: no mainline clock driver exists for the CRT gates and the
+	 * bootloader leaves clk_en_usb (CRT 0x0c bit 4) closed, so every dwc3
+	 * register read returns garbage. Open the gate here. */
+	if (of_device_is_compatible(dev->of_node, "realtek,rtd1295-dwc3")) {
+		void __iomem *clk_en1 = ioremap(0x9800000c, 0x4);
+		void __iomem *typec_cc1 = ioremap(0x9801334c, 0x4);
+		if (clk_en1) {
+			writel(readl(clk_en1) | BIT(4), clk_en1);
+			iounmap(clk_en1);
+		}
+		/* Pin type-C lane switch to CC1 (fixed type-A port); without
+		 * this the port links at High-Speed only. */
+		if (typec_cc1) {
+			u32 v = readl(typec_cc1);
+			v &= ~(BIT(29) | BIT(28) | BIT(27));
+			v |= BIT(29);
+			writel(v, typec_cc1);
+			iounmap(typec_cc1);
+		}
+	}
```

寄存器配方出处：厂商 `rtk_usb_rtd129x.c` 的 `TYPE_C_EN_SWITCH BIT(29)` 与 `TYPE_C_TxRX_sel BIT(28)|BIT(27)`。

**这两处是明确的临时 quirk**：正道是写一个真正的 RTD129x clock driver，届时 `clk_en_usb` 应该由时钟框架管理。

另外，物理 USB-A 口挂在 **DRD 块**上（厂商跑 adb gadget 用软件切角色，u2host/u3host 是空焊盘），DTS 里要把 DRD 按 host 使能；VBUS 由 initramfs 拉高 misc-gpio19。

---

### 4.5 `drivers/watchdog/rtd119x_wdt.c` — 软重启

主线已有 `rtd119x_wdt`（覆盖 RTD129x），但没实现 `.restart`。本固件**没有 PSCI**，`reboot` 只会把机器停住。看门狗是唯一可用的 SoC 复位通道：

```c
+static int rtd119x_wdt_restart(struct watchdog_device *wdev,
+			       unsigned long action, void *data_)
+{
+	struct rtd119x_watchdog_device *data = watchdog_get_drvdata(wdev);
+	/* Overflow after ~1 ms: TCWOV counts clock cycles (27 MHz osc). */
+	writel(clk_get_rate(data->clk) / 1000, data->base + RTD119X_TCWOV);
+	writel_relaxed(RTD119X_TCWTR_WDCLR, data->base + RTD119X_TCWTR);
+	rtd119x_wdt_start(wdev);
+	while (1)
+		cpu_relax();
+	return 0;
+}
...
+	.restart	= rtd119x_wdt_restart,
...
+	/* No PSCI SYSTEM_RESET on this firmware; the watchdog is the only
+	 * working SoC reset. High priority so it wins over any default. */
+	watchdog_set_restart_priority(&data->wdt_dev, 192);
```

优先级 192 是为了盖过任何默认 restart handler。实测 `systemctl reboot` 34 秒下线→上线。

---

### 4.6 `drivers/thermal/rtd129x_thermal.c` — 温度传感（新写）

厂商驱动 83 行，本驱动 79 行，但**基本是重写**（相对厂商 144 行差异）——因为 6.x 的 thermal_of 框架和 4.9 完全不同。核心只有两件事：

- **arm 序列**：向 CTRL2（基址 + 0x08）依次写 `0x01904001`、`0x01924001`；
- **读数**：STATUS1（基址 + 0x18）取低 18 位，**符号扩展后 × 1000 / 1024 = m°C**。

```c
static int rtd129x_thermal_get_temp(struct thermal_zone_device *tz, int *temp)
{
	struct rtd129x_thermal *priv = thermal_zone_device_priv(tz);
	u32 val;

	val = readl_relaxed(priv->base + TM_SENSOR_STATUS1) & GENMASK(17, 0);
	*temp = sign_extend32(val, 17) * 1000 / 1024;

	return 0;
}
```

注册用 `devm_thermal_of_zone_register()`，DTS 侧提供 `thermal-sensor@1d150` 节点和根级 `thermal-zones`（105°C critical trip）。

**找地址的经验**：传感器在 `scpu_wrapper 0x9801d000 + 0x150`。第一次按 CRT+0x150 猜，读回 `0xDEADBEEF`——这是 RBUS 对无效区域的标志性回读，**可以当作"地址猜错了"的可靠信号**。

---

### 4.7 `drivers/soc/realtek/rtk-memory-remap.c` — 保留内存语义

厂商 DTS 用一种非上游的 reserved-memory 绑定：

```dts
compatible = "rsvmem-remap";
save_remap_name = "rbus" | "common" | "ringbuf";
```

主线不认识它。本文件（100 行，厂商原版 245 行，差异 313 行 → 大幅重写）保留这个语义，让厂商 DTS 的保留内存描述继续有效。文件头注释写明了它的性质：

> This is *not* an upstream binding. It's here to keep the vendor DTS semantics working while porting WD My Cloud Home (RTD1295) to 6.x.

⚠️ 与之相关的一个**大坑**：厂商 DTS 里的 `rsvmem-remap` 节点 `rbus@98000000` 圈了 `0x98000000–0x981fffff`，把 SATA 控制器的 MMIO 一起包进去了，导致 AHCI 探测 `-EBUSY`。板级 DTS 里必须删掉**所有** `rsvmem-remap` 节点——保留驱动是为了兼容语义，不是为了在这块板子上使用它。

配套的 `include/linux/soc/realtek/rtk_rsvmem.h`（11 行）是**本项目自写**的 API 头，厂商树里没有对应文件。

---

### 4.8 设备树

**`arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dts`（新增，514 行）**

主线**没有**这块板子（主线的 rtd1295 板级 dts 都是 35 行左右的琐碎文件，只有 memory 节点 + uart 使能）。本文件基于俄语论坛的第三方 Debian 设备树，从 4.9.330 移植而来，自包含地建立在主线 `rtd1295.dtsi` 之上。

节点清单（按行号）：

```
28  memory@0 (1 GiB)          45  reserved-memory (linux,cma / ramoops@22000000)
81  mux_intc: interrupt-controller@1b000  ("Realtek,rtk-irq-mux")
114 i2c0..i2c5 ("realtek,rtk-i2c")        124 pmic@12 (gmt,g2227) + dc1..dc6/ldo2/ldo3
205 sata_phy@3ff00                        219 sata@3f000 (AHCI)
256 usb2phy_u2/u3, usb3phy_u3             281 usb2phy_drd/usb3phy_drd
275 soc_thermal: thermal-sensor@1d150
293/320/347 usb wrapper + dwc3 子节点 usb@20000/29000/1f0000
371 gmac: ethernet@16000 ("Realtek,r8168")
393 &uart0/1/2                            417 &cpu0..&cpu3（spin-table release addr）
489 thermal-zones (soc-crit 105°C)        507 &iso { rtc@600 }
```

**`arch/arm64/boot/dts/realtek/rtd129x.dtsi`（修改，仅 1 行实质变更）**

```diff
 		rbus: bus@98000000 {
 			compatible = "simple-bus";
-			reg = <0x98000000 0x200000>;
 			#address-cells = <1>;
 			#size-cells = <1>;
 			ranges = <0x0 0x98000000 0x200000>;
```

删掉 `reg` 属性。`simple-bus` 节点带 `reg` 会把整个 2 MiB 窗口登记为已占用资源，让挂在它下面的子设备（SATA 等）请求自己那段 MMIO 时撞上 `-EBUSY`。`ranges` 保留即可完成地址翻译。

**厂商参考 DTS**：`.../rtd129x/rtd-1295-monarch-1GB.dts`（318 行，include `rtd-1295-giraffe-common.dtsi`）。它是"在 giraffe 公共 dtsi 上打差量"的结构，而本树的 DTS 是自包含建立在主线 dtsi 上的，所以两者直接 diff 参考价值有限——移植时是按硬件块逐个翻译，而不是文本对照。

---

### 4.9 编成模块但未加载的部分：I2C / PMIC / Regulator

这一组值得单独说明，因为仓库里的旧文档 `DRIVER_PORTING_GUIDE.md` 曾断言"缺 I2C 驱动 = 严重问题，可能导致无法启动"。

**事实是**：这些驱动**已经移植进树**——

| 文件 | 行数 | vs 厂商 |
|---|---:|---:|
| `drivers/i2c/busses/i2c-rtk.c` | 983 | 211 |
| `drivers/mfd/g2227-i2c.c` | 133 | 26 |
| `drivers/mfd/g22xx-core.c` | 43 | 0（逐字节相同） |
| `include/linux/mfd/g2227.h` / `g22xx.h` | 197 / 27 | 0 / 0 |
| `drivers/regulator/g2227-regulator.c` | 196 | 0 |
| `drivers/regulator/g22xx-regulator-core.c` | 342 | 72（新 regulator API） |
| `drivers/regulator/g22xx-regulator.h` | 71 | 0 |
| `include/dt-bindings/regulator/gmt,g22xx.h` | 27 | 0 |

它们在 `.config` 里全部是 **`=m`**（全配置只有 9 个 `=m`，基本就是这一组），而**设备上 `/lib/modules` 目录根本不存在、已加载模块数为 0**。也就是说：

> **这套 I2C + GMT G2227 PMIC + regulator 栈被移植、被编译，但从未安装也从未加载。设备完全靠内建驱动运行，regulator 全部回落到 dummy。**

所以旧文档那个论断**在实践中被证伪**了——设备不带这套驱动照常启动、跑满负载、对外发布。但也不能反过来说"没移植"：代码在树里，DTS 也实例化了 `pmic@12`，只要 `=y` 重编或把模块装上就能启用。

**留着它们的理由**：这是把电源管理做完整（动态调压、精确掉电控制）的现成起点，没必要因为暂时用不上就删掉。

### 4.10 `drivers/phy/realtek/phy-rtk-sata.c` — 别把它和上面一组混为一谈

SATA PHY 是 **`=y`，内建，且真在工作**——启动盘就挂在它下面：

```
phy-rtk-sata 9803ff00.sata-phy: rtk-sata-phy: init phy0 OK
```

431 行，厂商原版 677 行（在 4.9 树里路径是 `drivers/phy/phy-rtk-sata.c`，还没有 `realtek/` 子目录），差异 809 行——**大幅重写并精简**，用上了 `devm_platform_ioremap_resource`、`devm_kcalloc`、现代 `struct phy_ops` / `phy_provider` 框架。

顺带说明日志里那三行 `supply ahci/phy/target not found, using dummy regulator` 是正常的——正是 §4.9 那套 regulator 没加载的结果，AHCI 用 dummy regulator 照常工作。

---

## 5. 配置片段

仓库里保留了 16 个 `rtd1295_*.config` 片段。**它们已经全部折叠进入库的 `.config`，不再是构建输入**（构建脚本只在构建目录里设 `INITRAMFS_SOURCE` 一项）。保留它们是为了说明"每一组选项分别为了解决什么问题"：

| 片段 | 解决的问题 |
|---|---|
| `rtd1295_minimal.config` / `_size.config` | 体积控制（`CONFIG_SYS_BOOTM_LEN` 约 20 MB 上限，见 §1.4） |
| `rtd1295_cmdline.config` / `_cmdline_fix.config` | `CMDLINE_FORCE` + 写死 earlycon/console（§2.1-③） |
| `rtd1295_compat32.config` | `CONFIG_COMPAT=y`，32 位厂商用户态 |
| `rtd1295_mdraid.config` | md RAID1（根文件系统在 md1 上） |
| `rtd1295_initramfs_fix.config` | 内嵌 initramfs 相关 |
| `rtd1295_systemd.config` | cgroups 全家 / SYSVIPC / POSIX_MQUEUE / TMPFS ACL / AUTOFS —— 缺了 systemd 直接冻结（§2.2-⑧） |
| `rtd1295_irqmux.config` | `IRQ_RTD129X_MUX=y` |
| `rtd1295_ethernet.config` | `R8169SOC=y` + `NET_VENDOR_REALTEK=y` |
| `rtd1295_usb.config` | dwc3 / phy-rtk |
| `rtd1295_thermal.config` | 温度传感 |
| `rtd1295_docker.config` | netfilter 双栈（nft + legacy）、**IPv6**（瘦身配置里整个没有）、veth/bridge/macvlan/vlan、cgroup-bpf、user-ns、overlayfs、blk-throttle、CFS bandwidth |
| `rtd1295_nas.config` | NFSD v4、ext4 ACL/xattr、配额、TUN/WireGuard、DM+crypt、FUSE、vfat/exfat/ntfs3/CIFS、zram、看门狗、RTC class |
| `CONFIG_VENDOR_RTSDK_*.config` | 厂商 SDK 对照参考 |

6.18 上的三个具体踩点：legacy iptables 表要同时开 `IP_NF_IPTABLES_LEGACY` + `NETFILTER_XTABLES_LEGACY`（trixie 的 iptables 默认走 nft 后端，但 docker 仍可能用 legacy）；`VETH` 依赖 `NET_CORE`；`NF_TABLES_INET` 依赖 `IPV6`。

## 6. 构建与打包流程

构建脚本：`rebuild_package_and_print_flash.sh`（约 380 行）。默认目标内核 6.18.40，发布名可用 `--release` 指定。

它做的事，按阶段：

**预检。** 要求内核 Makefile、已入库的 `.config`、`initramfs/init`、基准 fw_table（必须恰好 8192 字节）、以及发布目录里的 README/SOURCES/docs/tools 都已就位。备份源码树的 `.config`（EXIT trap 恢复），拷进构建目录。

**[0/5] 配置装配。** 先 `make mrproper`（out-of-tree 构建会拒绝在残留产物的源码树上跑），然后：

```sh
scripts/config --file build/.config --set-str INITRAMFS_SOURCE "$ROOT_DIR/initramfs"
```

⚠️ **这是唯一在此处合并的片段**——历史上的 `rtd1295_*.config` 片段早已折叠进入库的 `.config`。片段文件保留在仓库里是**为了说明每组选项为什么存在**（见 §5），不是构建输入。

**[1/5]** `olddefconfig`。

**[2/5] 编译。** `O=$BUILD_DIR` out-of-tree 构建 `Image dtbs`，并钉死 `KBUILD_BUILD_TIMESTAMP=@$SOURCE_DATE_EPOCH`、`KBUILD_BUILD_USER`、`KBUILD_BUILD_HOST`——为了可复现构建。`SOURCE_DATE_EPOCH` 默认取当前 git 提交的时间戳。

**[3/5] 打包**（内嵌 Python）：

1. 校验 arm64 魔数（偏移 56 = `0x644D5241`）和 FDT 魔数（`0xD00DFEED`）；
2. 改 Image 头三字段（§1.3）；
3. Image 零填充到 4 KiB 边界；
4. DTB 零填充到恰好 `0x7000`，**并改写大端 FDT `totalsize` 为 `0x7000`**（§1.5）；
5. 算附加校验和（`sum(bytes) & 0xFFFFFFFF`）；
6. 在基准 fw_table 的 `0x1A0+14/+18/+22` 和 `0x260+14/+18/+22` 写入新的大小与校验和，重算头部校验和 `sum(fw[0x0A:]) & 0xFFFF` 存回偏移 8；
7. 输出 `BUILD-METADATA.json`（原始/补齐字节数、`sata_blocks = bytes/512`、附加校验和、sha256、源码提交）。

同时生成 `FLASH_COMMANDS.txt`（含算好的扇区数，写序 DTB → 内核 → fw_table）和 `SHA256SUMS`。

**[4/5] 独立复验。** 重新读回三个产物，逐字段断言 fw_table 一致、头部校验和有效、Image 4 KiB 对齐、DTB 恰好 `0x7000` 且 `totalsize == 文件长度`、RTD 头魔数存在；最后把补齐后的 DTB 用刚编出来的 `dtc` 反解析round-trip 一遍。

**[5/5] 确定性归档。** `tar --sort=name --mtime=@epoch --owner=0 --group=0 --numeric-owner`，验证 Image 路径在包内，恢复源码 `.config`。实测两次独立重建产出的归档 SHA256 完全一致。

**A/GOLD 条目在整个流程中原样继承**自基准表。（USB 免串口刷机包更进一步：不发整张表，而是用一个静态编译的 ARM64 `patch-fwtable` 工具从**目标机自己的**盘上表生成新表，只改 B 槽 24 个字节。）

---

---

## 7. 4.9 → 6.18 API 迁移对照

搬运厂商驱动时实际撞到的 API 变化，按"改动量"排序。这些是从本树 2,232 行"相对厂商原版"的差异里归纳出来的，不是通用清单。

### 7.1 时钟：最大的一类，也是最容易 Oops 的

厂商代码假定 `clk_get()` 一定成功。RTD129x 在主线上**没有时钟驱动**，所有 `clk_get` 返回 `ERR_PTR(-ENOENT)`。

```c
/* 厂商 4.9 写法，在主线上是定时炸弹 */
clk = clk_get(dev, "name");
if (__clk_is_enabled(clk))      /* ERR_PTR 进来 → Oops */
```

统一收敛到一个 helper，拿不到时返回 **NULL** 而不是 ERR_PTR，让调用点用"NULL = 没有时钟框架，走直接寄存器 bring-up"这一条语义：

```c
static struct clk *rtl_clk_get_optional(struct device *dev, const char *id);
```

`r8169soc.c` 里 23 处调用点全部走这个 helper。**教训**：这类替换必须做到"一处不漏"——v35 就是因为漏了两处裸 `clk_get` 而在 probe 里 panic。漏网的代价是整机不启动，而且现场只有一行 Oops。

### 7.2 ethtool

`struct ethtool_cmd` 及 `get_settings`/`set_settings` 已被删除，改用 link_ksettings：

| 4.9 | 6.18 |
|---|---|
| `struct ethtool_cmd` | `struct ethtool_link_ksettings` |
| `.get_settings` / `.set_settings` | `.get_link_ksettings` / `.set_link_ksettings` |
| 直接读写 `cmd->supported` 等 | `ethtool_convert_link_mode_to_legacy_u32()` 等转换辅助 |

### 7.3 网络设备

| 4.9 | 6.18 |
|---|---|
| `netif_napi_add(dev, napi, poll, weight)` | `netif_napi_add(dev, napi, poll)`（weight 参数已去掉） |
| `memcpy(dev->dev_addr, ...)` | `dev->dev_addr` 变只读，须用 `eth_hw_addr_set()` |

### 7.4 platform / resource 样板

现代 devm 辅助函数大幅缩短了 probe 代码，`phy-rtk-sata.c` 从 677 行精简到 431 行主要靠这个：

| 4.9 常见写法 | 6.18 |
|---|---|
| `platform_get_resource` + `devm_ioremap_resource` | `devm_platform_ioremap_resource()` |
| 手写数组分配 | `devm_kcalloc()` |
| `of_property_read_u32` 逐个数数 | `of_property_count_u32_elems()` 等 |

### 7.5 thermal

4.9 的 thermal 注册方式与 6.x 差异太大，`rtd129x_thermal.c` 属于**照着寄存器协议重写**而不是移植：

| 4.9 | 6.18 |
|---|---|
| 自建 `thermal_zone_device_register` + 私有 ops | `devm_thermal_of_zone_register()` |
| ops 回调签名带私有 struct | `.get_temp(struct thermal_zone_device *tz, int *temp)` + `thermal_zone_device_priv()` |

从厂商驱动里真正需要提取的只有两条硬件知识：arm 序列的两个魔数，和 18 位符号扩展 × 1000/1024 的换算。

### 7.6 regulator

`g22xx-regulator-core.c` 相对厂商 72 行差异，主要是 of 解析辅助的变化（`of_property_read_bool` / `of_get_child_by_name` 等）与 regulator 框架结构体字段调整。

### 7.7 irqchip

厂商 irq mux 的核心逻辑（读状态、查 enable、分发）在 6.18 上基本可以照搬，`generic_handle_irq` / `irq_find_mapping` / `irq_desc_get_irq` 都还在。真正需要改的不是 API，而是**语义责任的转移**：厂商靠 fork 的 8250 驱动 ack 状态位，主线外设驱动不知道这个寄存器，所以 ack 责任必须搬进 mux（§4.2）。

**这是移植厂商 BSP 时最需要警惕的一类问题**：不是函数签名变了，而是厂商把某个职责分散在了它自己 fork 的其他驱动里。你只搬了一个文件，那个职责就凭空消失了。

---

## 8. 与仓库内其他文档的关系

本仓库的文档有历史层积，这里说明取代关系，避免读到过时结论。

| 文档 | 状态 | 说明 |
|---|---|---|
| [README.md](README.md) | **现行** | 面向使用者：刷机、槽位边界、版本命名。本指南不重复扇区表，需要时链接过去。 |
| [DEVELOPMENT_HISTORY.md](DEVELOPMENT_HISTORY.md) | **现行** | 里程碑编年（vNN + git SHA）。与本指南互补：它讲"何时"，本指南讲"为什么和怎么改"。 |
| `DEBUG_SESSION_2026-04-20.md` | **史料，结论部分已被取代** | 四月引导链攻坚的一手记录，厂商 DTS 剖析仍有参考价值。但它早于所有真机验证——其中 v23 的 spin-table DTS 后来实测硬挂（原因见 §2.2-⑦）。 |
| `PORTING_STATUS.md` | **史料** | 2026-04-19 快照。"已完成"部分的事实（Image 头数值、COMPAT、rsvmem、switch_root 决策）准确，但状态与下一步框架早于 SMP/UART/网络/USB/thermal 全部完成。 |
| `KERNEL_PORTING_GUIDE.md` | **被本文取代** | 冻结在 6.18.2 时期。其中 DT 新旧格式转换的操作方法仍有效，其余状态描述已废。 |
| `DRIVER_PORTING_GUIDE.md` | **被本文取代（且结论有误）** | 其核心论断"缺 I2C 驱动 = 严重问题，可能导致无法启动"**已被实践否定**：I2C/PMIC 栈虽已移植进树，但编成模块且从未加载，设备照常启动、运行、发布（详见 §4.9）。特此写明，以免有人重新捡起这个结论。 |
| `OFFICIAL_KERNEL_ANALYSIS.md` | **被本文取代（部分史料有用）** | 其中厂商 DTS 的 include 层次（`rtd-1295-monarch-1GB.dts` → giraffe-common → `rtd-1295.dtsi`）、厂商 bootargs、gmac/PWM 节点记录是准确的 4.9 树参考；前瞻性分析部分已废。 |

---

## 9. 未完成与已知限制

| 项目 | 状态 |
|---|---|
| RTC 不走针 | 主动搁置。probe 成功、`/dev/rtc0` 存在，缺厂商使能序列。NTP 已覆盖需求。 |
| `rtl_csiar_cond` 超时告警 | 厂商驱动在此 SoC 上的已知噪声，×2 出现，不影响功能。 |
| u2host / u3host 空根集线器 | 无害（对应物理口是空焊盘），可在 DTS 里关掉。 |
| I2C / PMIC / regulator | 已移植进树但编成模块、从未加载；设备靠内建驱动运行，regulator 全部是 dummy。要启用改 `=y` 重编即可（§4.9）。 |
| 板级 DTS 的 `bootargs` | 仍写着错误的 `root=/dev/sda9 rootfstype=ext4`，被 `CMDLINE_FORCE` 盖住。应顺手修掉。 |
| A 槽 | 本机上已失效（旧 initramfs 的 switch_root 失败 → 约 43 秒 panic → 无限重启）。可考虑改造成写入本项目已验证内核的免串口回退槽。 |
| 时钟驱动 | RTD129x 无主线时钟驱动。以太网、USB 都靠 bootloader 留下的时钟门 + probe 期 quirk 开门。写一个真正的 clock driver 是后续正道。 |
