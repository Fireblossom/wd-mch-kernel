# 救援与槽位切换（无需串口）

这台机器有三条独立的启动路径,全部可以从运行中的 Debian 里用一条命令切换。
工具:`tools/mch-boot`(装到 /usr/local/sbin/)。

## 三条路径

| 槽位 | 内容 | 何时用 |
|---|---|---|
| **B**(默认) | 本包的主线 6.18.2 内核 | 日常 |
| **A** | 厂商 4.9.330 内核 + 同一个 Debian(md1) | 新内核有问题时的完整可用回退 |
| **GOLD** | 出厂 WD 救援镜像 | 最后的救命稻草,分区表都乱了时 |

另有 **netrescue**:停在 initramfs 里,在局域网上开一个 telnet root shell。

## 原理

一阶段引导器从 FAT32 的 CONFIG 分区(sda18)读一个 16 字节文件 `bootConfig`,
格式 `<bootState>:<nbr>:<bna>:;`:

| bootState | 行为 |
|---|---|
| 0 NO_OTA | 启动 CBR(已提交的槽) |
| 1 INIT | 把 CBR 设为 A 并启动 A |
| 2 OTA_TRIGGERED | 启动 NBR(需 1<=bna<=5) |
| 3 OTA_PASSED | 把 NBR 提交为新 CBR 再启动 |
| 4 OTA_FAILED | 回退 CBR |
| **5 RECOVERY** | **启动 GOLD 救援镜像** |

fw_table(sda1)按 FW_TYPE 描述镜像:A 槽用 KERNEL/KERNEL_DT/KERNEL_ROOTFS,
B 槽用 RESCUE_KERNEL/RESCUE_DT,GOLD 用 GOLD_*。三组条目本包都保持完整。

## 用法

    mch-boot status      # 当前配置 + 正在跑哪个内核 + 已提交槽位
    mch-boot a           # 下次启动切到 A(厂商 4.9 内核)
    mch-boot b           # 下次启动切回 B(主线 6.18)
    mch-boot commit      # 把当前试运行的槽位设为永久
    mch-boot gold        # 下次启动进出厂救援镜像
    mch-boot rescue      # 下次启动停在 initramfs,开 telnet(一次性)
    mch-boot normal      # 取消试运行,回到已提交槽位

## netrescue(网络救援)

**自动触发**:找不到可启动的根文件系统时自动进入,不需要人操作。
**手动触发**:`mch-boot rescue` 后重启;**一次性**,再下次启动自动恢复正常。

进去后约 20 秒内:
- DHCP 拿地址(拿不到则回落 192.168.1.222/24),IPv6 走 RA 自动获取
- `telnet <ip>` 得到 root shell(**无密码**),`ftp <ip>` 传文件
- md 阵列已自动组好,可直接 `mount /dev/md1 /mnt` 修 fstab 等

⚠️ 救援 shell 无认证,任何同网段的人都能进。它只在 initramfs 阶段存在、
且手动模式是一次性的,但仍建议只在可信网络里用。

## 已知限制(务必知悉)

引导器**不会**递减 bna,也就是说**没有自动回滚**:被选中的槽位会一直被启动,
直到你再改一次 bootConfig。因此:

- **永远保持 A 槽可用**(本包不碰 A 槽)
- 主线内核完全起不来、又进不了系统改 bootConfig 时,只能靠串口(U-Boot 里
  `snboot`=A / `srboot`=B / `sgboot`=GOLD)或 WD 的 USB tp_recovery 流程

netrescue 覆盖的是"内核能起来但根文件系统坏了"这一最常见故障,该场景无需串口。
