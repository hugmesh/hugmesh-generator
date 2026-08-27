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
  that silently does nothing is the inert-control trap, and the theme MODEL
  already persists vanta values for configs written elsewhere;
* malformed input fails closed with an inline message — no edit ever raises.
"""
from __future__ import annotations

from ..core import theme, theme_presets

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
        out = [
            "The web login theme for the pages this image serves "
            "(login/shell chrome).", "",
            f"  preset     {preset} · {cfg.login_theme_mode or 'dark'} ramp",
            f"  primary    {cfg.login_primary_color or '(shipped default)'}",
            f"  secondary  {cfg.login_secondary_color or '(shipped default)'}",
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
