"""The LookEditor — one widget that designs the superbrand's look and overrides a
brand's, field by field (hugmesh-generator#654, decisions D6, D7 and D19).

TWO MODES, ONE WIDGET. In DESIGN mode (the superbrand) every setting is the
superbrand's own. In OVERRIDE mode (a brand) every row also says where its value comes
from — "inherited from the superbrand" or "this brand's own" — and carries 'Use the
superbrand's value', which ARMS on the first click and applies on the second. No pop-up
anywhere: every refusal (a picture that is not a PNG or JPEG, a picture past the budget,
a malformed colour) is a sentence in a label beside the control, and the record is left
as it was.

THE MODEL IS :class:`hugmesh_studio.core.brand_look.Look`. The widget owns no look of
its own: every control writes through ``model.set`` and reads back through
``model.effective()``, so the text screen (tui/themes.py) editing the same model object
sees the same values, and the two faces write the same record (J-DESIGN proves it).

WHAT THE PREVIEW IS. The token board shows the derived hexes and the MEASURED contrast
ratios straight from core/theme.py (the values that ship, by construction); the
contrast line says in one sentence whether text, accent text and button text clear AA.
'Preview in your browser' writes ONE themed page (the captured real login page plus
representative panes) from ``model.css()`` — the delivered bytes — and opens it in the
operator's real browser (see _look_shared.open_platform_preview for the honesty rules).

THE METER. The web look may spend 100 KiB of finished stylesheet; the two pictures are
what spend it. The meter is brand_look.budget() measured on the real composition, and a
picture that would not fit is refused with the numbers (used, free, what it would cost,
how big a file would fit).

WHERE AN OVERRIDE CAN SHOW. A brand's own look is served on the Docker mesh only (D18).
In override mode on any other path every edit control is drawn DISABLED with the
sentence that says why, never hidden: a control that is missing cannot say why.

Slots never raise (an exception escaping a Qt slot aborts PyQt6): every write is guarded
and lands in error_note instead.
"""
from __future__ import annotations

import os

from ..qt import QtCore, QtGui, QtWidgets, Signal
from ...core import (brand_images, brand_look, fonts as core_fonts, plain_words, theme,
                     theme_presets)
from ...core.branding_themes import PREMADE_THEMES, THEME_SPECS
from ._look_shared import open_platform_preview, populate_preset_combo
from ._scroll import scrollable
from ._widgets import NoWheelComboBox, _file_picker, _row

__all__ = ["LookEditor", "ElidedLabel", "EFFECT_LABELS", "STYLE_LABELS", "DECOR_LABELS"]

#: the same sentences as the text screen, from the one definition in core
INHERITED_TEXT = brand_look.INHERITED_TEXT
OWN_TEXT = brand_look.OWN_TEXT
USE_SUPERBRAND = brand_look.USE_SUPERBRAND
USE_SUPERBRAND_ARMED = brand_look.USE_SUPERBRAND_ARMED
DOCKER_ONLY_SENTENCE = brand_look.DOCKER_ONLY_SENTENCE
VANTA_UNSELECTABLE = brand_look.VANTA_UNSELECTABLE

EFFECT_LABELS = brand_look.EFFECT_LABELS
STYLE_LABELS = brand_look.STYLE_LABELS
DECOR_LABELS = brand_look.DECOR_LABELS
_HEX_PLACEHOLDER_DESIGN = "#RRGGBB — empty keeps the shipped colour"
_HEX_PLACEHOLDER_BRAND = "#RRGGBB — empty keeps the superbrand's or the shipped colour"
_KEEP_FONT = "(keep the shipped font — Arial)"
_THUMB_BOX = (200, 72)                     # the picture as the page will show it, small
_PICTURE_FILTER = "Pictures (*.png *.jpg *.jpeg)"
_IMAGE_FILTER = "Images (*.png *.jpg *.jpeg *.webp *.svg)"


class ElidedLabel(QtWidgets.QLabel):
    """A one-line label that elides its text in the middle instead of widening the
    page. A plain QLabel's minimumSizeHint is the whole text, so a long font family or
    file name pushes every control past the viewport (#661); this one asks for very
    little and draws what fits, with the full text as its tooltip."""

    def __init__(self, text: str = "", parent=None):
        super().__init__(parent)
        self._full = ""
        self.setSizePolicy(QtWidgets.QSizePolicy.Policy.Ignored,
                           QtWidgets.QSizePolicy.Policy.Preferred)
        self.set_full_text(text)

    def set_full_text(self, text: str) -> None:
        self._full = text or ""
        self.setToolTip(self._full)
        self._relayout()

    def full_text(self) -> str:
        return self._full

    def minimumSizeHint(self):  # noqa: N802 (Qt override)
        h = super().minimumSizeHint().height()
        return QtCore.QSize(24, h)

    def resizeEvent(self, ev):  # noqa: N802 (Qt override)
        super().resizeEvent(ev)
        self._relayout()

    def _relayout(self) -> None:
        width = max(24, self.width() - 4)
        super().setText(self.fontMetrics().elidedText(
            self._full, QtCore.Qt.TextElideMode.ElideMiddle, width))


class LookEditor(QtWidgets.QWidget):
    """See the module docstring. ``model`` is a brand_look.Look (design or override
    mode); ``path`` names the start path the host is on ("docker", "kind", "image",
    ...) so override controls can say where they would show."""

    changed = Signal()

    def __init__(self, model: brand_look.Look, *, path: str = "docker", parent=None):
        super().__init__(parent)
        self.model = model
        self.path = path
        self.controls: dict[str, QtWidgets.QWidget] = {}
        self.source_labels: dict[str, QtWidgets.QLabel] = {}
        self.use_buttons: dict[str, QtWidgets.QPushButton] = {}
        self.picture_notes: dict[str, ElidedLabel] = {}
        self.picture_paths: dict[str, QtWidgets.QLineEdit] = {}
        self.picture_thumbs: dict[str, QtWidgets.QLabel] = {}
        self._loading = False
        self._font_qt_family = ""
        self._error = ""

        lay = scrollable(self)
        # The refusal sentence lives ABOVE the scroll area, not in the page: a person who
        # typed a bad colour halfway down the page must still see why nothing changed.
        self.error_note = QtWidgets.QLabel()
        self.error_note.setObjectName("look_error")
        self.error_note.setWordWrap(True)
        self.error_note.setStyleSheet("color: #b00020; padding: 2px 4px;")
        self.error_note.setVisible(False)
        self.layout().insertWidget(0, self.error_note)
        self.mode_note = QtWidgets.QLabel()
        self.mode_note.setWordWrap(True)
        lay.addWidget(self.mode_note)
        self.path_note = QtWidgets.QLabel(DOCKER_ONLY_SENTENCE)
        self.path_note.setWordWrap(True)
        self.path_note.setStyleSheet("color: #a65d00;")
        self.path_note.setVisible(False)
        lay.addWidget(self.path_note)

        lay.addWidget(self._colours_group())
        lay.addWidget(self._font_group())
        lay.addWidget(self._shape_group())
        lay.addWidget(self._chrome_group("header"))
        lay.addWidget(self._chrome_group("footer"))
        lay.addWidget(self._background_group())
        lay.addWidget(self._pictures_group())
        lay.addWidget(self._desktop_group())
        lay.addWidget(self._preview_group())
        lay.addStretch(1)

        self.load_from_model()
        self.set_path(path)

    # ── building the rows ──────────────────────────────────────────────────────────
    def _field_row(self, field: str, label: str, control: QtWidgets.QWidget,
                   extra: list[QtWidgets.QWidget] | None = None) -> QtWidgets.QWidget:
        """One row: label, the control (and any buttons beside it), then in override
        mode the source label and the 'Use the superbrand's value' button. The control
        is registered under its look field so the parity pin can read it."""
        control.setObjectName(f"look_{field}")
        self.controls[field] = control
        inner = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(inner)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(2)
        first = QtWidgets.QHBoxLayout()
        first.setContentsMargins(0, 0, 0, 0)
        first.addWidget(control, 1)
        for w in extra or []:
            first.addWidget(w)
        v.addLayout(first)
        # The source and 'Use the superbrand's value' sit on a second line under the
        # control: on one line with Browse and Clear the row was 100 px wider than the
        # 736 px window the Studio opens at on a small display (every row clipped).
        src = QtWidgets.QLabel()
        src.setObjectName(f"look_source_{field}")
        src.setStyleSheet("color: gray;")
        use = QtWidgets.QPushButton(USE_SUPERBRAND)
        use.setObjectName(f"look_use_{field}")
        use.clicked.connect(lambda _=False, f=field: self.use_superbrand_clicked(f))
        self.source_labels[field] = src
        self.use_buttons[field] = use
        second = QtWidgets.QHBoxLayout()
        second.setContentsMargins(0, 0, 0, 0)
        second.addWidget(src)
        second.addWidget(use)
        second.addStretch(1)
        v.addLayout(second)
        override = self.model.mode == "override"
        src.setVisible(override)
        use.setVisible(override)
        return _row(label, inner)

    def _hex_placeholder(self) -> str:
        return (_HEX_PLACEHOLDER_BRAND if self.model.mode == "override"
                else _HEX_PLACEHOLDER_DESIGN)

    def _hex_edit(self, field: str, label: str, box: QtWidgets.QVBoxLayout) -> QtWidgets.QLineEdit:
        le = QtWidgets.QLineEdit()
        le.setPlaceholderText(self._hex_placeholder())
        pick = QtWidgets.QPushButton("Pick…")
        pick.clicked.connect(lambda _=False, e=le: self._pick_color(e))
        le.editingFinished.connect(lambda f=field, e=le: self._hex_done(f, e.text()))
        le.textEdited.connect(lambda t, f=field: self._hex_typing(f, t))
        box.addWidget(self._field_row(field, label, le, [pick]))
        return le

    def _path_edit(self, field: str, label: str, box: QtWidgets.QVBoxLayout, *,
                   caption: str, file_filter: str, directory: bool = False,
                   on_change=None) -> QtWidgets.QLineEdit:
        le = QtWidgets.QLineEdit()
        browse = _file_picker(self, le, caption, file_filter, directory=directory)
        clear = QtWidgets.QPushButton("Clear")
        handler = on_change or (lambda t, f=field: self._write(f, t))
        # A stored picture is a data: URI, so its path box is EMPTY: setText("") on an
        # empty box emits nothing and the picture could never be removed from the window
        # (the text face removes it with 'logo -'). Clear therefore calls the handler
        # itself, with the signal held so a box that does change is not handled twice.
        def _clear(_=False, e=le, h=handler):
            e.blockSignals(True)
            try:
                e.setText("")
            finally:
                e.blockSignals(False)
            h("")
        clear.clicked.connect(_clear)
        le.textChanged.connect(handler)
        box.addWidget(self._field_row(field, label, le, [browse, clear]))
        return le

    def _colours_group(self) -> QtWidgets.QGroupBox:
        box = QtWidgets.QGroupBox("Colours")
        v = QtWidgets.QVBoxLayout(box)
        self.preset = NoWheelComboBox()
        populate_preset_combo(self.preset)
        self.preset.currentIndexChanged.connect(self._preset_chosen)
        v.addWidget(self._field_row("preset", "Theme preset", self.preset))
        self.ramp = NoWheelComboBox()
        for mode in theme_presets.MODES:
            self.ramp.addItem(f"{mode.capitalize()} ramp", mode)
        self.ramp.setToolTip("The neutral background and text ramp under the accent "
                             "colours; it applies with a preset.")
        self.ramp.currentIndexChanged.connect(
            lambda _i: self._write("mode", self.ramp.currentData() or ""))
        v.addWidget(self._field_row("mode", "Ramp", self.ramp))
        self.primary = self._hex_edit("primary", "Primary colour", v)
        self.secondary = self._hex_edit("secondary", "Secondary colour", v)
        self.stripes = QtWidgets.QWidget()
        self.stripes_lay = QtWidgets.QHBoxLayout(self.stripes)
        self.stripes_lay.setContentsMargins(0, 0, 0, 0)
        self.stripes_lay.setSpacing(0)
        self.stripes.setFixedHeight(14)
        self.stripes.setVisible(False)
        v.addWidget(_row("", self.stripes))
        return box

    def _font_group(self) -> QtWidgets.QGroupBox:
        box = QtWidgets.QGroupBox("Font")
        v = QtWidgets.QVBoxLayout(box)
        self.font = NoWheelComboBox()
        self.font.addItem(_KEEP_FONT, "")
        for name in core_fonts.FONT_PRESETS:
            self.font.addItem(name, name)
        self.font.setToolTip(
            "System font stacks only — zero bytes shipped, works air-gapped. For a "
            "specific face, upload it below (a data: URI embed, CSP-permitted).")
        self.font.currentIndexChanged.connect(
            lambda _i: self._write("font", self.font.currentData() or ""))
        v.addWidget(self._field_row("font", "Font preset", self.font))
        self.font_file = self._path_edit(
            "font_file", "Upload font", v, caption="Font file",
            file_filter="Fonts (*.woff2 *.woff *.ttf *.otf)", on_change=self._font_changed)
        # Short enough to be whole in the Fleet window's field (test_fleet_window_layout
        # measures every placeholder); the licence and source rows say they are required.
        self.font_file.setPlaceholderText("optional .woff2/.woff/.ttf/.otf file")
        self.font_note = ElidedLabel()
        self.font_note.setVisible(False)
        v.addWidget(self.font_note)
        self.font_licence = QtWidgets.QLineEdit()
        self.font_licence.setPlaceholderText("e.g. SIL OFL 1.1 — required with an upload")
        self.font_licence.editingFinished.connect(
            lambda: self._write("font_licence", self.font_licence.text()))
        v.addWidget(self._field_row("font_licence", "Font licence", self.font_licence))
        self.font_source = QtWidgets.QLineEdit()
        self.font_source.setPlaceholderText("foundry / URL it came from — required with an upload")
        self.font_source.editingFinished.connect(
            lambda: self._write("font_source", self.font_source.text()))
        v.addWidget(self._field_row("font_source", "Font source", self.font_source))
        self.requirements_note = QtWidgets.QLabel()
        self.requirements_note.setObjectName("look_requirements")
        self.requirements_note.setWordWrap(True)
        self.requirements_note.setStyleSheet("color: #a65d00;")
        self.requirements_note.setVisible(False)
        v.addWidget(self.requirements_note)
        self.font_sample = ElidedLabel("Sign in — AaBbGg 0123")
        self.font_sample.setStyleSheet("border: 1px solid #444; padding: 4px;")
        v.addWidget(_row("Font sample", self.font_sample))
        return box

    def _shape_group(self) -> QtWidgets.QGroupBox:
        box = QtWidgets.QGroupBox("Shape and decoration")
        v = QtWidgets.QVBoxLayout(box)
        self.style = NoWheelComboBox()
        for name in theme.STYLE_VARIANTS:
            self.style.addItem(STYLE_LABELS.get(name, name), name)
        self.style.currentIndexChanged.connect(
            lambda _i: self._write("style", self.style.currentData() or ""))
        v.addWidget(self._field_row("style", "Shape", self.style))
        self.decor = NoWheelComboBox()
        for name in theme.DECOR_VARIANTS:
            self.decor.addItem(DECOR_LABELS.get(name, name), name)
        self.decor.setToolTip("Decorative text on the menu links; screen readers skip "
                              "it (the consuming pages mark it decorative).")
        self.decor.currentIndexChanged.connect(
            lambda _i: self._write("decor", self.decor.currentData() or ""))
        v.addWidget(self._field_row("decor", "Menu decoration", self.decor))
        return box

    def _chrome_group(self, which: str) -> QtWidgets.QGroupBox:
        box = QtWidgets.QGroupBox(which.capitalize())
        v = QtWidgets.QVBoxLayout(box)
        hidden = QtWidgets.QCheckBox(f"Hide the {which}")
        hidden.toggled.connect(lambda on, f=f"{which}_hidden": self._write(f, bool(on)))
        v.addWidget(self._field_row(f"{which}_hidden", "Shown", hidden))
        size = NoWheelComboBox()
        size.addItem("Shipped size", "")
        for name, length in theme.CHROME_SIZES.items():
            size.addItem(f"{name.capitalize()} ({length})", name)
        size.currentIndexChanged.connect(
            lambda _i, c=size, f=f"{which}_size": self._write(f, c.currentData() or ""))
        v.addWidget(self._field_row(f"{which}_size", "Size", size))
        self._hex_edit(f"{which}_bg", "Background", v)
        text = QtWidgets.QLineEdit()
        text.setPlaceholderText(f"replacement {which} text — empty keeps the shipped content")
        text.editingFinished.connect(lambda f=f"{which}_text", e=text: self._write(f, e.text()))
        v.addWidget(self._field_row(f"{which}_text", "Content", text))
        setattr(self, f"{which}_hidden", hidden)
        setattr(self, f"{which}_size", size)
        setattr(self, f"{which}_text", text)
        return box

    def _background_group(self) -> QtWidgets.QGroupBox:
        box = QtWidgets.QGroupBox("Page background")
        v = QtWidgets.QVBoxLayout(box)
        self.bg_effect = NoWheelComboBox()
        for effect in theme.BG_EFFECTS:
            label = EFFECT_LABELS.get(effect, effect)
            if effect in theme.VANTA_EFFECTS:
                label += f" — {VANTA_UNSELECTABLE}"
            self.bg_effect.addItem(label, effect)
            if effect in theme.VANTA_EFFECTS:
                # listed, greyed, and the reason is one tooltip and one label away
                item = self.bg_effect.model().item(self.bg_effect.count() - 1)
                item.setEnabled(False)
                item.setToolTip(theme.VANTA_DEPENDENCY_NOTE)
        self.bg_effect.currentIndexChanged.connect(
            lambda _i: self._write("bg_effect", self.bg_effect.currentData()
                                   or theme.BG_EFFECT_DEFAULT))
        v.addWidget(self._field_row("bg_effect", "Background effect", self.bg_effect))
        self.vanta_note = QtWidgets.QLabel(
            f"The four Vanta effects are {VANTA_UNSELECTABLE}: " + theme.VANTA_DEPENDENCY_NOTE)
        self.vanta_note.setWordWrap(True)
        self.vanta_note.setStyleSheet("color: gray;")
        v.addWidget(self.vanta_note)
        return box

    def _pictures_group(self) -> QtWidgets.QGroupBox:
        box = QtWidgets.QGroupBox("Pictures on the web pages")
        v = QtWidgets.QVBoxLayout(box)
        intro = QtWidgets.QLabel(
            "PNG or JPEG only; the Studio re-encodes each picture and drops its "
            f"metadata. A logo is at most {brand_images.LIMITS['logo'][0]}x"
            f"{brand_images.LIMITS['logo'][1]}, a login background at most "
            f"{brand_images.LIMITS['background'][0]}x{brand_images.LIMITS['background'][1]}.")
        intro.setWordWrap(True)
        intro.setStyleSheet("color: gray;")
        v.addWidget(intro)
        for field, label in (("logo_image", "Logo"), ("login_bg_image", "Login background")):
            le = self._path_edit(field, label, v, caption=f"{label} picture",
                                 file_filter=_IMAGE_FILTER,
                                 on_change=lambda t, f=field: self._picture_changed(f, t))
            le.setPlaceholderText("path of a PNG or JPEG file")
            self.picture_paths[field] = le
            note = ElidedLabel()
            note.setObjectName(f"look_note_{field}")
            note.setVisible(False)
            self.picture_notes[field] = note
            v.addWidget(note)
            thumb = QtWidgets.QLabel()
            thumb.setObjectName(f"look_thumb_{field}")
            thumb.setFixedSize(*_THUMB_BOX)
            thumb.setAlignment(QtCore.Qt.AlignmentFlag.AlignLeft | QtCore.Qt.AlignmentFlag.AlignVCenter)
            thumb.setVisible(False)
            self.picture_thumbs[field] = thumb
            v.addWidget(thumb)
        self.meter = QtWidgets.QProgressBar()
        self.meter.setObjectName("look_meter")
        self.meter.setRange(0, brand_look.LOOK_CSS_BUDGET)
        self.meter.setTextVisible(False)
        self.meter.setMinimumHeight(14)
        self.meter_label = QtWidgets.QLabel()
        self.meter_label.setObjectName("look_meter_label")
        self.meter_label.setWordWrap(True)
        v.addWidget(_row("Stylesheet budget", self.meter))
        v.addWidget(self.meter_label)
        return box

    def _desktop_group(self) -> QtWidgets.QGroupBox:
        box = QtWidgets.QGroupBox("Desktop pictures and colours (x86 desktop images only)")
        v = QtWidgets.QVBoxLayout(box)
        self.theme = NoWheelComboBox()
        self.theme.addItem("No premade theme (stock look)", "")
        for name in PREMADE_THEMES:
            self.theme.addItem(THEME_SPECS[name].title, name)
        self.theme.currentIndexChanged.connect(
            lambda _i: self._write("theme", self.theme.currentData() or ""))
        v.addWidget(self._field_row("theme", "Premade theme", self.theme))
        self.wallpaper = self._path_edit("wallpaper", "Wallpaper", v, caption="Wallpaper",
                                         file_filter=_PICTURE_FILTER)
        self.boot_background = self._path_edit("boot_background", "Boot background", v,
                                               caption="Boot background",
                                               file_filter=_PICTURE_FILTER)
        self.boot_theme = self._path_edit("boot_theme", "Boot theme folder", v,
                                          caption="GRUB theme folder", file_filter="",
                                          directory=True)
        self.login_screen_background = self._path_edit(
            "login_screen_background", "Login-screen background", v,
            caption="Login-screen background", file_filter=_PICTURE_FILTER)
        self.desktop_logo = self._path_edit("desktop_logo", "Desktop logo", v,
                                            caption="Logo", file_filter=_PICTURE_FILTER)
        self.identity_note = QtWidgets.QLabel()
        self.identity_note.setWordWrap(True)
        self.identity_note.setStyleSheet("color: #a65d00;")
        self.identity_note.setVisible(False)
        v.addWidget(self.identity_note)
        self.accent_color = self._hex_edit("accent_color", "Accent colour", v)
        self.color_scheme = QtWidgets.QLineEdit()
        self.color_scheme.setPlaceholderText("a KDE colour scheme name — empty keeps the theme's")
        self.color_scheme.editingFinished.connect(
            lambda: self._write("color_scheme", self.color_scheme.text()))
        v.addWidget(self._field_row("color_scheme", "Colour scheme", self.color_scheme))
        return box

    def _preview_group(self) -> QtWidgets.QGroupBox:
        box = QtWidgets.QGroupBox("Preview")
        v = QtWidgets.QVBoxLayout(box)
        self.board = QtWidgets.QWidget()
        self.board_grid = QtWidgets.QGridLayout(self.board)
        self.board_grid.setContentsMargins(0, 0, 0, 0)
        v.addWidget(self.board)
        self.contrast_line = QtWidgets.QLabel()
        self.contrast_line.setObjectName("look_contrast")
        self.contrast_line.setWordWrap(True)
        v.addWidget(self.contrast_line)
        note = QtWidgets.QLabel(
            "Colour values and measured contrast only — layout and typography are the "
            "browser preview's job.")
        note.setWordWrap(True)
        note.setStyleSheet("color: gray;")
        v.addWidget(note)
        self.preview_btn = QtWidgets.QPushButton("Preview in your browser…")
        self.preview_btn.setObjectName("look_preview")
        self.preview_btn.clicked.connect(self._open_preview)
        v.addWidget(self.preview_btn)
        self.preview_note = QtWidgets.QLabel()
        self.preview_note.setWordWrap(True)
        self.preview_note.setTextInteractionFlags(
            QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        self.preview_note.setVisible(False)
        v.addWidget(self.preview_note)
        return box

    # ── model <-> controls ─────────────────────────────────────────────────────────
    def set_model(self, model: brand_look.Look) -> None:
        self.model = model
        override = model.mode == "override"
        for field in brand_look.HEX_FIELDS:
            ctl = self.controls.get(field)
            if isinstance(ctl, QtWidgets.QLineEdit):
                ctl.setPlaceholderText(self._hex_placeholder())
        for field in self.controls:
            self.source_labels[field].setVisible(override)
            self.use_buttons[field].setVisible(override)
        self.load_from_model()
        self.set_path(self.path)

    def load_from_model(self) -> None:
        """Every control from the model's effective look, signals held, then one
        refresh. The picture path boxes show nothing for a stored picture (it is a
        data: URI, not a file); their notes say a picture is set."""
        eff = self.model.effective()
        self._loading = True
        try:
            for field, control in self.controls.items():
                value = eff[field]
                control.blockSignals(True)
                try:
                    if isinstance(control, QtWidgets.QComboBox):
                        idx = control.findData(value)
                        control.setCurrentIndex(idx if idx >= 0 else 0)
                    elif isinstance(control, QtWidgets.QCheckBox):
                        control.setChecked(bool(value))
                    elif field in brand_look.PICTURE_FIELDS:
                        control.setText("")
                    elif isinstance(control, QtWidgets.QLineEdit):
                        control.setText(value or "")
                finally:
                    control.blockSignals(False)
            for field in brand_look.PICTURE_FIELDS:
                self._picture_note_from_model(field)
        finally:
            self._loading = False
        self._disarm()
        self._refresh()

    def _write(self, field: str, value) -> None:
        """One field changed by its control. Slot-safe: a refused value lands in
        error_note and the record is left as it was (the model says why, the same
        sentence the text screens show)."""
        if self._loading:
            return
        before = dict(self.model.own)
        try:
            out = self.model.try_set(field, value)
        except brand_look.LookError as exc:
            self._set_error(str(exc))
            return
        if not out.ok:
            self._set_error(out.text)
            return
        self._set_error("")
        if self.model.own != before:       # a box left unchanged is not an edit
            self._after_edit()

    def _after_edit(self) -> None:
        self._disarm()
        self._refresh()
        self.changed.emit()

    def _hex_done(self, field: str, text: str) -> None:
        """A colour finished (typed and left, or picked). A hand-typed primary or
        secondary goes through the model's rule: in DESIGN mode it flips a preset to
        Custom (the Themes group's rule) and the combo follows; any refusal is a sentence
        beside the control and the record is as it was."""
        if self._loading:
            return
        if field not in ("primary", "secondary"):
            self._write(field, text)
            self._refill_emptied(field, text)
            return
        had_preset = bool(self.model.get("preset"))
        before = dict(self.model.own)
        out = self.model.hand_edit_colour(field, text)
        if not out.ok:
            self._set_error(out.text)
            return
        if had_preset and not self.model.get("preset"):
            self.preset.blockSignals(True)
            try:
                self.preset.setCurrentIndex(0)
            finally:
                self.preset.blockSignals(False)
        self._set_error("")
        if self.model.own != before:
            self._after_edit()
        self._refill_emptied(field, text)

    def _refill_emptied(self, field: str, text: str) -> None:
        """An emptied colour box in override mode means "use the superbrand's": the model
        dropped the brand's own value, so the box shows the inherited one again."""
        if self.model.mode == "override" and not text.strip() and field not in self.model.own:
            self.load_from_model()

    def _hex_typing(self, field: str, text: str) -> None:
        """Live while typing: only a whole valid colour is applied, so a half-typed
        '#12' never raises a refusal under the person's fingers."""
        if theme.HEX_RE.match(text.strip()):
            self._hex_done(field, text)

    def _preset_chosen(self, *_):
        """A preset FILLS the two colours (the model keeps the preset too, for its
        ramp and stripes), so the board and the preview keep telling the truth."""
        if self._loading:
            return
        out = self.model.choose_preset(self.preset.currentData() or "")
        if not out.ok:
            self._set_error(out.text)
            return
        for le, field in ((self.primary, "primary"), (self.secondary, "secondary")):
            le.blockSignals(True)
            try:
                le.setText(self.model.effective()[field])
            finally:
                le.blockSignals(False)
        self._set_error("")
        self._after_edit()

    def _font_changed(self, text: str) -> None:
        """Validate an upload at pick time (the Themes group's gates, in the model), show
        the family the stylesheet will name, then record the path."""
        if self._loading:
            return
        path = text.strip()
        self._font_qt_family = ""
        out = self.model.load_font(path)
        if out.ok and path:
            try:
                with open(path, "rb") as fh:
                    font_id = QtGui.QFontDatabase.addApplicationFontFromData(fh.read())
                fams = QtGui.QFontDatabase.applicationFontFamilies(font_id) \
                    if font_id >= 0 else []
                self._font_qt_family = fams[0] if fams else ""
            except OSError:
                pass
        color = "#b00020" if not out.ok else ("#a65d00" if out.warn else "gray")
        self.font_note.set_full_text(out.text)
        self.font_note.setStyleSheet(f"color: {color};")
        self.font_note.setVisible(bool(out.text))
        if out.ok:
            self._set_error("")
            self._after_edit()

    def _picture_changed(self, field: str, text: str) -> None:
        """A picture path typed or picked: the model reads, re-encodes, measures it
        against the budget and the carriers, and only then records the data: URI. Any
        refusal is a sentence beside the box and the record keeps its previous picture."""
        if self._loading:
            return
        out = self.model.load_picture(field, text)
        self._picture_note(field, out.text, "#2e7d32" if out.ok else "#b00020")
        if out.ok:
            self._set_error("")
            self._after_edit()

    def _picture_note(self, field: str, text: str, color: str) -> None:
        note = self.picture_notes[field]
        note.set_full_text(text)
        note.setStyleSheet(f"color: {color};")
        note.setVisible(bool(text))

    def _picture_note_from_model(self, field: str) -> None:
        uri = self.model.effective()[field]
        if not uri:
            self._picture_note(field, "", "gray")
            return
        kind = "PNG" if uri.startswith("data:image/png") else "JPEG"
        size = len(uri.split(",", 1)[1]) * 3 // 4
        self._picture_note(field, f"A {kind} of about {size:,} bytes is set.", "gray")

    # ── 'Use the superbrand's value': arm, then apply ──────────────────────────────
    def use_superbrand_clicked(self, field: str) -> None:
        verdict = self.model.click_use_superbrand(field)
        if verdict == "armed":
            self._rearm_labels()
        elif verdict == "applied":
            self.load_from_model()
            self.changed.emit()

    def armed_field(self) -> str | None:
        return self.model.armed

    def _rearm_labels(self) -> None:
        for field, btn in self.use_buttons.items():
            btn.setText(USE_SUPERBRAND_ARMED if self.model.armed == field else USE_SUPERBRAND)

    def _disarm(self) -> None:
        self.model.armed = None
        self._rearm_labels()

    # ── where an override can show ─────────────────────────────────────────────────
    def set_path(self, path: str) -> None:
        self.path = path
        own_look_shows = (self.model.mode != "override"
                          or path in brand_look.PATHS_WITH_OWN_LOOK)
        self.path_note.setVisible(not own_look_shows)
        for field, control in self.controls.items():
            row = control.parentWidget()
            if row is not None:
                # DIRECT children only: the control, its buttons and the 'Use the
                # superbrand's value' button. A disabled parent disables everything
                # inside it, and walking every descendant reached a control's own
                # internal widgets (a combo box's popup, a line edit's clear button),
                # which Qt re-creates when a style changes: calling setEnabled on a
                # stale one crashed the process now and then (segfault in QWidget::
                # setEnabled, seen in a style-switching test).
                for w in row.findChildren(
                        QtWidgets.QWidget,
                        options=QtCore.Qt.FindChildOption.FindDirectChildrenOnly):
                    if w is not self.source_labels[field]:
                        w.setEnabled(own_look_shows)
        self._refresh_sources()
        sb = plain_words.term("superbrand")
        self.mode_note.setText(
            f"The {sb}'s look: every brand starts from these choices."
            if self.model.mode == "design" else
            f"This brand's look: each setting is inherited from the {sb} until you "
            f"change it; “{USE_SUPERBRAND}” hands it back (click twice).")

    def set_identity_allowed(self, allowed: bool, reason: str = "") -> None:
        """An unaffiliated build refuses the desktop logo (identity) and keeps every
        look field; the row stays drawn, disabled, with the reason."""
        self.model.identity_allowed = allowed
        self.model.identity_reason = reason
        row = self.controls["desktop_logo"].parentWidget()
        if row is not None:
            row.setEnabled(allowed)
        self.identity_note.setText(reason)
        self.identity_note.setVisible(not allowed and bool(reason))

    # ── refresh: sources, board, contrast, meter ───────────────────────────────────
    def _set_error(self, text: str) -> None:
        self._error = text
        self.error_note.setText(text)
        self.error_note.setVisible(bool(text))

    def error_text(self) -> str:
        return self._error

    def _refresh_sources(self) -> None:
        """Each row's source label, and 'Use the superbrand's value' enabled only where
        there is something of the brand's own to hand back AND somewhere it would show."""
        if self.model.mode != "override":
            return
        for field in self.controls:
            own = self.model.is_own(field)
            self.source_labels[field].setText(OWN_TEXT if own else INHERITED_TEXT)
            self.use_buttons[field].setEnabled(
                own and self.path in brand_look.PATHS_WITH_OWN_LOOK)

    def _refresh(self) -> None:
        eff = self.model.effective()
        self._refresh_sources()
        # stripes of a flag preset
        while self.stripes_lay.count():
            item = self.stripes_lay.takeAt(0)
            _discard(item.widget())
        stripes = ()
        if eff["preset"]:
            try:
                stripes = theme_presets.by_id(eff["preset"]).stripes
            except KeyError:
                stripes = ()
        for stripe in stripes:
            sw = QtWidgets.QLabel()
            sw.setStyleSheet(f"background: {stripe};")
            sw.setMinimumWidth(8)
            self.stripes_lay.addWidget(sw, 1)
        self.stripes.setVisible(bool(stripes))
        # the font sample shows the face Qt knows; the css names the safe family
        sample = QtGui.QFont()
        if self._font_qt_family:
            sample.setFamily(self._font_qt_family)
        elif eff["font"] and eff["font"] in core_fonts.FONT_PRESETS:
            sample.setFamily(core_fonts.FONT_PRESETS[eff["font"]].split(",")[0]
                             .strip().strip('"'))
        self.font_sample.setFont(sample)
        needs = self.model.requirements()
        self.requirements_note.setText("\n".join(needs))
        self.requirements_note.setVisible(bool(needs))
        self._refresh_board(eff)
        self._refresh_thumbs(eff)
        self._refresh_meter()

    def _refresh_board(self, eff: dict) -> None:
        while self.board_grid.count():
            item = self.board_grid.takeAt(0)
            _discard(item.widget())
        data = brand_look.board(eff)
        if data.problem:
            self.board_grid.addWidget(QtWidgets.QLabel(data.problem), 0, 0)
            self.contrast_line.setText("")
            return
        for row, cells in enumerate(data.rows):
            for col, (hex_color, caption) in enumerate(cells):
                self.board_grid.addWidget(_swatch(hex_color, caption), row, col)
        self.contrast_line.setText(data.contrast)

    def _refresh_thumbs(self, eff: dict) -> None:
        """Draw each chosen picture from the SAME data: URI the stylesheet carries, so a
        picture that is drawn here is the one that ships (and a broken one shows up)."""
        import base64
        for field, thumb in self.picture_thumbs.items():
            uri = eff[field]
            pix = QtGui.QPixmap()
            if uri:
                try:
                    pix.loadFromData(base64.b64decode(uri.split(",", 1)[1]))
                except (ValueError, IndexError):
                    pix = QtGui.QPixmap()
            if pix.isNull():
                thumb.clear()
                thumb.setVisible(False)
                continue
            thumb.setPixmap(pix.scaled(
                *_THUMB_BOX, QtCore.Qt.AspectRatioMode.KeepAspectRatio,
                QtCore.Qt.TransformationMode.SmoothTransformation))
            thumb.setVisible(True)

    def _refresh_meter(self) -> None:
        try:
            b = self.model.budget()
        except brand_look.LookError as exc:
            self.meter.setValue(0)
            self.meter_label.setText("")
            self._set_error(str(exc))
            return
        self.meter.setValue(min(b.used, b.limit))
        self.meter_label.setText(b.text())
        self.meter_label.setStyleSheet("" if b.fits else "color: #b00020;")

    # ── gestures ───────────────────────────────────────────────────────────────────
    def _pick_color(self, line_edit: QtWidgets.QLineEdit) -> None:
        initial = QtGui.QColor(line_edit.text().strip() or "#7c4dff")
        color = QtWidgets.QColorDialog.getColor(initial, self, "Pick a colour")
        if color.isValid():
            line_edit.setText(color.name())
            line_edit.editingFinished.emit()

    def _open_preview(self, *_):
        """The delivered bytes (model.css, budget enforced) into the browser preview."""
        self.preview_note.setVisible(False)
        try:
            css = self.model.css()
        except brand_look.LookError as exc:
            self._set_error(str(exc))
            self.preview_note.setStyleSheet("color: #b00020;")
            self.preview_note.setText("Fix the look error above before previewing.")
            self.preview_note.setVisible(True)
            return
        open_platform_preview(css, self.preview_note, self.error_note,
                              writer=brand_look.write_look_preview)


def _discard(widget) -> None:
    """Remove a widget the layout has let go of. deleteLater alone leaves it a visible
    child of its old parent, painted at its default 640x480 over the page, until the
    event loop gets round to the deletion; taking it off the parent first means it is
    never drawn."""
    if widget is not None:
        widget.setParent(None)
        widget.deleteLater()


def _swatch(hex_color: str, caption: str) -> QtWidgets.QLabel:
    """A colour tile whose text is auto black/white via the SAME on_color rule that
    ships — the board demonstrates the derivation by being built from it."""
    lab = QtWidgets.QLabel(caption)
    lab.setAlignment(QtCore.Qt.AlignmentFlag.AlignCenter)
    lab.setWordWrap(True)
    lab.setMinimumSize(96, 44)
    lab.setStyleSheet(
        f"background: {hex_color}; color: {theme.on_color(hex_color)};"
        f" border: 1px solid #444; border-radius: 3px; font-size: 8pt;")
    return lab
