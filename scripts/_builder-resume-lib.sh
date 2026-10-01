#!/usr/bin/env bash
# _builder-resume-lib.sh — what a stage4 builder must check before it REUSES a
# build system (--resume) and how it leaves mounts behind. Sourced by
# build-x86-host-stage4.sh and build-rpi5-stage4.sh; never executed directly.
#
# Why this exists (hugmesh-generator#659, 2026-09-30). A finished build leaves
# its build system (<work dir>/snap-build-*/sysroot) in a state a later --resume
# cannot safely reuse, for three independent reasons, and the builder checked
# none of them:
#
#   1. The clean step deletes every static library under usr/lib{,64} to keep
#      the image small. A resumed build that has to COMPILE anything then fails
#      with "C compiler cannot create executables" / "cannot find -lpthread" /
#      "cannot find /usr/lib64/libc_nonshared.a". The restore that puts them
#      back ran only for GPU roles.
#   2. `make` hands the whole work directory to the invoking user after a native
#      build (Makefile chown-artifacts), build system included. A build resumed
#      from that tree finishes GREEN and writes an image whose every directory
#      is owned by that user: sshd, systemd-tmpfiles, snort and tor refuse to
#      start in it. Nothing looked.
#   3. The build's own bind mount of var/cache/distfiles-ro was never unmounted,
#      so every run (failed or successful) left one or two stacked under the
#      build system, and the next non-resume build refused to start with a
#      suggested `umount -R <sysroot>` that names a directory which is not a
#      mount point.
#
# Every function here is plain bash, safe under `set -euo pipefail`, and uses
# no `| grep -q` (SIGPIPE under pipefail can turn a FOUND match into a failure).
# No `local` line reads one of its own names on its right-hand side (bash 5.3
# localises every name BEFORE assigning, so `local a=$1 b=$a` dies under set -u;
# `local a=$1 b=$2` is fine). Messages go through the builder's err/info/warn
# when they are defined, else to stderr/stdout in plain form.

_hmr_err()  { if declare -F err  >/dev/null 2>&1; then err  "$1"; else printf 'ERROR: %s\n' "$1" >&2; fi; }
_hmr_warn() { if declare -F warn >/dev/null 2>&1; then warn "$1"; else printf 'WARNING: %s\n' "$1" >&2; fi; }
_hmr_info() { if declare -F info >/dev/null 2>&1; then info "$1"; else printf '%s\n' "$1"; fi; }

# ── 1. Ownership ──────────────────────────────────────────────────────────────
# hmr_owner_gate <sysroot> [remedy] — 0 when every checked directory of the build
# system is owned by uid 0; otherwise prints ONE sentence naming the directory
# and its owner, ending in <remedy>, and returns 1. Checked: the root, etc, var,
# usr, usr/lib, usr/lib64, bin, var/empty and var/db/pkg (whichever exist).
# `stat -L` follows a symlink (merged usr ships /bin -> usr/bin), so the directory
# behind the link is what is read. The default remedy is what the x86 and rpi5
# builders do on a non-resume run (wipe, then extract the stage3 again as root);
# a builder that extracts the stage3 OVER an existing tree passes its own, since
# overlaying a stage3 on a user-owned tree leaves every later-installed file the
# user's.
#
# Why REFUSE rather than restore root ownership: `chown -R user` erases the
# information needed to undo it. A stage3 seed ships 24 entries that are NOT
# root:root (measured on stage3-amd64-hardened-openrc-20260920: 14 root:portage,
# 4 root:shadow, 4 portage:portage, 1 root:mail, 1 man:man), a built image adds
# tor, sshd, postgres and every other service account, and portage's own record
# of an installed package (var/db/pkg/*/*/CONTENTS) carries paths and hashes but
# NO owner column. So after the tree has been handed to a user there is no
# source of truth to restore each file's real owner from; "chown -R root" would
# produce a different wrong image (services that must NOT run as root would
# find their state directories root-owned). A fresh extraction as root is the
# only correct fix, and it costs about an hour.
HMR_OWNER_CHECK_DIRS="/ /etc /var /usr /usr/lib /usr/lib64 /bin /var/empty /var/db/pkg"
hmr_owner_gate() {
    local sysroot="${1:?sysroot}"
    local remedy="${2:-rebuild WITHOUT --resume so the build system is wiped and re-extracted as root}"
    local rel path uid
    for rel in ${HMR_OWNER_CHECK_DIRS}; do
        path="${sysroot%/}${rel%/}"
        [ -d "${path}" ] || continue
        uid="$(stat -L -c %u "${path}" 2>/dev/null || echo '?')"
        if [ "${uid}" != "0" ]; then
            _hmr_err "Refusing --resume: the build system directory ${path} is owned by uid ${uid}, not root (a finished 'make' run used to hand the whole work directory to the invoking user), and an image built from such a tree boots broken because sshd, systemd-tmpfiles, snort and tor refuse directories that are not root's; ${remedy}."
            return 1
        fi
    done
    return 0
}

# ── 2. Which seed a build system came from ────────────────────────────────────
# The marker lives BESIDE the sysroot (<build root>/sysroot.seed), never inside
# it: nothing inside the sysroot survives the clean step or stays out of the
# image, and the marker must do both. It holds the seed tarball's basename.
HMR_SEED_MARKER_NAME="sysroot.seed"
hmr_seed_marker_path()  { printf '%s/%s\n' "${1%/}" "${HMR_SEED_MARKER_NAME}"; }
# The marker is written as root into <build root>, a directory the Makefile hands
# to the invoking user (only directories NAMED sysroot are skipped), so a symlink
# planted at the marker's path would be followed by a plain `>`. Refuse to write
# through one; the caller carries on, and the next resume falls back to the
# version match.
hmr_seed_marker_write() {
    local build_root="${1:?build root}" seed="${2:?seed path}"
    local marker
    marker="$(hmr_seed_marker_path "${build_root}")"
    if [ -L "${marker}" ]; then
        _hmr_warn "not recording the seed name: ${marker} is a symlink; remove it"
        return 1
    fi
    printf '%s\n' "$(basename "${seed}")" > "${marker}" 2>/dev/null \
        || { _hmr_warn "could not record the seed name in ${marker}"; return 1; }
}
# What is read back is joined onto the seed cache directory as a file NAME, so
# anything that is not a bare name (a `/`, `.`, `..`, nothing) is ignored: a
# marker holding `../../x.tar.xz` cannot point the restore outside the cache.
hmr_seed_marker_read() {
    local build_root="${1:?build root}"
    local marker m
    marker="$(hmr_seed_marker_path "${build_root}")"
    [ -f "${marker}" ] || return 0
    m="$(head -n1 "${marker}" 2>/dev/null | tr -d '[:space:]')"
    case "${m}" in */*|.|..|'') return 0 ;; esac
    printf '%s\n' "${m}"
}

# hmr_seed_list <seed.tar.xz> <listing out> — write the tarball's member list
# ONCE (about a second for a 280 MiB stage3 on this host); every later question
# about the seed is answered from that file, not by re-reading the tarball.
hmr_seed_list() {
    local seed="${1:?seed}" out="${2:?listing out}"
    tar tJf "${seed}" > "${out}" 2>/dev/null || { : > "${out}"; return 1; }
    [ -s "${out}" ]
}

# hmr_toolchain_from_listing <listing> — the seed's installed toolchain, one
# `<category>/<pf>` per line, from the package database the stage3 ships:
# sys-libs/glibc, sys-devel/gcc, sys-devel/binutils. The `-[0-9]` anchor keeps
# gcc-config and binutils-config out.
HMR_TOOLCHAIN_RE='^\./var/db/pkg/(sys-libs/glibc|sys-devel/gcc|sys-devel/binutils)-[0-9][^/]*/$'
hmr_toolchain_from_listing() {
    local listing="${1:?listing}"
    grep -a -E "${HMR_TOOLCHAIN_RE}" "${listing}" 2>/dev/null \
        | sed -e 's#^\./var/db/pkg/##' -e 's#/$##' | sort -u
}

# hmr_toolchain_from_sysroot <sysroot> — the same three packages as installed
# in the build system (its var/db/pkg), `<category>/<pf>` per line.
hmr_toolchain_from_sysroot() {
    local sysroot="${1:?sysroot}"
    local cat pn d
    for cat in sys-libs/glibc sys-devel/gcc sys-devel/binutils; do
        pn="${cat#*/}"
        for d in "${sysroot%/}/var/db/pkg/${cat}"-[0-9]*/; do
            [ -d "${d}" ] || continue
            d="${d%/}"
            case "${d##*/}" in "${pn}"-[0-9]*) printf '%s/%s\n' "${cat%/*}" "${d##*/}" ;; esac
        done
    done | sort -u
}

# hmr_toolchain_matches <listing> <sysroot> — 0 when every toolchain package
# the seed lists (exact <pf>: version and revision) is installed in the build
# system, and the seed lists all three. A build system may hold MORE (a second
# gcc slot); it may not lack or differ in any of the seed's.
hmr_toolchain_matches() {
    local listing="${1:?listing}" sysroot="${2:?sysroot}"
    local seed_tc want n=0
    seed_tc="$(hmr_toolchain_from_listing "${listing}")"
    [ -n "${seed_tc}" ] || return 1
    while IFS= read -r want; do
        [ -n "${want}" ] || continue
        n=$((n+1))
        [ -d "${sysroot%/}/var/db/pkg/${want}" ] || return 1
    done <<EOF
${seed_tc}
EOF
    [ "${n}" -eq 3 ]
}

# hmr_seed_for_resume <build root> <sysroot> <current seed> <listing out>
# Prints the path of the seed whose toolchain the build system carries, and
# leaves that seed's member list in <listing out>. Order tried: the seed the
# marker names (when it is still cached beside the current one), then the
# current seed, then every other cached stage3 beside it in glob order (oldest
# name first; the order cannot matter, since a match is exact).
# When none matches it prints ONE sentence and returns 1: the safe choice, since
# restoring glibc/gcc/binutils static archives from a different toolchain than
# the one the build system's shared libraries and compiler came from is exactly
# the mismatch that produces link errors nobody can read.
hmr_seed_for_resume() {
    local build_root="${1:?build root}" sysroot="${2:?sysroot}" current="${3:?current seed}" listing="${4:?listing out}"
    local seeddir marker cand tried="" have tc_line seed_tc
    seeddir="$(dirname "${current}")"
    marker="$(hmr_seed_marker_read "${build_root}")"
    for cand in "${seeddir}/${marker:-.none}" "${current}" "${seeddir}"/stage3-*.tar.xz; do
        [ -f "${cand}" ] || continue
        case " ${tried} " in *" ${cand} "*) continue ;; esac
        tried="${tried} ${cand}"
        hmr_seed_list "${cand}" "${listing}" || continue
        if hmr_toolchain_matches "${listing}" "${sysroot}"; then
            printf '%s\n' "${cand}"
            return 0
        fi
    done
    have="$(hmr_toolchain_from_sysroot "${sysroot}" | tr '\n' ' ')"
    have="${have% }"
    tc_line=""
    for cand in ${tried}; do
        hmr_seed_list "${cand}" "${listing}" >/dev/null 2>&1 || true
        seed_tc="$(hmr_toolchain_from_listing "${listing}" | tr '\n' ' ')"
        seed_tc="${seed_tc% }"
        tc_line="${tc_line}${tc_line:+; }$(basename "${cand}"): ${seed_tc:-no toolchain record}"
    done
    : > "${listing}"
    _hmr_err "Refusing to restore the build system's static libraries: no cached seed tarball carries the toolchain this build system was extracted from (the build system has ${have:-no toolchain record}; cached seeds: ${tc_line:-none}), so the files restored would come from a different glibc, gcc or binutils than the one already installed; rebuild WITHOUT --resume."
    return 1
}

# ── 3. The static files themselves ────────────────────────────────────────────
# hmr_statics_missing <sysroot> — 0 when the clean step has stripped the
# toolchain's static files: no libgcc.a under usr/lib/gcc or no libc_nonshared.a
# under usr/lib{,64}. Either alone makes every link fail (gcc's link spec pulls
# libgcc.a; glibc's libc.so linker script pulls libc_nonshared.a).
hmr_statics_missing() {
    local sysroot="${1:?sysroot}"
    local gcc_a libc_a
    gcc_a="$(find "${sysroot%/}/usr/lib/gcc" -name libgcc.a -print -quit 2>/dev/null || true)"
    libc_a="$(find "${sysroot%/}/usr/lib" "${sysroot%/}/usr/lib64" -maxdepth 1 -name libc_nonshared.a -print -quit 2>/dev/null || true)"
    [ -z "${gcc_a}" ] || [ -z "${libc_a}" ]
}

# hmr_statics_from_listing <listing> <out> — the members to restore: every
# static archive and every crt*.o start file. The same selection the GPU-only
# restore used, unchanged.
HMR_STATICS_RE='\.a$|/[^/]*crt[^/]*\.o$'
hmr_statics_from_listing() {
    local listing="${1:?listing}" out="${2:?out}"
    grep -a -E "${HMR_STATICS_RE}" "${listing}" > "${out}" 2>/dev/null || : > "${out}"
    [ -s "${out}" ]
}

# hmr_statics_restore <sysroot> <seed> <listing> — extract those members from
# the seed over the build system (additive: nothing is removed or replaced that
# the seed does not itself ship). Returns 1 when the list is empty or tar fails.
hmr_statics_restore() {
    local sysroot="${1:?sysroot}" seed="${2:?seed}" listing="${3:?listing}"
    local members n
    members="$(mktemp)"
    if ! hmr_statics_from_listing "${listing}" "${members}"; then
        rm -f "${members}"
        _hmr_err "The seed $(basename "${seed}") lists no static archives or crt*.o files to restore; rebuild WITHOUT --resume."
        return 1
    fi
    n="$(wc -l < "${members}" | tr -d ' ')"
    if ! tar xJf "${seed}" -C "${sysroot}" -T "${members}" 2>/dev/null; then
        rm -f "${members}"
        _hmr_err "Could not extract the ${n} static archives/crt objects from $(basename "${seed}") into ${sysroot}; rebuild WITHOUT --resume."
        return 1
    fi
    rm -f "${members}"
    _hmr_info "Restored ${n} toolchain static archives/crt objects from $(basename "${seed}")"
}

# ── 4. Can the build system link at all? ──────────────────────────────────────
# hmr_link_check_chroot <sysroot> — compile and link a one-line C program
# INSIDE the build system (chroot; the mounts must be up), with -lpthread -ldl
# so the same three files the 2026-09-30 failure named are exercised
# (libc_nonshared.a through libc.so's linker script, libpthread.a, libdl.a).
# On failure prints ONE sentence carrying the first linker/compiler error line
# and returns 1. Single-quoted snippet: nothing in it expands on the host.
hmr_link_check_chroot() {
    local sysroot="${1:?sysroot}"
    local out rc=0 first
    out="$(chroot "${sysroot}" /bin/bash -c 'set -e; d="$(mktemp -d /tmp/hm-link.XXXXXX)"; trap "rm -rf \"$d\"" EXIT; printf "int main(void){return 0;}\n" > "$d/t.c"; gcc -o "$d/t" "$d/t.c" -lpthread -ldl' 2>&1)" || rc=$?
    [ "${rc}" -eq 0 ] && return 0
    first="$(printf '%s\n' "${out}" | grep -a -m1 -E 'error|cannot find|not found' || true)"
    [ -n "${first}" ] || first="$(printf '%s\n' "${out}" | head -n1)"
    _hmr_err "The reused build system cannot link a C program (${first:-no output, exit ${rc}}): its static libraries were stripped by an earlier build's clean step and were not restored, so every package that has to compile would fail the same way; rebuild WITHOUT --resume."
    return 1
}

# ── 5. Mounts under the build system ──────────────────────────────────────────
# HOW THE MOUNT TABLE IS READ, AND WHY (found by review, 2026-09-30).
# The first version of this section compared the path the builder was GIVEN with
# the text `findmnt -rn -o TARGET` prints, and gated its `umount` on that count.
# Measured, that fails whenever the builder's spelling differs from the kernel's,
# and it failed SILENTLY:
#   - the kernel names a mount by its canonical path (absolute, every symlink
#     resolved), so a build system reached through a symlink (`make WORK_DIR=`
#     pointing at one) or through a relative --work-dir never matched;
#   - findmnt escapes what it prints: a space as \x20 in raw mode, and every byte
#     above 0x7f under the C locale even in list mode (`jörg` comes out as
#     `j\xc3\xb6rg`), and a literal `\x` as `\x5cx`; so a work directory with a
#     space or an umlaut never matched either.
# On such a path the count was 0, hmr_umount_own unmounted NOTHING and reported
# success, the stale-mount check found nothing, and the next non-resume run's
# `rm -rf` of the build system would have gone through the bind of the host's
# portage tree and the fleet's binpkg pool.
# Now: the builder's spelling is resolved to the kernel's (readlink -f); the
# table is read straight from /proc/self/mountinfo (the file findmnt itself
# parses), whose escaping is the kernel's and fixed: in the mount point field
# every space, tab, newline and backslash is written as \NNN, three octal
# digits, and every other byte as it is (_hmr_unmangle undoes exactly that);
# paths are compared as literal text, never as a regex or a glob; the detach in
# hmr_umount_own does not wait for any count; and a table that cannot be read
# refuses, instead of answering "nothing is mounted", which is the answer that
# lets a rm -rf run. A build system path holding a newline is refused outright.

# _hmr_unmangle <string> — undo the kernel's escaping of one mount point. NOT
# `printf %b`: bash reads \0NNN greedily, so a space followed by a digit
# ("build 5", written build\0405) comes back as byte 0x05 and the path is lost.
_hmr_unmangle() {
    local s="${1-}" out="" pre oct ch
    while :; do
        case "${s}" in
            *'\'[0-7][0-7][0-7]*) ;;
            *) break ;;
        esac
        pre="${s%%\\[0-7][0-7][0-7]*}"
        oct="${s:${#pre}+1:3}"
        printf -v ch "\\${oct}"
        out="${out}${pre}${ch}"
        s="${s:${#pre}+4}"
    done
    printf '%s' "${out}${s}"
}

# _hmr_squote <string> — the string as ONE single-quoted shell word, safe to paste.
_hmr_squote() {
    local s="${1-}" q="'"
    printf "'%s'" "${s//${q}/${q}\\${q}${q}}"
}

# hmr_canon <path> — the spelling the kernel uses for <path>: absolute, symlinks
# resolved. A path readlink cannot resolve is returned as given.
hmr_canon() {
    local p="${1:?path}"
    local c
    c="$(readlink -f -- "${p}" 2>/dev/null || true)"
    [ -n "${c}" ] || c="${p}"
    [ "${c}" = "/" ] || c="${c%/}"
    printf '%s\n' "${c}"
}

# hmr_mount_targets — every mount point in the kernel's table, one decoded path
# per line, in the kernel's order (a bind stacked three times is three lines, the
# top one last). The table is ${HMR_MOUNTINFO:-/proc/self/mountinfo}; only a test
# sets the variable. Returns 1 with one sentence when the table cannot be read.
hmr_mount_targets() {
    local table="${HMR_MOUNTINFO:-/proc/self/mountinfo}"
    local _id _parent _dev _root target _rest
    if [ ! -r "${table}" ]; then
        _hmr_err "cannot read the kernel's mount table (${table}), so there is no telling what is mounted under the build system; refusing to go on"
        return 1
    fi
    while IFS=' ' read -r _id _parent _dev _root target _rest; do
        [ -n "${target}" ] || continue
        _hmr_unmangle "${target}"
        printf '\n'
    done < "${table}"
}

# hmr_stale_mounts <sysroot> — every mount whose mount point lies strictly under
# the sysroot, one per line, a stacked bind once per layer. Empty means nothing
# is mounted there. Returns 1, printing nothing, when the table cannot be read or
# the sysroot's own path holds a newline: an empty answer from a table nobody
# read is the answer that lets `rm -rf` run.
hmr_stale_mounts() {
    local sysroot="${1:?sysroot}"
    local canon prefix targets t
    canon="$(hmr_canon "${sysroot}")"
    case "${canon}" in
        *$'\n'*)
            _hmr_err "the build system path ${sysroot} contains a newline, which this builder cannot check for mounts; use a path without one"
            return 1 ;;
    esac
    prefix="${canon%/}/"
    targets="$(hmr_mount_targets)" || return 1
    while IFS= read -r t; do
        case "${t}" in
            "${prefix}"*) printf '%s\n' "${t}" ;;
        esac
    done <<< "${targets}"
}

# hmr_stale_mount_hint <listing> [indent] — the commands that clear a listing:
# one `umount '<path>'` per line, deepest path first (an rbind's submounts go
# before their parent), a path listed twice unmounted twice (a bind stacked
# twice needs two umounts). Built from the decoded listing and quoted per path,
# so it is right for any spelling. The old hint, `umount -R <sysroot>`, never
# worked: the sysroot directory itself is not a mount point.
hmr_stale_mount_hint() {
    local listing="${1:-}" indent="${2-}" m
    [ -n "${listing}" ] || return 0
    printf '%s\n' "${listing}" | LC_ALL=C sort -r | while IFS= read -r m; do
        [ -n "${m}" ] || continue
        printf '%sumount %s\n' "${indent}" "$(_hmr_squote "${m}")"
    done
}

# hmr_stale_mount_refuse <sysroot> <listing> — the refusal (to stderr): the WHOLE
# listing, as the commands that remove it, and a plain statement that they are
# every mount under the directory, including any a person mounted there on purpose.
hmr_stale_mount_refuse() {
    local sysroot="${1:?sysroot}" listing="${2:-}"
    local canon n note=""
    canon="$(hmr_canon "${sysroot}")"
    [ "${canon}" = "${sysroot%/}" ] || note=" (the kernel lists it as ${canon})"
    n="$(printf '%s\n' "${listing}" | grep -a -c . || true)"
    _hmr_err "mounts are still attached under ${sysroot}${note}: ${n} in all (a crashed run, or an older builder that left its distfiles-ro bind behind). Each is listed below as the command that removes it:"
    hmr_stale_mount_hint "${listing}" "    " >&2
    _hmr_err "rm -rf or a new chroot would go THROUGH those mounts (host /dev, the shared portage scratch, the distfiles cache), so nothing is touched until they are gone."
    _hmr_err "Run the commands above as root, top to bottom. They are ALL the mounts under that directory, deepest first, one umount per line (a path listed twice is stacked twice and needs two umounts), including any you mounted there on purpose: read them before you run them."
    _hmr_err "Then re-run (add --resume back if you had it)."
}

# hmr_mount_layers <path> — how many mounts sit on exactly this path, however
# the path is spelled (a bind stacked three times answers 3; nothing mounted
# there, or a table that cannot be read, answers 0).
hmr_mount_layers() {
    local canon targets t
    local n=0
    canon="$(hmr_canon "${1:?path}")"
    targets="$(hmr_mount_targets 2>/dev/null)" || { printf '0\n'; return 0; }
    while IFS= read -r t; do
        if [ "${t}" = "${canon}" ]; then n=$((n+1)); fi
    done <<< "${targets}"
    printf '%s\n' "${n}"
}

# hmr_umount_own <path> — detach ONE layer from <path>: the one this build
# made. The `umount -l` is UNCONDITIONAL: it never waits for the layer count,
# because a count that cannot see the path (an unreadable table, a spelling that
# does not match) must not turn the build's own cleanup into a no-op. `umount -l`
# peels the topmost mount only, so layers somebody else (an earlier crashed run,
# the operator) stacked beneath stay where they were, and the stale-mount
# refusal at the next Extract phase names them. The count is used only to VERIFY
# (`umount -l ... || true` is silent): when it saw the path before and the count
# did not go down, that is said out loud. Never fails the caller — a build's own
# cleanup must not turn a finished image into a failed run — so the return value
# is informational.
hmr_umount_own() {
    local path="${1:?path}"
    local before after
    before="$(hmr_mount_layers "${path}")"
    umount -l "${path}" 2>/dev/null || true
    [ "${before:-0}" -gt 0 ] || return 0
    after="$(hmr_mount_layers "${path}")"
    if [ "${after:-0}" -ge "${before}" ]; then
        _hmr_warn "${path} is STILL mounted (${after} layer(s)) after this build's own umount — it was not detached; see the stale-mount hint before the next build"
        return 1
    fi
    return 0
}
