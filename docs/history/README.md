# Archived notes

These files are kept for provenance only. They record the investigation as it
happened between April and July 2026 and **contain conclusions that were later
disproven on hardware**. Do not follow them as instructions.

Current documentation:

- [../../README.md](../../README.md) — flashing, slot boundaries, releases
- [../PORTING_GUIDE_4.9_to_6.18.md](../PORTING_GUIDE_4.9_to_6.18.md) — the port itself,
  per source file, plus the boot chain and the root-cause history
- [../../DEVELOPMENT_HISTORY.md](../../DEVELOPMENT_HISTORY.md) — milestone chronology

Two corrections worth stating up front, because several files here get them wrong:

1. `DRIVER_PORTING_GUIDE.md` treats a missing I2C driver as a possible boot blocker.
   It is not. The I2C and PMIC stack is present in the tree but built as modules that
   are never loaded, and the device boots and runs without them.
2. Files from July and earlier describe slot A and the GOLD slot as usable fallbacks.
   Slot A panic-loops on switch_root, and GOLD is an Android recovery image that
   factory-resets the machine unconditionally on every boot.

Several of these notes reference intermediate binaries (`fw_table_v*.bin`,
padded `.dtb` files, `extracted.dts`, GPT dumps) that used to sit in the repository
root. They were build by-products, not sources, and have been removed; recover them
from git history if you ever need them.
