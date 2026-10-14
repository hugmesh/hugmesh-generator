#!/usr/bin/env python3
"""studio-local-ai-driver.py — drive the Studio's Local AI dock end to end, offscreen.

The sibling of studio-driver.py for ONE scenario (features/studio/studio-local-ai-dock
.feature): a person opens the Studio, presses **Start local assistant**, asks the local
model a question, and presses **Clear** while the answer is still arriving. The REAL
pieces run — ``StudioShell.open_window`` (which mounts the dock on the window), the dock,
``core.local_ai_status.read_snapshot`` / ``send_prompt`` / ``start_assistant`` — against
two stand-ins that keep the run on this machine and start nothing of the operator's:

* a model server bound to a free loopback port inside this process (``studio/tests/
  _local_ai_fake.py``), streaming a four-piece answer with a pause between pieces so
  Clear can land mid-answer; ``OLLAMA_HOST`` points at it, so the loopback rule is the
  one the Studio ships;
* a stand-in ``scripts/local-ai.sh`` in a scratch folder that only RECORDS how it was
  called, in place of the repository's script, which would start a real Ollama and a
  real queue worker on the box running the suite. ``start_assistant`` itself is the
  real function: it spawns the stand-in exactly as it would spawn the real script.

Before the window opens, the plain command line (``python -m hugmesh_studio
--local-ai-prompt``) asks the same fake under the same ``$LOCAL_AI_MODEL``, so the step
file can hold the dock to the model the command line asked, not to whatever was loaded.

Both state folders (the Studio's and the local-AI one) are scratch, and the local-AI one
is seeded with one queued job and one finished draft so the status line has something
to count.

Prints ONE JSON object on the LAST stdout line (the step file's contract):
``{ok, binding, png, grabs:[{name,png}], faces:{...}, dock:{...}, start:{...},
prompt:{...}, clear:{...}, modal, errors:[...]}``. Exit codes: 0 driven and grabbed,
2 bad usage, 3 no Qt binding, 4 the Studio could not be built or driven.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time


def _fail(code, message):
    print(message, file=sys.stderr)
    print(json.dumps({"ok": False, "error": message}))
    sys.exit(code)


def _seed_state(root):
    """One queued job and one finished draft, so the summary counts something."""
    os.makedirs(os.path.join(root, "queue", "pending"), exist_ok=True)
    with open(os.path.join(root, "queue", "pending", "20260101-000001-draft-hugmesh-generator-12.job"), "w") as fh:
        fh.write("draft hugmesh-generator 12\n")
    d = os.path.join(root, "drafts", "hugmesh-generator-9")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "STATUS"), "w") as fh:
        fh.write("applied files=1\n")
    with open(os.path.join(d, "issue.md"), "w") as fh:
        fh.write("# A finished draft\n\nbody\n")
    with open(os.path.join(d, "draft.diff"), "w") as fh:
        fh.write("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n")


def _stand_in_start_script(gen_dir, record):
    """A scripts/local-ai.sh that records its call instead of starting anything."""
    os.makedirs(os.path.join(gen_dir, "scripts"), exist_ok=True)
    path = os.path.join(gen_dir, "scripts", "local-ai.sh")
    with open(path, "w") as fh:
        fh.write("#!/usr/bin/env bash\n"
                 "# stand-in for the e2e driver: record the call, start nothing\n"
                 f"printf 'args=%s\\nOLLAMA_HOST=%s\\nsid=%s\\n' \"$*\" \"${{OLLAMA_HOST:-}}\" \"$(ps -o sid= -p $$ | tr -d ' ')\" > '{record}'\n"
                 "exit 0\n")
    os.chmod(path, 0o755)
    return path


def main(argv):
    ap = argparse.ArgumentParser(description="offscreen driver for the Studio's Local AI dock")
    ap.add_argument("--generator-dir", default=os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument("--grab-dir", required=True, help="folder for the PNG grabs (one per act)")
    ap.add_argument("--width", type=int, default=1040)
    ap.add_argument("--height", type=int, default=780)
    args = ap.parse_args(argv)

    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    generator_dir = os.path.abspath(args.generator_dir)
    studio_root = os.path.join(generator_dir, "studio")
    if not os.path.isdir(os.path.join(studio_root, "hugmesh_studio")):
        _fail(2, f"no hugmesh_studio package under {studio_root}")
    for p in (studio_root, os.path.join(studio_root, "tests")):
        if p not in sys.path:
            sys.path.insert(0, p)
    os.makedirs(args.grab_dir, exist_ok=True)

    scratch = tempfile.mkdtemp(prefix="studio-local-ai-e2e.")
    state = os.path.join(scratch, "local-ai")
    _seed_state(state)
    os.environ["HUGMESH_LOCAL_AI_DIR"] = state
    os.environ["HUGMESH_STUDIO_STATE_DIR"] = os.path.join(scratch, "studio-state")
    record = os.path.join(scratch, "start.record")
    stand_in_gen = os.path.join(scratch, "gen")
    stand_in = _stand_in_start_script(stand_in_gen, record)

    try:
        from hugmesh_studio.gui.qt import BINDING, Qt, QtWidgets
    except Exception as exc:  # noqa: BLE001
        _fail(3, f"no usable Qt6 binding for the Studio ({type(exc).__name__}: {exc})")
    try:
        from _local_ai_fake import FakeOllama
        from hugmesh_studio.core import local_ai_status as lai
        from hugmesh_studio.gui import shell as shell_mod
    except Exception as exc:  # noqa: BLE001
        _fail(4, f"cannot import the Studio ({type(exc).__name__}: {exc})")

    fake = FakeOllama()
    os.environ["OLLAMA_HOST"] = fake.host

    # ── act 0: the command line, under the same setting the dock will see ──
    # Two models pulled, only the default loaded, and $LOCAL_AI_MODEL naming the OTHER
    # one: the faces agree only if neither prefers what happens to be loaded. The plain
    # CLI goes first so its one request can be told apart from the dock's.
    model_setting = "qwen2.5-coder:7b"
    fake.models = [{"name": "qwen3:8b"}, {"name": model_setting}]
    os.environ[lai.MODEL_ENV] = model_setting
    cli = subprocess.run([sys.executable, "-m", "hugmesh_studio", "--local-ai-prompt",
                          "Which model answers?"], cwd=studio_root, env=dict(os.environ),
                         capture_output=True, text=True, timeout=120)
    faces = {
        "modelSetting": model_setting, "loaded": [m["name"] for m in fake.loaded],
        "cliExit": cli.returncode, "cliAnswer": cli.stdout.strip(), "cliStderr": cli.stderr[-400:],
        "cliModelAsked": next((b.get("model") for m, p, b in fake.requests if m == "POST"), None),
    }
    del fake.requests[:]                            # the dock's requests are counted alone
    fake.chunks = ["The dock talks ", "to the model on ", "this machine ", "only."]
    fake.chunk_delay = 0.6

    # the real start_assistant, pointed at the stand-in script (the dock asks for the
    # repository's; that one would start a real server and worker on this box)
    real_start = lai.start_assistant
    lai.start_assistant = lambda _gen, **kw: real_start(stand_in_gen, **kw)

    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    report = {"ok": True, "binding": BINDING, "grabs": [], "errors": [], "modal": None,
              "standInStartScript": stand_in, "model": fake.host, "faces": faces}

    def pump(cond, timeout=10.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            app.processEvents()
            if cond():
                return True
            time.sleep(0.02)
        app.processEvents()
        return bool(cond())

    def modal_check(where):
        m = QtWidgets.QApplication.activeModalWidget()
        if m is not None and report["modal"] is None:
            report["modal"] = f"{type(m).__name__} during {where}"

    def grab(name):
        pix = wiz.grab()
        dest = os.path.join(args.grab_dir, f"{name}.png")
        pix.save(dest, "PNG")
        if not (os.path.isfile(dest) and os.path.getsize(dest) > 0):
            report["errors"].append(f"grab {name} wrote nothing")
        report["grabs"].append({"name": name, "png": dest})
        report["png"] = dest
        return dest

    try:
        shell = shell_mod.StudioShell(generator_dir)
        wiz = shell.open_window()                       # the real door: this mounts the dock
        wiz.resize(args.width, args.height)
        app.processEvents()
        dock = getattr(wiz, "local_ai_dock", None)
        if dock is None:
            _fail(4, "StudioShell.open_window mounted no Local AI dock on the window")

        # ── act 1: the Studio opens; the dock is on the page and reads its status ──
        if not pump(lambda: dock.snapshot is not None, 15):
            report["errors"].append("the dock never read a snapshot: "
                                    + dock.summary.full_text())
        from hugmesh_studio.gui.qt import QtCore
        drect = QtCore.QRect(dock.mapTo(wiz, QtCore.QPoint(0, 0)), dock.size())
        buttons = []
        for b in (QtWidgets.QWizard.WizardButton.BackButton, QtWidgets.QWizard.WizardButton.NextButton,
                  QtWidgets.QWizard.WizardButton.CancelButton):
            btn = wiz.button(b)
            if btn is not None and btn.isVisible():
                buttons.append(QtCore.QRect(btn.mapTo(wiz, QtCore.QPoint(0, 0)), btn.size()))
        report["dock"] = {
            "visible": dock.isVisible(), "expanded": dock.expanded,
            "insideWindow": wiz.rect().contains(drect),
            "bottomStrip": drect.bottom() == wiz.rect().bottom() and drect.width() == wiz.width(),
            "coversAWizardButton": any(drect.intersects(b) for b in buttons),
            "summary": dock.summary.full_text(), "barHeight": dock.bar_height(),
            "startButton": dock.start_btn.text(), "startButtonHeight": dock.start_btn.height(),
            "workButton": dock.work_btn.text(),
            "page": type(wiz.currentPage()).__name__,
        }
        grab("1-opened-collapsed")
        modal_check("opening")
        dock.set_expanded(True)
        app.processEvents()
        report["dock"]["promptHeight"] = dock.prompt.height()
        report["dock"]["promptVisible"] = dock.prompt.isVisible()
        grab("2-expanded")

        # ── act 2: Start local assistant ──
        dock.start_btn.click()
        pressed_text = dock.start_btn.text()
        ran = pump(lambda: os.path.isfile(record) and dock.start_btn.isEnabled(), 15)
        rec = {}
        if os.path.isfile(record):
            for line in open(record).read().splitlines():
                k, _, v = line.partition("=")
                rec[k] = v
        report["start"] = {
            "buttonSaidWhilePending": pressed_text, "scriptRan": ran and bool(rec),
            "args": rec.get("args"), "ollamaHostSeenByScript": rec.get("OLLAMA_HOST"),
            "ownSession": bool(rec.get("sid")) and rec.get("sid") != str(os.getsid(0)),
            "note": dock.note.text(), "startLogWritten": os.path.isfile(os.path.join(state, "start.log")),
            "workWindowOpened": dock.work_window is not None,
        }
        modal_check("start")
        app.processEvents()            # the button was just re-labelled: let the bar re-lay out before the grab
        grab("3-started")

        # ── act 3a: a half-typed question is abandoned with Escape ──
        # The dock is a text field on a QDialog (the wizard): an Escape the line edit does
        # not take CLOSES THE WHOLE WINDOW. With text in the prompt it must clear the
        # prompt and go no further; the window's `rejected` is watched to prove it.
        from hugmesh_studio.gui.qt import QtGui
        rejected = []
        wiz.rejected.connect(lambda: rejected.append(True))
        dock.prompt.setText("What does the dock ta")
        dock.prompt.setFocus()
        app.processEvents()
        for kind in (QtCore.QEvent.Type.KeyPress, QtCore.QEvent.Type.KeyRelease):
            app.sendEvent(dock.prompt, QtGui.QKeyEvent(
                kind, Qt.Key.Key_Escape, Qt.KeyboardModifier.NoModifier, "\x1b"))
        app.processEvents()
        report["escape"] = {
            "how": "QKeyEvent(Key_Escape) via QApplication.sendEvent",
            "promptAfter": dock.prompt.text(), "windowRejected": bool(rejected),
            "windowVisible": wiz.isVisible(), "promptHasFocus": dock.prompt.hasFocus(),
            "page": type(wiz.currentPage()).__name__,
        }
        grab("3a-escape-cleared-the-prompt")
        modal_check("escape")

        # ── act 3: a question, answered by the loopback model, streaming ──
        # The wizard page is read before and after Enter: a prompt line that let the key
        # travel on would press the wizard's default button (Next) along with sending.
        question = "What does the dock talk to?"
        dock.prompt.setText(question)
        dock.prompt.setFocus()
        app.processEvents()
        page_before = {"id": wiz.currentId(), "title": wiz.currentPage().title(),
                       "page": type(wiz.currentPage()).__name__}
        try:
            # a real Enter key press delivered through Qt's event system (QtTest is not
            # part of every binding install; QKeyEvent is)
            for kind in (QtCore.QEvent.Type.KeyPress, QtCore.QEvent.Type.KeyRelease):
                app.sendEvent(dock.prompt, QtGui.QKeyEvent(
                    kind, Qt.Key.Key_Return, Qt.KeyboardModifier.NoModifier, "\r"))
            enter_how = "QKeyEvent(Key_Return) via QApplication.sendEvent"
        except Exception as exc:  # noqa: BLE001 — say which path fired, never guess
            dock.prompt.returnPressed.emit()
            enter_how = f"returnPressed.emit() (key event failed: {exc})"
        streamed = pump(lambda: fake.chunks[0] in dock.answer.toPlainText(), 15)
        before_clear = dock.answer.toPlainText()
        page_after = {"id": wiz.currentId(), "title": wiz.currentPage().title(),
                      "page": type(wiz.currentPage()).__name__}
        report["prompt"] = {
            "text": question, "enter": enter_how, "promptClearedOnSend": dock.prompt.text() == "",
            "wizardBeforeEnter": page_before, "wizardAfterEnter": page_after,
            "sendButtonWhileBusy": dock.send_btn.text(), "busy": dock._busy,
            "streamedBeforeClear": streamed, "answerBeforeClear": before_clear,
            "requestsToModel": [p for m, p, _ in fake.requests if m == "POST"],
            "modelAsked": next((b.get("model") for m, p, b in fake.requests if m == "POST"), None),
        }
        grab("4-answer-streaming")
        modal_check("prompt")

        # ── act 4: Clear while the answer is still arriving ──
        was_busy = dock._busy
        dock.clear_btn.click()
        right_after = dock.answer.toPlainText()
        pump(lambda: not dock._busy, 15)
        time.sleep(0.8)                                 # any late pieces would land here
        app.processEvents()
        report["clear"] = {
            "pressedWhileBusy": was_busy, "answerRightAfter": right_after,
            "answerAfterTheModelFinished": dock.answer.toPlainText(),
            "historyAfter": len(dock._history), "sendButtonAfter": dock.send_btn.text(),
            "promptEnabled": dock.prompt.isEnabled(),
        }
        grab("5-after-clear")
        modal_check("clear")
        report["width"], report["height"] = wiz.width(), wiz.height()
        wiz.close()
        app.processEvents()
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 — the whole reason is in the report
        report["ok"] = False
        report["errors"].append(f"{type(exc).__name__}: {exc}")
    finally:
        fake.close()
        shutil.rmtree(scratch, ignore_errors=True)
    if report["errors"] or report["modal"]:
        report["ok"] = False
    print(json.dumps(report))
    return 0 if report["ok"] else 4


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
