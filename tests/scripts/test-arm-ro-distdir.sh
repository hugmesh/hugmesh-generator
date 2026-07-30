#!/usr/bin/env bash
# test-arm-ro-distdir.sh — regression test for the shared READ-ONLY distfiles wiring
# added to the 6 ARM builders (shared-binpkg track, Lane 3).
#
# WHAT / WHY: distfiles are arch-independent SOURCE tarballs, so a single fleet-wide
# cache is safe across every board (no ABI/-mcpu risk). x86 already reused an
# external cache read-only via PORTAGE_RO_DISTDIRS; Lane 3 generalizes that to the
# nine cross builders (rpi5/frite/jetson/orangepi5/orangepi-zero2[w]/orangepi-zero3/
# orangepi3-lts/orangepi4-lts) via a --distdir
# DIR flag (+ SNAP_DISTDIR_SRC env). When set to an existing dir the builder appends
# PORTAGE_RO_DISTDIRS="<dir>" to the rendered make.conf; new fetches still land in
# the build's PRIVATE ${BUILD_ROOT}/distfiles, so the shared pool is never written.
#
# HERMETIC (NO real build): the wiring is a self-contained block delimited by
# SB-RO-DISTFILES-BEGIN/END. Part 1 SLICES that exact block from each builder and
# executes it against fixture SYSROOT/make.conf + fixture distdir, asserting the RO
# line is added on a good path, NOT added (and warned) on a bad path, and never
# duplicated. Part 2 asserts every ARM builder actually carries the block + the
# --distdir parse arm + the SNAP_DISTDIR_SRC default (so none was missed).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARM_BUILDERS=(build-rpi5-stage4.sh build-frite-stage4.sh build-jetson-stage4.sh \
              build-orangepi5-stage4.sh build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh
              build-orangepi3-lts-stage4.sh build-orangepi4-lts-stage4.sh)

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== ARM shared READ-ONLY distfiles (Lane 3) =="

# ── Part 1 — FUNCTIONAL: slice the REAL block and run it against fixtures ──────
# Slice between the markers (inclusive of the guarded code, exclusive of markers).
slice_block() { # <builder-path>
    awk '/SB-RO-DISTFILES-BEGIN/{g=1;next} /SB-RO-DISTFILES-END/{g=0} g{print}' "$1"
}

run_block() { # <builder-path> <DISTDIR_SRC value> ; sets globals RC + MKCONF content
    local builder="$1" distdir="$2" block; block="$(slice_block "${builder}")"
    [ -n "${block}" ] || { echo "__EMPTY_SLICE__"; return 3; }
    local sysroot; sysroot="$(mktemp -d)"
    mkdir -p "${sysroot}/etc/portage"
    printf 'FEATURES="buildpkg"\nDISTDIR="/br/distfiles"\n' > "${sysroot}/etc/portage/make.conf"
    # Fixture env the block references; stub info/warn so nothing else is needed.
    SYSROOT="${sysroot}" BUILD_ROOT="/br" DISTDIR_SRC="${distdir}" \
    bash -c '
        set -u
        info() { :; }
        warn() { echo "WARN:$*"; }
        SYSROOT="'"${sysroot}"'"; BUILD_ROOT="/br"; DISTDIR_SRC="'"${distdir}"'"
        '"${block}"'
    '
    RC=$?
    MKCONF="$(cat "${sysroot}/etc/portage/make.conf")"
    rm -rf "${sysroot}"
}

# 1a — good path: DISTDIR_SRC is an existing dir ⇒ RO line appended (host path, not chroot)
GOODDIR="$(mktemp -d)"
run_block "${REPO}/build-frite-stage4.sh" "${GOODDIR}"
if printf '%s\n' "${MKCONF}" | grep -qx "PORTAGE_RO_DISTDIRS=\"${GOODDIR}\""; then
    ok "good path: PORTAGE_RO_DISTDIRS=\"<distdir>\" appended to make.conf"
else
    bad "good path: RO line missing. make.conf was:"; printf '%s\n' "${MKCONF}"
fi
# private DISTDIR must be untouched (new fetches stay private)
printf '%s\n' "${MKCONF}" | grep -qx 'DISTDIR="/br/distfiles"' \
    && ok "good path: private DISTDIR left intact (shared pool never written)" \
    || bad "good path: private DISTDIR was altered"

# 1b — bad path: DISTDIR_SRC set but not a directory ⇒ WARN + NO RO line
run_block "${REPO}/build-frite-stage4.sh" "/no/such/distdir/xyz"
if printf '%s\n' "${MKCONF}" | grep -q 'PORTAGE_RO_DISTDIRS'; then
    bad "bad path: RO line was appended for a nonexistent dir"
else
    ok "bad path: nonexistent --distdir ignored (no RO line), correct artifact"
fi

# 1c — empty (default): no flag ⇒ NO RO line (private-only)
run_block "${REPO}/build-frite-stage4.sh" ""
printf '%s\n' "${MKCONF}" | grep -q 'PORTAGE_RO_DISTDIRS' \
    && bad "empty default wrongly added an RO line" \
    || ok "empty default: private-only, no RO line"

# 1d — idempotent: block twice must not duplicate the RO line
run_block "${REPO}/build-frite-stage4.sh" "${GOODDIR}"   # first
# feed the resulting make.conf back through a second run
SYS2="$(mktemp -d)"; mkdir -p "${SYS2}/etc/portage"
printf '%s\n' "${MKCONF}" > "${SYS2}/etc/portage/make.conf"
BLOCK="$(slice_block "${REPO}/build-frite-stage4.sh")"
SYSROOT="${SYS2}" BUILD_ROOT="/br" DISTDIR_SRC="${GOODDIR}" bash -c '
    info() { :; }; warn() { :; }
    SYSROOT="'"${SYS2}"'"; BUILD_ROOT="/br"; DISTDIR_SRC="'"${GOODDIR}"'"
    '"${BLOCK}"'
'
n=$(grep -c 'PORTAGE_RO_DISTDIRS' "${SYS2}/etc/portage/make.conf")
[ "${n}" -eq 1 ] && ok "idempotent: RO line present exactly once after a second pass" \
                 || bad "idempotent: RO line count=${n} (want 1)"
rm -rf "${SYS2}" "${GOODDIR}"

# ── Part 2 — STRUCTURAL: every ARM builder carries the wiring ──────────────────
for b in "${ARM_BUILDERS[@]}"; do
    path="${REPO}/${b}"
    have_block=$(grep -c 'SB-RO-DISTFILES-BEGIN' "${path}")
    have_parse=$(grep -c 'DISTDIR_SRC="\$2"' "${path}")
    have_env=$(grep -c 'SNAP_DISTDIR_SRC' "${path}")
    if [ "${have_block}" -ge 1 ] && [ "${have_parse}" -ge 1 ] && [ "${have_env}" -ge 1 ]; then
        ok "${b}: has RO-distfiles block + --distdir parse + SNAP_DISTDIR_SRC env"
    else
        bad "${b}: missing wiring (block=${have_block} parse=${have_parse} env=${have_env})"
    fi
done

echo "== ARM RO distfiles: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
