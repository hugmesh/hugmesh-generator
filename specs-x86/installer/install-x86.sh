#!/bin/bash
# Snapdragon x86_64 installer (hardened Gentoo + k8s, optional GPU).
# Run as root from a Linux/Gentoo live environment with this ISO mounted.
# Writes a UEFI GPT disk (ESP + ext4 root, ext4 root LAST so growroot can expand
# it), installs GRUB-EFI --removable, and extracts the stage4 tarball. Mirrors
# the .img builder's layout for parity: PARTUUID-based fstab (from the bundled
# fstab.template), ESP mounted at /boot/efi, kernel/initramfs on the ext4 /boot.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "ERROR: run as root: sudo $0 $*" >&2; exit 1; fi
if [ $# -lt 1 ]; then
    echo "Usage: $0 /dev/sdX | /dev/nvme0n1"
    echo "WARNING: destroys all data on the target device!"
    exit 1
fi

DEV="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE4="$(find "${HERE}/stage4" -name '*.tar.xz' | head -1)"
[ -n "${STAGE4}" ] || { echo "No stage4 tarball in ${HERE}/stage4/" >&2; exit 1; }

if [[ "${DEV}" =~ (nvme|mmcblk) ]]; then P="${DEV}p"; else P="${DEV}"; fi

echo "Target: ${DEV}   Stage4: ${STAGE4}"
read -rp "ERASE ${DEV}? type the device path to confirm: " c
[ "${c}" = "${DEV}" ] || { echo "Aborted."; exit 1; }

echo "==> Partitioning (UEFI GPT: ESP + ext4 root; root LAST for growroot)"
parted -s "${DEV}" mklabel gpt
parted -s "${DEV}" mkpart ESP fat32 1MiB 513MiB
parted -s "${DEV}" set 1 esp on
parted -s "${DEV}" mkpart root ext4 513MiB 100%
partprobe "${DEV}"; sleep 1

echo "==> Formatting"
mkfs.vfat -F 32 -n SNAP_ESP "${P}1"
mkfs.ext4 -L SNAP_ROOT -F "${P}2"

echo "==> Mount + extract (ESP at /boot/efi; root on ext4)"
mkdir -p /mnt/sdhost
mount "${P}2" /mnt/sdhost
mkdir -p /mnt/sdhost/boot/efi
mount "${P}1" /mnt/sdhost/boot/efi
tar -C /mnt/sdhost --xattrs-include='*.*' -xJf "${STAGE4}" 2>/dev/null || \
    tar -C /mnt/sdhost -xJf "${STAGE4}"

# PARTUUID identity, matching the .img builder. Prefer the fstab carried in the
# stage4 (specs-x86/etc/fstab tokens); fall back to the bundled template.
ESP_PARTUUID="$(blkid -s PARTUUID -o value "${P}1")"
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "${P}2")"
if [ -f /mnt/sdhost/etc/fstab ] && grep -q '__ROOT_PARTUUID__' /mnt/sdhost/etc/fstab; then
    : # stage4 already ships the token fstab
elif [ -f "${HERE}/fstab.template" ]; then
    cp "${HERE}/fstab.template" /mnt/sdhost/etc/fstab
fi
sed -i -e "s/__ROOT_PARTUUID__/${ROOT_PARTUUID}/g" -e "s/__ESP_PARTUUID__/${ESP_PARTUUID}/g" \
    /mnt/sdhost/etc/fstab

echo "==> Installing GRUB-EFI (--removable)"
for d in dev proc sys run; do mount --rbind "/$d" "/mnt/sdhost/$d"; done
chroot /mnt/sdhost /bin/bash -c '
  export GRUB_DISABLE_OS_PROBER=true
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable || true
  grub-mkconfig -o /boot/grub/grub.cfg
'
sync
for d in run sys proc dev; do umount -lR "/mnt/sdhost/$d" 2>/dev/null || true; done
umount -R /mnt/sdhost

echo ""
echo "==> Done. Insert a USB KEYS stick and boot. growroot expands the root on"
echo "    first boot; the KEYS stick applies the node role/labels (init or join)."
