#!/usr/bin/env python3
"""Run packaging/gen_icons.py under Wine so the icon's letter is drawn with a real font.

build-msi-wine.sh runs this with the WINDOWS Python, in place of calling gen_icons.py
directly. gen_icons.py itself is not changed and is run as written (``runpy``); this only
sets up the two things Wine does not give it:

  * Qt's ``windows`` platform. gen_icons.py forces ``offscreen``, whose font database is
    empty, so the brand mark's "S" comes out as an empty box (measured under Wine; the same
    plugin is used on Windows, where this was not checked).
  * a default font. The mark is painted with whatever the application font is, and a fresh
    Wine prefix has no "Tahoma" registered (Wine's stand-in for the Windows UI font), so Qt
    picked a thin serif face. Registering Wine's own Tahoma through the registry was tried
    first and did not survive a first run reliably, so the faces are loaded straight from the
    files with QFontDatabase and set as the application font. Nothing in the prefix changes.

    python render_icon_wine.py --out build/icons          # $HUGMESH_ICON_FONT_DIR holds the .ttf files

It must not be used to ship a different icon on Windows: there Segoe UI is the default and
gen_icons.py needs no help beyond not using ``offscreen``.
"""
from __future__ import annotations

import os
import runpy
import sys

FACES = ("tahoma.ttf", "tahomabd.ttf")


def main() -> int:
    font_dir = os.environ.get("HUGMESH_ICON_FONT_DIR", "")
    missing = [f for f in FACES if not os.path.isfile(os.path.join(font_dir, f))]
    if missing:
        print("error: %s not found in HUGMESH_ICON_FONT_DIR=%r" % (", ".join(missing), font_dir),
              file=sys.stderr)
        return 2
    # Before Qt is imported: a platform is chosen when the application object is built.
    os.environ["QT_QPA_PLATFORM"] = "windows"
    from PySide6 import QtGui, QtWidgets

    app = QtWidgets.QApplication([])
    for face in FACES:
        if QtGui.QFontDatabase.addApplicationFont(os.path.join(font_dir, face)) < 0:
            print("error: Qt could not load %s" % face, file=sys.stderr)
            return 3
    app.setFont(QtGui.QFont("Tahoma", 9))
    gen_icons = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "gen_icons.py")
    sys.argv = [gen_icons, *sys.argv[1:]]
    # gen_icons builds `QApplication.instance() or QApplication([])`, so it reuses ours.
    runpy.run_path(gen_icons, run_name="__main__")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
