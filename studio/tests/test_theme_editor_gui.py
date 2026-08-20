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
  5. VANTA ANCHOR: the background-effect vocabulary persists host-shell PR #20's
     deferred vanta catalog (the generator-side anchor), while the UI lists those
     rows DISABLED with the login-ui dependency named — never an inert control.
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
from hugmesh_studio.gui.pages._theme_editor import (                # noqa: E402
    VANTA_DEPENDENCY_NOTE, ThemeEditorDialog)
from hugmesh_studio.gui.pages._widgets import Collapsible           # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                 # noqa: E402

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
def test_group_and_both_hosts_say_Themes_not_Web_login_theme(qapp):
    assert LoginThemeGroup().title().startswith("Themes")

    branding = wizard_mod.BrandingPage(
        SimpleNamespace(cfg=ImageConfig(), generator_dir=GENERATOR_DIR))
    assert branding.login_collapsible.title() == "Themes"

    mesh = wizard_mod.LocalMeshPage(
        SimpleNamespace(cfg=ImageConfig(), generator_dir=GENERATOR_DIR,
                        localmesh_selected=True))
    mine = [c for c in mesh.findChildren(Collapsible)
            if c.content is mesh.login_theme]
    assert mine and mine[0].title().startswith("Themes")

    for label in (LoginThemeGroup().title(), branding.login_collapsible.title(),
                  mine[0].title(), branding.subTitle()):
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


# ── 5. the background-effect anchor (host-shell PR #20) ──────────────────────────────
def test_vanta_rows_are_listed_but_disabled_and_name_the_login_ui_dependency(qapp):
    g, ed = _opened_editor(qapp)
    model = ed.bg_effect.model()
    for effect in theme.VANTA_EFFECTS:
        idx = ed.bg_effect.findData(effect)
        assert idx >= 0, f"{effect} missing from the combo"
        assert not (model.item(idx).flags() & QtCore.Qt.ItemFlag.ItemIsEnabled), \
            f"{effect} must stay unselectable until the shell can render it"
        tip = ed.bg_effect.itemData(idx, QtCore.Qt.ItemDataRole.ToolTipRole)
        assert tip and "login-ui" in tip        # the dependency, named
    assert "login-ui" in VANTA_DEPENDENCY_NOTE
    for effect in ("gradient", "none"):         # the exposed pair stays live
        idx = ed.bg_effect.findData(effect)
        assert model.item(idx).flags() & QtCore.Qt.ItemFlag.ItemIsEnabled


def test_vanta_values_are_valid_persisted_state_and_emit_their_token(qapp):
    # The MODEL accepts what the UI defers — that is what "persistence anchor" means.
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
