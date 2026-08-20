#!/usr/bin/env bash
# test-host-bdep-pool.sh — regression test for the ARM host-side BDEPEND binpkg
# pool (PR #72 §4 design: scripts/_shared-assets-lib.sh sa_host_bdep_pool_* +
# its wiring in build-rpi5-stage4.sh / build-jetson-stage4.sh).
#
# WHAT THIS LEG IS: cross builds merge every BDEPEND "to /" — the builder
# container's own root — under crossdev's --root-deps=rdeps, and wave 1 (#46)
# measured 33–49 such amd64 host tools source-compiled per arm image because the
# container's default PKGDIR dies with the container. The leg
# <root>/pkgdir/host-amd64-bdep pools them across ALL arm boards, keyed by the
# HOST's identity (host make.conf + host profile + builder-toolchain salt),
# NEVER the target board's.
#
# HERMETIC (no build, no root): sources the REAL libraries, runs the real
# decisions against fixture make.conf files/pool dirs, and asserts:
#   (1) leg path shape + host-keying (one leg, no board component);
#   (2) fresh leg: guarded+stamped, HOST make.conf wired (PKGDIR + FEATURES
#       buildpkg binpkg-multi-instance), idempotent on re-run;
#   (3) container-reuse with a DIFFERENT root: a fresh block is appended and the
#       LAST PKGDIR assignment wins (make.conf semantics);
#   (4) salt change (rebuilt/upgraded builder) → the leg is FLUSHED and
#       restamped, loudly — never refused (no bricked builds), and never
#       silently reused (no mixed gcc/libc ABIs);
#   (5) matching identity does NOT flush (binpkgs survive);
#   (6) host-profile change → flush; #44-style MIGRATION (empty→non-empty
#       profile respelling, same everything else) restamps WITHOUT flushing —
#       consistent with the x86 pool's stamp-migration handling;
#   (7) missing host make.conf → wire refuses (caller builds unpooled);
#   (8) structural sweep: both ARM builders carry the resolution, the
#       hostguard-gated wire call at the HOST make.conf, the PLAN_ key, the
#       --usepkg/--binpkg-respect-use host-tools emerge, and never spell the
#       host leg into any other PKGDIR sink (target isolation).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/scripts/_shared-assets-lib.sh"
POOLLIB="${REPO}/scripts/_binpkg-pool-lib.sh"
[ -f "${LIB}" ]     || { echo "  FAIL lib missing: ${LIB}"; exit 1; }
[ -f "${POOLLIB}" ] || { echo "  FAIL lib missing: ${POOLLIB}"; exit 1; }
# shellcheck source=/dev/null
source "${LIB}"
# shellcheck source=/dev/null
source "${POOLLIB}"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
SA_QUIET=1

echo "== ARM host-side BDEPEND binpkg pool (#72 §4) =="

# Fixture HOST make.conf (amd64 — the builder container's own root).
mk_host_makeconf() { # <path>
    mkdir -p "$(dirname "$1")"
    { printf 'COMMON_FLAGS="-O2 -pipe"\n'
      printf 'CFLAGS="${COMMON_FLAGS}"\n'
      printf 'CXXFLAGS="${COMMON_FLAGS}"\n'
      printf 'FEATURES="parallel-fetch"\n'; } > "$1"
}
HOST_PROF="/var/db/repos/gentoo/profiles/default/linux/amd64/23.0"
SALT1="builder-toolchain:gcc=14.2.1:glibc=ldd (Gentoo 2.40) 2.40"
SALT2="builder-toolchain:gcc=15.1.0:glibc=ldd (Gentoo 2.41) 2.41"

# ── (1) leg path shape + host keying ──────────────────────────────────────────
ROOT="${TMP}/shared"
LEG="$(sa_host_bdep_pool_dir "${ROOT}")"
[ "${LEG}" = "${ROOT}/pkgdir/host-amd64-bdep" ] \
    && ok "1 leg = <root>/pkgdir/host-amd64-bdep (ONE leg, no board component)" \
    || bad "1 leg path wrong: ${LEG}"
if sa_host_bdep_pool_dir "" >/dev/null 2>&1; then
    bad "1 empty root yielded a leg (sharing-off must yield none)"
else
    ok "1 sharing off (empty root) yields NO leg"
fi

# ── (2) fresh leg: guard + stamp + HOST make.conf wiring, idempotent ──────────
MC="${TMP}/host/make.conf"; mk_host_makeconf "${MC}"
if sa_host_bdep_pool_wire "${LEG}" "${MC}" "${HOST_PROF}" "${SALT1}" 2>"${TMP}/w2.txt"; then
    ok "2 fresh leg: wire succeeds"
else
    bad "2 fresh leg wire failed: $(cat "${TMP}/w2.txt")"
fi
FP1="$(pool_fingerprint_of "${MC}" "${HOST_PROF}" "${SALT1}")"
[ "$(cat "${LEG}/.hugmesh-pool-fingerprint" 2>/dev/null)" = "${FP1}" ] \
    && ok "2 leg stamped with the HOST-identity fingerprint (host mc + host profile + salt)" \
    || bad "2 stamp wrong/missing: $(cat "${LEG}/.hugmesh-pool-fingerprint" 2>/dev/null)"
[ "$(_bpl_mc_get PKGDIR "${MC}")" = "${LEG}" ] \
    && ok "2 HOST make.conf PKGDIR now points at the leg" \
    || bad "2 HOST make.conf PKGDIR = '$(_bpl_mc_get PKGDIR "${MC}")'"
grep -qF 'FEATURES="${FEATURES} buildpkg binpkg-multi-instance"' "${MC}" \
    && ok "2 HOST FEATURES gains buildpkg + binpkg-multi-instance (concurrent-writer safety)" \
    || bad "2 FEATURES wiring missing"
n_before="$(grep -c '^PKGDIR=' "${MC}")"
sa_host_bdep_pool_wire "${LEG}" "${MC}" "${HOST_PROF}" "${SALT1}" 2>/dev/null \
    || bad "2 idempotent re-wire failed"
[ "$(grep -c '^PKGDIR=' "${MC}")" = "${n_before}" ] \
    && ok "2 re-wire is a no-op (no duplicate PKGDIR block)" \
    || bad "2 re-wire duplicated the PKGDIR block"

# ── (3) container reuse with a DIFFERENT shared root: last assignment wins ────
ROOT_B="${TMP}/shared-b"; LEG_B="$(sa_host_bdep_pool_dir "${ROOT_B}")"
sa_host_bdep_pool_wire "${LEG_B}" "${MC}" "${HOST_PROF}" "${SALT1}" 2>/dev/null \
    || bad "3 wire at a second root failed"
[ "$(_bpl_mc_get PKGDIR "${MC}")" = "${LEG_B}" ] \
    && ok "3 reused container, new root: a fresh block is appended and LAST PKGDIR wins" \
    || bad "3 stale PKGDIR still wins: $(_bpl_mc_get PKGDIR "${MC}")"

# ── (4) salt change (rebuilt builder) → FLUSH + restamp, loud, never refuse ───
mkdir -p "${LEG}/sys-apps/checkpolicy"
printf 'stale-abi-binpkg\n' > "${LEG}/sys-apps/checkpolicy/checkpolicy-3.11-1.gpkg.tar"
printf 'fake index\n' > "${LEG}/Packages"
w4="${TMP}/w4.txt"
if sa_host_bdep_pool_wire "${LEG}" "${MC}" "${HOST_PROF}" "${SALT2}" 2>"${w4}"; then
    grep -q 'FLUSHING' "${w4}" \
        && ok "4 builder-identity change FLUSHES the leg loudly (never refuses the build)" \
        || bad "4 mismatch passed SILENTLY (a guard rewrite must be loud): $(cat "${w4}")"
    [ -e "${LEG}/sys-apps/checkpolicy/checkpolicy-3.11-1.gpkg.tar" ] || [ -e "${LEG}/Packages" ] \
        && bad "4 stale host binpkgs SURVIVED the flush (mixed gcc/libc ABIs)" \
        || ok "4 stale host binpkgs are gone after the flush"
    FP2="$(pool_fingerprint_of "${MC}" "${HOST_PROF}" "${SALT2}")"
    [ "$(cat "${LEG}/.hugmesh-pool-fingerprint" 2>/dev/null)" = "${FP2}" ] \
        && ok "4 leg restamped with the NEW builder identity" \
        || bad "4 restamp wrong: $(cat "${LEG}/.hugmesh-pool-fingerprint" 2>/dev/null)"
else
    bad "4 identity change REFUSED the build (host leg must flush, not brick): $(cat "${w4}")"
fi

# ── (5) matching identity does NOT flush ──────────────────────────────────────
printf 'good-binpkg\n' > "${LEG}/keeper.gpkg.tar"
sa_host_bdep_pool_wire "${LEG}" "${MC}" "${HOST_PROF}" "${SALT2}" 2>"${TMP}/w5.txt" \
    || bad "5 matching identity was refused"
if [ -f "${LEG}/keeper.gpkg.tar" ] && ! grep -q 'FLUSHING' "${TMP}/w5.txt"; then
    ok "5 matching identity reuses the leg (no flush, binpkgs survive)"
else
    bad "5 matching identity flushed a valid leg"
fi

# ── (6) profile change → flush; empty→non-empty profile → #44-style MIGRATION ─
w6="${TMP}/w6.txt"
if sa_host_bdep_pool_wire "${LEG}" "${MC}" "${HOST_PROF}-hardened" "${SALT2}" 2>"${w6}"; then
    grep -q 'FLUSHING' "${w6}" \
        && ok "6 host-profile change flushes the leg (identity component, like the salt)" \
        || bad "6 profile change neither flushed nor failed: $(cat "${w6}")"
else
    bad "6 profile change refused the build"
fi
# migration consistency: a leg stamped with the EMPTY-profile spelling of the
# SAME identity is RESTAMPED (loud NOTICE: MIGRATING), NOT flushed — the same
# one-shot mechanics #72 shipped for the x86 pool stamps.
LEG_M="$(sa_host_bdep_pool_dir "${TMP}/shared-m")"
mkdir -p "${LEG_M}"
pool_fingerprint_preflight "${LEG_M}" "${MC}" "" "${SALT2}" 2>/dev/null \
    || bad "6 migration fixture: could not stamp the legacy (no-profile) leg"
printf 'abi-identical-binpkg\n' > "${LEG_M}/keeper.gpkg.tar"
m6="${TMP}/m6.txt"
if sa_host_bdep_pool_wire "${LEG_M}" "${MC}" "${HOST_PROF}" "${SALT2}" 2>"${m6}"; then
    if grep -q 'MIGRATING' "${m6}" && ! grep -q 'FLUSHING' "${m6}"; then
        ok "6 empty→non-empty profile respelling MIGRATES the stamp (no flush — #72 mechanics)"
    else
        bad "6 migration path broken (flushed an ABI-identical leg?): $(cat "${m6}")"
    fi
    [ -f "${LEG_M}/keeper.gpkg.tar" ] \
        && ok "6 migration preserved the leg's binpkgs" \
        || bad "6 migration destroyed the leg's binpkgs"
else
    bad "6 migration respelling was refused"
fi

# ── (7) missing host make.conf → wire refuses (caller builds unpooled) ────────
if sa_host_bdep_pool_wire "${LEG}" "${TMP}/does-not-exist/make.conf" "${HOST_PROF}" "${SALT2}" 2>/dev/null; then
    bad "7 wire succeeded against a MISSING host make.conf (nothing to wire)"
else
    ok "7 missing host make.conf refused (caller falls back to unpooled, loudly)"
fi

# ── (8) structural sweep: the two ARM builders carry the wiring ───────────────
# A functional test of the library cannot see a builder that was missed, and the
# HOST/TARGET separation is a seam a single silent revert would undo. Style of
# test-shared-build-assets.sh sweep K.
for b in build-rpi5-stage4.sh build-jetson-stage4.sh; do
    p="${REPO}/${b}"
    miss=""
    grep -qF 'HOST_BDEP_POOL_DIR="$(sa_host_bdep_pool_dir "${SHARED_ROOT}")"' "${p}" \
                                                              || miss+=" leg-resolution"
    # activation is gated on the shared root AND the hostguard AND root — the
    # exact gate every other host-mutation site uses.
    grep -qF '[ -n "${HOST_BDEP_POOL_DIR}" ] && hostguard_mutation_allowed && [ "$(id -u)" -eq 0 ]' "${p}" \
                                                              || miss+=" hostguard-gate"
    # the wire call targets the HOST make.conf, never the sysroot's.
    grep -qF 'sa_host_bdep_pool_wire "${HOST_BDEP_POOL_DIR}" /etc/portage/make.conf' "${p}" \
                                                              || miss+=" host-makeconf-wire"
    # unavailability degrades to UNPOOLED (legacy behavior), never an abort.
    grep -qF 'HOST_BDEP_POOL_DIR=""' "${p}"                   || miss+=" unpooled-fallback"
    # the plan states the leg on every channel (additive PLAN_ key).
    grep -qF '_plan HOST_BDEP_POOL     "${HOST_BDEP_POOL_DIR:-no (host bdeps not pooled)}"' "${p}" \
                                                              || miss+=" PLAN_HOST_BDEP_POOL"
    # the native host-tools emerge consumes the leg with respect-use intact.
    grep -qF 'emerge --noreplace --quiet --usepkg=y --binpkg-respect-use=y "${HOST_POLICY_TOOLS[@]}"' "${p}" \
                                                              || miss+=" host-tools-usepkg"
    # TARGET ISOLATION: the host leg must never be spelled into any other PKGDIR
    # sink — the ONLY 'PKGDIR.*HOST_BDEP_POOL_DIR' pairing allowed is none at all
    # (the lib wires the HOST make.conf; the sysroot make.conf gets POOL_DIR).
    grep -qE 'PKGDIR="?\$\{HOST_BDEP_POOL_DIR\}' "${p}"       && miss+=" host-leg-leaked-into-a-PKGDIR-sink"
    # ...and the target pool's own wiring is still intact (we sit NEXT to it).
    grep -qF "printf 'PKGDIR=\"%s\"\\n'  \"\${POOL_DIR}\"" "${p}" \
                                                              || miss+=" target-POOL_DIR-wiring-gone"
    [ -z "${miss}" ] && ok "8 ${b}: host-bdep pool wiring complete" \
                     || bad "8 ${b}: missing:${miss}"
done
# The cross_emerge flags that make the leg consumable are load-bearing for the
# whole feature: --usepkg=y consumes, --binpkg-respect-use=y preserves USE
# semantics per-package. They are the SAME flags the target pool relies on.
for b in build-rpi5-stage4.sh build-jetson-stage4.sh; do
    grep -q -- '--usepkg=y --binpkg-respect-use=y' "${REPO}/${b}" \
        && ok "8 ${b}: --usepkg=y --binpkg-respect-use=y semantics present" \
        || bad "8 ${b}: --binpkg-respect-use=y semantics missing"
done

echo "== host bdep pool: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
