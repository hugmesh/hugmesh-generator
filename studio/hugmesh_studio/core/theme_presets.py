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

#: TIME-OF-DAY RAMPS. Operator ask 2026-08-14: "add more times of day".
#:
#: A ramp is the NEUTRAL surface only — background steps, text, border. It never touches
#: the brand colours, so every ramp composes with every preset and every style, exactly
#: like the style axis. "dark" and "light" are kept as the first two and are BYTE-
#: IDENTICAL to what they were (dark = the base _NEUTRALS with no override), because
#: cfg.login_theme_mode persists these names and every existing caller passes one.
#:
#: The progression is warm->cool->warm around the clock rather than a plain brightness
#: ladder: dawn and dusk are dim but WARM, midday is bright and cool, midnight is the
#: deepest and coolest. That is what makes them read as times rather than as five greys.
#:
#: Every ramp is swept in tests/test_theme_ramps.py for AA on text and muted text; a
#: ramp whose own text failed would poison every preset rendered on it.
RAMPS: Dict[str, Dict[str, str]] = {
    # the shipped dark shell — NO override, so byte-identical to the original "dark".
    "dark": {},
    "light": _LIGHT_NEUTRALS,
    # first light: dim, cool, faintly violet.
    "dawn": {
        "--sd-bg-0": "#14121f", "--sd-bg-1": "#1c1930", "--sd-bg-2": "#252140",
        "--sd-border": "#2e2a4a", "--sd-text": "#e6e2f5", "--sd-text-muted": "#a9a3c6",
    },
    # full daylight: brightest and coolest of the light ramps.
    "morning": {
        "--sd-bg-0": "#fbfcff", "--sd-bg-1": "#f0f3fa", "--sd-bg-2": "#e3e8f4",
        "--sd-border": "#c6cee0", "--sd-text": "#16192a", "--sd-text-muted": "#454c6b",
        "--sd-surface": "#ffffff", "--sd-charcoal": "#f2f4f8",
        "--sd-muted": "#5a5a5a", "--sd-light": "#3a3a3a", "--sd-offwhite": "#141414",
        "--sd-mid": "#c4c4c4",
    },
    # warm afternoon light — paper rather than screen.
    "afternoon": {
        "--sd-bg-0": "#fdfaf4", "--sd-bg-1": "#f6f0e4", "--sd-bg-2": "#ece4d3",
        "--sd-border": "#d8cdb6", "--sd-text": "#241d12", "--sd-text-muted": "#5a4c35",
        "--sd-surface": "#fffdf8", "--sd-charcoal": "#f4efe4",
        "--sd-muted": "#5a5245", "--sd-light": "#3a352c", "--sd-offwhite": "#141210",
        "--sd-mid": "#c9bfa8",
    },
    # golden hour: dim and amber, the warmest dark ramp.
    "dusk": {
        "--sd-bg-0": "#1a1410", "--sd-bg-1": "#241b14", "--sd-bg-2": "#30241a",
        "--sd-border": "#3d2e21", "--sd-text": "#f5e8db", "--sd-text-muted": "#c2a98f",
    },
    # after sundown: neutral-warm, darker than dusk.
    "evening": {
        "--sd-bg-0": "#12100f", "--sd-bg-1": "#1a1817", "--sd-bg-2": "#242120",
        "--sd-border": "#2f2b29", "--sd-text": "#ece7e3", "--sd-text-muted": "#b0a8a2",
    },
    # deepest and coolest — near-black with a blue cast, for a dark room.
    "midnight": {
        "--sd-bg-0": "#05060c", "--sd-bg-1": "#0a0c16", "--sd-bg-2": "#111423",
        "--sd-border": "#1a1e30", "--sd-text": "#dfe4f2", "--sd-text-muted": "#98a0bb",
    },
}

MODES: Tuple[str, ...] = tuple(RAMPS)


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

    # ── DESKTOP SCHEMES ──────────────────────────────────────────────────────
    # Operator ask 2026-08-14: "color themes covering usual desktop theme color
    # combinations". These are the palettes people already have in their editor and
    # terminal, so the mesh can be made to match the rest of a desk rather than
    # standing out from it.
    #
    # Each carries its scheme's ACCENT RAMP as `stripes`, which the extended palette
    # then turns into readable roles + panes + a background wash — the same machinery
    # the flags use, and the reason these are richer than a primary/secondary pair.
    # Values are each project's published palette; all are permissively licensed
    # (Solarized/Nord/Dracula/Gruvbox/Catppuccin: MIT or equivalent) and a colour list
    # is not the licensable part of any of them.
    _p("solarized", "Solarized", "Desktop", "#268bd2", "#2aa198",
       ("#b58900", "#cb4b16", "#dc322f", "#d33682", "#6c71c4", "#268bd2",
        "#2aa198", "#859900"),
       note="Ethan Schoonover's Solarized accent ramp. Pairs with any ramp."),
    _p("nord", "Nord", "Desktop", "#88c0d0", "#81a1c1",
       ("#bf616a", "#d08770", "#ebcb8b", "#a3be8c", "#b48ead", "#8fbcbb",
        "#88c0d0", "#5e81ac"),
       note="Arctic, bluish and low-saturation."),
    _p("dracula", "Dracula", "Desktop", "#bd93f9", "#ff79c6",
       ("#8be9fd", "#50fa7b", "#ffb86c", "#ff79c6", "#bd93f9", "#ff5555",
        "#f1fa8c"),
       note="High-contrast purples and pinks on near-black."),
    _p("gruvbox", "Gruvbox", "Desktop", "#d79921", "#98971a",
       ("#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a",
        "#d65d0e"),
       note="Warm, retro and deliberately low-blue."),
    _p("monokai", "Monokai", "Desktop", "#a6e22e", "#f92672",
       ("#f92672", "#a6e22e", "#fd971f", "#66d9ef", "#ae81ff", "#e6db74"),
       note="The classic editor scheme — saturated on charcoal."),
    _p("one-dark", "One Dark", "Desktop", "#61afef", "#c678dd",
       ("#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2"),
       note="Atom's One Dark; the most familiar modern editor palette."),
    _p("tokyo-night", "Tokyo Night", "Desktop", "#7aa2f7", "#bb9af7",
       ("#f7768e", "#e0af68", "#9ece6a", "#7dcfff", "#7aa2f7", "#bb9af7"),
       note="Cool neon blues and violets."),
    _p("catppuccin", "Catppuccin", "Desktop", "#cba6f7", "#89b4fa",
       ("#f38ba8", "#fab387", "#a6e3a1", "#94e2d5", "#89b4fa", "#cba6f7",
        "#f5c2e7"),
       note="Soft pastels; the gentlest of the desktop sets."),
    _p("everforest", "Everforest", "Desktop", "#a7c080", "#83c092",
       ("#e67e80", "#dbbc7f", "#a7c080", "#83c092", "#7fbbb3", "#d699b6"),
       note="Muted greens — easy on the eyes for long sessions."),
    _p("rose-pine", "Rosé Pine", "Desktop", "#c4a7e7", "#ebbcba",
       ("#eb6f92", "#f6c177", "#ebbcba", "#31748f", "#9ccfd8", "#c4a7e7"),
       note="Muted rose and pine; soho-vibes."),
    _p("sepia", "Sepia", "Desktop", "#8b5a2b", "#a0522d",
       ("#8b5a2b", "#a0522d", "#6b4423", "#c19a6b", "#7a6a53"),
       note="Paper-like warmth; best on the afternoon ramp."),
    _p("high-contrast", "High contrast", "Desktop", "#ffff00", "#00ffff",
       ("#ffff00", "#00ffff", "#ff00ff", "#ffffff", "#00ff00"),
       note="Maximum separation for low-vision use."),
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


def _is_light(bg: str) -> bool:
    """Is this ramp's background LIGHT — i.e. does black read better on it than white?

    The one property every ramp-dependent derivation actually turns on. Using this
    rather than the ramp's NAME is what lets a new time-of-day be added as data."""
    return theme.contrast_ratio("#000000", bg) > theme.contrast_ratio("#ffffff", bg)


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
    # THE FLAG IS ALREADY AN 8-COLOUR PALETTE. The operator asked for themes built on up
    # to 8 base colours beyond primary/secondary; every flag preset here has carried 3-8
    # of them since the presets landed, and until now they were used ONLY as a decorative
    # stripe gradient. Feeding p.stripes in as the palette is what turns the colours a
    # preset already declares into working surface/pane/gradient tokens — no new colour
    # is invented, which is the same rule the stripe gradient follows (never approximate
    # someone's flag).
    #
    # The palette is derived LAST, after the mode's neutrals are settled, because it is
    # a function of BOTH the background and the body-text colour — and on the light ramp
    # both change. Deriving it inside the base call would rank and tint every colour
    # against the DARK shell's bg/text and then have the light neutrals land on top,
    # giving a light theme panes computed for a dark one.
    tokens = theme.derive(p.primary, p.secondary)
    ramp = RAMPS.get(mode) or {}
    if ramp:
        tokens.update(ramp)
    # MEASURE the ramp instead of testing `mode == "light"`. With eight ramps and more
    # to come, a name test would silently give every new LIGHT ramp the dark ramp's
    # lighten-only derivation — i.e. white-on-white accent text. Luminance is the actual
    # property the derivation depends on, so this is correct for any ramp ever added.
    light_ramp = _is_light(tokens["--sd-bg-0"])
    # RE-DERIVE THE ACCENT TEXT FOR **EVERY** RAMP, not just the light one.
    # theme.derive() solves --sd-accent-soft against the fixed default shell (#0a0a12).
    # Any ramp with a LIGHTER background than that — dusk, evening, dawn — leaves the
    # pre-derived value short: measured crimson/dusk at 4.16:1, i.e. below AA, on a ramp
    # that looks perfectly reasonable. Only "dark" is the bg it was solved against, so
    # only "dark" may keep it unchanged.
    tokens["--sd-accent-soft"] = (
        _soft_for_text_on_light(p.secondary, tokens["--sd-bg-0"]) if light_ramp
        else theme.soft_for_text(p.secondary, tokens["--sd-bg-0"]))
    if p.stripes:
        bg = tokens["--sd-bg-0"]
        tokens.update(theme.palette_tokens(
            p.stripes, bg=bg, text=tokens["--sd-text"]))
        if light_ramp:
            # Same lighten-only trap as --sd-accent-soft, for every palette colour used
            # AS TEXT: on a near-white page each -soft would have run to #ffffff.
            for key in [k for k in tokens if k.startswith("--sd-palette-")
                        and k.endswith("-soft")]:
                tokens[key] = _soft_for_text_on_light(
                    tokens[key.removesuffix("-soft")], bg)
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
