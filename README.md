# Linux for WD My Cloud Home (RTD1295)

This repository contains a Linux board port for the single-bay WD My Cloud
Home, based on the Realtek RTD1295 SoC. The current development branch uses
Linux 6.18.40 LTS. It includes the complete kernel source tree, board-specific
changes, an embedded initramfs, and B-slot flashing packages.

This is an independent community project. It is neither official WD firmware
nor a Debian installer. The prebuilt package assumes that Debian 13 arm64 is
already installed with its root filesystem on `/dev/md1`.

Testing has been performed on one single-bay My Cloud Home. My Cloud Home Duo
and other RTD1295-based products are outside the tested scope.

> [!IMPORTANT]
> The current release is **6.18.40-r7**, validated on hardware. Over **r5** it
> adds CPU frequency scaling (300/600/1100 MHz under schedutil — the board had
> always run at a fixed 600 MHz) with a thermal throttle at 85 °C. The 1100 MHz
> peak sits above WD's only factory-validated operating point; the package
> README explains this honestly and how to cap the maximum back to 600 MHz.
> The r5, r2 and **6.18.2-r1** packages are kept for rollback and are no
> longer recommended for new installations.

> [!WARNING]
> Writing the wrong disk sectors can make the device unbootable. Before
> flashing, back up the existing B-slot partitions and verify every address
> and transfer size. This project only writes the B slot. Do not overwrite the
> A or GOLD slots — but do not treat them as recovery paths either; see the
> rollback section below.

## Quick start

If you want to use the prebuilt kernel:

1. Confirm that your device matches the supported configuration above.
2. Download
   [`wd-mch-kernel-6.18.40-r7.tar.gz`](release/wd-mch-kernel-6.18.40-r7.tar.gz).
3. Read the [package overview](release/wd-mch-kernel-6.18.40-r7/README.md)
   (Chinese).
4. Follow the [flashing guide](release/wd-mch-kernel-6.18.40-r7/docs/FLASHING.md)
   (Chinese). A device that already boots this project's kernel (or the
   community Debian image) can be flashed over SSH without a serial console;
   the guide documents both paths.
5. Before making changes, understand the
   [slot-selection, rollback, and network-recovery procedures](release/wd-mch-kernel-6.18.40-r7/docs/RESCUE.md)
   (Chinese).

The previous [`6.18.40-r5`](release/wd-mch-kernel-6.18.40-r5/README.md),
[`6.18.40-r2`](release/wd-mch-kernel-6.18.40-r2/README.md) and
[`6.18.2-r1`](release/wd-mch-kernel-6.18.2-r1/README.md) packages remain
available as rollback targets. Do not mix files from different packages.

If you plan to modify or port the kernel, start with
[`docs/PORTING_GUIDE_4.9_to_6.18.md`](docs/PORTING_GUIDE_4.9_to_6.18.md) — a
per-file account of every source change relative to vanilla 6.18.40, the vendor
boot chain, and the symptom-to-root-cause history of the port. Then see
`linux-6.18.40/`, the [Building from source](#building-from-source) section, and
[`DEVELOPMENT_HISTORY.md`](DEVELOPMENT_HISTORY.md).

Earlier investigation notes have been moved to
[`docs/history/`](docs/history/). They are kept for provenance and contain
conclusions that were later disproven on hardware; do not follow them as
instructions.

## Recommended release

| Item | Value |
|---|---|
| User-facing release | **r7** |
| Upstream kernel | Linux 6.18.40 LTS |
| Target hardware | Single-bay WD My Cloud Home / Realtek RTD1295 |
| Target boot slot | B; A and GOLD remain untouched |
| Root filesystem | Existing Debian 13 arm64 installation on `/dev/md1` |
| Corresponding source | Commit `465b61eea` |
| Validation | Flashed and booted on hardware; four cores, interrupt-driven UART, gigabit ethernet, Docker, OpenMediaVault, USB 3.0, md array assembly, a 15-second hardware watchdog under systemd, pstore/ramoops crash logging, three-point cpufreq under schedutil with an 85 °C passive throttle, CE-accelerated dm-crypt (246 MB/s write / 376 MB/s read against a 251/373 MB/s plaintext baseline — at disk speed), and temperature via both thermal and hwmon all confirmed, across three cold power cycles |

Regular users should use `r7`. Do not select files by the internal `v21`,
`v38`, or `v46` labels found in old development artifacts.

## Previous releases

| Package | Upstream kernel | Status |
|---|---|---|
| `r5` | Linux 6.18.40 | Superseded by `r7`; kept as a rollback target |
| `r2` | Linux 6.18.40 | Superseded; kept as a rollback target |
| `r1` | Linux 6.18.2 | Historical; kept as a rollback target |

The previous packages remain in the repository so an existing installation can
be put back the way it was. All packages write only the B slot, so rolling
back is the same procedure as flashing forward.

## Version naming

The development log contains several unrelated numbering schemes:

| Example | Meaning | User-selectable? |
|---|---|---|
| `6.18.2`, `6.18.40` | Upstream Linux kernel version | Only through a complete package |
| `r7` | Version of the complete public flashing package | **Yes; use this release** |
| `r1`–`r6` | Previous packages and internal releases | Only to roll back |
| `v21` through `v46` | Chronological labels for internal kernel + DTB + `fw_table` test combinations | No; traceability only |
| Kernel `#35` | A local kernel build counter shown by `uname` | No |
| DTB `v22` | An internal device-tree artifact revision | No |

The internal labels are not semantic versions, Git tags, or compatibility
claims. For example, the internal `v46` combination used DTB revision `v22`;
the differing numbers do not indicate a missing file.

The public package replaces those labels with three neutral filenames:

```text
Image-6.18.40-mch
mch.dtb
fw_table.bin
```

These files form one validated set and must be used together. For a concise
explanation of the internal milestones, see
[`DEVELOPMENT_HISTORY.md`](DEVELOPMENT_HISTORY.md).

## Hardware-verified functionality

| Capability | Status |
|---|---|
| All four Cortex-A53 CPU cores (SMP) | Verified |
| UART0 in interrupt-driven mode, 115200 8N1 | Verified |
| Integrated Gigabit Ethernet with the factory MAC address | Verified |
| Rear USB 3.0 Type-A port at 5 Gbit/s | Verified |
| Debian 13 and systemd | Verified |
| Docker and OpenMediaVault 8 | Verified |
| NFS, quotas, and the ACL/xattr support required by SMB | Verified |
| TUN, WireGuard, FUSE, and zram | Verified |
| dm-crypt with ARMv8 Crypto Extensions | Verified; 246 MB/s write / 376 MB/s read, at the disk's own speed |
| CPU frequency scaling (300/600/1100 MHz, schedutil) | Verified; 1100 MHz is above the factory operating point, see the package README |
| Thermal throttling (85 °C passive trip, cpufreq cooling) | Verified |
| Hardware watchdog (systemd keepalive, 15 s timeout) | Verified |
| pstore/ramoops crash logging across reboots | Verified; does not survive power loss |
| SoC temperature via thermal zones and hwmon (`sensors`) | Verified |
| Cold power-cycle self-recovery | Verified; three consecutive cycles, 26 s back on the network |
| B/A/GOLD slot selection and one-shot network recovery | Verified, with limitations documented below |

The USB 3.0 port sustained approximately 137 MB/s in testing with a mechanical
disk. Actual performance depends on the drive, filesystem, and workload.

## Flashing and rollback boundaries

The kernel, DTB, and `fw_table` in a package are an inseparable set. The
`fw_table` stores the sizes and checksums of the other two files; mixing
artifacts from different packages or development stages will invalidate that
relationship.

The `r7` release writes only these B-slot locations:

| Content | First SATA sector | Sector count |
|---|---:|---:|
| `fw_table.bin` | `0x22` | `0x10` |
| `mch.dtb` | `0x31000` | `0x38` |
| `Image-6.18.40-mch` | `0x33800` | `0x8110` |

Use the exact commands, backup procedure, and transfer-size checks in
[`FLASHING.md`](release/wd-mch-kernel-6.18.40-r7/docs/FLASHING.md). Never
overwrite the A or GOLD slots.

> [!CAUTION]
> Neither A nor GOLD is a usable fallback, despite what earlier notes in this
> repository claimed. GOLD is an Android recovery image whose userspace runs an
> unconditional factory reset on **every** boot, including `mke2fs -E discard`
> on what the community Debian layout uses as the data partition; that TRIMs the
> SSD and the data is gone immediately. Slot A, on a device installed by the
> community Debian package, panic-loops on `switch_root`. **Back up the three
> B-slot partitions before flashing and restore those if you need to roll back.**
> Keep `bootConfig` at `0:F:0:;`.

The first-stage bootloader does not decrement a retry counter and does not
automatically roll back a failed slot. See
[`RESCUE.md`](release/wd-mch-kernel-6.18.40-r7/docs/RESCUE.md) before flashing.

## Repository layout

| Path | Purpose |
|---|---|
| `linux-6.18.40/` | Linux 6.18.40 source with the board changes and tracked `.config` |
| `initramfs/` | Embedded BusyBox/mdadm initramfs, root handoff, and network recovery |
| `rtd1295_*.config` | Configuration fragments for systemd, NAS, networking, USB, thermal, crypto acceleration, and related features |
| `rebuild_package_and_print_flash.sh` | Portable build and packaging tool that patches the Realtek Image header, pads artifacts, updates `fw_table`, and verifies the result |
| `release/wd-mch-kernel-6.18.40-r7/` | Current release: artifacts and documentation |
| `release/wd-mch-kernel-6.18.40-r5/` | Previous release, kept as a rollback target |
| `release/wd-mch-kernel-6.18.40-r2/` | Previous release, kept as a rollback target |
| `release/wd-mch-kernel-6.18.2-r1/` | Previous release, kept as a rollback target |

The main board-specific changes relative to unmodified Linux 6.18.40 are:

- a WD My Cloud Home device tree for RTD1295;
- the RTD129x interrupt mux and UART interrupt handling;
- device-register access for the RTD1295 CPU release address;
- support for the integrated Realtek Ethernet controller;
- DWC3/PHY and USB 3.0 lane configuration;
- RTD129x thermal monitoring, exposed through both thermal zones and hwmon,
  with passive throttling through the cpufreq cooling device;
- an SCPU clock driver (PLL_SCPU + post-divider) providing three cpufreq
  operating points without ever touching a voltage rail;
- a usable RTD119x hardware watchdog (keepalive and timeout ioctls);
- kernel configuration for Debian 13, containers, NAS workloads, and
  ARMv8 Crypto Extensions.

## Building from source

The packaging tool performs an out-of-tree build, overrides the tracked
initramfs path in the build copy of `.config`, creates a matching `fw_table`,
and verifies the complete package:

```bash
./rebuild_package_and_print_flash.sh
```

For a manual raw-kernel build:

```bash
cd /path/to/wd-mch-kernel
mkdir -p build/linux-6.18.40
cp linux-6.18.40/.config build/linux-6.18.40/.config

linux-6.18.40/scripts/config \
  --file build/linux-6.18.40/.config \
  --set-str INITRAMFS_SOURCE "$PWD/initramfs"

make -C linux-6.18.40 O="$PWD/build/linux-6.18.40" \
  ARCH=arm64 olddefconfig
make -C linux-6.18.40 O="$PWD/build/linux-6.18.40" \
  ARCH=arm64 -j"$(nproc)" Image dtbs
```

For a cross-build on a non-arm64 host, also set an appropriate
`CROSS_COMPILE` prefix.

The resulting raw Linux `Image` is **not directly flashable**. This device
requires a compatible Image header, fixed-size padding, and an `fw_table`
matching both the kernel and DTB. Use the packaging tool rather than manually
copying the raw build output.

## Known limitations

- `poweroff` has no power-cut implementation (`pm_power_off` is absent): the
  system halts but stays powered. `reboot` works normally. Cutting power
  requires an external switch.
- The front LED has no driver and cannot be controlled.
- cpufreq scales frequency only; no voltage scaling (cpudvs stays at 1.0 V).
  The 1100 MHz peak is above WD's factory-validated operating point and can be
  capped back to 600 MHz via scaling_max_freq.
- pstore relies on a DRAM reserved region: it survives reboots and panics but
  not power loss.
- The RTC registers successfully but does not advance; the system currently
  relies on NTP for wall-clock time.
- `r8169soc` occasionally logs an `rtl_csiar_cond` timeout. It has not affected
  networking in hardware testing.
- Network recovery exposes an unauthenticated root shell over telnet. Use it
  only temporarily on a trusted local network.
- Test coverage is limited to one physical device and does not establish
  compatibility with other hardware revisions or RTD1295 products.

## License and source provenance

The Linux kernel and the corresponding modifications in this repository are
licensed under GPL-2.0. The upstream baseline, vendor reference material, and
release-to-source relationship are documented in the
[`r7 source notes`](release/wd-mch-kernel-6.18.40-r7/SOURCES.md); earlier
packages carry their own `SOURCES.md`.
