"""Where build sessions live: the per-user OUTPUT-ROOT registry (Qt-free, stdlib only).

A build session's artifacts land in ``<out>/sessions/<id>/`` where ``<out>`` is the
operator's chosen output folder, or ``<generator>/out`` when none was chosen
(core/build_sessions.py ``session_workdir``). The Sessions page always found every
session, because it reads the per-session RECORDS under the state dir and each record
carries its absolute ``workdir``. The emulation lane did not: it scanned
``<generator>/out/sessions`` and nothing else, so a session built into another folder
could be listed, restarted and deleted, but never booted under QEMU. The picker was
empty, ``--session <id>`` was "no such build session", and the runner's default said
"no build session under out/sessions/".

This module is the one answer to "which folders can hold sessions?", for every
reader: the GUI and TUI pickers, the emulation and mesh-emulation CLIs, the Windows
WHPX backend (through ``emulation._as_session``), the save-target guard in
core/qemu_devices.py, and tests/qemu/run-qemu-docker.sh (through ``python3 -m``).

WHERE THE REGISTRY LIVES, AND WHY NOT ``$XDG_DATA_HOME``
--------------------------------------------------------
Under :func:`.state_paths.state_dir` (``$HUGMESH_STUDIO_STATE_DIR``, else
``~/.hugmesh/studio``), beside the session records it indexes. That is the Studio's
existing per-user data folder, and it is the SAME folder for every way the Studio
runs:

* a source checkout and the bash runner resolve ``~`` to the real home;
* the Flatpak keeps ``$HOME`` as the real home and is granted ``--filesystem=host``,
  but it rewrites ``$XDG_DATA_HOME``/``$XDG_STATE_HOME`` to
  ``~/.var/app/org.hugmesh.ImageStudio/…``. A registry under XDG would therefore be
  one file for the Flatpak and another for everything else, which is the
  "my sessions vanished" defect again, moved one layer down;
* native Windows resolves ``~`` to ``%USERPROFILE%``, giving
  ``%USERPROFILE%\\.hugmesh\\studio`` (and the MSI smoke test sets the override).

A WSL Studio and a native Windows Studio are two users as far as this is concerned:
each has its own home and its own registry.

WHAT IS RECORDED (and what is not)
----------------------------------
One small file per output root, ``<state>/session-roots/<hash>.json``, holding
``{"root": <absolute path>, "recorded": <time>}``. Paths only: no config, no
hostname, no secret, ever. Written ``0600``.

One file per root rather than one shared list is the concurrency story. Two
Studios (or a Studio and a CLI) starting builds at the same moment each write their
OWN file with an atomic tmp + ``os.replace``. There is no read-modify-write, so
there is nothing to lose an update to; two writers recording the same root write
identical content to the same name, and either one winning is correct.

The registry is also not the only witness. :func:`roots` re-derives roots from the
session records themselves (``dirname(dirname(workdir))``), so a session with a
record is findable even with an empty or deleted registry. That is also the
migration path for sessions recorded before this module existed. The reverse does
NOT hold: once a record is deleted and its images kept (the Sessions page's
"delete the record, keep the images", bulk ``build_sessions.prune(remove_artifacts=
False)``, the TUI's "record only"), the registry entry is the ONLY thing left on
disk that names the folder. So ``build_sessions.delete`` records the folder here
before it removes such a record (a session dispatched before this module existed
has no entry yet), and nothing forgets an entry merely because its folder is away.

ABSENCE IS NOT DELETION (nothing prunes on its own)
---------------------------------------------------
A folder that is not there right now (an unplugged drive, an unmounted share, a
renamed parent) is simply not LISTED: :func:`roots` filters it on every read. Its
entry stays, so the moment the drive comes back its sessions are listed and bootable
again, with no rebuild and no record. The registry used to drop such an entry from
every Sessions page refresh and every build dispatch; after a record-only delete
that made one refresh with the drive unplugged lose the folder for good (round-1
refutation of PR #928). Neither path prunes any more, and a test pins both.

Growth is bounded by the number of DISTINCT output folders an operator ever chose,
one ~100-byte file each, not by the number of builds: there is nothing to reclaim
that is worth a lost drive. :func:`prune` survives only as an explicit call for a
caller that has been told a folder is gone for good. It never touches a session
record, and never touches a session folder: records are the build history
(core/build_sessions.py "crash honesty"), and a record whose folder is gone is what
offers Redo.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime

from .state_paths import state_dir

__all__ = [
    "REGISTRY_SUBDIR", "SESSIONS_NAME", "find_session_dir", "is_session_name",
    "prune", "record_root", "registered_roots", "registry_dir", "root_of",
    "roots", "same_path", "sessions_dirs",
]

#: The registry folder under the state dir, one ``<hash>.json`` per output root.
REGISTRY_SUBDIR = "session-roots"
#: The fixed child of every output root that holds the per-session dirs. Spelled
#: here and in build_sessions.session_workdir; test_session_locations.py pins the two.
SESSIONS_NAME = "sessions"
#: Where the session records live under the state dir (build_sessions.sessions_dir).
_RECORDS_SUBDIR = "sessions"


# ── path identity ────────────────────────────────────────────────────────────────────
def _key(path: str) -> str:
    """The identity of a folder: absolute, symlinks resolved, case folded on Windows
    (``normcase`` lower-cases and turns ``/`` into ``\\`` there, and is a no-op on
    POSIX, where ``/Out`` and ``/out`` really are two folders)."""
    return os.path.normcase(os.path.realpath(os.path.abspath(path)))


def same_path(a: str, b: str) -> bool:
    """True when ``a`` and ``b`` name the same folder (see :func:`_key`)."""
    return bool(a) and bool(b) and _key(a) == _key(b)


def root_of(session_dir: str) -> str:
    """The output root a session dir belongs to: ``<out>`` for ``<out>/sessions/<id>``,
    "" for a path of any other shape (a hand-picked ``--artifacts`` folder)."""
    norm = os.path.normpath(os.path.abspath(session_dir))
    parent = os.path.dirname(norm)
    if os.path.basename(parent) != SESSIONS_NAME:
        return ""
    return os.path.dirname(parent)


def is_session_name(name: str) -> bool:
    """A bare session dir name (``20261108-213119-c18ff4``), never a path. The guard
    that keeps a name lookup from walking out of ``<root>/sessions`` with ``..``."""
    return (bool(name) and name not in (".", "..")
            and "/" not in name and "\\" not in name and os.sep not in name
            and (os.altsep is None or os.altsep not in name))


# ── the registry ─────────────────────────────────────────────────────────────────────
def registry_dir() -> str:
    """``<state>/session-roots``. Resolved through :func:`.state_paths.state_dir`, so
    the override and the pytest guard apply exactly as they do to the records."""
    return os.path.join(state_dir(), REGISTRY_SUBDIR)


def _entry_path(root: str) -> str:
    digest = hashlib.sha256(_key(root).encode("utf-8", "surrogatepass")).hexdigest()
    return os.path.join(registry_dir(), digest[:20] + ".json")


def record_root(out_dir: str) -> bool:
    """Remember ``out_dir`` as a folder that holds (or will hold) ``sessions/``.

    Called at build dispatch (core/build_sessions.py ``start``) and before a
    record-only delete (``build_sessions.delete``). Best-effort in the same way the
    record write is: a build must never die because this could not be written, so
    every OSError is swallowed and reported as False. It never prunes other entries:
    an absent folder is a drive that may come back (see the module docstring).
    """
    if not out_dir:
        return False
    root = os.path.abspath(out_dir)
    path = _entry_path(root)
    body = json.dumps({"root": root,
                       "recorded": datetime.now().astimezone().isoformat(
                           timespec="seconds")}, indent=2)
    tmp = f"{path}.{os.getpid()}.{os.urandom(4).hex()}.tmp"
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False
    return True


def _entries() -> list[tuple[str, str]]:
    """``(entry file, root)`` for every readable registry entry, newest first."""
    reg = registry_dir()
    try:
        names = os.listdir(reg)
    except OSError:
        return []
    found: list[tuple[float, str, str]] = []
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(reg, name)
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
            mtime = os.path.getmtime(path)
        except (OSError, ValueError):
            continue
        root = data.get("root") if isinstance(data, dict) else None
        if isinstance(root, str) and root and os.path.isabs(root):
            found.append((mtime, path, root))
    found.sort(key=lambda t: t[0], reverse=True)
    return [(p, r) for _m, p, r in found]


def registered_roots() -> list[str]:
    """Every root in the registry, existing or not, newest first."""
    return [r for _p, r in _entries()]


def prune(keep: str = "") -> list[str]:
    """Drop registry entries whose folder does not exist RIGHT NOW; return the roots
    dropped.

    EXPLICIT ONLY. Absence is not deletion: an unplugged drive is absent too, and
    after a record-only delete its entry is the last pointer to its images (module
    docstring, "ABSENCE IS NOT DELETION"). Nothing in the Studio calls this on its
    own, and nothing should: not a page refresh, not a build dispatch.

    Only the tiny pointer file goes. Session records and session folders are never
    touched. ``keep`` is spared even when absent."""
    dropped: list[str] = []
    for path, root in _entries():
        if os.path.isdir(root) or (keep and _key(root) == _key(keep)):
            continue
        try:
            os.unlink(path)
        except OSError:
            continue
        dropped.append(root)
    return dropped


def _roots_from_records() -> list[str]:
    """Roots derived from the session records' ``workdir``: every folder a Studio
    build ever wrote a session into. Read raw (not via build_sessions, which pulls in
    the config and worklist modules; qemu_tests and the runner stay import-light).
    Unreadable records are skipped: build_sessions.scan surfaces those already."""
    rec_dir = os.path.join(state_dir(), _RECORDS_SUBDIR)
    try:
        names = sorted(os.listdir(rec_dir), reverse=True)
    except OSError:
        return []
    out: list[str] = []
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(rec_dir, name), encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            continue
        workdir = data.get("workdir") if isinstance(data, dict) else None
        if isinstance(workdir, str) and workdir and os.path.isabs(workdir):
            root = root_of(workdir)
            if root:
                out.append(root)
    return out


# ── the reader API ───────────────────────────────────────────────────────────────────
def roots(generator_dir: str = "", extra=()) -> list[str]:
    """Every output root that exists right now, de-duplicated, in lookup order:

    1. ``<generator>/out`` (the builders' default);
    2. ``extra`` — the live config's output folder, which a page passes in so a
       folder chosen a moment ago is searched before any build has recorded it;
    3. the registry (newest first);
    4. roots derived from the session records.

    Reads only; never writes. Roots that do not exist are left out, so a vanished
    folder is never scanned and never errors, and is listed again when it returns
    (its registry entry is kept: see "ABSENCE IS NOT DELETION").
    """
    candidates: list[str] = []
    if generator_dir:
        candidates.append(os.path.join(os.path.abspath(generator_dir), "out"))
    candidates += [e for e in (extra or ()) if e]
    candidates += registered_roots()
    candidates += _roots_from_records()

    seen: set[str] = set()
    result: list[str] = []
    for cand in candidates:
        if not isinstance(cand, str) or not cand:
            continue
        key = _key(cand)
        if key in seen:
            continue
        seen.add(key)
        if os.path.isdir(cand):
            result.append(os.path.abspath(cand))
    return result


def sessions_dirs(generator_dir: str = "", extra=()) -> list[str]:
    """``<root>/sessions`` for every :func:`roots` entry that has one."""
    dirs = [os.path.join(r, SESSIONS_NAME) for r in roots(generator_dir, extra)]
    return [d for d in dirs if os.path.isdir(d)]


def find_session_dir(generator_dir: str, name: str, extra=()) -> str:
    """The folder of the session called ``name`` in any known root, or "".

    First root wins (the order of :func:`roots`). Session ids carry a timestamp and
    random hex, so two roots holding the same id is a copy, not a collision."""
    if not is_session_name(name):
        return ""
    for sdir in sessions_dirs(generator_dir, extra):
        cand = os.path.join(sdir, name)
        if os.path.isdir(cand):
            return cand
    return ""


# ── CLI (what tests/qemu/run-qemu-docker.sh calls) ───────────────────────────────────
def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="python -m hugmesh_studio.core.session_locations",
        description="Print the folders that can hold build sessions (one per line).")
    p.add_argument("what", choices=("roots", "sessions-dirs", "find"),
                   help="roots: output folders; sessions-dirs: their sessions/ "
                        "children; find: the folder of the session NAME")
    p.add_argument("name", nargs="?", default="", help="find: the session name")
    p.add_argument("--generator-dir", default="",
                   help="the hugmesh-generator checkout (its out/ is searched first)")
    p.add_argument("--extra", action="append", default=[],
                   help="another output folder to search; repeatable")
    args = p.parse_args(argv)
    try:
        if args.what == "roots":
            lines = roots(args.generator_dir, args.extra)
        elif args.what == "sessions-dirs":
            lines = sessions_dirs(args.generator_dir, args.extra)
        else:
            hit = find_session_dir(args.generator_dir, args.name, args.extra)
            lines = [hit] if hit else []
    except RuntimeError as exc:          # state_paths' pytest guard
        print(exc, file=sys.stderr)
        return 2
    for line in lines:
        print(line)
    return 0 if lines or args.what != "find" else 1


if __name__ == "__main__":     # pragma: no cover - exercised by the runner's tests
    from .entry import bootstrap as _bootstrap   # the Mac PATH hook: core/entry.py
    _bootstrap()
    sys.exit(main())
