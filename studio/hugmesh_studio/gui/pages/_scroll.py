"""Shared helper: let a tall wizard page scroll instead of clipping.

The Studio wizard window opens at one screen-clamped "medium" size for every page
(``StudioWizard`` / ``gui.wizard.medium_size``) and the user may resize it smaller;
several pages stack more rows/group-boxes than fit that height (Review&Build,
Network, Role, Home), so their lower controls were clipped with no way to reach
them. This is what keeps a tall page SCROLLING rather than growing the window —
the wizard deliberately does not resize itself to fit its pages.

There is deliberately no scroll-to-widget helper here any more. One existed
(``reveal``) for exactly one caller: the mesh worklist's per-row command button, whose
output pane sat a thousand pixels below it. Moving the operator's viewport turned out to
BE the complaint ("it just scrolls the window"), so that button's output moved next to
the button instead — see ``pages/build.py:_preview_entry``. A control whose output is
off screen wants its output relocated, not the viewport hijacked.

``scrollable(page)`` gives the page a single vertical ``QScrollArea`` whose inner
widget carries the real content layout, and returns that content layout. Callers
build their rows into the returned layout exactly as they did into the old
``QVBoxLayout(self)`` — the only change at each call site is the one line that
creates the layout. ``setWidgetResizable(True)`` keeps the content the full width
of the viewport (no horizontal scrollbar); a vertical scrollbar appears only when
the content is taller than the viewport.

That "full width" is a floor, not a ceiling. The content can never be squeezed below
its own ``minimumSizeHint()``, so one child that cannot shrink — a long QCheckBox
(checkbox text never wraps), a QHBoxLayout row of radios — makes the content WIDER
than the viewport, and with the horizontal scrollbar off the excess is simply cut:
the controls on the right are drawn past the edge and cannot be reached (GUI-03: the
Role page's posture checkbox forced a 1750px content into a 1000px viewport).
Keeping the scrollbar off is deliberate — a sideways-scrolling wizard page is its own
defect — so the rule for a scrollable page is: every row must be able to WRAP. Long
text goes in a word-wrapped QLabel, a row of many buttons goes in
``flow_layout.flow_box``. ``horizontal_overflow`` is the measurement page tests use
to hold a page to that rule.
"""
from ..qt import Qt, QtWidgets


class _SqueezeFirst(QtWidgets.QWidget):
    """Scrolled content that is squeezed to its MINIMUM height before it scrolls.

    A resizable QScrollArea gives content whose layout is height-for-width (any
    word-wrapped label makes it one) its PREFERRED height. A page with a table then
    scrolls as soon as the table cannot have its full height, although the table could
    simply have shrunk. Answering with the layout's minimum keeps the page laid out
    exactly as it is without a scroll area for as long as it fits, and scrolls only
    when even the minimum does not fit.
    """

    def heightForWidth(self, width: int) -> int:  # noqa: N802 (Qt override)
        lay = self.layout()
        return lay.minimumHeightForWidth(width) if lay is not None else -1


def scrollable(page: QtWidgets.QWidget, *,
               squeeze_first: bool = False) -> QtWidgets.QVBoxLayout:
    """Wrap ``page`` in a vertical scroll area; return the inner content layout.

    ``squeeze_first`` is for a page whose rows can shrink (a table): see
    :class:`_SqueezeFirst`."""
    content = _SqueezeFirst() if squeeze_first else QtWidgets.QWidget()
    content_layout = QtWidgets.QVBoxLayout(content)

    scroll = QtWidgets.QScrollArea(page)
    scroll.setWidgetResizable(True)
    scroll.setFrameShape(QtWidgets.QFrame.Shape.NoFrame)
    scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
    scroll.setWidget(content)

    outer = QtWidgets.QVBoxLayout(page)
    outer.setContentsMargins(0, 0, 0, 0)
    outer.addWidget(scroll)
    # Stashed so anything needing THIS scroll area gets it by identity rather than by
    # findChild, which walks the whole subtree and would happily return a QScrollArea a
    # page nested inside its own content. (The one consumer, reveal(), is gone; the
    # handle stays because identity is the only correct way to name it.)
    page._content_scroll = scroll
    return content_layout


def horizontal_overflow(page: QtWidgets.QWidget) -> int:
    """How many pixels of ``page``'s scroll content cannot fit its viewport — 0 when
    it fits.

    Measured from the content's ``minimumSizeHint()`` (what the layout CANNOT go
    below) rather than its current width, so it reports the defect even before the
    page has been shown or resized. A pure measurement: it changes nothing, so a test
    or a walker can call it on a live page at any window size. Raises AttributeError
    on a page that was never passed through ``scrollable()``."""
    scroll = page._content_scroll
    return max(0, scroll.widget().minimumSizeHint().width() - scroll.viewport().width())
