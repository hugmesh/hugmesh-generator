"""Shared "look at what is drawn" helpers for Studio page tests (#647, #656, #661).

The Studio's tests drive the MODEL (setChecked, text()) and a control a person cannot
see still answers those. These helpers ask what the screen shows at the wizard's
default window size, and they are meant to be run under more than one Qt style and
at 8 pt as well as the default font, because the #647 measurements showed the
default font alone hides a clipped control.

Every helper is a plain function over Qt geometry so a test can name exactly what
it measured when it fails.
"""
from __future__ import annotations

import contextlib

import pytest

from hugmesh_studio.gui.qt import QtGui, QtWidgets

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
    qapp.setStyle(style)
    if pt:
        f = QtGui.QFont(old_font)
        f.setPointSizeF(pt)
        qapp.setFont(f)
    try:
        yield
    finally:
        qapp.setFont(old_font)
        qapp.setStyle(old_style)


def settle(qapp, n: int = 3) -> None:
    """Let the layouts land: a few event-loop turns after a show or a page change."""
    for _ in range(n):
        qapp.processEvents()
        qapp.sendPostedEvents()


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
