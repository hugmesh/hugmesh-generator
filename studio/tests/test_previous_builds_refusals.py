"""GUI-26 (B-06/B-07): the Previous-builds buttons say WHY before a click, not after.

The route is Welcome -> Review prior sessions -> Previous builds. Three defects were
verified on main:

* an UNREADABLE record greyed Restart and Redo with an empty tooltip, and "Open
  artifacts" claimed "The artifact directory no longer exists". The real reason is
  that the record could not be read, so it names no directory at all;
* a session RUNNING IN ANOTHER STUDIO left Restart and Delete enabled, and each one
  then refused through a modal ``QMessageBox.warning``;
* Redo moved the wizard to Welcome and THEN popped a modal "Passwords not saved".

Each test below drives the real wizard and the real Sessions page offscreen, and
measures what is drawn where it matters. Every gate is asserted against the click-time
guard it front-runs (``can_restart`` and ``build_sessions.is_active``), so the two
cannot drift apart. The documented confirm dialogs (Restart's confirm, the
missing-directory Redo offer, Delete's confirm) are not part of this defect and are
left as they were.

Round 2 (the second half of this file) is what a review of the first fix found:

* a session running elsewhere STILL showed Restart and Delete enabled, and refused
  each click through a modal, once another build had been deleted from its own
  per-build window. That action reloads the list while its row is pinned, and the gate
  read the pin instead of the highlighted row;
* the grey never lifted when the other Studio exited, until the row was reselected;
* in a window shorter than the defaults the reason was squeezed over the Delete row
  and cut off, and Redo's note landed with its first line scrolled out of view;
* the per-build window called an unreadable record a "pre-session build".

Those tests click with real mouse events, as an operator does.
"""
import os
import subprocess
import sys
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import build_sessions as bs                # noqa: E402
from hugmesh_studio.core import domain_services as ds               # noqa: E402
from hugmesh_studio.core.config import Domain, ImageConfig          # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo              # noqa: E402
from hugmesh_studio.core.worklist import synthesize                 # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                 # noqa: E402
from hugmesh_studio.gui.pages import sessions_widget as sw          # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtGui, QtWidgets          # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")

#: The wizard's default window on a small screen, and a short laptop one.
SIZES = [(736, 736), (942, 552)]
#: A window the operator made short. The page still fits, because its table shrinks.
SQUEEZED = (736, 450)
#: Shorter still, and the wizard's own floor (gui/wizard.py medium_size): the tallest
#: reason no longer fits whatever shrinks.
SHORT = [(600, 420), (518, 401)]
#: Session ids are the sort key (build_sessions.scan lists newest first). Two records
#: minted in the same second sort by their random suffix, so a test that cares which
#: row is above the other names both.
NEWER, OLDER = "20261112-120000-bbbbbb", "20261111-120000-aaaaaa"


def _ids(sizes):
    return [f"{w}x{h}" for w, h in sizes]


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def no_modal(monkeypatch):
    """Every modal this route could pop is recorded. The tests assert none appeared,
    and a stray one never blocks the run."""
    shown = []
    mb = QtWidgets.QMessageBox
    for name in ("warning", "information", "critical", "question"):
        monkeypatch.setattr(
            mb, name,
            staticmethod(lambda *a, _n=name, **k: shown.append((_n, a[1:3]))
                         or mb.StandardButton.Cancel))
    monkeypatch.setattr(mb, "exec",
                        lambda self: shown.append(("exec", self.text()))
                        or mb.StandardButton.Cancel)
    return shown


@pytest.fixture
def wiz(qapp, tmp_path, monkeypatch):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    # never a build from these tests, whatever a regression would let through
    monkeypatch.setattr(w, "start_build_from_session",
                        lambda *a, **k: pytest.fail("a build was dispatched"))
    w.cfg.output_dir = str(tmp_path / "out")
    yield w
    _destroy_build_windows(w)
    w.close()
    w.deleteLater()


def _destroy_build_windows(wiz):
    """Destroy the per-build windows a row click opened, now, while the list that
    opened them is alive. Each has a ``destroyed`` hook that reads that list widget
    (sessions_widget.open_build_window). Left to the garbage collector, a window can
    be destroyed after the collector has already cleared the list widget's wrapper,
    and under PyQt6 the hook's exception then aborts the whole run."""
    widget = wiz.page(wiz._page_ids["sessions"]).previous_builds
    for win in list(widget._build_windows):
        win.close()
        win.deleteLater()
        QtCore.QCoreApplication.sendPostedEvents(win, QtCore.QEvent.Type.DeferredDelete)


def _cfg(tmp_path, **kw):
    kw.setdefault("role", "standalone-thick")
    kw.setdefault("platform", "x86")
    return ImageConfig(mode="standalone", brand="acme",
                       output_dir=str(tmp_path / "out"), **kw)


def _finished(tmp_path, *, workdir=True, sid=None, **kw):
    s = bs.new_session(synthesize(_cfg(tmp_path, **kw)), GENERATOR_DIR, session_id=sid)
    bs.start(s)
    bs.update_image(s, 0, status="ok", exit_code=0)
    bs.finish(s, "complete")
    if workdir:
        os.makedirs(s.workdir, exist_ok=True)
        with open(os.path.join(s.workdir, "image.img"), "w") as fh:
            fh.write("x")
    return s


def _running_elsewhere(tmp_path, *, sid=None, pid=None):
    """A record another Studio is building right now: status running, its pid alive
    on this host. This test process stands in for the other Studio, unless ``pid``
    names a second process that does (one the test can end)."""
    s = bs.new_session(synthesize(_cfg(tmp_path, role="generic", platform="rpi5")),
                       GENERATOR_DIR, session_id=sid)
    bs.start(s)
    if pid is not None:
        s.pid = pid
        bs.save(s)
    os.makedirs(s.workdir, exist_ok=True)
    assert bs.is_active(s)
    return s


def _services_gap(tmp_path, *, workdir=True):
    """A mesh record whose configuration gained a domain with no recorded services
    (#495): restart_gate_reason refuses it by name."""
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                      additional_domains=True, output_dir=str(tmp_path / "out"),
                      domains=[Domain(name="a.example"), Domain(name="b.example")])
    ds.record_reviewed(cfg, ["a.example"])
    s = bs.new_session(synthesize(cfg), GENERATOR_DIR)
    bs.start(s)
    bs.finish(s, "failed")
    if workdir:
        os.makedirs(s.workdir, exist_ok=True)
    return s


def _unreadable():
    os.makedirs(bs.sessions_dir(), exist_ok=True)
    path = os.path.join(bs.sessions_dir(), "zzz-broken.json")
    with open(path, "w") as fh:
        fh.write("{broken")
    return path


def _previous_builds(wiz):
    page = wiz.page(wiz._page_ids["sessions"])
    page.initializePage()
    return page.previous_builds


def _select(w, pred):
    i = next(i for i, r in enumerate(w._row_data) if pred(r))
    w.table.selectRow(i)
    return w._row_data[i]


def _is_session(s):
    return lambda r: r.kind == "session" and r.session.id == s.id


# ── B-06: an unreadable record ────────────────────────────────────────────────────────
def test_an_unreadable_record_says_it_is_unreadable(qapp, wiz, no_modal):
    path = _unreadable()
    w = _previous_builds(wiz)
    row = _select(w, lambda r: r.kind == "unreadable")
    assert row.path == path
    for btn in (w.restart_btn, w.redo_btn):
        assert not btn.isEnabled()
        assert btn.toolTip() == sw.UNREADABLE_RESTART_REASON
    assert not w.open_btn.isEnabled()
    assert w.open_btn.toolTip() == sw.UNREADABLE_ARTIFACTS_REASON
    # the old text blamed a missing directory: an unreadable record recorded none
    assert "no longer exists" not in w.open_btn.toolTip()
    # Delete and the log stay: an unreadable record is still cleaned up and inspected
    assert w.delete_btn.isEnabled() and w.log_btn.isEnabled()
    note = w.gate_note.text()
    assert not w.gate_note.isHidden()
    assert sw.UNREADABLE_RESTART_REASON in note
    assert sw.UNREADABLE_ARTIFACTS_REASON in note
    assert f"{w.restart_btn.text()}, {w.redo_btn.text()}:" in note
    assert no_modal == []


# ── B-06: a session running in another Studio process ─────────────────────────────────
def test_a_session_running_elsewhere_greys_restart_and_delete_with_the_reason(
        qapp, wiz, no_modal, tmp_path):
    s = _running_elsewhere(tmp_path)
    w = _previous_builds(wiz)
    _select(w, _is_session(s))
    # the click-time guard this gate front-runs refuses the same session
    ok, why = w.can_restart(s)
    assert not ok and why == sw.IN_USE_REASON
    for btn in (w.restart_btn, w.delete_btn):
        assert not btn.isEnabled(), btn.text()
        assert btn.toolTip() == sw.IN_USE_REASON
    # Redo makes a NEW session, so a build running elsewhere does not block it
    assert w.redo_btn.isEnabled() and w.redo_btn.toolTip() == ""
    assert not w.gate_note.isHidden()
    assert w.gate_note.text() == (f"{w.restart_btn.text()}, {w.delete_btn.text()}: "
                                  f"{sw.IN_USE_REASON}")
    # a click on either reaches no handler, so no modal can refuse afterwards
    w.restart_btn.click()
    w.delete_btn.click()
    qapp.processEvents()
    assert no_modal == []
    assert os.path.exists(s.path())


def test_a_services_refused_session_greys_restart_up_front(qapp, wiz, no_modal,
                                                           tmp_path):
    s = _services_gap(tmp_path)
    w = _previous_builds(wiz)
    _select(w, _is_session(s))
    ok, why = w.can_restart(s)
    assert not ok and "b.example" in why
    assert not w.restart_btn.isEnabled()
    assert w.restart_btn.toolTip() == why
    assert why in w.gate_note.text()
    # its remedy is Redo, and Redo is right there and live
    assert w.redo_btn.isEnabled() and w.delete_btn.isEnabled()
    w.restart_btn.click()
    assert no_modal == []


def test_moving_to_a_restartable_session_clears_the_reason(qapp, wiz, no_modal,
                                                          tmp_path):
    """Nothing is refused for a restartable session, and nothing a refused row said
    stays behind when the selection moves on to one."""
    busy = _running_elsewhere(tmp_path)
    s = _finished(tmp_path)
    w = _previous_builds(wiz)
    _select(w, _is_session(busy))
    assert not w.restart_btn.isEnabled() and not w.gate_note.isHidden()
    _select(w, _is_session(s))
    assert w.can_restart(s) == (True, "")
    for btn in (w.restart_btn, w.redo_btn, w.open_btn, w.delete_btn):
        assert btn.isEnabled(), btn.text()
        assert btn.toolTip() == "", btn.text()
    assert w.gate_note.isHidden() and w.gate_note.text() == ""


def test_a_gone_directory_keeps_restart_on_its_documented_redo_offer(qapp, wiz,
                                                                    no_modal, tmp_path):
    """Not this defect's: a Restart whose directory is gone OFFERS Redo on click
    (docs/STUDIO-WALKTHROUGH.md), so it stays enabled. Only Open artifacts greys."""
    s = _finished(tmp_path, workdir=False)
    w = _previous_builds(wiz)
    _select(w, _is_session(s))
    assert w.restart_btn.isEnabled() and w.restart_btn.toolTip() == ""
    assert not w.open_btn.isEnabled()
    assert w.open_btn.toolTip() == sw.MISSING_DIR_REASON
    assert w.gate_note.text() == f"{w.open_btn.text()}: {sw.MISSING_DIR_REASON}"


def test_a_gate_that_cannot_be_computed_falls_back_to_the_click_guard(
        qapp, wiz, no_modal, tmp_path, monkeypatch, capsys):
    """_update_buttons is a Qt slot reached from initializePage; under PyQt6 an
    exception escaping it aborts the Studio. A failing gate leaves Restart and Delete
    to their click-time guards instead, and says so on stderr."""
    s = _finished(tmp_path)
    w = _previous_builds(wiz)              # listed first: the Next column probes too

    def boom(_s):
        raise RuntimeError("probe failed")
    monkeypatch.setattr(sw.build_sessions, "is_active", boom)
    _select(w, _is_session(s))
    assert w.restart_btn.isEnabled() and w.delete_btn.isEnabled()
    assert "swallowed exception in _refusals" in capsys.readouterr().err


def test_every_greyed_restart_is_one_the_click_guard_refuses(qapp, wiz, no_modal,
                                                             tmp_path):
    """The up-front gate and the click-time guard never disagree, for every session
    row kind seeded here. Both ways: Restart is greyed exactly where its click would
    refuse outright, with the guard's own words, and Delete exactly where the session
    is running elsewhere. (A gone directory is not a refusal: its click offers Redo.)"""
    seeded = {"finished": (_finished(tmp_path), True),
              "directory gone": (_finished(tmp_path, workdir=False), True),
              "running elsewhere": (_running_elsewhere(tmp_path), False),
              "services gap": (_services_gap(tmp_path), False)}
    w = _previous_builds(wiz)
    for name, (s, restart_live) in seeded.items():
        _select(w, _is_session(s))
        ok, why = w.can_restart(s)
        assert w.restart_btn.isEnabled() is restart_live, name
        if not restart_live:
            assert not ok and w.restart_btn.toolTip() == why, name
        assert w.delete_btn.isEnabled() is (not bs.is_active(s)), name
        if bs.is_active(s):
            assert w.delete_btn.toolTip() == sw.IN_USE_REASON, name


# ── B-07: Redo's unsaved-passwords note lands inline on Welcome ───────────────────────
def _welcome(wiz):
    return wiz.page(wiz._page_ids["welcome"])


@pytest.mark.parametrize("route", ["button", "build window"])
def test_redo_says_unsaved_passwords_on_welcome_not_in_a_modal(qapp, wiz, no_modal,
                                                              route, tmp_path):
    s = _finished(tmp_path, local_pass="hunter2")
    assert s.blanked_secrets == ["local_pass"]
    wiz.resize(*SIZES[0])
    wiz.show()
    w = _previous_builds(wiz)
    row = _select(w, _is_session(s))
    if route == "button":
        w.redo_btn.click()
    else:                                # the per-build window's "Edit as a new build"
        assert w.act_on_row(row, "edit")
    qapp.processEvents()
    assert no_modal == []
    assert wiz.currentId() == wiz._page_ids["welcome"]
    welcome = _welcome(wiz)
    note = welcome.landing_note
    assert note.isVisible()
    assert note.text() == sw.redo_secrets_note(s)
    assert "local-pass was NOT saved" in note.text()
    # drawn where the operator lands: at the top of the page, above the explainer,
    # inside the visible viewport, wrapped to its width and not clipped
    scroll = welcome._content_scroll
    view = scroll.viewport()
    assert scroll.widget().isAncestorOf(note)    # on the page, never a stray window
    assert note.window() is wiz
    top_left = note.mapTo(view, QtCore.QPoint(0, 0))
    assert top_left.y() >= 0
    assert top_left.y() + note.height() <= view.height()
    assert top_left.x() + note.width() <= view.width()
    assert note.mapTo(view, QtCore.QPoint(0, 0)).y() < \
        welcome.explainer.mapTo(view, QtCore.QPoint(0, 0)).y()
    assert note.height() >= note.heightForWidth(note.width())
    assert scroll.verticalScrollBar().value() == 0


def test_redo_from_a_tray_opened_build_window_lands_its_note_too(qapp, no_modal,
                                                                tmp_path):
    """The tray's per-build window delegates through StudioShell._delegate, which
    opens (or raises) a Studio window FIRST and only then runs Redo. A window opened
    after the Redo would re-initialise Welcome and wipe the note; this pins the order."""
    from hugmesh_studio.gui import shell as shell_mod
    s = _finished(tmp_path, local_pass="hunter2")
    sh = shell_mod.StudioShell(GENERATOR_DIR)
    try:
        assert sh.current_window() is None          # the tray route opens the window
        win = sh.open_build_window(s)
        win.buttons["edit"].click()
        qapp.processEvents()
        wiz = sh.current_window()
        assert wiz is not None
        assert wiz.currentId() == wiz._page_ids["welcome"]
        note = _welcome(wiz).landing_note
        assert note.isVisible() and "local-pass was NOT saved" in note.text()
        assert no_modal == []
    finally:
        for w in list(sh.windows) + list(sh.build_windows):
            try:
                w.close()
            except RuntimeError:
                pass


def test_the_redo_note_does_not_outlive_its_redo(qapp, wiz, no_modal, tmp_path):
    blanked = _finished(tmp_path, local_pass="hunter2")
    kept = _finished(tmp_path, role="generic", platform="rpi5")
    assert kept.blanked_secrets == []
    wiz.show()
    w = _previous_builds(wiz)
    _select(w, _is_session(blanked))
    w.redo_btn.click()
    assert _welcome(wiz).landing_note.isVisible()
    wiz.restart()                       # what Load config and a reset come down to
    qapp.processEvents()
    assert _welcome(wiz).landing_note.isHidden()
    assert _welcome(wiz).landing_note.text() == ""
    w = _previous_builds(wiz)
    _select(w, _is_session(kept))
    w.redo_btn.click()                  # a Redo whose record kept everything
    qapp.processEvents()
    assert _welcome(wiz).landing_note.isHidden()
    assert no_modal == []


# ── what is drawn: the reason fits the page at the wizard's own sizes ─────────────────
@pytest.mark.parametrize("workdir", [True, False], ids=["longest", "tallest"])
@pytest.mark.parametrize("size", SIZES + [SQUEEZED], ids=_ids(SIZES + [SQUEEZED]))
def test_the_reason_is_drawn_inside_the_page_without_widening_it(qapp, wiz, no_modal,
                                                                 size, workdir,
                                                                 tmp_path):
    # the longest reason this route states; without its directory it is also the
    # tallest note (a second line for Open artifacts). At these sizes all of it is in
    # view with nothing scrolled: in the SQUEEZED window because the table shrinks to
    # make room, which a page that scrolled before it squeezed would not do.
    s = _services_gap(tmp_path, workdir=workdir)
    wiz.resize(*size)
    wiz.show()
    welcome = _welcome(wiz)
    welcome._buttons["sessions"].setChecked(True)
    wiz.next()
    qapp.processEvents()
    page = wiz.currentPage()
    assert page is wiz.page(wiz._page_ids["sessions"])
    w = page.previous_builds
    w.table.clearSelection()
    qapp.processEvents()
    rows = w.parentWidget()              # what the page's rows are laid out in
    min_w_before = rows.minimumSizeHint().width()
    _select(w, _is_session(s))
    qapp.processEvents()
    note = w.gate_note
    assert note.isVisible() and note.height() > 0
    assert (sw.MISSING_DIR_REASON in note.text()) is (not workdir)
    assert wiz.size() == QtCore.QSize(*size)     # the window did not grow to fit it
    assert rows.minimumSizeHint().width() <= max(min_w_before, size[0])
    assert rows.width() <= page.width()          # and nothing is cut off on the right
    page_rect = page.rect()
    for widget in (note, w.delete_btn, w.delete_all_btn):
        tl = widget.mapTo(page, QtCore.QPoint(0, 0))
        r = QtCore.QRect(tl, widget.size())
        assert page_rect.contains(r), (widget, r, page_rect)
    # under the button grid, inside the group box, and wrapped rather than clipped
    assert note.mapTo(w, QtCore.QPoint(0, 0)).y() >= \
        w.delete_btn.mapTo(w, QtCore.QPoint(0, 0)).y() + w.delete_btn.height()
    assert w.rect().contains(QtCore.QRect(note.mapTo(w, QtCore.QPoint(0, 0)),
                                          note.size()))
    assert note.height() >= note.heightForWidth(note.width())


# ══ round 2: what a review of the first fix found ═════════════════════════════════════
P0 = QtCore.QPoint(0, 0)


def _mouse_click(widget, pos=None):
    """A real left-button press and release, delivered through the application as an
    operator's click is (this host's PyQt6 has no QtTest). A greyed button is sent the
    same two events and ignores them."""
    pos = QtCore.QPointF(pos if pos is not None else widget.rect().center())
    gpos = QtCore.QPointF(widget.mapToGlobal(pos.toPoint()))
    left = QtCore.Qt.MouseButton.LeftButton
    for kind, buttons in ((QtCore.QEvent.Type.MouseButtonPress, left),
                          (QtCore.QEvent.Type.MouseButtonRelease,
                           QtCore.Qt.MouseButton.NoButton)):
        QtWidgets.QApplication.sendEvent(widget, QtGui.QMouseEvent(
            kind, pos, gpos, left, buttons, QtCore.Qt.KeyboardModifier.NoModifier))


def _sessions_page(qapp, wiz, size):
    """Welcome -> Review prior sessions, in a window of ``size``."""
    wiz.resize(*size)
    wiz.show()
    _welcome(wiz)._buttons["sessions"].setChecked(True)
    wiz.next()
    qapp.processEvents()
    page = wiz.currentPage()
    assert page is wiz.page(wiz._page_ids["sessions"])
    return page


def _click_row(qapp, w, pred):
    """Click a row of the table. That selects it and opens its per-build window."""
    i = next(i for i, r in enumerate(w._row_data) if pred(r))
    _mouse_click(w.table.viewport(),
                 w.table.visualItemRect(w.table.item(i, 0)).center())
    qapp.processEvents()
    return w._row_data[i]


def _highlighted(w):
    """The session ids of the rows the table draws as selected."""
    return [w._row_data[i].session.id
            for i in sorted({ix.row() for ix in w.table.selectedIndexes()})]


def _delete_confirm_says_ok(monkeypatch, shown):
    """Delete's own documented confirm is answered Ok. It is still recorded like every
    other modal, and any other box that is exec()'d is still cancelled."""
    mb = QtWidgets.QMessageBox

    def answer(box):
        shown.append(("exec", box.windowTitle()))
        return (mb.StandardButton.Ok if box.windowTitle() == "Delete build session"
                else mb.StandardButton.Cancel)
    monkeypatch.setattr(mb, "exec", answer)


def _wait_until(qapp, cond, timeout=5.0):
    """Run the event loop until ``cond()`` holds or ``timeout`` seconds pass, and say
    which."""
    deadline = time.monotonic() + timeout
    while not cond() and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.01)
    return bool(cond())


def _close_shell(sh):
    """Close everything a StudioShell test opened. Its per-build windows are destroyed
    now, while the shell and the list are alive, for the reason _destroy_build_windows
    gives: the shell's own ``destroyed`` hook reads the shell."""
    for wiz in list(sh.windows):
        try:
            _destroy_build_windows(wiz)
        except RuntimeError:
            pass
    for win in list(sh.build_windows):
        try:
            win.close()
            win.deleteLater()
            QtCore.QCoreApplication.sendPostedEvents(
                win, QtCore.QEvent.Type.DeferredDelete)
        except RuntimeError:
            pass
    for wiz in list(sh.windows):
        try:
            wiz.close()
        except RuntimeError:
            pass


def _assert_refused_as_running_elsewhere(page, w):
    """Restart and Delete are greyed, and the reason is drawn whole under the button
    grid, on the page."""
    for btn in (w.restart_btn, w.delete_btn):
        assert not btn.isEnabled(), btn.text()
        assert btn.toolTip() == sw.IN_USE_REASON, btn.text()
    note = w.gate_note
    assert note.isVisible()
    assert note.text() == (f"{w.restart_btn.text()}, {w.delete_btn.text()}: "
                           f"{sw.IN_USE_REASON}")
    assert page.rect().contains(QtCore.QRect(note.mapTo(page, P0), note.size()))
    assert note.mapTo(w, P0).y() >= \
        w.delete_btn.mapTo(w, P0).y() + w.delete_btn.height()
    assert note.height() >= note.heightForWidth(note.width())


# ── the gate describes the HIGHLIGHTED row, whatever a per-build window has pinned ────
@pytest.mark.parametrize("running_row", ["above", "below"])
@pytest.mark.parametrize("size", SIZES, ids=_ids(SIZES))
def test_deleting_another_build_from_its_window_keeps_the_running_row_greyed(
        qapp, wiz, no_modal, monkeypatch, size, running_row, tmp_path):
    """The review's steps, by mouse. Click finished build B, which opens B's window.
    Click A, which is running in another Studio. Delete B from B's window. A is still
    the highlighted row, so its Restart and Delete stay greyed with the reason, and a
    click on either pops nothing.

    B's Delete reloads the list while B's row is pinned (act_on_row). The gate read
    the pin, found finished B, and enabled both buttons for the row A."""
    a_id, b_id = (NEWER, OLDER) if running_row == "above" else (OLDER, NEWER)
    a = _running_elsewhere(tmp_path, sid=a_id)
    b = _finished(tmp_path, sid=b_id)
    _delete_confirm_says_ok(monkeypatch, no_modal)
    page = _sessions_page(qapp, wiz, size)
    assert wiz.size() == QtCore.QSize(*size)
    w = page.previous_builds
    assert [r.session.id for r in w._row_data] == sorted([a_id, b_id], reverse=True)
    row_b = _click_row(qapp, w, _is_session(b))
    _click_row(qapp, w, _is_session(a))
    assert _highlighted(w) == [a.id]
    _assert_refused_as_running_elsewhere(page, w)
    win_b = next(x for x in w._build_windows if x.row is row_b)
    _mouse_click(win_b.buttons["delete"])
    qapp.processEvents()
    assert no_modal == [("exec", "Delete build session")]
    assert not os.path.exists(b.path())
    assert [r.session.id for r in w._row_data] == [a.id]
    assert _highlighted(w) == [a.id]
    _assert_refused_as_running_elsewhere(page, w)
    _mouse_click(w.restart_btn)
    _mouse_click(w.delete_btn)
    qapp.processEvents()
    assert no_modal == [("exec", "Delete build session")]    # no refusal after a click
    assert os.path.exists(a.path())


@pytest.mark.parametrize("running_row", ["above", "below"])
def test_deleting_from_a_tray_opened_window_keeps_the_running_row_greyed(
        qapp, no_modal, monkeypatch, running_row, tmp_path):
    """The same through the tray. Its per-build window hands the action to the
    Studio's one builds manager (StudioShell._delegate -> act_on_row), which pins the
    same way."""
    from hugmesh_studio.gui import shell as shell_mod
    a_id, b_id = (NEWER, OLDER) if running_row == "above" else (OLDER, NEWER)
    a = _running_elsewhere(tmp_path, sid=a_id)
    b = _finished(tmp_path, sid=b_id)
    _delete_confirm_says_ok(monkeypatch, no_modal)
    sh = shell_mod.StudioShell(GENERATOR_DIR)
    try:
        wiz = sh.open_or_raise()
        monkeypatch.setattr(wiz, "start_build_from_session",
                            lambda *a, **k: pytest.fail("a build was dispatched"))
        wiz.cfg.output_dir = str(tmp_path / "out")
        page = _sessions_page(qapp, wiz, SIZES[0])
        w = page.previous_builds
        _click_row(qapp, w, _is_session(a))
        assert _highlighted(w) == [a.id]
        _assert_refused_as_running_elsewhere(page, w)
        win_b = sh.open_build_window(b)          # the tray's door to one build
        _mouse_click(win_b.buttons["delete"])
        qapp.processEvents()
        assert no_modal == [("exec", "Delete build session")]
        assert not os.path.exists(b.path())
        assert _highlighted(w) == [a.id]
        _assert_refused_as_running_elsewhere(page, w)
        _mouse_click(w.restart_btn)
        _mouse_click(w.delete_btn)
        qapp.processEvents()
        assert no_modal == [("exec", "Delete build session")]
        assert os.path.exists(a.path())
    finally:
        _close_shell(sh)


def test_a_reload_under_another_builds_confirm_does_not_move_the_gate(
        qapp, wiz, no_modal, monkeypatch, tmp_path):
    """The list can be reloaded while a per-build window's confirm is still open and
    its row still pinned: a fleet run's session_changed is wired straight to
    refresh(). The buttons under the table describe the highlighted row throughout,
    not only once the action is over."""
    a = _running_elsewhere(tmp_path, sid=NEWER)
    b = _finished(tmp_path, sid=OLDER)
    page = _sessions_page(qapp, wiz, SIZES[0])
    w = page.previous_builds
    row_b = _click_row(qapp, w, _is_session(b))
    _click_row(qapp, w, _is_session(a))
    win_b = next(x for x in w._build_windows if x.row is row_b)
    during = []

    def confirm(box):
        w.refresh()                              # what session_changed calls
        during.append((_highlighted(w), w.restart_btn.isEnabled(),
                       w.delete_btn.isEnabled(), w.gate_note.text()))
        return QtWidgets.QMessageBox.StandardButton.Cancel
    monkeypatch.setattr(QtWidgets.QMessageBox, "exec", confirm)
    _mouse_click(win_b.buttons["delete"])
    qapp.processEvents()
    assert during == [([a.id], False, False,
                       f"{w.restart_btn.text()}, {w.delete_btn.text()}: "
                       f"{sw.IN_USE_REASON}")]
    assert os.path.exists(b.path())              # the confirm was cancelled
    _assert_refused_as_running_elsewhere(page, w)
    assert no_modal == []


def test_a_tray_windows_delete_does_not_light_the_row_buttons_with_no_row_highlighted(
        qapp, no_modal, monkeypatch, tmp_path):
    """The other face of the same defect. Nobody has clicked a row, so none is
    highlighted and every row button is off. Deleting a build from its tray-opened
    window then left Restart, Redo, Open artifacts and Delete enabled under the table:
    they described the deleted build, and a click on any of them did nothing."""
    from hugmesh_studio.gui import shell as shell_mod
    kept = _finished(tmp_path, sid=NEWER)
    b = _finished(tmp_path, sid=OLDER)
    _delete_confirm_says_ok(monkeypatch, no_modal)
    sh = shell_mod.StudioShell(GENERATOR_DIR)
    try:
        wiz = sh.open_or_raise()
        monkeypatch.setattr(wiz, "start_build_from_session",
                            lambda *a, **k: pytest.fail("a build was dispatched"))
        wiz.cfg.output_dir = str(tmp_path / "out")
        page = _sessions_page(qapp, wiz, SIZES[0])
        w = page.previous_builds
        row_buttons = (w.open_window_btn, w.restart_btn, w.redo_btn, w.open_btn,
                       w.log_btn, w.delete_btn)
        assert _highlighted(w) == []
        assert not any(btn.isEnabled() for btn in row_buttons)
        win_b = sh.open_build_window(b)
        _mouse_click(win_b.buttons["delete"])
        qapp.processEvents()
        assert no_modal == [("exec", "Delete build session")]
        assert not os.path.exists(b.path()) and os.path.exists(kept.path())
        assert [r.session.id for r in w._row_data] == [kept.id]
        assert _highlighted(w) == []
        for btn in row_buttons:
            assert not btn.isEnabled(), btn.text()
        assert w.gate_note.isHidden()
    finally:
        _close_shell(sh)


# ── the grey lifts by itself once the other Studio is gone ───────────────────────────
@pytest.fixture
def quick_recheck(monkeypatch):
    """A row greyed as running elsewhere is asked again every 20 ms instead of every
    2 s. Named BEFORE ``wiz`` in a test's arguments: the widget reads the interval when
    it is built."""
    monkeypatch.setattr(sw, "LIVENESS_RECHECK_MS", 20)


@pytest.fixture
def other_studio():
    """A second live process on this host, standing in for the other Studio. A test
    ends it to say "that Studio exited"."""
    proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"])
    yield proc
    if proc.poll() is None:
        proc.kill()
    proc.wait()


def test_the_grey_lifts_by_itself_once_the_other_studio_is_gone(
        qapp, quick_recheck, wiz, no_modal, other_studio, tmp_path):
    """A greyed button cannot be clicked to find out whether its reason still holds.
    Before the buttons were greyed, the click asked. Now the row is asked again while
    it stays highlighted, and the per-build window the same click opened follows."""
    s = _running_elsewhere(tmp_path, pid=other_studio.pid)
    page = _sessions_page(qapp, wiz, SIZES[0])
    w = page.previous_builds
    row = _click_row(qapp, w, _is_session(s))
    win = next(x for x in w._build_windows if x.row is row)
    _assert_refused_as_running_elsewhere(page, w)
    assert not win.buttons["resume"].isEnabled()
    assert not win.buttons["delete"].isEnabled()
    # it stays refused for as long as that process lives, however often it is asked
    assert not _wait_until(qapp, w.delete_btn.isEnabled, timeout=0.2)
    other_studio.kill()
    other_studio.wait()
    # nobody reselects the row and nobody leaves the page
    assert _wait_until(qapp, w.delete_btn.isEnabled)
    for btn in (w.restart_btn, w.delete_btn):
        assert btn.isEnabled() and btn.toolTip() == "", btn.text()
    assert w.gate_note.isHidden() and w.gate_note.text() == ""
    assert win.buttons["resume"].isEnabled() and win.buttons["delete"].isEnabled()
    assert "another Studio" not in win.note.text()
    # Delete is back on its own documented confirm, as it was before the grey
    _mouse_click(w.delete_btn)
    qapp.processEvents()
    assert no_modal == [("exec", f"Delete the record for “{row.label}”?")]
    assert os.path.exists(s.path())              # the fixture answered Cancel


def test_only_a_row_greyed_as_running_elsewhere_is_asked_again(
        qapp, quick_recheck, wiz, no_modal, monkeypatch, tmp_path):
    busy = _running_elsewhere(tmp_path, sid=NEWER)
    done = _finished(tmp_path, sid=OLDER)
    page = _sessions_page(qapp, wiz, SIZES[0])
    w = page.previous_builds
    asked = []
    real = bs.is_active
    monkeypatch.setattr(bs, "is_active", lambda s: asked.append(s.id) or real(s))
    _select(w, _is_session(busy))
    assert _wait_until(qapp, lambda: asked.count(busy.id) >= 3)     # and asked again
    _select(w, _is_session(done))
    qapp.processEvents()
    del asked[:]
    assert not _wait_until(qapp, lambda: bool(asked), timeout=0.2)  # and no longer
    _select(w, _is_session(busy))
    w.table.clearSelection()
    qapp.processEvents()
    del asked[:]
    assert not _wait_until(qapp, lambda: bool(asked), timeout=0.2)  # nor with no row


def test_out_of_view_nothing_is_asked_and_back_in_view_the_answer_is_fresh(
        qapp, quick_recheck, wiz, no_modal, monkeypatch, other_studio, tmp_path):
    """Closed to the tray, nobody can see the buttons, so nothing is asked. Reopened,
    the page is still the one on screen and nothing reloads it (no initializePage):
    the gate is asked again as the window shows."""
    s = _running_elsewhere(tmp_path, pid=other_studio.pid)
    page = _sessions_page(qapp, wiz, SIZES[0])
    w = page.previous_builds
    _select(w, _is_session(s))
    _assert_refused_as_running_elsewhere(page, w)
    wiz.hide()
    qapp.processEvents()
    asked = []
    real = bs.is_active
    monkeypatch.setattr(bs, "is_active", lambda x: asked.append(x.id) or real(x))
    assert not _wait_until(qapp, lambda: bool(asked), timeout=0.2)
    other_studio.kill()
    other_studio.wait()
    assert not _wait_until(qapp, lambda: bool(asked), timeout=0.2)
    wiz.show()
    qapp.processEvents()
    assert _highlighted(w) == [s.id]             # nobody reselected anything
    for btn in (w.restart_btn, w.delete_btn):
        assert btn.isEnabled() and btn.toolTip() == "", btn.text()
    assert w.gate_note.isHidden() and w.gate_note.text() == ""


def test_a_recheck_that_fails_stops_asking_and_does_not_abort(
        qapp, quick_recheck, wiz, no_modal, monkeypatch, capsys, tmp_path):
    """The re-check is a timer slot, and under PyQt6 an exception escaping a slot
    aborts the Studio. One that fails says so once on stderr and stops asking. The
    buttons stay as they were, greyed, until the row is selected again."""
    s = _running_elsewhere(tmp_path)
    page = _sessions_page(qapp, wiz, SIZES[0])
    w = page.previous_builds
    _select(w, _is_session(s))
    _assert_refused_as_running_elsewhere(page, w)
    capsys.readouterr()

    def boom(_why):
        raise RuntimeError("the note could not be drawn")
    monkeypatch.setattr(w, "_show_refusals", boom)
    said = []
    assert _wait_until(qapp, lambda: said.append(capsys.readouterr().err) or any(
        "swallowed exception in _recheck_liveness" in e for e in said))
    _wait_until(qapp, lambda: False, timeout=0.2)        # ten more intervals
    said.append(capsys.readouterr().err)
    assert "".join(said).count("swallowed exception in _recheck_liveness") == 1
    assert not w.restart_btn.isEnabled() and not w.delete_btn.isEnabled()


# ── a window shorter than the defaults: scroll, never squeeze or clip ─────────────────
@pytest.mark.parametrize("size", SHORT, ids=_ids(SHORT))
def test_in_a_short_window_the_tallest_reason_scrolls_instead_of_being_squeezed(
        qapp, wiz, no_modal, size, tmp_path):
    """Measured before: at 600x420 the five-line note got 61 of the 70 px it needs,
    over a Delete row squeezed from 22 px to 16. The page did not scroll."""
    s = _services_gap(tmp_path, workdir=False)
    page = _sessions_page(qapp, wiz, size)
    w = page.previous_builds
    _select(w, _is_session(s))
    qapp.processEvents()
    assert wiz.size() == QtCore.QSize(*size)
    note = w.gate_note
    assert note.isVisible() and sw.MISSING_DIR_REASON in note.text()
    # whole: every wrapped line of it, and no button squeezed to make room for it
    assert note.height() >= note.heightForWidth(note.width())
    for btn in (w.restart_btn, w.open_btn, w.delete_btn, w.delete_all_btn):
        assert btn.height() >= btn.sizeHint().height(), btn.text()
    # under the Delete row, not over it
    assert note.mapTo(w, P0).y() >= \
        w.delete_btn.mapTo(w, P0).y() + w.delete_btn.height()
    # and reachable: the page scrolls to it, and then all of it is in view
    scroll = page._content_scroll
    assert scroll.horizontalScrollBar().maximum() == 0   # nothing cut off on the right
    scroll.ensureWidgetVisible(note, 0, 0)
    qapp.processEvents()
    view = scroll.viewport()
    assert view.rect().contains(QtCore.QRect(note.mapTo(view, P0), note.size()))


def test_arriving_on_the_page_still_puts_the_keyboard_on_load_config(qapp, wiz):
    """The page is a scroll area now, and a scroll area takes the keyboard when its
    page is entered. This page's first button always had it, and it keeps it."""
    _sessions_page(qapp, wiz, SIZES[0])
    focus = wiz.focusWidget()
    assert isinstance(focus, QtWidgets.QPushButton), focus
    assert focus.text() == "Load config…"


@pytest.mark.parametrize("size", SHORT, ids=_ids(SHORT))
def test_redo_lands_on_its_note_when_welcome_was_left_scrolled(qapp, wiz, no_modal,
                                                               size, tmp_path):
    """In a short window Welcome scrolls, and the Review card is below the fold. The
    page kept that scroll offset when Redo sent the operator back to it, so the note's
    first line was cut off (measured: 13 px above the viewport at 600x420)."""
    s = _finished(tmp_path, local_pass="hunter2")
    wiz.resize(*size)
    wiz.show()
    qapp.processEvents()
    welcome = _welcome(wiz)
    bar = welcome._content_scroll.verticalScrollBar()
    assert bar.maximum() > 0                 # Welcome does not fit a window this short
    bar.setValue(bar.maximum())              # scrolled down to the Review card
    assert bar.value() > 0
    page = _sessions_page(qapp, wiz, size)
    w = page.previous_builds
    _select(w, _is_session(s))
    _mouse_click(w.redo_btn)
    qapp.processEvents()
    assert no_modal == []
    assert wiz.currentId() == wiz._page_ids["welcome"]
    note = welcome.landing_note
    assert note.isVisible() and "local-pass was NOT saved" in note.text()
    view = welcome._content_scroll.viewport()
    top = note.mapTo(view, P0).y()
    assert bar.value() == 0
    assert top >= 0, "the note's first line is scrolled out of view"
    assert top + note.height() <= view.height()
    assert note.height() >= note.heightForWidth(note.width())


# ── the per-build window says the same as the list about an unreadable record ─────────
def test_the_per_build_window_does_not_call_an_unreadable_record_pre_session(
        qapp, wiz, no_modal):
    """The window a click on the row opens gave Resume and Edit the unmanaged tree's
    reason, "No config snapshot exists for a pre-session build". The row is a session
    record that could not be read, which is what the list beside it says."""
    path = _unreadable()
    page = _sessions_page(qapp, wiz, SIZES[0])
    w = page.previous_builds
    row = _click_row(qapp, w, lambda r: r.kind == "unreadable")
    assert row.path == path
    win = next(x for x in w._build_windows if x.row is row)
    for name in ("resume", "edit"):
        btn = win.buttons[name]
        assert not btn.isEnabled(), name
        assert "could not be parsed" in btn.toolTip(), name
        assert "pre-session" not in btn.toolTip(), name
    assert win.note.isVisible()
    assert "pre-session" not in win.note.text()
    assert win.note.text().count("could not be parsed") == 3    # resume, artifacts, edit
    assert win.buttons["delete"].isEnabled() and win.buttons["log"].isEnabled()
    assert no_modal == []
