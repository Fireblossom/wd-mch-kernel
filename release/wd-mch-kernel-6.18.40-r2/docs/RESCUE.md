# 救援与槽位切换

WD My Cloud Home 有三条启动路径：

| 槽位 | 内容 | 用途 |
|---|---|---|
| **B** | 本项目的主线内核 | 本次候选测试目标 |
| **A** | 厂商内核和同一个 Debian 根文件系统 | 主线内核失败时回退 |
| **GOLD** | WD 出厂救援镜像 | 最后的独立恢复路径 |

本包只更新 B 槽，不写 A 或 GOLD。

## `mch-boot` 工具

从运行中的 Debian 安装：

```bash
install -m 0755 tools/mch-boot /usr/local/sbin/mch-boot
```

常用命令：

```text
mch-boot status   显示当前启动配置
mch-boot a        下一次启动 A 槽
mch-boot b        下一次启动 B 槽
mch-boot commit   把正在试运行的 A/B 槽设为永久目标
mch-boot gold     下一次启动 GOLD
mch-boot rescue   下一次启动停在 initramfs 网络救援环境
mch-boot disarm   取消待执行的网络救援
mch-boot normal   清除试运行状态，启动已提交槽位
```

一阶段引导器读取 FAT32 CONFIG 分区（通常是 `/dev/sda18`）中的 16 字节
`bootConfig` 文件。工具修改该文件，不修改内核或固件分区。

## 没有自动回滚

引导器不会递减启动尝试计数。某个槽位即使连续启动失败，也不会自动切回另一个槽位。
因此测试 `r2` 时必须：

- 保持 A 槽可启动；
- 保持 GOLD 分区不变；
- 全程连接串口；
- 在完成全部验证前不执行 `mch-boot commit`。

如果 B 槽内核完全无法启动，只能在串口 U-Boot 中使用：

```text
snboot   启动 A 槽
srboot   启动 B 槽
sgboot   启动 GOLD
```

## netrescue

当内核能够启动但根文件系统无法挂载时，initramfs 会进入网络救援环境。也可以先执行
`mch-boot rescue`，再重启进行一次性手动救援。

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
