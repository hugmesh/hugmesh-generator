"""Time-of-day ramps + the desktop schemes.

OPERATOR ASK (2026-08-14): "add more times of day and color themes covering usual
desktop theme color combinations".

A ramp is the NEUTRAL surface only, so it composes with every preset and every style
instead of multiplying the catalogue — 38 presets x 8 ramps is 304 themes, and with the
6 styles on top, 1824. That only holds while ramps stay colour-free and every
combination stays legible, so both are swept here rather than spot-checked.

THE BUG THIS SUITE ALREADY CAUGHT: theme.derive() solves --sd-accent-soft against the
FIXED default shell (#0a0a12). Any ramp with a lighter background than that — dusk,
evening, dawn — left the pre-derived value short, measured at 4.16:1 on crimson/dusk,
below AA on a ramp that looks perfectly reasonable. compose_tokens now re-derives it for
EVERY ramp, choosing lighten or darken by MEASURING the background rather than testing
`mode == "light"` — with eight ramps a name test would hand every new light ramp the
dark ramp's lighten-only derivation, i.e. white-on-white accent text.
"""

from __future__ import annotations

import pytest

from hugmesh_studio.core import theme, theme_presets as tp

AA = 4.5
FLAG_PRESETS = [p for p in tp.PRESETS if p.stripes]


class TestRamps:
    def test_dark_and_light_are_still_the_first_two_modes(self):
        """cfg.login_theme_mode persists these names; reordering breaks stored configs."""
        assert tp.MODES[:2] == ("dark", "light")

    def test_dark_applies_no_override_so_it_stays_byte_identical(self):
        assert tp.RAMPS["dark"] == {}

    def test_no_ramp_declares_a_BRAND_colour(self):
        """Ramps must stay neutral-only or they stop composing with every preset."""
        brand = ("--sd-primary", "--sd-secondary", "--sd-accent")
        for name, toks in tp.RAMPS.items():
            for k in toks:
                assert not k.startswith(brand), f"ramp {name} sets brand token {k}"

    def test_every_ramp_key_exists_in_the_base_neutrals(self):
        """A typo'd key would add a token nothing reads while leaving the real one at
        its dark-ramp value — a half-applied ramp, which is worse than none."""
        for name, toks in tp.RAMPS.items():
            unknown = set(toks) - set(theme._NEUTRALS)
            assert not unknown, f"ramp {name} has unknown keys {unknown}"

    @pytest.mark.parametrize("name", sorted(tp.RAMPS))
    def test_each_ramps_own_text_clears_AA(self, name):
        toks = dict(theme._NEUTRALS); toks.update(tp.RAMPS[name])
        for key in ("--sd-text", "--sd-text-muted"):
            assert theme.contrast_ratio(toks[key], toks["--sd-bg-0"]) >= AA, (
                f"{name}/{key} is illegible on its own background")

    def test_light_ramps_are_detected_by_MEASUREMENT_not_by_name(self):
        assert tp._is_light("#ffffff") and tp._is_light(tp._LIGHT_NEUTRALS["--sd-bg-0"])
        assert not tp._is_light("#0a0a12") and not tp._is_light("#1a1410")

    def test_the_ramps_really_do_differ(self):
        bgs = {n: (dict(theme._NEUTRALS) | t)["--sd-bg-0"] for n, t in tp.RAMPS.items()}
        assert len(set(bgs.values())) == len(bgs), f"duplicate backgrounds: {bgs}"


class TestDesktopSchemes:
    def test_the_group_exists_and_is_populated(self):
        desktop = [p for p in tp.PRESETS if p.group == "Desktop"]
        assert len(desktop) >= 10
        assert "Desktop" in tp.groups()

    def test_each_scheme_carries_an_accent_RAMP_not_just_a_pair(self):
        """The stripes are what the extended palette turns into panes and gradients."""
        for p in [p for p in tp.PRESETS if p.group == "Desktop"]:
            assert len(p.stripes) >= 5, f"{p.preset_id} has too few accents"

    def test_scheme_palettes_are_drawn_from_their_own_accents(self):
        for p in [p for p in tp.PRESETS if p.group == "Desktop"][:4]:
            toks = tp.compose_tokens(p.preset_id, "dark")
            stripes = {c.lower() for c in p.stripes}
            for i in range(1, int(toks["--sd-palette-count"]) + 1):
                assert toks[f"--sd-palette-{i}"].lower() in stripes


class TestEveryCombinationStaysLegible:
    """THE acceptance sweep. 304 themes; the point of more options was that they all
    remain usable, so every one is measured rather than a representative few."""

    @pytest.mark.parametrize("mode", sorted(tp.RAMPS))
    def test_all_presets_on_this_ramp(self, mode):
        checked = 0
        for p in tp.PRESETS:
            t = tp.compose_tokens(p.preset_id, mode)
            bg, text = t["--sd-bg-0"], t["--sd-text"]
            for key in ("--sd-text", "--sd-text-muted", "--sd-accent-soft"):
                assert theme.contrast_ratio(t[key], bg) >= AA, (
                    f"{p.preset_id}/{mode}/{key} = "
                    f"{theme.contrast_ratio(t[key], bg):.2f}:1")
                checked += 1
            for i in range(1, int(t.get("--sd-palette-count", 0)) + 1):
                assert theme.contrast_ratio(t[f"--sd-palette-{i}-soft"], bg) >= AA
                assert theme.contrast_ratio(text, t[f"--sd-pane-{i}-bg"]) >= AA
                checked += 2
        assert checked > 100, f"only {checked} measured on {mode}"

    def test_unknown_mode_still_raises(self):
        """Ramps are data, but a typo'd mode must not silently render the dark one."""
        with pytest.raises(ValueError):
            tp.compose_tokens("dark", "not-a-time-of-day")
