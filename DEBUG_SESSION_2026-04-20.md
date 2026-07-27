# WD My Cloud Home Debug Session Log

Date: 2026-04-20
Workspace: `/home/ubuntu/linux`
Target: WD My Cloud Home / Realtek RTD1295
Goal: Continue kernel/userspace bring-up for the Debian13-based install package while using the vendor 4.9 tree only as hardware reference.

## 1. Initial Symptom From Serial Log

The starting serial log showed:

- FSBL/U-Boot path completed successfully.
- Linux 6.18.2 booted to userspace.
- SATA/AHCI link-up worked.
- GPT partitions were visible.
- mdraid arrays `md0`, `md1`, `md2` were assembled.
- `md1` mounted successfully as ext4.
- The system then failed during handoff from initramfs to the real rootfs and dropped to a BusyBox shell.

The key failure sequence from the log was:

```text
[initramfs] Debian rootfs detected on /dev/md1
[initramfs] chroot -> /newroot /sbin/init
init: required argument missing.
[initramfs] Debian init exited, fallback to shell
...
[initramfs] dropping to shell
```

There was also a secondary symptom:

```text
mount: mounting sysfs on /newroot/sys failed: Device or resource busy
```

This suggested that `/newroot` submounts were not being cleaned up after a failed attempt.

## 2. First Conclusion: This Was Not Primarily a SATA/ext4/mdraid Driver Failure

The following parts were already working in the observed boot:

- SATA PHY and AHCI host
- GPT partition parsing
- Block device discovery
- mdraid assembly
- ext4 mount of the Debian system partition

Therefore the primary failure was not "storage drivers are broken". It was a rootfs handoff problem in initramfs userspace.

## 3. Initramfs Investigation

The active initramfs script in the workspace is:

- `initramfs/init`

Relevant findings:

- The script originally tried to boot Debian by:

```sh
chroot /newroot /sbin/init
```

- This is fine for some debug use cases, but is not correct for a real Debian/systemd handoff.
- The Debian rootfs in `MyCloudHome_Debian13_v6.0/linux/linux.tar.xz` is a usr-merge system:
  - `/usr/sbin/init -> ../lib/systemd/systemd`
  - the real init is `systemd`

This matters because systemd expects to be PID 1 for system mode. Running it under plain `chroot` is not equivalent to a real root switch.

## 4. What Was Learned From The Debian13 Package

The package `MyCloudHome_Debian13_v6.0` is not a pure direct-to-Debian boot image.
It keeps a small vendor-style intermediate rootfs and then hands off to Debian.

### 4.1 Rescue/installer environment

The rescue image:

- `MyCloudHome_Debian13_v6.0/rescue.root.sata.cpio.gz_pad.img`

contains:

- `/init`
- `bin/install-linux0.sh`
- `bin/install-linux1.sh`
- `bin/mdadm`

Its `/init` is a 4.9-based rescue shell/installer environment. It loads modules, brings up network and storage, then leaves the user in a shell.

### 4.2 Installed runtime rootfs layout

The Debian install package also contains:

- `linux/rootfs0.bin`
- `linux/rootfs1.bin`

Both are `gzip+cpio` images, not ext4.

Those rootfs images contain a small early userspace whose `/init` does the following:

1. mounts `proc`, `sys`, `devpts`
2. loads `phy-rtk-sata.ko`
3. assembles:
   - `md0`
   - `md1`
   - `md2`
4. mounts `/dev/md1` on `/mnt`
5. executes:

```sh
exec switch_root /mnt /sbin/init
```

This is extremely important:

- The Debian package itself already proves that the intended handoff method for Debian is `switch_root`, not `chroot`.

### 4.3 Debian real rootfs assumptions

From `linux/linux.tar.xz`:

- `/etc/fstab` contains:

```fstab
/dev/md1    /      ext4  errors=remount-ro 0 1
/dev/md0    none   swap  sw                0 0
/dev/md2    /data  ext4  errors=remount-ro 0 2
```

- `/etc/mdadm/mdadm.conf` defines persistent arrays.
- `/usr/sbin/init` points to `systemd`.

So the Debian userspace expectation is:

- `mdadm` works
- `/dev/md1` is the real root
- PID 1 becomes systemd after a proper root switch

## 5. Initramfs Fix Applied

File changed:

- `initramfs/init`

### 5.1 Functional changes

Added helper functions:

- `is_mounted()`
- `cleanup_newroot()`
- `prepare_newroot_mounts()`
- `find_debian_init()`
- `find_root_init()`
- `handoff_to_debian_rootfs()`

### 5.2 New policy

Two different handoff paths are now used:

1. Debian/mdraid rootfs
   - use `switch_root`
   - reason: systemd needs a real PID 1 handoff

2. Vendor `gzip+cpio` rescue rootfs
   - keep `chroot`
   - reason: if vendor init exits, a hard PID 1 replacement could panic the system during debug

### 5.3 Specific behavioral fix

Before:

- Debian handoff used `chroot`
- failed attempts left `/newroot/proc`, `/newroot/sys`, `/newroot/dev` mounted

After:

- Debian handoff uses:

```sh
exec /bin/busybox switch_root -c /dev/console "$root" "$init"
```

- mountpoints under `/newroot` are cleaned before retry/fallback

### 5.4 Validation performed

- `sh -n initramfs/init` passed

## 6. Documentation Updated To Match Reality

These files were updated because they previously described the Debian handoff as `chroot`:

- `PORTING_STATUS.md`
- `QUICKSTART.md`
- `SDA_PARTITION_MAP_V3_AND_DEBUG_PLAN.md`
- `LOCAL_CONTINUATION_PLAN.md`

The new wording reflects:

- Debian/systemd rootfs uses `switch_root`
- vendor `gzip+cpio` rootfs keeps a `chroot` debug path

## 7. 4.9 Vendor Tree Investigation

Important note:

- The top-level local directory `linux-4.9.330/` in the workspace is only a partial snapshot, mainly containing a vendor NIC driver copy.
- The full vendor 4.9 tree is in:

`GPL_MCH_Monarch_9.9.0-102_20251211/kernel/linux-4.9.330.tar.gz`

That full tree was used as the source of truth for hardware bring-up reference.

## 8. What The Vendor 4.9 Tree Actually Does

Board DTS identified:

- `arch/arm64/boot/dts/realtek/rtd129x/rtd-1295-monarch-1GB.dts`

Core SoC DTS:

- `arch/arm64/boot/dts/realtek/rtd129x/rtd-1295.dtsi`

SATA DTS fragment:

- `arch/arm64/boot/dts/realtek/rtd129x/rtd-1295-sata.dtsi`

### 8.1 CPU bring-up in 4.9

4.9 uses:

- `enable-method = "rtk-spin-table"`
- `cpu-release-addr = <0x0 0x9801AA44>`

Implemented by:

- `drivers/soc/realtek/rtd129x/rtd129x_spin_table.c`

This is a Realtek-specific SMP bring-up method.

### 8.2 UART0 in 4.9

4.9 UART0 is not wired directly to the GIC in the DT.

It uses:

- vendor irq mux:
  - `compatible = "Realtek,rtk-irq-mux"`
- UART0:
  - `interrupt-parent = <&mux_intc>`
  - `interrupts = <1 2>`
  - `interrupts-st-mask = <0x4>`

### 8.3 SATA in 4.9

4.9 SATA uses a vendor combination:

- PHY:
  - `compatible = "Realtek,rtk-sata-phy"`
  - driver: `drivers/phy/phy-rtk-sata.c`
- AHCI host:
  - `compatible = "Realtek,ahci-sata"`
  - driver: `drivers/ata/ahci_rtk.c`

## 9. Comparison Against Current 6.18 State

### 9.1 CPU

Current 6.18 before this session:

- CPU nodes had no `enable-method`
- boot log showed:

```text
/cpus/cpu@1: missing enable-method property
/cpus/cpu@2: missing enable-method property
/cpus/cpu@3: missing enable-method property
SMP: Total of 1 processors activated.
```

Conclusion:

- This was a real DTS bring-up gap compared with the vendor 4.9 tree.

### 9.2 UART0

Current 6.18 before this session:

- `uart0` existed in the SoC DTS but lacked interrupt wiring equivalent to vendor 4.9
- boot log showed:

```text
dw-apb-uart 98007800.serial: error -ENXIO: IRQ index 0 not found
```

Conclusion:

- Console worked through earlycon/legacy console fallback, but the full UART interrupt description was incomplete.

### 9.3 SATA

SATA was already mostly functional on 6.18:

- PHY initialized
- AHCI host came up
- disk enumerated
- partitions visible
- mdraid built

Conclusion:

- SATA was no longer the primary blocker.

## 10. DTS Fixes Applied In 6.18

File changed:

- `linux-6.18.2/arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dts`

### 10.1 UART0 fix

Added:

```dts
&uart0 {
    interrupt-parent = <&mux_intc>;
    interrupts = <1 2>;
    interrupts-st-mask = <0x4>;
    status = "okay";
};
```

### 10.2 CPU fix

The vendor 4.9 tree uses `rtk-spin-table`, but mainline arm64 6.18 only knows the generic:

- `spin-table`

So the board DTS was updated to use the mainline-compatible form:

```dts
&cpu0 { enable-method = "spin-table"; cpu-release-addr = <0x0 0x9801aa44>; };
&cpu1 { enable-method = "spin-table"; cpu-release-addr = <0x0 0x9801aa44>; };
&cpu2 { enable-method = "spin-table"; cpu-release-addr = <0x0 0x9801aa44>; };
&cpu3 { enable-method = "spin-table"; cpu-release-addr = <0x0 0x9801aa44>; };
```

Rationale:

- copy the vendor release address
- use the mainline-recognized method name instead of the Realtek-private one

### 10.3 Validation performed

- `make -C linux-6.18.2 ARCH=arm64 dtbs` passed

## 11. New DTB Produced

New padded DTB created:

- `rtd1295-wd-mycloud-home-v12-padded.dtb`

Creation method:

1. copy the newly built DTB
2. pad/truncate to 28672 bytes so it matches the expected packaging size used by existing scripts

Checksum:

```text
2ab4ac3a2b541189131f1c73b6e6e2768a87288b9cfb8d519b9e2a9da511b700  rtd1295-wd-mycloud-home-v12-padded.dtb
```

## 12. Artifacts Built During This Session

### 12.1 Version v22

Purpose:

- include initramfs `switch_root` handoff fix for Debian

Files:

- `Image-6.18.2-v22-raw-padded`
- `fw_table_v22.bin`
- `MyCloudHome_Debian13_v6.0-k6.18-v22/`

Checksums:

```text
c77d358f2c4d3b74fec23279aa1b2fd4b232001101fd686b781483d80a72219b  Image-6.18.2-v22-raw-padded
4e7e8753eb398e79f6cf72653feb2ba41bbffa2131603ea8de8405987e83b68d  fw_table_v22.bin
53a0f7323858bd0df85a7352b281bc8a1539ca655a5620b0ee5d416e8cae32c7  MyCloudHome_Debian13_v6.0-k6.18-v22/sata.uImage
8c3c92a9398d53dfd27cb7bc12bbdc09b4d3e4dbdb8ecae9bf833260ede8530b  MyCloudHome_Debian13_v6.0-k6.18-v22/rescue.sata.dtb
```

### 12.2 Version v23

Purpose:

- include v22 initramfs fixes
- plus CPU/UART DTS fixes
- plus the new `rtd1295-wd-mycloud-home-v12-padded.dtb`

Files:

- `Image-6.18.2-v23-raw-padded`
- `fw_table_v23.bin`
- `MyCloudHome_Debian13_v6.0-k6.18-v23/`

Checksums:

```text
9565e9c75415b3ef58d9530c8e6a3d652ecb3000a4895b4d760b5247cd123215  Image-6.18.2-v23-raw-padded
08fb9eff25b30ba30047ea89cbf56df7c1e7ea9d80dbe2846c004b46204d187b  fw_table_v23.bin
0f8dc0a3554c1c2675354823069fa80e89a86044dd5eeab31018ff5ef17e2125  MyCloudHome_Debian13_v6.0-k6.18-v23/sata.uImage
2ab4ac3a2b541189131f1c73b6e6e2768a87288b9cfb8d519b9e2a9da511b700  MyCloudHome_Debian13_v6.0-k6.18-v23/rescue.sata.dtb
```

## 13. Commands Used To Build

### 13.1 Raw image / fw table rebuild

```bash
cd /home/ubuntu/linux
./rebuild_package_and_print_flash.sh --version v23 --base-fw fw_table_v22.bin --dtb rtd1295-wd-mycloud-home-v12-padded.dtb
```

### 13.2 Debian13 package update

```bash
cd /home/ubuntu/linux
./upgrade_mychome_debian13_kernel.sh \
  --pkg-dir /home/ubuntu/linux/MyCloudHome_Debian13_v6.0 \
  --kernel-raw /home/ubuntu/linux/Image-6.18.2-v23-raw-padded \
  --dtb /home/ubuntu/linux/rtd1295-wd-mycloud-home-v12-padded.dtb \
  --out-dir /home/ubuntu/linux/MyCloudHome_Debian13_v6.0-k6.18-v23
```

## 14. Expected Boot Differences To Watch For Next

If v23 is booted and the DTS changes are actually being used, the next serial log should ideally show:

### 14.1 CPU

These messages should disappear:

```text
/cpus/cpu@1: missing enable-method property
/cpus/cpu@2: missing enable-method property
/cpus/cpu@3: missing enable-method property
```

And SMP should ideally move from 1 CPU to 4 CPUs.

### 14.2 UART

This message should disappear:

```text
dw-apb-uart 98007800.serial: error -ENXIO: IRQ index 0 not found
```

### 14.3 Debian handoff

This old path should no longer appear:

```text
[initramfs] chroot -> /newroot /sbin/init
```

Instead the Debian handoff should use:

```text
[initramfs] exec switch_root /newroot /sbin/init
```

## 15. Remaining Risk / Unknowns

### 15.1 CPU bring-up risk

Vendor 4.9 uses:

- `rtk-spin-table`

Current 6.18 uses:

- `spin-table`

This is the best mainline-compatible approximation, but it is still possible that the Realtek platform relies on extra vendor behavior that generic `spin-table` does not reproduce.

If SMP still fails on v23, the next place to investigate is whether the board/firmware/BL31 path expects extra semantics beyond the generic mainline spin-table support.

### 15.2 Runtime validation not yet performed on real hardware

This session completed:

- code inspection
- DTS comparison
- initramfs fixes
- script validation
- DTB build validation
- image/package rebuild

This session did not complete:

- live boot validation of v22 or v23 on the target hardware

## 16. Practical Summary

The most important outcomes of this session are:

1. Confirmed that the Debian package itself uses `switch_root`, so the initramfs Debian handoff fix was necessary and correct.
2. Confirmed that original 4.9 vendor hardware bring-up differs from current 6.18 mainly in:
   - CPU enable method
   - UART interrupt wiring
3. Produced new artifacts:
   - `v22` for Debian handoff fix
   - `v23` for Debian handoff fix plus CPU/UART DTS fixes

## 17. Recommended Next Action

Boot `v23` first, then compare the serial log against these three checkpoints:

- does SMP rise above 1 CPU?
- does UART lose the `IRQ index 0 not found` error?
- does Debian handoff change from `chroot` to `switch_root`?

Those three observations will determine the next debugging branch.
