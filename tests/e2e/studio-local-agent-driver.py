#!/usr/bin/env python3
"""studio-local-agent-driver.py — drive the "Work on this mesh with a local AI agent"
card of the REAL Studio wizard, offscreen, and report what it says (issue #695).

SIBLING TO studio-driver.py, not a copy of its job: that one moves the e2e environment
chooser; this one reads and presses the card on the Bring-up page, which is where both
the Docker mesh and the kind (Running DevOps) build screens end.

WHAT IS REAL AND WHAT IS STAND-IN, said plainly:
  * REAL: the StudioWizard, the Bring-up page, the card, its diagnosis text, its
    enabled/disabled Start button, its tooltip, the scratch copy it makes (a real
    ``git clone`` into a state folder under --work-dir), and the command text it shows.
  * STAND-IN: the machine probe (--machine picks what the "machine" has: Ollama
    installed or not, the server answering or not, a model with tools or not, an agent
    command installed or not) and the terminal (--press runs the card's own launch with
    NO terminal installed, so the page must show the lines to copy). Nothing is read
    from this machine's Ollama and no window is opened. A live run with a real Ollama
    and a real desktop is a separate thing and is not claimed here.

CONTRACT WITH THE NODE SIDE (steps/studio-local-agent.steps.ts):
  * the LAST line of stdout is one JSON object; diagnostics go to stderr;
  * success: {"ok": true, "png": ..., "card": {...}}; failure: {"ok": false, "error": ...}
    with a non-zero exit code.

EXIT CODES  0 grabbed · 2 bad usage · 3 no Qt6 binding · 4 the page or card did not come
up · 5 the grab produced no file.

*** THIS DRIVER STARTS NOTHING. *** It builds widgets, reads a throwaway git folder and
makes one scratch copy of it under --work-dir. It never contacts Ollama, a registry, a
mesh or a cluster, never elevates and never opens a window.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import traceback

APP = "hugmesh-user-bff-api"
MACHINES = ("ready", "no-ollama", "server-down", "no-tools-model", "no-agent")


def _exit_now(code: int) -> None:
    """Leave with the streams flushed and Qt teardown skipped: the Bring-up page owns
    background probes that abort the process if they are still running at teardown
    (see studio-driver.py:_exit_now for the measured case)."""
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)


def _fail(code: int, message: str) -> None:
    print(json.dumps({"ok": False, "error": message}))
    sys.stdout.flush()
    print(message, file=sys.stderr)
    _exit_now(code)


def _git(*args, cwd):
    env = dict(os.environ, GIT_AUTHOR_NAME="e2e", GIT_AUTHOR_EMAIL="e2e@example.invalid",
               GIT_COMMITTER_NAME="e2e", GIT_COMMITTER_EMAIL="e2e@example.invalid")
    p = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True)
    if p.returncode != 0:
        _fail(4, "git %s failed in %s: %s" % (" ".join(args), cwd, p.stderr.strip()))


def _make_source_tree(root: str) -> str:
    """The operator's own source tree, in miniature: one real git repository named like
    the app, so the card has an app whose folder exists and can be copied."""
    tree = os.path.join(root, "source")
    repo = os.path.join(tree, APP)
    os.makedirs(repo, exist_ok=True)
    if not os.path.isdir(os.path.join(repo, ".git")):
        _git("init", "-q", "-b", "main", cwd=repo)
        with open(os.path.join(repo, "README.md"), "w", encoding="utf-8") as fh:
            fh.write("# %s\n" % APP)
        _git("add", "README.md", cwd=repo)
        _git("commit", "-q", "-m", "first", cwd=repo)
    return tree


def _probe_for(la, machine: str):
    """What the stand-in machine has. Same shapes core.local_agent.probe() returns."""
    up = machine != "server-down"
    has_ollama = machine != "no-ollama"
    tools = machine != "no-tools-model"
    agents = () if machine == "no-agent" else ("claude",)
    models = (la.ModelInfo("qwen3:8b" if tools else "plain:1", tools),) if up else ()
    return la.Probe(
        ollama_path="/usr/bin/ollama" if has_ollama else "",
        server="127.0.0.1:11434", server_up=up,
        server_error="" if up else "connection refused",
        models=models,
        agents={a: ("/usr/bin/" + a if a in agents else "") for a in la.AGENTS})


def main(argv: "list[str]") -> int:
    ap = argparse.ArgumentParser(description="offscreen driver for the local-agent card")
    ap.add_argument("--generator-dir", default=os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument("--grab", help="PNG destination for the widget grab")
    ap.add_argument("--machine", choices=MACHINES, default="ready")
    ap.add_argument("--press", choices=("none", "start", "copy"), default="none",
                    help="press Start (with NO terminal installed, so the page must show "
                         "the lines to run) or Copy command, then report")
    ap.add_argument("--lane", choices=("docker", "kind"), default="docker")
    ap.add_argument("--work-dir", help="a scratch folder this driver may write in")
    ap.add_argument("--width", type=int, default=1040)
    ap.add_argument("--height", type=int, default=760)
    ap.add_argument("--self-check", action="store_true")
    args = ap.parse_args(argv)

    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    generator_dir = os.path.abspath(args.generator_dir)
    studio_root = os.path.join(generator_dir, "studio")
    if not os.path.isdir(os.path.join(studio_root, "hugmesh_studio")):
        _fail(2, "no hugmesh_studio package under %s" % studio_root)
    sys.path.insert(0, studio_root)
    try:
        from hugmesh_studio.gui.qt import QtWidgets, BINDING
    except Exception as exc:  # noqa: BLE001
        _fail(3, "no usable Qt6 binding (%s: %s)" % (type(exc).__name__, exc))
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    if args.self_check:
        print(json.dumps({"ok": True, "binding": BINDING}))
        return 0
    if not args.grab or not args.work_dir:
        _fail(2, "--grab PATH and --work-dir DIR are required")

    work = os.path.abspath(args.work_dir)
    os.makedirs(work, exist_ok=True)
    # The scratch copy goes under the Studio's state folder; never the operator's own.
    os.environ["HUGMESH_STUDIO_STATE_DIR"] = os.path.join(work, "studio-state")
    source_tree = _make_source_tree(work)

    try:
        from hugmesh_studio.core import local_agent as la
        from hugmesh_studio.gui import wizard as wizard_mod
        wiz = wizard_mod.StudioWizard(generator_dir)
        page = wiz.localmesh_page
        card = page.local_agent
    except Exception as exc:  # noqa: BLE001
        traceback.print_exc(file=sys.stderr)
        _fail(4, "could not build the Bring-up page and its card: %s: %s"
                 % (type(exc).__name__, exc))

    # Stand-ins go in BEFORE the card is first shown: that first show is what starts its
    # first look at the machine.
    plans = []

    def no_terminal(plan):
        plans.append(plan)
        host = la.Host("linux", which=lambda _c: None, environ={"DISPLAY": ":0"})
        return la.launch(plan, host)

    card.set_prober(lambda: _probe_for(la, args.machine))
    card.set_launcher(no_terminal)

    wiz.resize(args.width, args.height)
    wiz.show()
    app.processEvents()
    ids = getattr(wiz, "_page_ids", {})
    if "localmesh" not in ids:
        _fail(4, "the wizard has no 'localmesh' page; known: %s" % sorted(ids))
    wiz.setStartId(ids["localmesh"])
    wiz.restart()
    app.processEvents()
    if wiz.currentId() != ids["localmesh"]:
        _fail(4, "asked for the Bring-up page but the wizard shows %s"
                 % type(wiz.currentPage()).__name__)
    page.src_existing.setChecked(True)
    page.src_dir.setText(source_tree)
    card.refresh_apps()
    app.processEvents()
    if not card.isVisible():
        _fail(4, "the card is not visible on the Bring-up page")
    card.set_lane(args.lane)
    card.wait_idle()
    for i in range(card.app_box.count()):            # pick the app whose folder exists
        if card.app_box.itemText(i) == APP:
            card.app_box.setCurrentIndex(i)
    card.wait_idle()
    app.processEvents()
    if args.press == "start":
        card.start_btn.click()
        card.wait_idle()
    elif args.press == "copy":
        card.copy_btn.click()
        card.wait_idle()
    app.processEvents()

    # bring the card into the picture (generic: the page scrolls its content)
    scroll = getattr(page, "_content_scroll", None)
    if scroll is not None:
        scroll.ensureWidgetVisible(card, 0, 0)
        app.processEvents()
    pix = card.grab()
    dest = os.path.abspath(args.grab)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if not pix.save(dest, "PNG"):
        _fail(5, "QPixmap.save returned False for %s" % dest)
    if not os.path.exists(dest) or os.path.getsize(dest) == 0:
        _fail(5, "grab wrote no bytes to %s" % dest)

    def drawn(w):
        """Is the widget visible, inside the card and wide enough for its own label?"""
        if not w.isVisible():
            return {"visible": False, "width": 0, "height": 0, "inside": False}
        top_left = w.mapTo(card, w.rect().topLeft())
        rect = w.rect().translated(top_left)
        inside = card.rect().contains(rect)
        return {"visible": True, "width": w.width(), "height": w.height(), "inside": inside}

    start = drawn(card.start_btn)
    start["labelWidth"] = card.start_btn.fontMetrics().horizontalAdvance(
        card.start_btn.text())
    card_info = {
        "title": card.title(),
        "onBringUpPage": type(wiz.currentPage()).__name__ == "LocalMeshPage"
                         and page.isAncestorOf(card),
        "status": card.status.text(),
        "more": card.more.text() if card.more.isVisible() else "",
        "startText": card.start_btn.text(),
        "startEnabled": card.start_btn.isEnabled(),
        "startTooltip": card.start_btn.toolTip(),
        "start": start,
        "copy": drawn(card.copy_btn),
        "recheck": drawn(card.recheck_btn),
        "note": card.note.text() if card.note.isVisible() else "",
        "commandShown": card.command_box.toPlainText() if card.command_box.isVisible() else "",
        "laneChoices": [card.lane_box.itemText(i) for i in range(card.lane_box.count())],
        "lane": card.lane_box.currentData(),
        "app": card.app_box.currentText(),
        "folder": card.folder_label.full_text(),
        "launchesRequested": len(plans),
        "cardWidth": card.width(),
        "forbiddenFlags": sorted(la.FORBIDDEN_FLAGS),
    }
    if plans:
        p = plans[0]
        card_info["plan"] = {"argv": list(p.argv), "cwd": p.cwd, "brief": p.brief,
                             "title": p.title}
        card_info["copyHasRemote"] = bool(subprocess.run(
            ["git", "remote"], cwd=p.cwd, capture_output=True, text=True).stdout.strip()) \
            if os.path.isdir(p.cwd) else None
    print(json.dumps({"ok": True, "png": dest, "binding": BINDING, "card": card_info}))
    _exit_now(0)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
