"""The look screen as text — :class:`LookText`, the text face of the window's
LookEditor (hugmesh-generator#654, D6 and D7).

The cfg-bound ``ThemesScreen`` that used to sit here (the TUI twin of the window's
old mesh-wide "Themes" group, opened with ``t`` from the Branding step) is gone: on
2026-10-21 the look moved to section 2 (Look) of each domain's Brand settings on the
Domain services step, the journey stopped offering ``t``, and nothing but tests still
opened the screen. The window's ``LoginThemeGroup`` and ``ThemeEditorDialog`` went the
same way. Everything that screen edited (colours, preset, ramp, font, header, footer,
background effect) is a :data:`FIELD_COMMANDS` row of :class:`LookText`, with the same
short verbs.
"""
from __future__ import annotations

from ..core import (brand_images, brand_look, fonts as _fonts, login_preview,
                    plain_words, theme, theme_presets)
from ..core.branding_themes import PREMADE_THEMES, THEME_SPECS

__all__ = ["EFFECT_LABELS", "VANTA_DEPENDENCY_NOTE"]

#: Re-exported from core.theme, which is the single definition. Kept in __all__
#: because callers and the GUI/TUI parity test both read it from this module.
from hugmesh_studio.core.theme import VANTA_DEPENDENCY_NOTE  # noqa: E402,F401

#: effect id -> human label: the one table in core, the same object the window's
#: LookEditor shows (tests/test_tui_gui_parity.py pins it).
EFFECT_LABELS = brand_look.EFFECT_LABELS


# ═════════════════════════════════════════════════════════════════════════════════════
# The LOOK screen (hugmesh-generator#654, D6 and D7): the text face of the window's
# LookEditor. It edits a brand_look.Look — the superbrand's own look in design mode, a
# brand's overrides in override mode — through the SAME checked verbs the window calls
# (Look.try_set, choose_preset, load_picture, load_font, click_use_superbrand), so the
# two faces refuse with the same sentence and write the same record (J-DESIGN).
# ═════════════════════════════════════════════════════════════════════════════════════
__all__ += ["LookText", "FIELD_COMMANDS", "SECTIONS"]

#: look field -> the command that edits it. EVERY control of the window's LookEditor has
#: a row here (tests/test_look_text.py iterates the editor's controls and fails when
#: one has no command). The short verbs are the old Themes screen's (p, m, 1, 2, hh...).
FIELD_COMMANDS: dict[str, str] = {
    "preset": "p", "mode": "m", "primary": "1", "secondary": "2",
    "font": "font", "font_file": "fontfile", "font_licence": "fontlicence",
    "font_source": "fontsource",
    "style": "shape", "decor": "decor",
    "header_hidden": "hh", "header_size": "hs", "header_bg": "hb", "header_text": "ht",
    "footer_hidden": "fh", "footer_size": "fs", "footer_bg": "fb", "footer_text": "ft",
    "bg_effect": "e",
    "logo_image": "logo", "login_bg_image": "loginbg",
    "theme": "dtheme", "wallpaper": "wallpaper", "boot_background": "bootbg",
    "boot_theme": "boottheme", "login_screen_background": "loginscreen",
    "desktop_logo": "dlogo", "accent_color": "accent", "color_scheme": "scheme",
}
_VERB_FIELD = {v: k for k, v in FIELD_COMMANDS.items()}

#: The numbered sections, the window's group boxes in the window's order.
SECTIONS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("Colours", ("preset", "mode", "primary", "secondary")),
    ("Font", ("font", "font_file", "font_licence", "font_source")),
    ("Shape and decoration", ("style", "decor")),
    ("Header", ("header_hidden", "header_size", "header_bg", "header_text")),
    ("Footer", ("footer_hidden", "footer_size", "footer_bg", "footer_text")),
    ("Page background", ("bg_effect",)),
    ("Pictures on the web pages", ("logo_image", "login_bg_image")),
    ("Desktop pictures and colours (x86 desktop images only)",
     ("theme", "wallpaper", "boot_background", "boot_theme", "login_screen_background",
      "desktop_logo", "accent_color", "color_scheme")),
)
_LABELS = {
    "preset": "Theme preset", "mode": "Ramp", "primary": "Primary colour",
    "secondary": "Secondary colour", "font": "Font preset", "font_file": "Upload font",
    "font_licence": "Font licence", "font_source": "Font source", "style": "Shape",
    "decor": "Menu decoration", "header_hidden": "Header hidden", "header_size": "Header size",
    "header_bg": "Header background", "header_text": "Header content",
    "footer_hidden": "Footer hidden", "footer_size": "Footer size",
    "footer_bg": "Footer background", "footer_text": "Footer content",
    "bg_effect": "Background effect", "logo_image": "Logo", "login_bg_image": "Login background",
    "theme": "Premade theme", "wallpaper": "Wallpaper", "boot_background": "Boot background",
    "boot_theme": "Boot theme folder", "login_screen_background": "Login-screen background",
    "desktop_logo": "Desktop logo", "accent_color": "Accent colour", "color_scheme": "Colour scheme",
}
_CHOICE_FIELDS = ("preset", "mode", "font", "style", "decor", "header_size", "footer_size",
                  "bg_effect", "theme")
_BOOL_FIELDS = ("header_hidden", "footer_hidden")
_PICTURE_VERBS = ("logo", "loginbg")
_EXTRA_VERBS = ("use", "board", "meter", "css", "preview", "commands")


def _look_choices(field: str) -> list[tuple[str, str]]:
    """(value, label) for a choice field, the same sets the window's combos offer."""
    if field == "preset":
        out = [("", "Custom colours (type the two below)")]
        out += [(p.preset_id, f"{p.group}: {p.label}") for p in theme_presets.PRESETS]
        return out
    if field == "mode":
        return [(m, f"{m.capitalize()} ramp") for m in theme_presets.MODES]
    if field == "font":
        return [("", "(keep the shipped font — Arial)")] + [(n, n) for n in _fonts.FONT_PRESETS]
    if field == "style":
        return [(n, brand_look.STYLE_LABELS.get(n, n)) for n in theme.STYLE_VARIANTS]
    if field == "decor":
        return [(n, brand_look.DECOR_LABELS.get(n, n)) for n in theme.DECOR_VARIANTS]
    if field in ("header_size", "footer_size"):
        return [("", "Shipped size")] + [(n, f"{n.capitalize()} ({v})")
                                         for n, v in theme.CHROME_SIZES.items()]
    if field == "bg_effect":
        return [(e, brand_look.EFFECT_LABELS[e] + (
            f" — {brand_look.VANTA_UNSELECTABLE}" if e in theme.VANTA_EFFECTS else ""))
            for e in theme.BG_EFFECTS]
    if field == "theme":
        return [("", "No premade theme (stock look)")] + [
            (n, THEME_SPECS[n].title) for n in PREMADE_THEMES]
    raise KeyError(field)


class LookText:
    """The look screen over one :class:`brand_look.Look`. Pure text in, text out: a host
    (the brand screens, a test script) calls :meth:`feed` with a
    line and shows :meth:`lines`. Slots-never-raise applies here too: every edit is
    checked and a refusal is a sentence in :attr:`message`, the record untouched."""

    def __init__(self, model: brand_look.Look, *, path: str = "docker") -> None:
        self.model = model
        self.path = path
        self.message: list[str] = []

    # ── what the screen shows ──────────────────────────────────────────────────────
    def _override_note(self) -> str:
        return ("" if (self.model.mode != "override"
                       or self.path in brand_look.PATHS_WITH_OWN_LOOK)
                else brand_look.DOCKER_ONLY_SENTENCE)

    def _value_text(self, field: str, eff: dict) -> str:
        value = eff[field]
        if field in _BOOL_FIELDS:
            return "hidden" if value else "shown"
        if field in _CHOICE_FIELDS:
            label = dict(_look_choices(field)).get(value, value)
            return label if value or field in ("preset", "font", "header_size", "footer_size",
                                               "theme") else "(shipped)"
        if field in brand_look.PICTURE_FIELDS:
            if not value:
                return "(none)"
            kind = "PNG" if value.startswith("data:image/png") else "JPEG"
            return f"a {kind} of about {len(value.split(',', 1)[1]) * 3 // 4:,} bytes is set"
        return value or "(shipped)"

    def lines(self) -> list[str]:
        m = self.model
        eff = m.effective()
        out: list[str] = []
        sb = plain_words.term("superbrand")
        if m.mode == "design":
            out.append(f"The {sb}'s look: every brand starts from these choices.")
        else:
            out.append(f"This brand's look: each setting is inherited from the {sb} "
                       "until you change it.")
            out.append(f"  'use COMMAND' twice hands one back ({brand_look.USE_SUPERBRAND}).")
        note = self._override_note()
        if note:
            out.append("  " + note + "  (the settings below are shown, not editable here)")
        out.append("")
        for number, (title, fields) in enumerate(SECTIONS, 1):
            out.append(f"{number}. {title}")
            for field in fields:
                cmd = FIELD_COMMANDS[field]
                src = ""
                if m.mode == "override":
                    src = ("   [" + (brand_look.OWN_TEXT if m.is_own(field)
                                     else brand_look.INHERITED_TEXT) + "]")
                    if m.armed == field:
                        src += "   [armed — " + brand_look.USE_SUPERBRAND_ARMED.lower() + "]"
                out.append(f"   {cmd:<11} {_LABELS[field]:<26} {self._value_text(field, eff)}{src}")
            if title == "Font":
                out += ["   ! " + need for need in m.requirements()]
            if title.startswith("Page background"):
                out.append("   " + f"The four Vanta effects are {brand_look.VANTA_UNSELECTABLE}: "
                           + theme.VANTA_DEPENDENCY_NOTE)
            if title.startswith("Pictures"):
                out.append("   " + self._picture_intro())
                out.append("   " + self._meter_text())
            out.append("")
        out.append(f"{len(SECTIONS) + 1}. Preview")
        out += ["   " + ln for ln in self._board_lines()]
        out.append("   board = the token board, preview = the page in your browser, "
                   "css = the stylesheet")
        out.append("")
        out.append("commands: " + ", ".join(sorted(_VERB_FIELD)) + ", " + ", ".join(_EXTRA_VERBS)
                   + "  (a command alone lists its choices; - clears; 'use COMMAND' twice)")
        if self.message:
            out.append("")
            out += self.message
        return out

    def _picture_intro(self) -> str:
        lo, bg = brand_images.LIMITS["logo"], brand_images.LIMITS["background"]
        return (f"PNG or JPEG only, re-encoded without metadata; a logo is at most "
                f"{lo[0]}x{lo[1]}, a login background at most {bg[0]}x{bg[1]}.")

    def _meter_text(self) -> str:
        try:
            return "Stylesheet budget: " + self.model.budget().text()
        except brand_look.LookError as exc:
            return f"Stylesheet budget: {exc}"

    def _board_lines(self) -> list[str]:
        data = brand_look.board(self.model.effective())
        if data.problem:
            return [data.problem]
        out = []
        for row in data.rows:
            out.append(" | ".join(caption.replace("\n", " ") for _hex, caption in row))
        out.append(data.contrast)
        return out

    # ── what the person types ──────────────────────────────────────────────────────
    def feed(self, line: str) -> str:
        """One command line. Returns (and keeps in :attr:`message`) the sentence the
        screen shows: the refusal with its reason, or the accepted-picture note. A line
        that changed nothing and had nothing to say returns ''."""
        text = self._feed(line.strip())
        self.message = text.splitlines() if text else []
        return text

    def _feed(self, line: str) -> str:
        verb, _, arg = line.partition(" ")
        verb, arg = verb.lower(), arg.strip()
        if not verb:
            return ""
        if verb != "use":
            self.model.armed = None          # anything but a second 'use' cancels the arm
        if verb == "use":
            return self._use(arg)
        if verb == "board":
            return "\n".join(self._board_lines())
        if verb == "meter":
            return self._meter_text()
        if verb == "css":
            try:
                return self.model.css() or ("(all defaults — no themed css is emitted)")
            except brand_look.LookError as exc:
                return str(exc)
        if verb == "preview":
            return self._preview()
        if verb == "commands":
            return ", ".join(sorted(_VERB_FIELD))
        field = _VERB_FIELD.get(verb)
        if field is None:
            return "unrecognised — 'commands' lists every command"
        note = self._override_note()
        if note:
            return note
        return self._edit(field, arg)

    def _edit(self, field: str, arg: str) -> str:
        m = self.model
        if field == "mode" and not arg:       # `m` alone toggles, as on the Themes screen
            now = m.effective()["mode"]
            arg = "light" if now == "dark" else "dark"
        if field in _CHOICE_FIELDS:
            return self._choose(field, arg)
        if field in _BOOL_FIELDS:
            low = arg.lower()
            value = (not m.effective()[field]) if not low else low in ("on", "yes", "true", "hide")
            return m.try_set(field, value).text
        if field in brand_look.PICTURE_FIELDS:
            if not arg:
                return self._picture_intro()
            return m.load_picture(field, "" if arg == "-" else arg).text
        if field == "font_file":
            if not arg:
                return "give the path of a .woff2, .woff, .ttf or .otf file, or - to remove it"
            return m.load_font("" if arg == "-" else arg).text
        if field in ("primary", "secondary"):
            if not arg:
                return "give #RRGGBB, or - to clear"
            return m.hand_edit_colour(field, "" if arg == "-" else arg).text
        if not arg:
            return "give a value, or - to clear"
        return m.try_set(field, "" if arg == "-" else arg).text

    def _choose(self, field: str, arg: str) -> str:
        choices = _look_choices(field)
        if not arg:
            cur = self.model.effective()[field]
            return "\n".join(
                f" {'*' if value == cur else ' '}{i:2d}. {label}"
                for i, (value, label) in enumerate(choices, 1))
        picked = None
        if arg.isdigit() and 1 <= int(arg) <= len(choices):
            picked = choices[int(arg) - 1][0]
        elif arg == "0" and field == "preset":
            picked = ""
        else:
            for value, _label in choices:
                if value == arg and (value or field in ("preset", "font", "header_size",
                                                        "footer_size", "theme")):
                    picked = value
        if picked is None:
            return f"no such choice {arg!r} — the command alone lists them"
        if field == "preset":
            return self.model.choose_preset(picked).text
        if field == "mode" and not picked:
            return "pick dark or light"
        return self.model.try_set(field, picked).text

    def _use(self, arg: str) -> str:
        field = _VERB_FIELD.get(arg.lower()) or (arg if arg in FIELD_COMMANDS else None)
        if field is None:
            return "'use' takes a command from the list, e.g. 'use shape'"
        if self.model.mode != "override":
            sb = plain_words.term("superbrand")
            return (f"This is the {sb}'s own look: there is no {sb} above it to "
                    "go back to.")
        note = self._override_note()
        if note:
            return note
        if not self.model.is_own(field):
            return f"{_LABELS[field]} is already {brand_look.INHERITED_TEXT}."
        verdict = self.model.click_use_superbrand(field)
        if verdict == "armed":
            return (f"{brand_look.USE_SUPERBRAND_ARMED}: type 'use {FIELD_COMMANDS[field]}' "
                    "again to apply (anything else cancels).")
        return f"{_LABELS[field]} is {brand_look.INHERITED_TEXT} again."

    def _preview(self) -> str:
        try:
            css = self.model.css()
        except brand_look.LookError as exc:
            return f"Fix the look error before previewing: {exc}"
        try:
            path = brand_look.write_look_preview(css, login_preview.preview_out_dir())
        except (OSError, RuntimeError) as exc:
            return f"preview failed: {exc}"
        opened, how = login_preview.open_in_browser(path)
        if opened:
            return f"Preview opened ({how}).\nFile: {path}"
        return f"Could not launch a browser automatically ({how}).\nOpen this file manually:\n{path}"
