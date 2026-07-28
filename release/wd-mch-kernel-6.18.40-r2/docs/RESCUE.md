# 救援与槽位切换

WD My Cloud Home 有三条启动路径，但**只有一条适合当作回退目标**：

| 槽位 | 内容 | 能否用于回退 |
|---|---|---|
| **B** | 本项目的主线内核 | 本包的写入目标 |
| **A** | 厂商 4.9 内核 + 同一个 Debian 根文件系统 | ⚠️ **通常不行**，见下 |
| **GOLD** | WD 出厂重置固件 | ❌ **绝对不要启动**，见下 |

本包只更新 B 槽，不写 A 或 GOLD。

## 先读这一节：A 与 GOLD 的真实性质

早期版本的本文档把 A 槽称作"回退"、把 GOLD 称作"最后的独立恢复路径"。
**这两个说法都是错的**，以下结论来自厂商 GPL 源码和真机实测。

> [!CAUTION]
> **GOLD 不是救援环境，是出厂重置器。绝对不要启动它。**
>
> 它的 rootfs 是 Android 6.0.1 recovery，`init.rc` 通过硬编码在自身
> `default.prop` 里的 `ro.debuggable=1` 属性触发器，**在每次启动时无条件**
> 运行 `do_reset.sh`。该脚本按**分区号**硬编码出厂布局，开机约 31 秒执行
> `mke2fs -m0 -t ext4 -E discard ...`。
>
> 在社区 Debian 的分区布局下，它认定为"cache"的那个分区号，正是用户数据分区。
> 本项目开发期间因此丢失了一个 215 GiB 数据分区；由于 `-E discard` 会向 SSD
> 下发全盘 TRIM，数据在闪存层面即刻不可恢复——实测老文件系统的主超级块与全部
> 15 个备用超级块位置均已归零。
>
> 它也不会自己停下：格式化完第一个分区后，因为下一个目标分区在新布局里不存在，
> 脚本进入无限错误循环，既不重启也不改写 `bootConfig`。

> [!WARNING]
> **A 槽通常也不是可用的回退目标。**
>
> 由社区 Debian 包安装的设备，A 槽里是厂商 4.9 内核配一个旧 initramfs。该
> initramfs 的 `switch_root` 会失败，约 43 秒后 panic 并无限重启。本项目实测
> 确认过这一点。
>
> 如果你没有亲自验证过自己设备的 A 槽能完整启动，就不要把它当作退路。

**唯一推荐的回退方式**：刷写前把 B 槽三个分区（FW_TABLE / FDT_B / KERNEL_B）
完整备份，出问题时原样写回。`docs/FLASHING.md` 里的备份步骤不是可选项。

另外请保持 `bootConfig` 为 `0:F:0:;`。一阶段引导器**只有**在该文件首字节为 `5`
或有人在串口敲 `sgboot` 时才会进入 GOLD；保持这个值，它就不会被意外触发。
（Realtek 原有的"启动失败自动回退 GOLD"逻辑已被 WD 在源码中用 `#if 0` 关闭。）

## `mch-boot` 工具

从运行中的 Debian 安装：

```bash
install -m 0755 tools/mch-boot /usr/local/sbin/mch-boot
```

常用命令：

```text
mch-boot status   显示当前启动配置
mch-boot a        下一次启动 A 槽（先确认 A 槽真的能启动）
mch-boot b        下一次启动 B 槽
mch-boot commit   把正在试运行的 A/B 槽设为永久目标
mch-boot rescue   下一次启动停在 initramfs 网络救援环境
mch-boot disarm   取消待执行的网络救援
mch-boot normal   清除试运行状态，启动已提交槽位
```

工具里还有一个 `mch-boot gold`。**不要使用它**，理由见上。

一阶段引导器读取 FAT32 CONFIG 分区（通常是 `/dev/sda18`）中的 16 字节
`bootConfig` 文件。工具修改该文件，不修改内核或固件分区。

## 没有自动回滚

引导器不会递减启动尝试计数（源码确认没有写回）。某个槽位即使连续启动失败，
也不会自动切回另一个槽位——选中的槽会一直被启动，直到 `bootConfig` 再次被修改。

因此刷写 `r2` 时：

- 刷写前务必备份 B 槽三个分区；
- 建议全程连接 115200 8N1 串口；
- 在完成验证前不要执行 `mch-boot commit`。

如果 B 槽内核完全无法启动，可在串口一阶段 U-Boot 中用 `srboot` 重试 B 槽，或按
`docs/FLASHING.md` 的步骤把备份写回。`sgboot` 会进入 GOLD，**不要使用**。

## netrescue

当内核能够启动但根文件系统无法挂载时，initramfs 会进入网络救援环境。也可以先执行
`mch-boot rescue`，再重启进行一次性手动救援（marker 被消费后立即删除，不会困住机器）。

救援环境会：

- 尝试通过 DHCP 获取 IPv4 地址；
- DHCP 失败时使用 `192.168.1.222/24`；
- 提供 telnet root shell 和 FTP；
- 尝试组装 Linux MD 阵列。

可以随后挂载根文件系统：

```bash
mount /dev/md1 /mnt
```

> [!WARNING]
> netrescue 的 root shell 没有密码。同一网络中的任何人都可能连接，只能在可信、
> 隔离的局域网临时使用。
