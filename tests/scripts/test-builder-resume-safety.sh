#!/usr/bin/env bash
# test-builder-resume-safety.sh — what --resume must refuse and restore, EXECUTED.
#
# hugmesh-generator#659 (2026-09-30). A finished build leaves its build system
# unusable for --resume three ways: its static libraries are stripped (the
# restore ran only for GPU roles), `make` handed it to the invoking user (the
# resumed image booted with every directory uid 1002), and its distfiles-ro
# bind was never unmounted (three stacked under one sysroot). This suite runs
# the code that now handles each, against FIXTURES, without a build:
#
#   - scripts/_builder-resume-lib.sh is SOURCED (the real file) and driven
#     against a scratch build system: one owned by this test's user (must be
#     refused), one that reads as root's (via `unshare -Ur`, where the caller's
#     files appear as uid 0, plus a `stat` shim leg for hosts without user
#     namespaces), one with its static files removed, and two tiny REAL seed
#     tarballs (tar.xz) whose var/db/pkg names a toolchain that does or does not
#     match the build system's.
#   - the builder's OWN sections are extracted by their anchor lines and run
#     with stubs on PATH: the Extract phase (owner gate, stale-mount refusal,
#     seed marker), section 4b (the restore, no longer GPU-gated), the link
#     check after mount_chroot (stub chroot + stub gcc), and umount_chroot
#     (stub umount + mountpoint, recording every argument).
#   - call-site pins against the builder text, for every builder, and the
#     stale-mount refusal executed on each cross builder's own text.
#   - a MUTATION BATTERY: each guard is removed from a COPY of the builder (the
#     copy is `cmp`-checked to differ), and the leg that covers it must go RED.
#
# Real bind mounts (stacked, in a user+mount namespace) are the subject of the
# sibling suite tests/scripts/test-builder-unmount-real.sh, which needs
# `unshare -Urm`; this file needs no privilege at all.
#
# HOST TRAPS this file is written against: no `| grep -q` under pipefail (drain
# to /dev/null and branch on the status); `grep -a` everywhere; one name per
# `local`; every dynamic leg runs under `timeout`.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TEST_DIR}/../.." && pwd)"
LIB="${REPO}/scripts/_builder-resume-lib.sh"
X86="${REPO}/build-x86-host-stage4.sh"
RPI="${REPO}/build-rpi5-stage4.sh"
WALL="${WALL:-60}"

P=0; F=0
ok()  { P=$((P+1)); echo "  PASS $*"; }
bad() { F=$((F+1)); echo "  FAIL $*"; }
has() { grep -a -F -e "$2" "$1" >/dev/null 2>&1; }        # file contains fixed string
hasr() { grep -a -E -e "$2" "$1" >/dev/null 2>&1; }       # file contains regex

[ -f "${LIB}" ] || { echo "MISSING: ${LIB}"; exit 2; }
[ -f "${X86}" ] || { echo "MISSING: ${X86}"; exit 2; }
[ -f "${RPI}" ] || { echo "MISSING: ${RPI}"; exit 2; }
for t in tar xz find stat mktemp timeout cmp; do
    command -v "$t" >/dev/null 2>&1 || { echo "MISSING tool: $t"; exit 2; }
done

TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR}"' EXIT
mkdir -p "${TDIR}/bin"

# The "user-owned" fixtures must NOT be root's. A developer runs this file as a
# normal user, so a fixture is theirs (uid $(id -u)) as soon as it is made; a CI
# container runs as ROOT, where the same fixture would be uid 0 and the owner
# gate would — correctly — pass it, turning every refusal leg red for the wrong
# reason. Under root the fixture is handed to FIX_UID (65534, nobody: present on
# alpine, debian and this host) after it is built, and every assertion names
# FIX_UID rather than $(id -u).
if [ "$(id -u)" -eq 0 ]; then FIX_UID=65534; else FIX_UID="$(id -u)"; fi

# ── fixtures ─────────────────────────────────────────────────────────────────
# A build system: the directories the owner gate looks at, a package database
# naming glibc 2.43-r2 / gcc 15.3.0 / binutils 2.46.1 (the operator's tree on
# 2026-09-30), and the static files the clean step deletes. Owned by FIX_UID.
make_sysroot() {   # <dir> [with-statics]
    local d="$1"
    mkdir -p "$d/etc" "$d/var/empty" "$d/var/db/pkg/sys-libs/glibc-2.43-r2" \
             "$d/var/db/pkg/sys-devel/gcc-15.3.0" "$d/var/db/pkg/sys-devel/binutils-2.46.1" \
             "$d/var/db/pkg/sys-devel/gcc-config-2.12.2" "$d/var/db/pkg/sys-devel/binutils-config-5.6" \
             "$d/usr/lib64" "$d/usr/lib/gcc/x86_64-pc-linux-gnu/15" "$d/bin" "$d/var/cache/distfiles-ro" "$d/tmp"
    echo "Gentoo Base System release 2.18" > "$d/etc/gentoo-release"
    touch "$d/usr/lib64/crt1.o"
    if [ "${2:-}" = with-statics ]; then
        touch "$d/usr/lib64/libc_nonshared.a" "$d/usr/lib64/libpthread.a" "$d/usr/lib64/libdl.a" \
              "$d/usr/lib/gcc/x86_64-pc-linux-gnu/15/libgcc.a"
    fi
    [ "$(id -u)" -ne 0 ] || chown -R "${FIX_UID}:${FIX_UID}" "$d"
}
# A seed tarball: the members the restore selects (*.a, crt*.o) plus the
# package database directories that name its toolchain.
make_seed() {   # <path.tar.xz> <glibc-pf> <gcc-pf> <binutils-pf>
    local out="$1" glibc="$2" gcc="$3" binutils="$4"
    local s
    s="$(mktemp -d "${TDIR}/seedsrc.XXXXXX")"
    mkdir -p "$s/var/db/pkg/sys-libs/${glibc}" "$s/var/db/pkg/sys-devel/${gcc}" "$s/var/db/pkg/sys-devel/${binutils}" \
             "$s/var/db/pkg/sys-devel/gcc-config-2.12.2" "$s/usr/lib64" "$s/usr/lib/gcc/x86_64-pc-linux-gnu/15" "$s/etc"
    echo "seed ${glibc}" > "$s/usr/lib64/libc_nonshared.a"
    echo "seed ${glibc}" > "$s/usr/lib64/libpthread.a"
    echo "seed ${glibc}" > "$s/usr/lib64/libdl.a"
    echo "seed ${glibc}" > "$s/usr/lib64/crt1.o"
    echo "seed ${glibc}" > "$s/usr/lib64/crti.o"
    echo "seed ${gcc}" > "$s/usr/lib/gcc/x86_64-pc-linux-gnu/15/libgcc.a"
    echo "seed ${gcc}" > "$s/usr/lib/gcc/x86_64-pc-linux-gnu/15/crtbegin.o"
    echo "Gentoo Base System release 2.18" > "$s/etc/gentoo-release"
    echo "not a static: must not be restored" > "$s/etc/hostname"
    tar -C "$s" -cJf "$out" .
    rm -rf "$s"
}
SEEDDIR="${TDIR}/seed/amd64"; mkdir -p "${SEEDDIR}"
SEED_OLD="${SEEDDIR}/stage3-amd64-hardened-openrc-20260920T170055Z.tar.xz"   # matches the sysroot
SEED_NEW="${SEEDDIR}/stage3-amd64-hardened-openrc-20260927T170058Z.tar.xz"   # binutils moved
make_seed "${SEED_OLD}" glibc-2.43-r2 gcc-15.3.0 binutils-2.46.1
make_seed "${SEED_NEW}" glibc-2.43-r2 gcc-15.3.0 binutils-2.47

# Builder log helpers the sections call (the real ones colour their output).
banner() { echo "==> $1"; }
info()   { echo "    $1"; }
warn()   { echo "    WARNING: $1"; }
err()    { echo "    ERROR: $1" >&2; }
export -f banner info warn err

echo "== 1. the library, executed =="
# shellcheck source=../../scripts/_builder-resume-lib.sh
. "${LIB}"

# 1a. owner gate refuses a build system this user owns, in one sentence.
SR="${TDIR}/sr-user"; make_sysroot "${SR}" with-statics
out="$(hmr_owner_gate "${SR}" 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && [ "$(printf '%s\n' "${out}" | wc -l)" -eq 1 ] \
   && printf '%s' "${out}" | grep -a -F "owned by uid ${FIX_UID}, not root" >/dev/null \
   && printf '%s' "${out}" | grep -a -F "rebuild WITHOUT --resume" >/dev/null; then
    ok "owner gate: user-owned build system refused (rc=1), one sentence naming uid ${FIX_UID} and 'rebuild WITHOUT --resume'"
else
    bad "owner gate: expected rc=1 + one sentence, got rc=${rc}: ${out}"
fi
# 1b. owner gate passes a root-owned build system. Two legs: a `stat` shim
# that answers 0 for the fixture (runs anywhere), and the real stat inside
# `unshare -Ur`, where this user's files are uid 0 (runs where user
# namespaces are allowed; docker's default seccomp blocks them in CI). Under
# root the fixture is simply root's (chowned back after make_sysroot).
cat > "${TDIR}/bin/stat" <<STUB
#!/usr/bin/env bash
# Answer 0 for anything under the fixture; delegate everything else.
for a in "\$@"; do case "\$a" in "${TDIR}/sr-root"*) echo 0; exit 0 ;; esac; done
exec /usr/bin/stat "\$@"
STUB
chmod +x "${TDIR}/bin/stat"
SRR="${TDIR}/sr-root"; make_sysroot "${SRR}" with-statics
[ "$(id -u)" -ne 0 ] || chown -R 0:0 "${SRR}"
out="$(PATH="${TDIR}/bin:${PATH}" bash -c ". '${LIB}'; hmr_owner_gate '${SRR}'" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && [ -z "${out}" ] && ok "owner gate: root-owned build system passes silently (stat shim leg)" \
    || bad "owner gate (stat shim): expected rc=0 silent, got rc=${rc}: ${out}"
rm -f "${TDIR}/bin/stat"
if unshare -Ur true 2>/dev/null; then
    out="$(timeout "${WALL}" unshare -Ur bash -c ". '${LIB}'; stat -c %u '${SRR}'; hmr_owner_gate '${SRR}'" 2>&1)"; rc=$?
    [ "${rc}" -eq 0 ] && [ "${out}" = "0" ] && ok "owner gate: passes under unshare -Ur where the fixture reads as uid 0 (real stat)" \
        || bad "owner gate (unshare -Ur): expected rc=0 and '0', got rc=${rc}: ${out}"
else
    echo "  SKIP owner gate real-stat leg: unshare -Ur is not permitted here (the stat shim leg above covered the pass path)"
fi
# 1c. missing statics detected either way round.
SM="${TDIR}/sr-miss"; make_sysroot "${SM}"
hmr_statics_missing "${SM}" && ok "statics: missing libc_nonshared.a + libgcc.a detected" || bad "statics: stripped build system not detected"
hmr_statics_missing "${SR}" && bad "statics: intact build system reported as stripped" || ok "statics: intact build system passes"
touch "${SM}/usr/lib64/libc_nonshared.a"
hmr_statics_missing "${SM}" && ok "statics: libgcc.a alone missing still counts" || bad "statics: libgcc.a missing not detected"
rm -f "${SM}/usr/lib64/libc_nonshared.a"
# 1d. toolchain listing: three packages from the seed, config packages excluded.
L="${TDIR}/listing"; hmr_seed_list "${SEED_OLD}" "${L}" || bad "seed list failed"
tc="$(hmr_toolchain_from_listing "${L}" | tr '\n' ' ')"
[ "${tc}" = "sys-devel/binutils-2.46.1 sys-devel/gcc-15.3.0 sys-libs/glibc-2.43-r2 " ] \
    && ok "seed toolchain read from ONE listing: ${tc}(gcc-config excluded)" \
    || bad "seed toolchain: got '${tc}'"
tcs="$(hmr_toolchain_from_sysroot "${SM}" | tr '\n' ' ')"
[ "${tcs}" = "sys-devel/binutils-2.46.1 sys-devel/gcc-15.3.0 sys-libs/glibc-2.43-r2 " ] \
    && ok "sysroot toolchain read from var/db/pkg: ${tcs}(config packages excluded)" \
    || bad "sysroot toolchain: got '${tcs}'"
hmr_toolchain_matches "${L}" "${SM}" && ok "toolchain match: 20260920 seed == sysroot" || bad "toolchain match: 20260920 seed should match"
hmr_seed_list "${SEED_NEW}" "${L}"
hmr_toolchain_matches "${L}" "${SM}" && bad "toolchain match: 20260927 seed (binutils 2.47) must NOT match" || ok "toolchain match: 20260927 seed (binutils 2.47 vs 2.46.1) rejected"
# 1e. seed choice: newest seed current, no marker -> the OLD cached seed is found.
BR="${TDIR}/br-nomarker"; mkdir -p "${BR}"
chosen="$(hmr_seed_for_resume "${BR}" "${SM}" "${SEED_NEW}" "${L}" 2>"${TDIR}/e1")"; rc=$?
[ "${rc}" -eq 0 ] && [ "${chosen}" = "${SEED_OLD}" ] && ok "seed choice (no marker, newest seed mismatches): the cached matching seed is chosen" \
    || bad "seed choice (no marker): rc=${rc} chosen='${chosen}' $(cat "${TDIR}/e1")"
# 1f. marker present and cached -> it wins even when the current seed also matches.
BRM="${TDIR}/br-marker"; mkdir -p "${BRM}"; hmr_seed_marker_write "${BRM}" "${SEED_OLD}"
[ "$(hmr_seed_marker_read "${BRM}")" = "$(basename "${SEED_OLD}")" ] && ok "seed marker: written beside the sysroot as the basename, read back" || bad "seed marker round trip"
chosen="$(hmr_seed_for_resume "${BRM}" "${SM}" "${SEED_OLD}" "${L}" 2>/dev/null)"
[ "${chosen}" = "${SEED_OLD}" ] && ok "seed choice (marker): the marker's seed is chosen" || bad "seed choice (marker): got '${chosen}'"
# 1g. refusal: only a mismatching seed cached -> one sentence, rc=1, says to rebuild.
ONLYNEW="${TDIR}/seed-onlynew"; mkdir -p "${ONLYNEW}"; cp "${SEED_NEW}" "${ONLYNEW}/"
out="$(hmr_seed_for_resume "${BR}" "${SM}" "${ONLYNEW}/$(basename "${SEED_NEW}")" "${L}" 2>&1 >/dev/null)"; rc=$?
if [ "${rc}" -eq 1 ] && [ "$(printf '%s\n' "${out}" | wc -l)" -eq 1 ] \
   && printf '%s' "${out}" | grep -a -F "rebuild WITHOUT --resume" >/dev/null \
   && printf '%s' "${out}" | grep -a -F "binutils-2.47" >/dev/null \
   && printf '%s' "${out}" | grep -a -F "binutils-2.46.1" >/dev/null; then
    ok "seed refusal: no matching seed -> rc=1, ONE sentence naming both toolchains and 'rebuild WITHOUT --resume'"
else
    bad "seed refusal: rc=${rc}: ${out}"
fi
# 1h. restore: only *.a and crt*.o come back; nothing else from the seed.
hmr_seed_list "${SEED_OLD}" "${L}"
out="$(hmr_statics_restore "${SM}" "${SEED_OLD}" "${L}" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && [ -f "${SM}/usr/lib64/libc_nonshared.a" ] && [ -f "${SM}/usr/lib/gcc/x86_64-pc-linux-gnu/15/libgcc.a" ] \
   && [ -f "${SM}/usr/lib64/crti.o" ] && [ ! -f "${SM}/etc/hostname" ] && ! hmr_statics_missing "${SM}"; then
    ok "restore: statics + crt*.o extracted from the chosen seed, non-static members untouched (${out})"
else
    bad "restore: rc=${rc} ${out}; hostname present: $([ -f "${SM}/etc/hostname" ] && echo yes || echo no)"
fi
# 1i. link check through a stub chroot: the snippet runs on the host, `gcc` is a stub.
cat > "${TDIR}/bin/chroot" <<'STUB'
#!/usr/bin/env bash
# chroot <dir> <cmd...>: run the command here (no privilege), recording the dir.
echo "$1" >> "${STUB_STATE}/chroot-dirs"; shift; exec "$@"
STUB
cat > "${TDIR}/bin/gcc" <<'STUB'
#!/usr/bin/env bash
if [ "${STUB_GCC_FAIL:-0}" = 1 ]; then
    echo "/usr/lib/gcc/x86_64-pc-linux-gnu/15/../../../../x86_64-pc-linux-gnu/bin/ld: cannot find /usr/lib64/libc_nonshared.a: No such file or directory" >&2
    echo "collect2: error: ld returned 1 exit status" >&2; exit 1
fi
out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done; : > "${out}"; exit 0
STUB
chmod +x "${TDIR}/bin/chroot" "${TDIR}/bin/gcc"
export STUB_STATE="${TDIR}/state"; mkdir -p "${STUB_STATE}"
out="$(PATH="${TDIR}/bin:${PATH}" STUB_GCC_FAIL=1 timeout "${WALL}" bash -c ". '${LIB}'; hmr_link_check_chroot '${SM}'" 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && [ "$(printf '%s\n' "${out}" | wc -l)" -eq 1 ] \
   && printf '%s' "${out}" | grep -a -F "cannot find /usr/lib64/libc_nonshared.a" >/dev/null \
   && printf '%s' "${out}" | grep -a -F "rebuild WITHOUT --resume" >/dev/null \
   && [ "$(cat "${STUB_STATE}/chroot-dirs")" = "${SM}" ]; then
    ok "link check: failing link -> rc=1, ONE sentence carrying the ld error, run inside chroot of the sysroot"
else
    bad "link check (fail): rc=${rc}: ${out}"
fi
out="$(PATH="${TDIR}/bin:${PATH}" STUB_GCC_FAIL=0 timeout "${WALL}" bash -c ". '${LIB}'; hmr_link_check_chroot '${SM}'" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && [ -z "${out}" ] && ok "link check: a working toolchain passes silently" || bad "link check (pass): rc=${rc}: ${out}"
# 1j. stale-mount listing and hint: findmnt stubbed to report stacked binds.
cat > "${TDIR}/bin/findmnt" <<STUB
#!/usr/bin/env bash
cat "${STUB_STATE}/mounts" 2>/dev/null
STUB
chmod +x "${TDIR}/bin/findmnt"
printf '%s\n' "/" "/home" "${SM}/var/cache/distfiles-ro" "${SM}/var/cache/distfiles-ro" "${SM}/var/cache/distfiles-ro" "${SM}/dev" "${SM}/dev/pts" "${SM}-other/x" > "${STUB_STATE}/mounts"
listing="$(PATH="${TDIR}/bin:${PATH}" bash -c ". '${LIB}'; hmr_stale_mounts '${SM}'")"
[ "$(printf '%s\n' "${listing}" | wc -l)" -eq 5 ] && ! printf '%s' "${listing}" | grep -a -F -- "-other" >/dev/null \
    && ok "stale mounts: 5 lines under the sysroot (a bind stacked 3x listed 3x), the sibling dir excluded" \
    || bad "stale mounts: got: ${listing}"
hint="$(hmr_stale_mount_hint "${SM}")"
[ "${hint}" = "findmnt -rn -o TARGET | grep '^${SM}/' | sort -r | while read -r m; do umount \"\$m\"; done" ] \
    && ok "stale-mount hint is a per-line loop, deepest first: ${hint}" \
    || bad "stale-mount hint: ${hint}"
# The hint, executed against the stub: every listed line gets its own umount, deeper paths first.
cat > "${TDIR}/bin/umount" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_STATE}/umount-args"; exit 0
STUB
chmod +x "${TDIR}/bin/umount"
: > "${STUB_STATE}/umount-args"
PATH="${TDIR}/bin:${PATH}" bash -c "${hint}"
i_pts="$(grep -a -n -F "${SM}/dev/pts" "${STUB_STATE}/umount-args" | cut -d: -f1)"
i_dev="$(grep -a -n -x -F "${SM}/dev" "${STUB_STATE}/umount-args" | cut -d: -f1)"
if [ "$(wc -l < "${STUB_STATE}/umount-args")" -eq 5 ] && [ -n "${i_pts}" ] && [ -n "${i_dev}" ] && [ "${i_pts}" -lt "${i_dev}" ] \
   && [ "$(grep -a -c "distfiles-ro" "${STUB_STATE}/umount-args")" -eq 3 ]; then
    ok "hint executed: 5 umounts, a submount (dev/pts) before its parent (dev), distfiles-ro three times (one per stacked layer)"
else
    bad "hint executed: $(cat "${STUB_STATE}/umount-args")"
fi
out="$(PATH="${TDIR}/bin:${PATH}" bash -c ". '${LIB}'; hmr_stale_mount_refuse '${SM}' \"\$(hmr_stale_mounts '${SM}')\"" 2>&1)"
printf '%s' "${out}" | grep -a -F "while read -r m; do umount" >/dev/null && ! printf '%s' "${out}" | grep -a -F "umount -R" >/dev/null \
    && ok "refusal text carries the loop hint and no 'umount -R'" || bad "refusal text: ${out}"
rm -f "${TDIR}/bin/findmnt" "${TDIR}/bin/umount"

echo "== 2. the builder's own sections, extracted and executed =="
# extract_section <file> <start regex> <end regex after start> <out>: the lines
# from the first line matching start through the first line matching end
# that comes AFTER a line matching the third argument (a landmark), inclusive.
extract_section() {   # <file> <start-re> <landmark-re> <end-re> <out>
    awk -v s="$2" -v l="$3" -v e="$4" '
        !on && $0 ~ s { on=1 }
        on { print; if (!seen && $0 ~ l) seen=1; if (seen && $0 ~ e) exit }
    ' "$1" > "$5"
    [ -s "$5" ]
}
# 2a. the Extract phase: owner gate on the resume branch, stale-mount refusal
# on both, seed marker after a fresh extract.
run_extract_phase() {   # <builder> <resume true|false> <sysroot> <build root> <seed> [extra PATH]
    local b="$1" resume="$2" sysroot="$3" build_root="$4" seed="$5" epath="${6:-}"
    local sec="${TDIR}/sec-extract.sh"
    extract_section "$b" '^banner "Extracting stage3 into sysroot"$' 'hmr_seed_marker_write' '^fi$' "${sec}" || return 99
    PATH="${epath:+${epath}:}${PATH}" timeout "${WALL}" bash -c "
        set -euo pipefail
        . '${LIB}'
        banner(){ echo \"==> \$1\"; }; info(){ echo \"    \$1\"; }; warn(){ echo \"    WARNING: \$1\"; }; err(){ echo \"    ERROR: \$1\" >&2; }
        acquire_build_lock(){ :; }
        RESUME=${resume}; SYSROOT='${sysroot}'; BUILD_ROOT='${build_root}'; STAGE3_LOCAL='${seed}'
        . '${sec}'
        echo EXTRACT-PHASE-COMPLETED
    "
}
B1="${TDIR}/b-extract"; mkdir -p "${B1}"; SX="${B1}/sysroot"; make_sysroot "${SX}"
out="$(run_extract_phase "${X86}" true "${SX}" "${B1}" "${SEED_OLD}" 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "Refusing --resume: the build system directory ${SX} is owned by uid ${FIX_UID}" >/dev/null \
   && ! printf '%s' "${out}" | grep -a -F "skipping extraction" >/dev/null && ! printf '%s' "${out}" | grep -a -F "EXTRACT-PHASE-COMPLETED" >/dev/null; then
    ok "extract phase (--resume, user-owned): refused before 'skipping extraction', nothing proceeds"
else
    bad "extract phase (--resume, user-owned): rc=${rc}: ${out}"
fi
touch "${SX}/leftover-from-the-previous-attempt"
out="$(run_extract_phase "${X86}" false "${SX}" "${B1}" "${SEED_OLD}" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -a -F "wiping for a clean stage3 extract" >/dev/null \
   && [ "$(cat "${B1}/sysroot.seed" 2>/dev/null)" = "$(basename "${SEED_OLD}")" ] && [ -f "${SX}/usr/lib64/libc_nonshared.a" ] \
   && [ ! -e "${SX}/leftover-from-the-previous-attempt" ]; then
    ok "extract phase (no --resume, user-owned): wiped, re-extracted from the seed, marker sysroot.seed written beside the sysroot"
else
    bad "extract phase (no --resume): rc=${rc}: ${out}; marker=$(cat "${B1}/sysroot.seed" 2>/dev/null)"
fi
# stale mounts (stub findmnt) refuse on BOTH branches, with the loop hint.
mkdir -p "${TDIR}/bin-mnt"; cat > "${TDIR}/bin-mnt/findmnt" <<STUB
#!/usr/bin/env bash
printf '%s\n' "${SX}/var/cache/distfiles-ro" "${SX}/var/cache/distfiles-ro"
STUB
chmod +x "${TDIR}/bin-mnt/findmnt"
for r in true false; do
    out="$(run_extract_phase "${X86}" "$r" "${SX}" "${B1}" "${SEED_OLD}" "${TDIR}/bin-mnt" 2>&1)"; rc=$?
    if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "mounts are still attached under ${SX}" >/dev/null \
       && printf '%s' "${out}" | grep -a -F "while read -r m; do umount" >/dev/null \
       && ! printf '%s' "${out}" | grep -a -F "EXTRACT-PHASE-COMPLETED" >/dev/null && [ -f "${SX}/etc/gentoo-release" ]; then
        ok "extract phase (RESUME=$r, stale binds): refused with the loop hint before any wipe or skip"
    else
        bad "extract phase (RESUME=$r, stale binds): rc=${rc}: ${out}"
    fi
done
# 2b. section 4b: the restore runs for a non-GPU role when the statics are missing.
run_4b() {   # <builder> <sysroot> <build root> <current seed> <GPU true|false>
    local b="$1" sysroot="$2" build_root="$3" seed="$4" gpu="$5"
    local sec="${TDIR}/sec-4b.sh"
    extract_section "$b" '^# ── 4b\. Toolchain static restore' 'hmr_statics_restore' '^fi$' "${sec}" || return 99
    timeout "${WALL}" bash -c "
        set -euo pipefail
        . '${LIB}'
        banner(){ echo \"==> \$1\"; }; info(){ echo \"    \$1\"; }; warn(){ echo \"    WARNING: \$1\"; }; err(){ echo \"    ERROR: \$1\" >&2; }
        GPU=${gpu}; SYSROOT='${sysroot}'; BUILD_ROOT='${build_root}'; STAGE3_LOCAL='${seed}'
        . '${sec}'
        echo 4B-COMPLETED
    "
}
B2="${TDIR}/b-4b"; mkdir -p "${B2}"; S4="${B2}/sysroot"; make_sysroot "${S4}"
out="$(run_4b "${X86}" "${S4}" "${B2}" "${SEED_NEW}" false 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && [ -f "${S4}/usr/lib64/libc_nonshared.a" ] && [ -f "${S4}/usr/lib/gcc/x86_64-pc-linux-gnu/15/libgcc.a" ] \
   && [ "$(cat "${B2}/sysroot.seed" 2>/dev/null)" = "$(basename "${SEED_OLD}")" ] && printf '%s' "${out}" | grep -a -F "Restored" >/dev/null; then
    ok "4b (GPU=false, statics stripped, newest seed mismatches): restored from the MATCHING cached seed, marker recorded"
else
    bad "4b (GPU=false): rc=${rc}: ${out}"
fi
out="$(run_4b "${X86}" "${S4}" "${B2}" "${SEED_NEW}" false 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ! printf '%s' "${out}" | grep -a -F "Restoring" >/dev/null && ok "4b: a no-op when the statics are present" || bad "4b no-op: rc=${rc}: ${out}"
B3="${TDIR}/b-4b-refuse"; mkdir -p "${B3}"; S5="${B3}/sysroot"; make_sysroot "${S5}"
out="$(run_4b "${X86}" "${S5}" "${B3}" "${ONLYNEW}/$(basename "${SEED_NEW}")" true 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "Refusing to restore" >/dev/null && ! printf '%s' "${out}" | grep -a -F "4B-COMPLETED" >/dev/null \
   && [ ! -f "${S5}/usr/lib64/libc_nonshared.a" ]; then
    ok "4b (only a mismatching seed cached, even for GPU=true): refused, nothing restored, build stops"
else
    bad "4b refusal: rc=${rc}: ${out}"
fi
# 2c. the link check after mount_chroot: only under --resume, stops before emerge.
run_link_block() {   # <builder> <resume> <sysroot> <gcc fail 0|1>
    local b="$1" resume="$2" sysroot="$3" fail="$4"
    local sec="${TDIR}/sec-link.sh"
    extract_section "$b" '^mount_chroot$' 'hmr_link_check_chroot' '^fi$' "${sec}" || return 99
    : > "${STUB_STATE}/chroot-dirs"
    PATH="${TDIR}/bin:${PATH}" STUB_GCC_FAIL="${fail}" timeout "${WALL}" bash -c "
        set -euo pipefail
        . '${LIB}'
        banner(){ echo \"==> \$1\"; }; info(){ echo \"    \$1\"; }; warn(){ echo \"    WARNING: \$1\"; }; err(){ echo \"    ERROR: \$1\" >&2; }
        mount_chroot(){ echo MOUNTED; }
        RESUME=${resume}; SYSROOT='${sysroot}'
        . '${sec}'
        echo LINK-BLOCK-COMPLETED
    "
}
out="$(run_link_block "${X86}" true "${S4}" 1 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "cannot link a C program" >/dev/null && ! printf '%s' "${out}" | grep -a -F "LINK-BLOCK-COMPLETED" >/dev/null \
   && [ "$(cat "${STUB_STATE}/chroot-dirs")" = "${S4}" ]; then
    ok "link block (--resume, link fails): one sentence, exit 1 after mount_chroot and before anything else"
else
    bad "link block (--resume, fail): rc=${rc}: ${out}"
fi
out="$(run_link_block "${X86}" true "${S4}" 0 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -a -F "LINK-BLOCK-COMPLETED" >/dev/null && ok "link block (--resume, link works): continues" || bad "link block pass: rc=${rc}: ${out}"
out="$(run_link_block "${X86}" false "${S4}" 1 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && [ ! -s "${STUB_STATE}/chroot-dirs" ] && ok "link block (no --resume): the check is not run (a fresh extract always links)" || bad "link block (no resume): rc=${rc} chroot-dirs=$(cat "${STUB_STATE}/chroot-dirs")"
# 2d. umount_chroot: the distfiles-ro bind is in the list, each flag resets, the detach is verified.
run_umount_chroot() {   # <builder> <sysroot> <distfiles true|false>
    local b="$1" sysroot="$2" dist="$3"
    local sec="${TDIR}/sec-umount.sh"
    # awk -v processes backslash escapes once: double them so the regex keeps them.
    extract_section "$b" '^umount_chroot\\(\\) \\{$' 'umount_chroot' '^\\}$' "${sec}" || return 99
    : > "${STUB_STATE}/umount-args"
    PATH="${TDIR}/bin-um:${PATH}" timeout "${WALL}" bash -c "
        set -euo pipefail
        . '${LIB}'
        banner(){ echo \"==> \$1\"; }; info(){ echo \"    \$1\"; }; warn(){ echo \"    WARNING: \$1\"; }; err(){ echo \"    ERROR: \$1\" >&2; }
        SYSROOT='${sysroot}'
        DISTFILES_MOUNTED=${dist}; PORTAGE_SCRATCH_MOUNTED=true; HOST_REPO_MOUNTED=true; X86_POOL_MOUNTED=true
        . '${sec}'
        umount_chroot
        echo \"flags-after: \${DISTFILES_MOUNTED} \${PORTAGE_SCRATCH_MOUNTED} \${HOST_REPO_MOUNTED} \${X86_POOL_MOUNTED}\"
        umount_chroot
        echo UMOUNT-COMPLETED
    "
}
# A stateful mount table: findmnt prints it, umount peels ONE line equal to
# its path argument (what the kernel does for a stacked bind) unless the
# fixture says the detach silently fails (still-mounted).
mkdir -p "${TDIR}/bin-um"
cat > "${TDIR}/bin-um/findmnt" <<'STUB'
#!/usr/bin/env bash
cat "${STUB_STATE}/mounts" 2>/dev/null
STUB
cat > "${TDIR}/bin-um/umount" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_STATE}/umount-args"
[ -f "${STUB_STATE}/still-mounted" ] && exit 0
p=""; for a in "$@"; do case "$a" in -*) ;; *) p="$a" ;; esac; done
awk -v p="$p" '!done && $0==p {done=1; next} {print}' "${STUB_STATE}/mounts" > "${STUB_STATE}/mounts.new" 2>/dev/null && mv "${STUB_STATE}/mounts.new" "${STUB_STATE}/mounts"
exit 0
STUB
chmod +x "${TDIR}/bin-um/umount" "${TDIR}/bin-um/findmnt"
set_mounts() {   # <sysroot>: our four flagged binds (distfiles-ro stacked on one foreign layer) + run/dev/sys/proc
    printf '%s\n' "$1/var/cache/distfiles-ro" "$1/var/cache/distfiles-ro" "$1/var/tmp/portage" "$1/var/db/repos/gentoo" "$1/var/cache/binpkgs" \
                  "$1/run" "$1/dev" "$1/sys" "$1/proc" > "${STUB_STATE}/mounts"
}
set_mounts "${S4}"
out="$(run_umount_chroot "${X86}" "${S4}" true 2>&1)"; rc=$?
n_dist="$(grep -a -c "distfiles-ro" "${STUB_STATE}/umount-args")"
n_all="$(wc -l < "${STUB_STATE}/umount-args")"
left_dist="$(grep -a -c "distfiles-ro" "${STUB_STATE}/mounts")"
if [ "${rc}" -eq 0 ] && [ "${n_dist}" -eq 1 ] && [ "${n_all}" -eq 12 ] && [ "${left_dist}" -eq 1 ] \
   && printf '%s' "${out}" | grep -a -F "flags-after: false false false false" >/dev/null \
   && ! printf '%s' "${out}" | grep -a -F "STILL mounted" >/dev/null; then
    ok "umount_chroot: peels ONE distfiles-ro layer (the foreign one beneath stays), scratch, repo, pool + run/dev/sys/proc; flags reset so a second call unmounts only run/dev/sys/proc (12 umounts total); no warning"
else
    bad "umount_chroot: rc=${rc} distfiles=${n_dist} total=${n_all} left=${left_dist}: ${out} :: $(cat "${STUB_STATE}/umount-args")"
fi
set_mounts "${S4}"
out="$(run_umount_chroot "${X86}" "${S4}" false 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && [ "$(grep -a -c "distfiles-ro" "${STUB_STATE}/umount-args")" -eq 0 ] && [ "$(grep -a -c "distfiles-ro" "${STUB_STATE}/mounts")" -eq 2 ] \
    && ok "umount_chroot: does NOT unmount distfiles-ro it did not mount (DISTFILES_MOUNTED=false); both foreign layers stay" \
    || bad "umount_chroot (not ours): rc=${rc} $(cat "${STUB_STATE}/umount-args")"
set_mounts "${S4}"; touch "${STUB_STATE}/still-mounted"
out="$(run_umount_chroot "${X86}" "${S4}" true 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -a -F "distfiles-ro is STILL mounted (2 layer(s)) after this build's own umount" >/dev/null \
    && printf '%s' "${out}" | grep -a -F "UMOUNT-COMPLETED" >/dev/null \
    && ok "umount_chroot: a detach that did not happen (layer count unchanged) is said out loud, build continues" \
    || bad "umount_chroot verify: rc=${rc}: ${out}"
rm -f "${STUB_STATE}/still-mounted"

echo "== 3. call-site pins (every builder) and the refusal executed on each cross builder =="
pin_x86() {   # <builder> -> 0 when every pin holds
    local b="$1" rc=0
    local n_gate n_skip n_mc n_lc n_em
    has "$b" 'source "${SCRIPT_DIR}/scripts/_builder-resume-lib.sh"' || rc=1
    n_gate="$(grep -a -n -F 'hmr_owner_gate "${SYSROOT}" || exit 1' "$b" | head -1 | cut -d: -f1)"
    n_skip="$(grep -a -n -F 'skipping extraction' "$b" | head -1 | cut -d: -f1)"
    [ -n "${n_gate}" ] && [ -n "${n_skip}" ] && [ "${n_gate}" -lt "${n_skip}" ] || rc=1
    # the 4b condition is exactly this line: any prefix (the old `${GPU} &&`) breaks it
    hasr "$b" '^if hmr_statics_missing "\$\{SYSROOT\}"; then$' || rc=1
    n_mc="$(grep -a -n -E '^mount_chroot$' "$b" | head -1 | cut -d: -f1)"
    n_lc="$(grep -a -n -F 'hmr_link_check_chroot "${SYSROOT}" || exit 1' "$b" | head -1 | cut -d: -f1)"
    # the first emerge COMMAND after mount_chroot (a line starting with `emerge `),
    # not the first mention of the word in a comment.
    n_em="$(awk -v s="${n_mc:-0}" 'NR>s && /^[[:space:]]*emerge[[:space:]]/ {print NR; exit}' "$b")"
    [ -n "${n_mc}" ] && [ -n "${n_lc}" ] && [ -n "${n_em}" ] && [ "${n_mc}" -lt "${n_lc}" ] && [ "${n_lc}" -lt "${n_em}" ] || rc=1
    has "$b" 'hmr_umount_own "${SYSROOT}/var/cache/distfiles-ro"' || rc=1
    has "$b" 'hmr_stale_mount_refuse "${SYSROOT}" "${_stale_mounts}"' || rc=1
    has "$b" 'hmr_seed_marker_write "${BUILD_ROOT}" "${STAGE3_LOCAL}"' || rc=1
    grep -a -F "umount -R '\${SYSROOT}'" "$b" >/dev/null 2>&1 && rc=1
    return "${rc}"
}
pin_x86 "${X86}" && ok "x86 pins: lib sourced; owner gate before 'skipping extraction'; 4b ungated (no '\${GPU} &&'); link check between mount_chroot and the first emerge; distfiles-ro in umount_chroot; stale refusal + marker present; no 'umount -R' hint left" \
    || bad "x86 pins: one or more call sites missing (run: bash -x on pin_x86)"
pin_rpi() {
    local b="$1" rc=0 n_ref n_rm
    n_ref="$(grep -a -n -F 'hmr_stale_mount_refuse "${SYSROOT}" "${_stale_mounts}"' "$b" | head -1 | cut -d: -f1)"
    n_rm="$(grep -a -n -F 'rm -rf "${SYSROOT:?}"' "$b" | head -1 | cut -d: -f1)"
    [ -n "${n_ref}" ] && [ -n "${n_rm}" ] && [ "${n_ref}" -lt "${n_rm}" ] || rc=1
    has "$b" 'aarch64-unknown-linux-gnu-gcc -print-sysroot' || rc=1
    return "${rc}"
}
pin_rpi "${RPI}" && ok "rpi5 pins: stale-mount refusal before the rm -rf of the sysroot; the reason its restore/link test do not apply is written down (print-sysroot evidence)" \
    || bad "rpi5 pins missing"
# EVERY other builder (rpi5 and the seven cross builders) binds host /proc, /sys
# and /dev under its sysroot for the qemu-chroot dracut step, so each shares the
# stale-mount hazard — MEASURED here, by the bind itself, not by the x86 function
# name `mount_chroot` (which none of them uses) — and each carries the same
# refusal before its extraction branch. The owner gate is there too, for a ROOT
# build only, on the seven whose media are made straight from the sysroot and
# keep its owners (jetson: the .img tar pipe; frite + orangepi: the live and
# installer squashfs) — with the remedy "remove the tree", because those seven
# extract a stage3 OVER an existing tree rather than wiping it. A NON-ROOT cross
# build owns its sysroot by design (`--no-same-owner` at the stage3 extract) and
# is exempt. rpi5 has no gate: every owner in its stage4 tarball is forced to 0
# and its .img is filled from that tarball (both pinned). None but rpi5 has a
# `*.a` clean step, and rpi5's cross toolchain links against
# /usr/aarch64-unknown-linux-gnu, never the sysroot: no restore, no link test.
pin_arm() {   # <builder> -> 0 when every pin holds
    local b="$1" rc=0 n_ref n_skip n_gate n_cond
    grep -a -F 'mount --bind /proc "${SYSROOT}/proc"' "$b" >/dev/null 2>&1 || { echo "    (no /proc bind under the sysroot in $(basename "$b") — the hazard this pin is about is gone; re-measure)"; rc=1; }
    has "$b" 'source "${SCRIPT_DIR}/scripts/_builder-resume-lib.sh"' || rc=1
    n_ref="$(grep -a -n -F 'hmr_stale_mount_refuse "${SYSROOT}" "${_stale_mounts}"' "$b" | head -1 | cut -d: -f1)"
    n_skip="$(grep -a -n -F 'skipping extraction' "$b" | head -1 | cut -d: -f1)"
    [ -n "${n_ref}" ] && [ -n "${n_skip}" ] && [ "${n_ref}" -lt "${n_skip}" ] || rc=1
    case "$(basename "$b")" in
        build-rpi5-stage4.sh)
            # Every owner in its stage4 tarball is forced to 0 and its .img is filled
            # FROM that tarball: a user-owned tree cannot reach the image, so no gate.
            # Both halves of that evidence are pinned; if either moves, re-measure.
            grep -a -F 'hmr_owner_gate' "$b" >/dev/null 2>&1 && rc=1
            has "$b" '--numeric-owner --owner=0 --group=0' || rc=1
            has "$b" '-xpf "${STAGE4_TARBALL}"' || rc=1 ;;
        *)
            # The gate, for a ROOT build only — the line right above it is the id -u
            # test — before 'skipping extraction', with the remove-the-tree remedy.
            # No *.a clean step (one arriving would need the restore too).
            n_gate="$(grep -a -n -F 'hmr_owner_gate "${SYSROOT}" "remove ${SYSROOT} (this builder extracts the stage3 over an existing tree' "$b" | head -1 | cut -d: -f1)"
            n_cond="$(grep -a -n -F 'if [ "$(id -u)" -eq 0 ]; then' "$b" | awk -F: -v g="${n_gate:-0}" '$1<g {l=$1} END{print l+0}')"
            [ -n "${n_gate}" ] && [ "${n_gate}" -lt "${n_skip}" ] && [ $((n_gate - n_cond)) -eq 1 ] || rc=1
            grep -a -F "name '*.a' -delete" "$b" >/dev/null 2>&1 && rc=1 ;;
    esac
    return "${rc}"
}
# The same Extract-phase stale refusal, executed on each builder's own text (stub findmnt).
run_arm_extract() {   # <builder> <sysroot> <epath>
    local sec="${TDIR}/sec-arm.sh"
    extract_section "$1" '^banner "Extracting stage3 into sysroot"$' 'hmr_stale_mount_refuse' '^fi$' "${sec}" || return 99
    PATH="$3:${PATH}" timeout "${WALL}" bash -c "
        set -euo pipefail
        . '${LIB}'
        banner(){ echo \"==> \$1\"; }; info(){ echo \"    \$1\"; }; warn(){ echo \"    WARNING: \$1\"; }; err(){ echo \"    ERROR: \$1\" >&2; }
        RESUME=false; SYSROOT='$2'
        . '${sec}'
        echo ARM-EXTRACT-GUARD-PASSED
    "
}
# The whole extraction if/else of each builder with RESUME=true on the FIX_UID-
# owned fixture, with a stub `id` answering STUB_ID_UID to `id -u`, so the
# root-only gate is driven both ways whatever user this file runs as.
mkdir -p "${TDIR}/bin-id"; REAL_ID="$(command -v id)"
cat > "${TDIR}/bin-id/id" <<STUB
#!/usr/bin/env bash
# \`id -u\` answers STUB_ID_UID when set; everything else goes to the real id.
if [ "\${1:-}" = -u ] && [ -n "\${STUB_ID_UID:-}" ]; then
    printf '%s\n' "\${STUB_ID_UID}"
else
    exec "${REAL_ID}" "\$@"
fi
STUB
chmod +x "${TDIR}/bin-id/id"
run_arm_resume() {   # <builder> <sysroot> <uid the stub id answers>
    local sec="${TDIR}/sec-arm-resume.sh"
    extract_section "$1" '^banner "Extracting stage3 into sysroot"$' 'skipping extraction' '^fi$' "${sec}" || return 99
    PATH="${TDIR}/bin-id:${PATH}" STUB_ID_UID="$3" timeout "${WALL}" bash -c "
        set -euo pipefail
        . '${LIB}'
        banner(){ echo \"==> \$1\"; }; info(){ echo \"    \$1\"; }; warn(){ echo \"    WARNING: \$1\"; }; err(){ echo \"    ERROR: \$1\" >&2; }
        RESUME=true; SYSROOT='$2'; STAGE3_LOCAL='${SEED_OLD}'
        . '${sec}'
        echo ARM-RESUME-BRANCH-COMPLETED
    "
}
make_sysroot "${SX}"   # user-owned again: the non-resume leg above re-extracted it (under root, as root's)
n_arm=0
for b in "${REPO}"/build-*-stage4.sh; do
    bn="$(basename "$b")"
    [ "${bn}" = build-x86-host-stage4.sh ] && continue
    n_arm=$((n_arm+1))
    pin_arm "$b" || { bad "${bn} pins: lib sourced + stale-mount refusal before 'skipping extraction'; the root-only owner gate with the remove-the-tree remedy (rpi5: none, its owners are forced to 0); no *.a clean (run: bash -x on pin_arm)"; continue; }
    out="$(run_arm_extract "$b" "${SX}" "${TDIR}/bin-mnt" 2>&1)"; rc=$?
    if [ "${rc}" -ne 1 ] || ! printf '%s' "${out}" | grep -a -F "mounts are still attached under ${SX}" >/dev/null; then
        bad "${bn} extract guard (stale binds): rc=${rc}: ${out}"; continue
    fi
    out="$(run_arm_extract "$b" "${SX}" "${TDIR}/bin-none" 2>&1)"; rc=$?
    if [ "${rc}" -ne 0 ] || ! printf '%s' "${out}" | grep -a -F "ARM-EXTRACT-GUARD-PASSED" >/dev/null; then
        bad "${bn} extract guard (no mounts): rc=${rc}: ${out}"; continue
    fi
    if [ "${bn}" = build-rpi5-stage4.sh ]; then
        out="$(run_arm_resume "$b" "${SX}" 0 2>&1)"; rc=$?
        if [ "${rc}" -ne 0 ] || ! printf '%s' "${out}" | grep -a -F "skipping extraction" >/dev/null; then
            bad "${bn} resume (root, user-owned tree): expected to proceed (its owners are forced to 0 at packaging), got rc=${rc}: ${out}"; continue
        fi
        ok "${bn}: binds host /proc under its sysroot; lib sourced; stale refusal pinned + EXECUTED (stale binds -> refused with the loop hint; clean -> passes); a root resume on a user-owned tree proceeds — no gate, every owner in its stage4 tarball is forced to 0 and the .img is filled from it (pinned)"
        continue
    fi
    out="$(run_arm_resume "$b" "${SX}" 0 2>&1)"; rc=$?
    if [ "${rc}" -ne 1 ] || ! printf '%s' "${out}" | grep -a -F "Refusing --resume: the build system directory ${SX} is owned by uid ${FIX_UID}" >/dev/null \
       || ! printf '%s' "${out}" | grep -a -F "remove ${SX} (this builder extracts the stage3 over an existing tree" >/dev/null \
       || printf '%s' "${out}" | grep -a -F "skipping extraction" >/dev/null; then
        bad "${bn} resume (root, user-owned tree): expected ONE refusal with the remove-the-tree remedy before 'skipping extraction', got rc=${rc}: ${out}"; continue
    fi
    out="$(run_arm_resume "$b" "${SX}" 1000 2>&1)"; rc=$?
    if [ "${rc}" -ne 0 ] || ! printf '%s' "${out}" | grep -a -F "skipping extraction" >/dev/null; then
        bad "${bn} resume (non-root, user-owned tree): expected to proceed (a non-root build owns its tree by design), got rc=${rc}: ${out}"; continue
    fi
    ok "${bn}: binds host /proc under its sysroot; lib sourced; stale refusal pinned + EXECUTED (stale binds -> refused with the loop hint; clean -> passes); root-only owner gate EXECUTED (root + user-owned tree -> refused, remedy says remove the tree; non-root -> proceeds)"
done
[ "${n_arm}" -eq 9 ] && ok "nine non-x86 builders measured (rpi5 + frite + jetson + six orangepi)" || bad "expected 9 non-x86 builders, found ${n_arm}: a builder was added or removed — re-measure its resume path"

echo "== 4. mutation battery: each guard removed from a COPY must turn its leg RED =="
mutate() {   # <name> <sed expr> -> path of mutated copy (fails the suite if unchanged)
    local m="${TDIR}/mut-$1.sh"
    sed -e "$2" "${X86}" > "$m"
    if cmp -s "$m" "${X86}"; then bad "mutation '$1' did not change the builder text"; return 1; fi
    printf '%s\n' "$m"
}
# M1: the owner gate call deleted -> the extract phase proceeds on a user-owned tree.
if m="$(mutate no-owner-gate '/hmr_owner_gate "\${SYSROOT}" || exit 1/d')"; then
    make_sysroot "${SX}"
    out="$(run_extract_phase "$m" true "${SX}" "${B1}" "${SEED_OLD}" 2>&1)"; rc=$?
    { [ "${rc}" -ne 1 ] || printf '%s' "${out}" | grep -a -F "skipping extraction" >/dev/null; } && ! pin_x86 "$m" \
        && ok "M1 owner gate removed: the phase skips extraction on a user-owned tree (leg RED) and the pin is RED" \
        || bad "M1: removing the owner gate was not caught (rc=${rc})"
fi
# M2: the GPU-only gate put back -> a pki (GPU=false) resume restores nothing.
if m="$(mutate gpu-gate 's/^if hmr_statics_missing "\${SYSROOT}"; then$/if ${GPU} \&\& hmr_statics_missing "${SYSROOT}"; then/')"; then
    rm -rf "${B2}"; mkdir -p "${B2}"; make_sysroot "${S4}"
    out="$(run_4b "$m" "${S4}" "${B2}" "${SEED_NEW}" false 2>&1)"; rc=$?
    [ ! -f "${S4}/usr/lib64/libc_nonshared.a" ] && ! pin_x86 "$m" \
        && ok "M2 '\${GPU} &&' put back: pki resume restores nothing (leg RED) and the pin is RED" \
        || bad "M2: GPU gate not caught"
fi
# M3: the link check deleted -> a resumed build that cannot link goes on to emerge.
if m="$(mutate no-link-check '/hmr_link_check_chroot "\${SYSROOT}" || exit 1/d')"; then
    out="$(run_link_block "$m" true "${S4}" 1 2>&1)"; rc=$?
    { [ "${rc}" -ne 1 ] || ! printf '%s' "${out}" | grep -a -F "cannot link" >/dev/null; } && ! pin_x86 "$m" \
        && ok "M3 link check removed: the block continues past a failing link (leg RED) and the pin is RED" \
        || bad "M3: link check removal not caught"
fi
# M4: distfiles-ro dropped from umount_chroot -> the bind stays behind.
# (the call becomes a no-op rather than a deleted line: an empty `if` body would
# be a syntax error and the leg would go red for the wrong reason)
if m="$(mutate no-distfiles-umount 's/hmr_umount_own "\${SYSROOT}\/var\/cache\/distfiles-ro" || true/:/')"; then
    set_mounts "${S4}"
    out="$(run_umount_chroot "$m" "${S4}" true 2>&1)"
    [ "$(grep -a -c "distfiles-ro" "${STUB_STATE}/umount-args")" -eq 0 ] && ! pin_x86 "$m" \
        && ok "M4 distfiles-ro umount removed: the bind is left behind (leg RED) and the pin is RED" \
        || bad "M4: distfiles-ro umount removal not caught"
fi
# M5: the stale-mount refusal moved back inside the non-resume branch -> a resume stacks.
if m="$(mutate stale-only-nonresume '/^if \[ -d "\${SYSROOT}" \]; then$/,/^fi$/{s/^if \[ -d "\${SYSROOT}" \]; then$/if ! ${RESUME} \&\& [ -d "${SYSROOT}" ]; then/}')"; then
    out="$(run_extract_phase "$m" true "${SX}" "${B1}" "${SEED_OLD}" "${TDIR}/bin-mnt" 2>&1)"; rc=$?
    ! printf '%s' "${out}" | grep -a -F "mounts are still attached" >/dev/null \
        && ok "M5 stale refusal gated on non-resume only: a resume over stacked binds is NOT refused (leg RED)" \
        || bad "M5: gating the stale refusal was not caught"
fi
# M6: the old hint restored -> the pin catches 'umount -R'.
if m="$(mutate old-hint 's/hmr_stale_mount_hint "\${SYSROOT}")  — then re-run/umount -R '"'"'${SYSROOT}'"'"'  — then re-run/')"; then
    ! pin_x86 "$m" && ok "M6 old 'umount -R <sysroot>' hint restored: pin RED" || bad "M6: old hint not caught"
fi
# M7: the seed marker write deleted -> a fresh extract leaves no marker.
if m="$(mutate no-marker '/hmr_seed_marker_write "\${BUILD_ROOT}" "\${STAGE3_LOCAL}" || true/d')"; then
    rm -f "${B1}/sysroot.seed"; make_sysroot "${SX}"
    out="$(run_extract_phase "$m" false "${SX}" "${B1}" "${SEED_OLD}" 2>&1)"; rc=$?
    [ ! -f "${B1}/sysroot.seed" ] && ! pin_x86 "$m" && ok "M7 marker write removed: no marker after a fresh extract (leg RED) and the pin is RED" || bad "M7: marker removal not caught"
fi
# M8 (lib): the toolchain comparison short-circuited to 'match' -> the mismatching seed is accepted.
sed -e 's/^hmr_toolchain_matches() {$/hmr_toolchain_matches() { return 0; }\nhmr_toolchain_matches_real() {/' "${LIB}" > "${TDIR}/mut-lib.sh"
cmp -s "${TDIR}/mut-lib.sh" "${LIB}" && bad "M8 lib mutation did not apply"
out="$(bash -c ". '${TDIR}/mut-lib.sh'; hmr_seed_for_resume '${B3}' '${S5}' '${ONLYNEW}/$(basename "${SEED_NEW}")' '${L}'" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "M8 version comparison disabled: the binutils-2.47 seed is accepted for a 2.46.1 build system (leg RED — the comparison is what refuses it)" \
    || bad "M8: disabling the comparison changed nothing (rc=${rc})"
# M9 (cross builders): the root-only owner gate turned into a no-op in a COPY of
# the jetson builder (a deleted line would leave an empty `if` body — a syntax
# error, red for the wrong reason) -> a root resume on a user-owned tree
# proceeds to 'skipping extraction' (leg RED) and the pin is RED.
JET="${REPO}/build-jetson-stage4.sh"
sed -e 's/^        hmr_owner_gate "\${SYSROOT}" "remove \${SYSROOT} (this builder extracts the stage3 over an existing tree.*$/        :/' "${JET}" > "${TDIR}/mut-jetson-no-gate.sh"
if cmp -s "${TDIR}/mut-jetson-no-gate.sh" "${JET}"; then
    bad "M9 mutation did not change the jetson builder text"
else
    make_sysroot "${SX}"
    out="$(run_arm_resume "${TDIR}/mut-jetson-no-gate.sh" "${SX}" 0 2>&1)"; rc=$?
    [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -a -F "skipping extraction" >/dev/null && ! pin_arm "${TDIR}/mut-jetson-no-gate.sh" \
        && ok "M9 cross-builder owner gate removed: a root resume on a user-owned tree proceeds (leg RED) and the pin is RED" \
        || bad "M9: removing the cross builder's owner gate was not caught (rc=${rc}: ${out})"
fi

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
