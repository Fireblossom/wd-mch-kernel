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
> The current release is **6.18.40-r2**, validated on hardware. The earlier
> **6.18.2-r1** package is kept for rollback and is no longer recommended for
> new installations.

> [!WARNING]
> Writing the wrong disk sectors can make the device unbootable. Before
> flashing, connect a 115200 8N1 serial console, back up the existing
> partitions, and verify every address and transfer size. This project only
> writes the B slot. Do not overwrite the A or GOLD slots — but do not treat
> them as recovery paths either; see the rollback section below.

## Quick start

If you want to use the prebuilt kernel:

1. Confirm that your device matches the supported configuration above.
2. Download
   [`wd-mch-kernel-6.18.40-r2.tar.gz`](release/wd-mch-kernel-6.18.40-r2.tar.gz).
3. Read the [package overview](release/wd-mch-kernel-6.18.40-r2/README.md)
   (Chinese).
4. Follow the [flashing guide](release/wd-mch-kernel-6.18.40-r2/docs/FLASHING.md)
   (Chinese).
5. Before making changes, understand the
   [slot-selection, rollback, and network-recovery procedures](release/wd-mch-kernel-6.18.40-r2/docs/RESCUE.md)
   (Chinese).

The previous [`6.18.2-r1`](release/wd-mch-kernel-6.18.2-r1/README.md) package
remains available as a rollback target. Do not mix files from the two
packages.

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
| User-facing release | **r2** |
| Upstream kernel | Linux 6.18.40 LTS |
| Target hardware | Single-bay WD My Cloud Home / Realtek RTD1295 |
| Target boot slot | B; A and GOLD remain untouched |
| Root filesystem | Existing Debian 13 arm64 installation on `/dev/md1` |
| Corresponding source | Commit `31ed4b309` on `main` |
| Validation | Flashed and booted on hardware; four cores, interrupt-driven UART, ethernet, Docker, OpenMediaVault, USB 3.0, thermal zones and md array assembly all confirmed, across three cold power cycles with no failed units |

Regular users should use `r2`. Do not select files by the internal `v21`,
`v38`, or `v46` labels found in old development artifacts.

## Previous release

| Item | Value |
|---|---|
| Package | `r1` |
| Upstream kernel | Linux 6.18.2 |
| Status | Superseded by `r2`; kept as a rollback target |

`r1` remains in the repository so an existing installation can be put back the
way it was. Both packages write only the B slot, so rolling back is the same
procedure as flashing forward.

## Version naming

The development log contains several unrelated numbering schemes:

| Example | Meaning | User-selectable? |
|---|---|---|
| `6.18.2`, `6.18.40` | Upstream Linux kernel version | Only through a complete package |
| `r2` | Version of the complete public flashing package | **Yes; use this release** |
| `r1` | The previous package, kept as a rollback target | Only to roll back |
| `v21` through `v46` | Chronological labels for internal kernel + DTB + `fw_table` test combinations | No; traceability only |
| Kernel `#35` | A local kernel build counter shown by `uname` | No |
| DTB `v22` | An internal device-tree artifact revision | No |

The internal labels are not semantic versions, Git tags, or compatibility
claims. For example, the internal `v46` combination used DTB revision `v22`;
the differing numbers do not indicate a missing file.

The public package replaces those labels with three neutral filenames:

```text
Image-6.18.2-mch
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
| TUN, WireGuard, dm-crypt, FUSE, and zram | Verified |
| Watchdog-based soft reboot | Verified |
| SoC temperature reporting and thermal zones | Verified |
| B/A/GOLD slot selection and one-shot network recovery | Verified, with limitations documented below |

The USB 3.0 port sustained approximately 137 MB/s in testing with a mechanical
disk. Actual performance depends on the drive, filesystem, and workload.

## Flashing and rollback boundaries

The kernel, DTB, and `fw_table` in `r1` are an inseparable set. The
`fw_table` stores the sizes and checksums of the other two files; mixing
artifacts from different development stages will invalidate that relationship.

The release writes only these B-slot locations:

| Content | First SATA sector | Sector count |
|---|---:|---:|
| `fw_table.bin` | `0x22` | `0x10` |
| `mch.dtb` | `0x31000` | `0x38` |
| `Image-6.18.40-mch` | `0x33800` | `0x7ee8` |

Use the exact commands, backup procedure, and transfer-size checks in
[`FLASHING.md`](release/wd-mch-kernel-6.18.40-r2/docs/FLASHING.md). Never
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
[`RESCUE.md`](release/wd-mch-kernel-6.18.40-r2/docs/RESCUE.md) before flashing.

## Repository layout

| Path | Purpose |
|---|---|
| `linux-6.18.40/` | Linux 6.18.40 source with the board changes and tracked `.config` |
| `initramfs/` | Embedded BusyBox/mdadm initramfs, root handoff, and network recovery |
| `rtd1295_*.config` | Configuration fragments for systemd, NAS, networking, USB, thermal support, and related features |
| `rebuild_package_and_print_flash.sh` | Portable build and packaging tool that patches the Realtek Image header, pads artifacts, updates `fw_table`, and verifies the result |
| `release/wd-mch-kernel-6.18.40-r2/` | Current release: artifacts and documentation |
| `release/wd-mch-kernel-6.18.2-r1/` | Previous release, kept as a rollback target |

The main board-specific changes relative to unmodified Linux 6.18.40 are:

- a WD My Cloud Home device tree for RTD1295;
- the RTD129x interrupt mux and UART interrupt handling;
- device-register access for the RTD1295 CPU release address;
- support for the integrated Realtek Ethernet controller;
- DWC3/PHY and USB 3.0 lane configuration;
- RTD129x thermal monitoring and watchdog restart support;
- kernel configuration for Debian 13, containers, and NAS workloads.

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
[`r2 source notes`](release/wd-mch-kernel-6.18.40-r2/SOURCES.md) and
[`r1 source notes`](release/wd-mch-kernel-6.18.2-r1/SOURCES.md).
