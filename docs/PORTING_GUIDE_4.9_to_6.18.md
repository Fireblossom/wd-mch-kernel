# Porting the WD My Cloud Home from vendor Linux 4.9.330 to mainline 6.18.40

**Target**: WD My Cloud Home, single-bay model — Realtek RTD1295 ("Monarch"/"Kamino" platform), 4× Cortex-A53, 1 GiB DRAM, one SATA SSD.

**Result**: mainline 6.18.40 running a full Debian 13 + OpenMediaVault 8 on real hardware, with 4-core SMP, interrupt-driven serial, gigabit ethernet, USB 3 SuperSpeed, a thermal sensor, working soft reboot, NFS/SMB and Docker.

This document explains **the port itself**: what each source change does, why it was necessary, and how the problem was diagnosed. It is not a flashing manual (see [README.md](../README.md) and the release [`FLASHING.md`](../release/wd-mch-kernel-6.18.2-r1/docs/FLASHING.md)), and not a version chronology (see [`DEVELOPMENT_HISTORY.md`](../DEVELOPMENT_HISTORY.md)).

---

## 0. Read this first: what kind of port this is

Mainline support for the RTD1295 is **far more complete than it first appears**. The actual distribution of work was roughly:

| Category | Share | Notes |
|---|---|---|
| Making existing mainline drivers selectable | Largest | Three drivers sat in the mainline tree behind Kconfig dependencies that could never be satisfied |
| Satisfying the vendor bootloader's conventions | Second | Image header, fw_table, DTB padding — nothing to do with kernel features, but without them the machine does not boot at all |
| Expressing vendor-private semantics with mainline mechanisms | Moderate | spin-table, IRQ mux, reset, clock gates |
| Genuinely new code | Smallest | One ~100-line thermal driver and one watchdog patch |
| Carried over wholesale from the vendor tree | One file | `r8169soc.c` (ethernet, the vendor's platform variant of r8169) |

**The single most repeated trap**: the driver source is in the mainline tree, the Makefile references it, but the Kconfig prompt is gated behind an unsatisfiable condition, so the symbol never exists in `.config` and the driver is never linked. This happened three times (the IRQ mux's `if COMPILE_TEST`, `NET_VENDOR_REALTEK depends on PCI`, and `R8169SOC depends on ARCH_RTD129x`).

**How to recognise it**: if `grep` finds the symbol nowhere in `.config` *and* `System.map` has zero hits for the driver's symbols, the driver was never compiled in. Stop suspecting the device tree.

**The vendor GPL drop is required reading, not optional reference.** Locations:

```
GPL_MCH_Monarch_9.9.0-102_20251211/                        # U-Boot source
GPL_MCH_Monarch_9.7.0-104_20241205/kernel/linux-4.9.330/   # 4.9 kernel tree
```

Every time a register's semantics could not be guessed — the thermal sampling sequence, the Type-C lane switch, the write-1-to-clear contract of ISO_ISR, the width of the spin-table write — the answer was in a vendor driver, and usually in only a few dozen lines.

---

## 1. The boot chain: unrelated to kernel features, but it decides whether you get a single character out

This is where a port like this most often dies, because the failure mode is **total silence** — no panic, no earlycon, no output whatsoever.

### 1.1 Storage layout

The device has one SATA disk with 21 partitions. All three firmware slots share a single firmware table:

| Purpose | Partition | Start LBA | Sectors |
|---|---|---:|---:|
| FW_TABLE | sda1 | `0x22` | `0x10` (8192 B) |
| **FDT_B** | sda6 | `0x31000` | `0x38` (28672 B) |
| **KERNEL_B** | sda8 | `0x33800` | size-dependent (`0x7ee8` for 6.18.40 r2) |

The mainline kernel **only ever writes these three**. Slot A (sda2/5/3) and the GOLD slot (sda16/10/9) are never touched — see §1.6; this is a hard safety boundary, not caution.

### 1.2 fw_table structure (sda1, exactly 8192 bytes)

```
offset    content
0x00      magic "VERONA__"
0x08      u16 header checksum  <- algorithm: sum(fw[0x0A:]) & 0xFFFF (skips magic and itself)
0x18      u32 part_list_len = 0xC0 (192)
0x1C      u32 fw_list_len   = 0x1A0 (416 = 13 * 32)
0x20      partition table, 192 bytes
0xE0      13 firmware descriptors, 32 bytes each
```

**The entry stride is 32 bytes.** An early note recorded it as 0xC0; that was an artifact of sampling every sixth entry.

Field offsets within one entry, as used by the packaging script:

```
+0    u8  type (FW_TYPE)
+1    u8  flags (0x80)
+8    u32 load address >> 16
+14   u32 actual byte count
+18   u32 allocated byte count
+22   u32 additive checksum of the content  <- sum(bytes) & 0xFFFFFFFF over the padded artifact
```

FW_TYPE decides which slot an entry belongs to:

| Slot | FW_TYPE |
|---|---|
| A (`BOOT_NORMAL_MODE`) | KERNEL=2, KERNEL_DT=4, KERNEL_ROOTFS=6, AFW=7 |
| **B (`BOOT_RESCUE_MODE`, where the mainline kernel lives)** | **RESCUE_KERNEL=43, RESCUE_DT=3**, RESCUE_ROOTFS=5, RESCUE_AUDIO=44 |
| GOLD (`BOOT_GOLD_MODE`) | 31–34 |

When booting slot B, U-Boot **reads and verifies only the B entries**; A and GOLD entries fall through `default: continue` and their partition contents are never read. That source-level fact is useful: the A and GOLD partitions can be repurposed as long as the descriptor bytes in sda1 stay self-consistent (one header checksum covers the whole table).

Packaging therefore patches exactly two entries: file offset **0x1A0** (RESCUE_DT, type `0x03`) and **0x260** (RESCUE_KERNEL, type `0x2B` = 43), fields `+14/+18/+22`, then recomputes the header checksum. A and GOLD entries are preserved byte for byte.

### 1.3 The ARM64 Image header patch, or: why the machine went completely silent

**Symptom**: after flashing, nothing at all — not even earlycon. The device looks bricked.

**Root cause**: a 6.18 PIE/relocatable kernel ships `text_offset = 0` in its Image header. The second-stage bootloader here is U-Boot 2015.07, whose `booti` copies the Image **literally** to `DRAM_BASE + text_offset` = `0x00000000` — squarely on top of U-Boot itself and the exception vector table. The CPU dies before decompression, so not one character escapes.

**Fix**: binary-patch three header fields (automated in the packaging script):

```python
struct.pack_into("<I", kernel,  0, 0x91005A4D)   # code0: a valid AArch64 instruction, MZ-compatible
struct.pack_into("<Q", kernel,  8, 0x200000)     # text_offset = 0x200000
struct.pack_into("<I", kernel, 60, 0x40)         # pe_offset = 0x40
```

Validate the arm64 magic `0x644D5241` ("ARM\x64") at offset 56 before patching, so you cannot silently corrupt the wrong file.

### 1.4 Size limit, and why the image is uncompressed

The second-stage U-Boot's `CONFIG_SYS_BOOTM_LEN` caps decompression at about 20 MB, while 6.18 decompresses to roughly 22 MB → `inflate() returned -5`. Two responses:

- `CONFIG_CC_OPTIMIZE_FOR_SIZE=y` plus disabling debug options to shrink the image;
- **ship a raw, uncompressed Image** — this second-stage U-Boot was trimmed down to `booti`/`fdt` and has no `unzip` command at all.

### 1.5 Two device-tree traps

**Trap one: `FDT_ERR_NOSPACE`.** U-Boot inserts a `/factory` node (serial number, MAC, IP) into the DTB at runtime. Compile with headroom: `dtc -p 16384`.

**Trap two: padding is not the same as usable space** (only fixed correctly in r2). Padding the DTB out to `0x7000` bytes merely makes the file longer. U-Boot/libfdt decides how much room it has from the **big-endian `totalsize` field in the FDT header (offset 4)**, not from the file length. So after padding, `totalsize` must be rewritten to `0x7000` as well before the padding becomes usable runtime FDT space. Verify by round-tripping through `dtc -I dtb -O dts`.

### 1.6 Write rules and slot selection

`sata write` writes whole 512-byte sectors, and any surplus sector carries leftover RAM garbage that breaks the additive checksum. The rule: **zero-pad on the host, and the sector count must be exactly padded_bytes / 512**. The kernel is padded to a 4096-byte boundary.

The write order is always **DTB → kernel → fw_table last**. The fw_table is the commit point: if anything fails before it, the on-disk state is still the self-consistent previous configuration, and a plain power cycle boots the old kernel as before.

Slot selection comes from a 16-byte `bootConfig` file on the FAT32 partition sda18, formatted `<bootState>:<nbr>:<bna>:;`, normally `0:F:0:;`.

| bootState | Behaviour |
|---|---|
| 0 NO_OTA | Boot the slot named by `cbr` in the U-Boot environment |
| 1 INIT | Set `cbr=A` and boot A |
| 2 OTA_TRIGGERED | Boot `nbr` (requires 1 ≤ `bna` ≤ 5) |
| 3 OTA_PASSED | Commit `nbr` as `cbr` |
| 4 OTA_FAILED | Fall back to `cbr` |
| **5 RECOVERY** | **Boot GOLD** |

Two facts you must internalise:

1. **U-Boot never decrements `bna` (confirmed in the source: there is no write-back), so there is no automatic rollback.** The selected slot keeps booting until `bootConfig` is changed again. Never rely on "a bad kernel will roll itself back".
2. **GOLD is not a rescue environment; it is a factory reset appliance.** Its rootfs is an Android 6.0.1 recovery whose `init.rc` starts `do_reset.sh` **unconditionally** via a hardcoded `ro.debuggable=1` property trigger. That script hardcodes the *factory* partition numbers and runs `mke2fs -E discard`. On a repartitioned disk this destroys the user data partition, and because `-E discard` issues a full TRIM to the SSD the data is unrecoverable at the flash level the instant it runs. This project hit exactly that on 2026-07-27. **Never boot GOLD.** The good news: Realtek's original "fall back to GOLD when boot fails" logic is disabled by WD inside `#if 0` (comment KAM-8762), so every failure path goes USB rescue → DHCP rescue → serial console and never lands in GOLD on its own.

Manual boot from the second-stage `Realtek>` prompt:

```
booti 0x03000000 - 0x01f00000
```

To interrupt the second-stage autoboot, run `env set bootdelay 5` **before** `bootr`; otherwise the window is too short. TFTP load address is uniformly `0x04000000`.
---

## 2. Symptom → root cause → fix, in the order they were hit

This section doubles as a troubleshooting index. Every entry was confirmed on real hardware, not reasoned about in the abstract.

### 2.1 Boot chain (April 2026)

**① Total silence, not even earlycon**
PIE kernel with `text_offset=0`; U-Boot 2015.07 `booti` copies it to address 0 and overwrites itself. → Binary-patch the Image header (§1.3).

**② `inflate() returned -5`**
`CONFIG_SYS_BOOTM_LEN` ≈ 20 MB < the 22 MB decompressed size. → Shrink the image and ship it uncompressed (§1.4).

**③ `bootargs` in the DTB has no effect**
`CONFIG_CMDLINE_FROM_BOOTLOADER=y` is the default, so U-Boot's empty/incorrect bootargs win. → `CONFIG_CMDLINE_FORCE=y`, with `earlycon=uart8250,mmio32,0x98007800 console=ttyS0,115200 panic=5` baked into `CONFIG_CMDLINE`.
⚠️ Latent hazard: the board DTS still says `root=/dev/sda9 rootfstype=ext4` (sda9 is actually a gzip+cpio stream, not ext4). It is only harmless because `CMDLINE_FORCE` overrides it. Remove FORCE some day and this bites.

**④ AHCI probe fails with `-EBUSY: can't request region [mem 0x9803f000-...]`**
The vendor DTS `rsvmem-remap` node `rbus@98000000` reserves `0x98000000–0x981fffff`, swallowing the SATA controller's MMIO. → Delete **all** `rsvmem-remap` nodes from the board DTS.

**⑤ 32-bit vendor userspace binaries fail with `Exec format error`**
→ `CONFIG_COMPAT=y`.

**⑥ `init: required argument missing.` then a drop to BusyBox**
Debian's `/sbin/init` is systemd (usr-merge), and systemd in system mode **requires being PID 1**; `chroot` does not replace PID 1.
Corroboration: the vendor's own Debian package uses `exec switch_root /mnt /sbin/init` in its early userspace — switch_root was always the intended path.
→ The Debian/mdraid branch of the initramfs now uses `exec /bin/busybox switch_root -c /dev/console "$root" "$init"`, plus a `cleanup_newroot()` helper (which also fixed `mounting sysfs on /newroot/sys failed: -EBUSY` on retries).
⚠️ The vendor gzip+cpio rescue branch **deliberately keeps `chroot`**: on that path the vendor init exiting as PID 1 would panic the kernel.
⚠️ BusyBox's own `switch_root` also demands that the caller be PID 1, so the initramfs must stay PID 1.

### 2.2 Feature completion (July 2026)

**⑦ SMP hard-hangs before secondary CPUs come up (no panic, no output)**
Mainline `smp_spin_table.c` maps the release address with `ioremap_cache`, writes it with a 64-bit `writeq`, and performs dcache maintenance. But `0x9801AA44` is a **device register**, not RAM, and that access pattern locks up the interconnect. The vendor's `rtd129x_spin_table.c` uses plain `ioremap` with a 32-bit `writel_relaxed`.
→ See the `smp_spin_table.c` patch in §4.1. Worked on the first attempt; four cores came up.

**⑧ switch_root succeeds but systemd freezes: `Failed to mount cgroup v1 hierarchy`**
The size-trimmed config had dropped CGROUPS, SYSVIPC, POSIX_MQUEUE, TMPFS_POSIX_ACL and AUTOFS_FS. → The `rtd1295_systemd.config` fragment. With it, 34 s to `graphical.target`.

**⑨ Wiring uart0 to the IRQ mux kills the console entirely (no ttyS0 → init dies)**
`irq-rtd129x.c` was in the tree with a Makefile entry, but its Kconfig prompt was gated behind `if COMPILE_TEST`, so `CONFIG_IRQ_RTD129X_MUX` never existed in `.config`, the driver was never linked, and uart0's `interrupt-parent` pointed at an irqchip that would never bind — fw_devlink deferred forever.
(The console had worked earlier only because the DTB omitted `interrupts`, so dw8250 reported ENXIO and fell back to polling.)
→ Remove the COMPILE_TEST gate; `CONFIG_IRQ_RTD129X_MUX=y`.

**⑩ Once ttyS0 has a real IRQ, a self-sustaining log storm appears (607 lines in 150 s)**
Two layers:
- mainline's 8250 never acks the ISO mux status register (the vendor did this from a forked 8250 driver via `interrupts-st-mask`);
- the mux handler's own `pr_err` writes to the console **riding the very UART being muxed** → each printed line raises a TX interrupt → re-enter the handler → print again. Self-feeding.

There was also a **methodological trap** worth remembering. ISO_ISR bit 2 appeared to be "stuck at 1, cannot be cleared", which looked like broken hardware. It was a measurement artifact: each `devmem` probe command travelled over the same serial port, and its own traffic re-latched the bit that had just been cleared. Clearing and reading **in a single command line with no traffic in between** returned 0 — write-1-to-clear works exactly as documented (the register contract is in the vendor's `rtk_iso.h`: `BIT(n)|0` clears, `BIT(n)|1` sets).
→ See §4.2: ack (W1C) before dispatch, delete every printk from the hot path, and delete the vendor's dead "force clear" tail.
**Lesson: never printk inside the interrupt handler of the bus your console sits on.**

**⑪ Debian boots but there is no login prompt**
The image ships `/etc/systemd/system/serial-getty@ttyS0.service -> /dev/null` (masked when the image was built). → `apply_rootfs_fixups()` in the initramfs removes the mask before switch_root; systemd's getty generator then instantiates it.

**⑫ The ethernet driver cannot even be selected in menuconfig**
`NET_VENDOR_REALTEK depends on PCI || (PARPORT && X86)` — this SoC has no PCI. → Add `|| ARCH_REALTEK`. (Third member of the "ported but unselectable" family.)

**⑬ Ethernet probe oopses, then panics**
Two bare `clk_get` calls were missed during the April adaptation; the returned `ERR_PTR` flowed into `__clk_is_enabled`. RTD129x has no mainline clock driver, so clocks depend on the gates the bootloader leaves open. → Replace with an `rtl_clk_get_optional` helper that returns NULL, which routes the driver to its direct-register bring-up path. Afterwards eth0 reads its factory MAC from hardware and negotiates gigabit.
(Known harmless noise: two `rtl_csiar_cond` timeout warnings.)

**⑭ USB: a bare `snps,dwc3` node reports `-EBUSY` with an inverted resource range**
Mainline dwc3 hardcodes the globals block at 0xc100; on the RTD1295 it is **0x8100** (the vendor's `fixed_dwc3_globals_regs_start`).
→ The fix is not a patch: give the parent node the compatible **`realtek,rtd-dwc3`**, which triggers the RTD globals-offset quirk already present in mainline. (dwc3-rtk glue and phy-rtk-usb2/usb3 are all already in-tree.)

**⑮ dwc3 probe reads garbage from GSNPSID**
`clk_en_usb` (CRT 0x0c bit 4) is **left closed by the bootloader**, and the initramfs poke that opened it ran later than probe. Diagnosed by rebinding the driver at runtime (xHCI registered the instant the gate opened). → dwc3-rtk probe opens the gate itself on rtd1295 (a quirk until a clock driver exists).

**⑯ Root hubs come up but no device ever enumerates**
The physical USB-A port hangs off the **DRD block** (the vendor ran an adb gadget with a software role switch; the u2host/u3host ports are unpopulated pads). → Enable DRD in host mode in the DTS (wrapper @13200, core @20000, GIC SPI 21, both PHYs); VBUS is raised by the initramfs via misc-gpio19. A 4 TB disk enumerated in 9 s.

**⑰ The link only reaches High-Speed (38 MB/s)**
The Type-C lane switch register **0x9801334c resets to "disconnected"**, even though the physical port is a fixed Type-A. → Set bit 29 (enable) and clear bits 28:27 (CC1 direction); the drive jumps onto the 5 Gbps bus immediately, measured 137 MB/s (the drive's own mechanical limit). Recipe from the vendor's `rtk_usb_rtd129x.c`: `TYPE_C_EN_SWITCH BIT(29)`, `TYPE_C_TxRX_sel BIT(28)|BIT(27)`.

**⑱ Thermal sensor**
The sensor lives at **scpu_wrapper 0x9801d000 + 0x150**. The first guess, CRT+0x150, read back `0xDEADBEEF` — RBUS's signature response for an invalid region, which makes a **reliable "wrong address" signal** while probing.
Protocol: write `0x01904001` then `0x01924001` to CTRL2 (0x9801d158) to arm; read STATUS1 (0x9801d168) and interpret it as an **18-bit signed value × 1000 / 1024 = m°C**. The vendor driver is 83 lines. → A new ~100-line `drivers/thermal/rtd129x_thermal.c`.

**⑲ `reboot` halts the machine instead of restarting it**
This firmware has no PSCI, so the watchdog is the only reset channel. → Add `.restart` to `rtd119x_wdt` (1 ms timeout, enable, spin; priority 192). `systemctl reboot` measured at 34 s down-to-up.
⚠️ Trap: sending `reboot` through `nohup` in the background gets swallowed by sshd session cleanup (initially misread as "the command did nothing"). Issue it synchronously.

**⑳ RTC probes but does not tick (shelved)**
Adding `rtc@600` (ISO block) to the DTS makes rtc-rtd119x probe successfully and `/dev/rtc0` appear, but the epoch stays frozen — the vendor's enable sequence (ISO_RTC ctrl / RTCEN magic values, in the vendor rtk-rtc driver) is missing. Deliberately shelved: NTP covers timekeeping and a smart plug covers power cycling. To fix it, copy the enable bits from the GPL package's rtc driver.

### 2.3 The 6.18.40 upgrade (2026-07-28)

**㉑ A kernel built from a fresh checkout drops into network rescue, with `grep: not found` scrolling past**
**Git cannot track empty directories.** The seven empty mount-point directories in the initramfs source (`dev/ proc/ sys/ tmp/ usr/bin/ usr/sbin/`) had never been committed, so a fresh worktree checkout simply lacked them → `mount -t proc proc /proc` failed → **BusyBox's standalone shell locates its own binary through `/proc/self/exe` to dispatch built-in applets**, so with `/proc` missing, `grep`, `sed` and `tr` were all "not found" → the rescue script could not even read back its own IP address, concluded DHCP had failed, and moved itself to a fallback address off the local subnet.
→ Add `.gitkeep` placeholders so checkouts carry the directories, **and** make `init` create its own mount points (`mkdir -p /proc /sys /tmp /newroot /run`) so a stripped checkout can never reproduce this.
**Lesson: any build input that depends on a directory skeleton needs a fallback for the skeleton not being there.**

---

## 3. Network rescue: making the serial cable optional

The most expensive part of this port was not writing code — it was needing a serial cable for every single verification cycle. So network rescue is built into the initramfs.

**Triggers** (both one-shot):

- automatic, when every root filesystem handoff path has failed;
- manual, when `mch-boot rescue` drops a `netrescue` marker on sda18, which the initramfs **consumes and immediately deletes**. The one-shot behaviour is deliberate: a rescue mode must never be able to trap the machine.

**Actions**: mount devpts → write `/etc/passwd` → `udhcpc` (falling back to 192.168.1.222/24) → `mdadm --assemble --scan` → start telnetd and ftpd, keeping the serial shell as well. Telnet is available about 20 s after reboot.

**Four iterations, every bug found on hardware**:

1. The telnet port opened but the first connection died instantly → `/dev/pts` was missing (devpts not mounted). BusyBox telnetd exits when it cannot allocate a pty. The vendor's rescue init has exactly those two lines; they had been overlooked.
2. Connections worked but `/dev/md1` did not exist → repairing the root filesystem is the whole point of rescue, so `mdadm --assemble --scan` was added.
3. Verified end to end: telnet in, `mount /dev/md1 /mnt`, edit `/etc/fstab`, clean unmount.
4. Added IPv6 addresses to the rescue banner.

⚠️ Security: this is **unauthenticated root telnet**. It belongs on a trusted LAN only. It is debug infrastructure, not a product feature.
---

## 4. Per-file account of the source changes

Baseline: **unmodified Linux 6.18.40** from kernel.org. This tree differs in 42 files — 22 modified, 20 new — totalling 12,994 diff lines, of which `r8169soc.c` alone accounts for 8,906.

Vendor baseline for comparison: `GPL_MCH_Monarch_9.7.0-104_20241205/kernel/linux-4.9.330/`. For files carried over from the vendor tree, a second line count is given against the vendor original, to show how much actually had to change during the move.

The script that reproduces these diffs is `porting-guide-material/make-diffs.sh` on the build server.

### 4.0 Overview

| File | State | vs mainline | vs vendor | Summary |
|---|---|---:|---:|---|
| `arch/arm64/Kconfig.platforms` | mod | 18 | — | Adds the `ARCH_RTD129x` sub-family symbol |
| `arch/arm64/kernel/smp_spin_table.c` | mod | 42 | — | Use a 32-bit device write when the release address is MMIO |
| `arch/arm64/boot/dts/realtek/Makefile` | mod | 10 | — | Register the board dtb |
| `arch/arm64/boot/dts/realtek/rtd129x.dtsi` | mod | 10 | — | Drop `reg` from the rbus node |
| `arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dts` | **new** | 514 | — | Board device tree |
| `drivers/irqchip/irq-rtd129x.{c,h}` | **new** | 303+127 | 141 / 0 | Vendor IRQ mux, plus ack-first and printk removal |
| `drivers/irqchip/{Kconfig,Makefile}` | mod | 16+7 | — | Remove the `COMPILE_TEST` gate |
| `drivers/net/ethernet/realtek/r8169soc.c` | **new** | 8,903 | 450 | Vendor platform r8169, carried over near-verbatim |
| `drivers/net/ethernet/realtek/{Kconfig,Makefile}` | mod | 32+7 | — | `NET_VENDOR_REALTEK` gains `\|\| ARCH_REALTEK` |
| `drivers/usb/dwc3/dwc3-rtk.c` | mod | 40 | — | Open clk_en_usb, pin the Type-C lane switch |
| `drivers/watchdog/rtd119x_wdt.c` | mod | 43 | — | Add `.restart` (the only reset channel on this board) |
| `drivers/thermal/rtd129x_thermal.c` | **new** | 79 | 144 | Rewritten thermal sensor driver |
| `drivers/thermal/{Kconfig,Makefile}` | mod | 14+7 | — | New symbol |
| `drivers/soc/realtek/rtk-memory-remap.c` | **new** | 100 | 313 | `rsvmem-remap` reserved-memory semantics |
| `drivers/soc/realtek/{Kconfig,Makefile}`, `drivers/soc/{Kconfig,Makefile}` | new/mod | ~10 each | — | Hook up the realtek subdirectory |
| `include/linux/soc/realtek/rtk_rsvmem.h` | **new** | 11 | no counterpart | API header written for this port |
| `include/soc/realtek/rtk_chip.h` | **new** | 47 | 39 | Chip identification |
| `drivers/i2c/busses/i2c-rtk.c` + Kconfig/Makefile | **new**/mod | 983 | 211 | Vendor I2C (built as a module, never loaded — see §4.9) |
| `drivers/mfd/g2227-i2c.c`, `g22xx-core.c` + 2 headers | **new** | 133+43+224 | 26 / 0 / 0 | GMT G2227 PMIC |
| `drivers/regulator/g2227-regulator.c`, `g22xx-regulator-core.c`, header | **new** | 196+342+71 | 0 / 72 / 0 | PMIC regulators |
| `drivers/phy/realtek/phy-rtk-sata.c` + Kconfig/Makefile | **new**/mod | 431 | 809 | SATA PHY (`=y`, the boot disk depends on it) |

**No mainline file was deleted, and the only core-kernel change is the one hunk in `smp_spin_table.c`.**

---

### 4.1 `arch/arm64/kernel/smp_spin_table.c` — the only core-kernel change

**Why it was needed**: the vendor uses a private `enable-method = "rtk-spin-table"` that mainline does not recognise. Switching to mainline's `"spin-table"` while keeping the vendor's release address `0x9801aa44` made the kernel **hard-hang** before waking the secondary CPUs — no panic, no output.

The cause is how mainline accesses that address: `ioremap_cache` (a cacheable mapping), a 64-bit `writeq`, and dcache maintenance. But `0x9801AA44` is not RAM — it is a **32-bit device register** inside a SoC block. Driving it that way locks up the interconnect.

The vendor's `rtd129x_spin_table.c` uses plain `ioremap` with a 32-bit `writel_relaxed`.

**The change** — a generic condition rather than a board `#ifdef`:

```c
+#include <linux/memblock.h>
...
+	/*
+	 * RTD1295 quirk: the release address (0x9801AA44) is an MMIO
+	 * register in the SoC block, not RAM. ioremap_cache() + a 64-bit
+	 * write + cache maintenance on that region hard-hangs the
+	 * interconnect ... vendor 4.9 uses a plain device mapping with a
+	 * 32-bit write - the register is 32 bits wide and with 1 GiB of
+	 * RAM the pen address always fits.
+	 */
+	if (!memblock_is_map_memory(cpu_release_addr[cpu])) {
+		void __iomem *rel32 = ioremap(cpu_release_addr[cpu], sizeof(u32));
+		if (!rel32)
+			return -ENOMEM;
+		writel_relaxed((u32)pa_holding_pen, rel32);
+		dsb(sy);
+		sev();
+		iounmap(rel32);
+		return 0;
+	}
```

`memblock_is_map_memory()` answers "is this address normal memory?". If not, take the device-register path; if so, take the original mainline path. Boards whose release address really is in RAM behave exactly as before.

**Scope**: this covers **cold boot only** (write the pen address, then `sev()`), which is where the vendor protocol is already close to mainline. CPU hotplug would need the vendor's whole `rtk_cpu_power_up`/SMC machinery, which this port does not implement.

---

### 4.2 `drivers/irqchip/irq-rtd129x.{c,h}` — the vendor IRQ mux

Many peripheral interrupts on this SoC, uart0 among them, do not reach the GIC directly; they pass through a private second-level multiplexer, `Realtek,rtk-irq-mux`. **Mainline 6.18.40 has no driver for it**, so this file was carried over from the vendor tree: 341 vendor lines → 303 here, 141 diff lines; the header is byte-identical to the vendor's.

Two substantive changes were made during the move.

**① Ack the status bit (W1C) before dispatching.** The vendor did this from its forked 8250 driver through an `interrupts-st-mask` property. Mainline peripheral drivers know nothing about that register, so the mux itself must ack:

```c
+			/* Ack the mux status bit before dispatching. The
+			 * ISR latches peripheral interrupt edges (verified
+			 * on ISO_ISR bit2/UR0 by devmem: write-1-to-clear
+			 * with bit0 = WRITE_DATA per rtk_iso.h, stays clear
+			 * while the line is quiet). The vendor tree acked
+			 * from its forked 8250 driver via interrupts-st-mask;
+			 * mainline peripheral drivers know nothing about
+			 * this register, so the mux must ack here.
+			 */
+			spin_lock(&irq_mux_lock);
+			__raw_writel(BIT(i), mux_data->base + reg_st);
+			spin_unlock(&irq_mux_lock);
```

**② Every `printk` removed from the hot path.** The vendor code calls `pr_err` when it cannot find an irq desc. But the console rides the very UART being muxed: print one line → TX interrupt → re-enter the handler → print again. Measured at 607 lines in 150 s. The vendor's "force clear" tail (including dead code for `irq == 1`) was deleted along with it:

```c
+			/* NEVER printk in this handler: the console may
+			 * ride a muxed uart, so a print here generates a
+			 * fresh uart interrupt event and the handler
+			 * re-enters forever (the v29/v30 log storm). Any
+			 * event without a consumer (e.g. latched before the
+			 * peripheral driver probed) was already acked above -
+			 * drop it silently.
+			 */
```

**On the Kconfig side**: the driver file and its Makefile entry were already present, but the prompt was gated behind `if COMPILE_TEST`, so `CONFIG_IRQ_RTD129X_MUX` did not exist in `.config` and the driver was never linked. Removing that gate is the precondition for any of this working.

---

### 4.3 `drivers/net/ethernet/realtek/r8169soc.c` — ethernet

Mainline has no RTD1295 GMAC driver. The vendor's `r8169soc.c` is a platform variant of r8169 (8,897 lines). This tree has 8,903 lines and differs from the vendor original by **only 450 lines** — a near-verbatim carry-over.

The differences fall into four categories, all 4.9 → 6.18 API migration:

| Category | Occurrences | Notes |
|---|---:|---|
| `rtl_clk_get_optional` replacing bare `clk_get` | 23 | see below |
| `ethtool_link_ksettings` family | 4 | the old `ethtool_cmd` interface was removed |
| `netif_napi_add` signature | 1 | the weight argument is gone in 6.x |
| `eth_hw_addr` / MAC assignment | 1 | `dev->dev_addr` became read-only |

**Clocks are the important one.** RTD129x has **no mainline clock driver**; the clock gates are whatever state the bootloader left them in. Vendor code calls `clk_get` everywhere, and on mainline those calls return `ERR_PTR`. The moment one reaches `__clk_is_enabled`, it oopses and panics — which is exactly what happened in v35, where two bare `clk_get` calls had been missed during the April adaptation.

All of them now funnel through an `rtl_clk_get_optional` helper that returns **NULL** rather than an ERR_PTR when no clock is available, which routes the driver into its direct-register bring-up path. Consolidating all 23 call sites onto one helper is what makes "we did not miss any" checkable.

**The Kconfig gate**: `NET_VENDOR_REALTEK depends on PCI || (PARPORT && X86)`. This SoC has no PCI, so the entire Realtek networking submenu was unreachable and `R8169SOC` could never be selected. Adding `|| ARCH_REALTEK` fixes it. The gmac node's compatible in the DTS is `"Realtek,r8168"`.

Known harmless noise: `rtl_csiar_cond` logs two timeout warnings. It is inherent to this vendor driver on this SoC and does not affect operation.

---

### 4.4 `drivers/usb/dwc3/dwc3-rtk.c` — USB

**Mainline already has the whole family**: the `dwc3-rtk` glue, `phy-rtk-usb2` and `phy-rtk-usb3` (both carrying rtd1295 compatibles), and the RTD globals-offset quirk inside dwc3 core. USB work here was therefore **device-tree configuration plus two leftover bootloader states**, not driver writing.

Three problems and their conclusions:

1. A bare `snps,dwc3` node reports `-EBUSY` with an inverted resource range — mainline dwc3 hardcodes globals at 0xc100, the RTD1295 has them at **0x8100**. **The fix is not a patch**: give the parent node the compatible `realtek,rtd-dwc3` to trigger the built-in quirk.
2. With the wrapper structure correct, probe still read garbage from GSNPSID — `clk_en_usb` (CRT `0x9800000c` bit 4) is **closed by bootloader default**.
3. The link only reached High-Speed — the Type-C lane switch (`0x9801334c`) **resets to "disconnected"**, despite the port being a fixed Type-A.

The last two are handled once, idempotently, in probe:

```c
+	/* RTD1295: no mainline clock driver exists for the CRT gates and the
+	 * bootloader leaves clk_en_usb (CRT 0x0c bit 4) closed, so every dwc3
+	 * register read returns garbage. Open the gate here. */
+	if (of_device_is_compatible(dev->of_node, "realtek,rtd1295-dwc3")) {
+		void __iomem *clk_en1 = ioremap(0x9800000c, 0x4);
+		void __iomem *typec_cc1 = ioremap(0x9801334c, 0x4);
+		if (clk_en1) {
+			writel(readl(clk_en1) | BIT(4), clk_en1);
+			iounmap(clk_en1);
+		}
+		/* Pin type-C lane switch to CC1 (fixed type-A port); without
+		 * this the port links at High-Speed only. */
+		if (typec_cc1) {
+			u32 v = readl(typec_cc1);
+			v &= ~(BIT(29) | BIT(28) | BIT(27));
+			v |= BIT(29);
+			writel(v, typec_cc1);
+			iounmap(typec_cc1);
+		}
+	}
```

Register recipe from the vendor's `rtk_usb_rtd129x.c`: `TYPE_C_EN_SWITCH BIT(29)` and `TYPE_C_TxRX_sel BIT(28)|BIT(27)`.

**Both of these are explicitly temporary quirks.** The proper fix is a real RTD129x clock driver, after which `clk_en_usb` should be owned by the clock framework.

Separately, the physical USB-A port is on the **DRD block** (the vendor ran an adb gadget with a software role switch; u2host/u3host are unpopulated pads), so the DTS enables DRD in host mode, and the initramfs raises VBUS through misc-gpio19.

---

### 4.5 `drivers/watchdog/rtd119x_wdt.c` — soft reboot

Mainline already has `rtd119x_wdt` (it covers RTD129x), but without a `.restart` implementation. This firmware has **no PSCI**, so `reboot` merely halts the machine. The watchdog is the only usable SoC reset:

```c
+static int rtd119x_wdt_restart(struct watchdog_device *wdev,
+			       unsigned long action, void *data_)
+{
+	struct rtd119x_watchdog_device *data = watchdog_get_drvdata(wdev);
+	/* Overflow after ~1 ms: TCWOV counts clock cycles (27 MHz osc). */
+	writel(clk_get_rate(data->clk) / 1000, data->base + RTD119X_TCWOV);
+	writel_relaxed(RTD119X_TCWTR_WDCLR, data->base + RTD119X_TCWTR);
+	rtd119x_wdt_start(wdev);
+	while (1)
+		cpu_relax();
+	return 0;
+}
...
+	.restart	= rtd119x_wdt_restart,
...
+	/* No PSCI SYSTEM_RESET on this firmware; the watchdog is the only
+	 * working SoC reset. High priority so it wins over any default. */
+	watchdog_set_restart_priority(&data->wdt_dev, 192);
```

Priority 192 ensures it beats any default restart handler. Measured: `systemctl reboot` takes 34 s from down to back up.

---

### 4.6 `drivers/thermal/rtd129x_thermal.c` — thermal sensor (new)

The vendor driver is 83 lines and this one is 79, but it is **essentially a rewrite** (144 diff lines against the vendor), because the 6.x thermal_of framework bears no resemblance to 4.9's. Only two things matter:

- **Arm sequence**: write `0x01904001` then `0x01924001` to CTRL2 (base + 0x08);
- **Reading**: take the low 18 bits of STATUS1 (base + 0x18), **sign-extend, then × 1000 / 1024 to get m°C**.

```c
static int rtd129x_thermal_get_temp(struct thermal_zone_device *tz, int *temp)
{
	struct rtd129x_thermal *priv = thermal_zone_device_priv(tz);
	u32 val;

	val = readl_relaxed(priv->base + TM_SENSOR_STATUS1) & GENMASK(17, 0);
	*temp = sign_extend32(val, 17) * 1000 / 1024;

	return 0;
}
```

Registration uses `devm_thermal_of_zone_register()`; the DTS provides a `thermal-sensor@1d150` node and a root-level `thermal-zones` with a 105 °C critical trip.

**A note on finding the address**: the sensor is at `scpu_wrapper 0x9801d000 + 0x150`. The first guess of CRT+0x150 read back `0xDEADBEEF` — RBUS's signature response for an invalid region, which makes a **reliable "you have the wrong address" signal** during exploration.

---

### 4.7 `drivers/soc/realtek/rtk-memory-remap.c` — reserved-memory semantics

The vendor RTD129x trees use a non-upstream reserved-memory binding:

```dts
compatible = "rsvmem-remap";
save_remap_name = "rbus" | "common" | "ringbuf";
```

Mainline does not know it. This file (100 lines; the vendor original is 245, with 313 diff lines — a heavy rewrite) keeps those semantics working. Its header comment states what it is:

> This is *not* an upstream binding. It's here to keep the vendor DTS semantics working while porting WD My Cloud Home (RTD1295) to 6.x.

⚠️ A **major related trap**: the vendor DTS `rsvmem-remap` node `rbus@98000000` claims `0x98000000–0x981fffff`, which swallows the SATA controller's MMIO and makes AHCI probe fail with `-EBUSY`. The board DTS must delete **all** `rsvmem-remap` nodes. Keeping the driver is about staying compatible with the binding, not about using it on this board.

The companion `include/linux/soc/realtek/rtk_rsvmem.h` (11 lines) was **written for this port**; there is no vendor counterpart.

---

### 4.8 Device tree

**`arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dts` (new, 514 lines)**

Mainline does **not** have this board (its rtd1295 board files are ~35-line stubs with a memory node and uart enables). This file derives from a third-party Debian device tree published on a Russian forum, was ported from 4.9.330, and is self-contained on top of mainline's `rtd1295.dtsi`.

Node inventory, by line:

```
28  memory@0 (1 GiB)          45  reserved-memory (linux,cma / ramoops@22000000)
81  mux_intc: interrupt-controller@1b000  ("Realtek,rtk-irq-mux")
114 i2c0..i2c5 ("realtek,rtk-i2c")        124 pmic@12 (gmt,g2227) + dc1..dc6/ldo2/ldo3
205 sata_phy@3ff00                        219 sata@3f000 (AHCI)
256 usb2phy_u2/u3, usb3phy_u3             281 usb2phy_drd/usb3phy_drd
275 soc_thermal: thermal-sensor@1d150
293/320/347 usb wrappers + dwc3 children usb@20000/29000/1f0000
371 gmac: ethernet@16000 ("Realtek,r8168")
393 &uart0/1/2                            417 &cpu0..&cpu3 (spin-table release addresses)
489 thermal-zones (soc-crit 105 C)        507 &iso { rtc@600 }
```

**`arch/arm64/boot/dts/realtek/rtd129x.dtsi` (modified, one substantive line)**

```diff
 		rbus: bus@98000000 {
 			compatible = "simple-bus";
-			reg = <0x98000000 0x200000>;
 			#address-cells = <1>;
 			#size-cells = <1>;
 			ranges = <0x0 0x98000000 0x200000>;
```

Removing `reg` matters because a `simple-bus` node carrying `reg` registers the whole 2 MiB window as a claimed resource, so child devices underneath it (SATA among them) hit `-EBUSY` when requesting their own MMIO. `ranges` alone is sufficient for address translation.

**Vendor reference DTS**: `.../rtd129x/rtd-1295-monarch-1GB.dts` (318 lines, including `rtd-1295-giraffe-common.dtsi`). It is structured as a delta on a shared giraffe dtsi, whereas ours is self-contained on mainline's dtsi, so a direct textual diff between the two is of limited value — the port proceeded hardware block by hardware block, not by text comparison.

---

### 4.9 Ported but never loaded: I2C, PMIC, regulators

This group deserves its own section, because the older `DRIVER_PORTING_GUIDE.md` in this repository claimed that a missing I2C driver was a severe problem that might prevent boot.

**The drivers are in fact present in the tree**:

| File | Lines | vs vendor |
|---|---:|---:|
| `drivers/i2c/busses/i2c-rtk.c` | 983 | 211 |
| `drivers/mfd/g2227-i2c.c` | 133 | 26 |
| `drivers/mfd/g22xx-core.c` | 43 | 0 (byte-identical) |
| `include/linux/mfd/g2227.h` / `g22xx.h` | 197 / 27 | 0 / 0 |
| `drivers/regulator/g2227-regulator.c` | 196 | 0 |
| `drivers/regulator/g22xx-regulator-core.c` | 342 | 72 (new regulator API) |
| `drivers/regulator/g22xx-regulator.h` | 71 | 0 |
| `include/dt-bindings/regulator/gmt,g22xx.h` | 27 | 0 |

All of them are **`=m`** in `.config` (the whole configuration has only nine `=m` symbols, essentially this group), and on the device **`/lib/modules` does not exist and zero modules are loaded**. In other words:

> **This I2C + GMT G2227 PMIC + regulator stack was ported and compiled, but never installed and never loaded. The device runs entirely on built-in drivers, and every regulator falls back to dummy.**

So the old claim is disproven in practice — but it would be equally wrong to say the drivers were never ported. The code is in the tree, the DTS instantiates `pmic@12`, and switching the symbols to `=y` and rebuilding would enable it.

**Why keep them**: they are a ready-made starting point for proper power management (dynamic voltage scaling, precise power sequencing). There is no reason to delete working ported code just because it is currently unused.

### 4.10 `drivers/phy/realtek/phy-rtk-sata.c` — do not confuse this with the group above

The SATA PHY is **`=y`, built in, and actively working** — the boot disk hangs off it:

```
phy-rtk-sata 9803ff00.sata-phy: rtk-sata-phy: init phy0 OK
```

431 lines here against a 677-line vendor original (which lived at `drivers/phy/phy-rtk-sata.c` — 4.9 had no `realtek/` subdirectory), with 809 diff lines: **heavily rewritten and slimmed**, using `devm_platform_ioremap_resource`, `devm_kcalloc`, and the modern `struct phy_ops` / `phy_provider` framework.

Incidentally, the three `supply ahci/phy/target not found, using dummy regulator` lines in the boot log are expected — they are a direct consequence of the §4.9 regulator stack not being loaded. AHCI works fine on dummy regulators.

---

## 5. Configuration fragments

The repository keeps 16 `rtd1295_*.config` fragments. **They have all been folded into the tracked `.config` and are no longer build inputs** (the build script only sets `INITRAMFS_SOURCE` in the build directory). They are kept as documentation of *why each group of options exists*:

| Fragment | Problem it solves |
|---|---|
| `rtd1295_minimal.config` / `_size.config` | Size control (the ~20 MB `CONFIG_SYS_BOOTM_LEN` ceiling, §1.4) |
| `rtd1295_cmdline.config` / `_cmdline_fix.config` | `CMDLINE_FORCE` plus a hardcoded earlycon/console (§2.1-③) |
| `rtd1295_compat32.config` | `CONFIG_COMPAT=y` for 32-bit vendor userspace |
| `rtd1295_mdraid.config` | md RAID1 (the root filesystem lives on md1) |
| `rtd1295_initramfs_fix.config` | Embedded initramfs options |
| `rtd1295_systemd.config` | cgroups family, SYSVIPC, POSIX_MQUEUE, TMPFS ACL, AUTOFS — without these systemd simply freezes (§2.2-⑧) |
| `rtd1295_irqmux.config` | `IRQ_RTD129X_MUX=y` |
| `rtd1295_ethernet.config` | `R8169SOC=y` plus `NET_VENDOR_REALTEK=y` |
| `rtd1295_usb.config` | dwc3 and phy-rtk |
| `rtd1295_thermal.config` | Thermal sensor |
| `rtd1295_docker.config` | Dual netfilter stacks (nft + legacy), **IPv6** (entirely absent from the trimmed config), veth/bridge/macvlan/vlan, cgroup-bpf, user namespaces, overlayfs, blk-throttle, CFS bandwidth |
| `rtd1295_nas.config` | NFSD v4, ext4 ACL/xattr, quotas, TUN/WireGuard, DM+crypt, FUSE, vfat/exfat/ntfs3/CIFS, zram, watchdog, RTC class |
| `CONFIG_VENDOR_RTSDK_*.config` | Vendor SDK reference for comparison |

Three specific 6.18-era gotchas: legacy iptables tables need both `IP_NF_IPTABLES_LEGACY` and `NETFILTER_XTABLES_LEGACY` (trixie's iptables defaults to the nft backend, but Docker may still reach for legacy); `VETH` depends on `NET_CORE`; `NF_TABLES_INET` depends on `IPV6`.
---

## 6. Build and packaging

The build script is `rebuild_package_and_print_flash.sh` (about 380 lines). It targets 6.18.40 by default; the release name is set with `--release`.

What it does, by stage:

**Preflight.** Requires the kernel Makefile, the tracked `.config`, `initramfs/init`, the base fw_table (which must be exactly 8192 bytes), and the release directory's README/SOURCES/docs/tools to already be in place. Backs up the source tree's `.config` (restored by an EXIT trap) and copies it into the build directory.

**[0/5] Config assembly.** `make mrproper` first (an out-of-tree build refuses to run against a source tree with leftover build products), then:

```sh
scripts/config --file build/.config --set-str INITRAMFS_SOURCE "$ROOT_DIR/initramfs"
```

⚠️ **That is the only fragment merged at this point** — the historical `rtd1295_*.config` fragments were folded into the tracked `.config` long ago. They remain in the repository to document *why each group of options exists* (§5), not as build inputs.

**[1/5]** `olddefconfig`.

**[2/5] Compile.** Out-of-tree (`O=$BUILD_DIR`) build of `Image dtbs`, with `KBUILD_BUILD_TIMESTAMP=@$SOURCE_DATE_EPOCH`, `KBUILD_BUILD_USER` and `KBUILD_BUILD_HOST` pinned for reproducibility. `SOURCE_DATE_EPOCH` defaults to the current git commit's timestamp.

**[3/5] Packaging** (embedded Python):

1. Validate the arm64 magic (offset 56 = `0x644D5241`) and the FDT magic (`0xD00DFEED`);
2. Patch the three Image header fields (§1.3);
3. Zero-pad the Image to a 4 KiB boundary;
4. Zero-pad the DTB to exactly `0x7000` **and rewrite the big-endian FDT `totalsize` to `0x7000`** (§1.5);
5. Compute additive checksums (`sum(bytes) & 0xFFFFFFFF`);
6. Write the new sizes and checksums into the base fw_table at `0x1A0+14/+18/+22` and `0x260+14/+18/+22`, then recompute the header checksum `sum(fw[0x0A:]) & 0xFFFF` back into offset 8;
7. Emit `BUILD-METADATA.json` (raw and padded byte counts, `sata_blocks = bytes/512`, additive checksums, sha256 sums, source commit).

It also generates `FLASH_COMMANDS.txt` with the computed sector counts (write order DTB → kernel → fw_table) and `SHA256SUMS`.

**[4/5] Independent verification.** Re-reads all three artifacts and asserts every fw_table field matches, the header checksum is valid, the Image is 4 KiB aligned, the DTB is exactly `0x7000` with `totalsize == file length`, and the RTD header magic is present. Finally it round-trips the padded DTB through the `dtc` that was just built.

**[5/5] Deterministic archive.** `tar --sort=name --mtime=@epoch --owner=0 --group=0 --numeric-owner`, verifies the Image path is inside the archive, and restores the source `.config`. Two independent rebuilds have been confirmed to produce byte-identical archives.

**A and GOLD entries are inherited untouched** from the base table throughout. (The serial-free USB flasher package goes further: rather than shipping a whole table, it uses a statically linked ARM64 `patch-fwtable` tool to derive the new table from the **target machine's own** on-disk table, changing only 24 bytes of slot B.)

---

## 7. 4.9 → 6.18 API migration

The API changes actually encountered while carrying vendor drivers over, ordered by how much work each caused. This is distilled from the 2,232 diff lines this tree carries against the vendor originals — it is not a generic checklist.

### 7.1 Clocks: the largest category, and the one that oopses

Vendor code assumes `clk_get()` always succeeds. RTD129x has **no clock driver on mainline**, so every `clk_get` returns `ERR_PTR(-ENOENT)`.

```c
/* vendor 4.9 idiom — a time bomb on mainline */
clk = clk_get(dev, "name");
if (__clk_is_enabled(clk))      /* ERR_PTR arrives here -> oops */
```

Funnel everything through one helper that returns **NULL** rather than an ERR_PTR when no clock is available, giving call sites a single clear meaning: NULL means "no clock framework here, use the direct-register bring-up path".

```c
static struct clk *rtl_clk_get_optional(struct device *dev, const char *id);
```

All 23 call sites in `r8169soc.c` go through it. **Lesson**: this kind of substitution has to be exhaustive. v35 panicked in probe because exactly two bare `clk_get` calls were missed, and the cost of missing one is a machine that does not boot, with a single oops line as your only evidence.

### 7.2 ethtool

`struct ethtool_cmd` and the `get_settings`/`set_settings` callbacks were removed in favour of link_ksettings:

| 4.9 | 6.18 |
|---|---|
| `struct ethtool_cmd` | `struct ethtool_link_ksettings` |
| `.get_settings` / `.set_settings` | `.get_link_ksettings` / `.set_link_ksettings` |
| Direct access to `cmd->supported` etc. | Conversion helpers such as `ethtool_convert_link_mode_to_legacy_u32()` |

### 7.3 Network devices

| 4.9 | 6.18 |
|---|---|
| `netif_napi_add(dev, napi, poll, weight)` | `netif_napi_add(dev, napi, poll)` — the weight argument is gone |
| `memcpy(dev->dev_addr, ...)` | `dev->dev_addr` is read-only; use `eth_hw_addr_set()` |

### 7.4 platform / resource boilerplate

Modern devm helpers shorten probe code considerably; this is most of why `phy-rtk-sata.c` went from 677 lines to 431:

| Common 4.9 idiom | 6.18 |
|---|---|
| `platform_get_resource` + `devm_ioremap_resource` | `devm_platform_ioremap_resource()` |
| Hand-rolled array allocation | `devm_kcalloc()` |
| Counting properties with repeated `of_property_read_u32` | `of_property_count_u32_elems()` and friends |

### 7.5 thermal

4.9's thermal registration differs so much from 6.x that `rtd129x_thermal.c` was **rewritten against the register protocol** rather than ported:

| 4.9 | 6.18 |
|---|---|
| Hand-rolled `thermal_zone_device_register` with private ops | `devm_thermal_of_zone_register()` |
| Callbacks taking a private struct | `.get_temp(struct thermal_zone_device *tz, int *temp)` plus `thermal_zone_device_priv()` |

Only two pieces of hardware knowledge actually had to be extracted from the vendor driver: the two arm-sequence magic values, and the 18-bit sign-extension × 1000/1024 conversion.

### 7.6 regulator

`g22xx-regulator-core.c` differs from the vendor by 72 lines, mostly changes to OF parsing helpers (`of_property_read_bool`, `of_get_child_by_name`) and adjustments to regulator framework structures.

### 7.7 irqchip

The core logic of the vendor IRQ mux — read status, check enable, dispatch — carries over to 6.18 almost unchanged; `generic_handle_irq`, `irq_find_mapping` and `irq_desc_get_irq` all still exist. What actually had to change was not an API but **a transfer of responsibility**: the vendor acked the status register from its forked 8250 driver, and mainline peripheral drivers know nothing about that register, so acking had to move into the mux itself (§4.2).

**This is the failure mode to watch for when porting a vendor BSP**: not that a function signature changed, but that the vendor distributed some responsibility across its own forked drivers. Port one file, and that responsibility silently disappears.

---

## 8. Relationship to the other documents in this repository

The documentation here accumulated in layers. Everything that this guide supersedes has been
moved under [`docs/history/`](history/) so the repository root stays readable; nothing was
lost, and git history has the rest. This table records what supersedes what, so nobody acts
on an obsolete conclusion.

| Document | Status | Notes |
|---|---|---|
| [`README.md`](../README.md) | **Current** | User-facing: flashing, slot boundaries, version naming. This guide does not restate the sector tables; it links here. |
| [`DEVELOPMENT_HISTORY.md`](../DEVELOPMENT_HISTORY.md) | **Current** | Milestone chronology (vNN plus git SHAs). Complementary: it covers *when*, this guide covers *why and how*. |
| [`history/DEBUG_SESSION_2026-04-20.md`](history/DEBUG_SESSION_2026-04-20.md) | **Historical; conclusions superseded** | The primary record of the April boot-chain work, and its vendor-DTS analysis is still useful. But it predates all hardware validation — notably, its v23 spin-table DTS later hard-hung on the machine (§2.2-⑦). |
| [`history/PORTING_STATUS.md`](history/PORTING_STATUS.md) | **Historical** | A 2026-04-19 snapshot. Its "completed" facts (Image header values, COMPAT, rsvmem, the switch_root decision) are accurate, but its status and next-steps framing predates SMP, UART IRQ, ethernet, USB and thermal all being finished. |
| [`history/KERNEL_PORTING_GUIDE.md`](history/KERNEL_PORTING_GUIDE.md) | **Superseded by this document** | Frozen in the 6.18.2 era. Its device-tree format conversion recipe is still valid; the status sections are obsolete. |
| [`history/DRIVER_PORTING_GUIDE.md`](history/DRIVER_PORTING_GUIDE.md) | **Superseded by this document, and one conclusion was wrong** | Its central claim — that a missing I2C driver is severe and might prevent boot — **is disproven in practice**: the I2C and PMIC stack is in the tree but built as modules that are never loaded, and the device boots, runs and ships without them (§4.9). Stated explicitly here so nobody revives it. |
| [`history/OFFICIAL_KERNEL_ANALYSIS.md`](history/OFFICIAL_KERNEL_ANALYSIS.md) | **Superseded by this document; some reference value remains** | Its record of the vendor DTS include hierarchy (`rtd-1295-monarch-1GB.dts` → giraffe-common → `rtd-1295.dtsi`), vendor bootargs and gmac/PWM nodes is accurate as 4.9-tree reference. Its forward-looking analysis is obsolete. |

---

## 9. Unfinished work and known limitations

| Item | Status |
|---|---|
| RTC does not tick | Deliberately shelved. It probes and `/dev/rtc0` exists, but the vendor enable sequence is missing. NTP covers the requirement. |
| `rtl_csiar_cond` timeout warnings | Known noise from this vendor driver on this SoC; appears twice, harmless. |
| Empty u2host / u3host root hubs | Harmless (the corresponding ports are unpopulated pads); can be disabled in the DTS. |
| I2C / PMIC / regulators | Ported into the tree but built as modules and never loaded; the device runs on built-in drivers with dummy regulators. Switch to `=y` and rebuild to enable (§4.9). |
| Board DTS `bootargs` | Still contains the incorrect `root=/dev/sda9 rootfstype=ext4`, masked by `CMDLINE_FORCE`. Should be fixed. |
| Slot A | Dead on this unit: the old initramfs fails switch_root and panic-loops after about 43 s. Could be repurposed as a serial-free fallback slot holding a validated kernel from this project. |
| Clock driver | RTD129x has no mainline clock driver. Ethernet and USB rely on the gates the bootloader leaves open plus probe-time quirks. Writing a real clock driver is the proper path forward. |
