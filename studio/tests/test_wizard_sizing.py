"""Wizard geometry — the "size changes wildly as you proceed" report.

Two independent root causes, both regression-guarded here:

A. ``gui/pages/keyzip.py`` carried a 249-character QCheckBox label. A QCheckBox cannot
   word-wrap, so its minimumSizeHint width (measured: 1387px) became a hard floor that
   QWizard could not lay out below — reaching the key-zip page FORCED the window to
   1431px wide and it never shrank back.
B. ``gui/pages/progress.py`` explicitly ratcheted the window to 1040x780, growing but
   never shrinking, and ignoring the screen entirely.

The fix is one screen-clamped "medium" size for the whole flow, centred on first show.
``test_no_page_jitter_across_the_whole_flow`` is the test that actually reproduces the
report; the rest guard the classes of bug that produced it.
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo          # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod             # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtGui, QtWidgets      # noqa: E402
from hugmesh_studio.gui.wizard import StudioWizard, medium_size  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# a canned host so wizard construction never probes the machine (docker info &c.)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    yield w
    w.close()
    w.deleteLater()


# (label, available-geometry) — real screens this must fit on, incl. deliberately tiny
# ones. The old ratchet ignored the screen, so the netbook/800x800 rows are the point.
_SCREENS = [
    ("1080p", QtCore.QRect(0, 0, 1920, 1080)),
    ("1440p", QtCore.QRect(0, 0, 2560, 1440)),
    ("768p laptop", QtCore.QRect(0, 0, 1366, 768)),
    ("1024x600 netbook", QtCore.QRect(0, 0, 1024, 600)),
    ("800x800", QtCore.QRect(0, 0, 800, 800)),
    ("tiny 640x480", QtCore.QRect(0, 0, 640, 480)),
]


@pytest.mark.parametrize("label,avail", _SCREENS, ids=[s[0] for s in _SCREENS])
def test_medium_size_always_fits_the_screen(label, avail):
    """The medium never exceeds the available geometry — a pure function of the rect, so
    screens the test host does not have are still covered."""
    size = medium_size(avail)
    assert size.width() <= avail.width() and size.height() <= avail.height(), (
        f"{label}: {size} does not fit {avail}")
    assert size.width() > 0 and size.height() > 0


def test_medium_size_prefers_the_readable_size_on_a_big_screen():
    """On any screen with room, the medium is the 1040x780 the progress page used to
    ratchet to — i.e. the readability requirement is met by the default, which is what
    made the ratchet removable."""
    assert medium_size(QtCore.QRect(0, 0, 1920, 1080)) == QtCore.QSize(1040, 780)


def test_medium_size_clamps_below_the_preferred_on_a_small_screen():
    """Real-cases check for the clamp: a small screen must actually shrink the window (the
    old code hardcoded 1040x780 regardless and overflowed the display)."""
    small = medium_size(QtCore.QRect(0, 0, 800, 800))
    assert small.width() < 1040 and small.height() < 780
    assert small == QtCore.QSize(736, 736)


def _avail():
    return QtGui.QGuiApplication.primaryScreen().availableGeometry()


def test_no_page_jitter_across_the_whole_flow(wiz):
    """THE report: walk every page and assert the window never changes size.

    Deliberately walks pageIds() rather than the mode-gated flow so the pages that used
    to force the jump (KeyZip) are visited regardless of mode.
    """
    wiz.show()
    sizes = {}
    for pid in wiz.pageIds():
        page = wiz.page(pid)
        wiz.setStartId(pid)
        wiz.restart()
        QtWidgets.QApplication.processEvents()
        sizes.setdefault((wiz.width(), wiz.height()), []).append(type(page).__name__)
    wiz.setStartId(-1)
    assert len(sizes) == 1, f"window size jitters across pages: {sizes}"


def test_no_page_forces_the_window_wider_than_the_medium(wiz):
    """Guard the CLASS of bug root cause A was: an un-wrappable label (QCheckBox /
    QLabel with wordWrap off) whose minimumSizeHint exceeds the window width drags the
    whole wizard wider, on every page, permanently. Catches the next one."""
    wiz.show()
    medium = medium_size(_avail())
    too_wide = {}
    for pid in wiz.pageIds():
        page = wiz.page(pid)
        try:
            page.initializePage()      # populate trees/tables: measure the REAL minimum
        except Exception:
            pass
        mw = page.minimumSizeHint().width()
        if mw > medium.width():
            too_wide[type(page).__name__] = mw
    assert not too_wide, (
        "page minimum widths exceed the wizard's medium width "
        f"({medium.width()}px) — the window will be forced wider on these pages: "
        f"{too_wide}. A QCheckBox cannot word-wrap: put long prose in a wrapped QLabel.")


def test_keyzip_remember_roles_label_stays_short(wiz):
    """Root cause A, pinned at source. The prose belongs in the wrapped gray QLabel
    beside the box; the LABEL must stay short or the hard floor comes back.

    The old label measured 1387px of un-wrappable minimum width; the whole page's
    minimum is now well under the medium.
    """
    from hugmesh_studio.gui.pages.keyzip import KeyZipPage
    page = [wiz.page(p) for p in wiz.pageIds()
            if isinstance(wiz.page(p), KeyZipPage)][0]
    assert len(page.remember_roles.text()) < 80, page.remember_roles.text()
    assert page.remember_roles.minimumSizeHint().width() < 600
    # the preference it drives is untouched — presentation-only change
    assert page.remember_roles.isChecked() is False


def test_wizard_opens_centred_and_fully_on_screen(wiz):
    """Centred on the primary screen on first show, and wholly within it.

    NOTE this one is a smoke test, NOT the guard: QWizard is a QDialog, and Qt's
    QDialog::adjustPosition auto-centres a parentless dialog on show, so this passes
    even with our centring deleted (a bare QWizard measures dead-centre, 0px error).
    test_centred_top_left_* below is what actually guards the arithmetic.
    """
    wiz.show()
    QtWidgets.QApplication.processEvents()
    avail = _avail()
    fg = wiz.frameGeometry()
    assert avail.contains(fg), f"window {fg} is not fully within the screen {avail}"
    # ~4px of slack for the window-manager frame border.
    assert abs(fg.center().x() - avail.center().x()) <= 4
    assert abs(fg.center().y() - avail.center().y()) <= 4


@pytest.mark.parametrize("avail", [
    QtCore.QRect(0, 0, 1920, 1080),          # 1080p
    QtCore.QRect(0, 0, 2560, 1440),          # 1440p
    QtCore.QRect(0, 0, 1366, 768),           # laptop
    QtCore.QRect(0, 0, 1024, 600),           # netbook
    QtCore.QRect(1920, 0, 1920, 1080),       # a SECOND screen, x-offset from the origin
    QtCore.QRect(0, 27, 1920, 1053),         # a top panel/menu bar eating the top strip
    QtCore.QRect(-1920, -200, 1920, 1080),   # a screen left of / above the origin
])
def test_centred_top_left_centres_on_any_screen(avail):
    """THE centring guard. Drives the arithmetic directly over screens this host does
    not have, so it fails when the centring is wrong — unlike showing the wizard, which
    Qt's own QDialog auto-centring would satisfy regardless.

    The offset rects are the cases a naive width/2 (rather than rect-centre) gets wrong:
    a second monitor, a reserved panel strip, and negative origins.
    """
    size = medium_size(avail)
    frame = QtCore.QRect(QtCore.QPoint(0, 0), size)
    top_left = wizard_mod.centred_top_left(frame, avail)
    placed = QtCore.QRect(top_left, size)
    off = placed.center() - avail.center()
    # 1px, and 1px only: QRect is integer, and an even-width rect has no exact integer
    # centre — QRect::center() floors, so moveCenter()/center() do not round-trip on a
    # negative origin (measured: QRect(-1920,-200,1920,1080).center().x() == -960, and
    # placing a 1040-wide window there reads back -959). That is Qt's rounding, not our
    # arithmetic; a centring that is actually WRONG is off by hundreds of px, so this
    # tolerance costs the assertion nothing.
    assert abs(off.x()) <= 1 and abs(off.y()) <= 1, (
        f"{placed} is not centred on {avail} (off by {off})")
    assert avail.contains(placed), f"{placed} is not fully within {avail}"


def test_centred_top_left_is_pure_and_does_not_mutate_its_argument():
    """It takes the LIVE frameGeometry() of the window it is about to move; moving that
    rect in place instead of copying would be a self-inflicted heisenbug."""
    avail = QtCore.QRect(0, 0, 1920, 1080)
    frame = QtCore.QRect(10, 20, 1040, 780)
    before = QtCore.QRect(frame)
    wizard_mod.centred_top_left(frame, avail)
    assert frame == before, "centred_top_left mutated the rect it was passed"


def test_wizard_opens_at_the_medium_size(wiz):
    wiz.show()
    assert wiz.size() == medium_size(_avail())


def test_centring_is_one_shot_and_does_not_steal_a_moved_window(wiz):
    """A user who drags the window must not have it yanked back to centre by the next
    show/hide (dialogs and restart() both trigger one)."""
    wiz.show()
    QtWidgets.QApplication.processEvents()
    wiz.move(wiz.x() + 40, wiz.y() + 30)
    moved = wiz.pos()
    wiz.hide()
    wiz.show()
    QtWidgets.QApplication.processEvents()
    assert wiz.pos() == moved, "the wizard re-centred itself over the user's own position"


def test_wizard_stays_user_resizable(wiz):
    """resize(), never setFixedSize() — and nothing is persisted between runs."""
    wiz.show()
    wiz.resize(700, 560)
    QtWidgets.QApplication.processEvents()
    assert wiz.size() == QtCore.QSize(700, 560)
    assert wiz.minimumSize() != wiz.maximumSize()      # not pinned to one size
    fresh = StudioWizard(wiz.generator_dir)
    assert fresh.size() == medium_size(_avail()), "geometry leaked between wizards"


def test_progress_page_no_longer_ratchets_the_window(wiz):
    """Root cause B, pinned at source: no page may resize the wizard."""
    import inspect
    from hugmesh_studio.gui.pages import progress
    src = inspect.getsource(progress.ProgressPage.initializePage)
    assert "resize(" not in src, "the progress page ratchet is back"


def test_medium_size_is_above_every_page_minimum(wiz):
    """The medium must be comfortably usable, not merely 'fits the screen': every page
    must be able to lay out its minimum inside it on a real 1080p screen."""
    wiz.show()
    medium = medium_size(QtCore.QRect(0, 0, 1920, 1080))
    for pid in wiz.pageIds():
        page = wiz.page(pid)
        try:
            page.initializePage()
        except Exception:
            pass
        m = page.minimumSizeHint()
        assert m.width() <= medium.width(), type(page).__name__


def test_the_brand_pages_on_a_mesh_fit_the_smallest_window_and_do_not_jitter(wiz):
    """#654, D8 and D9: the Branding page (drop-down and design step), the Network page
    (read-only brand rows), the Domains page (its summaries) and the Domain services
    page (four tabs) in MESH mode ask for no more width than the 800x800 screen's window
    (736 px) and the window keeps its one size across them. The pages are measured with
    the design OPEN and a brand row present: the tallest, widest state each has."""
    from hugmesh_studio.core.config import Domain
    wiz.cfg.mode = "mesh"
    wiz.cfg.domains = [Domain(name="shop.example", title="Shop"),
                       Domain(name="blog.example", title="Blog", idp="own")]
    wiz.show()
    smallest = medium_size(QtCore.QRect(0, 0, 800, 800))
    assert smallest.width() == 736
    sizes = {}
    for cls in (wizard_mod.BrandingPage, wizard_mod.NetworkPage, wizard_mod.DomainsPage,
                wizard_mod.DomainServicesPage):
        pid = next(p for p in wiz.pageIds() if isinstance(wiz.page(p), cls))
        page = wiz.page(pid)
        wiz.setStartId(pid)
        wiz.restart()
        QtWidgets.QApplication.processEvents()
        assert page.minimumSizeHint().width() <= smallest.width(), (
            f"{cls.__name__} asks for {page.minimumSizeHint().width()}px of "
            f"{smallest.width()}")
        sizes.setdefault((wiz.width(), wiz.height()), []).append(cls.__name__)
    wiz.setStartId(-1)
    assert len(sizes) == 1, f"window size jitters across the brand pages: {sizes}"
    branding = wiz.page(next(p for p in wiz.pageIds()
                             if isinstance(wiz.page(p), wizard_mod.BrandingPage)))
    assert branding.superbrand is not None and not branding.superbrand.isHidden()
