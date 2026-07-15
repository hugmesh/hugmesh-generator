#!/bin/bash
# install-frite.sh — install the light desktop to a Libre Computer Le/La Frite's
# ONBOARD storage (eMMC module, or microSD on Le Potato / Sweet Potato).
#
# This is the INSTALLER flavor's payload: boot the LIVE image (off USB), then run
# this to write a PERSISTENT copy to onboard storage. It partitions the target
# (FAT boot + ext4 root), extracts the stage4, lays down extlinux.conf + the
# kernel + the board DTB, and (for La Frite) optionally writes u-boot to SPI NOR.
#
# Two layouts (same split as install-x86.sh):
#   PLAINTEXT (default): FAT boot + ext4 root, unchanged from before this flag existed.
#   ENCRYPTED (--encrypt / an 'encrypt-root' marker next to this script — set by
#     build-frite-stage4.sh --encrypt-root): the FAT boot partition (kernel/DTB/
#     extlinux/the crypt-capable disk-boot initramfs) stays UNENCRYPTED so a single
#     passphrase unlocks at the initramfs, exactly like install-x86.sh's ESP; the
#     root partition becomes a LUKS2 container instead of plain ext4. The
#     passphrase is PROMPTED here on the target (or read from the seeded
#     luks-passphrase file), never baked into any artifact.
#
# Must be run as root on the target (the booted Frite).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root:  sudo $0 $*" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Markers/payloads build-frite-stage4.sh --encrypt-root may drop into this tree.
ENCRYPT_MARKER="${SCRIPT_DIR}/encrypt-root"       # presence => LUKS2 root
SEEDED_PASS_FILE="${SCRIPT_DIR}/luks-passphrase"  # optional unattended passphrase (0600)
ENCRYPT=false; [ -f "${ENCRYPT_MARKER}" ] && ENCRYPT=true
LUKS_PASS=""

if [ $# -lt 1 ]; then
    cat <<USAGE
Usage: $0 [--encrypt|--no-encrypt] [--luks-pass PASS] [--write-uboot-spi] <target-block-device>

  <target-block-device>   the ONBOARD storage to install to, e.g.:
                            /dev/mmcblk0   (eMMC module on La Frite / Le Potato)
                            /dev/mmcblk1   (microSD on Le Potato / Sweet Potato)

  --encrypt / --no-encrypt   Override the baked default (an 'encrypt-root' marker
                              next to this script, from --encrypt-root at build
                              time). LUKS2-encrypts the root partition; the FAT
                              boot partition (kernel/initramfs/extlinux) stays
                              plaintext.
  --luks-pass PASS            Skip the interactive passphrase prompt (also lands
                               in this process's argv — fine on a single-user
                               install session, matches install-x86.sh).

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
        --encrypt)          ENCRYPT=true;         shift   ;;
        --no-encrypt)       ENCRYPT=false;         shift   ;;
        --luks-pass)        LUKS_PASS="$2";        shift 2 ;;
        --write-uboot-spi)  WRITE_UBOOT_SPI=true;  shift   ;;
        -* ) echo "unknown option: $1" >&2; exit 1 ;;
        *  ) DEV="$1"; shift ;;
    esac
done
[ -n "${DEV}" ] || { echo "ERROR: no target device given" >&2; exit 1; }

STAGE4=$(find "${SCRIPT_DIR}/stage4" -name '*.tar.xz' 2>/dev/null | head -1)
BOOT_SRC="${SCRIPT_DIR}/boot"   # kernel Image, dtb/, extlinux/extlinux.conf(, initrd.img if encrypted)

if [ -z "${STAGE4}" ]; then
    echo "ERROR: No stage4 tarball found in ${SCRIPT_DIR}/stage4/" >&2
    exit 1
fi
if ${ENCRYPT} && [ ! -f "${BOOT_SRC}/initrd.img" ]; then
    echo "ERROR: --encrypt requested but ${BOOT_SRC}/initrd.img is missing — this" >&2
    echo "       installer medium was built WITHOUT --encrypt-root, so there is no" >&2
    echo "       crypt-capable disk-boot initramfs to unlock a LUKS root at boot." >&2
    exit 1
fi

# mmcblk / nvme style devices use a 'p' partition infix; plain sdX do not.
case "${DEV}" in
    *mmcblk*|*nvme*) PART_PFX="${DEV}p" ;;
    *)               PART_PFX="${DEV}"  ;;
esac

echo "Target device: ${DEV}"
echo "Stage4:        ${STAGE4}"
echo "Encrypt root (LUKS2): ${ENCRYPT}"
read -rp "This will ERASE ${DEV}. Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

# ── Root-unlock passphrase (encrypted layout only) — prompted here on the
# target, NEVER baked into any artifact (mirrors install-x86.sh). ────────────
if ${ENCRYPT}; then
    command -v cryptsetup >/dev/null || { echo "ERROR: cryptsetup not in the live environment" >&2; exit 1; }
    if [ -z "${LUKS_PASS}" ] && [ -f "${SEEDED_PASS_FILE}" ]; then
        LUKS_PASS="$(cat "${SEEDED_PASS_FILE}")"
        echo "Using the seeded (unattended) LUKS passphrase from the installer tree."
    fi
    if [ -z "${LUKS_PASS}" ]; then
        while :; do
            read -rsp "Enter the SYSTEM ROOT-UNLOCK passphrase (LUKS2, full-disk): " p1; echo
            read -rsp "Confirm passphrase: " p2; echo
            [ -n "${p1}" ] && [ "${p1}" = "${p2}" ] && { LUKS_PASS="${p1}"; break; }
            echo "  Empty or mismatched — try again."
        done
        unset p1 p2
    fi
fi

echo "==> Partitioning ${DEV} (msdos: FAT boot + $(${ENCRYPT} && echo 'LUKS2 root' || echo 'ext4 root'))..."
parted -s "${DEV}" mklabel msdos
parted -s "${DEV}" mkpart primary fat32 1MiB 256MiB
parted -s "${DEV}" set 1 boot on
parted -s "${DEV}" mkpart primary ext4 256MiB 100%
# Let the kernel/udev rescan the new partition table before anything below
# touches the freshly created partition nodes (cryptsetup/mkfs racing a not-yet-
# settled node is a real failure mode on eMMC — mirrors install-x86.sh).
partprobe "${DEV}" 2>/dev/null || true; udevadm settle 2>/dev/null || true; sleep 1

mkdir -p /mnt/frite-boot /mnt/frite-root
if ${ENCRYPT}; then
    echo "==> Creating LUKS2 container on ${PART_PFX}2"
    printf '%s' "${LUKS_PASS}" | cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id \
        --batch-mode "${PART_PFX}2" -
    # Clear a stale 'cryptroot' mapping left by a prior run that was
    # interrupted after open but before the final close (see the matching
    # cleanup at umount time, below) — otherwise this open fails with
    # cryptsetup's native "Device cryptroot already exists."
    cryptsetup close cryptroot 2>/dev/null || true
    printf '%s' "${LUKS_PASS}" | cryptsetup open "${PART_PFX}2" cryptroot -
    ROOT_DEV="/dev/mapper/cryptroot"
else
    ROOT_DEV="${PART_PFX}2"
fi

echo "==> Formatting..."
mkfs.vfat -F 32 -n FRITE_BOOT "${PART_PFX}1"
mkfs.ext4 -F -L FRITE_ROOT "${ROOT_DEV}"

echo "==> Mounting and extracting the light desktop..."
mount "${ROOT_DEV}" /mnt/frite-root
mount "${PART_PFX}1" /mnt/frite-boot

tar -C /mnt/frite-root --xattrs-include='*.*' -xJf "${STAGE4}" 2>/dev/null || \
tar -C /mnt/frite-root -xJf "${STAGE4}"

echo "==> Staging boot files (kernel + DTB + extlinux.conf$(${ENCRYPT} && echo ' + initrd.img')) onto the FAT boot..."
# The booted LIVE image carries the kernel Image, the board DTB tree, the
# extlinux config, and (only when built with --encrypt-root) the crypt-capable
# disk-boot initramfs under ${BOOT_SRC}; copy them to the target's /boot (FAT).
cp -r "${BOOT_SRC}/." /mnt/frite-boot/ 2>/dev/null || true
# If the booted system has them in /boot instead, fall back to that.
[ -f /mnt/frite-boot/extlinux/extlinux.conf ] || cp -r /boot/. /mnt/frite-boot/ 2>/dev/null || true

BOOT_PARTUUID="$(blkid -s PARTUUID -o value "${PART_PFX}1" || true)"
if ${ENCRYPT}; then
    # Re-point root= at the decrypted mapper device + the LUKS UUID that unlocks
    # it — the disk-boot initramfs's dracut crypt module reads rd.luks.uuid= off
    # this exact cmdline. Mirrors install-x86.sh's GRUB_CMDLINE_LINUX rewrite,
    # just as a direct extlinux.conf edit (no bootloader-config-regenerate step
    # exists for extlinux the way grub-mkconfig exists for GRUB).
    LUKS_UUID="$(blkid -s UUID -o value "${PART_PFX}2" || true)"
    if [ -z "${LUKS_UUID}" ]; then
        echo "ERROR: could not determine the LUKS UUID for ${PART_PFX}2 — aborting" >&2
        echo "       before writing an inconsistent boot config." >&2
        exit 1
    fi
    if [ -f /mnt/frite-boot/extlinux/extlinux.conf ]; then
        # rd.luks.name=<uuid>=cryptroot is required alongside rd.luks.uuid=: with
        # no /etc/crypttab baked into the disk-boot initramfs (it's built at image
        # time, before this install exists), dracut's crypt module falls back to
        # naming the mapper 'luks-<uuid>', NOT 'cryptroot' — without this token
        # root=/dev/mapper/cryptroot never resolves and boot drops to the dracut
        # emergency shell.
        sed -i -E "s#root=[^ ]+#root=/dev/mapper/cryptroot rd.luks.uuid=${LUKS_UUID} rd.luks.name=${LUKS_UUID}=cryptroot#" \
            /mnt/frite-boot/extlinux/extlinux.conf
    fi
    # crypttab: unlock 'cryptroot' from the LUKS partition at boot (passphrase
    # prompt via the disk-boot initramfs — no keyfile factor on this platform yet).
    printf 'cryptroot UUID=%s none luks\n' "${LUKS_UUID}" > /mnt/frite-root/etc/crypttab
    chmod 0600 /mnt/frite-root/etc/crypttab
    ROOT_FS_UUID="$(blkid -s UUID -o value "${ROOT_DEV}" || true)"
    [ -n "${BOOT_PARTUUID}" ] && [ -n "${ROOT_FS_UUID}" ] && sed -i -E \
        -e "s#^LABEL=FRITE_BOOT#PARTUUID=${BOOT_PARTUUID}#" \
        -e "s#^LABEL=FRITE_ROOT#UUID=${ROOT_FS_UUID}#" \
        /mnt/frite-root/etc/fstab || true
else
    # Re-point root= at the freshly created ext4 root by PARTUUID so the installed
    # copy boots regardless of where it ends up (eMMC vs SD enumeration order).
    ROOT_PARTUUID="$(blkid -s PARTUUID -o value "${PART_PFX}2" || true)"
    if [ -n "${ROOT_PARTUUID}" ] && [ -f /mnt/frite-boot/extlinux/extlinux.conf ]; then
        sed -i -E "s#root=[^ ]+#root=PARTUUID=${ROOT_PARTUUID}#" \
            /mnt/frite-boot/extlinux/extlinux.conf
        # Rewrite the installed root's fstab to mount by the new labels/PARTUUIDs.
        [ -n "${BOOT_PARTUUID}" ] && sed -i -E \
            -e "s#^LABEL=FRITE_BOOT#PARTUUID=${BOOT_PARTUUID}#" \
            -e "s#^LABEL=FRITE_ROOT#PARTUUID=${ROOT_PARTUUID}#" \
            /mnt/frite-root/etc/fstab || true
    fi
fi

# La Frite: u-boot lives in SPI NOR. Optionally (re)flash it from ./uboot/u-boot.bin
# (only if the operator asked AND the blob + flashcp are present). The blob must
# already be signed with Amlogic's FIP/BL31 to be bootable — see the builder.
if ${WRITE_UBOOT_SPI}; then
    UBOOT_BIN="${SCRIPT_DIR}/uboot/u-boot.bin"
    if [ -f "${UBOOT_BIN}" ] && command -v flashcp >/dev/null 2>&1 && [ -e /dev/mtd0 ]; then
        echo "==> Writing u-boot to SPI NOR (/dev/mtd0)..."
        # Best-effort: the OS install above is already complete, so a flash
        # failure/verify-mismatch here must not abort the script under set -e
        # and skip the umount/cryptsetup-close cleanup below.
        flashcp -v "${UBOOT_BIN}" /dev/mtd0 || echo "    WARNING: u-boot SPI write FAILED — OS install is fine; reflash manually." >&2
    else
        echo "    (skipping SPI u-boot write: need ${UBOOT_BIN} + flashcp + /dev/mtd0)"
    fi
fi

sync
umount /mnt/frite-boot /mnt/frite-root 2>/dev/null || true
# Close the LUKS mapping only AFTER unmounting — cryptsetup close fails (and
# would leave the mapper device dangling) if the filesystem on top is still
# mounted. Suppressed/non-fatal: a transient 'device busy' right after umount
# (dm-crypt holders/udev not yet released) shouldn't abort a successful install.
${ENCRYPT} && { cryptsetup close cryptroot 2>/dev/null || true; }
unset LUKS_PASS
echo ""
echo "==> Done. The light desktop is installed to ${DEV}."
${ENCRYPT} && echo "    Root is LUKS2-encrypted — boot will prompt for the passphrase you set."
echo "    Power off, remove the LIVE USB, and boot from onboard storage."
echo "    SSH is key-only (add a pubkey to ~/.ssh/authorized_keys); the node"
echo "    joins the tailnet on first boot from its KEYS stick (keys-provision)."
