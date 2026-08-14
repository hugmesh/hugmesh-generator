"""FlowLayout — a QLayout that WRAPS its items onto as many rows as the width needs.

Qt ships no wrapping layout. QHBoxLayout lays every child on ONE line forever: it
reports the sum of all the children's minimum widths as the layout's own minimum,
so a row with enough buttons in it silently sets a window-wide minimum width that
can exceed the screen. The buttons past that point are not merely ugly, they are
UNREACHABLE — you cannot resize the window small enough to see them and you cannot
scroll to them either (operator report 2026-08-14, on the local-mesh page's
fourteen-button action row: "buttons next to generate and start go too far over
... impossible to reach without moving to a bigger screen").

This is the standard Qt "Flow Layout" example, ported to the QtCore/QtWidgets shim
in .qt so it works under PySide6 and PyQt6 alike. Items are placed left-to-right
and wrapped to a new line whenever the next one would cross the right edge, so the
row becomes a BLOCK that grows taller as the window narrows instead of wider than
the screen.

Two deliberate departures from the upstream example:

* Hidden items are SKIPPED (`item.isEmpty()`), not laid out as full-size gaps.
  The upstream example does not do this, and the bug shows here: the local-mesh
  row's Cancel button lives its whole life hidden until a verb is running, and
  without this check it would reserve a permanent hole in the middle of the block.
* `heightForWidth` is honoured, which is what actually makes a parent give this
  layout more vertical room as it wraps. Without it the block is clipped instead
  of growing.
"""
from __future__ import annotations

from .qt import QtCore, QtWidgets, Qt


class FlowLayout(QtWidgets.QLayout):
    """Left-to-right layout that wraps onto new rows to fit the available width."""

    def __init__(self, parent=None, margin: int = 0, spacing: int = 6) -> None:
        super().__init__(parent)
        self._items: list[QtWidgets.QLayoutItem] = []
        self.setContentsMargins(margin, margin, margin, margin)
        self.setSpacing(spacing)

    # ── QLayout plumbing ────────────────────────────────────────────────
    # QLayout is abstract: Qt calls these to walk and own the items. addItem is
    # what addWidget() funnels into, so widgets are added the usual way.

    def addItem(self, item) -> None:  # noqa: N802 (Qt casing)
        self._items.append(item)

    def count(self) -> int:
        return len(self._items)

    def itemAt(self, index: int):  # noqa: N802
        if 0 <= index < len(self._items):
            return self._items[index]
        return None

    def takeAt(self, index: int):  # noqa: N802
        if 0 <= index < len(self._items):
            return self._items.pop(index)
        return None

    def expandingDirections(self):  # noqa: N802
        # Claim no appetite for extra space in either direction: the block should
        # sit at its natural height under the content above it, not fight it.
        return Qt.Orientation(0)

    # ── the wrapping contract ───────────────────────────────────────────

    def hasHeightForWidth(self) -> bool:  # noqa: N802
        return True

    def heightForWidth(self, width: int) -> int:  # noqa: N802
        return self._do_layout(QtCore.QRect(0, 0, width, 0), test_only=True)

    def setGeometry(self, rect) -> None:  # noqa: N802
        super().setGeometry(rect)
        self._do_layout(rect, test_only=False)

    def sizeHint(self):  # noqa: N802
        return self.minimumSize()

    def minimumSize(self):  # noqa: N802
        # The minimum is ONE item wide, never the sum — that is the whole point.
        # Reporting the sum here is exactly what makes QHBoxLayout unshrinkable.
        size = QtCore.QSize()
        for item in self._items:
            if item.isEmpty():
                continue
            size = size.expandedTo(item.minimumSize())
        margins = self.contentsMargins()
        size += QtCore.QSize(margins.left() + margins.right(),
                             margins.top() + margins.bottom())
        return size

    def _do_layout(self, rect, test_only: bool) -> int:
        """Place every visible item, wrapping at `rect`'s right edge.

        Returns the total height consumed. With test_only=True nothing is moved —
        that is the heightForWidth probe, which Qt calls before it has committed
        to a geometry.
        """
        margins = self.contentsMargins()
        effective = rect.adjusted(margins.left(), margins.top(),
                                  -margins.right(), -margins.bottom())
        x = effective.x()
        y = effective.y()
        line_height = 0
        space = self.spacing()

        for item in self._items:
            # Hidden widgets take no room and leave no hole (see module docstring).
            if item.isEmpty():
                continue
            hint = item.sizeHint()
            next_x = x + hint.width() + space
            if next_x - space > effective.right() and line_height > 0:
                # Would overflow: drop to the next row. The `line_height > 0`
                # guard keeps a single item wider than the whole row on its own
                # line instead of looping forever trying to fit it.
                x = effective.x()
                y = y + line_height + space
                next_x = x + hint.width() + space
                line_height = 0
            if not test_only:
                item.setGeometry(QtCore.QRect(QtCore.QPoint(x, y), hint))
            x = next_x
            line_height = max(line_height, hint.height())

        return y + line_height - rect.y() + margins.bottom()


def flow_box(title: str = "") -> tuple[QtWidgets.QWidget, FlowLayout]:
    """A container widget wrapping a FlowLayout, ready to `addWidget` into a page.

    A FlowLayout cannot be handed to `addLayout()` and still wrap correctly: the
    parent needs a WIDGET whose heightForWidth it can consult. Returns the widget
    to add and the layout to put buttons in. Pass a title for a framed QGroupBox,
    or leave it empty for a bare (invisible) container.
    """
    box: QtWidgets.QWidget
    if title:
        box = QtWidgets.QGroupBox(title)
    else:
        box = QtWidgets.QWidget()
    lay = FlowLayout(box)
    # A group box needs room for its frame + title; a bare container should sit
    # flush so the block looks like the row it replaced.
    lay.setContentsMargins(*((8, 8, 8, 8) if title else (0, 0, 0, 0)))
    return box, lay
