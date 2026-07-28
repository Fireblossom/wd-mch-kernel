# 设备树对比分析

## 概述

本文档对比三个设备树源：
1. **官方 Monarch 设备树** (`rtd-1295-monarch-1GB.dts`) - WD 官方，针对 Android
2. **第三方 Debian 设备树** (`extracted.dts`) - 俄罗斯论坛，针对 Debian
3. **6.18 内核目标** - 需要适配的新内核

## 关键差异

### 1. 内存定义

#### 官方 Monarch (Android)
```dts
memory@0 {
    device_type = "memory";
    reg = <0 0x40000000>; /* 1024 MB */
};
```

#### 第三方 Debian (extracted.dts)
```dts
memory@0 {
    device_type = "memory";
    reg = <0x00 0x40000000>; /* 1024 MB - 相同 */
};
```

**结论**: 内存大小相同，但地址格式略有不同（官方使用 `<0>`，第三方使用 `<0x00>`）

### 2. 保留内存 (Reserved Memory)

#### 官方 Monarch
```dts
/memreserve/ SYS_BOOTCODE_MEMBASE SYS_BOOTCODE_MEMSIZE;
/memreserve/ RPC_COMM_PHYS RPC_COMM_SIZE;
/memreserve/ ACPU_FIREWARE_PHYS ACPU_FIREWARE_SIZE;
/memreserve/ RPC_RINGBUF_PHYS RPC_RINGBUF_SIZE;
/memreserve/ ROOTFS_NORMAL_START ROOTFS_NORMAL_SIZE;
/memreserve/ ION_AUDIO_HEAP_PHYS ION_AUDIO_HEAP_SIZE;
/memreserve/ ION_MEDIA_HEAP_PHYS1 ION_MEDIA_HEAP_SIZE1;
/memreserve/ ACPU_IDMEM_PHYS ACPU_IDMEM_SIZE;
/memreserve/ ION_MEDIA_HEAP_PHYS2 ION_MEDIA_HEAP_SIZE2;
/memreserve/ PSTORE_MEM_PHYS PSTORE_MEM_SIZE;
```

#### 第三方 Debian
```dts
reserved-memory {
    ringbuf@0 {
        reg = <0x1ffe000 0x4000>;
    }
    rbus@0 {
        reg = <0x98000000 0x200000>;
    }
    common@0 {
        reg = <0x1f000 0x1000>;
    }
    ramoops@0 {
        reg = <0x22000000 0x200000>;
    }
}
```

**关键差异**:
- 官方使用宏定义（`SYS_BOOTCODE_MEMBASE` 等）
- 第三方使用直接地址值
- 第三方简化了保留内存定义，移除了 Android 特定的 ION 堆

⚠️ 反思/纠错：
我们之前在 6.18 的 DTS 里沿用了 `compatible = "rsvmem-remap"` 这种写法，但 6.18 源码里并没有任何引用它的驱动/绑定，
这意味着它在 mainline 上等同于“摆设”。如果走 mainline 路线，应改成标准 `reserved-memory` 用法（`no-map`/`shared-dma-pool` 等）。

### 3. ION 内存管理

#### 官方 Monarch (Android 必需)
```dts
rtk,ion {
    rtk,ion-heap@8 { /* Audio */
        rtk,memory-reserve = <...>;
    }
    rtk,ion-heap@7 { /* TYPE_MEDIA */
        rtk,memory-reserve = <...>;
    }
}
```

#### 第三方 Debian
```dts
rtk,ion {
    rtk,ion-heap@4 { /* 简化定义 */
        rtk,memory-reservation-size = <0x00>;
    }
    rtk,ion-heap@0 {
        rtk,memory-reservation-size = <0x00>;
    }
    rtk,ion-heap@7 {
        rtk,memory-reserve = <0x2e00000 0x400 0x8e 0x12000000 0x1000000 0x8e>;
    }
    rtk,ion-heap@8 {
        rtk,memory-reserve = <0x2600000 0x400 0x8e>;
    }
}
```

**结论**: Debian 版本保留了 ION 但简化了配置，可能用于兼容性

### 4. CMA (Contiguous Memory Allocator)

#### 官方 Monarch
```dts
chosen {
    cma-region-enable = <1>;
    cma-region-info = <0x00000000 0x02000000 0x20000000>;
}
```

#### 第三方 Debian
```dts
chosen {
    cma-region-enable = <0x01>;
    cma-region-info = <0x00 0x2000000 0x20000000>;
}
```

**结论**: 配置相同，只是格式略有不同

⚠️ 反思/纠错（很关键）：
`cma-region-enable`/`cma-region-info` 不是设备树标准属性，属于 vendor 内核私货。
在 6.18（mainline 框架）里它们大概率**不起作用**。

更可靠的做法是在 `reserved-memory` 下用 mainline 的 CMA 描述：

```dts
reserved-memory {
    linux,cma {
        compatible = "shared-dma-pool";
        reusable;
        size = <0x02000000>; /* 32 MiB */
        linux,cma-default;
    };
};
```

### 5. 启动参数

#### 官方 Monarch (Android)
```dts
bootargs = "earlycon=uart8250,mmio32,0x98007800 console=ttyS0,115200 init=/init androidboot.hardware=kylin androidboot.storage=sata loglevel=4";
```

#### 第三方 Debian
```dts
bootargs = "earlycon=uart8250,mmio32,0x98007800 console=ttyS0,115200 init=/init androidboot.hardware=monarch androidboot.heapgrowthlimit=128m androidboot.heapsize=192m androidboot.storage=sata_b androidboot.selinux=permissive ver=4.2.2 sn=WX92DA079Z8J";
```

**关键差异**:
- 官方: `androidboot.hardware=kylin`
- 第三方: `androidboot.hardware=monarch` + 更多 Android 参数
- 第三方保留了 Android 参数但实际运行 Debian

### 6. 设备启用状态

#### 官方 Monarch
- `emmc@98012000`: `status = "disabled";`
- `uart1`: `status = "disabled";`
- `pcie@9804E000`: `status = "disabled";`
- `pcie2@9803B000`: `status = "disabled";`

#### 第三方 Debian
- `emmc@98012000`: `status = "disabled";` (相同)
- `serial1@9801B200`: `status = "disabled";` (相同)
- `pcie@9804E000`: `status = "disabled";` (相同)
- `pcie2@9803B000`: `status = "disabled";` (相同)

**结论**: 设备启用状态基本相同

### 7. 网络配置

#### 官方 Monarch
```dts
nic: gmac@98016000 {
    led-cfg = <0x804F>;
};
```

#### 第三方 Debian
```dts
gmac@98016000 {
    led-cfg = <0x804f>;  /* 小写，但值相同 */
    compatible = "Realtek,r8168";
    status = "okay";
    /* 更多详细配置 */
};
```

**结论**: 第三方有更完整的网络配置

## 移植建议

### 方案 1: 基于官方 Monarch（推荐用于 Android）
- 使用官方设备树作为基础
- 保持 Android 特定的配置
- 适合需要 Android 兼容性的场景

### 方案 2: 基于第三方 Debian（推荐用于 Debian/Linux）
- 使用第三方设备树作为基础
- 简化 ION 配置
- 优化内存布局
- 适合纯 Linux/Debian 系统

### 方案 3: 混合方案（推荐）
- 以官方 Monarch 为基础
- 从第三方 Debian 提取内存优化
- 移除不必要的 Android 特定配置
- 添加 Debian 需要的配置

## 内存布局对比

### 官方 Monarch 内存布局
```
0x00000000 - 0x0002FFFF: Boot code
0x0001F000 - 0x0001FFFF: RPC comm
0x01B00000 - 0x01EFFFFF: ACPU firmware
0x01FFE000 - 0x02001FFF: RPC ringbuf
0x02200000 - 0x025FFFFF: Rootfs normal
0x02600000 - 0x031FFFFF: ION audio heap
0x03200000 - 0x0E9FFFFF: ION media heap 1
0x10000000 - 0x10013FFF: ACPU IDMEM
0x11000000 - 0x181FFFFF: ION media heap 2
0x22000000 - 0x221FFFFF: Ramoops
```

### 第三方 Debian 内存布局
```
0x0001F000 - 0x0001FFFF: Common (RPC comm)
0x01FFE000 - 0x02001FFF: Ringbuf
0x098000000 - 0x0981FFFFF: RBUS
0x22000000 - 0x221FFFFF: Ramoops
```

**关键差异**:
- 第三方移除了大部分 ION 堆（Android 特定）
- 第三方简化了内存保留区域
- 第三方更适合通用 Linux 系统

## 6.18 内核适配建议

### 内存定义
```dts
memory@1f000 {
    device_type = "memory";
    reg = <0x1f000 0x7ffe1000>; /* 从 boot ROM 到 2GB */
};
```

### 保留内存（基于第三方 Debian）
```dts
reserved-memory {
    #address-cells = <1>;
    #size-cells = <1>;
    ranges;

    rbus@98000000 {
        compatible = "rsvmem-remap";
        reg = <0x98000000 0x200000>;
        no-map;
    };

    ramoops@22000000 {
        compatible = "ramoops";
        reg = <0x22000000 0x200000>;
        record-size = <0x4000>;
        console-size = <0x100000>;
        ftrace-size = <0x4000>;
    };
};
```

### CMA 配置
```dts
chosen {
    cma-region-enable = <1>;
    cma-region-info = <0x00000000 0x02000000 0x20000000>;
};
```

## 注意事项

1. **ION 内存管理**: 
   - 如果运行纯 Linux（非 Android），可以移除或简化 ION 配置
   - 如果运行 Android，需要保留 ION 配置

2. **内存布局**:
   - 第三方 Debian 版本优化了内存使用
   - 移除了 Android 特定的大块内存保留

3. **启动参数**:
   - Debian 系统不需要 Android 特定的启动参数
   - 可以简化为: `bootargs = "earlycon=uart8250,mmio32,0x98007800 console=ttyS0,115200";`

4. **设备树格式**:
   - 6.18 内核使用新的设备树格式
   - 需要将 phandle 引用转换为标签引用
   - 需要更新中断格式

## 下一步

1. 创建基于第三方 Debian 的设备树（适合 Linux/Debian）
2. 创建基于官方 Monarch 的设备树（适合 Android）
3. 创建混合版本（通用）

