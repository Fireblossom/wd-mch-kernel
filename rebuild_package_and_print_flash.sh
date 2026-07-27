#!/usr/bin/env bash
set -euo pipefail

# Rebuild kernel Image, package firmware table, and always print flash commands.
# Example:
#   ./rebuild_package_and_print_flash.sh --version v15 --base-fw fw_table_v14.bin

ROOT_DIR="/home/ubuntu/linux"
KERNEL_DIR="$ROOT_DIR/linux-6.18.2"
DTB_FILE_DEFAULT="rtd1295-wd-mycloud-home-v11-padded.dtb"
SERVER_DEFAULT="ubuntu@100.115.19.12"
MDADM_PACK_DEFAULT="$ROOT_DIR/mdadm-pack.tar.gz"
DEBIAN13_TAR_DEFAULT="$ROOT_DIR/MyCloudHome_Debian13_v6.0/linux/linux.tar.xz"

VERSION=""
BASE_FW=""
DTB_FILE="$DTB_FILE_DEFAULT"
SERVER="$SERVER_DEFAULT"
MDADM_PACK="$MDADM_PACK_DEFAULT"

prepare_initramfs_mdadm() {
	local initramfs_dir="$ROOT_DIR/initramfs"
	local tmp_dir

	if [[ ! -f "$MDADM_PACK" ]]; then
		echo "[warn] mdadm pack not found: $MDADM_PACK (md root assembly may fail)"
		return 0
	fi

	tmp_dir="$(mktemp -d)"
	tar -xzf "$MDADM_PACK" -C "$tmp_dir"

	mkdir -p "$initramfs_dir/sbin" "$initramfs_dir/lib" "$initramfs_dir/lib/aarch64-linux-gnu"
	install -m 0755 "$tmp_dir/mdadm-pack/mdadm" "$initramfs_dir/sbin/mdadm"
	cp -a "$tmp_dir/mdadm-pack/lib/." "$initramfs_dir/lib/"

	if [[ -f "$DEBIAN13_TAR_DEFAULT" ]]; then
		tar -xJf "$DEBIAN13_TAR_DEFAULT" --to-stdout ./usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 > "$initramfs_dir/lib/ld-linux-aarch64.so.1"
		tar -xJf "$DEBIAN13_TAR_DEFAULT" --to-stdout ./usr/lib/aarch64-linux-gnu/libcap.so.2.75 > "$initramfs_dir/lib/aarch64-linux-gnu/libcap.so.2.75"
		tar -xJf "$DEBIAN13_TAR_DEFAULT" --to-stdout ./usr/lib/aarch64-linux-gnu/libudev.so.1.7.10 > "$initramfs_dir/lib/aarch64-linux-gnu/libudev.so.1.7.10"

		chmod 0755 "$initramfs_dir/lib/ld-linux-aarch64.so.1"
		chmod 0644 "$initramfs_dir/lib/aarch64-linux-gnu/libcap.so.2.75" "$initramfs_dir/lib/aarch64-linux-gnu/libudev.so.1.7.10"
		ln -sf libcap.so.2.75 "$initramfs_dir/lib/aarch64-linux-gnu/libcap.so.2"
		ln -sf libudev.so.1.7.10 "$initramfs_dir/lib/aarch64-linux-gnu/libudev.so.1"
	else
		echo "[warn] cannot find loader/lib source: $DEBIAN13_TAR_DEFAULT"
	fi

	rm -rf "$tmp_dir"
	echo "[initramfs] mdadm runtime injected"
}

usage() {
	cat <<'EOF'
Usage:
	rebuild_package_and_print_flash.sh --version vNN --base-fw fw_table_vNN.bin [options]

Required:
	--version NAME        Output tag, e.g. v15
	--base-fw FILE        Base fw table file in /home/ubuntu/linux, e.g. fw_table_v14.bin

Optional:
	--dtb FILE            DTB padded file name in /home/ubuntu/linux
	--server USER@HOST    SCP source host shown in printed commands
	--mdadm-pack FILE     mdadm dependency bundle tar.gz (default: /home/ubuntu/linux/mdadm-pack.tar.gz)

This script always:
1) recompiles Image
2) generates Image-6.18.2-<version>-raw-padded and fw_table_<version>.bin
3) prints Mac download commands and WD flash commands
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version)
			VERSION="$2"
			shift 2
			;;
		--base-fw)
			BASE_FW="$2"
			shift 2
			;;
		--dtb)
			DTB_FILE="$2"
			shift 2
			;;
		--server)
			SERVER="$2"
			shift 2
			;;
		--mdadm-pack)
			MDADM_PACK="$2"
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

if [[ -z "$VERSION" || -z "$BASE_FW" ]]; then
	usage
	exit 1
fi

if [[ ! -f "$ROOT_DIR/$BASE_FW" ]]; then
	echo "Base fw table not found: $ROOT_DIR/$BASE_FW" >&2
	exit 1
fi

if [[ ! -f "$ROOT_DIR/$DTB_FILE" ]]; then
	echo "DTB file not found: $ROOT_DIR/$DTB_FILE" >&2
	exit 1
fi

IMG_OUT="Image-6.18.2-${VERSION}-raw-padded"
FW_OUT="fw_table_${VERSION}.bin"

echo "[1/3] Rebuilding kernel Image..."
prepare_initramfs_mdadm
(cd "$KERNEL_DIR" && ./scripts/kconfig/merge_config.sh .config "$ROOT_DIR/rtd1295_initramfs_fix.config" "$ROOT_DIR/rtd1295_cmdline_fix.config" "$ROOT_DIR/rtd1295_compat32.config" "$ROOT_DIR/rtd1295_mdraid.config" >/dev/null)
make -C "$KERNEL_DIR" ARCH=arm64 -j"$(nproc)" Image

echo "[2/3] Packaging artifacts..."
read -r KERN_BLOCKS DTB_BLOCKS FW_CKSUM KERN_CKSUM DTB_CKSUM <<EOF
$(python3 <<PYEOF
import struct
from pathlib import Path

root = Path("$ROOT_DIR")
img_in = root / "linux-6.18.2/arch/arm64/boot/Image"
img_out = root / "$IMG_OUT"
fw_in = root / "$BASE_FW"
fw_out = root / "$FW_OUT"
dtb = root / "$DTB_FILE"

kernel = bytearray(img_in.read_bytes())
struct.pack_into('<Q', kernel, 8, 0x200000)
struct.pack_into('<I', kernel, 0, 0x91005a4d)
struct.pack_into('<I', kernel, 60, 0x40)

kern_padded = (len(kernel) + 0xFFF) & ~0xFFF
kernel.extend(b'\x00' * (kern_padded - len(kernel)))
img_out.write_bytes(kernel)
kern_cksum = sum(kernel) & 0xFFFFFFFF

dtb_blob = bytearray(dtb.read_bytes())
dtb_padded = len(dtb_blob)
dtb_cksum = sum(dtb_blob) & 0xFFFFFFFF

fw = bytearray(fw_in.read_bytes())
struct.pack_into('<I', fw, 0x1A0 + 14, dtb_padded)
struct.pack_into('<I', fw, 0x1A0 + 18, dtb_padded)
struct.pack_into('<I', fw, 0x1A0 + 22, dtb_cksum)
struct.pack_into('<I', fw, 0x260 + 14, kern_padded)
struct.pack_into('<I', fw, 0x260 + 18, kern_padded)
struct.pack_into('<I', fw, 0x260 + 22, kern_cksum)

fw_cksum = sum(fw[0x0A:]) & 0xFFFF
struct.pack_into('<H', fw, 8, fw_cksum)
fw_out.write_bytes(fw)

print(kern_padded // 512, dtb_padded // 512, f"{fw_cksum:04x}", f"{kern_cksum:08x}", f"{dtb_cksum:08x}")
PYEOF
)
EOF

echo "[3/3] Done"
echo
echo "=== Package Summary ==="
echo "Kernel file : $IMG_OUT"
echo "FW table    : $FW_OUT"
echo "Kernel cksum: 0x$KERN_CKSUM"
echo "DTB cksum   : 0x$DTB_CKSUM"
echo "FW cksum    : 0x$FW_CKSUM"
echo
echo "=== Mac download to TFTP ==="
echo "scp $SERVER:$ROOT_DIR/$FW_OUT ~/"
echo "scp $SERVER:$ROOT_DIR/$IMG_OUT ~/"
echo "sudo cp ~/$FW_OUT ~/$IMG_OUT /private/tftpboot/"
echo
echo "=== WD flash commands (1st stage) ==="
echo "sata init"
echo "env set serverip 192.168.123.191"
echo "env set ipaddr 192.168.123.164"
echo
echo "tftp 0x04000000 $FW_OUT"
echo "sata write 0x04000000 0x22 0x10"
echo
echo "tftp 0x04000000 $IMG_OUT"
printf 'sata write 0x04000000 0x33800 0x%x\n' "$KERN_BLOCKS"
echo
echo "env set bootdelay 5"
echo "bootr"
echo
echo "Then in 2nd stage: booti 0x03000000 - 0x01f00000"
