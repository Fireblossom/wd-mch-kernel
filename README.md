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
> The hardware-tested release remains **6.18.2-r1**. The
> **6.18.40-r2-rc1** package is a build-verified upgrade candidate and must
> complete hardware validation before it becomes the recommended release.

> [!WARNING]
> Writing the wrong disk sectors can make the device unbootable. Before
> flashing, connect a 115200 8N1 serial console, back up the existing
> partitions, and verify every address and transfer size. This project only
> writes the B slot. Do not overwrite the A or GOLD recovery slots.

## Quick start

If you want to use the prebuilt kernel:

1. Confirm that your device matches the supported configuration above.
2. For a normal installation, download
   [`wd-mch-kernel-6.18.2-r1.tar.gz`](release/wd-mch-kernel-6.18.2-r1.tar.gz).
3. Read the [package overview](release/wd-mch-kernel-6.18.2-r1/README.md)
   (Chinese).
4. Follow the [flashing guide](release/wd-mch-kernel-6.18.2-r1/docs/FLASHING.md)
   (Chinese).
5. Before making changes, understand the
   [slot-selection, rollback, and network-recovery procedures](release/wd-mch-kernel-6.18.2-r1/docs/RESCUE.md)
   (Chinese).

Hardware testers evaluating Linux 6.18.40 must instead use the explicitly
labelled
[`r2-rc1` candidate](release/wd-mch-kernel-6.18.40-r2-rc1/README.md)
and its generated flash commands. Do not mix files from the two packages.

If you plan to modify or port the kernel, start with `linux-6.18.40/`, the
[Building from source](#building-from-source) section, and
[`DEVELOPMENT_HISTORY.md`](DEVELOPMENT_HISTORY.md). The other
top-level notes document earlier investigation and may contain conclusions that
were later superseded; they should not be treated as current instructions.

## Recommended release

| Item | Value |
|---|---|
| User-facing release | **r1** |
| Upstream kernel | Linux 6.18.2 |
| Target hardware | Single-bay WD My Cloud Home / Realtek RTD1295 |
| Target boot slot | B; A and GOLD remain untouched |
| Root filesystem | Existing Debian 13 arm64 installation on `/dev/md1` |
| Corresponding source | Commit `7b70fa890`, plus public-release documentation |
| Validation | Cold boot, soft reboot, networking, and unattended SSH recovery tested on hardware |

Regular users should use `r1`. Do not select files by the internal `v21`,
`v38`, or `v46` labels found in old development artifacts.

## Upgrade candidate

| Item | Value |
|---|---|
| Candidate package | **r2-rc1** |
| Upstream kernel | Linux 6.18.40 LTS |
| Development branch | `upgrade/linux-6.18.40` |
| Build validation | Clean configuration, Image, DTB, packaging, and checksum verification passed |
| Hardware validation | Pending |

The candidate is an upgrade test, not a replacement for `r1` yet. Its package
contains `BUILD-METADATA.json` and generated `FLASH_COMMANDS.txt` so that the
source commit, artifact sizes, and B-slot write counts remain auditable.

## Version naming

The development log contains several unrelated numbering schemes:

| Example | Meaning | User-selectable? |
|---|---|---|
| `6.18.2`, `6.18.40` | Upstream Linux kernel version | Only through a complete package |
| `r1` | Version of the complete public flashing package | **Yes; use this release** |
| `r2-rc1` | Hardware-test candidate for the next release | Testers only |
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

## Hardware-verified functionality in r1

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
| `Image-6.18.2-mch` | `0x33800` | `0x7e60` |

Use the exact commands, backup procedure, and transfer-size checks in
[`FLASHING.md`](release/wd-mch-kernel-6.18.2-r1/docs/FLASHING.md). Never
overwrite the A or GOLD slots; they provide independent recovery paths if the
mainline kernel cannot boot.

The first-stage bootloader does not decrement a retry counter and does not
automatically roll back a failed slot. See
[`RESCUE.md`](release/wd-mch-kernel-6.18.2-r1/docs/RESCUE.md) before flashing.
The `r2-rc1` candidate has its own flashing and rescue documents and must be
tested without committing B as the permanent slot.

## Repository layout

| Path | Purpose |
|---|---|
| `linux-6.18.40/` | Linux 6.18.40 source with the board changes and tracked `.config` |
| `initramfs/` | Embedded BusyBox/mdadm initramfs, root handoff, and network recovery |
| `rtd1295_*.config` | Configuration fragments for systemd, NAS, networking, USB, thermal support, and related features |
| `rebuild_package_and_print_flash.sh` | Portable build and packaging tool that patches the Realtek Image header, pads artifacts, updates `fw_table`, and verifies the result |
| `release/wd-mch-kernel-6.18.2-r1/` | User-facing `r1` artifacts and documentation |
| `release/wd-mch-kernel-6.18.40-r2-rc1/` | Build-verified upgrade candidate and test documentation |

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
[`r1 source notes`](release/wd-mch-kernel-6.18.2-r1/SOURCES.md) and
[`r2-rc1 source notes`](release/wd-mch-kernel-6.18.40-r2-rc1/SOURCES.md).
