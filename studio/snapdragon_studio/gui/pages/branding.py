"""BrandingPage — TWO branding surfaces with opposite scopes:

* DESKTOP assets (premade theme XOR custom boot/login/wallpaper/GRUB/accent, plus
  the brand lock): x86-only emission, greys+clears on node images and in mesh mode
  (``branding_allowed``) and on the unaffiliated role (a builder hard-conflict).
  The premade combo and the eight custom fields are an exclusive either/or so the
  two branding channels can never fight.
* The WEB LOGIN THEME (colours/fonts for the login page the MESH serves to
  browsers): NON-argv mesh-plane fields (config NON_ARGV_FIELDS), deliberately
  OUTSIDE the desktop gating — mesh mode visits this page exactly FOR this half,
  and greying it there would gate the knob off on the only plane that renders it.
"""
from __future__ import annotations

import os

from ..qt import QtWidgets
from ...core.config import UNAFFILIATED_ROLE, branding_allowed
from ._gating import (
    clear_unsupported, gate_widgets_role_class, platform_supports, unsupported_note,
)
from ._logintheme import LoginThemeGroup
from ._scroll import scrollable
from ._widgets import _file_picker, _row, collapsible

# every widget-backed field on this page — all x86-only emission, so the whole
# form greys as one unit off-x86 (G10) and clears on Next.
_BRANDING_FIELDS = ("theme", "branding_dir", "wallpaper", "grub_background",
                    "grub_theme", "login_background", "brand_logo", "accent_color",
                    "color_scheme", "brand_locked")
# The eight custom-value fields (spec 2): everything in THEME_FIELDS except the
# premade ``theme`` (the preset radio's combo) and ``brand_locked`` (which stays
# OUTSIDE the either/or — a lock applies to whichever branding channel is chosen).
# Selecting "Premade theme" blanks these; selecting "Custom branding" blanks theme.
_CUSTOM_FIELDS = ("branding_dir", "wallpaper", "grub_background", "grub_theme",
                  "login_background", "brand_logo", "color_scheme", "accent_color")

_ROLE_CLASS_REASON = (
    "Theming applies to desktop images only — node / mesh images take the brand "
    "defaults, no per-image theme. Cleared when you leave the page.")


class BrandingPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Branding")
        self.setSubTitle("Desktop branding (theme or custom assets) plus the web "
                         "login theme the mesh serves.")
        # scrollable: the login-theme group grew this page past the #400 jitter
        # budget — tall content scrolls inside the page instead of resizing the window.
        lay = scrollable(self)
        # shown INSTEAD of the (disabled) form when the unaffiliated role is selected
        self.unaffiliated_note = QtWidgets.QLabel(
            "Branding does not apply — unaffiliated build (plain Gentoo, zero brand identity).")
        self.unaffiliated_note.setWordWrap(True)
        self.unaffiliated_note.setStyleSheet("color: #a65d00;")
        self.unaffiliated_note.setVisible(False)
        lay.addWidget(self.unaffiliated_note)
        # every branding widget lives in one container so the role-class / platform /
        # unaffiliated grey can disable the whole surface at once.
        self.form = QtWidgets.QWidget()
        form_lay = QtWidgets.QVBoxLayout(self.form)
        form_lay.setContentsMargins(0, 0, 0, 0)

        # premade-theme (preset) XOR custom-branding — an exclusive either/or (spec 2).
        # Both stay visible/scannable; selecting one enables it and disables+clears the
        # other (enable-gating, not a QStackedWidget).
        self.mode_group = QtWidgets.QButtonGroup(self)
        self.rb_preset = QtWidgets.QRadioButton("Premade theme")
        self.rb_custom = QtWidgets.QRadioButton("Custom branding")
        self.mode_group.addButton(self.rb_preset, 0)
        self.mode_group.addButton(self.rb_custom, 1)
        form_lay.addWidget(self.rb_preset)
        # theme preset combo — NON-editable now: a fixed enumeration of the shipped
        # themes plus the brand-derived entry, so free text can't smuggle a custom
        # value past the either/or. Items are (re)built per-brand in initializePage.
        self.theme = QtWidgets.QComboBox()
        self.theme.setEditable(False)
        self.theme.addItem("")
        for t in self._themes():
            self.theme.addItem(t)
        form_lay.addWidget(_row("Theme preset", self.theme))

        form_lay.addWidget(self.rb_custom)
        # the eight custom-value fields + accent, wrapped so the custom radio can grey
        # them all at once (line edits AND their Browse… buttons).
        self.custom_group = QtWidgets.QGroupBox("Custom branding assets")
        cg = QtWidgets.QVBoxLayout(self.custom_group)
        self.fields = {}
        for key, label, flt, is_dir in (
            # --branding-dir: a whole hand-rolled branding tree — the manual
            # counterpart of the keyzip import, which was the ONLY way to set it (G8)
            ("branding_dir", "Branding dir", "", True),
            ("wallpaper", "Wallpaper", "Images (*.png *.jpg *.jpeg)", False),
            ("grub_background", "GRUB background", "Images (*.png)", False),
            # --grub-theme: a full GRUB theme dir, distinct from the background (G33)
            ("grub_theme", "GRUB theme dir", "", True),
            ("login_background", "Login background", "Images (*.png *.jpg)", False),
            ("brand_logo", "Brand logo", "Images (*.png)", False),
            # --color-scheme FILE.colors (the build menu's OPT_BR_SCHEME; G9)
            ("color_scheme", "Colour scheme", "KDE colour scheme (*.colors)", False),
        ):
            le = QtWidgets.QLineEdit()
            btn = _file_picker(self, le, label, flt or "All files (*)", directory=is_dir)
            w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
            h.addWidget(le, 1); h.addWidget(btn)
            cg.addWidget(_row(label, w))
            self.fields[key] = le
        self.accent = QtWidgets.QLineEdit()
        self.accent.setPlaceholderText("#3f5b8c")
        cg.addWidget(_row("Accent colour", self.accent))
        form_lay.addWidget(self.custom_group)

        # an old save with BOTH a premade theme AND custom assets → custom wins, the
        # theme is cleared, and this orange note explains the reconciliation.
        self.both_set_note = QtWidgets.QLabel(
            "Both a premade theme and custom assets were set — keeping the custom "
            "assets and clearing the theme.")
        self.both_set_note.setWordWrap(True)
        self.both_set_note.setStyleSheet("color: #a65d00;")
        self.both_set_note.setVisible(False)
        form_lay.addWidget(self.both_set_note)

        # brand lock stays OUTSIDE the either/or (applies to any branding channel).
        self.locked = QtWidgets.QCheckBox("Lock branding (user cannot re-theme — managed image)")
        form_lay.addWidget(self.locked)
        lay.addWidget(self.form)

        # WEB login theme — OUTSIDE self.form on purpose: the desktop gating
        # (role-class / platform / unaffiliated) must never grey it, because it
        # themes the login page the MESH serves, not the desktop image. Collapsed
        # by default in desktop flows; initializePage expands it in mesh, where it
        # is the reason the page is shown at all.
        self.login_theme = LoginThemeGroup()
        self.login_collapsible = collapsible("Web login theme", self.login_theme,
                                             expanded=False)
        lay.addWidget(self.login_collapsible)
        lay.addStretch(1)

        self.rb_preset.toggled.connect(self._mode_toggled)
        self.rb_preset.setChecked(True)   # default channel: premade theme

    def _themes(self):
        d = os.path.join(self.wiz.generator_dir, "specs-x86", "branding", "themes")
        try:
            return sorted(x for x in os.listdir(d) if os.path.isdir(os.path.join(d, x)))
        except OSError:
            return ["boogiepop"]

    def _mode_toggled(self, *_):
        """Keep the preset combo and the custom group mutually exclusive: the selected
        channel is enabled, the other disabled AND cleared so a stale value can't leak
        past the either/or (belt & braces for validatePage's field commit)."""
        preset = self.rb_preset.isChecked()
        self.theme.setEnabled(preset)
        self.custom_group.setEnabled(not preset)
        if preset:
            for le in list(self.fields.values()) + [self.accent]:
                le.clear()
        elif self.theme.count():
            self.theme.setCurrentIndex(0)

    def initializePage(self):
        c = self.wiz.cfg
        unaffiliated = c.role == UNAFFILIATED_ROLE
        self.unaffiliated_note.setVisible(unaffiliated)
        # theming is desktop-class AND x86-only emission — grey the whole form when
        # (a) the unaffiliated role is selected, (b) it is a node/mesh image
        # (branding_allowed), or (c) the platform's builder parses no --theme/… flag.
        role_class_ok = branding_allowed(c)
        platform_ok = platform_supports("theme", c.platform)
        enabled = not unaffiliated and role_class_ok and platform_ok

        # rebuild the preset enumeration for this brand (non-editable → the current
        # value must be a present item or the combo can't display it).
        self.theme.blockSignals(True)
        self.theme.clear()
        self.theme.addItem("")
        for t in self._themes():
            self.theme.addItem(t)
        brand_theme = (c.brand or "").strip()
        if brand_theme and self.theme.findText(brand_theme) < 0:
            self.theme.addItem(brand_theme)
        if c.theme and self.theme.findText(c.theme) < 0:
            self.theme.addItem(c.theme)
        self.theme.blockSignals(False)

        # populate both channels from the config
        self.theme.setCurrentText(c.theme)
        self.fields["branding_dir"].setText(c.branding_dir)
        self.fields["wallpaper"].setText(c.wallpaper)
        self.fields["grub_background"].setText(c.grub_background)
        self.fields["grub_theme"].setText(c.grub_theme)
        self.fields["login_background"].setText(c.login_background)
        self.fields["brand_logo"].setText(c.brand_logo)
        self.fields["color_scheme"].setText(c.color_scheme)
        self.accent.setText(c.accent_color)
        self.locked.setChecked(c.brand_locked)

        # decide the active channel: theme-only or neither → preset; any custom field
        # → custom; BOTH set → custom wins (theme cleared) with the orange warning.
        has_theme = bool(c.theme)
        has_custom = any(getattr(c, f) for f in _CUSTOM_FIELDS)
        self.both_set_note.setVisible(has_theme and has_custom)
        self.mode_group.blockSignals(True)
        (self.rb_custom if has_custom else self.rb_preset).setChecked(True)
        self.mode_group.blockSignals(False)
        self._mode_toggled()   # sync enable + clear the inactive channel

        reason = unsupported_note(c.platform) if not platform_ok else _ROLE_CLASS_REASON
        gate_widgets_role_class(self.form, enabled, "" if enabled else reason)

        # web login theme: ALWAYS active (mesh-plane, not desktop). In mesh the
        # desktop half is greyed, so this half IS the page — open it by default
        # (respecting an operator who folded it themselves).
        self.login_theme.load(c)
        self.login_collapsible.set_default_expanded(c.mode == "mesh")

    def _blank_all(self, c):
        """Clear every branding field — the shared clear for the unaffiliated role and
        for any greyed (node/mesh/off-x86) image, so a stale value can never poison a
        save or the emitted argv."""
        c.theme = c.branding_dir = c.wallpaper = c.grub_background = ""
        c.grub_theme = c.login_background = c.brand_logo = ""
        c.accent_color = c.color_scheme = ""
        c.brand_locked = False

    def validatePage(self):
        c = self.wiz.cfg
        # web login theme commits FIRST and UNCONDITIONALLY: it is mesh-plane data,
        # so neither the unaffiliated role nor the desktop role-class/platform
        # clears below may touch it (an unaffiliated IMAGE can ride a mesh whose
        # login page is themed — different scopes).
        self.login_theme.commit(c)
        if c.role == UNAFFILIATED_ROLE:
            # branding is a builder HARD CONFLICT on the unaffiliated role — clear
            # everything so a role switch cannot poison the argv.
            self._blank_all(c)
            return True
        if not (branding_allowed(c) and platform_supports("theme", c.platform)):
            # node / mesh / off-x86: the form is greyed — clear every branding field
            # (belt & braces, mirrored by materialize()'s clear_role_class_fields I4).
            self._blank_all(c)
            return True
        if self.rb_preset.isChecked():
            # premade-theme channel: commit the preset, blank the custom fields.
            c.theme = self.theme.currentText().strip()
            for f in _CUSTOM_FIELDS:
                setattr(c, f, "")
        else:
            # custom-branding channel: blank the preset, collect the eight fields.
            c.theme = ""
            c.branding_dir = self.fields["branding_dir"].text().strip()
            c.wallpaper = self.fields["wallpaper"].text().strip()
            c.grub_background = self.fields["grub_background"].text().strip()
            c.grub_theme = self.fields["grub_theme"].text().strip()
            c.login_background = self.fields["login_background"].text().strip()
            c.brand_logo = self.fields["brand_logo"].text().strip()
            c.color_scheme = self.fields["color_scheme"].text().strip()
            c.accent_color = self.accent.text().strip()
        c.brand_locked = self.locked.isChecked()
        # platform belt & braces (the form is already greyed off-x86, but keep the
        # established clear so nothing can linger).
        clear_unsupported(c, _BRANDING_FIELDS)
        return True
