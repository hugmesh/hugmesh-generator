#!/usr/bin/env python3
"""Render the four premade branding themes into ``specs-x86/branding/themes/``.

Operator ask 6 — "remove existing themes and leave a light and a dark, a purple, and a
grey theme selectable". The previous single theme (``boogiepop``) was a hand-pasted
1920x1080 PNG blob with no provenance and no way to reproduce it. Its four
replacements are **drawn here, in code, from the colour table in
``hugmesh_studio.core.branding_themes``** — the same table the wizard's theme cards
paint their preview swatch from, so a card can never advertise a wallpaper it does not
match.

    NO NETWORK. NO DOWNLOADED ASSET. NO THIRD-PARTY ARTWORK. NO BINARY BLOB.

Everything is composed from stdlib primitives: a hand-rolled PNG encoder (``struct`` +
``zlib``) over pixel buffers filled by integer span arithmetic. The only maths used
are ``+ - * /`` and ``sqrt`` — ``sqrt`` is correctly-rounded by IEEE-754, so it gives
the same bits everywhere. Nothing here calls ``sin``/``cos``/``pow``, whose libm
results are *not* bit-identical across platforms and would have made the output
host-dependent.

Determinism
-----------
Re-running reproduces every file **byte for byte**:

* the pixel maths is integer / IEEE-exact (above), so the raw image bytes are fixed;
* PNG rows use a fixed filter choice (``None`` on row 0, ``Up`` on the rest) rather
  than an adaptive heuristic;
* the ``IDAT`` deflate stream is produced with pinned zlib parameters
  (``level=9, wbits=15, memLevel=9, strategy=Z_DEFAULT_STRATEGY``);
* no timestamp, no ``tEXt``, no ``tIME`` chunk is written.

The one input outside this file's control is the **zlib build** that compresses IDAT.
zlib's deflate output for pinned parameters has been stable across releases, but that
is not a written contract (a zlib-ng drop-in, for instance, would differ). Rather than
claim a guarantee we do not own, ``--check`` re-renders into memory and compares the
bytes against what is committed — so if that ever stops holding, the studio test
``test_branding_themes.py::test_generator_is_deterministic_and_matches_committed``
fails loudly and names the file, instead of the tree silently drifting.

Usage
-----
    scripts/gen-branding-themes.py             # (re)write the four theme dirs
    scripts/gen-branding-themes.py --check     # verify committed == regenerated
    scripts/gen-branding-themes.py --sha256    # print the manifest
    scripts/gen-branding-themes.py --prune     # also DELETE theme dirs not declared
"""
from __future__ import annotations

import argparse
import hashlib
import math
import os
import shutil
import struct
import sys
import zlib

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(_HERE)
# The colour + set contract lives with the code that consumes it (the wizard cards and
# the set-equality assertion). Importing it here is what makes ONE table feed both the
# rendered asset and the GUI preview.
if os.path.join(_REPO, "studio") not in sys.path:
    sys.path.insert(0, os.path.join(_REPO, "studio"))
try:
    from hugmesh_studio.core.branding_themes import (  # noqa: E402
        PREMADE_THEMES, REQUIRED_THEME_ASSETS, THEME_ASSETS, THEME_SPECS, ThemeSpec,
        on_disk_themes, themes_dir,
    )
except ImportError as exc:                                   # pragma: no cover
    raise SystemExit(
        f"cannot import hugmesh_studio.core.branding_themes from {_REPO}/studio: {exc}\n"
        "run this script from inside a generator checkout") from exc

WALLPAPER_W, WALLPAPER_H = 1920, 1080
LOGO_SIZE = 256
#: vertical gradient steps. 48 keeps the banding invisible at 1080 rows while holding
#: the palette (3 entries per step + 2) far under the 256 an 8-bit PLTE allows — and
#: identical rows within a step are what makes the ``Up`` filter compress to nothing.
GRADIENT_STEPS = 48
#: diagonal cross-hatch period, px. A "mesh" texture that stays subtle at 1080p.
LATTICE_PERIOD = 96

_SQRT3 = math.sqrt(3.0)          # IEEE-754 exact: same bits on every platform


# ──────────────────────────────────────────────────────────────────────────────
# colour helpers (all integer maths — no rounding-mode surprises)
# ──────────────────────────────────────────────────────────────────────────────
def _rgb(hex_colour: str) -> tuple[int, int, int]:
    h = hex_colour.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def _mix(a: tuple[int, int, int], b: tuple[int, int, int],
         num: int, den: int) -> tuple[int, int, int]:
    """``a`` blended ``num/den`` of the way to ``b`` — integer-exact, no floats."""
    return tuple((a[i] * (den - num) + b[i] * num + den // 2) // den for i in range(3))


# ──────────────────────────────────────────────────────────────────────────────
# PNG encoder (no Pillow — the studio venv has no imaging library and must not
# grow one for four generated files)
# ──────────────────────────────────────────────────────────────────────────────
def _chunk(tag: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def _deflate(raw: bytes) -> bytes:
    """Pinned-parameter deflate — see the module docstring's determinism note."""
    co = zlib.compressobj(9, zlib.DEFLATED, 15, 9, zlib.Z_DEFAULT_STRATEGY)
    return co.compress(raw) + co.flush()


def _filtered(rows: list[bytes | bytearray], stride: int) -> bytes:
    """Serialise scanlines with the FIXED filter choice: ``None`` (0) on the first
    row, ``Up`` (2) on every later row.

    Fixed rather than adaptive on purpose — an adaptive heuristic is one more thing
    that could differ between runs, and ``Up`` is already the right answer for these
    images: a gradient band's rows are identical, so ``Up`` turns them into runs of
    zero bytes that deflate erases.
    """
    out = bytearray()
    prev = bytes(stride)
    for i, row in enumerate(rows):
        if i == 0:
            out.append(0)
            out += row
        else:
            out.append(2)
            out += bytes((row[j] - prev[j]) & 0xFF for j in range(stride))
        prev = bytes(row)
    return bytes(out)


def png_indexed(width: int, height: int, palette: list[tuple[int, int, int]],
                rows: list[bytearray]) -> bytes:
    """8-bit palette PNG (colour type 3)."""
    if len(palette) > 256:
        raise ValueError(f"palette too large: {len(palette)}")
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)
    plte = b"".join(bytes(c) for c in palette)
    return (b"\x89PNG\r\n\x1a\n"
            + _chunk(b"IHDR", ihdr)
            + _chunk(b"PLTE", plte)
            + _chunk(b"IDAT", _deflate(_filtered(rows, width)))
            + _chunk(b"IEND", b""))


def png_rgba(width: int, height: int, rows: list[bytearray]) -> bytes:
    """8-bit RGBA PNG (colour type 6) — the logo needs real transparency."""
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + _chunk(b"IHDR", ihdr)
            + _chunk(b"IDAT", _deflate(_filtered(rows, width * 4)))
            + _chunk(b"IEND", b""))


# ──────────────────────────────────────────────────────────────────────────────
# geometry — a pointy-top regular hexagon, the mesh mark
# ──────────────────────────────────────────────────────────────────────────────
def _hex_halfwidth(dy: float, radius: float) -> float:
    """Half-width of a pointy-top regular hexagon of circumradius ``radius`` at
    vertical offset ``dy`` from its centre; negative when ``dy`` is outside it.

    Vertices sit at ``(0, +-R)`` and ``(+-R*sqrt(3)/2, +-R/2)``. The interior is
    ``|x| <= R*sqrt(3)/2`` AND ``|x| + sqrt(3)*|y| <= sqrt(3)*R`` — six straight
    edges, so only ``sqrt(3)`` is ever needed.
    """
    a = abs(dy)
    if a > radius:
        return -1.0
    return min(radius * _SQRT3 / 2.0, _SQRT3 * (radius - a))


def _hex_row_spans(y: int, cx: float, cy: float, radius: float, stroke: float,
                   width: int) -> list[tuple[int, int]]:
    """The x-spans (half-open) covered by a hexagon RING on scanline ``y``."""
    dy = y + 0.5 - cy
    outer = _hex_halfwidth(dy, radius)
    if outer < 0:
        return []
    inner = _hex_halfwidth(dy, radius - stroke)
    lo, hi = int(cx - outer), int(cx + outer) + 1
    lo, hi = max(0, lo), min(width, hi)
    if hi <= lo:
        return []
    if inner < 0:                       # the ring is solid across this scanline
        return [(lo, hi)]
    ilo, ihi = int(cx - inner), int(cx + inner) + 1
    ilo, ihi = max(lo, ilo), min(hi, ihi)
    spans = []
    if ilo > lo:
        spans.append((lo, ilo))
    if ihi < hi:
        spans.append((ihi, hi))
    return spans


def _hex_contains(px: float, py: float, radius: float) -> bool:
    return abs(px) <= radius * _SQRT3 / 2.0 and abs(px) + _SQRT3 * abs(py) <= _SQRT3 * radius


# ──────────────────────────────────────────────────────────────────────────────
# assets
# ──────────────────────────────────────────────────────────────────────────────
def render_wallpaper(spec: ThemeSpec) -> bytes:
    """1920x1080 desktop background: a vertical gradient, a subtle diagonal mesh
    lattice, the hexagon mark, and a two-weight brand rule.

    Palette layout (``3 * GRADIENT_STEPS + 2`` = 146 entries):
      ``[0, G)``      gradient band colours
      ``[G, 2G)``     lattice tone for that band (band mixed 10% toward ``ink``)
      ``[2G, 3G)``    the mark's inner ring for that band (band mixed 55% to ``dim``)
      ``3G``          accent (outer ring + primary rule)
      ``3G + 1``      dim (secondary rule)
    """
    top, bottom = _rgb(spec.top), _rgb(spec.bottom)
    ink, accent, dim = _rgb(spec.ink), _rgb(spec.accent), _rgb(spec.dim)
    g = GRADIENT_STEPS
    grad = [_mix(top, bottom, i, g - 1) for i in range(g)]
    palette = list(grad)                                    # [0, G)   gradient
    palette += [_mix(c, ink, 10, 100) for c in grad]        # [G, 2G)  lattice
    palette += [_mix(c, dim, 55, 100) for c in grad]        # [2G, 3G) inner ring
    palette += [accent, dim]                                # 3G, 3G+1
    i_accent, i_dim = 3 * g, 3 * g + 1

    w, h = WALLPAPER_W, WALLPAPER_H
    # the mark: right of centre, comfortably clear of a left-aligned rule
    cx, cy, r_out, s_out = w * 0.68, h * 0.44, 300.0, 8.0
    r_in, s_in = 172.0, 5.0
    # brand rule: a thick accent bar with a thinner dim bar under it, lower-left
    rule_x, rule_y, rule_w, rule_h = 116, int(h * 0.74), 560, 9
    rule2_x, rule2_y, rule2_w, rule2_h = 116, rule_y + rule_h + 9, 372, 4

    rows: list[bytearray] = []
    for y in range(h):
        band = y * g // h
        row = bytearray([band]) * w
        # diagonal cross-hatch, both directions — 1px, period LATTICE_PERIOD
        for start in ((-y) % LATTICE_PERIOD, y % LATTICE_PERIOD):
            n = (w - start + LATTICE_PERIOD - 1) // LATTICE_PERIOD
            row[start::LATTICE_PERIOD] = bytes([g + band]) * n
        # hexagon mark: outer ring in accent, inner ring in the band's dim mix
        for lo, hi in _hex_row_spans(y, cx, cy, r_out, s_out, w):
            row[lo:hi] = bytes([i_accent]) * (hi - lo)
        for lo, hi in _hex_row_spans(y, cx, cy, r_in, s_in, w):
            row[lo:hi] = bytes([2 * g + band]) * (hi - lo)
        # brand rule
        if rule_y <= y < rule_y + rule_h:
            row[rule_x:rule_x + rule_w] = bytes([i_accent]) * rule_w
        if rule2_y <= y < rule2_y + rule2_h:
            row[rule2_x:rule2_x + rule2_w] = bytes([i_dim]) * rule2_w
        rows.append(row)
    return png_indexed(w, h, palette, rows)


def render_logo(spec: ThemeSpec) -> bytes:
    """256x256 RGBA brand mark: an accent hexagon ring around a filled ``dim`` core,
    on transparency. 3x3 supersampled, so the alpha is an exact ninths coverage
    fraction — integer maths, no filtering kernel to drift."""
    n = LOGO_SIZE
    accent, dim = _rgb(spec.accent), _rgb(spec.dim)
    cx = cy = n / 2.0
    r_out, stroke, r_core = 112.0, 17.0, 54.0
    r_in = r_out - stroke
    ss = 3                                     # 3x3 supersample -> 9 coverage levels
    rows: list[bytearray] = []
    for y in range(n):
        row = bytearray(n * 4)
        for x in range(n):
            ring = core = 0
            for sy in range(ss):
                py = y + (2 * sy + 1) / (2.0 * ss) - cy
                for sx in range(ss):
                    px = x + (2 * sx + 1) / (2.0 * ss) - cx
                    if _hex_contains(px, py, r_core):
                        core += 1
                    elif _hex_contains(px, py, r_out) and not _hex_contains(px, py, r_in):
                        ring += 1
            if not (ring or core):
                continue
            total = ring + core
            # premultiplied-free straight alpha: colour is the coverage-weighted mix
            col = tuple((accent[i] * ring + dim[i] * core + total // 2) // total
                        for i in range(3))
            o = x * 4
            row[o], row[o + 1], row[o + 2] = col
            row[o + 3] = (255 * total + (ss * ss) // 2) // (ss * ss)
        rows.append(row)
    return png_rgba(n, n, rows)


def render_brand_conf(spec: ThemeSpec) -> bytes:
    """The theme half of ``brand.conf``.

    Deliberately sets ONLY the two theming keys. ``BRAND_NAME``/``BRAND_TITLE`` are
    brand IDENTITY, not theme, and ``build-x86-host-stage4.sh`` appends them (plus an
    explicit ``--accent-color``, when given) after copying the preset — so a theme that
    wrote them would be silently overridden and a theme that omits them lets the
    operator's ``--accent-color`` win, which is the documented precedence.
    """
    return (
        "# HugMesh premade branding theme: {name}\n"
        "# GENERATED by scripts/gen-branding-themes.py — do not edit by hand.\n"
        "# Read as strict KEY=VALUE by specs/usr/sbin/hugmesh-branding (never sourced).\n"
        "ACCENT_COLOR={accent}\n"
        "COLOR_SCHEME_NAME={scheme}\n"
    ).format(name=spec.name, accent=spec.accent, scheme=spec.color_scheme_name).encode()


def render_colors(spec: ThemeSpec) -> bytes:
    """A KDE colour-scheme file (``colors.colors``) — installed verbatim by
    ``hugmesh-branding``'s ``apply_color_scheme`` so Plasma/KDE apps match the
    wallpaper instead of staying stock Breeze."""
    top, bottom = _rgb(spec.top), _rgb(spec.bottom)
    ink, accent, dim = _rgb(spec.ink), _rgb(spec.accent), _rgb(spec.dim)
    # window/view/button surfaces read off the SAME gradient ends the wallpaper uses
    window = _mix(bottom, top, 35, 100)
    view = _mix(bottom, top, 65, 100)
    button = _mix(window, ink, 8, 100)
    inactive = _mix(ink, window, 45, 100)

    def c(v: tuple[int, int, int]) -> str:
        return "{},{},{}".format(*v)

    sections = [
        ("General", [("ColorScheme", spec.color_scheme_name),
                     ("Name", spec.color_scheme_name),
                     ("shadeSortColumn", "true")]),
        ("Colors:Window", [("BackgroundNormal", c(window)),
                           ("BackgroundAlternate", c(_mix(window, ink, 5, 100))),
                           ("ForegroundNormal", c(ink)),
                           ("ForegroundInactive", c(inactive)),
                           ("ForegroundLink", c(accent)),
                           ("DecorationFocus", c(accent)),
                           ("DecorationHover", c(dim))]),
        ("Colors:View", [("BackgroundNormal", c(view)),
                         ("BackgroundAlternate", c(_mix(view, ink, 4, 100))),
                         ("ForegroundNormal", c(ink)),
                         ("ForegroundInactive", c(inactive)),
                         ("ForegroundLink", c(accent)),
                         ("DecorationFocus", c(accent)),
                         ("DecorationHover", c(dim))]),
        ("Colors:Button", [("BackgroundNormal", c(button)),
                           ("BackgroundAlternate", c(_mix(button, ink, 6, 100))),
                           ("ForegroundNormal", c(ink)),
                           ("ForegroundInactive", c(inactive)),
                           ("DecorationFocus", c(accent)),
                           ("DecorationHover", c(dim))]),
        ("Colors:Selection", [("BackgroundNormal", c(accent)),
                              ("BackgroundAlternate", c(dim)),
                              ("ForegroundNormal", c(_mix(accent, (255, 255, 255), 88, 100)
                                                     if sum(accent) < 384 else
                                                     _mix(accent, (0, 0, 0), 82, 100))),
                              ("DecorationFocus", c(accent)),
                              ("DecorationHover", c(dim))]),
        ("Colors:Tooltip", [("BackgroundNormal", c(_mix(window, ink, 12, 100))),
                            ("ForegroundNormal", c(ink))]),
        ("WM", [("activeBackground", c(_mix(window, accent, 18, 100))),
                ("activeForeground", c(ink)),
                ("inactiveBackground", c(window)),
                ("inactiveForeground", c(inactive))]),
    ]
    out = ["# HugMesh premade branding theme: " + spec.name,
           "# GENERATED by scripts/gen-branding-themes.py — do not edit by hand.", ""]
    for name, keys in sections:
        out.append("[" + name + "]")
        out += ["{}={}".format(k, v) for k, v in keys]
        out.append("")
    return ("\n".join(out).rstrip("\n") + "\n").encode()


_RENDERERS = {
    "brand.conf": render_brand_conf,
    "wallpaper.png": render_wallpaper,
    "logo.png": render_logo,
    "colors.colors": render_colors,
}
assert set(_RENDERERS) == set(THEME_ASSETS), "renderer table vs THEME_ASSETS drift"
assert set(REQUIRED_THEME_ASSETS) <= set(_RENDERERS)


def render_theme(name: str) -> dict[str, bytes]:
    """Every asset of one theme, as ``filename -> bytes``. Pure: touches no disk."""
    spec = THEME_SPECS[name]
    return {fn: _RENDERERS[fn](spec) for fn in THEME_ASSETS}


def render_all() -> dict[str, dict[str, bytes]]:
    return {name: render_theme(name) for name in PREMADE_THEMES}


# ──────────────────────────────────────────────────────────────────────────────
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--generator-dir", default=_REPO,
                    help="generator checkout to write into (default: this one)")
    ap.add_argument("--check", action="store_true",
                    help="verify the committed files equal a fresh render; write nothing")
    ap.add_argument("--sha256", action="store_true", help="print the asset manifest")
    ap.add_argument("--prune", action="store_true",
                    help="DELETE theme directories that are not declared "
                         "(the one destructive mode; off by default)")
    args = ap.parse_args(argv)

    root = themes_dir(args.generator_dir)
    rendered = render_all()
    stale = [t for t in on_disk_themes(args.generator_dir) if t not in THEME_SPECS]
    rc = 0

    if args.check:
        for name, assets in rendered.items():
            for fn, data in assets.items():
                path = os.path.join(root, name, fn)
                try:
                    with open(path, "rb") as fh:
                        have = fh.read()
                except OSError as exc:
                    print(f"MISSING {path}: {exc}", file=sys.stderr)
                    rc = 1
                    continue
                if have != data:
                    print(f"DRIFT   {path}: committed {len(have)}B "
                          f"sha256 {hashlib.sha256(have).hexdigest()[:16]} != "
                          f"regenerated {len(data)}B "
                          f"sha256 {hashlib.sha256(data).hexdigest()[:16]}",
                          file=sys.stderr)
                    rc = 1
        for t in stale:
            print(f"STALE   {os.path.join(root, t)} is not a declared theme",
                  file=sys.stderr)
            rc = 1
        if rc == 0:
            print(f"OK: {len(rendered)} themes, "
                  f"{sum(len(a) for a in rendered.values())} files match")
    else:
        for name, assets in rendered.items():
            d = os.path.join(root, name)
            os.makedirs(d, exist_ok=True)
            for fn, data in assets.items():
                with open(os.path.join(d, fn), "wb") as fh:
                    fh.write(data)
            print(f"wrote {d}: " + " ".join(f"{fn}({len(assets[fn])}B)"
                                            for fn in THEME_ASSETS))
        for t in stale:
            path = os.path.join(root, t)
            if args.prune:
                shutil.rmtree(path)
                print(f"pruned {path} (not a declared theme)")
            else:
                print(f"WARNING: {path} is not a declared theme — "
                      f"re-run with --prune to delete it", file=sys.stderr)
                rc = 1

    if args.sha256:
        for name in PREMADE_THEMES:
            for fn in THEME_ASSETS:
                print(hashlib.sha256(rendered[name][fn]).hexdigest(),
                      f"{name}/{fn}")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
