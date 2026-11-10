#!/usr/bin/env python3
"""The Studio release version: ONE place that spells the rules, used by three callers.

    release_version.py current                         -> 0.3.0-beta.1
    release_version.py next                            -> 0.3.0-beta.2
    release_version.py next --final                    -> 0.3.0
    release_version.py next --minor                    -> 0.4.0-beta.1
    release_version.py next --minor --final            -> 0.4.0
    release_version.py next --major                    -> 1.0.0-beta.1
    release_version.py resolve next-minor --main 0.3.0-beta.1 --after-tags refs/tags/studio-v0.3.0-beta.1
                                                       -> 0.4.0-beta.1
    release_version.py newest refs/tags/studio-v0.3.0 refs/tags/studio-v0.3.0-beta.9  -> 0.3.0
    release_version.py validate 0.3.0-beta.2           (format + MSI mapping; exit 1 if bad)
    release_version.py validate 0.3.0-beta.2 --after-tags refs/tags/studio-v0.3.0-beta.1
    release_version.py compare 0.3.0-beta.1 0.3.0      -> lt | eq | gt
    release_version.py bump 0.3.0-beta.2 [--date YYYY-MM-DD] [--root DIR]

The three callers are scripts/release-studio.sh (the operator's terminal),
.github/workflows/studio-release-cut.yml (the "Cut a Studio release" button) and the
guard tests under studio/tests. They all call this file, so no two of them can spell
the version rules differently.

THE RULES. A version is MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-beta.N (N >= 1). It
must also survive packaging/wix/msi_version.py, which refuses -rc, -SNAPSHOT, +build,
beta.0 and anything an MSI ProductVersion cannot order. The ordering key is

    (major, minor, patch, 1 if final else 0, N)

so 0.3.0-beta.1 < 0.3.0-beta.2 < 0.3.0 < 0.3.1-beta.1. A new release must sort
strictly after every studio-v* tag that already exists.

`bump` edits the two files that carry the version: `__version__` in
hugmesh_studio/__init__.py and the newest <release> in the Flatpak's AppStream
metainfo (AppStream spells a pre-release with "~": 0.3.0~beta.2, so it sorts below its
final). It is idempotent: a tree already at the version is left as it is. The
metainfo edit is a text insertion that keeps the existing comment and entries, and
the result must still parse as XML. Stdlib only: this runs on a bare GitHub runner.
"""
from __future__ import annotations

import argparse
import datetime
import importlib.util
import os
import re
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
STUDIO_ROOT = os.path.dirname(HERE)
GENERATOR_ROOT = os.path.dirname(STUDIO_ROOT)

VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-beta\.([1-9]\d*))?$")
TAG_PREFIX = "studio-v"

INIT_REL = os.path.join("studio", "hugmesh_studio", "__init__.py")
METAINFO_REL = os.path.join("studio", "packaging", "flatpak", "org.hugmesh.ImageStudio.metainfo.xml")


class VersionError(ValueError):
    pass


def _msi_mapper():
    path = os.path.join(HERE, "wix", "msi_version.py")
    spec = importlib.util.spec_from_file_location("msi_version", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse(version: str) -> tuple[int, int, int, int, int]:
    """The ordering key, or VersionError. Also runs the MSI mapping, so anything the
    installer could not carry is refused here first."""
    version = version.strip()
    match = VERSION_RE.match(version)
    if not match:
        raise VersionError(
            f"{version!r} is not MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-beta.N "
            "(no -rc, no -SNAPSHOT, no +build, no beta.0)")
    try:
        _msi_mapper().msi_version(version)
    except ValueError as exc:
        raise VersionError(f"{version!r}: the MSI ProductVersion mapping refuses it: {exc}") from exc
    major, minor, patch = (int(match.group(i)) for i in (1, 2, 3))
    beta = match.group(4)
    return (major, minor, patch, 0 if beta else 1, int(beta) if beta else 0)


def compare(a: str, b: str) -> int:
    ka, kb = parse(a), parse(b)
    return (ka > kb) - (ka < kb)


def is_final(version: str) -> bool:
    return parse(version)[3] == 1


def appstream(version: str) -> str:
    parse(version)
    return version.replace("-", "~", 1)


def tag_versions(refs: list[str]) -> list[str]:
    """studio-v* tag refs (bare names or refs/tags/... forms) -> their versions.
    A tag that is not a valid version is ignored: it cannot be ordered, and it was
    never produced by this tooling."""
    out = []
    for ref in refs:
        name = ref.strip()
        if name.startswith("refs/tags/"):
            name = name[len("refs/tags/"):]
        if not name.startswith(TAG_PREFIX):
            continue
        candidate = name[len(TAG_PREFIX):]
        try:
            parse(candidate)
        except VersionError:
            continue
        out.append(candidate)
    return out


def newest(versions: list[str]) -> str | None:
    return max(versions, key=parse) if versions else None


def validate(version: str, after_tags: list[str] | None = None) -> None:
    parse(version)
    if after_tags:
        top = newest(tag_versions(after_tags))
        if top is not None and compare(version, top) <= 0:
            raise VersionError(
                f"{version} does not sort strictly after the newest existing tag "
                f"{TAG_PREFIX}{top}; choose a later version")


# ── the two files that carry the version ───────────────────────────────────────────
def _read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def _write(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def current(root: str = GENERATOR_ROOT) -> str:
    text = _read(os.path.join(root, INIT_REL))
    match = re.search(r'(?m)^__version__ = "([^"]+)"$', text)
    if not match:
        raise VersionError(f"no __version__ line in {INIT_REL}")
    return match.group(1)


def next_version(base: str | None = None, final: bool = False, root: str = GENERATOR_ROOT,
                 minor: bool = False, major: bool = False) -> str:
    """The next version after `base` (default: the tree's __version__).

    plain:            the next beta of the same base (0.3.0-beta.1 -> 0.3.0-beta.2); after a
                      final, the next PATCH's beta.1 (0.3.0 -> 0.3.1-beta.1)
    --final:          the base itself (0.3.0-beta.4 -> 0.3.0); refused on a final
    --minor:          the next MINOR's beta.1 (0.3.0-beta.4 or 0.3.2 -> 0.4.0-beta.1)
    --major:          the next MAJOR's beta.1 (0.3.0-beta.4 -> 1.0.0-beta.1)
    --minor/--major --final: that MINOR/MAJOR's final, with no beta before it (0.4.0, 1.0.0)

    Nothing here knows which version is "current" in the world; it only counts. The
    result goes through parse(), so a number the MSI cannot carry is refused here."""
    if minor and major:
        raise VersionError("--minor and --major are mutually exclusive")
    version = base or current(root)
    ma, mi, pa, fin, n = parse(version)
    if major or minor:
        triple = f"{ma + 1}.0.0" if major else f"{ma}.{mi + 1}.0"
        result = triple if final else f"{triple}-beta.1"
    elif final:
        if fin:
            raise VersionError(f"{version} is already a final release")
        result = f"{ma}.{mi}.{pa}"
    elif fin:
        result = f"{ma}.{mi}.{pa + 1}-beta.1"
    else:
        result = f"{ma}.{mi}.{pa}-beta.{n + 1}"
    parse(result)
    return result


# The words scripts/release-studio.sh (and scripts/release.sh) accept in place of a number.
KEYWORDS = {"next": None, "next-beta": None, "next-minor": "minor", "next-major": "major"}


def resolve(spec: str, final: bool = False, main: str | None = None, tags: list[str] | None = None) -> str:
    """A version, or a keyword (next, next-beta, next-minor, next-major), resolved to the
    number to release on a channel (beta, or stable with final=True).

    A keyword counts from the newest studio-v* TAG, i.e. what was already released, not
    from a checkout that may be stale. One exception: main's __version__ is PENDING when
    it sorts after every tag (bumped, never released; 567a5a60 was one). When the
    keyword would not get past it, the pending version is released (or its final, on
    the stable channel) instead of a number main is already later than.

    An explicit version must match the channel: a beta is refused on stable, and a
    final X.Y.Z is refused on beta, because a final publishes as the LATEST release and
    is the one typo nobody can take back."""
    spec = spec.strip()
    if spec in KEYWORDS:
        kind = KEYWORDS[spec]
        top = newest(tag_versions(tags or []))
        if main is not None:
            parse(main)
        if top is None and main is None:
            raise VersionError(f"{spec}: there is no studio-v* tag and no main version to count from")
        candidate = None
        if top is not None:
            try:
                candidate = next_version(top, final=final, minor=kind == "minor", major=kind == "major")
            except VersionError as exc:
                if main is None or compare(main, top) <= 0:
                    raise VersionError(
                        f"{spec} on the {'stable' if final else 'beta'} channel: {exc} "
                        f"(newest tag {TAG_PREFIX}{top}); name the version, or use next-minor") from exc
        pending = main is not None and (top is None or compare(main, top) > 0)
        if pending and (candidate is None or compare(candidate, main) <= 0):
            if is_final(main) == final and (kind is None or top is not None):
                return main
            return next_version(main, final=final, minor=top is None and kind == "minor",
                                major=top is None and kind == "major")
        return candidate
    parse(spec)
    if final and not is_final(spec):
        raise VersionError(f"{spec} is a beta; the stable channel (--final) releases MAJOR.MINOR.PATCH only")
    if not final and is_final(spec):
        raise VersionError(
            f"{spec} is a final release, which publishes as the LATEST release; "
            "say so with --final (or --channel stable)")
    return spec


def _release_entry(version: str, date: str, indent: str) -> str:
    kind = "" if is_final(version) else ' type="development"'
    what = f"Studio {version}"
    lines = [
        f'{indent}<release version="{appstream(version)}" date="{date}"{kind}>',
        f"{indent}  <description>",
        f"{indent}    <p>{what}. See the GitHub release notes for what changed.</p>",
        f"{indent}  </description>",
        f"{indent}</release>",
    ]
    return "\n".join(lines) + "\n"


def bump(version: str, date: str | None = None, root: str = GENERATOR_ROOT) -> list[str]:
    """Set the tree to `version`. Returns the files it changed (none when already there).
    A bump BACKWARDS is refused: it would rewrite __version__ while the metainfo keeps
    the newer entry first, and the two files would disagree silently."""
    parse(version)
    before = current(root)
    if compare(version, before) < 0:
        raise VersionError(f"the tree is at {before}, which is later than {version}; a version never goes backwards")
    date = date or datetime.date.today().isoformat()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        raise VersionError(f"--date must be YYYY-MM-DD, not {date!r}")
    changed: list[str] = []

    init_path = os.path.join(root, INIT_REL)
    text = _read(init_path)
    new_text, count = re.subn(r'(?m)^__version__ = "[^"]+"$', f'__version__ = "{version}"', text)
    if count != 1:
        raise VersionError(f"expected exactly one __version__ line in {INIT_REL}, found {count}")
    if new_text != text:
        _write(init_path, new_text)
        changed.append(INIT_REL)

    meta_path = os.path.join(root, METAINFO_REL)
    meta = _read(meta_path)
    if f'<release version="{appstream(version)}"' not in meta:
        match = re.search(r"(?m)^([ \t]*)<release\b", meta)
        if not match:
            raise VersionError(f"no <release> entry in {METAINFO_REL} to insert before")
        entry = _release_entry(version, date, match.group(1))
        new_meta = meta[:match.start()] + entry + meta[match.start():]
        root_el = ET.fromstring(new_meta)  # must still be XML, or nothing is written
        first = root_el.find("releases").find("release")
        if first is None or first.get("version") != appstream(version):
            raise VersionError("the inserted <release> is not the first entry; refusing to write")
        _write(meta_path, new_meta)
        changed.append(METAINFO_REL)
    return changed


# ── CLI ────────────────────────────────────────────────────────────────────────────
def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="release_version.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("current", help="print __version__")
    p.add_argument("--root", default=GENERATOR_ROOT)

    p = sub.add_parser("next", help="propose the next version")
    p.add_argument("base", nargs="?")
    p.add_argument("--final", action="store_true", help="a final MAJOR.MINOR.PATCH, not a beta")
    step = p.add_mutually_exclusive_group()
    step.add_argument("--minor", action="store_true", help="the next MINOR (X.Y+1.0)")
    step.add_argument("--major", action="store_true", help="the next MAJOR (X+1.0.0)")
    p.add_argument("--root", default=GENERATOR_ROOT)

    p = sub.add_parser("resolve", help="a version or keyword (next, next-beta, next-minor, next-major) -> the version")
    p.add_argument("spec")
    p.add_argument("--final", action="store_true", help="the stable channel")
    p.add_argument("--main", help="main's __version__ (a keyword never counts from a local checkout)")
    p.add_argument("--after-tags", nargs="*", default=None, help="existing studio-v* tag refs")

    p = sub.add_parser("newest", help="the newest version among studio-v* tag refs (empty when none)")
    p.add_argument("refs", nargs="*")

    p = sub.add_parser("validate", help="exit 0 when the version is releasable")
    p.add_argument("version")
    p.add_argument("--after-tags", nargs="*", default=None,
                   help="existing studio-v* tag refs; the version must sort strictly after the newest")

    p = sub.add_parser("compare", help="print lt, eq or gt")
    p.add_argument("a")
    p.add_argument("b")

    p = sub.add_parser("bump", help="rewrite __init__.py and the metainfo to this version")
    p.add_argument("version")
    p.add_argument("--date")
    p.add_argument("--root", default=GENERATOR_ROOT)

    args = parser.parse_args(argv)
    try:
        if args.cmd == "current":
            print(current(args.root))
        elif args.cmd == "next":
            print(next_version(args.base, args.final, args.root, minor=args.minor, major=args.major))
        elif args.cmd == "resolve":
            print(resolve(args.spec, args.final, args.main, args.after_tags))
        elif args.cmd == "newest":
            print(newest(tag_versions(args.refs)) or "")
        elif args.cmd == "validate":
            validate(args.version, args.after_tags)
            print(f"{args.version} ok (MSI ProductVersion {_msi_mapper().msi_version(args.version)})")
        elif args.cmd == "compare":
            print({-1: "lt", 0: "eq", 1: "gt"}[compare(args.a, args.b)])
        elif args.cmd == "bump":
            changed = bump(args.version, args.date, args.root)
            print("\n".join(changed) if changed else f"already at {args.version}; nothing changed")
    except (VersionError, OSError) as exc:
        print(f"release_version.py: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
