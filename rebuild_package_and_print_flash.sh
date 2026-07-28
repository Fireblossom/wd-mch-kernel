#!/usr/bin/env bash
set -euo pipefail

# Build a WD My Cloud Home kernel and create a self-consistent flashing
# package. The raw Linux Image is never copied directly: this script applies
# the RTD1295 header values, pads the Image and DTB, and updates fw_table.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_VERSION="6.18.40"
RELEASE_NAME="r2-rc1"
ARCH="${ARCH:-arm64}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}"
BUILD_DIR=""
OUTPUT_DIR=""
BASE_FW=""

usage() {
	cat <<'EOF'
Usage:
  ./rebuild_package_and_print_flash.sh [options]

Options:
  --kernel-version VERSION  Kernel source directory suffix (default: 6.18.40)
  --release NAME            Package release name (default: r2-rc1)
  --build-dir DIR           Out-of-tree build directory
  --output-dir DIR          Package directory
  --base-fw FILE            8192-byte fw_table used as the structural template
  --jobs N                  Parallel build jobs
  -h, --help                Show this help

Environment:
  ARCH, CROSS_COMPILE, JOBS, KBUILD_BUILD_USER and KBUILD_BUILD_HOST are
  honored. SOURCE_DATE_EPOCH defaults to the timestamp of the current commit.

The script builds Image and DTBs, creates all files under flash/, validates
their internal sizes and checksums, and writes a deterministic .tar.gz archive
next to the package directory.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--kernel-version)
			KERNEL_VERSION="$2"
			shift 2
			;;
		--release)
			RELEASE_NAME="$2"
			shift 2
			;;
		--build-dir)
			BUILD_DIR="$2"
			shift 2
			;;
		--output-dir)
			OUTPUT_DIR="$2"
			shift 2
			;;
		--base-fw)
			BASE_FW="$2"
			shift 2
			;;
		--jobs)
			JOBS="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

KERNEL_DIR="$ROOT_DIR/linux-$KERNEL_VERSION"
PACKAGE_NAME="wd-mch-kernel-$KERNEL_VERSION-$RELEASE_NAME"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/linux-$KERNEL_VERSION}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/release/$PACKAGE_NAME}"
BASE_FW="${BASE_FW:-$ROOT_DIR/release/wd-mch-kernel-6.18.40-r2/flash/fw_table.bin}"
FLASH_DIR="$OUTPUT_DIR/flash"
ARCHIVE="$ROOT_DIR/release/$PACKAGE_NAME.tar.gz"
IMAGE_NAME="Image-$KERNEL_VERSION-mch"
SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT_DIR" show -s --format=%ct HEAD)}"
KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-Fireblossom}"
KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-wd-mch-builder}"
SOURCE_CONFIG_BACKUP=""

restore_source_config() {
	if [[ -n "$SOURCE_CONFIG_BACKUP" && -f "$SOURCE_CONFIG_BACKUP" ]]; then
		cp "$SOURCE_CONFIG_BACKUP" "$KERNEL_DIR/.config"
		rm -f "$SOURCE_CONFIG_BACKUP"
	fi
}

trap restore_source_config EXIT

for required in \
	"$KERNEL_DIR/Makefile" \
	"$KERNEL_DIR/.config" \
	"$ROOT_DIR/initramfs/init" \
	"$BASE_FW" \
	"$OUTPUT_DIR/README.md" \
	"$OUTPUT_DIR/SOURCES.md" \
	"$OUTPUT_DIR/docs/FLASHING.md" \
	"$OUTPUT_DIR/docs/RESCUE.md" \
	"$OUTPUT_DIR/tools/mch-boot"
do
	if [[ ! -e "$required" ]]; then
		echo "Required input is missing: $required" >&2
		exit 1
	fi
done

if [[ "$(wc -c < "$BASE_FW")" -ne 8192 ]]; then
	echo "Base fw_table must be exactly 8192 bytes: $BASE_FW" >&2
	exit 1
fi

mkdir -p "$BUILD_DIR" "$FLASH_DIR"
SOURCE_CONFIG_BACKUP="$(mktemp)"
cp "$KERNEL_DIR/.config" "$SOURCE_CONFIG_BACKUP"
cp "$SOURCE_CONFIG_BACKUP" "$BUILD_DIR/.config"

# Linux refuses an O= build when an earlier in-tree build left .config or
# generated headers in the source directory. Keep the repository's tracked
# configuration safe while mrproper removes only those build products.
echo "[0/5] Cleaning in-tree build products"
make -C "$KERNEL_DIR" ARCH="$ARCH" mrproper

"$KERNEL_DIR/scripts/config" \
	--file "$BUILD_DIR/.config" \
	--set-str INITRAMFS_SOURCE "$ROOT_DIR/initramfs"

echo "[1/5] Configuring Linux $KERNEL_VERSION"
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" olddefconfig

echo "[2/5] Building Image and DTBs"
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" -j"$JOBS" \
	KBUILD_BUILD_TIMESTAMP="@$SOURCE_DATE_EPOCH" \
	KBUILD_BUILD_USER="$KBUILD_BUILD_USER" \
	KBUILD_BUILD_HOST="$KBUILD_BUILD_HOST" \
	Image dtbs

RAW_IMAGE="$BUILD_DIR/arch/$ARCH/boot/Image"
RAW_DTB="$BUILD_DIR/arch/$ARCH/boot/dts/realtek/rtd1295-wd-mycloud-home.dtb"

echo "[3/5] Packaging Image, DTB, and fw_table"
python3 - \
	"$RAW_IMAGE" \
	"$RAW_DTB" \
	"$BASE_FW" \
	"$FLASH_DIR/$IMAGE_NAME" \
	"$FLASH_DIR/mch.dtb" \
	"$FLASH_DIR/fw_table.bin" \
	"$FLASH_DIR/BUILD-METADATA.json" \
	"$KERNEL_VERSION" \
	"$RELEASE_NAME" \
	"$SOURCE_COMMIT" \
	"$SOURCE_DATE_EPOCH" <<'PY'
import hashlib
import json
import struct
import sys
from pathlib import Path

(
    raw_image_path,
    raw_dtb_path,
    base_fw_path,
    image_path,
    dtb_path,
    fw_path,
    metadata_path,
    kernel_version,
    release_name,
    source_commit,
    source_date_epoch,
) = sys.argv[1:]

raw_image = Path(raw_image_path).read_bytes()
raw_dtb = Path(raw_dtb_path).read_bytes()
fw = bytearray(Path(base_fw_path).read_bytes())

if len(raw_image) < 64:
    raise SystemExit("raw Image is too small to contain an arm64 header")
if struct.unpack_from("<I", raw_image, 56)[0] != 0x644D5241:
    raise SystemExit("raw Image does not contain the arm64 Image magic")
if len(raw_dtb) < 8 or struct.unpack_from(">I", raw_dtb, 0)[0] != 0xD00DFEED:
    raise SystemExit("DTB does not contain the flattened-device-tree magic")
raw_fdt_totalsize = struct.unpack_from(">I", raw_dtb, 4)[0]
if raw_fdt_totalsize > len(raw_dtb):
    raise SystemExit(
        f"DTB header totalsize is {raw_fdt_totalsize}, larger than the file"
    )
if len(fw) != 8192:
    raise SystemExit("base fw_table is not 8192 bytes")

kernel = bytearray(raw_image)
struct.pack_into("<I", kernel, 0, 0x91005A4D)
struct.pack_into("<Q", kernel, 8, 0x200000)
struct.pack_into("<I", kernel, 60, 0x40)
kernel.extend(b"\0" * (-len(kernel) % 0x1000))

dtb_size = 0x7000
if len(raw_dtb) > dtb_size:
    raise SystemExit(
        f"DTB is {len(raw_dtb)} bytes, larger than the 0x{dtb_size:x}-byte slot"
    )
dtb = bytearray(raw_dtb)
dtb.extend(b"\0" * (dtb_size - len(dtb)))
# U-Boot/libfdt uses the big-endian totalsize field, not the host file size,
# to decide how much room is available for /chosen and other runtime edits.
# Claim the whole 0x7000-byte buffer so the zero padding is usable FDT space.
struct.pack_into(">I", dtb, 4, dtb_size)

kernel_checksum = sum(kernel) & 0xFFFFFFFF
dtb_checksum = sum(dtb) & 0xFFFFFFFF

struct.pack_into("<III", fw, 0x1A0 + 14, len(dtb), len(dtb), dtb_checksum)
struct.pack_into(
    "<III", fw, 0x260 + 14, len(kernel), len(kernel), kernel_checksum
)
struct.pack_into("<H", fw, 8, sum(fw[0x0A:]) & 0xFFFF)

Path(image_path).write_bytes(kernel)
Path(dtb_path).write_bytes(dtb)
Path(fw_path).write_bytes(fw)

def sha256(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()

metadata = {
    "package": f"wd-mch-kernel-{kernel_version}-{release_name}",
    "kernel_version": kernel_version,
    "release": release_name,
    "source_commit": source_commit,
    "source_date_epoch": int(source_date_epoch),
    "image": {
        "file": Path(image_path).name,
        "raw_bytes": len(raw_image),
        "padded_bytes": len(kernel),
        "sata_blocks": len(kernel) // 512,
        "additive_checksum": f"0x{kernel_checksum:08x}",
        "sha256": sha256(kernel),
    },
    "dtb": {
        "file": Path(dtb_path).name,
        "raw_bytes": len(raw_dtb),
        "raw_fdt_totalsize": raw_fdt_totalsize,
        "padded_bytes": len(dtb),
        "padded_fdt_totalsize": struct.unpack_from(">I", dtb, 4)[0],
        "sata_blocks": len(dtb) // 512,
        "additive_checksum": f"0x{dtb_checksum:08x}",
        "sha256": sha256(dtb),
    },
    "fw_table": {
        "file": Path(fw_path).name,
        "bytes": len(fw),
        "checksum": f"0x{struct.unpack_from('<H', fw, 8)[0]:04x}",
        "sha256": sha256(fw),
    },
}
Path(metadata_path).write_text(
    json.dumps(metadata, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

KERNEL_BYTES="$(wc -c < "$FLASH_DIR/$IMAGE_NAME")"
DTB_BYTES="$(wc -c < "$FLASH_DIR/mch.dtb")"
KERNEL_BLOCKS=$((KERNEL_BYTES / 512))
DTB_BLOCKS=$((DTB_BYTES / 512))

printf -v KERNEL_BLOCKS_HEX '0x%x' "$KERNEL_BLOCKS"
printf -v DTB_BLOCKS_HEX '0x%x' "$DTB_BLOCKS"

cat > "$FLASH_DIR/FLASH_COMMANDS.txt" <<EOF
# Generated for $PACKAGE_NAME from source commit $SOURCE_COMMIT
# Confirm every TFTP byte count before running the following sata write.

sata init
env set serverip 192.168.1.100
env set ipaddr 192.168.1.200

tftp 0x04000000 mch.dtb
sata write 0x04000000 0x31000 $DTB_BLOCKS_HEX

tftp 0x04000000 $IMAGE_NAME
sata write 0x04000000 0x33800 $KERNEL_BLOCKS_HEX

tftp 0x04000000 fw_table.bin
sata write 0x04000000 0x22 0x10

env set bootdelay 5
bootr
EOF

(
	cd "$FLASH_DIR"
	sha256sum "$IMAGE_NAME" mch.dtb fw_table.bin > SHA256SUMS
	sha256sum -c SHA256SUMS
)

echo "[4/5] Verifying fw_table fields and padded artifacts"
python3 - \
	"$FLASH_DIR/$IMAGE_NAME" \
	"$FLASH_DIR/mch.dtb" \
	"$FLASH_DIR/fw_table.bin" <<'PY'
import struct
import sys
from pathlib import Path

image = Path(sys.argv[1]).read_bytes()
dtb = Path(sys.argv[2]).read_bytes()
fw = Path(sys.argv[3]).read_bytes()

expected = {
    "DTB stored size": (0x1A0 + 14, len(dtb)),
    "DTB allocated size": (0x1A0 + 18, len(dtb)),
    "DTB checksum": (0x1A0 + 22, sum(dtb) & 0xFFFFFFFF),
    "Image stored size": (0x260 + 14, len(image)),
    "Image allocated size": (0x260 + 18, len(image)),
    "Image checksum": (0x260 + 22, sum(image) & 0xFFFFFFFF),
}
for label, (offset, value) in expected.items():
    actual = struct.unpack_from("<I", fw, offset)[0]
    if actual != value:
        raise SystemExit(f"{label}: fw_table has {actual:#x}, expected {value:#x}")

fw_checksum = struct.unpack_from("<H", fw, 8)[0]
if fw_checksum != sum(fw[0x0A:]) & 0xFFFF:
    raise SystemExit("fw_table checksum is invalid")
if len(image) % 0x1000:
    raise SystemExit("Image is not padded to a 4096-byte boundary")
if len(dtb) != 0x7000:
    raise SystemExit("DTB is not padded to exactly 0x7000 bytes")
if struct.unpack_from(">I", dtb, 4)[0] != len(dtb):
    raise SystemExit("DTB FDT totalsize does not expose the padded runtime space")
if struct.unpack_from("<I", image, 0)[0] != 0x91005A4D:
    raise SystemExit("Image RTD1295 header magic is invalid")
PY

"$BUILD_DIR/scripts/dtc/dtc" \
	-I dtb \
	-O dts \
	-o /dev/null \
	"$FLASH_DIR/mch.dtb"

echo "[5/5] Creating deterministic archive"
tar \
	--sort=name \
	--mtime="@$SOURCE_DATE_EPOCH" \
	--owner=0 \
	--group=0 \
	--numeric-owner \
	-czf "$ARCHIVE" \
	-C "$(dirname "$OUTPUT_DIR")" \
	"$(basename "$OUTPUT_DIR")"

tar -tzf "$ARCHIVE" > "$BUILD_DIR/package-contents.txt"
grep -Fqx "$PACKAGE_NAME/flash/$IMAGE_NAME" "$BUILD_DIR/package-contents.txt"

restore_source_config
trap - EXIT

cat <<EOF

Package:        $PACKAGE_NAME
Source commit:  $SOURCE_COMMIT
Image bytes:    $KERNEL_BYTES ($KERNEL_BLOCKS_HEX SATA blocks)
DTB bytes:      $DTB_BYTES ($DTB_BLOCKS_HEX SATA blocks)
Package dir:    $OUTPUT_DIR
Archive:        $ARCHIVE
Flash commands: $FLASH_DIR/FLASH_COMMANDS.txt
EOF
