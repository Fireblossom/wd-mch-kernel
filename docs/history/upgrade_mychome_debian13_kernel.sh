#!/usr/bin/env bash
set -euo pipefail

PKG_DIR="/home/ubuntu/linux/MyCloudHome_Debian13_v6.0"
KERNEL_RAW="/home/ubuntu/linux/Image-6.18.2-v19-raw-padded"
DTB_FILE="/home/ubuntu/linux/rtd1295-wd-mycloud-home-v11-padded.dtb"
OUT_DIR=""

usage() {
  cat <<'EOF'
Usage:
  upgrade_mychome_debian13_kernel.sh [options]

Options:
  --pkg-dir PATH        Source package directory
  --kernel-raw PATH     Raw arm64 Image file to package (already header-patched)
  --dtb PATH            DTB file to place as rescue.sata.dtb
  --out-dir PATH        Output package directory (default: <pkg-dir>-kupgrade)
  -h, --help            Show this help

This script will:
1) Copy package directory to output directory
2) Build sata.uImage (gzip of raw Image)
3) Replace rescue.sata.dtb
4) Rebuild linux/16.img (KERNEL_GOLD, 32 MiB padded raw Image)
5) Rebuild linux/10.img (FDT_GOLD, 1 MiB padded DTB)
6) Patch linux/fwtable0.bin and linux/fwtable1.bin checksums/sizes
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pkg-dir)
      PKG_DIR="$2"
      shift 2
      ;;
    --kernel-raw)
      KERNEL_RAW="$2"
      shift 2
      ;;
    --dtb)
      DTB_FILE="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

[[ -d "$PKG_DIR" ]] || { echo "Package dir not found: $PKG_DIR" >&2; exit 1; }
[[ -f "$KERNEL_RAW" ]] || { echo "Kernel file not found: $KERNEL_RAW" >&2; exit 1; }
[[ -f "$DTB_FILE" ]] || { echo "DTB file not found: $DTB_FILE" >&2; exit 1; }

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="${PKG_DIR}-kupgrade"
fi

if [[ -e "$OUT_DIR" ]]; then
  echo "Output path already exists: $OUT_DIR" >&2
  exit 1
fi

echo "[1/5] Copying package to output directory..."
cp -a "$PKG_DIR" "$OUT_DIR"

echo "[2/5] Replacing sata.uImage and rescue.sata.dtb..."
gzip -n -9 -c "$KERNEL_RAW" > "$OUT_DIR/sata.uImage"
cp "$DTB_FILE" "$OUT_DIR/rescue.sata.dtb"

echo "[3/5] Rebuilding linux/16.img and linux/10.img..."
python3 - <<PY
from pathlib import Path

out = Path(r"$OUT_DIR")
kernel = Path(r"$KERNEL_RAW").read_bytes()
dtb = Path(r"$DTB_FILE").read_bytes()

if len(kernel) > 32 * 1024 * 1024:
    raise SystemExit("Kernel raw image exceeds 32 MiB; cannot fit KERNEL_GOLD (16.img)")
if len(dtb) > 1 * 1024 * 1024:
    raise SystemExit("DTB exceeds 1 MiB; cannot fit FDT_GOLD (10.img)")

(out / "linux/16.img").write_bytes(kernel + b"\x00" * (32 * 1024 * 1024 - len(kernel)))
(out / "linux/10.img").write_bytes(dtb + b"\x00" * (1 * 1024 * 1024 - len(dtb)))
PY

echo "[4/5] Patching fwtable0.bin and fwtable1.bin..."
python3 - <<PY
import struct
from pathlib import Path

out = Path(r"$OUT_DIR")
kernel_blob = (out / "sata.uImage").read_bytes()
dtb_blob = (out / "rescue.sata.dtb").read_bytes()

k_size = len(kernel_blob)
k_cksum = sum(kernel_blob) & 0xFFFFFFFF
d_size = len(dtb_blob)
d_cksum = sum(dtb_blob) & 0xFFFFFFFF

for name in ("fwtable0.bin", "fwtable1.bin"):
    p = out / "linux" / name
    fw = bytearray(p.read_bytes())

    struct.pack_into('<I', fw, 0x1A0 + 14, d_size)
    struct.pack_into('<I', fw, 0x1A0 + 18, d_size)
    struct.pack_into('<I', fw, 0x1A0 + 22, d_cksum)

    struct.pack_into('<I', fw, 0x260 + 14, k_size)
    struct.pack_into('<I', fw, 0x260 + 18, k_size)
    struct.pack_into('<I', fw, 0x260 + 22, k_cksum)

    fw_cksum = sum(fw[0x0A:]) & 0xFFFF
    struct.pack_into('<H', fw, 8, fw_cksum)
    p.write_bytes(fw)

print(f"kernel_size={k_size} kernel_cksum=0x{k_cksum:08x}")
print(f"dtb_size={d_size} dtb_cksum=0x{d_cksum:08x}")
PY

echo "[5/5] Completed."
echo "Output package: $OUT_DIR"
echo "Updated files:"
echo "  $OUT_DIR/sata.uImage"
echo "  $OUT_DIR/rescue.sata.dtb"
echo "  $OUT_DIR/linux/fwtable0.bin"
echo "  $OUT_DIR/linux/fwtable1.bin"
echo "  $OUT_DIR/linux/16.img"
echo "  $OUT_DIR/linux/10.img"
