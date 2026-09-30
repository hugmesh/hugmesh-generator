#!/usr/bin/env bash
# test-builder-unmount-real.sh — the builder's unmount path against REAL,
# STACKED bind mounts, in a private user+mount namespace (no root).
#
# hugmesh-generator#659: after one successful x86 build three bind mounts of
# <sysroot>/var/cache/distfiles-ro were stacked under the build system, the
# next non-resume build refused to start, and the hint it printed —
# `umount -R '<sysroot>'` — names a directory that is not a mount point and
# does nothing. tests/scripts/test-builder-resume-safety.sh proves the code
# with stubs; THIS file proves it against the kernel:
#
#   1. a bind stacked three times is listed three times by the builder's
#      hmr_stale_mounts (that is how /proc/self/mountinfo reports it);
#   2. the builder's OWN umount_chroot (extracted from the builder text) with
#      DISTFILES_MOUNTED=true removes exactly ONE layer of distfiles-ro — the
#      one this run made — and leaves the other two (somebody else's), while
#      removing the run/dev/sys/proc binds it owns including a submount;
#   3. the OLD hint, `umount -R <sysroot>`, leaves every mount in place;
#   4. the NEW hint (the exact command the refusal prints, executed) clears
#      every stacked layer and every submount, so the next build can start.
#
# Needs `unshare -Urm` (user + mount namespaces). Docker's default seccomp
# profile blocks them, so no shell-suites CI container can run this: it exits
# 2 SKIPPED-LOUDLY there and is listed in tests/scripts/test-guard-integrity.sh
# with that reason; run it on a developer host. Same convention as
# tests/stack/test-tor-onion-mechanism.sh.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TEST_DIR}/../.." && pwd)"
LIB="${REPO}/scripts/_builder-resume-lib.sh"
X86="${REPO}/build-x86-host-stage4.sh"
WALL="${WALL:-60}"

[ -f "${LIB}" ] || { echo "MISSING: ${LIB}"; exit 2; }
[ -f "${X86}" ] || { echo "MISSING: ${X86}"; exit 2; }

if [ "${1:-}" != "--inner" ]; then
    for t in unshare findmnt mountpoint umount mount; do
        command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED-LOUDLY: $t is not on PATH — this guard checked NOTHING (util-linux needed)"; exit 2; }
    done
    if ! unshare -Urm true 2>/dev/null; then
        echo "SKIPPED-LOUDLY: unshare -Urm is not permitted here (user+mount namespaces blocked, e.g. docker's default seccomp) — this guard checked NOTHING; run it on a developer host"
        exit 2
    fi
    exec timeout "${WALL}" unshare -Urm bash "${BASH_SOURCE[0]}" --inner
fi

# ── inside the namespace: uid 0 as far as mount(2) is concerned ──────────────
P=0; F=0
ok()  { P=$((P+1)); echo "  PASS $*"; }
bad() { F=$((F+1)); echo "  FAIL $*"; }
# Make every mount private so nothing propagates out (paranoia: the namespace
# is already ours, but a shared root would otherwise mirror the binds).
mount --make-rprivate / 2>/dev/null || true

TDIR="$(mktemp -d)"
SR="${TDIR}/snap-build-x86/sysroot"
mkdir -p "${SR}/var/cache/distfiles-ro" "${SR}/dev/pts" "${SR}/run" "${SR}/sys" "${SR}/proc" "${SR}/var/tmp/portage" \
         "${SR}/var/db/repos/gentoo" "${SR}/var/cache/binpkgs" "${TDIR}/src-a" "${TDIR}/src-b" "${TDIR}/src-c" "${TDIR}/dev-src/pts" "${TDIR}/pts-src"
echo a > "${TDIR}/src-a/which"; echo b > "${TDIR}/src-b/which"; echo c > "${TDIR}/src-c/which"
cleanup() {
    findmnt -rn -o TARGET | grep -a "^${TDIR}/" | sort -r | while read -r m; do umount -l "$m" 2>/dev/null || true; done
    rm -rf "${TDIR}"
}
trap cleanup EXIT

# shellcheck source=../../scripts/_builder-resume-lib.sh
. "${LIB}"
banner() { echo "==> $1"; }; info() { echo "    $1"; }; warn() { echo "    WARNING: $1"; }; err() { echo "    ERROR: $1" >&2; }

echo "== real stacked binds under a scratch build system (unshare -Urm) =="
# Two layers "from earlier runs", then the one "this run" makes; plus this run's
# dev bind with a submount (dev/pts), as mount --rbind /dev produces.
mount --bind "${TDIR}/src-a" "${SR}/var/cache/distfiles-ro" || bad "bind a"
mount --bind "${TDIR}/src-b" "${SR}/var/cache/distfiles-ro" || bad "bind b"
mount --bind "${TDIR}/src-c" "${SR}/var/cache/distfiles-ro" || bad "bind c"
mount --bind "${TDIR}/dev-src" "${SR}/dev" || bad "bind dev"
mount --bind "${TDIR}/pts-src" "${SR}/dev/pts" || bad "bind dev/pts"
listing="$(hmr_stale_mounts "${SR}")"
n_dist="$(printf '%s\n' "${listing}" | grep -a -c "distfiles-ro")"
n_all="$(printf '%s\n' "${listing}" | grep -a -c .)"
[ "${n_dist}" -eq 3 ] && [ "${n_all}" -eq 5 ] && [ "$(cat "${SR}/var/cache/distfiles-ro/which")" = c ] \
    && ok "1. hmr_stale_mounts lists the 3 stacked distfiles-ro layers as 3 lines (+ dev, dev/pts = 5); the top layer is c" \
    || bad "1. listing: dist=${n_dist} all=${n_all}: ${listing}"

# 2. the builder's own umount_chroot, extracted from its text.
awk 'BEGIN{on=0} /^umount_chroot\(\) \{$/ {on=1} on {print} on && /^\}$/ {exit}' "${X86}" > "${TDIR}/umount_chroot.sh"
[ -s "${TDIR}/umount_chroot.sh" ] || { bad "could not extract umount_chroot from the builder"; echo "== ${P} passed, ${F} failed =="; exit 1; }
SYSROOT="${SR}"
DISTFILES_MOUNTED=true; PORTAGE_SCRATCH_MOUNTED=false; HOST_REPO_MOUNTED=false; X86_POOL_MOUNTED=false
# shellcheck disable=SC1090
. "${TDIR}/umount_chroot.sh"
# (called in THIS shell, not a command substitution: the flag reset must be visible here)
umount_chroot > "${TDIR}/umount.out" 2>&1; rc=$?
out="$(cat "${TDIR}/umount.out")"
listing="$(hmr_stale_mounts "${SR}")"
n_dist="$(printf '%s\n' "${listing}" | grep -a -c "distfiles-ro")"
n_dev="$(printf '%s\n' "${listing}" | grep -a -c "/dev")"
if [ "${rc}" -eq 0 ] && [ "${n_dist}" -eq 2 ] && [ "${n_dev}" -eq 0 ] && [ "$(cat "${SR}/var/cache/distfiles-ro/which")" = b ] \
   && [ "${DISTFILES_MOUNTED}" = false ] && [ -z "${out}" ]; then
    ok "2. umount_chroot removed exactly ONE distfiles-ro layer (its own; b is now on top, a below) and dev + dev/pts; the other two layers stay; flag reset; no warning"
else
    bad "2. umount_chroot: rc=${rc} dist=${n_dist} dev=${n_dev} top=$(cat "${SR}/var/cache/distfiles-ro/which" 2>/dev/null) flag=${DISTFILES_MOUNTED} out=${out}"
fi

# 3. the OLD hint does nothing useful: the sysroot dir is not a mount point.
out="$(umount -R "${SR}" 2>&1)"; rc=$?
n_after="$(hmr_stale_mounts "${SR}" | grep -a -c .)"
[ "${rc}" -ne 0 ] && [ "${n_after}" -eq 2 ] && ok "3. the OLD hint 'umount -R <sysroot>' fails (rc=${rc}: ${out}) and leaves both remaining layers" \
    || bad "3. old hint: rc=${rc} remaining=${n_after}: ${out}"

# 4. the NEW hint, exactly as the refusal prints it, executed: everything under the sysroot is gone.
# Re-stack first so the loop is exercised on stacked layers AND a submount.
mount --bind "${TDIR}/src-c" "${SR}/var/cache/distfiles-ro"
mount --bind "${TDIR}/dev-src" "${SR}/dev"; mount --bind "${TDIR}/pts-src" "${SR}/dev/pts"
before="$(hmr_stale_mounts "${SR}" | grep -a -c .)"
hint="$(hmr_stale_mount_hint "${SR}")"
out="$(bash -c "${hint}" 2>&1)"; rc=$?
n_after="$(hmr_stale_mounts "${SR}" | grep -a -c .)"
[ "${before}" -eq 5 ] && [ "${rc}" -eq 0 ] && [ "${n_after}" -eq 0 ] && [ -z "${out}" ] \
    && ok "4. the NEW hint cleared all 5 mounts (3 stacked layers + dev + its submount) with no error: ${hint}" \
    || bad "4. new hint: before=${before} rc=${rc} after=${n_after}: ${out}"
# and the Extract-phase refusal text names that same command
out="$(hmr_stale_mount_refuse "${SR}" "x" 2>&1)"
printf '%s' "${out}" | grep -a -F "${hint}" >/dev/null && ok "4b. the refusal prints exactly that command" || bad "4b. refusal text: ${out}"

# 5. hmr_verify_detached against real state.
mount --bind "${TDIR}/src-a" "${SR}/var/cache/distfiles-ro"
out="$(hmr_verify_detached "${SR}/var/cache/distfiles-ro" "${SR}/dev" 2>&1)"; rc=$?
[ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "distfiles-ro is STILL a mount point" >/dev/null && ! printf '%s' "${out}" | grep -a -F "${SR}/dev is" >/dev/null \
    && ok "5. hmr_verify_detached warns for the path still mounted and not for the one that is clear" || bad "5. verify: rc=${rc}: ${out}"
umount "${SR}/var/cache/distfiles-ro"

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
