"""BrandingPage — theme preset / branding dir, boot/login/wallpaper assets, GRUB
theme dir, accent + colour scheme, brand lock."""
from __future__ import annotations

import os

from ..qt import QtWidgets
from ...core.config import UNAFFILIATED_ROLE
from ._gating import clear_unsupported, platform_supports, unsupported_note
from ._widgets import _file_picker, _row

# every widget-backed field on this page — all x86-only emission, so the whole
# form greys as one unit off-x86 (G10), reusing the unaffiliated-role container.
# branding_dir (G8), color_scheme (G9) and grub_theme (G33) previously had field +
# emission but NO widget — only the keyzip import could set a branding dir.
_BRANDING_FIELDS = ("theme", "branding_dir", "wallpaper", "grub_background",
                    "grub_theme", "login_background", "brand_logo", "accent_color",
                    "color_scheme", "brand_locked")


class BrandingPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Branding")
        self.setSubTitle("Boot screen, login, wallpaper, accent — consistent across the desktop.")
        lay = QtWidgets.QVBoxLayout(self)
        # shown INSTEAD of the (disabled) form when the unaffiliated role is selected
        self.unaffiliated_note = QtWidgets.QLabel(
            "Branding does not apply — unaffiliated build (plain Gentoo, zero brand identity).")
        self.unaffiliated_note.setWordWrap(True)
        self.unaffiliated_note.setStyleSheet("color: #a65d00;")
        self.unaffiliated_note.setVisible(False)
        lay.addWidget(self.unaffiliated_note)
        # every branding widget lives in one container so the unaffiliated role can
        # disable the whole surface (line edits AND their Browse… buttons) at once
        self.form = QtWidgets.QWidget()
        form_lay = QtWidgets.QVBoxLayout(self.form)
        form_lay.setContentsMargins(0, 0, 0, 0)
        self.theme = QtWidgets.QComboBox()
        self.theme.setEditable(True)
        self.theme.addItem("")
        for t in self._themes():
            self.theme.addItem(t)
        form_lay.addWidget(_row("Theme preset", self.theme))
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
            form_lay.addWidget(_row(label, w))
            self.fields[key] = le
        self.accent = QtWidgets.QLineEdit()
        self.accent.setPlaceholderText("#3f5b8c")
        form_lay.addWidget(_row("Accent colour", self.accent))
        self.locked = QtWidgets.QCheckBox("Lock branding (user cannot re-theme — managed image)")
        form_lay.addWidget(self.locked)
        lay.addWidget(self.form)
        lay.addStretch(1)

    def _themes(self):
        d = os.path.join(self.wiz.generator_dir, "specs-x86", "branding", "themes")
        try:
            return sorted(x for x in os.listdir(d) if os.path.isdir(os.path.join(d, x)))
        except OSError:
            return ["boogiepop"]

    def initializePage(self):
        c = self.wiz.cfg
        unaffiliated = c.role == UNAFFILIATED_ROLE
        self.unaffiliated_note.setVisible(unaffiliated)
        # branding assets are x86-only emission (no ARM builder parses --theme/
        # --wallpaper/…) — grey the whole form off-x86 too, not just for the
        # unaffiliated role, instead of silently dropping the values (G10).
        supported = platform_supports("theme", c.platform)
        self.form.setEnabled(not unaffiliated and supported)
        self.form.setToolTip("" if supported else unsupported_note(c.platform))
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

    def validatePage(self):
        c = self.wiz.cfg
        if c.role == UNAFFILIATED_ROLE:
            # branding is a builder HARD CONFLICT on the unaffiliated role — clear
            # anything left over from a previously selected role instead of collecting
            # the (disabled) widgets, so a role switch cannot poison the argv.
            c.theme = c.branding_dir = c.wallpaper = c.grub_background = ""
            c.grub_theme = c.login_background = c.brand_logo = ""
            c.accent_color = c.color_scheme = ""
            c.brand_locked = False
            return True
        c.theme = self.theme.currentText().strip()
        c.branding_dir = self.fields["branding_dir"].text().strip()
        c.wallpaper = self.fields["wallpaper"].text().strip()
        c.grub_background = self.fields["grub_background"].text().strip()
        c.grub_theme = self.fields["grub_theme"].text().strip()
        c.login_background = self.fields["login_background"].text().strip()
        c.brand_logo = self.fields["brand_logo"].text().strip()
        c.color_scheme = self.fields["color_scheme"].text().strip()
        c.accent_color = self.accent.text().strip()
        c.brand_locked = self.locked.isChecked()
        # off-x86 the form is greyed (see initializePage) — reset the collected
        # fields so values picked while x86 was selected can't linger (G10).
        clear_unsupported(c, _BRANDING_FIELDS)
        return True
