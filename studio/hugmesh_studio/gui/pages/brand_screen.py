"""BrandSettingsTabs — the per-brand screen's four tabs (hugmesh-generator#654, D9).

    Identity | Look | Services | Ways to reach it

The Domain services step IS this screen (the page slug and order stay), retitled
"Brand settings". Its three hosts — the image page, the Docker route's step and the Fleet
window — hand each tab its content; this module owns the tabs and what the three tabs
that are not the services table show.

EACH SETTING HAS EXACTLY ONE EDITING HOME (the rule the screen is built on):

* Identity mirrors the Domains table (public name, title, images, certificate
  authority — changed there) and EDITS the domain's sign-in (2026-10-21, the operator:
  "Make sure the identity provider step is also added per domain"): through the mesh's
  sign-in (inherited), its own Casdoor, or its own Azure Entra ID / AWS Cognito / OIDC
  provider with a sign-in address, client id and key address, written by
  ``config.set_domain_signin`` (the one writer) with every refusal inline. The mesh's
  own row (row 0) EDITS the mesh's sign-in, which is the default every domain inherits:
  through ``superbrand_step.MeshWrites``, into the one place the route keeps it (the
  Identity provider step's fields, or the Docker page's controls), so the step and
  row 0 are two doors on one value; a route that keeps none says so (2026-10-21).
* Look is edited here: a :class:`~._lookeditor.LookEditor` over the brand's override model
  (every setting says 'inherited from the superbrand' or 'this brand's own'; 'Use the
  superbrand's value' is an inline second click). On every route but the Docker mesh the
  editor draws disabled with the reason (D18). The mesh's own row (row 0) edits the
  superbrand's look itself, in design mode, on every route: this tab is the ONE place a
  theme is chosen (2026-10-21; the old mesh-wide theme panels are gone).
* Services is the existing services body, unchanged, and the tab the screen opens on.
* Ways to reach it EDITS the domain's Tor address (its own onion — the same choice as
  the Services tab's front door, kept in step with it), its VPN membership and its
  egress (inherit / on / off; inherit / an egress VPN with an optional provider file /
  direct), through ``brand_model.set_ways``, and says what each route does with them.
  Row 0's Tor and egress are the MESH's and are edited in place the same way as its
  sign-in (``MeshWrites``); its VPN is shown, never chosen (the mesh's whole posture).
  The internal and public names stay with the Go-Live wizard.
* A Mesh desktop CLIENT image (cloud mode) gets the same tabs, each with one line
  saying the client keeps the choice with its configuration only
  (``brand_step.CLIENT_*_NOTE``).

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
from ...core import domain_reach, plain_words
from ...tui import brand_step
from ._lookeditor import LookEditor
from ._widgets import collapsible

__all__ = ["BrandSettingsTabs", "TAB_TITLES"]

TAB_TITLES = tuple(t for _n, t in brand_step.SECTIONS)
(TAB_IDENTITY, TAB_LOOK, TAB_SERVICES, TAB_WAYS) = range(4)
_MUTED = "color: gray;"
#: the provider-file box's hint: a brand may fall back on the mesh's file; row 0 IS it
_BRAND_CONF_HINT = "/absolute/path/provider.conf — empty: the mesh's own provider file"
_OWN_CONF_HINT = "/absolute/path/provider.conf (a WireGuard .conf or an OpenVPN .ovpn)"


def own_look_note() -> str:
    """The Look tab's line on the mesh's own row (brand_step.LOOK_HOME as a sentence)."""
    home = brand_step.LOOK_HOME
    return home[:1].upper() + home[1:] + "."


def _wrapped(text: str = "", *, name: str = "", muted: bool = False) -> QtWidgets.QLabel:
    lab = QtWidgets.QLabel(text)
    lab.setWordWrap(True)
    lab.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
    if name:
        lab.setObjectName(name)
    if muted:
        lab.setStyleSheet(_MUTED)
    return lab


def _set_items(combo: QtWidgets.QComboBox, choices) -> None:
    """Give ``combo`` exactly ``choices`` ((key, label) pairs), keeping it untouched
    when it already holds them (row 0 and a brand offer different lists)."""
    want = [(k, lab) for k, lab in choices]
    have = [(combo.itemData(i), combo.itemText(i)) for i in range(combo.count())]
    if have == want:
        return
    blocked = combo.blockSignals(True)
    try:
        combo.clear()
        for k, lab in want:
            combo.addItem(lab, k)
    finally:
        combo.blockSignals(blocked)


class BrandSettingsTabs(QtCore.QObject):
    """The four tabs. ``mount(layout)`` puts the tab bar and the three pages in the
    body's layout; ``adopt_services(widgets)`` names the widgets that are the Services
    tab."""

    #: the 'Set up ways to reach this brand' click, with the brand's name
    ways_requested = Signal(str)
    currentChanged = Signal(int)
    #: a look edit was written (the host refreshes what reads the look: the plan)
    look_changed = Signal()
    #: the domain's sign-in or reach was written (the host refreshes its mirrors)
    row_changed = Signal()
    #: the Ways tab's Tor tick was clicked: the host's front door owns the working
    #: value (the Services tab's row), so it applies it and calls show_tor back
    tor_changed = Signal(bool)

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
        self._loading = False
        # ── the domain's sign-in: the per-domain identity provider ──────────────────
        self.signin_box = QtWidgets.QGroupBox("How this domain's people sign in")
        self.signin_box.setObjectName("brand_signin_box")
        sl = QtWidgets.QVBoxLayout(self.signin_box)
        self.signin_now = _wrapped("", name="brand_signin_now")
        sl.addWidget(self.signin_now)
        self.signin_choice = QtWidgets.QComboBox()
        self.signin_choice.setObjectName("brand_signin_choice")
        for key, label in brand_step.SIGNIN_CHOICES:
            self.signin_choice.addItem(label, key)
        self.signin_choice.setMinimumHeight(26)
        self.signin_choice.activated.connect(self._signin_choice_clicked)
        sl.addWidget(self.signin_choice)
        self.signin_fields = QtWidgets.QWidget()
        self.signin_fields.setObjectName("brand_signin_fields")
        sf = QtWidgets.QFormLayout(self.signin_fields)
        sf.setContentsMargins(0, 0, 0, 0)
        self.signin_issuer = QtWidgets.QLineEdit()
        self.signin_issuer.setObjectName("brand_signin_address")
        self.signin_issuer.setPlaceholderText("https://… (the provider's sign-in address)")
        self.signin_client = QtWidgets.QLineEdit()
        self.signin_client.setObjectName("brand_signin_client")
        self.signin_client.setPlaceholderText("the provider's client id (public, never a secret)")
        self.signin_keys = QtWidgets.QLineEdit()
        self.signin_keys.setObjectName("brand_signin_keys")
        self.signin_keys.setPlaceholderText("empty: derived from the sign-in address")
        sf.addRow("Sign-in address", self.signin_issuer)
        sf.addRow("Client id", self.signin_client)
        sf.addRow("Key address", self.signin_keys)
        sl.addWidget(self.signin_fields)
        self.signin_apply = QtWidgets.QPushButton("Use this sign-in")
        self.signin_apply.setObjectName("brand_signin_apply")
        self.signin_apply.setMinimumHeight(28)
        self.signin_apply.clicked.connect(self._signin_apply_clicked)
        row_apply = QtWidgets.QHBoxLayout()
        row_apply.setContentsMargins(0, 0, 0, 0)
        row_apply.addWidget(self.signin_apply)
        row_apply.addStretch(1)
        sl.addLayout(row_apply)
        self.signin_note = _wrapped("", name="brand_signin_note")
        sl.addWidget(self.signin_note)
        il.addWidget(self.signin_box)

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
        # ── Tor, VPN and egress: chosen here, per domain ────────────────────────────
        self.reach_box = QtWidgets.QGroupBox("Tor, VPN and egress for this domain")
        self.reach_box.setObjectName("brand_reach_box")
        rl = QtWidgets.QFormLayout(self.reach_box)
        self.tor_box = QtWidgets.QCheckBox("Its own Tor address (an onion of its own)")
        self.tor_box.setObjectName("brand_ways_tor")
        self.tor_box.clicked.connect(self._tor_clicked)
        rl.addRow("Tor", self.tor_box)
        self.tailnet_combo = QtWidgets.QComboBox()
        self.tailnet_combo.setObjectName("brand_ways_vpn")
        for key, label in brand_step.TAILNET_CHOICES:
            self.tailnet_combo.addItem(label, key)
        self.tailnet_combo.setMinimumHeight(26)
        self.tailnet_combo.activated.connect(self._tailnet_clicked)
        rl.addRow("VPN", self.tailnet_combo)
        self.egress_combo = QtWidgets.QComboBox()
        self.egress_combo.setObjectName("brand_ways_egress")
        for key, label in brand_step.EGRESS_CHOICES:
            self.egress_combo.addItem(label, key)
        self.egress_combo.setMinimumHeight(26)
        self.egress_combo.activated.connect(self._egress_clicked)
        rl.addRow("Egress", self.egress_combo)
        conf_row = QtWidgets.QWidget()
        cr = QtWidgets.QHBoxLayout(conf_row)
        cr.setContentsMargins(0, 0, 0, 0)
        self.egress_conf = QtWidgets.QLineEdit()
        self.egress_conf.setObjectName("brand_ways_egress_conf")
        # typed, never a file dialog (no modal on this screen): an absolute path to a
        # WireGuard .conf or OpenVPN .ovpn, checked as a real file when the mesh starts
        self.egress_conf.setPlaceholderText(_BRAND_CONF_HINT)
        self.egress_conf.editingFinished.connect(self._egress_conf_done)
        cr.addWidget(self.egress_conf, 1)
        self.egress_conf_row = conf_row
        rl.addRow("Provider file", conf_row)
        self.reach_words = _wrapped("", name="brand_reach_words")
        rl.addRow(self.reach_words)
        self.reach_note = _wrapped("", name="brand_reach_note")
        rl.addRow(self.reach_note)
        wl.addWidget(self.reach_box)
        self.ways_text = _wrapped("", name="brand_ways_text")
        # The per-path table (every way on every start path) is long: folded by default
        # so the tab stays as tall as its controls; one click shows it.
        self.ways_more = collapsible("What each start path does with these ways",
                                     self.ways_text, expanded=False)
        self.ways_more.setObjectName("brand_ways_more")
        wl.addWidget(self.ways_more)
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

        # ── a Mesh desktop CLIENT image (cloud mode): one honest line on top of each
        # of the three pages — what that route does with the tab's choices (nothing
        # but keep them; brand_step.CLIENT_*_NOTE, the text screen prints the same)
        self.client_notes: dict[int, QtWidgets.QLabel] = {}
        for tab, page, text, name in (
                (TAB_IDENTITY, self.identity_page, brand_step.CLIENT_SIGNIN_NOTE,
                 "brand_client_identity"),
                (TAB_LOOK, self.look_page, brand_step.CLIENT_LOOK_NOTE,
                 "brand_client_look"),
                (TAB_WAYS, self.ways_page, brand_step.CLIENT_WAYS_NOTE,
                 "brand_client_ways")):
            note = _wrapped(text, name=name)
            note.setStyleSheet("color: #a65d00;")
            note.setVisible(False)
            page.layout().insertWidget(0, note)
            self.client_notes[tab] = note

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
            client = bool(view is not None and view.client_image())
            for note in self.client_notes.values():
                note.setVisible(client)
            self._fill_identity()
            self._fill_signin()
            self._fill_look()
            self._fill_ways()
            self._fill_reach()
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
        if model is None:
            self.look_note.setText("")
            self.look_summary.setVisible(False)
            if self.look_editor is not None:
                self.look_editor.setVisible(False)
            return
        if v.own:
            # the mesh's own row: the superbrand's look itself, in design mode
            self.look_note.setText(own_look_note())
        else:
            self.look_note.setText(
                f"Every setting starts from the {plain_words.term('superbrand')}'s. Change "
                f"one to make it this brand's own; ‘Use the "
                f"{plain_words.term('superbrand')}'s value’ gives it back.")
        self.look_summary.setVisible(False)
        if self.look_editor is None:
            self.look_editor = LookEditor(
                model, path=self.route,
                generator_dir=getattr(getattr(v.session, "host", None), "generator_dir",
                                      "") or "")
            # the editor scrolls inside itself: give it room for the colours and the
            # font at once, or the tab shows a 300 px slot over blank space (looked at)
            self.look_editor.setMinimumHeight(520)
            self.look_editor.changed.connect(self._look_changed)
            self._look_layout.insertWidget(self._look_layout.count() - 1, self.look_editor)
        else:
            self.look_editor.set_path(self.route)
            self.look_editor.set_model(model)
        # an unaffiliated image keeps its look and loses the desktop logo (D20): the
        # session wires that onto its own look model, and the editor draws it
        self.look_editor.set_identity_allowed(
            getattr(model, "identity_allowed", True), getattr(model, "identity_reason", ""))
        self.look_editor.setVisible(True)
        self._refresh_record_note()

    def _look_changed(self) -> None:
        try:
            if self.view is not None:
                self.view.commit_look()
            self._refresh_record_note()
            self.look_changed.emit()
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
        # A client image serves no domain: the Go-Live wizard (internal and public
        # names) is a mesh device's, so the button and its pointer are not offered.
        client = v.client_image()
        self.ways_btn.setVisible(not client)
        self.ways_note.setText("" if client else brand_step.WAYS_HOME)

    # ── the domain's sign-in ──────────────────────────────────────────────────────
    def _fill_signin(self, note: str = "", error: bool = False) -> None:
        v = self.view
        self._loading = True
        try:
            if v is None:
                self.signin_box.setVisible(False)
                return
            self.signin_box.setVisible(True)
            self.signin_now.setText("Now: " + v.signin_words())
            own = v.own
            # row 0 offers the MESH's own provider (it IS the mesh); a brand offers its
            # own sign-in or the mesh's
            _set_items(self.signin_choice, v.signin_choices())
            why = v.signin_refusal()
            self.signin_choice.setVisible(not why)
            if why:
                # a route that keeps no mesh-wide sign-in: say so, offer nothing
                self.signin_fields.setVisible(False)
                self.signin_apply.setVisible(False)
                self.signin_note.setStyleSheet(_MUTED)
                self.signin_note.setText(
                    brand_step.SIGNIN_MESH_HOME[:1].upper()
                    + brand_step.SIGNIN_MESH_HOME[1:] + ". " + why + ".")
                return
            choice = v.signin_choice()
            self.signin_choice.setCurrentIndex(max(0, self.signin_choice.findData(choice)))
            vals = v.signin_values()
            self.signin_issuer.setText(vals["issuer"])
            self.signin_client.setText(vals["client_id"])
            self.signin_keys.setText(vals["jwks"])
            self._show_signin_fields()
            self.signin_note.setStyleSheet("color: #b00020;" if error else _MUTED)
            if not note and own:
                note = (brand_step.SIGNIN_MESH_EDIT[:1].upper()
                        + brand_step.SIGNIN_MESH_EDIT[1:] + ".")
            self.signin_note.setText(note)
        finally:
            self._loading = False

    def _show_signin_fields(self) -> None:
        ext = self.signin_choice.currentData() in brand_step.SIGNIN_EXTERNAL
        self.signin_fields.setVisible(ext)
        self.signin_apply.setVisible(ext)

    def _signin_choice_clicked(self, *_args) -> None:
        """A person picked a sign-in. Through the mesh and its own Casdoor need nothing
        more and are written at once; an external provider waits for its values and
        the ‘Use this sign-in’ click. Never raises."""
        try:
            if self._loading or self.view is None:
                return
            self._show_signin_fields()
            choice = self.signin_choice.currentData()
            if choice in brand_step.SIGNIN_EXTERNAL:
                self.signin_note.setStyleSheet(_MUTED)
                self.signin_note.setText(
                    "Fill in the sign-in address and the client id, then press "
                    "‘Use this sign-in’. Nothing has changed yet.")
                return
            self._apply_signin(choice)
        except Exception:                       # noqa: BLE001
            self._swallow("_signin_choice_clicked")

    def _signin_apply_clicked(self, *_args) -> None:
        try:
            if self.view is not None:
                self._apply_signin(self.signin_choice.currentData())
        except Exception:                       # noqa: BLE001
            self._swallow("_signin_apply_clicked")

    def _apply_signin(self, choice: str) -> None:
        v = self.view
        problems = v.set_signin(choice, self.signin_issuer.text(),
                                self.signin_client.text(), self.signin_keys.text())
        if problems:
            # nothing was written: the row keeps what it had, the controls keep what
            # was typed so it can be fixed, and the sentence says why
            self.signin_note.setStyleSheet("color: #b00020;")
            self.signin_note.setText("Not changed: " + problems[0])
            return
        self._fill_identity()
        self._fill_signin("Saved: " + v.signin_words())
        self.row_changed.emit()

    # ── Tor, VPN and egress ───────────────────────────────────────────────────────
    def _fill_reach(self, note: str = "", error: bool = False) -> None:
        v = self.view
        self._loading = True
        try:
            if v is None:
                self.reach_box.setVisible(False)
                return
            self.reach_box.setVisible(True)
            own = v.own
            words = v.reach_lines()
            self.reach_words.setText(
                f"VPN: {words.get(domain_reach.WAY_TAILNET, '')}\n"
                f"Egress: {words.get(domain_reach.WAY_EGRESS, '')}")
            if own:
                self._fill_own_reach(v, note, error)
                return
            _set_items(self.tailnet_combo, brand_step.TAILNET_CHOICES)
            _set_items(self.egress_combo, brand_step.EGRESS_CHOICES)
            for w in (self.tailnet_combo, self.egress_combo, self.egress_conf):
                w.setEnabled(True)
            self.tailnet_combo.setToolTip("")
            self.egress_conf.setPlaceholderText(_BRAND_CONF_HINT)
            self.tor_box.setEnabled(True)
            self.tor_box.setVisible(True)
            self.tor_box.setText("Its own Tor address (an onion of its own)")
            self.tor_box.setChecked(v.tor_on())
            self.tailnet_combo.setCurrentIndex(
                max(0, self.tailnet_combo.findData(v.tailnet_choice())))
            mode, conf = v.egress_choice()
            self.egress_combo.setCurrentIndex(max(0, self.egress_combo.findData(mode)))
            self.egress_conf.setText(conf)
            self.egress_conf_row.setEnabled(mode == domain_reach.EGRESS_VPN)
            self.reach_note.setStyleSheet("color: #b00020;" if error else _MUTED)
            # what THIS route's start does with the choice (core/reach_apply):
            # applied, or why not — never a blanket 'recorded'
            self.reach_note.setText(note or v.reach_effect())
        finally:
            self._loading = False

    def _fill_own_reach(self, v, note: str, error: bool) -> None:
        """Row 0: the MESH's own Tor and egress, edited in place where the route keeps
        them (``MeshWrites``); its VPN is shown, never chosen here (the mesh's whole
        posture). A way this route keeps nowhere is greyed with the reason — and a Tor
        box that cannot be set is not drawn at all, because an unticked grey box read as
        "off" even with the mesh's Tor on (domain-ui skeptic 3)."""
        tor_why = v.own_way_refusal("tor")
        egress_why = v.own_way_refusal("egress")
        self.tor_box.setText("The mesh's own Tor address (its onion)")
        self.tor_box.setVisible(not tor_why)
        self.tor_box.setEnabled(not tor_why)
        self.tor_box.setChecked(bool(v.tor_on()) and not tor_why)
        own_tail = tuple(c for c in brand_step.TAILNET_CHOICES
                         if c[0] != domain_reach.REACH_INHERIT)
        _set_items(self.tailnet_combo, own_tail)
        self.tailnet_combo.setCurrentIndex(
            max(0, self.tailnet_combo.findData(v.tailnet_choice())))
        self.tailnet_combo.setEnabled(False)
        self.tailnet_combo.setToolTip(v.own_way_refusal("tailnet"))
        own_egress = tuple(c for c in brand_step.EGRESS_CHOICES
                           if c[0] != domain_reach.REACH_INHERIT)
        _set_items(self.egress_combo, own_egress)
        mode, conf = v.egress_choice()
        self.egress_combo.setCurrentIndex(max(0, self.egress_combo.findData(mode)))
        self.egress_combo.setEnabled(not egress_why)
        self.egress_conf.setEnabled(not egress_why)
        self.egress_conf.setPlaceholderText(_OWN_CONF_HINT)
        self.egress_conf.setText(conf)
        self.egress_conf_row.setEnabled(not egress_why and mode == domain_reach.EGRESS_VPN)
        lines = [note] if note else [brand_step.OWN_REACH_EDIT[:1].upper()
                                     + brand_step.OWN_REACH_EDIT[1:] + "."]
        lines.append(v.own_way_refusal("tailnet") + ".")
        for why in (tor_why, egress_why):
            if why:
                lines.append(why + ".")
        self.reach_note.setStyleSheet("color: #b00020;" if error else _MUTED)
        self.reach_note.setText(" ".join(lines))

    def show_tor(self, available: bool, on: bool) -> None:
        """The host's front door says what the domain's Tor choice is now."""
        self._loading = True
        try:
            if self.view is not None and not self.view.own:
                self.tor_box.setEnabled(bool(available))
                self.tor_box.setChecked(bool(on))
        finally:
            self._loading = False

    def _reach_done(self, problems: list[str]) -> None:
        if problems:
            self._fill_reach("Not changed: " + problems[0], error=True)
            return
        self._fill_reach()
        self._fill_ways()
        self.row_changed.emit()

    def _tor_clicked(self, checked: bool) -> None:
        try:
            if self._loading or self.view is None:
                return
            if self.view.own:
                # row 0's onion IS the mesh's Tor: written where the mesh keeps it
                self._reach_done(self.view.set_tor(bool(checked)))
                return
            self.tor_changed.emit(bool(checked))
            self._fill_ways()
        except Exception:                       # noqa: BLE001
            self._swallow("_tor_clicked")

    def _tailnet_clicked(self, *_args) -> None:
        try:
            if self._loading or self.view is None:
                return
            self._reach_done(self.view.set_tailnet(self.tailnet_combo.currentData()))
        except Exception:                       # noqa: BLE001
            self._swallow("_tailnet_clicked")

    def _egress_clicked(self, *_args) -> None:
        try:
            if self._loading or self.view is None:
                return
            mode = self.egress_combo.currentData()
            self.egress_conf_row.setEnabled(mode == domain_reach.EGRESS_VPN)
            if (self.view.own and mode == domain_reach.EGRESS_VPN
                    and not self.egress_conf.text().strip()):
                # the mesh's egress VPN needs its file before anything is written:
                # leave the choice on screen and ask for the path, inline
                self.reach_note.setStyleSheet(_MUTED)
                self.reach_note.setText(
                    "Type the provider file's absolute path and press Enter. Nothing "
                    "has changed yet.")
                return
            self._reach_done(self.view.set_egress(
                mode, self.egress_conf.text() if mode == domain_reach.EGRESS_VPN else ""))
        except Exception:                       # noqa: BLE001
            self._swallow("_egress_clicked")

    def _egress_conf_done(self) -> None:
        try:
            if (self._loading or self.view is None
                    or self.egress_combo.currentData() != domain_reach.EGRESS_VPN):
                return
            if self.egress_conf.text().strip() == self.view.egress_choice()[1]:
                return                           # tabbing through is not an edit
            self._reach_done(self.view.set_egress(domain_reach.EGRESS_VPN,
                                                  self.egress_conf.text()))
        except Exception:                       # noqa: BLE001
            self._swallow("_egress_conf_done")

    @staticmethod
    def _swallow(where: str) -> None:
        import sys
        import traceback
        print(f"brand_screen: swallowed exception in {where}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)

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
