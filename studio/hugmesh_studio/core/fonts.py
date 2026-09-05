"""Login-font selection — the Qt-free half of the font system (presets, upload gates,
``@font-face`` emission). The Qt half (QFontDatabase parse + in-window rendering) lives
with the GUI; THIS module is what the CLI, the entrypoint pipeline and the tests share.

THE FONT SYSTEM IS A STUB TODAY: login-ui's ``_tokens.scss`` has three tokens all equal
to Arial and exactly one consumer (``styles.scss`` body font-family). So this builds the
loading infrastructure, not just a picker: ``--sd-font-sans/-mono/-fancy`` join the SAME
single ``:root`` pipeline as the colours (core/theme.py), and the SCSS default becomes a
``var(--sd-font-sans, ...)`` fallback that renders byte-identically when no theme is set.

PRESETS ARE SYSTEM STACKS, NEVER CDN AND NEVER VENDORED BINARIES:
  - login-ui's shipped CSP is ``font-src 'self' data:`` — a Google-Fonts link would be
    BLOCKED by code we ship, and sovereign LAN-only/air-gapped meshes could never reach
    it anyway. So presets carry zero bytes and work air-gapped.
  - The operator ask named "fonts compatible with Bootstrap", but login-ui is Angular 22
    with NO Bootstrap dependency, and Bootstrap itself ships NO fonts — it uses a system
    stack. That stack ships here as the "Bootstrap native stack" preset (honouring the
    intent); the rest are the classic cross-platform stack families.
  - We do NOT vendor font binaries we have not licensed. A custom face is the operator's
    explicit upload, recorded with SHA-256 + licence + source so the decision is theirs
    and auditable.

UPLOAD GATES (order matters, cheap first): extension -> magic bytes -> size (WARN above
~256KB per #387 "warn where it still renders"; a ConfigMap tops out at 1MiB) -> Qt parse
(GUI side, QFontDatabase — structural validation + the canonical family name, proven on
the operator's PyQt6 for ttf/woff2, rejects renamed junk). HONESTY: a Qt parse proves
the bytes are parseable BY QT — it is NOT a browser-safety proof and NOT a security
boundary. The operator builds their own image with their own font; the risk is supply
chain, and the recorded SHA-256 + licence provenance is the honest mitigation.

Accepted bytes land as a base64 ``data:`` URI inside the generated snap-theme.css
``@font-face`` — permitted by the shipped CSP, and it keeps fonts on the SAME
rebrand-without-rebuild path as colour (no extra volume, no image rebuild).

THE FAMILY NAME IS ATTACKER-CONTROLLED TEXT. It is NOT typed by the operator: it is
read out of the font FILE's own ``name`` table (QFontDatabase.applicationFontFamilies),
so whoever authored the .ttf/.woff2 chose it. That string is interpolated into css that
is then written into a ``<style id="snap-theme">`` element in the generated platform
preview — and ``<style>`` is an HTML RAW-TEXT element, so a family containing
``</style>`` terminates it and everything after is parsed as MARKUP (reproduced in
chromium: ``window.PWNED = 1`` from a font file). The same text ships to production as
HUG_THEME_CSS / the login-theme ConfigMap, where it lands in a real served stylesheet.
So ``safe_font_family`` ALLOWLISTS — blacklisting backslash and double-quote let
``<``, ``>``, ``/``, ``;``, ``{``, ``}`` and newlines straight through.
"""
from __future__ import annotations

import base64
import hashlib

# name -> CSS font-family stack. Insertion order is presentation order.
# "Classic (current)" is BYTE-IDENTICAL to login-ui _tokens.scss $font-sans — picking it
# (or picking nothing) must not change a rendered pixel; tests pin the literal.
FONT_PRESETS: dict[str, str] = {
    "System UI": "system-ui, sans-serif",
    "Bootstrap native stack": (
        'system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", '
        '"Noto Sans", "Liberation Sans", Arial, sans-serif, "Apple Color Emoji", '
        '"Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji"'
    ),
    "Humanist": (
        'Seravek, "Gill Sans Nova", Ubuntu, Calibri, "DejaVu Sans", '
        "source-sans-pro, sans-serif"
    ),
    "Geometric": 'Avenir, Montserrat, Corbel, "URW Gothic", source-sans-pro, sans-serif',
    "Slab serif": (
        'Rockwell, "Rockwell Nova", "Roboto Slab", "DejaVu Serif", '
        '"Sitka Small", serif'
    ),
    "Monospace": (
        'ui-monospace, "Cascadia Code", "Source Code Pro", Menlo, Consolas, '
        '"DejaVu Sans Mono", monospace'
    ),
    "Classic (current)": "Arial, Helvetica, sans-serif",
}

# --sd-font-mono always gets a real monospace stack (a mono token aliased to a
# proportional face is the _tokens.scss stub reproduced, not fixed).
MONO_STACK = FONT_PRESETS["Monospace"]

FONT_EXTENSIONS = (".woff2", ".woff", ".ttf", ".otf")

# magic -> (css format() string, data: URI mime). wOF2 verified byte-for-byte against a
# real Fira Sans woff2; 00 01 00 00 is the TrueType sfnt version; OTTO is CFF OpenType.
_MAGIC: tuple[tuple[bytes, str, str], ...] = (
    (b"wOF2", "woff2", "font/woff2"),
    (b"wOFF", "woff", "font/woff"),
    (b"\x00\x01\x00\x00", "truetype", "font/ttf"),
    (b"OTTO", "opentype", "font/otf"),
)

MAX_FONT_BYTES = 256 * 1024  # WARN threshold, not a block — ConfigMap ceiling is 1MiB.


def sniff_format(data: bytes) -> str:
    """CSS ``format()`` string for the font bytes, or "" when the magic is unknown."""
    for magic, fmt, _mime in _MAGIC:
        if data[: len(magic)] == magic:
            return fmt
    return ""


# The name a face falls back to when its own name table yields nothing usable — an
# empty family would emit `font-family: ""`, which no browser resolves.
FALLBACK_FAMILY = "HugMesh Brand Font"

# Punctuation a REAL font family may carry, on top of unicode alphanumerics: "Foo Sans",
# "Noto Sans JP", "PT_Sans-Web", "Bitstream Vera Sans (Roman)", "Gill Sans & Co", "M+ 1p",
# "Trebuchet MS". Everything else is dropped, including every character that can break
# out of a css string, a css comment, or an HTML raw-text element.
_FAMILY_PUNCT = " ._-+&'()"


def safe_font_family(family: str) -> str:
    """The family name reduced to characters that cannot break out of the css string,
    the ``/* ... */`` provenance comment, or the ``<style>`` raw-text element it is
    interpolated into. ALLOWLIST, not blacklist: unicode alphanumerics (so "游ゴシック"
    and "Иван" survive intact) plus ``_FAMILY_PUNCT``. Whitespace runs collapse so a
    stripped payload cannot leave a ragged name, and an empty result becomes
    ``FALLBACK_FAMILY`` rather than an unresolvable empty family.

    ``str.isalnum()`` is False for every character that matters here — ``<`` ``>`` ``/``
    backslash ``"`` ``;`` ``{`` ``}`` ``*`` ``@`` ``:`` ``,``, control characters, NEL/LS/PS
    and the bidi overrides — so this is one rule rather than a list to keep in sync."""
    kept = "".join(ch for ch in family if ch.isalnum() or ch in _FAMILY_PUNCT)
    return " ".join(kept.split()) or FALLBACK_FAMILY


def font_sha256(data: bytes) -> str:
    """The digest recorded next to the licence/source in the brand file, so a rebuilt
    mesh can prove it embeds the exact bytes the operator approved."""
    return hashlib.sha256(data).hexdigest()


def check_font(filename: str, data: bytes) -> tuple[list[str], list[str]]:
    """(blocks, warnings) for an upload. Blocks are structural (wrong extension, junk
    bytes, empty); size is a WARNING per #387 — it still renders, the operator decides."""
    blocks: list[str] = []
    warns: list[str] = []
    lower = filename.lower()
    if not lower.endswith(FONT_EXTENSIONS):
        blocks.append(
            f"unsupported extension (want one of {', '.join(FONT_EXTENSIONS)}): {filename}")
    if not data:
        blocks.append("font file is empty")
    elif not sniff_format(data):
        blocks.append(
            "not a recognisable font (magic bytes are none of wOF2/wOFF/TrueType/OTTO) "
            "— a renamed non-font file is rejected here")
    if data and len(data) > MAX_FONT_BYTES:
        warns.append(
            f"font is {len(data) // 1024}KB (> {MAX_FONT_BYTES // 1024}KB): it still "
            "works, but it inflates every login page load and the theme ConfigMap "
            "(1MiB ceiling) — consider a WOFF2 subset")
    return blocks, warns


def font_face_css(family: str, data: bytes) -> str:
    """One ``@font-face`` block embedding the bytes as a ``data:`` URI (CSP-permitted:
    ``font-src 'self' data:``). Raises on bytes that check_font would block, so a
    caller cannot skip the gates by calling emission directly."""
    fmt = sniff_format(data)
    if not fmt:
        raise ValueError("refusing to emit @font-face for unrecognised font bytes")
    mime = next(m for magic, f, m in _MAGIC if f == fmt)
    b64 = base64.b64encode(data).decode("ascii")
    safe_family = safe_font_family(family)
    return (
        "@font-face {\n"
        f'  font-family: "{safe_family}";\n'
        f'  src: url(data:{mime};base64,{b64}) format("{fmt}");\n'
        "  font-display: swap;\n"
        "}\n"
    )


def font_tokens(sans_stack: str, *, uploaded_family: str = "") -> dict[str, str]:
    """The ``--sd-font-*`` tokens for the chosen stack (preset value or an uploaded
    face's canonical family). An uploaded family leads its stack and keeps the chosen
    preset (or Classic) behind it as fallback while the @font-face loads."""
    sans = sans_stack.strip() or FONT_PRESETS["Classic (current)"]
    if uploaded_family.strip():
        fam = safe_font_family(uploaded_family)
        sans = f'"{fam}", {sans}'
    return {
        "--sd-font-sans": sans,
        "--sd-font-mono": MONO_STACK,
        "--sd-font-fancy": sans,
    }
