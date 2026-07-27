# Linux 6.18 内核移植指南 - WD My Cloud Home

## 概述

本指南帮助您将 Linux 6.18.2 内核移植到 WD My Cloud Home 设备。该设备基于 Realtek RTD1295 SoC，当前运行内核 4.9.330。

## 硬件信息

- **SoC**: Realtek RTD1295
- **CPU**: ARM Cortex-A53 四核
- **内存**: 1 GiB
- **当前内核**: 4.9.330
- **目标内核**: 6.18.2

## 移植状态

✅ **已完成**:
- 基础设备树文件已创建 (`rtd1295-wd-mycloud-home.dts`)
- Makefile 已更新
- 6.18.2 内核已包含 RTD1295 基础支持
- 启动链路已打通（2nd stage `booti` 可进入 userspace）
- `sda9` gzip+cpio 路径已验证可解包并交接 rootfs
- 兼容性关键项已落地（Image header 修补、fw_table 自动重算、CONFIG_COMPAT）

⚠️ **进行中**:
- Debian 安装后的 userspace 服务稳定性回归
- Docker/containerd 在新内核上的端到端验证
- 安装流程自动化前置校验（文件与 fw_table 字段）

## 关键发现

### 1. 内核支持情况

Linux 6.18.2 内核已经包含了对 RTD1295 的基础支持：
- ✅ 设备树基础结构 (`rtd129x.dtsi`, `rtd1295.dtsi`)
- ✅ GPIO 驱动 (`drivers/gpio/gpio-rtd.c`)
- ✅ USB PHY 驱动 (`drivers/phy/realtek/`)
- ✅ RTC 驱动 (`drivers/rtc/rtc-rtd119x.c`)
- ✅ Watchdog 驱动 (`drivers/watchdog/rtd119x_wdt.c`)
- ✅ USB DWC3 驱动支持 (`drivers/usb/dwc3/dwc3-rtk.c`)

### 2. 设备树格式变化

从 4.9 到 6.18 的主要变化：

#### 旧格式 (4.9):
```dts
i2c@0x98007D00 {
    compatible = "realtek,rtk-i2c";
    clocks = <0x0a 0x09>;  /* 使用 phandle 引用 */
    resets = <0x0a 0x0b>;
    interrupts = <0x01 0x08>;
    reg = <0x98007d00 0x100 0x98007000 0x100>;
    pinctrl-0 = <0x09>;
};
```

#### 新格式 (6.18):
```dts
&i2c_0 {
    compatible = "realtek,rtk-i2c";  /* 需要确认正确的 compatible */
    clocks = <&iso_clk RTD1295_CLK_EN_I2C_0>;
    resets = <&iso_reset RTD1295_ISO_RSTN_I2C_0>;
    interrupts = <GIC_SPI 8 IRQ_TYPE_LEVEL_HIGH>;
    reg = <0x98007d00 0x100>;
    pinctrl-0 = <&i2c_pins_0>;
    status = "okay";
};
```

### 3. 需要移植的主要组件

#### 3.1 I2C 控制器
- **位置**: `extracted.dts` 行 20-145, 561-574, 973-986, 1679-1692, 1865-1878
- **状态**: 需要确认新内核中的 compatible 字符串
- **关键设备**: 
  - PMIC (g2227@12) - 电源管理
  - 其他 I2C 设备

#### 3.2 USB 控制器
- **位置**: `extracted.dts` 行 234-240, 302-313, 315-337, 599-610, 1189-1264, 2082-2104
- **状态**: 新内核已有 DWC3 驱动支持
- **注意**: 需要检查 USB PHY 配置

#### 3.3 SATA 控制器
- **位置**: `extracted.dts` 行 147-167, 1454-1470
- **状态**: 需要确认 SATA 驱动支持

#### 3.4 网络控制器 (GMAC)
- **位置**: `extracted.dts` 行 258-279
- **状态**: 需要确认网络驱动

#### 3.5 GPIO 和 Pin Control
- **位置**: `extracted.dts` 行 618-907, 1771-1786, 1880-1896
- **状态**: 新内核已有 GPIO 驱动

#### 3.6 时钟和复位控制器
- **位置**: `extracted.dts` 多处
- **状态**: 新内核已有基础支持

#### 3.7 电源管理
- **位置**: `extracted.dts` 行 576-586, 1987-2080
- **状态**: 需要移植 CPU 频率表

## 移植步骤

### 步骤 1: 准备环境

```bash
cd /home/ubuntu/linux/linux-6.18.2
```

### 步骤 2: 配置内核

```bash
# 使用默认 Realtek 配置作为起点
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig

# 或者使用现有配置
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
```

**关键配置选项**:
- `CONFIG_ARCH_REALTEK=y`
- `CONFIG_ARM64=y`
- 启用必要的驱动模块

### 步骤 3: 逐步移植设备树节点

#### 3.1 从 extracted.dts 提取关键信息

使用以下命令提取特定节点：
```bash
# 提取 I2C 节点
grep -A 50 "i2c@0x98007D00" extracted.dts

# 提取 USB 节点
grep -A 30 "usb" extracted.dts

# 提取 SATA 节点
grep -A 20 "sata" extracted.dts
```

#### 3.2 转换格式

将旧格式转换为新格式：
1. 将十六进制 phandle 引用 (`<0x0a>`) 转换为标签引用 (`<&iso_clk>`)
2. 将中断号格式从 `<0x01 0x08>` 转换为 `<GIC_SPI 8 IRQ_TYPE_LEVEL_HIGH>`
3. 移除 `linux,phandle` 和 `phandle` 属性（使用标签替代）

#### 3.3 验证兼容性

检查每个节点的 `compatible` 字符串是否在新内核中支持：
```bash
# 搜索驱动中的 compatible 字符串
grep -r "realtek,rtk-i2c" linux-6.18.2/drivers/
```

### 步骤 4: 编译设备树

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- dtbs
```

生成的设备树文件：
```
arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dtb
```

### 步骤 5: 测试

1. **设备树验证**:
```bash
dtc -I dtb -O dts -o test.dts rtd1295-wd-mycloud-home.dtb
```

2. **在设备上测试**:
   - 备份原始设备树
   - 替换设备树文件
   - 启动设备并检查日志

## 已知问题和注意事项

### 1. I2C 驱动兼容性

旧设备树使用 `"realtek,rtk-i2c"`，需要确认新内核是否支持。如果不支持，可能需要：
- 使用替代的 I2C 驱动
- 或者添加兼容的驱动代码

### 2. 自定义驱动

WD My Cloud Home 可能使用了一些自定义驱动（如 `Realtek,rtk1295-*`），这些可能需要：
- 从旧内核移植
- 或者使用新内核的替代方案

### 3. 设备树属性变化

某些属性可能已废弃或更改：
- `cma-region-enable` / `cma-region-info` → 使用 `reserved-memory` 节点
- `swiotlb-*` → 内核配置选项

### 4. 中断控制器

新内核使用标准的 GIC 定义，需要更新所有中断引用。

## 调试技巧

### 1. 查看设备树
```bash
# 在运行的系统上
cat /proc/device-tree/compatible
ls -la /sys/firmware/devicetree/base/
```

### 2. 检查驱动加载
```bash
dmesg | grep -i "realtek\|rtd1295"
lsmod | grep rtd
```

### 3. 设备树编译错误
```bash
# 详细输出
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- dtbs V=1
```

## 下一步工作

1. **安装路径验证**:
   - [ ] 使用 `MyCloudHome_Debian13_v6.0-k6.18-v19` 完整安装一次
   - [ ] 验证重启后可稳定进入 Debian userspace

2. **服务兼容性回归**:
   - [ ] 网络、存储、SSH 稳定性
   - [ ] Docker/containerd 组合验证

3. **文档与自动化收敛**:
   - [ ] 安装前自动体检脚本（关键文件与 fw_table 字段一致性）
   - [ ] 统一保留当前推荐流程，移除历史分支噪音

## 参考资源

- [Linux 设备树文档](https://www.kernel.org/doc/Documentation/devicetree/)
- [Realtek RTD1295 数据手册](https://www.realtek.com/)
- [Linux 内核邮件列表](https://lkml.org/)

## 贡献

如果您发现错误或有改进建议，请：
1. 更新设备树文件
2. 更新本文档
3. 记录测试结果

---

**注意**: 内核移植是一个复杂的过程，可能需要多次迭代。建议在测试环境中充分验证后再部署到生产设备。


