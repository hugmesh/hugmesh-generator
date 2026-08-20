#!/usr/bin/env python3
"""Render the Studio's application icon at every size the installers need.

There is no icon FILE in this repository. The Studio's brand mark is painted
procedurally by :func:`hugmesh_studio.gui.branding_icon.brand_pixmap` — a navy rounded
square with a white 'S' — and that painter is the single source of truth for what the
app looks like in the tray. Exporting from it, rather than committing a PNG somebody
drew once, means the installer icon and the tray icon can never drift apart.

Runs headless (``QT_QPA_PLATFORM=offscreen``), so it works on a CI runner with no
display.

    python packaging/gen_icons.py --out build/icons

Writes:
    icon-<n>.png   for n in 16 32 48 64 128 256   (Flatpak hicolor, Linux .desktop)
    hugmesh-studio.ico                            (WiX / Windows shortcut)
    hugmesh-studio.png                            (256px, the canonical single file)

The .ico is assembled with Pillow when it is available. Without Pillow the PNGs are
still written and the .ico is SKIPPED with a clear message rather than a traceback —
the Linux lane does not need it, and failing that lane over a Windows-only asset
would be wrong.
"""
from __future__ import annotations

import argparse
import os
import sys

# Must be set BEFORE Qt is imported: QGuiApplication picks its platform plugin at
# construction and cannot be moved to offscreen afterwards.
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

SIZES = (16, 32, 48, 64, 128, 256)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default="build/icons", help="output directory")
    args = ap.parse_args(argv)

    # Imported after QT_QPA_PLATFORM is set, and after argparse so --help works on a
    # machine with no Qt at all.
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if repo_root not in sys.path:
        sys.path.insert(0, repo_root)

    # `Qt` comes from the shim, not from QtGui: PySide6 re-exports the enum
    # namespace onto QtGui and PyQt6 does not, so QtGui.Qt is an AttributeError
    # on a PyQt6 machine. gui/qt.py already imports Qt from QtCore for both.
    from hugmesh_studio.gui.qt import Qt, QtWidgets
    from hugmesh_studio.gui.branding_icon import brand_pixmap

    # A QGuiApplication is required before any QPixmap is constructed.
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    os.makedirs(args.out, exist_ok=True)
    source = brand_pixmap()
    written: list[str] = []

    for size in SIZES:
        # SmoothTransformation, not the default FastTransformation: the mark is a
        # rounded square with a glyph in it, and nearest-neighbour downscaling to
        # 16px turns the border into a dashed line.
        scaled = source.scaled(
            size, size,
            Qt.AspectRatioMode.KeepAspectRatio,
            Qt.TransformationMode.SmoothTransformation,
        )
        path = os.path.join(args.out, f"icon-{size}.png")
        if not scaled.save(path, "PNG"):
            print(f"error: could not write {path}", file=sys.stderr)
            return 1
        written.append(path)

    canonical = os.path.join(args.out, "hugmesh-studio.png")
    source.scaled(256, 256,
                  Qt.AspectRatioMode.KeepAspectRatio,
                  Qt.TransformationMode.SmoothTransformation).save(canonical, "PNG")
    written.append(canonical)

    ico = os.path.join(args.out, "hugmesh-studio.ico")
    if _write_ico(written, ico, args.out):
        written.append(ico)
    else:
        print("note: Pillow is not installed — skipped the .ico (Windows-only asset)")

    for path in written:
        print(f"  {path}  {os.path.getsize(path)} bytes")
    del app
    return 0


def _write_ico(pngs: list[str], dest: str, out_dir: str) -> bool:
    """Pack the rendered PNGs into a multi-resolution .ico. Windows picks the size it
    needs from inside the file, so all six go in one artefact."""
    try:
        from PIL import Image
    except ImportError:
        return False
    base = Image.open(os.path.join(out_dir, "icon-256.png"))
    base.save(dest, format="ICO", sizes=[(s, s) for s in SIZES])
    return True


if __name__ == "__main__":
    raise SystemExit(main())
