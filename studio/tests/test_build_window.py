"""ASK 15 — the build list opens a per-build WINDOW, and the actions it offers are
derived from the build's REAL state (never a dead button).

The lane's rule, verbatim: "Derive the available actions from the build's real state
(a finished build cannot be resumed; a build with no artifacts cannot show them) rather
than offering dead buttons." So the meat here is :func:`build_window.actions_for` driven
across every state a row can be in — complete, failed, stopped, running-here,
stale-running, artifact-dir-empty, artifact-dir-gone, unmanaged, unreadable.
"""
import os
import socket

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import build_sessions as bs                # noqa: E402
from hugmesh_studio.gui.pages import build_window                   # noqa: E402
from hugmesh_studio.gui.pages import sessions_widget as sw          # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _session(tmp_path, *, status, sid="20260101-000000-aaaaaa", artifacts=True,
             workdir_exists=True, pid=None, hostname=None):
    """A BuildSession row in a chosen real state — including its directory on disk."""
    workdir = str(tmp_path / "out" / "sessions" / sid)
    if workdir_exists:
        os.makedirs(workdir, exist_ok=True)
        if artifacts:
            with open(os.path.join(workdir, "build.log"), "w", encoding="utf-8") as fh:
                fh.write("something was produced\n")
    s = bs.BuildSession(id=sid, created="2026-01-01T00:00:00", label="be · x86",
                        workdir=workdir, status=status,
                        images=[{"id": "e1", "role": "be", "platform": "x86",
                                 "status": "ok" if status == bs.COMPLETE else "failed"}],
                        pid=pid, hostname=hostname or socket.gethostname())
    return sw._RowData("session", session=s)


# ── the honesty rule, state by state ────────────────────────────────────────────────
def test_a_finished_build_cannot_be_resumed(tmp_path):
    row = _session(tmp_path, status=bs.COMPLETE)
    acts = build_window.actions_for(row)
    assert acts["resume"].enabled is False
    assert "nothing to resume" in acts["resume"].reason
    # ...but its artifacts and its config are both still reachable
    assert acts["artifacts"].enabled is True
    assert acts["edit"].enabled is True
    assert acts["delete"].enabled is True


def test_a_failed_build_can_be_resumed(tmp_path):
    row = _session(tmp_path, status=bs.FAILED)
    acts = build_window.actions_for(row)
    assert acts["resume"].enabled is True
    assert acts["resume"].reason == ""


def test_a_stopped_build_can_be_resumed(tmp_path):
    row = _session(tmp_path, status=bs.STOPPED)
    assert build_window.actions_for(row)["resume"].enabled is True


def test_a_build_with_no_artifacts_cannot_show_them(tmp_path):
    row = _session(tmp_path, status=bs.FAILED, artifacts=False)   # dir exists, empty
    acts = build_window.actions_for(row)
    assert acts["artifacts"].enabled is False
    assert "produced no files" in acts["artifacts"].reason
    assert acts["resume"].enabled is True        # ...resuming it is exactly the point


def test_a_build_whose_directory_is_gone_offers_edit_not_resume(tmp_path):
    row = _session(tmp_path, status=bs.FAILED, workdir_exists=False)
    acts = build_window.actions_for(row)
    assert acts["resume"].enabled is False
    assert "no longer exists" in acts["resume"].reason
    assert acts["artifacts"].enabled is False
    assert acts["edit"].enabled is True          # the config snapshot survives the tree
    assert acts["delete"].enabled is True


def test_a_build_running_in_another_studio_is_neither_resumed_nor_deleted(tmp_path):
    # a RUNNING record whose pid is THIS live process == genuinely active
    row = _session(tmp_path, status=bs.RUNNING, pid=os.getpid())
    assert bs.is_active(row.session) is True
    acts = build_window.actions_for(row)
    assert acts["resume"].enabled is False
    assert "another Studio process" in acts["resume"].reason
    assert acts["delete"].enabled is False
    assert "another Studio process" in acts["delete"].reason


def test_a_stale_running_record_is_resumable(tmp_path):
    """A record left at "running" by a SIGKILL'd Studio is not active — it is exactly
    the interrupted build a resume exists for."""
    row = _session(tmp_path, status=bs.RUNNING, pid=999999999)
    assert bs.is_stale(row.session) is True
    assert bs.is_active(row.session) is False
    assert build_window.actions_for(row)["resume"].enabled is True


def test_an_unmanaged_tree_has_no_config_so_no_resume_and_no_edit(tmp_path):
    path = tmp_path / "out" / "wl-be.x86"
    path.mkdir(parents=True)
    (path / "image.img").write_text("x")
    u = bs.UnmanagedBuild(path=str(path), role="be", platform="x86", mtime=1.0,
                          has_log=False, log_path="")
    row = sw._RowData("unmanaged", unmanaged=u)
    acts = build_window.actions_for(row)
    assert acts["resume"].enabled is False and "pre-session" in acts["resume"].reason
    assert acts["edit"].enabled is False
    assert acts["artifacts"].enabled is True     # the tree itself is real and non-empty
    assert acts["delete"].enabled is True
    assert acts["log"].enabled is False          # has_log=False -> honestly unavailable


def test_an_unreadable_record_offers_only_delete(tmp_path):
    p = tmp_path / "broken.json"
    p.write_text("{not json")
    row = sw._RowData("unreadable", path=str(p))
    acts = build_window.actions_for(row)
    assert acts["resume"].enabled is False
    assert acts["edit"].enabled is False
    assert acts["artifacts"].enabled is False
    assert acts["delete"].enabled is True


# ── the NEXT column ("options to resume builds should show next") ────────────────────
@pytest.mark.parametrize("status,artifacts,expected", [
    (bs.FAILED, True, "resume"),
    (bs.STOPPED, True, "resume"),
    (bs.COMPLETE, True, "open artifacts"),
    (bs.COMPLETE, False, "edit as new"),
])
def test_next_action_names_the_primary_thing_to_do(tmp_path, status, artifacts,
                                                   expected):
    row = _session(tmp_path, status=status, artifacts=artifacts)
    assert build_window.next_action(row) == expected


def test_next_action_for_a_live_build_says_running(tmp_path):
    row = _session(tmp_path, status=bs.RUNNING, pid=os.getpid())
    assert build_window.next_action(row) == "running — open to watch"


# ── the window itself ────────────────────────────────────────────────────────────────
def _wired(row, **overrides):
    """A window with every action WIRED — the real caller's shape. A window built with
    no handlers cannot enable anything (see the dead-button tests below), so a test
    about state must supply them or it would only be measuring the handler gate."""
    kw = {f"on_{n}": (lambda _r: None) for n in (*build_window.ACTIONS, "log")}
    kw.update(overrides)
    return build_window.BuildActionsWindow(row, **kw)


def test_the_window_offers_the_four_asked_actions(qapp, tmp_path):
    row = _session(tmp_path, status=bs.FAILED)
    win = _wired(row)
    try:
        for name in ("resume", "artifacts", "edit", "delete"):
            assert name in win.buttons
        assert win.isWindow()                    # a real top-level window
        assert not win.isModal()                 # ...and it does not block the Studio
    finally:
        win.close()
        win.deleteLater()


def test_the_windows_buttons_match_actions_for(qapp, tmp_path):
    row = _session(tmp_path, status=bs.COMPLETE, artifacts=False)
    win = _wired(row)
    try:
        acts = build_window.actions_for(row)
        for name, btn in win.buttons.items():
            assert btn.isEnabled() == acts[name].enabled, name
            assert btn.toolTip() == acts[name].reason, name
        # a refusal is stated in the open, not only in a tooltip
        assert win.note.isVisible() or win.note.text()
        assert "nothing to resume" in win.note.text()
    finally:
        win.close()
        win.deleteLater()


def test_a_disabled_action_cannot_be_fired_even_if_forced(qapp, tmp_path, monkeypatch):
    """_fire re-derives at CLICK time: a build can finish (or be taken by another
    Studio) while the window sits open, so the baked enablement is never trusted."""
    row = _session(tmp_path, status=bs.COMPLETE)
    called = []
    win = build_window.BuildActionsWindow(row, on_resume=lambda r: called.append(r))
    monkeypatch.setattr(QtWidgets.QMessageBox, "warning",
                        staticmethod(lambda *a, **k: None))
    try:
        win.buttons["resume"].setEnabled(True)   # force the dead button live
        win.buttons["resume"].click()
        assert called == []                      # ...and it still refuses
    finally:
        win.close()
        win.deleteLater()


def test_each_enabled_action_reaches_its_handler(qapp, tmp_path):
    row = _session(tmp_path, status=bs.FAILED)
    fired = []
    win = build_window.BuildActionsWindow(
        row,
        on_resume=lambda r: fired.append("resume"),
        on_artifacts=lambda r: fired.append("artifacts"),
        on_edit=lambda r: fired.append("edit"),
        on_log=lambda r: fired.append("log"))
    try:
        for name in ("resume", "artifacts", "edit", "log"):
            win.buttons[name].click()
        assert fired == ["resume", "artifacts", "edit", "log"]
    finally:
        win.close()
        win.deleteLater()


# ── the list: clicking an entry opens that build's window ────────────────────────────
class _FakeWiz:
    """Just enough wizard for PreviousBuildsWidget (it reads cfg.output_dir and
    generator_dir, and the window parents to .window())."""

    def __init__(self, out_dir):
        class _Cfg:
            output_dir = out_dir
        self.cfg = _Cfg()
        self.generator_dir = out_dir


def _widget_with_one_session(qapp, tmp_path, status=bs.FAILED):
    row = _session(tmp_path, status=status)
    bs.save(row.session)
    w = sw.PreviousBuildsWidget(_FakeWiz(str(tmp_path / "out")))
    w.refresh()
    return w


def test_clicking_a_row_opens_that_builds_window(qapp, tmp_path):
    w = _widget_with_one_session(qapp, tmp_path)
    try:
        assert w.table.rowCount() == 1
        w._row_clicked(0, 0)
        assert len(w._build_windows) == 1
        win = w._build_windows[0]
        assert isinstance(win, build_window.BuildActionsWindow)
        assert win.isWindow()
        assert win.row is w._row_data[0]
        # clicking the same row again re-raises the SAME window, never a second one
        w._row_clicked(0, 0)
        assert len(w._build_windows) == 1
    finally:
        for win in list(w._build_windows):
            win.close()
        w.deleteLater()


def test_the_list_shows_a_next_column_matching_the_window(qapp, tmp_path):
    w = _widget_with_one_session(qapp, tmp_path, status=bs.COMPLETE)
    try:
        headers = [w.table.horizontalHeaderItem(i).text()
                   for i in range(w.table.columnCount())]
        assert "Next" in headers
        col = headers.index("Next")
        shown = w.table.item(0, col).text()
        assert shown == build_window.next_action(w._row_data[0])
        assert shown == "open artifacts"
    finally:
        w.deleteLater()


def test_the_old_button_row_still_works(qapp, tmp_path):
    """The window is an ADDITION: nothing an operator already reaches for is removed."""
    w = _widget_with_one_session(qapp, tmp_path)
    try:
        for name in ("restart_btn", "redo_btn", "open_btn", "log_btn", "delete_btn",
                     "delete_all_btn"):
            assert hasattr(w, name)
    finally:
        w.deleteLater()


# ── the "Open build window" button: a discoverable face on row activation ────────────
def test_the_open_window_button_is_gated_on_selection(qapp, tmp_path):
    """(a) disabled with nothing selected, (b) enabled once a readable row is."""
    w = _widget_with_one_session(qapp, tmp_path)
    try:
        w.table.clearSelection()
        w._update_buttons()
        assert not w.open_window_btn.isEnabled()
        w.table.selectRow(0)
        assert w.open_window_btn.isEnabled()
    finally:
        w.deleteLater()


def test_the_open_window_button_opens_the_same_window_as_activation(qapp, tmp_path):
    """(c) the button routes through open_build_window — the SAME window object the
    row's click / double-click / Enter activation opens, never a second copy."""
    w = _widget_with_one_session(qapp, tmp_path)
    try:
        w.table.selectRow(0)
        w.open_window_btn.click()
        assert len(w._build_windows) == 1
        win = w._build_windows[0]
        assert isinstance(win, build_window.BuildActionsWindow)
        assert win.row is w._row_data[0]
        # activation re-raises the SAME window the button opened, and vice versa
        w._row_clicked(0, 0)                     # single click
        assert w._build_windows == [win]
        w._open_build_window()                   # double-click / Enter route
        assert w._build_windows == [win]
    finally:
        for win in list(w._build_windows):
            win.close()
        w.deleteLater()


def test_the_open_window_button_mirrors_activation_for_every_row_kind(qapp, tmp_path):
    """The button's guard is _open_build_window's own — every row kind a click would
    open (unmanaged and unreadable included) keeps the button live, so it is never
    dead where activation works."""
    w, _broken = _widget_with_every_row_kind(qapp, tmp_path)
    try:
        for kind in ("session", "unmanaged", "unreadable"):
            i = w._row_data.index(_rows_of(w, kind)[0])
            w.table.selectRow(i)
            assert w.open_window_btn.isEnabled(), kind
            before = len(w._build_windows)
            w.open_window_btn.click()
            assert len(w._build_windows) == before + 1, kind
            assert w._build_windows[-1].row is w._row_data[i], kind
    finally:
        for win in list(w._build_windows):
            win.close()
        w.deleteLater()


def test_nothing_carries_the_retired_click_the_row_tooltip(qapp, tmp_path):
    """(d) the "Click the row to open…" instruction is retired: the button says it
    now. No table cell and no child widget may still carry that copy."""
    w, _broken = _widget_with_every_row_kind(qapp, tmp_path)
    try:
        tips = [w.table.item(i, j).toolTip()
                for i in range(w.table.rowCount())
                for j in range(w.table.columnCount())
                if w.table.item(i, j) is not None]
        tips += [c.toolTip() for c in w.findChildren(QtWidgets.QWidget)]
        assert not any("click the row" in t.lower() for t in tips), tips
    finally:
        w.deleteLater()


def test_refresh_re_derives_after_the_state_changes(qapp, tmp_path):
    row = _session(tmp_path, status=bs.FAILED)
    win = _wired(row)
    try:
        assert win.buttons["resume"].isEnabled() is True
        row.session.status = bs.COMPLETE          # the build finished under the window
        row.status = bs.COMPLETE
        win.refresh()
        assert win.buttons["resume"].isEnabled() is False
    finally:
        win.close()
        win.deleteLater()


# ── REPAIR (freeze audit): a button with no handler is a DEAD button ─────────────────
# The tray's per-build window was constructed with NO handlers at all
# (StudioShell.open_build_window passed none), so every action the build's state
# allowed was shown ENABLED and did nothing whatsoever when clicked. That is precisely
# the dead button ask 15 forbids, and it survived because actions_for() — correctly —
# only knows about the build, never about whether the caller wired anything to it.
def test_an_unwired_window_offers_nothing_rather_than_dead_buttons(qapp, tmp_path):
    row = _session(tmp_path, status=bs.FAILED)          # resume/artifacts/edit/delete
    assert all(build_window.actions_for(row)[n].enabled
               for n in ("resume", "artifacts", "edit", "delete")), (
        "the fixture must be a build whose STATE allows everything, or this test "
        "proves nothing")
    win = build_window.BuildActionsWindow(row)          # ...but nothing is wired
    try:
        for name in (*build_window.ACTIONS, "log"):
            assert win.buttons[name].isEnabled() is False, name
            assert win.buttons[name].toolTip() == build_window.NO_HANDLER_REASON, name
        assert build_window.NO_HANDLER_REASON in win.note.text()
    finally:
        win.close()
        win.deleteLater()


def test_a_partially_wired_window_offers_exactly_what_it_can_do(qapp, tmp_path):
    """The gate is per-action, not all-or-nothing: wire one, get one."""
    row = _session(tmp_path, status=bs.FAILED)
    fired = []
    win = build_window.BuildActionsWindow(row, on_artifacts=lambda r: fired.append(r))
    try:
        assert win.buttons["artifacts"].isEnabled() is True
        assert win.buttons["resume"].isEnabled() is False
        win.buttons["artifacts"].click()
        assert fired == [row]
    finally:
        win.close()
        win.deleteLater()


def test_the_gate_holds_through_refresh(qapp, tmp_path):
    """refresh() re-derives from actions_for; it must not re-enable an unwired button."""
    row = _session(tmp_path, status=bs.FAILED)
    win = build_window.BuildActionsWindow(row)
    try:
        win.refresh()
        assert win.buttons["edit"].isEnabled() is False
        assert build_window.actions_for(row)["edit"].enabled is True   # state says yes
    finally:
        win.close()
        win.deleteLater()


# ── REPAIR (freeze audit): the window acts on ITS build, never on the selection ──────
# Every PreviousBuildsWidget handler reads _selected(). A per-build window is about ONE
# build, and the table's selection moves under it — so build A's "Delete" acted on
# whatever row happened to be selected, or on nothing at all after a refresh() cleared
# the selection. act_on_row() pins the row for the duration of the action.
def _widget_with_two_sessions(qapp, tmp_path):
    a = _session(tmp_path, status=bs.FAILED, sid="20260101-000000-aaaaaa")
    b = _session(tmp_path, status=bs.FAILED, sid="20260202-000000-bbbbbb")
    bs.save(a.session)
    bs.save(b.session)
    w = sw.PreviousBuildsWidget(_FakeWiz(str(tmp_path / "out")))
    w.refresh()
    return w


def test_the_window_acts_on_its_own_build_not_the_tables_selection(qapp, tmp_path):
    w = _widget_with_two_sessions(qapp, tmp_path)
    seen = []
    w._redo = lambda: seen.append(w._selected().session.id)     # records what it got
    try:
        assert len(w._row_data) == 2
        first, second = w._row_data[0], w._row_data[1]
        win = w.open_build_window(first)
        w.table.selectRow(1)                     # the operator selects the OTHER build
        assert w._selected() is second           # ...and the table agrees
        win.buttons["edit"].click()
        assert seen == [first.session.id], (
            "the window acted on the table's selection instead of its own build")
    finally:
        for win in list(w._build_windows):
            win.close()
        w.deleteLater()


def test_the_window_still_works_after_a_refresh_clears_the_selection(qapp, tmp_path):
    """refresh() rebuilds _row_data and drops the selection — unpinned, every button in
    an open per-build window became a silent no-op."""
    w = _widget_with_two_sessions(qapp, tmp_path)
    seen = []
    w._redo = lambda: seen.append(w._selected())
    try:
        row = w._row_data[0]
        win = w.open_build_window(row)
        w.table.clearSelection()
        assert w._selected() is None             # nothing is selected at all
        win.buttons["edit"].click()
        assert seen == [row]
    finally:
        for win in list(w._build_windows):
            win.close()
        w.deleteLater()


def test_the_pin_is_released_after_the_action(qapp, tmp_path):
    """A pin that leaked would leave the button ROW under the table permanently aimed
    at a build nobody selected."""
    w = _widget_with_two_sessions(qapp, tmp_path)
    w._redo = lambda: None
    try:
        w.act_on_row(w._row_data[0], "edit")
        assert w._pinned_row is None
        w.table.clearSelection()
        assert w._selected() is None
    finally:
        w.deleteLater()


def test_the_pin_is_released_even_when_the_handler_raises(qapp, tmp_path):
    w = _widget_with_two_sessions(qapp, tmp_path)

    def _boom():
        raise RuntimeError("handler exploded")
    w._redo = _boom
    try:
        with pytest.raises(RuntimeError):
            w.act_on_row(w._row_data[0], "edit")
        assert w._pinned_row is None
    finally:
        w.deleteLater()


def test_acting_on_a_row_that_left_the_list_says_so(qapp, tmp_path, monkeypatch):
    w = _widget_with_two_sessions(qapp, tmp_path)
    warned = []
    monkeypatch.setattr(QtWidgets.QMessageBox, "warning",
                        staticmethod(lambda *a, **k: warned.append(a[1:3])))
    called = []
    w._redo = lambda: called.append(1)
    try:
        stale = w._row_data[0]
        bs.delete(stale.session)
        w.refresh()                              # the row object is no longer listed
        assert w.act_on_row(stale, "edit") is False
        assert called == []
        assert warned and "no longer listed" in warned[0][0]
    finally:
        w.deleteLater()


def test_row_for_session_finds_the_listed_row(qapp, tmp_path):
    w = _widget_with_two_sessions(qapp, tmp_path)
    try:
        got = w.row_for_session("20260202-000000-bbbbbb")
        assert got is w._row_data[[r.session.id for r in w._row_data].index(
            "20260202-000000-bbbbbb")]
        assert w.row_for_session("nothing-like-this") is None
    finally:
        w.deleteLater()


def test_an_open_window_survives_the_list_reloading_under_it(qapp, tmp_path,
                                                             monkeypatch):
    """refresh() rebuilds _row_data from disk, so an open window's row object is stale
    even though its build is still listed. The action must land on the FRESH row rather
    than refuse — refusing after every reload would make the window useless in practice
    (the list refreshes on every session change)."""
    # The refusal path opens a MODAL warning. Stubbed so a regression FAILS this test
    # instead of hanging pytest forever on a dialog nobody can dismiss offscreen.
    warned = []
    monkeypatch.setattr(QtWidgets.QMessageBox, "warning",
                        staticmethod(lambda *a, **k: warned.append(a[1:3])))
    w = _widget_with_two_sessions(qapp, tmp_path)
    seen = []
    w._redo = lambda: seen.append(w._selected())
    try:
        stale = w._row_data[0]
        sid = stale.session.id
        win = w.open_build_window(stale)
        w.refresh()                              # every _RowData object is replaced
        assert stale not in w._row_data
        win.buttons["edit"].click()
        assert len(seen) == 1
        assert seen[0] is not stale              # the fresh row, not the stale one
        assert seen[0].session.id == sid         # ...and it is the same build
    finally:
        for win in list(w._build_windows):
            win.close()
        w.deleteLater()


# ── REPAIR: "survives a reload" was SESSION-ONLY — the other two row kinds still died ──
# The window-survives-a-reload fix re-resolved a stale row by ``session.id``. An
# UNMANAGED build tree and an UNREADABLE record have no session at all, so the id was
# "", the re-resolution was skipped, and every action in their window refused with
# "This build is no longer in the list — its record was removed or the list was
# reloaded" while the row sat plainly listed one line above. refresh() runs on every
# return to the Welcome screen, so that was every open window of those kinds, always —
# and the failure STATED something false rather than quietly doing nothing.
#
# TWO rows of each kind, deliberately: a re-resolution that merely finds "some row of
# the same kind" would act on the WRONG build, and with one row apiece nothing here
# could tell that apart from a correct fix.
def _widget_with_every_row_kind(qapp, tmp_path):
    """A widget listing TWO of each row kind: sessions, unmanaged trees, unreadables."""
    out = tmp_path / "out"
    for sid in ("20260101-000000-aaaaaa", "20260202-000000-bbbbbb"):
        bs.save(_session(tmp_path, status=bs.FAILED, sid=sid).session)
    for name in ("wl-be.x86", "wl-fe.arm64"):    # pre-session build trees
        (out / name).mkdir(parents=True, exist_ok=True)
        (out / name / "disk.img").write_text("x", encoding="utf-8")
    (out / bs.LOG_NAME).write_text("legacy log line\n", encoding="utf-8")
    os.makedirs(bs.sessions_dir(), exist_ok=True)
    broken = []
    for name in ("broken-1.json", "broken-2.json"):   # unreadable record files
        p = os.path.join(bs.sessions_dir(), name)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write("{not json")
        broken.append(p)
    w = sw.PreviousBuildsWidget(_FakeWiz(str(out)))
    w.refresh()
    return w, broken


def _rows_of(w, kind):
    return [r for r in w._row_data if r.kind == kind]


@pytest.mark.parametrize("kind", ["unmanaged", "unreadable"])
def test_a_reload_does_not_kill_the_window_of_a_build_with_no_session_record(
        qapp, tmp_path, monkeypatch, kind):
    warned = []
    monkeypatch.setattr(QtWidgets.QMessageBox, "warning",
                        staticmethod(lambda *a, **k: warned.append(a[1:3])))
    w, _broken = _widget_with_every_row_kind(qapp, tmp_path)
    seen = []
    w._view_log = lambda: seen.append(w._selected())
    try:
        rows = _rows_of(w, kind)
        assert len(rows) == 2
        row = rows[1]                            # the SECOND, so a first-match re-
        where = row.location                     # resolution lands on the wrong build
        # deliberately expressed WITHOUT the new row_identity helper: against the
        # pre-fix code this must fail on the false refusal below, never on an
        # AttributeError for an API that does not exist yet.
        win = w.open_build_window(row)
        w.refresh()                              # every _RowData object is replaced
        assert row not in w._row_data            # ...so the window's row IS stale
        assert any(r.location == where for r in _rows_of(w, kind)), (
            "the build is still listed — the reload deleted nothing")
        win.buttons["log"].click()
        assert warned == [], f"a build that is still listed was refused: {warned}"
        assert len(seen) == 1, "the action never ran"
        assert seen[0] is not row                # the fresh row, not the stale one
        assert seen[0].location == where, "the action landed on a DIFFERENT build"
    finally:
        for win in list(w._build_windows):
            win.close()
        w.deleteLater()


@pytest.mark.parametrize("kind", ["unmanaged", "unreadable"])
def test_a_build_that_really_left_the_list_is_still_refused(qapp, tmp_path,
                                                            monkeypatch, kind):
    """The negative half: re-resolving by identity must not turn the honest refusal
    into a lie in the other direction. A SIBLING of the same kind stays listed, so a
    re-resolution that matched on kind alone would act on somebody else's build."""
    warned = []
    monkeypatch.setattr(QtWidgets.QMessageBox, "warning",
                        staticmethod(lambda *a, **k: warned.append(a[1:3])))
    w, broken = _widget_with_every_row_kind(qapp, tmp_path)
    seen = []
    w._view_log = lambda: seen.append(w._selected())
    try:
        row = _rows_of(w, kind)[1]
        if kind == "unmanaged":
            import shutil
            shutil.rmtree(row.location)
        else:
            os.remove(row.path)
        w.refresh()
        assert len(_rows_of(w, kind)) == 1, "its sibling is still listed"
        assert w.act_on_row(row, "log") is False
        assert seen == [], f"it acted on another build entirely: {seen}"
        assert warned and "no longer listed" in warned[0][0]
    finally:
        w.deleteLater()


def test_reopening_a_build_after_a_reload_raises_its_window_instead_of_a_second_one(
        qapp, tmp_path):
    """Same build, new row object: the dedupe keyed on object identity, so every reload
    let the list spawn another window for a build that already had one."""
    w, _broken = _widget_with_every_row_kind(qapp, tmp_path)
    try:
        row = _rows_of(w, "unmanaged")[1]
        where = row.location
        win = w.open_build_window(row)
        w.refresh()
        fresh = next(r for r in _rows_of(w, "unmanaged") if r.location == where)
        assert fresh is not row
        again = w.open_build_window(fresh)
        assert again is win
        assert len(w._build_windows) == 1
        # ...and the OTHER unmanaged build still gets its own window
        other = next(r for r in _rows_of(w, "unmanaged") if r.location != where)
        assert w.open_build_window(other) is not win
        assert len(w._build_windows) == 2
    finally:
        for win in list(w._build_windows):
            win.close()
        w.deleteLater()


def test_a_reload_rebinds_every_open_window_to_its_fresh_row(qapp, tmp_path):
    """The fix at its source: refresh() replaced every row object and left the windows
    it owns pointing at orphans."""
    w, _broken = _widget_with_every_row_kind(qapp, tmp_path)
    try:
        opened = [(r.kind, r.location, w.open_build_window(r))
                  for r in list(w._row_data)]
        assert len(opened) == 6
        w.refresh()
        for kind, where, win in opened:
            assert win.row in w._row_data, f"{kind} window still holds a stale row"
            assert win.row.kind == kind
            assert win.row.location == where, "rebound to the WRONG build"
    finally:
        for win in list(w._build_windows):
            win.close()
        w.deleteLater()


def test_row_identity_tells_builds_apart_and_survives_a_reload(tmp_path):
    """The pure half — no widgets. Identity is stable across a reload and distinct per
    build, which is the whole basis of the re-resolution."""
    out = tmp_path / "out"
    (out / "wl-be.x86").mkdir(parents=True)
    (out / "wl-fe.arm64").mkdir(parents=True)
    first = [sw._RowData("unmanaged", unmanaged=u)
             for u in bs.discover_unmanaged(str(out))]
    second = [sw._RowData("unmanaged", unmanaged=u)
              for u in bs.discover_unmanaged(str(out))]
    assert len({sw.row_identity(r) for r in first}) == 2      # distinct per build
    assert ({sw.row_identity(r) for r in first}
            == {sw.row_identity(r) for r in second})          # stable across a reload
    assert all(r1 is not r2 for r1 in first for r2 in second)  # different objects
    assert sw.row_identity(sw._RowData("unreadable", path=str(out / "x.json"))) == (
        "unreadable", os.path.normpath(str(out / "x.json")))
    assert sw.row_identity(object()) is None                  # no identity -> no match
