"""The Themes EDITOR — the decompressed, MODELESS popup for the Themes surface
(#50 item 2: "much more than bootstrap color: header/footer size, existence,
backgrounds, content — in a popup … that decompresses the options crammed into the
existing page").

DESIGN RULES, in order:

* **Modeless, by repo rule.** No ``exec()`` and no ``QMessageBox`` is reachable from
  page logic — a nested event loop hangs headless tests and blocks the wizard.
  :meth:`LoginThemeGroup.open_editor` calls ``show()``; this class never overrides
  that with modality.
* **The group stays the model.** This dialog owns NO state. The colour widgets are
  two-way synced with the in-page group's (Qt setters are no-ops — no signal — when
  the value already matches, so the cross-connections terminate instead of looping),
  and every chrome option writes through :meth:`LoginThemeGroup.set_chrome` into the
  ``chrome`` dict that ``load``/``commit``/``compose_css`` already round-trip.
  Closing the dialog therefore loses nothing, and a host that never opens it commits
  exactly what it loaded.
* **All six background effects are selectable.** The vocabulary
  (``theme.BG_EFFECTS``) is the ``--sd-bg-effect`` contract login-ui PR #6 renders
  (self-hosted three.js + vanta chunks, CSP-clean) and the host shell consumes;
  an unknown or unbundled value degrades to the themed gradient by that contract,
  so no selection here can ever produce a dead page. The picker is a
  :class:`NoWheelComboBox` (PR #72's pattern): a stray hover-scroll must never
  silently flip the mesh's background — the worklist board-combo corruption class.
"""
from __future__ import annotations

from ..qt import QtCore, QtWidgets
from ...core import theme
from ._logintheme import LoginThemeGroup, populate_preset_combo
from ._widgets import NoWheelComboBox, _row

_EFFECT_LABELS = {
    "gradient": "Moving gradient (shipped default — colours follow the theme)",
    "none": "None — flat themed background",
    "vanta-fog": "Vanta fog (animated WebGL)",
    "vanta-waves": "Vanta waves (animated WebGL)",
    "vanta-net": "Vanta net (animated WebGL)",
    "vanta-globe": "Vanta globe (animated WebGL)",
}

_SURFACE_BLURB = {
    "header": "the bar across the top of every themed web page",
    "footer": "the strip along the bottom of every themed web page",
}


class ThemeEditorDialog(QtWidgets.QDialog):
    """The decompressed Themes editor. Construct once per group, reuse via
    :meth:`LoginThemeGroup.open_editor`; edits apply live to the page section."""

    def __init__(self, group: LoginThemeGroup, parent=None):
        super().__init__(parent or group)
        self.group = group
        self.setWindowTitle("Themes editor")
        # Belt & braces for the modeless rule: open_editor() uses show(), and the
        # dialog itself is pinned NonModal so no host can accidentally block on it.
        self.setModal(False)
        self.setWindowModality(QtCore.Qt.WindowModality.NonModal)
        self._chrome_widgets: dict[str, dict[str, QtWidgets.QWidget]] = {}

        outer = QtWidgets.QVBoxLayout(self)
        intro = QtWidgets.QLabel(
            "Everything here edits the SAME theme the page section holds — changes "
            "apply live there (token board, warnings, browser preview) and are saved "
            "with the page, so closing this window loses nothing.")
        intro.setWordWrap(True)
        outer.addWidget(intro)

        outer.addWidget(self._colours_group())
        outer.addWidget(self._chrome_half("header"))
        outer.addWidget(self._chrome_half("footer"))
        outer.addWidget(self._background_group())

        close = QtWidgets.QPushButton("Close")
        close.clicked.connect(self.close)   # plain close — never exec()/accept loops
        btn_row = QtWidgets.QHBoxLayout()
        btn_row.addStretch(1)
        btn_row.addWidget(close)
        outer.addLayout(btn_row)

    # ── colours: the existing bootstrap-colour controls, mirrored ────────────────
    def _colours_group(self) -> QtWidgets.QGroupBox:
        g = self.group
        box = QtWidgets.QGroupBox(
            "Colours — the brand pair every token derives from (including the "
            "Bootstrap --bs-* bridge that restyles buttons/alerts/cards/forms)")
        v = QtWidgets.QVBoxLayout(box)

        self.theme_preset = QtWidgets.QComboBox()
        populate_preset_combo(self.theme_preset)
        self.theme_mode = QtWidgets.QComboBox()
        for i in range(g.theme_mode.count()):
            self.theme_mode.addItem(g.theme_mode.itemText(i), g.theme_mode.itemData(i))
        pw = QtWidgets.QWidget()
        ph = QtWidgets.QHBoxLayout(pw)
        ph.setContentsMargins(0, 0, 0, 0)
        ph.addWidget(self.theme_preset, 1)
        ph.addWidget(self.theme_mode)
        v.addWidget(_row("Theme preset", pw))

        self.primary = QtWidgets.QLineEdit()
        self.secondary = QtWidgets.QLineEdit()
        for le, twin, label in ((self.primary, g.primary, "Primary colour"),
                                (self.secondary, g.secondary, "Secondary colour")):
            le.setPlaceholderText(twin.placeholderText())
            btn = QtWidgets.QPushButton("Pick…")
            btn.clicked.connect(lambda _=False, e=le: g._pick_color(e))
            w = QtWidgets.QWidget()
            h = QtWidgets.QHBoxLayout(w)
            h.setContentsMargins(0, 0, 0, 0)
            h.addWidget(le, 1)
            h.addWidget(btn)
            v.addWidget(_row(label, w))

        # TWO-WAY SYNC with the page group. Termination is structural, not a guard
        # flag: QLineEdit.setText and QComboBox.setCurrentIndex emit NOTHING when the
        # value already matches, so each edit makes exactly one round trip. Combo
        # syncs ride the group's own interplay (_preset_chosen fills the hex fields,
        # which then sync back here; a hand-edited hex flips both combos to Custom).
        self.primary.textChanged.connect(g.primary.setText)
        g.primary.textChanged.connect(self.primary.setText)
        self.secondary.textChanged.connect(g.secondary.setText)
        g.secondary.textChanged.connect(self.secondary.setText)
        self.theme_preset.currentIndexChanged.connect(g.theme_preset.setCurrentIndex)
        g.theme_preset.currentIndexChanged.connect(self.theme_preset.setCurrentIndex)
        self.theme_mode.currentIndexChanged.connect(g.theme_mode.setCurrentIndex)
        g.theme_mode.currentIndexChanged.connect(self.theme_mode.setCurrentIndex)

        note = QtWidgets.QLabel(
            "Fonts, uploads and the browser preview stay on the page section — this "
            "editor adds the web-chrome options below on top of them.")
        note.setWordWrap(True)
        note.setStyleSheet("color: gray;")
        v.addWidget(note)
        return box

    # ── header / footer: existence, size, background, content ────────────────────
    def _chrome_half(self, which: str) -> QtWidgets.QGroupBox:
        g = self.group
        box = QtWidgets.QGroupBox(f"{which.capitalize()} — {_SURFACE_BLURB[which]}")
        v = QtWidgets.QVBoxLayout(box)

        hidden = QtWidgets.QCheckBox(
            f"Hide the {which} entirely (emits --sd-{which}-display: none)")
        hidden.toggled.connect(
            lambda on, k=f"{which}_hidden": g.set_chrome(k, bool(on)))
        v.addWidget(hidden)

        size = QtWidgets.QComboBox()
        size.addItem("Shipped size (no token emitted)", "")
        for name, length in theme.CHROME_SIZES.items():
            size.addItem(f"{name.capitalize()} ({length})", name)
        size.currentIndexChanged.connect(
            lambda _i, c=size, k=f"{which}_size": g.set_chrome(k, c.currentData() or ""))
        v.addWidget(_row("Size", size))

        bg = QtWidgets.QLineEdit()
        bg.setPlaceholderText("#RRGGBB — empty keeps the shipped background")
        bg.setToolTip(
            f"A flat {which} background. Its text twin --sd-{which}-on is derived "
            "automatically (pure black/white by luminance — AA by construction, the "
            "same rule every accent colour gets).")
        pick = QtWidgets.QPushButton("Pick…")
        pick.clicked.connect(lambda _=False, e=bg: g._pick_color(e))
        bg.textChanged.connect(
            lambda t, k=f"{which}_bg": g.set_chrome(k, t.strip()))
        w = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(w)
        h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(bg, 1)
        h.addWidget(pick)
        v.addWidget(_row("Background", w))

        content = QtWidgets.QLineEdit()
        content.setPlaceholderText(
            f"replacement {which} text — empty keeps the shipped content")
        content.setToolTip(
            "Emitted as a CSS string literal; consumers pair it with alt-text syntax "
            "(content: var(..) / '') so screen readers skip decorative text — the "
            "same accessibility rule the nav-decor tokens follow.")
        content.textChanged.connect(
            lambda t, k=f"{which}_text": g.set_chrome(k, t))
        v.addWidget(_row("Content", content))

        self._chrome_widgets[which] = {
            "hidden": hidden, "size": size, "bg": bg, "text": content}
        return box

    # ── background effect (--sd-bg-effect; rendered by login-ui PR #6 + the shell) ──
    def _background_group(self) -> QtWidgets.QGroupBox:
        g = self.group
        box = QtWidgets.QGroupBox("Page background")
        v = QtWidgets.QVBoxLayout(box)
        # NoWheelComboBox, not QComboBox (PR #72): the group this dialog edits lives
        # on scrolling pages, and this picker sits below enough rows that a dialog
        # gaining a scroll area would put it mid-scroll-path — an unfocused wheel
        # must scroll past it, never silently swap the mesh's page background.
        self.bg_effect = NoWheelComboBox()
        for effect in theme.BG_EFFECTS:
            self.bg_effect.addItem(_EFFECT_LABELS.get(effect, effect), effect)
        self.bg_effect.setToolTip(
            "Emitted as --sd-bg-effect (omitted for the default gradient). The vanta "
            "effects animate with the theme's own colours; consumers degrade any "
            "value they cannot render to the themed gradient, and honour "
            "prefers-reduced-motion by never starting an animation.")
        self.bg_effect.currentIndexChanged.connect(
            lambda _i: g.set_chrome(
                "bg_effect", self.bg_effect.currentData() or theme.BG_EFFECT_DEFAULT))
        v.addWidget(_row("Background effect", self.bg_effect))
        note = QtWidgets.QLabel(
            "Vanta effects are animated WebGL (self-hosted three.js — no CDN, "
            "CSP-clean), coloured live from this theme's own tokens. Visitors who "
            "set prefers-reduced-motion never see an animation, and a consumer "
            "that cannot render a value falls back to the themed gradient.")
        note.setWordWrap(True)
        note.setStyleSheet("color: gray;")
        v.addWidget(note)
        return box

    # ── group -> dialog (open + re-load) ──────────────────────────────────────────
    def load_from_group(self) -> None:
        """Pull the current group state into the dialog widgets. Colour widgets use
        their no-op-when-equal setters (no loops); chrome widgets are set with
        signals blocked because the group is the SOURCE here — writing the same
        values back through set_chrome would be redundant refresh churn."""
        g = self.group
        self.primary.setText(g.primary.text())
        self.secondary.setText(g.secondary.text())
        self.theme_preset.setCurrentIndex(g.theme_preset.currentIndex())
        self.theme_mode.setCurrentIndex(g.theme_mode.currentIndex())
        ch = g.chrome
        for which in ("header", "footer"):
            w = self._chrome_widgets[which]
            for widget in w.values():
                widget.blockSignals(True)
            try:
                w["hidden"].setChecked(bool(ch[f"{which}_hidden"]))
                idx = w["size"].findData(ch[f"{which}_size"] or "")
                w["size"].setCurrentIndex(idx if idx >= 0 else 0)
                w["bg"].setText(ch[f"{which}_bg"])
                w["text"].setText(ch[f"{which}_text"])
            finally:
                for widget in w.values():
                    widget.blockSignals(False)
        self.bg_effect.blockSignals(True)
        try:
            idx = self.bg_effect.findData(ch["bg_effect"] or theme.BG_EFFECT_DEFAULT)
            self.bg_effect.setCurrentIndex(idx if idx >= 0 else 0)
        finally:
            self.bg_effect.blockSignals(False)
