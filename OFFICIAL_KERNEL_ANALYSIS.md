# 官方内核源码分析

## 发现的关键文件

### 设备树文件
- **Monarch 设备树**: `rtd-1295-monarch-1GB.dts` - WD My Cloud Home 使用的设备树
- **基础设备树**: `rtd-1295.dtsi` - RTD1295 SoC 基础定义
- **通用配置**: `rtd-1295-giraffe-common.dtsi` - Monarch 继承的通用配置

### 驱动文件
- **I2C 驱动**: `drivers/i2c/busses/i2c-rtk.c` - 使用 `"realtek,rtk-i2c"` compatible
- **Realtek 特定驱动**: `include/soc/realtek/` - 各种 Realtek 特定头文件

## 关键发现

### 1. I2C 驱动兼容性

**4.9 内核**:
- 驱动文件: `drivers/i2c/busses/i2c-rtk.c`
- Compatible: `"realtek,rtk-i2c"`

**6.18 内核**:
- 需要检查是否支持 `"realtek,rtk-i2c"`
- 如果不支持，可能需要从 4.9 内核移植驱动

### 2. Monarch 设备树关键配置

从 `rtd-1295-monarch-1GB.dts` 提取的关键信息：

#### 内存配置
```dts
memory@0 {
    device_type = "memory";
    reg = <0 0x40000000>; /* 1024 MB */
};
```

#### 启动参数
```dts
bootargs = "earlycon=uart8250,mmio32,0x98007800 console=ttyS0,115200 init=/init androidboot.hardware=kylin androidboot.storage=sata loglevel=4";
```

#### USB 配置
- USB 3.0 PHY 配置
- USB 2.0 PHY 配置
- USB 电源管理 GPIO

#### SATA 配置
- SATA PHY 参数
- SATA 端口 GPIO

#### PWM (系统 LED)
```dts
pwm_3 {
    duty_rate=<10>;
    enable = <1>;
};
```

#### 网络配置
```dts
nic: gmac@98016000 {
    led-cfg = <0x804F>;
};
```

### 3. 设备树包含关系

```
rtd-1295-monarch-1GB.dts
  ├── rtd-1295-giraffe-common.dtsi
  │   └── rtd-1295.dtsi
  │       ├── rtd-129x.dtsi
  │       ├── rtd-1295-pinctrl.dtsi
  │       ├── rtd-1295-usb.dtsi
  │       ├── rtd-1295-sata.dtsi
  │       └── rtd-129x-dcsys-debug.dtsi
  └── rtd-129x-dvfs-v1p0.dtsi
```

## 需要移植的驱动

### 1. I2C 驱动 (`i2c-rtk.c`)
- **状态**: 需要检查 6.18 内核是否支持
- **位置**: `drivers/i2c/busses/i2c-rtk.c`
- **Compatible**: `"realtek,rtk-i2c"`

### 2. Realtek 特定驱动
检查以下驱动是否在新内核中：
- USB 管理器驱动
- 电源管理驱动
- ION 内存管理驱动
- AVCPU 驱动

### 3. 设备树绑定
检查以下 compatible 字符串：
- `"Realtek,rtk-ion"`
- `"Realtek,rtk-avcpu"`
- `"Realtek,usb-manager"`
- `"Realtek,power-management"`
- `"Realtek,rtk-sata-phy"`
- `"Realtek,ahci-sata"`

## 移植策略

### 方案 A: 直接使用官方设备树（推荐）
1. 将 `rtd-1295-monarch-1GB.dts` 转换为 6.18 格式
2. 更新 compatible 字符串（如果需要）
3. 更新设备树语法（phandle 引用等）

### 方案 B: 从 extracted.dts 移植
1. 对比 `extracted.dts` 和官方设备树
2. 找出差异（可能是运行时修改）
3. 合并到新设备树

### 方案 C: 混合方案
1. 以官方设备树为基础
2. 从 `extracted.dts` 补充运行时配置
3. 更新为 6.18 格式

## 下一步行动

1. **检查驱动兼容性**
   ```bash
   grep -r "realtek,rtk-i2c" linux-6.18.2/drivers/
   ```

2. **转换官方设备树**
   - 将 `rtd-1295-monarch-1GB.dts` 转换为 6.18 格式
   - 更新所有包含的文件

3. **对比差异**
   - 对比官方设备树和 extracted.dts
   - 找出运行时修改的配置

4. **测试驱动**
   - 如果驱动不存在，考虑从 4.9 移植
   - 或者使用替代方案

## 文件位置

### 4.9 内核源码
```
/tmp/linux-4.9.330-extract/linux-4.9.330/
├── arch/arm64/boot/dts/realtek/rtd129x/
│   ├── rtd-1295-monarch-1GB.dts
│   ├── rtd-1295.dtsi
│   └── ...
└── drivers/
    └── i2c/busses/i2c-rtk.c
```

### 6.18 内核源码
```
/home/ubuntu/linux/linux-6.18.2/
├── arch/arm64/boot/dts/realtek/
│   └── rtd1295-wd-mycloud-home.dts (需要更新)
└── drivers/
    └── (需要检查驱动支持)
```


