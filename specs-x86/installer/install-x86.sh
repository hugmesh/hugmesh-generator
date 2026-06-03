#!/bin/bash
# Snapdragon x86_64 host installer (hardened Gentoo + k8s + GPU).
# Run as root from a Linux/Gentoo live environment with this ISO mounted.
# Writes a GPT disk: EFI System Partition + ext4 root, installs GRUB
# (UEFI + BIOS), and extracts the stage4 tarball.
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

echo "==> Partitioning (GPT: ESP + root)"
parted -s "${DEV}" mklabel gpt
parted -s "${DEV}" mkpart ESP fat32 1MiB 1025MiB
parted -s "${DEV}" set 1 esp on
parted -s "${DEV}" mkpart primary ext4 1025MiB 100%
# BIOS boot partition for legacy GRUB (tiny)
parted -s "${DEV}" mkpart bios 1MiB 2MiB 2>/dev/null || true
partprobe "${DEV}"; sleep 1

echo "==> Formatting"
mkfs.vfat -F 32 "${P}1"
mkfs.ext4 -F "${P}2"

echo "==> Mount + extract"
mkdir -p /mnt/sdhost
mount "${P}2" /mnt/sdhost
mkdir -p /mnt/sdhost/boot
mount "${P}1" /mnt/sdhost/boot
tar -C /mnt/sdhost --xattrs-include='*.*' -xJf "${STAGE4}" 2>/dev/null || \
    tar -C /mnt/sdhost -xJf "${STAGE4}"

ROOT_UUID="$(blkid -s UUID -o value "${P}2")"
cat > /mnt/sdhost/etc/fstab <<EOF
UUID=${ROOT_UUID}  /      ext4  defaults,noatime           0 1
${P}1              /boot  vfat  defaults,noatime,umask=0077 0 2
tmpfs              /tmp   tmpfs defaults,nosuid,nodev,noexec,size=2g 0 0
EOF

echo "==> Installing GRUB (UEFI + BIOS)"
for d in dev proc sys run; do mount --rbind "/$d" "/mnt/sdhost/$d"; done
chroot /mnt/sdhost /bin/bash -c '
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=snapdragon --removable || true
  grub-install --target=i386-pc '"${DEV}"' || true
  grub-mkconfig -o /boot/grub/grub.cfg
'
sync
for d in run sys proc dev; do umount -lR "/mnt/sdhost/$d" 2>/dev/null || true; done
umount -R /mnt/sdhost

echo ""
echo "==> Done. Insert a USB KEYS stick (role=host worker) and boot."
echo "    It will join the pki control-plane and host argocd/games/backend."
