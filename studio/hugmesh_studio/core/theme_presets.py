"""Named web-login theme PRESETS — the wizard's one-click alternative to typing hex.

Operator ask: *"add a theme wizard with options like the desktop themes — light,
dark and some basic color themes — with also themes for all LGBTQ+ flags"*.

This module is the ONE place the preset set is declared, mirroring the pattern
:mod:`branding_themes` established for the desktop wallpaper themes ("the GUI
offers a theme the builder rejects" is the defect class a single table
prevents). Each preset resolves to the SAME ``--sd-*`` token contract
:mod:`theme` derives for hand-typed colours — a preset is exactly "someone
already picked good primary/secondary values for you", plus for the flag
presets a stripe gradient carrying the REAL flag so a consumer can paint an
authentic accent bar rather than a two-colour approximation.

Design rules, in order:

* **Reuse the derivation, never fork it.** ``compose_tokens`` starts from
  :func:`theme.derive` — WCAG-safe accent-text derivation included — and only
  then applies mode neutrals + extras. No second colour pipeline.
* **Light mode is a NEUTRAL swap, not a re-derivation.** The dark neutral ramp
  is fixed by design (see ``theme._NEUTRALS``); light mode swaps in the
  equivalent light ramp and re-runs the ONE derived text token that targets the
  background (``--sd-accent-soft``) against the light bg so accent text stays
  >= 4.5:1. Everything else is untouched.
* **Flag themes are respectful, not novelty.** The stripe colours are the
  commonly-published flag values; the derived UI accents are drawn FROM the
  flag's own stripes (never invented), and the full flag is preserved verbatim
  in ``--sd-flag-stripes`` (a CSS ``linear-gradient`` with hard stops) plus
  ``--sd-flag-name`` for accessibility labelling. A consumer that only knows
  the base contract simply ignores the extras.

Pure stdlib + :mod:`theme`; no Qt — the GUI paints its cards from this table
and the headless CLI path can resolve a preset by id.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Tuple

from . import theme

# ── light-mode neutral ramp ──────────────────────────────────────────────────
# The light counterpart of theme._NEUTRALS. Same keys, so a mode swap can never
# leave a token dangling (test-pinned). Text colours clear 4.5:1 on --sd-bg-0
# by construction: #1a1a24 on #f7f7fb is ~15.8:1, #4a4e66 muted is ~7.0:1.
_LIGHT_NEUTRALS: Dict[str, str] = {
    "--sd-bg-0": "#f7f7fb",
    "--sd-bg-1": "#ededf4",
    "--sd-bg-2": "#e2e2ec",
    "--sd-border": "#c9c9d8",
    "--sd-text": "#1a1a24",
    "--sd-text-muted": "#4a4e66",
    "--sd-success": "#1a7f37",
    "--sd-error": "#c62828",
    "--sd-black": "#0a0a0a",
    "--sd-charcoal": "#f0f0f0",
    "--sd-surface": "#ffffff",
    "--sd-mid": "#c4c4c4",
    "--sd-muted": "#5a5a5a",
    "--sd-light": "#3a3a3a",
    "--sd-offwhite": "#141414",
}

MODES: Tuple[str, ...] = ("dark", "light")


@dataclass(frozen=True)
class ThemePreset:
    """One selectable theme. ``stripes`` empty => a plain colour preset."""
    preset_id: str
    label: str
    group: str                      # "Core" | "Colours" | "Pride flags"
    primary: str
    secondary: str
    stripes: Tuple[str, ...] = ()   # the flag, top-to-bottom, verbatim
    note: str = ""                  # one-liner shown under the card label


def _p(pid, label, group, primary, secondary, stripes=(), note=""):
    return ThemePreset(pid, label, group, primary, secondary, tuple(stripes), note)


# ── the catalogue ────────────────────────────────────────────────────────────
# Colour sources: the flag stripe values are the commonly-published sets (e.g.
# the 6-stripe rainbow, Helms trans, Page bi); primary/secondary picks favour
# mid-saturation stripes that derive well on both ramps.
PRESETS: Tuple[ThemePreset, ...] = (
    # Core — mirrors the desktop set's shape (light and dark firsts).
    _p("dark",    "HugMesh Dark",  "Core", "#ffd700", "#7c4dff",
       note="The shipped brand on the dark ramp."),
    _p("light",   "HugMesh Light", "Core", "#b8860b", "#5e35b1",
       note="The shipped brand tuned for the light ramp."),

    # Basic colour themes — one hue each, both ramps available via mode.
    _p("ocean",   "Ocean",   "Colours", "#1976d2", "#0097a7"),
    _p("forest",  "Forest",  "Colours", "#2e7d32", "#558b2f"),
    _p("crimson", "Crimson", "Colours", "#c62828", "#ad1457"),
    _p("amber",   "Amber",   "Colours", "#ff8f00", "#d84315"),
    _p("teal",    "Teal",    "Colours", "#00796b", "#00838f"),
    _p("violet",  "Violet",  "Colours", "#6a1b9a", "#7c4dff"),
    _p("slate",   "Slate",   "Colours", "#546e7a", "#78909c"),
    _p("rose",    "Rose",    "Colours", "#d81b60", "#ec407a"),

    # Pride flags. Stripe order is top-to-bottom as flown.
    _p("pride", "Pride", "Pride flags", "#e40303", "#732982",
       ("#e40303", "#ff8c00", "#ffed00", "#008026", "#24408e", "#732982"),
       "The six-stripe rainbow flag."),
    _p("progress", "Progress Pride", "Pride flags", "#e40303", "#613915",
       ("#ffffff", "#ffafc8", "#74d7ee", "#613915", "#000000",
        "#e40303", "#ff8c00", "#ffed00", "#008026", "#24408e", "#732982"),
       "Rainbow plus the chevron's trans + brown/black stripes."),
    _p("trans", "Transgender", "Pride flags", "#5bcefa", "#f5a9b8",
       ("#5bcefa", "#f5a9b8", "#ffffff", "#f5a9b8", "#5bcefa"),
       "The Helms trans flag."),
    _p("bi", "Bisexual", "Pride flags", "#d60270", "#0038a8",
       ("#d60270", "#d60270", "#9b4f96", "#0038a8", "#0038a8"),
       "The Page bi flag (2-1-2 ratio kept via repeated stripes)."),
    _p("pan", "Pansexual", "Pride flags", "#ff218c", "#21b1ff",
       ("#ff218c", "#ffd800", "#21b1ff")),
    _p("lesbian", "Lesbian", "Pride flags", "#d52d00", "#a30262",
       ("#d52d00", "#ff9a56", "#ffffff", "#d362a4", "#a30262"),
       "The five-stripe orange/pink flag."),
    _p("gay-mlm", "Gay (MLM)", "Pride flags", "#078d70", "#3d1a78",
       ("#078d70", "#26ceaa", "#98e8c1", "#ffffff", "#7bade2", "#5049cc", "#3d1a78")),
    _p("nonbinary", "Nonbinary", "Pride flags", "#9c59d1", "#fcf434",
       ("#fcf434", "#ffffff", "#9c59d1", "#2c2c2c")),
    _p("ace", "Asexual", "Pride flags", "#800080", "#a3a3a3",
       ("#000000", "#a3a3a3", "#ffffff", "#800080")),
    _p("aro", "Aromantic", "Pride flags", "#3da542", "#a7d379",
       ("#3da542", "#a7d379", "#ffffff", "#a9a9a9", "#000000")),
    _p("genderfluid", "Genderfluid", "Pride flags", "#be18d6", "#333ebd",
       ("#ff75a2", "#ffffff", "#be18d6", "#000000", "#333ebd")),
    _p("genderqueer", "Genderqueer", "Pride flags", "#b57edc", "#4a8123",
       ("#b57edc", "#ffffff", "#4a8123")),
    _p("intersex", "Intersex", "Pride flags", "#ffd800", "#7902aa",
       ("#ffd800", "#7902aa", "#ffd800"),
       "Yellow and purple; the ring is the flag's mark, kept in the stripes."),
    _p("agender", "Agender", "Pride flags", "#b9b9b9", "#b8f483",
       ("#000000", "#b9b9b9", "#ffffff", "#b8f483", "#ffffff", "#b9b9b9", "#000000")),
    _p("polysexual", "Polysexual", "Pride flags", "#f714ba", "#1594f6",
       ("#f714ba", "#01d66a", "#1594f6")),
    _p("demisexual", "Demisexual", "Pride flags", "#6e0070", "#d2d2d2",
       ("#ffffff", "#6e0070", "#d2d2d2"),
       "White/purple/grey; the black chevron is preserved as the first stop."),
)


def by_id(preset_id: str) -> ThemePreset:
    for p in PRESETS:
        if p.preset_id == preset_id:
            return p
    raise KeyError(f"unknown theme preset: {preset_id!r}")


def groups() -> List[str]:
    seen: List[str] = []
    for p in PRESETS:
        if p.group not in seen:
            seen.append(p.group)
    return seen


def _soft_for_text_on_light(accent_hex: str, bg: str, target: float = 4.5) -> str:
    """DARKEN ``accent_hex`` toward black until it clears ``target`` on a LIGHT
    ``bg``. :func:`theme.soft_for_text` deliberately only lightens (its bg is the
    fixed dark shell, where lifting always solves); reusing it against a light
    background falls through its loop and returns #ffffff — invisible text. Same
    minimal-step lerp shape, opposite direction; black on any light ramp bg
    clears 4.5:1, so the loop always terminates with a passing value."""
    r0 = int(accent_hex[1:3], 16)
    g0 = int(accent_hex[3:5], 16)
    b0 = int(accent_hex[5:7], 16)
    for i in range(0, 257):
        t = i / 256.0
        cand = "#%02x%02x%02x" % (
            round(r0 * (1 - t)), round(g0 * (1 - t)), round(b0 * (1 - t)))
        if theme.contrast_ratio(cand, bg) >= target:
            return cand
    return "#000000"


def _stripe_gradient(stripes: Tuple[str, ...]) -> str:
    """Hard-stop linear-gradient of the flag, top to bottom — the REAL flag, not
    an approximation. Equal bands; consumers size the bar, not this module."""
    n = len(stripes)
    parts = []
    for i, c in enumerate(stripes):
        a = i * 100.0 / n
        b = (i + 1) * 100.0 / n
        parts.append(f"{c} {a:.4g}% {b:.4g}%")
    return "linear-gradient(180deg, " + ", ".join(parts) + ")"


def compose_tokens(preset_id: str, mode: str = "dark") -> Dict[str, str]:
    """The full token map for a preset+mode. Starts from :func:`theme.derive`
    (accent-text WCAG derivation included), then applies the mode's neutral
    ramp, re-anchors the one bg-targeted derived token for light mode, and adds
    the flag extras when the preset carries stripes."""
    if mode not in MODES:
        raise ValueError(f"mode must be one of {MODES}, got {mode!r}")
    p = by_id(preset_id)
    tokens = theme.derive(p.primary, p.secondary)
    if mode == "light":
        tokens.update(_LIGHT_NEUTRALS)
        # --sd-accent-soft was derived to clear 4.5:1 on the DARK bg; re-target it
        # against the light bg. Darken, don't reuse soft_for_text — that helper
        # only lightens (correct for its fixed dark shell) and would fall through
        # to #ffffff here, i.e. invisible accent text on a near-white page.
        tokens["--sd-accent-soft"] = _soft_for_text_on_light(
            p.secondary, _LIGHT_NEUTRALS["--sd-bg-0"])
    if p.stripes:
        tokens["--sd-flag-stripes"] = _stripe_gradient(p.stripes)
        tokens["--sd-flag-name"] = f'"{p.label}"'
    return tokens


def compose_css(preset_id: str, mode: str = "dark", *, font_faces: str = "") -> str:
    """The ready-to-ship snap-theme.css text for a preset+mode."""
    return theme.css_root(compose_tokens(preset_id, mode), font_faces=font_faces)


def delta_tokens(preset_id: str, mode: str = "dark") -> Dict[str, str]:
    """ONLY the tokens a preset+mode changes versus the plain
    ``theme.derive(primary, secondary)`` base — i.e. the light-ramp neutrals,
    the re-anchored accent text, and the flag extras. Empty for a dark-mode
    preset with no stripes (the base derivation already IS the theme).

    Exists so the delivery path can reuse :func:`theme.compose_login_css`
    unchanged (colour + font pipeline, one implementation) and merely APPEND a
    second ``:root:root`` block: at equal specificity the later block wins, so
    the delta lands without forking the font/derivation code."""
    p = by_id(preset_id)
    base = theme.derive(p.primary, p.secondary)
    full = compose_tokens(preset_id, mode)
    return {k: v for k, v in full.items() if base.get(k) != v}


def delta_css(preset_id: str, mode: str = "dark") -> str:
    """The appendable ``:root:root`` block for :func:`delta_tokens`; "" when the
    preset+mode adds nothing over the base derivation."""
    delta = delta_tokens(preset_id, mode)
    return theme.css_root(delta) if delta else ""
