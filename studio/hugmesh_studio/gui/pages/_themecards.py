"""Theme picker for the branding section — choice cards with a live preview swatch.

Ask 6 asked for the branding section to be redone with exactly four premade themes.
Picking a theme is a PICK-ONE over a small closed set, which is precisely what the
#507 choice-card idiom was built for, so the picker is a
:class:`~..choice_cards.ChoiceCardGroup` of :class:`ThemeCard` tiles rather than the
old non-editable ``QComboBox``. Three things a combo could not do and this can:

* a theme is a LOOK — the card carries a **preview swatch** painted from the very
  numbers ``scripts/gen-branding-themes.py`` renders the wallpaper from
  (``core.branding_themes.THEME_SPECS``), so the preview cannot drift from the file
  it previews. A combo could only ever show the word "purple";
* every option is on screen at once, so "which four exist" is answerable by looking,
  which is the actual complaint behind "redo entire branding section";
* a card states in prose WHY you would pick it (bright panel? colour-critical work?),
  which a one-line combo entry has nowhere to put.

The swatch is a MINIATURE of the real wallpaper composition — vertical gradient,
hexagon mark, two-weight brand rule — not an abstract colour chip, so the card shows
the operator the thing they are choosing.

``None`` (no premade theme, stock look) is a card too: it paints from the LIVE Qt
palette with a diagonal strike, so "no theme" reads as a deliberate option rather
than an empty combo row.

Qt duality: the venv is PySide6, the operator runs PyQt6, where an exception escaping
a paint handler calls ``qFatal`` and kills the Studio — so every ``paintEvent`` here
is exception-guarded exactly like ``choice_cards``' own, and only scoped-enum
spellings shared by both bindings are used.
"""
from __future__ import annotations

import sys
import traceback

from ..choice_cards import ChoiceCard, ChoiceCardGroup
from ..qt import Qt, QtCore, QtGui, QtWidgets
from ...core.branding_themes import PREMADE_THEMES, THEME_SPECS, ThemeSpec

__all__ = ["ThemeCard", "ThemeCardGroup", "ThemeSwatch", "ThemeStripSwatch",
           "CustomAssetsSwatch", "NO_THEME"]

#: the card id / config value meaning "no premade theme — stock look"
NO_THEME = ""

_SWATCH_W, _SWATCH_H = 96, 58
_SQRT3_2 = 0.8660254037844386          # sqrt(3)/2 — the hexagon's half-width factor


def _log_swallowed(where: str) -> None:
    print(f"_themecards: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


def _hex_polygon(cx: float, cy: float, r: float) -> QtGui.QPolygonF:
    """A pointy-top regular hexagon — the same mark the generated wallpaper draws."""
    pts = [(0.0, -r), (r * _SQRT3_2, -r / 2.0), (r * _SQRT3_2, r / 2.0),
           (0.0, r), (-r * _SQRT3_2, r / 2.0), (-r * _SQRT3_2, -r / 2.0)]
    return QtGui.QPolygonF([QtCore.QPointF(cx + x, cy + y) for x, y in pts])


class ThemeSwatch(QtWidgets.QWidget):
    """A miniature of one theme's wallpaper (or, with ``spec=None``, the "stock look"
    tile painted from the live palette)."""

    def __init__(self, spec: ThemeSpec | None, parent: QtWidgets.QWidget | None = None):
        super().__init__(parent)
        self.spec = spec
        self.setFixedSize(_SWATCH_W, _SWATCH_H)

    def paintEvent(self, _ev) -> None:  # noqa: N802 (Qt override)
        try:
            self._paint()
        except Exception:
            _log_swallowed("ThemeSwatch.paintEvent")

    def _paint(self) -> None:
        p = QtGui.QPainter(self)
        try:
            p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing, True)
            r = QtCore.QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
            path = QtGui.QPainterPath()
            path.addRoundedRect(r, 5.0, 5.0)
            p.setClipPath(path)
            pal = self.palette()
            role = QtGui.QPalette.ColorRole
            if self.spec is None:
                self._paint_stock(p, r, pal, role)
            else:
                self._paint_theme(p, r, self.spec)
            # hairline frame so a near-window-coloured swatch still reads as a tile
            p.setClipping(False)
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.setPen(QtGui.QPen(pal.color(role.WindowText), 1.0))
            p.setOpacity(0.35)
            p.drawRoundedRect(r, 5.0, 5.0)
        finally:
            p.end()

    def _paint_theme(self, p: QtGui.QPainter, r: QtCore.QRectF, spec: ThemeSpec) -> None:
        """The wallpaper composition at swatch scale: gradient, mark, brand rule.
        Geometry mirrors ``render_wallpaper``'s proportions (mark at 0.68w / 0.44h,
        rule at 0.74h) so the preview is a real miniature, not a decoration."""
        grad = QtGui.QLinearGradient(r.topLeft(), r.bottomLeft())
        grad.setColorAt(0.0, QtGui.QColor(spec.top))
        grad.setColorAt(1.0, QtGui.QColor(spec.bottom))
        p.setPen(Qt.PenStyle.NoPen)
        p.fillRect(r, QtGui.QBrush(grad))

        accent, dim = QtGui.QColor(spec.accent), QtGui.QColor(spec.dim)
        cx = r.left() + r.width() * 0.68
        cy = r.top() + r.height() * 0.44
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.setPen(QtGui.QPen(accent, 1.6))
        p.drawPolygon(_hex_polygon(cx, cy, r.height() * 0.30))
        p.setPen(QtGui.QPen(dim, 1.0))
        p.drawPolygon(_hex_polygon(cx, cy, r.height() * 0.17))

        p.setPen(Qt.PenStyle.NoPen)
        x0 = r.left() + r.width() * 0.08
        y0 = r.top() + r.height() * 0.74
        p.fillRect(QtCore.QRectF(x0, y0, r.width() * 0.30, 2.4), accent)
        p.fillRect(QtCore.QRectF(x0, y0 + 4.4, r.width() * 0.20, 1.2), dim)

    def _paint_stock(self, p: QtGui.QPainter, r: QtCore.QRectF,
                     pal: QtGui.QPalette, role) -> None:
        """"No premade theme": the operator's own desktop colours, struck through."""
        base = pal.color(role.Window)
        text = pal.color(role.WindowText)
        p.setPen(Qt.PenStyle.NoPen)
        p.fillRect(r, base)
        pen = QtGui.QPen(text, 1.4)
        pen.setCapStyle(Qt.PenCapStyle.RoundCap)
        p.setPen(pen)
        p.setOpacity(0.55)
        p.drawLine(QtCore.QPointF(r.left() + 8, r.bottom() - 8),
                   QtCore.QPointF(r.right() - 8, r.top() + 8))
        p.setOpacity(1.0)


class ThemeStripSwatch(QtWidgets.QWidget):
    """A four-up chip strip — one chip per premade theme — for the "Premade theme"
    fork card. The fork card's job is to say WHAT lies behind it, and four coloured
    chips say "four themes" faster than the sentence does. Built from the same
    ``THEME_SPECS`` table, so it grows/shrinks with the declared set automatically."""

    def __init__(self, parent: QtWidgets.QWidget | None = None):
        super().__init__(parent)
        self.setFixedSize(_SWATCH_W, _SWATCH_H)

    def paintEvent(self, _ev) -> None:  # noqa: N802 (Qt override)
        try:
            self._paint()
        except Exception:
            _log_swallowed("ThemeStripSwatch.paintEvent")

    def _paint(self) -> None:
        p = QtGui.QPainter(self)
        try:
            p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing, True)
            names = tuple(PREMADE_THEMES)
            if not names:
                return
            r = QtCore.QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
            gap = 3.0
            w = (r.width() - gap * (len(names) - 1)) / len(names)
            for i, name in enumerate(names):
                spec = THEME_SPECS[name]
                chip = QtCore.QRectF(r.left() + i * (w + gap), r.top(), w, r.height())
                grad = QtGui.QLinearGradient(chip.topLeft(), chip.bottomLeft())
                grad.setColorAt(0.0, QtGui.QColor(spec.top))
                grad.setColorAt(1.0, QtGui.QColor(spec.bottom))
                path = QtGui.QPainterPath()
                path.addRoundedRect(chip, 3.0, 3.0)
                p.setPen(Qt.PenStyle.NoPen)
                p.fillPath(path, QtGui.QBrush(grad))
                # the accent, as the bar the wallpaper draws in the same place
                p.fillRect(QtCore.QRectF(chip.left() + 2, chip.bottom() - 8,
                                         chip.width() - 4, 2.4),
                           QtGui.QColor(spec.accent))
        finally:
            p.end()


class CustomAssetsSwatch(QtWidgets.QWidget):
    """"Your own files" pane for the custom-branding fork card: a folder gesture with
    two asset sheets, drawn from the LIVE palette (the Studio does not own its
    background, so nothing here hardcodes a colour). Original geometry — no vendor
    mark, no imported artwork."""

    def __init__(self, parent: QtWidgets.QWidget | None = None):
        super().__init__(parent)
        self.setFixedSize(_SWATCH_W, _SWATCH_H)

    def paintEvent(self, _ev) -> None:  # noqa: N802 (Qt override)
        try:
            self._paint()
        except Exception:
            _log_swallowed("CustomAssetsSwatch.paintEvent")

    def _paint(self) -> None:
        p = QtGui.QPainter(self)
        try:
            p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing, True)
            pal = self.palette()
            role = QtGui.QPalette.ColorRole
            grp = (QtGui.QPalette.ColorGroup.Active if self.isEnabled()
                   else QtGui.QPalette.ColorGroup.Disabled)
            ink = pal.color(grp, role.WindowText)
            hi = pal.color(grp, role.Highlight)
            r = QtCore.QRectF(self.rect()).adjusted(8.5, 6.5, -8.5, -6.5)
            # two asset sheets peeking out from behind the folder
            p.setPen(QtGui.QPen(ink, 1.0))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.setOpacity(0.45)
            p.drawRoundedRect(QtCore.QRectF(r.left() + 12, r.top(),
                                            r.width() - 26, r.height() - 12), 2.0, 2.0)
            p.drawRoundedRect(QtCore.QRectF(r.left() + 18, r.top() + 4,
                                            r.width() - 26, r.height() - 12), 2.0, 2.0)
            # the folder itself: body + tab
            p.setOpacity(1.0)
            body = QtCore.QRectF(r.left(), r.top() + 10, r.width() - 4, r.height() - 10)
            p.setPen(QtGui.QPen(hi, 1.6))
            p.drawRoundedRect(body, 3.0, 3.0)
            tab = QtGui.QPainterPath()
            tab.moveTo(body.left() + 1, body.top())
            tab.lineTo(body.left() + 1, body.top() - 6)
            tab.lineTo(body.left() + 15, body.top() - 6)
            tab.lineTo(body.left() + 20, body.top())
            p.drawPath(tab)
        finally:
            p.end()


class ThemeCard(ChoiceCard):
    """One premade theme (or the stock-look option) as a choice card.

    ``theme_name`` is the EXACT string committed to ``cfg.theme`` and emitted as
    ``--theme NAME`` — "" for the stock-look card. Nothing derives the name from the
    card's title, so retitling a card can never change what the builder receives.
    """

    def __init__(self, theme_name: str, title: str, description: str,
                 parent: QtWidgets.QWidget | None = None):
        super().__init__(title, description, "", parent)
        self.theme_name = theme_name
        spec = THEME_SPECS.get(theme_name) if theme_name else None
        self.swatch = ThemeSwatch(spec)
        self.set_icon_widget(self.swatch)
        # a11y: the swatch is decoration, so the accent has to be readable as TEXT too
        if spec is not None:
            self.setAccessibleDescription(f"{description} Accent {spec.accent}.")


class ThemeCardGroup(ChoiceCardGroup):
    """The five theme cards (stock look + the four premade themes) as one pick-one.

    Ids are indices into ``order()`` — but callers should use :meth:`selected` /
    :meth:`select`, which speak THEME NAMES, so a reordering of the cards can never
    change which theme a saved config resolves to.
    """

    def __init__(self, parent: QtCore.QObject | None = None):
        super().__init__(parent)
        self.cards: dict[str, ThemeCard] = {}

    @staticmethod
    def order() -> tuple[str, ...]:
        """Card order: stock look first (it is the default), then the declared four."""
        return (NO_THEME,) + tuple(PREMADE_THEMES)

    def build(self, container: QtWidgets.QWidget) -> None:
        """Create one card per option into ``container``'s layout."""
        lay = container.layout()
        for i, name in enumerate(self.order()):
            if name == NO_THEME:
                card = ThemeCard(
                    NO_THEME, "No premade theme",
                    "Ship the stock look — no wallpaper, boot screen or colour scheme "
                    "is baked. Pick this unless you want one of the four below.")
            else:
                spec = THEME_SPECS[name]
                card = ThemeCard(name, spec.title, spec.description)
            self.add_card(card, i)
            self.cards[name] = card
            lay.addWidget(card)

    def selected(self) -> str:
        """The checked card's theme name ("" = stock look; also the fallback when
        nothing is checked, which is the same emission)."""
        btn = self.checkedButton()
        return getattr(btn, "theme_name", NO_THEME) if btn is not None else NO_THEME

    def select(self, name: str) -> bool:
        """Check the card for ``name``. Returns False (and selects the stock-look
        card) for a name this build does not offer — the caller shows the note; a
        theme the GUI cannot offer must never be silently kept, because the builder
        would hard-error on it."""
        card = self.cards.get(name)
        if card is None:
            self.cards[NO_THEME].setChecked(True)
            return False
        card.setChecked(True)
        return True
