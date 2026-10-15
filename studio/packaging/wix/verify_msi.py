#!/usr/bin/env python3
"""Check a built HugMesh Image Studio MSI against the tree it was built from.

Nothing here needs Windows. build-msi-wine.sh runs `msiinfo export` and `msiextract`
(msitools, a Linux re-implementation of the MSI/CAB readers, so it is not WiX or Wine
marking their own homework) in a throwaway container and hands the results to this
script, which reads them with the standard library only:

    verify_msi.py --tables DIR --extract DIR --dist DIR --version 1.0.0 \\
                  --package-wxs Package.wxs --icon hugmesh-studio.ico --license LICENSE

  --tables   one `<Table>.idt` per table (msiinfo export), plus `streams.txt` and
             `Icon.AppIcon` (the extracted icon stream)
  --extract  the msiextract output directory
  --dist     the PyInstaller onedir the MSI was built from

Checks (each prints PASS or FAIL; the exit status is 1 if any fails):

  * ProductVersion is the version we meant to ship
  * UpgradeCode is the permanent one written in Package.wxs
  * the package is per-user (no ALLUSERS property)
  * the File table has one row per file in the frozen tree
  * hugmesh-studio.exe is installed at the root of HugMesh\\Image Studio
  * the extracted file list AND every file's SHA-256 equal the frozen tree's
  * the Start Menu shortcut points at that exe
  * the icon stream is the icon we rendered
  * the licence page carries the repository LICENSE text
  * the cabinet is embedded, so the single .msi is the whole installer
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys

EXE = "hugmesh-studio.exe"
INSTALL_PARTS = ("HugMesh", "Image Studio")


def parse_idt(text: str) -> list[dict[str, str]]:
    """Rows of a `msiinfo export` table as dicts keyed by column name. The export is
    tab-separated: names, then types, then `<Table>\\t<keys>`, then the rows."""
    lines = text.split("\n")
    if len(lines) < 3:
        return []
    names = lines[0].split("\t")
    return [dict(zip(names, line.split("\t"))) for line in lines[3:] if line.strip("\r")]


def read_table(tables: str, name: str) -> list[dict[str, str]]:
    path = os.path.join(tables, name + ".idt")
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8", errors="replace") as fh:
        return parse_idt(fh.read())


def sha_tree(root: str) -> dict[str, str]:
    out = {}
    for base, _dirs, files in os.walk(root):
        for name in files:
            full = os.path.join(base, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            with open(full, "rb") as fh:
                out[rel] = hashlib.sha256(fh.read()).hexdigest()
    return out


def find_install_root(extract: str) -> str | None:
    """The folder msiextract put hugmesh-studio.exe in, when it is where the package
    says it installs: .../HugMesh/Image Studio/."""
    hits = []
    for base, _dirs, files in os.walk(extract):
        if EXE in files:
            hits.append(base)
    good = [h for h in hits
            if tuple(h.replace(os.sep, "/").rstrip("/").split("/")[-2:]) == INSTALL_PARTS]
    return good[0] if len(good) == 1 else None


def longest_plain_line(license_text: str) -> str:
    """A run of the licence long enough to be distinctive and free of the characters
    RTF escapes, so it must appear verbatim on the licence page."""
    best = ""
    for line in license_text.splitlines():
        line = line.strip()
        if len(line) > len(best) and not re.search(r"[\\{}]", line) and line.isascii():
            best = line
    return best[:60]


def verify(*, tables: str, extract: str, dist: str, version: str, package_wxs: str,
           icon: str, license_file: str) -> list[tuple[bool, str]]:
    results: list[tuple[bool, str]] = []

    def check(ok: bool, message: str) -> None:
        results.append((bool(ok), message))

    props = {r.get("Property", ""): r.get("Value", "") for r in read_table(tables, "Property")}

    got = props.get("ProductVersion", "<missing>")
    check(got == version, "ProductVersion is %s (want %s)" % (got, version))

    with open(package_wxs, encoding="utf-8") as fh:
        m = re.search(r'UpgradeCode="([0-9A-Fa-f-]{36})"', fh.read())
    want_code = "{%s}" % m.group(1).upper() if m else "<not found in Package.wxs>"
    got_code = props.get("UpgradeCode", "<missing>").upper()
    check(got_code == want_code, "UpgradeCode is %s (Package.wxs says %s)" % (got_code, want_code))

    check("ALLUSERS" not in props, "per-user package: no ALLUSERS property"
          + ("" if "ALLUSERS" not in props else " (ALLUSERS=%s)" % props["ALLUSERS"]))

    dist_files = sha_tree(dist)
    file_rows = read_table(tables, "File")
    check(len(file_rows) == len(dist_files),
          "File table has %d rows for %d files in the frozen tree" % (len(file_rows), len(dist_files)))

    root = find_install_root(extract)
    check(root is not None, "%s is installed under %s" % (EXE, "\\".join(INSTALL_PARTS)))
    installed = sha_tree(root) if root else {}
    missing = sorted(set(dist_files) - set(installed))
    extra = sorted(set(installed) - set(dist_files))
    differ = sorted(k for k in dist_files if k in installed and dist_files[k] != installed[k])
    check(not missing and not extra,
          "the MSI's file list equals the frozen tree's (%d files; missing %d%s, extra %d%s)" % (
              len(dist_files), len(missing), " e.g. " + missing[0] if missing else "",
              len(extra), " e.g. " + extra[0] if extra else ""))
    check(not differ and bool(installed), "every file's SHA-256 matches the frozen tree"
          + ("" if not differ else " (%d differ, e.g. %s)" % (len(differ), differ[0])))
    check(EXE in installed, "%s is in the MSI" % EXE)

    targets = [r.get("Target", "") for r in read_table(tables, "Shortcut")]
    check("[INSTALLFOLDER]" + EXE in targets,
          "a shortcut targets [INSTALLFOLDER]%s (found %s)" % (EXE, targets or "none"))

    streams_path = os.path.join(tables, "streams.txt")
    streams = open(streams_path, encoding="utf-8").read().split() if os.path.isfile(streams_path) else []
    icon_stream = os.path.join(tables, "Icon.AppIcon")
    icon_ok = False
    if "Icon.AppIcon" in streams and os.path.isfile(icon_stream) and os.path.isfile(icon):
        with open(icon_stream, "rb") as a, open(icon, "rb") as b:
            icon_ok = a.read() == b.read()
    check(icon_ok, "the MSI's Icon.AppIcon stream is the rendered .ico")

    with open(license_file, encoding="utf-8", errors="replace") as fh:
        phrase = longest_plain_line(fh.read())
    controls = os.path.join(tables, "Control.idt")
    page = open(controls, encoding="utf-8", errors="replace").read() if os.path.isfile(controls) else ""
    check(bool(phrase) and phrase in page,
          "the licence page carries the LICENSE text (%r)" % phrase[:40])

    media = read_table(tables, "Media")
    check(any(r.get("Cabinet", "").startswith("#") for r in media),
          "the cabinet is embedded in the .msi (Media: %s)" % [r.get("Cabinet") for r in media])
    return results


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--tables", required=True)
    ap.add_argument("--extract", required=True)
    ap.add_argument("--dist", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--package-wxs", required=True)
    ap.add_argument("--icon", required=True)
    ap.add_argument("--license", required=True, dest="license_file")
    args = ap.parse_args(argv)
    results = verify(tables=args.tables, extract=args.extract, dist=args.dist,
                     version=args.version, package_wxs=args.package_wxs, icon=args.icon,
                     license_file=args.license_file)
    for ok, message in results:
        print("%s  %s" % ("PASS" if ok else "FAIL", message))
    failed = sum(1 for ok, _ in results if not ok)
    print("%d check(s), %d failed" % (len(results), failed))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
