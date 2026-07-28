# r2 刷机步骤（U-Boot / 串口）

`r2` 是候选包，不是正式稳定版。以下操作只写 B 槽，但输入错误的地址或扇区数
仍可能破坏其他启动路径。

## 0. 刷写前检查

必须具备：

- 115200 8N1 TTL 串口；
- 能进入一阶段 `Realtek>` U-Boot 提示符；
- **当前固件表、B 槽 DTB 和 B 槽内核的备份（这是唯一推荐的回退手段，不是可选项）；**
- TFTP 服务器。

在当前 Debian 系统中备份：

```bash
mkdir -p /data/wd-mch-backup
dd if=/dev/sda1 of=/data/wd-mch-backup/fw_table-before-r2.bin
dd if=/dev/sda6 of=/data/wd-mch-backup/fdt-b-before-r2.img
dd if=/dev/sda8 of=/data/wd-mch-backup/kernel-b-before-r2.img
sync
```

确认三个备份文件均非空，并把它们复制到设备之外。

## 1. 检查候选包

```bash
cd flash
sha256sum -c SHA256SUMS
cat BUILD-METADATA.json
cat FLASH_COMMANDS.txt
```

把 `Image-6.18.40-mch`、`mch.dtb` 和 `fw_table.bin` 放进 TFTP 根目录。三个文件
必须来自同一个包。

## 2. 进入 U-Boot

上电后，在串口出现 `CPU  : Cortex-A53 quad core - AARCH32` 时连续快速按 Esc，
直到出现 `Realtek>`。提示通常是
`Hit Esc or Tab key to enter console mode`，可操作窗口很短。

## 3. 刷写 B 槽

打开本包生成的 `flash/FLASH_COMMANDS.txt`，逐行输入。不要从旧文档复制内核扇区数，
因为它取决于本次构建的实际 Image 大小。

每个 `tftp` 命令完成后：

1. 核对 `Bytes transferred` 与本地文件大小完全一致；
2. 再执行紧随其后的 `sata write`；
3. 如果串口报告 `input overrun`，重新手工输入当前行。

固件表被安排在最后写入，使它只在 DTB 和内核均已写入后才指向新产物。

## 4. 首次启动

`bootr` 后保持串口连接，记录完整日志。进入 Debian 后执行：

```bash
uname -a
nproc
ip -br link
cat /sys/class/net/eth0/address
lsusb -t
cat /sys/class/thermal/thermal_zone0/temp
systemctl --failed
```

继续验证 SATA、`/dev/md1`、SSH、持续网络传输、Docker、NFS/SMB 和软重启。所有
项目通过前，不要使用 `mch-boot commit` 把候选槽位设为永久目标。

## 禁止事项

- 不写任何未列在 `FLASH_COMMANDS.txt` 中的扇区；
- 不覆盖 A 槽；
- 不覆盖 GOLD 分区（通常为 `sda9`、`sda10`、`sda16`）；
- 不混用 `r1`、`r2` 或旧 `vNN` 文件；
- 没有串口和异机备份时不测试候选包。

## 回滚

如果内核能启动但 Debian 无法挂载，使用 netrescue。

如果内核本身无法启动，**按原扇区位置写回第 0 步保存的三个 B 槽备份**。

> [!CAUTION]
> 不要用 `sgboot` 启动 GOLD——它是出厂重置固件，每次启动都会无条件格式化数据
> 分区并对 SSD 下发 TRIM。`snboot` 启动的 A 槽在社区 Debian 布局下通常也会
> panic 循环。理由和实测细节见 [`RESCUE.md`](RESCUE.md)。
