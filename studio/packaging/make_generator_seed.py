#!/usr/bin/env python3
"""Write the hugmesh-generator seed an installed Studio carries (stdlib + git only).

    python3 studio/packaging/make_generator_seed.py --out studio/packaging/flatpak/generator-seed

writes, into ``--out``:

  generator-seed.tar.gz   ``git archive <ref>`` of the whole generator repository,
                          gzip-compressed (mtime 0, so one commit gives one archive)
  generator-seed.json     {"version", "commit", "dirty", "files": {path: sha256}}

The Flatpak manifest installs both into /app/share/hugmesh-studio/, and
``hugmesh_studio/core/managed_generator.py`` places the tree under the real home on the
first start of each release. See that module for why the tree cannot be used from /app.

WHY THE WHOLE TREE. The Studio runs the ten builders, scripts/, specs*/, tests/qemu/,
tests/stack/, tests/e2e/, the Makefile and Dockerfile.build, and those in turn
``source`` and rsync whole directories of each other; an allowlist of the files the
Studio names would miss what the scripts it names read. ``EXCLUDE`` exists so a cut can
be made deliberately, and tests/test_flatpak_generator_seed.py fails when a cut removes
anything the Studio references (it derives that list from the Studio's own source).

WHY git archive. It ships exactly the committed tree: never out/ (which has held 305 GB
of root-owned build artefacts on a developer machine), keys-out/, .stack-src/ or any
other local state, which a ``type: dir`` source at the repository root would copy.
A build from a tree with uncommitted changes still archives the COMMIT, says so on
stderr and records ``"dirty": true``.

Exit codes: 0 written (or already up to date), 1 failed, 2 bad usage.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_REPO = os.path.dirname(os.path.dirname(HERE))

ARCHIVE = "generator-seed.tar.gz"
META = "generator-seed.json"

#: Top-level paths left out of the seed, deliberately. Empty: see the module docstring.
EXCLUDE: tuple[str, ...] = ()

VERSION_FILE = "studio/hugmesh_studio/__init__.py"


class SeedError(RuntimeError):
    pass


def _git(repo: str, *args: str, text: bool = True) -> str | bytes:
    try:
        result = subprocess.run(["git", "-C", repo, *args], capture_output=True,
                                text=text, check=False)
    except OSError as exc:
        raise SeedError(f"git could not be run: {exc}") from exc
    if result.returncode != 0:
        err = result.stderr if text else result.stderr.decode("utf-8", "replace")
        raise SeedError(f"git {' '.join(args)} failed: {err.strip()}")
    return result.stdout


def _excluded(path: str) -> bool:
    return any(path == cut or path.startswith(cut.rstrip("/") + "/") for cut in EXCLUDE)


def seed_files(repo: str = DEFAULT_REPO, ref: str = "HEAD") -> list[str]:
    """Every file the seed holds, in order: the tree of ``ref`` minus ``EXCLUDE``.

    Refuses a symlink or a submodule: the managed copy is extracted file by file and
    does not follow links (core/managed_generator.py)."""
    raw = _git(repo, "ls-tree", "-r", "-z", "--full-tree", ref, text=False)
    files = []
    for entry in raw.split(b"\0"):
        if not entry:
            continue
        info, _, name = entry.partition(b"\t")
        mode, kind, _obj = info.decode().split(" ")
        path = name.decode("utf-8", "surrogateescape")
        if kind != "blob" or mode not in ("100644", "100755"):
            raise SeedError(f"{path} is a {kind} with mode {mode}; the seed holds plain "
                            "files only")
        if not _excluded(path):
            files.append(path)
    return sorted(files)


def seed_version(repo: str = DEFAULT_REPO, ref: str = "HEAD") -> str:
    text = _git(repo, "show", f"{ref}:{VERSION_FILE}")
    match = re.search(r'(?m)^__version__ = "([^"]+)"', text)
    if not match:
        raise SeedError(f"no __version__ in {VERSION_FILE} at {ref}")
    return match.group(1)


def is_up_to_date(out: str, commit: str) -> bool:
    try:
        with open(os.path.join(out, META), encoding="utf-8") as fh:
            meta = json.load(fh)
    except (OSError, ValueError):
        return False
    return (isinstance(meta, dict) and meta.get("commit") == commit
            and os.path.isfile(os.path.join(out, ARCHIVE)))


def make(out: str, repo: str = DEFAULT_REPO, ref: str = "HEAD", force: bool = False,
         log=sys.stderr) -> dict:
    commit = _git(repo, "rev-parse", f"{ref}^{{commit}}").strip()
    if not force and is_up_to_date(out, commit):
        print(f"generator seed for {commit[:12]} is already in {out}", file=log)
        with open(os.path.join(out, META), encoding="utf-8") as fh:
            return json.load(fh)
    version = seed_version(repo, ref)
    wanted = seed_files(repo, ref)
    dirty = False
    if ref == "HEAD":
        dirty = bool(_git(repo, "status", "--porcelain", "--untracked-files=no").strip())
        if dirty:
            print("warning: the working tree has uncommitted changes; the seed holds the "
                  f"COMMIT {commit[:12]}, not them", file=log)
    pathspecs = [f":(exclude){cut}" for cut in EXCLUDE]
    os.makedirs(out, exist_ok=True)
    partial = os.path.join(out, ARCHIVE + ".partial")
    hashes: dict[str, str] = {}
    proc = subprocess.Popen(["git", "-C", repo, "archive", "--format=tar", ref,
                             *(["--", *pathspecs] if pathspecs else [])],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        with open(partial, "wb") as raw_out, \
                gzip.GzipFile(filename="", mode="wb", fileobj=raw_out, mtime=0,
                              compresslevel=6) as gz, \
                tarfile.open(fileobj=gz, mode="w|", format=tarfile.PAX_FORMAT) as tar_out, \
                tarfile.open(fileobj=proc.stdout, mode="r|") as tar_in:
            for member in tar_in:
                if member.isdir():
                    continue
                if member.name == "pax_global_header":
                    continue
                if not member.isfile():
                    raise SeedError(f"git archive wrote a non-file entry {member.name!r}")
                data = tar_in.extractfile(member).read()
                hashes[member.name] = hashlib.sha256(data).hexdigest()
                clean = tarfile.TarInfo(member.name)
                clean.size = len(data)
                clean.mode = 0o755 if member.mode & 0o111 else 0o644
                clean.mtime = member.mtime
                tar_out.addfile(clean, io.BytesIO(data))
    finally:
        stderr = proc.stderr.read().decode("utf-8", "replace") if proc.stderr else ""
        rc = proc.wait()
    if rc != 0:
        os.unlink(partial)
        raise SeedError(f"git archive failed: {stderr.strip()}")
    if sorted(hashes) != wanted:
        os.unlink(partial)
        extra = sorted(set(hashes) - set(wanted))[:5]
        missing = sorted(set(wanted) - set(hashes))[:5]
        raise SeedError(f"git archive and git ls-tree disagree (extra {extra}, missing "
                        f"{missing}); is there an export-ignore attribute?")
    # "top": the REPOSITORY's top level, EXCLUDE included, so --self-check still looks
    # for a path under a directory the seed was cut from (core/self_check.py).
    top = sorted(_git(repo, "ls-tree", "--name-only", ref).split())
    meta = {"version": version, "commit": commit, "dirty": dirty, "top": top,
            "excluded": list(EXCLUDE), "files": hashes}
    meta_partial = os.path.join(out, META + ".partial")
    with open(meta_partial, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.replace(partial, os.path.join(out, ARCHIVE))
    os.replace(meta_partial, os.path.join(out, META))
    size = os.path.getsize(os.path.join(out, ARCHIVE))
    print(f"generator seed {version} ({commit[:12]}{', dirty' if dirty else ''}): "
          f"{len(hashes)} files, {size / 1e6:.1f} MB in {out}", file=log)
    return meta


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    ap.add_argument("--out", required=True, help="directory to write the two seed files to")
    ap.add_argument("--repo", default=DEFAULT_REPO, help="the generator repository")
    ap.add_argument("--ref", default="HEAD", help="the commit to archive (default HEAD)")
    ap.add_argument("--force", action="store_true", help="rewrite an up-to-date seed")
    args = ap.parse_args(argv)
    try:
        make(os.path.abspath(args.out), args.repo, args.ref, force=args.force)
    except (SeedError, OSError, tarfile.TarError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
