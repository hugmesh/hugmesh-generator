"""Choice cards + drawn-in-code icons — the pick-one tiles and their vector glyphs.

Covers the conversion of the wizard's pick-one surfaces (ModePage, IdpPage,
GoLiveExposurePage) from radio rows to large clickable ChoiceCards, and the
choice_icons registry behind them:

- each converted surface renders ONE card per option, ids/order unchanged;
- selection round-trips through the same group/property surface the radios had;
- keyboard: arrows move+select through the group, Enter/Space select;
- every registered icon paints without raising and non-blank; no two icons render
  identically (an identical pair means a silhouette is not doing its job);
- the pixmap cache really caches (a second request never re-runs the painter);
- the card modules import NO network machinery (air-gap hard rule) — the single
  QDesktopServices.openUrl hand-off lives in the explicit-click link slot;
- accessibleName/Description are set, so no option is icon-only;
- the Gentoo card carries gentoo.org as an explicit-click link AND as visible
  selectable text;
- RolePage image-type rows carry a role-family glyph.

Runs on Qt's offscreen platform; skipped whole when no Qt binding is installed.
"""
import ast
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import IDP_CHOICES, IDP_LABELS       # noqa: E402
from hugmesh_studio.gui import choice_cards as cc                    # noqa: E402
from hugmesh_studio.gui import choice_icons as ci                    # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                  # noqa: E402
from hugmesh_studio.gui.pages import golive as golive_mod            # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtCore, QtGui, QtWidgets       # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    yield w
    w.close()
    w.deleteLater()


def _page(wiz, cls_name):
    for pid in wiz.pageIds():
        page = wiz.page(pid)
        if type(page).__name__ == cls_name:
            return page
    raise AssertionError(f"page {cls_name} not registered")


def _style():
    return ci.style_for(QtGui.QPalette())


def _png(pm: QtGui.QPixmap) -> bytes:
    """Binding-portable raw bytes of a pixmap (PNG round-trip — PyQt6's
    constBits() and PySide6's differ, a saved buffer does not)."""
    ba = QtCore.QByteArray()
    buf = QtCore.QBuffer(ba)
    buf.open(QtCore.QIODevice.OpenModeFlag.WriteOnly)
    pm.toImage().save(buf, "PNG")
    buf.close()
    return bytes(ba.data())


def _blank_png(size: int) -> bytes:
    pm = QtGui.QPixmap(size, size)
    pm.fill(Qt.GlobalColor.transparent)
    return _png(pm)


def _key(widget, key):
    ev = QtGui.QKeyEvent(QtCore.QEvent.Type.KeyPress, key,
                         Qt.KeyboardModifier.NoModifier)
    QtWidgets.QApplication.sendEvent(widget, ev)


# ── surfaces render one card per option, ids/order byte-identical ────────────────

def test_mode_page_renders_seven_cards_with_the_radio_ids(wiz):
    page = _page(wiz, "ModePage")
    cards = page.group.buttons()
    assert len(cards) == 7 == len(page.modes)
    assert [c.property("mode") for c in cards] == [m for m, _, _ in page.modes]
    for i, card in enumerate(cards):
        assert isinstance(card, cc.ChoiceCard)
        assert page.group.button(i) is card          # id == option index, as before
    # option ids are the parity contract with validatePage/cfg — pinned verbatim
    assert [m for m, _, _ in page.modes] == [
        "mesh", "localmesh", "cloud", "standalone", "phone", "quest", "deploy"]


def test_idp_page_renders_one_card_per_idp_choice(wiz):
    page = _page(wiz, "IdpPage")
    cards = page.group.buttons()
    assert [c.property("idp") for c in cards] == list(IDP_CHOICES)
    for c in cards:
        assert isinstance(c, cc.ChoiceCard)
        assert c.accessibleName() == IDP_LABELS[c.property("idp")]


def test_golive_exposure_page_renders_one_card_per_registry_model(qapp, monkeypatch):
    monkeypatch.setattr(
        golive_mod.GoLiveDriver, "status_text", lambda self: "posture: INTERNAL")
    gwiz = golive_mod.GoLiveWizard(GENERATOR_DIR)
    try:
        page = _page(gwiz, "GoLiveExposurePage")
        cards = page.group.buttons()
        assert [c.property("model") for c in cards] == page.models
        assert len(cards) == len(page.models) > 0
        for c in cards:
            assert isinstance(c, cc.ChoiceCard)
        # the six drawn models map onto registered glyphs by name
        for model in ("tunnel", "public-dns", "ddns", "funnel", "router", "onion"):
            if model in page.models:
                assert f"golive-{model}" in ci.ICON_PAINTERS
    finally:
        gwiz.close()
        gwiz.deleteLater()


# ── selection round-trips through the unchanged group surface ───────────────────

def test_card_click_round_trips_into_cfg_mode(wiz):
    page = _page(wiz, "ModePage")
    page._buttons["cloud"].click()
    assert page.group.checkedButton().property("mode") == "cloud"
    assert page.validatePage() is True
    assert wiz.cfg.mode == "cloud"


def test_loaded_config_reselects_its_card(wiz):
    wiz.cfg.mode = "mesh"
    page = _page(wiz, "ModePage")
    page.initializePage()
    assert page.group.checkedButton() is page._buttons["mesh"]


# ── keyboard: arrows move+select, Enter/Space select ────────────────────────────

def test_arrow_keys_move_the_selection_through_the_cards(wiz):
    page = _page(wiz, "ModePage")
    page._buttons["standalone"].setChecked(True)      # index 3
    _key(page._buttons["standalone"], Qt.Key.Key_Down)
    assert page.group.checkedButton().property("mode") == "phone"
    _key(page._buttons["phone"], Qt.Key.Key_Up)
    assert page.group.checkedButton().property("mode") == "standalone"
    # wraps at the edges instead of dead-ending
    page._buttons["deploy"].setChecked(True)
    _key(page._buttons["deploy"], Qt.Key.Key_Right)
    assert page.group.checkedButton().property("mode") == "mesh"
    _key(page._buttons["mesh"], Qt.Key.Key_Left)
    assert page.group.checkedButton().property("mode") == "deploy"


def test_enter_and_space_select_the_focused_card(wiz):
    page = _page(wiz, "ModePage")
    page._buttons["standalone"].setChecked(True)
    _key(page._buttons["quest"], Qt.Key.Key_Return)
    assert page.group.checkedButton().property("mode") == "quest"
    _key(page._buttons["phone"], Qt.Key.Key_Space)
    assert page.group.checkedButton().property("mode") == "phone"


def test_arrow_keys_skip_a_disabled_card(qapp):
    group = cc.ChoiceCardGroup()
    host = QtWidgets.QWidget()
    cards = [cc.ChoiceCard(f"c{i}", "d", parent=host) for i in range(3)]
    for i, c in enumerate(cards):
        group.add_card(c, i)
    cards[1].setEnabled(False)
    cards[0].setChecked(True)
    _key(cards[0], Qt.Key.Key_Down)
    assert group.checkedButton() is cards[2]          # skipped the disabled middle
    host.deleteLater()


# ── icons: paint, non-blank, pairwise distinct ──────────────────────────────────

def test_every_registered_icon_paints_non_blank(qapp):
    blank = _blank_png(64)
    st = _style()
    for name in ci.ICON_NAMES:
        pm = ci.pixmap(name, 64, st, 1.0)             # must not raise
        assert pm.width() == 64
        assert _png(pm) != blank, f"icon {name!r} rendered blank"


def test_no_two_icons_render_identically(qapp):
    st = _style()
    renders = {name: _png(ci.pixmap(name, 64, st, 1.0)) for name in ci.ICON_NAMES}
    names = list(renders)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            assert renders[a] != renders[b], f"icons {a!r} and {b!r} are identical"


def test_unknown_icon_name_paints_nothing_rather_than_raising(qapp):
    st = _style()
    assert _png(ci.pixmap("no-such-icon", 48, st, 1.0)) == _blank_png(48)


def test_vendor_labels_shrink_to_fit_their_tile(qapp):
    """Recovered-WIP audit regression: 'AZURE' at a fixed 8px clipped to 'ZURI'
    inside its 20-unit cloud-deploy tile (QPainter.drawText clips at the rect).
    _draw_label must treat px as a MAXIMUM and shrink until the text fits."""

    class RecordingPainter(QtGui.QPainter):
        sizes: list

        def setFont(self, f):
            self.sizes.append(f.pixelSize())
            super().setFont(f)

    def final_size(text, w, px):
        pm = QtGui.QPixmap(64, 64)
        pm.fill(Qt.GlobalColor.transparent)
        p = RecordingPainter(pm)
        p.sizes = []
        try:
            ci._draw_label(p, _style(), text, 0, 20, w, 14, px=px)
        finally:
            p.end()
        assert p.sizes, "_draw_label never set a font"
        return p.sizes[-1]

    assert final_size("AZURE", 20, 8) < 8      # shrinks: 8px 'AZURE' can't fit 20
    assert final_size("CF", 20, 8) == 8        # already fits: keeps the asked size


def test_high_dpi_render_carries_the_device_pixel_ratio(qapp):
    st = _style()
    pm = ci.pixmap("mesh", 48, st, 2.0)
    assert pm.devicePixelRatio() == pytest.approx(2.0)
    assert pm.width() == 96                            # physical px = logical * dpr


# ── the pixmap cache actually caches ────────────────────────────────────────────

def test_pixmap_cache_runs_the_painter_once_per_appearance(qapp, monkeypatch):
    calls = {"n": 0}
    orig = ci.ICON_PAINTERS["mesh"]

    def counting(p, st):
        calls["n"] += 1
        orig(p, st)

    monkeypatch.setitem(ci.ICON_PAINTERS, "mesh", counting)
    ci.clear_cache()
    st = _style()
    first = ci.pixmap("mesh", 48, st, 1.0)
    second = ci.pixmap("mesh", 48, st, 1.0)
    assert calls["n"] == 1                             # painter built ONCE
    assert second is first                             # the very same pixmap back
    ci.pixmap("mesh", 64, st, 1.0)                     # a new appearance re-runs it
    assert calls["n"] == 2
    ci.clear_cache()


# ── air-gap: the card/icon modules import no network machinery ──────────────────

_BANNED_IMPORTS = ("urllib", "requests", "http", "httplib", "socket", "ftplib",
                   "QtNetwork", "QtWebEngine", "QtWebEngineWidgets")


@pytest.mark.parametrize("mod", [cc, ci])
def test_modules_import_no_network_machinery(mod):
    with open(os.path.abspath(mod.__file__), encoding="utf-8") as fh:
        tree = ast.parse(fh.read())
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(a.name.split(".")[0] for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                imported.update(node.module.split("."))
            imported.update(a.name for a in node.names)
    for banned in _BANNED_IMPORTS:
        assert banned not in imported, f"{banned} imported by {mod.__name__}"


def test_the_only_openurl_is_the_explicit_click_link_slot():
    with open(os.path.abspath(ci.__file__), encoding="utf-8") as fh:
        assert "openUrl" not in fh.read()              # icons NEVER touch a browser
    with open(os.path.abspath(cc.__file__), encoding="utf-8") as fh:
        tree = ast.parse(fh.read())
    # AST, not grep: docstrings legitimately EXPLAIN the rule — only CALL sites count
    call_homes = []
    for fn in [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)]:
        for node in ast.walk(fn):
            if (isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "openUrl"):
                call_homes.append(fn.name)
    assert call_homes == ["_open_link"]                # ONE call, in the click slot


# ── accessibility + non-colour state cues ───────────────────────────────────────

def test_every_mode_card_carries_accessible_name_and_description(wiz):
    page = _page(wiz, "ModePage")
    for mid, label, desc in page.modes:
        card = page._buttons[mid]
        assert card.accessibleName() == label
        assert card.accessibleDescription() == desc
        assert card.text() == label                    # never icon-only


def test_card_states_render_visibly_distinct(qapp):
    card = cc.ChoiceCard("State card", "desc", icon_name="phone")
    card.resize(360, 90)
    unchecked = _png(card.grab())
    card.setChecked(True)
    checked = _png(card.grab())
    card.setChecked(False)
    card.setEnabled(False)
    disabled = _png(card.grab())
    assert unchecked != checked                        # badge + border, not hover-luck
    assert unchecked != disabled and checked != disabled
    card.deleteLater()


# ── the Gentoo card's link ──────────────────────────────────────────────────────

def test_gentoo_card_shows_the_url_as_selectable_text_and_click_opens_it(
        wiz, monkeypatch):
    page = _page(wiz, "ModePage")
    card = page._buttons["standalone"]
    lab = card._link_label
    assert lab is not None
    # the raw URL is VISIBLE text (air-gapped operators read it without clicking)
    assert "https://www.gentoo.org/" in lab.text()
    assert lab.textInteractionFlags() & Qt.TextInteractionFlag.TextSelectableByMouse
    # Qt itself must not auto-open — the hand-off runs through OUR guarded slot
    assert lab.openExternalLinks() is False
    opened = []
    monkeypatch.setattr(QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: opened.append(url.toString()) or True))
    lab.linkActivated.emit("https://www.gentoo.org/")   # == an explicit click
    assert opened == ["https://www.gentoo.org/"]
    # no other mode card carries a link
    for mid, _, _ in page.modes:
        if mid != "standalone":
            assert page._buttons[mid]._link_label is None


def test_selected_badge_sits_in_a_clean_seat_over_the_icon(qapp):
    """Regression: on a min-height card the check badge shares the icon's
    top-right corner, and children paint AFTER their parent — so the cloud's
    strokes drew straight across the badge circle (5 stroke pixels measured in
    the ring around the badge). The icon pane now punches a fill-ringed seat
    for the badge: the halo annulus between the badge circle and the icon must
    be pure card fill."""
    card = cc.ChoiceCard("Outbound tunnel", "dials out", "golive-tunnel")
    card.resize(360, 76)                 # min-height: the geometry that collides
    card.setChecked(True)
    card.show()
    qapp.processEvents()
    img = card.grab().toImage()
    pal = card.palette()
    role = QtGui.QPalette.ColorRole
    fill = cc.ChoiceCard._mix(pal.color(role.Window),
                              pal.color(role.Highlight), 0.16)
    br = card._badge_rect()
    cx, cy = br.center().x(), br.center().y()
    ig = card._icon_pane.geometry()
    sampled, intruders = 0, []
    for y in range(int(cy) - 12, int(cy) + 13):
        for x in range(int(cx) - 12, int(cx) + 13):
            d = ((x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2) ** 0.5
            if not (9.0 <= d <= 9.9) or not ig.contains(x, y):
                continue
            sampled += 1
            c = img.pixelColor(x, y)
            if (abs(c.red() - fill.red()) + abs(c.green() - fill.green())
                    + abs(c.blue() - fill.blue())) > 24:
                intruders.append(((x, y), c.name()))
    assert sampled >= 15                 # the ring really crosses the icon pane
    assert intruders == []               # pre-fix: cloud strokes crossed the seat
    card.hide()
    card.deleteLater()


class _OpaquePane(QtWidgets.QWidget):
    """The worst case a ``set_icon_widget`` caller can hand the card: WIDER than
    ``_ICON_SIZE`` and filling its whole rect with a flat opaque colour. This is what
    the branding lane's theme swatches are, and it is what overpainted the badge."""

    def __init__(self, colour="#7a3fb0"):
        super().__init__()
        self._colour = QtGui.QColor(colour)
        self.setFixedSize(96, 58)

    def paintEvent(self, _ev):                       # noqa: N802 (Qt override)
        p = QtGui.QPainter(self)
        try:
            p.fillRect(self.rect(), self._colour)
        finally:
            p.end()


def _badge_ink(card) -> tuple[int, int]:
    """(badge-coloured pixels, sampled pixels) inside the check badge's circle.

    "Badge-coloured" = near palette Highlight (the disc) or HighlightedText (the
    tick) — i.e. the badge itself, as opposed to whatever painted over it."""
    img = card.grab().toImage()
    pal = card.palette()
    role = QtGui.QPalette.ColorRole
    refs = (pal.color(role.Highlight), pal.color(role.HighlightedText))
    br = card._badge_rect()
    cx, cy, rad = br.center().x(), br.center().y(), br.width() / 2.0 - 1.0
    ink = seen = 0
    for y in range(int(br.top()), int(br.bottom()) + 1):
        for x in range(int(br.left()), int(br.right()) + 1):
            if (x - cx) ** 2 + (y - cy) ** 2 > rad * rad:
                continue
            seen += 1
            c = img.pixelColor(x, y)
            if any(abs(c.red() - r.red()) + abs(c.green() - r.green())
                   + abs(c.blue() - r.blue()) <= 60 for r in refs):
                ink += 1
    return ink, seen


def test_badge_survives_an_opaque_swapped_icon_pane(qapp):
    """Regression (branding lane): children paint AFTER their parent, so a badge
    drawn by the card was at the mercy of the icon slot. ``set_icon_widget`` replaced
    the pane that co-operated (it punched a badge-shaped hole in its own clip) with
    opaque theme swatches that did not, and ~half of every checked card's tick was
    overpainted: 57/156 badge pixels vs the stock pane's 114/156, a crescent that
    reads as a HALF-drawn check. The badge now owns its seat, so a swapped pane —
    wider than the icon box and fully opaque — must leave it byte-for-byte intact."""
    stock = cc.ChoiceCard("Stock", "keeps the built-in icon pane", "desktop")
    stock.resize(360, 76)                            # min height: the geometry that collides
    stock.setChecked(True)
    swapped = cc.ChoiceCard("Swapped", "opaque pane installed over the icon slot", "desktop")
    swapped.set_icon_widget(_OpaquePane())
    swapped.resize(360, 76)
    swapped.setChecked(True)
    qapp.processEvents()

    stock_ink, seen = _badge_ink(stock)
    swapped_ink, seen2 = _badge_ink(swapped)
    assert seen == seen2 and seen >= 120             # the probe really sampled the badge
    # the badge is drawn identically over its own opaque halo, so the two must MATCH,
    # not merely "be present" — a partially occluded badge scored 57 where this is 114.
    assert swapped_ink == stock_ink, (
        f"swapped pane ate the badge: {swapped_ink}/{seen} vs stock {stock_ink}/{seen}")
    assert swapped_ink > seen * 0.6                  # and the badge really is drawn
    # the opaque pane is genuinely over the badge: it is wider than the icon box and
    # its rect covers the badge centre (so the assertion above is not vacuous).
    pane = swapped._icon_pane
    assert pane.width() > cc._ICON_SIZE
    assert pane.geometry().contains(int(stock._badge_rect().center().x()),
                                    int(stock._badge_rect().center().y()))
    for c in (stock, swapped):
        c.hide()
        c.deleteLater()


def test_badge_is_the_topmost_child_whatever_is_added_later(qapp):
    """Structural half of the same defect: stacking order, not pixels. Any child added
    after the badge (a swapped icon pane, a subclass's own widget) would paint on top
    of it — so the card restacks the badge in ``childEvent``, making "the badge paints
    last" a property of the CARD rather than a favour each pane must remember."""
    card = cc.ChoiceCard("Restack", "desc", "desktop")
    kids = [w for w in card.children() if isinstance(w, QtWidgets.QWidget)]
    assert kids[-1] is card._badge                   # last child == topmost
    card.set_icon_widget(_OpaquePane())
    kids = [w for w in card.children() if isinstance(w, QtWidgets.QWidget)]
    assert kids[-1] is card._badge, "a later child outranked the badge"
    # and a widget parented directly (not via set_icon_widget) is restacked too
    stray = QtWidgets.QLabel("late", card)
    kids = [w for w in card.children() if isinstance(w, QtWidgets.QWidget)]
    assert kids[-1] is card._badge, "a stray late child outranked the badge"
    assert stray in kids
    card.deleteLater()


def test_unchecked_card_paints_no_badge(qapp):
    """The overlay is always present; it must paint NOTHING while unchecked, or every
    card would read as selected — the inverse of the bug it fixes."""
    card = cc.ChoiceCard("Quiet", "desc", "desktop")
    card.resize(360, 76)
    ink, seen = _badge_ink(card)
    assert seen >= 120
    assert ink == 0, f"unchecked card painted {ink}/{seen} badge pixels"
    card.deleteLater()


def _theme_palette(dark: bool) -> QtGui.QPalette:
    """A full theme palette that deliberately does NOT set the Link role — like
    real platform dark themes, which leave it at Qt's pure-#0000ff default."""
    pal = QtGui.QPalette()
    if dark:
        win, text = QtGui.QColor(30, 32, 34), QtGui.QColor(224, 224, 224)
    else:
        win, text = QtGui.QColor(246, 245, 244), QtGui.QColor(30, 30, 30)
    hi, hitext = QtGui.QColor(53, 132, 228), QtGui.QColor(255, 255, 255)
    for grp in (QtGui.QPalette.ColorGroup.Active,
                QtGui.QPalette.ColorGroup.Inactive,
                QtGui.QPalette.ColorGroup.Disabled):
        pal.setColor(grp, QtGui.QPalette.ColorRole.Window, win)
        pal.setColor(grp, QtGui.QPalette.ColorRole.WindowText, text)
        pal.setColor(grp, QtGui.QPalette.ColorRole.Base, win)
        pal.setColor(grp, QtGui.QPalette.ColorRole.Text, text)
        pal.setColor(grp, QtGui.QPalette.ColorRole.Highlight, hi)
        pal.setColor(grp, QtGui.QPalette.ColorRole.HighlightedText, hitext)
    return pal


def test_link_anchor_readable_on_dark_theme_and_rederives_on_flip(qapp):
    """Regression: the gentoo.org anchor used to render in the palette Link role,
    which Qt's default palette leaves at pure #0000ff even on dark themes —
    measured 1.56:1 on the dark selected fill (invisible; WCAG floor is 4.5:1).
    The anchor colour must now be palette-derived, contrast-guarded, actually
    painted, and re-derived on a live theme flip."""
    pal = _theme_palette(dark=True)
    card = cc.ChoiceCard("Standalone Gentoo desktop", "Just Gentoo.", "gentoo")
    card.setPalette(pal)
    lab = card.set_link("https://www.gentoo.org/", "gentoo.org")
    card.resize(420, 110)
    card.setChecked(True)      # selected tint = the worst pre-fix fill (1.56:1)
    card.show()
    qapp.processEvents()
    link = card.link_color()
    img = card.grab().toImage()
    g = lab.geometry()
    pure_blue = near_link = 0
    for y in range(g.top(), g.bottom()):
        for x in range(g.left(), g.right()):
            c = img.pixelColor(x, y)
            if (c.red(), c.green(), c.blue()) == (0, 0, 255):
                pure_blue += 1
            if (abs(c.red() - link.red()) + abs(c.green() - link.green())
                    + abs(c.blue() - link.blue())) <= 12:
                near_link += 1
    assert pure_blue == 0      # pre-fix: 57 px of Qt-default #0000ff
    assert near_link >= 10     # the derived ink is what actually got painted
    # the derived colour clears 4.5:1 on EVERY fill _paint_card can paint
    role = QtGui.QPalette.ColorRole
    base, text = pal.color(role.Window), pal.color(role.WindowText)
    hi = pal.color(role.Highlight)
    for fill in (base,
                 cc.ChoiceCard._mix(base, text, 0.04),
                 cc.ChoiceCard._mix(base, text, 0.08),
                 cc.ChoiceCard._mix(base, hi, 0.16)):
        assert ci._contrast(link, fill) >= 4.5
    # live theme flip: PaletteChange must re-derive the baked colour
    dark_html = lab.text()
    card.setPalette(_theme_palette(dark=False))
    qapp.processEvents()
    assert lab.text() != dark_html
    assert card.link_color().name() in lab.text()
    assert "https://www.gentoo.org/" in lab.text()   # raw URL text survives
    card.hide()
    card.deleteLater()


# ── RolePage image-type rows carry a role-family glyph ──────────────────────────

def test_role_rows_carry_role_family_icons(wiz):
    wiz.cfg.mode = "standalone"
    page = _page(wiz, "RolePage")
    page.initializePage()
    assert page.roles.count() > 0
    for i in range(page.roles.count()):
        assert not page.roles.item(i).icon().isNull()


def test_role_icon_classification_covers_the_catalog():
    assert ci.role_icon_name("pki", "mesh") == "role-server"
    assert ci.role_icon_name("generic", "standalone") == "role-board"
    assert ci.role_icon_name("orangepizero3", "cloud") == "role-board"
    assert ci.role_icon_name("standalone-thin", "standalone") == "role-desktop"
    assert ci.role_icon_name("laptop", "cloud") == "role-mesh-desktop"
    assert ci.role_icon_name("rpi5-desktop", "mesh") == "role-mesh-desktop"
    # every classification target is a registered painter
    for name in ("role-server", "role-board", "role-desktop", "role-mesh-desktop"):
        assert name in ci.ICON_PAINTERS
