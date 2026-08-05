#!/usr/bin/env bash
# test-rpi5-per-board-pkgdir.sh — regression test for the Pi per-board binpkg-pool
# isolation (shared-binpkg track, Lane 2).
#
# THE BUG THIS GUARDS (latent SIGILL): build-rpi5-stage4.sh builds rpi5/rpi4/rpi3
# from ONE script and ONE CHOST (aarch64-unknown-linux-gnu) but with DIFFERENT
# -mcpu — cortex-a76 (ARMv8.2-A, LSE atomics + dotprod) / cortex-a72 / cortex-a53
# (both ARMv8.0-A). Before the fix, BUILD_SUBDIR defaulted to the single literal
# "snap-build-pi5" for ALL THREE boards (set before argv parse; --board did not
# change it). rpi5 already consumes binpkgs (--usepkg), so building rpi5 then
# `--board rpi4` into the same WORK_DIR reused cortex-a76 binpkgs into an a72/a53
# image → SIGILL at runtime. portage's --binpkg-respect-use checks USE only, never
# -mcpu, so the ONLY guard is keeping each board's pkgdir in its OWN directory.
#
# WHAT THIS ASSERTS (NO real build — drives the REAL builder with --print-plan,
# which resolves+validates everything then exit 0 BEFORE any root/emerge/mutation):
#   (1) rpi5/rpi4/rpi3 each resolve to a DISTINCT BUILD_SUBDIR and PKGDIR pool.
#   (2) The defaults are exactly snap-build-pi5 / -pi4 / -pi3.
#   (3) An explicit --build-subdir / env BUILD_SUBDIR override still owns the build
#       TREE (the worklist wl-<id> isolation invariant), while the POOL is keyed on the
#       BOARD and therefore SHARED across entries — the shared-build-assets change (G2).
#       --no-shared-assets restores the legacy private per-BUILD_ROOT pool verbatim.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER="${REPO}/build-rpi5-stage4.sh"
[ -f "${BUILDER}" ] || { echo "  FAIL builder missing: ${BUILDER}"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== rpi5 per-board pkgdir isolation (Lane 2 / SIGILL guard) =="

WD="/tmp/sb-perboard-probe"   # fixed WORK_DIR so paths are deterministic + comparable

# plan_val <plan-output-file> <PLAN_KEY> → echoes the value (empty if absent)
plan_val() { sed -n "s/^PLAN_$2=//p" "$1"; }

# Run the REAL builder with --print-plan for one board; capture stdout+stderr.
# rpi3 is desktop-only (hard-errors on cluster roles) so it takes --role desktop.
run_plan() { # <board> <role> <outfile> [extra args...]
    local board="$1" role="$2" out="$3"; shift 3
    ( cd "${REPO}" && ./build-rpi5-stage4.sh \
        --board "${board}" --role "${role}" --env test -w "${WD}" \
        "$@" --print-plan ) >"${out}" 2>&1
}

O5="$(mktemp)"; O4="$(mktemp)"; O3="$(mktemp)"; OV="$(mktemp)"
trap 'rm -f "${O5}" "${O4}" "${O3}" "${OV}"' EXIT

run_plan rpi5 frontend "${O5}"           || { bad "rpi5 --print-plan exited non-zero"; cat "${O5}"; }
run_plan rpi4 frontend "${O4}"           || { bad "rpi4 --print-plan exited non-zero"; cat "${O4}"; }
run_plan rpi3 desktop  "${O3}"           || { bad "rpi3 --print-plan exited non-zero"; cat "${O3}"; }

SUB5="$(plan_val "${O5}" BUILD_SUBDIR)"; PKG5="$(plan_val "${O5}" PKGDIR)"
SUB4="$(plan_val "${O4}" BUILD_SUBDIR)"; PKG4="$(plan_val "${O4}" PKGDIR)"
SUB3="$(plan_val "${O3}" BUILD_SUBDIR)"; PKG3="$(plan_val "${O3}" PKGDIR)"

# (0) the plan MUST expose the seam at all (fails loudly if the PLAN_ keys move)
if [ -n "${SUB5}" ] && [ -n "${PKG5}" ]; then
    ok "builder emits PLAN_BUILD_SUBDIR + PLAN_PKGDIR (rpi5=${SUB5})"
else
    bad "builder did not emit PLAN_BUILD_SUBDIR/PLAN_PKGDIR — seam missing"
fi

# (1) exact per-board default subdir names
[ "${SUB5}" = "snap-build-pi5" ] && ok "rpi5 → snap-build-pi5" || bad "rpi5 subdir='${SUB5}' (want snap-build-pi5)"
[ "${SUB4}" = "snap-build-pi4" ] && ok "rpi4 → snap-build-pi4" || bad "rpi4 subdir='${SUB4}' (want snap-build-pi4)"
[ "${SUB3}" = "snap-build-pi3" ] && ok "rpi3 → snap-build-pi3" || bad "rpi3 subdir='${SUB3}' (want snap-build-pi3)"

# (2) the THREE pkgdir pools must be pairwise DISTINCT (the actual SIGILL guard)
if [ -n "${PKG5}" ] && [ "${PKG5}" != "${PKG4}" ] && [ "${PKG5}" != "${PKG3}" ] && [ "${PKG4}" != "${PKG3}" ]; then
    ok "three distinct pkgdir pools: ${PKG5##*/snap-build-} / ${PKG4##*/snap-build-} / ${PKG3##*/snap-build-}"
else
    bad "pkgdir pools NOT all distinct: pi5='${PKG5}' pi4='${PKG4}' pi3='${PKG3}'"
fi

# (3a) each pkgdir lives under its own BOARD-KEYED pool dir. CLAIM UPDATED by the
# shared-build-assets track: the pool moved from ${WORK_DIR}/<build-subdir>/pkgdir to
# ${WORK_DIR}/shared/pkgdir/<board-key>. The SIGILL-relevant property is unchanged and
# is what (2) above asserts — one directory per board, never shared across boards — but
# the pool is no longer fragmented by the per-entry build subdir (that was G2: every
# Studio wl-<id> build started from an EMPTY pool).
[ "${PKG5}" = "${WD}/shared/pkgdir/snap-build-pi5" ] && ok "rpi5 pool under shared/pkgdir/snap-build-pi5" || bad "rpi5 pkgdir='${PKG5}'"
[ "${PKG4}" = "${WD}/shared/pkgdir/snap-build-pi4" ] && ok "rpi4 pool under shared/pkgdir/snap-build-pi4" || bad "rpi4 pkgdir='${PKG4}'"
[ "${PKG3}" = "${WD}/shared/pkgdir/snap-build-pi3" ] && ok "rpi3 pool under shared/pkgdir/snap-build-pi3" || bad "rpi3 pkgdir='${PKG3}'"

# (3b) an EXPLICIT --build-subdir still owns the build TREE (the wl-<id> isolation
# invariant) but must NOT fragment the POOL any more — that is the whole point of G2.
run_plan rpi4 frontend "${OV}" --build-subdir wl-42
SUBV="$(plan_val "${OV}" BUILD_SUBDIR)"; PKGV="$(plan_val "${OV}" PKGDIR)"
if [ "${SUBV}" = "wl-42" ]; then
    ok "explicit --build-subdir wl-42 still owns the build TREE"
else
    bad "explicit --build-subdir ignored: subdir='${SUBV}' (want wl-42)"
fi
if [ "${PKGV}" = "${PKG4}" ]; then
    ok "wl-42 REUSES the rpi4 board pool (${PKGV}) — no per-entry empty pool"
else
    bad "wl-42 got its own pool '${PKGV}' (want the shared board pool '${PKG4}')"
fi

# (3b-ii) --no-shared-assets restores the LEGACY private per-BUILD_ROOT pool verbatim.
run_plan rpi4 frontend "${OV}" --build-subdir wl-42 --no-shared-assets
SUBN="$(plan_val "${OV}" BUILD_SUBDIR)"; PKGN="$(plan_val "${OV}" PKGDIR)"
SHN="$(plan_val "${OV}" SHARED_ASSETS)"
if [ "${SUBN}" = "wl-42" ] && [ "${PKGN}" = "${WD}/wl-42/pkgdir" ] && [ "${SHN}" = "off" ]; then
    ok "--no-shared-assets restores the legacy ${WD}/wl-42/pkgdir pool (SHARED_ASSETS=off)"
else
    bad "--no-shared-assets did not restore the legacy pool: subdir='${SUBN}' pkgdir='${PKGN}' shared='${SHN}'"
fi

# (3b-iii) the POOL KEY must follow --board, never the build subdir — a wl-<id> tree on
# rpi5 and one on rpi4 must still land in DIFFERENT pools (this is the SIGILL property
# under the new sharing, and it is the one that would silently break if the key drifted).
run_plan rpi5 frontend "${OV}" --build-subdir wl-42
PKGV5="$(plan_val "${OV}" PKGDIR)"; KEY5="$(plan_val "${OV}" POOL_KEY)"
if [ -n "${PKGV5}" ] && [ "${PKGV5}" != "${PKGV}" ] && [ "${KEY5}" = "snap-build-pi5" ]; then
    ok "same --build-subdir wl-42 on rpi5 vs rpi4 → DIFFERENT pools (key follows --board)"
else
    bad "pool key followed the subdir, not the board: rpi5='${PKGV5}' rpi4='${PKGV}' key='${KEY5}'"
fi

# (3c) an env BUILD_SUBDIR override also wins (worklist/env path)
( cd "${REPO}" && BUILD_SUBDIR=wl-env ./build-rpi5-stage4.sh \
    --board rpi4 --role frontend --env test -w "${WD}" --print-plan ) >"${OV}" 2>&1
SUBE="$(plan_val "${OV}" BUILD_SUBDIR)"
[ "${SUBE}" = "wl-env" ] && ok "env BUILD_SUBDIR=wl-env overrides the per-board default" \
                         || bad "env override ignored: subdir='${SUBE}' (want wl-env)"

echo "== per-board pkgdir: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
