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
    if [ "$(cat "${POOL}/.hugmesh-pool-fingerprint")" = "${FP_A76}" ]; then
        ok "absent stamp: preflight writes the fingerprint fresh and passes"
    else
        bad "fresh stamp content wrong: $(cat "${POOL}/.hugmesh-pool-fingerprint")"
    fi
else
    bad "fresh pool preflight returned non-zero"
fi

# (1b) UNSTAMPED pool that ALREADY holds binpkgs → adopts BUT warns loudly (the
# first-rollout / manually-shared-dir case the guard must not be silently inert on).
POOL_NE="${TMP}/pool-unstamped-nonempty"; mkdir -p "${POOL_NE}"
printf 'fake index\n' > "${POOL_NE}/Packages"          # pool looks populated, no stamp
w1="${TMP}/w1.txt"
if pool_fingerprint_preflight "${POOL_NE}" "${MC_A76}" 2>"${w1}"; then
    if grep -qi 'UNSTAMPED' "${w1}" && grep -q 'SIGILL' "${w1}"; then
        ok "unstamped NON-EMPTY pool: adopted but WARNED (SIGILL risk made visible)"
    else
        bad "unstamped non-empty pool adopted SILENTLY (no warning): $(cat "${w1}")"
    fi
    [ "$(cat "${POOL_NE}/.hugmesh-pool-fingerprint")" = "${FP_A76}" ] \
        && ok "unstamped non-empty pool got stamped after the warning" \
        || bad "unstamped non-empty pool was not stamped"
else
    bad "unstamped non-empty pool wrongly REFUSED (should adopt-with-warning)"
fi
# an EMPTY unstamped pool must NOT warn (normal fresh-pool path stays quiet)
POOL_E="${TMP}/pool-unstamped-empty"; mkdir -p "${POOL_E}"
w2="${TMP}/w2.txt"
pool_fingerprint_preflight "${POOL_E}" "${MC_A76}" 2>"${w2}" || true
grep -qi 'UNSTAMPED' "${w2}" && bad "empty fresh pool warned (should be silent)" \
    || ok "empty fresh pool adopts SILENTLY (no spurious warning)"

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
[ "$(cat "${POOL}/.hugmesh-pool-fingerprint")" = "${FP_A76}" ] \
    && ok "refused build left the original a76 stamp intact" \
    || bad "refused build corrupted the stamp"

# (5) SALT (INSTALL_MASK/package.mask correctness pin) flips the fingerprint
FP_SALT="$(pool_fingerprint_of "${MC_A76}" "" "gettext-mo-fix-2026-07-08")"
[ -n "${FP_SALT}" ] && [ "${FP_SALT}" != "${FP_A76}" ] \
    && ok "correctness SALT change flips the fingerprint (forces a pool flush)" \
    || bad "SALT did not change the fingerprint"

# (6) STAMP MIGRATION (the PR #44 deferral): a pool stamped BEFORE the profile
# joined the fingerprint (empty PROFILE component — every pre-#44 x86 pool) is
# RESTAMPED, loudly and exactly once, when the SAME make.conf (same CHOST/CFLAGS/
# salt) gains a profile — never refused, never silent.
PROF="default/linux/amd64/23.0/hardened/selinux"
POOL_M="${TMP}/pool-migrate"; mkdir -p "${POOL_M}"
pool_fingerprint_preflight "${POOL_M}" "${MC_X86}" 2>/dev/null \
    || bad "migration fixture: could not stamp the legacy (no-profile) pool"
FP_X86_PROF="$(pool_fingerprint_of "${MC_X86}" "${PROF}")"
m1="${TMP}/m1.txt"
if pool_fingerprint_preflight "${POOL_M}" "${MC_X86}" "${PROF}" 2>"${m1}"; then
    grep -q 'MIGRATING' "${m1}" \
        && ok "empty->non-empty profile respelling RESTAMPS the pool (loud NOTICE)" \
        || bad "migration passed but was SILENT (a guard-key rewrite must be loud): $(cat "${m1}")"
    [ "$(cat "${POOL_M}/.hugmesh-pool-fingerprint")" = "${FP_X86_PROF}" ] \
        && ok "migrated stamp is the profile-keyed fingerprint" \
        || bad "migrated stamp wrong: $(cat "${POOL_M}/.hugmesh-pool-fingerprint")"
else
    bad "empty->non-empty profile respelling was REFUSED — the migration path is dead"
fi
# ... and exactly once: the second profile-keyed run matches the stamp silently.
m2="${TMP}/m2.txt"
if pool_fingerprint_preflight "${POOL_M}" "${MC_X86}" "${PROF}" 2>"${m2}"; then
    grep -q 'MIGRATING' "${m2}" \
        && bad "migration fired TWICE (must be unreachable once restamped)" \
        || ok "second run passes silently (migration is one-shot by construction)"
else
    bad "post-migration run wrongly refused the freshly restamped pool"
fi

# (7) MUTATION — the migration must never launder a REAL mismatch.
# (7a) foreign-board stamp + profile-keyed build: an a72 pool must still REFUSE an
#      a76 build even though the a76 build now supplies a profile (the migration
#      key is the a76 conf's OWN empty-profile spelling, which never equals the
#      a72 stamp — CFLAGS differ).
POOL_X="${TMP}/pool-mutation-a72"; mkdir -p "${POOL_X}"
pool_fingerprint_preflight "${POOL_X}" "${MC_A72}" 2>/dev/null   # legacy a72 stamp
mx="${TMP}/mx.txt"
if pool_fingerprint_preflight "${POOL_X}" "${MC_A76}" "arm64/23.0/hardened/selinux" 2>"${mx}"; then
    bad "MUTATION ESCAPED: a76+profile build ADOPTED an a72-stamped pool via migration (SIGILL hazard)"
else
    grep -q 'ABI MISMATCH' "${mx}" \
        && ok "a72-stamped pool still REFUSES an a76+profile build (migration cannot launder -mcpu)" \
        || { bad "refused but message unclear:"; cat "${mx}"; }
fi
[ "$(cat "${POOL_X}/.hugmesh-pool-fingerprint")" = "$(pool_fingerprint_of "${MC_A72}")" ] \
    && ok "refused mutation left the a72 stamp intact" \
    || bad "mutation corrupted the a72 stamp"
# (7b) profile-to-DIFFERENT-profile is NOT a migration: a pool stamped WITH profile
#      P1 must refuse a P2 build (the from-side of the migration is always the
#      EMPTY spelling, never another profile).
POOL_P="${TMP}/pool-mutation-prof"; mkdir -p "${POOL_P}"
pool_fingerprint_preflight "${POOL_P}" "${MC_X86}" "${PROF}" 2>/dev/null
mp="${TMP}/mp.txt"
if pool_fingerprint_preflight "${POOL_P}" "${MC_X86}" "default/linux/amd64/23.0/hardened" 2>"${mp}"; then
    bad "MUTATION ESCAPED: profile P1 pool adopted under profile P2 (profile change must refuse)"
else
    ok "profile-to-different-profile still REFUSES (migration only covers empty->non-empty)"
fi
# (7c) a salt mismatch is not laundered either: legacy no-salt stamp, salted+profiled
#      build — the migration key carries the NEW salt, so it cannot match.
POOL_S="${TMP}/pool-mutation-salt"; mkdir -p "${POOL_S}"
pool_fingerprint_preflight "${POOL_S}" "${MC_X86}" 2>/dev/null   # no profile, no salt
if pool_fingerprint_preflight "${POOL_S}" "${MC_X86}" "${PROF}" "gettext-mo-fix-2026-07-08" 2>/dev/null; then
    bad "MUTATION ESCAPED: salt change laundered through the profile migration"
else
    ok "profile migration does not launder a SALT change (correctness pins still flush)"
fi

# (0) empty fingerprint (no make.conf yet) is a no-op guard (never blocks a fresh tree)
POOL2="${TMP}/pool-empty"; mkdir -p "${POOL2}"
if pool_fingerprint_preflight "${POOL2}" "${TMP}/does-not-exist/make.conf"; then
    ok "missing make.conf → empty fingerprint → guard is a no-op (does not block)"
else
    bad "missing make.conf wrongly blocked the build"
fi

echo "== fingerprint guard: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
