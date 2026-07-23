"""The "Web login theme" group — colours + fonts for the login page the MESH serves.

Hosted in TWO places (one implementation, so they cannot drift):
  * BrandingPage — every mode, INCLUDING mesh (the page's desktop-asset half greys
    there; this half is exactly why mesh no longer skips the page).
  * LocalMeshPage's bootstrap tab — that flow is terminal at the page, so
    BrandingPage is unreachable from it.

HONESTY SPLIT (what each surface can guarantee):
  * The in-window TOKEN BOARD shows the real derived hex values and live-measured
    WCAG ratios straight from core/theme.py — the values cannot drift from what
    ships, by construction. It makes NO layout claim and says so.
  * The "Preview in browser" button substitutes the derived css into the CAPTURED
    real login page (core/login_preview.py) and opens it in the operator's REAL
    browser — the actual runtime target. NOT QtWebEngine: that exists under PySide6
    (the test venv) and not under the operator's PyQt6, so a WebEngine preview
    would pass every test and be dead on the machine that matters.

Slots here NEVER raise (an unhandled exception in a Qt slot aborts PyQt6):
``compose_css()`` returns "" and records ``error_text()`` instead of raising, and
hosts surface that text (red note + refusing to launch a verb with bad input).
"""
from __future__ import annotations

import os
import tempfile

from ..qt import QtCore, QtGui, QtWidgets
from ...core import fonts as core_fonts
from ...core import login_preview, theme
from ._widgets import _file_picker, _row

_HEX_PLACEHOLDER = "#RRGGBB — empty keeps the shipped colour"
_KEEP_FONT = "(keep the shipped font — Arial)"


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


class LoginThemeGroup(QtWidgets.QGroupBox):
    def __init__(self, parent=None):
        super().__init__("Web login theme (the login page this mesh serves)", parent)
        lay = QtWidgets.QVBoxLayout(self)

        intro = QtWidgets.QLabel(
            "Pick primary + secondary brand colours — every other login token "
            "(bright/dim accents, legible text variants) is DERIVED, and text "
            "legibility is guaranteed by construction: no colour is ever rejected, "
            "text tokens are auto-adjusted to WCAG AA (≥ 4.5:1). Applied at "
            "container start (no image rebuild); empty = the shipped brand.")
        intro.setWordWrap(True)
        lay.addWidget(intro)

        # ── colours ──
        self.primary = QtWidgets.QLineEdit()
        self.primary.setPlaceholderText(_HEX_PLACEHOLDER)
        self.secondary = QtWidgets.QLineEdit()
        self.secondary.setPlaceholderText(_HEX_PLACEHOLDER)
        for le, label in ((self.primary, "Primary colour"),
                          (self.secondary, "Secondary colour")):
            btn = QtWidgets.QPushButton("Pick…")
            btn.clicked.connect(lambda _=False, e=le: self._pick_color(e))
            w = QtWidgets.QWidget()
            h = QtWidgets.QHBoxLayout(w)
            h.setContentsMargins(0, 0, 0, 0)
            h.addWidget(le, 1)
            h.addWidget(btn)
            lay.addWidget(_row(label, w))

        # ── font ──
        self.font_preset = QtWidgets.QComboBox()
        self.font_preset.addItem(_KEEP_FONT)
        for name in core_fonts.FONT_PRESETS:
            self.font_preset.addItem(name)
        self.font_preset.setToolTip(
            "System font stacks only — zero bytes shipped, works air-gapped, and the "
            "login page's CSP (font-src 'self' data:) would block any CDN font by "
            "code. 'Bootstrap native stack' is Bootstrap 5's real system stack. For "
            "a specific face, upload it below (a data: URI embed — CSP-permitted).")
        lay.addWidget(_row("Font preset", self.font_preset))

        self.font_file = QtWidgets.QLineEdit()
        self.font_file.setPlaceholderText(
            "optional .woff2/.woff/.ttf/.otf — embedded, so licence + source are "
            "recorded with its sha256")
        browse = _file_picker(self, self.font_file, "Font file",
                              "Fonts (*.woff2 *.woff *.ttf *.otf)")
        clear = QtWidgets.QPushButton("Clear")
        clear.clicked.connect(lambda: self.font_file.setText(""))
        fw = QtWidgets.QWidget()
        fh = QtWidgets.QHBoxLayout(fw)
        fh.setContentsMargins(0, 0, 0, 0)
        fh.addWidget(self.font_file, 1)
        fh.addWidget(browse)
        fh.addWidget(clear)
        lay.addWidget(_row("Upload font", fw))

        self.font_note = QtWidgets.QLabel("")
        self.font_note.setWordWrap(True)
        self.font_note.setVisible(False)
        lay.addWidget(self.font_note)

        self.font_licence = QtWidgets.QLineEdit()
        self.font_licence.setPlaceholderText("e.g. SIL OFL 1.1 — required with an upload")
        lay.addWidget(_row("Font licence", self.font_licence))
        self.font_source = QtWidgets.QLineEdit()
        self.font_source.setPlaceholderText("foundry / URL it came from — required with an upload")
        lay.addWidget(_row("Font source", self.font_source))

        # in-window font sample: REAL Qt rendering of the chosen face/stack. Only the
        # browser preview is typographically faithful to the page; this shows the face.
        self.font_sample = QtWidgets.QLabel("Sign in to hugmesh — AaBbGg 0123")
        self.font_sample.setStyleSheet("border: 1px solid #444; padding: 4px;")
        lay.addWidget(_row("Font sample", self.font_sample))

        # ── live token board ──
        self.board = QtWidgets.QWidget()
        self.board_grid = QtWidgets.QGridLayout(self.board)
        self.board_grid.setContentsMargins(0, 0, 0, 0)
        lay.addWidget(self.board)
        board_note = QtWidgets.QLabel(
            "Colour values + measured contrast only — layout and typography are the "
            "browser preview's job (button below opens the real captured login page "
            "in your browser).")
        board_note.setWordWrap(True)
        board_note.setStyleSheet("color: gray;")
        lay.addWidget(board_note)

        self.warn_note = QtWidgets.QLabel("")
        self.warn_note.setWordWrap(True)
        self.warn_note.setStyleSheet("color: #a65d00;")
        self.warn_note.setVisible(False)
        lay.addWidget(self.warn_note)

        self.error_note = QtWidgets.QLabel("")
        self.error_note.setWordWrap(True)
        self.error_note.setStyleSheet("color: #b00020;")
        self.error_note.setVisible(False)
        lay.addWidget(self.error_note)

        self.preview_btn = QtWidgets.QPushButton("Preview the real login page in your browser…")
        self.preview_btn.clicked.connect(self._open_preview)
        lay.addWidget(self.preview_btn)

        # Feedback for the preview open itself (distinct from the red css error_note):
        # confirms the launch + the file path, and — when no browser could be launched
        # (a headless / minimal / Wayland desktop with no xdg-open handler) — shows the
        # path to open manually instead of the button appearing to do nothing.
        self.preview_note = QtWidgets.QLabel("")
        self.preview_note.setWordWrap(True)
        self.preview_note.setTextInteractionFlags(
            QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        self.preview_note.setVisible(False)
        lay.addWidget(self.preview_note)

        # uploaded-font state (bytes cached once, validated at pick time)
        self._font_bytes = b""
        self._font_family = ""
        self._error = ""

        self.primary.textChanged.connect(self._refresh)
        self.secondary.textChanged.connect(self._refresh)
        self.font_preset.currentIndexChanged.connect(self._refresh)
        self.font_file.textChanged.connect(self._font_changed)
        self._refresh()

    # ── cfg binding ──────────────────────────────────────────────────────────────
    def load(self, cfg) -> None:
        self.primary.setText(cfg.login_primary_color)
        self.secondary.setText(cfg.login_secondary_color)
        idx = self.font_preset.findText(cfg.login_font) if cfg.login_font else 0
        self.font_preset.setCurrentIndex(idx if idx > 0 else 0)
        self.font_file.setText(cfg.login_font_file)
        self.font_licence.setText(cfg.login_font_licence)
        self.font_source.setText(cfg.login_font_source)

    def commit(self, cfg) -> None:
        """Widgets -> cfg.login_* (raw fields; derivation happens at delivery via
        cfg.login_theme_css() / compose_css so every consumer shares it)."""
        cfg.login_primary_color = self.primary.text().strip()
        cfg.login_secondary_color = self.secondary.text().strip()
        cfg.login_font = self._preset_name()
        cfg.login_font_file = self.font_file.text().strip()
        cfg.login_font_licence = self.font_licence.text().strip()
        cfg.login_font_source = self.font_source.text().strip()

    def _preset_name(self) -> str:
        return "" if self.font_preset.currentIndex() <= 0 else self.font_preset.currentText()

    # ── composition (never raises — slot-safe) ───────────────────────────────────
    def error_text(self) -> str:
        return self._error

    def compose_css(self) -> str:
        """The derived snap-theme.css text for the current widget state, or "" when
        unthemed OR invalid — with the reason in error_text() and shown in red.
        Never raises: textChanged slots reach this, and an unhandled slot exception
        aborts the app under PyQt6."""
        try:
            css = theme.compose_login_css(
                self.primary.text(), self.secondary.text(),
                font_preset=self._preset_name(),
                font_family=self._font_family, font_bytes=self._font_bytes)
            self._error = ""
        except ValueError as exc:
            css, self._error = "", str(exc)
        self.error_note.setText(self._error)
        self.error_note.setVisible(bool(self._error))
        return css

    # ── interaction ──────────────────────────────────────────────────────────────
    def _pick_color(self, line_edit: QtWidgets.QLineEdit) -> None:
        initial = QtGui.QColor(line_edit.text().strip() or "#7c4dff")
        color = QtWidgets.QColorDialog.getColor(initial, self, "Pick a brand colour")
        if color.isValid():
            line_edit.setText(color.name())

    def _font_changed(self, *_):
        """Validate an upload ONCE at pick time: cheap structural gates (extension,
        magic bytes, size warning) then Qt's own parser — which also yields the
        canonical family name and lets the sample label render the actual face.
        HONESTY: a Qt parse is structural validation, not a browser-safety proof;
        the sha256 + required licence/source are the recorded provenance."""
        path = self.font_file.text().strip()
        self._font_bytes, self._font_family = b"", ""
        note, color = "", "gray"
        if path:
            try:
                with open(path, "rb") as fh:
                    data = fh.read()
            except OSError as exc:
                note, color = f"cannot read: {exc}", "#b00020"
                data = b""
            if data:
                blocks, warns = core_fonts.check_font(os.path.basename(path), data)
                if blocks:
                    note, color = "REJECTED: " + "; ".join(blocks), "#b00020"
                else:
                    font_id = QtGui.QFontDatabase.addApplicationFontFromData(data)
                    if font_id < 0:
                        note, color = ("REJECTED: Qt could not parse this file as a "
                                       "font (renamed/corrupt file?)"), "#b00020"
                    else:
                        fams = QtGui.QFontDatabase.applicationFontFamilies(font_id)
                        self._font_family = fams[0] if fams else \
                            os.path.splitext(os.path.basename(path))[0]
                        self._font_bytes = data
                        note = (f"OK: family “{self._font_family}”, "
                                f"{len(data) // 1024}KB, "
                                f"sha256 {core_fonts.font_sha256(data)[:16]}… — "
                                "licence + source below are REQUIRED (recorded).")
                        if warns:
                            note += "  " + " ".join(warns)
                            color = "#a65d00"
        self.font_note.setText(note)
        self.font_note.setStyleSheet(f"color: {color};")
        self.font_note.setVisible(bool(note))
        self._refresh()

    def _refresh(self, *_):
        """Rebuild the token board + warnings + font sample from core/theme.py —
        the same derive() that ships, so the board cannot drift."""
        while self.board_grid.count():
            item = self.board_grid.takeAt(0)
            w = item.widget()
            if w is not None:
                w.deleteLater()

        primary = self.primary.text().strip()
        secondary = self.secondary.text().strip()
        valid_p = bool(theme.HEX_RE.match(primary)) if primary else True
        valid_s = bool(theme.HEX_RE.match(secondary)) if secondary else True
        row = 0
        if valid_p and valid_s:
            tokens = (theme.derive(primary or theme._DEFAULT_PRIMARY, secondary)
                      if (primary or secondary) else theme.default_tokens())
            for row, prefix in enumerate(("primary", "secondary")):
                base = tokens[f"--sd-{prefix}"]
                soft = tokens[f"--sd-{prefix}-soft"]
                on = tokens[f"--sd-{prefix}-on"]
                cells = (
                    (base, f"{prefix}\n{base}"),
                    (tokens[f"--sd-{prefix}-bright"],
                     f"bright\n{tokens[f'--sd-{prefix}-bright']}"),
                    (tokens[f"--sd-{prefix}-dim"],
                     f"dim\n{tokens[f'--sd-{prefix}-dim']}"),
                    (soft, f"text on shell\n{soft}\n"
                           f"{theme.contrast_ratio(soft, theme.SHELL_BG):.2f}:1 AA"),
                    (base, f"“Sign in” text\n{on} on {base}\n"
                           f"{theme.contrast_ratio(on, base):.2f}:1 AA"),
                )
                for col, (hex_color, caption) in enumerate(cells):
                    self.board_grid.addWidget(_swatch(hex_color, caption), row, col)
            warns = theme.warnings(primary or theme._DEFAULT_PRIMARY, secondary) \
                if (primary or secondary) else []
            self.warn_note.setText("\n".join(warns))
            self.warn_note.setVisible(bool(warns))
        else:
            bad = self.primary if not valid_p else self.secondary
            self.board_grid.addWidget(QtWidgets.QLabel(
                f"“{bad.text().strip()}” is not #RRGGBB — board paused"), 0, 0)
            self.warn_note.setVisible(False)

        # font sample: uploaded family wins; else first family of the preset stack.
        sample_font = QtGui.QFont()
        if self._font_family:
            sample_font.setFamily(self._font_family)
        elif self._preset_name():
            first = core_fonts.FONT_PRESETS[self._preset_name()].split(",")[0]
            sample_font.setFamily(first.strip().strip('"'))
        self.font_sample.setFont(sample_font)

        self.compose_css()   # refresh error state live

    def _open_preview(self, *_):
        """Write the captured real login page with the CURRENT theme substituted and
        open it in the operator's default browser (the actual runtime target).

        Robust open: Qt's QDesktopServices.openUrl first, then the Qt-free
        login_preview.open_in_browser fallback (stdlib webbrowser + xdg-open/$BROWSER)
        — and if NOTHING can launch a browser (headless / minimal / Wayland desktop
        with no registered handler), the file path is surfaced for a manual open so
        the button never silently does nothing."""
        self.preview_note.setVisible(False)
        css = self.compose_css()
        if self._error:
            # The red error_note already explains the theme error; make the button's
            # inaction explicit rather than a silent no-op.
            self.preview_note.setStyleSheet("color: #b00020;")
            self.preview_note.setText("Fix the theme error above before previewing.")
            self.preview_note.setVisible(True)
            return
        out_dir = os.path.join(tempfile.gettempdir(), "hugmesh-studio-preview")
        try:
            path = login_preview.write_preview(css, out_dir)
        except (OSError, RuntimeError) as exc:
            self.error_note.setText(f"preview failed: {exc}")
            self.error_note.setVisible(True)
            return
        opened = bool(QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(path)))
        if not opened:
            opened, _how = login_preview.open_in_browser(path)
        if opened:
            self.preview_note.setStyleSheet("color: #2e7d32;")
            self.preview_note.setText(f"Preview opened in your browser.\nFile: {path}")
        else:
            self.preview_note.setStyleSheet("color: #b00020;")
            self.preview_note.setText(
                "Could not launch a browser automatically. Open this file manually:\n"
                + path)
        self.preview_note.setVisible(True)
