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
#   • an .img.xz / .iso.xz -> the SAME whole-disk write, streamed through `xz -dc`
#     into dd. This is not an extra artifact kind, it is the DEFAULT one: the Studio
#     builds with --compress ON (studio core/config.py ImageConfig.compress = True),
#     which leaves x86/rpi5/jetson with only <name>.img.xz and frite/orangepi* with
#     only <name>.live.iso.xz / <name>.installer.iso.xz. Refusing those made the
#     flasher unable to name ANY artifact a default build produces — a Pi or Jetson
#     node image was unflashable outright, and a standalone x86 build fell back to
#     its ISO (#337).
#
# Artifact auto-pick (when --artifact is omitted) globs the work dir for
#   <brand>-<platform>-<arch>-<role>-*.img[.xz]   (PREFERRED)
#   <brand>-<platform>-<arch>-<role>-*.iso[.xz]   (fallback)
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
ARCH="arm64"               # arm64 (RPi5 / Jetson / SBC) | amd64/x86 (host)
PLATFORM=""                # optional device-platform anchor; derived when omitted
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
  --arch ARCH        Target arch: arm64 (RPi5 / Jetson / Orange Pi / Frite)
                     | x86 (amd64 host). Default: ${ARCH}
                     Selects the default --work-dir if you don't pass one, AND
                     ANCHORS the artifact search — an x86 request can no longer
                     resolve to an arm64 image.
  --platform NAME    Device platform to flash (rpi5 | jetson | x86 | frite |
                     orangepi5 | orangepi4-lts | orangepizero2 | orangepizero2w |
                     orangepizero3 | orangepi3-lts). Usually unnecessary: a CLUSTER
                     NODE role names its own platform (backend/frontend/pki/generic
                     are Pi-or-x86, omnibus/edge-ai/backend-gpu on arm64 are Jetson),
                     so the anchor is DERIVED. Pass it for the client/desktop roles,
                     which several arm64 boards all build — when candidates from more
                     than one platform match, the flasher REFUSES rather than pick a
                     board for you.
  --work-dir DIR     Dir to search for artifacts.
                       arm64 default: ${RPI_WORK_DIR}
                       x86   default: ${X86_WORK_DIR}
  --artifact FILE    Flash THIS file (.img/.iso, or the xz-compressed .img.xz/
                     .iso.xz a --compress build leaves); skips auto-pick.
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
  sudo $0 --arch x86 --role backend-gpu --no-confirm /dev/nvme0n1

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
        --platform)   PLATFORM="$2"; shift 2 ;;
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

# ── Normalize the device PLATFORM ──────────────────────────────────
# THE PLATFORM ANCHOR. `--arch` alone is not enough on arm64: rpi5, jetson and the
# five Orange Pi / Frite boards all emit arm64 images, so an arm64 request could
# surface a Jetson .img for a Raspberry Pi SD card — a silent wrong-board write.
# Derivation, in order:
#   1. --platform given            use it verbatim.
#   2. the role is a CLUSTER NODE role (pki/backend/frontend/backend-gpu/omnibus/
#      edge-ai)                    the platforms of this arch that BUILD that role.
#      A node role identifies its platform: on arm64 `backend` can only be rpi5 and
#      `omnibus`/`edge-ai`/`backend-gpu` can only be jetson. The free-slug boards are
#      excluded on purpose — they refuse a node --role (hugmesh_role_reject_node_role),
#      so they cannot have emitted one.
#   3. otherwise (desktop/laptop/generic/appliance/a free slug)
#                                  ANY platform, as before, plus the cross-platform
#      ambiguity refusal below. Those roles genuinely exist on several boards and
#      narrowing by guesswork would hide images that are legitimately there.
PLATFORM_GLOBS=()
if [ -n "${PLATFORM}" ]; then
    PLATFORM_GLOBS=("${PLATFORM}")
elif hugmesh_role_is_node_role "${ROLE}"; then
    for _p in x86 rpi5 jetson; do
        [ "$(hugmesh_role_arch "${_p}")" = "${ARCH}" ] || continue
        hugmesh_role_for "${_p}" "${ROLE}" >/dev/null 2>&1 || continue
        PLATFORM_GLOBS+=("${_p}")
    done
fi
[ "${#PLATFORM_GLOBS[@]}" -gt 0 ] || PLATFORM_GLOBS=("*")

# Resolve default work dir from arch if not given explicitly.
if [ -z "${WORK_DIR}" ]; then
    case "${ARCH}" in
        arm64) WORK_DIR="${RPI_WORK_DIR}" ;;
        x86)   WORK_DIR="${X86_WORK_DIR}" ;;
    esac
fi

# declared_brand <dir> — the brand the session manifest in <dir> declares, or "".
# A brand may contain '-' (it is only validated as a DNS label, studio
# core/validate.py validate_brand), and then no positional rule can find where it
# ends; the manifest is the only witness. Same key, same file, same "" fallback as
# tests/qemu/run-qemu-docker.sh declared_brand() and
# studio/hugmesh_studio/core/qemu_tests.py declared_brand().
declared_brand() {
    local mf
    mf="$1/hugmesh-mesh-manifest.json"
    [ -f "${mf}" ] || return 0
    # No pipe: `sed | head` under `set -o pipefail` reports the SIGPIPE, not the
    # match. `q` stops at the first hit instead.
    sed -n '/"brand"[[:space:]]*:/{s/.*"brand"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q;}' \
        "${mf}" 2>/dev/null || true
}
DECLARED_BRAND="$(declared_brand "${WORK_DIR}")"

# ── Artifact auto-pick ─────────────────────────────────────────────
# Three things this must get right, all of which it used to get wrong.
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
# 3. THE BRAND, WHICH IS NOT AN ANCHOR. The leading field is ${BRAND}, whatever
#    --brand the build ran under — hugmesh only by DEFAULT, sdhm for the operator's
#    own mesh, gentoo forced by an unaffiliated build. The pattern list used to
#    enumerate `hugmesh-` and `gentoo-` literally, so a mesh built as
#    sdhm-rpi5-arm64-pki-… was invisible to the flasher — the same shape of bug
#    that emptied the Studio's emulation picker on a finished 3-image Pi session.
#    The brand is globbed now; 1 and 2 above are what still narrow a candidate.
# 4. THE ROLE TOKEN IS TERMINAL, NOT A PREFIX. `-${r}-` prefix-matches a LONGER
#    role that starts with it: `backend` also matches
#    <brand>-x86-amd64-backend-gpu-<env>-<ts>.img, and the default x86 fleet
#    (scripts/build-all-roles.sh: pki backend frontend backend-gpu, one work dir)
#    makes the GPU image the NEWEST — so `--role backend --arch x86` resolved the
#    GPU worker image every time, with no ambiguity refusal possible because both
#    are platform x86. hugmesh_role_shadow_filter (scripts/_roles-lib.sh) subtracts
#    the longer role's names; when only the longer role's image exists the auto-pick
#    finds NOTHING, which is the fail-safe a whole-disk write needs.
#
# Naming conventions matched (newest-mtime-first, role-scoped first):
#   • <brand>-<platform>-<arch>-<role>-<env>-<stamp>.{img,iso}   builders + QEMU launchers
#   • <brand>-<platform>-<arch>-<role>-k8s-<stamp>.iso           older ISO naming
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
    local pf
    for r in "${ROLE_GLOBS[@]}"; do
        for a in "${ARCH_GLOBS[@]}"; do
            for pf in "${PLATFORM_GLOBS[@]}"; do
                # <brand>-<platform>-<arch>-<role>-<env>-<stamp>. The platform token
                # can be multi-part (jetson-orin-nano), so `${pf}*` covers both
                # hugmesh-rpi5-arm64-… and hugmesh-jetson-orin-nano-arm64-….
                # ${pf} is deliberately UNQUOTED: these elements are glob patterns
                # expanded at array-build time (that is why the `*`s sit outside the
                # quotes), and the "any platform" anchor IS the literal `*`. Quoting
                # it would make it a literal asterisk and match nothing. Platform
                # tokens contain only [a-z0-9-], so word-splitting cannot bite.
                # The leading "*-" is the ${BRAND} field (hugmesh / sdhm /
                # gentoo / anything --brand was given); it is NOT an anchor
                # loosening — ${a} (arch) and ${pf} (platform) still gate every
                # candidate, which is what keeps an arm64 Pi image off an
                # `--arch x86` flash.
                pats+=("${WORK_DIR}/"*"-"${pf}*"-${a}-${r}-"*".${kind}")
                # x86 'host'-era names put a second brand token between platform
                # and role (gentoo-x86-hugmesh-host-*.iso), so allow the role
                # right after arch too.
                pats+=("${WORK_DIR}/"*"-"${pf}*"-${a}-"*"-${r}-"*".${kind}")
                # ...and the xz-compressed twin of both, which is what a
                # --compress build (the Studio default) actually leaves on disk.
                pats+=("${WORK_DIR}/"*"-"${pf}*"-${a}-${r}-"*".${kind}.xz")
                pats+=("${WORK_DIR}/"*"-"${pf}*"-${a}-"*"-${r}-"*".${kind}.xz")
            done
        done
    done
    # ls -1t gives newest-mtime-first ordering (find can't sort by mtime portably);
    # our build artifacts have safe, glob-stable names.
    #
    # hugmesh_role_shadow_filter is the LAST stage and is not optional: `-${r}-` is
    # a PREFIX match, so `--role backend` also matches
    # <brand>-x86-amd64-backend-gpu-<env>-<ts>.img. scripts/build-all-roles.sh
    # builds the default x86 fleet `pki backend frontend backend-gpu` into ONE work
    # dir, which makes the GPU image the NEWEST — so `ls -1t | head -1` handed a
    # `make flash ROLE=backend ARCH=x86` the GPU worker image, deterministically,
    # and neither the platform anchor nor assert_one_platform can notice (both
    # artifacts are platform x86). See hugmesh_role_shadow_tokens in _roles-lib.sh.
    # shellcheck disable=SC2012
    ls -1t "${pats[@]}" 2>/dev/null \
        | grep -ivE '/(.*-)?(kernel|initramfs|initrd|squashfs)[^/]*\.'"${kind}"'(\.xz)?$' \
        | awk '!seen[$0]++' \
        | hugmesh_role_shadow_filter "${ROLE}"
}

# platform_of <path> — the device-platform token out of an artifact NAME:
# everything between the brand prefix and the arch token. The brand is the FIRST
# field whatever it spells (hugmesh / sdhm / gentoo / …), so it is stripped
# positionally rather than by name — enumerating two brands here silently
# mis-parsed every other one into the platform. When the work dir's manifest
# DECLARES a brand the prefix is stripped by name instead, which is the only way
# to end a hyphenated brand: `--brand my-mesh` would otherwise leave "mesh-rpi5"
# as the platform and make assert_one_platform refuse a single-board dir.
#   hugmesh-jetson-orin-nano-arm64-full-test-….img -> jetson-orin-nano
#   sdhm-rpi5-arm64-backend-test-….iso             -> rpi5
#   my-mesh-rpi5-arm64-backend-test-….img          -> rpi5   (manifest brand=my-mesh)
platform_of() {
    local n
    n="$(basename "$1")"
    local stripped
    stripped=""
    if [ -n "${DECLARED_BRAND}" ]; then
        case "${n}" in "${DECLARED_BRAND}"-*) stripped="${n#"${DECLARED_BRAND}"-}" ;; esac
    fi
    if [ -n "${stripped}" ]; then n="${stripped}"; else n="${n#*-}"; fi
    local a
    for a in x86 amd64 arm64 aarch64; do
        case "${n}" in *"-${a}-"*) printf '%s\n' "${n%%-${a}-*}"; return 0 ;; esac
    done
    printf '%s\n' "${n%%-*}"
}

# candidate_platforms — the DISTINCT platforms the auto-pick is choosing between.
candidate_platforms() {
    # `|| true` twice over: list_candidates' `ls` fails when nothing matches, and
    # this script runs under `set -euo pipefail`, where that would abort --list.
    { list_candidates img || true; list_candidates iso || true; } \
        | while IFS= read -r c; do platform_of "${c}"; done | sort -u || true
}

# THE CROSS-PLATFORM REFUSAL. Only reachable for a non-node role with no --platform
# and no --artifact: `--role desktop --arch arm64` legitimately matches rpi5, jetson,
# frite and four Orange Pi boards at once, and newest-mtime is not a board choice.
# This writes a WHOLE DISK, so an ambiguity is an error, not a coin flip.
assert_one_platform() {
    local plats
    plats="$(candidate_platforms || true)"
    plats="$(printf '%s\n' "${plats}" | sed '/^$/d')"
    local n
    n="$(printf '%s\n' "${plats}" | sed '/^$/d' | wc -l)"
    [ "${n}" -le 1 ] && return 0
    dl_die "$(printf 'candidates span %s device platforms: %s\n' "${n}" "$(echo ${plats} | tr '\n' ' ')")
       --role ${ROLE} is built by more than one board on --arch ${ARCH}, and flashing
       the wrong board's image is a silent, whole-disk mistake. Re-run with
       --platform <one of the above>, or pass --artifact FILE."
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
    if [ -n "${PLATFORM}" ]; then
        echo "Platform : ${PLATFORM}   (--platform)"
    elif [ "${PLATFORM_GLOBS[0]}" = "*" ]; then
        echo "Platform : any (${ROLE} is not a cluster node role — pass --platform to anchor)"
    else
        echo "Platform : $(echo "${PLATFORM_GLOBS[*]}")   (derived from the role)"
    fi
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
    amb="$(candidate_platforms || true)"
    amb="$(printf '%s\n' "${amb}" | sed '/^$/d')"
    if [ "$(printf '%s\n' "${amb}" | sed '/^$/d' | wc -l)" -gt 1 ]; then
        echo "AMBIGUOUS: candidates span $(echo ${amb} | tr '\n' ' ') — a flash would REFUSE."
        echo "           Pass --platform <one of those> or --artifact FILE."
    fi
    if chosen="$(pick_artifact)"; then
        echo "Would flash: ${chosen}"
    else
        echo "Would flash: (no artifact found — build one or pass --artifact)"
    fi
    exit 0
fi

# Resolve the artifact (explicit wins; otherwise auto-pick).
if [ -z "${ARTIFACT}" ]; then
    assert_one_platform
    ARTIFACT="$(pick_artifact || true)"
    [ -n "${ARTIFACT}" ] || dl_die "no ${ARCH} ${ROLE} .img/.iso in ${WORK_DIR}. Build one, pass --artifact, or check --arch/--role (try: $0 --role ${ROLE} --list)."
fi
[ -f "${ARTIFACT}" ] || dl_die "artifact not found: ${ARTIFACT}"

# Determine flash mode from the extension. COMPRESSED is the xz-compressed twin of
# the same whole-disk image: identical bytes on the disk, piped through `xz -dc` on the
# way there. The two .xz arms are what a --compress build (the Studio default) actually
# produces, and refusing them here is what made a finished node image unflashable.
COMPRESSED=false
case "${ARTIFACT}" in
    *.img)    FLASH_KIND="img" ;;
    *.iso)    FLASH_KIND="iso" ;;
    *.img.xz) FLASH_KIND="img"; COMPRESSED=true ;;
    *.iso.xz) FLASH_KIND="iso"; COMPRESSED=true ;;
    *)        dl_die "artifact must be .img/.iso or .img.xz/.iso.xz (got: ${ARTIFACT})" ;;
esac

# ── Device required from here on ───────────────────────────────────
[ -n "${DEVICE}" ] || { echo "ERROR: target /dev/sdX required (or use --list)." >&2; usage 1; }

# ── Root + tools (destructive path) ────────────────────────────────
dl_require_root
dl_require_tools dd sync lsblk partprobe blkid
${COMPRESSED} && dl_require_tools xz
dl_is_block "${DEVICE}" || dl_die "${DEVICE} is not a block device."

# Refuse to flash onto an obvious partition (e.g. /dev/sda1) — we want the disk.
if [[ "${DEVICE}" =~ [0-9]$ ]] && [[ ! "${DEVICE}" =~ (nvme[0-9]+n[0-9]+|mmcblk[0-9]+|loop[0-9]+)$ ]]; then
    dl_die "${DEVICE} looks like a PARTITION. Pass the WHOLE disk (e.g. /dev/sda, /dev/nvme0n1)."
fi

# The size that must fit on the disk is the size that gets WRITTEN. For a compressed
# artifact that is the uncompressed size, not the file size — comparing the 3 GB .xz
# against the device would have passed an image that expands to more than the disk
# holds, and dd would only find out mid-write. `xz --robot --list` reports it exactly;
# a 0 from a failed read simply skips the fit check, as it always did.
ART_SIZE="$(stat -c '%s' "${ARTIFACT}" 2>/dev/null || echo 0)"
if ${COMPRESSED}; then
    ART_SIZE="$(xz --robot --list "${ARTIFACT}" 2>/dev/null \
                | awk '$1=="totals"{print $5}' || echo 0)"
    [ -n "${ART_SIZE}" ] || ART_SIZE=0
fi
DEV_SIZE="$(blockdev --getsize64 "${DEVICE}" 2>/dev/null || echo 0)"
ART_H="$(numfmt --to=iec "${ART_SIZE}" 2>/dev/null || echo "${ART_SIZE}B")"
DEV_H="$(numfmt --to=iec "${DEV_SIZE}" 2>/dev/null || echo "${DEV_SIZE}B")"

dl_info "Role     : ${ROLE} (${ARCH}, platform $(platform_of "${ARTIFACT}"))"
if ${COMPRESSED}; then
    dl_info "Artifact : ${ARTIFACT} [${FLASH_KIND}.xz, ${ART_H} uncompressed]"
else
    dl_info "Artifact : ${ARTIFACT} [${FLASH_KIND}, ${ART_H}]"
fi
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
if ${COMPRESSED}; then
    # Decompress STRAIGHT to the disk — never to a 3-30 GB temp file, which would
    # need scratch space the operator did not ask for and may not have.
    #
    # `iflag=fullblock` is load-bearing: dd reading a PIPE takes short reads, and a
    # short read becomes a short (unaligned) write. `oflag=direct` is deliberately
    # NOT used on this path for the same reason — direct I/O rejects unaligned
    # writes with EINVAL, so pairing it with a pipe source fails at a random block
    # rather than never. Buffered + conv=fsync writes the same bytes; the sync
    # below still settles them.
    #
    # pipefail is already on (set -euo pipefail at the top), so a dd failure fails
    # the whole pipeline instead of being masked by xz's exit status.
    xz -dc "${ARTIFACT}" \
        | dd of="${DEVICE}" bs=4M iflag=fullblock conv=fsync status=progress
elif dd if="${ARTIFACT}" of="${DEVICE}" bs=4M conv=fsync oflag=direct status=progress 2>&1; then
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
