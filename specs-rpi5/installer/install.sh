#!/bin/bash
# Gentoo RPi 5 installer (hardened + K8s)
# Must be run as root on the target machine.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root:  sudo $0 $*" >&2
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: $0 /dev/sdX        (SD card)"
    echo "       $0 /dev/nvme0n1    (NVMe via M.2 HAT)"
    echo ""
    echo "WARNING: This will destroy all data on the target device!"
    exit 1
fi

DEV="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE4=$(find "${SCRIPT_DIR}/stage4" -name '*.tar.xz' | head -1)

if [ -z "${STAGE4}" ]; then
    echo "ERROR: No stage4 tarball found in ${SCRIPT_DIR}/stage4/" >&2
    exit 1
fi

if [[ "${DEV}" == *nvme* ]]; then
    PART_PFX="${DEV}p"
else
    PART_PFX="${DEV}"
fi

echo "Target device: ${DEV}"
echo "Stage4:        ${STAGE4}"
read -rp "This will ERASE ${DEV}. Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

echo "==> Partitioning ${DEV}..."
parted -s "${DEV}" mklabel msdos
parted -s "${DEV}" mkpart primary fat32 1MiB 512MiB
parted -s "${DEV}" set 1 boot on
parted -s "${DEV}" mkpart primary ext4 512MiB 100%

echo "==> Formatting..."
mkfs.vfat -F 32 "${PART_PFX}1"
mkfs.ext4 -F "${PART_PFX}2"

echo "==> Mounting and extracting..."
mkdir -p /mnt/{rpi-boot,rpi-root}
mount "${PART_PFX}2" /mnt/rpi-root
mount "${PART_PFX}1" /mnt/rpi-boot

tar -C /mnt/rpi-root --xattrs-include='*.*' -xJf "${STAGE4}" 2>/dev/null || \
tar -C /mnt/rpi-root -xJf "${STAGE4}"

mv /mnt/rpi-root/boot/* /mnt/rpi-boot/

if [[ "${DEV}" == *nvme* ]]; then
    sed -i 's|/dev/mmcblk0p|/dev/nvme0n1p|g' /mnt/rpi-root/etc/fstab
    sed -i 's|root=/dev/mmcblk0p2|root=/dev/nvme0n1p2|' /mnt/rpi-boot/cmdline.txt
fi

sync
umount /mnt/rpi-boot /mnt/rpi-root
echo ""
echo "==> Done. Insert into RPi 5 and boot."
echo "    SSH: key-only (add pubkey to ~/.ssh/authorized_keys)"
echo "    Init cluster: kubeadm init --config /etc/kubernetes/kubeadm-config.yaml"
