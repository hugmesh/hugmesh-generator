#!/usr/bin/env bash
# test-builder-unmount-real.sh — the builder's mount handling against the REAL
# kernel: real bind mounts, stacked, in a private user+mount namespace (no root).
#
# hugmesh-generator#659: after one successful x86 build three bind mounts of
# <sysroot>/var/cache/distfiles-ro were stacked under the build system, the
# next non-resume build refused to start, and the hint it printed —
# `umount -R '<sysroot>'` — names a directory that is not a mount point and
# does nothing. A review then found the replacement unmounted NOTHING, and its
# stale-mount check saw nothing, whenever the build system was reached through
# a spelling the kernel does not use. tests/scripts/test-builder-resume-safety.sh
# proves the code against a fixture table; THIS file proves it against the
# kernel:
#
#   1. a bind stacked three times is listed three times by hmr_stale_mounts;
#   2. the builder's OWN umount_chroot (extracted from the builder text) with
#      DISTFILES_MOUNTED=true removes exactly ONE layer of distfiles-ro — the
#      one this run made — and leaves the other two (somebody else's), while
#      removing the run/dev/sys/proc binds it owns including a submount;
#   3. the OLD hint, `umount -R <sysroot>`, leaves every mount in place;
#   4. the NEW hint (the commands the refusal prints, executed as printed)
#      clears every stacked layer and every submount;
#   5. the decoder: thirty awkward directory names (spaces, a space followed by
#      a digit, tabs, newlines, backslashes, quotes, a byte above 0x7f, ...) are
#      each bind-mounted for real, read back from /proc/self/mountinfo and
#      decoded to exactly the path they were made with;
#   6. the build system reached through eight SPELLINGS — plain, a symlink
#      component, a space, a space then a digit, a non-ASCII name, a backslash,
#      glob characters, a relative path — each with real stacked binds under it:
#      the listing, the layer count, the builder's own umount_chroot, the commands
#      the refusal prints and the Extract-phase refusal all work through the
#      spelling the builder was given. This is the leg the first version of the
#      library fails: it counted 0 mounts on every spelling but the plain one and
#      unmounted nothing;
#   7. a mount table that cannot be read stops the Extract phase.
#
# HMR_TEST_LIB / HMR_TEST_X86 point the suite at another copy of the library or
# of the x86 builder (how a mutation of either is run against every leg).
#
# Needs `unshare -Urm` (user + mount namespaces). Docker's default seccomp
# profile blocks them, so no shell-suites CI container can run this: it exits
# 2 SKIPPED-LOUDLY there and is listed in tests/scripts/test-guard-integrity.sh
# with that reason; run it on a developer host. Same convention as
# tests/stack/test-tor-onion-mechanism.sh.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TEST_DIR}/../.." && pwd)"
LIB="${HMR_TEST_LIB:-${REPO}/scripts/_builder-resume-lib.sh}"
X86="${HMR_TEST_X86:-${REPO}/build-x86-host-stage4.sh}"
WALL="${WALL:-120}"

[ -f "${LIB}" ] || { echo "MISSING: ${LIB}"; exit 2; }
[ -f "${X86}" ] || { echo "MISSING: ${X86}"; exit 2; }

if [ "${1:-}" != "--inner" ]; then
    for t in unshare findmnt mountpoint umount mount readlink; do
        command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED-LOUDLY: $t is not on PATH — this guard checked NOTHING (util-linux and coreutils needed)"; exit 2; }
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

# The test's OWN way to clear its mounts, sharing nothing with the code under test:
# findmnt's raw output (every unsafe byte as \xHH, exactly two hex digits, so
# `printf %b` decodes it safely), deepest first, one lazy umount per line.
unmount_all_under() {
    local m
    findmnt -rn -o TARGET | grep -a -F -e "${TDIR}" | LC_ALL=C sort -r | while IFS= read -r m; do
        umount -l -- "$(printf '%b' "${m}")" 2>/dev/null || true
    done
}
cleanup() { unmount_all_under; rm -rf "${TDIR}"; }
trap cleanup EXIT

# shellcheck source=../../scripts/_builder-resume-lib.sh
. "${LIB}"
banner() { echo "==> $1"; }; info() { echo "    $1"; }; warn() { echo "    WARNING: $1"; }; err() { echo "    ERROR: $1" >&2; }
export -f banner info warn err

# Pieces of the builder's own text, extracted by their anchor lines.
awk 'BEGIN{on=0} /^umount_chroot\(\) \{$/ {on=1} on {print} on && /^\}$/ {exit}' "${X86}" > "${TDIR}/umount_chroot.sh"
awk -v s='^banner "Extracting stage3 into sysroot"$' -v l='hmr_stale_mount_refuse' -v e='^fi$' \
    '!on && $0 ~ s {on=1} on {print; if (!seen && $0 ~ l) seen=1; if (seen && $0 ~ e) exit}' "${X86}" > "${TDIR}/extract_guard.sh"
[ -s "${TDIR}/umount_chroot.sh" ] && [ -s "${TDIR}/extract_guard.sh" ] \
    || { echo "  FAIL could not extract umount_chroot / the Extract-phase guard from the builder"; echo "== 0 passed, 1 failed =="; exit 1; }
# A runner for one extracted piece, with the sysroot handed over in the ENVIRONMENT
# (a name with a quote or a backslash cannot be pasted into a script text safely).
cat > "${TDIR}/run-piece.sh" <<'RUN'
#!/usr/bin/env bash
# <lib> <piece file> <function to call, or "-" for none> <RESUME> ; SYSROOT_ARG in the environment
set -euo pipefail
. "$1"
banner() { echo "==> $1"; }; info() { echo "    $1"; }; warn() { echo "    WARNING: $1"; }; err() { echo "    ERROR: $1" >&2; }
acquire_build_lock() { :; }
SYSROOT="${SYSROOT_ARG}"; RESUME="${4:-false}"; BUILD_ROOT="${SYSROOT_ARG}.build"; STAGE3_LOCAL=/nonexistent
DISTFILES_MOUNTED=true; PORTAGE_SCRATCH_MOUNTED=false; HOST_REPO_MOUNTED=false; X86_POOL_MOUNTED=false
. "$2"
if [ "$3" != "-" ]; then "$3"; else echo EXTRACT-PHASE-COMPLETED; fi
RUN

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

# 4. the NEW hint — the commands the refusal prints — executed as printed: everything under the sysroot is gone.
# Re-stack first so the commands are exercised on stacked layers AND a submount.
mount --bind "${TDIR}/src-c" "${SR}/var/cache/distfiles-ro"
mount --bind "${TDIR}/dev-src" "${SR}/dev"; mount --bind "${TDIR}/pts-src" "${SR}/dev/pts"
listing="$(hmr_stale_mounts "${SR}")"
before="$(printf '%s\n' "${listing}" | grep -a -c .)"
hint="$(hmr_stale_mount_hint "${listing}")"
out="$(bash -c "${hint}" 2>&1)"; rc=$?
n_after="$(hmr_stale_mounts "${SR}" | grep -a -c .)"
[ "${before}" -eq 5 ] && [ "${rc}" -eq 0 ] && [ "${n_after}" -eq 0 ] && [ -z "${out}" ] \
    && ok "4. the NEW hint cleared all 5 mounts (3 stacked layers + dev + its submount) with no error: $(printf '%s' "${hint}" | tr '\n' ';')" \
    || bad "4. new hint: before=${before} rc=${rc} after=${n_after}: ${out}"
# and the refusal prints exactly those commands, each on its own line
mount --bind "${TDIR}/src-c" "${SR}/var/cache/distfiles-ro"; mount --bind "${TDIR}/dev-src" "${SR}/dev"
listing="$(hmr_stale_mounts "${SR}")"
hint="$(hmr_stale_mount_hint "${listing}" "    ")"
out="$(hmr_stale_mount_refuse "${SR}" "${listing}" 2>&1)"
n_hint=0; n_found=0
while IFS= read -r l; do
    n_hint=$((n_hint+1))
    if printf '%s\n' "${out}" | grep -a -x -F -- "${l}" >/dev/null; then n_found=$((n_found+1)); fi
done <<< "${hint}"
[ "${n_hint}" -eq 2 ] && [ "${n_found}" -eq "${n_hint}" ] && ok "4b. the refusal prints each of those ${n_hint} commands on a line of its own" || bad "4b. refusal text (${n_found}/${n_hint} command lines found): ${out}"
unmount_all_under

# 5. the decoder against the kernel: each awkward name bound for real, read back raw from
# /proc/self/mountinfo, decoded, compared with the path it was made from.
NAMES=(
    "plain" "with space" " leading" "trailing " $'tab\there' $'new\nline' 'back\slash' 'x\x41y' 'x\101y' 'x\040y'
    'x\0y' 'x\cy' 'dq"q' "sq'q" 'dollar$HOME' 'star*?[x]' 'hash#x' $'esc\e[0m' $'del\x7f' 'jörg'
    $'hi\xffbyte' '-dash' '%s%n' 'p%b' 'build 5' 'a 5b' $'t\t7' 'sp  sp' 'two\\\\slashes' "it's a \"q\" \$x"
)
i=0; n_ok=0; n_names=${#NAMES[@]}; why=""
for name in "${NAMES[@]}"; do
    i=$((i+1))
    d="${TDIR}/n/${i}/${name}"
    mkdir -p "${d}" && mount --bind "${TDIR}/src-a" "${d}" || { why="${why} [mount ${i} failed]"; continue; }
    raw="$(awk -v p="${TDIR}/n/${i}/" 'index($5,p)==1 {print $5}' /proc/self/mountinfo; printf x)"; raw="${raw%x}"; raw="${raw%$'\n'}"
    got="$(_hmr_unmangle "${raw}"; printf x)"; got="${got%x}"
    if [ "${got}" = "${d}" ]; then n_ok=$((n_ok+1)); else why="${why} [#${i} $(printf '%q' "${name}") -> $(printf '%q' "${got}")]"; fi
done
[ "${n_ok}" -eq "${n_names}" ] && ok "5. the decoder: all ${n_names} awkward names bound for real are decoded to exactly the path they were made with" \
    || bad "5. decoder: ${n_ok}/${n_names} round-tripped:${why}"
# and the listing sees every one of them (the name with a newline in it is the one a line-based listing cannot hold)
listing="$(hmr_stale_mounts "${TDIR}/n")"
miss=""; i=0
for name in "${NAMES[@]}"; do
    i=$((i+1)); d="${TDIR}/n/${i}/${name}"
    case "${name}" in *$'\n'*) continue ;; esac
    printf '%s\n' "${listing}" | grep -a -x -F -- "${d}" >/dev/null || miss="${miss} [#${i}]"
done
[ -z "${miss}" ] && ok "5b. hmr_stale_mounts lists every one of them (all but the newline name, which a line-based listing cannot hold)" || bad "5b. missing from the listing:${miss}"
unmount_all_under

# 6. the build system reached through every spelling, with real stacked binds under it.
SPD="${TDIR}/sp"; mkdir -p "${SPD}"
mk_build_dir() { mkdir -p "$1/snap-build-x86/sysroot/var/cache/distfiles-ro" "$1/snap-build-x86/sysroot/dev/pts"; }
mk_build_dir "${SPD}/real"; ln -s real "${SPD}/link"
mk_build_dir "${SPD}/with space"; mk_build_dir "${SPD}/build 2"; mk_build_dir "${SPD}/jörg"
mk_build_dir "${SPD}/back\\slash"; mk_build_dir "${SPD}/sr[1]"; mk_build_dir "${SPD}/sr1"
# spelling label | sysroot as the builder is given it | working directory
SPELLINGS=(
    "plain|${SPD}/real/snap-build-x86/sysroot|."
    "symlink component|${SPD}/link/snap-build-x86/sysroot|."
    "space|${SPD}/with space/snap-build-x86/sysroot|."
    "space then a digit|${SPD}/build 2/snap-build-x86/sysroot|."
    "non-ASCII (C locale)|${SPD}/jörg/snap-build-x86/sysroot|."
    "backslash|${SPD}/back\\slash/snap-build-x86/sysroot|."
    "glob characters|${SPD}/sr[1]/snap-build-x86/sysroot|."
    "relative --work-dir|snap-build-x86/sysroot|${SPD}/real"
)
spell_check() {   # <spelled sysroot>  (cwd already set): prints one line per failed expectation
    local S="$1" K want got n out rc hint left
    K="$(readlink -f -- "${S}")"
    # the shape of a crashed run: distfiles-ro stacked twice, /dev with a submount
    mount --bind "${TDIR}/src-a" "${S}/var/cache/distfiles-ro" && mount --bind "${TDIR}/src-b" "${S}/var/cache/distfiles-ro" \
        && mount --bind "${TDIR}/dev-src" "${S}/dev" && mount --bind "${TDIR}/pts-src" "${S}/dev/pts" || { echo "could not bind under [${S}]"; return 1; }
    got="$(hmr_stale_mounts "${S}" | LC_ALL=C sort)"
    want="$(printf '%s\n' "${K}/var/cache/distfiles-ro" "${K}/var/cache/distfiles-ro" "${K}/dev" "${K}/dev/pts" | LC_ALL=C sort)"
    [ "${got}" = "${want}" ] || echo "stale listing: got [${got}], wanted [${want}]"
    n="$(hmr_mount_layers "${S}/var/cache/distfiles-ro")"
    [ "${n}" = 2 ] || echo "layer count of distfiles-ro: ${n}, wanted 2"
    # the Extract phase must refuse, on both branches, through this spelling
    for rsm in true false; do
        out="$(SYSROOT_ARG="${S}" bash "${TDIR}/run-piece.sh" "${LIB}" "${TDIR}/extract_guard.sh" - "${rsm}" 2>&1)"; rc=$?
        if [ "${rc}" -eq 0 ] || ! printf '%s' "${out}" | grep -a -F "mounts are still attached under ${S}" >/dev/null \
           || printf '%s' "${out}" | grep -a -F "EXTRACT-PHASE-COMPLETED" >/dev/null; then
            echo "Extract phase (RESUME=${rsm}) did not refuse: rc=${rc}: ${out}"
        fi
    done
    # the builder's own umount_chroot, SYSROOT spelled the same way: ONE distfiles-ro layer (ours) goes,
    # dev and its submount go, the other layer stays, and nothing is said
    out="$(SYSROOT_ARG="${S}" bash "${TDIR}/run-piece.sh" "${LIB}" "${TDIR}/umount_chroot.sh" umount_chroot false 2>&1)"; rc=$?
    n="$(hmr_mount_layers "${S}/var/cache/distfiles-ro")"
    [ "${rc}" -eq 0 ] && [ "${n}" = 1 ] && [ -z "${out}" ] || echo "umount_chroot: rc=${rc}, ${n} distfiles-ro layer(s) left (wanted 1), said [${out}]"
    if mountpoint -q "${S}/dev" 2>/dev/null; then echo "umount_chroot left ${S}/dev mounted"; fi
    # the commands the refusal prints clear the rest
    hint="$(hmr_stale_mount_hint "$(hmr_stale_mounts "${S}")")"
    out="$(bash -c "${hint}" 2>&1)"; rc=$?
    left="$(hmr_stale_mounts "${S}")"
    [ "${rc}" -eq 0 ] && [ -z "${left}" ] && ! mountpoint -q "${S}/var/cache/distfiles-ro" 2>/dev/null \
        || echo "the printed commands: rc=${rc}, still listed [${left}], said [${out}]"
    return 0
}
for entry in "${SPELLINGS[@]}"; do
    IFS='|' read -r label spelled cwd <<EOF
${entry}
EOF
    unmount_all_under
    out="$( cd "${cwd}" && spell_check "${spelled}" 2>&1 )"
    if [ -z "${out}" ]; then
        ok "6. spelling '${label}': listing, layer count, Extract-phase refusal, umount_chroot (one layer, ours) and the printed commands all work through it"
    else
        bad "6. spelling '${label}': ${out}"
    fi
done
unmount_all_under

# 7. a table that cannot be read stops the Extract phase (the old code read it as 'nothing mounted')
out="$(HMR_MOUNTINFO=/nonexistent/mountinfo SYSROOT_ARG="${SPD}/real/snap-build-x86/sysroot" bash "${TDIR}/run-piece.sh" "${LIB}" "${TDIR}/extract_guard.sh" - false 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -a -F "cannot read the kernel's mount table" >/dev/null && ! printf '%s' "${out}" | grep -a -F "EXTRACT-PHASE-COMPLETED" >/dev/null \
    && ok "7. an unreadable mount table stops the Extract phase with one sentence" || bad "7. unreadable table: rc=${rc}: ${out}"

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
