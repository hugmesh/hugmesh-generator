"""tui — where the web look is chosen in the text interface, after the theme move.

On 2026-10-21 the look moved to section 2 (Look) of each domain's Brand settings on
the Domain services step (the operator: "the theme selection should be there instead
of where it is now"). The Branding step stopped offering ``t``, and the cfg-bound
Themes screen it used to open became dead code: nothing but its own tests opened it.
The screen was removed in the same cleanup that removed the window's LoginThemeGroup
and ThemeEditorDialog; everything it edited is a LookText command (tests in
test_look_text.py and tests/journey/test_brand_design.py).
"""
import importlib

import pytest

from hugmesh_studio.core import brand_look, theme
from hugmesh_studio.tui import journey, themes


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def test_branding_step_no_longer_offers_themes_and_says_where_the_look_is():
    """The operator: "the theme selection should be there instead of where it is now"
    — in each domain's section. The branding step says so, and ``t`` opens nothing."""
    j = journey.Journey(".")
    for line in ("", "", "", ""):
        j.feed(line)
    assert j.slug == "branding"
    text = "\n".join(j.lines())
    assert "t opens the Themes screen" not in text and "t. Themes" not in text
    assert "section 2 (Look)" in text
    j.feed("t")
    assert j.overlay is None


def test_the_dead_themes_screen_is_gone_and_the_look_screen_stays():
    """The cleanup removed the unreachable cfg-bound screen; the look screen every
    route mounts (LookText) is what remains in this module."""
    mod = importlib.import_module("hugmesh_studio.tui.themes")
    assert not hasattr(mod, "ThemesScreen")
    assert "ThemesScreen" not in mod.__all__
    assert {"LookText", "FIELD_COMMANDS", "SECTIONS"} <= set(mod.__all__)


def test_every_old_themes_screen_edit_is_a_look_text_command():
    """What the removed screen could edit, the look screen can: colours, preset,
    ramp, font, header, footer and the background effect, with the same short verbs."""
    for field, verb in (("primary", "1"), ("secondary", "2"), ("preset", "p"),
                        ("mode", "m"), ("font", "font"), ("header_hidden", "hh"),
                        ("header_size", "hs"), ("header_bg", "hb"), ("header_text", "ht"),
                        ("footer_hidden", "fh"), ("footer_size", "fs"), ("footer_bg", "fb"),
                        ("footer_text", "ft"), ("bg_effect", "e")):
        assert themes.FIELD_COMMANDS[field] == verb, field


def test_effect_vocabulary_is_the_theme_modules():
    # every BG_EFFECTS entry is offered (labelled), none invented, one table in core
    assert set(themes.EFFECT_LABELS) == set(theme.BG_EFFECTS)
    assert themes.EFFECT_LABELS is brand_look.EFFECT_LABELS
