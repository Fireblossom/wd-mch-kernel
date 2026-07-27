# 驱动移植指南

## 关键发现

### ❌ 缺失的驱动

**I2C 驱动** (`realtek,rtk-i2c`)
- **4.9 内核**: ✅ 存在 (`drivers/i2c/busses/i2c-rtk.c`)
- **6.18 内核**: ❌ 不存在
- **影响**: ⚠️ **严重** - I2C 控制器无法工作，PMIC 无法初始化，可能导致无法启动

## 需要移植的驱动

### 1. I2C 驱动 (最高优先级)

**源文件**: `/tmp/linux-4.9.330-extract/linux-4.9.330/drivers/i2c/busses/i2c-rtk.c`

**移植步骤**:

1. **复制驱动文件**
   ```bash
   cp /tmp/linux-4.9.330-extract/linux-4.9.330/drivers/i2c/busses/i2c-rtk.c \
      /home/ubuntu/linux/linux-6.18.2/drivers/i2c/busses/
   ```

2. **更新 Makefile**
   编辑 `linux-6.18.2/drivers/i2c/busses/Makefile`:
   ```makefile
   obj-$(CONFIG_I2C_RTK) += i2c-rtk.o
   ```

3. **更新 Kconfig**
   编辑 `linux-6.18.2/drivers/i2c/busses/Kconfig`:
   ```kconfig
   config I2C_RTK
       tristate "Realtek I2C controller"
       depends on ARCH_REALTEK || COMPILE_TEST
       help
         Support for Realtek I2C controller found on RTD1295 and similar SoCs.
   ```

4. **适配 6.18 内核 API**
   - 检查中断处理函数签名
   - 检查时钟 API 变化
   - 检查复位控制器 API
   - 检查设备树 API

5. **编译测试**
   ```bash
   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
   # 启用 I2C_RTK
   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules
   ```

### 2. 其他可能需要的驱动

检查以下驱动是否在 6.18 内核中支持：

#### Realtek ION 内存管理
- Compatible: `"Realtek,rtk-ion"`
- 如果不存在，可能需要禁用或使用替代方案

#### Realtek AVCPU
- Compatible: `"Realtek,rtk-avcpu"`
- 用于音频/视频处理

#### Realtek USB 管理器
- Compatible: `"Realtek,usb-manager"`
- USB 电源管理

#### Realtek 电源管理
- Compatible: `"Realtek,power-management"`
- 系统电源管理

## API 变化检查清单

### 中断处理
- [ ] `request_irq()` → 可能改为 `devm_request_irq()`
- [ ] 中断标志位定义

### 时钟 API
- [ ] `clk_get()` / `clk_put()` → 可能改为 `devm_clk_get()`
- [ ] 时钟频率设置 API

### 复位控制器
- [ ] 复位控制器 API 可能变化

### 设备树
- [ ] `of_property_read_*()` API
- [ ] 设备树节点访问方式

### 平台驱动
- [ ] `platform_driver` 结构体字段
- [ ] PM 操作结构

## 快速检查脚本

创建 `check_driver_compatibility.sh`:

```bash
#!/bin/bash

DRIVER_FILE="$1"
KERNEL_DIR="linux-6.18.2"

echo "检查驱动兼容性: $DRIVER_FILE"
echo ""

# 检查使用的 API
echo "=== 检查 API 使用 ==="
grep -E "request_irq|clk_get|of_property_read" "$DRIVER_FILE" | head -10

echo ""
echo "=== 检查头文件 ==="
grep -E "^#include" "$DRIVER_FILE"
```

## 测试步骤

1. **编译驱动**
   ```bash
   cd linux-6.18.2
   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M=drivers/i2c/busses modules
   ```

2. **加载驱动**
   ```bash
   insmod i2c-rtk.ko
   dmesg | grep -i i2c
   ```

3. **检查设备**
   ```bash
   ls -la /dev/i2c-*
   i2cdetect -l
   ```

## 替代方案

如果驱动移植困难，可以考虑：

1. **使用通用 I2C 驱动**
   - 检查是否有通用的 I2C 驱动可以配置
   - 可能需要修改设备树

2. **禁用 I2C 设备**
   - 如果 PMIC 不是必需的，可以暂时禁用
   - 但可能影响电源管理和系统稳定性

3. **使用设备树覆盖**
   - 在运行时动态加载设备树覆盖
   - 临时解决方案

## 参考资源

- [Linux 内核驱动移植指南](https://www.kernel.org/doc/html/latest/)
- [设备树绑定文档](https://www.kernel.org/doc/Documentation/devicetree/bindings/)
- [内核 API 变化](https://www.kernel.org/doc/html/latest/process/changes.html)

## 注意事项

⚠️ **重要**:
- 驱动移植需要深入理解内核 API
- 建议先在测试环境验证
- 保留原始驱动文件作为参考
- 记录所有 API 变化和修改

---

**建议**: 优先移植 I2C 驱动，因为它是系统启动的关键组件。


