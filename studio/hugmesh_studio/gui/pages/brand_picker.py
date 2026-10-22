"""BrandPicker — the superbrand drop-down (hugmesh-generator#654, decision D8).

ONE WIDGET, THREE ROUTES. The image route's Branding page hosts it at its top
(``superbrand.SuperbrandStep``), the Fleet window hosts it on its Superbrand step and in
place of the Shared options step's brand row, and the Docker route's "Environment and
brand" step mounts it where its editable Brand box was (``pages/localmesh.py`` belongs to
the mesh-page lane; this module is what it mounts, and takes the route's
``BrandSession`` — ``tui.superbrand_step.session_for(page, "docker", boot_cfg, dir)`` —
so all three routes drive one model, and the text screen drives the same one).

WHAT IT SHOWS. ``Create a new superbrand`` first (and selected when nothing has been
chosen yet), then this configuration's own superbrand when it has one, the saved designs
and the ``brands/*.conf`` profiles. Choosing an existing one shows a read-only summary
and a ``Change it`` button; choosing Create opens the design (the host shows it when
:attr:`designing_changed` fires). On an unaffiliated image the drop-down is disabled and
the reason is a label beside it, not a hidden control (D20): a control that is missing
cannot say why.

No modal anywhere: every refusal is the ``note`` label. Slots never raise (an exception
escaping a Qt slot aborts PyQt6).
"""
from __future__ import annotations

import html

from ..qt import QtCore, QtWidgets, Signal
from ...core import plain_words
from ...tui.superbrand_step import BrandSession, UNAFFILIATED_REASON
from ._widgets import NoWheelComboBox

__all__ = ["BrandPicker"]


class BrandPicker(QtWidgets.QWidget):
    """The drop-down, the reason line, the read-only summary and the Change-it click."""

    #: emitted after the session's choice or design state changed (the host re-draws
    #: whatever depends on it: the design step, the look editor's model)
    designing_changed = Signal()

    def __init__(self, session: BrandSession | None = None, parent=None):
        super().__init__(parent)
        self.session: BrandSession | None = None
        self._filling = False
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(4)

        top = QtWidgets.QHBoxLayout()
        top.setContentsMargins(0, 0, 0, 0)
        self.caption = QtWidgets.QLabel(plain_words.term("superbrand").capitalize())
        self.combo = NoWheelComboBox()
        self.combo.setObjectName("brand_picker_combo")
        self.combo.setSizeAdjustPolicy(
            QtWidgets.QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
        self.combo.setMinimumContentsLength(18)
        self.combo.setMinimumHeight(26)
        self.combo.setSizePolicy(QtWidgets.QSizePolicy.Policy.Expanding,
                                 QtWidgets.QSizePolicy.Policy.Fixed)
        self.caption.setBuddy(self.combo)
        self.combo.setAccessibleName(plain_words.term("superbrand").capitalize())
        top.addWidget(self.caption)
        top.addWidget(self.combo, 1)
        lay.addLayout(top)

        # the reason on an unaffiliated image, and every refusal: one inline label
        self.note = QtWidgets.QLabel("")
        self.note.setObjectName("brand_picker_note")
        self.note.setWordWrap(True)
        self.note.setStyleSheet("color: #a65d00;")
        self.note.setVisible(False)
        lay.addWidget(self.note)

        # the read-only summary of an existing choice, with its one button
        self.summary = QtWidgets.QLabel("")
        self.summary.setObjectName("brand_picker_summary")
        self.summary.setWordWrap(True)
        self.summary.setTextFormat(QtCore.Qt.TextFormat.RichText)
        self.summary.setTextInteractionFlags(
            QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.summary)
        self.change_btn = QtWidgets.QPushButton("Change it")
        self.change_btn.setObjectName("brand_picker_change")
        self.change_btn.setMinimumHeight(26)
        change_row = QtWidgets.QHBoxLayout()
        change_row.setContentsMargins(0, 0, 0, 0)
        change_row.addWidget(self.change_btn)
        change_row.addStretch(1)
        lay.addLayout(change_row)

        self.combo.currentIndexChanged.connect(self._picked)
        self.change_btn.clicked.connect(self._change)
        if session is not None:
            self.set_session(session)

    # ── model ─────────────────────────────────────────────────────────────────────
    def set_session(self, session: BrandSession) -> None:
        self.session = session
        self.refresh()

    def refresh(self) -> None:
        """Re-read the session: the items, the selection, the summary and the reason."""
        s = self.session
        if s is None:
            return
        self._filling = True
        try:
            self.combo.clear()
            choices = s.choices()
            for c in choices:
                self.combo.addItem(c.label, c.key)
            idx = next((i for i, c in enumerate(choices) if c.key == s.choice), 0)
            if choices:
                self.combo.setCurrentIndex(idx)
        finally:
            self._filling = False
        unaff = s.unaffiliated
        self.combo.setEnabled(not unaff)
        self.note.setStyleSheet("color: #a65d00;")
        self.note.setText(UNAFFILIATED_REASON if unaff else s.message)
        self.note.setVisible(bool(self.note.text()))
        show_summary = (not unaff) and not s.designing
        self.summary.setText(self._summary_html(s) if show_summary else "")
        self.summary.setVisible(show_summary)
        self.change_btn.setVisible(show_summary)

    @staticmethod
    def _summary_html(s: BrandSession) -> str:
        """The read-only summary as a two-column table: a proportional font cannot align
        columns of spaces (looked at: the labels and values drifted)."""
        rows = "".join(
            f"<tr><td style='padding-right:14px'><b>{html.escape(k)}</b></td>"
            f"<td>{html.escape(v)}</td></tr>" for k, v in s.summary_rows())
        return f"<b>{html.escape(s.summary_title())}</b><table cellspacing='2'>{rows}</table>"

    # ── events ────────────────────────────────────────────────────────────────────
    def _picked(self, _index: int) -> None:
        if self._filling or self.session is None:
            return
        try:
            key = self.combo.currentData()
            if key:
                self.session.choose(str(key))
            self.refresh()
            self.designing_changed.emit()
        except Exception:                       # noqa: BLE001 — PyQt6 qFatal guard
            self._swallow("_picked")

    def _change(self, *_args) -> None:
        if self.session is None:
            return
        try:
            self.session.change()
            self.refresh()
            self.designing_changed.emit()
        except Exception:                       # noqa: BLE001
            self._swallow("_change")

    def _swallow(self, where: str) -> None:
        import sys
        import traceback
        print(f"brand_picker: swallowed exception in {where}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        # and said where the person is looking, once (the terminal is for whoever debugs)
        self.note.setStyleSheet("color: #b00020;")
        self.note.setText(
            f"That {plain_words.term('superbrand')} choice could not be applied, and "
            "nothing was changed by it. Pick again; if it comes back, the details are in "
            "the terminal.")
        self.note.setVisible(True)

    # ── reading ───────────────────────────────────────────────────────────────────
    def current_key(self) -> str:
        return str(self.combo.currentData() or "")

    def item_labels(self) -> list[str]:
        return [self.combo.itemText(i) for i in range(self.combo.count())]

    def select(self, key: str) -> None:
        """Choose ``key`` as a click on the drop-down would."""
        i = self.combo.findData(key)
        if i >= 0:
            self.combo.setCurrentIndex(i)
