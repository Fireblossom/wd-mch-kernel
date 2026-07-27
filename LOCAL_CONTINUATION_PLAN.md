# 本地接续计划（无聊天记录版）

## 目标

你准备从服务器迁移到本地电脑继续推进 WD My Cloud Home (RTD1295) 内核与 Debian 安装工作。
本文件是完整交接手册：包含当前状态、必须带走的文件、校验方法、下一步详细执行计划、失败回滚方案。

## 当前基线（已验证）

- 目标内核：Linux 6.18.2
- 当前可用产物版本：v19
- 启动链状态：1st stage -> 2nd stage -> booti 已打通
- rootfs 关键事实：`/dev/sda9` 为 `gzip+cpio`，不是 ext4
- initramfs 交接策略：Debian/systemd 根文件系统使用 `switch_root`；vendor `gzip+cpio` rootfs 继续使用 `chroot`
- 兼容关键配置：已启用 `CONFIG_COMPAT=y`

## 必须迁移的文件

### A. 刷机与启动核心产物

- `Image-6.18.2-v19-raw-padded`
- `fw_table_v19.bin`
- `rtd1295-wd-mycloud-home-v11-padded.dtb`

### B. Debian13 升级包产物（建议整目录保留）

- `MyCloudHome_Debian13_v6.0-k6.18-v19/`
  - 重点文件：
    - `sata.uImage`
    - `rescue.sata.dtb`
    - `linux/fwtable0.bin`
    - `linux/fwtable1.bin`
    - `linux/16.img`
    - `linux/10.img`

### C. 必须迁移的脚本与文档

- `rebuild_package_and_print_flash.sh`
- `upgrade_mychome_debian13_kernel.sh`
- `initramfs/init`
- `PORTING_STATUS.md`
- `QUICKSTART.md`
- `SDA_PARTITION_MAP_V3_AND_DEBUG_PLAN.md`
- `LOCAL_CONTINUATION_PLAN.md`（本文件）

## 迁移后完整性校验（本地执行）

在本地目录执行：

```bash
sha256sum Image-6.18.2-v19-raw-padded \
  fw_table_v19.bin \
  rtd1295-wd-mycloud-home-v11-padded.dtb \
  MyCloudHome_Debian13_v6.0-k6.18-v19/sata.uImage \
  MyCloudHome_Debian13_v6.0-k6.18-v19/rescue.sata.dtb
```

应得到：

- `1be2052d4a23436574ebe23869b78b04949a1aa51ede6cf5a7ad358cfa39715d  Image-6.18.2-v19-raw-padded`
- `3d321a916058f02e5cd2ae9e9478c13e9dd83a84e2e2c6d1505bc7da21b4b4b0  fw_table_v19.bin`
- `8c3c92a9398d53dfd27cb7bc12bbdc09b4d3e4dbdb8ecae9bf833260ede8530b  rtd1295-wd-mycloud-home-v11-padded.dtb`
- `3e466b6d5c2cd309b5822c8f1076642d995fe796b0079db3080c2803cfa8dcd7  MyCloudHome_Debian13_v6.0-k6.18-v19/sata.uImage`
- `8c3c92a9398d53dfd27cb7bc12bbdc09b4d3e4dbdb8ecae9bf833260ede8530b  MyCloudHome_Debian13_v6.0-k6.18-v19/rescue.sata.dtb`

## 下一步详细计划（建议执行顺序）

## 第 1 阶段：本地环境恢复（必须）

1. 建立本地工作目录，放置上述文件。
2. 执行完整性校验（上一节）。
3. 确认脚本可执行：

```bash
chmod +x rebuild_package_and_print_flash.sh upgrade_mychome_debian13_kernel.sh
```

4. 快速检查当前文档基线：
   - `PORTING_STATUS.md`
   - `QUICKSTART.md`
   - `SDA_PARTITION_MAP_V3_AND_DEBUG_PLAN.md`

完成标准：校验值一致，脚本可运行，文档可读。

## 第 2 阶段：安装路径验证（优先 USB）

1. 使用 `MyCloudHome_Debian13_v6.0-k6.18-v19` 做一次安装试跑。
2. 首次目标不是“所有服务都好”，而是先确认三件事：
   - 能稳定启动到 userspace
   - 网络拿到地址
   - SSH 可连接

建议最小检查：

```bash
uname -a
lsblk
ip a
```

完成标准：系统可重启、可二次进入、SSH 稳定。

## 第 3 阶段：服务兼容性回归

1. 排查并抑制旧 Android 服务噪音（如循环重启服务）。
2. 验证 Docker/containerd（若本地目标包含 OMV/Docker）：

```bash
docker info
```

3. 出现异常时优先保系统稳定，再逐个恢复附加服务。

完成标准：基础服务稳定，无高频重启风暴。

## 第 4 阶段：可重复发布流程固化

1. 固化“重编 -> 打包 -> 校验 -> 刷机命令输出”流程。
2. 保留最近两版产物（当前策略：v18、v19），旧版定期清理。
3. 为下一次迁移准备“最小交接包”。

## 遇错时的决策树

1. 无串口输出或 early 阶段静默：
   - 先核对内核头 patch（text_offset/code0/pe_offset）
   - 再核对 fw_table size/checksum

2. 能进内核但 rootfs 不起：
   - 先确认 `sda9` 是否仍是 gzip+cpio
   - 再检查 `initramfs/init` 中 Debian `switch_root` 与 vendor `chroot` 路径

3. userspace 启动后服务风暴：
   - 先禁用非关键服务
   - 记录 `dmesg` 与进程状态
   - 最后再恢复容器/附加服务

## 回滚方案

- 保留并可随时回滚到 v18：
  - `Image-6.18.2-v18-raw-padded`
  - `fw_table_v18.bin`

建议：任何大改前先确认 v18 回滚路径仍可用。

## 本地继续时的注意事项

- 串口出现 `ttyS0 input overrun` 时，逐行短命令输入。
- 大文件传输优先网络（TFTP/SCP），不要长时间依赖串口传输。
- 不要删除原始备份文件：
  - `fw_table_original.bin`
  - `backup_sda8_kernel_b.img`
  - `backup_sda6_fdt_b.img`
  - `gpt_primary.bin`
  - `gpt_backup.bin`

---

当前建议：先在本地复现“v19 能稳定进系统”的最小闭环，再进入服务兼容性回归。
