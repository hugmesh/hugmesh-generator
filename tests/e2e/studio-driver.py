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


def _exit_now(code: int) -> "None":
    """Leave RIGHT NOW, with the streams flushed, skipping Qt teardown.

    WHY THIS IS NOT LAZINESS. Some Studio pages own a background QThread — the
    LocalMeshPage's e2e readiness probe is three 30s docker subprocesses deep —
    and Qt ABORTS the process (SIGABRT, exit 134) if such a thread is still
    running when the QApplication is torn down. Measured on this box BEFORE any
    change from this unit: `studio-driver.py --page localmesh` exits 134 with
    "QThread: Destroyed while thread '' is still running", so the studio
    interface could not photograph that page at all.

    The two alternatives are both worse. Waiting for the probe means up to ~95s
    per grab on a wedged docker daemon. Reaching into the page to cancel its
    probe means the driver knows about page internals, which is exactly the
    coupling that makes a harness rot. So: the artefact is already written and
    fsync'd by Qt, the result JSON is already printed, and the process leaves
    before teardown can abort it. The result carries `liveThreads` so a skipped
    teardown is VISIBLE rather than something the reader has to infer from an
    exit code that no longer happens.
    """
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)


def _reveal(page, widget) -> "None":
    """Make `widget` visible in a grab of `page`: raise its tab, scroll to it.

    Deliberately structural rather than page-specific — it looks for ANY
    QTabWidget ancestor-chain and ANY QScrollArea, so it works on a page whose
    layout changes and on pages that have neither.
    """
    from hugmesh_studio.gui.qt import QtWidgets
    for tabs in page.findChildren(QtWidgets.QTabWidget):
        for i in range(tabs.count()):
            pane = tabs.widget(i)
            if pane is not None and pane.isAncestorOf(widget):
                tabs.setCurrentIndex(i)
                break
    for area in page.findChildren(QtWidgets.QScrollArea):
        if area.widget() is not None and area.widget().isAncestorOf(widget):
            area.ensureWidgetVisible(widget, 50, 50)


def _live_thread_names() -> "list[str]":
    """Names of QThreads still running, for the result's `liveThreads` field.
    Best-effort: returns [] when Qt is not importable or gives nothing back."""
    try:
        from hugmesh_studio.gui.qt import QtCore
        app = QtCore.QCoreApplication.instance()
        if app is None:
            return []
        out = []
        for obj in app.findChildren(QtCore.QThread):
            try:
                if obj.isRunning():
                    out.append(obj.objectName() or type(obj).__name__)
            except RuntimeError:      # C++ side already gone
                continue
        return out
    except Exception:                 # noqa: BLE001 - diagnostics must never throw
        return []


def _fail(code: int, message: str) -> "None":
    """Emit the failure object on stdout, the detail on stderr, and exit.

    Exits through _exit_now so the DECLARED exit code is what the runner sees. A
    plain sys.exit here would let a live background QThread turn a clean `4`
    into a SIGABRT 134, and the runner would report "killed by SIGABRT" for what
    is really "unknown wizard page slug".
    """
    print(json.dumps({"ok": False, "error": message}))
    sys.stdout.flush()
    print(message, file=sys.stderr)
    _exit_now(code)


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
    ap.add_argument("--e2e-env", metavar="ID",
                    help="drive the Studio's e2e ENVIRONMENT chooser to this id "
                         "(docker|kind|qemu) before grabbing. Implies --page "
                         "localmesh when no page is named. The grab is then a "
                         "photograph of the real chooser holding the real "
                         "selection, and the result JSON reports what the page "
                         "ACTUALLY says it will run — not what we asked for.")
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

    # Selecting an environment is a LocalMeshPage act, so it fixes the page.
    if args.e2e_env and not args.page:
        args.page = "localmesh"

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

    # ── drive the e2e ENVIRONMENT chooser ────────────────────────────────────
    # This is the half that makes the studio interface a DRIVER and not just a
    # camera: the scenario names an environment, the real combo box is moved to
    # it, and the grab photographs the result.
    #
    # WHAT IS REPORTED IS WHAT THE PAGE SAYS, NOT WHAT WE ASKED FOR. Echoing the
    # requested id back would make this check pass even if the selection never
    # landed — which is exactly the mutation the guard battery plants.
    e2e_env_reported = None
    e2e_env_plan = None
    if args.e2e_env:
        page = wiz.currentPage()
        combo = getattr(page, "e2e_env_combo", None)
        if combo is None:
            _fail(4, "page %r has no e2e environment chooser (e2e_env_combo). "
                     "The studio interface cannot select an environment on a "
                     "page that does not offer one." % (args.page,))
        idx = combo.findData(args.e2e_env)
        if idx < 0:
            known = [combo.itemData(i) for i in range(combo.count())]
            _fail(4, "the Studio's e2e chooser has no environment %r. It offers: %s"
                     % (args.e2e_env, known))
        combo.setCurrentIndex(idx)
        app.processEvents()
        # BRING THE THING WE DROVE INTO THE PICTURE. The chooser lives on the
        # page's SECOND tab and inside a scroll area, so a grab taken without
        # this photographs a different tab entirely — a plausible PNG of the
        # wrong screen, which is worse than no PNG because it passes for
        # evidence. Both moves are generic (find the tab that CONTAINS the
        # widget; ask the enclosing scroll area to reveal it), so the driver
        # still knows nothing about this page's layout.
        _reveal(page, combo)
        app.processEvents()
        e2e_env_reported = page.e2e_environment()
        if e2e_env_reported != args.e2e_env:
            _fail(4, "asked the Studio for environment %r but the page reports %r"
                     % (args.e2e_env, e2e_env_reported))
        # The PLAN the page would hand the runner — the same core function the
        # CLI channel prints. Carrying it in the result is what lets a Gherkin
        # step assert that the GUI's choice reaches the spawned run's env.
        from hugmesh_studio.core import e2e_environments as _e2e_env
        e2e_env_plan = _e2e_env.plan(e2e_env_reported).to_dict()

    pix = wiz.grab()
    dest = os.path.abspath(args.grab)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if not pix.save(dest, "PNG"):
        _fail(5, "QPixmap.save returned False for %s" % dest)
    if not os.path.exists(dest) or os.path.getsize(dest) == 0:
        _fail(5, "grab wrote no bytes to %s" % dest)

    result = {
        "ok": True,
        "png": dest,
        "page": args.page or page_name,
        "pageClass": page_name,
        "binding": binding,
        "width": pix.width(),
        "height": pix.height(),
        "bytes": os.path.getsize(dest),
    }
    if e2e_env_reported is not None:
        result["e2eEnvironment"] = e2e_env_reported
        result["e2ePlan"] = e2e_env_plan
    live = _live_thread_names()
    result["liveThreads"] = live
    print(json.dumps(result))
    # Past this point the evidence is on disk and reported. Leave before Qt can
    # abort over a page's still-running background probe (see _exit_now).
    _exit_now(0)
    return 0                                     # pragma: no cover - unreachable


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
