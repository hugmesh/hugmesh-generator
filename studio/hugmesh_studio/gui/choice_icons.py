"""Vector icons for the wizard's choice cards — drawn in code, never fetched.

Every glyph here is an ORIGINAL rendition built from ``QPainterPath`` primitives in a
fixed 64x64 logical box; the renderer scales that box to whatever the card asks for, so
one painter serves 24px list rows and 64px cards alike. There is **no asset file, no
base64 blob, no network fetch and no third-party brand artwork** in this module — the
Studio must run air-gapped, and a pixel-copy of a corporate logo would be neither
honest nor trademark-safe. Where a vendor has to be identifiable (Gentoo on the
standalone card; AWS / Azure / Cloudflare on the cloud-deploy card) we draw a simple
*gesture* of the mark — a swirl, a smile-arc, a wedge, a cloud — and print a short
TEXT LABEL naming it, which is what actually makes the icon readable.

Theme awareness: nothing here hardcodes a colour. :func:`style_for` derives the four
tones an icon uses from the widget's own ``QPalette`` (plus the repo's
``styles.MUTED``-style mid-tone convention for secondary strokes), so the same painter
reads correctly on a light and a dark desktop. The Studio does not own its background.

Cost: these repaint on every hover, so :func:`pixmap` memoises the rendered
``QPixmap`` per ``(name, size, devicePixelRatio, style)``. A complex path build runs
once per distinct appearance, not once per paint event.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Dict, Tuple

from .qt import Qt, QtCore, QtGui

# Every painter draws inside this logical square; `pixmap()` scales it to the request.
CANVAS = 64.0

__all__ = [
    "CANVAS", "IconStyle", "style_for", "pixmap", "icon", "paint", "clear_cache",
    "ICON_PAINTERS", "ICON_NAMES", "ICON_NOTES", "cache_size", "role_icon_name",
]


# ──────────────────────────────────────────────────────────────────────────────
# colour derivation (palette-driven; hashable so it can key the pixmap cache)
# ──────────────────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class IconStyle:
    """The four tones an icon painter may use, all derived from a live palette.

    ``fg``     primary strokes — the silhouette that must survive greyscale.
    ``accent`` the one "this is the cloud / the arrow" highlight.
    ``muted``  secondary detail strokes (ports, pins, meridians).
    ``faint``  large fills that must stay *behind* the strokes on either theme.
    """
    fg: str
    accent: str
    muted: str
    faint: str

    @property
    def key(self) -> Tuple[str, str, str, str]:
        return (self.fg, self.accent, self.muted, self.faint)


def _mix(a: QtGui.QColor, b: QtGui.QColor, t: float) -> QtGui.QColor:
    """``a`` blended ``t`` of the way towards ``b`` (t=0 -> a, t=1 -> b)."""
    t = max(0.0, min(1.0, t))
    return QtGui.QColor(
        round(a.red() + (b.red() - a.red()) * t),
        round(a.green() + (b.green() - a.green()) * t),
        round(a.blue() + (b.blue() - a.blue()) * t),
    )


def _luma(c: QtGui.QColor) -> float:
    """Relative luminance (sRGB approximation) — used only to test readability."""
    def ch(v: int) -> float:
        s = v / 255.0
        return s / 12.92 if s <= 0.04045 else ((s + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch(c.red()) + 0.7152 * ch(c.green()) + 0.0722 * ch(c.blue())


def _contrast(a: QtGui.QColor, b: QtGui.QColor) -> float:
    la, lb = _luma(a), _luma(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def style_for(palette: QtGui.QPalette, *, selected: bool = False,
              enabled: bool = True) -> IconStyle:
    """Derive an :class:`IconStyle` from a widget palette.

    The accent starts as the palette Highlight, but a highlight that does not read
    against the card background (some low-contrast system themes) is pulled towards the
    text colour until it does — an icon nobody can see is a defect, not a theme choice.
    """
    role = QtGui.QPalette.ColorRole
    group = (QtGui.QPalette.ColorGroup.Active if enabled
             else QtGui.QPalette.ColorGroup.Disabled)
    text = palette.color(group, role.WindowText)
    back = palette.color(group, role.Window)
    accent = palette.color(group, role.Highlight)
    if _contrast(accent, back) < 2.2:
        accent = _mix(accent, text, 0.6)
    if selected:
        # a selected card fills with the highlight; the icon then rides on that fill.
        text = palette.color(group, role.HighlightedText)
        back = palette.color(group, role.Highlight)
        accent = _mix(text, back, 0.28)
    if not enabled:
        text = _mix(text, back, 0.45)
        accent = _mix(accent, back, 0.45)
    return IconStyle(
        fg=text.name(),
        accent=accent.name(),
        muted=_mix(text, back, 0.42).name(),
        faint=_mix(text, back, 0.84).name(),
    )


# ──────────────────────────────────────────────────────────────────────────────
# drawing primitives (all in the 64x64 logical box)
# ──────────────────────────────────────────────────────────────────────────────
def _pen(colour: str, width: float,
         style: Qt.PenStyle = Qt.PenStyle.SolidLine) -> QtGui.QPen:
    p = QtGui.QPen(QtGui.QColor(colour), width, style)
    p.setCapStyle(Qt.PenCapStyle.RoundCap)
    p.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
    return p


def _rect(x: float, y: float, w: float, h: float) -> QtCore.QRectF:
    return QtCore.QRectF(x, y, w, h)


def _cloud_path(x: float, y: float, w: float, h: float) -> QtGui.QPainterPath:
    """A flat-bottomed three-lobed cloud filling the box, as ONE united outline.

    The lobe circles are placed so each is TANGENT to the base slab's top-left /
    top-right corner: the boolean union then has no cusp and no stray interior edge
    (an earlier ``simplified()`` union of loosely-placed ellipses had both).
    """
    sx, sy = w / 100.0, h / 60.0

    def box(bx: float, by: float, bw: float, bh: float) -> QtCore.QRectF:
        return _rect(x + bx * sx, y + by * sy, bw * sx, bh * sy)

    left = QtGui.QPainterPath()
    left.addEllipse(box(6, 14, 40, 40))
    top = QtGui.QPainterPath()
    top.addEllipse(box(24, 0, 52, 52))
    right = QtGui.QPainterPath()
    right.addEllipse(box(54, 12, 44, 44))
    base = QtGui.QPainterPath()
    base.addRoundedRect(box(6, 34, 92, 26), 3 * sx, 3 * sy)
    return left.united(top).united(right).united(base)


def _draw_cloud(p: QtGui.QPainter, st: IconStyle,
                x: float, y: float, w: float, h: float, width: float = 2.4) -> None:
    p.setPen(_pen(st.accent, width))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawPath(_cloud_path(x, y, w, h))


def _monitor_path(x: float, y: float, w: float, h: float) -> QtGui.QPainterPath:
    """A desktop machine — screen, neck, foot — as one outline in the given box."""
    screen_h = h * 0.68
    path = QtGui.QPainterPath()
    path.addRoundedRect(_rect(x, y, w, screen_h), w * 0.10, w * 0.10)
    neck_w = max(w * 0.18, 2.0)
    path.addRect(_rect(x + (w - neck_w) / 2.0, y + screen_h - 1.0, neck_w, h * 0.18))
    foot_w = w * 0.58
    path.addRoundedRect(_rect(x + (w - foot_w) / 2.0, y + h * 0.84, foot_w, h * 0.16),
                        h * 0.06, h * 0.06)
    return path.simplified()


def _draw_monitor(p: QtGui.QPainter, st: IconStyle,
                  x: float, y: float, w: float, h: float, width: float = 2.4) -> None:
    p.setPen(_pen(st.fg, width))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawPath(_monitor_path(x, y, w, h))


def _draw_board(p: QtGui.QPainter, st: IconStyle,
                x: float, y: float, w: float, h: float, width: float = 2.0) -> None:
    """A single-board computer: outline, GPIO header strip, SoC, two edge ports."""
    p.setPen(_pen(st.fg, width))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawRoundedRect(_rect(x, y, w, h), w * 0.10, w * 0.10)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.muted)))
    p.drawRect(_rect(x + w * 0.12, y + h * 0.13, w * 0.60, h * 0.16))   # pin header
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.fg)))
    p.drawRect(_rect(x + w * 0.26, y + h * 0.42, w * 0.34, h * 0.32))   # SoC
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.muted)))
    p.drawRect(_rect(x + w * 0.76, y + h * 0.40, w * 0.20, h * 0.18))   # ports
    p.drawRect(_rect(x + w * 0.76, y + h * 0.66, w * 0.20, h * 0.18))


def _draw_label(p: QtGui.QPainter, st: IconStyle, text: str,
                x: float, y: float, w: float, h: float,
                px: int = 11, colour: str | None = None) -> None:
    """A short TEXT LABEL inside the icon (what makes a vendor gesture honest).

    ``px`` is a MAXIMUM: the label shrinks until it fits the box width, so a longer
    vendor name can never clip into a wrong word (recovered-WIP audit: "AZURE" at
    a fixed 8px rendered as "ZURI" inside its 20-unit tile — drawText clips)."""
    p.save()
    f = p.font()
    f.setBold(True)
    size = max(1, int(px))
    f.setPixelSize(size)
    while size > 4 and QtGui.QFontMetricsF(f).horizontalAdvance(text) > w:
        size -= 1
        f.setPixelSize(size)
    p.setFont(f)
    p.setPen(_pen(colour or st.fg, 1.0))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawText(_rect(x, y, w, h),
               int(Qt.AlignmentFlag.AlignCenter), text)
    p.restore()


def _arrow(p: QtGui.QPainter, st: IconStyle,
           x1: float, y1: float, x2: float, y2: float,
           width: float = 2.6, head: float = 5.0) -> None:
    """A straight accent arrow from (x1,y1) to (x2,y2) with a filled head."""
    import math
    p.setPen(_pen(st.accent, width))
    p.setBrush(Qt.BrushStyle.NoBrush)
    ang = math.atan2(y2 - y1, x2 - x1)
    bx, by = x2 - math.cos(ang) * head * 0.9, y2 - math.sin(ang) * head * 0.9
    p.drawLine(QtCore.QPointF(x1, y1), QtCore.QPointF(bx, by))
    tri = QtGui.QPainterPath()
    tri.moveTo(x2, y2)
    tri.lineTo(bx - math.sin(ang) * head * 0.55, by + math.cos(ang) * head * 0.55)
    tri.lineTo(bx + math.sin(ang) * head * 0.55, by - math.cos(ang) * head * 0.55)
    tri.closeSubpath()
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.accent)))
    p.drawPath(tri)


def _link(p: QtGui.QPainter, st: IconStyle,
          x1: float, y1: float, x2: float, y2: float) -> None:
    """A dashed uplink between a device and the cloud above it."""
    p.setPen(_pen(st.accent, 1.8, Qt.PenStyle.DashLine))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawLine(QtCore.QPointF(x1, y1), QtCore.QPointF(x2, y2))


# ──────────────────────────────────────────────────────────────────────────────
# the seven first-screen icons (ModePage) — one per thing the Studio can build/do
# ──────────────────────────────────────────────────────────────────────────────
def _mesh(p: QtGui.QPainter, st: IconStyle) -> None:
    """THREE Raspberry-Pi-class boards with a cloud above them — a server mesh."""
    _draw_cloud(p, st, 11, 1, 42, 21)
    xs = (2.0, 23.5, 45.0)
    for x in xs:
        _link(p, st, x + 8.5, 24, 32, 21)
    for x in xs:
        _draw_board(p, st, x, 39, 17, 22)


def _localmesh(p: QtGui.QPainter, st: IconStyle) -> None:
    """ONE desktop machine with a cloud above it — the mesh runs on THIS box."""
    _draw_cloud(p, st, 15, 1, 34, 19)
    _link(p, st, 32, 21, 32, 27)
    _draw_monitor(p, st, 16, 27, 32, 34)


def _mesh_desktop(p: QtGui.QPainter, st: IconStyle) -> None:
    """A desktop BESIDE other desktops, with a board underneath, all under a cloud."""
    _draw_cloud(p, st, 4, 0, 56, 17)
    _draw_monitor(p, st, 2, 21, 27, 26)          # the one you are building
    _draw_monitor(p, st, 32, 24, 14, 16, 1.8)    # …beside its peers
    _draw_monitor(p, st, 48, 24, 14, 16, 1.8)
    _link(p, st, 32, 18, 32, 21)
    _draw_board(p, st, 20, 49, 24, 13, 1.8)      # the mesh node it joins


def _gentoo(p: QtGui.QPainter, st: IconStyle) -> None:
    """An ORIGINAL swirl-and-'g' gesture for Gentoo (NOT the vendor's artwork), with
    the name spelled out beneath it — the card also carries the gentoo.org link."""
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.setPen(_pen(st.accent, 6.5))
    p.drawArc(_rect(12, 2, 40, 40), int(35 * 16), int(300 * 16))    # the open ring
    p.setPen(_pen(st.fg, 5.0))
    p.drawArc(_rect(21, 11, 22, 22), int(215 * 16), int(250 * 16))  # the inner swirl
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.fg)))
    p.drawEllipse(_rect(29.5, 19.5, 5, 5))                          # the swirl's eye
    _draw_label(p, st, "gentoo", 0, 46, 64, 16, px=13, colour=st.muted)


def _phone(p: QtGui.QPainter, st: IconStyle) -> None:
    """A handset UNDER a cloud — the MDM phone flow."""
    _draw_cloud(p, st, 15, 0, 34, 18)
    _link(p, st, 32, 19, 32, 23)
    p.setPen(_pen(st.fg, 2.4))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawRoundedRect(_rect(22, 23, 20, 39), 4.0, 4.0)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.muted)))
    p.drawRoundedRect(_rect(28.5, 26.5, 7, 1.8), 0.9, 0.9)     # earpiece slit
    p.drawRoundedRect(_rect(28.0, 57.5, 8, 1.8), 0.9, 0.9)     # home indicator
    p.setPen(_pen(st.muted, 1.4))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawRect(_rect(25.5, 31, 13, 23))                        # screen


def _quest(p: QtGui.QPainter, st: IconStyle) -> None:
    """A VR headset UNDER a cloud — the MDM Quest flow (visor + head strap)."""
    _draw_cloud(p, st, 15, 0, 34, 18)
    _link(p, st, 32, 19, 32, 24)
    p.setPen(_pen(st.muted, 2.6))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawArc(_rect(4, 24, 56, 32), int(20 * 16), int(140 * 16))    # head strap
    visor = QtGui.QPainterPath()
    visor.addRoundedRect(_rect(6, 33, 52, 23), 10.0, 10.0)
    notch = QtGui.QPainterPath()
    notch.addEllipse(_rect(26, 50, 12, 12))                          # nose cut-out
    p.setPen(_pen(st.fg, 2.4))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawPath(visor.subtracted(notch))
    p.setPen(_pen(st.accent, 1.8))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawEllipse(_rect(12.5, 38, 15, 12))                           # lenses
    p.drawEllipse(_rect(36.5, 38, 15, 12))


def _deploy(p: QtGui.QPainter, st: IconStyle) -> None:
    """A THREE-WAY arrow rising into three labelled cloud-provider marks.

    The three marks are our own gestures — a smile-arc (AWS), a wedge (Azure), a
    cloud (Cloudflare) — each with a short text label. No vendor artwork is copied.
    """
    tiles = ((0.5, "AWS"), (22.0, "AZURE"), (43.5, "CF"))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    for x, _ in tiles:
        p.setPen(_pen(st.muted, 1.6))
        p.drawRoundedRect(_rect(x, 1, 20, 24), 3.5, 3.5)
    # AWS — an upward "smile" arc
    p.setPen(_pen(st.accent, 2.0))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawArc(_rect(3.5, 3.5, 14, 12), int(200 * 16), int(140 * 16))
    # Azure — a wedge
    wedge = QtGui.QPainterPath()
    wedge.moveTo(29.0, 4.0)
    wedge.lineTo(36.5, 15.5)
    wedge.lineTo(25.0, 15.5)
    wedge.closeSubpath()
    p.setPen(_pen(st.accent, 1.6))
    p.drawPath(wedge)
    # Cloudflare — a small cloud
    p.setPen(_pen(st.accent, 1.6))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawPath(_cloud_path(45.5, 4.0, 16, 11))
    for x, name in tiles:
        _draw_label(p, st, name, x, 15.0, 20, 10, px=8, colour=st.fg)
    # the three-way arrow: one stem, three heads, one per provider
    p.setPen(_pen(st.accent, 2.8))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawLine(QtCore.QPointF(32, 62), QtCore.QPointF(32, 46))
    p.drawLine(QtCore.QPointF(10.5, 46), QtCore.QPointF(53.5, 46))
    _arrow(p, st, 10.5, 46, 10.5, 29.5)
    _arrow(p, st, 32.0, 46, 32.0, 29.5)
    _arrow(p, st, 53.5, 46, 53.5, 29.5)


# ──────────────────────────────────────────────────────────────────────────────
# identity-provider icons (IdpPage)
# ──────────────────────────────────────────────────────────────────────────────
def _shield_path(x: float, y: float, w: float, h: float) -> QtGui.QPainterPath:
    path = QtGui.QPainterPath()
    path.moveTo(x + w / 2, y)
    path.lineTo(x + w, y + h * 0.20)
    path.lineTo(x + w, y + h * 0.55)
    path.quadTo(x + w, y + h * 0.90, x + w / 2, y + h)
    path.quadTo(x, y + h * 0.90, x, y + h * 0.55)
    path.lineTo(x, y + h * 0.20)
    path.closeSubpath()
    return path


def _idp_casdoor(p: QtGui.QPainter, st: IconStyle) -> None:
    """The built-in IdP: a shield with a keyhole — nothing external to configure."""
    p.setPen(_pen(st.fg, 2.6))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawPath(_shield_path(12, 4, 40, 50))
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.accent)))
    p.drawEllipse(_rect(27, 20, 10, 10))
    key = QtGui.QPainterPath()
    key.moveTo(29.5, 28)
    key.lineTo(34.5, 28)
    key.lineTo(33.5, 40)
    key.lineTo(30.5, 40)
    key.closeSubpath()
    p.drawPath(key)


def _idp_entra(p: QtGui.QPainter, st: IconStyle) -> None:
    """An external Microsoft-Entra tenant: a wedge over a labelled base."""
    wedge = QtGui.QPainterPath()
    wedge.moveTo(32, 4)
    wedge.lineTo(56, 40)
    wedge.lineTo(8, 40)
    wedge.closeSubpath()
    inner = QtGui.QPainterPath()
    inner.moveTo(32, 18)
    inner.lineTo(45, 38)
    inner.lineTo(19, 38)
    inner.closeSubpath()
    p.setPen(_pen(st.accent, 2.4))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawPath(wedge.subtracted(inner))
    _draw_label(p, st, "ENTRA", 0, 44, 64, 16, px=13, colour=st.fg)


def _idp_aws(p: QtGui.QPainter, st: IconStyle) -> None:
    """An external AWS Cognito pool: a smile-arc over a labelled base."""
    p.setPen(_pen(st.accent, 3.4))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawArc(_rect(6, 6, 52, 34), int(200 * 16), int(140 * 16))
    _arrow(p, st, 44, 30, 56, 22, width=2.4, head=5.0)
    _draw_label(p, st, "AWS", 0, 44, 64, 16, px=13, colour=st.fg)


def _idp_oidc(p: QtGui.QPainter, st: IconStyle) -> None:
    """Any spec-compliant OIDC issuer: a globe (issuer + JWKS), labelled."""
    p.setPen(_pen(st.fg, 2.4))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawEllipse(_rect(15, 3, 34, 34))
    p.setPen(_pen(st.muted, 1.6))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawEllipse(_rect(24, 3, 16, 34))
    p.drawLine(QtCore.QPointF(15, 20), QtCore.QPointF(49, 20))
    _draw_label(p, st, "OIDC", 0, 42, 64, 18, px=14, colour=st.fg)


# ──────────────────────────────────────────────────────────────────────────────
# go-live exposure-model icons (GoLiveExposurePage)
# ──────────────────────────────────────────────────────────────────────────────
def _golive_tunnel(p: QtGui.QPainter, st: IconStyle) -> None:
    """Outbound tunnel: the node dials OUT to the edge; nothing listens inbound."""
    _draw_cloud(p, st, 30, 2, 32, 20)
    _draw_board(p, st, 2, 36, 22, 24)
    p.setPen(_pen(st.accent, 2.6))
    p.setBrush(Qt.BrushStyle.NoBrush)
    curve = QtGui.QPainterPath()
    curve.moveTo(24, 42)
    curve.quadTo(42, 40, 44, 24)
    p.drawPath(curve)
    _arrow(p, st, 43.4, 29, 44, 22.5)


def _golive_public_dns(p: QtGui.QPainter, st: IconStyle) -> None:
    """Public DNS records: a globe with a copy-paste record set beside it."""
    p.setPen(_pen(st.fg, 2.4))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawEllipse(_rect(2, 14, 32, 32))
    p.setPen(_pen(st.muted, 1.5))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawEllipse(_rect(11, 14, 14, 32))
    p.drawLine(QtCore.QPointF(2, 30), QtCore.QPointF(34, 30))
    p.setPen(_pen(st.accent, 2.0))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawRoundedRect(_rect(38, 12, 24, 36), 3.0, 3.0)
    p.setPen(_pen(st.muted, 2.0))
    for i in range(4):
        y = 19.0 + i * 7.5
        p.drawLine(QtCore.QPointF(42, y), QtCore.QPointF(58, y))


def _golive_ddns(p: QtGui.QPainter, st: IconStyle) -> None:
    """Dynamic DNS: a globe wrapped in a refresh arrow — the address keeps moving."""
    p.setPen(_pen(st.fg, 2.4))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawEllipse(_rect(16, 16, 32, 32))
    p.setPen(_pen(st.muted, 1.5))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawEllipse(_rect(24, 16, 16, 32))
    p.drawLine(QtCore.QPointF(16, 32), QtCore.QPointF(48, 32))
    p.setPen(_pen(st.accent, 2.8))
    p.drawArc(_rect(6, 6, 52, 52), int(45 * 16), int(260 * 16))
    _arrow(p, st, 50, 15, 56, 6, width=2.4, head=5.5)


def _golive_funnel(p: QtGui.QPainter, st: IconStyle) -> None:
    """Tailscale Funnel: a literal funnel — public HTTPS through the tailnet edge."""
    path = QtGui.QPainterPath()
    path.moveTo(6, 8)
    path.lineTo(58, 8)
    path.lineTo(37, 34)
    path.lineTo(37, 54)
    path.lineTo(27, 60)
    path.lineTo(27, 34)
    path.closeSubpath()
    p.setPen(_pen(st.fg, 2.4))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawPath(path)
    p.setPen(_pen(st.accent, 2.4))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawLine(QtCore.QPointF(14, 15), QtCore.QPointF(50, 15))


def _golive_router(p: QtGui.QPainter, st: IconStyle) -> None:
    """Router port-forward: a router with antennas and an inbound arrow you wire up."""
    p.setPen(_pen(st.fg, 2.4))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawRoundedRect(_rect(6, 34, 52, 20), 4.0, 4.0)
    p.setPen(_pen(st.muted, 2.2))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawLine(QtCore.QPointF(18, 34), QtCore.QPointF(12, 18))
    p.drawLine(QtCore.QPointF(46, 34), QtCore.QPointF(52, 18))
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.muted)))
    for i in range(3):
        p.drawEllipse(_rect(14.0 + i * 8, 42, 4, 4))
    _arrow(p, st, 32, 6, 32, 31)


def _golive_onion(p: QtGui.QPainter, st: IconStyle) -> None:
    """Tor v3 onion: a layered bulb with a sprout — no public IP, DNS or open port."""
    bulb = QtGui.QPainterPath()
    bulb.moveTo(32, 12)
    bulb.cubicTo(56, 20, 56, 44, 32, 60)
    bulb.cubicTo(8, 44, 8, 20, 32, 12)
    bulb.closeSubpath()
    p.setPen(_pen(st.fg, 2.4))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawPath(bulb)
    p.setPen(_pen(st.accent, 1.8))
    p.setBrush(Qt.BrushStyle.NoBrush)
    inner = QtGui.QPainterPath()
    inner.moveTo(32, 22)
    inner.cubicTo(46, 28, 46, 44, 32, 53)
    inner.cubicTo(18, 44, 18, 28, 32, 22)
    inner.closeSubpath()
    p.drawPath(inner)
    p.drawEllipse(_rect(28, 34, 8, 10))
    p.setPen(_pen(st.muted, 2.2))
    p.drawLine(QtCore.QPointF(32, 12), QtCore.QPointF(32, 3))
    p.drawLine(QtCore.QPointF(32, 6), QtCore.QPointF(41, 3))


# ──────────────────────────────────────────────────────────────────────────────
# image-type (role family) icons — the RolePage list rows
# ──────────────────────────────────────────────────────────────────────────────
def _role_desktop(p: QtGui.QPainter, st: IconStyle) -> None:
    """A plain desktop image — one machine, no mesh furniture."""
    _draw_monitor(p, st, 6, 6, 52, 52)


def _role_mesh_desktop(p: QtGui.QPainter, st: IconStyle) -> None:
    """A desktop image that JOINS a mesh — a monitor with an uplink cloud."""
    _draw_cloud(p, st, 30, 2, 32, 20)
    _draw_monitor(p, st, 4, 20, 40, 40)
    _link(p, st, 40, 26, 46, 22)


def _role_board(p: QtGui.QPainter, st: IconStyle) -> None:
    """A single-board-computer image (Pi / Orange Pi / La Frite / Jetson)."""
    _draw_board(p, st, 4, 12, 56, 40, 2.6)


def _role_server(p: QtGui.QPainter, st: IconStyle) -> None:
    """A mesh SERVER node image — stacked rack units with status lamps."""
    p.setPen(_pen(st.fg, 2.4))
    for i in range(3):
        y = 8.0 + i * 17.0
        p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
        p.drawRoundedRect(_rect(8, y, 48, 13), 2.5, 2.5)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.accent)))
    for i in range(3):
        p.drawEllipse(_rect(13, 11.5 + i * 17.0, 5, 5))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.muted)))
    for i in range(3):
        p.drawRect(_rect(24, 12.5 + i * 17.0, 24, 3))


# ──────────────────────────────────────────────────────────────────────────────
# the ask-19/20/22 path icons — domains-at-launch, users-at-launch, launch
# ──────────────────────────────────────────────────────────────────────────────
def _person(p: QtGui.QPainter, st: IconStyle, x: float, y: float, w: float,
            h: float, colour: str | None = None) -> None:
    """One person glyph (head + shoulders) inside the given box."""
    p.setPen(_pen(colour or st.fg, 2.2))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    head = w * 0.42
    p.drawEllipse(_rect(x + (w - head) / 2, y, head, head))
    body = QtGui.QPainterPath()
    body.moveTo(x, y + h)
    body.arcTo(_rect(x, y + head * 1.15, w, (h - head * 1.15) * 2), 180, -180)
    p.drawPath(body)


def _globe(p: QtGui.QPainter, st: IconStyle, x: float, y: float, d: float,
           width: float = 2.2) -> None:
    """A meridian globe — the repo's established "a domain" gesture (see the
    go-live DNS icons), reused so one thing keeps one shape."""
    p.setPen(_pen(st.fg, width))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawEllipse(_rect(x, y, d, d))
    p.setPen(_pen(st.muted, max(1.0, width * 0.62)))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawEllipse(_rect(x + d * 0.28, y, d * 0.44, d))
    p.drawLine(QtCore.QPointF(x, y + d / 2), QtCore.QPointF(x + d, y + d / 2))


def _domain_internal(p: QtGui.QPainter, st: IconStyle) -> None:
    """ONE domain, kept inside: a globe behind a closed padlock."""
    _globe(p, st, 6, 10, 40, 2.4)
    p.setPen(_pen(st.accent, 2.6))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawArc(_rect(38, 26, 16, 18), 0, int(180 * 16))
    p.setPen(_pen(st.fg, 2.2))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawRoundedRect(_rect(35, 36, 22, 20), 3.0, 3.0)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.accent)))
    p.drawEllipse(_rect(43.5, 43, 5, 5))


def _domain_add(p: QtGui.QPainter, st: IconStyle) -> None:
    """MORE domains: two globes and a plus — the table that adds them."""
    _globe(p, st, 2, 8, 30, 2.2)
    _globe(p, st, 20, 30, 26, 2.0)
    p.setPen(_pen(st.accent, 3.2))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawLine(QtCore.QPointF(52, 8), QtCore.QPointF(52, 26))
    p.drawLine(QtCore.QPointF(43, 17), QtCore.QPointF(61, 17))


def _users_generated(p: QtGui.QPainter, st: IconStyle) -> None:
    """The accounts the key-USB mints for you: one person beside a key."""
    _person(p, st, 4, 12, 30, 40)
    p.setPen(_pen(st.accent, 2.8))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawEllipse(_rect(40, 14, 18, 18))
    p.setPen(_pen(st.accent, 3.0))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawLine(QtCore.QPointF(49, 32), QtCore.QPointF(49, 56))
    p.drawLine(QtCore.QPointF(49, 44), QtCore.QPointF(58, 44))
    p.drawLine(QtCore.QPointF(49, 51), QtCore.QPointF(56, 51))


def _users_table(p: QtGui.QPainter, st: IconStyle) -> None:
    """Naming them yourself: three people over a ruled table."""
    for i in range(3):
        _person(p, st, 4.0 + i * 20.0, 6, 16, 22)
    p.setPen(_pen(st.fg, 2.2))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawRoundedRect(_rect(4, 34, 56, 24), 2.5, 2.5)
    p.setPen(_pen(st.muted, 1.6))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawLine(QtCore.QPointF(4, 42), QtCore.QPointF(60, 42))
    p.drawLine(QtCore.QPointF(4, 50), QtCore.QPointF(60, 50))
    p.drawLine(QtCore.QPointF(24, 34), QtCore.QPointF(24, 58))
    p.drawLine(QtCore.QPointF(42, 34), QtCore.QPointF(42, 58))


def _build_run(p: QtGui.QPainter, st: IconStyle) -> None:
    """Start the build: a play triangle on the image-artifact slab."""
    p.setPen(_pen(st.fg, 2.4))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawRoundedRect(_rect(4, 12, 56, 40), 4.0, 4.0)
    p.setPen(_pen(st.muted, 2.0))
    p.drawLine(QtCore.QPointF(4, 22), QtCore.QPointF(60, 22))
    tri = QtGui.QPainterPath()
    tri.moveTo(26, 28)
    tri.lineTo(46, 37)
    tri.lineTo(26, 46)
    tri.closeSubpath()
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.accent)))
    p.drawPath(tri)


def _main_menu(p: QtGui.QPainter, st: IconStyle) -> None:
    """Back to the first screen: a house with a return arrow."""
    roof = QtGui.QPainterPath()
    roof.moveTo(4, 30)
    roof.lineTo(30, 8)
    roof.lineTo(56, 30)
    p.setPen(_pen(st.fg, 2.6))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawPath(roof)
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    p.drawRect(_rect(12, 30, 36, 26))
    _arrow(p, st, 44, 44, 22, 44, width=2.8, head=6.0)


def _sessions(p: QtGui.QPainter, st: IconStyle) -> None:
    """Prior sessions: a stack of build-list rows, the newest wearing its status
    tick — the Previous-builds table as a glyph (WelcomePage's REVIEW card)."""
    p.setPen(_pen(st.fg, 2.2))
    p.setBrush(QtGui.QBrush(QtGui.QColor(st.faint)))
    for y in (8, 26, 44):
        p.drawRoundedRect(_rect(6, y, 38, 12), 3.0, 3.0)
    # a muted label stub inside each row (reads as text at any size)
    p.setPen(_pen(st.muted, 2.0))
    for y in (14, 32, 50):
        p.drawLine(QtCore.QPointF(11, y), QtCore.QPointF(30, y))
    # the newest row's status: an accent tick beside it, drawn last so it reads first
    p.setPen(_pen(st.accent, 3.0))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawLine(QtCore.QPointF(48, 13), QtCore.QPointF(53, 19))
    p.drawLine(QtCore.QPointF(53, 19), QtCore.QPointF(60, 6))


# ──────────────────────────────────────────────────────────────────────────────
# registry
# ──────────────────────────────────────────────────────────────────────────────
ICON_PAINTERS: Dict[str, Callable[[QtGui.QPainter, IconStyle], None]] = {
    # ModePage — the operator's seven
    "mesh": _mesh,
    "localmesh": _localmesh,
    "mesh-desktop": _mesh_desktop,
    "gentoo": _gentoo,
    "phone": _phone,
    "quest": _quest,
    "cloud-deploy": _deploy,
    # IdpPage
    "idp-casdoor": _idp_casdoor,
    "idp-entra": _idp_entra,
    "idp-aws": _idp_aws,
    "idp-oidc": _idp_oidc,
    # GoLiveExposurePage
    "golive-tunnel": _golive_tunnel,
    "golive-public-dns": _golive_public_dns,
    "golive-ddns": _golive_ddns,
    "golive-funnel": _golive_funnel,
    "golive-router": _golive_router,
    "golive-onion": _golive_onion,
    # RolePage image-type rows
    "role-desktop": _role_desktop,
    "role-mesh-desktop": _role_mesh_desktop,
    "role-board": _role_board,
    "role-server": _role_server,
    # DomainsChoicePage / UsersChoicePage (asks 19+20)
    "domain-internal": _domain_internal,
    "domain-add": _domain_add,
    "users-generated": _users_generated,
    "users-table": _users_table,
    # LaunchPage (ask 22)
    "build-run": _build_run,
    "main-menu": _main_menu,
    # WelcomePage (issue #50 welcome flow) — the REVIEW PRIOR SESSIONS card;
    # its other two cards reuse "main-menu" and "localmesh" above.
    "sessions": _sessions,
}

ICON_NAMES = tuple(ICON_PAINTERS)

# ── role -> icon-family classification (presentation only; RolePage list rows) ──
# The image-type list is DERIVED per device, so rows are classified into the four
# role-family glyphs above by role id (+ the current mode for the desktop split).
# Unknown/future roles fall through to the desktop pair — a wrong-family icon is
# cosmetic, and paint() ignores unknown icon names outright.
_SERVER_ROLES = frozenset({"pki", "be", "fe", "be+gpu", "omnibus",
                           "edge_ai", "full", "gpu-host"})
_BOARD_ROLES = frozenset({"generic", "frite", "orangepi5", "orangepizero2",
                          "orangepizero2w", "orangepizero3", "orangepi3-lts",
                          "orangepi4-lts"})


def role_icon_name(role: str, mode: str = "") -> str:
    """Icon-registry name for an image-type row: server rack / bare board /
    standalone desktop / mesh-joined desktop. Pure presentation — never consulted
    by config emission."""
    if role in _SERVER_ROLES:
        return "role-server"
    if role in _BOARD_ROLES:
        return "role-board"
    # desktop-class (standalone-*, laptop, chromebook, desktop, rpi5-desktop,
    # jetson-desktop, …): standalone builds carry no mesh uplink in the glyph.
    return "role-desktop" if mode == "standalone" else "role-mesh-desktop"

# Plain-English provenance for the icons that gesture at a third party. Surfaced as a
# tooltip on the owning card so the drawing is never passed off as the vendor's mark.
ICON_NOTES: Dict[str, str] = {
    "gentoo": ("Icon: our own swirl-and-'g' gesture for Gentoo, drawn in code — "
               "not the Gentoo Foundation's logo artwork."),
    "cloud-deploy": ("Icon: our own marks for AWS / Azure / Cloudflare, drawn in "
                     "code — not the vendors' logo artwork."),
    "idp-entra": ("Icon: our own wedge gesture for Microsoft Entra ID, drawn in "
                  "code — not Microsoft's logo artwork."),
    "idp-aws": ("Icon: our own arc gesture for AWS, drawn in code — not Amazon's "
                "logo artwork."),
}


# ──────────────────────────────────────────────────────────────────────────────
# rendering + cache
# ──────────────────────────────────────────────────────────────────────────────
_CACHE: Dict[Tuple, QtGui.QPixmap] = {}
_CACHE_MAX = 512


def paint(p: QtGui.QPainter, name: str, rect: QtCore.QRectF, st: IconStyle) -> None:
    """Draw ``name`` into ``rect`` on an existing painter (used by the cache filler).

    Unknown names draw nothing rather than raising: an icon is decoration, and under
    PyQt6 an exception escaping a paint slot calls qFatal and kills the Studio.
    """
    fn = ICON_PAINTERS.get(name)
    if fn is None:
        return
    side = min(rect.width(), rect.height())
    if side <= 0:
        return
    p.save()
    try:
        p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing, True)
        p.setRenderHint(QtGui.QPainter.RenderHint.TextAntialiasing, True)
        p.translate(rect.x() + (rect.width() - side) / 2.0,
                    rect.y() + (rect.height() - side) / 2.0)
        p.scale(side / CANVAS, side / CANVAS)
        fn(p, st)
    finally:
        p.restore()


def pixmap(name: str, size: int, st: IconStyle, dpr: float = 1.0) -> QtGui.QPixmap:
    """A rendered, high-DPI-correct, MEMOISED pixmap for ``name``.

    Keyed by (name, size, dpr, style) — a hover that only changes the *card* border
    reuses the same pixmap, and a complex path build never runs on a paint event twice.
    """
    size = max(1, int(size))
    dpr = float(dpr) if dpr and dpr > 0 else 1.0
    key = (name, size, round(dpr, 3), st.key)
    hit = _CACHE.get(key)
    if hit is not None:
        return hit
    pm = QtGui.QPixmap(int(round(size * dpr)), int(round(size * dpr)))
    pm.setDevicePixelRatio(dpr)
    pm.fill(Qt.GlobalColor.transparent)
    p = QtGui.QPainter(pm)
    try:
        paint(p, name, QtCore.QRectF(0, 0, size, size), st)
    finally:
        p.end()
    if len(_CACHE) >= _CACHE_MAX:      # unbounded growth would be its own defect
        _CACHE.clear()
    _CACHE[key] = pm
    return pm


def icon(name: str, size: int, st: IconStyle, dpr: float = 1.0) -> QtGui.QIcon:
    """The same cached render, wrapped as a QIcon (for item views / buttons)."""
    return QtGui.QIcon(pixmap(name, size, st, dpr))


def clear_cache() -> None:
    """Drop every memoised pixmap (a palette/theme change invalidates nothing else —
    the style is part of the key — but tests and a hot reload want a clean slate)."""
    _CACHE.clear()


def cache_size() -> int:
    """How many distinct renders are memoised right now (test/observability hook)."""
    return len(_CACHE)
