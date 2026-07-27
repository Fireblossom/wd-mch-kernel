# WD Monarch GPT V3 Partition Map and Current Debug Plan

## Source of truth

Partition layout comes from U-Boot source:
- `_vendor_refs/uboot/cmd_rtkgpt.c` (`fill_GPT_PTES_V3`)
- `_vendor_refs/uboot/cmd_boot.c` (`CURRENT_GPT_VER = 3`)

## GPT V3 mapping (index -> name)

1. FW_TABLE
2. KERNEL_A
3. ROOTFS_A
4. ROOTFS_B
5. FDT_A
6. FDT_B
7. AFW_A
8. KERNEL_B
9. ROOTFS_GOLD
10. FDT_GOLD
11. AFW_B
12. BOOTCODE32
13. BOOTCODE64
14. BL31
15. BL32
16. KERNEL_GOLD
17. AFW_GOLD
18. CONFIG
19. SYSTEM_A
20. SYSTEM_B
21. CACHE
22. DATA
23. SWAP
24. DISKVOLUME1

## Current verified state

- SATA/AHCI working; partitions `sda1..sda24` visible.
- `/dev/sda9` starts with gzip magic (`1f 8b 08`), not ext4.
- initramfs path for `sda9` auto-unpack is implemented and verified.
- Debian root handoff uses `switch_root` so `/sbin/init` becomes PID 1; vendor rescue rootfs still keeps a `chroot` debug path.
- 32-bit userspace compatibility issue was fixed by enabling `CONFIG_COMPAT=y`.

## What is no longer current

- "Mount `/dev/sda9` as ext4" (invalid for this image type).
- "Debian can stay on chroot handoff" (not true for systemd; Debian now needs `switch_root`).
- "SATA path blocked by EBUSY" (already resolved in current DTS/kernel state).

## Current debug focus

### 1) Debian installer path validation

Prefer validating upgraded package:
- `MyCloudHome_Debian13_v6.0-k6.18-v19`

Checkpoints after install/boot:

```sh
uname -a
lsblk
ip a
```

### 2) Service stability after userspace boot

If service spam appears, collect:

```sh
dmesg | tail -n 200
ps -ef | head -n 80
```

Prioritize keeping system stable before enabling non-essential services.

### 3) Serial reliability guardrails

- Send one short command per line.
- Avoid long pasted chains when `ttyS0 input overrun` appears.
- Prefer network-based transfer (TFTP) for large payloads.

## Installer observed layout (single-disk, 2026-04-20)

Source: serial log from `install-linux1.sh` in stock Debian13 rescue environment.

Detected devices:
- Target HDD: `/dev/sdb` (Intel SSD 250GB)
- Install USB: `/dev/sda` (HSUD 57.5GB)

Created GPT partitions on `/dev/sdb`:

| Partition | Start | End | Size | Label |
|---|---:|---:|---:|---|
| /dev/sdb1 | 34 | 2047 | 1007K | FW_TABLE |
| /dev/sdb2 | 2048 | 67583 | 32M | KERNEL_A |
| /dev/sdb3 | 67584 | 133119 | 32M | ROOTFS_A |
| /dev/sdb4 | 133120 | 198655 | 32M | ROOTFS_B |
| /dev/sdb5 | 198656 | 200703 | 1M | FDT_A |
| /dev/sdb6 | 200704 | 202751 | 1M | FDT_B |
| /dev/sdb7 | 202752 | 210943 | 4M | AFW_A |
| /dev/sdb8 | 210944 | 276479 | 32M | KERNEL_B |
| /dev/sdb9 | 276480 | 342015 | 32M | ROOTFS_GOLD |
| /dev/sdb10 | 342016 | 344063 | 1M | FDT_GOLD |
| /dev/sdb11 | 344064 | 352255 | 4M | AFW_B |
| /dev/sdb12 | 352256 | 354303 | 1M | BOOTCODE32 |
| /dev/sdb13 | 354304 | 356351 | 1M | BOOTCODE64 |
| /dev/sdb14 | 356352 | 358399 | 1M | BL31 |
| /dev/sdb15 | 358400 | 360447 | 1M | BL32 |
| /dev/sdb16 | 360448 | 425983 | 32M | KERNEL_GOLD |
| /dev/sdb17 | 425984 | 434175 | 4M | AFW_GOLD |
| /dev/sdb18 | 434176 | 499711 | 32M | CONFIG |
| /dev/sdb19 | 499712 | 6791167 | 3G | SWAP |
| /dev/sdb20 | 6791168 | 48734207 | 20G | SYSTEM |
| /dev/sdb21 | 48734208 | 500117503 | 215.2G | DATA |

Notes:
- This installer path creates partitions up to 21 (no 22-24 in this single-disk install script).
- md arrays created:
	- `md0` <- `sdb19` (swap)
	- `md1` <- `sdb20` (SYSTEM ext4)
	- `md2` <- `sdb21` (DATA ext4)
- Log reached `--- Unpacking the system image -----` and progress `8082/20201 extracted`.
