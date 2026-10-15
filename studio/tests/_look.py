"""Shared "look at what is drawn" helpers for Studio page tests (#647, #656, #661).

The Studio's tests drive the MODEL (setChecked, text()) and a control a person cannot
see still answers those. These helpers ask what the screen shows at the wizard's
default window size, and they are meant to be run under more than one Qt style and
at 8 pt as well as the default font, because the #647 measurements showed the
default font alone hides a clipped control.

Every helper is a plain function over Qt geometry so a test can name exactly what
it measured when it fails.

WHERE THE LOOK TESTS RUN. Looking under a style and a font size means switching the
APPLICATION's style, and ``QApplication.setStyle`` re-polishes every widget the process
still holds. A pytest process that has run a few dozen wizard tests holds all of them
(each wizard and its pages point at each other, so only the cycle collector frees
them): measured on tests/test_pages_qemu.py, eight look cases that take 11 s in a fresh
interpreter took more than 170 s after the file's other tests, and freeing the dead
wizards first (``gc.collect`` + posted DeferredDelete) aborted the test process in that
file ("Fatal Python error: Aborted"; tests/conftest.py documents this family of
failure: a live probe thread or a queued slot meeting a deleted page). Styling one wizard's
widgets instead of the application's is cheap but measures a different layout (at 8 pt
the picker's note came out 28 px tall instead of 26). So the look tests run in a FRESH
interpreter: every one is named ``test_look_*`` and starts with :func:`child_only`
(it skips in an ordinary run), and ``tests/test_look.py`` starts one child per test file
with :data:`LOOK_CHILD_ENV` set and reads its verdict.
"""
from __future__ import annotations

import contextlib
import os

import pytest

from hugmesh_studio.gui.qt import QtGui, QtWidgets

#: Set to "1" by tests/test_look.py in the child interpreter it starts.
LOOK_CHILD_ENV = "HUGMESH_LOOK_CHILD"


def child_only() -> None:
    """First line of every ``test_look_*`` test: skip unless this is the fresh child
    interpreter tests/test_look.py started (see the module docstring for why)."""
    if os.environ.get(LOOK_CHILD_ENV) != "1":
        pytest.skip("a look test runs in a fresh interpreter: tests/test_look.py "
                    "starts it")


#: (Qt style, point size or None = the application default). Two styles with
#: different indicator sizes and margins, each at the default font and at 8 pt.
LOOK_CASES = [("Fusion", None), ("Breeze", None), ("Fusion", 8.0), ("Breeze", 8.0)]
LOOK_IDS = ["fusion-default", "breeze-default", "fusion-8pt", "breeze-8pt"]

#: The wizard's default window (``wizard.medium_size`` clamped to the offscreen
#: screen): what a person sees when the Studio opens on a small display.
DEFAULT_WINDOW = (736, 736)


@contextlib.contextmanager
def looking(qapp, style: str, pt: float | None):
    """Set the style and font BEFORE a wizard is built, and restore both after.

    The style must be applied before the widgets exist: QApplication.setStyle
    re-polishes live widgets but their size hints were already computed under the
    old one. Tests therefore build their own wizard inside this context rather than
    use a file-level fixture."""
    if style not in QtWidgets.QStyleFactory.keys():
        pytest.skip(f"Qt style {style!r} is not installed here")
    old_style = qapp.style().objectName()
    old_font = QtGui.QFont(qapp.font())
    try:
        qapp.setStyle(style)
        # A case that silently measured the OLD style (or font) would be a Fusion run
        # wearing another name, so what was asked for must be what is applied.
        assert qapp.style().objectName().lower() == style.lower(), \
            f"asked for the {style!r} style, the application has " \
            f"{qapp.style().objectName()!r}"
        if pt:
            f = QtGui.QFont(old_font)
            f.setPointSizeF(pt)
            qapp.setFont(f)
            assert abs(qapp.font().pointSizeF() - pt) < 0.01, \
                f"asked for {pt} pt, the application font is " \
                f"{qapp.font().pointSizeF()} pt"
        yield
    finally:
        qapp.setFont(old_font)
        qapp.setStyle(old_style)


def settle(qapp, n: int = 3) -> None:
    """Let the layouts land: a few event-loop turns after a show or a page change."""
    for _ in range(n):
        qapp.processEvents()
        qapp.sendPostedEvents()


def snap(wiz, name: str, style: str = "", pt: float | None = None) -> str:
    """Save what the wizard window shows to ``$HUGMESH_LOOK_SHOTS/<name>-<style>-<pt>.png``
    and return the path — "" when that variable is unset (the normal test run saves
    nothing). The point of the look tests is that a person can open the picture a
    reviewer is asked to look at, next to the geometry the test measured."""
    out = os.environ.get("HUGMESH_LOOK_SHOTS", "")
    if not out:
        return ""
    os.makedirs(out, exist_ok=True)
    tag = "-".join(p for p in (name, style.lower() if style else "",
                               f"{pt:g}pt" if pt else "default") if p)
    path = os.path.join(out, tag + ".png")
    wiz.grab().save(path)
    return path


def viewport_of(page):
    """The scroll viewport a ``scrollable()`` page draws in, or the page itself."""
    sa = getattr(page, "_content_scroll", None)
    return sa.viewport() if sa is not None else page


def right_edge_in_viewport(page, widget) -> tuple[int, int]:
    """``(widget's right edge, viewport width)`` in the viewport's coordinates —
    through global coordinates, so the two need not be ancestor and descendant."""
    vp = viewport_of(page)
    right = vp.mapFromGlobal(widget.mapToGlobal(widget.rect().topRight())).x() + 1
    return right, vp.width()


def assert_inside(page, widget, what: str) -> None:
    """``widget`` is visible and its right edge is inside the page's viewport."""
    assert widget.isVisible(), f"{what} is not visible"
    right, width = right_edge_in_viewport(page, widget)
    assert right <= width, f"{what}: right edge at {right}px, viewport is {width}px wide"


def assert_seen_without_scrolling(page, widget, what: str) -> None:
    """``widget`` is visible and WHOLLY inside the page's viewport as first shown —
    right edge and bottom edge — so a person sees all of it without scrolling. A
    page may still scroll for what sits BELOW the widget (a streamed log, say); that
    is not the same as the widget itself being below the fold."""
    assert_inside(page, widget, what)
    vp = viewport_of(page)
    bottom = vp.mapFromGlobal(widget.mapToGlobal(widget.rect().bottomLeft())).y() + 1
    top = vp.mapFromGlobal(widget.mapToGlobal(widget.rect().topLeft())).y()
    assert top >= 0 and bottom <= vp.height(), \
        f"{what}: spans {top}..{bottom}px of a {vp.height()}px viewport (below the fold)"


def assert_whole(label, what: str) -> None:
    """A label draws its whole text: a wrapped one needs no more height than it has,
    a single-line one no more width."""
    assert label.isVisible(), f"{what} is not visible"
    if label.wordWrap():
        need = label.heightForWidth(label.width())
        assert need <= label.height() + 1, \
            f"{what}: needs {need}px of height for its text, has {label.height()}px"
    else:
        need = label.fontMetrics().horizontalAdvance(label.text())
        assert need <= label.width() + 2, \
            f"{what}: needs {need}px of width for its text, has {label.width()}px"


def assert_fits(button, what: str) -> None:
    """A radio button or tick-box draws its whole text next to its indicator (the
    #656 walk script's rule)."""
    assert button.isVisible(), f"{what} is not visible"
    ind = button.style().pixelMetric(QtWidgets.QStyle.PixelMetric.PM_IndicatorWidth)
    need = button.fontMetrics().horizontalAdvance(button.text().replace("&", "")) \
        + ind + 6
    assert need <= button.width() + 2, \
        f"{what}: needs {need}px for its text, has {button.width()}px"


def assert_page_fits_its_window(page) -> None:
    """No visible control on ``page`` reaches past the right edge of its viewport
    (#661: a page whose minimum width exceeds the window clips every line, with no
    sideways scroll to reach the rest). Names the worst offenders when it fails."""
    vp = viewport_of(page)
    content = vp.findChild(QtWidgets.QWidget) if vp is not page else page
    assert content is not None
    over = []
    for w in content.findChildren(QtWidgets.QWidget):
        if not w.isVisible() or not vp.isAncestorOf(w):
            continue
        right, width = right_edge_in_viewport(page, w)
        if right > width:
            over.append((right - width, type(w).__name__,
                         (getattr(w, "text", lambda: "")() or "")[:40]))
    over.sort(reverse=True)
    assert not over, (f"{len(over)} control(s) reach past the viewport "
                      f"({vp.width()}px): " + "; ".join(
                          f"{name} {text!r} by {by}px" for by, name, text in over[:4]))
