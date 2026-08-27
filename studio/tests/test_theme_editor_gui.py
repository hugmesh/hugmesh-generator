"""The Themes surface rename + the modeless Themes editor (#50 item 2).

Pins:
  1. RENAME: every user-visible label says "Themes"; the persisted ``login_*``
     config KEYS are untouched, so every saved session keeps loading.
  2. MODELESS: the editor opens via show() — never exec() — and is pinned NonModal
     (repo rule: a nested event loop hangs headless tests and blocks the wizard).
  3. ROUND-TRIP: editor edits land in cfg.login_* fields, emit as literal
     --sd-header-*/--sd-footer-*/--sd-bg-effect tokens (with their --hug-* twins)
     through the SAME compose path the page always used, and reload into a fresh
     group + editor.
  4. OLD THEMES LOAD: a config JSON saved before the chrome fields existed loads
     to the shipped defaults and composes BYTE-IDENTICAL css.
  5. EFFECT PICKER: all six --sd-bg-effect contract values (login-ui PR #6 renders
     them; the host shell consumes the same channel) are SELECTABLE, default
     gradient, on a NoWheelComboBox (PR #72 — an unfocused hover-scroll must never
     silently swap the mesh's page background); presets MAY declare an effect and
     fill the picker like they fill the hex fields, presets without one emit
     nothing (omit-when-default keeps old theme files byte-identical).
"""
import json
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import theme, theme_presets                # noqa: E402
from hugmesh_studio.core.config import ImageConfig                  # noqa: E402
from hugmesh_studio.core.validate import IdentityValidationError    # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                 # noqa: E402
from hugmesh_studio.gui.pages._logintheme import LoginThemeGroup    # noqa: E402
from hugmesh_studio.gui.pages._theme_editor import ThemeEditorDialog  # noqa: E402
from hugmesh_studio.gui.pages._widgets import (                     # noqa: E402
    Collapsible, NoWheelComboBox)
from hugmesh_studio.gui.qt import QtCore, QtGui, QtWidgets          # noqa: E402

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture
def qapp():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


def _opened_editor(qapp) -> tuple[LoginThemeGroup, ThemeEditorDialog]:
    g = LoginThemeGroup()
    g.open_editor()
    return g, g.editor


# ── 1. the rename ────────────────────────────────────────────────────────────────────
def test_group_and_both_hosts_say_Themes_except_where_two_theme_groups_collide(qapp):
    """The original rename still holds everywhere it was unambiguous — and is
    DELIBERATELY reversed on the one page that hosts two different theme surfaces.

    Operator, 2026-08-26: the standalone flow "is asking same questions seemingly
    multiple times". BrandingPage was one of the offenders: its desktop theme cards
    sit under a "Desktop theme" header, and the mesh web-login group directly below
    them was titled, flatly, "Themes" — so the page asked for "a theme" twice with
    the SECOND one carrying the less specific label. DECISION 2(a) collapsed that:
    the web-login group is now titled for what it themes. Everywhere else there is
    only one theme surface on screen, so "Themes" stays."""
    assert LoginThemeGroup().title().startswith("Themes")

    branding = wizard_mod.BrandingPage(
        SimpleNamespace(cfg=ImageConfig(), generator_dir=GENERATOR_DIR))
    # THE EXEMPTION, and the only one: BrandingPage shows BOTH kinds at once.
    assert branding.login_collapsible.title() == "Web login theme"

    mesh = wizard_mod.LocalMeshPage(
        SimpleNamespace(cfg=ImageConfig(), generator_dir=GENERATOR_DIR,
                        localmesh_selected=True))
    mine = [c for c in mesh.findChildren(Collapsible)
            if c.content is mesh.login_theme]
    # LocalMeshPage hosts NO desktop theme cards, so there is nothing to collide
    # with and the short title is still the right one.
    assert mine and mine[0].title().startswith("Themes")

    # The negative survives for every surface that did NOT collide. BrandingPage's
    # subTitle() is in this list on purpose: the page's mesh-mode subtitle is set by
    # initializePage, never by the constructor, so a freshly built page must not be
    # carrying the web-login wording in its standing subtitle.
    for label in (LoginThemeGroup().title(), mine[0].title(), branding.subTitle()):
        assert "Web login theme" not in label


def test_rename_is_labels_only_the_persisted_login_keys_survive(qapp):
    # The saved-session JSON keys keep their login_* names (the slug IS persisted
    # state), so an old session round-trips through the renamed surface unchanged.
    d = ImageConfig().to_dict()
    for key in ("login_primary_color", "login_secondary_color", "login_theme_preset",
                "login_theme_mode", "login_bg_effect", "login_header_hidden",
                "login_footer_text"):
        assert key in d


# ── 2. modeless, by construction ─────────────────────────────────────────────────────
def test_editor_opens_modeless_via_show_and_is_reused(qapp):
    g, ed = _opened_editor(qapp)
    assert isinstance(ed, ThemeEditorDialog)
    assert ed.isVisible()                       # show() ran — no exec() anywhere
    assert not ed.isModal()
    assert ed.windowModality() == QtCore.Qt.WindowModality.NonModal
    # the page behind it stays interactive (the whole point of modeless)
    g.primary.setText("#336699")
    assert g.compose_css() != ""
    g.open_editor()
    assert g.editor is ed                       # one instance, reused


# ── 3. round-trip: editor -> cfg -> .theme.css -> fresh editor ───────────────────────
def test_chrome_edits_roundtrip_through_cfg_and_the_theme_css(qapp):
    g, ed = _opened_editor(qapp)
    hdr, ftr = ed._chrome_widgets["header"], ed._chrome_widgets["footer"]
    hdr["hidden"].setChecked(True)
    hdr["size"].setCurrentIndex(hdr["size"].findData("compact"))
    hdr["bg"].setText("#112233")
    ftr["text"].setText("© Example Mesh")
    ed.bg_effect.setCurrentIndex(ed.bg_effect.findData("none"))

    cfg = ImageConfig()
    g.commit(cfg)
    assert cfg.login_header_hidden is True
    assert cfg.login_header_size == "compact"
    assert cfg.login_header_bg == "#112233"
    assert cfg.login_footer_text == "© Example Mesh"
    assert cfg.login_bg_effect == "none"

    css = cfg.login_theme_css()
    assert css == g.compose_css() != ""         # page preview == delivered bytes
    assert "--sd-header-display: none;" in css
    assert f"--sd-header-height: {theme.CHROME_SIZES['compact']};" in css
    assert "--sd-header-bg: #112233;" in css
    assert "--sd-header-on:" in css             # legibility twin, by construction
    assert "--sd-footer-content: '© Example Mesh';" in css
    assert "--sd-bg-effect: none;" in css
    assert "--hug-bg-effect: none;" in css      # the runtime-contract twin

    # ...and back: a FRESH group + editor restores every choice from the cfg.
    g2 = LoginThemeGroup()
    g2.load(cfg)
    g2.open_editor()
    ed2 = g2.editor
    assert ed2._chrome_widgets["header"]["hidden"].isChecked()
    assert ed2._chrome_widgets["header"]["size"].currentData() == "compact"
    assert ed2._chrome_widgets["header"]["bg"].text() == "#112233"
    assert ed2._chrome_widgets["footer"]["text"].text() == "© Example Mesh"
    assert ed2.bg_effect.currentData() == "none"
    # the round-trip is lossless at the css level too
    cfg2 = ImageConfig()
    g2.commit(cfg2)
    assert cfg2.login_theme_css() == css


def test_colour_controls_sync_both_ways_with_the_page_group(qapp):
    g, ed = _opened_editor(qapp)
    ed.primary.setText("#336699")
    assert g.primary.text() == "#336699"        # editor -> page
    g.secondary.setText("#996633")
    assert ed.secondary.text() == "#996633"     # page -> editor
    # a preset picked in the editor drives the page combo AND its hex fill-in,
    # which then syncs straight back into the editor's own hex fields.
    idx = ed.theme_preset.findData("ocean")
    assert idx > 0
    ed.theme_preset.setCurrentIndex(idx)
    assert g.theme_preset.currentData() == "ocean"
    assert g.primary.text() == theme_presets.by_id("ocean").primary
    assert ed.primary.text() == g.primary.text()


def test_chrome_errors_surface_in_the_page_never_raise(qapp):
    g, ed = _opened_editor(qapp)
    ed._chrome_widgets["header"]["bg"].setText("nope")   # textChanged slot fires
    assert g.compose_css() == ""
    assert "not an #RRGGBB" in g.error_text()
    assert g.error_note.isVisibleTo(g)
    ed._chrome_widgets["header"]["bg"].setText("")
    assert g.error_text() == ""


# ── 4. old theme files still load ────────────────────────────────────────────────────
def test_old_theme_files_load_to_shipped_defaults_and_compose_identically(qapp, tmp_path):
    # A config saved BEFORE the chrome fields existed: no login_header_*/footer_*/
    # bg_effect keys at all.
    old = {"login_primary_color": "#336699", "login_font": "System UI"}
    cfg = ImageConfig.from_dict(old)
    assert cfg.login_bg_effect == "gradient"    # the shipped default, filled in
    assert cfg.login_header_hidden is False and cfg.login_footer_text == ""
    expected = theme.compose_login_css("#336699", font_preset="System UI")
    assert cfg.login_theme_css() == expected    # byte-identical: no chrome block
    assert "--sd-header" not in expected and "--sd-bg-effect" not in expected

    p = tmp_path / "old-theme.json"
    p.write_text(json.dumps(old), encoding="utf-8")
    assert ImageConfig.load(str(p)).login_theme_css() == expected

    # an UNTOUCHED renamed surface commits the same bytes an old save composes
    g = LoginThemeGroup()
    g.load(cfg)
    cfg2 = ImageConfig()
    g.commit(cfg2)
    assert cfg2.login_theme_css() == expected


# ── 5. the background-effect picker (--sd-bg-effect, login-ui PR #6's contract) ──────
def test_all_six_contract_effects_are_selectable_and_default_to_gradient(qapp):
    g, ed = _opened_editor(qapp)
    # exactly the contract vocabulary, in contract order, defaulting to gradient
    assert [ed.bg_effect.itemData(i) for i in range(ed.bg_effect.count())] \
        == list(theme.BG_EFFECTS)
    assert ed.bg_effect.currentData() == theme.BG_EFFECT_DEFAULT == "gradient"
    model = ed.bg_effect.model()
    for i in range(ed.bg_effect.count()):
        assert model.item(i).flags() & QtCore.Qt.ItemFlag.ItemIsEnabled, \
            f"{ed.bg_effect.itemData(i)} must be selectable — login-ui PR #6 " \
            "renders the full catalog, and unknown values degrade to gradient"
    # a vanta pick round-trips picker -> cfg -> css like any other theme option
    ed.bg_effect.setCurrentIndex(ed.bg_effect.findData("vanta-globe"))
    cfg = ImageConfig()
    g.commit(cfg)
    assert cfg.login_bg_effect == "vanta-globe"
    cfg.validate_identity()                     # a selectable value is a valid one
    css = cfg.login_theme_css()
    assert "--sd-bg-effect: vanta-globe;" in css
    assert "--hug-bg-effect: vanta-globe;" in css   # the runtime-contract twin


def test_effect_picker_ignores_an_unfocused_wheel(qapp):
    """PR #72's NoWheelComboBox pattern: a hover-scroll on the way past the picker
    must scroll the container, never silently swap the mesh's page background —
    the worklist board-combo corruption class. The ignored event propagates
    (accepted=False) so a containing scroll area still gets the scroll."""
    g, ed = _opened_editor(qapp)
    assert isinstance(ed.bg_effect, NoWheelComboBox)
    ed.bg_effect.clearFocus()
    before = ed.bg_effect.currentData()
    ev = QtGui.QWheelEvent(
        QtCore.QPointF(5, 5), QtCore.QPointF(5, 5),
        QtCore.QPoint(0, 0), QtCore.QPoint(0, -120),
        QtCore.Qt.MouseButton.NoButton, QtCore.Qt.KeyboardModifier.NoModifier,
        QtCore.Qt.ScrollPhase.NoScrollPhase, False)
    QtWidgets.QApplication.sendEvent(ed.bg_effect, ev)
    assert ed.bg_effect.currentData() == before, \
        "wheel over the UNFOCUSED effect picker edited it"
    assert not ev.isAccepted(), \
        "the ignored wheel must propagate so the page can scroll past the picker"


def test_preset_declared_effect_fills_the_picker_and_undeclared_leaves_it(qapp, monkeypatch):
    # A preset MAY declare an effect (ThemePreset.effect). Choosing it fills the
    # picker exactly like the hex fill-in, so the editor never shows a value the
    # preset's delta block would override — and the write-through means cfg +
    # css agree with what the picker shows.
    aurora = theme_presets.ThemePreset(
        "aurora-test", "Aurora", "Colours", "#1976d2", "#0097a7", effect="vanta-fog")
    monkeypatch.setattr(theme_presets, "PRESETS", theme_presets.PRESETS + (aurora,))
    g = LoginThemeGroup()
    g.open_editor()
    ed = g.editor
    ed.theme_preset.setCurrentIndex(ed.theme_preset.findData("aurora-test"))
    assert g.chrome["bg_effect"] == "vanta-fog"
    assert ed.bg_effect.currentData() == "vanta-fog"    # the open editor follows
    cfg = ImageConfig()
    g.commit(cfg)
    assert cfg.login_bg_effect == "vanta-fog"
    assert "--sd-bg-effect: vanta-fog;" in cfg.login_theme_css()
    # a preset WITHOUT a declared effect leaves the operator's pick alone
    ed.theme_preset.setCurrentIndex(ed.theme_preset.findData("ocean"))
    assert g.chrome["bg_effect"] == "vanta-fog"
    assert ed.bg_effect.currentData() == "vanta-fog"


def test_vanta_values_are_valid_persisted_state_and_emit_their_token(qapp):
    # The MODEL path stands alone: a hand-written config needs no GUI round-trip.
    cfg = ImageConfig(login_bg_effect="vanta-fog")
    cfg.validate_identity()                     # must not raise
    assert "--sd-bg-effect: vanta-fog;" in cfg.login_theme_css()


def test_unknown_effect_and_size_fail_closed_like_every_login_field():
    with pytest.raises(IdentityValidationError):
        ImageConfig(login_bg_effect="vanta-spaghetti").validate_identity()
    with pytest.raises(IdentityValidationError):
        ImageConfig(login_header_size="huge").validate_identity()
    with pytest.raises(IdentityValidationError):
        ImageConfig(login_footer_bg="blue").validate_identity()
    # defaults stay valid (the conservative-schema guarantee)
    ImageConfig().validate_identity()
