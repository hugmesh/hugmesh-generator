#!/bin/bash
# Gentoo RPi 5 installer (hardened + K8s)
# Must be run as root on the machine writing the target device (SD card
# reader / NVMe enclosure — the Pi 5 cannot boot this ISO itself, see the
# builder's Phase 6 comment; this is a portable "write to a target block
# device" tool, same shape as install-x86.sh/install-frite.sh).
#
# Two layouts:
#   PLAINTEXT (default): FAT boot + ext4 root, unchanged from before this flag existed.
#   ENCRYPTED (--encrypt / an 'encrypt-root' marker next to this script — set by
#     build-rpi5-stage4.sh --encrypt-root): the FAT boot partition (kernel/DTB/
#     config.txt/the crypt-capable disk-boot initramfs) stays UNENCRYPTED so a
#     single passphrase unlocks at the initramfs; the root partition becomes a
#     LUKS2 container instead of plain ext4. The passphrase is PROMPTED here on
#     the install host (or read from the seeded luks-passphrase file), never
#     baked into any artifact.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root:  sudo $0 $*" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Markers/payloads build-rpi5-stage4.sh --encrypt-root may drop into this tree.
ENCRYPT_MARKER="${SCRIPT_DIR}/encrypt-root"       # presence => LUKS2 root
SEEDED_PASS_FILE="${SCRIPT_DIR}/luks-passphrase"  # optional unattended passphrase (0600)
CLIENT_ROLE_MARKER="${SCRIPT_DIR}/client-role"    # presence => --role desktop image (no k8s stack aboard)
ENCRYPT=false; [ -f "${ENCRYPT_MARKER}" ] && ENCRYPT=true
LUKS_PASS=""

if [ $# -lt 1 ]; then
    cat <<USAGE
Usage: $0 [--encrypt|--no-encrypt] [--luks-pass PASS] /dev/sdX        (SD card)
       $0 [--encrypt|--no-encrypt] [--luks-pass PASS] /dev/nvme0n1    (NVMe via M.2 HAT)

  --encrypt / --no-encrypt   Override the baked default (an 'encrypt-root'
                              marker next to this script, from --encrypt-root
                              at build time). LUKS2-encrypts the root
                              partition; the FAT boot partition (kernel/DTB/
                              config.txt/initramfs) stays plaintext.
  --luks-pass PASS            Skip the interactive passphrase prompt (also
                               lands in this process's argv — fine on a
                               single-user install session).

WARNING: This will destroy all data on the target device!
USAGE
    exit 1
fi

DEV=""
while [ $# -gt 0 ]; do
    case "$1" in
        --encrypt)    ENCRYPT=true;  shift   ;;
        --no-encrypt) ENCRYPT=false; shift   ;;
        --luks-pass)  LUKS_PASS="$2"; shift 2 ;;
        -* ) echo "unknown option: $1" >&2; exit 1 ;;
        *  ) DEV="$1"; shift ;;
    esac
done
[ -n "${DEV}" ] || { echo "ERROR: no target device given" >&2; exit 1; }

STAGE4=$(find "${SCRIPT_DIR}/stage4" -name '*.tar.xz' | head -1)

if [ -z "${STAGE4}" ]; then
    echo "ERROR: No stage4 tarball found in ${SCRIPT_DIR}/stage4/" >&2
    exit 1
fi
if ${ENCRYPT} && [ ! -f "${SCRIPT_DIR}/boot/disk-initrd.img" ]; then
    echo "ERROR: --encrypt requested but ${SCRIPT_DIR}/boot/disk-initrd.img is missing —" >&2
    echo "       this ISO was built WITHOUT --encrypt-root, so there is no crypt-capable" >&2
    echo "       disk-boot initramfs to unlock a LUKS root at boot." >&2
    exit 1
fi

# mmcblk / nvme style devices use a 'p' partition infix; plain sdX do not
# (mirrors install-frite.sh/install-orangepi5.sh/install-orangepi-zero2.sh/
# install-orangepi-zero2w.sh/install-orangepi-zero3.sh/install-orangepi3-lts.sh/
# install-orangepi4-lts.sh —
# a write host with a built-in SD-card slot, e.g. another SBC, enumerates the
# target as /dev/mmcblkN just like eMMC, not /dev/sdX).
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
# install host, NEVER baked into any artifact (mirrors install-frite.sh). ────
if ${ENCRYPT}; then
    command -v cryptsetup >/dev/null || { echo "ERROR: cryptsetup not found on this host" >&2; exit 1; }
    if [ -z "${LUKS_PASS}" ] && [ -f "${SEEDED_PASS_FILE}" ]; then
        LUKS_PASS="$(cat "${SEEDED_PASS_FILE}")"
        echo "Using the seeded (unattended) LUKS passphrase from the installer tree."
        echo "  NOTE: this ISO carries that passphrase in plaintext (0600 is Rock-Ridge"
        echo "  metadata only, not real access control) — treat it as a secret artifact."
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
parted -s "${DEV}" mkpart primary fat32 1MiB 512MiB
parted -s "${DEV}" set 1 boot on
parted -s "${DEV}" mkpart primary ext4 512MiB 100%
# Let the kernel/udev rescan the new partition table before anything below
# touches the freshly created partition nodes (cryptsetup/mkfs racing a not-yet-
# settled node is a real failure mode, esp. on SD-card readers). partprobe is
# best-effort: it can legitimately fail ("unable to inform the kernel", e.g. a
# stale auto-mounted partition on ${DEV}) without meaning the reread failed.
partprobe "${DEV}" 2>/dev/null || true; udevadm settle 2>/dev/null || true; sleep 1

mkdir -p /mnt/{rpi-boot,rpi-root}
if ${ENCRYPT}; then
    echo "==> Creating LUKS2 container on ${PART_PFX}2"
    # UNLIKE install-x86.sh/install-frite.sh (which run ON the hardware that
    # later unlocks the root, so cryptsetup's argon2id auto-benchmark
    # self-calibrates correctly), THIS script runs on a separate host writing
    # the target device (see the header comment) — the Pi 5 itself, which is
    # what actually pays the KDF cost on every future boot, is never the
    # machine running this benchmark. An auto-calibrated cost tuned to a fast
    # multi-core writing host would be needlessly (and unpredictably) slow to
    # unlock on the Pi 5. Pin explicit, bounded cost parameters instead so the
    # LUKS2 header always encodes a cost appropriate for the ACTUAL unlock
    # hardware, independent of whatever machine ran this installer.
    printf '%s' "${LUKS_PASS}" | cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id \
        --pbkdf-memory 262144 --iter-time 2000 --pbkdf-parallel 4 \
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
mkfs.vfat -F 32 "${PART_PFX}1"
mkfs.ext4 -F "${ROOT_DEV}"

echo "==> Mounting and extracting..."
mount "${ROOT_DEV}" /mnt/rpi-root
mount "${PART_PFX}1" /mnt/rpi-boot

tar -C /mnt/rpi-root --xattrs-include='*.*' -xJf "${STAGE4}" 2>/dev/null || \
tar -C /mnt/rpi-root -xJf "${STAGE4}"

mv /mnt/rpi-root/boot/* /mnt/rpi-boot/
# The stage4's own /boot (just moved above) already carries config.txt with
# the initramfs directive baked in AND disk-initrd.img itself when this build
# used --encrypt-root — both are packaged into the stage4 tarball BEFORE it's
# archived (see build-rpi5-stage4.sh's Phase 4), so nothing further to stage
# here. (${SCRIPT_DIR}/boot/disk-initrd.img on the ISO is a reference/inspection
# copy only, checked above to confirm this ISO was actually built encrypt-capable.)

if ! ${ENCRYPT}; then
    # Undo an --encrypt-root bake if --no-encrypt overrode it at install time:
    # strip the disk-boot dracut initramfs directive (mirrors build_img()'s
    # same sed for its always-plaintext .img artifact) and drop the now-unused
    # crypt-capable initramfs so a plaintext install doesn't carry an extra,
    # needless boot stage.
    sed -i -E 's/^initramfs .* followkernel$/# &/' /mnt/rpi-boot/config.txt
    rm -f /mnt/rpi-boot/disk-initrd.img
fi

if [[ "${DEV}" == *nvme* ]]; then
    sed -i 's|/dev/mmcblk0p|/dev/nvme0n1p|g' /mnt/rpi-root/etc/fstab
    sed -i 's|root=/dev/mmcblk0p2|root=/dev/nvme0n1p2|' /mnt/rpi-boot/cmdline.txt
fi

if ${ENCRYPT}; then
    # Re-point root= at the decrypted mapper device + the LUKS UUID/name that
    # unlock it — the disk-boot initramfs's dracut crypt module reads
    # rd.luks.uuid=/rd.luks.name= off this exact cmdline. With NO /etc/crypttab
    # baked into that initramfs (built at image time, before this install
    # exists), dracut's crypt module defaults the mapper name to
    # 'luks-<uuid>' — rd.luks.name=<uuid>=cryptroot is REQUIRED for root= to
    # resolve to /dev/mapper/cryptroot; omitting it leaves the target unbootable.
    LUKS_UUID="$(blkid -s UUID -o value "${PART_PFX}2" || true)"
    if [ -z "${LUKS_UUID}" ]; then
        echo "ERROR: could not determine the LUKS UUID for ${PART_PFX}2 — aborting" >&2
        echo "       before writing an inconsistent boot config." >&2
        exit 1
    fi
    sed -i -E "s#root=[^ ]+#root=/dev/mapper/cryptroot rd.luks.uuid=${LUKS_UUID} rd.luks.name=${LUKS_UUID}=cryptroot#" \
        /mnt/rpi-boot/cmdline.txt
    # crypttab: unlock 'cryptroot' from the LUKS partition at boot (passphrase
    # prompt via the disk-boot initramfs — no keyfile factor on this platform yet).
    printf 'cryptroot UUID=%s none luks\n' "${LUKS_UUID}" > /mnt/rpi-root/etc/crypttab
    chmod 0600 /mnt/rpi-root/etc/crypttab
    # fstab's root line still reads the pre-encryption device-name placeholder
    # (mmcblk0p2, or nvme0n1p2 if the NVMe substitution above already ran) —
    # swap it for the fixed, always-correct mapper path. No blkid/UUID lookup
    # needed: the mapper name is a install-time constant, not partition-specific.
    sed -i -E 's#^/dev/(mmcblk0p2|nvme0n1p2)([[:space:]])#/dev/mapper/cryptroot\2#' /mnt/rpi-root/etc/fstab
fi

sync
umount /mnt/rpi-boot /mnt/rpi-root 2>/dev/null || true
# Close the LUKS mapping only AFTER unmounting — cryptsetup close fails (and
# would leave the mapper device dangling) if the filesystem on top is still
# mounted. Suppressed/non-fatal: a transient 'device busy' right after umount
# (dm-crypt holders/udev not yet released) shouldn't abort a successful install.
${ENCRYPT} && { cryptsetup close cryptroot 2>/dev/null || true; }
unset LUKS_PASS
echo ""
echo "==> Done. Insert into RPi 5 and boot."
${ENCRYPT} && echo "    Root is LUKS2-encrypted — boot will prompt for the passphrase you set."
echo "    SSH: key-only (add pubkey to ~/.ssh/authorized_keys)"
if [ -f "${CLIENT_ROLE_MARKER}" ]; then
    echo "    Log in at the desktop greeter (LightDM) with your local user account"
else
    echo "    Init cluster: kubeadm init --config /etc/kubernetes/kubeadm-config.yaml"
fi
