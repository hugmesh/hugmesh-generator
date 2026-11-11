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
"""
import os

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
from hugmesh_studio.gui.qt import QtCore, QtWidgets                 # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")

#: The wizard's default window on a small screen, and a short laptop one.
SIZES = [(736, 736), (942, 552)]


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
    w.close()
    w.deleteLater()


def _cfg(tmp_path, **kw):
    kw.setdefault("role", "standalone-thick")
    kw.setdefault("platform", "x86")
    return ImageConfig(mode="standalone", brand="acme",
                       output_dir=str(tmp_path / "out"), **kw)


def _finished(tmp_path, *, workdir=True, **kw):
    s = bs.new_session(synthesize(_cfg(tmp_path, **kw)), GENERATOR_DIR)
    bs.start(s)
    bs.update_image(s, 0, status="ok", exit_code=0)
    bs.finish(s, "complete")
    if workdir:
        os.makedirs(s.workdir, exist_ok=True)
        with open(os.path.join(s.workdir, "image.img"), "w") as fh:
            fh.write("x")
    return s


def _running_elsewhere(tmp_path):
    """A record another Studio is building right now: status running, its pid alive
    on this host (this test process stands in for the other Studio)."""
    s = bs.new_session(synthesize(_cfg(tmp_path, role="generic", platform="rpi5")),
                       GENERATOR_DIR)
    bs.start(s)
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


def test_a_restartable_session_shows_no_note(qapp, wiz, no_modal, tmp_path):
    s = _finished(tmp_path)
    w = _previous_builds(wiz)
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
    row kind seeded here: Restart greys only where can_restart refuses."""
    seeded = [_finished(tmp_path), _finished(tmp_path, workdir=False),
              _running_elsewhere(tmp_path), _services_gap(tmp_path)]
    w = _previous_builds(wiz)
    for s in seeded:
        _select(w, _is_session(s))
        ok, why = w.can_restart(s)
        if not w.restart_btn.isEnabled():
            assert not ok and w.restart_btn.toolTip() == why
        if not w.delete_btn.isEnabled():
            assert bs.is_active(s) and w.delete_btn.toolTip() == sw.IN_USE_REASON


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
@pytest.mark.parametrize("size", SIZES, ids=[f"{w}x{h}" for w, h in SIZES])
def test_the_reason_is_drawn_inside_the_page_without_widening_it(qapp, wiz, no_modal,
                                                                 size, workdir,
                                                                 tmp_path):
    # the longest reason this route states; without its directory it is also the
    # tallest note (a second line for Open artifacts), and SessionsPage does not scroll
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
    min_w_before = page.minimumSizeHint().width()
    _select(w, _is_session(s))
    qapp.processEvents()
    note = w.gate_note
    assert note.isVisible() and note.height() > 0
    assert (sw.MISSING_DIR_REASON in note.text()) is (not workdir)
    assert wiz.size() == QtCore.QSize(*size)     # the window did not grow to fit it
    assert page.minimumSizeHint().width() <= max(min_w_before, size[0])
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
