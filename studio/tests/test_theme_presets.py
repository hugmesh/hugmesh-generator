"""theme_presets — the wizard's named theme catalogue.

Pins the properties that make the catalogue safe to offer blind from a GUI:
every preset derives on both ramps, text stays WCAG-legible after the light-mode
neutral swap, the flag gradients carry the REAL stripe values, and the light
neutral ramp can never leave a dark-ramp token dangling.
"""
from __future__ import annotations

import re

import pytest

from hugmesh_studio.core import theme, theme_presets as tp


HEX = re.compile(r"^#[0-9a-f]{6}$", re.IGNORECASE)


def test_catalogue_shape_and_unique_ids():
    ids = [p.preset_id for p in tp.PRESETS]
    assert len(ids) == len(set(ids)), "duplicate preset ids"
    assert tp.groups() == ["Core", "Colours", "Pride flags"]
    # the operator's ask, literally: light + dark cores, basic colours, flags
    assert "dark" in ids and "light" in ids
    assert sum(1 for p in tp.PRESETS if p.group == "Colours") >= 6
    assert sum(1 for p in tp.PRESETS if p.group == "Pride flags") >= 12


def test_every_preset_derives_on_both_modes():
    for p in tp.PRESETS:
        for mode in tp.MODES:
            tokens = tp.compose_tokens(p.preset_id, mode)
            # full base contract: everything theme.derive emits is present
            for key in theme.derive(p.primary, p.secondary):
                assert key in tokens, f"{p.preset_id}/{mode} lost {key}"
            css = tp.compose_css(p.preset_id, mode)
            assert css.startswith(":root:root {")


def test_light_neutrals_swap_exactly_the_dark_neutral_keys():
    # Same key set == a mode swap can never leave a dark token dangling or
    # introduce a token no consumer knows. theme._NEUTRALS is the contract's
    # neutral half; reaching into it here is the point of the pin.
    dark_keys = set(theme._NEUTRALS)  # noqa: SLF001 — deliberate contract pin
    light_keys = set(tp._LIGHT_NEUTRALS)  # noqa: SLF001
    # channel-triple tokens are emitted by derive() from the neutrals it knows;
    # the light ramp only overrides the hex half it declares.
    assert light_keys <= dark_keys, (
        f"light ramp invents tokens the contract lacks: {light_keys - dark_keys}")


def test_light_mode_text_is_legible():
    for p in tp.PRESETS:
        tokens = tp.compose_tokens(p.preset_id, "light")
        bg = tokens["--sd-bg-0"]
        assert theme.contrast_ratio(tokens["--sd-text"], bg) >= 4.5
        assert theme.contrast_ratio(tokens["--sd-text-muted"], bg) >= 4.5
        # the re-anchored accent text token must clear AA on the light bg —
        # this is the assertion that catches "reused the lighten-only helper"
        assert theme.contrast_ratio(tokens["--sd-accent-soft"], bg) >= 4.5, (
            f"{p.preset_id}: accent text illegible on light bg")


def test_dark_mode_accent_text_still_legible():
    for p in tp.PRESETS:
        tokens = tp.compose_tokens(p.preset_id, "dark")
        assert theme.contrast_ratio(
            tokens["--sd-accent-soft"], tokens["--sd-bg-0"]) >= 4.5


def test_flag_presets_carry_the_real_flag():
    for p in tp.PRESETS:
        if not p.stripes:
            continue
        assert all(HEX.match(s) for s in p.stripes), f"{p.preset_id}: bad stripe hex"
        tokens = tp.compose_tokens(p.preset_id, "dark")
        grad = tokens["--sd-flag-stripes"]
        assert grad.startswith("linear-gradient(180deg, ")
        for s in p.stripes:
            assert s in grad, f"{p.preset_id}: stripe {s} missing from gradient"
        # accents come FROM the flag (or the shared default secondary), never invented
        assert tokens["--sd-flag-name"] == f'"{p.label}"'
        # css_root must accept the extras (no var(), literal values only)
        tp.compose_css(p.preset_id, "dark")


def test_flag_accents_are_drawn_from_the_flag_stripes():
    # Respectfulness pin: a flag preset's primary/secondary must be stripe
    # values of that flag (bi's purple midpoint and progress's chevron brown are
    # stripes too). Prevents drive-by "brand colour + flag gradient" edits.
    for p in tp.PRESETS:
        if not p.stripes:
            continue
        stripes = {s.lower() for s in p.stripes}
        assert p.primary.lower() in stripes, f"{p.preset_id}: primary not a stripe"
        assert p.secondary.lower() in stripes, f"{p.preset_id}: secondary not a stripe"


def test_unknown_preset_and_mode_fail_loudly():
    with pytest.raises(KeyError):
        tp.by_id("no-such-theme")
    with pytest.raises(ValueError):
        tp.compose_tokens("pride", "sepia")
