---
description: WD My Cloud Home (RTD1295) Linux Kernel Porting & Flashing
---

# WD My Cloud Home (RTD1295) Linux 内核移植完整工作流

## 硬件信息
- **SoC**: Realtek RTD1295 (Cortex-A53 四核, AArch64)
- **RAM**: 1 GiB
- **Storage**: Intel 256GB SSD via SATA
- **UART**: 串口调试 115200 8N1, 地址 0x98007800
- **Bootloader**: 两阶段 U-Boot (1st: AArch32, 2nd: AArch64, U-Boot 2015.07)

## 网络环境
- Mac TFTP 服务器 IP: `192.168.123.191`, 目录: `/private/tftpboot/`
- WD 设备 IP: `192.168.123.164`
- Ubuntu 编译服务器 (Tailscale): `100.115.19.12`

## 分区布局 (GPT V3)
> 分区定义来源：U-Boot `cmd_rtkgpt.c` 的 `fill_GPT_PTES_V3`。

| 分区 | 名称 | 说明 |
|------|------|------|
| sda1 | FW_TABLE | 固件描述符表 |
| sda2 | KERNEL_A | A 区内核 |
| sda3 | ROOTFS_A | A 区 rootfs |
| sda4 | ROOTFS_B | B 区 rootfs |
| sda5 | FDT_A | A 区 DTB |
| sda6 | FDT_B | B 区 DTB |
| sda7 | AFW_A | A 区音频 FW |
| sda8 | KERNEL_B | B 区内核 |
| sda9 | ROOTFS_GOLD | **gzip+cpio 镜像，不是 ext 分区** |
| sda10 | FDT_GOLD | GOLD DTB |
| sda11 | AFW_B | B 区音频 FW |
| sda12 | BOOTCODE32 | 32-bit bootcode |
| sda13 | BOOTCODE64 | 64-bit bootcode |
| sda14 | BL31 | ARM TF BL31 |
| sda15 | BL32 | TEE/BL32 |
| sda16 | KERNEL_GOLD | GOLD 内核 |
| sda17 | AFW_GOLD | GOLD 音频 FW |
| sda18 | CONFIG | bootConfig 等配置 |
| sda19 | SYSTEM_A | 系统分区 A |
| sda20 | SYSTEM_B | 系统分区 B |
| sda21 | CACHE | 缓存分区 |
| sda22 | DATA | 数据分区 |
| sda23 | SWAP | 交换分区 |
| sda24 | DISKVOLUME1 | 用户数据盘 |

---

## 🚨 踩过的坑（按时间顺序）

### 坑 1：固件描述符表 (FW Table) 校验和
**问题**：修改固件表中的内核/DTB 大小后，引导时报 `Checksum not match`。
**根因**：固件表头部包含一个 16-bit 校验和字段（偏移 0x08-0x09），算法为 `sum(bytes[0x0A:]) & 0xFFFF`。
**解决**：逆向校验和算法，每次修改固件表后重新计算。

```python
fw_cksum = sum(fw[0x0A:]) & 0xFFFF
struct.pack_into('<H', fw, 8, fw_cksum)
```

### 坑 2：Image.gz `inflate() returned -5`
**问题**：第二阶段 U-Boot 解压 gzip 内核时报错 `-5`。
**根因**：2nd stage U-Boot 的 `CONFIG_SYS_BOOTM_LEN` 限制了解压缓冲区大小（约 20MB）。6.18 内核解压后 22MB 超出限制。
**解决**：通过 `CONFIG_CC_OPTIMIZE_FOR_SIZE=y` 和禁用调试功能将内核缩减至 ~8MB。

### 坑 3：垃圾数据导致校验和失败
**问题**：TFTP 下载文件到内存后，`sata write` 写入的扇区数超过文件实际大小，导致磁盘上的数据包含内存中的垃圾。
**根因**：`sata write` 按扇区（512B）写入，如果写入扇区数 > 文件大小/512，多出的数据是内存中残留的随机值。
**解决**：在主机端生成文件时，**必须使用零填充 (zero-padding) 到扇区对齐大小**，`sata write` 的扇区数必须精确等于填充后的文件大小/512。

```python
padded_size = (orig_size + 0xFFF) & ~0xFFF
data.extend(b'\x00' * (padded_size - orig_size))
sata_blocks = padded_size // 512  # 精确计算
```

### 坑 4：DTB `FDT_ERR_NOSPACE`
**问题**：U-Boot 尝试向 DTB 添加 `/factory` 节点时报 `FDT_ERR_NOSPACE`。
**根因**：DTB 编译后没有预留额外空间。U-Boot 需要在运行时修改 DTB。
**解决**：编译 DTB 时加 padding：`dtc -p 16384 ...`

### 坑 5：2nd stage `unzip` 命令不存在
**问题**：想在 2nd stage 手动 `unzip` 解压内核，但该命令被裁剪了。
**根因**：2nd stage U-Boot 是精简版，只有 `booti`、`fdt` 等基本命令。
**解决**：改用 Raw Image（未压缩内核）方案，跳过解压。

### 坑 6：🔥 `text_offset = 0` 导致内核完全静默（最关键的坑！）
**问题**：无论 Raw Image 还是 gzip，内核启动后完全无输出（连 earlycon 都没有）。
**根因**：
- 原版 4.9 内核的 ARM64 Image header 中 `text_offset = 0x280000`
- 6.18 内核的 `text_offset = 0x000000`（现代 PIE 内核）
- 老版 U-Boot 2015.07 的 `booti` 会把内核拷贝到 `DRAM_BASE + text_offset`
- `text_offset=0` → 拷贝到地址 `0x00000000` → **覆盖了 U-Boot 自身和异常向量表** → CPU 瞬间崩溃

**解决**：在 Image 二进制文件中直接 patch header，将 `text_offset` 改为 `0x200000`（2MB 对齐，兼容新内核对齐检查）：

```python
struct.pack_into('<Q', kernel, 8, 0x200000)   # text_offset (2MB aligned)
struct.pack_into('<I', kernel, 0, 0x91005a4d) # code0 = MZ header
struct.pack_into('<I', kernel, 60, 0x40)      # pe_offset
```

### 坑 7：`rsvmem-remap` 节点导致 SATA EBUSY
**问题**：AHCI 驱动报 `error -EBUSY: can't request region for resource [mem 0x9803f000-0x9803ffff]`。
**根因**：DTB 中的 `rbus@98000000` reserved-memory 节点（vendor `rsvmem-remap`）占用了整个 0x98000000-0x981fffff 区域。SATA 控制器在该范围内，被拒绝注册。同时 `common@1f000` 和 `ringbuf@1ffe000` 与 `rpc@1f000` / `rpc@1ffe000` 重叠。
**解决**：从 DTS 中删除所有 vendor `rsvmem-remap` 节点。

### 坑 8：`CONFIG_CMDLINE_FROM_BOOTLOADER` vs `CONFIG_CMDLINE_FORCE`
**问题**：DTB 中设置了 `bootargs`，但内核没有使用。
**根因**：默认 `CONFIG_CMDLINE_FROM_BOOTLOADER=y` 会让 U-Boot 的 bootargs 覆盖 DTB 设置，而 U-Boot 的 bootargs 可能为空或错误。
**解决**：使用 `CONFIG_CMDLINE_FORCE=y` 并在内核配置中硬编码 earlycon 参数。

### 坑 9：`sda9` 不是 ext4，而是 gzip+cpio
**问题**：`mount -t ext4 /dev/sda9 /mnt` 始终报 `Invalid argument`。
**根因**：`sda9` 头部魔数是 `1f 8b 08`，这是 gzip 流，不是块文件系统。
**解决**：使用 initramfs 解包后再切换根：

```sh
mkdir -p /newroot
zcat /dev/sda9 | cpio -idm -D /newroot
```

### 坑 10：`switch_root` 必须由 PID 1 执行
**问题**：在交互 shell 里执行 `switch_root /newroot /init` 只打印 usage。
**根因**：BusyBox `switch_root` 要求当前进程是 PID1。
**解决**：
- 当前稳定方案：在 initramfs 保持 PID1 存活，使用 `chroot /newroot /init` 交接
- `switch_root` 仅作为严格 PID1 场景下的可选路径

```sh
mount -t proc proc /newroot/proc
mount -t sysfs sysfs /newroot/sys
mount -o bind /dev /newroot/dev
chroot /newroot /init
```

### 坑 11：串口 overrun 导致命令截断
**问题**：串口出现 `ttyS0: input overrun(s)`，长命令被吞字。
**解决**：诊断时一行一条短命令，不要链式 `&&`。

### 坑 12：`bootr` 前必须先设倒计时
**问题**：2nd stage 自动启动窗口太短，来不及打断。
**解决**：先设 `bootdelay` 再 `bootr`。

```sh
env set bootdelay 5
bootr
```

---

## 完整打包流程

### 步骤 1：编译精简内核
```bash
cat << 'EOF' > rtd1295_boot.config
CONFIG_CC_OPTIMIZE_FOR_SIZE=y
CONFIG_DEBUG_KERNEL=n
CONFIG_DEBUG_INFO=n
CONFIG_FTRACE=n
CONFIG_CMDLINE="earlycon=uart8250,mmio32,0x98007800 console=ttyS0,115200 panic=5"
CONFIG_CMDLINE_FORCE=y
EOF

cd linux-6.18.2
scripts/kconfig/merge_config.sh .config rtd1295_boot.config
make ARCH=arm64 -j$(nproc) Image dtbs
```

### 步骤 2：生成 DTB (带 padding)
```bash
dtc -I dtb -O dtb -p 16384 \
  arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dtb \
  -o rtd1295-wd-mycloud-home-padded.dtb
```

### 步骤 3：Patch Image Header + 零填充
```python
import struct

with open('Image', 'rb') as f:
    kernel = bytearray(f.read())

# Patch header to match old U-Boot expectations
struct.pack_into('<Q', kernel, 8, 0x200000)    # text_offset (2MB aligned)
struct.pack_into('<I', kernel, 0, 0x91005a4d)  # code0 = MZ
struct.pack_into('<I', kernel, 60, 0x40)       # pe_offset

# Zero-pad to sector alignment
padded_size = (len(kernel) + 0xFFF) & ~0xFFF
kernel.extend(b'\x00' * (padded_size - len(kernel)))

with open('Image-padded', 'wb') as f:
    f.write(kernel)
```

### 步骤 4：构建固件表
```python
# DTB and kernel checksums
dtb_cksum = sum(dtb_data) & 0xFFFFFFFF
kern_cksum = sum(kern_data) & 0xFFFFFFFF

# Patch firmware table entries
# DTB entry at offset 0x1A0: +14=size, +18=padded, +22=cksum
# Kernel entry at offset 0x260: +14=size, +18=padded, +22=cksum
# Header checksum at offset 0x08: sum(bytes[0x0A:]) & 0xFFFF
```

### 步骤 5：刷入 (1st stage Realtek>)
```
sata init
env set serverip 192.168.123.191
env set ipaddr 192.168.123.164

tftp 0x04000000 fw_table.bin
sata write 0x04000000 0x22 0x10

tftp 0x04000000 padded.dtb
sata write 0x04000000 0x31000 <DTB_BLOCKS>

tftp 0x04000000 Image-padded
sata write 0x04000000 0x33800 <KERNEL_BLOCKS>

env set bootdelay 5
bootr
```

### 步骤 6：手动引导 (2nd stage)
```
booti 0x03000000 - 0x01f00000
```

### 步骤 7：ROOTFS_GOLD (sda9) 解包启动（当前验证可用）
```sh
mkdir -p /newroot
zcat /dev/sda9 | cpio -idm -D /newroot
mkdir -p /newroot/proc /newroot/sys /newroot/dev
mount -t proc proc /newroot/proc
mount -t sysfs sysfs /newroot/sys
mount -o bind /dev /newroot/dev
chroot /newroot /init
```

---

## 关键文件位置
- 原始固件表备份: `/home/ubuntu/linux/fw_table_original.bin`
- 原始内核备份: `/home/ubuntu/linux/backup_sda8_kernel_b.img`
- 原始 DTB 备份: `/home/ubuntu/linux/backup_sda6_fdt_b.img`
- 原始 GPT 备份: `/home/ubuntu/linux/gpt_primary.bin`, `gpt_backup.bin`
- 编译服务器内核源码: `/home/ubuntu/linux/linux-6.18.2/`
- DTS 源文件: `.../arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dts`
