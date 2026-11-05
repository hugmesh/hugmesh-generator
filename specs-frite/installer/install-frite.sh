#!/bin/bash
# install-frite.sh — install the light desktop to a Libre Computer Le/La Frite's
# ONBOARD storage (eMMC module, or microSD on Le Potato / Sweet Potato).
#
# This is the INSTALLER flavor's payload: boot the LIVE image (off USB), then run
# this to write a PERSISTENT copy to onboard storage. It partitions the target
# (FAT boot + ext4 root), extracts the stage4, lays down extlinux.conf + the
# kernel + the board DTB, and optionally writes u-boot (SPI NOR on La Frite /
# Sweet Potato with --write-uboot-spi; the eMMC/SD user area on Le Potato and
# Sweet Potato with --write-uboot-media).
#
# Two layouts (same split as install-x86.sh):
#   PLAINTEXT (default): FAT boot + ext4 root.
#   ENCRYPTED (--encrypt / an 'encrypt-root' marker next to this script — set by
#     build-frite-stage4.sh --encrypt-root): the FAT boot partition (kernel/DTB/
#     extlinux/the crypt-capable disk-boot initramfs) stays UNENCRYPTED so a single
#     passphrase unlocks at the initramfs, exactly like install-x86.sh's ESP; the
#     root partition becomes a LUKS2 container instead of plain ext4. The
#     passphrase is PROMPTED here on the target (or read from --luks-pass / the
#     seeded luks-passphrase file), never baked into any artifact.
#
# TARGET SELECTION. With no device argument the installer looks for the board's
# eMMC itself: every /sys/block/mmcblk<N> whose device/type is MMC (an SD card
# reports SD). La Frite enables only sd_emmc_c and has no mmc aliases, so its eMMC
# really is mmcblk0; Le Potato / Sweet Potato enable both controllers with no
# aliases, so there the number depends on probe order and the eMMC can be mmcblk1
# — never hardcode it. Exactly one MMC-type disk is required for auto-selection;
# an SD install on the Potatoes is an explicit device argument. Whatever the
# device, it must be a whole disk that is not mounted, not an eMMC hardware boot
# or RPMB partition, and not the medium this live session booted from.
#
# DISK LAYOUT (MBR, one sfdisk write with an EXPLICIT random disk id):
#   sector 1 ..  8 MiB   reserved: the Amlogic GXL boot ROM reads BL2+FIP from the
#                        user area at sector 1 (SD and eMMC alike), so partition 1
#                        starts at 8 MiB and --write-uboot-media refuses a blob that
#                        would not fit under it.
#   p1   8 MiB .. 264 MiB  FAT32, bootable, LABEL FRITE_BOOT (u-boot distro-boot
#                        scans it for /extlinux/extlinux.conf)
#   p2 264 MiB .. end    ext4 LABEL FRITE_ROOT, or a LUKS2 container holding it
# root= and fstab are rewritten to PARTUUID=<diskid>-0N / UUID= and the rewrite
# is READ BACK: a bare kernel (no initramfs) can only resolve root=PARTUUID, and
# an MBR PARTUUID is the disk id, so the id must be non-zero and unique.
#
# Must be run as root on the target (the booted Frite).
set -euo pipefail

# ── Seams. Plain `: ${VAR:=default}` so the test suite can point the installer at
# fixtures (a sysfs tree, a mount root, a user.* xattr instead of security.*) and
# execute it end to end with stubbed block tools instead of grepping its text.
: "${FRITE_SYSFS:=/sys}"                        # /sys/block, /sys/class/block
: "${FRITE_PROC:=/proc}"                        # /proc/swaps, /proc/device-tree
: "${FRITE_MNT:=/mnt}"                          # mount root for frite-boot / frite-root
: "${FRITE_DEV_DIR:=/dev}"                      # where block device nodes live
: "${FRITE_DM_DIR:=/dev/mapper}"                # where an open 'cryptroot' shows up
: "${FRITE_LIVE_MOUNT:=/run/initramfs/live}"    # dmsquash-live's medium mount
: "${FRITE_LABEL_XATTR:=security.selinux}"      # the label attribute the probe reads
: "${FRITE_TEST_ALLOW_FILE_DEV:=0}"             # 1: a regular file may stand in for the disk (TESTS ONLY)

P1_START_MIB=8      # keeps the Amlogic BL2+FIP region (sector 1 ..) clear of p1
P1_END_MIB=264      # 256 MiB FAT boot partition
SECTOR=512

MNT_BOOT="${FRITE_MNT}/frite-boot"
MNT_ROOT="${FRITE_MNT}/frite-root"
MOUNTED_BOOT=false; MOUNTED_ROOT=false; CRYPT_OPEN=false

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

# Every abort below (a failed tar, a missing FDT, an unreadable PARTUUID) used to
# leave /mnt/frite-* mounted and 'cryptroot' open, which is exactly the stale
# state the next run then tripped over. Undo in reverse order, always.
cleanup() {
    local rc=$?
    sync 2>/dev/null || true
    ${MOUNTED_BOOT} && { umount "${MNT_BOOT}" 2>/dev/null || true; }
    ${MOUNTED_ROOT} && { umount "${MNT_ROOT}" 2>/dev/null || true; }
    ${CRYPT_OPEN}   && { cryptsetup close cryptroot 2>/dev/null || true; }
    unset LUKS_PASS
    [ "${rc}" -eq 0 ] || echo "install-frite.sh: aborted (exit ${rc}); nothing further was written." >&2
    return "${rc}"
}
trap cleanup EXIT

usage() {
    cat <<USAGE
Usage: $0 [--yes|--unattended] [--encrypt|--no-encrypt] [--luks-pass PASS]
          [--write-uboot-spi] [--write-uboot-media] [<target-block-device>]

  <target-block-device>   the ONBOARD storage to install to. Omit it and the
                          installer picks the eMMC itself (the one /sys/block
                          mmcblk disk whose device/type is MMC). Examples:
                            /dev/mmcblk0   (eMMC on La Frite; eMMC OR microSD on
                                            Le Potato / Sweet Potato — probe order)
                            /dev/mmcblk1   (the other MMC slot on the Potatoes)
                          Partitions, mmcblkNboot0/boot1/rpmb, mounted disks and
                          the medium this live session booted from are refused.

  --yes / --unattended    No prompts. The LUKS passphrase must then come from
                          --luks-pass or the seeded luks-passphrase file.
  --encrypt / --no-encrypt   Override the baked default (an 'encrypt-root' marker
                             next to this script, from --encrypt-root at build
                             time). LUKS2-encrypts the root partition; the FAT
                             boot partition (kernel/initramfs/extlinux) stays
                             plaintext.
  --luks-pass PASS        Skip the interactive passphrase prompt (also lands in
                          this process's argv — fine on a single-user install
                          session, matches install-x86.sh).
  --write-uboot-spi       La Frite / Sweet Potato: (re)flash ./uboot/u-boot.bin
                          to SPI NOR (/dev/mtd0) after the install.
  --write-uboot-media     Le Potato / Sweet Potato: write ./uboot/u-boot.bin into
                          the TARGET's user area at the Amlogic offset (sector 1),
                          so the eMMC/SD boots on its own without SPI NOR. The
                          blob must be the signed SD/eMMC image for this board.

  WARNING: this ERASES all data on the target device.
USAGE
}

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
UNATTENDED=false
WRITE_UBOOT_SPI=false
WRITE_UBOOT_MEDIA=false
DEV=""
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|--unattended)   UNATTENDED=true;         shift   ;;
        --encrypt)            ENCRYPT=true;            shift   ;;
        --no-encrypt)         ENCRYPT=false;           shift   ;;
        --luks-pass)          [ $# -ge 2 ] || die "--luks-pass needs a value"
                              LUKS_PASS="$2";          shift 2 ;;
        --write-uboot-spi)    WRITE_UBOOT_SPI=true;    shift   ;;
        --write-uboot-media)  WRITE_UBOOT_MEDIA=true;  shift   ;;
        -h|--help)            usage; exit 0 ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)  [ -z "${DEV}" ] || die "more than one target device given: ${DEV} and $1"
            DEV="$1"; shift ;;
    esac
done

STAGE4=$(find "${SCRIPT_DIR}/stage4" -name '*.tar.xz' 2>/dev/null | head -1)
BOOT_SRC="${SCRIPT_DIR}/boot"   # kernel Image, dtb/, extlinux/extlinux.conf(, initrd.img if encrypted)
EXTLINUX_SRC="${BOOT_SRC}/extlinux/extlinux.conf"
UBOOT_BIN="${SCRIPT_DIR}/uboot/u-boot.bin"

[ -n "${STAGE4}" ] || die "No stage4 tarball found in ${SCRIPT_DIR}/stage4/"
[ -f "${EXTLINUX_SRC}" ] || die "No ${EXTLINUX_SRC} — this installer tree has no disk boot config; the installed system could not boot."

# ── The boot tree the target needs, READ FROM the extlinux.conf that u-boot will
# boot: the LINUX image, the FDT (mandatory on Amlogic GXL — the kernel's own DTB,
# see the template) and the INITRD when one is configured. Verified on the
# medium before the disk is touched and again on the target FAT after the copy.
extlinux_path() {   # <KEY> <extlinux.conf> -> the path after the key, stripped of its leading '/'
    awk -v k="$1" '
        $1 == k { sub("^[[:space:]]*" k "[[:space:]]+", ""); sub("^/", ""); print; exit }' "$2"
}
BOOT_LINUX="$(extlinux_path LINUX "${EXTLINUX_SRC}")"
BOOT_FDT="$(extlinux_path FDT "${EXTLINUX_SRC}")"
BOOT_INITRD="$(extlinux_path INITRD "${EXTLINUX_SRC}")"
[ -n "${BOOT_LINUX}" ] || die "${EXTLINUX_SRC} has no LINUX line"
[ -n "${BOOT_FDT}" ]   || die "${EXTLINUX_SRC} has no FDT line — Amlogic GXL needs the board DTB named explicitly"
BOOT_FILES=("extlinux/extlinux.conf" "${BOOT_LINUX}" "${BOOT_FDT}")
if ${ENCRYPT}; then
    # A LUKS root is unlocked by the crypt-capable disk-boot initramfs; the
    # extlinux render names it only when the medium was built with --encrypt-root.
    [ -n "${BOOT_INITRD}" ] || die "--encrypt requested but ${EXTLINUX_SRC} has no INITRD line — this installer medium was built WITHOUT --encrypt-root, so there is no crypt-capable disk-boot initramfs to unlock a LUKS root at boot."
fi
[ -n "${BOOT_INITRD}" ] && BOOT_FILES+=("${BOOT_INITRD}")
require_boot_files() {   # <root> <where> — every file extlinux names must exist under <root>
    local root="$1" where="$2" f missing=""
    for f in "${BOOT_FILES[@]}"; do
        [ -s "${root}/${f}" ] || missing="${missing} ${f}"
    done
    [ -z "${missing}" ] || die "boot file(s) missing ${where}:${missing} — refusing to leave a target that u-boot cannot boot."
}
require_boot_files "${BOOT_SRC}" "from the installer medium (${BOOT_SRC})"

# ── Target detection + refusals ──────────────────────────────────────────────
list_candidates() {
    echo "Block devices seen from this live session:" >&2
    lsblk -dpno NAME,SIZE,TYPE,RM,MODEL 2>/dev/null | sed 's/^/    /' >&2 || true
}
detect_emmc() {   # prints the single MMC-type whole disk, or nothing
    local d n t found=()
    for d in "${FRITE_SYSFS}"/block/mmcblk*; do
        [ -e "${d}" ] || continue
        n="$(basename "${d}")"
        [[ "${n}" =~ ^mmcblk[0-9]+$ ]] || continue          # not boot0/boot1/rpmb
        t="$(cat "${d}/device/type" 2>/dev/null || true)"
        [ "${t}" = "MMC" ] && found+=("${FRITE_DEV_DIR}/${n}")
    done
    case "${#found[@]}" in
        1) printf '%s\n' "${found[0]}" ;;
        0) echo "No eMMC found: no /sys/block/mmcblk* reports device/type MMC (an SD card reports SD)." >&2 ;;
        *) echo "More than one MMC-type disk (${found[*]}) — name the target explicitly." >&2 ;;
    esac
}
live_backing_devices() {   # the device the live medium is mounted from, plus its parent disk
    local src parent
    src="$(findmnt -no SOURCE "${FRITE_LIVE_MOUNT}" 2>/dev/null || true)"
    src="${src%%\[*}"                                   # /dev/sda1[/sub] -> /dev/sda1
    [ -n "${src}" ] || return 0
    printf '%s\n' "${src}"
    parent="$(lsblk -no PKNAME "${src}" 2>/dev/null | head -1 || true)"
    [ -n "${parent}" ] && printf '%s/%s\n' "${FRITE_DEV_DIR}" "${parent}"
    return 0
}
check_target() {   # <dev> — refuse anything that is not a free whole disk
    local dev="$1" name typ mp live
    name="$(basename "${dev}")"
    if [ "${FRITE_TEST_ALLOW_FILE_DEV}" = 1 ]; then
        [ -e "${dev}" ] || die "${dev} does not exist"
    else
        [ -b "${dev}" ] || die "${dev} is not a block device"
    fi
    case "${name}" in
        *boot[0-9]) die "${dev} is an eMMC HARDWARE boot partition (the boot ROM's, not a Linux partition) — install to ${FRITE_DEV_DIR}/${name%boot*}" ;;
        *rpmb)      die "${dev} is the eMMC Replay-Protected Memory Block, not storage — install to ${FRITE_DEV_DIR}/${name%rpmb}" ;;
    esac
    [ -e "${FRITE_SYSFS}/class/block/${name}/partition" ] \
        && die "${dev} is a PARTITION — give the whole disk (e.g. ${FRITE_DEV_DIR}/${name%p[0-9]*}); the installer writes its own partition table"
    typ="$(lsblk -dno TYPE "${dev}" 2>/dev/null | head -1 || true)"
    [ -z "${typ}" ] || [ "${typ}" = "disk" ] || die "${dev} is a ${typ}, not a whole disk"
    while read -r live; do
        [ -n "${live}" ] || continue
        if [ "$(realpath -m "${live}")" = "$(realpath -m "${dev}")" ]; then
            die "${dev} is the medium this live session booted from (${FRITE_LIVE_MOUNT} is on ${live}) — refusing to erase the running installer"
        fi
    done < <(live_backing_devices)
    mp="$(lsblk -no MOUNTPOINTS "${dev}" 2>/dev/null || lsblk -no MOUNTPOINT "${dev}" 2>/dev/null || true)"
    mp="$(printf '%s\n' "${mp}" | awk 'NF {print; exit}')"
    [ -z "${mp}" ] || die "${dev} (or a partition of it) is MOUNTED at ${mp} — refusing to erase a disk in use"
    if awk -v d="${dev}" '$1 ~ "^" d "(p?[0-9]+)?$" {found=1} END {exit !found}' "${FRITE_PROC}/swaps" 2>/dev/null; then
        die "${dev} (or a partition of it) is active SWAP — refusing to erase a disk in use"
    fi
}

if [ -z "${DEV}" ]; then
    DEV="$(detect_emmc)" || true
    if [ -z "${DEV}" ]; then
        list_candidates
        die "no target device given and no single eMMC could be auto-detected — pass the whole-disk device explicitly."
    fi
    echo "Auto-selected the eMMC: ${DEV} (/sys/block/$(basename "${DEV}")/device/type = MMC)"
fi
check_target "${DEV}"

# mmcblk / nvme style devices use a 'p' partition infix; plain sdX do not.
case "${DEV}" in
    *mmcblk*|*nvme*) PART_PFX="${DEV}p" ;;
    *)               PART_PFX="${DEV}"  ;;
esac

# ── u-boot blob for the media write: checked BEFORE the disk is touched ──────
P1_START_BYTES=$((P1_START_MIB * 1024 * 1024))
if ${WRITE_UBOOT_MEDIA}; then
    [ -s "${UBOOT_BIN}" ] || die "--write-uboot-media: ${UBOOT_BIN} is missing (build with --uboot-url to stage the signed board u-boot)"
    UBOOT_SIZE=$(stat -c %s "${UBOOT_BIN}")
    # The blob lands at sector 1 (skip=1 seek=1), so it spans bytes 512 .. size-1
    # of the disk and must end before partition 1 begins.
    [ "${UBOOT_SIZE}" -le "${P1_START_BYTES}" ] \
        || die "--write-uboot-media: ${UBOOT_BIN} is ${UBOOT_SIZE} bytes, but partition 1 starts at ${P1_START_BYTES} (${P1_START_MIB} MiB) — the bootloader would overlap the boot partition. Is this the SD/eMMC image (not the 4 MiB-padded SPI image)?"
    if tr -d '\000' < "${FRITE_PROC}/device-tree/compatible" 2>/dev/null | grep -F 'aml-s805x-ac' >/dev/null; then
        warn "this board identifies as La Frite, whose u-boot normally lives in SPI NOR (--write-uboot-spi); writing the user-area image anyway as asked."
    fi
fi

echo "Target device: ${DEV}"
echo "Stage4:        ${STAGE4}"
echo "Boot files:    ${BOOT_FILES[*]}"
echo "Encrypt root (LUKS2): ${ENCRYPT}"
if ! ${UNATTENDED}; then
    read -rp "This will ERASE ${DEV}. Type the device path to confirm: " confirm
    [ "${confirm}" = "${DEV}" ] || { echo "Aborted."; exit 1; }
fi

# ── Root-unlock passphrase (encrypted layout only) — prompted here on the
# target, NEVER baked into any artifact (mirrors install-x86.sh). ────────────
if ${ENCRYPT}; then
    command -v cryptsetup >/dev/null || die "cryptsetup not in the live environment"
    if [ -z "${LUKS_PASS}" ] && [ -f "${SEEDED_PASS_FILE}" ]; then
        LUKS_PASS="$(cat "${SEEDED_PASS_FILE}")"
        echo "Using the seeded (unattended) LUKS passphrase from the installer tree."
    fi
    if [ -z "${LUKS_PASS}" ] && ${UNATTENDED}; then
        die "unattended encrypted install but no LUKS passphrase: pass --luks-pass or seed ${SEEDED_PASS_FILE} (nothing was written)."
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

# ── Wipe stale state: an interrupted earlier run can leave 'cryptroot' open on
# this very disk, and a reused eMMC carries old LUKS/ext4/FAT signatures that
# blkid would keep reporting next to the new ones. ───────────────────────────
echo "==> Clearing stale signatures on ${DEV} ..."
if [ -e "${FRITE_DM_DIR}/cryptroot" ]; then
    cryptsetup close cryptroot || die "could not close the stale 'cryptroot' mapping — is it still mounted?"
fi
while read -r part; do
    [ -n "${part}" ] && [ "${part}" != "${DEV}" ] || continue
    wipefs -a "${part}" >/dev/null || warn "wipefs ${part} failed (continuing: the table below replaces it)"
done < <(lsblk -lnpo NAME "${DEV}" 2>/dev/null || true)
wipefs -a "${DEV}" >/dev/null || die "wipefs -a ${DEV} failed"

# ── Bootloader into the user area (Le Potato / Sweet Potato) ─────────────────
# The documented Amlogic GXL recipe (u-boot doc/board/amlogic, Armbian meson64):
# the image minus its first sector goes to sector 1, then the first 444 bytes go
# to sector 0 so the BL2 header copy sits in front of the MBR's partition table
# (bytes 446..509). Those 444 bytes OVERLAP the MBR disk id at 440..443, which is
# why the partition table (and its explicit id) is written AFTER this, and the
# table write leaves bytes 0..439 alone (sfdisk only rewrites 440..511).
# ASSUMPTION, not provable in emulation: the boot ROM does not need the blob's
# own bytes 440..443 — in the GXL BL2 images they are zero.
if ${WRITE_UBOOT_MEDIA}; then
    echo "==> Writing u-boot (${UBOOT_SIZE} bytes) to the user area of ${DEV} at sector 1 ..."
    dd if="${UBOOT_BIN}" of="${DEV}" bs=512 skip=1 seek=1 conv=fsync,notrunc status=none \
        || die "u-boot write to ${DEV} (sector 1) failed"
    dd if="${UBOOT_BIN}" of="${DEV}" bs=1 count=444 conv=fsync,notrunc status=none \
        || die "u-boot header write to ${DEV} (sector 0) failed"
fi

# ── Partition table: ONE sfdisk write with an explicit random disk id ────────
mbr_disk_id() {   # the MBR disk id of <dev> as 8 lowercase hex digits (little-endian u32 at 440)
    od -An -tx1 -j440 -N4 "$1" 2>/dev/null | awk '{printf "%s%s%s%s\n", $4, $3, $2, $1}'
}
DISK_ID=""
while [ -z "${DISK_ID}" ] || [ "${DISK_ID}" = "00000000" ]; do
    DISK_ID="$(od -An -tx1 -N4 /dev/urandom | awk '{printf "%s%s%s%s\n", $1, $2, $3, $4}')"
done
echo "==> Partitioning ${DEV} (msdos, id 0x${DISK_ID}: FAT boot + $(${ENCRYPT} && echo 'LUKS2 root' || echo 'ext4 root'))..."
P1_START_S=$((P1_START_BYTES / SECTOR))
P1_SIZE_S=$(((P1_END_MIB - P1_START_MIB) * 1024 * 1024 / SECTOR))
P2_START_S=$((P1_START_S + P1_SIZE_S))
printf 'label: dos\nlabel-id: 0x%s\nunit: sectors\nstart=%s, size=%s, type=c, bootable\nstart=%s, type=83\n' \
    "${DISK_ID}" "${P1_START_S}" "${P1_SIZE_S}" "${P2_START_S}" | sfdisk --quiet --wipe-partitions never "${DEV}" \
    || die "sfdisk failed to write the partition table to ${DEV}"
GOT_ID="$(mbr_disk_id "${DEV}")"
[ "${GOT_ID}" = "${DISK_ID}" ] && [ "${GOT_ID}" != "00000000" ] \
    || die "MBR disk id on ${DEV} reads back as '${GOT_ID:-<unreadable>}', expected ${DISK_ID} — root=PARTUUID would never resolve; aborting."
# Let the kernel/udev rescan the new partition table before anything below
# touches the freshly created partition nodes (cryptsetup/mkfs racing a not-yet-
# settled node is a real failure mode on eMMC — mirrors install-x86.sh).
partprobe "${DEV}" 2>/dev/null || true; udevadm settle 2>/dev/null || true; sleep 1
BOOT_PARTUUID="${DISK_ID}-01"
ROOT_PARTUUID="${DISK_ID}-02"

mkdir -p "${MNT_BOOT}" "${MNT_ROOT}"
if ${ENCRYPT}; then
    echo "==> Creating LUKS2 container on ${PART_PFX}2"
    printf '%s' "${LUKS_PASS}" | cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id \
        --batch-mode "${PART_PFX}2" -
    printf '%s' "${LUKS_PASS}" | cryptsetup open "${PART_PFX}2" cryptroot -
    CRYPT_OPEN=true
    ROOT_DEV="${FRITE_DM_DIR}/cryptroot"
else
    ROOT_DEV="${PART_PFX}2"
fi

echo "==> Formatting..."
mkfs.vfat -F 32 -n FRITE_BOOT "${PART_PFX}1"
mkfs.ext4 -F -L FRITE_ROOT "${ROOT_DEV}"

echo "==> Mounting and extracting the light desktop..."
mount "${ROOT_DEV}" "${MNT_ROOT}"; MOUNTED_ROOT=true
mount "${PART_PFX}1" "${MNT_BOOT}"; MOUNTED_BOOT=true

# ONE tar with xattrs, stderr visible, failure ABORTS (install-x86.sh, #503): the
# old `2>/dev/null || tar -xJf` fallback silently re-extracted WITHOUT xattrs
# (SELinux labels, file capabilities) and hid why.
tar -C "${MNT_ROOT}" --xattrs --xattrs-include='*.*' -xJf "${STAGE4}" \
    || die "extracting ${STAGE4} with its xattrs failed — aborting the install rather than writing a system that lost its labels/capabilities (see tar's output above)."

# ── Label probe. The x86 installer aborts unless /usr/bin/init is init_exec_t;
# the Frite stage4 is not labelled at build time yet, so here an unlabelled tree
# is a RELABEL REQUEST: /.autorelabel on the target (standard semantics —
# provision_selinux consumes it, the enforce gate refuses to flip while it
# stands). Probes: getfattr, then python3, then a tar round-trip that lists the
# attribute names (presence only) — the live medium may lack sys-apps/attr.
label_of() {   # <file> -> the value of ${FRITE_LABEL_XATTR}, or 'PRESENT' (name seen, value unknown), or ''
    local f="$1" v=""
    if command -v getfattr >/dev/null 2>&1; then
        v="$(getfattr -h --absolute-names --only-values -n "${FRITE_LABEL_XATTR}" "${f}" 2>/dev/null | tr -d '\000' || true)"
    fi
    if [ -z "${v}" ] && command -v python3 >/dev/null 2>&1; then
        v="$(python3 -c 'import os,sys
try: print(os.getxattr(sys.argv[1], sys.argv[2], follow_symlinks=False).rstrip(b"\0").decode())
except OSError: pass' "${f}" "${FRITE_LABEL_XATTR}" 2>/dev/null || true)"
    fi
    if [ -z "${v}" ]; then
        # (stderr redirected up front: this is a read probe, not the extract; the
        # selinux label suite counts an xattr tar whose stderr is dropped on the
        # same line as the silent no-xattr extract fallback this script no longer has)
        if tar 2>/dev/null --xattrs --xattrs-include='*.*' -C "$(dirname "${f}")" -cf - "$(basename "${f}")" \
            | tar 2>/dev/null --xattrs -tvvf - | grep -F "${FRITE_LABEL_XATTR}" >/dev/null; then
            v="PRESENT"
        fi
    fi
    printf '%s' "${v}"
}
INIT_LABEL="$(label_of "${MNT_ROOT}/usr/bin/init")"
case "${INIT_LABEL}" in
    *:init_exec_t:*|PRESENT)
        echo "==> SELinux labels present (/usr/bin/init ${INIT_LABEL})" ;;
    *)
        warn "the stage4 carried no SELinux labels (/usr/bin/init: '${INIT_LABEL:-none}') — requesting a relabel on first boot (/.autorelabel on the target)."
        touch "${MNT_ROOT}/.autorelabel" ;;
esac

echo "==> Staging boot files (${BOOT_FILES[*]}) onto the FAT boot..."
# The installer medium carries the kernel Image, the board DTB tree, the
# extlinux config, and (only when built with --encrypt-root) the crypt-capable
# disk-boot initramfs under ${BOOT_SRC}. No fallback to the live /boot: the live
# squashfs is built without boot/dtb and without extlinux, so that copy produced
# a FAT u-boot could not boot from, silently.
cp -r "${BOOT_SRC}/." "${MNT_BOOT}/" || die "copying ${BOOT_SRC} onto the boot partition failed"
require_boot_files "${MNT_BOOT}" "on the target boot partition after the copy"
EXTLINUX_DST="${MNT_BOOT}/extlinux/extlinux.conf"
FSTAB_DST="${MNT_ROOT}/etc/fstab"
[ -f "${FSTAB_DST}" ] || die "${FSTAB_DST} missing from the extracted stage4"

# ── root= and fstab: ALWAYS rewritten, from ids READ BACK off the disk ────────
# blkid is asked with an empty cache (-c /dev/null): the wipe + new table above
# would otherwise be answered from /run/blkid with the previous disk's ids.
read_id() {   # <tag> <dev>
    blkid -c /dev/null -s "$1" -o value "$2" 2>/dev/null || true
}
got="$(read_id PARTUUID "${PART_PFX}1")"
[ "${got}" = "${BOOT_PARTUUID}" ] || die "PARTUUID of ${PART_PFX}1 reads '${got:-<none>}', expected ${BOOT_PARTUUID} (disk id 0x${DISK_ID}) — the kernel did not take the new table; aborting."
got="$(read_id PARTUUID "${PART_PFX}2")"
[ "${got}" = "${ROOT_PARTUUID}" ] || die "PARTUUID of ${PART_PFX}2 reads '${got:-<none>}', expected ${ROOT_PARTUUID} (disk id 0x${DISK_ID}) — the kernel did not take the new table; aborting."
unset got

if ${ENCRYPT}; then
    # Re-point root= at the decrypted mapper device + the LUKS UUID that unlocks
    # it — the disk-boot initramfs's dracut crypt module reads rd.luks.uuid= off
    # this exact cmdline. rd.luks.name=<uuid>=cryptroot is required alongside
    # rd.luks.uuid=: with no /etc/crypttab baked into the disk-boot initramfs (it
    # is built at image time, before this install exists), dracut's crypt module
    # falls back to naming the mapper 'luks-<uuid>', NOT 'cryptroot' — without
    # this token root=/dev/mapper/cryptroot never resolves and boot drops to the
    # dracut emergency shell.
    LUKS_UUID="$(read_id UUID "${PART_PFX}2")"
    [ -n "${LUKS_UUID}" ] || die "could not read the LUKS UUID of ${PART_PFX}2 — aborting before writing an inconsistent boot config."
    ROOT_FS_UUID="$(read_id UUID "${ROOT_DEV}")"
    [ -n "${ROOT_FS_UUID}" ] || die "could not read the filesystem UUID of ${ROOT_DEV} — aborting before writing an inconsistent fstab."
    ROOT_ARG="root=/dev/mapper/cryptroot rd.luks.uuid=${LUKS_UUID} rd.luks.name=${LUKS_UUID}=cryptroot"
    FSTAB_ROOT="UUID=${ROOT_FS_UUID}"
    # crypttab: unlock 'cryptroot' from the LUKS partition at boot (passphrase
    # prompt via the disk-boot initramfs — no keyfile factor on this platform yet).
    printf 'cryptroot UUID=%s none luks\n' "${LUKS_UUID}" > "${MNT_ROOT}/etc/crypttab"
    chmod 0600 "${MNT_ROOT}/etc/crypttab"
else
    # A bare kernel (no initramfs) resolves root=PARTUUID= and nothing else by
    # id, which is why the MBR disk id above is explicit and verified.
    ROOT_ARG="root=PARTUUID=${ROOT_PARTUUID}"
    FSTAB_ROOT="PARTUUID=${ROOT_PARTUUID}"
fi

echo "==> Pointing extlinux.conf at ${ROOT_ARG%% *} and rewriting fstab ..."
grep -E 'root=[^ ]+' "${EXTLINUX_DST}" >/dev/null || die "${EXTLINUX_DST} carries no root= token to rewrite"
sed -i -E "s#root=[^ ]+#${ROOT_ARG}#" "${EXTLINUX_DST}"
grep -F -- "${ROOT_ARG}" "${EXTLINUX_DST}" >/dev/null || die "root= rewrite of ${EXTLINUX_DST} did not take"
grep -E '^LABEL=FRITE_(BOOT|ROOT)[[:space:]]' "${FSTAB_DST}" >/dev/null \
    || die "${FSTAB_DST} has no LABEL=FRITE_BOOT / LABEL=FRITE_ROOT lines to rewrite (unexpected stage4 fstab)"
sed -i -E \
    -e "s#^LABEL=FRITE_BOOT([[:space:]])#PARTUUID=${BOOT_PARTUUID}\\1#" \
    -e "s#^LABEL=FRITE_ROOT([[:space:]])#${FSTAB_ROOT}\\1#" \
    "${FSTAB_DST}"
if grep -E '^LABEL=FRITE_' "${FSTAB_DST}" >/dev/null \
   || ! grep -F -- "PARTUUID=${BOOT_PARTUUID}" "${FSTAB_DST}" >/dev/null \
   || ! grep -F -- "${FSTAB_ROOT}" "${FSTAB_DST}" >/dev/null; then
    die "fstab rewrite of ${FSTAB_DST} did not take (LABEL=FRITE_* left, or the new ids are missing)"
fi

# La Frite / Sweet Potato: u-boot lives in SPI NOR. Optionally (re)flash it from
# ./uboot/u-boot.bin (only if the operator asked AND the blob + flashcp are
# present). The blob must already be signed with Amlogic's FIP/BL31 to be
# bootable — see the builder.
if ${WRITE_UBOOT_SPI}; then
    if [ -f "${UBOOT_BIN}" ] && command -v flashcp >/dev/null 2>&1 && [ -e /dev/mtd0 ]; then
        echo "==> Writing u-boot to SPI NOR (/dev/mtd0)..."
        # Best-effort: the OS install above is already complete, so a flash
        # failure/verify-mismatch here must not abort the script under set -e.
        flashcp -v "${UBOOT_BIN}" /dev/mtd0 || warn "u-boot SPI write FAILED — OS install is fine; reflash manually."
    else
        echo "    (skipping SPI u-boot write: need ${UBOOT_BIN} + flashcp + /dev/mtd0)"
    fi
fi

sync
umount "${MNT_BOOT}"; MOUNTED_BOOT=false
umount "${MNT_ROOT}"; MOUNTED_ROOT=false
# Close the LUKS mapping only AFTER unmounting — cryptsetup close fails (and
# would leave the mapper device dangling) if the filesystem on top is still
# mounted. Non-fatal: a transient 'device busy' right after umount (dm-crypt
# holders/udev not yet released) shouldn't abort a successful install.
if ${CRYPT_OPEN}; then cryptsetup close cryptroot 2>/dev/null || true; CRYPT_OPEN=false; fi
unset LUKS_PASS
echo ""
echo "==> Done. The light desktop is installed to ${DEV} (disk id 0x${DISK_ID}, ${ROOT_ARG%% *})."
${ENCRYPT} && echo "    Root is LUKS2-encrypted — boot will prompt for the passphrase you set."
echo "    Power off, remove the LIVE USB, and boot from onboard storage."
echo "    SSH is key-only (add a pubkey to ~/.ssh/authorized_keys); the node"
echo "    joins the tailnet on first boot from its KEYS stick (keys-provision)."
