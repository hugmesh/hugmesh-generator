#!/bin/bash
# install-orangepi4-lts.sh — install the light desktop to an Orange Pi 4 LTS's
# ONBOARD storage (the 16GB eMMC, or a microSD card).
#
# There is NO NVMe/M.2 install target on this board — unlike the Orange Pi 5
# Plus this installer was forked from. Do not re-add one.
#
# This is the INSTALLER flavor's payload: boot the LIVE image (off USB/SD, on
# the ACTUAL Orange Pi 4 LTS board itself), then run this to write a PERSISTENT
# copy to onboard storage. It partitions the target (FAT boot + ext4 root),
# extracts the stage4, lays down extlinux.conf + the kernel + the board DTB.
# U-Boot itself is NOT written here by default (see --write-uboot-spi) — see
# the builder's header for the full boot-chain rationale. NOTE the RK3399 boot
# chain is BLOB-FREE (mainline U-Boot TPL inits DRAM, mainline TF-A supplies
# BL31), unlike the RK3588 board this was forked from.
#
# ON-DEVICE LUKS FORMAT MODEL (mirrors install-frite.sh, NOT install.sh's RPi5
# model): this script runs FROM WITHIN the booted LIVE session, ON THE ACTUAL
# Orange Pi 4 LTS board that will later unlock the encrypted root at every boot —
# exactly like install-frite.sh/install-x86.sh, and UNLIKE
# specs-rpi5/installer/install.sh (which explicitly runs on a SEPARATE host
# writing an SD card from a USB reader, because the Pi 5 cannot boot that ISO
# itself). Because format-time and unlock-time hardware are the SAME machine
# here, cryptsetup's argon2id PBKDF auto-benchmark is TRUSTWORTHY and
# deliberately NOT pinned (no --pbkdf-memory/--iter-time/--pbkdf-parallel) —
# pinning would be WRONG here, not just unnecessary; it is only correct when
# format-host != unlock-host (see build-rpi5-stage4.sh / build-jetson-stage4.sh
# for that case). If this assumption is ever wrong for a given real-world
# operator workflow (e.g. an operator instead dd's this ISO from a PC onto an
# SD card and never actually live-boots the installer ON the board), the
# auto-benchmark could calibrate to the WRONG hardware — see
# specs-orangepi4-lts/README.md's EXPERIMENTAL caveats.
#
# Two layouts (same split as install-frite.sh / install-x86.sh):
#   PLAINTEXT (default): FAT boot + ext4 root, unchanged from before this flag existed.
#   ENCRYPTED (--encrypt / an 'encrypt-root' marker next to this script — set by
#     build-orangepi4-lts-stage4.sh --encrypt-root): the FAT boot partition (kernel/
#     DTB/extlinux/the crypt-capable disk-boot initramfs) stays UNENCRYPTED so a
#     single passphrase unlocks at the initramfs, exactly like install-frite.sh's
#     boot partition; the root partition becomes a LUKS2 container instead of
#     plain ext4. The passphrase is PROMPTED here on the target (or read from
#     the seeded luks-passphrase file), never baked into any artifact.
#
# Must be run as root on the target (the booted Orange Pi 4 LTS).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root:  sudo $0 $*" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Markers/payloads build-orangepi4-lts-stage4.sh --encrypt-root may drop into this tree.
ENCRYPT_MARKER="${SCRIPT_DIR}/encrypt-root"       # presence => LUKS2 root
SEEDED_PASS_FILE="${SCRIPT_DIR}/luks-passphrase"  # optional unattended passphrase (0600)
ENCRYPT=false; [ -f "${ENCRYPT_MARKER}" ] && ENCRYPT=true
LUKS_PASS=""

if [ $# -lt 1 ]; then
    cat <<USAGE
Usage: $0 [--encrypt|--no-encrypt] [--luks-pass PASS] [--write-uboot-spi] <target-block-device>

  <target-block-device>   the ONBOARD storage to install to, e.g.:
                            /dev/mmcblk0   (onboard 16GB eMMC / microSD)
                            /dev/mmcblk1   (microSD, if eMMC is mmcblk0)
                          NOTE: this board has NO M.2/NVMe slot — there is no
                          /dev/nvme0n1 target here.

  --encrypt / --no-encrypt   Override the baked default (an 'encrypt-root'
                              marker next to this script, from --encrypt-root
                              at build time). LUKS2-encrypts the root
                              partition; the FAT boot partition (kernel/DTB/
                              extlinux/initramfs) stays plaintext.
  --luks-pass PASS            Skip the interactive passphrase prompt (also
                               lands in this process's argv — fine on a
                               single-user install session, matches
                               install-x86.sh/install-frite.sh).

  WARNING: this ERASES all data on the target device.

  U-Boot: this board needs Rockchip's proprietary rkbin DDR-init + TF-A BL31
  blobs to be flashable — mainline U-Boot alone is not (see the builder). If
  you also need to (re)flash U-Boot, pass --write-uboot-spi (writes
  ./uboot/u-boot.bin to the appropriate offset — SPI NOR if present, else the
  target's own boot area per --uboot-defconfig's board convention).
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

# mmcblk style devices use a 'p' partition infix; plain sdX do not. (nvme is
# kept in the pattern purely as harmless defensive matching — this board has
# no NVMe slot.)
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
# target, NEVER baked into any artifact (mirrors install-frite.sh). ────────────
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
# settled node is a real failure mode on eMMC/NVMe — mirrors install-frite.sh).
partprobe "${DEV}" 2>/dev/null || true; udevadm settle 2>/dev/null || true; sleep 1

mkdir -p /mnt/opi4lts-boot /mnt/opi4lts-root
if ${ENCRYPT}; then
    echo "==> Creating LUKS2 container on ${PART_PFX}2"
    # On-device format (see the header note): auto-benchmark is trustworthy
    # here, so — unlike install.sh (RPi5)/build-jetson-stage4.sh — we do NOT
    # pin --pbkdf-memory/--iter-time/--pbkdf-parallel.
    printf '%s' "${LUKS_PASS}" | cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id \
        --batch-mode "${PART_PFX}2" -
    # Clear a stale 'cryptroot' mapping left by a prior run that was
    # interrupted after open but before the final close (mirrors install.sh).
    cryptsetup close cryptroot 2>/dev/null || true
    printf '%s' "${LUKS_PASS}" | cryptsetup open "${PART_PFX}2" cryptroot -
    ROOT_DEV="/dev/mapper/cryptroot"
else
    ROOT_DEV="${PART_PFX}2"
fi

echo "==> Formatting..."
mkfs.vfat -F 32 -n OPI4L_BOOT "${PART_PFX}1"
mkfs.ext4 -F -L OPI4L_ROOT "${ROOT_DEV}"

echo "==> Mounting and extracting the light desktop..."
mount "${ROOT_DEV}" /mnt/opi4lts-root
mount "${PART_PFX}1" /mnt/opi4lts-boot

tar -C /mnt/opi4lts-root --xattrs-include='*.*' -xJf "${STAGE4}" 2>/dev/null || \
tar -C /mnt/opi4lts-root -xJf "${STAGE4}"

echo "==> Staging boot files (kernel + DTB + extlinux.conf$(${ENCRYPT} && echo ' + initrd.img')) onto the FAT boot..."
# The booted LIVE image carries the kernel Image, the board DTB tree, the
# extlinux config, and (only when built with --encrypt-root) the crypt-capable
# disk-boot initramfs under ${BOOT_SRC}; copy them to the target's /boot (FAT).
cp -r "${BOOT_SRC}/." /mnt/opi4lts-boot/ 2>/dev/null || true
# If the booted system has them in /boot instead, fall back to that.
[ -f /mnt/opi4lts-boot/extlinux/extlinux.conf ] || cp -r /boot/. /mnt/opi4lts-boot/ 2>/dev/null || true

BOOT_PARTUUID="$(blkid -s PARTUUID -o value "${PART_PFX}1" || true)"
if ${ENCRYPT}; then
    # Re-point root= at the decrypted mapper device + the LUKS UUID that unlocks
    # it — the disk-boot initramfs's dracut crypt module reads rd.luks.uuid= off
    # this exact cmdline. rd.luks.name=<uuid>=cryptroot is REQUIRED alongside
    # rd.luks.uuid=: with no /etc/crypttab baked into the disk-boot initramfs
    # (it's built at image time, before this install exists), dracut's crypt
    # module falls back to naming the mapper 'luks-<uuid>', NOT 'cryptroot' —
    # without this token root=/dev/mapper/cryptroot never resolves and boot
    # drops to the dracut emergency shell. Mirrors install-frite.sh /
    # specs-rpi5's install.sh / build-jetson-stage4.sh exactly.
    LUKS_UUID="$(blkid -s UUID -o value "${PART_PFX}2" || true)"
    if [ -z "${LUKS_UUID}" ]; then
        echo "ERROR: could not determine the LUKS UUID for ${PART_PFX}2 — aborting" >&2
        echo "       before writing an inconsistent boot config." >&2
        exit 1
    fi
    if [ -f /mnt/opi4lts-boot/extlinux/extlinux.conf ]; then
        sed -i -E "s#root=[^ ]+#root=/dev/mapper/cryptroot rd.luks.uuid=${LUKS_UUID} rd.luks.name=${LUKS_UUID}=cryptroot#" \
            /mnt/opi4lts-boot/extlinux/extlinux.conf
    fi
    # crypttab: unlock 'cryptroot' from the LUKS partition at boot (passphrase
    # prompt via the disk-boot initramfs — no keyfile factor on this platform yet).
    printf 'cryptroot UUID=%s none luks\n' "${LUKS_UUID}" > /mnt/opi4lts-root/etc/crypttab
    chmod 0600 /mnt/opi4lts-root/etc/crypttab
    ROOT_FS_UUID="$(blkid -s UUID -o value "${ROOT_DEV}" || true)"
    [ -n "${BOOT_PARTUUID}" ] && [ -n "${ROOT_FS_UUID}" ] && sed -i -E \
        -e "s#^LABEL=OPI4L_BOOT#PARTUUID=${BOOT_PARTUUID}#" \
        -e "s#^LABEL=OPI4L_ROOT#UUID=${ROOT_FS_UUID}#" \
        /mnt/opi4lts-root/etc/fstab || true
else
    # Re-point root= at the freshly created ext4 root by PARTUUID so the
    # installed copy boots regardless of where it ends up (eMMC/SD
    # enumeration order — the same reasoning matters even more here than on
    # Frite, since the Orange Pi 4 LTS target device could be mmcblk0 or
    # mmcblk1 depending on what the operator installed to).
    ROOT_PARTUUID="$(blkid -s PARTUUID -o value "${PART_PFX}2" || true)"
    if [ -n "${ROOT_PARTUUID}" ] && [ -f /mnt/opi4lts-boot/extlinux/extlinux.conf ]; then
        sed -i -E "s#root=[^ ]+#root=PARTUUID=${ROOT_PARTUUID}#" \
            /mnt/opi4lts-boot/extlinux/extlinux.conf
        sed -i -E \
            -e "s#^LABEL=OPI4L_BOOT#PARTUUID=${BOOT_PARTUUID}#" \
            -e "s#^LABEL=OPI4L_ROOT#PARTUUID=${ROOT_PARTUUID}#" \
            /mnt/opi4lts-root/etc/fstab || true
    fi
fi

# U-Boot: RK3399 needs NO proprietary blob to be flashable (mainline U-Boot TPL
# inits DRAM, mainline TF-A supplies BL31). Optionally (re)flash it from
# ./uboot/u-boot.bin, only if the operator asked AND the image + flashcp are
# present. The Orange Pi 4 LTS is documented as carrying onboard SPI NOR flash,
# so unlike the Orange Pi 5 the /dev/mtd0 path below is plausibly the right one
# here — but the exact device node and offset are NOT hardware-verified, so
# treat --write-uboot-spi as informational/best-effort until a real board
# confirms it.
if ${WRITE_UBOOT_SPI}; then
    UBOOT_BIN="${SCRIPT_DIR}/uboot/u-boot.bin"
    if [ -f "${UBOOT_BIN}" ] && command -v flashcp >/dev/null 2>&1 && [ -e /dev/mtd0 ]; then
        echo "==> Writing u-boot to SPI NOR (/dev/mtd0)..."
        # Best-effort: the OS install above is already complete, so a flash
        # failure/verify-mismatch here must not abort the script under set -e
        # and skip the umount/cryptsetup-close cleanup below.
        flashcp -v "${UBOOT_BIN}" /dev/mtd0 || echo "    WARNING: u-boot SPI write FAILED — OS install is fine; reflash manually." >&2
    else
        echo "    (skipping U-Boot write: need ${UBOOT_BIN} + flashcp + /dev/mtd0 — most"
        echo "     some SKUs boot U-Boot from an SD/eMMC sector offset rather than SPI NOR;"
        echo "     if this board has no SPI NOR, write u-boot.bin to the target device at"
        echo "     the board's documented sector offset instead — UNVERIFIED here, see"
        echo "     specs-orangepi4-lts/README.md.)"
    fi
fi

sync
umount /mnt/opi4lts-boot /mnt/opi4lts-root 2>/dev/null || true
# Close the LUKS mapping only AFTER unmounting — cryptsetup close fails (and
# would leave the mapper device dangling) if the filesystem on top is still
# mounted. Suppressed/non-fatal: a transient 'device busy' right after umount
# (dm-crypt holders/udev not yet released) shouldn't abort a successful install.
${ENCRYPT} && { cryptsetup close cryptroot 2>/dev/null || true; }
unset LUKS_PASS
echo ""
echo "==> Done. The light desktop is installed to ${DEV}."
${ENCRYPT} && echo "    Root is LUKS2-encrypted — boot will prompt for the passphrase you set."
echo "    Power off, remove the LIVE USB/SD, and boot from onboard storage."
echo "    SSH is key-only (add a pubkey to ~/.ssh/authorized_keys); the node"
echo "    joins the tailnet on first boot from its KEYS stick (keys-provision)."
