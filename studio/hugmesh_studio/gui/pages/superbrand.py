"""SuperbrandStep — "Design your superbrand" (hugmesh-generator#654, decisions D6, D8, D20).

The drop-down (:class:`~.brand_picker.BrandPicker`) on top; under it, while a design is
open, the superbrand's identity (id, title, organisation, public name, internal root
name) and its look, the window's :class:`~._lookeditor.LookEditor` over the session's
look model. The image route's Branding page hosts it, the Fleet window hosts it on its
Superbrand step, and the Docker route's Environment-and-brand step mounts it beside the
picker.

ONE EDITING HOME PER SETTING. The superbrand's identity and its default look are edited
HERE and nowhere else: the Network step's brand rows and the Domain services step's
Identity and Look tabs show them read-only and say so.

WHAT THE RECORD CANNOT HOLD YET is a label under the look (``BrandSession.
not_in_record_sentence``), not a silent omission.

THE UNAFFILIATED RULE (D20). The identity block is DISABLED with the reason shown inline
and the picker says why there is nothing to choose; the look stays (identity refused,
look allowed), with the desktop-logo row switched off through
``LookEditor.set_identity_allowed``.

No modal anywhere. Every refusal is ``note``; slots never raise.
"""
from __future__ import annotations

from ..qt import QtWidgets, Signal
from ...tui.superbrand_step import (BrandSession, IDENTITY_FIELDS, IDENTITY_LABELS,
                                    UNAFFILIATED_REASON)
from ._lookeditor import LookEditor
from ._widgets import _row
from .brand_picker import BrandPicker

__all__ = ["SuperbrandStep"]

#: What a person can click or type in is at least this tall under every style and font
#: (the #647 rule; tests/test_brand_screens_look.py measures it at 8 and 9 pt).
_CLICK_HEIGHT = 26

_PLACEHOLDERS = {
    "id": "a short lowercase name, e.g. acme (empty keeps the shipped one)",
    "title": "the name people see, e.g. Acme Mesh",
    "org": "the organisation's short name",
    "public_name": "the public domain this mesh serves, e.g. mesh.example",
    "internal_root": "empty: <id>.internal",
}


class SuperbrandStep(QtWidgets.QWidget):
    """The picker plus the design step for one route's :class:`BrandSession`."""

    #: emitted after any edit that reached the session (a host may re-load a sibling
    #: control that shows the same values, e.g. the Branding page's legacy theme group)
    changed = Signal()

    def __init__(self, session: BrandSession | None = None, *, route: str = "image",
                 look_in_step: bool = True, with_picker: bool = True, parent=None):
        super().__init__(parent)
        self.route = route
        #: False when the host mounts the look editor itself (the Branding page keeps it
        #: in its existing "Web login theme" section; this step then points there)
        self.look_in_step = look_in_step
        self.session: BrandSession | None = None
        self._loading = False
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(6)

        self.picker = BrandPicker()
        #: a host that shows the drop-down elsewhere (the Fleet window keeps it on its
        #: Shared options step) draws only the design here
        lay.addWidget(self.picker)
        if not with_picker:
            self.picker.hide()

        # ── the design: identity ────────────────────────────────────────────────────
        self.design = QtWidgets.QWidget()
        self.design.setObjectName("superbrand_design")
        dl = QtWidgets.QVBoxLayout(self.design)
        dl.setContentsMargins(0, 0, 0, 0)
        dl.setSpacing(6)
        self.design_title = QtWidgets.QLabel("<b>Design your superbrand</b>")
        dl.addWidget(self.design_title)
        self.identity_box = QtWidgets.QGroupBox("1. Identity")
        il = QtWidgets.QVBoxLayout(self.identity_box)
        self.fields: dict[str, QtWidgets.QLineEdit] = {}
        for f in IDENTITY_FIELDS:
            le = QtWidgets.QLineEdit()
            le.setObjectName(f"superbrand_{f}")
            le.setPlaceholderText(_PLACEHOLDERS[f])
            le.setMinimumHeight(_CLICK_HEIGHT)
            le.editingFinished.connect(lambda f=f, e=le: self._identity_done(f, e.text()))
            self.fields[f] = le
            il.addWidget(_row(IDENTITY_LABELS[f], le))
        self.note = QtWidgets.QLabel("")
        self.note.setObjectName("superbrand_note")
        self.note.setWordWrap(True)
        self.note.setStyleSheet("color: #b00020;")
        self.note.setVisible(False)
        il.addWidget(self.note)
        # the reason an unaffiliated image has no identity (D20): the identity block is
        # HIDDEN there (the picker's own note says the same beside the drop-down), and
        # this label stays in its place so the design says why it has no identity
        self.reason = QtWidgets.QLabel(UNAFFILIATED_REASON)
        self.reason.setObjectName("superbrand_reason")
        self.reason.setWordWrap(True)
        self.reason.setStyleSheet("color: #a65d00;")
        self.reason.setVisible(False)
        dl.addWidget(self.reason)
        dl.addWidget(self.identity_box)

        # keep this design for the next mesh
        keep = QtWidgets.QWidget()
        kh = QtWidgets.QHBoxLayout(keep)
        kh.setContentsMargins(0, 0, 0, 0)
        self.keep_name = QtWidgets.QLineEdit()
        self.keep_name.setObjectName("superbrand_keep_name")
        self.keep_name.setPlaceholderText("a short name, e.g. acme-look")
        self.keep_name.setMinimumHeight(_CLICK_HEIGHT)
        self.keep_btn = QtWidgets.QPushButton("Keep this design")
        self.keep_btn.setObjectName("superbrand_keep")
        self.keep_btn.setMinimumHeight(_CLICK_HEIGHT)
        self.keep_btn.clicked.connect(self._keep)
        kh.addWidget(self.keep_name, 1)
        kh.addWidget(self.keep_btn)
        self.keep_row = _row("Keep it as", keep)
        dl.addWidget(self.keep_row)

        # ── the design: look ────────────────────────────────────────────────────────
        self.look_box = QtWidgets.QGroupBox("2. Look — colours, font, shape, decoration, pictures")
        ll = QtWidgets.QVBoxLayout(self.look_box)
        self.look_editor: LookEditor | None = None
        self._look_layout = ll
        self.look_pointer = QtWidgets.QLabel(
            "<b>2. Look</b> — colours, font, shape, decoration and pictures are set in "
            "the ‘Web login theme’ section below.")
        self.look_pointer.setWordWrap(True)
        self.look_pointer.setObjectName("superbrand_look_pointer")
        self.record_note = QtWidgets.QLabel("")
        self.record_note.setObjectName("superbrand_record_note")
        self.record_note.setWordWrap(True)
        self.record_note.setStyleSheet("color: #a65d00;")
        self.record_note.setVisible(False)
        dl.addWidget(self.look_box if look_in_step else self.look_pointer)
        dl.addWidget(self.record_note)
        lay.addWidget(self.design)

        self.picker.designing_changed.connect(self._designing_changed)
        if session is not None:
            self.set_session(session)

    # ── model ─────────────────────────────────────────────────────────────────────
    def set_session(self, session: BrandSession) -> None:
        self.session = session
        self.picker.set_session(session)
        self.refresh()

    def refresh(self) -> None:
        """Re-read the session into every control. Guarded: nothing here raises."""
        s = self.session
        if s is None:
            return
        self._loading = True
        try:
            self.picker.refresh()
            unaff = s.unaffiliated
            self.design.setVisible(bool(s.designing) or unaff)
            ident = s.identity()
            for f, le in self.fields.items():
                le.setText(ident[f])
                le.setEnabled(not unaff)
            self.identity_box.setVisible(not unaff)
            self.reason.setVisible(unaff)
            self.keep_row.setVisible(not unaff)
            self.design_title.setText(
                "<b>Design your look</b>" if unaff else "<b>Design your superbrand</b>")
            self._mount_look()
            self._refresh_notes()
        finally:
            self._loading = False

    def ensure_look_editor(self) -> LookEditor | None:
        """The look editor, made once. A host that sets ``look_in_step`` False places it
        itself; otherwise it sits in this step's Look group."""
        s = self.session
        if s is None:
            return None
        if self.look_editor is None:
            self.look_editor = LookEditor(s.look, path=self.route)
            self.look_editor.changed.connect(self._look_changed)
            if self.look_in_step:
                self._look_layout.addWidget(self.look_editor)
        return self.look_editor

    def _mount_look(self) -> None:
        s = self.session
        if s is None:
            return
        self.ensure_look_editor()
        if self.look_editor.model is not s.look:
            self.look_editor.set_model(s.look)
        self.look_editor.set_identity_allowed(
            not s.unaffiliated, UNAFFILIATED_REASON if s.unaffiliated else "")

    def _refresh_notes(self) -> None:
        s = self.session
        if s is None:
            return
        sentence = s.not_in_record_sentence()
        self.record_note.setText(sentence)
        self.record_note.setVisible(bool(sentence))

    # ── events ────────────────────────────────────────────────────────────────────
    def _designing_changed(self) -> None:
        try:
            self.refresh()
            self.changed.emit()
        except Exception:                       # noqa: BLE001 — PyQt6 qFatal guard
            self._swallow("_designing_changed")

    def _identity_done(self, field: str, text: str) -> None:
        if self._loading or self.session is None:
            return
        try:
            if text.strip() == (self.session.identity().get(field) or ""):
                return                           # tabbing through is not an edit
            problem = self.session.set_identity(field, text)
            self.note.setText(problem)
            self.note.setVisible(bool(problem))
            if problem:
                self.fields[field].setText(self.session.identity()[field])
            self.changed.emit()
        except Exception:                       # noqa: BLE001
            self._swallow("_identity_done")

    def _look_changed(self) -> None:
        if self._loading:
            return
        try:
            if self.session is not None:
                self.session.touched = True
            self._refresh_notes()
            self.changed.emit()
        except Exception:                       # noqa: BLE001
            self._swallow("_look_changed")

    def _keep(self, *_args) -> None:
        if self.session is None:
            return
        try:
            name = self.keep_name.text().strip()
            problem = self.session.keep_design(name) if name else (
                "give the design a short name first")
            self.note.setText(problem or f"Kept as ‘{name}’; it is in the drop-down "
                                         "the next time the list is opened.")
            self.note.setStyleSheet("color: #b00020;" if problem else "color: gray;")
            self.note.setVisible(True)
        except Exception:                       # noqa: BLE001
            self._swallow("_keep")

    def _swallow(self, where: str) -> None:
        import sys
        import traceback
        print(f"superbrand: swallowed exception in {where}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)

    # ── the host's exit ───────────────────────────────────────────────────────────
    def commit(self, *, save: bool = False) -> list[str]:
        """Write the design back to the route's configuration (and, with ``save``, the
        record file). Returns the problems, which the host shows inline."""
        if self.session is None:
            return []
        problems = self.session.commit(save=save)
        self.note.setStyleSheet("color: #b00020;")
        self.note.setText(problems[0] if problems else "")
        self.note.setVisible(bool(problems))
        return problems
