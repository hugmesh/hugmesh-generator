"""Login-theme derivation — the SINGLE source of truth for turning an operator's
primary/secondary brand colours into the full ``--sd-*`` custom-property contract the
Angular login-ui renders from.

Qt-free by convention (BESIDE PLATFORM_FIELD_SUPPORT, like the rest of core/): this
module does NO GUI and NO I/O, so the Studio token board, the Studio browser preview
writer, the ``scripts/tooling/derive-theme.py`` render-time CLI and the golden test
that pins the shipped SCSS defaults all import the SAME ``derive()`` — there is exactly
one implementation of the colour maths. A second implementation (a shell/JS re-derive at
render time) is the bug that makes the preview start lying, so the entrypoint does ZERO
colour maths: it interpolates already-derived token TEXT.

DERIVATION, measured from the shipped triple rather than invented
(login-ui src/styles/_tokens.scss:9-11):
    $neon        #ffd700 = HSL(50.6, 100%, L50)
    $neon-bright #ffe566 = L70
    $neon-dim    #cc9900 = L40
so the intended rule is "preserve H+S, move L". We use a RELATIVE rule so it cannot
flat-clamp at extreme lightness:  bright = L + 40%*(100-L);  dim = L - 20%*L.
At L=50 that reproduces the L70/L40 LIGHTNESS exactly; the bytes can still differ by a
hue-quantisation step (bright(#ffd700)=#ffe766 vs the hand-picked #ffe566) — one more
reason the unbranded default triple below stays LITERAL rather than derived.

CONTRAST is two DIFFERENT sub-problems and both are solved by CONSTRUCTION, so the
operator's colour is NEVER used anywhere its contrast could fail (see design notes):

  (1) text ON a filled accent button  -> ``*-on`` auto-picks pure #000000 / #ffffff by
      luminance. Swept over the whole sRGB cube the worst case with pure black/white is
      4.583:1 -> AA guaranteed for EVERY colour in sRGB. (The palette's near-black/near-
      white greys drop to 4.031:1, which FAILS — hence pure, not the brand greys.)

  (2) the accent AS TEXT on the dark shell -> ``*-soft`` lightens the exact hex toward
      white until it clears 4.5:1 against ``--sd-bg-0`` (#0a0a12). White on #0a0a12 is
      ~18:1, so by continuity a solution always exists -> never blocks. This generalises
      the decision the codebase already made by hand (styles.scss:29-30: --sd-accent is
      "backgrounds/borders only", --sd-accent-soft is "use this for accent text").

The operator's EXACT hex is kept in ``--sd-primary`` / ``--sd-secondary`` and used only
decoratively (borders, backgrounds, glow); it is never the text colour.
"""
from __future__ import annotations

import re

# The shell background the accent-as-text contrast is solved against. FIXED: derivation
# is against the shipped DARK shell; a light-shell variant would need re-derivation.
SHELL_BG = "#0a0a12"

# The unbranded default triple, kept LITERAL (not derived): derive() cannot reproduce the
# hand-tuned $neon-dim (#cc9900 drifted HUE 50.6->45.0, which no H-preserving rule
# reproduces), so the default theme keeps the shipped bytes and derive() is used ONLY when
# the operator supplies a colour. golden-pinned in tests/test_theme.py.
_DEFAULT_PRIMARY = "#ffd700"
_DEFAULT_PRIMARY_BRIGHT = "#ffe566"
_DEFAULT_PRIMARY_DIM = "#cc9900"
_DEFAULT_SECONDARY = "#7c4dff"        # the existing --sd-accent
_DEFAULT_SECONDARY_SOFT = "#b388ff"   # the existing --sd-accent-soft (AAA accent text)

# Neutral ramp + states — FIXED, never re-derived from a brand hue (re-deriving greys from
# a hue is how a palette turns muddy). Mirrors login-ui src/styles.scss:23-32 + the
# _tokens.scss neutral ramp that the migrated mixins/skip-link now reach as vars.
_NEUTRALS: dict[str, str] = {
    "--sd-bg-0": "#0a0a12",
    "--sd-bg-1": "#12121e",
    "--sd-bg-2": "#1a1a2e",
    "--sd-border": "#1e1e32",
    "--sd-text": "#e8e8f0",
    "--sd-text-muted": "#a8acc4",
    "--sd-success": "#4caf50",
    "--sd-error": "#ff6b6b",
    # legacy _tokens.scss neutrals, now reachable as vars by the migrated SCSS residue.
    "--sd-black": "#0a0a0a",
    "--sd-charcoal": "#111111",
    "--sd-surface": "#1c1c1c",
    "--sd-mid": "#3a3a3a",
    "--sd-muted": "#777777",
    "--sd-light": "#bbbbbb",
    "--sd-offwhite": "#e8e8e8",
    # channel triples for the neutrals composed inside rgba() by the migrated mixins —
    # `rgba(var(--x), a)` needs comma-separated channels, NOT a hex (a silent drop
    # otherwise; see design notes / _mixins.scss).
    "--sd-charcoal-rgb": "17,17,17",
    "--sd-surface-rgb": "28,28,28",
    "--sd-mid-rgb": "58,58,58",
}

HEX_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")


# ── colour maths (pure) ─────────────────────────────────────────────────────────────
def _parse(hex_str: str) -> tuple[int, int, int]:
    h = hex_str.strip()
    if not HEX_RE.match(h):
        raise ValueError(f"not an #RRGGBB hex colour: {hex_str!r}")
    return int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16)


def _fmt(rgb: tuple[float, float, float]) -> str:
    return "#" + "".join(f"{max(0, min(255, round(c))):02x}" for c in rgb)


def _rgb_to_hsl(r: int, g: int, b: int) -> tuple[float, float, float]:
    rf, gf, bf = r / 255.0, g / 255.0, b / 255.0
    mx, mn = max(rf, gf, bf), min(rf, gf, bf)
    l = (mx + mn) / 2.0
    d = mx - mn
    if d == 0:
        return 0.0, 0.0, l
    s = d / (1 - abs(2 * l - 1))
    if mx == rf:
        h = ((gf - bf) / d) % 6
    elif mx == gf:
        h = (bf - rf) / d + 2
    else:
        h = (rf - gf) / d + 4
    return h * 60.0, s, l


def _hsl_to_rgb(h: float, s: float, l: float) -> tuple[float, float, float]:
    c = (1 - abs(2 * l - 1)) * s
    hp = (h % 360) / 60.0
    x = c * (1 - abs(hp % 2 - 1))
    if hp < 1:
        r, g, b = c, x, 0.0
    elif hp < 2:
        r, g, b = x, c, 0.0
    elif hp < 3:
        r, g, b = 0.0, c, x
    elif hp < 4:
        r, g, b = 0.0, x, c
    elif hp < 5:
        r, g, b = x, 0.0, c
    else:
        r, g, b = c, 0.0, x
    m = l - c / 2.0
    return (r + m) * 255.0, (g + m) * 255.0, (b + m) * 255.0


def _rel_luminance(r: int, g: int, b: int) -> float:
    def lin(c: float) -> float:
        c /= 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def contrast_ratio(fg: str, bg: str) -> float:
    """WCAG 2.x contrast ratio between two #RRGGBB colours (>= 1.0)."""
    l1 = _rel_luminance(*_parse(fg))
    l2 = _rel_luminance(*_parse(bg))
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


def _lightness(hex_str: str) -> float:
    return _rgb_to_hsl(*_parse(hex_str))[2]


def _move_l(hex_str: str, new_l: float) -> str:
    h, s, _ = _rgb_to_hsl(*_parse(hex_str))
    return _fmt(_hsl_to_rgb(h, s, max(0.0, min(1.0, new_l))))


def _bright(hex_str: str) -> str:
    l = _lightness(hex_str)
    return _move_l(hex_str, l + 0.40 * (1.0 - l))


def _dim(hex_str: str) -> str:
    l = _lightness(hex_str)
    return _move_l(hex_str, l - 0.20 * l)


def on_color(accent_hex: str) -> str:
    """Pure #000000 or #ffffff for text sitting ON a filled ``accent_hex`` — whichever
    yields higher contrast. Pure (not the brand greys) makes AA unconditional for any
    sRGB colour (worst case 4.583:1)."""
    return "#000000" if contrast_ratio("#000000", accent_hex) >= contrast_ratio("#ffffff", accent_hex) else "#ffffff"


def soft_for_text(accent_hex: str, bg: str = SHELL_BG, target: float = 4.5) -> str:
    """Lighten ``accent_hex`` toward white until it clears ``target`` contrast against
    ``bg`` — the only accent-as-text token. Always solvable on the dark shell (white on
    #0a0a12 ~18:1), so it never blocks. Returns the exact hex when it already passes."""
    r0, g0, b0 = _parse(accent_hex)
    # 256 steps of a straight RGB lerp toward white is finer than 1/255 per channel, so
    # the first passing step is effectively the minimal lift.
    for i in range(0, 257):
        t = i / 256.0
        cand = _fmt((r0 + (255 - r0) * t, g0 + (255 - g0) * t, b0 + (255 - b0) * t))
        if contrast_ratio(cand, bg) >= target:
            return cand
    return "#ffffff"


def _rgb_triple(hex_str: str) -> str:
    r, g, b = _parse(hex_str)
    return f"{r},{g},{b}"


def _color_distance(a: str, b: str) -> float:
    ra, ga, ba = _parse(a)
    rb, gb, bb = _parse(b)
    return ((ra - rb) ** 2 + (ga - gb) ** 2 + (ba - bb) ** 2) ** 0.5


# ── the contract ────────────────────────────────────────────────────────────────────
def _brand_tokens(prefix: str, hex_str: str, *, dim_override: str | None = None,
                   bright_override: str | None = None, soft_override: str | None = None) -> dict[str, str]:
    bright = bright_override or _bright(hex_str)
    dim = dim_override or _dim(hex_str)
    soft = soft_override or soft_for_text(hex_str)
    return {
        f"--sd-{prefix}": hex_str,
        f"--sd-{prefix}-bright": bright,
        f"--sd-{prefix}-dim": dim,
        f"--sd-{prefix}-soft": soft,
        f"--sd-{prefix}-on": on_color(hex_str),
        f"--sd-{prefix}-rgb": _rgb_triple(hex_str),
    }


def derive(primary: str, secondary: str = "") -> dict[str, str]:
    """Full ``--sd-*`` token map for an operator's (primary, secondary) brand colours.

    Raises ValueError on malformed input (the only BLOCK — reuses the #RRGGBB shape the
    root-sourced brand.conf already requires). Legibility is guaranteed by construction,
    so no colour is ever rejected for contrast. ``secondary`` defaults to the shipped
    accent (#7c4dff) when blank, so a primary-only call is still complete."""
    primary = primary.strip()
    secondary = (secondary or _DEFAULT_SECONDARY).strip()
    _parse(primary)      # raises on malformed
    _parse(secondary)

    tokens: dict[str, str] = {}
    tokens.update(_NEUTRALS)
    tokens.update(_brand_tokens("primary", primary))
    tokens.update(_brand_tokens("secondary", secondary))
    # --sd-accent/-accent-soft are the pre-existing accent-text contract; secondary drives
    # them (design: secondary => links / focus / secondary actions / accent-soft).
    tokens["--sd-accent"] = secondary
    tokens["--sd-accent-soft"] = soft_for_text(secondary)
    return tokens


def default_tokens() -> dict[str, str]:
    """The UNBRANDED default token map — the LITERAL shipped triple (not derived), so the
    fallback :root and _tokens.scss stay byte-identical. Every value here is pinned to the
    shipped SCSS by tests/test_theme.py."""
    tokens: dict[str, str] = {}
    tokens.update(_NEUTRALS)
    tokens.update(_brand_tokens(
        "primary", _DEFAULT_PRIMARY,
        bright_override=_DEFAULT_PRIMARY_BRIGHT, dim_override=_DEFAULT_PRIMARY_DIM))
    tokens.update(_brand_tokens(
        "secondary", _DEFAULT_SECONDARY, soft_override=_DEFAULT_SECONDARY_SOFT))
    tokens["--sd-accent"] = _DEFAULT_SECONDARY
    tokens["--sd-accent-soft"] = _DEFAULT_SECONDARY_SOFT
    return tokens


# Font-family CSS values are appended to the token map by the caller (fonts.py), so the
# colour and font halves ride the SAME single :root pipeline.


def css_root(tokens: dict[str, str], *, font_faces: str = "") -> str:
    """The full ``snap-theme.css`` text: optional ``@font-face`` blocks, then ONE
    ``:root:root { ... }`` rule holding every token.

    ``:root:root`` is deliberate: snap-theme.css is <link>ed from index.html SOURCE,
    and Angular's build-time styles link can land AFTER it in <head> — with equal
    specificity the later sheet's plain ``:root`` fallback would win and the injected
    theme would be a silent no-op. Doubling the selector ((0,2,0) beats (0,1,0)) makes
    the theme win regardless of link order, without ``!important`` and while staying
    overridable by anything more specific than a root default should be.

    Emits token TEXT only (the entrypoint interpolates it verbatim, zero colour maths),
    so every value must already be a literal — a ``var(`` in a value means a consumer
    re-derived something and is raised as a build bug, not shipped as a broken theme.
    """
    lines = [":root:root {"]
    for name, value in tokens.items():
        if "var(" in value:
            raise ValueError(f"token {name} is not a literal: {value!r}")
        lines.append(f"  {name}: {value};")
    lines.append("}")
    body = "\n".join(lines) + "\n"
    if font_faces.strip():
        return font_faces.rstrip() + "\n\n" + body
    return body


def compose_login_css(primary: str = "", secondary: str = "", *, font_preset: str = "",
                      font_family: str = "", font_bytes: bytes = b"") -> str:
    """The complete snap-theme.css text for an operator's choices, or "" when nothing
    was chosen (no injection at all — the shipped default renders byte-identically).

    The ONE composition point shared by the Studio GUI, the bootstrap CLI and
    scripts/tooling/derive-theme.py, so colour derivation, font resolution and css
    emission cannot drift between entrypoints. ``font_preset`` is a fonts.FONT_PRESETS
    NAME (fail-closed on typos, mirroring config validation); ``font_bytes`` is an
    uploaded face (already gate-checked) embedded as a data: URI with
    ``font_family`` as its canonical family name."""
    from . import fonts as _fonts   # caller-side per the module contract above

    primary = primary.strip()
    secondary = secondary.strip()
    font_preset = font_preset.strip()
    if not (primary or secondary or font_preset or font_bytes):
        return ""
    if primary or secondary:
        tokens = derive(primary or _DEFAULT_PRIMARY, secondary)
    else:
        # font-only theming still emits the full default colour map: identical values
        # to the compiled fallback, and the css stays self-contained either way.
        tokens = default_tokens()
    faces = ""
    if font_preset and font_preset not in _fonts.FONT_PRESETS:
        raise ValueError(f"unknown font preset: {font_preset!r} — "
                         f"known: {', '.join(_fonts.FONT_PRESETS)}")
    if font_bytes:
        family = font_family.strip() or "Snapdragon Brand Font"
        faces = _fonts.font_face_css(family, font_bytes)
        tokens.update(_fonts.font_tokens(
            _fonts.FONT_PRESETS.get(font_preset, ""), uploaded_family=family))
    elif font_preset:
        tokens.update(_fonts.font_tokens(_fonts.FONT_PRESETS[font_preset]))
    return css_root(tokens, font_faces=faces)


def warnings(primary: str, secondary: str = "") -> list[str]:
    """Non-blocking legibility WARNINGS (per #387: warn where it still renders, block only
    malformed). Never raises for a well-formed colour; never blocks."""
    out: list[str] = []
    primary = primary.strip()
    secondary = (secondary or _DEFAULT_SECONDARY).strip()
    if not HEX_RE.match(primary) or not HEX_RE.match(secondary):
        return out   # malformed is a BLOCK handled by validation, not a warning
    if _color_distance(primary, secondary) < 40.0:
        out.append("primary and secondary are very close — they will be hard to tell "
                   "apart, though both still render.")
    if _color_distance(primary, SHELL_BG) < 40.0:
        out.append("primary is nearly the shell background — borders/glow drawn in it "
                   "will be almost invisible on the dark login page.")
    soft = soft_for_text(primary)
    if _color_distance(soft, primary) > 120.0:
        out.append("primary is dark, so as TEXT it is lightened a lot to stay legible — "
                   "your accent-as-text (links/labels) will read paler than the swatch.")
    return out
