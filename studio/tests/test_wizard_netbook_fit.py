"""Every wizard page fits the smallest window the Studio opens at by default.

``wizard.medium_size`` clamps the wizard to the screen. On a 1024x600 netbook that
gives 942x552. Take away the page header, the button row and the folded Studio panel,
and the page itself gets about 916x405. A page that asks for more than that does not
scroll. Instead, one of two things happens, and both are on screen:

* SYSTEM (GUI-13 / B-02): a mesh worklist with seven images gives seven per-image
  hostname rows. The page used a plain QVBoxLayout, and its minimum came to 410px in a
  405px page. Qt squeezed every QLineEdit below its own size hint, and the role-derived
  placeholders were cut in half.
* BUILDING (GUI-13 / A5): the ProgressPage minimum was 462px when idle. After an
  all-ok mesh run it was more, with the saved-mesh banner, the footer lines and the
  "Flash to a device" group shown (671 px). Qt grew the window to 942x656, taller than
  a 600 px screen, or laid the page out under its minimum. Either way the footer ("mesh
  manifest written: ...") was drawn over the job rows of the tree.

What is checked:

* ``test_every_page_minimum_fits_the_netbook_page_area`` takes the page area from a
  REAL Studio window: the shell, with its bottom panel folded, at medium_size of a
  1024x600 screen. Every registered page must then lay its minimum out inside that
  area. It goes over ``wiz.pageIds()`` rather than a list of classes, so a page added
  to WIZARD_PAGE_SLUGS later is measured without anyone remembering to add it here.
* The page-minimum check stops seeing a page once the page is wrapped in a scroll
  area: the minimum becomes the scroll area's, about 68x68. So each of the two
  defects also gets a state test that measures the controls themselves. These are the
  tests that go red if either fix is reverted.
* Scrolling the Building page brought problems of its own, each pinned here. The
  content was sized to its PREFERRED height (941 px at every window size), wrapped
  labels in the splitter panes got less than their text, Stop all scrolled away
  mid-build, and a finished run scrolled at the 1040x780 default. The tests check the
  page after an all-ok run, the same run at 1040x780, and a build caught mid-run.

No build, key generation or flash runs. The per-image driver, the key generator's
Popen and the flash-target listing are replaced before the page is reached. The
Studio panel's local assistant is scripted by test_studio_panel's ``_pinned``.
Screenshots go to STUDIO_PANEL_SHOTS, or to a temp folder whose path is printed.
"""
import os
import subprocess

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import worklist_driver as wd                  # noqa: E402
from hugmesh_studio.core.config import (                               # noqa: E402
    WIZARD_PAGE_SLUGS, Domain, ImageConfig, User)
from hugmesh_studio.core.flash_targets import FlashTarget              # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.pages import _images_mesh                      # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                    # noqa: E402

from _helpers import advance_to, check_worklist_rows, pick_mode        # noqa: E402
from test_studio_panel import (SMALLEST, _pinned, open_at, qapp,      # noqa: E402,F401
                               settle, shell, shot, wait_for)

#: the documented netbook screen, and the window medium_size gives it
NETBOOK = QtCore.QRect(0, 0, 1024, 600)

#: the lane's mesh-many-rows worklist: seven images, so seven hostname rows
SEVEN_IMAGES = ("pki.x86", "pki.rpi5", "backend.x86", "backend.rpi5",
                "frontend.x86", "frontend.rpi5", "omnibus.x86")


def _netbook_window(shell, qapp):
    """A real Studio window at medium_size(1024x600), with its bottom panel folded.
    That is the state the Studio opens in on that screen."""
    size = wizard_mod.medium_size(NETBOOK)
    assert size == SMALLEST, f"medium_size(1024x600) moved to {size}; update SMALLEST"
    wiz = open_at(shell, qapp, size)
    wiz.local_ai_dock.set_expanded(False)
    wiz.resize(size)
    settle(qapp, 8)
    return wiz


def _fold_and_settle(wiz, qapp):
    wiz.local_ai_dock.set_expanded(False)
    wiz.resize(SMALLEST)
    settle(qapp, 8)


def _rect_in(ancestor, w):
    return QtCore.QRect(w.mapTo(ancestor, QtCore.QPoint(0, 0)), w.size())


def _layout_minimum(w):
    """The minimum a layout really gives ``w``. An explicit setMinimumWidth/Height
    wins over minimumSizeHint(), as in Qt's qSmartMinSize. Reading only the hint
    misses a page that sets its own minimum: a 420 px HardwarePage passed a
    hint-only sweep."""
    hint, explicit = w.minimumSizeHint(), w.minimumSize()
    return QtCore.QSize(explicit.width() if explicit.width() > 0 else max(hint.width(), 0),
                        explicit.height() if explicit.height() > 0 else max(hint.height(), 0))


# ── the guard: every page ────────────────────────────────────────────────────────────
def test_every_page_minimum_fits_the_netbook_page_area(shell, qapp):
    """Every registered page's minimum (after initializePage, so trees and tables
    hold their real rows) fits the page area of the 942x552 window."""
    wiz = _netbook_window(shell, qapp)
    first = wiz.currentPage()
    # The welcome page scrolls, so it fills exactly the area the wizard gives a page.
    # Taken from the live window, so a change to the header, the button row or the
    # folded panel moves the area here too.
    area = first.size()
    assert wiz.size() == SMALLEST
    assert area.width() > 800 and area.height() > 300, (
        f"the measured page area {area.width()}x{area.height()} is implausible: the "
        "window did not lay out, so this test would pass for any page")
    ids = set(wiz._page_ids)
    missing = [s for s in WIZARD_PAGE_SLUGS if s not in ids]
    assert not missing, f"slugs with no registered page, so never measured: {missing}"

    too_big = {}
    for pid in wiz.pageIds():
        page = wiz.page(pid)
        try:
            page.initializePage()
        except Exception:                      # noqa: BLE001 - measure what we have
            pass
        m = _layout_minimum(page)
        if m.width() > area.width() or m.height() > area.height():
            too_big[type(page).__name__] = (m.width(), m.height())
    assert not too_big, (
        f"pages whose minimum does not fit the {area.width()}x{area.height()} page "
        f"area of the {SMALLEST.width()}x{SMALLEST.height()} window (medium_size on a "
        f"1024x600 screen): {too_big}. Lay the page out with pages/_scroll.scrollable() "
        "or lower the minimum of whatever is tall on it.")


# ── SYSTEM: seven per-image hostname rows ────────────────────────────────────────────
def test_system_page_lays_out_seven_hostname_rows_at_full_height(shell, qapp):
    """The lane's mesh-many-rows walk. Main laid out a 410px minimum in a 405px page,
    and every hostname editor was squeezed below its size hint, with the placeholder
    glyphs cut. Each editor must now get its full height, none may overlap the next,
    and the window must keep its size."""
    wiz = _netbook_window(shell, qapp)
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, *SEVEN_IMAGES)
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    _fold_and_settle(wiz, qapp)
    assert set(sysp.hostname_edits) == set(SEVEN_IMAGES)
    assert sysp.hostname_rows.isVisible()
    path = shot(wiz, "system-seven-images-942x552")
    print("system page:", path)

    assert wiz.size() == SMALLEST, f"the System page grew the window to {wiz.size()}"
    m = _layout_minimum(sysp)
    assert m.height() <= sysp.height() and m.width() <= sysp.width(), (
        f"System page minimum {m.width()}x{m.height()} > its {sysp.width()}x"
        f"{sysp.height()} area: Qt lays it out below its minimum")
    squeezed = {rid: (ed.height(), ed.sizeHint().height())
                for rid, ed in sysp.hostname_edits.items()
                if ed.height() < ed.sizeHint().height()}
    assert not squeezed, (
        "hostname editors squeezed below their size hint (height, hint) — the "
        f"placeholder text is cut: {squeezed}")
    rects = sorted((_rect_in(sysp, ed) for ed in sysp.hostname_edits.values()),
                   key=lambda r: r.y())
    for a, b in zip(rects, rects[1:]):
        assert not a.intersects(b), f"hostname editors overlap: {a} and {b}"
    # still reachable: everything below the rows is on the page (it scrolls)
    assert sysp.creds_optin.isVisibleTo(wiz)


# ── BUILDING: an all-ok mesh run, every block shown ──────────────────────────────────
class _OkDriver:
    """Per-image driver for WorklistDriver: every image builds at once and succeeds.
    Same shape as test_pages_progress.FakeBuildDriver."""

    def __init__(self, gen, host, graphical=False, workdir=None):
        self.workdir = workdir
        self.cancelled = False

    def run(self, cfg, backend, on_line=None):
        if on_line:
            on_line(f"==> building {cfg.role}")
        return 0

    def cancel(self):
        self.cancelled = True

    def preflight(self, cfg, backend):
        return []

    def preflight_warnings(self, cfg, backend):
        return []

    def command_string(self, cfg, backend=None):
        return f"cmd:{cfg.role}"


class _KeysProc:
    def __init__(self):
        self.stdout = iter(["generating keys (test)"])

    def wait(self):
        return 0


class _KeysOnlySubprocess:
    """worklist_driver's ``subprocess``, with only its Popen (gen-provision-keys.sh)
    faked. The Studio panel's own probes keep the real module: patching the global
    subprocess.Popen breaks every subprocess.run in the window."""

    def __getattr__(self, name):
        return getattr(subprocess, name)

    @staticmethod
    def Popen(cmd, **kw):
        return _KeysProc()


def _mesh_worklist(tmp_path):
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                       superdomain="core.acme.internal", output_dir=str(tmp_path / "out"))
    base.domains = [Domain(name="acme.example", title="Acme")]
    base.users = [User(username="root-admin", domain="core.acme.internal",
                       role="superadmin")]
    return WorklistConfig(base=base, entries=[WorklistEntry(role="backend", platform="x86"),
                                              WorklistEntry(role="omnibus", platform="x86")])


def _saved_mesh_banner(panel, wiz, session):
    """LocalMeshPanel.begin as the Build screen's "save this mesh" leaves it: shown,
    one status line. No saved-mesh store is written."""
    panel.status.setText("Saved this mesh as 'test' · acme · no services' in Saved "
                         "meshes (a draft until it runs); it points at this build.")
    panel.show()


def _arrive_at_progress(shell, qapp, monkeypatch, tmp_path, driver, *, banner,
                        targets, generate_keys=True):
    """Arrive on the Building page the way the flow does, with nothing real behind it:
    the per-image driver, the key generator's Popen, the flash-target listing and the
    saved-mesh banner are faked BEFORE initializePage dispatches."""
    monkeypatch.setattr(wd, "BuildDriver", driver)
    monkeypatch.setattr(wd, "subprocess", _KeysOnlySubprocess())
    monkeypatch.setattr("hugmesh_studio.core.flash_targets.list_targets", lambda: targets)
    if banner:
        monkeypatch.setattr(_images_mesh.LocalMeshPanel, "begin", _saved_mesh_banner)
    else:
        monkeypatch.setattr(_images_mesh.LocalMeshPanel, "begin",
                            lambda panel, wiz, session: None)
    wiz = _netbook_window(shell, qapp)
    wiz.worklist = _mesh_worklist(tmp_path)
    wiz.build_backend = None
    wiz.generate_node_keys = generate_keys
    wiz.setStartId(wiz._page_ids["progress"])
    try:
        wiz.restart()                           # arrives: initializePage dispatches
    finally:
        wiz.setStartId(-1)
    page = wiz.currentPage()
    assert isinstance(page, wizard_mod.ProgressPage)
    return wiz, page


def _finish(qapp, page):
    assert wait_for(qapp, page.isComplete, timeout=10), "the faked run never finished"
    if page.worker is not None:
        page.worker.wait(5000)
    settle(qapp, 10)


_TARGET = FlashTarget(path="/dev/sdz", size=16 * (1 << 30), model="Test SD",
                      transport="usb", removable=True, kind="usb")


def _wrapped_text_fits(label):
    return label.height() >= label.heightForWidth(label.width()) - 1


def test_progress_page_after_an_all_ok_mesh_run_fits_and_nothing_overlaps(
        shell, qapp, monkeypatch, tmp_path):
    """The lane's mesh-ok run, at 942x552. All of these are shown: the saved-mesh
    banner, a three-line footer (manifest plus two key-zips) and the Flash group. Main
    grew the window to 942x656 and still drew the footer over the job rows. The window
    must keep its size, the page must lay its minimum out, the footer must sit below
    the tree, and both wrapped labels in the splitter must get their full text."""
    wiz, page = _arrive_at_progress(shell, qapp, monkeypatch, tmp_path, _OkDriver,
                                    banner=True, targets=[_TARGET])
    _finish(qapp, page)
    _fold_and_settle(wiz, qapp)
    # every block that made the page tall on main is really on it
    assert [page.driver.results[i].status for i in range(2)] == ["ok", "ok"]
    assert page.local_mesh.isVisibleTo(wiz)
    assert page.flash_group.isVisibleTo(wiz)
    assert page.footer.text().count("\n") >= 2, page.footer.text()
    path = shot(wiz, "progress-mesh-ok-942x552")
    print("progress page:", path)

    assert wiz.minimumHeight() <= SMALLEST.height(), (
        f"the Building page raised the window minimum to {wiz.minimumHeight()}px")
    assert wiz.size() == SMALLEST, f"the Building page grew the window to {wiz.size()}"
    m = _layout_minimum(page)
    assert m.height() <= page.height() and m.width() <= page.width(), (
        f"Building page minimum {m.width()}x{m.height()} > its {page.width()}x"
        f"{page.height()} area: Qt lays it out below its minimum")
    tree, footer = _rect_in(page, page.tree), _rect_in(page, page.footer)
    assert footer.top() >= tree.bottom(), (
        f"the footer {footer} is drawn over the job tree {tree}")
    for label in (page.footer, page.log_help):
        assert _wrapped_text_fits(label), (
            f"{label.text()[:40]!r}: {label.height()} px for "
            f"{label.heightForWidth(label.width())} px of wrapped text — it is cut, or "
            "drawn over its neighbour")
    assert _rect_in(page, page.log_help).top() >= _rect_in(page, page.log).bottom()
    # the tree still shows its job rows, and the log keeps its header
    assert page.tree.viewport().height() >= 2 * page.tree.sizeHintForRow(0)
    assert page.log_header.isVisibleTo(wiz)
    # Stop all / Next failure sit under the scroll area: on screen, never scrolled away
    stop = _rect_in(wiz, page.stop_all_btn)
    assert wiz.rect().contains(stop) and page.stop_all_btn.isVisibleTo(wiz), stop
    assert not page._content_scroll.isAncestorOf(page.stop_all_btn)

    # Once the window is tall enough for the content's minimum, the page does not
    # scroll: the content is the viewport and the splitter takes the rest. The banner's
    # wrapped label gives the content layout height-for-width, and QScrollArea then
    # sizes the content to the layout's PREFERRED height. With a stock QSplitter
    # (preferring about 650 px for its tree and log) that was 941 px at every window
    # size, so a maximised 1920x1080 window still had the log and the Flash group
    # below the fold.
    scroll = page._content_scroll
    need = scroll.widget().minimumSizeHint().height()
    tall = QtCore.QSize(1040, wiz.height() - scroll.viewport().height() + need + 120)
    wiz.resize(tall)
    settle(qapp, 8)
    vp = scroll.viewport()
    assert vp.height() >= need + 100, (tall, vp.height(), need)
    path = shot(wiz, f"progress-mesh-ok-{tall.width()}x{tall.height()}")
    print("progress page:", path)
    assert not scroll.verticalScrollBar().isVisible(), (
        f"the finished page scrolls at {tall.width()}x{tall.height()}: content "
        f"{scroll.widget().height()} px in a {vp.height()} px viewport, minimum {need}")
    assert scroll.widget().height() == vp.height()
    for w in (page.tree, page.footer, page.log_header, page.flash_group):
        r = _rect_in(vp, w)
        assert vp.rect().contains(r), f"{type(w).__name__} {r} is outside {vp.rect()}"
    assert _rect_in(page, page.footer).top() >= _rect_in(page, page.tree).bottom()
    # the spare height went to the splitter, and the tree got the larger share
    assert page.tree.height() > page.log.height(), (page.tree.height(), page.log.height())


def test_progress_page_after_an_all_ok_run_does_not_scroll_at_the_1080p_default(
        shell, qapp, monkeypatch, tmp_path):
    """The common case: an all-ok mesh run that saved no mesh (no banner), in the
    1040x780 window a 1080p screen opens. The whole finished page fits that window,
    the Flash group included, with no page scrollbar. With the tree's old 180 px
    minimum it did not."""
    wiz, page = _arrive_at_progress(shell, qapp, monkeypatch, tmp_path, _OkDriver,
                                    banner=False, targets=[_TARGET])
    _finish(qapp, page)
    normal = wizard_mod.medium_size(QtCore.QRect(0, 0, 1920, 1080))
    wiz.local_ai_dock.set_expanded(False)
    wiz.resize(normal)
    settle(qapp, 8)
    assert not page.local_mesh.isVisibleTo(wiz)
    assert page.flash_group.isVisibleTo(wiz)
    path = shot(wiz, f"progress-mesh-ok-no-banner-{normal.width()}x{normal.height()}")
    print("progress page:", path)
    scroll = page._content_scroll
    vp = scroll.viewport()
    assert wiz.size() == normal
    assert not scroll.verticalScrollBar().isVisible(), (
        f"the finished page scrolls at {normal.width()}x{normal.height()}: content "
        f"minimum {scroll.widget().minimumSizeHint().height()} px in a {vp.height()} px "
        "viewport")
    for w in (page.tree, page.footer, page.log_header, page.log, page.flash_group):
        r = _rect_in(vp, w)
        assert vp.rect().contains(r), f"{type(w).__name__} {r} is outside {vp.rect()}"
    assert _rect_in(page, page.footer).top() >= _rect_in(page, page.tree).bottom()


class _HeldDriver(_OkDriver):
    """Per-image driver whose run() blocks until the test lets go: the page is caught
    MID-BUILD, rows running, with no Flash group yet."""

    release = None                              # a threading.Event, set per test

    def run(self, cfg, backend, on_line=None):
        if on_line:
            on_line(f"==> building {cfg.role}")
        self.release.wait(20)
        return 0


def test_progress_page_mid_build_keeps_stop_all_and_the_tree_on_screen(
        shell, qapp, monkeypatch, tmp_path):
    """Mid-build at 942x552. The content (413 px with the manifest footer and the
    three-line watch help) is taller than the 364 px viewport left under the Stop all
    row, so it scrolls. What must not scroll away: Stop all (it sits under the scroll
    area), and, at the top, the job rows and the log header. Main had a 483 px page
    minimum in the 405 px page and laid all of it out below that instead."""
    import threading
    release = threading.Event()
    monkeypatch.setattr(_HeldDriver, "release", release)
    wiz, page = _arrive_at_progress(shell, qapp, monkeypatch, tmp_path, _HeldDriver,
                                    banner=False, targets=[])
    try:
        assert wait_for(qapp, lambda: page.driver is not None and any(
            r.status == wd.RUNNING for r in page.driver.results)), "no image reached running"
        _fold_and_settle(wiz, qapp)
        assert not page.isComplete()
        path = shot(wiz, "progress-mid-build-942x552")
        print("progress page mid-build:", path)

        assert wiz.size() == SMALLEST
        m = _layout_minimum(page)
        assert m.height() <= page.height(), (m, page.size())
        stop = _rect_in(wiz, page.stop_all_btn)
        assert page.stop_all_btn.isVisibleTo(wiz) and wiz.rect().contains(stop), (
            f"Stop all {stop} is not on screen")
        assert not page._content_scroll.isAncestorOf(page.stop_all_btn)
        assert page.stop_all_btn.isEnabled()
        vp = page._content_scroll.viewport()
        assert page._content_scroll.verticalScrollBar().value() == 0
        for w in (page.tree, page.log_header):
            r = _rect_in(vp, w)
            assert vp.rect().contains(r), f"{type(w).__name__} {r} is outside {vp.rect()}"
        # the tree still shows the job rows, above the footer and the log
        assert page.tree.viewport().height() >= 2 * page.tree.sizeHintForRow(0)
        tree = _rect_in(page, page.tree)
        assert _rect_in(page, page.footer).top() >= tree.bottom()
        assert _rect_in(page, page.log_header).top() >= tree.bottom()
    finally:
        release.set()
        wait_for(qapp, page.isComplete, timeout=10)
        if getattr(page, "worker", None) is not None:
            page.worker.wait(5000)
        settle(qapp, 4)
