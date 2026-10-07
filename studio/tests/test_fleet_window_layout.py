"""What a person SEES in the fleet window at its own default size (hugmesh-generator
#647 / #656, the post-merge review of PR #645).

The review measured the window as it was (one QScrollArea around the whole page, a
QStackedWidget whose size hints are the maximum over ALL its steps) at its default
760x700: the Domains step's table was stretched to 770 px so its ‘Add domain’ /
‘Remove selected’ buttons sat 200 px below the viewport, the inline refusal under the
table was never in view, the Tor checkbox's 765 px label made every step scroll 103 px
sideways and cut its help text mid-word, and the Back / Next row was off screen on
every step. 187 green tests drove the model and none of them could see it.

So this file asserts on GEOMETRY, under the styles installed here (Fusion at the
default size; Windows, Breeze and Oxygen at 8 pt, where controls are drawn bigger
relative to the text) — never on ``isHidden()`` alone:

* every step fits the window's width (no sideways scroll) and keeps Back / Next inside
  the window;
* the Domains step shows its two buttons and its whole help text without scrolling;
* a refused row's explanation is inside the viewport — at the default size AND on a
  cramped window where the step does scroll;
* the Tor checkbox's text fits and its note wraps whole;
* the Review refusal wraps instead of scrolling sideways.

The helpers tolerate both layouts (a step in its own scroll area, or one scroll area
around the page), so the same file runs on the tree before the fix and fails there on
geometry, not on an attribute.

THE STYLE IS SET ON THE WINDOW'S OWN WIDGET TREE, NEVER ON THE APPLICATION. A
``QApplication.setStyle`` / ``setFont`` re-polishes every widget alive in the process
— and in the #591 wrapper, which runs twenty-odd files in one process, that includes
the windows earlier files left behind (a ``deleteLater`` is never delivered by
``processEvents``). Measured 2026-09-30: the fixture's restore of the application
style hung at 99 % CPU for 20 minutes inside one of those leftovers (faulthandler:
the fixture's teardown line), while the same file alone took 17 s. ``QWidget.setStyle``
does not propagate, so it is applied to every descendant, again after a step is
entered (a table row's cell widgets are made then), and the style object is kept
alive until the window is gone (a widget does not own its style).
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import build_driver                              # noqa: E402
from hugmesh_studio.core.fleet import FleetDriver                         # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                    # noqa: E402
from hugmesh_studio.gui.pages import fleet as fleet_mod                   # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                       # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")

#: The window's own default (``FleetWindow.__init__``: ``self.resize(760, 700)``).
DEFAULT_SIZE = (760, 700)

#: (style, point size). The default first; then the installed styles whose controls
#: are drawn larger relative to the text, at 8 pt — where the default font alone
#: hides a squeeze (#647's table). A style that is not installed here is not
#: parametrized (never skipped: the #591 wrapper treats a skip as red).
_INSTALLED = set(QtWidgets.QStyleFactory.keys())
COMBOS = [(s, pt) for s, pt in (("Fusion", None), ("Windows", 8.0),
                                ("Breeze", 8.0), ("Oxygen", 8.0))
          if s in _INSTALLED]


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-fleet-layout-tests"]))


@pytest.fixture(params=COMBOS, ids=[f"{s}-{pt or 'default'}pt" for s, pt in COMBOS])
def styled(request):
    """(style name, point size) for one case — applied to the window, never to the
    application (see the module doc)."""
    return request.param


def _restyle(win):
    """Give every widget of ``win``'s tree the case's style (no propagation in Qt),
    and the case's font to the window (that one propagates)."""
    style = win._case_style
    for w in [win, *win.findChildren(QtWidgets.QWidget)]:
        w.setStyle(style)
    if win._case_pt:
        f = win.font()
        f.setPointSizeF(win._case_pt)
        win.setFont(f)


@pytest.fixture
def window(qapp, styled, monkeypatch):
    style_name, pt = styled
    monkeypatch.setattr(build_driver, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    win = fleet_mod.FleetWindow(GENERATOR_DIR)
    p = win.page
    p.driver = FleetDriver(GENERATOR_DIR, HOST)
    p.driver._image_present = lambda: True
    p.driver.run = lambda *a, **k: 0
    style = QtWidgets.QStyleFactory.create(style_name)
    assert style is not None, style_name
    win._case_style, win._case_pt = style, pt        # the window does not own it
    _restyle(win)
    win.show()
    _events()
    _restyle(win)
    _events()
    yield win
    win.close()
    win.deleteLater()
    QtCore.QCoreApplication.sendPostedEvents(None, QtCore.QEvent.Type.DeferredDelete)
    _events()
    del style                                        # after the window is gone


def _events():
    QtWidgets.QApplication.processEvents()


def _rect_in(widget, frame):
    """``widget``'s rectangle in ``frame``'s coordinates."""
    return QtCore.QRect(widget.mapTo(frame, QtCore.QPoint(0, 0)), widget.size())


def _scroll_area(win, i):
    """The scroll area step ``i`` is seen through: its own (``stack.widget(i)`` is a
    QScrollArea), or the one around the whole page on the layout before the fix."""
    w = win.page.stack.widget(i)
    if isinstance(w, QtWidgets.QScrollArea):
        return w
    return next((c for c in win.findChildren(QtWidgets.QScrollArea)
                 if c.parent() is win), None)


def _viewport(win, i):
    sa = _scroll_area(win, i)
    return sa.viewport() if sa is not None else win


def _hbar_max(win, i):
    sa = _scroll_area(win, i)
    return sa.horizontalScrollBar().maximum() if sa is not None else 0


def _goto(win, i):
    win.page._goto(i)
    _events()
    _restyle(win)          # a step's table rows make their cell widgets on entry
    _events()


def _fits(label):
    """A wrapped label's text needs no more height than it has."""
    return label.heightForWidth(label.width()) <= label.height() + 1


def test_the_default_style_is_among_the_measured_ones():
    assert ("Fusion", None) in COMBOS


def test_every_step_fits_the_width_and_keeps_back_and_next_on_screen(window):
    win, p = window, window.page
    assert (win.width(), win.height()) == DEFAULT_SIZE
    for i in range(p.stack.count()):
        _goto(win, i)
        title = fleet_mod._STEP_TITLES[i]
        assert _hbar_max(win, i) == 0, f"step {i} {title!r} scrolls sideways"
        for b in (p.back_btn, p.next_btn):
            assert win.rect().contains(_rect_in(b, win)), (
                f"step {i} {title!r}: {b.text()!r} is outside the window at "
                f"{_rect_in(b, win)}")


def _scroll_ancestors(widget):
    out, w = [], widget.parentWidget()
    while w is not None:
        if isinstance(w, QtWidgets.QScrollArea):
            out.append(w)
        w = w.parentWidget()
    return out


def test_the_navigation_row_is_outside_every_scroll_area_and_each_step_has_its_own(window):
    """The geometry pins above measure where the controls land; this one pins the
    STRUCTURE that puts them there, so an outer scroll area around the whole page
    (the pre-fix layout, which can leave Back/Next in view at one size and not at
    another) cannot come back unnoticed (the skeptic's L8): Back and Next have no
    QScrollArea ancestor at all, and every step is seen through exactly one — its
    own, the stack's widget for that step."""
    win, p = window, window.page
    for b in (p.back_btn, p.next_btn):
        assert _scroll_ancestors(b) == [], f"{b.text()!r} scrolls with a step"
    for i in range(p.stack.count()):
        sa = p.stack.widget(i)
        assert isinstance(sa, QtWidgets.QScrollArea), f"step {i} is not scrolled on its own"
        assert sa.widgetResizable(), f"step {i}'s scroll area does not resize its page"
        assert _scroll_ancestors(sa) == [], f"step {i} sits inside another scroll area"
        assert p.step_scroll(i) is sa


def test_the_domains_step_shows_its_buttons_and_its_whole_help(window):
    win, p = window, window.page
    _goto(win, fleet_mod.STEP_DOMAINS)
    vp = _viewport(win, fleet_mod.STEP_DOMAINS)
    buttons = {b.text(): b for b in p.domains_table.findChildren(QtWidgets.QPushButton)}
    for text in ("Add domain", "Remove selected"):
        r = _rect_in(buttons[text], vp)
        assert vp.rect().contains(r), (
            f"{text!r} is at {r} in a {vp.width()}x{vp.height()} viewport")
    assert _fits(p.domains_help), "the Domains help text is cut"


@pytest.mark.parametrize("size", [DEFAULT_SIZE, (700, 330), (520, 260)],
                         ids=["default", "cramped-700x330", "cramped-520x260"])
def test_a_refused_row_is_explained_where_the_operator_can_see_it(window, size):
    """Next on a junk row keeps the operator on the step and says why, INLINE — and the
    sentence is inside the viewport, also on a window so small that the step scrolls
    (there the page brings it into view after the layout pass has placed it)."""
    win, p = window, window.page
    win.resize(*size)
    _events()
    _goto(win, fleet_mod.STEP_DOMAINS)
    p.domains_table._add("Not A Domain", "")
    _restyle(win)
    p.next_btn.click()
    _events()
    assert p.stack.currentIndex() == fleet_mod.STEP_DOMAINS
    note = p.domains_note
    assert note.isVisible() and "not a domain name" in note.text()
    vp = _viewport(win, fleet_mod.STEP_DOMAINS)
    r = _rect_in(note, vp)
    assert vp.rect().contains(r), (
        f"the refusal is at {r} in a {vp.width()}x{vp.height()} viewport")
    assert _fits(note), "the refusal text is cut"


def test_the_tor_checkbox_and_its_note_are_whole(window):
    """The per-builder sentence is a WRAPPED note under a one-line checkbox: a
    QCheckBox never wraps, and the long form on it was what widened every step."""
    win, p = window, window.page
    _goto(win, fleet_mod.STEP_SHARED)
    cb = p.with_tor
    ind = cb.style().pixelMetric(QtWidgets.QStyle.PixelMetric.PM_IndicatorWidth)
    need = cb.fontMetrics().horizontalAdvance(cb.text()) + ind + 6
    assert need <= cb.width(), f"the Tor checkbox needs {need}px, has {cb.width()}px"
    vp = _viewport(win, fleet_mod.STEP_SHARED)
    assert vp.rect().contains(_rect_in(cb, vp))
    note = p.with_tor_note
    assert note.wordWrap() and _fits(note), "the Tor note is cut"
    assert note.text() and note.isVisible()


def test_every_placeholder_is_whole_in_its_field(window):
    """A field's hint is read before anything is typed; one that is cut at the right
    edge ("(empty = each builder's d…") says less than it should. Every visible
    line edit on every step: the placeholder's advance fits the field less its
    frame and text margins (8 px). Measured before the fix: the Optional services
    hint needed 536 px in a 514 px field at Fusion 9 pt."""
    win, p = window, window.page
    cut = []
    for i in range(p.stack.count()):
        _goto(win, i)
        for le in p.stack.widget(i).findChildren(QtWidgets.QLineEdit):
            ph = le.placeholderText()
            if not ph or not le.isVisibleTo(win):
                continue
            need = le.fontMetrics().horizontalAdvance(ph)
            if need > le.width() - 8:
                cut.append(f"step {i}: {ph[:48]!r} needs {need}px, has {le.width() - 8}px")
    assert not cut, "; ".join(cut)


def test_the_review_refusal_wraps_instead_of_scrolling_sideways(window):
    win, p = window, window.page
    p.cluster_domain.setText("mesh.example")
    _goto(win, fleet_mod.STEP_DOMAINS)
    p.domains_table._add("acme.example", "Acme")
    _restyle(win)
    p.next_btn.click()                                    # -> Domain services
    p.next_btn.click()                                    # -> Review: refused
    _events()
    _restyle(win)
    _events()
    assert p.stack.currentIndex() == fleet_mod.STEP_REVIEW
    assert "acme.example" in p.problems.toPlainText()
    assert p.problems.lineWrapMode() == QtWidgets.QPlainTextEdit.LineWrapMode.WidgetWidth
    assert p.problems.horizontalScrollBar().maximum() == 0
