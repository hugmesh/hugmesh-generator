#!/usr/bin/env bash
# test-binpkg-pool-fingerprint.sh — regression test for the binpkg-pool fingerprint
# guard (shared-binpkg track, Lane 4d) in scripts/_binpkg-pool-lib.sh.
#
# THE GUARD IS THE LOAD-BEARING SIGILL SAFETY NET: portage's --usepkg /
# --binpkg-respect-use validate USE only, never CHOST/CFLAGS/-mcpu, so nothing else
# in the pipeline compares CFLAGS before reusing a binpkg pool. All aarch64 boards
# share CHOST but differ in -mcpu (a76/a72/a53/...); a cortex-a76 binpkg run on an
# a53/a72 SIGILLs. This guard fingerprints each pool by its rendered make.conf ABI
# values and REFUSES reuse on a mismatch.
#
# HERMETIC (NO build): sources the REAL library, builds fixture make.conf files
# (a76 vs a72 vs x86) + fixture pkgdirs, and asserts:
#   (1) an ABSENT stamp is written fresh (first build stamps the pool);
#   (2) a MATCHING stamp passes (reuse across roles of the same board);
#   (3) a WRONG stamp (a76 pool, a72 build) makes the preflight DIE (rc!=0) with a
#       clear SIGILL message — this is the cross-board reuse the guard must refuse;
#   (4) rpi5/rpi4/rpi3 (a76/a72/a53) produce THREE distinct fingerprints (it is the
#       -mcpu in CFLAGS, which portage ignores, that distinguishes them);
#   (5) an INSTALL_MASK/correctness SALT change flips the fingerprint (pool flush).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/scripts/_binpkg-pool-lib.sh"
[ -f "${LIB}" ] || { echo "  FAIL lib missing: ${LIB}"; exit 1; }
# shellcheck source=/dev/null
source "${LIB}"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== binpkg-pool fingerprint guard (Lane 4d / SIGILL net) =="

# Fixture rendered make.conf files (post-substitution, as render_template emits).
mk_makeconf() { # <path> <chost> <cflags>
    mkdir -p "$(dirname "$1")"
    { printf 'CHOST="%s"\n' "$2"
      printf 'COMMON_FLAGS=""\n'
      printf 'CFLAGS="%s"\n' "$3"
      printf 'CXXFLAGS="${CFLAGS}"\n'
      printf 'FEATURES="buildpkg"\n'; } > "$1"
}

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
MC_A76="${TMP}/pi5/make.conf"; mk_makeconf "${MC_A76}" "aarch64-unknown-linux-gnu" "-mcpu=cortex-a76 -mtune=cortex-a76 -O2 -pipe"
MC_A72="${TMP}/pi4/make.conf"; mk_makeconf "${MC_A72}" "aarch64-unknown-linux-gnu" "-mcpu=cortex-a72 -mtune=cortex-a72 -O2 -pipe"
MC_A53="${TMP}/pi3/make.conf"; mk_makeconf "${MC_A53}" "aarch64-unknown-linux-gnu" "-mcpu=cortex-a53 -mtune=cortex-a53 -O2 -pipe"
MC_X86="${TMP}/x86/make.conf"; mk_makeconf "${MC_X86}" "x86_64-pc-linux-gnu"       "-march=x86-64-v2 -O2 -pipe"

FP_A76="$(pool_fingerprint_of "${MC_A76}")"
FP_A72="$(pool_fingerprint_of "${MC_A72}")"
FP_A53="$(pool_fingerprint_of "${MC_A53}")"
FP_X86="$(pool_fingerprint_of "${MC_X86}")"

# (4) three distinct aarch64 fingerprints from -mcpu alone (same CHOST)
if [ -n "${FP_A76}" ] && [ "${FP_A76}" != "${FP_A72}" ] && [ "${FP_A76}" != "${FP_A53}" ] && [ "${FP_A72}" != "${FP_A53}" ]; then
    ok "a76/a72/a53 → three distinct fingerprints (same CHOST, -mcpu differs)"
else
    bad "aarch64 fingerprints not all distinct: a76=${FP_A76} a72=${FP_A72} a53=${FP_A53}"
fi
[ "${FP_X86}" != "${FP_A76}" ] && ok "x86 fingerprint differs from aarch64" || bad "x86 == aarch64 fingerprint"

# (1) absent stamp → written fresh, preflight passes
POOL="${TMP}/pool-pi5"; mkdir -p "${POOL}"
if pool_fingerprint_preflight "${POOL}" "${MC_A76}"; then
    if [ "$(cat "${POOL}/.snapdragon-pool-fingerprint")" = "${FP_A76}" ]; then
        ok "absent stamp: preflight writes the fingerprint fresh and passes"
    else
        bad "fresh stamp content wrong: $(cat "${POOL}/.snapdragon-pool-fingerprint")"
    fi
else
    bad "fresh pool preflight returned non-zero"
fi

# (2) matching stamp → passes (same board, next role reuses the pool)
if pool_fingerprint_preflight "${POOL}" "${MC_A76}"; then
    ok "matching stamp: reuse across same-board roles is allowed"
else
    bad "matching stamp wrongly refused"
fi

# (3) WRONG stamp → DIES. Reuse the a76-stamped pool for an a72 (rpi4) build.
errout="${TMP}/err.txt"
if pool_fingerprint_preflight "${POOL}" "${MC_A72}" 2>"${errout}"; then
    bad "cross-board reuse (a76 pool, a72 build) was ALLOWED — SIGILL hazard not caught"
else
    if grep -q 'SIGILL' "${errout}" && grep -q 'ABI MISMATCH' "${errout}"; then
        ok "cross-board reuse REFUSED with a clear SIGILL/ABI-mismatch message"
    else
        bad "refused but message unclear:"; cat "${errout}"
    fi
fi
# and the stamp must NOT have been overwritten by the refused build
[ "$(cat "${POOL}/.snapdragon-pool-fingerprint")" = "${FP_A76}" ] \
    && ok "refused build left the original a76 stamp intact" \
    || bad "refused build corrupted the stamp"

# (5) SALT (INSTALL_MASK/package.mask correctness pin) flips the fingerprint
FP_SALT="$(pool_fingerprint_of "${MC_A76}" "" "gettext-mo-fix-2026-07-08")"
[ -n "${FP_SALT}" ] && [ "${FP_SALT}" != "${FP_A76}" ] \
    && ok "correctness SALT change flips the fingerprint (forces a pool flush)" \
    || bad "SALT did not change the fingerprint"

# (0) empty fingerprint (no make.conf yet) is a no-op guard (never blocks a fresh tree)
POOL2="${TMP}/pool-empty"; mkdir -p "${POOL2}"
if pool_fingerprint_preflight "${POOL2}" "${TMP}/does-not-exist/make.conf"; then
    ok "missing make.conf → empty fingerprint → guard is a no-op (does not block)"
else
    bad "missing make.conf wrongly blocked the build"
fi

echo "== fingerprint guard: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
