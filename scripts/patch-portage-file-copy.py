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

EXIT CODES
    0  patched now, or already patched (idempotent)
    2  no portage/util/file_copy.py under ROOT (nothing extracted there yet)
    3  anchor text missing — portage changed; the pin needs a human
"""

import glob
import os
import sys

MARKER = "HUGMESH PINNED WORKAROUND"

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


def patch_one(path):
    """Returns 0 (patched or already patched) or 3 (anchor missing)."""
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
    tmp = path + ".hugmesh-tmp"
    st = os.stat(path)
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new)
    os.chmod(tmp, st.st_mode)
    os.replace(tmp, path)
    # Drop stale cached bytecode (any interpreter tag — the target root's
    # python may not be the one running this script); it regenerates on the
    # next import (the source mtime changed anyway — belt-and-braces).
    for stale in glob.glob(
        os.path.join(os.path.dirname(path), "__pycache__", "file_copy.*.pyc")
    ):
        try:
            os.unlink(stale)
        except OSError:
            pass
    log(f"patched: {path}")
    return 0


def main(argv):
    if len(argv) != 2:
        log("usage: patch-portage-file-copy.py ROOT", err=True)
        return 1
    root = argv[1]
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
        rc = max(rc, patch_one(path))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
