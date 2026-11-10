"""The hugmesh-generator copy an installed Studio carries (Qt-free, stdlib only).

The Studio runs a hugmesh-generator checkout's scripts (the ten builders, scripts/,
specs/, tests/qemu/, tests/stack/, the Makefile). Until 0.4.1 the Flatpak shipped none
of them: a fresh install opened on "<home> is not a hugmesh-generator checkout", and an
operator without a clone had nothing to point it at.

The bundle now carries the generator tree at its own release tag as a SEED:
``<prefix>/share/hugmesh-studio/generator-seed.tar.gz`` plus ``generator-seed.json``
(version, commit, and the sha256 of every file), written by
``studio/packaging/make_generator_seed.py`` from ``git archive``.

The seed cannot be USED where it is installed. /app is read-only inside the sandbox and
does not exist on the host, and both the Studio's writes (out/, keys-out/,
tests/stack/.env and the other files it keeps inside the tree) and its host commands
(``docker run -v <generator_dir>:/src``, scripts run through flatpak-spawn --host) need
a real, writable host path. So :func:`ensure` places it, once per release, in ONE
directory under the real home:

    ~/.local/share/hugmesh-studio/generator

resolved with ``os.path.expanduser`` and never ``$XDG_DATA_HOME``: the Flatpak points
that at ~/.var/app/org.hugmesh.ImageStudio/data, which a Studio run from a checkout would
never look at (the "sessions don't appear" split). The same path is the same file inside
the sandbox and on the host, because --filesystem=host binds the home at its real path.

An upgrade overwrites the files the old seed listed and the new one lists, deletes the
ones only the old seed listed, and never touches a file no seed listed: the operator's
out/, keys-out/, tests/stack/.env and the like survive every upgrade. The new files are
extracted into a temporary sibling, checked against their sha256 and only then moved
into place; the record of what is installed (``.studio-managed.json``) is written last,
so an interrupted upgrade is simply done again at the next start.

An operator's own clone always wins: ``core/generator_dir.resolve`` consults this copy
only after ``$HUGMESH_GENERATOR_DIR``, the source tree, the working directory and the
folder last picked in the GUI.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import tarfile
import tempfile
from dataclasses import dataclass

from . import state_paths

#: The seed's file names, as the manifest installs them.
SEED_ARCHIVE = "generator-seed.tar.gz"
SEED_META = "generator-seed.json"

#: Where an install keeps the seed, under its prefix (/app in the Flatpak).
SEED_SUBDIR = os.path.join("share", "hugmesh-studio")

#: A directory holding the two seed files, for other packagings and for tests.
SEED_ENV = "HUGMESH_STUDIO_GENERATOR_SEED"

#: Where the managed copy goes. Set it and nothing else matters (tests set it).
TARGET_ENV = "HUGMESH_STUDIO_MANAGED_GENERATOR_DIR"

#: The record of what the managed copy holds, inside it.
RECORD = ".studio-managed.json"


@dataclass
class Placed:
    """What :func:`ensure` did. ``path`` is "" when there is no usable copy."""
    path: str = ""
    action: str = ""        # "current" | "seeded" | "upgraded" | "" (failed / no seed)
    version: str = ""
    error: str = ""


#: The last :func:`ensure` result, for messages shown after resolve() ran.
last: Placed = Placed()


def seed_dir() -> str:
    """The directory holding this install's seed, "" when it carries none."""
    candidates = [os.environ.get(SEED_ENV, "").strip()]
    candidates.append(os.path.join(sys.prefix, SEED_SUBDIR))
    for candidate in candidates:
        if candidate and os.path.isfile(os.path.join(candidate, SEED_ARCHIVE)) \
                and os.path.isfile(os.path.join(candidate, SEED_META)):
            return candidate
    return ""


def target_dir() -> str:
    """``~/.local/share/hugmesh-studio/generator`` (never via $XDG_DATA_HOME)."""
    override = os.environ.get(TARGET_ENV, "").strip()
    if override:
        return os.path.abspath(override)
    if state_paths.under_pytest() and os.environ.get(state_paths.ALLOW_HOME_ENV) != "1":
        raise RuntimeError(
            f"refusing the managed generator copy under the real home during pytest; set "
            f"{TARGET_ENV}")
    return os.path.join(os.path.expanduser("~"), ".local", "share", "hugmesh-studio",
                        "generator")


def read_json(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def seed_meta(directory: str | None = None) -> dict:
    directory = seed_dir() if directory is None else directory
    return read_json(os.path.join(directory, SEED_META)) if directory else {}


def _free_space(path: str) -> str:
    probe = path
    while probe and not os.path.isdir(probe):
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    try:
        usage = shutil.disk_usage(probe or "/")
    except OSError:
        return "unknown"
    return f"{usage.free / (1 << 30):.1f} GiB"


def _safe_member(name: str) -> bool:
    if not name or name.startswith("/") or "\\" in name:
        return False
    return ".." not in name.split("/")


def _sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _is_current(target: str, meta: dict) -> bool:
    record = read_json(os.path.join(target, RECORD))
    if not record or record.get("commit") != meta.get("commit") \
            or record.get("version") != meta.get("version"):
        return False
    files = record.get("files") or {}
    return bool(files) and all(os.path.isfile(os.path.join(target, rel)) for rel in files)


def _extract(archive: str, staging: str, wanted: dict) -> None:
    with tarfile.open(archive, "r:*") as tar:
        for member in tar.getmembers():
            if not _safe_member(member.name):
                raise ValueError(f"the seed holds an unsafe path: {member.name!r}")
            if member.isdir():
                continue
            if not member.isfile():
                # git archive of this repo holds no symlinks (pinned by the seed test);
                # one appearing later must not be followed out of the tree.
                raise ValueError(f"the seed holds a non-file entry: {member.name!r}")
            if member.name not in wanted:
                raise ValueError(f"the seed holds {member.name!r}, which its manifest "
                                 "does not list")
            dest = os.path.join(staging, member.name)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            source = tar.extractfile(member)
            if source is None:
                raise ValueError(f"cannot read {member.name!r} from the seed")
            with source, open(dest, "wb") as out:
                shutil.copyfileobj(source, out)
            os.chmod(dest, 0o755 if member.mode & 0o111 else 0o644)
    for rel, digest in wanted.items():
        path = os.path.join(staging, rel)
        if not os.path.isfile(path):
            raise ValueError(f"the seed is missing {rel}, which its manifest lists")
        if _sha256(path) != digest:
            raise ValueError(f"{rel} in the seed does not match its sha256")


def _remove_empty_parents(target: str, rel: str) -> None:
    parent = os.path.dirname(rel)
    while parent:
        try:
            os.rmdir(os.path.join(target, parent))
        except OSError:
            return
        parent = os.path.dirname(parent)


def _lock(target: str):
    lock_path = os.path.join(os.path.dirname(target), ".generator.lock")
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    fh = open(lock_path, "a+")
    try:
        import fcntl
        fcntl.flock(fh, fcntl.LOCK_EX)
    except (ImportError, OSError):
        pass
    return fh


def ensure(seed: str | None = None, target: str | None = None) -> Placed:
    """Place (or upgrade) the managed copy from the seed. Never raises."""
    global last
    seed = seed_dir() if seed is None else seed
    if not seed:
        last = Placed()
        return last
    meta = seed_meta(seed)
    version = str(meta.get("version", ""))
    try:
        target = target_dir() if target is None else target
    except RuntimeError as exc:
        last = Placed(version=version, error=str(exc))
        return last
    wanted = meta.get("files")
    if not isinstance(wanted, dict) or not wanted:
        last = Placed(version=version,
                      error=f"{os.path.join(seed, SEED_META)} lists no files")
        return last
    staging = ""
    try:
        if _is_current(target, meta):
            last = Placed(path=target, action="current", version=version)
            return last
        with _lock(target):
            if _is_current(target, meta):      # another Studio placed it meanwhile
                last = Placed(path=target, action="current", version=version)
                return last
            os.makedirs(target, exist_ok=True)
            old = read_json(os.path.join(target, RECORD)).get("files") or {}
            staging = tempfile.mkdtemp(prefix=".generator-staging-",
                                       dir=os.path.dirname(target))
            _extract(os.path.join(seed, SEED_ARCHIVE), staging, wanted)
            for rel in wanted:
                dest = os.path.join(target, rel)
                if os.path.isdir(dest) and not os.path.islink(dest):
                    raise IsADirectoryError(f"{dest} is a folder, and this release has a "
                                            "file there")
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                os.replace(os.path.join(staging, rel), dest)
            for rel in old:
                if rel not in wanted and _safe_member(rel):
                    try:
                        os.unlink(os.path.join(target, rel))
                    except FileNotFoundError:
                        pass
                    _remove_empty_parents(target, rel)
            record = {k: meta.get(k) for k in ("version", "commit", "dirty") if k in meta}
            record["files"] = wanted
            tmp_record = os.path.join(target, RECORD + ".partial")
            with open(tmp_record, "w", encoding="utf-8") as fh:
                json.dump(record, fh, indent=1, sort_keys=True)
            os.replace(tmp_record, os.path.join(target, RECORD))
        last = Placed(path=target, action="upgraded" if old else "seeded", version=version)
        return last
    except (OSError, ValueError, tarfile.TarError) as exc:
        where = getattr(exc, "filename", None) or target
        last = Placed(version=version, error=(
            f"could not place the hugmesh-generator copy that came with this Studio in "
            f"{target}: {exc} (at {where}; {_free_space(target)} free there)"))
        return last
    finally:
        if staging:
            shutil.rmtree(staging, ignore_errors=True)


def describe(placed: Placed | None = None) -> str:
    placed = last if placed is None else placed
    if placed.error:
        return placed.error
    if placed.path:
        return (f"hugmesh-generator {placed.version or '(unknown version)'}, the copy that "
                f"came with this Studio, in {placed.path}")
    return ""
