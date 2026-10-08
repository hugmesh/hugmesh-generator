#!/usr/bin/env bash
# test-shared-build-assets.sh — EXECUTED-DECISION test for the shared build-asset root
# (scripts/_shared-assets-lib.sh + its wiring in the ten stage4 builders).
#
# WHY "EXECUTED-DECISION" AND NOT PARSE-ONLY (the #465 lesson): a gate that PARSES fine
# can still DECIDE wrong. Every assertion below therefore RUNS the real code and checks
# the DECISION it made — a cached seed actually reused, a corrupted one actually
# refused, a fingerprint-mismatched pool actually rejected, two writers actually
# serialised — never "the string appears in the file". The only greps here are the
# structural completeness sweep at the end, which asserts every builder carries the
# wiring at all (a functional test of ONE builder cannot see a builder that was missed).
#
# HERMETIC: no network, no root, no build. The library's fetch and verify hooks are
# injected (SA_FETCH_CMD / SA_VERIFY_CMD) so the seed flow runs against fixture files.
#
# What is asserted, in order:
#   A. root resolution      default / env override / explicit flag / opt-out
#   B. seed cache MISS      fetches once, verifies, returns the shared path
#   C. seed cache HIT       does NOT re-fetch, but DOES re-verify (never trusted)
#   D. WRONG-ARCH seed      an amd64 basename is refused for an arm64 build
#   E. CORRUPTED seed       discarded, re-fetched ONCE, then FAILS CLOSED
#   F. POISONED cache       a cached file that fails verification is never returned
#   G. pool fingerprint     a mismatched pool is REFUSED through the shared-root path
#   H. concurrency          two writers serialise under flock; re-entrancy no-deadlock
#   I. pool writer lock     a second concurrent build of one board is refused fast
#   J. opt-out              --no-shared-assets yields the legacy private paths
#   K. structural sweep     all ten builders carry the flags/lib/plan wiring
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
SA_QUIET=1          # keep the transcript readable; errors still print

echo "== shared build assets (seed cache + fleet distfiles + shared binpkg pool) =="

ARM_SEED="stage3-arm64-openrc-20260701T000000Z.tar.xz"
X86_SEED="stage3-amd64-hardened-openrc-20260701T000000Z.tar.xz"
URL="https://distfiles.example.invalid/releases/arm64/autobuilds/${ARM_SEED}"

# ── fixture fetch / verify hooks ───────────────────────────────────────────────
# ORIGIN is the "mirror": the fetch hook copies from it and records one line per call
# so a cache HIT is proven by the ABSENCE of a new fetch, not by a log message.
ORIGIN="${TMP}/origin"; mkdir -p "${ORIGIN}"
FETCH_LOG="${TMP}/fetch.log"; : >"${FETCH_LOG}"
printf 'GOOD-SEED-CONTENT\n' > "${ORIGIN}/${ARM_SEED}"

fixture_fetch() { # <url> <dest>
    printf '%s\n' "$1" >> "${FETCH_LOG}"
    local base="${1##*/}"
    [ -f "${ORIGIN}/${base}" ] || return 1
    cp "${ORIGIN}/${base}" "$2"
}
# The stand-in for dlv_verify_stage3: the same CONTRACT (file + DIGESTS url -> rc), so
# what is exercised is the library's decision logic, not curl/gpg.
fixture_verify() { # <file> <digests-url>
    [ -f "$1" ] || return 1
    grep -qx 'GOOD-SEED-CONTENT' "$1"
}
export -f fixture_fetch fixture_verify 2>/dev/null || true
SA_FETCH_CMD=fixture_fetch
SA_VERIFY_CMD=fixture_verify

fetch_count() { wc -l < "${FETCH_LOG}" | tr -d ' '; }

# ── A. root resolution ─────────────────────────────────────────────────────────
WD="${TMP}/work"
unset HUGMESH_SHARED_ASSETS
SHARED_ASSETS_ENABLED=true
[ "$(sa_root "${WD}")" = "${WD}/shared" ] \
    && ok "A default root = <work-dir>/shared (inside the existing docker -v WORK_DIR:/out mount)" \
    || bad "A default root = $(sa_root "${WD}")"
[ "$(sa_root "${WD}" "/srv/fleet")" = "/srv/fleet" ] \
    && ok "A explicit --shared-assets wins over the default" \
    || bad "A explicit root ignored"
HUGMESH_SHARED_ASSETS="/srv/env" \
    && [ "$(sa_root "${WD}")" = "/srv/env" ] \
    && ok "A HUGMESH_SHARED_ASSETS env override honoured (pool outside WORK_DIR)" \
    || bad "A env override ignored"
[ "$(sa_root "${WD}" "/srv/flag")" = "/srv/flag" ] \
    && ok "A argv beats env (precedence: argv > env > default)" \
    || bad "A precedence wrong"
unset HUGMESH_SHARED_ASSETS
SHARED_ASSETS_ENABLED=false
[ -z "$(sa_root "${WD}")" ] && ok "A opt-out: sa_root yields no shared root" || bad "A opt-out leaked a root"
SHARED_ASSETS_ENABLED=true
[ "$(sa_pool_dir "${WD}/shared" snap-build-pi4)" = "${WD}/shared/pkgdir/snap-build-pi4" ] \
    && ok "A pool dir is keyed per BOARD (<root>/pkgdir/<board-key>)" || bad "A pool dir shape wrong"
[ "$(sa_seed_dir "${WD}/shared" aarch64)" = "${WD}/shared/seed/arm64" ] \
    && ok "A seed dir is keyed per ARCH, normalised (aarch64 -> arm64)" || bad "A seed dir shape wrong"
# path-component safety: a traversal must never escape the root
if sa_pool_dir "${WD}/shared" "../../etc" >/dev/null 2>&1; then
    bad "A a traversal pool key was accepted"
else
    ok "A traversal pool key '../../etc' REFUSED (cannot escape the shared root)"
fi

# ── B. cache MISS: fetch once, verify, return the shared path ─────────────────
ROOT="${TMP}/root-b"
got="$(sa_seed_acquire "${ROOT}" arm64 "${ARM_SEED}" "${URL}" "${TMP}/private-b/${ARM_SEED}")"
rc=$?
if [ ${rc} -eq 0 ] && [ "${got}" = "${ROOT}/seed/arm64/${ARM_SEED}" ] && [ -f "${got}" ]; then
    ok "B cache MISS: seed fetched into the per-arch shared dir and returned verified"
else
    bad "B cache miss rc=${rc} path='${got}'"
fi
[ "$(fetch_count)" = "1" ] && ok "B cache MISS did exactly ONE fetch" || bad "B fetches=$(fetch_count) (want 1)"

# ── C. cache HIT: no second fetch, but verification RUNS AGAIN ────────────────
VERIFY_LOG="${TMP}/verify.log"; : >"${VERIFY_LOG}"
counting_verify() { printf '%s\n' "$1" >> "${VERIFY_LOG}"; fixture_verify "$@"; }
SA_VERIFY_CMD=counting_verify
got2="$(sa_seed_acquire "${ROOT}" arm64 "${ARM_SEED}" "${URL}" "${TMP}/private-b/${ARM_SEED}")"
if [ "${got2}" = "${got}" ] && [ "$(fetch_count)" = "1" ]; then
    ok "C cache HIT: the cached seed is REUSED (no second ~250 MB download)"
else
    bad "C cache hit re-fetched: fetches=$(fetch_count) path='${got2}'"
fi
if [ "$(wc -l < "${VERIFY_LOG}" | tr -d ' ')" = "1" ]; then
    ok "C cache HIT still RE-VERIFIES (a cache is never trusted; poisoning is caught)"
else
    bad "C verification did not run on the cache hit"
fi
SA_VERIFY_CMD=fixture_verify

# ── D. wrong-arch seed ────────────────────────────────────────────────────────
errf="${TMP}/err-d.txt"
if out="$(sa_seed_acquire "${ROOT}" arm64 "${X86_SEED}" "${URL}" "${TMP}/p/${X86_SEED}" 2>"${errf}")"; then
    bad "D an amd64 seed was ACCEPTED for an arm64 build (path='${out}')"
else
    if grep -q 'arm64' "${errf}"; then
        ok "D wrong-arch seed REFUSED (amd64 tarball unusable by an arm64 build)"
    else
        bad "D refused but the message does not name the arch: $(cat "${errf}")"
    fi
fi
# …and the mirror image: an arm64 seed offered to an amd64 build.
if sa_seed_acquire "${ROOT}" amd64 "${ARM_SEED}" "${URL}" "${TMP}/p/x" >/dev/null 2>&1; then
    bad "D an arm64 seed was accepted for an amd64 build"
else
    ok "D per-arch keying is symmetric (arm64 seed refused for amd64)"
fi

# ── E/F. corrupted + poisoned cache ───────────────────────────────────────────
# A cached file whose content no longer verifies must be discarded, re-fetched ONCE,
# and — when the mirror is ALSO bad — the build must fail closed with NO path returned.
ROOT_E="${TMP}/root-e"; mkdir -p "${ROOT_E}/seed/arm64"
printf 'POISONED\n' > "${ROOT_E}/seed/arm64/${ARM_SEED}"
: >"${FETCH_LOG}"
printf 'POISONED-MIRROR\n' > "${ORIGIN}/${ARM_SEED}"          # the re-fetch is bad too
errf="${TMP}/err-e.txt"
if out="$(sa_seed_acquire "${ROOT_E}" arm64 "${ARM_SEED}" "${URL}" "${TMP}/p/${ARM_SEED}" 2>"${errf}")"; then
    bad "E a POISONED cached seed was returned (path='${out}') — unverified unpack"
else
    ok "E poisoned cached seed FAILS CLOSED (no path returned, build cannot unpack)"
fi
[ "$(fetch_count)" = "1" ] \
    && ok "E poisoned cache is discarded and re-fetched exactly ONCE (then fails closed)" \
    || bad "E re-fetch count=$(fetch_count) (want exactly 1)"
[ -f "${ROOT_E}/seed/arm64/${ARM_SEED}" ] \
    && bad "E the unverified seed was left in the cache for the next build to reuse" \
    || ok "E the unverified seed is REMOVED from the shared cache (not left to rot)"
# F — recovery: a cache poisoned while the MIRROR is good must self-heal in one go.
printf 'GOOD-SEED-CONTENT\n' > "${ORIGIN}/${ARM_SEED}"
printf 'POISONED\n' > "${ROOT_E}/seed/arm64/${ARM_SEED}"
: >"${FETCH_LOG}"
if out="$(sa_seed_acquire "${ROOT_E}" arm64 "${ARM_SEED}" "${URL}" "${TMP}/p/${ARM_SEED}" 2>/dev/null)" \
   && grep -qx 'GOOD-SEED-CONTENT' "${out}"; then
    ok "F poisoned cache + good mirror: re-fetched and returned a VERIFIED seed"
else
    bad "F recovery from a poisoned cache failed"
fi

# ── G. fingerprint-mismatched pool through the SHARED path ────────────────────
mk_makeconf() { # <path> <chost> <cflags>
    mkdir -p "$(dirname "$1")"
    { printf 'CHOST="%s"\n' "$2"; printf 'COMMON_FLAGS=""\n'; printf 'CFLAGS="%s"\n' "$3"
      printf 'CXXFLAGS="${CFLAGS}"\n'; } > "$1"
}
MC_A76="${TMP}/mc/pi5.conf"; mk_makeconf "${MC_A76}" aarch64-unknown-linux-gnu "-mcpu=cortex-a76 -O2"
MC_A72="${TMP}/mc/pi4.conf"; mk_makeconf "${MC_A72}" aarch64-unknown-linux-gnu "-mcpu=cortex-a72 -O2"
POOL="$(sa_pool_dir "${TMP}/root-g" snap-build-pi5)"; mkdir -p "${POOL}"
if sa_pool_guard "${POOL}" "${MC_A76}"; then
    ok "G fresh shared pool: fingerprint stamped, build proceeds"
else
    bad "G fresh shared pool was refused"
fi
errf="${TMP}/err-g.txt"
if sa_pool_guard "${POOL}" "${MC_A72}" 2>"${errf}"; then
    bad "G an a72 build REUSED an a76-stamped shared pool — the SIGILL hazard is back"
else
    grep -q 'SIGILL' "${errf}" && grep -q 'ABI MISMATCH' "${errf}" \
        && ok "G fingerprint-mismatched shared pool REFUSED (SIGILL/ABI message intact)" \
        || { bad "G refused but message unclear:"; cat "${errf}"; }
fi
if sa_pool_guard "${POOL}" "${MC_A76}"; then
    ok "G the matching build still passes after a refusal (guard is not sticky)"
else
    bad "G a matching build was refused after an earlier mismatch"
fi

# ── H. concurrency: flock serialises writers; re-entrancy does not deadlock ───
LOCK="${TMP}/conc.lock"
ORDER="${TMP}/order.txt"; : >"${ORDER}"
writer() { # <tag>
    sa_lock_run "${LOCK}" bash -c "printf '%s-in\n' '$1' >> '${ORDER}'; sleep 0.4; printf '%s-out\n' '$1' >> '${ORDER}'"
}
( source "${LIB}"; SA_QUIET=1; SA_LOCK_WAIT=30
  sa_lock_run "${LOCK}" bash -c "printf 'A-in\n' >> '${ORDER}'; sleep 0.4; printf 'A-out\n' >> '${ORDER}'" ) &
w1=$!
sleep 0.1
( source "${LIB}"; SA_QUIET=1; SA_LOCK_WAIT=30
  sa_lock_run "${LOCK}" bash -c "printf 'B-in\n' >> '${ORDER}'; sleep 0.1; printf 'B-out\n' >> '${ORDER}'" ) &
w2=$!
wait ${w1} ${w2}
seq="$(tr '\n' ' ' < "${ORDER}")"
case "${seq}" in
    "A-in A-out B-in B-out "|"B-in B-out A-in A-out ")
        ok "H two concurrent writers SERIALISED by flock (no interleave: ${seq%% })" ;;
    *)  bad "H concurrent writers interleaved: ${seq}" ;;
esac
# re-entrancy: the SAME shell taking the SAME lock twice must not deadlock.
RE="${TMP}/reentrant.txt"; : >"${RE}"
SA_LOCK_WAIT=5
if sa_lock_run "${LOCK}" bash -c 'true' \
   && sa_lock_run "${LOCK}" sa_lock_run "${LOCK}" true 2>/dev/null; then
    ok "H re-entrant: one build taking its own lock twice does NOT deadlock"
else
    # nested via the same shell (function call, not a subprocess)
    inner() { sa_lock_run "${LOCK}" true; }
    if sa_lock_run "${LOCK}" inner; then
        ok "H re-entrant: one build taking its own lock twice does NOT deadlock"
    else
        bad "H re-entrant lock deadlocked or failed"
    fi
fi
SA_LOCK_WAIT=1800

# ── I. pool writer lock: a second concurrent build of one board is refused ────
POOL_I="$(sa_pool_dir "${TMP}/root-i" snap-build-frite)"; mkdir -p "${POOL_I}"
HOLDER="${TMP}/holder.sh"
# `exec sleep` (not a child `sleep`) is load-bearing: the lock fd is INHERITED by child
# processes — which is what keeps it held across the builder's whole emerge tree — so a
# forked `sleep` would outlive a SIGKILLed parent and keep the lock, testing nothing.
cat >"${HOLDER}" <<EOF
source "${LIB}"
SA_QUIET=1
sa_pool_hold "${POOL_I}" || exit 9
touch "${TMP}/holding"
exec sleep 30
EOF
bash "${HOLDER}" &
hpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -f "${TMP}/holding" ] && break
    sleep 0.1
done
errf="${TMP}/err-i.txt"
if ( source "${LIB}"; SA_QUIET=1; sa_pool_hold "${POOL_I}" ) 2>"${errf}"; then
    bad "I a SECOND concurrent writer got the same shared pool (binpkg corruption window)"
else
    grep -q 'binpkg-multi-instance' "${errf}" \
        && ok "I second concurrent writer REFUSED fast, naming the single-writer rule" \
        || { bad "I refused but message unclear:"; cat "${errf}"; }
fi
# SIGKILL the holder to simulate a CRASHED build (the case the comment in sa_pool_hold
# claims is safe): the kernel must drop the flock, so the next build takes it.
kill -9 ${hpid} 2>/dev/null; wait ${hpid} 2>/dev/null
took=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ( source "${LIB}"; SA_QUIET=1; sa_pool_hold "${POOL_I}" ) 2>/dev/null; then took=true; break; fi
    sleep 0.1
done
if ${took}; then
    ok "I a CRASHED (SIGKILLed) holder never wedges the pool (kernel releases the flock)"
else
    bad "I the pool stayed locked after its holder was killed"
fi

# ── J. opt-out end-to-end: the legacy private paths, byte-for-byte ────────────
SHARED_ASSETS_ENABLED=false
PRIV="${TMP}/private-j/${ARM_SEED}"
got3="$(sa_seed_acquire "$(sa_root "${WD}")" arm64 "${ARM_SEED}" "${URL}" "${PRIV}")"
if [ "${got3}" = "${PRIV}" ] && [ -f "${PRIV}" ]; then
    ok "J opt-out: the seed lands at the PRIVATE per-build path (legacy behaviour)"
else
    bad "J opt-out seed path='${got3}' (want ${PRIV})"
fi
SHARED_ASSETS_ENABLED=true

# ── K. structural sweep: every builder carries the wiring ────────────────────
# A functional test of one builder cannot see a builder that was MISSED, so assert the
# whole fleet. Each probe is a distinct required seam, not a vague grep for a word.
BUILDERS=(build-x86-host-stage4.sh build-rpi5-stage4.sh build-frite-stage4.sh
          build-jetson-stage4.sh build-orangepi5-stage4.sh build-orangepi-zero2-stage4.sh
          build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh
          build-orangepi3-lts-stage4.sh build-orangepi4-lts-stage4.sh)
for b in "${BUILDERS[@]}"; do
    p="${REPO}/${b}"
    miss=""
    grep -q 'scripts/_shared-assets-lib.sh' "${p}"           || miss+=" lib-source"
    grep -q -- '--shared-assets)' "${p}"                     || miss+=" --shared-assets"
    grep -q -- '--no-shared-assets)' "${p}"                  || miss+=" --no-shared-assets"
    grep -q 'sa_seed_acquire' "${p}"                         || miss+=" sa_seed_acquire"
    grep -q '_plan SHARED_ASSETS' "${p}"                     || miss+=" PLAN_SHARED_ASSETS"
    grep -q 'HUGMESH_SHARED_ASSETS' "${p}"                   || miss+=" env-override"
    # The seed download must go through the library — a leftover inline
    # `[ -f "${STAGE3_LOCAL}" ] || curl` would silently skip re-verification.
    grep -q 'STAGE3_LOCAL="\${BUILD_ROOT}' "${p}"            && miss+=" legacy-seed-path"
    [ -z "${miss}" ] && ok "K ${b}: full shared-assets wiring" || bad "K ${b}: missing:${miss}"
done
# x86 (issue #46): the pool is the SHARED per-arch dir (snap-build-x86) BIND-MOUNTED
# over the chroot's PKGDIR (/var/cache/binpkgs) — its own seams, distinct from the
# cross builders' make.conf PKGDIR rewrite. Each probe is one required link in the
# chain; losing any single one silently reverts wave-1's 0% reuse or, worse, lets
# the Phase-8 rm -rf reach THROUGH a still-attached bind into the fleet's pool.
p="${REPO}/build-x86-host-stage4.sh"
miss=""
grep -q 'X86_POOL_DIR="$(sa_pool_dir "${SHARED_ROOT}" "${BOARD_POOL_KEY}")"' "${p}" \
                                                              || miss+=" pool-dir-resolution"
grep -q 'sa_pool_hold "${X86_POOL_DIR}"' "${p}"               || miss+=" sa_pool_hold"
grep -q 'sa_pool_guard "${X86_POOL_DIR}" "${SYSROOT}/etc/portage/make.conf" "${PROFILE_PATH}"' "${p}" \
                                                              || miss+=" profile-keyed-shared-guard"
grep -q 'pool_fingerprint_preflight "${SYSROOT}/var/cache/binpkgs" "${SYSROOT}/etc/portage/make.conf" "${PROFILE_PATH}"' "${p}" \
                                                              || miss+=" profile-keyed-private-guard"
grep -q 'mount --bind "${X86_POOL_DIR}" "${SYSROOT}/var/cache/binpkgs"' "${p}" \
                                                              || miss+=" bind-mount"
# The detach on exit: since #659 umount_chroot peels the pool bind through
# hmr_umount_own (one layer, then a layer count that says so when the bind did
# not go) and resets the flag on the same line, where it used to be a bare
# `umount -l` gated on X86_POOL_MOUNTED.
grep -qE 'hmr_umount_own "\$\{SYSROOT\}/var/cache/binpkgs".*X86_POOL_MOUNTED=false' "${p}" \
                                                              || miss+=" umount-on-exit"
grep -q 'mountpoint -q "${SYSROOT}/var/cache/binpkgs"' "${p}" || miss+=" post-umount-guard"
grep -q '_plan SHARED_POOL        "${X86_POOL_DIR' "${p}"     || miss+=" PLAN_SHARED_POOL"
[ -z "${miss}" ] && ok "K build-x86-host-stage4.sh: shared POOL wiring (bind + guard + writer lock + detach guards)" \
                 || bad "K build-x86-host-stage4.sh: missing:${miss}"
# ... and the OLD profile-less preflight spelling must never come back (PR #44
# deferral: an empty PROFILE component was exactly the un-keyed stamp being migrated).
grep -qE 'pool_fingerprint_preflight "\$\{SYSROOT\}/var/cache/binpkgs" "\$\{SYSROOT\}/etc/portage/make.conf" ""' "${p}" \
    && bad "K build-x86-host-stage4.sh: profile-LESS preflight resurrected (empty PROFILE component)" \
    || ok "K build-x86-host-stage4.sh: no profile-less preflight remains"

# The nine CROSS builders additionally route their POOL through the shared root.
for b in "${BUILDERS[@]}"; do
    [ "${b}" = "build-x86-host-stage4.sh" ] && continue    # x86 pool seams asserted above
    p="${REPO}/${b}"
    miss=""
    grep -q 'sa_pool_guard "\${POOL_DIR}"' "${p}"            || miss+=" sa_pool_guard"
    grep -q 'sa_pool_hold "\${POOL_DIR}"' "${p}"             || miss+=" sa_pool_hold"
    grep -q 'SB-SHARED-ASSETS-BEGIN' "${p}"                  || miss+=" make.conf-block"
    grep -q '_plan PKGDIR             "\${POOL_DIR}"' "${p}" || miss+=" PLAN_PKGDIR"
    grep -q 'BOARD_POOL_KEY=' "${p}"                         || miss+=" BOARD_POOL_KEY"
    grep -q 'pool_fingerprint_preflight "\${BUILD_ROOT}/pkgdir"' "${p}" && miss+=" unguarded-legacy-preflight"
    [ -z "${miss}" ] && ok "K ${b}: shared POOL wiring (guard + writer lock + make.conf)" \
                     || bad "K ${b}: missing:${miss}"
done

echo "== shared build assets: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
