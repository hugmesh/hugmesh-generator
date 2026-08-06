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
