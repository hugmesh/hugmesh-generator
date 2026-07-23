"""Shared helper: let a tall wizard page scroll instead of clipping.

The Studio wizard window opens at one screen-clamped "medium" size for every page
(``StudioWizard`` / ``gui.wizard.medium_size``) and the user may resize it smaller;
several pages stack more rows/group-boxes than fit that height (Review&Build,
Network, Role, Home), so their lower controls were clipped with no way to reach
them. This is what keeps a tall page SCROLLING rather than growing the window —
the wizard deliberately does not resize itself to fit its pages.

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
    return content_layout
