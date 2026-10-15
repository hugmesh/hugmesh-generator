"""BrandSettingsTabs — the per-brand screen's four tabs (hugmesh-generator#654, D9).

    Identity | Look | Services | Ways to reach it

The Domain services step IS this screen (the page slug and order stay), retitled
"Brand settings". Its three hosts — the image page, the Docker route's step and the Fleet
window — hand each tab its content; this module owns the tabs and what the three tabs
that are not the services table show.

EACH SETTING HAS EXACTLY ONE EDITING HOME (the rule the screen is built on):

* Identity is a read-only mirror of the Domains table, which keeps a brand's public name,
  title, sign-in, images and certificate authority; it says where each is changed.
* Look is edited here: a :class:`~._lookeditor.LookEditor` over the brand's override model
  (every setting says 'inherited from the superbrand' or 'this brand's own'; 'Use the
  superbrand's value' is an inline second click). On every route but the Docker mesh the
  editor draws disabled with the reason (D18). The superbrand's own row shows its look
  read-only: it is edited on the superbrand step.
* Services is the existing services body, unchanged, and the tab the screen opens on.
* Ways to reach it is a read-only summary and ONE button, 'Set up ways to reach this
  brand'; the Go-Live wizard is where a way is chosen (``brand_model.set_ways``).

LAYOUT. This is a tab BAR with the four tabs' content in the body's own layout, not a
QTabWidget: the services body (two checkbox tables, their state line, the honesty banner,
the help and the read-only table) is many widgets that tests and the #647 looks pin to
one parent and one top-to-bottom order, and a QTabWidget would have put them in a page
of its own. Switching to another tab hides those widgets (remembering which of them were
hidden on purpose) and shows that tab's page in the same place; switching back restores
them. A short tab is therefore as tall as its own content, never as tall as the services
table, with no size-hint workaround.

No modal anywhere; slots never raise.
"""
from __future__ import annotations

import html

from ..qt import QtCore, QtWidgets, Signal
from ...core import plain_words
from ...tui import brand_step
from ._lookeditor import LookEditor

__all__ = ["BrandSettingsTabs", "TAB_TITLES"]

TAB_TITLES = tuple(t for _n, t in brand_step.SECTIONS)
(TAB_IDENTITY, TAB_LOOK, TAB_SERVICES, TAB_WAYS) = range(4)
_MUTED = "color: gray;"


def _wrapped(text: str = "", *, name: str = "", muted: bool = False) -> QtWidgets.QLabel:
    lab = QtWidgets.QLabel(text)
    lab.setWordWrap(True)
    lab.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
    if name:
        lab.setObjectName(name)
    if muted:
        lab.setStyleSheet(_MUTED)
    return lab


class BrandSettingsTabs(QtCore.QObject):
    """The four tabs. ``mount(layout)`` puts the tab bar and the three pages in the
    body's layout; ``adopt_services(widgets)`` names the widgets that are the Services
    tab."""

    #: the 'Set up ways to reach this brand' click, with the brand's name
    ways_requested = Signal(str)
    currentChanged = Signal(int)

    def __init__(self, route: str = "image", parent=None):
        super().__init__(parent)
        self.route = route
        self.view: brand_step.BrandView | None = None
        self._active = False
        self._services: list[QtWidgets.QWidget] = []
        self._hidden_on_purpose: dict[QtWidgets.QWidget, bool] = {}
        self._on_services = True

        self.bar = QtWidgets.QTabBar()
        self.bar.setObjectName("brand_tabs")
        self.bar.setExpanding(False)
        self.bar.setDrawBase(True)
        for title in TAB_TITLES:
            self.bar.addTab(title)
        self.bar.setMinimumHeight(28)

        # ── Identity: read-only mirror rows ─────────────────────────────────────────
        self.identity_page = QtWidgets.QWidget()
        self.identity_page.setObjectName("brand_tab_identity")
        il = QtWidgets.QVBoxLayout(self.identity_page)
        il.setContentsMargins(6, 6, 6, 6)
        self.identity_form = QtWidgets.QGridLayout()
        self.identity_form.setColumnStretch(1, 1)
        il.addLayout(self.identity_form)
        self.identity_home = _wrapped("", name="brand_identity_home", muted=True)
        il.addWidget(self.identity_home)
        self._identity_rows: list[QtWidgets.QWidget] = []

        # ── Look: the override editor, or a read-only summary ───────────────────────
        self.look_page = QtWidgets.QWidget()
        self.look_page.setObjectName("brand_tab_look")
        ll = QtWidgets.QVBoxLayout(self.look_page)
        ll.setContentsMargins(6, 6, 6, 6)
        self.look_note = _wrapped("", name="brand_look_note", muted=True)
        ll.addWidget(self.look_note)
        self.look_summary = _wrapped("", name="brand_look_summary")
        ll.addWidget(self.look_summary)
        self.look_editor: LookEditor | None = None
        self._look_layout = ll
        self.look_record_note = _wrapped("", name="brand_look_record_note")
        self.look_record_note.setStyleSheet("color: #a65d00;")
        self.look_record_note.setVisible(False)
        ll.addWidget(self.look_record_note)

        # ── Ways: read-only summary, one button ─────────────────────────────────────
        self.ways_page = QtWidgets.QWidget()
        self.ways_page.setObjectName("brand_tab_ways")
        wl = QtWidgets.QVBoxLayout(self.ways_page)
        wl.setContentsMargins(6, 6, 6, 6)
        self.ways_text = _wrapped("", name="brand_ways_text")
        wl.addWidget(self.ways_text)
        self.ways_btn = QtWidgets.QPushButton(brand_step.WAYS_BUTTON)
        self.ways_btn.setObjectName("brand_ways_button")
        self.ways_btn.setMinimumHeight(28)
        self.ways_btn.clicked.connect(self._ways_clicked)
        row = QtWidgets.QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        row.addWidget(self.ways_btn)
        row.addStretch(1)
        wl.addLayout(row)
        self.ways_note = _wrapped("", name="brand_ways_note", muted=True)
        wl.addWidget(self.ways_note)

        self._pages = {TAB_IDENTITY: self.identity_page, TAB_LOOK: self.look_page,
                       TAB_WAYS: self.ways_page}
        for pg in self._pages.values():
            pg.setVisible(False)
        # the screen opens on Services: the step every older flow walked, unchanged
        self.bar.setCurrentIndex(TAB_SERVICES)
        self.bar.currentChanged.connect(self._switch)

    # ── structure ─────────────────────────────────────────────────────────────────
    def mount(self, layout: QtWidgets.QVBoxLayout) -> None:
        """Put the tab bar and the three pages in ``layout``; the services body follows
        them in the same layout."""
        layout.addWidget(self.bar)
        for pg in self._pages.values():
            layout.addWidget(pg)
        self.bar.setVisible(False)
        for pg in self._pages.values():
            pg.setVisible(False)

    def adopt_services(self, widgets) -> None:
        """The widgets that ARE the Services tab (the body's own, left in the body's
        layout under their own parent)."""
        self._services = [w for w in widgets if w is not None]

    # the QTabWidget-shaped reading API the screens and tests use
    def tabBar(self) -> QtWidgets.QTabBar:      # noqa: N802
        return self.bar

    def count(self) -> int:
        return self.bar.count()

    def tabText(self, i: int) -> str:           # noqa: N802
        return self.bar.tabText(i)

    def currentIndex(self) -> int:              # noqa: N802
        return self.bar.currentIndex()

    def setCurrentIndex(self, i: int) -> None:  # noqa: N802
        self.bar.setCurrentIndex(i)

    def isTabVisible(self, i: int) -> bool:     # noqa: N802
        return self.bar.isTabVisible(i)

    def currentWidget(self):                    # noqa: N802
        """The page on screen: a tab's own page, or None for the Services tab (its
        content is the body itself)."""
        return self._pages.get(self.bar.currentIndex())

    def set_active(self, on: bool) -> None:
        """Show the four tabs (a brand record is on offer) or only the services body,
        exactly as the page was before the tabs existed (a host with no record)."""
        self._active = bool(on)
        self.bar.setVisible(self._active)
        if not self._active:
            self.bar.setCurrentIndex(TAB_SERVICES)
        self._switch(self.bar.currentIndex())

    def _switch(self, index: int) -> None:
        """Show the services body or one of the three pages. Never raises."""
        try:
            want_services = (index == TAB_SERVICES) or not self._active
            if want_services and not self._on_services:
                for w in self._services:
                    w.setHidden(self._hidden_on_purpose.get(w, False))
                self._hidden_on_purpose = {}
            elif not want_services and self._on_services:
                self._hidden_on_purpose = {w: w.isHidden() for w in self._services}
                for w in self._services:
                    w.setHidden(True)
            self._on_services = want_services
            for i, pg in self._pages.items():
                pg.setVisible(self._active and i == index)
            self.currentChanged.emit(index)
        except Exception:                       # noqa: BLE001 — PyQt6 qFatal guard
            import sys
            import traceback
            print("brand_screen: swallowed exception in _switch", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)

    # ── the brand on screen ───────────────────────────────────────────────────────
    def set_view(self, view: "brand_step.BrandView | None") -> None:
        """Show ``view`` (a brand, or the superbrand's own row); None clears the tabs."""
        # leaving a brand: its look edits are already written (the editor commits on
        # each change), but a model swap must not carry another brand's edits over
        self.view = view
        try:
            self._fill_identity()
            self._fill_look()
            self._fill_ways()
        except Exception:                       # noqa: BLE001 — PyQt6 qFatal guard
            import sys
            import traceback
            print("brand_screen: swallowed exception in set_view", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)

    def _clear_identity(self) -> None:
        for w in self._identity_rows:
            self.identity_form.removeWidget(w)
            w.setParent(None)
            w.deleteLater()
        self._identity_rows = []

    def _fill_identity(self) -> None:
        self._clear_identity()
        v = self.view
        if v is None:
            self.identity_home.setText("")
            return
        for r, (k, val) in enumerate(v.identity()):
            key = QtWidgets.QLabel(k)
            key.setMinimumWidth(96)
            key.setStyleSheet("font-weight: bold;")
            value = _wrapped(val, name=f"brand_identity_{r}")
            self.identity_form.addWidget(key, r, 0, QtCore.Qt.AlignmentFlag.AlignTop)
            self.identity_form.addWidget(value, r, 1)
            self._identity_rows += [key, value]
        self.identity_home.setText(v.identity_home())

    def _fill_look(self) -> None:
        v = self.view
        self.look_record_note.setVisible(False)
        if v is None:
            self.look_note.setText("")
            self.look_summary.setText("")
            self.look_summary.setVisible(False)
            if self.look_editor is not None:
                self.look_editor.setVisible(False)
            return
        model = v.look_model()
        if model is None:                       # the superbrand's own row
            self.look_note.setText(brand_step.LOOK_HOME)
            self.look_summary.setText("\n".join(v.look_lines(self.route)[:-2]))
            self.look_summary.setVisible(True)
            if self.look_editor is not None:
                self.look_editor.setVisible(False)
            return
        self.look_note.setText(
            f"Every setting starts from the {plain_words.term('superbrand')}'s. Change one "
            f"to make it this brand's own; ‘Use the {plain_words.term('superbrand')}'s "
            "value’ gives it back.")
        self.look_summary.setVisible(False)
        if self.look_editor is None:
            self.look_editor = LookEditor(model, path=self.route)
            self.look_editor.changed.connect(self._look_changed)
            self._look_layout.insertWidget(self._look_layout.count() - 1, self.look_editor)
        else:
            self.look_editor.set_path(self.route)
            self.look_editor.set_model(model)
        self.look_editor.setVisible(True)
        self._refresh_record_note()

    def _look_changed(self) -> None:
        try:
            if self.view is not None:
                self.view.commit_look()
            self._refresh_record_note()
        except Exception:                       # noqa: BLE001
            import sys
            import traceback
            print("brand_screen: swallowed exception in _look_changed", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)

    def _refresh_record_note(self) -> None:
        v = self.view
        names = v.look_not_in_record() if v is not None else []
        if names:
            self.look_record_note.setText(
                "Not saved in the brand record yet: " + ", ".join(names)
                + ". The record's look holds colours, font, shape, decoration and "
                  "background effect only.")
        self.look_record_note.setVisible(bool(names))

    def _fill_ways(self) -> None:
        v = self.view
        if v is None:
            self.ways_text.setText("")
            self.ways_btn.setVisible(False)
            self.ways_note.setText("")
            return
        lines = []
        last = ""
        for way, value, path, effect in v.ways():
            if way != last:
                lines.append(f"<b>{html.escape(way)}:</b> {html.escape(value)}")
                last = way
            lines.append(f"&nbsp;&nbsp;&nbsp;{html.escape(path)}: {html.escape(effect)}")
        self.ways_text.setTextFormat(QtCore.Qt.TextFormat.RichText)
        self.ways_text.setText("<br>".join(lines))
        self.ways_btn.setVisible(True)
        self.ways_note.setText(brand_step.WAYS_HOME)

    def _ways_clicked(self, *_args) -> None:
        try:
            if self.view is not None:
                self.ways_requested.emit(self.view.name)
        except Exception:                       # noqa: BLE001
            pass

    # ── reading (tests and hosts) ─────────────────────────────────────────────────
    def current_title(self) -> str:
        return self.tabText(self.currentIndex())

    def open_tab(self, title: str) -> None:
        for i in range(self.count()):
            if self.tabText(i) == title:
                self.setCurrentIndex(i)
                return
        raise KeyError(title)
