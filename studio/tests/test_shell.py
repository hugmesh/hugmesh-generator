"""ASK 16 — multi-window + the tray's "running builds" submenu.

Three claims, each pinned here:

  1. On launch, if a Studio GUI is ALREADY open, a DIALOG asks whether to open a NEW
     window or to return the EXISTING window to the initial wizard screen while builds
     continue in the background — and the dialog appears ONLY when an instance exists.
  2. Both branches do what they say.
  3. The tray's "Running builds" submenu lists EXACTLY the running builds, and selecting
     one opens a window for it.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import build_sessions as bs                # noqa: E402
from hugmesh_studio.core import instance                            # noqa: E402
from hugmesh_studio.gui import build_supervisor                     # noqa: E402
from hugmesh_studio.gui import shell as shell_mod                   # noqa: E402
from hugmesh_studio.gui import tray as tray_mod                     # noqa: E402
from hugmesh_studio.gui.pages import build_window                   # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402
from hugmesh_studio.gui.wizard import StudioWizard                  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _fresh_supervisor():
    build_supervisor.reset_supervisor()
    yield
    build_supervisor.supervisor().cancel_all(wait_ms=2000)
    build_supervisor.reset_supervisor()


@pytest.fixture
def shell(qapp):
    sh = shell_mod.StudioShell(GENERATOR_DIR)
    yield sh
    for w in list(sh.windows) + list(sh.build_windows):
        try:
            w.close()
        except RuntimeError:
            pass


# ── 1. the dialog appears only when an instance exists ───────────────────────────────
def test_no_running_instance_means_no_dialog(qapp):
    """The launch gate: with nothing listening, start() makes us primary and the
    dialog is never reached."""
    srv = instance.InstanceServer()
    try:
        assert srv.start() is True          # -> app.py opens normally, no dialog
    finally:
        srv.close()


def test_a_running_instance_is_what_triggers_the_dialog(qapp):
    first = instance.InstanceServer()
    second = instance.InstanceServer()
    try:
        assert first.start() is True
        assert second.start() is False      # -> app.py shows the dialog
    finally:
        second.close()
        first.close()


def test_detection_failure_opens_normally_rather_than_blocking(qapp, monkeypatch):
    """The lane's rule: "if detection fails, prefer opening normally over blocking"."""
    monkeypatch.setattr(instance.InstanceServer, "_bind",
                        lambda self: (_ for _ in ()).throw(OSError("no endpoint")))
    srv = instance.InstanceServer()
    try:
        assert srv.start() is True          # never returns "you are second"
        assert srv.listening is False
    finally:
        srv.close()


# ── the dialog itself: choosing IS answering ─────────────────────────────────────────
def test_dialog_offers_exactly_the_two_asked_branches(qapp):
    dlg = shell_mod.AlreadyRunningDialog()
    try:
        choices = [c.property("choice") for c in dlg.group.buttons()]
        assert sorted(choices) == sorted([shell_mod.CHOICE_NEW_WINDOW,
                                          shell_mod.CHOICE_RESET])
        # the reset card must SAY that builds keep running — that is the promise
        assert "KEEP RUNNING" in dlg.reset_card.accessibleDescription()
    finally:
        dlg.deleteLater()


@pytest.mark.parametrize("attr,expected", [
    ("new_card", shell_mod.CHOICE_NEW_WINDOW),
    ("reset_card", shell_mod.CHOICE_RESET),
])
def test_clicking_a_card_answers_and_closes(qapp, attr, expected):
    dlg = shell_mod.AlreadyRunningDialog()
    try:
        getattr(dlg, attr).click()
        assert dlg.choice == expected
        assert dlg.result() == QtWidgets.QDialog.DialogCode.Accepted
    finally:
        dlg.deleteLater()


def test_cancelling_answers_nothing(qapp):
    dlg = shell_mod.AlreadyRunningDialog()
    try:
        dlg.reject()
        assert dlg.choice == shell_mod.CHOICE_CANCEL
    finally:
        dlg.deleteLater()


# ── 2. both branches do what they say ────────────────────────────────────────────────
def test_new_window_branch_opens_a_second_independent_window(shell):
    first = shell.open_window()
    second = shell.handle_command(instance.CMD_NEW_WINDOW)
    assert isinstance(second, StudioWizard)
    assert second is not first
    assert len(shell.windows) == 2
    # independent work, not two views of one config
    assert second.cfg is not first.cfg


def test_reset_branch_returns_the_existing_window_to_the_first_screen(shell):
    wiz = shell.open_window()
    wiz.show()
    start = wiz.currentId()
    wiz.next()
    assert wiz.currentId() != start, "the flow did not move; the test proves nothing"
    got = shell.handle_command(instance.CMD_RESET)
    assert got is wiz, "reset must act on the EXISTING window, not open a new one"
    assert len(shell.windows) == 1
    assert wiz.currentId() == start


def test_reset_does_not_touch_a_running_build(shell, monkeypatch):
    """"…while builds continue in the background" — reset walks the UI back; the
    supervisor's roster is untouched."""
    sup = build_supervisor.supervisor()

    class _Worker:
        def isRunning(self):
            return True

        def setParent(self, _p):
            pass

    sup.adopt(session_id="s1", label="be · x86", worker=_Worker(), driver=None)
    wiz = shell.open_window()
    wiz.show()
    wiz.next()
    shell.handle_command(instance.CMD_RESET)
    assert sup.count() == 1


def test_unknown_commands_are_ignored_not_guessed_at(shell):
    assert shell.handle_command("SOMETHING-FROM-A-NEWER-STUDIO") is None
    assert shell.windows == []


def test_reset_with_no_open_window_gives_one(shell):
    assert shell.current_window() is None
    wiz = shell.handle_command(instance.CMD_RESET)
    assert isinstance(wiz, StudioWizard)


def test_tray_open_studio_raises_rather_than_piling_up_windows(shell):
    first = shell.open_window()
    again = shell.open_or_raise()
    assert again is first
    assert len(shell.windows) == 1


# ── the process lifetime rule (what makes survival true on a tray-less desktop) ──────
class _FakeWorker:
    def isRunning(self):
        return True

    def setParent(self, _p):
        pass


def test_closing_the_last_window_does_not_quit_while_a_build_runs(shell, monkeypatch):
    """Without this, closing the last window on a tray-less desktop would quit the app,
    fire aboutToQuit and cancel the very build ask 16 exists to protect."""
    quits = []
    monkeypatch.setattr(QtWidgets.QApplication, "quit",
                        staticmethod(lambda *a: quits.append(1)))
    shell.enable_autoquit(True)
    build_supervisor.supervisor().adopt(session_id="s", label="be · x86",
                                        worker=_FakeWorker(), driver=None)
    wiz = shell.open_window()
    wiz.show()
    wiz.close()
    assert quits == [], "the process quit out from under a running build"


def test_closing_the_last_window_with_nothing_building_ends_the_process(shell,
                                                                       monkeypatch):
    quits = []
    monkeypatch.setattr(QtWidgets.QApplication, "quit",
                        staticmethod(lambda *a: quits.append(1)))
    shell.enable_autoquit(True)
    wiz = shell.open_window()
    wiz.show()
    wiz.close()
    assert quits == [1]


def test_autoquit_is_off_unless_the_launch_path_enables_it(shell, monkeypatch):
    """Quitting an application you do not own is not a shell's call — a shell built by
    a test (or embedded anywhere else) must never end the process."""
    quits = []
    monkeypatch.setattr(QtWidgets.QApplication, "quit",
                        staticmethod(lambda *a: quits.append(1)))
    assert shell.autoquit is False
    wiz = shell.open_window()
    wiz.show()
    wiz.close()
    assert quits == []


def test_a_tray_is_always_a_reason_to_stay(shell, monkeypatch):
    quits = []
    monkeypatch.setattr(QtWidgets.QApplication, "quit",
                        staticmethod(lambda *a: quits.append(1)))
    shell.enable_autoquit(True)
    shell.tray = object()                       # a tray exists -> closing is "to tray"
    wiz = shell.open_window()
    wiz.show()
    wiz.close()
    assert quits == []


# ── REPAIR: a build ENDING is a lifetime event, and nothing was listening for it ──────
# _sync_lifetime only ever ran from a window/build-window close. In the exact scenario
# ask 16 creates — no tray, the last window closed WHILE A BUILD RUNS — it correctly
# declined to quit, and then nothing ever asked again once the build finished. With
# quitOnLastWindowClosed already off, the process lingered forever with no window, no
# tray and nothing building: the "invisible process the operator cannot reach" that
# _sync_lifetime's own docstring says it quits rather than becomes.
def _quit_counter(qapp, monkeypatch):
    """Count QApplication.quit calls — after draining anything an earlier test left
    pending, since the deferral below schedules real zero-timers on the shared app."""
    qapp.processEvents()
    quits = []
    monkeypatch.setattr(QtWidgets.QApplication, "quit",
                        staticmethod(lambda *a: quits.append(1)))
    return quits


def _closed_last_window_with_a_build_running(shell, qapp, monkeypatch):
    quits = _quit_counter(qapp, monkeypatch)
    shell.enable_autoquit(True)
    build = build_supervisor.supervisor().adopt(
        session_id="s", label="be · x86", worker=_FakeWorker(), driver=None)
    wiz = shell.open_window()
    wiz.show()
    wiz.close()
    qapp.processEvents()
    assert quits == [], "it quit out from under a running build"
    return quits, build


def test_the_last_build_ending_ends_a_windowless_trayless_studio(shell, qapp,
                                                                 monkeypatch):
    quits, build = _closed_last_window_with_a_build_running(shell, qapp, monkeypatch)
    build_supervisor.supervisor().release(build)      # the build ends
    assert quits == [], ("the decision must be deferred a turn — `changed` fires from "
                         "inside the worker's finish, before the page has written its "
                         "final record")
    qapp.processEvents()
    assert quits == [1], "the process lingered with no window, no tray and no build"


def test_a_build_ending_does_not_quit_while_a_window_is_still_open(shell, qapp,
                                                                   monkeypatch):
    quits = _quit_counter(qapp, monkeypatch)
    shell.enable_autoquit(True)
    build = build_supervisor.supervisor().adopt(
        session_id="s", label="be · x86", worker=_FakeWorker(), driver=None)
    wiz = shell.open_window()
    wiz.show()
    try:
        build_supervisor.supervisor().release(build)
        qapp.processEvents()
        assert quits == [], "it quit with a window still on screen"
    finally:
        wiz.close()


def test_a_build_ending_does_not_quit_when_a_tray_is_up(shell, qapp, monkeypatch):
    quits, build = _closed_last_window_with_a_build_running(shell, qapp, monkeypatch)
    shell.tray = object()
    build_supervisor.supervisor().release(build)
    qapp.processEvents()
    assert quits == [], "a tray is always a reason to stay"


def test_a_build_ending_never_quits_an_application_the_shell_was_not_given(shell, qapp,
                                                                          monkeypatch):
    """Lifetime is opt-in. A shell built by a test — or embedded anywhere else — must
    not end somebody's process off a background roster signal."""
    quits = _quit_counter(qapp, monkeypatch)
    assert shell.autoquit is False
    build = build_supervisor.supervisor().adopt(
        session_id="s", label="be · x86", worker=_FakeWorker(), driver=None)
    build_supervisor.supervisor().release(build)
    qapp.processEvents()
    assert quits == []


def test_enabling_autoquit_twice_subscribes_once(shell, qapp, monkeypatch):
    """A double subscription would run the lifetime decision twice per roster change."""
    qapp.processEvents()
    calls = []
    monkeypatch.setattr(shell_mod.StudioShell, "_safe_sync_lifetime",
                        lambda self: calls.append(1))
    shell.enable_autoquit(True)
    shell.enable_autoquit(True)
    build_supervisor.supervisor().adopt(
        session_id="s", label="be · x86", worker=_FakeWorker(), driver=None)
    qapp.processEvents()
    assert calls == [1]


# ── 3. the tray submenu ──────────────────────────────────────────────────────────────
def _session(sid, label, status=bs.RUNNING, pid=None):
    return bs.BuildSession(id=sid, label=label, status=status, pid=pid,
                           hostname=os.uname().nodename if hasattr(os, "uname") else "")


def test_tray_menu_carries_a_running_builds_submenu(qapp):
    tray = tray_mod.build_tray(GENERATOR_DIR, builds_provider=lambda: [])
    texts = [a.text() for a in tray.contextMenu().actions()]
    assert tray_mod.RUNNING_BUILDS_LABEL in texts
    sub = tray.builds_menu
    assert [a.text() for a in sub.actions()] == [tray_mod.NO_RUNNING_BUILDS]
    assert sub.actions()[0].isEnabled() is False   # honest, not a clickable phantom


def test_submenu_lists_exactly_the_running_builds(qapp):
    rows = [_session("a", "be · x86"), _session("b", "fe · rpi5")]
    tray = tray_mod.build_tray(GENERATOR_DIR, builds_provider=lambda: rows)
    tray.refresh_running_builds()
    assert [a.text() for a in tray.builds_menu.actions()] == ["be · x86", "fe · rpi5"]
    rows.pop()                                     # one finishes
    tray.refresh_running_builds()
    assert [a.text() for a in tray.builds_menu.actions()] == ["be · x86"]
    rows.clear()
    tray.refresh_running_builds()
    assert [a.text() for a in tray.builds_menu.actions()] == [tray_mod.NO_RUNNING_BUILDS]


def test_selecting_a_build_opens_a_window_for_it(qapp):
    opened = []
    rows = [_session("a", "be · x86"), _session("b", "fe · rpi5")]
    tray = tray_mod.build_tray(GENERATOR_DIR, builds_provider=lambda: rows,
                               on_open_build=opened.append)
    tray.refresh_running_builds()
    tray.builds_menu.actions()[1].trigger()
    assert [s.id for s in opened] == ["b"]         # the one selected, not the first


def test_the_running_roster_never_lists_a_stale_record(qapp, tmp_path):
    """A record left at "running" by a SIGKILL'd Studio must not appear as a phantom
    build the operator can click."""
    live = _session("live", "live one", pid=os.getpid())
    dead = _session("dead", "dead one", pid=999999999)
    bs.save(live)
    bs.save(dead)
    assert bs.is_active(live) is True
    assert bs.is_active(dead) is False
    got = {s.id for s in tray_mod.running_builds()}
    assert got == {"live"}


def test_a_broken_state_dir_costs_an_empty_submenu_not_the_studio(qapp, monkeypatch):
    def boom():
        raise OSError("state dir is on fire")
    tray = tray_mod.build_tray(GENERATOR_DIR, builds_provider=boom)
    tray.refresh_running_builds()                  # a Qt slot: must not raise
    assert [a.text() for a in tray.builds_menu.actions()] == [tray_mod.NO_RUNNING_BUILDS]


# ── REPAIR: the guard covered the PROVIDER call and not the row it rendered ──────────
# `self.builds_menu.addAction(label)` sat OUTSIDE the try, and the label came from a
# session record with no coercion — so a record whose `label` deserialised to a number
# raised TypeError out of refresh_running_builds. That method is an aboutToShow slot
# (qFatal under PyQt6) AND is called eagerly by _ControlTray.__init__, so the exception
# propagated build_tray -> install_tray -> app.main() and the Studio never started —
# the exact opposite of this module's stated contract, one row above.
class _UnrenderableBuild:
    """A roster entry neither of whose text fields can be turned into a label."""

    @property
    def label(self):
        raise RuntimeError("this record's label cannot be read")

    @property
    def id(self):
        raise RuntimeError("nor its id")


def test_a_malformed_record_does_not_stop_the_studio_from_starting(qapp, tmp_path):
    """The real launch path: a record on disk, the DEFAULT provider, build_tray()."""
    import json
    import socket
    os.makedirs(bs.sessions_dir(), exist_ok=True)
    with open(os.path.join(bs.sessions_dir(), "x1.json"), "w", encoding="utf-8") as fh:
        json.dump({"id": "x1", "label": 12345, "status": bs.RUNNING,
                   "pid": os.getpid(), "hostname": socket.gethostname()}, fh)
    tray = tray_mod.build_tray(GENERATOR_DIR)      # used to raise TypeError right here
    assert [a.text() for a in tray.builds_menu.actions()] == ["12345"]
    tray.refresh_running_builds()                  # ...and again as a slot
    assert [a.text() for a in tray.builds_menu.actions()] == ["12345"]


def test_a_record_whose_fields_cannot_be_read_is_still_listed(qapp):
    """It IS a running build. It gets the neutral placeholder label and stays clickable
    — dropping it would under-report what is running."""
    rows = [_UnrenderableBuild(), _session("b", "fe · rpi5")]
    opened = []
    tray = tray_mod.build_tray(GENERATOR_DIR, builds_provider=lambda: rows,
                               on_open_build=opened.append)
    assert [a.text() for a in tray.builds_menu.actions()] == ["build", "fe · rpi5"]
    tray.builds_menu.actions()[0].trigger()
    assert opened == [rows[0]]                     # the record itself, not a stand-in


def test_a_row_that_fails_to_render_is_declared_never_dropped(qapp, monkeypatch):
    """The last-ditch branch: if ANY step of drawing a row raises, that row is counted
    and stated. A roster that silently lost a running build would be lying."""
    def only_the_good_one(session):
        if getattr(session, "id", "") == "bad":
            raise RuntimeError("cannot render this one")
        return session.label
    monkeypatch.setattr(tray_mod, "menu_label", only_the_good_one)
    rows = [_session("bad", "x"), _session("b", "fe · rpi5")]
    tray = tray_mod.build_tray(GENERATOR_DIR, builds_provider=lambda: rows)
    texts = [a.text() for a in tray.builds_menu.actions()]
    assert "fe · rpi5" in texts                    # the good build is still listed
    assert tray_mod.unlistable_builds_text(1) in texts
    assert not any(a.isEnabled() for a in tray.builds_menu.actions()
                   if a.text() == tray_mod.unlistable_builds_text(1))
    # ...and an all-bad roster says so rather than claiming nothing is running
    tray2 = tray_mod.build_tray(GENERATOR_DIR,
                                builds_provider=lambda: [_session("bad", "x")])
    assert [a.text() for a in tray2.builds_menu.actions()] == [
        tray_mod.unlistable_builds_text(1)]
    assert tray_mod.unlistable_builds_text(2) == (
        "(2 running builds could not be listed)")


@pytest.mark.parametrize("label,sid,expected", [
    (12345, "x1", "12345"),                        # a number renders as what it says
    ([1, 2], "x1", "[1, 2]"),
    ("", 7, "7"),                                  # empty label falls back to the id
    (None, None, "build"),                         # neither -> a neutral placeholder
    ("  ", "", "build"),                           # whitespace is not a label
    ("be · x86", "x1", "be · x86"),                # the ordinary case, unchanged
])
def test_menu_label_always_yields_a_string(label, sid, expected):
    tray = _session(sid if isinstance(sid, str) else "", "")
    tray.label = label
    tray.id = sid
    assert tray_mod.menu_label(tray) == expected


def test_menu_label_survives_a_record_it_cannot_read_at_all():
    assert tray_mod.menu_label(_UnrenderableBuild()) == "build"


def test_shell_opens_a_build_window_for_someone_elses_run(shell, tmp_path):
    """A build this process does not own still gets a window — one that states exactly
    what is and is not possible for it."""
    s = _session("elsewhere", "be · x86", status=bs.FAILED)
    s.workdir = str(tmp_path / "gone")
    win = shell.open_build_window(s)
    assert isinstance(win, build_window.BuildActionsWindow)
    assert win.isWindow()
    assert win.buttons["resume"].isEnabled() is False    # its tree is gone
    assert "no longer exists" in win.buttons["resume"].toolTip()


def test_shell_raises_the_live_window_for_its_own_run(shell):
    sup = build_supervisor.supervisor()
    wiz = shell.open_window()

    class _Worker:
        def isRunning(self):
            return True

        def setParent(self, _p):
            pass

    sup.adopt(session_id="mine", label="be · x86", worker=_Worker(), driver=None,
              window=wiz)
    got = shell.open_build_window(_session("mine", "be · x86"))
    assert got is wiz, "its own live window must be raised, not shadowed by a new one"
    assert shell.build_windows == []


# ── REPAIR (freeze audit): the tray's per-build window had FIVE DEAD BUTTONS ─────────
# StudioShell.open_build_window() built a BuildActionsWindow with no handlers at all,
# so every action the build's state allowed was shown ENABLED and did nothing when
# clicked. Ask 16's "selecting one opens a window for that build" was a window you could
# look at and not act from.
def _saved_session(tmp_path, sid="20260303-000000-cccccc", status=bs.FAILED):
    workdir = tmp_path / "out" / "sessions" / sid
    workdir.mkdir(parents=True, exist_ok=True)
    (workdir / "build.log").write_text("something was produced\n", encoding="utf-8")
    s = bs.BuildSession(id=sid, created="2026-03-03T00:00:00", label="be · x86",
                        workdir=str(workdir), status=status,
                        images=[{"id": "e1", "role": "backend", "platform": "x86",
                                 "status": "failed"}],
                        hostname=os.uname().nodename if hasattr(os, "uname") else "")
    bs.save(s)
    return s


def test_a_tray_opened_build_window_can_actually_do_things(shell, tmp_path):
    s = _saved_session(tmp_path)
    win = shell.open_build_window(s)
    try:
        assert isinstance(win, build_window.BuildActionsWindow)
        for name in (*build_window.ACTIONS, "log"):
            assert win._handlers[name] is not None, f"{name} has no handler"
        # ...and the state-allowed ones are genuinely offered, not gated off as dead
        for name in ("resume", "artifacts", "edit", "delete"):
            assert win.buttons[name].isEnabled() is True, name
            assert win.buttons[name].toolTip() != build_window.NO_HANDLER_REASON
    finally:
        win.close()


def test_a_tray_opened_action_runs_the_studios_real_handler(shell, tmp_path,
                                                            monkeypatch):
    """It must not be a second implementation: the click lands in the Studio's one
    PreviousBuildsWidget, on the row for THIS build."""
    s = _saved_session(tmp_path)
    win = shell.open_build_window(s)
    seen = []
    try:
        pb = shell.builds_manager()
        assert pb is not None
        monkeypatch.setattr(type(pb), "_redo",
                            lambda self: seen.append(self._selected().session.id))
        win.buttons["edit"].click()
        assert seen == [s.id]
    finally:
        win.close()


def test_a_tray_opened_action_on_a_vanished_record_says_so(shell, tmp_path,
                                                           monkeypatch):
    s = _saved_session(tmp_path)
    win = shell.open_build_window(s)
    warned = []
    monkeypatch.setattr(QtWidgets.QMessageBox, "warning",
                        staticmethod(lambda *a, **k: warned.append(a[1:3])))
    try:
        bs.delete(s)                              # another Studio removed it
        win.buttons["edit"].click()
        assert warned and "no longer" in warned[0][0].lower()
    finally:
        win.close()


# ── REPAIR (freeze audit): survival must not depend on Qt's signal ORDER ─────────────
def test_enabling_autoquit_turns_qts_own_quit_on_last_window_off(shell, qapp):
    """Qt's quitOnLastWindowClosed knows about windows and nothing else. Left on, the
    last close of a tray-less Studio quits the app -> aboutToQuit -> cancel_all() ->
    the running build dies. _sync_lifetime turned it off, but only ONCE A WINDOW HAD
    ALREADY CLOSED, so the guarantee rode on `finished` reaching us before Qt's own
    last-window check. It is turned off when lifetime is handed over instead."""
    qapp.setQuitOnLastWindowClosed(True)
    shell.enable_autoquit(True)
    assert qapp.quitOnLastWindowClosed() is False, (
        "a window close can still quit the app out from under a running build")


def test_disabling_autoquit_does_not_touch_the_flag(shell, qapp):
    """enable_autoquit(False) means "I am not managing lifetime" — not "restore Qt's",
    which would silently re-arm the quit a tray owner had deliberately disabled."""
    qapp.setQuitOnLastWindowClosed(False)
    shell.enable_autoquit(False)
    assert qapp.quitOnLastWindowClosed() is False


def test_a_closed_build_window_is_no_longer_a_reason_to_stay(shell, qapp, tmp_path,
                                                             monkeypatch):
    """`if self.build_windows: return` counted CLOSED windows too — a QWidget stays in
    the list until Qt collects it — so a tray-less Studio lingered forever as a process
    with nothing on screen."""
    quits = []
    monkeypatch.setattr(QtWidgets.QApplication, "quit",
                        staticmethod(lambda *a: quits.append(1)))
    shell.enable_autoquit(True)
    s = _saved_session(tmp_path, sid="20260404-000000-dddddd")
    win = shell.open_build_window(s)
    wiz = shell.current_window()
    win.close()
    if wiz is not None:
        wiz.close()
    assert shell.build_windows == [win], "the widget is still alive, just not visible"
    assert quits == [1], "nothing is on screen and nothing is building; the app stayed"


# ── the tray/shell SEAM: the real wiring, not an injected fake ───────────────────────
# Every submenu test above injects builds_provider/on_open_build, which proves the menu
# but not that the LAUNCH path connects it to anything. install_tray() is what app.py
# actually calls.
def test_the_shells_own_tray_lists_the_real_roster_and_opens_real_windows(shell,
                                                                          tmp_path):
    s = _saved_session(tmp_path, sid="20260606-000000-ffffff", status=bs.RUNNING)
    s.pid = os.getpid()                          # genuinely active, per is_active
    bs.save(s)
    assert bs.is_active(s) is True
    tray = shell.install_tray()
    try:
        tray.refresh_running_builds()
        rows = [a.text() for a in tray.builds_menu.actions()]
        assert rows == [s.label], f"the default roster is not the real one: {rows}"
        tray.builds_menu.actions()[0].trigger()
        assert len(shell.build_windows) == 1, (
            "the tray is not wired to the shell's per-build window")
        win = shell.build_windows[0]
        assert isinstance(win, build_window.BuildActionsWindow)
        assert win.row.session.id == s.id
    finally:
        for w in list(shell.build_windows):
            w.close()
        tray.hide()


def test_the_shells_tray_shows_the_honest_empty_row_when_nothing_runs(shell):
    tray = shell.install_tray()
    try:
        tray.refresh_running_builds()
        assert [a.text() for a in tray.builds_menu.actions()] == [
            tray_mod.NO_RUNNING_BUILDS]
    finally:
        tray.hide()
