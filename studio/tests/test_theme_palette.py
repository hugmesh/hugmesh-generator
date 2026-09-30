"""The extended palette: up to 8 base colours, readability-ranked, with backpanes.

OPERATOR ASK (2026-08-14, in three parts):
  "themes should support varieties of colors that use up to 8 colors as the base in
   addition to primary and secondary colors for theme"
  "try to include more possible options and themes possible through bootstrap with
   different styles on top of different colors and borders etc"
  "for color themes with multiple colors up to 8 try to keep the first best colors for
   readability and work the other full spectrum of colors into gradients on backgrounds
   and having various backpanes of router outlets encapsulated web components use those
   alternate colors instead in whole or combination as readibility would be improved"

So readability is not a nice-to-have here, it is the ACCEPTANCE CRITERION — the whole
point of using more colours was that legibility improve, not degrade. The decisive
test in this file is therefore the sweep at the bottom: every pane surface of every flag
preset in both ramps must still carry body text at AA. A palette that looked good and
quietly broke contrast would be a failure of the actual request.

The colours are NOT invented. Every flag preset already declared 3-8 stripes and used
them only as a decorative gradient; the palette is those same colours put to work, which
keeps the presets' existing rule that a flag is never approximated.
"""

from __future__ import annotations

import pytest

from hugmesh_studio.core import theme, theme_presets as tp
from hugmesh_studio.core.theme import (
    MAX_PALETTE, contrast_ratio, palette_tokens, rank_for_readability,
)

DARK = theme.SHELL_BG
# Six stripes of the rainbow: a real, mixed-contrast set (white-ish yellow down to deep
# purple), which is what makes the ranking assertions meaningful.
RAINBOW = ("#e40303", "#ff8c00", "#ffed00", "#008026", "#004dff", "#750787")


class TestRanking:
    def test_best_contrast_comes_first(self):
        ranked = rank_for_readability(RAINBOW, DARK)
        ratios = [contrast_ratio(c, DARK) for c in ranked]
        assert ratios == sorted(ratios, reverse=True)

    def test_yellow_outranks_purple_on_the_dark_shell(self):
        """A concrete anchor so the ordering cannot silently invert."""
        ranked = rank_for_readability(RAINBOW, DARK)
        assert ranked.index("#ffed00") < ranked.index("#750787")

    def test_the_order_INVERTS_on_a_light_background(self):
        """Ranking is a function of the surface, not a property of the colour. If this
        ever stops holding, the light ramp is being handed the dark ramp's picks."""
        light = "#ffffff"
        ranked = rank_for_readability(RAINBOW, light)
        assert ranked.index("#750787") < ranked.index("#ffed00")

    def test_duplicates_are_dropped_case_insensitively(self):
        assert rank_for_readability(("#FF8C00", "#ff8c00"), DARK) == ["#FF8C00"]

    def test_malformed_colour_raises_like_derive_does(self):
        with pytest.raises(ValueError):
            rank_for_readability(("not-a-colour",), DARK)


class TestPaletteTokens:
    def test_caps_at_eight_even_when_given_more(self):
        many = tuple(f"#{i:02x}{i:02x}{i:02x}" for i in range(10, 210, 10))  # 20 colours
        tokens = palette_tokens(many, bg=DARK)
        assert int(tokens["--sd-palette-count"]) == MAX_PALETTE
        assert "--sd-palette-9" not in tokens

    def test_emits_the_full_role_set_per_colour(self):
        tokens = palette_tokens(RAINBOW, bg=DARK)
        for suffix in ("", "-on", "-soft", "-rgb"):
            assert f"--sd-palette-1{suffix}" in tokens
        assert "--sd-pane-1-bg" in tokens
        assert "--sd-pane-1-border" in tokens

    def test_every_soft_variant_clears_AA_as_text_on_the_background(self):
        tokens = palette_tokens(RAINBOW, bg=DARK)
        for i in range(1, int(tokens["--sd-palette-count"]) + 1):
            soft = tokens[f"--sd-palette-{i}-soft"]
            assert contrast_ratio(soft, DARK) >= 4.5, f"palette-{i}-soft is illegible"

    def test_on_colour_is_legible_against_its_own_swatch(self):
        tokens = palette_tokens(RAINBOW, bg=DARK)
        for i in range(1, int(tokens["--sd-palette-count"]) + 1):
            base = tokens[f"--sd-palette-{i}"]
            assert contrast_ratio(tokens[f"--sd-palette-{i}-on"], base) >= 4.5

    def test_empty_palette_emits_nothing_rather_than_placeholders(self):
        assert palette_tokens((), bg=DARK) == {}

    def test_gradient_is_built_from_the_LOW_contrast_leftovers(self):
        """The operator's split: best colours stay readable, "the other full spectrum"
        goes into the background. A bright colour that ranks as foreground-capable must
        not end up washing the background."""
        tokens = palette_tokens(RAINBOW, bg=DARK)
        grad = tokens["--sd-bg-gradient"]
        assert grad.startswith("linear-gradient(")
        # #ffed00 is the most readable stripe here; it belongs in the foreground set.
        assert "#ffed00" not in grad

    def test_gradient_is_always_a_real_gradient(self):
        """Consumers assign this to background-image, where a bare colour is invalid."""
        for colors in [("#750787",), RAINBOW, ("#ffffff", "#fefefe")]:
            g = palette_tokens(colors, bg=DARK)["--sd-bg-gradient"]
            assert g.startswith("linear-gradient(") and g.count(",") >= 1


class TestPaneSurfaces:
    def test_pane_keeps_body_text_legible(self):
        text = "#e8e8f0"
        tokens = palette_tokens(RAINBOW, bg=DARK, text=text)
        for i in range(1, int(tokens["--sd-palette-count"]) + 1):
            pane = tokens[f"--sd-pane-{i}-bg"]
            assert contrast_ratio(text, pane) >= 4.5, f"pane-{i} breaks body text"

    def test_pane_is_actually_tinted_not_just_the_background(self):
        """A pane that fell back to the bg for every colour would pass the contrast test
        while delivering none of the visual separation that was the point."""
        tokens = palette_tokens(RAINBOW, bg=DARK, text="#e8e8f0")
        panes = {tokens[f"--sd-pane-{i}-bg"]
                 for i in range(1, int(tokens["--sd-palette-count"]) + 1)}
        assert DARK not in panes
        assert len(panes) == int(tokens["--sd-palette-count"]), "panes must be distinct"

    def test_pane_fails_SAFE_when_no_tint_can_be_legible(self):
        """Text the same colour as the surface can never pass, so the pane must return
        the untinted background rather than an illegible one."""
        assert theme.pane_surface("#ffffff", "#0a0a12", "#0a0a12") == "#0a0a12"


class TestAdditiveNotDisruptive:
    """The palette may only ADD tokens. Every existing caller passes no palette, and its
    token map must be byte-identical to before — otherwise this feature silently
    restyles every mesh that never asked for it."""

    def test_derive_without_a_palette_emits_no_palette_tokens(self):
        tokens = theme.derive("#ffd700", "#7c4dff")
        assert not [k for k in tokens if "palette" in k or "-pane-" in k]
        assert "--sd-bg-gradient" not in tokens

    def test_derive_with_a_palette_is_a_strict_superset(self):
        base = theme.derive("#ffd700", "#7c4dff")
        rich = theme.derive("#ffd700", "#7c4dff", RAINBOW)
        assert all(rich[k] == v for k, v in base.items()), "an existing token moved"
        assert len(rich) > len(base)

    def test_palette_values_are_literals_so_css_root_accepts_them(self):
        """css_root refuses any value containing var( — the entrypoint interpolates token
        text verbatim and does no colour maths."""
        css = theme.css_root(theme.derive("#ffd700", "#7c4dff", RAINBOW))
        assert "--sd-palette-1:" in css
        assert "--hug-palette-1:" in css, "the --hug-* runtime contract must be emitted"
        assert "--hug-pane-1-bg:" in css


class TestFlagPresetsFeedTheirOwnStripes:
    def test_a_flag_preset_exposes_its_stripes_as_the_palette(self):
        tokens = tp.compose_tokens("progress", "dark")
        count = int(tokens["--sd-palette-count"])
        assert count >= 6
        stripes = {s.lower() for s in tp.by_id("progress").stripes}
        for i in range(1, count + 1):
            assert tokens[f"--sd-palette-{i}"].lower() in stripes, "a colour was invented"

    def test_a_plain_colour_preset_gets_no_palette(self):
        """Presets without stripes have no extra colours to offer, and inventing some
        would be exactly the approximation the flag rule forbids."""
        plain = next(p for p in tp.PRESETS if not p.stripes)
        assert "--sd-palette-count" not in tp.compose_tokens(plain.preset_id, "dark")

    @pytest.mark.parametrize("mode", ["dark", "light"])
    def test_EVERY_flag_preset_stays_legible_in_both_ramps(self, mode):
        """THE acceptance test for the whole feature — readability was the reason to add
        colours, so it has to hold for all 16 flags in both ramps, not just the one that
        was eyeballed. Measured worst case at the time of writing: 4.50:1, exactly AA.
        """
        checked = 0
        for preset in tp.PRESETS:
            if not preset.stripes:
                continue
            tokens = tp.compose_tokens(preset.preset_id, mode)
            bg, text = tokens["--sd-bg-0"], tokens["--sd-text"]
            for i in range(1, int(tokens["--sd-palette-count"]) + 1):
                pane = tokens[f"--sd-pane-{i}-bg"]
                assert contrast_ratio(text, pane) >= 4.5, (
                    f"{preset.preset_id}/{mode}: body text on pane-{i} is "
                    f"{contrast_ratio(text, pane):.2f}:1")
                soft = tokens[f"--sd-palette-{i}-soft"]
                assert contrast_ratio(soft, bg) >= 4.5, (
                    f"{preset.preset_id}/{mode}: palette-{i}-soft on bg is "
                    f"{contrast_ratio(soft, bg):.2f}:1")
                checked += 1
        assert checked >= 60, f"only {checked} colours swept — the flags stopped feeding in"

    def test_light_mode_softs_are_darkened_not_run_to_white(self):
        """theme.soft_for_text only LIGHTENS, which is correct for the fixed dark shell
        and catastrophic on a near-white page — every -soft would reach #ffffff and
        vanish. Same trap already documented for --sd-accent-soft."""
        tokens = tp.compose_tokens("progress", "light")
        softs = [tokens[f"--sd-palette-{i}-soft"]
                 for i in range(1, int(tokens["--sd-palette-count"]) + 1)]
        assert "#ffffff" not in softs
