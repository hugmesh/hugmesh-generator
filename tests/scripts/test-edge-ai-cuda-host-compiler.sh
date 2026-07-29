#!/usr/bin/env bash
# test-edge-ai-cuda-host-compiler.sh — the edge_ai.x86 CUDA host-compiler
# invariant + its pre-flight detector.
#
# THE BUG THIS PINS. dev-util/nvidia-cuda-toolkit's default (USE=-clang) host
# compiler dep is <sys-devel/gcc-15_pre[cxx] (12.9.2: GCC_MAX_VER="14"). The
# amd64 hardened stage3 seed ships gcc 15, and build-x86-host-stage4.sh keeps
# the seed toolchain with a NAME-level `--exclude sys-devel/gcc` — which also
# masks every installable gcc:14 candidate. Resolution of the WHOLE payload set
# then fails (a resolution failure aborts emerge before any merge; --keep-going
# cannot help), so role edge_ai.x86 merged NOTHING and emitted zero artifacts
# (out/sessions/20260719-103006-a775c2/build-edge_ai.x86.log:153744):
#     !!! All ebuilds that could satisfy "<sys-devel/gcc-15_pre[cxx]" have been masked.
#     - sys-devel/gcc-14.3.1_p20260604::gentoo (masked by: exclude option)
#     (dependency required by "dev-util/nvidia-cuda-toolkit-12.9.2::gentoo[-clang]" [ebuild])
# The fix: specs-x86/portage/package.use/nvidia enables USE=clang, flipping the
# dep onto <llvm-core/clang-20_pre (clang-19.1.7-r1 is stable amd64, slotted,
# and not excluded).
#
# WHAT IS TESTED
#   1) the LIVE repo holds the invariant (both via scripts/
#      preflight-cuda-host-compiler.sh and via an independent awk field-parse,
#      so a broken-permissive detector cannot vouch for a broken spec);
#   2) the detector CATCHES the historical broken state and its near neighbours
#      on doctored repo copies ('-clang', wrong atom, substring flags), and
#      stays quiet when the combination is genuinely absent (no toolkit
#      request / no exclude / SLOT-level exclude);
#   3) sysroot mode reads the RENDERED image config: seed gcc major from
#      /usr/lib/gcc, GCC_MAX_VER from the visible ebuild (never hardcoded), and
#      the package.use clang flag — on synthetic sysroots.
#
# package.use lines are parsed as FIELDS, never substring-matched — a regex form
# of exactly this kind of guard once PASSED on the very spec it was written to
# catch (see tests/scripts/test-spec-use-parity.sh's flag_enabled note).
#
# Static only: no emerge, no chroot, no network, no root.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
PREFLIGHT="${REPO}/scripts/preflight-cuda-host-compiler.sh"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "== edge_ai.x86 CUDA host-compiler invariant =="

echo "-- 1) live repo --"
[ -f "${PREFLIGHT}" ] && ok "preflight script present" || bad "missing ${PREFLIGHT}"

if bash "${PREFLIGHT}" --repo "${REPO}" >/dev/null 2>&1; then
    ok "preflight (repo mode) passes on the live tree"
else
    bad "preflight (repo mode) FAILS on the live tree — the impossible combination is back; see: bash ${PREFLIGHT}"
fi

# Independent field-parse of the live spec: the toolkit atom's line must carry
# the bare flag 'clang' (not '-clang', not a substring) in some package.use file.
live_clang_ok=1
for f in "${REPO}"/specs-x86/portage/package.use/*; do
    [ -f "${f}" ] || continue
    awk '/^[[:space:]]*#/ { next }
         $1 == "dev-util/nvidia-cuda-toolkit" { for (i = 2; i <= NF; i++) if ($i == "clang") found = 1 }
         END { exit(found ? 0 : 1) }' "${f}" && { live_clang_ok=0; break; }
done
[ "${live_clang_ok}" -eq 0 ] \
    && ok "specs-x86 package.use enables USE=clang on dev-util/nvidia-cuda-toolkit (independent field-parse)" \
    || bad "no specs-x86/portage/package.use file enables 'dev-util/nvidia-cuda-toolkit clang' — the gcc leg (<sys-devel/gcc-15_pre[cxx]) is unsatisfiable under the builder's --exclude sys-devel/gcc"

# The preconditions the invariant exists for (if either disappears, the two
# checks above still pass — these just document WHY the guard is here).
grep -vE '^[[:space:]]*(#|$)' "${REPO}/specs-x86/portage/packages-gpu-nvidia-cuda.list" 2>/dev/null | grep -qxF "dev-util/nvidia-cuda-toolkit" \
    && ok "precondition holds: packages-gpu-nvidia-cuda.list requests the toolkit" \
    || ok "precondition gone: packages-gpu-nvidia-cuda.list no longer requests the toolkit (guard vacuous but harmless)"

# ── doctored repo copies ────────────────────────────────────────────────────────
# A minimal fake repo: just the three files repo mode reads.
mk_fake_repo() { # <dir> <package.use/nvidia body> <cuda list body> <EMERGE_EXCLUDE line>
    local d="$1"
    mkdir -p "${d}/specs-x86/portage/package.use"
    printf '%s\n' "$2" > "${d}/specs-x86/portage/package.use/nvidia"
    printf '%s\n' "$3" > "${d}/specs-x86/portage/packages-gpu-nvidia-cuda.list"
    printf '%s\n' "$4" > "${d}/build-x86-host-stage4.sh"
}
EXCL_NAME='EMERGE_EXCLUDE="--exclude sys-devel/gcc --exclude sys-libs/glibc --exclude sys-devel/binutils"'
EXCL_SLOT='EMERGE_EXCLUDE="--exclude sys-devel/gcc:15 --exclude sys-libs/glibc --exclude sys-devel/binutils"'
EXCL_NOGCC='EMERGE_EXCLUDE="--exclude sys-libs/glibc --exclude sys-devel/binutils"'

run_repo_case() { # <name> <expected exit> <use body> <list body> <exclude line>
    local name="$1" want="$2" d="${TMP}/case-${1// /_}"
    mk_fake_repo "${d}" "$3" "$4" "$5"
    bash "${PREFLIGHT}" --repo "${d}" >"${d}.out" 2>&1
    local got=$?
    if [ "${got}" -eq "${want}" ]; then
        ok "repo-mode ${name} -> exit ${got} (expected)"
    else
        bad "repo-mode ${name} -> exit ${got}, expected ${want}; output: $(tail -n 2 "${d}.out" | tr '\n' ' ')"
    fi
}

echo "-- 2) detector catches the broken states (doctored copies) --"
# THE 2026-07-19 state: toolkit requested, gcc name-excluded, no clang USE.
run_repo_case "historical-broken (no clang line)" 1 \
    'x11-drivers/nvidia-drivers kernel-open' 'dev-util/nvidia-cuda-toolkit' "${EXCL_NAME}"
# Explicitly DISABLED clang must not count as enabled ('-clang' contains 'clang').
run_repo_case "clang disabled (-clang)" 1 \
    'dev-util/nvidia-cuda-toolkit -clang' 'dev-util/nvidia-cuda-toolkit' "${EXCL_NAME}"
# The flag on a DIFFERENT atom must not count.
run_repo_case "clang on the wrong atom" 1 \
    'x11-drivers/nvidia-drivers clang' 'dev-util/nvidia-cuda-toolkit' "${EXCL_NAME}"
# A comment mentioning clang must not count.
run_repo_case "clang only in a comment" 1 \
    '# dev-util/nvidia-cuda-toolkit clang
dev-util/nvidia-cuda-toolkit' 'dev-util/nvidia-cuda-toolkit' "${EXCL_NAME}"
# The fixed state: enabled among other flags, any position.
run_repo_case "fixed (clang among other flags)" 0 \
    'dev-util/nvidia-cuda-toolkit debugger clang -examples' 'dev-util/nvidia-cuda-toolkit' "${EXCL_NAME}"
# No toolkit request -> combination absent.
run_repo_case "toolkit not requested" 0 \
    'x11-drivers/nvidia-drivers kernel-open' '# no cuda here' "${EXCL_NAME}"
# No gcc exclude at all -> resolver can install gcc:14.
run_repo_case "gcc not excluded" 0 \
    'dev-util/nvidia-cuda-toolkit' 'dev-util/nvidia-cuda-toolkit' "${EXCL_NOGCC}"
# SLOT-level exclude keeps the seed slot pinned but leaves gcc:14 installable —
# NOT the impossible combination; the detector must know the difference.
run_repo_case "slot-level gcc exclude" 0 \
    'dev-util/nvidia-cuda-toolkit' 'dev-util/nvidia-cuda-toolkit' "${EXCL_SLOT}"

echo "-- 3) sysroot mode (synthetic sysroots) --"
mk_fake_sysroot() { # <dir> <gcc major> <package.use/nvidia body> [GCC_MAX_VER]
    local d="$1"
    mkdir -p "${d}/usr/lib/gcc/x86_64-pc-linux-gnu/$2" "${d}/etc/portage/package.use"
    printf '%s\n' "$3" > "${d}/etc/portage/package.use/nvidia"
    if [ -n "${4:-}" ]; then
        mkdir -p "${d}/var/db/repos/gentoo/dev-util/nvidia-cuda-toolkit"
        printf 'EAPI=8\nGCC_MAX_VER="%s"\nCLANG_MAX_VER="19"\n' "$4" \
            > "${d}/var/db/repos/gentoo/dev-util/nvidia-cuda-toolkit/nvidia-cuda-toolkit-12.9.2.ebuild"
    fi
}
run_sysroot_case() { # <name> <expected exit> <sysroot dir> [extra args…]
    local name="$1" want="$2" d="$3"; shift 3
    bash "${PREFLIGHT}" --sysroot "${d}" "$@" >"${d}.out" 2>&1
    local got=$?
    if [ "${got}" -eq "${want}" ]; then
        ok "sysroot-mode ${name} -> exit ${got} (expected)"
    else
        bad "sysroot-mode ${name} -> exit ${got}, expected ${want}; output: $(tail -n 2 "${d}.out" | tr '\n' ' ')"
    fi
}
# Seed gcc 15 > cap 14, clang off -> the 20260719 failure, caught in seconds.
mk_fake_sysroot "${TMP}/sr-broken" 15 'x11-drivers/nvidia-drivers kernel-open' 14
run_sysroot_case "seed gcc 15 / cap 14 / no clang" 1 "${TMP}/sr-broken"
# Same seed, clang enabled -> fine.
mk_fake_sysroot "${TMP}/sr-fixed" 15 'dev-util/nvidia-cuda-toolkit clang' 14
run_sysroot_case "seed gcc 15 / clang enabled" 0 "${TMP}/sr-fixed"
# Seed gcc <= cap -> the INSTALLED gcc satisfies the gcc leg; no clang needed.
mk_fake_sysroot "${TMP}/sr-old-seed" 14 'x11-drivers/nvidia-drivers' 14
run_sysroot_case "seed gcc 14 / cap 14 / no clang" 0 "${TMP}/sr-old-seed"
# The cap is PARSED, not hardcoded: a future toolkit with GCC_MAX_VER=15 accepts
# a gcc-15 seed…
mk_fake_sysroot "${TMP}/sr-cap15" 15 'x11-drivers/nvidia-drivers' 15
run_sysroot_case "seed gcc 15 / cap 15 / no clang" 0 "${TMP}/sr-cap15"
# …and a gcc-16 seed overruns a cap of 15.
mk_fake_sysroot "${TMP}/sr-gcc16" 16 'x11-drivers/nvidia-drivers' 15
run_sysroot_case "seed gcc 16 / cap 15 / no clang" 1 "${TMP}/sr-gcc16"
# --gcc-not-excluded (REBUILD_TOOLCHAIN=true) dissolves the combination.
run_sysroot_case "broken combo but gcc not excluded" 0 "${TMP}/sr-broken" --gcc-not-excluded

echo
echo "edge-ai-cuda-host-compiler: ${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
