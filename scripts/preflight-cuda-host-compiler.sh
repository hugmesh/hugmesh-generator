#!/usr/bin/env bash
# preflight-cuda-host-compiler.sh — detect the CUDA-vs-seed-toolchain impossible
# combination BEFORE hours are spent proving it the hard way.
#
# THE COMBINATION. dev-util/nvidia-cuda-toolkit hard-caps its host compiler
# (nvidia-cuda-toolkit-12.9.2.ebuild: GCC_MAX_VER="14"):
#     RDEPEND="!clang? ( <sys-devel/gcc-15_pre[cxx] )
#              clang?  ( <llvm-core/clang-20_pre ) …"
# build-x86-host-stage4.sh keeps the seed toolchain with a NAME-level
# `--exclude sys-devel/gcc` (EMERGE_EXCLUDE), and the amd64 hardened stage3 seed
# ships gcc 15 ("gcc (Gentoo Hardened 15.3.0 p8)" in the 20260719T170103Z seed).
# So with the toolkit's default USE=-clang:
#   - the INSTALLED gcc (15) does not satisfy <gcc-15_pre, and
#   - every INSTALLABLE gcc:14 candidate is masked by the very same exclude
#     ("masked by: exclude option"),
# meaning resolution of the whole payload set fails and — because a RESOLUTION
# failure aborts emerge before any merge, --keep-going notwithstanding — NOT ONE
# payload package installs. That is exactly how role edge_ai.x86 emitted zero
# artifacts (out/sessions/20260719-103006-a775c2/build-edge_ai.x86.log:153744):
#     !!! All ebuilds that could satisfy "<sys-devel/gcc-15_pre[cxx]" have been masked.
#     - sys-devel/gcc-14.3.1_p20260604::gentoo (masked by: exclude option)
#     (dependency required by "dev-util/nvidia-cuda-toolkit-12.9.2::gentoo[-clang]" [ebuild])
# The @world pass before that emerge had already run for HOURS. A build that
# cannot possibly succeed should say so in seconds — this script is that check.
#
# THE FIX IT GUARDS. specs-x86/portage/package.use/nvidia enables USE=clang on
# the toolkit, flipping the dep onto <llvm-core/clang-20_pre (clang-19.1.7-r1 is
# stable amd64 and NOT excluded). This script fails loudly whenever the
# impossible combination re-forms — the USE line dropped, a new CUDA ebuild
# raising/lowering its caps, a stage3 seed jumping past the cap with the clang
# leg off, or the exclude changing shape.
#
# MODES
#   repo mode (default; static, CI-safe — what tests/scripts/
#   test-edge-ai-cuda-host-compiler.sh runs):
#       preflight-cuda-host-compiler.sh [--repo DIR]
#     Checks the invariant on the REPO's own files: IF
#     specs-x86/portage/packages-gpu-nvidia-cuda.list requests the toolkit AND
#     build-x86-host-stage4.sh name-excludes sys-devel/gcc, THEN
#     specs-x86/portage/package.use/* must enable USE=clang on the toolkit.
#     (The seed gcc version is a build-time fact — repo mode conservatively
#     assumes seed gcc > GCC_MAX_VER, which has been true since gcc 15 went
#     stable and is the only case the invariant matters for.)
#
#   sysroot mode (build-time; run AFTER spec-install + mount_chroot, BEFORE the
#   payload emerge — integration into build-x86-host-stage4.sh is a one-line
#   call; NOTE for the integrator: if the call is placed inside the unquoted
#   CHROOT heredoc, every '$' must be escaped as \$ — better to call it from
#   the HOST against ${SYSROOT} right before the heredoc):
#       preflight-cuda-host-compiler.sh --sysroot DIR [--gcc-not-excluded]
#     Checks the RENDERED sysroot: seed gcc major (from
#     DIR/usr/lib/gcc/<chost>/<ver>), the toolkit caps (GCC_MAX_VER /
#     CLANG_MAX_VER parsed from the newest nvidia-cuda-toolkit ebuild under
#     DIR/var/db/repos/gentoo, when visible — the repo is bind-mounted/synced by
#     then), and whether DIR/etc/portage/package.use enables clang on the
#     toolkit. --gcc-not-excluded says the caller's emerge will NOT name-exclude
#     sys-devel/gcc (REBUILD_TOOLCHAIN=true), which dissolves the combination.
#
# Exit: 0 = combination not present / resolvable; 1 = IMPOSSIBLE COMBINATION
# (fail the build NOW); 2 = usage error. Static only: no emerge, no chroot, no
# network, no root.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
SYSROOT=""
GCC_EXCLUDED_OVERRIDE=""   # sysroot mode: ""=assume excluded (builder default), false via --gcc-not-excluded

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)    REPO="$2"; shift 2 ;;
        --sysroot) SYSROOT="$2"; shift 2 ;;
        --gcc-not-excluded) GCC_EXCLUDED_OVERRIDE=false; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[preflight-cuda] usage error: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

TOOLKIT_ATOM="dev-util/nvidia-cuda-toolkit"
fail() { echo "[preflight-cuda] ERROR: $*" >&2; }
note() { echo "[preflight-cuda] $*"; }

# package.use lines are "<atom> <flag> [<flag>…]" — parse FIELDS, not substrings:
# an enabled flag is the bare word, a disabled one is '-'-prefixed, and prose in
# '#' comments mentions the flag too. (House lesson, tests/scripts/
# test-spec-use-parity.sh: a substring/regex form of this exact kind of check
# silently PASSED on the very spec it was written to catch.)
clang_enabled_in() { # <dir with package.use files> -> 0 iff some file enables clang on the toolkit
    local d="$1" f hit=1
    [ -d "${d}" ] || return 1
    for f in "${d}"/*; do
        [ -f "${f}" ] || continue
        awk -v atom="${TOOLKIT_ATOM}" '
            /^[[:space:]]*#/ { next }
            $1 == atom { for (i = 2; i <= NF; i++) if ($i == "clang") found = 1 }
            END { exit(found ? 0 : 1) }' "${f}" && { hit=0; break; }
    done
    return "${hit}"
}

# The builder's EMERGE_EXCLUDE is a NAME-level gcc exclude only when the token
# after an `--exclude` is exactly `sys-devel/gcc` — `sys-devel/gcc:15` (a slot
# atom) would leave gcc:14 installable and NOT form the impossible combination,
# so token equality, not a substring match, is what gets tested.
gcc_name_excluded_in_builder() { # <builder file> -> 0 iff EMERGE_EXCLUDE name-excludes sys-devel/gcc
    local builder="$1" line tok prev=""
    [ -f "${builder}" ] || return 1
    # The non-REBUILD_TOOLCHAIN assignment (build-x86-host-stage4.sh: the
    # EMERGE_EXCLUDE="--exclude sys-devel/gcc …" else-branch).
    line="$(grep -E '^[[:space:]]*EMERGE_EXCLUDE="--exclude' "${builder}" | head -n1)" || true
    [ -n "${line}" ] || return 1
    line="${line#*=\"}"; line="${line%\"*}"
    for tok in ${line}; do
        [ "${prev}" = "--exclude" ] && [ "${tok}" = "sys-devel/gcc" ] && return 0
        prev="${tok}"
    done
    return 1
}

# ── sysroot mode ────────────────────────────────────────────────────────────────
if [ -n "${SYSROOT}" ]; then
    [ -d "${SYSROOT}" ] || { echo "[preflight-cuda] usage error: --sysroot '${SYSROOT}' is not a directory" >&2; exit 2; }

    gcc_excluded=true
    [ "${GCC_EXCLUDED_OVERRIDE}" = "false" ] && gcc_excluded=false

    # Seed gcc major: the version directories under /usr/lib/gcc/<CHOST>/ are
    # authoritative for what the stage3 actually ships (no chroot needed).
    seed_gcc_major=""
    for d in "${SYSROOT}"/usr/lib/gcc/*/*/; do
        [ -d "${d}" ] || continue
        v="$(basename "${d}")"; v="${v%%.*}"
        case "${v}" in *[!0-9]*|'') continue ;; esac
        [ -z "${seed_gcc_major}" ] || [ "${v}" -gt "${seed_gcc_major}" ] && seed_gcc_major="${v}"
    done

    # Toolkit caps from the newest ebuild visible in the sysroot's tree (the
    # gentoo repo is bind-mounted / synced before the payload emerge). GCC_MAX_VER
    # is a plain shell assignment in the ebuild — parse it, never hardcode it: the
    # 12.9.x cap is 14 today and WILL move.
    gcc_max="" clang_max=""
    eb_dir="${SYSROOT}/var/db/repos/gentoo/dev-util/nvidia-cuda-toolkit"
    if [ -d "${eb_dir}" ]; then
        eb="$(ls "${eb_dir}"/*.ebuild 2>/dev/null | sort -V | tail -n1)"
        if [ -n "${eb}" ]; then
            gcc_max="$(sed -n 's/^GCC_MAX_VER="\([0-9]\+\)"$/\1/p' "${eb}" | head -n1)"
            clang_max="$(sed -n 's/^CLANG_MAX_VER="\([0-9]\+\)"$/\1/p' "${eb}" | head -n1)"
        fi
    fi

    if clang_enabled_in "${SYSROOT}/etc/portage/package.use"; then
        note "OK: ${TOOLKIT_ATOM} USE=clang is enabled in the sysroot — the host-compiler dep is the clang leg (<llvm-core/clang-$(( ${clang_max:-19} + 1 ))_pre), which EMERGE_EXCLUDE does not touch."
        exit 0
    fi
    if ! ${gcc_excluded}; then
        note "OK: sys-devel/gcc is not excluded (--gcc-not-excluded) — the resolver may install a gcc:<=GCC_MAX_VER slot to satisfy the toolkit's gcc leg."
        exit 0
    fi
    if [ -z "${seed_gcc_major}" ]; then
        note "WARN: could not determine the seed gcc major from ${SYSROOT}/usr/lib/gcc/*/*/ — cannot prove the combination either way; NOT failing." >&2
        exit 0
    fi
    if [ -z "${gcc_max}" ]; then
        note "WARN: no nvidia-cuda-toolkit ebuild visible under ${eb_dir} — assuming the last-known cap GCC_MAX_VER=14 (nvidia-cuda-toolkit-12.9.2)." >&2
        gcc_max=14
    fi
    if [ "${seed_gcc_major}" -gt "${gcc_max}" ]; then
        fail "IMPOSSIBLE COMBINATION — this payload emerge CANNOT resolve. Failing now instead of after hours:"
        fail "  - ${TOOLKIT_ATOM} is requested with USE=-clang, so its host-compiler dep is <sys-devel/gcc-$((gcc_max + 1))_pre[cxx] (GCC_MAX_VER=${gcc_max})."
        fail "  - the seed toolchain in this sysroot is gcc ${seed_gcc_major} (> ${gcc_max}), which does NOT satisfy it."
        fail "  - EMERGE_EXCLUDE name-excludes sys-devel/gcc, so every installable gcc:<=${gcc_max} candidate is 'masked by: exclude option'."
        fail "  This is exactly how role edge_ai.x86 emitted ZERO artifacts (out/sessions/20260719-103006-a775c2/build-edge_ai.x86.log:153744)."
        fail "  Fix ONE of: enable '${TOOLKIT_ATOM} clang' in the sysroot package.use (specs-x86/portage/package.use/nvidia does this),"
        fail "  or run with REBUILD_TOOLCHAIN=true (drops the exclude), or drop --nvidia-cuda from this build."
        exit 1
    fi
    note "OK: seed gcc ${seed_gcc_major} <= GCC_MAX_VER ${gcc_max} — the INSTALLED gcc satisfies the toolkit's gcc leg."
    exit 0
fi

# ── repo mode (static invariant, CI) ────────────────────────────────────────────
SPECS="${REPO}/specs-x86/portage"
BUILDER="${REPO}/build-x86-host-stage4.sh"
CUDA_LIST="${SPECS}/packages-gpu-nvidia-cuda.list"

toolkit_requested=false
if [ -f "${CUDA_LIST}" ] && grep -vE '^[[:space:]]*(#|$)' "${CUDA_LIST}" | grep -qxF "${TOOLKIT_ATOM}"; then
    toolkit_requested=true
fi
if ! ${toolkit_requested}; then
    note "OK: ${CUDA_LIST##*/} does not request ${TOOLKIT_ATOM} — the combination is not present."
    exit 0
fi
if ! gcc_name_excluded_in_builder "${BUILDER}"; then
    note "OK: ${BUILDER##*/} does not NAME-exclude sys-devel/gcc — the resolver may install a gcc:<=GCC_MAX_VER slot for the toolkit's gcc leg."
    exit 0
fi
if clang_enabled_in "${SPECS}/package.use"; then
    note "OK: ${TOOLKIT_ATOM} is requested, sys-devel/gcc is name-excluded, and specs-x86 package.use enables USE=clang on the toolkit — the dep is the clang leg; resolvable."
    exit 0
fi
fail "IMPOSSIBLE COMBINATION in the x86 specs (this is the exact state that gave edge_ai.x86 ZERO artifacts on 2026-07-19):"
fail "  - ${CUDA_LIST##*/} requests ${TOOLKIT_ATOM} (host-compiler RDEPEND: !clang? ( <sys-devel/gcc-\${GCC_MAX_VER+1}_pre[cxx] ))."
fail "  - ${BUILDER##*/} name-excludes sys-devel/gcc (EMERGE_EXCLUDE), masking every installable gcc:14 candidate,"
fail "    while the amd64 hardened stage3 seed ships gcc 15 — so the gcc leg has NO candidate at all."
fail "  - no specs-x86/portage/package.use file enables '${TOOLKIT_ATOM} clang' to flip the dep onto the clang leg."
fail "  Evidence: out/sessions/20260719-103006-a775c2/build-edge_ai.x86.log:153744 —"
fail "    !!! All ebuilds that could satisfy \"<sys-devel/gcc-15_pre[cxx]\" have been masked."
fail "    - sys-devel/gcc-14.3.1_p20260604::gentoo (masked by: exclude option)"
fail "  Restore 'dev-util/nvidia-cuda-toolkit clang' in specs-x86/portage/package.use/nvidia (see that file's WHY-comment)."
exit 1
