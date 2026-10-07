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
#     check after mount_chroot (stub chroot + stub gcc), umount_chroot and the
#     binpkgs guard after it (a stateful umount stub that edits the table).
#   - the KERNEL'S MOUNT TABLE is a fixture written in the kernel's own format
#     and escaping (HMR_MOUNTINFO), so every question about mounts is asked of a
#     table whose spelling of the build system (canonical path, \040 for a space)
#     differs from the spelling the builder is given (a symlink, a space, an
#     umlaut, a relative path): the very difference the first version of the
#     library could not see (a review found it unmounted nothing on such a path).
#   - call-site pins against the builder text, for every builder, and the
#     stale-mount refusal executed on each cross builder's own text.
#   - a MUTATION BATTERY: each guard is removed from a COPY of the builder (the
#     copy is `cmp`-checked to differ), and the leg that covers it must go RED;
#     each line of the library that a leg depends on is mutated in a copy of the
#     library and this whole suite is run against it (HMR_TEST_LIB), which must
#     go red on the leg that covers that line.
#
# Real bind mounts (stacked, in a user+mount namespace) are the subject of the
# sibling suite tests/scripts/test-builder-unmount-real.sh, which needs
# `unshare -Urm`; this file needs no privilege at all.
#
# HOST TRAPS this file is written against: no `| grep -q` under pipefail (drain
# to /dev/null and branch on the status); `grep -a` everywhere; no `local` line
# that reads one of its own names (bash 5.3); every dynamic leg runs under
# `timeout`.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TEST_DIR}/../.." && pwd)"
# HMR_TEST_LIB / HMR_TEST_X86 point the whole suite at another copy of the library
# or the x86 builder: how a mutation of either is run against EVERY leg from
# outside (the battery at the end of this file mutates copies of its own).
LIB="${HMR_TEST_LIB:-${REPO}/scripts/_builder-resume-lib.sh}"
X86="${HMR_TEST_X86:-${REPO}/build-x86-host-stage4.sh}"
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
for t in tar xz find stat mktemp timeout cmp readlink awk sort sed mkfifo; do
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
# The current seed's URL as the builder spells it (<autobuilds>/<timestamp>/<name>),
# and a recording stand-in for the builder's verifier: section 4b re-verifies any
# cached seed that is not the current one before root extracts from it, through
# "${SA_VERIFY_CMD:-dlv_verify_stage3}" (the real one fetches the signed DIGESTS from
# the mirror; nothing here touches the network). Every call is logged as
# "<seed> <digests url>"; STUB_VERIFY_FAIL=1 makes it fail the way a checksum
# mismatch does.
STAGE3_URL_FIX="https://distfiles.gentoo.org/releases/amd64/autobuilds/20260927T170058Z/stage3-amd64-hardened-openrc-20260927T170058Z.tar.xz"
DIGESTS_OLD="https://distfiles.gentoo.org/releases/amd64/autobuilds/20260920T170055Z/stage3-amd64-hardened-openrc-20260920T170055Z.tar.xz.DIGESTS"
export VERIFY_LOG="${TDIR}/verify-calls"; : > "${VERIFY_LOG}"
stub_verify() {
    printf '%s %s\n' "$1" "$2" >> "${VERIFY_LOG}"
    if [ "${STUB_VERIFY_FAIL:-0}" = 1 ]; then
        echo "[verify-download] ERROR: stage3 tarball checksum did not match the signed DIGESTS — aborting build." >&2
        return 1
    fi
    return 0
}
export -f stub_verify
export SA_VERIFY_CMD=stub_verify

# Builder log helpers the sections call (the real ones colour their output).
banner() { echo "==> $1"; }
info()   { echo "    $1"; }
warn()   { echo "    WARNING: $1"; }
err()    { echo "    ERROR: $1" >&2; }
export -f banner info warn err

# The kernel's mount table is a FIXTURE here, written in the kernel's own format and
# escaping — deliberately NOT through the decoder under test. /proc/self/mountinfo
# names a mount point with every space, tab, newline and backslash written as \NNN
# (three octal digits) and every other byte as it is, and names it by its CANONICAL
# path (symlinks resolved). HMR_MOUNTINFO points the library at the fixture.
kernel_escape() {
    local s="$1"
    s="${s//\\/\\134}"; s="${s// /\\040}"; s="${s//$'\t'/\\011}"; s="${s//$'\n'/\\012}"
    printf '%s' "${s}"
}
write_mountinfo() {   # <file> <mount point>... : one line each, ids ascending (a later line is on top)
    local f="$1" id=100 p
    shift; : > "${f}"
    for p in "$@"; do
        printf '%s 1 0:50 / %s rw,relatime shared:1 - tmpfs tmpfs rw\n' "${id}" "$(kernel_escape "${p}")" >> "${f}"
        id=$((id+1))
    done
}
export -f kernel_escape write_mountinfo
# A stateful umount for that table: it resolves its path argument the way the
# kernel does (symlinks), then removes the TOPMOST (last) line for that mount point,
# or exits 32 ("not mounted") when there is none. Every call is recorded. The
# match is on the escaped text (what the kernel would have written), so it shares no
# code with the decoder under test. It edits ${STUB_TABLE}, which a leg points at the
# same file as HMR_MOUNTINFO, or elsewhere when it wants the library to be blind.
export STUB_STATE="${TDIR}/state"; mkdir -p "${STUB_STATE}" "${TDIR}/bin-um"
cat > "${TDIR}/bin-um/umount" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_STATE}/umount-args"
[ -f "${STUB_STATE}/still-mounted" ] && exit 0
table="${STUB_TABLE:-${HMR_MOUNTINFO:-/nonexistent}}"
p=""; for a in "$@"; do case "$a" in -*) ;; *) p="$a" ;; esac; done
real="$(readlink -f -- "$p" 2>/dev/null || printf '%s' "$p")"
s="$real"; s="${s//\\/\\134}"; s="${s// /\\040}"; s="${s//$'\t'/\\011}"; s="${s//$'\n'/\\012}"
WANT="$s" awk '{ line[NR]=$0; if ($5==ENVIRON["WANT"]) last=NR } END { for (i=1;i<=NR;i++) if (i!=last) print line[i]; exit (last ? 0 : 1) }' "${table}" > "${table}.new" \
    && mv "${table}.new" "${table}" || { rm -f "${table}.new"; exit 32; }
exit 0
STUB
chmod +x "${TDIR}/bin-um/umount"

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
# a seed that itself ships TWO gcc slots (a stage3 made during a gcc transition)
# matches a build system carrying both; the old "exactly three packages" count
# refused it even when the marker named it.
SEED_2GCC="${TDIR}/stage3-amd64-hardened-openrc-20260801T170000Z.tar.xz"
s2="$(mktemp -d "${TDIR}/seedsrc.XXXXXX")"
mkdir -p "${s2}/var/db/pkg/sys-libs/glibc-2.43-r2" "${s2}/var/db/pkg/sys-devel/gcc-14.3.0" "${s2}/var/db/pkg/sys-devel/gcc-15.3.0" \
         "${s2}/var/db/pkg/sys-devel/binutils-2.46.1" "${s2}/usr/lib64"
echo "seed" > "${s2}/usr/lib64/libc_nonshared.a"
tar -C "${s2}" -cJf "${SEED_2GCC}" . && rm -rf "${s2}"
SM2="${TDIR}/sr-2gcc"; make_sysroot "${SM2}"; mkdir -p "${SM2}/var/db/pkg/sys-devel/gcc-14.3.0"
hmr_seed_list "${SEED_2GCC}" "${L}"
hmr_toolchain_matches "${L}" "${SM2}" && ok "toolchain match: a seed shipping two gcc slots matches a build system that carries both" \
    || bad "toolchain match (two gcc slots): a seed with gcc-14 and gcc-15 was refused for a build system carrying both"
hmr_toolchain_matches "${L}" "${SM}" && bad "toolchain match (two gcc slots): accepted by a build system lacking gcc-14" \
    || ok "toolchain match: the two-slot seed is refused by a build system that lacks one of its slots"
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
# the marker is tried FIRST: two cached seeds with the SAME toolchain, the marker
# naming the older one, the newer one current -> the marker's seed is chosen (only
# the version match ordered the candidates before; a newer seed with the same
# versions can still differ in the files it ships).
TWIN="${TDIR}/seed-twins"; mkdir -p "${TWIN}"
SEED_TWIN_OLD="${TWIN}/stage3-amd64-hardened-openrc-20260913T170000Z.tar.xz"
SEED_TWIN_NEW="${TWIN}/stage3-amd64-hardened-openrc-20260920T170055Z.tar.xz"
cp "${SEED_OLD}" "${SEED_TWIN_OLD}"; cp "${SEED_OLD}" "${SEED_TWIN_NEW}"
BRT="${TDIR}/br-twin"; mkdir -p "${BRT}"; hmr_seed_marker_write "${BRT}" "${SEED_TWIN_OLD}"
chosen="$(hmr_seed_for_resume "${BRT}" "${SM}" "${SEED_TWIN_NEW}" "${L}" 2>/dev/null)"
[ "${chosen}" = "${SEED_TWIN_OLD}" ] && ok "seed choice (marker first): with two cached seeds of the same toolchain the marker's wins over the current one" \
    || bad "seed choice (marker first): got '${chosen}', wanted the marker's ${SEED_TWIN_OLD}"
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
# 1g2. the fallback glob is restricted to the current seed's FLAVOUR: a cached
# stage3-amd64-openrc (not hardened) seed whose toolchain versions match is never
# a candidate for a stage3-amd64-hardened-openrc build system. With no hardened
# seed matching, the refusal fires and does not even name the foreign one.
FLAV="${TDIR}/seed-flavour"; mkdir -p "${FLAV}"; cp "${SEED_NEW}" "${FLAV}/"
cp "${SEED_OLD}" "${FLAV}/stage3-amd64-openrc-20260920T170055Z.tar.xz"
out="$(hmr_seed_for_resume "${BR}" "${SM}" "${FLAV}/$(basename "${SEED_NEW}")" "${L}" 2>&1 >/dev/null)"; rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "rebuild WITHOUT --resume" >/dev/null \
   && ! printf '%s' "${out}" | grep -a -F "stage3-amd64-openrc-" >/dev/null; then
    ok "seed choice (flavour): a cached seed of another flavour (stage3-amd64-openrc) with a matching toolchain is not a candidate; refused without naming it"
else
    bad "seed choice (flavour): rc=${rc}: ${out}"
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
# ── scenario scripts: each takes the library (and builder) under test as an argument,
# so the same scenario is run against the real files here and against a MUTATED copy
# in the battery at the end of this file (the mutated copy must turn it red). ───────
SCN="${TDIR}/scn"; mkdir -p "${SCN}"
export STUB_BIN="${TDIR}/bin-um"
# _hmr_unmangle against the kernel's escaping.
cat > "${SCN}/unmangle.sh" <<'SCN'
#!/usr/bin/env bash
# <lib>: exit 0 when every raw -> expected pair decodes as the kernel's escaping says.
. "$1"
fail=0
chk() {   # <mount point as the kernel writes it> <the real path>
    local got
    got="$(_hmr_unmangle "$1"; printf x)"; got="${got%x}"
    [ "${got}" = "$2" ] || { printf 'unmangle [%s] -> [%q], wanted [%q]\n' "$1" "${got}" "$2"; fail=1; }
}
chk '/home/u/out/snap-build-x86/sysroot' '/home/u/out/snap-build-x86/sysroot'
chk '/a\040b' '/a b'
chk '/build\0405/x' '/build 5/x'            # a space followed by a digit: what printf %b gets wrong
chk '/a\040\040b' '/a  b'
chk '\040lead' ' lead'
chk 'trail\040' 'trail '
chk '/a\011b' $'/a\tb'
chk '/a\012b' $'/a\nb'
chk '/a\134b' '/a\b'
chk '/x\134040y' '/x\040y'                  # an escaped backslash followed by the digits 040 stays text
chk '/x\134134y' '/x\134y'
chk $'/j\303\266rg' $'/j\303\266rg'         # bytes above 0x7f are written as they are
chk '/hash#x' '/hash#x'
chk '/a\043b' '/a#b'                        # a kernel that also escapes # is decoded too
chk '/odd\bname' '/odd\bname'               # a backslash NOT followed by three octal digits is kept
chk '/pct%s%n' '/pct%s%n'
exit "${fail}"
SCN
# hmr_canon.
cat > "${SCN}/canon.sh" <<'SCN'
#!/usr/bin/env bash
# <lib> <scratch dir>: symlink, relative path, trailing slash, root.
. "$1"; W="$2"
fail=0
mkdir -p "${W}/real/sub"; ln -s real "${W}/link"
P="$(cd "${W}" && pwd -P)"
chk() { [ "$2" = "$3" ] || { printf 'hmr_canon %s: got [%s] wanted [%s]\n' "$1" "$2" "$3"; fail=1; }; }
chk "symlink component" "$(hmr_canon "${W}/link/sub")" "${P}/real/sub"
chk "trailing slash" "$(hmr_canon "${W}/real/sub/")" "${P}/real/sub"
chk "relative" "$(cd "${W}/real" && hmr_canon sub)" "${P}/real/sub"
chk "root" "$(hmr_canon /)" "/"
exit "${fail}"
SCN
# One build system reached by a spelling that differs from the kernel's.
cat > "${SCN}/spelling.sh" <<'SCN'
#!/usr/bin/env bash
# <lib> <x86 builder> <the sysroot as the builder spells it> [cwd]
# The kernel's table (a fixture in its own format) names the CANONICAL path; every check
# is made through the spelling. Prints one line per failed expectation; exit 0 = all held.
set -uo pipefail
LIBP="$1"; BLD="$2"; S="$3"; cd "${4:-.}" || exit 99
. "${LIBP}"
fail=0
bad() { printf '%s\n' "$*"; fail=1; }
K="$(readlink -f -- "${S}")"
MI="${STUB_STATE}/mi.$$"; export HMR_MOUNTINFO="${MI}" STUB_TABLE="${MI}"
# a mount that LOOKS like it is under a glob-spelled sysroot ([1] read as a class matches '1')
TWIN="${K//\[1\]/1}"
MOUNTS=(/ /home "${K}/var/cache/distfiles-ro" "${K}/dev" "${K}-sibling/x")
[ "${TWIN}" = "${K}" ] || MOUNTS+=("${TWIN}/var/cache/distfiles-ro")
write_mountinfo "${MI}" "${MOUNTS[@]}"
# 1. the stale listing names both mounts under it, and nothing else
got="$(hmr_stale_mounts "${S}")"
want="${K}/var/cache/distfiles-ro"$'\n'"${K}/dev"
[ "${got}" = "${want}" ] || bad "stale listing for [${S}]: got [${got}], wanted [${want}]"
# 2. the layer count sees the distfiles bind
n="$(hmr_mount_layers "${S}/var/cache/distfiles-ro")"
[ "${n}" = 1 ] || bad "layer count for [${S}/var/cache/distfiles-ro]: ${n}, wanted 1"
# 3. the builder's own umount_chroot, with SYSROOT spelled the same way, detaches them
UC="${STUB_STATE}/uc.$$"
awk 'BEGIN{on=0} /^umount_chroot\(\) \{$/ {on=1} on {print} on && /^\}$/ {exit}' "${BLD}" > "${UC}"
: > "${STUB_STATE}/umount-args"
out="$( (SYSROOT="${S}"; DISTFILES_MOUNTED=true; PORTAGE_SCRATCH_MOUNTED=false; HOST_REPO_MOUNTED=false; X86_POOL_MOUNTED=false
         . "${UC}"; PATH="${STUB_BIN}:${PATH}"; umount_chroot) 2>&1)"
left="$(hmr_stale_mounts "${S}")"
[ -z "${left}" ] || bad "umount_chroot with SYSROOT=[${S}] left [${left}] mounted"
[ -z "${out}" ] || bad "umount_chroot with SYSROOT=[${S}] printed [${out}]"
# 4. the Extract phase refuses on the stale bind, whichever way the sysroot is spelled
write_mountinfo "${MI}" / "${K}/var/cache/distfiles-ro"
SEC="${STUB_STATE}/ex.$$"
awk -v s='^banner "Extracting stage3 into sysroot"$' -v l='hmr_seed_marker_write' -v e='^fi$' \
    '!on && $0 ~ s {on=1} on {print; if (!seen && $0 ~ l) seen=1; if (seen && $0 ~ e) exit}' "${BLD}" > "${SEC}"
for r in true false; do
    out="$( (set -euo pipefail; acquire_build_lock() { :; }; RESUME=${r}; SYSROOT="${S}"; BUILD_ROOT="${STUB_STATE}/br.$$"; STAGE3_LOCAL=/nonexistent
             . "${SEC}"; echo EXTRACT-PHASE-COMPLETED) 2>&1)"; rc=$?
    if [ "${rc}" -eq 0 ] || ! printf '%s' "${out}" | grep -a -F "mounts are still attached under ${S}" >/dev/null \
       || printf '%s' "${out}" | grep -a -F "EXTRACT-PHASE-COMPLETED" >/dev/null; then
        bad "Extract phase (RESUME=${r}) with SYSROOT=[${S}] did not refuse: rc=${rc}: ${out}"
    fi
done
exit "${fail}"
SCN
# The build's own umount does not wait for the table.
cat > "${SCN}/blind.sh" <<'SCN'
#!/usr/bin/env bash
# <lib> <x86 builder> <sysroot spelling>: the library cannot read the table, the kernel
# still has the bind; umount_chroot must unmount it anyway (and say nothing).
set -uo pipefail
LIBP="$1"; BLD="$2"; S="$3"
. "${LIBP}"
fail=0
K="$(readlink -f -- "${S}")"
TAB="${STUB_STATE}/blind.$$"; write_mountinfo "${TAB}" / "${K}/var/cache/distfiles-ro"
export STUB_TABLE="${TAB}" HMR_MOUNTINFO="/nonexistent/mountinfo"
UC="${STUB_STATE}/ucb.$$"
awk 'BEGIN{on=0} /^umount_chroot\(\) \{$/ {on=1} on {print} on && /^\}$/ {exit}' "${BLD}" > "${UC}"
: > "${STUB_STATE}/umount-args"
out="$( (SYSROOT="${S}"; DISTFILES_MOUNTED=true; PORTAGE_SCRATCH_MOUNTED=false; HOST_REPO_MOUNTED=false; X86_POOL_MOUNTED=false
         . "${UC}"; PATH="${STUB_BIN}:${PATH}"; umount_chroot) 2>&1)"
grep -a -F "var/cache/distfiles-ro" "${STUB_STATE}/umount-args" >/dev/null || { echo "no umount was attempted on distfiles-ro while the table was unreadable"; fail=1; }
grep -a -F "distfiles-ro" "${TAB}" >/dev/null && { echo "the bind is still in the kernel's table"; fail=1; }
[ -z "${out}" ] || { echo "umount_chroot printed [${out}]"; fail=1; }
exit "${fail}"
SCN
chmod +x "${SCN}"/*.sh
# The spelled build systems: real directories, so readlink -f has something to resolve.
SPD="${TDIR}/spell"; mkdir -p "${SPD}"
mk_build_dir() { mkdir -p "$1/snap-build-x86/sysroot/var/cache/distfiles-ro" "$1/snap-build-x86/sysroot/dev"; }
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

# 1j. stale-mount listing: the kernel's table is the fixture, one stacked bind three times.
MI="${STUB_STATE}/mountinfo"
KSM="$(readlink -f -- "${SM}")"
write_mountinfo "${MI}" "/" "/home" "${KSM}/var/cache/distfiles-ro" "${KSM}/var/cache/distfiles-ro" "${KSM}/var/cache/distfiles-ro" "${KSM}/dev" "${KSM}/dev/pts" "${KSM}-other/x"
listing="$(HMR_MOUNTINFO="${MI}" hmr_stale_mounts "${SM}")"
[ "$(printf '%s\n' "${listing}" | wc -l)" -eq 5 ] && ! printf '%s' "${listing}" | grep -a -F -- "-other" >/dev/null \
    && ok "stale mounts: 5 lines under the sysroot (a bind stacked 3x listed 3x), the sibling dir excluded" \
    || bad "stale mounts: got: ${listing}"
# 1k. the hint: explicit, quoted, deepest first, once per layer; executed against the stateful umount.
hint="$(hmr_stale_mount_hint "${listing}")"
want="umount '${KSM}/var/cache/distfiles-ro'
umount '${KSM}/var/cache/distfiles-ro'
umount '${KSM}/var/cache/distfiles-ro'
umount '${KSM}/dev/pts'
umount '${KSM}/dev'"
[ "${hint}" = "${want}" ] && ok "stale-mount hint: one quoted umount per listed layer, a submount (dev/pts) before its parent (dev)" \
    || bad "stale-mount hint: got [${hint}] wanted [${want}]"
: > "${STUB_STATE}/umount-args"
PATH="${TDIR}/bin-um:${PATH}" HMR_MOUNTINFO="${MI}" bash -c "${hint}"
left="$(HMR_MOUNTINFO="${MI}" hmr_stale_mounts "${SM}")"
if [ "$(wc -l < "${STUB_STATE}/umount-args")" -eq 5 ] && [ -z "${left}" ] && [ "$(wc -l < "${MI}")" -eq 3 ]; then
    ok "hint executed (the line pasted as printed): 5 umounts, nothing left under the sysroot, the three unrelated mounts untouched"
else
    bad "hint executed: calls=$(wc -l < "${STUB_STATE}/umount-args") left=[${left}]"
fi
# a path with a single quote, a double quote, a space and a dollar sign survives the quoting:
# the pasted command is ONE correctly quoted word and unmounts exactly that mount
QP="${KSM}/it's \"a\" \$x"
write_mountinfo "${MI}" "/" "${QP}"
q="$(hmr_stale_mount_hint "${QP}")"
if [ "${q}" = "umount '${KSM}/it'\\''s \"a\" \$x'" ] && PATH="${TDIR}/bin-um:${PATH}" HMR_MOUNTINFO="${MI}" bash -c "${q}" \
   && [ "$(wc -l < "${MI}")" -eq 1 ]; then
    ok "hint quoting: a path with a single quote, a double quote, a space and a dollar sign is one quoted word and unmounts"
else
    bad "hint quoting: [${q}]"
fi
# 1l. the refusal: the WHOLE listing (no eight-line cut), the plain statement that it is everything.
write_mountinfo "${MI}" "/" "${KSM}/proc" "${KSM}/sys" "${KSM}/sys/kernel" "${KSM}/sys/fs" "${KSM}/dev" "${KSM}/dev/pts" "${KSM}/dev/shm" "${KSM}/run" "${KSM}/run/lock" "${KSM}/var/tmp/portage" "${KSM}/var/db/repos/gentoo" "${KSM}/var/cache/binpkgs" "${KSM}/var/cache/distfiles-ro"
listing="$(HMR_MOUNTINFO="${MI}" hmr_stale_mounts "${KSM}")"
out="$(hmr_stale_mount_refuse "${KSM}" "${listing}" 2>&1)"
n_cmd="$(printf '%s\n' "${out}" | grep -a -c "^    umount '")"
if [ "${n_cmd}" -eq 13 ] && printf '%s' "${out}" | grep -a -F "mounts are still attached under ${KSM}: 13 in all" >/dev/null \
   && printf '%s' "${out}" | grep -a -F "ALL the mounts under that directory" >/dev/null \
   && printf '%s' "${out}" | grep -a -F "including any you mounted there on purpose" >/dev/null \
   && printf '%s' "${out}" | grep -a -F "var/cache/binpkgs" >/dev/null && printf '%s' "${out}" | grep -a -F "sys/kernel" >/dev/null \
   && ! printf '%s' "${out}" | grep -a -F "umount -R" >/dev/null && ! printf '%s' "${out}" | grep -a -F "while read" >/dev/null; then
    ok "refusal: all 13 mounts printed as umount commands (the old cut at 8 lines is gone), says they are ALL the mounts under the directory, no 'umount -R', no loop"
else
    bad "refusal text (${n_cmd} commands): ${out}"
fi
# spelled through a symlink, the refusal also says what the kernel calls it
out="$(hmr_stale_mount_refuse "${SPD}/link/snap-build-x86/sysroot" "x" 2>&1)"
printf '%s' "${out}" | grep -a -F "(the kernel lists it as $(readlink -f -- "${SPD}/link/snap-build-x86/sysroot"))" >/dev/null \
    && ok "refusal: a symlinked spelling is followed by the kernel's name for it" || bad "refusal (symlinked spelling): ${out}"
# 1m. the decoder against the kernel's escaping (a space followed by a digit is the trap printf %b falls into)
out="$(timeout "${WALL}" bash "${SCN}/unmangle.sh" "${LIB}" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "decoder: 16 mount points decode as the kernel's \\NNN escaping says, including 'build 5' written build\\0405 and a backslash followed by 040" \
    || bad "decoder: ${out}"
# 1n. hmr_canon
out="$(timeout "${WALL}" bash "${SCN}/canon.sh" "${LIB}" "${TDIR}/canon" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "hmr_canon: symlink component, trailing slash, relative path and / resolved the way the kernel names them" || bad "hmr_canon: ${out}"
# 1o. a table that cannot be read refuses; it never answers 'nothing mounted'
out="$(HMR_MOUNTINFO=/nonexistent/mountinfo hmr_stale_mounts "${SM}" 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "cannot read the kernel's mount table" >/dev/null && [ "$(printf '%s\n' "${out}" | wc -l)" -eq 1 ]; then
    ok "unreadable mount table: hmr_stale_mounts refuses (rc=1, one sentence) instead of printing nothing"
else
    bad "unreadable mount table: rc=${rc}: ${out}"
fi
out="$(HMR_MOUNTINFO=/nonexistent/mountinfo hmr_mount_layers "${SM}/dev" 2>/dev/null)"; rc=$?
[ "${rc}" -eq 0 ] && [ "${out}" = 0 ] && ok "unreadable mount table: hmr_mount_layers answers 0 (and the build's own umount does not depend on it)" || bad "hmr_mount_layers blind: rc=${rc} out=${out}"
out="$(hmr_stale_mounts "$(printf 'a\nb')" 2>&1)"; rc=$?
[ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "contains a newline" >/dev/null && ok "a build system path with a newline in it is refused outright" || bad "newline path: rc=${rc}: ${out}"
# 1p. the build system reached through every awkward spelling: listing, count, the builder's own
# umount_chroot and its Extract phase, all through the spelling the builder was given.
for entry in "${SPELLINGS[@]}"; do
    IFS='|' read -r label spelled cwd <<EOF
${entry}
EOF
    out="$(timeout "${WALL}" bash "${SCN}/spelling.sh" "${LIB}" "${X86}" "${spelled}" "${cwd}" 2>&1)"; rc=$?
    [ "${rc}" -eq 0 ] && ok "spelling '${label}': stale listing, layer count, umount_chroot and the Extract-phase refusal all work through the builder's spelling" \
        || bad "spelling '${label}' (rc=${rc}): ${out}"
done
# 1q. the build's own umount happens with a blind table
out="$(timeout "${WALL}" bash "${SCN}/blind.sh" "${LIB}" "${X86}" "${SPD}/link/snap-build-x86/sysroot" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "umount_chroot unmounts the bind even when the library cannot read the table (the umount never waits for a count)" || bad "blind umount: ${out}"
# 1r. the seed refusal lists every cached seed, separated, with no stray space
ONLY2="${TDIR}/seed-only2"; mkdir -p "${ONLY2}"
SEED_NEWER="${ONLY2}/stage3-amd64-hardened-openrc-20261004T170000Z.tar.xz"
make_seed "${SEED_NEWER}" glibc-2.43-r2 gcc-15.3.0 binutils-2.48
cp "${SEED_NEW}" "${ONLY2}/"
out="$(hmr_seed_for_resume "${BR}" "${SM}" "${SEED_NEWER}" "${L}" 2>&1 >/dev/null)"; rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "(the build system has sys-devel/binutils-2.46.1 sys-devel/gcc-15.3.0 sys-libs/glibc-2.43-r2; cached seeds: " >/dev/null \
   && printf '%s' "${out}" | grep -a -F "cached seeds: stage3-amd64-hardened-openrc-20261004T170000Z.tar.xz: sys-devel/binutils-2.48 sys-devel/gcc-15.3.0 sys-libs/glibc-2.43-r2; stage3-amd64-hardened-openrc-20260927T170058Z.tar.xz: sys-devel/binutils-2.47 sys-devel/gcc-15.3.0 sys-libs/glibc-2.43-r2), so the files restored" >/dev/null \
   && ! printf '%s' "${out}" | grep -a -F " ;" >/dev/null && ! printf '%s' "${out}" | grep -a -F "; )" >/dev/null; then
    ok "seed refusal with two cached seeds: 'seed A: toolchain; seed B: toolchain' (separator between them, no stray space or dangling ';')"
else
    bad "seed refusal separators: rc=${rc}: ${out}"
fi
# a seed cache under a directory with a space and glob characters in its name: the
# refusal names each seed and its toolchain (word-splitting the tried list printed
# "my: no toolchain record; builds: no toolchain record" for a cache under "my builds [1]/")
SPACED="${TDIR}/my builds [1]"; mkdir -p "${SPACED}"; cp "${SEED_NEW}" "${SPACED}/"
out="$(hmr_seed_for_resume "${BR}" "${SM}" "${SPACED}/$(basename "${SEED_NEW}")" "${L}" 2>&1 >/dev/null)"; rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "cached seeds: stage3-amd64-hardened-openrc-20260927T170058Z.tar.xz: sys-devel/binutils-2.47 sys-devel/gcc-15.3.0 sys-libs/glibc-2.43-r2)" >/dev/null \
   && ! printf '%s' "${out}" | grep -a -F "no toolchain record" >/dev/null; then
    ok "seed refusal (seed cache under 'my builds [1]/'): the seed is named with its toolchain, no 'my: no toolchain record'"
else
    bad "seed cache with a space in its path: rc=${rc}: ${out}"
fi
# 1r2. the chosen seed is VERIFIED before anything is extracted from it, unless it is
# the current seed this run already verified; the DIGESTS URL is the seed's own, on
# the autobuilds tree the current seed came from.
d="$(hmr_seed_digests_url "${STAGE3_URL_FIX}" "${SEED_OLD}")"; rc=$?
[ "${rc}" -eq 0 ] && [ "${d}" = "${DIGESTS_OLD}" ] && ok "seed verify: the DIGESTS URL is <autobuilds>/<the seed's timestamp>/<its name>.DIGESTS" \
    || bad "seed verify URL: rc=${rc} got '${d}' wanted '${DIGESTS_OLD}'"
d="$(hmr_seed_digests_url "${STAGE3_URL_FIX}" "${TDIR}/stage3-amd64-hardened-openrc-custom.tar.xz")"; rc=$?
[ "${rc}" -eq 1 ] && [ -z "${d}" ] && ok "seed verify: a seed name without a release timestamp has no DIGESTS URL (rc=1, nothing printed)" \
    || bad "seed verify URL (no timestamp): rc=${rc} got '${d}'"
: > "${VERIFY_LOG}"
out="$(hmr_seed_verify "${SEED_OLD}" "${SEED_OLD}" "${STAGE3_URL_FIX}" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && [ -z "${out}" ] && [ ! -s "${VERIFY_LOG}" ] && ok "seed verify: the current seed is not re-verified (sa_seed_acquire did, this run): no call, silent" \
    || bad "seed verify (current seed): rc=${rc} calls=$(cat "${VERIFY_LOG}") ${out}"
: > "${VERIFY_LOG}"
out="$(hmr_seed_verify "${SEED_OLD}" "${SEED_NEW}" "${STAGE3_URL_FIX}" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && [ "$(cat "${VERIFY_LOG}")" = "${SEED_OLD} ${DIGESTS_OLD}" ] && ok "seed verify: another cached seed is handed to the verifier ONCE with its own DIGESTS URL" \
    || bad "seed verify (other seed): rc=${rc} calls=[$(cat "${VERIFY_LOG}")] ${out}"
: > "${VERIFY_LOG}"
out="$(STUB_VERIFY_FAIL=1 hmr_seed_verify "${SEED_OLD}" "${SEED_NEW}" "${STAGE3_URL_FIX}" 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && [ "$(printf '%s\n' "${out}" | grep -a -c "Refusing to restore")" -eq 1 ] \
   && printf '%s' "${out}" | grep -a -F "did not verify against its signed DIGESTS" >/dev/null \
   && printf '%s' "${out}" | grep -a -F "no other cached seed is tried in its place" >/dev/null \
   && printf '%s' "${out}" | grep -a -F "rebuild WITHOUT --resume" >/dev/null; then
    ok "seed verify fail: a cached seed that does not verify -> rc=1, ONE refusal sentence naming the seed, saying no other cached seed is tried, 'rebuild WITHOUT --resume'"
else
    bad "seed verify fail: rc=${rc}: ${out}"
fi
out="$(hmr_seed_verify "${TDIR}/stage3-amd64-hardened-openrc-custom.tar.xz" "${SEED_NEW}" "${STAGE3_URL_FIX}" 2>&1)"; rc=$?
[ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "carries no release timestamp" >/dev/null && ok "seed verify: a cached seed whose name has no timestamp is refused rather than extracted unverified" \
    || bad "seed verify (no timestamp): rc=${rc}: ${out}"
# 1r3. a build system path that resolves to / is refused outright: nothing listed, no
# umount command printed (the host's whole mount table would be 'stale' otherwise).
ROOTLINK="${TDIR}/rootlink"; ln -s / "${ROOTLINK}"
out="$(HMR_MOUNTINFO="${MI}" hmr_stale_mounts "${ROOTLINK}" 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && [ "$(printf '%s\n' "${out}" | wc -l)" -eq 1 ] && printf '%s' "${out}" | grep -a -F "resolves to /, the host's own root" >/dev/null; then
    ok "a build system path that resolves to / is refused in one sentence; no mount is listed"
else
    bad "sysroot resolving to /: rc=${rc}: ${out}"
fi
# 1s. the seed marker: never written through a symlink, never read as anything but a bare name
BRS="${TDIR}/br-symlink"; mkdir -p "${BRS}"; echo "untouched" > "${TDIR}/marker-victim"; ln -s "${TDIR}/marker-victim" "${BRS}/sysroot.seed"
out="$(hmr_seed_marker_write "${BRS}" "${SEED_OLD}" 2>&1)"; rc=$?
[ "${rc}" -eq 1 ] && [ "$(cat "${TDIR}/marker-victim")" = untouched ] && printf '%s' "${out}" | grep -a -F "is a symlink" >/dev/null \
    && ok "seed marker: a symlink planted at sysroot.seed is not written through (the victim file is untouched)" \
    || bad "seed marker via symlink: rc=${rc} victim=$(cat "${TDIR}/marker-victim") ${out}"
# a FIFO planted at sysroot.seed: refused at once. A plain `>` would block the root
# build for ever with no message (run under timeout so a regression ends as rc=124).
BRF="${TDIR}/br-fifo"; mkdir -p "${BRF}"; mkfifo "${BRF}/sysroot.seed"
out="$(timeout 5 bash -c ". '${LIB}'; hmr_seed_marker_write '${BRF}' '${SEED_OLD}'" 2>&1)"; rc=$?
[ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "is not a regular file" >/dev/null \
    && ok "seed marker: a FIFO planted at sysroot.seed is refused at once (rc=1) instead of blocking the write" \
    || bad "seed marker via FIFO: rc=${rc} (124 = the write blocked until timeout) ${out}"
BRB="${TDIR}/br-badmarker"; mkdir -p "${BRB}"
okm=1
for v in '../../evil.tar.xz' '/etc/passwd' '..' '.' ''; do
    printf '%s\n' "$v" > "${BRB}/sysroot.seed"
    [ -z "$(hmr_seed_marker_read "${BRB}")" ] || { okm=0; echo "    marker [$v] was accepted"; }
done
printf '%s\n' "stage3-amd64-hardened-openrc-20260920T170055Z.tar.xz" > "${BRB}/sysroot.seed"
[ "$(hmr_seed_marker_read "${BRB}")" = "stage3-amd64-hardened-openrc-20260920T170055Z.tar.xz" ] || okm=0
[ "${okm}" -eq 1 ] && ok "seed marker: a value with a slash, '.', '..' or nothing is ignored; a bare seed name is read back" || bad "seed marker read validation"

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
run_extract_phase() {   # <builder> <resume true|false> <sysroot> <build root> <seed> [extra PATH] [mount table fixture]
    local b="$1" resume="$2" sysroot="$3" build_root="$4" seed="$5" epath="${6:-}" mtab="${7:-}"
    local sec="${TDIR}/sec-extract.sh"
    extract_section "$b" '^banner "Extracting stage3 into sysroot"$' 'hmr_seed_marker_write' '^fi$' "${sec}" || return 99
    HMR_MOUNTINFO="${mtab}" PATH="${epath:+${epath}:}${PATH}" timeout "${WALL}" bash -c "
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
# stale mounts (the kernel's table is a fixture: two layers of distfiles-ro) refuse on
# BOTH branches, listing each layer as the umount command that removes it.
KSX="$(readlink -f -- "${SX}")"
MI_STALE="${STUB_STATE}/mi-stale"; write_mountinfo "${MI_STALE}" "/" "${KSX}/var/cache/distfiles-ro" "${KSX}/var/cache/distfiles-ro"
MI_CLEAR="${STUB_STATE}/mi-clear"; write_mountinfo "${MI_CLEAR}" "/" "/home"
for r in true false; do
    out="$(run_extract_phase "${X86}" "$r" "${SX}" "${B1}" "${SEED_OLD}" "" "${MI_STALE}" 2>&1)"; rc=$?
    if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "mounts are still attached under ${SX}" >/dev/null \
       && [ "$(printf '%s\n' "${out}" | grep -a -c "^    umount '${KSX}/var/cache/distfiles-ro'")" -eq 2 ] \
       && ! printf '%s' "${out}" | grep -a -F "EXTRACT-PHASE-COMPLETED" >/dev/null && [ -f "${SX}/etc/gentoo-release" ]; then
        ok "extract phase (RESUME=$r, stale binds): refused, one umount command per stacked layer, before any wipe or skip"
    else
        bad "extract phase (RESUME=$r, stale binds): rc=${rc}: ${out}"
    fi
done
# a table that cannot be read stops the phase on BOTH branches (the old code read it as 'nothing mounted')
for r in true false; do
    touch "${SX}/leftover-from-the-previous-attempt"
    out="$(run_extract_phase "${X86}" "$r" "${SX}" "${B1}" "${SEED_OLD}" "" "/nonexistent/mountinfo" 2>&1)"; rc=$?
    if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -a -F "cannot read the kernel's mount table" >/dev/null \
       && ! printf '%s' "${out}" | grep -a -F "EXTRACT-PHASE-COMPLETED" >/dev/null && ! printf '%s' "${out}" | grep -a -F "skipping extraction" >/dev/null \
       && [ -e "${SX}/leftover-from-the-previous-attempt" ]; then
        ok "extract phase (RESUME=$r, unreadable mount table): stops with the sentence, nothing wiped or skipped"
    else
        bad "extract phase (RESUME=$r, unreadable mount table): rc=${rc}: ${out}"
    fi
done
rm -f "${SX}/leftover-from-the-previous-attempt"
# a sysroot that resolves to / (a symlink planted where the build system should be):
# refused before anything, with no umount command printed (the host's whole mount
# table is not "stale mounts under the build system")
out="$(run_extract_phase "${X86}" true "${ROOTLINK}" "${B1}" "${SEED_OLD}" "" "${MI_CLEAR}" 2>&1)"; rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -a -F "resolves to /, the host's own root" >/dev/null \
   && [ "$(printf '%s\n' "${out}" | grep -a -c "^    umount '")" -eq 0 ] \
   && ! printf '%s' "${out}" | grep -a -F "EXTRACT-PHASE-COMPLETED" >/dev/null && ! printf '%s' "${out}" | grep -a -F "skipping extraction" >/dev/null; then
    ok "extract phase (sysroot is a symlink to /): stops with the sentence, prints no umount command, never reaches 'skipping extraction'"
else
    bad "extract phase (sysroot -> /): rc=${rc}: ${out}"
fi
# 2b. section 4b: the restore runs for a non-GPU role when the statics are missing.
run_4b() {   # <builder> <sysroot> <build root> <current seed> <GPU true|false>
    local b="$1" sysroot="$2" build_root="$3" seed="$4" gpu="$5"
    local sec="${TDIR}/sec-4b.sh"
    extract_section "$b" '^# ── 4b\. Toolchain static restore' 'hmr_statics_restore' '^fi$' "${sec}" || return 99
    : > "${VERIFY_LOG}"
    timeout "${WALL}" bash -c "
        set -euo pipefail
        . '${LIB}'
        banner(){ echo \"==> \$1\"; }; info(){ echo \"    \$1\"; }; warn(){ echo \"    WARNING: \$1\"; }; err(){ echo \"    ERROR: \$1\" >&2; }
        GPU=${gpu}; SYSROOT='${sysroot}'; BUILD_ROOT='${build_root}'; STAGE3_LOCAL='${seed}'; STAGE3_URL='${STAGE3_URL_FIX}'
        . '${sec}'
        echo 4B-COMPLETED
    "
}
B2="${TDIR}/b-4b"; mkdir -p "${B2}"; S4="${B2}/sysroot"; make_sysroot "${S4}"
out="$(run_4b "${X86}" "${S4}" "${B2}" "${SEED_NEW}" false 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && [ -f "${S4}/usr/lib64/libc_nonshared.a" ] && [ -f "${S4}/usr/lib/gcc/x86_64-pc-linux-gnu/15/libgcc.a" ] \
   && [ "$(cat "${B2}/sysroot.seed" 2>/dev/null)" = "$(basename "${SEED_OLD}")" ] && printf '%s' "${out}" | grep -a -F "Restored" >/dev/null \
   && [ "$(cat "${VERIFY_LOG}")" = "${SEED_OLD} ${DIGESTS_OLD}" ]; then
    ok "4b (GPU=false, statics stripped, newest seed mismatches): the MATCHING cached seed is verified once against its own DIGESTS, restored from, and recorded in the marker"
else
    bad "4b (GPU=false): rc=${rc}: verify calls=[$(cat "${VERIFY_LOG}")] ${out}"
fi
out="$(run_4b "${X86}" "${S4}" "${B2}" "${SEED_NEW}" false 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ! printf '%s' "${out}" | grep -a -F "Restoring" >/dev/null && [ ! -s "${VERIFY_LOG}" ] && ok "4b: a no-op when the statics are present (no verifier call either)" || bad "4b no-op: rc=${rc}: ${out}"
B3="${TDIR}/b-4b-refuse"; mkdir -p "${B3}"; S5="${B3}/sysroot"; make_sysroot "${S5}"
out="$(run_4b "${X86}" "${S5}" "${B3}" "${ONLYNEW}/$(basename "${SEED_NEW}")" true 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "Refusing to restore" >/dev/null && ! printf '%s' "${out}" | grep -a -F "4B-COMPLETED" >/dev/null \
   && [ ! -f "${S5}/usr/lib64/libc_nonshared.a" ]; then
    ok "4b (only a mismatching seed cached, even for GPU=true): refused, nothing restored, build stops"
else
    bad "4b refusal: rc=${rc}: ${out}"
fi
# the chosen seed fails verification -> refused before anything is extracted, no marker
B7="${TDIR}/b-4b-badseed"; mkdir -p "${B7}"; S7="${B7}/sysroot"; make_sysroot "${S7}"
out="$(STUB_VERIFY_FAIL=1 run_4b "${X86}" "${S7}" "${B7}" "${SEED_NEW}" false 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a -F "did not verify against its signed DIGESTS" >/dev/null && ! printf '%s' "${out}" | grep -a -F "4B-COMPLETED" >/dev/null \
   && [ ! -f "${S7}/usr/lib64/libc_nonshared.a" ] && [ ! -f "${S7}/usr/lib/gcc/x86_64-pc-linux-gnu/15/libgcc.a" ] && [ ! -e "${B7}/sysroot.seed" ] \
   && [ "$(cat "${VERIFY_LOG}")" = "${SEED_OLD} ${DIGESTS_OLD}" ]; then
    ok "4b (the matching cached seed does not verify): refused in one sentence, NOTHING extracted, no marker written, build stops"
else
    bad "4b verify fail: rc=${rc}: libc=$([ -f "${S7}/usr/lib64/libc_nonshared.a" ] && echo present || echo absent) marker=$(cat "${B7}/sysroot.seed" 2>/dev/null) ${out}"
fi
# the CURRENT seed matches -> restored from it with NO second verification (sa_seed_acquire verified it this run)
B6="${TDIR}/b-4b-current"; mkdir -p "${B6}"; S6="${B6}/sysroot"; make_sysroot "${S6}"
out="$(run_4b "${X86}" "${S6}" "${B6}" "${SEED_OLD}" false 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && [ -f "${S6}/usr/lib64/libc_nonshared.a" ] && [ ! -s "${VERIFY_LOG}" ] && [ "$(cat "${B6}/sysroot.seed" 2>/dev/null)" = "$(basename "${SEED_OLD}")" ]; then
    ok "4b (the current seed matches): restored from it, the verifier NOT called again, marker recorded"
else
    bad "4b current seed: rc=${rc}: verify calls=[$(cat "${VERIFY_LOG}")] ${out}"
fi
# a marker naming a seed that has LEFT the cache: the version match restores from the
# right seed and the marker is corrected to it (it used to stay stale for ever)
B8="${TDIR}/b-4b-stalemarker"; mkdir -p "${B8}"; S8="${B8}/sysroot"; make_sysroot "${S8}"
printf '%s\n' "stage3-amd64-hardened-openrc-20260101T000000Z.tar.xz" > "${B8}/sysroot.seed"
out="$(run_4b "${X86}" "${S8}" "${B8}" "${SEED_NEW}" false 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && [ -f "${S8}/usr/lib64/libc_nonshared.a" ] && [ "$(cat "${B8}/sysroot.seed" 2>/dev/null)" = "$(basename "${SEED_OLD}")" ]; then
    ok "4b (marker names a seed no longer cached): restored from the matching seed and the marker is CORRECTED to it"
else
    bad "4b stale marker: rc=${rc}: marker=$(cat "${B8}/sysroot.seed" 2>/dev/null) ${out}"
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
# 2d. umount_chroot: the distfiles-ro bind is in the list, each flag resets, the detach is
# verified — and the sysroot is spelled TWO ways (directly, and through a symlink: the
# kernel's table names the real path either way, so a count made by comparing spellings
# sees nothing on the second).
MI2="${STUB_STATE}/mi-um"
run_umount_chroot() {   # <builder> <sysroot as the builder spells it> <distfiles true|false> [library]
    local b="$1" sysroot="$2" dist="$3" lib="${4:-${LIB}}"
    local sec="${TDIR}/sec-umount.sh"
    # awk -v processes backslash escapes once: double them so the regex keeps them.
    extract_section "$b" '^umount_chroot\\(\\) \\{$' 'umount_chroot' '^\\}$' "${sec}" || return 99
    : > "${STUB_STATE}/umount-args"
    PATH="${TDIR}/bin-um:${PATH}" HMR_MOUNTINFO="${MI2}" STUB_TABLE="${MI2}" timeout "${WALL}" bash -c "
        set -euo pipefail
        . '${lib}'
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
# The stateful umount (defined with the fixtures above) peels ONE table line per call,
# as the kernel does for a stacked bind, unless the leg says the detach silently fails
# (still-mounted).
ln -s "$(basename "${B2}")" "${TDIR}/lnk"      # ${TDIR}/lnk/sysroot is ${S4}, through a symlink
set_mounts() {   # <sysroot as spelled>: the KERNEL's spelling of our four flagged binds (distfiles-ro stacked on one foreign layer) + run/dev/sys/proc
    local k; k="$(readlink -f -- "$1")"
    # the directories mount_chroot makes before it binds (a umount of a path that is not there fails, as the real one does)
    mkdir -p "${k}/var/cache/distfiles-ro" "${k}/var/tmp/portage" "${k}/var/db/repos/gentoo" "${k}/var/cache/binpkgs" "${k}/run" "${k}/dev" "${k}/sys" "${k}/proc"
    write_mountinfo "${MI2}" "${k}/var/cache/distfiles-ro" "${k}/var/cache/distfiles-ro" "${k}/var/tmp/portage" "${k}/var/db/repos/gentoo" "${k}/var/cache/binpkgs" \
                    "${k}/run" "${k}/dev" "${k}/sys" "${k}/proc"
}
for sp in "${S4}" "${TDIR}/lnk/sysroot"; do
    set_mounts "${sp}"
    out="$(run_umount_chroot "${X86}" "${sp}" true 2>&1)"; rc=$?
    n_dist="$(grep -a -c "distfiles-ro" "${STUB_STATE}/umount-args")"
    n_all="$(wc -l < "${STUB_STATE}/umount-args")"
    left_dist="$(grep -a -c "distfiles-ro" "${MI2}")"
    if [ "${rc}" -eq 0 ] && [ "${n_dist}" -eq 1 ] && [ "${n_all}" -eq 12 ] && [ "${left_dist}" -eq 1 ] && [ "$(wc -l < "${MI2}")" -eq 1 ] \
       && printf '%s' "${out}" | grep -a -F "flags-after: false false false false" >/dev/null \
       && ! printf '%s' "${out}" | grep -a -F "STILL mounted" >/dev/null; then
        ok "umount_chroot (sysroot spelled ${sp#"${TDIR}"/}): peels ONE distfiles-ro layer (the foreign one beneath stays), scratch, repo, pool + run/dev/sys/proc; flags reset so a second call unmounts only run/dev/sys/proc (12 umounts total); no warning"
    else
        bad "umount_chroot (${sp}): rc=${rc} distfiles=${n_dist} total=${n_all} left=${left_dist} table=$(wc -l < "${MI2}"): ${out} :: $(cat "${STUB_STATE}/umount-args")"
    fi
done
set_mounts "${S4}"
out="$(run_umount_chroot "${X86}" "${S4}" false 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && [ "$(grep -a -c "distfiles-ro" "${STUB_STATE}/umount-args")" -eq 0 ] && [ "$(grep -a -c "distfiles-ro" "${MI2}")" -eq 2 ] \
    && ok "umount_chroot: does NOT unmount distfiles-ro it did not mount (DISTFILES_MOUNTED=false); both foreign layers stay" \
    || bad "umount_chroot (not ours): rc=${rc} $(cat "${STUB_STATE}/umount-args")"
for sp in "${S4}" "${TDIR}/lnk/sysroot"; do
    set_mounts "${sp}"; touch "${STUB_STATE}/still-mounted"
    out="$(run_umount_chroot "${X86}" "${sp}" true 2>&1)"; rc=$?
    [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -a -F "distfiles-ro is STILL mounted (2 layer(s)) after this build's own umount" >/dev/null \
        && printf '%s' "${out}" | grep -a -F "UMOUNT-COMPLETED" >/dev/null \
        && ok "umount_chroot (sysroot spelled ${sp#"${TDIR}"/}): a detach that did not happen (layer count unchanged) is said out loud, build continues" \
        || bad "umount_chroot verify (${sp}): rc=${rc}: ${out}"
    rm -f "${STUB_STATE}/still-mounted"
done
# the binpkgs guard after umount_chroot (x86 section 8): the builder text, extracted, with `mountpoint`
# stubbed to say the pool is still mounted: it stops, and prints EVERY mount under the sysroot as a
# umount command (the table fixture), or just the pool's command when the table cannot be read.
run_binpkgs_guard() {   # <builder> <sysroot> <mount table fixture> [library]
    local b="$1" sysroot="$2" mtab="$3" lib="${4:-${LIB}}"
    local sec="${TDIR}/sec-binpkgs.sh"
    extract_section "$b" '^if mountpoint -q "\\$\\{SYSROOT\\}/var/cache/binpkgs"' 'hmr_stale_mount_hint' '^fi$' "${sec}" || return 99
    mkdir -p "${TDIR}/bin-mp"; printf '#!/usr/bin/env bash\nexit 0\n' > "${TDIR}/bin-mp/mountpoint"; chmod +x "${TDIR}/bin-mp/mountpoint"
    PATH="${TDIR}/bin-mp:${PATH}" HMR_MOUNTINFO="${mtab}" timeout "${WALL}" bash -c "
        set -euo pipefail
        . '${lib}'
        err(){ echo \"    ERROR: \$1\" >&2; }
        SYSROOT='${sysroot}'; X86_POOL_DIR=/srv/pool
        . '${sec}'
        echo BINPKGS-GUARD-PASSED
    "
}
KS4="$(readlink -f -- "${S4}")"
write_mountinfo "${MI2}" "/" "${KS4}/dev" "${KS4}/dev/pts" "${KS4}/var/cache/binpkgs"
out="$(run_binpkgs_guard "${X86}" "${TDIR}/lnk/sysroot" "${MI2}" 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && ! printf '%s' "${out}" | grep -a -F "BINPKGS-GUARD-PASSED" >/dev/null \
   && [ "$(printf '%s\n' "${out}" | grep -a -c "^    umount '")" -eq 3 ] \
   && printf '%s' "${out}" | grep -a -F "    umount '${KS4}/var/cache/binpkgs'" >/dev/null \
   && printf '%s' "${out}" | grep -a -F "    umount '${KS4}/dev/pts'" >/dev/null; then
    ok "binpkgs guard (x86 section 8): the pool is still a mount point -> stops, and prints all 3 mounts under the sysroot as quoted umount commands (the sysroot spelled through a symlink)"
else
    bad "binpkgs guard: rc=${rc}: ${out}"
fi
out="$(run_binpkgs_guard "${X86}" "${S4}" "/nonexistent/mountinfo" 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && [ "$(printf '%s\n' "${out}" | grep -a -c "^    umount '")" -eq 1 ] && printf '%s' "${out}" | grep -a -F "    umount '${KS4}/var/cache/binpkgs'" >/dev/null; then
    ok "binpkgs guard: with the table unreadable it still stops and names the pool's own umount command"
else
    bad "binpkgs guard (blind): rc=${rc}: ${out}"
fi

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
    # 4b: the chosen seed is verified AFTER it is chosen and BEFORE anything is
    # extracted from it, and the marker is corrected whenever it disagrees
    local n_sel n_ver n_res
    n_sel="$(grep -a -n -F 'hmr_seed_for_resume "${BUILD_ROOT}" "${SYSROOT}" "${STAGE3_LOCAL}" "${_hmr_listing}"' "$b" | head -1 | cut -d: -f1)"
    n_ver="$(grep -a -n -F 'hmr_seed_verify "${_hmr_seed}" "${STAGE3_LOCAL}" "${STAGE3_URL}" || { rm -f "${_hmr_listing}"; exit 1; }' "$b" | head -1 | cut -d: -f1)"
    n_res="$(grep -a -n -F 'hmr_statics_restore "${SYSROOT}" "${_hmr_seed}" "${_hmr_listing}"' "$b" | head -1 | cut -d: -f1)"
    [ -n "${n_sel}" ] && [ -n "${n_ver}" ] && [ -n "${n_res}" ] && [ "${n_sel}" -lt "${n_ver}" ] && [ "${n_ver}" -lt "${n_res}" ] || rc=1
    has "$b" '[ "$(hmr_seed_marker_read "${BUILD_ROOT}")" = "$(basename "${_hmr_seed}")" ] || hmr_seed_marker_write "${BUILD_ROOT}" "${_hmr_seed}" || true' || rc=1
    # the successful-build unmount: the explicit call before the Clean phase, at
    # column 0 (the live-ISO dracut step has an indented second one of its own)
    hasr "$b" '^umount_chroot; trap - EXIT$' || rc=1
    grep -a -F "umount -R '\${SYSROOT}'" "$b" >/dev/null 2>&1 && rc=1
    # hmr_stale_mount_hint takes the LISTING, not a path: handed the sysroot it prints
    # `umount '<sysroot>'`, a command for a directory that is not a mount point
    has "$b" 'hmr_stale_mount_hint "${_still_mounted}" "    " >&2' || rc=1
    grep -a -F 'hmr_stale_mount_hint "${SYSROOT}"' "$b" >/dev/null 2>&1 && rc=1
    return "${rc}"
}
pin_x86 "${X86}" && ok "x86 pins: lib sourced; owner gate before 'skipping extraction'; 4b ungated (no '\${GPU} &&'); the chosen seed verified between choice and restore; marker corrected when it disagrees; link check between mount_chroot and the first emerge; distfiles-ro in umount_chroot; the end-of-build umount_chroot call; stale refusal + marker present; the binpkgs guard hands the hint a listing; no 'umount -R' hint left" \
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
# The same Extract-phase stale refusal, executed on each builder's own text (the kernel's
# table is the fixture named by the third argument).
run_arm_extract() {   # <builder> <sysroot> <mount table fixture>
    local sec="${TDIR}/sec-arm.sh"
    extract_section "$1" '^banner "Extracting stage3 into sysroot"$' 'hmr_stale_mount_refuse' '^fi$' "${sec}" || return 99
    HMR_MOUNTINFO="$3" timeout "${WALL}" bash -c "
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
    HMR_MOUNTINFO="${MI_CLEAR}" PATH="${TDIR}/bin-id:${PATH}" STUB_ID_UID="$3" timeout "${WALL}" bash -c "
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
    out="$(run_arm_extract "$b" "${SX}" "${MI_STALE}" 2>&1)"; rc=$?
    if [ "${rc}" -ne 1 ] || ! printf '%s' "${out}" | grep -a -F "mounts are still attached under ${SX}" >/dev/null \
       || [ "$(printf '%s\n' "${out}" | grep -a -c "^    umount '${KSX}/var/cache/distfiles-ro'")" -ne 2 ]; then
        bad "${bn} extract guard (stale binds): rc=${rc}: ${out}"; continue
    fi
    out="$(run_arm_extract "$b" "${SX}" "${MI_CLEAR}" 2>&1)"; rc=$?
    if [ "${rc}" -ne 0 ] || ! printf '%s' "${out}" | grep -a -F "ARM-EXTRACT-GUARD-PASSED" >/dev/null; then
        bad "${bn} extract guard (no mounts): rc=${rc}: ${out}"; continue
    fi
    out="$(run_arm_extract "$b" "${SX}" "/nonexistent/mountinfo" 2>&1)"; rc=$?
    if [ "${rc}" -eq 0 ] || ! printf '%s' "${out}" | grep -a -F "cannot read the kernel's mount table" >/dev/null \
       || printf '%s' "${out}" | grep -a -F "ARM-EXTRACT-GUARD-PASSED" >/dev/null; then
        bad "${bn} extract guard (unreadable mount table): expected it to stop, rc=${rc}: ${out}"; continue
    fi
    if [ "${bn}" = build-rpi5-stage4.sh ]; then
        out="$(run_arm_resume "$b" "${SX}" 0 2>&1)"; rc=$?
        if [ "${rc}" -ne 0 ] || ! printf '%s' "${out}" | grep -a -F "skipping extraction" >/dev/null; then
            bad "${bn} resume (root, user-owned tree): expected to proceed (its owners are forced to 0 at packaging), got rc=${rc}: ${out}"; continue
        fi
        ok "${bn}: binds host /proc under its sysroot; lib sourced; stale refusal pinned + EXECUTED (stale binds -> refused, one umount command per layer; clean table -> passes; unreadable table -> stops); a root resume on a user-owned tree proceeds — no gate, every owner in its stage4 tarball is forced to 0 and the .img is filled from it (pinned)"
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
    ok "${bn}: binds host /proc under its sysroot; lib sourced; stale refusal pinned + EXECUTED (stale binds -> refused, one umount command per layer; clean table -> passes; unreadable table -> stops); root-only owner gate EXECUTED (root + user-owned tree -> refused, remedy says remove the tree; non-root -> proceeds)"
done
[ "${n_arm}" -eq 9 ] && ok "nine non-x86 builders measured (rpi5 + frite + jetson + six orangepi)" || bad "expected 9 non-x86 builders, found ${n_arm}: a builder was added or removed — re-measure its resume path"

echo "== 4. mutation battery: each guard removed from a COPY must turn its leg RED =="
if [ -n "${HMR_TEST_INNER:-}" ]; then
    echo "  (inner run against a mutated copy of the library: the battery is not repeated)"
else
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
    out="$(run_extract_phase "$m" true "${SX}" "${B1}" "${SEED_OLD}" "" "${MI_STALE}" 2>&1)"; rc=$?
    ! printf '%s' "${out}" | grep -a -F "mounts are still attached" >/dev/null \
        && ok "M5 stale refusal gated on non-resume only: a resume over stacked binds is NOT refused (leg RED)" \
        || bad "M5: gating the stale refusal was not caught"
fi
# M6: the old hint restored in the binpkgs guard -> the pin catches 'umount -R', and
# handing the hint the SYSROOT instead of a listing is caught by the pin and by the leg.
if m="$(mutate old-hint "s/err \"bottom; every mount under the build system is listed), then re-run:\"/err \"Unmount first: umount -R '\${SYSROOT}' then re-run\"/")"; then
    ! pin_x86 "$m" && ok "M6 old 'umount -R <sysroot>' hint restored: pin RED" || bad "M6: old hint not caught"
fi
if m="$(mutate hint-gets-sysroot 's/hmr_stale_mount_hint "\${_still_mounted}" "    " >&2/hmr_stale_mount_hint "${SYSROOT}" >\&2/')"; then
    write_mountinfo "${MI2}" "/" "${KS4}/dev" "${KS4}/dev/pts" "${KS4}/var/cache/binpkgs"
    out="$(run_binpkgs_guard "$m" "${S4}" "${MI2}" 2>&1)"; rc=$?
    ! pin_x86 "$m" && [ "$(printf '%s\n' "${out}" | grep -a -c "^    umount '")" -ne 3 ] \
        && ok "M6b the binpkgs guard hands the hint a path instead of the listing: pin RED and the leg RED (it prints a command for the sysroot directory)" \
        || bad "M6b: handing the hint the sysroot was not caught"
fi
# M7: the seed marker write deleted -> a fresh extract leaves no marker.
if m="$(mutate no-marker '/hmr_seed_marker_write "\${BUILD_ROOT}" "\${STAGE3_LOCAL}" || true/d')"; then
    rm -f "${B1}/sysroot.seed"; make_sysroot "${SX}"
    out="$(run_extract_phase "$m" false "${SX}" "${B1}" "${SEED_OLD}" 2>&1)"; rc=$?
    [ ! -f "${B1}/sysroot.seed" ] && ! pin_x86 "$m" && ok "M7 marker write removed: no marker after a fresh extract (leg RED) and the pin is RED" || bad "M7: marker removal not caught"
fi
# M30: the verification of the chosen seed deleted -> a seed that does not verify is
# extracted from anyway (leg RED) and the pin is RED.
if m="$(mutate no-seed-verify '/hmr_seed_verify "\${_hmr_seed}" "\${STAGE3_LOCAL}" "\${STAGE3_URL}" || { rm -f "\${_hmr_listing}"; exit 1; }/d')"; then
    rm -rf "${B7}"; mkdir -p "${B7}"; make_sysroot "${S7}"
    out="$(STUB_VERIFY_FAIL=1 run_4b "$m" "${S7}" "${B7}" "${SEED_NEW}" false 2>&1)"; rc=$?
    [ -f "${S7}/usr/lib64/libc_nonshared.a" ] && ! pin_x86 "$m" \
        && ok "M30 seed verification removed: an unverified cached seed is extracted from (leg RED) and the pin is RED" \
        || bad "M30: removing the seed verification was not caught (rc=${rc})"
fi
# M31: the explicit end-of-build umount_chroot call dropped (the EXIT trap alone) -> the pin is RED.
if m="$(mutate no-final-umount 's/^umount_chroot; trap - EXIT$/trap - EXIT/')"; then
    ! pin_x86 "$m" && ok "M31 end-of-build 'umount_chroot; trap - EXIT' removed: pin RED" || bad "M31: dropping the end-of-build umount_chroot was not caught"
fi
# M32: the marker write gated on 'no marker yet' again -> a stale marker is never corrected (leg RED) and the pin is RED.
if m="$(mutate stale-marker-kept 's/^    \[ "\$(hmr_seed_marker_read "\${BUILD_ROOT}")" = "\$(basename "\${_hmr_seed}")" \] || hmr_seed_marker_write/    [ -n "$(hmr_seed_marker_read "${BUILD_ROOT}")" ] || hmr_seed_marker_write/')"; then
    rm -rf "${B8}"; mkdir -p "${B8}"; make_sysroot "${S8}"
    printf '%s\n' "stage3-amd64-hardened-openrc-20260101T000000Z.tar.xz" > "${B8}/sysroot.seed"
    out="$(run_4b "$m" "${S8}" "${B8}" "${SEED_NEW}" false 2>&1)"; rc=$?
    [ "$(cat "${B8}/sysroot.seed" 2>/dev/null)" = "stage3-amd64-hardened-openrc-20260101T000000Z.tar.xz" ] && ! pin_x86 "$m" \
        && ok "M32 marker write gated on absence again: a marker naming a gone seed stays stale (leg RED) and the pin is RED" \
        || bad "M32: the stale-marker regression was not caught (marker=$(cat "${B8}/sysroot.seed" 2>/dev/null))"
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
# Library mutations. The whole suite is run again against a MUTATED COPY of the
# library (HMR_TEST_LIB), with this battery switched off (HMR_TEST_INNER), and the run
# must go red ON THE LEG THAT COVERS THE MUTATED LINE — the FAIL line is matched by
# its text, so a mutation that breaks something unrelated does not count.
lib_mut() {   # <name> <what was broken> <sed script> <extended regex the FAIL line must match>
    local name="$1" what="$2" script="$3" want="$4"
    local m="${TDIR}/mutlib-${name}.sh" o="${TDIR}/mutlib-${name}.out" rc
    sed -e "${script}" "${LIB}" > "${m}"
    if cmp -s "${m}" "${LIB}"; then bad "${name}: the mutation did not change the library"; return; fi
    HMR_TEST_INNER=1 HMR_TEST_LIB="${m}" timeout 180 bash "${BASH_SOURCE[0]}" > "${o}" 2>&1; rc=$?
    if [ "${rc}" -ne 0 ] && grep -a -E "^  FAIL .*(${want})" "${o}" >/dev/null; then
        ok "${name} ${what}: the suite goes RED on the leg that covers it ($(grep -a -c '^  FAIL ' "${o}") failing leg(s))"
    else
        bad "${name} ${what}: NOT caught (rc=${rc}; wanted a FAIL line matching '${want}'; got: $(grep -a '^  FAIL ' "${o}" | head -3 | cut -c1-160 | tr '\n' '|'))"
    fi
}
lib_mut M10 "hmr_umount_own waits for the layer count again" \
    's#^    umount -l "\${path}" 2>/dev/null || true$#    [ "${before:-0}" -gt 0 ] || return 0\n    umount -l "${path}" 2>/dev/null || true#' \
    'blind umount'
lib_mut M11 "hmr_canon stops resolving symlinks" \
    's#^    c="\$(readlink -f -- "\${p}" 2>/dev/null || true)"$#    c=""#' \
    "hmr_canon|spelling 'symlink component'|spelling 'relative --work-dir'"
lib_mut M12 "the decoder is printf %b (reads \\0405 as one byte)" \
    's/^_hmr_unmangle() {$/_hmr_unmangle() { printf "%b" "${1-}"; return 0; }\n_hmr_unmangle_real() {/' \
    "decoder:|spelling 'space then a digit'"
lib_mut M13 "the decoder does nothing" \
    's/^_hmr_unmangle() {$/_hmr_unmangle() { printf "%s" "${1-}"; return 0; }\n_hmr_unmangle_real() {/' \
    "decoder:|spelling 'space'|spelling 'backslash'"
lib_mut M14 "an unreadable table is reported as success" \
    '/^hmr_mount_targets() {$/,/^}$/ s/^        return 1$/        return 0/' \
    'unreadable mount table'
lib_mut M15 "the table error is swallowed by hmr_stale_mounts" \
    's/^    targets="\$(hmr_mount_targets)" || return 1$/    targets="$(hmr_mount_targets || true)"/' \
    'unreadable mount table'
lib_mut M16 "the refusal is cut to eight lines again" \
    's/^    hmr_stale_mount_hint "\${listing}" "    " >&2$/    hmr_stale_mount_hint "${listing}" "    " 2>\&1 | head -n 8 >\&2/' \
    'refusal text'
lib_mut M17 "the hint stops quoting each path" \
    's/\$(_hmr_squote "\${m}")/${m}/' \
    'hint quoting|stale-mount hint'
lib_mut M18 "the hint stops sorting deepest first" \
    's/ | LC_ALL=C sort -r | while/ | while/' \
    'stale-mount hint'
lib_mut M19 "the stale check compares as a glob (an unquoted prefix)" \
    's/^            "\${prefix}"\*) printf/            ${prefix}*) printf/' \
    "spelling 'glob characters'"
lib_mut M20 "the marker is written through a symlink" \
    's/^    if \[ -L "\${marker}" \]; then$/    if false; then/' \
    'seed marker via symlink'
lib_mut M21 "a marker naming a path outside the cache is trusted" \
    's/) return 0 ;; esac$/) true ;; esac/' \
    'seed marker read validation'
lib_mut M22 "the cached seeds in the refusal lose their separator" \
    's/tc_line="\${tc_line}\${tc_line:+; }\$(basename/tc_line="${tc_line}$(basename/' \
    'seed refusal separators'
lib_mut M23 "the still-mounted warning never fires" \
    's/^    if \[ "\${after:-0}" -ge "\${before}" \]; then$/    if false; then/' \
    'umount_chroot verify'
lib_mut M24 "a newline in the build system path is accepted" \
    's/^            return 1 ;;$/            true ;;/' \
    'newline path'
lib_mut M25 "the layer count compares the spelling it was given" \
    's/^    canon="\$(hmr_canon "\${1:?path}")"$/    canon="${1:?path}"/' \
    "spelling 'symlink component'|umount_chroot verify"
lib_mut M26 "the refusal stops naming the kernel's spelling" \
    's/^    \[ "\${canon}" = "\${sysroot%\/}" \] || note=.*$/    :/' \
    'refusal \(symlinked spelling\)'
lib_mut M27 "the refusal stops saying the commands are every mount under the directory" \
    's/They are ALL the mounts under that directory/They are mounts under that directory/' \
    'refusal text'
lib_mut M28 "the layer count stops answering 0 for a table it cannot read (it would abort a build's own cleanup under set -e)" \
    's/^\(    targets="\$(hmr_mount_targets 2>\/dev\/null)"\) || {.*$/\1 || return 1/' \
    'hmr_mount_layers blind'
lib_mut M29 "the refusal stops counting the mounts it lists" \
    's/^    n="\$(printf .*$/    n=0/' \
    'refusal text'
lib_mut M33 "the seed verification always says yes" \
    's/^hmr_seed_verify() {$/hmr_seed_verify() { return 0; }\nhmr_seed_verify_real() {/' \
    'seed verify fail|4b verify fail'
lib_mut M34 "the current seed is verified a second time (the short circuit removed)" \
    's/^    if \[ "\${seed}" = "\${current}" \] || \[ "\${seed}" -ef "\${current}" \]; then$/    if false; then/' \
    'seed verify \(current seed\)|4b current seed'
lib_mut M35 "the refusal word-splits the seeds it tried again" \
    's/^    while IFS= read -r cand; do$/    for cand in ${tried}; do/' \
    'seed cache with a space'
lib_mut M36 "the toolchain match wants exactly one gcc in the seed again" \
    's/^            sys-devel\/gcc-\*)     gcc=1 ;;$/            sys-devel\/gcc-*)     gcc=$((gcc+1)) ;;/' \
    'two gcc slots'
lib_mut M37 "the marker's seed is no longer tried first" \
    's#^    for cand in "\${seeddir}/\${marker:-.none}" "\${current}" "\${seeddir}/\${flavour}"-\*.tar.xz; do$#    for cand in "${current}" "${seeddir}/${flavour}"-*.tar.xz; do#' \
    'seed choice \(marker first\)'
lib_mut M38 "a build system path resolving to / is looked under like any other" \
    '/^        \/)$/,/^            return 1 ;;$/d' \
    'sysroot resolving to /|extract phase \(sysroot -> /\)'
lib_mut M39 "a FIFO at the marker path is written into (the regular-file guard removed)" \
    '/^    if \[ -e "\${marker}" \] && \[ ! -f "\${marker}" \]; then$/,/^    fi$/d' \
    'seed marker via FIFO'
lib_mut M40 "the fallback glob accepts a cached seed of any flavour again" \
    's#^    for cand in "\${seeddir}/\${marker:-.none}" "\${current}" "\${seeddir}/\${flavour}"-\*.tar.xz; do$#    for cand in "${seeddir}/${marker:-.none}" "${current}" "${seeddir}"/stage3-*.tar.xz; do#' \
    'seed choice \(flavour\)'
fi

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
