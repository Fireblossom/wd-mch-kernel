# r5 刷机步骤

以下操作只写 B 槽，但输入错误的设备名、地址或扇区数仍可能破坏其他启动路径。

有两条刷写路径：

- **路径 A（免串口 dd）**：设备当前能正常启动进 Debian 时使用。B 槽三个分区在
  运行中的系统上是未挂载的普通块设备，U-Boot 只在开机时读取它们，直接写入等同
  厂商 OTA。本项目自 r3 起的每次升级都走这条路径。
- **路径 B（串口 + U-Boot + TFTP）**：任何状态都可用，包括 B 槽已刷坏无法启动时。

## 0. 刷写前备份（两条路径都必须）

**当前固件表、B 槽 DTB 和 B 槽内核的备份是唯一推荐的回退手段，不是可选项。**

在当前 Debian 系统中：

```bash
mkdir -p /data/wd-mch-backup
dd if=/dev/sda1 of=/data/wd-mch-backup/fw_table-before-r5.bin
dd if=/dev/sda6 of=/data/wd-mch-backup/fdt-b-before-r5.img
dd if=/dev/sda8 of=/data/wd-mch-backup/kernel-b-before-r5.img
sync
```

确认三个备份文件均非空，并把它们复制到设备之外。

然后校验本包：

```bash
cd flash
sha256sum -c SHA256SUMS
cat BUILD-METADATA.json
```

## 路径 A：免串口 dd（从运行中的 Debian）

前置条件：

- 设备当前从 B 槽正常启动，能以 root 通过 SSH 登录；
- `lsblk` 确认 `sda1`、`sda6`、`sda8` 均未挂载、无占用；
- 第 0 步的备份已完成并已复制到设备之外。

> [!WARNING]
> `fw_table.bin` 是完整的 8192 字节固件表，除 B 槽条目外也包含 A 槽和 GOLD 的
> 条目值。只有当你的设备用社区 Debian 安装包（4PDA v6.x）安装、且从未自行改动过
> A/GOLD 分区时，这些条目才与你盘上的一致，可以整表写入。不确定时，先比较现役表
> （`cmp -l flash/fw_table.bin /data/wd-mch-backup/fw_table-before-r5.bin`，
> 差异应只落在头校验和 B 槽条目内），或改用发布页的 USB 刷机包——它的
> `patch-fwtable` 工具从你设备的原表出发只改 B 槽条目。

写入顺序固定为 DTB → 内核 → 固件表（固件表最后提交，使它只在两个产物都写完后
才指向新内容）：

```bash
cd flash
dd if=mch.dtb of=/dev/sda6 bs=1M conv=fsync
dd if=Image-6.18.40-mch of=/dev/sda8 bs=1M conv=fsync
dd if=fw_table.bin of=/dev/sda1 bs=8192 count=1 conv=fsync
```

每步写入后立即回读校验（O_DIRECT 绕过页缓存，字节数以 `SHA256SUMS` 对应文件
大小为准）：

```bash
dd if=/dev/sda6 iflag=direct bs=1M count=1 2>/dev/null | head -c $(stat -c%s mch.dtb) | sha256sum
dd if=/dev/sda8 iflag=direct bs=1M count=16 2>/dev/null | head -c $(stat -c%s Image-6.18.40-mch) | sha256sum
dd if=/dev/sda1 iflag=direct bs=8192 count=1 2>/dev/null | sha256sum
```

三个哈希都与 `SHA256SUMS` 一致后：

```bash
sync
systemctl reboot
```

设备约 30–40 秒后回网。若长时间不回网，见"回滚"。

## 路径 B：串口 + U-Boot + TFTP

额外前置：115200 8N1 TTL 串口、能进入一阶段 `Realtek>` U-Boot 提示符、局域网内
有 TFTP 服务器。把 `Image-6.18.40-mch`、`mch.dtb` 和 `fw_table.bin` 放进 TFTP
根目录，三个文件必须来自同一个包。

### 进入 U-Boot

上电后，在串口出现 `CPU  : Cortex-A53 quad core - AARCH32` 时连续快速按 Esc，
直到出现 `Realtek>`。提示通常是
`Hit Esc or Tab key to enter console mode`，可操作窗口很短。

### 刷写 B 槽

打开本包生成的 `flash/FLASH_COMMANDS.txt`，逐行输入。不要从旧文档复制内核扇区数，
因为它取决于本次构建的实际 Image 大小。

每个 `tftp` 命令完成后：

1. 核对 `Bytes transferred` 与本地文件大小完全一致；
2. 再执行紧随其后的 `sata write`；
3. 如果串口报告 `input overrun`，重新手工输入当前行。

固件表被安排在最后写入，使它只在 DTB 和内核均已写入后才指向新产物。

最后 `bootr` 启动并保持串口连接，记录完整日志。

## 首次启动验收

进入 Debian 后执行：

```bash
uname -a          # 6.18.40 #6
nproc             # 4
ip -br link
cat /sys/class/net/eth0/address
lsusb -t
cat /sys/class/thermal/thermal_zone0/temp
journalctl -b | grep -i watchdog   # systemd 接管，15 秒超时
systemctl --failed
```

继续验证 SATA、`/dev/md1`、SSH、持续网络传输、Docker、NFS/SMB 和软重启。装有
lm-sensors 时 `sensors` 应能读到 SoC 温度。所有项目通过前，不要使用
`mch-boot commit` 把候选槽位设为永久目标。

## 禁止事项

- 不写任何未列在本文档或 `FLASH_COMMANDS.txt` 中的扇区/设备；
- 不覆盖 A 槽；
- 不覆盖 GOLD 分区（通常为 `sda9`、`sda10`、`sda16`）；
- 不混用其他版本（`r1`/`r2` 或旧 `vNN`）的文件；
- 没有异机备份时不刷写；走路径 B 时没有串口不刷写。

## 回滚

如果内核能启动但 Debian 无法挂载，使用 netrescue。

如果内核本身无法启动，**按原扇区位置写回第 0 步保存的三个 B 槽备份**（串口 +
U-Boot 路径，或任何能访问到该盘的手段）。

> [!CAUTION]
> 不要用 `sgboot` 启动 GOLD——它是出厂重置固件，每次启动都会无条件格式化数据
> 分区并对 SSD 下发 TRIM。`snboot` 启动的 A 槽在社区 Debian 布局下通常也会
> panic 循环。理由和实测细节见 [`RESCUE.md`](RESCUE.md)。
