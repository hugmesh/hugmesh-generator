"""Shared helper: let a tall wizard page scroll instead of clipping.

The Studio wizard window opens at one screen-clamped "medium" size for every page
(``StudioWizard`` / ``gui.wizard.medium_size``) and the user may resize it smaller;
several pages stack more rows/group-boxes than fit that height (Review&Build,
Network, Role, Home), so their lower controls were clipped with no way to reach
them. This is what keeps a tall page SCROLLING rather than growing the window —
the wizard deliberately does not resize itself to fit its pages.

``reveal(page, widget)`` is the other half: on a page this tall, writing into a
widget that happens to be a thousand pixels below the viewport is indistinguishable
from doing nothing at all, so a control whose only effect is remote output scrolls
its output back into view.

``scrollable(page)`` gives the page a single vertical ``QScrollArea`` whose inner
widget carries the real content layout, and returns that content layout. Callers
build their rows into the returned layout exactly as they did into the old
``QVBoxLayout(self)`` — the only change at each call site is the one line that
creates the layout. ``setWidgetResizable(True)`` keeps the content the full width
of the viewport (no horizontal scrollbar); a vertical scrollbar appears only when
the content is taller than the viewport.
"""
from ..qt import Qt, QtWidgets


def scrollable(page: QtWidgets.QWidget) -> QtWidgets.QVBoxLayout:
    """Wrap ``page`` in a vertical scroll area; return the inner content layout."""
    content = QtWidgets.QWidget()
    content_layout = QtWidgets.QVBoxLayout(content)

    scroll = QtWidgets.QScrollArea(page)
    scroll.setWidgetResizable(True)
    scroll.setFrameShape(QtWidgets.QFrame.Shape.NoFrame)
    scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
    scroll.setWidget(content)

    outer = QtWidgets.QVBoxLayout(page)
    outer.setContentsMargins(0, 0, 0, 0)
    outer.addWidget(scroll)
    # Stashed so reveal() finds THIS scroll area by identity. findChild is the fallback
    # and not the primary: it walks the whole subtree, and a page is free to nest a
    # QScrollArea of its own inside the content later.
    page._content_scroll = scroll
    return content_layout


def reveal(page: QtWidgets.QWidget, widget: QtWidgets.QWidget) -> bool:
    """Scroll ``page`` so ``widget`` is on screen. Returns False if it has no scroll area.

    The layout is ``activate()``d first: a caller typically reveals something it has just
    un-hidden (an expanded ``Collapsible``), and until the layout settles the scroll area
    still holds the widget's PRE-expand geometry — ``ensureWidgetVisible`` would then
    scroll to where the widget used to be. Purely a viewport move: no widget value, no
    enabled-ness and no visibility is touched, so it cannot affect emission."""
    scroll = getattr(page, "_content_scroll", None)
    if scroll is None:
        scroll = page.findChild(QtWidgets.QScrollArea)
    if scroll is None:
        return False
    inner = scroll.widget()
    if inner is not None and inner.layout() is not None:
        inner.layout().activate()
    scroll.ensureWidgetVisible(widget)
    return True
