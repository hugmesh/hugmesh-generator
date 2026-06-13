#!/usr/bin/env bash
# make-keys-usb.sh — write a provisioning KEYS stick for the Gentoo RPi 5 image.
#
# Formats a USB device with a single FAT32 partition labelled "KEYS" and
# copies a keys directory (default: ./keys-template) onto it. The RPi 5
# image's keys-provision service reads this partition at first boot.
#
# Requires root (it partitions and formats a block device). The destructive
# safety (typed-path confirm, child unmount, partition naming, table settle)
# lives in scripts/_disk-lib.sh, shared with flash-disk.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/_disk-lib.sh
source "${SCRIPT_DIR}/_disk-lib.sh"

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

dl_require_root
[ -n "${DEVICE}" ]    || usage 1
dl_is_block "${DEVICE}" || { echo "ERROR: ${DEVICE} is not a block device." >&2; exit 1; }
[ -d "${SRC_DIR}" ]   || { echo "ERROR: keys dir not found: ${SRC_DIR}" >&2; exit 1; }
dl_require_tools parted mkfs.vfat lsblk

# ── Source content sanity-check (BEFORE we destroy the device) ────────
# A keys folder is the deliverable a node provisions from. gen-provision-keys.sh
# can leave a HALF-WRITTEN dir behind on failure (a swallowed upstream error), or
# the operator may point us at the raw keys-template (placeholders intact). Either
# would write a 'Done.' stick that bricks first-boot provisioning. Assert the core
# files are present and real BEFORE formatting; only WARN for join/CA material the
# operator fills in after generation (kubernetes pki ca.crt / tailscale authkey).
assert_keys_source() {
    local d="$1" missing=()
    # provision.json is emitted for EVERY role (pki/worker/mesh-extension).
    [ -f "${d}/provision.json" ] || missing+=("provision.json")
    # break-glass SSH: the generated private key + an authorized_keys (admin on a
    # pki stick, root on a worker stick). Either authorized_keys file satisfies it.
    [ -f "${d}/ssh/admin_ed25519" ] || missing+=("ssh/admin_ed25519 (break-glass private key)")
    if [ ! -f "${d}/ssh/admin.authorized_keys" ] && [ ! -f "${d}/ssh/root.authorized_keys" ]; then
        missing+=("ssh/{admin,root}.authorized_keys (break-glass public key)")
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: keys source ${d} is missing required provisioning files:" >&2
        printf '         - %s\n' "${missing[@]}" >&2
        echo "       (a half-written gen-provision-keys.sh run, or the raw keys-template — refusing to write a non-bootable stick)" >&2
        exit 1
    fi
    # Unresolved REPLACE_WITH_ placeholders in the LIVE deliverable files mean the
    # dir was never finished (the examples/ and *.example* reference files are not
    # consulted by provisioning and legitimately keep placeholders, so skip them).
    local ph
    ph="$(grep -rl 'REPLACE_WITH_' "${d}" 2>/dev/null \
            | grep -v '/examples/' | grep -v '\.example' || true)"
    if [ -n "${ph}" ]; then
        echo "ERROR: keys source ${d} still contains REPLACE_WITH_ placeholders in live files:" >&2
        printf '         %s\n' "${ph}" >&2
        echo "       (re-run gen-provision-keys.sh — do NOT write a placeholder stick)" >&2
        exit 1
    fi
    # Worker/mesh sticks (no users.json) carry cluster-join + CA material the node
    # needs to join the control-plane. The generator only prints 'Add: ...' for
    # these, so a missing one is a loud WARNING, not fatal (operator fills it in).
    if [ ! -f "${d}/users.json" ]; then
        [ -f "${d}/kubernetes/pki/ca.crt" ] || echo "WARNING: worker keys source has no kubernetes/pki/ca.crt (cluster CA join material)" >&2
        [ -f "${d}/tailscale/authkey" ]     || echo "WARNING: worker keys source has no tailscale/authkey (mesh-join material)" >&2
    fi
}
assert_keys_source "${SRC_DIR}"

# Partition naming (sdX1 vs nvme0n1p1 vs mmcblk0p1 vs loopXp1)
PART="$(dl_partdev "${DEVICE}" 1)"

echo "Device : ${DEVICE}"
echo "Keys   : ${SRC_DIR}"
echo "Format : ${DO_FORMAT}   Label: ${LABEL}"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "${DEVICE}" || true
echo
if ${DO_FORMAT}; then
    dl_confirm_destroy "${DEVICE}"
fi

# Unmount anything currently mounted from the device
dl_unmount_children "${DEVICE}"

if ${DO_FORMAT}; then
    echo "==> Partitioning ${DEVICE} (msdos, one FAT32)..."
    parted -s "${DEVICE}" mklabel msdos
    parted -s "${DEVICE}" mkpart primary fat32 1MiB 100%
    parted -s "${DEVICE}" set 1 lba on
    dl_wait_settle "${DEVICE}"
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

# ── Post-write verification: the core files MUST exist on the mounted stick ───
# Catch a truncated copy / FAT write error / silently-empty stick before 'Done.'.
POST_MISSING=()
[ -f "${MNT}/provision.json" ] || POST_MISSING+=("provision.json")
[ -f "${MNT}/ssh/admin_ed25519" ] || POST_MISSING+=("ssh/admin_ed25519")
if [ ! -f "${MNT}/ssh/admin.authorized_keys" ] && [ ! -f "${MNT}/ssh/root.authorized_keys" ]; then
    POST_MISSING+=("ssh/{admin,root}.authorized_keys")
fi
if [ "${#POST_MISSING[@]}" -gt 0 ]; then
    echo "ERROR: stick ${PART} is missing files after the copy:" >&2
    printf '         - %s\n' "${POST_MISSING[@]}" >&2
    echo "       (copy failed / device full / write error — the stick is NOT usable)" >&2
    exit 1
fi

echo "==> Contents:"
# Full tree (no -maxdepth): the deepest payloads — kubernetes/pki/ca.crt etc. —
# are exactly the join/CA material a worker stick must carry; never hide them.
find "${MNT}" -type f | sed "s|${MNT}|KEYS|"
echo
echo "Done. Eject ${DEVICE}, insert into the Pi, and boot."
