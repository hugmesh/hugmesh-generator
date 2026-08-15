"""The STYLE axis + the Bootstrap bridge.

OPERATOR ASK (2026-08-14): "try to include more possible options and themes possible
through bootstrap with different styles on top of different colors and borders etc".

Two claims worth pinning:

* STYLES ARE ORTHOGONAL TO COLOUR. A style shapes surfaces (radius, border weight,
  elevation) and never colours them, so any style composes with any palette instead of
  multiplying into "blue-rounded", "blue-square", "pink-rounded"... 6 styles x 26
  presets x 2 ramps is 312 themes from 34 declarations. If a style ever emitted a colour
  this stops being true, so that is asserted directly.
* THE BRIDGE IS WHAT MAKES IT REACH ANYTHING. The fleet's UIs are full of Bootstrap
  classes (`alert alert-warning`, `container`, `btn`), and Bootstrap 5.3 reads its own
  --bs-* properties at runtime. Overriding them in the same :root restyles every
  Bootstrap component with no per-repo SCSS. Without this the style axis would be a
  token nobody consumes — the exact silent no-op the --sd-/--hug- prefix bug already
  cost this feature once.
"""

from __future__ import annotations

import pytest

from hugmesh_studio.core import theme


class TestStyleAxis:
    def test_every_style_declares_the_same_token_set(self):
        """A style missing a token would silently inherit the previous theme's value."""
        keys = [set(v) for v in theme.STYLE_VARIANTS.values()]
        common = set.intersection(*keys)
        for name, toks in theme.STYLE_VARIANTS.items():
            missing = common - set(toks)
            assert not missing, f"style {name} is missing {missing}"

    def test_no_style_emits_a_COLOUR(self):
        """The orthogonality claim. A colour here would tie a shape to a palette."""
        for name, toks in theme.STYLE_VARIANTS.items():
            for k, v in toks.items():
                assert not theme.HEX_RE.match(v.strip()), f"{name}.{k} is a colour: {v}"

    def test_unknown_style_falls_back_rather_than_raising(self):
        """A style is cosmetic; refusing to render a theme over a typo would be worse."""
        assert theme.style_tokens("no-such-style") == theme.style_tokens(theme.DEFAULT_STYLE)

    @pytest.mark.parametrize("name", sorted(theme.STYLE_VARIANTS))
    def test_style_composes_with_a_palette_without_touching_it(self, name):
        base = theme.derive("#ffd700", "#7c4dff", ("#e40303", "#008026"))
        styled = dict(base)
        styled.update(theme.style_tokens(name))
        for k, v in base.items():
            assert styled[k] == v, f"style {name} overwrote {k}"

    def test_flat_and_sharp_differ_from_soft(self):
        soft = theme.style_tokens("soft")
        assert theme.style_tokens("sharp")["--sd-radius"] != soft["--sd-radius"]
        assert theme.style_tokens("flat")["--sd-shadow"] != soft["--sd-shadow"]


class TestBootstrapBridge:
    def _tokens(self, style="soft"):
        t = theme.derive("#ffd700", "#7c4dff")
        t.update(theme.style_tokens(style))
        return t

    def test_maps_brand_colours_onto_bootstrap(self):
        bs = theme.bootstrap_tokens(self._tokens())
        assert bs["--bs-primary"] == "#ffd700"
        assert bs["--bs-body-bg"] == "#0a0a12"
        assert bs["--bs-body-color"] == "#e8e8f0"

    def test_carries_the_rgb_triples_bootstrap_needs_for_alpha(self):
        """Bootstrap composes rgba() from --bs-*-rgb; a hex there is a silent drop."""
        bs = theme.bootstrap_tokens(self._tokens())
        assert bs["--bs-primary-rgb"] == "255,215,0"

    def test_maps_the_style_axis_onto_bootstraps_shape_variables(self):
        bs = theme.bootstrap_tokens(self._tokens("sharp"))
        assert bs["--bs-border-radius"] == "0"
        assert bs["--bs-box-shadow"] == "none"

    def test_a_borderless_style_also_clears_the_border_COLOUR(self):
        """Bootstrap composes its border shorthand from width AND colour, so a 0-width
        border still paints on components that set their own width."""
        bs = theme.bootstrap_tokens(self._tokens("elevated"))
        assert bs["--bs-border-width"] == "0"
        assert bs["--bs-border-color"] == "transparent"

    def test_a_bordered_style_gets_a_real_border_colour(self):
        assert theme.bootstrap_tokens(self._tokens("outlined"))["--bs-border-color"] != "transparent"

    def test_skips_a_bs_token_it_cannot_support(self):
        """A missing source must leave Bootstrap's own default alone, not emit empty."""
        assert "--bs-primary" not in theme.bootstrap_tokens({"--sd-text": "#fff"})

    def test_css_root_EMITS_the_bridge(self):
        """The claim that makes the feature real rather than a token nobody reads."""
        css = theme.css_root(self._tokens("outlined"))
        assert "--bs-primary: #ffd700;" in css
        assert "--bs-border-radius:" in css

    def test_an_explicit_bs_token_in_the_map_WINS(self):
        t = self._tokens()
        t["--bs-primary"] = "#123456"
        css = theme.css_root(t)
        assert "--bs-primary: #123456;" in css
        assert "--bs-primary: #ffd700;" not in css
