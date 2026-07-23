"""The HugMesh brand mark, painted with QPainter (no asset file, no extra deps).

A navy rounded square with a white 'S' — the one canonical Studio icon. It used to
live privately in gui/tray.py (tray-only); factored out here so every top-level
window (the wizard, Go-Live, Fleet) and the QApplication itself can carry the same
identity in the title bar / taskbar / alt-tab, instead of the generic Python/Qt icon.

Qt-only by design: importing this pulls in nothing but the binding shim, so app.py
and the tray both reuse it without dragging in the wider GUI. tray.py adds its
build-state badge overlay on top of :func:`brand_pixmap`.
"""
from __future__ import annotations

from .qt import Qt, QtGui

ICON_PX = 64


def brand_pixmap() -> QtGui.QPixmap:
    """A fresh navy rounded square with a white 'S' — the brand mark. Returned fresh each
    call so a badge painter can mutate it without touching a shared pixmap."""
    pm = QtGui.QPixmap(ICON_PX, ICON_PX)
    pm.fill(Qt.GlobalColor.transparent)
    p = QtGui.QPainter(pm)
    p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
    p.setBrush(QtGui.QColor("#1f2740"))
    p.setPen(QtGui.QColor("#3f5b8c"))
    p.drawRoundedRect(4, 4, 56, 56, 12, 12)
    p.setPen(QtGui.QColor("white"))
    f = p.font(); f.setBold(True); f.setPointSize(30); p.setFont(f)
    p.drawText(pm.rect(), Qt.AlignmentFlag.AlignCenter, "S")
    p.end()
    return pm


def brand_icon() -> QtGui.QIcon:
    """The plain brand icon (no build badge)."""
    return QtGui.QIcon(brand_pixmap())
