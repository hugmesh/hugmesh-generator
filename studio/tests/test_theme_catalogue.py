"""The generated theme catalogue: shape, coverage and the high-contrast promise.

Legibility of every generated preset on every ramp is walked by
test_theme_state_tokens.py (it parametrizes over theme_presets.PRESETS x MODES, which
now includes the catalogue); this file pins what the catalogue itself promises.
"""
import re

import pytest

from hugmesh_studio.core import fonts, theme, theme_catalogue, theme_presets

# hugmesh-admin-bff-api DomainThemeRequest: @Size(max = 64) @Pattern(^[a-z0-9][a-z0-9-]*$)
BFF_PRESET_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def test_catalogue_is_ten_times_the_hand_written_set():
    assert len(theme_presets.PRESETS) >= 10 * 38


def test_every_id_is_one_the_admin_bff_accepts():
    for p in theme_presets.PRESETS:
        assert BFF_PRESET_RE.match(p.preset_id) and len(p.preset_id) <= 64, p.preset_id


def test_every_palette_ships_with_every_background():
    effects = {e for _s, _l, e, _n in theme_catalogue.BACKGROUNDS}
    for pal in theme_catalogue.PALETTES:
        got = {p.effect for p in theme_presets.PRESETS
               if p.preset_id == pal.slug or p.preset_id.startswith(pal.slug + "-")}
        assert effects <= got, (pal.slug, effects - got)


def test_every_effect_is_one_the_shell_renders():
    for p in theme_presets.PRESETS:
        assert p.effect == "" or p.effect in theme.BG_EFFECTS, (p.preset_id, p.effect)


def test_webgl_backgrounds_are_present():
    vanta = {p.effect for p in theme_presets.PRESETS if p.effect in theme.VANTA_EFFECTS}
    assert vanta == set(theme.VANTA_EFFECTS)


def test_some_presets_change_the_font_and_all_fonts_are_catalogued():
    with_font = [p for p in theme_presets.PRESETS if p.font]
    assert len({p.font for p in with_font}) >= 10
    for p in with_font:
        assert p.font in fonts.FONT_PRESETS, (p.preset_id, p.font)


def test_high_contrast_presets_hold_still():
    hc = [p for p in theme_presets.PRESETS if p.group == "High contrast"]
    assert len(hc) >= 20
    for p in hc:
        assert p.effect == "none", p.preset_id


@pytest.mark.parametrize("ramp", ["contrast-dark", "contrast-light"])
@pytest.mark.parametrize("preset", [p.preset_id for p in theme_presets.PRESETS
                                    if p.group == "High contrast"])
def test_high_contrast_ramps_reach_aaa(preset, ramp):
    t = theme_presets.compose_tokens(preset, ramp)
    for s in (t["--sd-bg-0"], t["--sd-bg-1"]):
        assert theme.contrast_ratio(t["--sd-text"], s) >= 7.0
        assert theme.contrast_ratio(t["--sd-text-muted"], s) >= 7.0
        assert theme.contrast_ratio(t["--sd-field-border"], s) >= 4.5


def test_hand_written_presets_keep_their_order_and_ids():
    assert [p.preset_id for p in theme_presets.PRESETS[:3]] == ["dark", "light", "ocean"]


def test_ids_are_unique():
    ids = [p.preset_id for p in theme_presets.PRESETS]
    assert len(ids) == len(set(ids))
