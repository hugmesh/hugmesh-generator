"""Tall wizard pages must scroll, not clip.

The Studio wizard window is a fixed 820x640 (``StudioWizard.resize``). Several
pages stack more rows/group-boxes than fit that height — Review&Build, Network,
Role and Home — so before this fix their lower controls were unreachable (no
scrollbar, content simply clipped at the window edge). ``gui/pages/_scroll.py``
gives each of those pages a vertical ``QScrollArea``.

These tests drive the REAL pages on Qt's offscreen platform and assert that (1)
each tall page owns a QScrollArea whose inner content is genuinely taller than the
wizard viewport (so scrolling actually does something), (2) the page's own
sizeHint now fits inside the wizard height (so it no longer forces the window to
grow / clip), and (3) the Role list keeps a usable visible height inside the
scroll area (a stretch factor collapses once the page itself scrolls).
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.gui import wizard as wizard_mod                 # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo             # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# The wizard is 640px tall; subtract the title/subtitle + button-box chrome to get
# the usable per-page viewport. A page taller than this clipped before the fix.
WIZARD_HEIGHT = 640
VIEWPORT = WIZARD_HEIGHT - 120

TALL_PAGES = ("BuildPage", "NetworkPage", "RolePage", "HomePage")

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")


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


def _pages_by_name(wiz):
    return {type(wiz.page(pid)).__name__: wiz.page(pid) for pid in wiz.pageIds()}


def _scroll_of(page):
    areas = page.findChildren(QtWidgets.QScrollArea)
    return areas[0] if areas else None


@pytest.mark.parametrize("name", TALL_PAGES)
def test_tall_page_has_scroll_area(wiz, name):
    page = _pages_by_name(wiz)[name]
    scroll = _scroll_of(page)
    assert scroll is not None, f"{name} must be wrapped in a QScrollArea so it does not clip"
    assert scroll.widgetResizable() is True


@pytest.mark.parametrize("name", TALL_PAGES)
def test_tall_page_scroll_actually_needed(wiz, name):
    """The inner content is taller than the viewport (otherwise the wrap is pointless)."""
    page = _pages_by_name(wiz)[name]
    inner = _scroll_of(page).widget()
    assert inner is not None
    assert inner.sizeHint().height() > VIEWPORT, (
        f"{name} inner content should exceed the {VIEWPORT}px viewport")


@pytest.mark.parametrize("name", TALL_PAGES)
def test_tall_page_itself_fits_viewport(wiz, name):
    """After wrapping, the page's own sizeHint fits the wizard — it no longer forces clip."""
    page = _pages_by_name(wiz)[name]
    assert page.sizeHint().height() <= VIEWPORT + 40, (
        f"{name} page sizeHint {page.sizeHint().height()} should fit the wizard viewport now")


def test_role_list_keeps_usable_height(wiz):
    """RolePage's list had a stretch factor; inside a scroll it must keep a visible height."""
    role = _pages_by_name(wiz)["RolePage"]
    assert role.roles.minimumHeight() >= 240, (
        "the role list must stay tall enough to show several roles inside the scroll area")


def test_progress_page_still_scrolls(wiz):
    """Regression guard: ProgressPage must still scroll its build view. The old flat
    QVBoxLayout-of-QFrames lived in a QScrollArea; the nested job/stage view is now a
    QTreeWidget, which is itself a QAbstractScrollArea (it scrolls natively) — so the guard
    asserts the page owns a scrolling job/stage widget, not specifically a QScrollArea."""
    prog = _pages_by_name(wiz)["ProgressPage"]
    assert isinstance(prog.tree, QtWidgets.QTreeWidget)
    assert prog.tree.findChildren  # sanity: it's a real widget
    # a QTreeWidget IS a QAbstractScrollArea, so the build view scrolls without a wrapper.
    assert isinstance(prog.tree, QtWidgets.QAbstractScrollArea)
