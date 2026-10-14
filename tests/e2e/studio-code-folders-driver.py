#!/usr/bin/env python3
"""studio-code-folders-driver.py — walk the REAL Studio wizard to the local mesh's
"Repo source" step and press the buttons of its Code folders block (issue #689).

WHY A SECOND DRIVER. studio-driver.py jumps to a page and grabs it; it never
reaches the Repo source step's block and presses nothing. The choices made for #689
(the folder is the one the BUILD reads, a missing folder is a disabled control that
says why, an open nothing takes says so and offers the path) are only worth
anything when the real wizard is walked from the first page and the real buttons are
pressed, so this driver does exactly that, offscreen, and reports what it SAW.

WHAT IS REAL AND WHAT IS A STAND-IN
  real      : StudioWizard, the page flow (Welcome -> Mode -> Generate -> Env ->
              Domains -> Domain services -> Repo source), the Domains table, the
              Repo source cards, the Code folders widget, the real opener module
              (core/open_path: it launches real processes and reads their exit
              status), the real compose files of this checkout.
  stand-in  : the file manager. The driver puts a one-line ``xdg-open`` script
              first (and ONLY) on PATH, which appends the folder it was handed to a
              log file. ``--opener ok`` exits 0 at once; ``--opener stay`` never
              exits (the way a real file manager does); ``--opener none`` puts no
              opener on PATH at all (a machine with no file manager). Nothing is
              ever opened on the operator's desktop.
  pinned    : the host description (a Gentoo box with docker), as the studio test
              suite pins it, so the page flow does not depend on the box running
              the suite.

THE FOLDER THE BUILD READS is worked out HERE, separately from the Studio's own
map, from the three things the build actually uses: every tests/stack/compose*.yaml's
``context: ${STACK_SRC:-…}/hugmesh-<name>`` lines, the STACK_SRC the stack node
hands to make in "existing" mode, and the Makefile's ``STACK_SRC ?= $(CURDIR)/.stack-src``
default in "clone" mode. ``buildPath`` in each row is that, so a step can compare it
with the folder the button opens.

CONTRACT WITH THE NODE SIDE (steps/studio-code-folders.steps.ts)
  * the LAST line of stdout is one JSON object; diagnostics go to stderr;
  * success: {"ok": true, ...facts...}; failure: {"ok": false, "error": ...}, exit != 0.

EXIT CODES  0 ok · 2 bad usage · 3 no Qt binding · 4 the walk or a click failed ·
            5 no grab written

*** STARTS NOTHING. *** No stack, no build, no elevation; it writes only under --scratch
(it gives the Studio a symlinked copy of the generator checkout there, so even the
clone mode's .stack-src is a scratch folder).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
import traceback

PRESENT = ("hugmesh-gateway", "hugmesh-admin-ui", "hugmesh-owncast-ui",
           "hugmesh-forum-api")
EXTRA_DOMAIN = "chat.example.org"


def _exit_now(code: int) -> None:
    # A page may own a running QThread; Qt aborts the process if one is alive at
    # teardown (see studio-driver.py:_exit_now). The result is already printed.
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)


def _fail(code: int, message: str) -> None:
    print(json.dumps({"ok": False, "error": message}))
    print(message, file=sys.stderr)
    _exit_now(code)


def _build_reads(generator_dir: str, mode: str, source_dir: str, app: str) -> str:
    """Where the build looks for ``app``'s checkout, derived without the Studio's map."""
    stack = os.path.join(generator_dir, "tests", "stack")
    text = "\n".join(open(os.path.join(stack, n), encoding="utf-8").read()
                     for n in sorted(os.listdir(stack))
                     if n.startswith("compose") and n.endswith(".yaml"))
    # the first-party context line of this app: ${STACK_SRC:-<default>}/<app>
    if not re.search(r"context:\s*\$\{STACK_SRC:-[^}]*\}/" + re.escape(app) + r"\s*$",
                     text, re.M):
        return ""                      # compose does not build this app from a checkout
    if mode == "existing":
        from hugmesh_studio.core.local_stack_node import LocalStackNode
        env = LocalStackNode(generator_dir, source_mode="existing",
                             source_dir=source_dir)._build_env(write_overlays=False)
        return os.path.join(env["STACK_SRC"], app)
    make = open(os.path.join(generator_dir, "Makefile"), encoding="utf-8").read()
    if not re.search(r"^STACK_SRC\s*\?=\s*\$\(CURDIR\)/\.stack-src\s*$", make, re.M):
        _fail(4, "the Makefile no longer defaults STACK_SRC to $(CURDIR)/.stack-src; "
                 "this driver's clone-mode expectation is out of date")
    return os.path.join(generator_dir, ".stack-src", app)


def _write_fake_opener(scratch: str, kind: str) -> str:
    """Create scratch/bin and, unless kind == 'none', a logging xdg-open in it.
    Returns the log path."""
    bindir = os.path.join(scratch, "bin")
    os.makedirs(bindir, exist_ok=True)
    log = os.path.join(scratch, "opened.log")
    open(log, "w").close()
    if kind == "none":
        return log
    sleep = shutil.which("sleep") or "/bin/sleep"
    body = f'echo "$1" >> "{log}"\n'
    # "stay" ends by itself after a while so nothing outlives the suite; the point
    # is that it does NOT exit inside the Studio's wait.
    body += "exit 0\n" if kind == "ok" else f'exec "{sleep}" 8\n'
    script = os.path.join(bindir, "xdg-open")
    with open(script, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\n" + body)
    os.chmod(script, 0o755)
    return log


def main(argv: "list[str]") -> int:
    ap = argparse.ArgumentParser(description="offscreen Studio Code folders driver")
    ap.add_argument("--generator-dir", default=os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument("--scratch", required=True, help="a directory this driver may write")
    ap.add_argument("--grab", help="PNG destination for a grab of the block")
    ap.add_argument("--source-mode", choices=("existing", "clone"), default="existing")
    ap.add_argument("--opener", choices=("ok", "stay", "none"), default="ok")
    ap.add_argument("--tree", choices=("some", "all", "none"), default="some",
                    help="existing mode: which checkouts exist (some = four of them)")
    ap.add_argument("--click", default="",
                    help="open:<domain>:<app> | all:<domain> | root | '' (nothing)")
    ap.add_argument("--also-create", default="",
                    help="comma list of app folders to create AFTER the first read, "
                         "then finish a run the way 'Generate & start' does (the "
                         "Studio must pick them up on that path, nothing else)")
    args = ap.parse_args(argv)

    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    generator_dir = os.path.abspath(args.generator_dir)
    studio_root = os.path.join(generator_dir, "studio")
    if studio_root not in sys.path:
        sys.path.insert(0, studio_root)
    scratch = os.path.abspath(args.scratch)
    os.makedirs(scratch, exist_ok=True)
    # A generator checkout of our own: every top-level entry of the real one,
    # symlinked, EXCEPT .stack-src — so "Download the source" mode points at a
    # .stack-src we may create folders in, and the repo under test is never written.
    real_generator = generator_dir
    generator_dir = os.path.join(scratch, "generator")
    os.makedirs(generator_dir, exist_ok=True)
    for entry in os.listdir(real_generator):
        if entry in (".git", ".stack-src", "out", "node_modules"):
            continue
        link = os.path.join(generator_dir, entry)
        if not os.path.lexists(link):
            os.symlink(os.path.join(real_generator, entry), link)

    try:
        from hugmesh_studio.gui.qt import QtWidgets
    except Exception as exc:                       # noqa: BLE001
        _fail(3, "no usable Qt6 binding (%s: %s)" % (type(exc).__name__, exc))

    # The tree the operator says they already have, and the fake file manager.
    src = os.path.join(scratch, "my-source-tree")
    os.makedirs(src, exist_ok=True)
    present = {"some": PRESENT}.get(args.tree, ())
    log = _write_fake_opener(scratch, args.opener)
    # PATH holds ONLY the fake opener dir: the real desktop's opener can never run.
    os.environ["PATH"] = os.path.join(scratch, "bin")

    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    try:
        from hugmesh_studio.core.platform_info import HostInfo
        from hugmesh_studio.gui import wizard as wizard_mod
        from hugmesh_studio.gui.pages import localmesh as lm
        wizard_mod.detect = lambda builder_image="hugmesh-builder": HostInfo(
            os="linux", is_gentoo=True, has_docker=False, has_bash=True,
            has_kvm=False, is_root=False, builder_image="hugmesh-builder")
        wiz = wizard_mod.StudioWizard(generator_dir)
    except Exception as exc:                       # noqa: BLE001
        traceback.print_exc(file=sys.stderr)
        _fail(4, "could not build StudioWizard: %s: %s" % (type(exc).__name__, exc))
    wiz.resize(1040, 706)
    wiz.show()
    app.processEvents()

    def to(cls, limit=14):
        for _ in range(limit):
            if isinstance(wiz.currentPage(), cls):
                return wiz.currentPage()
            before = wiz.currentId()
            wiz.next()
            app.processEvents()
            if wiz.currentId() == before:
                _fail(4, "the wizard stuck on %s on the way to %s"
                         % (type(wiz.currentPage()).__name__, cls.__name__))
        _fail(4, "never reached %s" % cls.__name__)

    # ── the real journey: Welcome -> Mode -> Generate -> Env -> Domains ...
    wiz.next()
    mode = wiz.currentPage()
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    wiz.next()
    wiz.currentPage()._buttons["generate"].setChecked(True)
    wiz.next()
    ctl = wiz.localmesh_page
    to(lm.LocalMeshDomainsPage)
    ctl.domains_table._add(EXTRA_DOMAIN, "Added")        # a SECOND domain
    to(lm.LocalMeshDomainServicesPage)
    ctl.domain_services._step(1)
    for slug in ("owncast", "phpbb"):                    # chosen for that domain only
        ctl.domain_services._boxes[slug].setChecked(True)
    page = to(lm.LocalMeshSourcePage)
    if args.source_mode == "existing":
        for name in present:
            os.makedirs(os.path.join(src, name), exist_ok=True)
        ctl.src_existing.setChecked(True)
        ctl.src_dir.setText(src)
    else:
        ctl.src_clone.setChecked(True)
    app.processEvents()
    block = ctl.code_folders

    if args.tree == "all" and args.source_mode == "existing":
        for dom in block.map.domains:
            for a in dom.apps:
                os.makedirs(os.path.join(src, a.name), exist_ok=True)
        ctl.src_dir.setText(src + " ")
        ctl.src_dir.setText(src)
        app.processEvents()

    # Stage-4 style change AFTER the first read: the checkouts appear on disk (a
    # clone finished) and the Studio has to notice through the path a finished
    # 'Generate & start' really takes, _verb_done — no form control changes when
    # make stack-clone creates the folders, so nothing else would re-read them.
    # The verb itself (make, docker) is not run here; what stands in for it is
    # what the widget test uses: no run log is written, the docker status probe
    # and the mesh-state re-read are silenced (they read docker, which this driver
    # promises never to touch), and the run list is empty.
    if args.also_create:
        root = block.map.root
        for name in args.also_create.split(","):
            os.makedirs(os.path.join(root, name), exist_ok=True)
        ctl._probe_mesh_state = lambda: None
        ctl._refresh_status = lambda: None
        ctl._save_run_log = lambda run, ok: ""
        ctl._runs = []
        ctl._verb_done(True)
        app.processEvents()

    mode_name = args.source_mode
    typed = src if mode_name == "existing" else ""
    domains = []
    for dom in block.map.domains:
        rows = []
        for a in dom.apps:
            btn = block.open_buttons[(dom.name, a.name)]
            rows.append({
                "app": a.name,
                "path": a.path,
                "buildPath": _build_reads(generator_dir, mode_name, typed, a.name),
                "enabled": btn.isEnabled(),
                "label": btn.text(),
                "tooltip": btn.toolTip(),
                "visible": btn.isVisible(),
                "width": btn.width(),
                "labelWidth": btn.fontMetrics().horizontalAdvance(btn.text()),
            })
        allb = block.open_all_buttons[dom.name]
        domains.append({"name": dom.name, "rows": rows,
                        "openAll": {"enabled": allb.isEnabled(),
                                    "tooltip": allb.toolTip(),
                                    "visible": allb.isVisible()}})

    result = {
        "ok": True,
        "mode": mode_name,
        "sourceDir": typed,
        "root": block.map.root,
        "generatorDir": generator_dir,
        "rootButton": {"enabled": block.open_root_btn.isEnabled(),
                       "visible": block.open_root_btn.isVisible()},
        "domains": domains,
        "pageClass": type(wiz.currentPage()).__name__,
    }

    # ── press a button, as the operator would
    clicked = None
    if args.click:
        t0 = time.monotonic()
        parts = args.click.split(":")
        if parts[0] == "open" and len(parts) == 3:
            btn = block.open_buttons[(parts[1], parts[2])]
        elif parts[0] == "all" and len(parts) == 2:
            btn = block.open_all_buttons[parts[1]]
        elif args.click == "root":
            btn = block.open_root_btn
        else:
            _fail(2, "bad --click %r" % args.click)
        was_enabled = btn.isEnabled()
        btn.click()                    # a disabled button ignores this, as in the app
        app.processEvents()
        elapsed = time.monotonic() - t0
        logged = [ln for ln in open(log, encoding="utf-8").read().splitlines() if ln]
        top = [w for w in QtWidgets.QApplication.topLevelWidgets()
               if w.isVisible() and w is not wiz
               and isinstance(w, (QtWidgets.QDialog, QtWidgets.QMessageBox))]
        clicked = {
            "target": args.click,
            "wasEnabled": was_enabled,
            "elapsedS": round(elapsed, 2),
            "handedToFileManager": logged,
            "noteVisible": block.result_note.isVisible(),
            "note": block.result_note.text(),
            "noteStyle": block.result_note.styleSheet(),
            "copyFieldVisible": block.result_path.isVisible(),
            "copyFieldText": block.result_path.text(),
            "copyButtonVisible": block.copy_btn.isVisible(),
            "dialogsOpen": [type(w).__name__ for w in top],
        }
        result["clicked"] = clicked

    if args.grab:
        # Bring what the operator would be looking at into the picture: the result
        # note (and its copy field) after a click, the top of the block otherwise.
        target = block.result_note if clicked else block
        for area in page.findChildren(QtWidgets.QScrollArea):
            if area.widget() is not None and area.widget().isAncestorOf(target):
                area.ensureWidgetVisible(target, 50, 120)
        app.processEvents()
        pix = wiz.grab()
        dest = os.path.abspath(args.grab)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if not pix.save(dest, "PNG") or not os.path.getsize(dest):
            _fail(5, "no grab written to %s" % dest)
        result.update({"png": dest, "bytes": os.path.getsize(dest),
                       "width": pix.width(), "height": pix.height(),
                       "page": "localmesh", "binding": "unknown"})

    print(json.dumps(result))
    _exit_now(0)
    return 0                                       # pragma: no cover


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
