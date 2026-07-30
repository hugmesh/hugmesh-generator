#!/bin/bash
# install-orangepi3-lts.sh — install the headless appliance to a microSD card,
# the onboard eMMC, or a USB stick on the Orange Pi 3 LTS (Allwinner H6).
#
# This is the INSTALLER flavor's payload: boot the LIVE image (off a microSD
# card or USB stick, on the ACTUAL Orange Pi 3 LTS board itself), then run
# this to write a PERSISTENT copy. It partitions the target (FAT boot + ext4
# root), extracts the stage4, lays down extlinux.conf + the kernel + the board
# DTB. See the builder's header for the full boot-chain rationale (mainline
# U-Boot with a NATIVE, non-blob DRAM-init driver + distro-boot/extlinux).
#
# ── STORAGE CLASSES (microSD / onboard 8GB eMMC / USB — no NVMe: the H6's
# quirky PCIe is unusable in mainline; see specs-orangepi3-lts/README.md) ──
# UNLIKE the Zero 2 template (microSD-only), this board HAS an onboard 8GB
# eMMC, and the mainline sun50i-h6-orangepi-3.dts enables its mmc2 host — so
# the eMMC is a first-class install target here, Frite-style. The target for
# THIS script can be:
#   * the onboard eMMC (RECOMMENDED where 8GB fits the appliance — the LIVE
#     microSD stays untouched and bootable as a recovery/rescue disk), or
#   * a SECOND microSD card or USB stick (same safer-choice reasoning), or
#   * the SAME microSD/USB device the LIVE image booted from (SUPPORTED — the
#     LIVE system runs entirely from a squashfs+tmpfs-overlay already loaded
#     into RAM by the time you are running this script interactively, so
#     repartitioning/reformatting the boot medium out from under the running
#     live session does not corrupt what's already resident in RAM; this
#     mirrors how many live-CD-style installers "install to the disk you
#     booted from" work in practice). A same-device install is FLAGGED with an
#     extra confirmation below rather than silently allowed, since the failure
#     mode (partitioning the wrong disk, or a system that panics if something
#     unexpectedly touches the squashfs loop device mid-write) is real even if
#     rare — this is UNVERIFIED on actual hardware, see the README.
#
# ON-DEVICE LUKS FORMAT MODEL (mirrors install-frite.sh / install-orangepi5.sh,
# NOT specs-rpi5/installer/install.sh's cross-host model): this script runs
# FROM WITHIN the booted LIVE session, ON THE ACTUAL Orange Pi 3 LTS board
# that will later unlock the encrypted root at every boot. Because format-time
# and unlock-time hardware are the SAME machine here, cryptsetup's argon2id
# PBKDF auto-benchmark is TRUSTWORTHY and deliberately NOT pinned (no
# --pbkdf-memory/--iter-time/--pbkdf-parallel) — pinning would be WRONG here,
# not just unnecessary; it is only correct when format-host != unlock-host
# (see install.sh (RPi5) / build-jetson-stage4.sh for that case). This board's
# distro-boot/extlinux boot chain is architecturally identical to Frite/
# Orange-Pi-5's in this respect (a live+installer USB/SD image genuinely boots
# on the board itself), so the SAME judgment call applies — see
# specs-orangepi3-lts/README.md's LUKS section if this assumption ever needs
# revisiting.
#
# Two layouts (same split as install-frite.sh / install-orangepi5.sh):
#   PLAINTEXT (default): FAT boot + ext4 root, unchanged from before this flag existed.
#   ENCRYPTED (--encrypt / an 'encrypt-root' marker next to this script — set by
#     build-orangepi3-lts-stage4.sh --encrypt-root): the FAT boot partition
#     (kernel/DTB/extlinux/the crypt-capable disk-boot initramfs) stays
#     UNENCRYPTED so a single passphrase unlocks at the initramfs; the root
#     partition becomes a LUKS2 container instead of plain ext4. The passphrase
#     is PROMPTED here on the target (or read from the seeded luks-passphrase
#     file), never baked into any artifact.
#
# Must be run as root on the target (the booted Orange Pi 3 LTS).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root:  sudo $0 $*" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Markers/payloads build-orangepi3-lts-stage4.sh --encrypt-root may drop into this tree.
ENCRYPT_MARKER="${SCRIPT_DIR}/encrypt-root"       # presence => LUKS2 root
SEEDED_PASS_FILE="${SCRIPT_DIR}/luks-passphrase"  # optional unattended passphrase (0600)
ENCRYPT=false; [ -f "${ENCRYPT_MARKER}" ] && ENCRYPT=true
LUKS_PASS=""

if [ $# -lt 1 ]; then
    cat <<USAGE
Usage: $0 [--encrypt|--no-encrypt] [--luks-pass PASS] [--write-uboot-spi] <target-block-device>

  <target-block-device>   the microSD/USB storage to install to, e.g.:
                            /dev/mmcblk0   (the microSD slot)
                            /dev/mmcblk2   (the onboard 8GB eMMC — VERIFY the
                                           index on your board: mmcblk numbering
                                           follows probe order, and no real
                                           hardware has confirmed it here)
                            /dev/sda       (a USB stick, if that's what you're
                                           targeting instead)

                          This board has NO NVMe (the H6's PCIe is unusable in
                          mainline) — microSD, the onboard eMMC, or USB are the
                          persistent storage classes. The target may be the
                          eMMC/a SECOND card/stick (safer — the LIVE medium
                          stays bootable) or the SAME device you booted the
                          LIVE image from (supported; you'll get an extra
                          confirmation prompt — see this script's header).

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

  U-Boot: this board's mainline U-Boot needs NO proprietary blob (a real
  point of difference from Frite/Orange-Pi-5 — see specs-orangepi3-lts/
  README.md), so a from-source U-Boot build is realistic here. If you also
  need to (re)flash U-Boot, pass --write-uboot-spi (writes ./uboot/u-boot.bin
  to /dev/mtd0 IF one exists — mirrors La Frite). NOTE on THIS board the
  mainline DTB enables NO SPI node at all (see the kernel fragment), so
  /dev/mtd0 will not exist on the stock image and the flag degrades to its
  no-op warning path. Orange Pi 3 LTS boot-select configurations read U-Boot
  directly off the microSD/eMMC at a fixed byte offset (commonly 8KiB on
  sunxi boards); this script does NOT attempt that raw-offset write
  (UNVERIFIED here — no real hardware to confirm the exact offset for THIS
  board/U-Boot-version combination — see the README).
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

# mmcblk-style devices use a 'p' partition infix; plain sdX (USB) does not.
case "${DEV}" in
    *mmcblk*) PART_PFX="${DEV}p" ;;
    *)        PART_PFX="${DEV}"  ;;
esac

# ── Same-device-as-boot-medium guard (informational, not blocking — see the
# header). Best-effort: the live medium's own root is a squashfs+overlay, not a
# real block device mount, so there's no single authoritative "what did I boot
# from" query on every possible boot path; this checks the common case (the
# dmsquash-live LiveOS mount) and just warns loudly if it can't tell either way.
LIVE_SRC_DEV=""
LIVE_SRC_DEV="$(findmnt -n -o SOURCE /run/initramfs/live 2>/dev/null || true)"
if [ -n "${LIVE_SRC_DEV}" ] && [[ "${LIVE_SRC_DEV}" == "${DEV}"* ]]; then
    echo "WARNING: ${DEV} looks like the SAME device you booted this LIVE image from." >&2
    echo "         This is supported (the live session already runs from RAM), but a" >&2
    echo "         mistake here leaves you with no boot medium at all. Consider a" >&2
    echo "         second microSD/USB stick instead. See this script's header." >&2
    read -rp "Really install onto the CURRENTLY BOOTED device ${DEV}? [y/N] " same_confirm
    [[ "${same_confirm}" =~ ^[Yy]$ ]] || exit 0
fi

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
# settled node is a real failure mode on microSD — mirrors install-frite.sh /
# install-orangepi5.sh).
partprobe "${DEV}" 2>/dev/null || true; udevadm settle 2>/dev/null || true; sleep 1

mkdir -p /mnt/opiz2-boot /mnt/opiz2-root
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
mkfs.vfat -F 32 -n OPI3L_BOOT "${PART_PFX}1"
mkfs.ext4 -F -L OPI3L_ROOT "${ROOT_DEV}"

echo "==> Mounting and extracting the headless appliance..."
mount "${ROOT_DEV}" /mnt/opiz2-root
mount "${PART_PFX}1" /mnt/opiz2-boot

tar -C /mnt/opiz2-root --xattrs-include='*.*' -xJf "${STAGE4}" 2>/dev/null || \
tar -C /mnt/opiz2-root -xJf "${STAGE4}"

echo "==> Staging boot files (kernel + DTB + extlinux.conf$(${ENCRYPT} && echo ' + initrd.img')) onto the FAT boot..."
# The booted LIVE image carries the kernel Image, the board DTB tree, the
# extlinux config, and (only when built with --encrypt-root) the crypt-capable
# disk-boot initramfs under ${BOOT_SRC}; copy them to the target's /boot (FAT).
cp -r "${BOOT_SRC}/." /mnt/opiz2-boot/ 2>/dev/null || true
# If the booted system has them in /boot instead, fall back to that.
[ -f /mnt/opiz2-boot/extlinux/extlinux.conf ] || cp -r /boot/. /mnt/opiz2-boot/ 2>/dev/null || true

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
    # install-orangepi5.sh / specs-rpi5's install.sh / build-jetson-stage4.sh
    # exactly — this is the FIRST of the two hard-won LUKS2 lessons.
    LUKS_UUID="$(blkid -s UUID -o value "${PART_PFX}2" || true)"
    if [ -z "${LUKS_UUID}" ]; then
        echo "ERROR: could not determine the LUKS UUID for ${PART_PFX}2 — aborting" >&2
        echo "       before writing an inconsistent boot config." >&2
        exit 1
    fi
    if [ -f /mnt/opiz2-boot/extlinux/extlinux.conf ]; then
        sed -i -E "s#root=[^ ]+#root=/dev/mapper/cryptroot rd.luks.uuid=${LUKS_UUID} rd.luks.name=${LUKS_UUID}=cryptroot#" \
            /mnt/opiz2-boot/extlinux/extlinux.conf
    fi
    # crypttab: unlock 'cryptroot' from the LUKS partition at boot (passphrase
    # prompt via the disk-boot initramfs — no keyfile factor on this platform yet).
    printf 'cryptroot UUID=%s none luks\n' "${LUKS_UUID}" > /mnt/opiz2-root/etc/crypttab
    chmod 0600 /mnt/opiz2-root/etc/crypttab
    ROOT_FS_UUID="$(blkid -s UUID -o value "${ROOT_DEV}" || true)"
    [ -n "${BOOT_PARTUUID}" ] && [ -n "${ROOT_FS_UUID}" ] && sed -i -E \
        -e "s#^LABEL=OPI3L_BOOT#PARTUUID=${BOOT_PARTUUID}#" \
        -e "s#^LABEL=OPI3L_ROOT#UUID=${ROOT_FS_UUID}#" \
        /mnt/opiz2-root/etc/fstab || true
else
    # Re-point root= at the freshly created ext4 root by PARTUUID so the
    # installed copy boots regardless of which microSD slot/USB port it ends
    # up on.
    ROOT_PARTUUID="$(blkid -s PARTUUID -o value "${PART_PFX}2" || true)"
    if [ -n "${ROOT_PARTUUID}" ] && [ -f /mnt/opiz2-boot/extlinux/extlinux.conf ]; then
        sed -i -E "s#root=[^ ]+#root=PARTUUID=${ROOT_PARTUUID}#" \
            /mnt/opiz2-boot/extlinux/extlinux.conf
        sed -i -E \
            -e "s#^LABEL=OPI3L_BOOT#PARTUUID=${BOOT_PARTUUID}#" \
            -e "s#^LABEL=OPI3L_ROOT#PARTUUID=${ROOT_PARTUUID}#" \
            /mnt/opiz2-root/etc/fstab || true
    fi
fi

# U-Boot: this board's mainline U-Boot needs NO proprietary DRAM-init blob (a
# real point of difference from Frite/Orange-Pi-5 — see the README), so this is
# a genuine best-effort SPI NOR flash write, not a "you must vendor a blob"
# situation. Optionally (re)flash it from ./uboot/u-boot.bin (only if the
# operator asked AND flashcp + the onboard SPI NOR device node are present).
# UNVERIFIED here: whether THIS board's default boot-select strap reads U-Boot
# from SPI NOR at all vs. reading it directly off the microSD card at a fixed
# byte offset (the more common sunxi convention) — no real hardware to confirm
# either way, see specs-orangepi3-lts/README.md.
if ${WRITE_UBOOT_SPI}; then
    UBOOT_BIN="${SCRIPT_DIR}/uboot/u-boot.bin"
    if [ -f "${UBOOT_BIN}" ] && command -v flashcp >/dev/null 2>&1 && [ -e /dev/mtd0 ]; then
        echo "==> Writing u-boot to SPI NOR (/dev/mtd0)..."
        # Best-effort: the OS install above is already complete, so a flash
        # failure/verify-mismatch here must not abort the script under set -e
        # and skip the umount/cryptsetup-close cleanup below.
        flashcp -v "${UBOOT_BIN}" /dev/mtd0 || echo "    WARNING: u-boot SPI write FAILED — OS install is fine; reflash manually." >&2
    else
        echo "    (skipping U-Boot SPI write: need ${UBOOT_BIN} + flashcp + /dev/mtd0 — if"
        echo "     this board boots U-Boot from the microSD card itself instead, write"
        echo "     u-boot.bin to the target device at the standard sunxi byte offset"
        echo "     [commonly 8KiB] manually — UNVERIFIED here, see"
        echo "     specs-orangepi3-lts/README.md.)"
    fi
fi

sync
umount /mnt/opiz2-boot /mnt/opiz2-root 2>/dev/null || true
# Close the LUKS mapping only AFTER unmounting — cryptsetup close fails (and
# would leave the mapper device dangling) if the filesystem on top is still
# mounted. Suppressed/non-fatal: a transient 'device busy' right after umount
# (dm-crypt holders/udev not yet released) shouldn't abort a successful install.
${ENCRYPT} && { cryptsetup close cryptroot 2>/dev/null || true; }
unset LUKS_PASS
echo ""
echo "==> Done. The headless appliance is installed to ${DEV}."
${ENCRYPT} && echo "    Root is LUKS2-encrypted — boot will prompt for the passphrase you set."
echo "    Power off, remove the LIVE microSD/USB medium if it was a different"
echo "    device, and boot from ${DEV}."
echo "    SSH is key-only (add a pubkey to ~/.ssh/authorized_keys); the node"
echo "    joins the tailnet on first boot from its KEYS stick (keys-provision),"
echo "    or logs in as the local standalone user if built with --standalone."
