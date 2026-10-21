"""The Studio's bottom panel: the local-mesh actions, the running mesh, the run log and the
image builds, docked at the bottom of every Studio window (operator ask 2026-10-21).

A real :class:`StudioShell` opens a real window offscreen. What each test pins, and what
breaks it:

  * WHERE THE PARTS LIVE — the local-mesh page's Actions box, its running-mesh monitor and
    its run view are IN the panel from the moment the window opens, and no page takes them
    back as the person walks the flow (the join, review and bring-up steps all used to
    claim the run view on every show). Breaks if ``take_section``'s dock rule goes.
  * BUILDS KEEP RUNNING — a streaming verb keeps writing into its log while the person
    goes back to the first page, collapses the panel and pops it out; the panel opens on
    the run when a verb starts; the "what is running" line and the builds list say so.
  * THE POD VIEW STAYS LIVE — the monitor's 10 s tick reads the TABLE's visibility, so it
    still refreshes when the bring-up page is hidden but the panel shows the table.
  * POP OUT AND BACK — the same widgets move into a window of their own and back; the
    strip shrinks to its bar while popped.
  * KEYS — Enter on a drop-down of the Local mesh tab does not press the wizard's Next.
  * LOOK — screenshots of the panel collapsed, open on each tab, and popped out, with the
    geometry asserted: every control drawn inside the window, big enough to click.

Set STUDIO_PANEL_SHOTS=<dir> to keep the PNGs (they are written to a temp folder
otherwise, and their paths printed).
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
from hugmesh_studio.gui import build_supervisor                        # noqa: E402
from hugmesh_studio.gui import shell as shell_mod                      # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.pages import localmesh as lm                   # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtCore, QtGui, QtWidgets        # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")
NORMAL = QtCore.QSize(1040, 780)
SMALLEST = QtCore.QSize(942, 552)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-panel-tests"]))


@pytest.fixture(autouse=True)
def _pinned(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": HOST)
    snap = lai.Snapshot(taken=time.time(), state_dir="/nonexistent", host="127.0.0.1:11434",
                        ollama_installed=True, ollama_up=True, models=["qwen3:8b"],
                        loaded=["qwen3:8b"], worker="running", worker_pid=7, heartbeat_age=1.0,
                        counts={"pending": 0, "running": 0, "stalled": 0, "done": 3,
                                "drafts": 1, "builds": 0})
    snap.summary = lai.summary_line(snap)
    monkeypatch.setattr(lai, "read_snapshot", lambda *a, **k: snap)
    monkeypatch.setattr(lai, "send_prompt",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("real model called")))
    monkeypatch.setattr(lai, "start_assistant",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("real start called")))
    # the mesh-state probe the Local mesh tab kicks: answered at once, no docker
    monkeypatch.setattr(lm.LocalMeshPage, "_probe_mesh_state", lambda self: None)
    # Docker mode's read-only looks (docker version/inspect/info): scripted, no docker
    from hugmesh_studio.core import ollama_docker as odk
    monkeypatch.setattr(odk, "state", lambda runner=None: odk.DockerState(True))
    monkeypatch.setattr(odk, "detect_gpu", lambda runner=None, **k: odk.GpuChoice(
        "cpu", (), odk.IMAGE, "CPU only: scripted for the test."))


@pytest.fixture
def shell(qapp):
    sh = shell_mod.StudioShell(GENERATOR_DIR)
    yield sh
    for w in list(sh.windows):
        dock = getattr(w, "local_ai_dock", None)
        try:
            if dock is not None and dock.panel_window is not None:
                dock.panel_window.close()
            w.close()
            w.deleteLater()
        except RuntimeError:
            pass
    qapp.processEvents()


def settle(qapp, n=4):
    for _ in range(n):
        qapp.processEvents()


def wait_for(qapp, cond, timeout=8.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        qapp.processEvents()
        if cond():
            return True
        time.sleep(0.02)
    qapp.processEvents()
    return bool(cond())


def open_at(shell, qapp, size=NORMAL):
    wiz = shell.open_window()
    wiz.resize(size)
    settle(qapp)
    return wiz


def to_bringup(wiz, qapp):
    """Welcome -> mode (local mesh) -> generate -> ... -> the Bring-up step."""
    wiz.next()
    mode = wiz.currentPage()
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    wiz.next()
    wiz.currentPage()._buttons["generate"].setChecked(True)
    for _ in range(16):
        if isinstance(wiz.currentPage(), lm.LocalMeshPage):
            break
        wiz.next()
        settle(qapp, 2)
    assert isinstance(wiz.currentPage(), lm.LocalMeshPage)
    settle(qapp)
    return wiz.localmesh_page


def rect_in(ancestor, widget):
    return QtCore.QRect(widget.mapTo(ancestor, QtCore.QPoint(0, 0)), widget.size())


SHOTS = os.environ.get("STUDIO_PANEL_SHOTS", "")


def shot(widget, name, tmp_path_factory=None):
    folder = SHOTS or os.path.join(os.environ.get("TMPDIR", "/tmp"), "studio-panel-shots")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"panel-{name}.png")
    assert widget.grab().save(path), path
    print("screenshot:", path)
    return path


# ── where the parts live ─────────────────────────────────────────────────────────────
def test_the_mesh_parts_are_in_the_panel_from_the_start(shell, qapp):
    wiz = open_at(shell, qapp)
    dock, ctl = wiz.local_ai_dock, wiz.localmesh_page
    assert set(ctl.docked_parts()) == {"actions", "monitor", "run"}
    for part in (ctl.actions_box, ctl.monitor_section, ctl.run_view, ctl.boot_start_btn,
                 ctl.devops_up_btn, ctl.log, ctl.stage_tree, ctl.monitor):
        assert dock.isAncestorOf(part), part
        assert not ctl.isAncestorOf(part), part
    assert [dock.tabs.tabText(i) for i in range(dock.tabs.count())] == [t for _k, t in dock_mod.TABS]
    # the placeholders are gone once the parts arrived
    for key in ("mesh", "pods", "run"):
        assert dock._hosts[key][2].isHidden(), key


def test_the_bringup_step_says_where_its_parts_went_and_opens_the_panel_on_them(shell, qapp):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    dock.set_expanded(False)
    ctl = to_bringup(wiz, qapp)
    assert ctl.dock_note.isVisible()
    assert "panel at the bottom of this window" in ctl.dock_note_label.text()
    assert dock.expanded and dock.current_tab() == "mesh", "arriving did not open the panel"
    assert ctl.boot_start_btn.isVisible()
    dock.show_tab("assistant")
    ctl.dock_note_btn.click()
    assert dock.current_tab() == "mesh"
    shot(wiz, "bringup-step-panel-open-on-local-mesh")


def test_no_page_takes_the_parts_back_on_any_step_of_either_branch(shell, qapp):
    wiz = open_at(shell, qapp)
    dock, ctl = wiz.local_ai_dock, wiz.localmesh_page
    for join in (True, False):
        wiz.localmesh_selected = True
        wiz.localmesh_join_selected = join
        for pid in wiz.pageIds():
            page = wiz.page(pid)
            if not isinstance(page, (lm.LocalMeshPage, lm._LocalMeshStep)):
                continue
            wiz.setStartId(pid)
            wiz.restart()
            settle(qapp, 2)
            for part in (ctl.run_view, ctl.actions_box, ctl.monitor_section):
                assert dock.isAncestorOf(part), (type(page).__name__, part)
    wiz.setStartId(-1)


def test_a_window_without_a_panel_keeps_everything_on_the_page(qapp):
    """The standalone frame (no panel) is unchanged: the parts stay on the page."""
    dlg = lm.LocalMeshDialog(GENERATOR_DIR)
    try:
        page = dlg.page
        assert page.docked_parts() == ()
        for part in (page.actions_box, page.monitor_section, page.run_view):
            assert page.isAncestorOf(part)
        assert page.dock_note.isHidden()
    finally:
        dlg.close()
        dlg.deleteLater()


# ── builds keep running ───────────────────────────────────────────────────────────────
class FakeVerb:
    """A streaming verb that writes a line whenever the test says, and ends on release."""

    def __init__(self):
        self.say = []
        self.release = threading.Event()
        self.lock = threading.Lock()

    def __call__(self, on_line, cancel):
        sent = 0
        while not self.release.is_set():
            with self.lock:
                pending = self.say[sent:]
                sent = len(self.say)
            for line in pending:
                on_line(line)
            time.sleep(0.02)
        with self.lock:
            for line in self.say[sent:]:
                on_line(line)
        return True, []

    def emit(self, line):
        with self.lock:
            self.say.append(line)


def test_a_verb_keeps_running_and_streaming_while_the_person_moves_collapses_and_pops_out(
        shell, qapp):
    wiz = open_at(shell, qapp)
    dock, ctl = wiz.local_ai_dock, wiz.localmesh_page
    dock.set_expanded(False)
    dock.show_tab("assistant")
    dock.set_expanded(False)
    verb = FakeVerb()
    ctl._launch("Bootstrapping a test mesh", verb, stream=True)
    try:
        assert ctl._running
        assert dock.expanded and dock.current_tab() == "run", "a starting verb did not open the run"
        assert wait_for(qapp, lambda: "Mesh: Bootstrapping a test mesh running"
                        in dock.activity.full_text()), dock.activity.full_text()
        verb.emit("line one on the welcome page")
        assert wait_for(qapp, lambda: "line one" in ctl.log.toPlainText())
        # another page
        wiz.next()
        settle(qapp)
        verb.emit("line two on the mode page")
        assert wait_for(qapp, lambda: "line two" in ctl.log.toPlainText())
        # collapsed
        dock.set_expanded(False)
        verb.emit("line three while collapsed")
        assert wait_for(qapp, lambda: "line three" in ctl.log.toPlainText())
        # popped out
        win = dock.pop_out()
        settle(qapp)
        assert win.isVisible() and win.isAncestorOf(ctl.log)
        verb.emit("line four while popped out")
        assert wait_for(qapp, lambda: "line four" in ctl.log.toPlainText())
        dock.show_tab("builds")
        dock.refresh_activity()
        rows = [dock.builds_tree.topLevelItem(i).text(0)
                for i in range(dock.builds_tree.topLevelItemCount())]
        assert rows == ["Local mesh: Bootstrapping a test mesh"], rows
        shot(win, "popped-out-builds-while-a-verb-runs")
        win.close()                                    # closing the window puts it back
        settle(qapp)
        assert not dock.popped and dock.isAncestorOf(ctl.log)
        verb.emit("line five after putting it back")
    finally:
        verb.release.set()
    assert wait_for(qapp, lambda: not ctl._running, 15)
    text = ctl.log.toPlainText()
    for n in ("one", "two", "three", "four", "five"):
        assert f"line {n}" in text, n
    assert wait_for(qapp, lambda: "Mesh: idle" in dock.activity.full_text())


def test_the_builds_tab_lists_image_builds_and_shows_the_one_picked(shell, qapp):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock

    class Worker:
        def isRunning(self):
            return True

    shown = []
    dock._open_build = lambda session: shown.append(session.id)
    sup = build_supervisor.supervisor()
    run = sup.adopt(session_id="20261021-test", label="x86 desktop image", worker=Worker(),
                    driver=None, window=wiz)
    try:
        dock.show_tab("builds")
        dock.refresh_activity()
        assert "1 image build running" in dock.activity.full_text()
        item = dock.builds_tree.topLevelItem(0)
        assert item.text(0) == "x86 desktop image" and item.text(1) == "running"
        assert dock.build_show_btn.isEnabled()
        dock.build_show_btn.click()
        assert shown == ["20261021-test"]
        shot(wiz, "builds-tab-one-image-build")
    finally:
        run.finished = True
        sup.release(run)
    dock.refresh_activity()
    assert "no image build running" in dock.activity.full_text()


def test_the_shell_wires_show_this_build_to_the_trays_own_door(shell, qapp):
    wiz = open_at(shell, qapp)
    assert wiz.local_ai_dock._open_build == shell.open_build_window


# ── the pod view stays live in the panel ──────────────────────────────────────────────
def test_the_pod_table_keeps_refreshing_on_another_page_while_the_panel_shows_it(
        shell, qapp, monkeypatch):
    wiz = open_at(shell, qapp)
    dock, ctl = wiz.local_ai_dock, wiz.localmesh_page
    reads = []
    monkeypatch.setattr(ctl, "_refresh_monitor", lambda reason="": reads.append(reason) or True)
    dock.show_tab("pods")
    settle(qapp)
    assert ctl.monitor_section.is_expanded(), "opening the tab should open the table"
    assert not ctl.isVisible(), "the test needs the bring-up page hidden"
    reads.clear()
    ctl._on_monitor_tick()
    assert reads == ["tick"], "the 10 s tick stood down while the table was on screen"
    ctl.hide()                                          # what leaving the page does
    ctl.hideEvent(QtGui.QHideEvent())
    assert ctl._monitor_timer.isActive(), "leaving the page stopped the panel's poll"
    dock.show_tab("assistant")                          # the table off screen: no reads
    settle(qapp)
    reads.clear()
    ctl._on_monitor_tick()
    assert reads == []


# ── pop out and back ──────────────────────────────────────────────────────────────────
def test_pop_out_moves_the_tabs_into_a_window_and_back(shell, qapp):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    dock.set_expanded(True)
    settle(qapp)
    expanded_h = dock.height()
    win = dock.pop_out()
    settle(qapp)
    assert dock.popped and win.isVisible() and win.isAncestorOf(dock.tabs)
    assert not dock.isAncestorOf(dock.tabs)
    assert dock.height() < expanded_h and dock.height() <= dock.bar_height() + 2, \
        "the strip did not shrink to its bar while popped out"
    assert dock.pop_btn.text() == "Put back"
    assert not win.isModal() and win.windowModality() == Qt.WindowModality.NonModal
    dock.pop_btn.click()
    settle(qapp)
    assert not dock.popped and dock.isAncestorOf(dock.tabs) and not win.isVisible()
    assert dock.height() == expanded_h
    # the chevron on a popped panel brings it home too
    dock.pop_out()
    dock.chevron.click()
    settle(qapp)
    assert not dock.popped and dock.expanded


def test_escape_in_the_popped_window_puts_it_back_and_closes_no_studio(shell, qapp):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    win = dock.pop_out()
    settle(qapp)
    for kind in (QtCore.QEvent.Type.KeyPress, QtCore.QEvent.Type.KeyRelease):
        qapp.sendEvent(win, QtGui.QKeyEvent(kind, Qt.Key.Key_Escape, Qt.KeyboardModifier.NoModifier))
    settle(qapp)
    assert not dock.popped and wiz.isVisible()


# ── keys ────────────────────────────────────────────────────────────────────────────
def test_enter_on_a_local_mesh_drop_down_does_not_press_next(shell, qapp):
    wiz = open_at(shell, qapp)
    dock, ctl = wiz.local_ai_dock, wiz.localmesh_page
    dock.show_tab("mesh")
    settle(qapp)
    before = wiz.currentId()
    combo = ctl.e2e_env_combo
    combo.setFocus()
    for kind in (QtCore.QEvent.Type.KeyPress, QtCore.QEvent.Type.KeyRelease):
        qapp.sendEvent(combo, QtGui.QKeyEvent(kind, Qt.Key.Key_Return,
                                              Qt.KeyboardModifier.NoModifier, "\r"))
    settle(qapp)
    assert wiz.currentId() == before, "Enter in the panel pressed the wizard's Next"


# ── look ────────────────────────────────────────────────────────────────────────────
def _into_view(w):
    """Scroll ``w`` into view in the panel tab that holds it (a tall tab scrolls)."""
    p = w.parentWidget()
    while p is not None and not isinstance(p, QtWidgets.QScrollArea):
        p = p.parentWidget()
    if p is not None:
        for _ in range(3):                  # a flow layout settles over a few passes
            QtWidgets.QApplication.processEvents()
            p.ensureWidgetVisible(w, 0, 0)
        QtWidgets.QApplication.processEvents()


def _assert_drawn(wiz, widgets):
    win = wiz.rect()
    for w in widgets:
        _into_view(w)
        assert w.isVisible() and w.isEnabled() or w.isVisible(), w
        r = rect_in(wiz, w)
        assert win.contains(r), (type(w).__name__, getattr(w, "text", lambda: "")(), r)
        assert r.height() >= 20 and r.width() >= 24, (type(w).__name__, r)
        if isinstance(w, QtWidgets.QAbstractButton) and w.text():
            assert r.width() >= w.fontMetrics().horizontalAdvance(w.text().replace("&&", "&")) + 6, \
                ("label clipped", w.text(), r.width())


@pytest.mark.parametrize("size", [NORMAL, SMALLEST], ids=["1040x780", "942x552"])
def test_the_panel_looks_right_collapsed_open_on_every_tab_and_popped_out(shell, qapp, size):
    wiz = open_at(shell, qapp, size)
    dock, ctl = wiz.local_ai_dock, wiz.localmesh_page
    tag = f"{size.width()}x{size.height()}"
    dock.set_expanded(False)
    settle(qapp)
    _assert_drawn(wiz, [dock.chevron, dock.start_btn, dock.work_btn, dock.pop_btn])
    assert dock.activity.isVisible() and dock.summary.isVisible()
    shot(wiz, f"collapsed-{tag}")
    dock.set_expanded(True)
    for key, controls in (
            ("assistant", [dock.prompt, dock.send_btn, dock.clear_btn, dock.mode_system,
                           dock.mode_docker]),
            ("mesh", [ctl.boot_start_btn, ctl.boot_down_btn]),
            ("pods", [ctl.monitor.refresh_btn, ctl.monitor.copy_btn]),
            ("run", [ctl.stage_tree]),
            ("builds", [dock.build_show_btn])):
        dock.show_tab(key)
        settle(qapp)
        _assert_drawn(wiz, controls)
        shot(wiz, f"open-{key}-{tag}")
    # the Docker choice is a real, clickable control, and picking it shows its buttons
    dock.show_tab("assistant")
    dock.mode_docker.click()
    settle(qapp)
    assert dock.ollama_mode == "docker"
    dock.options_scroll.ensureWidgetVisible(dock.docker_start_btn, 0, 0)
    settle(qapp)
    assert dock.docker_start_btn.isVisible() and dock.docker_stop_btn.isVisible()
    assert "Ollama in Docker" in dock.instance_label.text()
    shot(wiz, f"open-assistant-docker-mode-{tag}")
    dock.mode_system.click()
    win = dock.pop_out()
    win.resize(980, 640)
    dock.show_tab("mesh")
    settle(qapp)
    assert win.isAncestorOf(ctl.boot_start_btn) and ctl.boot_start_btn.isVisible()
    shot(win, f"popped-out-window-{tag}")
    shot(wiz, f"popped-out-studio-window-{tag}")
    win.close()
    settle(qapp)


# ── a refused press says why where the person is looking (skeptic blocker 2026-10-21) ──
# The status line lives on the Mesh run tab; the buttons that write to it live on the
# Local mesh tab, on step pages and on the Running mesh tab. A press that starts nothing
# must still change what is on screen: its reason is copied above the Actions buttons,
# and when that copy is not on screen either, the panel opens on the status line.
def _visible_text_in(wiz, text):
    """Labels in the window that are ON SCREEN and show ``text`` (the person sees it)."""
    hits = []
    for lbl in wiz.findChildren(QtWidgets.QLabel):
        if text in lbl.text() and lbl.isVisible() and lbl.height() > 0:
            hits.append(lbl)
    return hits


def _launches(monkeypatch, ctl):
    launched = []
    monkeypatch.setattr(ctl, "_launch", lambda label, *a, **k: launched.append(label))
    return launched


def test_generate_on_another_page_arms_first_and_then_says_why_it_cannot_start(
        shell, qapp, monkeypatch):
    wiz = open_at(shell, qapp)
    dock, ctl = wiz.local_ai_dock, wiz.localmesh_page
    launched = _launches(monkeypatch, ctl)
    monkeypatch.setattr(ctl, "_domain_row_problems",
                        lambda: ["row 2: 'bad domain' is not a domain name"])
    dock.show_tab("mesh")
    settle(qapp)
    assert not isinstance(wiz.currentPage(), (lm.LocalMeshPage, lm._LocalMeshStep))
    # first press on the Welcome page: armed, nothing started, and it says so HERE
    ctl.boot_start_btn.click()
    settle(qapp)
    assert launched == []
    assert ctl.boot_start_btn.text() == "Press again to start"
    assert dock.current_tab() == "mesh", "the panel jumped away from the button"
    assert ctl.action_status.isVisible() and "Press it again" in ctl.action_status.text()
    assert _visible_text_in(wiz, "Press it again"), "the reason is not on screen"
    r = rect_in(wiz, ctl.action_status)
    assert wiz.rect().contains(r) and r.height() >= 14, r
    shot(wiz, "refused-armed-on-welcome")
    # second press: the gate runs, refuses, and the refusal is next to the button
    ctl.boot_start_btn.click()
    settle(qapp)
    assert launched == []
    assert ctl.boot_start_btn.text() == "Generate && start"
    assert "bad domain" in ctl.status.text()
    assert ctl.action_status.isVisible() and "bad domain" in ctl.action_status.text()
    assert _visible_text_in(wiz, "bad domain"), "a refused Generate & start is invisible"
    shot(wiz, "refused-generate-on-welcome")


def test_on_the_bringup_step_one_press_runs_the_gate_and_its_refusal_is_on_screen(
        shell, qapp, monkeypatch):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    ctl = to_bringup(wiz, qapp)
    launched = _launches(monkeypatch, ctl)
    monkeypatch.setattr(ctl, "_domain_row_problems",
                        lambda: ["row 2: 'bad domain' is not a domain name"])
    assert dock.current_tab() == "mesh"
    ctl.boot_start_btn.click()
    settle(qapp)
    assert launched == [] and ctl.boot_start_btn.text() == "Generate && start"
    assert _visible_text_in(wiz, "bad domain")
    # a press that passes the gate still starts on the first click on this step
    monkeypatch.setattr(ctl, "_domain_row_problems", lambda: [])
    monkeypatch.setattr(ctl, "_domain_services_refusal", lambda: "")
    monkeypatch.setattr(lm.LocalMeshBootstrap, "validate", lambda self: [])
    ctl.boot_start_btn.click()
    settle(qapp)
    assert launched == ["Bootstrapping"], launched


@pytest.mark.parametrize("where", ["collapsed", "popped", "other-tab"])
def test_a_refusal_from_outside_the_actions_opens_the_panel_on_its_reason(
        shell, qapp, monkeypatch, where):
    wiz = open_at(shell, qapp)
    dock, ctl = wiz.local_ai_dock, wiz.localmesh_page
    launched = _launches(monkeypatch, ctl)
    if where == "collapsed":
        dock.set_expanded(False)
    elif where == "popped":
        dock.show_tab("assistant")
        dock.pop_out().hide()                 # popped, and its window behind/closed
        dock.popped = True
    else:
        dock.show_tab("pods")
    settle(qapp)
    # a saved mesh's Start (review step) over a live mesh: refused, no verb
    ctl._mesh_up = True
    ctl._start_saved(None, "start")
    settle(qapp)
    assert launched == []
    assert "stop it first" in ctl.status.text()
    assert dock.current_tab() == "run"
    assert ctl.status.isVisible(), f"refusal not on screen ({where})"
    if where == "popped":
        assert dock.panel_window.isVisible()
    else:
        assert dock.expanded
    assert _visible_text_in(wiz if where != "popped" else dock.panel_window, "stop it first")
    if where == "collapsed":
        shot(wiz, "refused-saved-start-opens-panel")


def test_a_pod_rows_refused_open_is_shown(shell, qapp):
    wiz = open_at(shell, qapp)
    dock, ctl = wiz.local_ai_dock, wiz.localmesh_page
    dock.show_tab("pods")
    settle(qapp)
    ctl._open_door("javascript:alert(1)")
    settle(qapp)
    assert ctl.status.text().startswith("Not opened:")
    assert ctl.status.isVisible() and dock.current_tab() == "run"


def test_without_a_panel_the_status_line_stays_on_the_page_and_has_no_copy(qapp):
    dlg = lm.LocalMeshDialog(GENERATOR_DIR)
    try:
        dlg.show()
        settle(qapp)
        page = dlg.page
        page._mesh_up = True
        page._start_saved(None, "start")
        settle(qapp)
        assert page.status.isVisible() and "stop it first" in page.status.text()
        assert page.action_status.isHidden(), "the copy doubled the line on a panel-less page"
        # and no second press is asked for there
        assert page.boot_start_btn.text() == "Generate && start"
    finally:
        dlg.close()
        dlg.deleteLater()


# ── the Bring-up step gives the panel the room ─────────────────────────────────────────
def test_the_bringup_step_lets_the_panel_take_most_of_the_window(shell, qapp):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    dock.set_expanded(True)
    settle(qapp)
    usual = dock.height()
    assert usual <= dock_mod.EXPANDED_PX
    ctl = to_bringup(wiz, qapp)
    settle(qapp)
    assert dock.tall and dock.height() > usual + 100, (usual, dock.height())
    assert "panel" in wiz.currentPage().subTitle() and "below" not in wiz.currentPage().subTitle()
    # the page above still shows its note and the wizard's buttons
    for w in (ctl.dock_note_btn, wiz.button(QtWidgets.QWizard.WizardButton.BackButton)):
        r = rect_in(wiz, w)
        assert w.isVisible() and wiz.rect().contains(r) and r.bottom() < dock.y(), (w, r)
    shot(wiz, "bringup-step-panel-tall")
    wiz.back()
    settle(qapp)
    assert not dock.tall and dock.height() == usual


@pytest.mark.parametrize("h", [552, 780, 1080])
def test_the_tall_height_leaves_the_page_its_room(h):
    bar = 35
    assert dock_mod.dock_height_for(h, True, bar, tall=True) > dock_mod.dock_height_for(h, True, bar)
    assert h - dock_mod.dock_height_for(h, True, bar, tall=True) >= 200
    assert dock_mod.dock_height_for(h, False, bar, tall=True) == bar


# ── the running build itself, at the bottom ──────────────────────────────────────────
def test_the_builds_tab_follows_the_picked_builds_log(shell, qapp, tmp_path):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock

    class Worker:
        def isRunning(self):
            return True

    log = tmp_path / "build.log"
    log.write_text("".join(f"emerge line {i}\n" for i in range(1, 2001)))
    sup = build_supervisor.supervisor()
    run = sup.adopt(session_id="20261021-tail", label="x86 desktop image", worker=Worker(),
                    driver=None, window=wiz, workdir=str(tmp_path), log_path=str(log))
    try:
        dock.show_tab("builds")
        dock.refresh_activity()
        settle(qapp)
        text = dock.build_log.toPlainText()
        assert "emerge line 2000" in text and "emerge line 1500" not in text
        assert len(text.splitlines()) <= dock_mod.BUILD_TAIL_LINES
        assert str(log) in dock.build_log_title.text()
        with log.open("a") as fh:
            fh.write(">>> Completed (1 of 1) www-client/firefox\n")
        dock.refresh_activity()                       # what the 1 s timer does
        assert dock.build_log.toPlainText().endswith("www-client/firefox")
        assert dock.build_log.isVisible()
        r = rect_in(wiz, dock.build_log)
        assert wiz.rect().contains(r) and r.height() >= 60 and r.width() >= 200, r
        shot(wiz, "builds-tab-live-log")
    finally:
        run.finished = True
        sup.release(run)
    dock.refresh_activity()
    assert dock.build_log.toPlainText() == ""


def test_a_build_with_no_log_path_falls_back_to_its_workdir_log(shell, qapp, tmp_path):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock

    class Worker:
        def isRunning(self):
            return True

    (tmp_path / "build.log").write_text("from the workdir\n")
    sup = build_supervisor.supervisor()
    run = sup.adopt(session_id="20261021-wd", label="pi image", worker=Worker(),
                    driver=None, window=wiz, workdir=str(tmp_path))
    try:
        dock.show_tab("builds")
        dock.refresh_activity()
        assert "from the workdir" in dock.build_log.toPlainText()
    finally:
        run.finished = True
        sup.release(run)
