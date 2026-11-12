#!/usr/bin/env python3
"""Check a frozen ``HugMesh Image Studio.app`` before it is put in a .dmg.

    python packaging/check_macos_bundle.py "dist/HugMesh Image Studio.app" \\
        --version 0.4.4-beta.1 --arch arm64

Stdlib only, and it never executes the bundle, so every check can be proven on Linux
against a synthetic tree (tests/test_macos_packaging.py turns each one red in turn).
build-macos-app.sh runs it after PyInstaller and before codesign/hdiutil, and the
smoke runs that follow it are what prove the bundle STARTS. What this proves is that
it is the bundle we meant to build:

  * Contents/Info.plist parses and names the identifier, the executable, the minimum
    macOS, the icon and both version strings the spec writes;
  * the executable is there, is executable, and is a Mach-O for the architecture the
    build was for (an x86_64 bundle from an Apple-silicon runner would start under
    Rosetta and look fine, and then every arm64 user would run it emulated);
  * Qt's cocoa platform plugin is inside (without it the app dies at QApplication with
    "Could not find the Qt platform plugin", and --print-specs never gets that far);
  * every ``[tool.setuptools.package-data]`` file is inside (the spec's own list, read
    from pyproject.toml exactly as the spec reads it);
  * no second Qt binding was frozen (PyQt5/PyQt6 are GPL; the bundle ships PySide6).

With ``--self-check-report FILE --exit-code N [--require-gnu 1]`` it instead reads the
``--self-check --json`` report the frozen app wrote under Finder's environment and checks
that it said the right thing about the Mac it ran on (:func:`verify_self_check`).

Exit 0 when every check passes, 1 when any fails (each failure on its own line), 2 on
a usage error.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import plistlib
import struct
import sys

BUNDLE_ID = "org.hugmesh.ImageStudio"
EXECUTABLE = "hugmesh-studio"
MACOS_MINIMUM = "13.0"

#: Mach-O magic numbers (big-endian reads of the first four bytes).
_MH_MAGIC_64 = 0xFEEDFACF        # thin 64-bit, stored little-endian -> reads CFFAEDFE
_FAT_MAGIC = 0xCAFEBABE
_FAT_MAGIC_64 = 0xCAFEBABF
#: cputype values from <mach/machine.h>
CPU_TYPES = {"x86_64": 0x01000007, "arm64": 0x0100000C}

STUDIO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def macho_archs(path: str) -> set[str]:
    """The architectures a Mach-O file carries: one for a thin binary, each slice of a
    universal ("fat") one. Empty for anything that is not Mach-O."""
    names = {v: k for k, v in CPU_TYPES.items()}
    try:
        with open(path, "rb") as fh:
            head = fh.read(8)
            if len(head) < 8:
                return set()
            (be,) = struct.unpack(">I", head[:4])
            if be in (_FAT_MAGIC, _FAT_MAGIC_64):
                (count,) = struct.unpack(">I", head[4:8])
                size = 20 if be == _FAT_MAGIC else 32
                found = set()
                for _ in range(min(count, 16)):
                    entry = fh.read(size)
                    if len(entry) < size:
                        break
                    (cpu,) = struct.unpack(">I", entry[:4])
                    found.add(names.get(cpu, hex(cpu)))
                return found
            (le,) = struct.unpack("<I", head[:4])
            if le == _MH_MAGIC_64:
                (cpu,) = struct.unpack("<I", head[4:8])
                return {names.get(cpu, hex(cpu))}
    except OSError:
        return set()
    return set()


def package_data(studio_dir: str = STUDIO_DIR) -> list[str]:
    """Every package-data file the wheel (and the spec) ships, as a path relative to
    the studio directory, e.g. ``hugmesh_studio/core/progress-tables.json``."""
    import tomllib
    with open(os.path.join(studio_dir, "pyproject.toml"), "rb") as fh:
        table = tomllib.load(fh)["tool"]["setuptools"]["package-data"]
    out = []
    for package, patterns in sorted(table.items()):
        package_dir = os.path.join(studio_dir, *package.split("."))
        for pattern in patterns:
            for hit in sorted(glob.glob(os.path.join(package_dir, pattern))):
                out.append(os.path.relpath(hit, studio_dir).replace(os.sep, "/"))
    return out


def check(app: str, *, version: str = "", arch: str = "",
          studio_dir: str = STUDIO_DIR) -> list[str]:
    """Every problem with the bundle at ``app``, one sentence each; [] when it is good."""
    problems: list[str] = []
    contents = os.path.join(app, "Contents")
    plist_path = os.path.join(contents, "Info.plist")
    try:
        with open(plist_path, "rb") as fh:
            info = plistlib.load(fh)
    except (OSError, plistlib.InvalidFileException, ValueError) as exc:
        return [f"Info.plist: cannot be read ({exc})"]
    if not isinstance(info, dict):
        return ["Info.plist: is not a dictionary"]

    def want(key, expected):
        if info.get(key) != expected:
            problems.append(f"Info.plist: {key} is {info.get(key)!r}, expected {expected!r}")

    want("CFBundleIdentifier", BUNDLE_ID)
    want("CFBundleExecutable", EXECUTABLE)
    want("CFBundlePackageType", "APPL")
    want("LSMinimumSystemVersion", MACOS_MINIMUM)
    if info.get("NSHighResolutionCapable") is not True:
        problems.append("Info.plist: NSHighResolutionCapable is not true (blurry on Retina)")
    if version:
        want("CFBundleShortVersionString", version.split("-", 1)[0])
        want("HugMeshStudioVersion", version)

    icon = info.get("CFBundleIconFile") or ""
    if not icon:
        problems.append("Info.plist: no CFBundleIconFile (the app would show the generic icon)")
    else:
        name = icon if icon.endswith(".icns") else icon + ".icns"
        if not os.path.isfile(os.path.join(contents, "Resources", name)):
            problems.append(f"Contents/Resources/{name} (CFBundleIconFile) is missing")

    exe = os.path.join(contents, "MacOS", EXECUTABLE)
    if not os.path.isfile(exe):
        problems.append(f"Contents/MacOS/{EXECUTABLE} is missing")
    else:
        if not os.access(exe, os.X_OK):
            problems.append(f"Contents/MacOS/{EXECUTABLE} is not executable")
        found = macho_archs(exe)
        if not found:
            problems.append(f"Contents/MacOS/{EXECUTABLE} is not a Mach-O executable")
        elif arch and arch not in found:
            problems.append(f"Contents/MacOS/{EXECUTABLE} is built for "
                            f"{', '.join(sorted(found))}, not {arch}")

    cocoa = glob.glob(os.path.join(contents, "**", "platforms", "libqcocoa.dylib"),
                      recursive=True)
    if not cocoa:
        problems.append("Qt's cocoa platform plugin (platforms/libqcocoa.dylib) is not in "
                        "the bundle: QApplication cannot start without it")

    # PyInstaller 6 puts data files under Contents/Resources and links them into
    # Contents/Frameworks (sys._MEIPASS); either place counts.
    for rel in package_data(studio_dir):
        if not any(os.path.isfile(os.path.join(contents, where, rel))
                   for where in ("Resources", "Frameworks")):
            problems.append(f"{rel} (package-data) is not in the bundle")

    for binding in ("PyQt5", "PyQt6", "PySide2"):
        if any(os.path.isdir(os.path.join(contents, where, binding))
               for where in ("Resources", "Frameworks")):
            problems.append(f"{binding} was frozen into the bundle; it must ship PySide6 only")
    return problems


def verify_self_check(report, rc: int, require_gnu: bool = False) -> list[str]:
    """Problems with what ``--self-check --json`` said on a Mac; [] when it was right.

    * it ran the macOS checks at all (a frozen app taking the Linux branch would not);
    * with ``require_gnu`` (Homebrew's GNU tools installed): it found them THROUGH ITS
      OWN PATH HOOK, since the smoke runs with launchd's PATH, and passed;
    * without: when tools are missing it must exit 1 and name the brew line, and when
      none are it must pass."""
    if not isinstance(report, dict):
        return ["the self-check wrote no JSON report"]
    mac = report.get("macos")
    if not isinstance(mac, dict):
        return ["the self-check ran no macOS checks (it took the Linux branch)"]
    problems: list[str] = []
    if mac.get("arch") not in CPU_TYPES:
        problems.append(f"the self-check's macOS arch is {mac.get('arch')!r}")
    missing = mac.get("gnu_missing")
    if not isinstance(missing, list):
        return problems + ["the self-check's macOS section has no gnu_missing list"]
    said = "\n".join(report.get("problems") or [])
    if require_gnu:
        if missing:
            problems.append(f"the GNU userland is installed but the app, started with "
                            f"launchd's PATH, did not find: {', '.join(missing)} "
                            f"(core/macos_host.install did not put Homebrew on PATH)")
        if (mac.get("bash_major") or 0) < 4:
            problems.append(f"the app found bash {mac.get('bash_major')}, not 4 or newer")
        if rc != 0 or report.get("ok") is not True:
            problems.append(f"the self-check failed (exit {rc}): {said[:400]}")
    elif missing:
        if rc != 1 or "brew install" not in said:
            problems.append(f"GNU tools are missing ({', '.join(missing)}) but the "
                            f"self-check exited {rc} without the brew line")
    elif rc != 0:
        problems.append(f"the self-check failed (exit {rc}): {said[:400]}")
    return problems


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("app", nargs="?", help="path to the .app")
    ap.add_argument("--version", default="", help="the Studio version it must carry")
    ap.add_argument("--arch", default="", choices=["", *CPU_TYPES],
                    help="the architecture its executable must contain")
    ap.add_argument("--self-check-report", default="",
                    help="instead: a --self-check --json report to verify")
    ap.add_argument("--exit-code", type=int, default=0,
                    help="the exit code the self-check returned")
    ap.add_argument("--require-gnu", default="0", choices=["0", "1"],
                    help="1: the GNU userland must have been found")
    args = ap.parse_args(argv)
    if args.self_check_report:
        try:
            with open(args.self_check_report, encoding="utf-8") as fh:
                report = json.load(fh)
        except (OSError, ValueError) as exc:
            report = None
            print(f"cannot read {args.self_check_report}: {exc}")
        problems = verify_self_check(report, args.exit_code, args.require_gnu == "1")
        if isinstance(report, dict) and isinstance(report.get("macos"), dict):
            print("self-check macos: " + json.dumps(report["macos"], sort_keys=True))
        for problem in problems:
            print(f"FAIL: {problem}")
        print("self-check OK" if not problems else f"{len(problems)} problem(s)")
        return 1 if problems else 0
    if not args.app:
        ap.error("the path to the .app is required")
    if not os.path.isdir(args.app):
        print(f"check_macos_bundle.py: {args.app} is not a directory", file=sys.stderr)
        return 2
    problems = check(args.app, version=args.version, arch=args.arch)
    for problem in problems:
        print(f"FAIL: {problem}")
    print("bundle OK" if not problems else f"{len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
