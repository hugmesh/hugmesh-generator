"""ChoiceCard / ChoiceCardGroup — big clickable option tiles for pick-one screens.

The wizard's pick-one surfaces (what to build, identity provider, go-live exposure
model) used a bare ``QRadioButton`` + muted description label per option. The operator
asked for each option to be ONE LARGE CLICKABLE CARD instead: the text (title +
description) in a left-hand column, a vector icon right-aligned and vertically centred
opposite it, the whole rectangle obviously clickable with clear hover / focus /
selected / disabled states.

Drop-in surface: :class:`ChoiceCard` is a checkable ``QAbstractButton`` and
:class:`ChoiceCardGroup` a ``QButtonGroup`` subclass, so a converted page keeps the
exact selection API the radio pages exposed — ``group.button(i)``, ``buttons()``,
``checkedButton()``, ``setChecked(True)``, ``property("mode")`` — and the established
tests (and ``validatePage``/``initializePage`` plumbing) keep reading it unchanged.

Keyboard: Tab reaches the cards, Up/Left / Down/Right move the selection through the
group (wrapping, skipping disabled cards), Space/Enter select the focused card. The
focus ring (dotted inner outline) is deliberately distinct from the selected state
(thick highlight border + a check badge — a SHAPE cue, so selection never relies on
colour alone; a disabled card gets a dashed border, the same principle).

Accessibility: every card carries ``accessibleName`` (the title) and
``accessibleDescription`` (the description), so the option is never icon-only.

Theme + cost: all colours derive from the live ``QPalette`` (the Studio does not own
its background) and the icons come from :mod:`choice_icons`' memoised pixmap cache —
a hover repaints the card border but never re-runs a painter build.

Network: NONE. The one link a card may carry (:meth:`ChoiceCard.set_link`) renders the
URL as visible, selectable text and only ever hands the URL to the desktop browser via
``QDesktopServices.openUrl`` on an EXPLICIT click — the Studio itself fetches nothing,
never on hover, never at import.

Qt duality: the venv is PySide6 but the operator runs PyQt6, where an exception
escaping a slot/override calls qFatal and kills the Studio — so every override and
slot here is exception-guarded and only scoped-enum spellings shared by both bindings
are used (via the repo's ``.qt`` shim).
"""
from __future__ import annotations

import sys
import traceback

from .qt import Qt, QtCore, QtGui, QtWidgets
from . import choice_icons
from .styles import muted

__all__ = ["ChoiceCard", "ChoiceCardGroup"]

# card geometry (logical px)
_RADIUS = 8.0
_ICON_SIZE = 56
_MIN_HEIGHT = 76
#: ring of card fill the badge paints around itself so it seats cleanly on ANY
#: backdrop (see :class:`_BadgeOverlay`). Matches the halo the icon pane used to
#: punch out of its own clip, so the established seat geometry is unchanged.
_BADGE_HALO = 2.5


def _log_swallowed(where: str) -> None:
    """A guarded override failed: record it loudly on stderr, but keep the Studio
    alive (under PyQt6 the alternative is qFatal)."""
    print(f"choice_cards: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


class _IconPane(QtWidgets.QWidget):
    """The card's right-hand icon: paints the memoised vector render for the card's
    current palette/enabled state. Mouse-transparent — the card takes the click."""

    def __init__(self, card: "ChoiceCard", icon_name: str):
        super().__init__(card)
        self._card = card
        self._name = icon_name
        self.setFixedSize(_ICON_SIZE, _ICON_SIZE)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        # decoration only — never a focus stop, never announced on its own
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)

    def paintEvent(self, _ev) -> None:  # noqa: N802 (Qt override)
        try:
            if not self._name:
                return
            # selected=False on purpose: the card fill is only a light highlight
            # TINT (not the full Highlight block style_for's selected variant is
            # for), so the normal-contrast icon stays readable on either theme —
            # and the cache key stays selection-independent.
            st = choice_icons.style_for(self.palette(),
                                        enabled=self._card.isEnabled())
            pm = choice_icons.pixmap(self._name, min(self.width(), self.height()),
                                     st, self.devicePixelRatioF())
            p = QtGui.QPainter(self)
            try:
                p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing, True)
                # NOTE: this pane no longer makes room for the check badge. It used
                # to punch a halo seat out of its own clip, but that co-operation was
                # per-pane and could not be inherited by a swapped-in icon widget
                # (set_icon_widget) — see _BadgeOverlay, which now seats the badge
                # itself, above every sibling, for every pane there will ever be.
                p.drawPixmap(0, 0, pm)
            finally:
                p.end()
        except Exception:
            _log_swallowed("_IconPane.paintEvent")


class _BadgeOverlay(QtWidgets.QWidget):
    """The selected-state check badge — painted as the card's TOPMOST child.

    Child widgets paint AFTER their parent, so a badge drawn in
    :meth:`ChoiceCard._paint_card` is at the mercy of whatever occupies the icon
    slot. :class:`_IconPane` used to co-operate by punching a badge-shaped hole out
    of its own clip, but that co-operation lived in the pane, not in the card — so
    :meth:`ChoiceCard.set_icon_widget`, which replaces the pane wholesale, could not
    pass it on. The branding lane's theme swatches are wider than ``_ICON_SIZE`` and
    fill their rect opaquely, and they overpainted roughly half of every checked
    card's badge: the surviving crescent read as a HALF-drawn (indeterminate) tick —
    on a wizard whose headline complaint was "half checked instead of unchecked".

    So the badge stops depending on its neighbours entirely:

    * it is a child widget kept on top of every sibling (see
      :meth:`ChoiceCard.childEvent`), so it is the last thing painted no matter what
      is in the icon slot now or later;
    * it paints its OWN halo ring of card fill (``_BADGE_HALO``), so it seats itself
      cleanly over a vector glyph, an opaque wallpaper swatch, or a pane nobody has
      written yet — the seat is a property of the badge, not a favour from the pane.

    Mouse-transparent and never a focus stop: the CARD takes the click, exactly like
    the icon pane. Paints nothing at all while the card is unchecked.

    Qt duality: guarded like every other override here — under PyQt6 an exception
    escaping a paintEvent calls qFatal and kills the Studio.
    """

    def __init__(self, card: "ChoiceCard"):
        super().__init__(card)
        self._card = card
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)

    def paintEvent(self, _ev) -> None:  # noqa: N802 (Qt override)
        try:
            card = self._card
            if not card.isChecked():
                return                      # unchecked: draw nothing, show nothing
            pal = card.palette()
            role = QtGui.QPalette.ColorRole
            grp = (QtGui.QPalette.ColorGroup.Active if card.isEnabled()
                   else QtGui.QPalette.ColorGroup.Disabled)
            br = card._badge_rect().translated(-self.x(), -self.y())
            p = QtGui.QPainter(self)
            try:
                p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing, True)
                p.setPen(Qt.PenStyle.NoPen)
                # the seat: the card's own fill, so the badge reads on any backdrop
                p.setBrush(QtGui.QBrush(card._card_fill()))
                p.drawEllipse(br.adjusted(-_BADGE_HALO, -_BADGE_HALO,
                                          _BADGE_HALO, _BADGE_HALO))
                # non-colour selected cue: a check badge (shape, not just the border
                # colour) — a filled disc plus the tick, both in the palette pair.
                p.setBrush(QtGui.QBrush(pal.color(grp, role.Highlight)))
                p.drawEllipse(br)
                tick = QtGui.QPen(pal.color(grp, role.HighlightedText), 2.0)
                tick.setCapStyle(Qt.PenCapStyle.RoundCap)
                p.setPen(tick)
                p.drawLine(QtCore.QPointF(br.left() + 3.5, br.center().y() + 0.5),
                           QtCore.QPointF(br.center().x() - 0.5, br.bottom() - 4))
                p.drawLine(QtCore.QPointF(br.center().x() - 0.5, br.bottom() - 4),
                           QtCore.QPointF(br.right() - 3, br.top() + 4.5))
            finally:
                p.end()
        except Exception:
            _log_swallowed("_BadgeOverlay.paintEvent")


class ChoiceCard(QtWidgets.QAbstractButton):
    """One large clickable tile: left text column (bold title + muted wrapped
    description), right-aligned vertically-centred vector icon."""

    def __init__(self, title: str, description: str, icon_name: str = "",
                 parent: QtWidgets.QWidget | None = None):
        super().__init__(parent)
        self.setCheckable(True)
        # the group (ChoiceCardGroup / QButtonGroup) owns exclusivity
        self.setAutoExclusive(False)
        self.setText(title)                       # a11y + test surface, not painted
        self.setAccessibleName(title)
        self.setAccessibleDescription(description)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        # the card FILL derives from palette Window (we custom-paint), so pin the
        # background role: a QAbstractButton's default Button role would make the
        # child labels resolve their foreground to ButtonText — on themes where
        # Button/ButtonText differ from Window/WindowText the title would sit on
        # our Window-derived fill in the WRONG text colour (caught rendering the
        # dark-palette card: near-black title on a near-black card).
        self.setBackgroundRole(QtGui.QPalette.ColorRole.Window)
        self.setCursor(QtGui.QCursor(Qt.CursorShape.PointingHandCursor))
        self.setAttribute(Qt.WidgetAttribute.WA_Hover, True)
        self.setMinimumHeight(_MIN_HEIGHT)
        self.setSizePolicy(QtWidgets.QSizePolicy.Policy.Expanding,
                           QtWidgets.QSizePolicy.Policy.Preferred)
        note = choice_icons.ICON_NOTES.get(icon_name, "")
        if note:                                  # honest provenance for vendor gestures
            self.setToolTip(note)

        row = QtWidgets.QHBoxLayout(self)
        row.setContentsMargins(14, 10, 14, 10)
        row.setSpacing(12)
        self._text_col = QtWidgets.QVBoxLayout()
        self._text_col.setSpacing(2)

        self._title_label = QtWidgets.QLabel(title)
        f = self._title_label.font()
        f.setBold(True)
        self._title_label.setFont(f)
        self._title_label.setWordWrap(True)
        self._title_label.setAttribute(
            Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        self._text_col.addWidget(self._title_label)

        self._desc_label = QtWidgets.QLabel(description)
        self._desc_label.setWordWrap(True)
        self._desc_label.setStyleSheet(muted())   # the shared MUTED, never bare gray
        self._desc_label.setAttribute(
            Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        self._text_col.addWidget(self._desc_label)
        self._text_col.addStretch(1)

        row.addLayout(self._text_col, 1)
        self._icon_pane = _IconPane(self, icon_name)
        row.addWidget(self._icon_pane, 0,
                      Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)

        self._link_label: QtWidgets.QLabel | None = None
        self._link_url = ""
        self._link_text = ""
        # created LAST and kept on top (childEvent) — the badge must outrank every
        # sibling, including any pane a later set_icon_widget() installs.
        self._badge = _BadgeOverlay(self)
        self._sync_badge_geometry()
        self._badge.raise_()
        self.toggled.connect(self._on_toggled)

    def set_description(self, description: str) -> None:
        """Replace the card's muted description AFTER construction.

        Ask 19/20's cards describe the CURRENT config (the domains this mesh already
        serves; the accounts these worklist rows will mint and where their credentials
        land), which is only known in ``initializePage`` — and must be re-read on every
        visit, because a Back to the Network/Worklist step can change it. Keeps the
        accessible description in step with the painted text: a screen reader must never
        read the stale one."""
        self._desc_label.setText(description)
        self.setAccessibleDescription(description)

    # ── optional external link (the Gentoo card) ────────────────────────────────
    def set_link(self, url: str, label: str | None = None) -> QtWidgets.QLabel:
        """Show ``url`` on the card as an explicit-click link AND as visible,
        selectable text (an air-gapped operator can read/copy it without any
        browser). Clicking the anchor is the ONLY thing that opens it — via
        ``QDesktopServices.openUrl``, handing off to the desktop browser; the
        Studio itself never fetches anything."""
        lab = QtWidgets.QLabel()
        lab.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextBrowserInteraction
            | Qt.TextInteractionFlag.TextSelectableByMouse)
        lab.setOpenExternalLinks(False)           # openUrl fires from OUR guarded slot
        lab.setWordWrap(True)
        lab.setStyleSheet(muted())
        lab.linkActivated.connect(self._open_link)
        # NOT mouse-transparent: the link (and text selection) needs real clicks;
        # clicking beside the anchor selects text rather than toggling the card.
        self._text_col.insertWidget(self._text_col.count() - 1, lab)
        self._link_label = lab
        self._link_url = url
        self._link_text = label or url
        self._refresh_link_html()
        return lab

    def link_color(self) -> QtGui.QColor:
        """Anchor colour that actually reads on this card's fills.

        Qt's own default ``QPalette`` leaves the ``Link`` role at pure ``#0000ff``
        even when every other role is dark, and most platform dark themes never set
        it — so an unstyled anchor measures ~1.6:1 on our dark selected fill
        (invisible). Derive instead: start from the palette Highlight and pull it
        towards WindowText until it clears 4.5:1 (the WCAG floor) against every
        fill this card can paint — the same guard :func:`choice_icons.style_for`
        applies to its accent."""
        pal = self.palette()
        role = QtGui.QPalette.ColorRole
        grp = (QtGui.QPalette.ColorGroup.Active if self.isEnabled()
               else QtGui.QPalette.ColorGroup.Disabled)
        text = pal.color(grp, role.WindowText)
        base = pal.color(grp, role.Window)
        hi = pal.color(grp, role.Highlight)
        # every fill _paint_card can put under the label
        fills = (self._mix(base, text, 0.04),      # normal
                 self._mix(base, text, 0.08),      # hover
                 self._mix(base, hi, 0.16),        # selected tint
                 base)                             # disabled
        link = hi
        for _ in range(8):
            if all(choice_icons._contrast(link, f) >= 4.5 for f in fills):
                return link
            link = self._mix(link, text, 0.35)
        # a theme so odd the blend never clears the floor: the text colour is the
        # most readable ink the theme owns — use it rather than a wrong guess.
        return text

    def _refresh_link_html(self) -> None:
        """(Re)render the link label with an explicit anchor colour — recomputed
        here rather than baked once, so a live theme switch re-derives it.

        ``getattr`` guard: Qt delivers PaletteChange DURING ``__init__``'s
        ``super().__init__``, before this instance owns ``_link_label``."""
        if getattr(self, "_link_label", None) is None:
            return
        colour = self.link_color().name()
        self._link_label.setText(
            f'<a href="{self._link_url}" style="color: {colour};">'
            f'{self._link_text}</a> — {self._link_url}')

    def _open_link(self, url: str) -> None:
        """EXPLICIT user click on the anchor — the one permitted hand-off to the
        desktop browser. Never called on hover, never automatically."""
        try:
            QtGui.QDesktopServices.openUrl(QtCore.QUrl(url))
        except Exception:
            _log_swallowed("ChoiceCard._open_link")

    # ── state plumbing ──────────────────────────────────────────────────────────
    def _on_toggled(self, _checked: bool = False) -> None:
        try:
            self.update()
            # the badge only paints while checked, and the icon pane may key off
            # the selection too — repaint the children, not just the card
            self._update_badge()
            self._icon_pane.update()
        except Exception:
            _log_swallowed("ChoiceCard._on_toggled")

    def _update_badge(self) -> None:
        """Repaint the check badge. ``getattr`` guard: Qt delivers PaletteChange (and
        can deliver EnabledChange) DURING ``super().__init__``, before this instance
        owns ``_badge`` — the same hazard ``_refresh_link_html`` documents."""
        badge = getattr(self, "_badge", None)
        if badge is not None:
            badge.update()

    def _badge_rect(self) -> QtCore.QRectF:
        """The selected-state check badge, in CARD coordinates — the single source
        for :class:`_BadgeOverlay` (which draws it, plus its halo seat) and for the
        tests that measure it."""
        r = QtCore.QRectF(self.rect()).adjusted(1.5, 1.5, -1.5, -1.5)
        return QtCore.QRectF(r.right() - 22, r.top() + 6, 16, 16)

    def _sync_badge_geometry(self) -> None:
        """Park the overlay over :meth:`_badge_rect` plus its halo (and one pixel of
        antialiasing slack). Cheap and idempotent — it is called from
        :meth:`resizeEvent` AND from :meth:`_paint_card`, because Qt defers the
        resize event of a widget that has never been shown (``WA_PendingResizeEvent``)
        and the tests — like ``grab()`` on an offscreen card — paint without showing.

        ``getattr`` guard: building the layout in ``__init__`` already resizes the
        card, so Qt calls :meth:`resizeEvent` before this instance owns ``_badge``."""
        badge = getattr(self, "_badge", None)
        if badge is None:
            return
        pad = _BADGE_HALO + 1.0
        want = self._badge_rect().adjusted(-pad, -pad, pad, pad).toAlignedRect()
        if badge.geometry() != want:
            badge.setGeometry(want)

    def childEvent(self, ev) -> None:  # noqa: N802 (Qt override)
        """Keep the check badge above every sibling.

        A widget added later sits ON TOP of the stacking order, so without this any
        future ``set_icon_widget`` (or any child added by a subclass) would paint over
        the badge — the exact defect the branding lane's opaque theme swatches caused.
        Restacking here makes "the badge is the last thing painted" a property of the
        CARD rather than a rule each pane has to remember."""
        try:
            badge = getattr(self, "_badge", None)
            if (badge is not None
                    and ev.type() == QtCore.QEvent.Type.ChildAdded
                    and ev.child() is not badge):
                badge.raise_()
        except Exception:
            _log_swallowed("ChoiceCard.childEvent")
        try:
            super().childEvent(ev)
        except Exception:
            _log_swallowed("ChoiceCard.childEvent(super)")

    def resizeEvent(self, ev) -> None:  # noqa: N802 (Qt override)
        try:
            self._sync_badge_geometry()
        except Exception:
            _log_swallowed("ChoiceCard.resizeEvent")
        try:
            super().resizeEvent(ev)
        except Exception:
            _log_swallowed("ChoiceCard.resizeEvent(super)")

    # ── keyboard ────────────────────────────────────────────────────────────────
    def _move_selection(self, delta: int) -> bool:
        """Arrow-key step: select (and focus) the next/previous ENABLED card in
        the group, wrapping — radio-group semantics on tiles."""
        grp = self.group()
        if grp is None:
            return False
        cards = [b for b in grp.buttons() if b.isEnabled()]
        if len(cards) < 2 or self not in cards:
            return False
        nxt = cards[(cards.index(self) + delta) % len(cards)]
        nxt.setChecked(True)
        nxt.setFocus(Qt.FocusReason.TabFocusReason)
        return True

    def keyPressEvent(self, ev) -> None:  # noqa: N802 (Qt override)
        try:
            key = ev.key()
            if key in (Qt.Key.Key_Down, Qt.Key.Key_Right):
                if self._move_selection(+1):
                    ev.accept()
                    return
            elif key in (Qt.Key.Key_Up, Qt.Key.Key_Left):
                if self._move_selection(-1):
                    ev.accept()
                    return
            elif key in (Qt.Key.Key_Space, Qt.Key.Key_Return, Qt.Key.Key_Enter):
                if self.isEnabled():
                    self.click()
                    ev.accept()
                    return
            super().keyPressEvent(ev)
        except Exception:
            _log_swallowed("ChoiceCard.keyPressEvent")

    # ── painting ────────────────────────────────────────────────────────────────
    def event(self, ev) -> bool:
        try:
            if ev.type() in (QtCore.QEvent.Type.HoverEnter,
                             QtCore.QEvent.Type.HoverLeave,
                             QtCore.QEvent.Type.FocusIn,
                             QtCore.QEvent.Type.FocusOut,
                             QtCore.QEvent.Type.EnabledChange):
                self.update()
                self._update_badge()      # its halo tracks the card's fill
            elif ev.type() == QtCore.QEvent.Type.PaletteChange:
                # theme flipped under us: the baked anchor colour must re-derive
                self._refresh_link_html()
                self.update()
                self._update_badge()
            return super().event(ev)
        except Exception:
            _log_swallowed("ChoiceCard.event")
            return True

    # ── BRANDING-LANE HOOK (ask 6) — additive, nothing above changes ────────────
    def set_icon_widget(self, widget: QtWidgets.QWidget) -> QtWidgets.QWidget:
        """Swap the card's right-hand icon pane for ``widget``.

        A theme card previews a WALLPAPER, not a concept, so its right-hand pane is a
        live-painted colour swatch rather than one of :mod:`choice_icons`' vector
        glyphs. ``widget`` is given the icon pane's contract explicitly here —
        mouse-transparent (the CARD takes the click), never a focus stop, repainted
        whenever the card's checked state changes (``_on_toggled`` updates
        ``self._icon_pane``) — so selection, keyboard and accessibility behaviour are
        untouched.

        ``widget`` may be any size and may fill its rect opaquely: it is added AFTER
        the check badge, and :meth:`childEvent` restacks the badge above it, so the
        selected-state tick still paints last and still gets its halo seat. (It did
        not always: an earlier revision of this hook let the theme swatches overpaint
        half of every checked card's badge, and the crescent that survived read as a
        half-drawn tick. The seat now belongs to :class:`_BadgeOverlay`, not to the
        pane, precisely so a swapped pane cannot take it away.)
        """
        row = self.layout()
        row.removeWidget(self._icon_pane)
        self._icon_pane.setParent(None)
        self._icon_pane.deleteLater()
        widget.setParent(self)
        widget.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        widget.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        row.addWidget(widget, 0,
                      Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        self._icon_pane = widget
        self._badge.raise_()          # belt & braces alongside childEvent
        return widget

    def _card_fill(self) -> QtGui.QColor:
        """The rounded rect's fill for the card's CURRENT state — the one place the
        four fills are decided, shared with :class:`_BadgeOverlay`, which rings the
        badge with it so the seat can never drift from the card underneath it."""
        pal = self.palette()
        role = QtGui.QPalette.ColorRole
        grp = (QtGui.QPalette.ColorGroup.Active if self.isEnabled()
               else QtGui.QPalette.ColorGroup.Disabled)
        base = pal.color(grp, role.Window)
        if not self.isEnabled():
            return base
        if self.isChecked():
            return self._mix(base, pal.color(grp, role.Highlight), 0.16)
        text = pal.color(grp, role.WindowText)
        return self._mix(base, text, 0.08 if self.underMouse() else 0.04)

    @staticmethod
    def _mix(a: QtGui.QColor, b: QtGui.QColor, t: float) -> QtGui.QColor:
        return QtGui.QColor(round(a.red() + (b.red() - a.red()) * t),
                            round(a.green() + (b.green() - a.green()) * t),
                            round(a.blue() + (b.blue() - a.blue()) * t))

    def paintEvent(self, _ev) -> None:  # noqa: N802 (Qt override)
        try:
            self._paint_card()
        except Exception:
            _log_swallowed("ChoiceCard.paintEvent")

    def _paint_card(self) -> None:
        # the overlay's geometry must be right before it paints (children paint
        # after us, and a never-shown card gets no resize event) — see
        # _sync_badge_geometry. Cheap: one QRect compare on the common path.
        self._sync_badge_geometry()
        p = QtGui.QPainter(self)
        try:
            p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing, True)
            pal = self.palette()
            role = QtGui.QPalette.ColorRole
            grp = (QtGui.QPalette.ColorGroup.Active if self.isEnabled()
                   else QtGui.QPalette.ColorGroup.Disabled)
            base = pal.color(grp, role.Window)
            text = pal.color(grp, role.WindowText)
            hi = pal.color(grp, role.Highlight)
            checked = self.isChecked()
            hover = self.isEnabled() and self.underMouse()

            fill = self._card_fill()
            border = self._mix(base, text, 0.35)
            width = 1.2
            style = Qt.PenStyle.SolidLine
            if not self.isEnabled():
                # non-colour disabled cue: dashed outline (plus the platform's
                # greyed child text)
                style = Qt.PenStyle.DashLine
                border = self._mix(base, text, 0.25)
            elif checked:
                border = hi
                width = 2.6
            elif hover:
                border = self._mix(base, text, 0.55)
                width = 1.8
            pen = QtGui.QPen(border, width, style)
            p.setPen(pen)
            p.setBrush(QtGui.QBrush(fill))
            r = QtCore.QRectF(self.rect()).adjusted(1.5, 1.5, -1.5, -1.5)
            p.drawRoundedRect(r, _RADIUS, _RADIUS)

            # the selected-state check badge is NOT drawn here: it is drawn by
            # _BadgeOverlay, the card's topmost child, because children paint after
            # their parent and an icon pane would otherwise overpaint it.

            if self.hasFocus():
                # focus ring: dotted INNER outline in the text colour — visibly
                # different from the selected state's thick solid highlight border
                ring = QtGui.QPen(text, 1.2, Qt.PenStyle.DotLine)
                p.setPen(ring)
                p.setBrush(Qt.BrushStyle.NoBrush)
                p.drawRoundedRect(r.adjusted(3.0, 3.0, -3.0, -3.0),
                                  _RADIUS - 2.0, _RADIUS - 2.0)
        finally:
            p.end()


class ChoiceCardGroup(QtWidgets.QButtonGroup):
    """Exclusive selection over :class:`ChoiceCard` tiles.

    A ``QButtonGroup`` subclass on purpose: the pages' ``self.group`` keeps the
    exact ``button(i)`` / ``buttons()`` / ``checkedButton()`` / ``buttonToggled``
    surface the radio implementation exposed, so callers and tests are unchanged."""

    def __init__(self, parent: QtCore.QObject | None = None):
        super().__init__(parent)
        self.setExclusive(True)

    def add_card(self, card: ChoiceCard, cid: int) -> ChoiceCard:
        """Register ``card`` under integer id ``cid`` (== the page's option index,
        exactly like the old ``group.addButton(rb, i)``)."""
        self.addButton(card, cid)
        return card
