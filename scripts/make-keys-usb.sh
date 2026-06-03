#!/usr/bin/env bash
# make-keys-usb.sh — write a provisioning KEYS stick for the Gentoo RPi 5 image.
#
# Formats a USB device with a single FAT32 partition labelled "KEYS" and
# copies a keys directory (default: ./keys-template) onto it. The RPi 5
# image's keys-provision service reads this partition at first boot.
#
# Requires root (it partitions and formats a block device).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEVICE=""
SRC_DIR="${REPO_DIR}/keys-template"
DO_FORMAT=true
LABEL="KEYS"

usage() {
cat <<EOF
Usage: sudo $0 [OPTIONS] /dev/sdX [keys-dir]

  Writes a FAT32 "KEYS" provisioning partition for the Gentoo RPi 5 image.

Arguments:
  /dev/sdX        Target USB device (the WHOLE disk, not a partition).
  keys-dir        Directory to copy onto KEYS. Default: ${SRC_DIR}

Options:
  --no-format     Don't repartition/format; copy onto an existing KEYS
                  partition (the device's first partition).
  --label NAME    Volume label to use/expect. Default: KEYS
  -h, --help      Show this help.

Examples:
  sudo $0 /dev/sda                         # format + copy keys-template
  sudo $0 /dev/sda ./keys-out              # format + copy a generated dir
  sudo $0 --no-format /dev/sda ./keys-out  # update an existing KEYS stick
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-format) DO_FORMAT=false; shift ;;
        --label)     LABEL="$2"; shift 2 ;;
        -h|--help)   usage 0 ;;
        -*)          echo "Unknown option: $1" >&2; usage 1 ;;
        *)
            if [ -z "${DEVICE}" ]; then DEVICE="$1"
            else SRC_DIR="$1"; fi
            shift ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
[ -n "${DEVICE}" ]    || usage 1
[ -b "${DEVICE}" ]    || { echo "ERROR: ${DEVICE} is not a block device." >&2; exit 1; }
[ -d "${SRC_DIR}" ]   || { echo "ERROR: keys dir not found: ${SRC_DIR}" >&2; exit 1; }
for t in parted mkfs.vfat lsblk; do
    command -v "$t" >/dev/null || { echo "ERROR: missing tool: $t (emerge sys-fs/dosfstools sys-block/parted)" >&2; exit 1; }
done

# Partition naming (sdX1 vs nvme0n1p1 vs mmcblk0p1)
if [[ "${DEVICE}" =~ (nvme|mmcblk|loop) ]]; then PART="${DEVICE}p1"; else PART="${DEVICE}1"; fi

echo "Device : ${DEVICE}"
echo "Keys   : ${SRC_DIR}"
echo "Format : ${DO_FORMAT}   Label: ${LABEL}"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "${DEVICE}" || true
echo
if ${DO_FORMAT}; then
    read -rp "This will ERASE all data on ${DEVICE}. Type the device path to confirm: " c
    [ "${c}" = "${DEVICE}" ] || { echo "Aborted."; exit 1; }
fi

# Unmount anything currently mounted from the device
for m in $(lsblk -ln -o MOUNTPOINT "${DEVICE}" | grep -v '^$' || true); do
    umount "${m}" 2>/dev/null || true
done

if ${DO_FORMAT}; then
    echo "==> Partitioning ${DEVICE} (msdos, one FAT32)..."
    parted -s "${DEVICE}" mklabel msdos
    parted -s "${DEVICE}" mkpart primary fat32 1MiB 100%
    parted -s "${DEVICE}" set 1 lba on
    sleep 1; partprobe "${DEVICE}" 2>/dev/null || true; sleep 1
    echo "==> Formatting ${PART} as FAT32 (label ${LABEL})..."
    mkfs.vfat -F 32 -n "${LABEL}" "${PART}"
fi

MNT="$(mktemp -d)"
trap 'umount "${MNT}" 2>/dev/null || true; rmdir "${MNT}" 2>/dev/null || true' EXIT
echo "==> Mounting ${PART}..."
mount "${PART}" "${MNT}"

echo "==> Copying keys..."
cp -rT "${SRC_DIR}" "${MNT}/"
# FAT can't hold unix perms; provisioning re-applies them. Drop READMEs.
find "${MNT}" -name 'README.md' -delete 2>/dev/null || true
sync

echo "==> Contents:"
find "${MNT}" -maxdepth 2 -type f | sed "s|${MNT}|KEYS|"
echo
echo "Done. Eject ${DEVICE}, insert into the Pi, and boot."
