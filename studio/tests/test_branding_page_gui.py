"""Ask 6, GUI half — what the redone branding section OFFERS and what it can EMIT.

``test_branding_themes.py`` pins the four-theme set against the disk, the builder, the
menu and the docs. This file pins the last link in that chain: the wizard page. Its
central claim is that the page has **no path to an invalid ``--theme``** — not a free
text field, not an appended brand name, not a stale value from a loaded config. That
is exactly the hole ``origin/main`` had: ``initializePage`` did

    if brand_theme and self.theme.findText(brand_theme) < 0: self.theme.addItem(...)
    if c.theme     and self.theme.findText(c.theme) < 0:     self.theme.addItem(...)

so the combo offered the BRAND NAME (no such directory) and any saved value, and
picking one emitted ``--theme <name>`` into a builder that hard-errors on it.

Runs on Qt's offscreen platform; skipped whole when no binding is installed.
"""
import os
from types import SimpleNamespace

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.branding_themes import PREMADE_THEMES, THEME_SPECS  # noqa: E402
from hugmesh_studio.core.config import ImageConfig, UNAFFILIATED_ROLE  # noqa: E402
from hugmesh_studio.gui.pages._themecards import (  # noqa: E402
    NO_THEME, CustomAssetsSwatch, ThemeCard, ThemeStripSwatch, ThemeSwatch,
)
from hugmesh_studio.gui.pages.branding import BrandingPage  # noqa: E402
from hugmesh_studio.gui.qt import QtGui, QtWidgets  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(scope="module")
def qapp():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


def _page(qapp, **cfg_kw):
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      **cfg_kw)
    return _page_for(cfg)


def _page_for(cfg, worklist=None):
    """Build + initialize the page for an arbitrary config. Direct instantiation, so
    visibility is asserted with ``isVisibleTo(page)`` (the file's established idiom for
    an unshown page — a plain isVisible() is False for every widget here)."""
    page = BrandingPage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR,
                                        worklist=worklist))
    page.initializePage()
    return page, cfg


def _unaff(**kw):
    """The operator's image: role=standalone-unaffiliated, platform=x86 (session
    20260826-151356-64070a)."""
    base = dict(mode="standalone", role=UNAFFILIATED_ROLE, platform="x86")
    base.update(kw)
    return ImageConfig(**base)


def _composable_unaff(**kw):
    """The SAME builder posture reached the other way (G22): --unaffiliated composed
    onto a branded x86 client role."""
    base = dict(mode="standalone", role="standalone-thick", platform="x86",
                unaffiliated=True)
    base.update(kw)
    return ImageConfig(**base)


# ── the offered set ──────────────────────────────────────────────────────────────
def test_page_offers_exactly_the_four_plus_stock_look(qapp):
    page, _ = _page(qapp)
    assert list(page.theme_group.cards) == [NO_THEME] + list(PREMADE_THEMES)
    for name in PREMADE_THEMES:
        assert page.theme_group.cards[name].theme_name == name


def test_brand_name_is_not_offered_as_a_theme(qapp):
    """THE origin/main defect, pinned. A brand is not a theme; appending it offered a
    name with no directory, and the builder hard-errors on exactly that."""
    page, _ = _page(qapp, brand="acme")
    assert "acme" not in page.theme_group.cards
    assert list(page.theme_group.cards) == [NO_THEME] + list(PREMADE_THEMES)


def test_unknown_saved_theme_is_cleared_with_a_note_not_offered(qapp):
    """A config carrying a theme this generator does not ship must not be silently
    kept (the builder would fail) NOR silently dropped (the operator would never know
    their choice went away)."""
    page, cfg = _page(qapp, theme="boogiepop")
    assert "boogiepop" not in page.theme_group.cards
    assert page.theme_group.selected() == NO_THEME
    assert not page.stale_theme_note.isHidden()
    assert "boogiepop" in page.stale_theme_note.text()
    assert "unknown --theme" in page.stale_theme_note.text()
    assert page.validatePage()
    assert cfg.theme == ""                       # cleared, never emitted


@pytest.mark.parametrize("name", PREMADE_THEMES)
def test_each_theme_round_trips_through_the_page(qapp, name):
    page, cfg = _page(qapp, theme=name)
    assert page.rb_preset.isChecked()
    assert page.theme_group.selected() == name
    assert page.stale_theme_note.isHidden()
    assert page.validatePage()
    assert cfg.theme == name
    argv = cfg.to_cli_args()
    assert argv[argv.index("--theme") + 1] == name      # the flag's OWN value


def test_selecting_a_card_is_what_gets_emitted(qapp):
    page, cfg = _page(qapp)
    page.theme_group.cards["grey"].setChecked(True)
    assert page.validatePage()
    assert cfg.theme == "grey"
    assert "--theme" in cfg.to_cli_args() and "grey" in cfg.to_cli_args()


def test_stock_look_card_emits_no_theme_flag(qapp):
    page, cfg = _page(qapp, theme="purple")
    page.theme_group.cards[NO_THEME].setChecked(True)
    assert page.validatePage()
    assert cfg.theme == ""
    assert "--theme" not in cfg.to_cli_args()


def _under(widget, ancestor) -> bool:
    w = widget
    while w is not None:
        if w is ancestor:
            return True
        w = w.parent()
    return False


def test_page_has_no_free_text_path_to_a_theme(qapp):
    """Structural: nothing on the premade side is editable, so there is no way at all
    to type a name the builder would reject.

    Searched over the WHOLE PAGE, not just ``theme_box``: scoping the search to the
    picker's own container would stay green if a free-text theme entry were added
    anywhere else on the page, which is precisely how ``origin/main`` shipped a combo
    that offered the brand name. Every editable widget the page owns must belong to
    one of the two channels that are ALLOWED to take free text — the custom-branding
    assets group and the web login theme — and neither writes ``cfg.theme``."""
    page, _ = _page(qapp)
    assert page.theme_box.findChildren(QtWidgets.QLineEdit) == []
    assert page.theme_box.findChildren(QtWidgets.QComboBox) == []
    editable = []
    for cls in (QtWidgets.QLineEdit, QtWidgets.QComboBox,
                QtWidgets.QPlainTextEdit, QtWidgets.QTextEdit):
        editable += list(page.findChildren(cls))
    assert editable, "found no editable widgets at all — the probe stopped working"
    strays = [w for w in editable
              if not (_under(w, page.custom_group) or _under(w, page.login_theme))]
    assert strays == [], [(type(w).__name__, w.objectName()) for w in strays]


def test_typed_text_can_never_become_the_theme(qapp):
    """Behavioural twin of the structural check: type a builder-hostile name into
    EVERY editable widget on the page and commit. Whatever the operator types, the
    committed ``cfg.theme`` can only be "" or one of the declared four — the picker is
    the sole writer, so there is no field anywhere that can smuggle a name through."""
    page, cfg = _page(qapp)
    for cls in (QtWidgets.QLineEdit, QtWidgets.QPlainTextEdit, QtWidgets.QTextEdit):
        for w in page.findChildren(cls):
            if w.isEnabled():
                w.setText("../../etc")
    page.rb_preset.setChecked(True)             # the premade channel commits `theme`
    page.theme_group.cards[PREMADE_THEMES[0]].setChecked(True)
    assert page.selected_theme() in ("",) + tuple(PREMADE_THEMES)
    assert page.validatePage()
    assert cfg.theme in ("",) + tuple(PREMADE_THEMES), cfg.theme


# ── the either/or still holds ────────────────────────────────────────────────────
def test_choosing_custom_clears_the_theme_and_greys_the_picker(qapp):
    page, cfg = _page(qapp, theme="dark")
    page.rb_custom.setChecked(True)
    assert page.theme_group.selected() == NO_THEME
    assert not page.theme_box.isEnabled() and page.custom_group.isEnabled()
    page.fields["wallpaper"].setText("/tmp/w.png")
    assert page.validatePage()
    assert cfg.theme == "" and cfg.wallpaper == "/tmp/w.png"


def test_choosing_preset_clears_the_custom_fields(qapp):
    page, cfg = _page(qapp, wallpaper="/tmp/w.png")
    assert page.rb_custom.isChecked()            # a custom value selects that channel
    page.rb_preset.setChecked(True)
    assert page.fields["wallpaper"].text() == ""
    page.theme_group.cards["light"].setChecked(True)
    assert page.validatePage()
    assert cfg.theme == "light" and cfg.wallpaper == ""


def test_selected_theme_is_empty_on_the_custom_channel(qapp):
    """`selected_theme()` is the ONE widget->config translation; on the custom channel
    it must report "" whatever card happens to be checked underneath."""
    page, _ = _page(qapp)
    page.theme_group.cards["purple"].setChecked(True)
    page.rb_custom.setChecked(True)
    assert page.selected_theme() == NO_THEME


# ── the set-equality note (surfaced, never raised) ────────────────────────────────
def test_set_mismatch_is_shown_as_a_note_not_raised(qapp, tmp_path):
    """A checkout whose themes directory disagrees with the offered set must produce a
    VISIBLE explanation, not a traceback: under PyQt6 an exception escaping a slot
    calls qFatal and takes the whole Studio with it."""
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86")
    page = BrandingPage(SimpleNamespace(cfg=cfg, generator_dir=str(tmp_path)))
    page.initializePage()                        # empty dir: all four missing
    assert not page.theme_sync_note.isHidden()
    text = page.theme_sync_note.text()
    assert "missing on disk" in text and "gen-branding-themes.py" in text
    # and the page still WORKS — the operator can pick stock look and move on
    assert page.validatePage()
    assert cfg.theme == ""


def test_no_note_on_a_healthy_checkout(qapp):
    page, _ = _page(qapp)
    assert page.theme_sync_note.isHidden()
    assert page.theme_sync_note.text() == ""


# ── the swatches ─────────────────────────────────────────────────────────────────
def test_swatch_previews_come_from_the_generator_colour_table(qapp):
    """The preview and the rendered wallpaper share ONE source, so a card cannot
    advertise colours the PNG does not have."""
    page, _ = _page(qapp)
    for name in PREMADE_THEMES:
        card = page.theme_group.cards[name]
        assert isinstance(card.swatch, ThemeSwatch)
        assert card.swatch.spec is THEME_SPECS[name]
    assert page.theme_group.cards[NO_THEME].swatch.spec is None


def test_accent_is_readable_as_text_not_only_as_colour(qapp):
    """Accessibility: a swatch is decoration. The accent has to survive greyscale and
    a screen reader, so it is in the card's accessible description too."""
    page, _ = _page(qapp)
    for name in PREMADE_THEMES:
        desc = page.theme_group.cards[name].accessibleDescription()
        assert THEME_SPECS[name].accent in desc


@pytest.mark.parametrize("cls", [ThemeStripSwatch, CustomAssetsSwatch])
def test_fork_card_swatches_paint_without_raising(qapp, cls):
    """Qt duality guard: paint the pane for real on both a light and a dark palette.
    Under PyQt6 an exception escaping paintEvent is qFatal, so a swallowed-exception
    log would be a silent hole — and a pane that painted NOTHING would look exactly
    like a working one to a grab-it-and-shrug assertion, so both palettes must yield
    a genuinely non-blank render (this used to assert only ``pm.width() > 0``, which a
    ``_paint`` that returns immediately satisfies)."""
    w = cls()
    w.resize(w.sizeHint() if w.sizeHint().isValid() else w.size())
    for window, text in (("#f6f8fc", "#1b2333"), ("#232629", "#eff0f1")):
        pal = QtGui.QPalette()
        pal.setColor(QtGui.QPalette.ColorRole.Window, QtGui.QColor(window))
        pal.setColor(QtGui.QPalette.ColorRole.WindowText, QtGui.QColor(text))
        pal.setColor(QtGui.QPalette.ColorRole.Highlight, QtGui.QColor("#3daee9"))
        w.setPalette(pal)
        pm = w.grab()
        assert not pm.isNull() and pm.width() > 0
        img = pm.toImage()
        colours = {img.pixel(x, y)
                   for y in range(0, img.height(), 2) for x in range(0, img.width(), 2)}
        assert len(colours) > 2, f"{cls.__name__} rendered a flat block on {window}"


def test_premade_fork_strip_shows_one_chip_per_declared_theme(qapp):
    """The lane's headline claim is that "four themes" is answerable BY LOOKING: the
    fork card carries a chip strip painted from the live theme table. Assert the strip
    really carries one chip per PREMADE_THEMES entry, each in ITS theme's colours —
    a strip that painted nothing, or three chips, or four identical ones, was green
    under the old ``pm.width() > 0`` assertion."""
    w = ThemeStripSwatch()
    img = w.grab().toImage()
    mid = img.height() // 2
    gap = 3.0
    chip_w = (img.width() - 1.0 - gap * (len(PREMADE_THEMES) - 1)) / len(PREMADE_THEMES)
    seen = []
    for i, name in enumerate(PREMADE_THEMES):
        cx = int(0.5 + i * (chip_w + gap) + chip_w / 2)
        colour = img.pixelColor(cx, mid)
        seen.append((name, colour.name()))
        spec = THEME_SPECS[name]
        top, bot = QtGui.QColor(spec.top), QtGui.QColor(spec.bottom)
        # mid-height of a top->bottom gradient: between the two declared endpoints
        lo, hi = sorted((top.lightness(), bot.lightness()))
        assert lo - 12 <= colour.lightness() <= hi + 12, (name, colour.name())
        for chan in ("red", "green", "blue"):
            band = sorted((getattr(top, chan)(), getattr(bot, chan)()))
            assert band[0] - 12 <= getattr(colour, chan)() <= band[1] + 12, (
                name, chan, colour.name())
    # every declared theme is visibly DISTINCT in the strip (four grey chips would
    # satisfy every per-chip bound above while telling the operator nothing)
    assert len({c for _, c in seen}) == len(PREMADE_THEMES), seen


def test_checked_theme_cards_keep_a_whole_check_badge(qapp):
    """Regression: the swatches installed by ``set_icon_widget`` are wider than the
    icon box and fill their rect opaquely, and they overpainted the card's top-right
    check badge — measured 57/156 badge pixels on every ThemeCard and 54/156 on the
    "Premade theme" fork card, against 114/156 for a stock card. The surviving
    crescent read as a HALF-drawn tick, on a wizard whose headline complaint was
    "half checked instead of unchecked". Every checked card on this page must now
    score exactly what an unswapped card scores."""
    from hugmesh_studio.gui.choice_cards import ChoiceCard          # noqa: PLC0415
    from tests.test_choice_cards import _badge_ink                  # noqa: PLC0415

    reference = ChoiceCard("Reference", "stock icon pane", "desktop")
    reference.resize(360, 76)
    reference.setChecked(True)
    want, seen = _badge_ink(reference)
    assert seen >= 120 and want > seen * 0.6            # the probe sees a real badge

    page, _ = _page(qapp)
    cards = dict(page.theme_group.cards)
    cards["fork:premade"] = page.rb_preset
    cards["fork:custom"] = page.rb_custom
    scores = {}
    for label, card in cards.items():
        card.setParent(None)                            # measure the card, not the page
        card.resize(360, 76)
        card.setChecked(True)
        qapp.processEvents()
        scores[label] = _badge_ink(card)[0]
    assert scores == {k: want for k in cards}, (scores, want)
    reference.deleteLater()


@pytest.mark.parametrize("name", (NO_THEME,) + tuple(PREMADE_THEMES))
def test_theme_swatch_paints_and_is_not_blank(qapp, name):
    """Each swatch actually draws something — a pane that silently painted nothing
    would look exactly like a working one in a screenshot-free test."""
    spec = THEME_SPECS.get(name)
    w = ThemeSwatch(spec)
    img = w.grab().toImage()
    assert img.width() and img.height()
    colours = {img.pixel(x, y)
               for y in range(0, img.height(), 4) for x in range(0, img.width(), 4)}
    assert len(colours) > 1, f"{name or 'stock'} swatch painted a flat block"


def test_theme_card_name_is_not_derived_from_its_title(qapp):
    """Retitling a card must never change what the builder receives."""
    card = ThemeCard("grey", "Something Else Entirely", "desc")
    assert card.theme_name == "grey"
    assert card.text() == "Something Else Entirely"


# ── IDENTITY vs LOOK on an unaffiliated image (operator decision, 2026-08-26) ─────
# The operator's report, verbatim: "There should be the menu for adding the themes as
# in the branded images". Their image is role=standalone-unaffiliated / x86. The page
# used to remove itself for that role (applies_to -> False), because every field on it
# was then a builder hard conflict — which is exactly why the theme menu was missing.
# The decision splits the surface: a BRAND is an affiliation, a WALLPAPER is not.

@pytest.mark.parametrize("cfg_fn", [_unaff, _composable_unaff])
def test_the_page_applies_to_an_unaffiliated_desktop(qapp, cfg_fn):
    """The reversal, pinned. BOTH spellings of unaffiliated — the dedicated role id and
    the composable flag — get the page, because both are desktop-class x86 images whose
    builder parses --theme."""
    page, cfg = _page_for(cfg_fn())
    assert page.applies_to(cfg) is True


def test_the_page_still_skips_an_unaffiliated_image_with_no_desktop_half(qapp):
    """Mutation guard: the skip did not become "never skip". An unaffiliated image on a
    builder that parses no --theme has nothing to offer, so the page still disappears —
    and that still leaves the output unchanged through RolePage's clear at role-commit time."""
    page, cfg = _page_for(_composable_unaff(role="rpi5-desktop", platform="rpi5"))
    assert page.applies_to(cfg) is False


@pytest.mark.parametrize("cfg_fn", [_unaff, _composable_unaff])
def test_unaffiliated_offers_the_whole_theme_menu(qapp, cfg_fn):
    """THE ASK. Every premade theme card (and the stock-look card) is visible AND
    enabled on an unaffiliated image — not greyed, not hidden, not a subset."""
    page, _ = _page_for(cfg_fn())
    assert page.form.isVisibleTo(page) and page.form.isEnabled()
    assert list(page.theme_group.cards) == [NO_THEME] + list(PREMADE_THEMES)
    for name, card in page.theme_group.cards.items():
        assert card.isVisibleTo(page), name
        assert card.isEnabled(), name


@pytest.mark.parametrize("cfg_fn", [_unaff, _composable_unaff])
def test_unaffiliated_hides_the_two_identity_widgets(qapp, cfg_fn):
    """...and ONLY those two. brand_logo and "Lock branding" stay hard conflicts
    (config._check_unaffiliated_conflicts; build-x86-host-stage4.sh's unaffiliated err),
    so they are hidden — the whole _row(), never the bare edit, or the "Brand logo"
    caption is left stranded over an empty slot."""
    page, _ = _page_for(cfg_fn())
    assert not page.field_rows["brand_logo"].isVisibleTo(page)
    assert not page.locked.isVisibleTo(page)
    for key in ("branding_dir", "wallpaper", "grub_background", "grub_theme",
                "login_background", "color_scheme"):
        assert page.field_rows[key].isVisibleTo(page), key
    assert page.accent.isVisibleTo(page)


def test_a_branded_desktop_keeps_its_identity_widgets(qapp):
    """The mutation guard for the hide: a rule that hid the logo from EVERYONE would
    also satisfy the test above."""
    page, _ = _page(qapp)
    assert page.field_rows["brand_logo"].isVisibleTo(page)
    assert page.locked.isVisibleTo(page)


@pytest.mark.parametrize("cfg_fn", [_unaff, _composable_unaff])
def test_unaffiliated_note_says_look_is_available_not_that_the_page_is_moot(qapp, cfg_fn):
    """The note used to read "Branding does not apply" — true only while the page
    removed itself, and the sentence the operator's report is about. It must now say
    what IS excluded (identity) and what is not (the look)."""
    page, _ = _page_for(cfg_fn())
    assert page.unaffiliated_note.isVisibleTo(page)
    text = page.unaffiliated_note.text().lower()
    assert "identity" in text and ("logo" in text and "lock" in text)
    assert "theme" in text or "look" in text
    assert "does not apply" not in text


@pytest.mark.parametrize("cfg_fn", [_unaff, _composable_unaff])
@pytest.mark.parametrize("name", PREMADE_THEMES)
def test_a_theme_picked_on_an_unaffiliated_image_reaches_the_argv(qapp, cfg_fn, name):
    """End to end: the card commits, the config emits, and to_cli_args() — which still
    raises on an identity field — accepts it."""
    page, cfg = _page_for(cfg_fn())
    page.theme_group.cards[name].setChecked(True)
    assert page.validatePage()
    assert cfg.theme == name
    argv = cfg.to_cli_args()
    assert argv[argv.index("--theme") + 1] == name


@pytest.mark.parametrize("cfg_fn", [_unaff, _composable_unaff])
def test_unaffiliated_clears_identity_but_keeps_the_look(qapp, cfg_fn):
    """The emission half of the hide, in both directions at once: the two hidden fields
    go back to their ImageConfig defaults whatever the widgets hold, and the neutral
    assets collected beside them survive."""
    page, cfg = _page_for(cfg_fn())
    page.rb_custom.setChecked(True)
    page.fields["wallpaper"].setText("/tmp/w.png")
    page.fields["grub_theme"].setText("/tmp/g")
    page.fields["brand_logo"].setText("/tmp/logo.png")   # hidden control
    page.locked.setChecked(True)                          # hidden control
    assert page.validatePage()
    assert cfg.wallpaper == "/tmp/w.png" and cfg.grub_theme == "/tmp/g"
    assert cfg.brand_logo == "" and cfg.brand_locked is False
    args = cfg.to_cli_args()          # raises on a leftover identity asset
    assert "--brand-logo" not in args and "--brand-locked" not in args
    assert "--wallpaper" in args


def test_a_stale_brand_logo_cannot_steal_the_theme_channel(qapp):
    """MEASURED REGRESSION. brand_logo is one of the eight custom-asset fields, so a
    saved unaffiliated config carrying one (a leftover from a branded role) counted as
    "has custom assets", flipped the page to the custom channel and DISCARDED the theme
    the operator then picked — explained by a both-set note pointing at a widget that is
    hidden on this role. Fields the image is not offered get no vote."""
    page, cfg = _page_for(_unaff(theme="purple", brand_logo="/tmp/logo.png"))
    assert page.rb_preset.isChecked()
    assert page.theme_group.selected() == "purple"
    assert not page.both_set_note.isVisibleTo(page)
    assert page.fields["brand_logo"].text() == ""     # hidden control loads empty
    assert page.validatePage()
    assert cfg.theme == "purple" and cfg.brand_logo == ""


def test_the_closed_set_is_unchanged_on_an_unaffiliated_image(qapp):
    """The ask-6 invariant survives the reversal: nothing is appended to the offered set
    on this role either (the brand name, a saved unknown value — the origin/main defect
    this file exists to pin)."""
    page, cfg = _page_for(_unaff(brand="acme", theme="boogiepop"))
    assert list(page.theme_group.cards) == [NO_THEME] + list(PREMADE_THEMES)
    assert page.theme_group.selected() == NO_THEME
    assert not page.stale_theme_note.isHidden()
    assert page.validatePage()
    assert cfg.theme == ""


@pytest.mark.parametrize("cfg_fn", [_unaff, _composable_unaff])
def test_both_unaffiliated_spellings_gate_identically(qapp, cfg_fn):
    """THE THREE-PREDICATE ASYMMETRY, closed. applies_to tested "role or flag" while
    initializePage and validatePage tested ONLY the role — so a config with
    role="standalone-thick", unaffiliated=True rendered the page fully live (brand
    assets enabled, no note) for a config whose to_cli_args() raises. One predicate now
    answers all three, which means the two spellings must be indistinguishable HERE."""
    page, cfg = _page_for(cfg_fn())
    state = (page.applies_to(cfg),
             page.unaffiliated_note.isVisibleTo(page),
             page.field_rows["brand_logo"].isVisibleTo(page),
             page.locked.isVisibleTo(page))
    assert state == (True, True, False, False)


# ── the web login theme is a MESH surface (and is named for its plane) ────────────

def test_web_login_theme_is_named_for_its_plane(qapp):
    """The page hosts TWO theme surfaces. The desktop cards sit under a "Desktop theme"
    header while the collapsible literally titled "Themes" was the WEB one — which is
    why "the menu for adding the themes" was ambiguous. Label-only: the persisted
    login_* keys are untouched (test_theme_editor_gui pins that)."""
    page, _ = _page(qapp)
    assert page.login_collapsible.title() == "Web login theme"


@pytest.mark.parametrize("mode,role,shown", [("standalone", "standalone-thick", False),
                                             ("standalone", UNAFFILIATED_ROLE, False),
                                             ("cloud", "laptop", False),
                                             ("mesh", "pki", True)])
def test_web_login_theme_shown_only_in_mesh(qapp, mode, role, shown):
    """It themes the login-ui a MESH serves to browsers; a standalone/cloud desktop
    serves no login-ui, which the page's own applies_to docstring already conceded. The
    COLLAPSIBLE is the gate target, so the header goes with the content — an orphan
    header that expands to nothing is the defect network.py:906-909 records."""
    page, _ = _page_for(ImageConfig(mode=mode, role=role, platform="x86"))
    assert page.login_collapsible.isVisibleTo(page) is shown
    if shown:
        assert page.login_collapsible.is_expanded()


def test_web_login_theme_still_round_trips_through_a_stray_visit(qapp):
    """Hiding it leaves the output unchanged BECAUSE the commit stays unconditional: the fields
    are NON_ARGV (config.py:755-766), and a mesh config that walks this page in another
    mode must come out the other side unharmed."""
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      login_primary_color="#123456")
    page, _ = _page_for(cfg)
    assert not page.login_collapsible.isVisibleTo(page)
    assert page.validatePage()
    assert cfg.login_primary_color == "#123456"
