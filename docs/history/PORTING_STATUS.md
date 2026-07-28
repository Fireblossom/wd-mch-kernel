# 移植状态总结（2026-04-19）

## 当前结论

- 6.18.2 内核已可在 WD My Cloud Home (RTD1295) 上稳定进入 userspace。
- 启动链路（1st stage -> 2nd stage -> booti）已打通。
- SATA/AHCI 与分区枚举已恢复（可见 sda1..sda24）。
- ROOTFS_GOLD (`/dev/sda9`) 已确认是 `gzip+cpio`，不是 ext4。
- initramfs 已支持自动解包 rootfs；Debian/mdraid 根文件系统使用 `switch_root` 交接，vendor `gzip+cpio` rootfs 保留 `chroot` 调试路径。
- 已生成 Debian13 升级包：`MyCloudHome_Debian13_v6.0-k6.18-v19`。

## 已完成项

### 启动与镜像兼容
- ARM64 Image header 兼容修补已固化：`code0` / `text_offset=0x200000` / `pe_offset=0x40`。
- fw_table 的 DTB/KERNEL size 与 checksum 自动重算已稳定。
- 固件打包与刷机命令输出脚本可用：`rebuild_package_and_print_flash.sh`。

### 驱动与设备树
- I2C + PMIC + regulator 移植并可编译。
- IRQ mux 与 rsvmem-remap helper 已移植并可编译。
- SATA 路径已可用（含 vendor phy + AHCI 组合）。
- DTS 中历史冲突（reserved-memory/reg overlap）导致的 EBUSY 问题已处理。

### rootfs 交接
- `sda9` 自动识别 gzip 魔数并解包。
- Debian/systemd 根文件系统改为 `switch_root`，确保真实 rootfs 的 `init` 作为 PID 1 启动。
- vendor `gzip+cpio` rootfs 仍保留 `chroot` 路径，避免调试时 init 退出直接触发 panic。
- 已启用 `CONFIG_COMPAT=y` 解决 32-bit userspace `Exec format error`。

### Debian13 包升级链路
- 新增升级脚本：`upgrade_mychome_debian13_kernel.sh`。
- 已完成对以下文件的联动更新：
  - `sata.uImage`
  - `rescue.sata.dtb`
  - `linux/16.img` (KERNEL_GOLD)
  - `linux/10.img` (FDT_GOLD)
  - `linux/fwtable0.bin`
  - `linux/fwtable1.bin`

## 当前未完成/风险项

1. userspace 服务兼容性仍需收敛（例如个别旧服务在新内核上的重启风暴）。
2. Debian 安装后需做一次完整回归（网络、Docker、存储、重启恢复）。
3. 仍需沉淀“失败可回滚”的安装前校验流程（建议在 U 盘安装前自动验证关键文件/字段）。

## 下一步（按优先级）

1. 在 `MyCloudHome_Debian13_v6.0-k6.18-v19` 上做一次完整安装验证（建议先 USB 安装路径）。
2. 启动后执行最小回归：
   - `uname -a`
   - `lsblk`
   - 网络 DHCP/SSH
   - `docker info`（如安装 Docker）
3. 将 adbd/旧 Android 服务策略默认设为“禁用或 oneshot”，减少启动噪音。

## 关键文件

- 进度状态：`PORTING_STATUS.md`
- 快速操作：`QUICKSTART.md`
- GPT/分区与调试：`SDA_PARTITION_MAP_V3_AND_DEBUG_PLAN.md`
- 自动升级脚本：`upgrade_mychome_debian13_kernel.sh`
- 打包脚本：`rebuild_package_and_print_flash.sh`

---

当前状态：内核移植主链路已打通，重点从“能启动”转向“安装与服务稳定性回归”。
