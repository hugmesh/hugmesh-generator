#!/usr/bin/env bash
# flash-disk.sh — flash a built HugMesh OS artifact onto a real disk.
#
# This is the OS-disk flasher (the counterpart to make-keys-usb.sh, which writes
# the small provisioning KEYS stick). It writes a WHOLE-disk OS image:
#
#   • a raw .img  -> dd/cp'd byte-for-byte to the target disk. The .img already
#     carries its own partition table (Pi: msdos boot+root; x86: GPT ESP+root),
#     root is identified by PARTUUID, and growroot expands the root ext4 to fill
#     the disk on first boot. ONE image boots from SD / USB / NVMe unchanged.
#
#   • an .iso     -> dd'd to the disk as installer/live media (opt-in path; the
#     default OS artifact is the .img).
#
# Artifact auto-pick (when --artifact is omitted) globs the work dir for
#   gentoo-*-<role>-*.img   (PREFERRED)
#   gentoo-*-<role>-*.iso   (fallback)
# and, if both exist, prefers the .img. --list shows the candidates and exits.
#
# Safety (typed-path confirm, child unmount, partition naming, settle) is shared
# with make-keys-usb.sh via scripts/_disk-lib.sh.
#
# Agents/CI cannot sudo: arg parsing, artifact auto-detection and --list all work
# WITHOUT root. Only the actual destructive flash requires root (checked late).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/_disk-lib.sh
source "${SCRIPT_DIR}/_disk-lib.sh"
# THE role vocabulary (scripts/_roles-lib.sh) — the same declaration the builders
# read, so this script can never accept a role no builder produces, and can glob for
# an artifact that was built under an OLDER spelling.
# shellcheck source=scripts/_roles-lib.sh
source "${SCRIPT_DIR}/_roles-lib.sh"

# ── Defaults ───────────────────────────────────────────────────────
ROLE="pki"
ARCH="arm64"               # arm64 (RPi5) | amd64/x86 (host)
WORK_DIR=""                # resolved from --arch after parsing if left empty
ARTIFACT=""                # explicit artifact; otherwise auto-picked
WITH_KEYS=""               # optional keys dir -> writes/refreshes a KEYS stick
KEYS_DEV=""                # device for the KEYS stick (must differ from DEVICE)
DEVICE=""
NO_CONFIRM=false
LIST_ONLY=false

# Default work dirs per arch (match the build scripts' defaults).
RPI_WORK_DIR="${REPO_DIR}/rpi5-stage4-build"
X86_WORK_DIR="${REPO_DIR}/x86-host-build"

usage() {
cat <<EOF
Usage: sudo $0 [OPTIONS] /dev/sdX

  Flash a built HugMesh OS artifact (.img preferred, .iso fallback) onto the
  WHOLE target disk. The .img is self-partitioning (PARTUUID root, growroot).

Options:
  --role ROLE        Image role to flash. One of:
                       pki | backend | frontend | backend-gpu | omnibus | edge-ai
                       | generic | desktop
                     Old spellings still work and are normalized at parse time:
                       be=backend, fe=frontend, host/be+gpu/be-gpu/gpu-host=backend-gpu,
                       full=omnibus, edge_ai=edge-ai. Default: ${ROLE}
  --arch ARCH        Target arch: arm64 (RPi5) | x86 (amd64 host). Default: ${ARCH}
                     Selects the default --work-dir if you don't pass one, AND
                     ANCHORS the artifact search — an x86 request can no longer
                     resolve to an arm64 image.
  --work-dir DIR     Dir to search for artifacts.
                       arm64 default: ${RPI_WORK_DIR}
                       x86   default: ${X86_WORK_DIR}
  --artifact FILE    Flash THIS file (.img or .iso); skips auto-pick.
  --with-keys DIR    After flashing, also write a separate FAT32 KEYS stick from
                     DIR (delegates to make-keys-usb.sh). Requires --keys-dev.
  --keys-dev DEV     Device for the --with-keys stick. MUST differ from the OS
                     disk. If omitted, the exact make-keys-usb.sh command is
                     printed instead of guessing a device.
  --no-confirm       Skip the typed-device-path confirmation (CI / scripted).
  --list             List candidate artifacts for the role and exit (no root).
  -h, --help         Show this help.

Arguments:
  /dev/sdX           Target OS disk (the WHOLE disk, not a partition). Not
                     required with --list.

Examples:
  # auto-pick the newest pki .img in the default RPi work dir and flash it
  sudo $0 --role pki /dev/sda

  # x86 host image to NVMe, no prompt
  sudo $0 --arch x86 --role host --no-confirm /dev/nvme0n1

  # explicit artifact
  sudo $0 --artifact /path/to/hugmesh-rpi5-arm64-backend-test-20260610T193045Z.img /dev/sdb

  # just see what would be flashed (works without sudo)
  $0 --role frontend --list
EOF
exit "${1:-0}"
}

# ── Arg parsing (no root needed) ───────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)       ROLE="$2"; shift 2 ;;
        --arch)       ARCH="$2"; shift 2 ;;
        --work-dir|-w) WORK_DIR="$2"; shift 2 ;;
        --artifact)   ARTIFACT="$2"; shift 2 ;;
        --with-keys)  WITH_KEYS="$2"; shift 2 ;;
        --keys-dev)   KEYS_DEV="$2"; shift 2 ;;
        --no-confirm) NO_CONFIRM=true; shift ;;
        --list)       LIST_ONLY=true; shift ;;
        -h|--help)    usage 0 ;;
        --)           shift; break ;;
        -*)           echo "Unknown option: $1" >&2; usage 1 ;;
        *)
            if [ -z "${DEVICE}" ]; then DEVICE="$1"
            else echo "Unexpected extra argument: $1" >&2; usage 1; fi
            shift ;;
    esac
done

# ── Normalize role + arch ──────────────────────────────────────────
# ONE normalization point. The old table here knew five spellings and rejected the
# rest — `--role be+gpu`, `--role edge_ai` and `--role generic` all died on a flasher
# that could not name half the images the builders produce.
ROLE_RAW="${ROLE}"
if ! ROLE="$(hugmesh_role_canonicalize "${ROLE_RAW}")"; then
    dl_die "--role must be a role some builder produces: ${HUGMESH_ROLES_CANONICAL} (got '${ROLE_RAW}')"
fi

case "${ARCH}" in
    arm64|aarch64) ARCH="arm64" ;;
    x86|x86_64|amd64) ARCH="x86" ;;
    *) dl_die "--arch must be arm64 or x86 (got '${ARCH}')" ;;
esac

# Resolve default work dir from arch if not given explicitly.
if [ -z "${WORK_DIR}" ]; then
    case "${ARCH}" in
        arm64) WORK_DIR="${RPI_WORK_DIR}" ;;
        x86)   WORK_DIR="${X86_WORK_DIR}" ;;
    esac
fi

# ── Artifact auto-pick ─────────────────────────────────────────────
# Two things this must get right, both of which it used to get wrong.
#
# 1. THE ARCH ANCHOR. --arch only selected the default work dir; it never filtered
#    the glob. Against a real mixed session dir,
#      flash-disk.sh --role be --arch x86 --list
#    printed "Would flash: hugmesh-rpi5-arm64-backend-…iso" — an arm64 Raspberry Pi
#    image for an x86 backend request, silently, and reachable from the Studio's
#    post-build "Flash to device" button. Every candidate is now required to carry
#    the requested arch token in its name.
# 2. THE OLD SPELLINGS. Images already on disk were named under whatever spelling
#    was canonical when they were built (hugmesh-x86-amd64-be-…, …-host-…). Those
#    files are not renamed — they are already-emitted artifacts — so the search
#    covers the canonical role AND every alias that folds onto it.
#
# Naming conventions matched (newest-mtime-first, role-scoped first):
#   • hugmesh-<platform>-<arch>-<role>-<env>-<stamp>.{img,iso}   builders + QEMU launchers
#   • gentoo-<platform>-<arch>-<role>-k8s-<stamp>.iso            older ISO naming
# kernel/initramfs/squashfs blobs are filtered out (they share .img).
#
# ARCH_GLOBS: the arch tokens that may appear in an artifact name for --arch.
case "${ARCH}" in
    x86)   ARCH_GLOBS=("x86" "amd64") ;;
    arm64) ARCH_GLOBS=("arm64" "aarch64") ;;
esac
# ROLE_GLOBS: canonical first, then every alias of it (hugmesh_role_aliases_of).
read -r -a ROLE_GLOBS <<< "$(hugmesh_role_aliases_of "${ROLE}")"

list_candidates() {
    local kind="$1"   # img | iso
    local pats=()
    local r
    local a
    for r in "${ROLE_GLOBS[@]}"; do
        for a in "${ARCH_GLOBS[@]}"; do
            pats+=("${WORK_DIR}/hugmesh-"*"-${a}-${r}-"*".${kind}")
            pats+=("${WORK_DIR}/gentoo-"*"-${a}-${r}-"*".${kind}")
            # x86 'host'-era names put the brand between platform and role
            # (gentoo-x86-hugmesh-host-*.iso), so allow the role right after arch too.
            pats+=("${WORK_DIR}/hugmesh-"*"-${a}-"*"-${r}-"*".${kind}")
            pats+=("${WORK_DIR}/gentoo-"*"-${a}-"*"-${r}-"*".${kind}")
        done
    done
    # ls -1t gives newest-mtime-first ordering (find can't sort by mtime portably);
    # our build artifacts have safe, glob-stable names.
    # shellcheck disable=SC2012
    ls -1t "${pats[@]}" 2>/dev/null \
        | grep -ivE '/(.*-)?(kernel|initramfs|initrd|squashfs)[^/]*\.'"${kind}"'$' \
        | awk '!seen[$0]++'
}

pick_artifact() {
    local img iso
    img="$(list_candidates img | head -1 || true)"
    if [ -n "${img}" ]; then printf '%s' "${img}"; return 0; fi
    iso="$(list_candidates iso | head -1 || true)"
    if [ -n "${iso}" ]; then printf '%s' "${iso}"; return 0; fi
    return 1
}

if ${LIST_ONLY}; then
    if [ "${ROLE_RAW}" != "${ROLE}" ]; then
        echo "Role     : ${ROLE}   (normalized from '${ROLE_RAW}')"
    else
        echo "Role     : ${ROLE}"
    fi
    echo "Arch     : ${ARCH}"
    echo "Work dir : ${WORK_DIR}"
    if [ ! -d "${WORK_DIR}" ]; then
        echo "(work dir does not exist yet — nothing built?)"
        exit 0
    fi
    echo
    echo "Candidate .img (preferred):"
    list_candidates img | sed 's/^/  /' || true
    [ -n "$(list_candidates img)" ] || echo "  (none)"
    echo
    echo "Candidate .iso (fallback):"
    list_candidates iso | sed 's/^/  /' || true
    [ -n "$(list_candidates iso)" ] || echo "  (none)"
    echo
    if chosen="$(pick_artifact)"; then
        echo "Would flash: ${chosen}"
    else
        echo "Would flash: (no artifact found — build one or pass --artifact)"
    fi
    exit 0
fi

# Resolve the artifact (explicit wins; otherwise auto-pick).
if [ -z "${ARTIFACT}" ]; then
    ARTIFACT="$(pick_artifact || true)"
    [ -n "${ARTIFACT}" ] || dl_die "no hugmesh-*/gentoo-* ${ROLE} .img/.iso in ${WORK_DIR}. Build one, pass --artifact, or check --arch/--role (try: $0 --role ${ROLE} --list)."
fi
[ -f "${ARTIFACT}" ] || dl_die "artifact not found: ${ARTIFACT}"

# Determine flash mode from the extension.
case "${ARTIFACT}" in
    *.img) FLASH_KIND="img" ;;
    *.iso) FLASH_KIND="iso" ;;
    *)     dl_die "artifact must be .img or .iso (got: ${ARTIFACT})" ;;
esac

# ── Device required from here on ───────────────────────────────────
[ -n "${DEVICE}" ] || { echo "ERROR: target /dev/sdX required (or use --list)." >&2; usage 1; }

# ── Root + tools (destructive path) ────────────────────────────────
dl_require_root
dl_require_tools dd sync lsblk partprobe blkid
dl_is_block "${DEVICE}" || dl_die "${DEVICE} is not a block device."

# Refuse to flash onto an obvious partition (e.g. /dev/sda1) — we want the disk.
if [[ "${DEVICE}" =~ [0-9]$ ]] && [[ ! "${DEVICE}" =~ (nvme[0-9]+n[0-9]+|mmcblk[0-9]+|loop[0-9]+)$ ]]; then
    dl_die "${DEVICE} looks like a PARTITION. Pass the WHOLE disk (e.g. /dev/sda, /dev/nvme0n1)."
fi

ART_SIZE="$(stat -c '%s' "${ARTIFACT}" 2>/dev/null || echo 0)"
DEV_SIZE="$(blockdev --getsize64 "${DEVICE}" 2>/dev/null || echo 0)"
ART_H="$(numfmt --to=iec "${ART_SIZE}" 2>/dev/null || echo "${ART_SIZE}B")"
DEV_H="$(numfmt --to=iec "${DEV_SIZE}" 2>/dev/null || echo "${DEV_SIZE}B")"

dl_info "Role     : ${ROLE} (${ARCH})"
dl_info "Artifact : ${ARTIFACT} [${FLASH_KIND}, ${ART_H}]"
dl_info "Target   : ${DEVICE} [${DEV_H}]"
[ -n "${WITH_KEYS}" ] && dl_info "With keys: ${WITH_KEYS}"

# Sanity: artifact must fit on the disk.
if [ "${ART_SIZE}" -gt 0 ] && [ "${DEV_SIZE}" -gt 0 ] && [ "${ART_SIZE}" -gt "${DEV_SIZE}" ]; then
    dl_die "artifact (${ART_H}) is LARGER than ${DEVICE} (${DEV_H}) — wrong disk?"
fi

# ── Confirm + unmount ──────────────────────────────────────────────
${NO_CONFIRM} && export DL_NO_CONFIRM=1
dl_confirm_destroy "${DEVICE}"
dl_step "Unmounting any mounted partitions on ${DEVICE}"
dl_unmount_children "${DEVICE}"

# ── Flash ──────────────────────────────────────────────────────────
# Both .img and .iso are whole-device raw writes; dd with a large block size and
# progress, then sync + settle so the new partition table is visible.
dl_step "Writing ${FLASH_KIND} to ${DEVICE} (this can take a while)"
if dd if="${ARTIFACT}" of="${DEVICE}" bs=4M conv=fsync oflag=direct status=progress 2>&1; then
    :
else
    # oflag=direct can be unsupported on some targets (e.g. loop); retry without.
    dl_warn "direct I/O write failed; retrying buffered"
    dd if="${ARTIFACT}" of="${DEVICE}" bs=4M conv=fsync status=progress
fi
sync
dl_wait_settle "${DEVICE}"

dl_info "Flash complete. Partition table now on ${DEVICE}:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTUUID "${DEVICE}" 2>/dev/null || true

# ── Optional KEYS stick ────────────────────────────────────────────
# make-keys-usb.sh's signature is `/dev/sdX [keys-dir]`, so we always pass the
# device FIRST then the dir — never just the dir (which it would read as a
# device). A KEYS device is required and MUST differ from the OS disk.
if [ -n "${WITH_KEYS}" ]; then
    [ -d "${WITH_KEYS}" ] || dl_die "--with-keys dir not found: ${WITH_KEYS}"
    if [ -z "${KEYS_DEV}" ]; then
        dl_warn "--with-keys needs --keys-dev to know WHERE to write the KEYS stick."
        dl_warn "Run it yourself on a DIFFERENT device than ${DEVICE}, e.g.:"
        dl_warn "  sudo ${SCRIPT_DIR}/make-keys-usb.sh /dev/sdY ${WITH_KEYS}"
    elif [ "${KEYS_DEV}" = "${DEVICE}" ]; then
        dl_die "--keys-dev (${KEYS_DEV}) must differ from the OS disk (${DEVICE})."
    else
        dl_step "Writing KEYS stick to ${KEYS_DEV} from ${WITH_KEYS}"
        "${SCRIPT_DIR}/make-keys-usb.sh" "${KEYS_DEV}" "${WITH_KEYS}" || \
            dl_warn "make-keys-usb.sh did not complete — write the KEYS stick manually."
    fi
fi

dl_info "Done. Insert ${DEVICE} into the target and boot (root grows on first boot)."
