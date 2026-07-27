# 刷机步骤（U-Boot / 串口）

## 0. 刷前备份（在现有系统里执行,强烈建议）

    dd if=/dev/sda1 of=/data/backup_fw_table.bin
    dd if=/dev/sda6 of=/data/backup_fdt_b.img
    dd if=/dev/sda8 of=/data/backup_kernel_b.img

## 1. 准备

- 把 `flash/` 下三个文件放进 TFTP 服务器根目录,核对 SHA256SUMS
- 串口连好（115200 8N1）,记下 TFTP 服务器 IP（下文用 192.168.1.100 代替）

## 2. 进入 U-Boot 控制台

上电,在串口出现 `CPU  : Cortex-A53 quad core - AARCH32` 后**连续快速按 Esc**,
直到出现 `Realtek>` 提示符（提示行为 `Hit Esc or Tab key to enter console mode`,
倒计时为 0,窗口极短,建议上电即开始连按）。

## 3. 刷写（一行一条,勿粘贴多行）

    sata init
    env set serverip 192.168.1.100
    env set ipaddr 192.168.1.200

    tftp 0x04000000 mch.dtb
    sata write 0x04000000 0x31000 0x38

    tftp 0x04000000 Image-6.18.2-mch
    sata write 0x04000000 0x33800 0x7e60

    tftp 0x04000000 fw_table.bin
    sata write 0x04000000 0x22 0x10

    env set bootdelay 5
    bootr

每次 tftp 后确认 `Bytes transferred` 与文件大小一致再执行对应 sata write。

## ⚠️ 铁律

- **只写上述三个地址**（B 槽）。绝不触碰 sda9/sda10/sda16（Gold 救援槽,
  U-Boot `sgboot` 命令的最后退路）
- serverip/ipaddr 按你的网络实际修改
- 串口报 `input overrun` 说明输入太快,重敲该行

## 回滚

用第 0 步的备份反向刷回（fw_table→0x22 0x10、DTB→0x31000 0x38、
内核→0x33800 按备份大小/512 计算扇区数）,或走 Gold 槽救援。
