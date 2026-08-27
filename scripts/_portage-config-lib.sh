# _portage-config-lib.sh — sync a specs portage config dir into the sysroot,
# INCLUDING deletions. Sourced by every stage4 builder next to the other
# shared libs (_binpkg-pool-lib.sh, _python-targets-lib.sh).
#
# WHY THIS EXISTS (2026-08-05, found by a real resumed build). The builders
# used bare `cp specs/.../package.use/* sysroot/etc/portage/package.use/`,
# whose own comment said "so added spec files always land" — and additions do.
# DELETIONS never did: a file removed from specs survived in every RESUMED
# sysroot forever. The concrete incident: #513 retired
# package.use/firewalld-introspection (its glib[introspection] rebuild dies in
# glib's cross g-i bootstrap), but a resumed tree kept the stale copy, so every
# `--newuse` pass retried the broken glib rebuild and failed the build — the
# operator hit exactly this within hours of #513 merging. Fresh builds never
# see the bug (the sysroot starts from the seed); ONLY resume does, which is
# why it survived every gate.
#
# pcs_sync_dir SRC DEST
#   Makes DEST's file set exactly SRC's: prunes DEST files absent from SRC
#   (loudly, one line each — a deletion the operator can see in the log),
#   then copies everything in SRC. Builder-generated files that are REWRITTEN
#   downstream of the sync (pt_apply_seed_targets' python-targets, the rpi4
#   board-flip edit of package.use/rpi5) are unaffected: they exist in specs
#   too, so they are never pruned, and their rewrite happens after this step
#   exactly as it always did.
# Where this lib (and its sibling patcher script) lives — resolved at source
# time so pcs_quiet_sendfile_noise works no matter what the caller's cwd is.
_PCS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# pcs_quiet_sendfile_noise SYSROOT [backup]
#   Quiet portage's per-file sendfile WARNING-traceback spam (~300k lines per
#   stage4 build — measured 308386 in out/build-snap-build-x86.log) by
#   applying scripts/patch-portage-file-copy.py (root cause, upstream refs and
#   the exact patch live THERE) to:
#     * SYSROOT       — the freshly extracted stage3's portage, the one that
#                       runs the x86 chroot payload emerges; and
#     * the container root "/" — the builder's own portage, which the ARM
#                       lanes' cross-emerge --root=SYSROOT merges run under.
#                       Only when the host-guard proves this root disposable
#                       (never a real host), and redundant with the
#                       Dockerfile.build twin — belt-and-braces for builder
#                       images older than that layer, same pattern as the
#                       host-side keyword/USE seeds.
#   The underlying failure is sendfile(2) -> EINVAL for EVERY file merged onto
#   a filesystem with no .splice_write (the eCryptfs-backed /out work dir);
#   the copy itself always succeeded via portage's shutil fallback, so this is
#   PURELY log noise. Hence: NEVER fatal — on any failure it warns and returns
#   0. An hours-long build must not die over log cosmetics.
#
#   SECOND ARG — pcs_quiet_sendfile_noise SYSROOT backup
#   Pass the literal word `backup` ONLY from a lane that also calls
#   pcs_unquiet_sendfile_noise (below) before it packages anything. It opts the
#   SYSROOT leg into saving a pristine <file>.hugmesh-orig copy so the revert can
#   restore the file byte-exactly. DEFAULT IS NO BACKUP, and that default is the
#   fix for a real regression: the copy was unconditional for one change set, and
#   because only build-x86-host-stage4.sh reverts, the nine ARM/Jetson lanes each
#   started shipping a ~4 KB vdb-unowned duplicate of a portage source file inside
#   images that stage AIDE — exactly the build-time residue the revert exists to
#   remove. A caller that says nothing now leaves nothing. tests/build-matrix/
#   check.sh's SFO bucket fails any builder that opts in without reverting, so a
#   FUTURE lane cannot reintroduce the residue by copying the x86 call either.
#   The "/" leg NEVER takes a backup: the container root is disposable, nothing
#   reverts it, and a copy there is residue with no consumer.
pcs_quiet_sendfile_noise() {
    local sysroot="${1:?pcs_quiet_sendfile_noise: sysroot required}"
    local want_backup="${2:-}"
    local patcher="${_PCS_LIB_DIR}/patch-portage-file-copy.py" r rc bak
    case "${want_backup}" in
        ''|backup) ;;
        # Fail LOUD on a typo'd opt-in rather than silently patch with no backup:
        # the revert would then find nothing and ship the patched file forever.
        *) echo "[portage-config] WARN: pcs_quiet_sendfile_noise: unknown second arg '${want_backup}' (expected 'backup' or nothing) — proceeding WITHOUT a backup" >&2
           want_backup="" ;;
    esac
    if [ ! -f "${patcher}" ]; then
        echo "[portage-config] WARN: ${patcher} missing — per-file sendfile tracebacks will spam this build's log" >&2
        return 0
    fi
    for r in "${sysroot}" /; do
        bak=""
        if [ "${r}" = / ]; then
            # Host-guard gate (fail closed if the guard lib is not sourced):
            # patching / is a host mutation, allowed only on a disposable root.
            command -v hostguard_mutation_allowed >/dev/null 2>&1 || continue
            hostguard_mutation_allowed || continue
        elif [ "${want_backup}" = backup ]; then
            bak="--backup"
        fi
        rc=0
        python3 "${patcher}" ${bak} "${r}" || rc=$?
        case "${rc}" in
            0) ;;
            2) echo "[portage-config] WARN: no portage under ${r} — sendfile-noise patch skipped" >&2 ;;
            3) echo "[portage-config] WARN: portage under ${r} changed since 3.0.81.2 — sendfile-noise patch anchor missing; RE-EVALUATE the pin (see scripts/patch-portage-file-copy.py). Tracebacks will be back until then." >&2 ;;
            *) echo "[portage-config] WARN: sendfile-noise patch failed under ${r} (rc=${rc}) — continuing; tracebacks will be back" >&2 ;;
        esac
    done
    return 0
}

# pcs_unquiet_sendfile_noise SYSROOT
#   The MANDATORY twin of `pcs_quiet_sendfile_noise SYSROOT backup`: restore the
#   pristine portage file(s) from the .hugmesh-orig copies and delete the copies,
#   so the sendfile patch stays a BUILD-TIME artifact and NOTHING — neither the
#   patch nor its backup — rides into the shipped image. Call it AFTER the last
#   merge into SYSROOT (a later merge would re-spam the log, and on x86 the
#   kernel chroot merges gentoo-sources under the same portage) and BEFORE the
#   stage4 tar / .img / live-ISO squash.
#   WHY THE SHIPPED IMAGE MUST NOT KEEP THE PATCH: its portage would disagree
#   with the md5 sys-apps/portage recorded in var/db/pkg/.../CONTENTS forever, so
#   `equery check sys-apps/portage` and any file-integrity baseline (these images
#   stage AIDE) would report a modified file — for a workaround the device does
#   not need, since it merges onto its own root, not the builder's eCryptfs work dir.
#   Same never-fatal contract as its twin: warn and return 0 on every failure.
#   Only ever the SYSROOT — the container root "/" keeps its patch (disposable,
#   and it is the portage the ARM lanes' cross-emerge --root=SYSROOT runs under).
pcs_unquiet_sendfile_noise() {
    local sysroot="${1:?pcs_unquiet_sendfile_noise: sysroot required}"
    local patcher="${_PCS_LIB_DIR}/patch-portage-file-copy.py" rc=0
    if [ ! -f "${patcher}" ]; then
        echo "[portage-config] WARN: ${patcher} missing — the sendfile-noise patch stays in the shipped portage (harmless, but its vdb checksum will not match)" >&2
        return 0
    fi
    python3 "${patcher}" --revert "${sysroot}" || rc=$?
    case "${rc}" in
        0) ;;
        2) echo "[portage-config] WARN: no portage under ${sysroot} — sendfile-noise revert skipped" >&2 ;;
        *) echo "[portage-config] WARN: sendfile-noise revert failed under ${sysroot} (rc=${rc}) — the shipped portage stays patched (harmless, but its vdb checksum will not match)" >&2 ;;
    esac
    return 0
}

pcs_sync_dir() {
    local src="${1:?pcs_sync_dir: src required}" dest="${2:?pcs_sync_dir: dest required}" f base
    [ -d "${src}" ] || { echo "[portage-config] ERROR: spec dir missing: ${src}" >&2; return 1; }
    mkdir -p "${dest}"
    for f in "${dest}"/*; do
        [ -e "${f}" ] || continue          # empty dest glob
        base="${f##*/}"
        if [ ! -e "${src}/${base}" ]; then
            echo "[portage-config] pruning stale ${dest##*sysroot}/${base} (removed from specs)"
            # -rf, not -f: portage/env legitimately contains SUBDIRECTORIES
            # (specs-x86/portage/env/{app-office,dev-qt}), so a stale entry can be a
            # directory and `rm -f` would leave it behind forever.
            rm -rf -- "${f}" || return 1
        fi
    done
    # Copy everything present (tolerate an empty spec dir: some platforms have no
    # package.env entries). -R because portage/env nests one level: the pre-sync
    # code this replaced was `cp -r .../env/* ...` and dropping the recursion made
    # `cp` refuse every directory ("omitting directory"), fail the helper, and abort
    # EVERY x86 build at the spec-install step. -R (not -a) matches that original
    # behaviour: content + mode, no ownership games on a sysroot the builder owns.
    for f in "${src}"/*; do
        [ -e "${f}" ] || return 0
        # replace rather than nest: without this, cp -R of a directory INTO an
        # existing same-named directory would create dest/<name>/<name>.
        [ -d "${f}" ] && rm -rf -- "${dest}/${f##*/}"
        cp -R -- "${f}" "${dest}/" || return 1
    done
}
