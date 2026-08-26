#!/usr/bin/env python3
"""studio-driver.py — drive the REAL HugMesh Studio wizard headlessly and grab it.

WHY THIS EXISTS. The BDD harness is Node; a QApplication cannot be held in a Node
process. So the `studio` interface shells out to this driver, which builds the
actual ``hugmesh_studio.gui.wizard.StudioWizard`` under ``QT_QPA_PLATFORM=offscreen``
and writes ``QWidget.grab()`` to a PNG. That grab is the studio interface's evidence
— the exact equivalent of the browser interface's screenshot.

IT DRIVES THE REAL WIZARD, NOT A STUB. A stub would render, save a PNG, and prove
nothing about the Studio; the artefact would be decoration with a picture attached.
The same StudioWizard class the studio test-suite drives (studio/tests/_helpers.py)
is constructed here, so a Studio regression shows up in this lane too.

CONTRACT WITH THE NODE SIDE (steps/runners.ts:runStudio):
  * the LAST line of stdout is a single JSON object, always;
  * on success  : {"ok": true,  "png": …, "page": …, "binding": …, "width": …, "height": …}
  * on failure  : {"ok": false, "error": …}  and a non-zero exit code
  * everything else — Qt warnings, tracebacks — goes to stderr, which the runner
    keeps in the transcript. Never print diagnostics to stdout: a stray line
    would be parsed as the result.

EXIT CODES
  0  grabbed (or --self-check / --list-pages succeeded)
  2  bad usage
  3  no Qt6 binding importable (the availability probe's signal to SKIP LOUDLY)
  4  the wizard could not be built or the requested page never came up
  5  the grab produced no file

*** THIS DRIVER STARTS NOTHING AND BUILDS NO IMAGE. *** It constructs GUI widgets
and reads configuration. It never invokes a build script, never elevates, and
never writes outside --grab's destination.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import traceback


def _fail(code: int, message: str) -> "None":
    """Emit the failure object on stdout, the detail on stderr, and exit."""
    print(json.dumps({"ok": False, "error": message}))
    sys.stdout.flush()
    print(message, file=sys.stderr)
    sys.exit(code)


def _add_studio_to_path(generator_dir: str) -> str:
    """Make `hugmesh_studio` importable from the generator checkout."""
    studio_root = os.path.join(generator_dir, "studio")
    if not os.path.isdir(os.path.join(studio_root, "hugmesh_studio")):
        _fail(2, "no hugmesh_studio package under %s — is --generator-dir a "
                 "hugmesh-generator checkout?" % studio_root)
    if studio_root not in sys.path:
        sys.path.insert(0, studio_root)
    return studio_root


def _import_qt():
    """Import the Studio's OWN binding shim, so PySide6 and PyQt6 are both fine.

    Guessing an import name here would report 'no Qt' on a host carrying the
    other binding — the shim already resolves this and is the single source of
    truth for which one the Studio actually uses.
    """
    try:
        from hugmesh_studio.gui.qt import QtWidgets, BINDING  # noqa: WPS433
        return QtWidgets, BINDING
    except Exception as exc:  # noqa: BLE001 - any import failure is "no toolkit"
        _fail(3, "no usable Qt6 binding for the Studio interface (%s: %s). "
                 "Install PySide6 or PyQt6 into %s, or point SNAP_STUDIO_PYTHON at "
                 "an interpreter that has one."
                 % (type(exc).__name__, exc, sys.executable))


def main(argv: "list[str]") -> int:
    ap = argparse.ArgumentParser(description="offscreen HugMesh Studio driver")
    ap.add_argument("--generator-dir", default=os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        help="path to the hugmesh-generator checkout (default: this repo)")
    ap.add_argument("--grab", help="PNG destination for the widget grab")
    ap.add_argument("--page", help="wizard page SLUG to advance to before grabbing")
    ap.add_argument("--list-pages", action="store_true",
                    help="print the wizard page slugs as JSON and exit")
    ap.add_argument("--self-check", action="store_true",
                    help="prove a Qt binding imports and a QApplication constructs")
    ap.add_argument("--width", type=int, default=1100)
    ap.add_argument("--height", type=int, default=760)
    args = ap.parse_args(argv)

    # Offscreen is not optional. Defaulting it here (rather than only in the
    # caller's env) means a hand-run of this driver on the operator's Wayland
    # desktop cannot pop a window up mid-suite.
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

    generator_dir = os.path.abspath(args.generator_dir)
    _add_studio_to_path(generator_dir)

    if args.list_pages:
        try:
            from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS
        except Exception as exc:  # noqa: BLE001
            _fail(4, "cannot read WIZARD_PAGE_SLUGS: %s: %s" % (type(exc).__name__, exc))
        print(json.dumps(list(WIZARD_PAGE_SLUGS)))
        return 0

    QtWidgets, binding = _import_qt()

    if args.self_check:
        # Construct a QApplication for real. Importing the binding is not proof:
        # an offscreen platform plugin that is absent fails HERE, not at import,
        # and reporting "studio available" on such a host would turn every
        # studio scenario into a mystery failure instead of a named skip.
        app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
        _ = app
        print(json.dumps({
            "ok": True, "binding": binding,
            "platform": os.environ.get("QT_QPA_PLATFORM"),
            "python": sys.executable,
        }))
        return 0

    if not args.grab:
        _fail(2, "--grab PATH is required (nothing else produces the studio "
                 "interface's evidence artefact)")

    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    try:
        from hugmesh_studio.gui import wizard as wizard_mod
        wiz = wizard_mod.StudioWizard(generator_dir)
    except Exception as exc:  # noqa: BLE001
        traceback.print_exc(file=sys.stderr)
        _fail(4, "could not build StudioWizard(%s): %s: %s"
                 % (generator_dir, type(exc).__name__, exc))

    wiz.resize(args.width, args.height)
    wiz.show()
    app.processEvents()

    page_name = type(wiz.currentPage()).__name__
    if args.page:
        # The wizard keeps its own slug -> page-id map (gui/wizard.py builds
        # self._page_ids from WIZARD_PAGE_SLUGS). Jumping by id beats clicking
        # Next N times: a validatePage that rejects would otherwise stall the
        # flow and we would grab the WRONG page while reporting the right one.
        ids = getattr(wiz, "_page_ids", None)
        if not isinstance(ids, dict) or args.page not in ids:
            known = sorted(ids) if isinstance(ids, dict) else "<no _page_ids map>"
            _fail(4, "unknown wizard page slug %r. Known slugs: %s. "
                     "(--list-pages prints the catalogue.)" % (args.page, known))
        wiz.setStartId(ids[args.page])
        wiz.restart()
        app.processEvents()
        page_name = type(wiz.currentPage()).__name__
        # Prove we actually landed there rather than trusting setStartId.
        if ids.get(args.page) != wiz.currentId():
            _fail(4, "asked for page %r (id %s) but the wizard is showing id %s (%s)"
                     % (args.page, ids[args.page], wiz.currentId(), page_name))

    pix = wiz.grab()
    dest = os.path.abspath(args.grab)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if not pix.save(dest, "PNG"):
        _fail(5, "QPixmap.save returned False for %s" % dest)
    if not os.path.exists(dest) or os.path.getsize(dest) == 0:
        _fail(5, "grab wrote no bytes to %s" % dest)

    print(json.dumps({
        "ok": True,
        "png": dest,
        "page": args.page or page_name,
        "pageClass": page_name,
        "binding": binding,
        "width": pix.width(),
        "height": pix.height(),
        "bytes": os.path.getsize(dest),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
