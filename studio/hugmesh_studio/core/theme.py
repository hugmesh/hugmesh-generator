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
from collections.abc import Sequence

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


# ...and the SAME hazard for every other neutral, which was missed. The three triples
# above were added for the mixins that compose neutrals inside rgba(); the SEMANTIC
# colours never got theirs, and consumers wrote `rgba(var(--hug-success), .4)` anyway.
# That is invalid CSS -- rgba() needs channels, not a hex -- so the browser DROPS the
# whole declaration silently. Five live examples in hugmesh-matrix-ui alone
# (composer.component.scss:74,207,213 and role-actions.component.scss:60,66) render with
# no border at all today.
#
# Generated rather than hand-listed so a neutral added above cannot arrive without its
# twin: the class of bug this fixes is precisely "the token existed but its -rgb did not".
_NEUTRALS.update({
    f"{name}-rgb": ",".join(str(c) for c in _parse(value))
    for name, value in list(_NEUTRALS.items())
    if HEX_RE.match(value) and f"{name}-rgb" not in _NEUTRALS
})


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


# ── the EXTENDED PALETTE (up to 8 colours beyond primary/secondary) ──────────────────
#: Operator ask, 2026-08-14: "themes should support varieties of colors that use up to 8
#: colors as the base in addition to primary and secondary", and then the shaping rule —
#: "keep the first best colors for readability and work the other full spectrum of colors
#: into gradients on backgrounds and having various backpanes of router outlets /
#: encapsulated web components use those alternate colors instead in whole or combination
#: as readability would be improved".
#:
#: That is two jobs for one list, and the split is made HERE rather than left to each UI:
#: a colour either contrasts well enough against the surface to carry meaning as
#: foreground, or it does not and belongs in a background wash. Sorting by measured
#: contrast is what "the first best colors for readability" means operationally.
MAX_PALETTE = 8

#: Floor for a palette colour to be treated as FOREGROUND-capable as-is. 3:1 is the
#: WCAG AA line for large text and UI components (not the 4.5:1 body-text line) because
#: these drive borders, icons and headings; anything used as BODY text goes through
#: soft_for_text() and is lifted to 4.5:1 regardless.
_PALETTE_FG_MIN = 3.0

#: Hard ceiling on a backpane's tint. Even when the maths says a heavier wash would keep
#: body text legible, a pane that saturated stops reading as a surface and starts
#: reading as a filled block, which fights the content it is meant to sit behind.
_PANE_MAX_ALPHA = 0.22


def _mix(fg: str, bg: str, alpha: float) -> str:
    """Composite ``fg`` over ``bg`` at ``alpha`` — the same result the browser produces
    for ``rgba(fg, alpha)`` on an opaque ``bg``. Computed here, and emitted as a LITERAL,
    because css_root refuses non-literal tokens: the entrypoint interpolates token text
    verbatim and does no colour maths."""
    fr, fg_, fb = _parse(fg)
    br, bg_, bb = _parse(bg)
    return _fmt((br + (fr - br) * alpha,
                 bg_ + (fg_ - bg_) * alpha,
                 bb + (fb - bb) * alpha))


def pane_surface(color: str, bg: str, text: str, *, target: float = 4.5,
                 max_alpha: float = _PANE_MAX_ALPHA) -> str:
    """The STRONGEST tint of ``color`` over ``bg`` that still keeps ``text`` legible.

    This is the "readability would be improved" clause taken literally. A backpane exists
    to tell one router outlet apart from another, so it wants as much colour as it can
    carry — but the body text on top has to keep clearing ``target``. Rather than pick a
    timid fixed alpha and hope, walk the alpha down from ``max_alpha`` and return the
    first composite that still passes. Fails SAFE: if even the faintest tint would break
    contrast, return ``bg`` unchanged, i.e. no pane tint rather than an illegible one.
    """
    steps = 22
    for i in range(steps, -1, -1):
        alpha = max_alpha * (i / steps)
        cand = _mix(color, bg, alpha)
        if contrast_ratio(text, cand) >= target:
            return cand
    return bg


def rank_for_readability(colors: Sequence[str], bg: str) -> list[str]:
    """``colors`` ordered best-contrast-first against ``bg``, duplicates dropped.

    Ties keep declaration order, which matters for the flag presets: a flag's stripes
    arrive top-to-bottom and two stripes can measure identically, so a stable sort keeps
    the flag's own reading order instead of shuffling it arbitrarily."""
    seen: set[str] = set()
    uniq: list[str] = []
    for c in colors:
        key = c.strip().lower()
        if not key or key in seen:
            continue
        _parse(c)                      # raises on malformed, same contract as derive()
        seen.add(key)
        uniq.append(c.strip())
    return sorted(uniq, key=lambda c: -contrast_ratio(c, bg))


def palette_tokens(colors: Sequence[str], *, bg: str = SHELL_BG,
                   text: str = "", prefix: str = "palette") -> dict[str, str]:
    """Tokens for the extended palette: ranked colours, per-colour text-safe variants,
    per-index BACKPANE surfaces, and one background gradient built from the leftovers.

    Emitted per colour ``i`` (1-based, at most :data:`MAX_PALETTE`):
      ``--sd-palette-i``        the colour verbatim
      ``--sd-palette-i-on``     black/white for text sitting ON a filled swatch
      ``--sd-palette-i-soft``   the colour lifted until it clears 4.5:1 AS text on ``bg``
      ``--sd-palette-i-rgb``    channel triple, for consumers that need their own alpha
      ``--sd-pane-i-bg``        a backpane surface (see :func:`pane_surface`)
      ``--sd-pane-i-border``    a heavier tint of the same hue, for the pane's edge

    Plus ``--sd-palette-count`` so a consumer can cycle panes without hardcoding 8, and
    ``--sd-bg-gradient`` / ``--sd-bg-gradient-soft``.

    THE GRADIENT USES THE LEFTOVERS ON PURPOSE. The operator asked for the best colours
    to stay readable and "the other full spectrum" to go into background gradients, so
    the wash is built from the colours that ranked BELOW :data:`_PALETTE_FG_MIN` — the
    ones that would have made poor foregrounds anyway. When every colour ranks as
    foreground-capable (a bright flag on a dark shell), the gradient falls back to the
    full ranked list rather than emitting nothing, because an absent token would leave
    consumers with a visible hole where a background should be.
    """
    text = text or _NEUTRALS.get("--sd-text", "#ffffff")
    ranked = rank_for_readability(colors, bg)[:MAX_PALETTE]
    tokens: dict[str, str] = {}
    if not ranked:
        return tokens

    for i, color in enumerate(ranked, start=1):
        tokens[f"--sd-{prefix}-{i}"] = color
        tokens[f"--sd-{prefix}-{i}-on"] = on_color(color)
        tokens[f"--sd-{prefix}-{i}-soft"] = soft_for_text(color, bg)
        tokens[f"--sd-{prefix}-{i}-rgb"] = _rgb_triple(color)
        tokens[f"--sd-pane-{i}-bg"] = pane_surface(color, bg, text)
        # The border may sit heavier than the surface: nothing reads text ON a 1px edge,
        # so it only needs to be distinguishable from the pane it outlines.
        tokens[f"--sd-pane-{i}-border"] = _mix(color, bg, 0.42)
    tokens[f"--sd-{prefix}-count"] = str(len(ranked))

    decorative = [c for c in ranked if contrast_ratio(c, bg) < _PALETTE_FG_MIN]
    wash = decorative or ranked
    tokens["--sd-bg-gradient"] = _linear_gradient(
        [_mix(c, bg, 0.30) for c in wash], bg)
    tokens["--sd-bg-gradient-soft"] = _linear_gradient(
        [_mix(c, bg, 0.12) for c in wash], bg)
    return tokens


def _linear_gradient(stops: Sequence[str], bg: str) -> str:
    """A smooth 135° wash across ``stops``. One stop still has to be a gradient (a bare
    colour would break any consumer that assigns this to ``background-image``), so it is
    blended back to ``bg`` to stay a real two-stop ramp."""
    if not stops:
        return f"linear-gradient(135deg, {bg} 0%, {bg} 100%)"
    if len(stops) == 1:
        return f"linear-gradient(135deg, {stops[0]} 0%, {bg} 100%)"
    span = len(stops) - 1
    parts = [f"{c} {round(i * 100 / span)}%" for i, c in enumerate(stops)]
    return f"linear-gradient(135deg, {', '.join(parts)})"


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


def derive(primary: str, secondary: str = "",
           palette: Sequence[str] = (), *, bg: str = "") -> dict[str, str]:
    """Full ``--sd-*`` token map for an operator's (primary, secondary) brand colours,
    plus an OPTIONAL extended ``palette`` of up to :data:`MAX_PALETTE` further colours.

    Raises ValueError on malformed input (the only BLOCK — reuses the #RRGGBB shape the
    root-sourced brand.conf already requires). Legibility is guaranteed by construction,
    so no colour is ever rejected for contrast. ``secondary`` defaults to the shipped
    accent (#7c4dff) when blank, so a primary-only call is still complete.

    ``palette`` is ADDITIVE and defaults to empty, so every existing caller keeps its
    exact previous token map — the extended palette can only add tokens, never move an
    existing one. ``bg`` overrides the surface the palette is ranked and tinted against;
    it defaults to this map's own ``--sd-bg-0`` so a light ramp ranks against the light
    surface rather than the dark shell (ranking against the wrong surface would invert
    the whole readability order)."""
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
    # TEXT ON A FILLED ACCENT, which was missing and is why the UIs all hardcode white.
    #
    # This module's own contract promises that a "*-on" twin auto-picks #000/#fff by
    # luminance so AA is guaranteed for every sRGB colour -- and it delivered that for
    # --sd-primary-on and --sd-secondary-on while never emitting one for --sd-accent, the
    # token the UIs actually use as a button background. With no token to reach for, a
    # dozen components hardcoded `color: #fff`, and MEASURED against the shipped presets
    # that fails AA on 24 of 38: white on the nonbinary flag's #fcf434 is 1.16:1, on
    # high-contrast's #00ffff 1.25:1 -- effectively invisible.
    #
    # No new maths: --sd-accent IS secondary, so the correct value is the one already
    # computed for --sd-secondary-on. This only stops throwing it away.
    tokens["--sd-accent-on"] = on_color(secondary)
    if palette:
        tokens.update(palette_tokens(
            palette,
            bg=bg or tokens.get("--sd-bg-0", SHELL_BG),
            text=tokens.get("--sd-text", "#ffffff")))
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
    tokens["--sd-accent-on"] = on_color(_DEFAULT_SECONDARY)
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
        # RUNTIME-CONTRACT BRIDGE: the fleet's UIs consume --hug-* (the rebrand
        # renamed the cross-repo contract — login-ui styles.scss calls --hug-*
        # "the cross-repo HugMesh contract any remote can reach for"), while this
        # module's internal names stayed --sd-*. Before this duplication the
        # emitted theme was a SILENT NO-OP everywhere: the css was served,
        # measured, and consumed by nothing — the deepest root of "my theme
        # choices are not applied". Every --sd-* token is therefore emitted a
        # second time under its --hug-* twin (same literal), unless the map
        # already carries that twin explicitly. Internal names stay --sd-* so
        # the Studio's token board, tests and derivation pins are untouched.
        if name.startswith("--sd-"):
            twin = "--hug-" + name[len("--sd-"):]
            if twin not in tokens:
                lines.append(f"  {twin}: {value};")
    # BOOTSTRAP BRIDGE: emitted LAST so an explicit --bs-* already in the map wins.
    # Bootstrap 5.3 reads these at runtime, so overriding them in this same :root
    # restyles every Bootstrap component the fleet already ships — buttons, alerts,
    # cards, form controls, tables — with no per-repo SCSS work at all.
    for name, value in bootstrap_tokens(tokens).items():
        if name not in tokens:
            lines.append(f"  {name}: {value};")
    lines.append("}")
    body = "\n".join(lines) + "\n"
    if font_faces.strip():
        return font_faces.rstrip() + "\n\n" + body
    return body


# Appended by compose_login_css whenever a FONT was chosen. Form controls do NOT
# inherit font-family — every UA styles input/button/select/textarea with its own
# default — and neither the login-ui build nor the theme tokens set one on them, so a
# chosen font changed the headings and labels while the username/password inputs and
# the "Sign in" button stayed on the UA default (issue #225, measured in chromium:
# body ui-monospace, inputs "Arial"). One weakest-specificity rule ((0,0,1) +
# ``inherit``) fixes every consumer of this css without overriding any UI's own,
# more specific font choice.
FORM_FONT_RESET = "input, button, select, textarea { font-family: inherit; }\n"


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
        family = font_family.strip() or "HugMesh Brand Font"
        faces = _fonts.font_face_css(family, font_bytes)
        tokens.update(_fonts.font_tokens(
            _fonts.FONT_PRESETS.get(font_preset, ""), uploaded_family=family))
    elif font_preset:
        tokens.update(_fonts.font_tokens(_fonts.FONT_PRESETS[font_preset]))
    css = css_root(tokens, font_faces=faces)
    if font_preset or font_bytes:
        # A colour-only theme appends nothing (no font changed, and the emitted
        # bytes stay identical for existing colour-only configs).
        css += FORM_FONT_RESET
    return css


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


# ── the STYLE axis: borders, radii and surfaces, ON TOP of any colour choice ────────
#: Operator ask, 2026-08-14: "try to include more possible options and themes possible
#: through bootstrap with different styles on top of different colors and borders etc".
#:
#: Deliberately ORTHOGONAL to colour. A style says how surfaces are SHAPED — corner
#: radius, border weight, elevation — and never what colour they are, so any of these
#: composes with any palette or preset instead of multiplying into a combinatorial list
#: of "blue-rounded", "blue-square", "pink-rounded"... Six styles x 26 presets x 2 ramps
#: is 312 themes from 34 declarations.
#:
#: Values are literals, not var() references, because css_root refuses non-literals —
#: the entrypoint interpolates token text verbatim and does no CSS maths.
STYLE_VARIANTS: dict[str, dict[str, str]] = {
    # The shipped look: gently rounded, hairline border, subtle lift.
    "soft": {
        "--sd-radius": "0.5rem", "--sd-radius-sm": "0.3rem", "--sd-radius-lg": "0.85rem",
        "--sd-border-width": "1px", "--sd-border-style": "solid",
        "--sd-shadow-sm": "0 1px 2px rgba(0,0,0,.28)",
        "--sd-shadow": "0 4px 14px rgba(0,0,0,.34)",
    },
    # No radius anywhere — the terminal/brutalist end. Reads as denser and more
    # technical, and is what an operator running a NOC wall usually wants.
    "sharp": {
        "--sd-radius": "0", "--sd-radius-sm": "0", "--sd-radius-lg": "0",
        "--sd-border-width": "1px", "--sd-border-style": "solid",
        "--sd-shadow-sm": "none", "--sd-shadow": "none",
    },
    # Structure carried by BORDERS rather than shadow: the highest-contrast option for
    # separating panes, and the one that survives a printout or a projector.
    "outlined": {
        "--sd-radius": "0.35rem", "--sd-radius-sm": "0.2rem", "--sd-radius-lg": "0.5rem",
        "--sd-border-width": "2px", "--sd-border-style": "solid",
        "--sd-shadow-sm": "none", "--sd-shadow": "none",
    },
    # Structure carried by ELEVATION, borders nearly gone. Material-ish.
    "elevated": {
        "--sd-radius": "0.75rem", "--sd-radius-sm": "0.45rem", "--sd-radius-lg": "1.1rem",
        "--sd-border-width": "0", "--sd-border-style": "none",
        "--sd-shadow-sm": "0 2px 6px rgba(0,0,0,.30)",
        "--sd-shadow": "0 10px 28px rgba(0,0,0,.42)",
    },
    # Fully flat: no radius, no shadow, no border. Maximum density.
    "flat": {
        "--sd-radius": "0", "--sd-radius-sm": "0", "--sd-radius-lg": "0",
        "--sd-border-width": "0", "--sd-border-style": "none",
        "--sd-shadow-sm": "none", "--sd-shadow": "none",
    },
    # Translucent panes over the palette's background gradient. Pairs with the extended
    # palette on purpose — it is the style that puts --sd-bg-gradient to work.
    "glass": {
        "--sd-radius": "0.9rem", "--sd-radius-sm": "0.55rem", "--sd-radius-lg": "1.25rem",
        "--sd-border-width": "1px", "--sd-border-style": "solid",
        "--sd-shadow-sm": "0 2px 10px rgba(0,0,0,.30)",
        "--sd-shadow": "0 12px 40px rgba(0,0,0,.45)",
        "--sd-surface-blur": "10px",
    },
}

DEFAULT_STYLE = "soft"


def style_tokens(variant: str = DEFAULT_STYLE) -> dict[str, str]:
    """Shape tokens for one style. Unknown names fall back to the shipped style rather
    than raising: a style is cosmetic, and refusing to render a theme over a typo in a
    preset id would be a worse failure than quietly looking normal."""
    return dict(STYLE_VARIANTS.get(variant, STYLE_VARIANTS[DEFAULT_STYLE]))


# ── the DECOR axis (nav suffix) ────────────────────────────────────────────────────
#: Decorative text appended to every nav link, in three states: base, hover, active.
#:
#: THIS USED TO BE HARD-CODED. hugmesh-host-shell's menu.component.scss appended ' UwU'
#: to every nav link, ' UwO' on hover and ' OwO' when active, with no way to change or
#: remove it. It is now a theme option, and the shipped default is OFF — a mesh that
#: chooses nothing renders plain nav labels.
#:
#: ACCESSIBILITY IS WHY THIS CAN BE OFFERED AT ALL. Pseudo-element `content` is announced
#: by screen readers, so the hard-coded version made every link read as "Home UwU". The
#: consuming SCSS pairs these with CSS alt-text syntax (`content: var(...) / ''`), which
#: marks the generated text as decorative so assistive tech skips it. Without that pairing
#: this axis would be an accessibility regression dressed up as a feature.
#:
#: Values are CSS string literals (quotes included) because they are interpolated into a
#: `content:` declaration verbatim. An empty string means "render nothing".
DECOR_VARIANTS: dict[str, dict[str, str]] = {
    # The shipped default: no decoration at all.
    "none": {
        "--sd-nav-suffix": "''",
        "--sd-nav-suffix-hover": "''",
        "--sd-nav-suffix-active": "''",
    },
    # The historical HugMesh chrome, preserved as an OPT-IN rather than deleted outright.
    "uwu": {
        "--sd-nav-suffix": "' UwU'",
        "--sd-nav-suffix-hover": "' UwO'",
        "--sd-nav-suffix-active": "' OwO'",
    },
    # Directional marker — reads as navigation rather than as a mood.
    "arrows": {
        "--sd-nav-suffix": "''",
        "--sd-nav-suffix-hover": "' \\2192'",     # →
        "--sd-nav-suffix-active": "' \\2022'",    # •
    },
    # Terminal-ish, pairs with the `sharp` style for a NOC/console look.
    "terminal": {
        "--sd-nav-suffix": "''",
        "--sd-nav-suffix-hover": "' _'",
        "--sd-nav-suffix-active": "' *'",
    },
    # Sparkle, for the operator who wanted the cute chrome but not the emoticons.
    "sparkle": {
        "--sd-nav-suffix": "''",
        "--sd-nav-suffix-hover": "' \\2726'",     # ✦
        "--sd-nav-suffix-active": "' \\2727'",    # ✧
    },
}

DEFAULT_DECOR = "none"


def decor_tokens(variant: str = DEFAULT_DECOR) -> dict[str, str]:
    """Decorative tokens for one variant. Unknown names fall back to the shipped default
    (i.e. NOTHING), on the same reasoning as :func:`style_tokens`: decoration is cosmetic,
    and a typo should render plain chrome rather than refuse the whole theme."""
    return dict(DECOR_VARIANTS.get(variant, DECOR_VARIANTS[DEFAULT_DECOR]))


# ── the WEB CHROME axis: header/footer existence, size, backgrounds, content ────────
#: Operator ask (#50 item 2): the Themes editor covers "much more than bootstrap color:
#: header/footer size, existence, backgrounds, content". Same doctrine as every other
#: axis: the generator emits LITERAL tokens, the consuming UI does the rendering, and a
#: token that is not emitted means "the shipped page, byte-identical" — so an old theme
#: (no chrome choices) composes exactly the css it always did.
#:
#: Named sizes rather than free-form CSS lengths: the value flows into SNAP_THEME_CSS
#: token text, and a closed set is the same fail-closed rule login_font follows (a typo'd
#: free-form length would silently mis-render at runtime with nothing to catch it).
CHROME_SIZES: dict[str, str] = {
    "compact": "2.5rem",
    "comfortable": "4rem",
    "tall": "6rem",
}

#: The page BACKGROUND EFFECT — the persistence anchor for hugmesh-host-shell PR #20's
#: deferred vanta catalog. "gradient" is the shipped default (host-shell's theme-driven
#: moving CSS gradient — PR #20's tier chain), so it emits NO token; "none" asks the
#: shell to render a flat themed background; "vanta-<effect>" names an animated WebGL
#: effect from the proven catalog (the four Vanta effects that render against the
#: three.js 0.185 login-ui already ships). The vanta values are PLACEHOLDERS today:
#: the loader lives only in hugmesh-login-ui and porting it to the host shell was
#: deferred by PR #20 — the Studio therefore persists them but keeps them unselectable
#: until the shell can render them. Emitted as ``--sd-bg-effect`` (PR #20's named
#: contract: "emit the selection as a literal token (e.g. --sd-bg-effect: fog)").
BG_EFFECT_DEFAULT = "gradient"
VANTA_EFFECTS: tuple[str, ...] = ("vanta-fog", "vanta-waves", "vanta-net", "vanta-globe")
BG_EFFECTS: tuple[str, ...] = (BG_EFFECT_DEFAULT, "none") + VANTA_EFFECTS

#: Why the vanta rows cannot be picked yet. ONE definition, here, because both
#: front ends must say the same thing and a copy in each is how they stopped:
#: tui/themes.py named this and the GUI editor did not, so a GUI user could choose
#: a vanta effect and be told nothing about why it would not render.
#: test_tui_gui_parity.py pins the equality; importing from one place makes it hold
#: by construction rather than by two authors remembering.
VANTA_DEPENDENCY_NOTE = (
    "Vanta effects need the three.js + vanta effect loader that today ships only "
    "in hugmesh-login-ui; porting it to the host shell was deferred by "
    "hugmesh-host-shell PR #20. The choice is already persisted by the theme "
    "model, and these rows unlock once the login-ui loader lands in the shell.")


def css_string(text: str) -> str:
    """``text`` as a CSS single-quoted string literal, for ``content:`` consumers.

    Same interpolation contract as DECOR_VARIANTS: the value lands verbatim in a
    ``content:`` declaration, so quotes/backslashes must be escaped and newlines become
    the CSS ``\\A`` escape — an unescaped quote would end the string early and drop the
    whole declaration silently (the rgba() hazard, in string form)."""
    escaped = text.replace("\\", "\\\\").replace("'", "\\'")
    escaped = escaped.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\\A ")
    return f"'{escaped}'"


def chrome_tokens(*, header_hidden: bool = False, header_size: str = "",
                  header_bg: str = "", header_text: str = "",
                  footer_hidden: bool = False, footer_size: str = "",
                  footer_bg: str = "", footer_text: str = "",
                  bg_effect: str = BG_EFFECT_DEFAULT) -> dict[str, str]:
    """Tokens for the web-chrome options — ONLY the deviations from the shipped page.

    Emitted per surface (header/footer), each only when chosen:
      ``--sd-<s>-display: none``   the surface is hidden outright
      ``--sd-<s>-height``          a :data:`CHROME_SIZES` length
      ``--sd-<s>-bg``              a flat background colour, with ``--sd-<s>-on`` as its
                                   auto black/white text twin (legibility by construction,
                                   the same on_color rule every accent gets)
      ``--sd-<s>-content``         replacement text as a CSS string literal — consumers
                                   must pair it with alt-text syntax (``content: var(..) / ''``
                                   or real markup), the DECOR_VARIANTS accessibility rule
    plus ``--sd-bg-effect`` when the effect is not the shipped gradient.

    An all-defaults call returns ``{}`` — the conservative-schema guarantee: a config
    saved before these options existed composes byte-identical css. Raises ValueError on
    malformed input (bad hex, unknown size/effect), the same fail-closed contract as
    :func:`derive`."""
    tokens: dict[str, str] = {}
    for surface, hidden, size, bg, text in (
            ("header", header_hidden, header_size, header_bg, header_text),
            ("footer", footer_hidden, footer_size, footer_bg, footer_text)):
        if hidden:
            tokens[f"--sd-{surface}-display"] = "none"
        if size:
            if size not in CHROME_SIZES:
                raise ValueError(
                    f"{surface} size must be one of {', '.join(CHROME_SIZES)} "
                    f"(or empty for the shipped size), got {size!r}")
            tokens[f"--sd-{surface}-height"] = CHROME_SIZES[size]
        if bg:
            _parse(bg)   # raises on malformed, before anything is emitted
            tokens[f"--sd-{surface}-bg"] = bg
            tokens[f"--sd-{surface}-on"] = on_color(bg)
        if text:
            tokens[f"--sd-{surface}-content"] = css_string(text)
    effect = (bg_effect or BG_EFFECT_DEFAULT).strip()
    if effect not in BG_EFFECTS:
        raise ValueError(
            f"background effect must be one of {', '.join(BG_EFFECTS)}, got {bg_effect!r}")
    if effect != BG_EFFECT_DEFAULT:
        tokens["--sd-bg-effect"] = effect
    return tokens


def chrome_css(**options) -> str:
    """The appendable ``:root:root`` block for :func:`chrome_tokens`; "" when nothing
    deviates from the shipped page. Rides the same later-block-wins mechanism as
    theme_presets.delta_css, so it lands after the colour base without forking the
    composition pipeline."""
    tokens = chrome_tokens(**options)
    return css_root(tokens) if tokens else ""


# ── the BOOTSTRAP bridge ───────────────────────────────────────────────────────────
#: Bootstrap 5.3 reads its own `--bs-*` custom properties at RUNTIME, so overriding them
#: in the same :root restyles every Bootstrap component the fleet already ships —
#: buttons, alerts, cards, form controls, tables — with no per-repo SCSS work at all.
#: That is what makes "more themes possible through bootstrap" true rather than
#: aspirational: the UIs are already full of `class="alert alert-warning"` and
#: `class="container"`, and until now the theme could not touch any of it.
#:
#: (sd token, bs token). Only mappings whose SEMANTICS genuinely match are listed — a
#: near-enough mapping would silently mis-colour a component, which is harder to notice
#: and harder to undo than simply not theming it.
_BS_COLOR_MAP: tuple[tuple[str, str], ...] = (
    ("--sd-primary", "--bs-primary"),
    ("--sd-secondary", "--bs-secondary"),
    ("--sd-bg-0", "--bs-body-bg"),
    ("--sd-text", "--bs-body-color"),
    ("--sd-accent", "--bs-link-color"),
    ("--sd-accent-soft", "--bs-link-hover-color"),
    ("--sd-primary-rgb", "--bs-primary-rgb"),
    ("--sd-secondary-rgb", "--bs-secondary-rgb"),
)

_BS_STYLE_MAP: tuple[tuple[str, str], ...] = (
    ("--sd-radius", "--bs-border-radius"),
    ("--sd-radius-sm", "--bs-border-radius-sm"),
    ("--sd-radius-lg", "--bs-border-radius-lg"),
    ("--sd-border-width", "--bs-border-width"),
    ("--sd-border-style", "--bs-border-style"),
    ("--sd-shadow", "--bs-box-shadow"),
    ("--sd-shadow-sm", "--bs-box-shadow-sm"),
)


def bootstrap_tokens(tokens: dict[str, str]) -> dict[str, str]:
    """The `--bs-*` overrides implied by a token map.

    Derived rather than declared, so a palette or style change reaches Bootstrap
    automatically and the two can never drift into disagreeing about the same colour.
    Only emits a `--bs-*` the map can actually support; a missing source token is
    skipped, leaving Bootstrap's own default in place.
    """
    out: dict[str, str] = {}
    for src, dst in (*_BS_COLOR_MAP, *_BS_STYLE_MAP):
        if src in tokens:
            out[dst] = tokens[src]
    # Bootstrap composes its border shorthand from these two, so a style with no border
    # must also null the COLOR or a 0-width border still paints on some components.
    if tokens.get("--sd-border-width") == "0":
        out["--bs-border-color"] = "transparent"
    elif "--sd-bg-2" in tokens:
        out["--bs-border-color"] = tokens["--sd-bg-2"]
    return out
