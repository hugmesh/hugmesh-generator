"""tui — the Themes SCREEN (#63's TUI surface): rename, edits, fail-closed.

Headless and Qt-free. The screen edits the same ``cfg.login_*`` fields through
the same closed vocabularies as the GUI editor, and the CSS it previews is
``cfg.login_theme_css()`` — the delivered bytes, byte for byte.
"""
import pytest

from hugmesh_studio.core import theme, theme_presets
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.tui import journey, themes


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _at_themes() -> journey.Journey:
    """A journey standing on the Themes screen (standalone flow -> branding -> t)."""
    j = journey.Journey(".")
    for line in ("", "", "", ""):        # welcome, mode, role, hardware
        j.feed(line)
    assert j.slug == "branding"
    j.feed("t")
    assert j.overlay is not None
    return j


# ── the rename (#63): the surface says Themes ───────────────────────────────────────
def test_the_surface_is_titled_themes():
    j = _at_themes()
    assert j.title() == "Themes"
    assert j.lines()[0] == "Themes"


def test_branding_step_offers_the_themes_screen_not_a_popup():
    j = journey.Journey(".")
    for line in ("", "", "", ""):
        j.feed(line)
    text = "\n".join(j.lines())
    assert "Themes" in text and "t opens the Themes screen" in text


def test_persisted_keys_stay_login_star():
    # the rename is labels-only: the persisted field names never changed, so old
    # sessions load unchanged (the GUI pins the same rule).
    j = _at_themes()
    j.feed("1 #112233")
    assert j.cfg.login_primary_color == "#112233"
    assert "login_primary_color" in ImageConfig().to_dict()


# ── preset interplay: preset fills hexes; a hand-edited hex flips to Custom ─────────
def test_preset_pick_fills_the_two_colours():
    j = _at_themes()
    j.feed("p")
    j.feed("1")                          # first catalogue entry
    p = theme_presets.PRESETS[0]
    assert j.cfg.login_theme_preset == p.preset_id
    assert j.cfg.login_primary_color == p.primary
    assert j.cfg.login_secondary_color == p.secondary


def test_hand_edited_hex_flips_the_preset_to_custom():
    j = _at_themes()
    j.feed("p")
    j.feed("1")
    j.feed("2 #445566")
    assert j.cfg.login_theme_preset == ""
    assert j.cfg.login_secondary_color == "#445566"


def test_preset_zero_returns_to_custom_colours():
    j = _at_themes()
    j.feed("p")
    j.feed("0")
    assert j.cfg.login_theme_preset == ""


# ── chrome edits ride the same fields the GUI editor writes ─────────────────────────
def test_chrome_edits_round_trip_into_cfg_and_css():
    j = _at_themes()
    j.feed("hh")                          # hide the header
    j.feed("fs tall")
    j.feed("fb #001122")
    j.feed("ft (c) ACME")
    cfg = j.cfg
    assert cfg.login_header_hidden is True
    assert cfg.login_footer_size == "tall"
    assert cfg.login_footer_bg == "#001122"
    assert cfg.login_footer_text == "(c) ACME"
    css = cfg.login_theme_css()
    assert "--sd-header-display: none" in css
    assert f"--sd-footer-height: {theme.CHROME_SIZES['tall']}" in css
    assert "--sd-footer-bg: #001122" in css


def test_dash_resets_a_chrome_field_to_shipped():
    j = _at_themes()
    j.feed("fs tall")
    j.feed("fs -")
    assert j.cfg.login_footer_size == ""


# ── fail-closed: malformed input never lands, never raises ─────────────────────────
def test_bad_hex_and_unknown_size_fail_closed_inline():
    j = _at_themes()
    j.feed("1 zzz")
    assert "not a colour" in j.status and j.cfg.login_primary_color == ""
    j.feed("hs huge")
    assert "unknown size" in j.status and j.cfg.login_header_size == ""
    assert not j.done                     # inline message, never a crash/quit


def test_unrecognised_edit_gets_the_command_list_hint():
    j = _at_themes()
    j.feed("frobnicate")
    assert "command list" in j.status


# ── the background effect: vanta listed but refused with the dependency ────────────
def test_effects_list_marks_the_vanta_rows_unavailable_with_the_dependency():
    j = _at_themes()
    j.feed("e")
    text = "\n".join(j.lines())
    for effect in theme.VANTA_EFFECTS:
        assert themes.EFFECT_LABELS[effect] in text
    assert text.count("(unavailable)") == len(theme.VANTA_EFFECTS)
    assert "hugmesh-host-shell PR #20" in text


def test_picking_a_vanta_row_is_refused_not_silently_inert():
    j = _at_themes()
    j.feed("e")
    idx = theme.BG_EFFECTS.index("vanta-fog") + 1
    j.feed(str(idx))
    assert j.cfg.login_bg_effect == "gradient"       # unchanged
    assert "not selectable yet" in j.status
    assert "hugmesh-host-shell PR #20" in j.status


def test_gradient_and_none_are_selectable():
    j = _at_themes()
    j.feed("e")
    j.feed(str(theme.BG_EFFECTS.index("none") + 1))
    assert j.cfg.login_bg_effect == "none"


def test_effect_vocabulary_is_the_theme_modules():
    # every BG_EFFECTS entry is offered (labelled), none invented
    assert set(themes.EFFECT_LABELS) == set(theme.BG_EFFECTS)


# ── the preview is the delivered bytes ──────────────────────────────────────────────
def test_css_preview_is_cfg_login_theme_css_verbatim():
    j = _at_themes()
    j.feed("1 #112233")
    j.feed("hh")
    j.feed("css")
    css_lines = j.cfg.login_theme_css().splitlines()
    shown = j.lines()
    for line in css_lines:
        assert line in shown


def test_all_defaults_preview_says_nothing_is_emitted():
    j = _at_themes()
    j.feed("css")
    assert any("no themed css is emitted" in ln for ln in j.lines())
    assert j.cfg.login_theme_css() == ""


def test_q_closes_the_screen_back_to_branding_not_out():
    j = _at_themes()
    j.feed("q")
    assert j.overlay is None and j.slug == "branding" and not j.done
