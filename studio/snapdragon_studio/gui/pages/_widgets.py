"""Small form-building helpers shared by every wizard page (build + go-live flows).

Kept in their own module (not __init__) so page modules can import them without
touching the package registry — and re-exported from gui.wizard for golive.py's
established ``from ..wizard import _file_picker, _row`` import.
"""
from __future__ import annotations

from ..qt import QtWidgets


def _row(label, widget):
    w = QtWidgets.QWidget()
    h = QtWidgets.QHBoxLayout(w)
    h.setContentsMargins(0, 0, 0, 0)
    lab = QtWidgets.QLabel(label)
    lab.setMinimumWidth(150)
    h.addWidget(lab)
    h.addWidget(widget, 1)
    return w


def _file_picker(parent, line_edit, caption, file_filter="All files (*)", directory=False):
    def pick():
        if directory:
            p = QtWidgets.QFileDialog.getExistingDirectory(parent, caption)
        else:
            p, _ = QtWidgets.QFileDialog.getOpenFileName(parent, caption, "", file_filter)
        if p:
            line_edit.setText(p)
    btn = QtWidgets.QPushButton("Browse…")
    btn.clicked.connect(pick)
    return btn
