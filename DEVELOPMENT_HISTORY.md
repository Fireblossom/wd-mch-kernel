# Development History

This page explains how the WD My Cloud Home port became usable. It is a
maintainer-oriented history, not a list of releases for users to choose from.

If you only want to install the kernel, use the current **r1** package and
follow its flashing guide. The `v21`, `v38`, and similar names below were
temporary labels used during hardware testing.

## The short version

Development progressed in four broad stages:

1. Boot the existing Debian installation from its `/dev/md1` RAID device.
2. Bring up all CPU cores, interrupts, the serial console, and Ethernet.
3. Add the kernel features and hardware support needed for normal NAS use.
4. Add safer slot selection, rollback options, and network recovery.

The first public package, **r1**, was produced after those stages were
completed. It is based on the final `v46` development combination.

## 1. Booting the existing Debian system

The first challenge was not simply starting the kernel. The initramfs also had
to assemble the device's Linux MD array before it could mount the Debian root
filesystem.

- **v21:** Added `mdadm` to the initramfs. The kernel could find and assemble
  the RAID device containing the Debian root filesystem, but the system was not
  yet suitable for normal use.
- **v27:** Reached a complete systemd boot. The serial login service was still
  disabled, so this was an important diagnostic milestone rather than a usable
  recovery environment.
- **v31:** Reached a repeatable boot with an interactive shell on the serial
  console. At this point the system still used only one CPU core, and the UART
  relied on polling instead of hardware interrupts.

## 2. Enabling the SoC hardware

Once the basic boot path worked, the focus moved to the Realtek RTD1295
hardware that was not supported by the upstream kernel configuration.

- **v32:** Corrected access to the CPU release address and brought all four
  Cortex-A53 cores online.
- **v34:** Added the RTD129x interrupt multiplexer and converted the serial
  port from polling to normal interrupt-driven operation.
- **v36:** Enabled the integrated Gigabit Ethernet controller and preserved the
  factory-assigned MAC address.

These changes turned the early single-core diagnostic system into a practical
networked machine.

## 3. Making the system useful as a NAS

The next stage added the kernel facilities expected by Debian, containers, and
NAS software.

- **v38:** Enabled NFS, ACLs, quotas, TUN, WireGuard, device-mapper encryption,
  FUSE, and zram. It also added a working soft-reboot path.
- **v42:** Enabled the rear USB 3.0 port at 5 Gbit/s and added SoC temperature
  monitoring and an RTC device-tree node. This was the first combination with
  the hardware and operating-system features needed for routine use.

The RTC node allows the driver to register, but the clock still does not
advance correctly. The released system therefore relies on NTP for wall-clock
time.

## 4. Adding recovery and preparing the release

- **v46:** Added explicit B/A/GOLD slot selection and a one-shot network
  recovery environment. This combination became the technical basis of the
  public **r1** package.

The recovery work was deliberately completed before publication. The
bootloader does not automatically roll back a failed boot, so preserving the A
and GOLD slots remains essential.

## Milestone reference

The table below is for source-history lookup. These identifiers are not
downloadable releases.

| Internal label | Milestone | Related commit |
|---|---|---|
| `v21` | The initramfs could assemble the Debian MD root device | — |
| `v27` | systemd completed its boot sequence | — |
| `v31` | Repeatable boot with an interactive serial console | `29a312b28` |
| `v32` | All four Cortex-A53 cores came online | `776e6569b` |
| `v34` | Interrupt-driven UART operation became stable | `34adcdfb4` |
| `v36` | Integrated Ethernet and the factory MAC address worked | `ea27e1acc` |
| `v38` | NAS, container, VPN, storage, and soft-reboot support was added | `4cda483ae` |
| `v42` | USB 3.0, temperature monitoring, and the RTC node were added | `4a3860a93` |
| `v46` | Slot control and one-shot network recovery were added | `7b70fa890` |

## What the internal numbers mean

Each `vNN` label identified a kernel Image, device tree, and `fw_table` that
were tested together on the device. The number only records the order of the
experiments:

- It is not a Git tag or a semantic version.
- Missing numbers were usually short-lived diagnostic or failed builds.
- A kernel build number such as `#35` is a separate compiler-generated
  counter.
- Device-tree files had another independent revision counter.

For example, the `v46` test combination used device-tree revision `v22`. The
different numbers do not indicate that an artifact is missing.

## Relationship to the r1 package

The public package replaces the internal labels with these filenames:

```text
Image-6.18.2-mch
mch.dtb
fw_table.bin
```

They form one validated set. The `fw_table` records the sizes and checksums of
the kernel and device tree, so files from different development combinations
must not be mixed.

Old notes may use words such as “current” or “next” to describe the state of
the project at the time they were written. Use the commit date and the
milestones above when reading them; those notes are not current installation
instructions.
