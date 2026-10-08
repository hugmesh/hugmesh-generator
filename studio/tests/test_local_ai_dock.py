"""The Local AI dock — present on every page, never in the way, never blocking.

A real :class:`StudioShell` opens a real :class:`StudioWizard` offscreen; the model, the
snapshot and the start request are fakes. What each group pins, and what breaks it:

  * PLACEMENT — the dock is visible on EVERY wizard page, collapsed and expanded, inside
    the window, below the Back/Next/Cancel row and covering none of it, at the smallest
    window the Studio supports and at a normal one. Breaks if the dock is mounted on one
    page only, overlaps the buttons, or lets the expanded height eat the page.
  * LOOK — every control is tall enough to click and drawn at its full width, and a long
    status shortens itself instead of pushing a button out.
  * THREADS — polling, prompts and the start request run off the window thread; the
    window keeps painting while a slow one is in flight; nothing starts until the dock is
    shown.
  * NO MODALS — nothing the dock does opens a modal dialog.

The screenshots the operator reads are produced by the same calls (see the lane notes);
what is asserted here is the geometry they show.
"""
import os
import threading
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import local_ai_status as lai                 # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.gui import _local_ai_dock as dock_mod              # noqa: E402
from hugmesh_studio.gui import shell as shell_mod                      # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtCore, QtWidgets               # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

#: the smallest window the Studio opens at (a 1024x600 screen, see wizard.medium_size) and a normal one
SMALLEST = QtCore.QSize(942, 552)
NORMAL = QtCore.QSize(1040, 780)
TINY = QtCore.QSize(588, 441)            # a 640x480 screen: the extreme the clamp still handles


def make_snapshot(**kw):
    s = lai.Snapshot(taken=time.time(), state_dir="/tmp/state", host="127.0.0.1:11434",
                     ollama_installed=True, ollama_up=True, models=["qwen3:8b"], loaded=["qwen3:8b"],
                     worker="running", worker_pid=7, heartbeat_age=2.0,
                     counts={"pending": 2, "running": 1, "stalled": 0, "done": 4, "drafts": 2, "builds": 0})
    s.jobs = [lai.Job("queue", "j1", "draft hugmesh-generator#12", "running"),
              lai.Job("queue", "j2", "draft hugmesh-generator#13", "pending"),
              lai.Job("draft", "hugmesh-generator-9", "hugmesh-generator-9  A title", "applied",
                      "files=1", "/nope", kw.pop("diff_path", "")),
              lai.Job("draft", "hugmesh-generator-8", "hugmesh-generator-8  Other", "does-not-apply", "x")]
    for k, v in kw.items():
        setattr(s, k, v)
    s.summary = lai.summary_line(s)
    return s


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _pinned(monkeypatch, tmp_path):
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": HOST)
    # nothing in this file may reach the Ollama that happens to run on the host
    monkeypatch.setattr(lai, "read_snapshot", lambda *a, **k: make_snapshot())
    monkeypatch.setattr(lai, "send_prompt",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("real model called")))
    monkeypatch.setattr(lai, "start_assistant",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("real start called")))
    monkeypatch.setenv("HUGMESH_LOCAL_AI_DIR", str(tmp_path / "localai"))


@pytest.fixture
def shell(qapp):
    sh = shell_mod.StudioShell(GENERATOR_DIR)
    yield sh
    for w in list(sh.windows):
        try:
            w.close()
            w.deleteLater()
        except RuntimeError:
            pass
    qapp.processEvents()


def wait_for(qapp, cond, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        qapp.processEvents()
        if cond():
            return True
        time.sleep(0.02)
    qapp.processEvents()
    return bool(cond())


def open_at(shell, qapp, size):
    wiz = shell.open_window()
    wiz.resize(size)
    qapp.processEvents()
    qapp.processEvents()
    return wiz


def rect_in(wiz, widget):
    """A widget's rectangle in the wizard's own coordinates."""
    return QtCore.QRect(widget.mapTo(wiz, QtCore.QPoint(0, 0)), widget.size())


def button_rects(wiz):
    out = []
    for b in (QtWidgets.QWizard.WizardButton.BackButton, QtWidgets.QWizard.WizardButton.NextButton,
              QtWidgets.QWizard.WizardButton.CancelButton, QtWidgets.QWizard.WizardButton.HelpButton,
              QtWidgets.QWizard.WizardButton.FinishButton):
        btn = wiz.button(b)
        if btn is not None and btn.isVisible():
            out.append(rect_in(wiz, btn))
    return out


# ── PLACEMENT ────────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("size", [SMALLEST, NORMAL, TINY], ids=["smallest", "normal", "tiny"])
@pytest.mark.parametrize("expanded", [False, True], ids=["collapsed", "expanded"])
def test_dock_is_on_every_page_inside_the_window_and_clear_of_the_buttons(shell, qapp, size, expanded):
    wiz = open_at(shell, qapp, size)
    dock = wiz.local_ai_dock
    dock.set_expanded(expanded)
    seen = []
    for pid in wiz.pageIds():
        wiz.setStartId(pid)
        wiz.restart()
        qapp.processEvents()
        seen.append(pid)
        d = rect_in(wiz, dock)
        win = wiz.rect()
        assert dock.isVisible(), f"dock hidden on page {pid} ({type(wiz.page(pid)).__name__})"
        assert win.contains(d), f"dock {d} sticks out of the window {win} on page {pid}"
        assert d.width() == win.width() and d.bottom() == win.bottom(), "dock is not the bottom strip"
        for b in button_rects(wiz):
            assert not d.intersects(b), (f"dock {d} covers a wizard button {b} on page "
                                         f"{type(wiz.page(pid)).__name__}")
            assert b.bottom() < d.top() + 1, "a wizard button sits below the dock's top edge"
    wiz.setStartId(-1)
    assert len(seen) == len(set(seen)) > 20, "the walk did not visit the whole flow"


def test_the_page_above_the_dock_stays_usable_when_expanded(shell, qapp):
    for size, min_page in ((SMALLEST, 330), (NORMAL, 500), (TINY, 270)):
        wiz = open_at(shell, qapp, size)
        dock = wiz.local_ai_dock
        dock.set_expanded(True)
        qapp.processEvents()
        container = wiz._local_ai_mount.container
        assert container.height() >= min_page, (size, container.height())
        assert dock.height() <= size.height() * 0.4 + 4, (size, dock.height())
        assert container.height() + dock.height() == size.height()
        dock.set_expanded(False)
        wiz.close()


def test_dock_height_function_caps_the_expanded_strip():
    bar = 36
    assert dock_mod.dock_height_for(552, False, bar) == bar
    assert dock_mod.dock_height_for(780, True, bar) == dock_mod.EXPANDED_PX
    assert dock_mod.dock_height_for(552, True, bar) <= 0.4 * 552
    assert dock_mod.dock_height_for(300, True, bar) >= bar + 70      # never smaller than a usable strip


def test_dock_follows_resizes_style_changes_and_restarts(shell, qapp):
    wiz = open_at(shell, qapp, SMALLEST)
    dock = wiz.local_ai_dock
    for size in (NORMAL, TINY, SMALLEST):
        wiz.resize(size)
        qapp.processEvents()
        assert rect_in(wiz, dock).bottom() == wiz.rect().bottom()
        assert not any(rect_in(wiz, dock).intersects(b) for b in button_rects(wiz))
    # QWizard rebuilds parts of its layout when the style changes; the dock must not be dropped
    wiz.setWizardStyle(QtWidgets.QWizard.WizardStyle.ClassicStyle)
    qapp.processEvents()
    wiz.setWizardStyle(QtWidgets.QWizard.WizardStyle.ModernStyle)
    qapp.processEvents()
    wiz.restart()
    qapp.processEvents()
    assert dock.isVisible() and rect_in(wiz, dock).bottom() == wiz.rect().bottom()
    assert not any(rect_in(wiz, dock).intersects(b) for b in button_rects(wiz))
    wiz.next()
    qapp.processEvents()
    assert dock.isVisible() and not any(rect_in(wiz, dock).intersects(b) for b in button_rects(wiz))


def test_every_studio_window_has_its_own_dock_and_mounting_twice_is_harmless(shell, qapp):
    a = shell.open_window()
    b = shell.open_window()
    assert a.local_ai_dock is not b.local_ai_dock
    assert dock_mod.mount_dock(a, GENERATOR_DIR) is a.local_ai_dock


# ── LOOK ─────────────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("size", [SMALLEST, TINY], ids=["smallest", "tiny"])
def test_controls_are_tall_enough_drawn_in_full_and_not_overlapping(shell, qapp, size):
    wiz = open_at(shell, qapp, size)
    dock = wiz.local_ai_dock
    dock.set_expanded(True)
    qapp.processEvents()
    clickable = [dock.chevron, dock.start_btn, dock.work_btn, dock.prompt, dock.send_btn, dock.clear_btn]
    d = dock.rect()
    rects = []
    for w in clickable:
        assert w.isVisible()
        assert w.height() >= 26, f"{w.objectName() or type(w).__name__} is only {w.height()}px tall"
        r = QtCore.QRect(w.mapTo(dock, QtCore.QPoint(0, 0)), w.size())
        assert d.contains(r), f"{type(w).__name__} {r} is clipped by the dock {d}"
        rects.append(r)
    for w in (dock.start_btn, dock.work_btn, dock.send_btn, dock.clear_btn):
        assert w.width() >= w.sizeHint().width() - 1, (
            f"'{w.text()}' is drawn {w.width()}px wide but needs {w.sizeHint().width()}px")
    for i, a in enumerate(rects):
        for b in rects[i + 1:]:
            assert not a.intersects(b), f"two dock controls overlap: {a} {b}"
    assert dock.answer.height() >= 36, "the answer area collapsed"
    assert dock.bar.height() >= 28


def test_a_long_status_shortens_itself_and_pushes_nothing_out(shell, qapp):
    wiz = open_at(shell, qapp, TINY)
    dock = wiz.local_ai_dock
    long_text = "Local AI: " + ", ".join(f"model-number-{i}:70b loaded" for i in range(30))
    dock.summary.set_full_text(long_text)
    qapp.processEvents()
    shown = dock.summary.text()
    assert shown.endswith("…") and len(shown) < len(long_text)
    assert dock.summary.toolTip() == long_text, "the full text must stay reachable"
    d = dock.rect()
    for w in (dock.chevron, dock.summary, dock.start_btn, dock.work_btn):
        r = QtCore.QRect(w.mapTo(dock, QtCore.QPoint(0, 0)), w.size())
        assert d.contains(r), f"{type(w).__name__} pushed out of the dock: {r}"
    assert dock.start_btn.width() >= dock.start_btn.sizeHint().width() - 1
    assert dock.sizeHint().width() < 700 and dock.minimumSizeHint().width() < TINY.width()


def test_a_problem_is_shown_in_words_with_the_fix(shell, qapp):
    wiz = open_at(shell, qapp, SMALLEST)
    dock = wiz.local_ai_dock
    dock.set_expanded(True)
    assert wait_for(qapp, lambda: dock.snapshot is not None)      # the first poll lands before ours
    dock.apply_snapshot(make_snapshot(problem="Ollama is not installed on this machine.",
                                      fix="Install it, then run: scripts/local-ai.sh up",
                                      ollama_up=False, models=[], loaded=[]))
    qapp.processEvents()
    assert dock.note.isVisible()
    assert "not installed" in dock.note.text() and "scripts/local-ai.sh up" in dock.note.text()
    assert "LOCAL-AI-ASSISTANT.md" in dock.note.text()
    assert dock.summary.full_text().startswith("Local AI: Ollama is not installed")


# ── remembering open/closed ──────────────────────────────────────────────────────────
def test_open_or_closed_is_remembered_in_the_studio_state(shell, qapp):
    a = shell.open_window()
    assert a.local_ai_dock.expanded is False                       # first run: collapsed
    a.local_ai_dock.set_expanded(True)
    path = os.path.join(os.environ["HUGMESH_STUDIO_STATE_DIR"], "local-ai-dock.json")
    assert os.path.isfile(path) and '"expanded": true' in open(path).read()
    b = shell.open_window()
    assert b.local_ai_dock.expanded is True
    b.local_ai_dock.set_expanded(False)
    assert shell.open_window().local_ai_dock.expanded is False


# ── THREADS ──────────────────────────────────────────────────────────────────────────
def test_nothing_runs_until_the_dock_is_shown(qapp):
    calls = []
    before = {t.name for t in threading.enumerate()}
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=lambda: calls.append(1) or make_snapshot())
    qapp.processEvents()
    time.sleep(0.2)
    assert calls == [] and not [t for t in threading.enumerate()
                                if t.name.startswith("local-ai-") and t.name not in before]
    dock.show()
    assert wait_for(qapp, lambda: calls)
    dock.close()


def test_polling_runs_off_the_window_thread_and_never_blocks_it(qapp):
    main = threading.get_ident()
    seen, gate = [], threading.Event()

    def slow_snapshot():
        seen.append(threading.get_ident())
        gate.wait(5)
        return make_snapshot()
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=slow_snapshot, auto_poll=False)
    dock.show()
    assert wait_for(qapp, lambda: seen)
    t0 = time.monotonic()
    for _ in range(25):
        qapp.processEvents()                  # the window is alive while the read is stuck
    assert time.monotonic() - t0 < 1.0
    assert seen[0] != main
    gate.set()
    assert wait_for(qapp, lambda: dock.snapshot is not None)
    assert dock.summary.full_text() == lai.summary_line(make_snapshot())
    dock.close()


def test_only_one_read_is_in_flight_at_a_time(qapp):
    n, gate = [], threading.Event()
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=lambda: n.append(1) or gate.wait(3) or make_snapshot(),
                                auto_poll=False)
    dock.show()
    assert wait_for(qapp, lambda: n)
    for _ in range(5):
        dock.refresh()
    time.sleep(0.2)
    assert len(n) == 1
    gate.set()
    wait_for(qapp, lambda: dock.snapshot is not None)
    dock.close()


def test_enter_sends_the_prompt_on_a_worker_thread_and_the_answer_streams_in(qapp):
    main = threading.get_ident()
    where, gate = [], threading.Event()

    def prompt_fn(text, history, on_chunk, should_stop):
        where.append(threading.get_ident())
        on_chunk("First part, ")
        gate.wait(5)
        on_chunk("second part.")
        return "First part, second part."
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=make_snapshot, prompt_fn=prompt_fn,
                                auto_poll=False, expanded=True)
    dock.show()
    dock.prompt.setText("hello there")
    dock.prompt.returnPressed.emit()                              # what Enter does
    assert dock.prompt.text() == "" and dock.send_btn.text() == "Stop"
    assert wait_for(qapp, lambda: "First part, " in dock.answer.toPlainText())
    assert where and where[0] != main
    assert "You: hello there" in dock.answer.toPlainText()
    assert dock._busy
    gate.set()
    assert wait_for(qapp, lambda: not dock._busy)
    assert "First part, second part." in dock.answer.toPlainText()
    assert dock.send_btn.text() == "Send"
    assert dock._history[-1] == {"role": "assistant", "content": "First part, second part."}
    dock.close()


def test_a_second_prompt_carries_the_conversation_and_clear_forgets_it(qapp):
    seen = []

    def prompt_fn(text, history, on_chunk, should_stop):
        seen.append(list(history))
        on_chunk("ok")
        return "ok"
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=make_snapshot, prompt_fn=prompt_fn,
                                auto_poll=False, expanded=True)
    dock.show()
    for text in ("one", "two"):
        dock.prompt.setText(text)
        dock.send()
        assert wait_for(qapp, lambda: not dock._busy)
    assert seen[0] == [] and [m["content"] for m in seen[1]] == ["one", "ok"]
    dock.clear()
    assert dock._history == [] and dock.answer.toPlainText() == ""
    dock.close()


def test_stop_ends_a_running_answer(qapp):
    stopped = threading.Event()

    def prompt_fn(text, history, on_chunk, should_stop):
        on_chunk("x")
        for _ in range(200):
            if should_stop():
                stopped.set()
                break
            time.sleep(0.02)
        return "x"
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=make_snapshot, prompt_fn=prompt_fn,
                                auto_poll=False, expanded=True)
    dock.show()
    dock.prompt.setText("long one")
    dock.send()
    assert wait_for(qapp, lambda: dock._busy and "x" in dock.answer.toPlainText())
    dock.send_btn.click()                                           # the button says Stop now
    assert wait_for(qapp, lambda: stopped.is_set() and not dock._busy)
    dock.close()


def test_a_failed_prompt_says_why_and_the_dock_stays_usable(qapp):
    def prompt_fn(text, history, on_chunk, should_stop):
        raise lai.LocalAIError("Ollama is not answering on 127.0.0.1:11434. Start it with scripts/local-ai.sh up")
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=make_snapshot, prompt_fn=prompt_fn,
                                auto_poll=False, expanded=True)
    dock.show()
    dock.prompt.setText("hi")
    dock.send()
    assert wait_for(qapp, lambda: not dock._busy)
    assert "scripts/local-ai.sh up" in dock.note.text() and dock.note.isVisible()
    assert "scripts/local-ai.sh up" in dock.answer.toPlainText()
    assert dock.send_btn.text() == "Send" and dock.prompt.isEnabled()
    dock.close()


def test_start_runs_off_the_window_thread_and_reports_inline(qapp):
    main = threading.get_ident()
    where = []

    def start_fn():
        where.append(threading.get_ident())
        return lai.StartResult(True, "Starting the local assistant; the status line updates.", "x start")
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=make_snapshot, start_fn=start_fn,
                                auto_poll=False, expanded=True)
    dock.show()
    dock.start_btn.click()
    assert dock.start_btn.text() == "Starting…" and not dock.start_btn.isEnabled()
    assert wait_for(qapp, lambda: dock.start_btn.isEnabled())
    assert where[0] != main and dock.start_btn.text() == "Start local assistant"
    assert "Starting the local assistant" in dock.note.text()
    assert dock.work_window is None, "a successful start must not open anything uninvited"
    dock.close()


def test_when_it_cannot_start_the_work_window_opens_with_the_exact_command(qapp):
    def start_fn():
        return lai.StartResult(False, "scripts/local-ai.sh is missing.", "/x/scripts/local-ai.sh start")
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=make_snapshot, start_fn=start_fn,
                                auto_poll=False, expanded=True)
    dock.show()
    dock.start_btn.click()
    assert wait_for(qapp, lambda: dock.work_window is not None and dock.work_window.isVisible())
    assert "/x/scripts/local-ai.sh start" in dock.note.text()
    assert "local-ai.sh start" in dock.work_window.commands.text()
    dock.work_window.close()
    dock.close()


def test_a_start_that_raises_is_reported_not_swallowed(qapp):
    def start_fn():
        raise RuntimeError("boom")
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=make_snapshot, start_fn=start_fn,
                                auto_poll=False, expanded=True)
    dock.show()
    dock.start_btn.click()
    assert wait_for(qapp, lambda: dock.start_btn.isEnabled())
    assert "boom" in dock.note.text()
    dock.work_window.close()
    dock.close()


def test_a_closed_window_mid_request_leaves_nothing_calling_into_it(shell, qapp):
    gate = threading.Event()

    def prompt_fn(text, history, on_chunk, should_stop):
        gate.wait(5)
        on_chunk("late")
        return "late"
    wiz = shell.open_window()
    dock = wiz.local_ai_dock
    dock._prompt_fn = prompt_fn
    dock.prompt.setText("hi")
    dock.send()
    wiz.close()
    wiz.deleteLater()
    qapp.processEvents()
    gate.set()
    time.sleep(0.2)
    qapp.processEvents()                                             # must not crash


# ── NO MODALS ────────────────────────────────────────────────────────────────────────
def test_nothing_the_dock_does_opens_a_modal_dialog(qapp):
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=make_snapshot, auto_poll=False, expanded=True,
                                prompt_fn=lambda *a: "x",
                                start_fn=lambda: lai.StartResult(False, "no", "cmd"))
    dock.show()
    dock.set_expanded(False)
    dock.set_expanded(True)
    dock.prompt.setText("q")
    dock.send()
    wait_for(qapp, lambda: not dock._busy)
    dock.start_btn.click()
    wait_for(qapp, lambda: dock.work_window is not None)
    dock.show_current_work()
    qapp.processEvents()
    assert QtWidgets.QApplication.activeModalWidget() is None
    assert dock.work_window.windowModality() == Qt.WindowModality.NonModal
    assert not dock.work_window.isModal()
    dock.work_window.close()
    dock.close()


# ── the Current work window ──────────────────────────────────────────────────────────
def test_current_work_lists_everything_and_opens_a_draft_diff(qapp, tmp_path):
    diff = tmp_path / "draft.diff"
    diff.write_text("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n")
    snap = make_snapshot(diff_path=str(diff))
    win = dock_mod.LocalWorkWindow(GENERATOR_DIR, snapshot_fn=lambda: snap, auto_poll=False)
    win.show()
    assert wait_for(qapp, lambda: win.snapshot is not None)
    assert win.tree.topLevelItemCount() == len(snap.jobs) == 4
    assert win.summary.text() == snap.summary
    states = [win.tree.topLevelItem(i).text(1) for i in range(4)]
    assert states == ["running", "pending", "applied", "does-not-apply"]
    assert "qwen3:8b" in win.facts.text() and "running" in win.facts.text()
    assert not win.diff_btn.isEnabled()
    win.tree.setCurrentItem(win.tree.topLevelItem(2))            # the applied draft has a diff
    assert win.diff_btn.isEnabled()
    win.diff_btn.click()
    assert "+new" in win.diff_view.toPlainText()
    win.tree.setCurrentItem(win.tree.topLevelItem(3))            # the one that does not apply has none
    assert not win.diff_btn.isEnabled()
    win.close()


def test_current_work_refreshes_now_and_every_five_seconds_while_open(qapp):
    n = []
    win = dock_mod.LocalWorkWindow(GENERATOR_DIR, snapshot_fn=lambda: n.append(1) or make_snapshot())
    assert win._timer.interval() == 5000
    assert not win._timer.isActive()
    win.show()
    assert win._timer.isActive()
    assert wait_for(qapp, lambda: len(n) >= 1)
    # a click while a read is still in flight is folded into it on purpose, so let the first land
    assert wait_for(qapp, lambda: not win._threads.in_flight)
    win.refresh_btn.click()
    assert wait_for(qapp, lambda: len(n) >= 2)
    win.hide()
    assert not win._timer.isActive()
    win.close()


def test_current_work_shows_a_problem_with_its_fix(qapp):
    snap = make_snapshot(problem="Ollama is not installed on this machine.",
                         fix="Install it, then run: scripts/local-ai.sh up", ollama_up=False)
    win = dock_mod.LocalWorkWindow(GENERATOR_DIR, snapshot_fn=lambda: snap, auto_poll=False)
    win.show()
    wait_for(qapp, lambda: win.snapshot is not None)
    assert win.problem.isVisible() and "not installed" in win.problem.text()
    assert "LOCAL-AI-ASSISTANT.md" in win.problem.text()
    win.close()


def test_the_current_work_button_opens_one_reusable_window(shell, qapp):
    wiz = open_at(shell, qapp, SMALLEST)
    dock = wiz.local_ai_dock
    dock.work_btn.click()
    first = dock.work_window
    assert first is not None and first.isVisible()
    assert first.windowFlags() & Qt.WindowType.Window
    dock.work_btn.click()
    assert dock.work_window is first
    first.close()


def test_clear_during_an_answer_is_not_undone_by_the_answer_arriving_late(qapp):
    """Clear says 'Forget the conversation'. The answer that was still on its way when it
    was pressed must not put the question and its reply back into the history, nor its
    words back on the screen, or the next prompt would carry what the person forgot."""
    gate, seen = threading.Event(), []

    def prompt_fn(text, history, on_chunk, should_stop):
        seen.append(list(history))
        on_chunk("partial answer")
        gate.wait(5)
        on_chunk(" and the rest")
        return "partial answer and the rest"
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=make_snapshot, prompt_fn=prompt_fn,
                                auto_poll=False, expanded=True)
    dock.show()
    dock.prompt.setText("q1")
    assert dock.send()
    assert wait_for(qapp, lambda: "partial answer" in dock.answer.toPlainText())
    dock.clear()                                               # mid-answer
    assert dock._history == [] and dock.answer.toPlainText() == ""
    gate.set()
    assert wait_for(qapp, lambda: not dock._busy)
    assert dock._history == [], dock._history
    assert dock.answer.toPlainText() == "", dock.answer.toPlainText()
    dock.prompt.setText("q2")
    assert dock.send()
    assert wait_for(qapp, lambda: not dock._busy)
    assert seen[1] == [], "the next prompt carried what Clear had forgotten"
    dock.close()


def test_an_error_from_a_cleared_question_is_not_shown_on_the_clean_screen(qapp):
    gate = threading.Event()

    def prompt_fn(text, history, on_chunk, should_stop):
        gate.wait(5)
        raise lai.LocalAIError("old failure")
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=make_snapshot, prompt_fn=prompt_fn,
                                auto_poll=False, expanded=True)
    dock.show()
    dock.prompt.setText("q1")
    dock.send()
    dock.clear()
    gate.set()
    assert wait_for(qapp, lambda: not dock._busy)
    assert "old failure" not in dock.answer.toPlainText()
    assert dock.send_btn.text() == "Send" and dock.prompt.isEnabled()
    dock.close()


def test_a_second_prompt_is_refused_while_one_is_running(qapp):
    """One question at a time: sending while the model is busy must start nothing."""
    gate, calls = threading.Event(), []

    def prompt_fn(text, history, on_chunk, should_stop):
        calls.append(text)
        gate.wait(5)
        return "ok"
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=make_snapshot, prompt_fn=prompt_fn,
                                auto_poll=False, expanded=True)
    dock.show()
    dock.prompt.setText("first")
    assert dock.send() is True
    dock.prompt.setText("second")
    assert dock.send() is False
    assert dock.prompt.text() == "second"                      # kept, not swallowed
    time.sleep(0.2)
    assert calls == ["first"]
    gate.set()
    assert wait_for(qapp, lambda: not dock._busy)
    dock.close()
