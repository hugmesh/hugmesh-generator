#!/bin/bash
# install-frite.sh — install the light desktop to a Libre Computer Le/La Frite's
# ONBOARD storage (eMMC module, or microSD on Le Potato / Sweet Potato).
#
# This is the INSTALLER flavor's payload: boot the LIVE image (off USB), then run
# this to write a PERSISTENT copy to onboard storage. It partitions the target
# (FAT boot + ext4 root), extracts the stage4, lays down extlinux.conf + the
# kernel + the board DTB, and (for La Frite) optionally writes u-boot to SPI NOR.
#
# Must be run as root on the target (the booted Frite).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root:  sudo $0 $*" >&2
    exit 1
fi

if [ $# -lt 1 ]; then
    cat <<USAGE
Usage: $0 <target-block-device>

  <target-block-device>   the ONBOARD storage to install to, e.g.:
                            /dev/mmcblk0   (eMMC module on La Frite / Le Potato)
                            /dev/mmcblk1   (microSD on Le Potato / Sweet Potato)

  WARNING: this ERASES all data on the target device.

  La Frite note: this board has NO microSD slot. Install to the eMMC module
  (/dev/mmcblk0). u-boot lives in SPI NOR on La Frite; if you also need to
  (re)flash u-boot to SPI, pass --write-uboot-spi (writes ./uboot/u-boot.bin).
USAGE
    exit 1
fi

WRITE_UBOOT_SPI=false
DEV=""
while [ $# -gt 0 ]; do
    case "$1" in
        --write-uboot-spi) WRITE_UBOOT_SPI=true; shift ;;
        -* ) echo "unknown option: $1" >&2; exit 1 ;;
        *  ) DEV="$1"; shift ;;
    esac
done
[ -n "${DEV}" ] || { echo "ERROR: no target device given" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE4=$(find "${SCRIPT_DIR}/stage4" -name '*.tar.xz' 2>/dev/null | head -1)
BOOT_SRC="${SCRIPT_DIR}/boot"   # kernel Image, dtb/, extlinux/extlinux.conf

if [ -z "${STAGE4}" ]; then
    echo "ERROR: No stage4 tarball found in ${SCRIPT_DIR}/stage4/" >&2
    exit 1
fi

# mmcblk / nvme style devices use a 'p' partition infix; plain sdX do not.
case "${DEV}" in
    *mmcblk*|*nvme*) PART_PFX="${DEV}p" ;;
    *)               PART_PFX="${DEV}"  ;;
esac

echo "Target device: ${DEV}"
echo "Stage4:        ${STAGE4}"
read -rp "This will ERASE ${DEV}. Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

echo "==> Partitioning ${DEV} (msdos: FAT boot + ext4 root)..."
parted -s "${DEV}" mklabel msdos
parted -s "${DEV}" mkpart primary fat32 1MiB 256MiB
parted -s "${DEV}" set 1 boot on
parted -s "${DEV}" mkpart primary ext4 256MiB 100%

echo "==> Formatting..."
mkfs.vfat -F 32 -n FRITE_BOOT "${PART_PFX}1"
mkfs.ext4 -F -L FRITE_ROOT "${PART_PFX}2"

echo "==> Mounting and extracting the light desktop..."
mkdir -p /mnt/frite-boot /mnt/frite-root
mount "${PART_PFX}2" /mnt/frite-root
mount "${PART_PFX}1" /mnt/frite-boot

tar -C /mnt/frite-root --xattrs-include='*.*' -xJf "${STAGE4}" 2>/dev/null || \
tar -C /mnt/frite-root -xJf "${STAGE4}"

echo "==> Staging boot files (kernel + DTB + extlinux.conf) onto the FAT boot..."
# The booted LIVE image carries the kernel Image, the board DTB tree and the
# extlinux config under ${BOOT_SRC}; copy them to the target's /boot (FAT).
cp -r "${BOOT_SRC}/." /mnt/frite-boot/ 2>/dev/null || true
# If the booted system has them in /boot instead, fall back to that.
[ -f /mnt/frite-boot/extlinux/extlinux.conf ] || cp -r /boot/. /mnt/frite-boot/ 2>/dev/null || true

# Re-point root= at the freshly created ext4 root by PARTUUID so the installed
# copy boots regardless of where it ends up (eMMC vs SD enumeration order).
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "${PART_PFX}2" || true)"
if [ -n "${ROOT_PARTUUID}" ] && [ -f /mnt/frite-boot/extlinux/extlinux.conf ]; then
    sed -i -E "s#root=[^ ]+#root=PARTUUID=${ROOT_PARTUUID}#" \
        /mnt/frite-boot/extlinux/extlinux.conf
    # Rewrite the installed root's fstab to mount by the new labels/PARTUUIDs.
    BOOT_PARTUUID="$(blkid -s PARTUUID -o value "${PART_PFX}1" || true)"
    [ -n "${BOOT_PARTUUID}" ] && sed -i -E \
        -e "s#^LABEL=FRITE_BOOT#PARTUUID=${BOOT_PARTUUID}#" \
        -e "s#^LABEL=FRITE_ROOT#PARTUUID=${ROOT_PARTUUID}#" \
        /mnt/frite-root/etc/fstab || true
fi

# La Frite: u-boot lives in SPI NOR. Optionally (re)flash it from ./uboot/u-boot.bin
# (only if the operator asked AND the blob + flashcp are present). The blob must
# already be signed with Amlogic's FIP/BL31 to be bootable — see the builder.
if ${WRITE_UBOOT_SPI}; then
    UBOOT_BIN="${SCRIPT_DIR}/uboot/u-boot.bin"
    if [ -f "${UBOOT_BIN}" ] && command -v flashcp >/dev/null 2>&1 && [ -e /dev/mtd0 ]; then
        echo "==> Writing u-boot to SPI NOR (/dev/mtd0)..."
        flashcp -v "${UBOOT_BIN}" /dev/mtd0
    else
        echo "    (skipping SPI u-boot write: need ${UBOOT_BIN} + flashcp + /dev/mtd0)"
    fi
fi

sync
umount /mnt/frite-boot /mnt/frite-root
echo ""
echo "==> Done. The light desktop is installed to ${DEV}."
echo "    Power off, remove the LIVE USB, and boot from onboard storage."
echo "    SSH is key-only (add a pubkey to ~/.ssh/authorized_keys); the node"
echo "    joins the tailnet on first boot from its KEYS stick (keys-provision)."
