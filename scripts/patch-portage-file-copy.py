#!/usr/bin/env python3
"""Silence portage's per-file sendfile WARNING traceback — a PINNED workaround.

WHAT BREAKS (root cause, verified 2026-08-19)
    portage merges every installed file with _fastcopy
    (portage/util/file_copy.py): FICLONE -> copy_file_range -> sendfile ->
    (caller falls back to) shutil.copyfile. When the merge DESTINATION
    filesystem has no .splice_write file op, sendfile(2) fails EINVAL for
    EVERY file: Linux removed the splice write fallback for such filesystems
    in v5.10 (kernel commit 36e2c7421f02, "fs: don't allow splice read/write
    without explicit ops"). eCryptfs is one of those filesystems — and the
    stage4 sysroots live on the operator's eCryptfs-backed work dir (the
    /out volume) — so every merge into a sysroot hits it. Reproduced on the
    build host: os.sendfile() to an eCryptfs destination EINVALs regardless
    of source fs / offset / count; to overlayfs/tmpfs/xfs it succeeds.
    (The docker overlayfs itself was a red herring: sendfile works there.)

    The copy itself is FINE — copyfile() catches the OSError and falls back
    to shutil.copyfile. The noise is not: the copy_file_range leg silently
    ignores an expected-errno set (_CFR_IGNORE, "Taken from coreutils"), but
    the sendfile leg logs a FULL TRACEBACK on any OSError before re-raising —
    once per merged file. Measured: 308386 warning tracebacks in one stage4
    build log (out/build-snap-build-x86.log), drowning the Studio log pane.

WHAT THIS DOES
    Adds _SF_IGNORE (EINVAL/ENOSYS/EOPNOTSUPP/ENOTSUP) and gates the sendfile
    warning on it — the exact treatment the copy_file_range leg one branch up
    already gets. The OSError is STILL raised, so copy behavior is unchanged:
    copyfile still falls back to shutil.copyfile, and a sendfile failure
    OUTSIDE the expected set still logs the full traceback (real errors stay
    visible).

WHY A PATCH AND NOT A KNOB
    Verified against portage-3.0.81.2: nothing gates _fastcopy — no FEATURES
    flag, no env var, no make.conf setting (portage/util/file_copy.py and
    portage/util/movefile.py read no configuration at all), and no released
    portage version ships a sendfile ignore-set. So this is a pinned source
    patch, applied twice (same two-sided lesson as the gettext .mo masking):
      * builder image  — Dockerfile.build final stage (host-side portage:
        the ARM lanes' cross-emerge --root=SYSROOT merges),
      * every sysroot  — pcs_quiet_sendfile_noise in
        scripts/_portage-config-lib.sh (chroot-side portage: the freshly
        extracted stage3 that runs the x86 payload emerges; also re-patches
        the container root at run time as belt-and-braces for builder images
        older than the Dockerfile.build layer).

    KNOWN RESIDUAL: if a chroot payload re-merges sys-apps/portage mid-build,
    the new file is unpatched and later emerge runs in that same build get
    noisy again (the already-running emerge keeps its patched in-memory
    module). Rare — the stage3 floats and tracks the tree — and cosmetic.

    RE-EVALUATE THE PIN when this script exits 3 (anchor missing): a future
    portage rewrote file_copy.py, quite possibly silencing the noise itself —
    then this script, its Dockerfile.build layer, and pcs_quiet_sendfile_noise
    are deletable.

USAGE
    patch-portage-file-copy.py ROOT
        ROOT: a portage root — "/" (builder container) or a stage4 sysroot.
        Leaves NOTHING beside the file it edits: no sidecar, no backup.
    patch-portage-file-copy.py --backup ROOT
        As above, PLUS a pristine copy saved beside each patched file as
        <file>.hugmesh-orig. OPT-IN, and only for a caller that also runs the
        --revert below before it packages anything (see WHY THE BACKUP IS OPT-IN).
    patch-portage-file-copy.py --revert ROOT
        Restore the pristine file(s) from the .hugmesh-orig copies saved at patch
        time, and delete those copies (a stray copy beside an UNpatched file is
        deleted too). Used to keep the patch a BUILD-TIME artifact:
        a shipped image whose portage differs from what its vdb CONTENTS records
        would make `equery check sys-apps/portage` (and any file-integrity baseline)
        report a modified file forever, for a workaround the device does not need —
        it merges onto its own root, not onto the builder's eCryptfs work dir.

    The backup MUST live beside the patched file, never in a sidecar tree keyed by
    ROOT: the x86 lane patches in-chroot as ROOT="/" and reverts from OUTSIDE the
    chroot as ROOT="${SYSROOT}" — two spellings of the SAME file — so a
    root-path-keyed location would simply not be found at revert time.

WHY THE BACKUP IS OPT-IN (regression, found and fixed 2026-08-26)
    It was unconditional for exactly one change set. --revert has ONE caller
    (build-x86-host-stage4.sh, immediately before its "Packaging stage4 tarball"
    banner), but pcs_quiet_sendfile_noise — which ALL TEN stage4 builders call on
    their SYSROOT — does not revert. So the nine ARM/Jetson lanes each began
    shipping usr/lib*/python3.*/site-packages/portage/util/file_copy.py.hugmesh-orig:
    a ~4 KB vdb-unowned duplicate of a portage source file that did not exist before
    that diff, inside images that stage AIDE. Precisely the build-time residue
    --revert was added to eliminate, reintroduced nine times over.
    Opt-in inverts the default so a lane that never asks for a backup cannot leave
    one — the nine ARM lanes are byte-identical to their pre-diff behaviour again —
    and the pairing (opt in => you MUST revert) is enforced mechanically by the SFO
    bucket in tests/build-matrix/check.sh, so a FUTURE builder cannot reintroduce it
    silently either.

EXIT CODES
    0  patched now, or already patched (idempotent)
    2  no portage/util/file_copy.py under ROOT (nothing extracted there yet)
    3  anchor text missing — portage changed; the pin needs a human
"""

import glob
import os
import sys

MARKER = "HUGMESH PINNED WORKAROUND"
# Pristine copy saved beside the patched file so --revert restores it byte-exactly.
# Written ONLY under --backup (see WHY THE BACKUP IS OPT-IN above); --revert
# consumes and removes it, including a stray one beside an unpatched file.
BACKUP_SUFFIX = ".hugmesh-orig"

# The exact upstream text of portage-3.0.81.2 (whitespace included).
ANCHOR_TRY = """\
                try:
                    _do_sendfile(srcfd, dstfd, offset, count)
                except OSError:
                    logger.warning(
                        "_do_sendfile failed unexpectedly", exc_info=sys.exc_info()
                    )
                    raise
"""

REPLACEMENT_TRY = """\
                try:
                    _do_sendfile(srcfd, dstfd, offset, count)
                except OSError as e:
                    # HUGMESH PINNED WORKAROUND — see _SF_IGNORE above.
                    if e.errno not in _SF_IGNORE:
                        logger.warning(
                            "_do_sendfile failed unexpectedly",
                            exc_info=sys.exc_info(),
                        )
                    raise
"""

ANCHOR_DEF = "\ndef _get_chunks(src):"

SF_BLOCK = """\
# HUGMESH PINNED WORKAROUND (scripts/patch-portage-file-copy.py) — NOT
# upstream code. sendfile(2) EINVALs for every file when the merge
# destination fs lacks .splice_write (Linux v5.10+, kernel commit
# 36e2c7421f02; eCryptfs is such an fs and hugmesh stage4 sysroots live on
# one). _fastcopy's caller still falls back to shutil.copyfile, so only the
# per-file WARNING traceback is suppressed — mirroring the _CFR_IGNORE
# treatment of the copy_file_range leg above. Unexpected errnos still warn.
_SF_IGNORE = frozenset(
    (
        errno.EINVAL,
        errno.ENOSYS,
        errno.EOPNOTSUPP,
        errno.ENOTSUP,
    )
)"""


def log(msg, err=False):
    print(f"[sendfile-quiet] {msg}", file=sys.stderr if err else sys.stdout)


def patch_one(path, backup=False):
    """Patch PATH in place; with backup=True also save a pristine copy beside it.

    Returns 0 (patched or already patched) or 3 (anchor missing)."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if MARKER in text:
        log(f"already patched: {path}")
        return 0
    if ANCHOR_TRY not in text or ANCHOR_DEF not in text:
        log(
            f"ANCHOR MISSING in {path} — portage changed since 3.0.81.2; "
            "re-evaluate this pin (upstream may have silenced the sendfile "
            "noise itself, making this patch deletable).",
            err=True,
        )
        return 3
    new = text.replace(ANCHOR_TRY, REPLACEMENT_TRY, 1)
    head, _sep, tail = new.partition(ANCHOR_DEF)
    new = (
        head.rstrip("\n")
        + "\n\n\n"
        + SF_BLOCK
        + "\n\n\ndef _get_chunks(src):"
        + tail
    )
    # Refuse to write anything that does not compile.
    compile(new, path, "exec")
    st = os.stat(path)
    # Keep the pristine bytes so --revert can restore them EXACTLY. Re-deriving
    # the original by un-applying the transform would be a second, independently
    # wrong-able implementation of the same edit; a byte copy cannot drift. Taken
    # only on a real patch (the MARKER early-return above leaves an existing
    # backup alone), so re-patching a root never overwrites the true original
    # with an already-patched file — and so a re-patch AFTER an in-chroot
    # sys-apps/portage self-update refreshes the backup to the NEW version's
    # pristine bytes, which is the version --revert has to restore.
    # OPT-IN (`backup`): a caller that will not --revert must not leave the copy
    # behind — that residue is exactly what --revert exists to prevent, and the
    # nine ARM lanes shipped it for a day. See WHY THE BACKUP IS OPT-IN above.
    if backup:
        try:
            with open(path, "rb") as src, open(path + BACKUP_SUFFIX, "wb") as dst:
                dst.write(src.read())
            os.chmod(path + BACKUP_SUFFIX, st.st_mode)
        except OSError as exc:                   # non-fatal: the patch still applies
            log(f"WARN: could not save {path}{BACKUP_SUFFIX} ({exc}) — --revert will "
                "not be able to restore this file", err=True)
    tmp = path + ".hugmesh-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new)
    os.chmod(tmp, st.st_mode)
    os.replace(tmp, path)
    _drop_pycache(path)
    log(f"patched: {path}")
    return 0


def _drop_pycache(path):
    """Drop stale cached bytecode (any interpreter tag — the target root's python
    may not be the one running this script); it regenerates on the next import
    (the source mtime changed anyway — belt-and-braces)."""
    for stale in glob.glob(
        os.path.join(os.path.dirname(path), "__pycache__", "file_copy.*.pyc")
    ):
        try:
            os.unlink(stale)
        except OSError:
            pass


def revert_one(path):
    """Undo patch_one from the saved pristine copy. Returns 0 always — a root that
    was never patched, or whose backup is gone, is not an error worth failing a
    multi-hour build over."""
    backup = path + BACKUP_SUFFIX
    if MARKER not in open(path, encoding="utf-8").read():
        log(f"not patched, nothing to revert: {path}")
        # A stray backup with no patched file is cruft either way.
        if os.path.exists(backup):
            try:
                os.unlink(backup)
            except OSError:
                pass
        return 0
    if not os.path.isfile(backup):
        log(f"WARN: {path} is patched but {backup} is missing — leaving it patched "
            "(the file still WORKS; only its vdb checksum will differ)", err=True)
        return 0
    st = os.stat(path)
    with open(backup, "rb") as src, open(path + ".hugmesh-tmp", "wb") as dst:
        dst.write(src.read())
    os.chmod(path + ".hugmesh-tmp", st.st_mode)
    os.replace(path + ".hugmesh-tmp", path)
    try:
        os.unlink(backup)
    except OSError:
        pass
    _drop_pycache(path)
    log(f"reverted: {path}")
    return 0


def main(argv):
    revert = "--revert" in argv[1:]
    backup = "--backup" in argv[1:]
    args = [a for a in argv[1:] if a not in ("--revert", "--backup")]
    if len(args) != 1 or (revert and backup):
        # `--revert --backup` is not "revert and re-save": revert DELETES the copy.
        # Refuse the pairing rather than silently pick one, so a caller that wrote it
        # by accident finds out at the first build instead of at image-inspection time.
        log("usage: patch-portage-file-copy.py [--backup | --revert] ROOT", err=True)
        return 1
    root = args[0]
    paths = sorted(
        p
        for libdir in ("usr/lib", "usr/lib64")
        for p in glob.glob(
            os.path.join(
                root, libdir, "python3.*/site-packages/portage/util/file_copy.py"
            )
        )
        if not os.path.islink(p)
    )
    if not paths:
        log(f"no portage file_copy.py under {root!r} — nothing to patch", err=True)
        return 2
    rc = 0
    for path in paths:
        rc = max(rc, revert_one(path) if revert else patch_one(path, backup))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
