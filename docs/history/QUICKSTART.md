# 快速开始（当前可用流程）

## 适用范围

本页用于当前仓库的实际可运行流程：
- 内核版本：6.18.2（RTD1295 兼容头修补）
- 已验证产物：`Image-6.18.2-v19-raw-padded`、`fw_table_v19.bin`
- Debian13 升级包：`MyCloudHome_Debian13_v6.0-k6.18-v19`

## 无聊天记录接续

如果迁移到本地电脑且不继承本次聊天记录，优先阅读：
- `LOCAL_CONTINUATION_PLAN.md`

## 当前状态

- 启动链路已打通（2nd stage `booti` 可进入 userspace）。
- SATA 与 GPT V3 分区枚举正常。
- `sda9` 识别为 `gzip+cpio`，initramfs 自动解包已可用。
- initramfs 对 Debian/systemd 根文件系统使用 `switch_root` 交接；对 vendor `gzip+cpio` rootfs 保留 `chroot` 调试路径。

## 路径 A：重编并生成刷机产物

```bash
cd /home/ubuntu/linux
./rebuild_package_and_print_flash.sh --version v19 --base-fw fw_table_v18.bin
```

脚本会自动：
1. 合并必要配置并重编 `Image`
2. 输出 `Image-6.18.2-v19-raw-padded` 与 `fw_table_v19.bin`
3. 打印可直接执行的刷机命令

## 路径 B：升级 Debian13 安装包内核

```bash
cd /home/ubuntu/linux
./upgrade_mychome_debian13_kernel.sh \
  --pkg-dir /home/ubuntu/linux/MyCloudHome_Debian13_v6.0 \
  --kernel-raw /home/ubuntu/linux/Image-6.18.2-v19-raw-padded \
  --dtb /home/ubuntu/linux/rtd1295-wd-mycloud-home-v11-padded.dtb \
  --out-dir /home/ubuntu/linux/MyCloudHome_Debian13_v6.0-k6.18-v19
```

该脚本会联动更新：
- `sata.uImage`
- `rescue.sata.dtb`
- `linux/16.img` / `linux/10.img`
- `linux/fwtable0.bin` / `linux/fwtable1.bin`

## 安装建议

- 优先 USB 安装（串口仅监控和故障兜底）。
- 若必须串口传文件，可用 YMODEM/XMODEM，但速度慢且易 overrun。
- 大文件传输优先 TFTP。

## 最小验证清单

安装或启动后，至少确认：

```bash
uname -a
lsblk
cat /proc/cmdline
```

如要验证容器能力，再补：

```bash
docker info
```

## 已废弃的旧结论（不再作为当前状态）

- “I2C 驱动是当前阻塞点”
- “仅完成基础设备树框架”
- “下一步先做 I2C 移植”

这些项在当前仓库中已不是主阻塞。
