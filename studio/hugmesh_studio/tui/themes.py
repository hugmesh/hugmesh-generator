"""The Themes SCREEN — the TUI surface of GUI PR #63 ("'Web login theme' becomes
'Themes' + modeless decompressed editor").

TUI-appropriate: a SCREEN, not a popup — opened from the Branding step (and
closed with q), never a modal (the repo's no-modal rule needs no translation
here: a prompt loop has no exec() to abuse). It edits the SAME ``cfg.login_*``
fields the GUI group/editor edit, through the same closed vocabularies
(``theme.CHROME_SIZES``, ``theme.BG_EFFECTS``), so the previewed CSS bytes
(``cfg.login_theme_css()``) are the delivered bytes for both surfaces.

Semantics mirrored from the GUI editor:

* the PRESET interplay — picking a preset fills the two hex colours; hand-editing
  a hex flips the preset to Custom (``login_theme_preset = ""``);
* header/footer existence, size (CHROME_SIZES), background, content;
* the background effect: gradient/none selectable, the VANTA rows LISTED but
  refused with the dependency named (:data:`VANTA_DEPENDENCY_NOTE`) — an option
  that silently does nothing is the do-nothing-control trap, and the theme MODEL
  already persists vanta values for configs written elsewhere;
* malformed input fails closed with an inline message — no edit ever raises.
"""
from __future__ import annotations

from ..core import (brand_images, brand_look, fonts as _fonts, login_preview, plain_words,
                    theme, theme_presets)
from ..core.branding_themes import PREMADE_THEMES, THEME_SPECS

__all__ = ["ThemesScreen", "EFFECT_LABELS", "VANTA_DEPENDENCY_NOTE", "chrome_summary"]

#: Re-exported from core.theme, which is the single definition. Kept in __all__
#: because callers and the GUI/TUI parity test both read it from this module.
from hugmesh_studio.core.theme import VANTA_DEPENDENCY_NOTE  # noqa: F401

#: effect id -> human label — parity-pinned against the GUI editor's labels.
EFFECT_LABELS = {
    "gradient": "Moving gradient (shipped default — colours follow the theme)",
    "none": "None — flat themed background",
    "vanta-fog": "Vanta fog (animated WebGL)",
    "vanta-waves": "Vanta waves (animated WebGL)",
    "vanta-net": "Vanta net (animated WebGL)",
    "vanta-globe": "Vanta globe (animated WebGL)",
}

#: The font commands and the board are cfg-backed, so the cfg-bound Themes screen offers
#: them. Shape, decoration and the two web pictures have no field in the image config
#: yet (they live in the brand record), so offering them here would be a control that
#: changes nothing; the brand screens mount :class:`LookText` over the record instead.
_CFG_LOOK_VERBS = ("font", "fontfile", "fontlicence", "fontsource", "board")

_HELP = [
    "commands:",
    "  p               pick a named preset (fills the colours)",
    "  1 #RRGGBB       primary colour   (hand-editing flips the preset to Custom)",
    "  2 #RRGGBB       secondary colour (hand-editing flips the preset to Custom)",
    "  m               toggle dark/light neutral ramp",
    "  hh / fh         toggle the header / footer hidden",
    "  hs SIZE / fs SIZE   header/footer size: "
    + " | ".join(theme.CHROME_SIZES) + " | - (shipped)",
    "  hb #RRGGBB|- / fb #RRGGBB|-   header/footer background (- = shipped)",
    "  ht TEXT|- / ft TEXT|-         header/footer content (- = shipped)",
    "  e               pick the page background effect",
    "  font [N|name]   the font style (alone: the list; - keeps the shipped font)",
    "  fontfile PATH   upload one font file (- removes it); then:",
    "  fontlicence TEXT / fontsource TEXT   its licence and where it came from (required)",
    "  board           the token board with the measured contrast",
    "  css             preview the composed theme CSS (the delivered bytes)",
    "  q               back",
]


def chrome_summary(cfg, which: str) -> str:
    """One line describing a chrome surface's current choices."""
    hidden = getattr(cfg, f"login_{which}_hidden")
    size = getattr(cfg, f"login_{which}_size") or "(shipped)"
    bg = getattr(cfg, f"login_{which}_bg") or "(shipped)"
    text = getattr(cfg, f"login_{which}_text") or "(shipped)"
    shown = "hidden" if hidden else "shown"
    return f"{which:6s}  {shown} · size {size} · bg {bg} · content {text}"


class ThemesScreen:
    """The Themes screen (an overlay over the Branding step)."""

    slug = "themes"
    title = "Themes"
    wants_q = True                     # q means BACK here, not quit-the-journey

    def __init__(self):
        self._sub = "main"             # main | presets | effects | css

    def enter(self, j) -> None:  # noqa: ARG002 — screen-protocol signature
        self._sub = "main"

    # ── rendering ───────────────────────────────────────────────────────────────
    def lines(self, j) -> list[str]:
        cfg = j.cfg
        if self._sub == "presets":
            out = ["Named presets (a NUMBER picks; 0 = custom colours, "
                   "q = back):", ""]
            for i, p in enumerate(theme_presets.PRESETS, 1):
                marker = "*" if cfg.login_theme_preset == p.preset_id else " "
                out.append(f" {marker}{i:2d}. {p.label}  [{p.group}]")
            return out
        if self._sub == "effects":
            out = ["Page background effect (a NUMBER picks, q = back):", ""]
            for i, effect in enumerate(theme.BG_EFFECTS, 1):
                marker = "*" if cfg.login_bg_effect == effect else " "
                note = "" if effect in _selectable_effects() else "  (unavailable)"
                out.append(f" {marker}{i}. {EFFECT_LABELS[effect]}{note}")
            out += ["", VANTA_DEPENDENCY_NOTE]
            return out
        if self._sub == "css":
            css = cfg.login_theme_css()
            out = css.splitlines() if css else [
                "(all defaults — no themed css is emitted, so an unthemed "
                "config composes byte-identically)"]
            out += ["", "(any input returns)"]
            return out
        preset = cfg.login_theme_preset or "(custom colours)"
        font = cfg.login_font_file or cfg.login_font or "(shipped — Arial)"
        out = [
            "The web login theme for the pages this image serves "
            "(login/shell chrome).", "",
            f"  preset     {preset} · {cfg.login_theme_mode or 'dark'} ramp",
            f"  primary    {cfg.login_primary_color or '(shipped default)'}",
            f"  secondary  {cfg.login_secondary_color or '(shipped default)'}",
            f"  font       {font}",
            "  " + chrome_summary(cfg, "header"),
            "  " + chrome_summary(cfg, "footer"),
            f"  effect     {EFFECT_LABELS[cfg.login_bg_effect]}",
            "",
        ]
        out += _HELP
        return out

    def prompt(self, j) -> str:  # noqa: ARG002
        return f"themes:{self._sub}> " if self._sub != "main" else "themes> "

    # ── input ───────────────────────────────────────────────────────────────────
    def feed(self, j, line: str) -> None:
        cfg = j.cfg
        low = line.lower()
        if self._sub == "presets":
            self._feed_presets(j, line)
            return
        if self._sub == "effects":
            self._feed_effects(j, line)
            return
        if self._sub == "css":
            self._sub = "main"
            return
        if low in ("q", "quit", "exit"):
            j.close_overlay()
            return
        if low == "p":
            self._sub = "presets"
            return
        if low == "e":
            self._sub = "effects"
            return
        if low == "css":
            self._sub = "css"
            return
        if low == "m":
            cfg.login_theme_mode = ("light" if (cfg.login_theme_mode or "dark")
                                    == "dark" else "dark")
            return
        if low in ("hh", "fh"):
            which = "header" if low[0] == "h" else "footer"
            field = f"login_{which}_hidden"
            setattr(cfg, field, not getattr(cfg, field))
            return
        verb, _, arg = line.partition(" ")
        arg = arg.strip()
        if verb.lower() in _CFG_LOOK_VERBS:
            # The font and the board are the cfg's own fields; the Look screen
            # edits them through the same checked verbs the window's LookEditor uses.
            j.status = LookText(brand_look.CfgLook(cfg)).feed(line)
            return
        handler = {
            "1": self._set_primary, "2": self._set_secondary,
            "hs": lambda j, a: self._set_size(j, "header", a),
            "fs": lambda j, a: self._set_size(j, "footer", a),
            "hb": lambda j, a: self._set_bg(j, "header", a),
            "fb": lambda j, a: self._set_bg(j, "footer", a),
            "ht": lambda j, a: self._set_text(j, "header", a),
            "ft": lambda j, a: self._set_text(j, "footer", a),
        }.get(verb.lower())
        if handler is None or not arg:
            j.status = "unrecognised — the command list above shows every edit"
            return
        handler(j, arg)

    # ── edits (each fails closed with an inline message, never raises) ──────────
    def _set_primary(self, j, value: str) -> None:
        if not theme.HEX_RE.match(value):
            j.status = f"not a colour: {value!r} (use #RRGGBB)"
            return
        j.cfg.login_primary_color = value
        j.cfg.login_theme_preset = ""       # hand-edited hex flips to Custom

    def _set_secondary(self, j, value: str) -> None:
        if not theme.HEX_RE.match(value):
            j.status = f"not a colour: {value!r} (use #RRGGBB)"
            return
        j.cfg.login_secondary_color = value
        j.cfg.login_theme_preset = ""

    def _set_size(self, j, which: str, value: str) -> None:
        if value == "-":
            value = ""
        elif value not in theme.CHROME_SIZES:
            j.status = (f"unknown size {value!r} — one of "
                        f"{' | '.join(theme.CHROME_SIZES)} | - (shipped)")
            return
        setattr(j.cfg, f"login_{which}_size", value)

    def _set_bg(self, j, which: str, value: str) -> None:
        if value == "-":
            value = ""
        elif not theme.HEX_RE.match(value):
            j.status = f"not a colour: {value!r} (use #RRGGBB, or - for shipped)"
            return
        setattr(j.cfg, f"login_{which}_bg", value)

    def _set_text(self, j, which: str, value: str) -> None:
        setattr(j.cfg, f"login_{which}_text", "" if value == "-" else value)

    def _feed_presets(self, j, line: str) -> None:
        if line.lower() in ("q", "quit", "exit"):
            self._sub = "main"
            return
        if line == "0":
            j.cfg.login_theme_preset = ""
            self._sub = "main"
            return
        try:
            idx = int(line) - 1
        except ValueError:
            idx = -1
        if not 0 <= idx < len(theme_presets.PRESETS):
            j.status = f"no such preset: {line!r}"
            return
        p = theme_presets.PRESETS[idx]
        j.cfg.login_theme_preset = p.preset_id
        # the preset FILLS the hex fields (the GUI group's interplay) — a later
        # hand-edit of either flips back to Custom.
        j.cfg.login_primary_color = p.primary
        j.cfg.login_secondary_color = p.secondary
        self._sub = "main"

    def _feed_effects(self, j, line: str) -> None:
        if line.lower() in ("q", "quit", "exit"):
            self._sub = "main"
            return
        try:
            idx = int(line) - 1
        except ValueError:
            idx = -1
        if not 0 <= idx < len(theme.BG_EFFECTS):
            j.status = f"no such effect: {line!r}"
            return
        effect = theme.BG_EFFECTS[idx]
        if effect not in _selectable_effects():
            # listed but refused WITH the dependency — never a silent no-op.
            j.status = f"not selectable yet: {VANTA_DEPENDENCY_NOTE}"
            return
        j.cfg.login_bg_effect = effect
        self._sub = "main"


def _selectable_effects() -> tuple[str, ...]:
    """What the TUI lets the operator PICK: everything but the vanta rows —
    exactly the GUI editor's enablement (the shipped shell renders these two)."""
    return tuple(e for e in theme.BG_EFFECTS if e not in theme.VANTA_EFFECTS)


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
#: one has no command). The short verbs are the ThemesScreen's own (p, m, 1, 2, hh...).
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
    (the Themes overlay, the brand screens, a test script) calls :meth:`feed` with a
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
