"""Every preset on every ramp carries role tokens that read on ITS OWN surfaces.

The shell paints form-field edges, warnings, inline code, success/error text and the
native colour scheme from these tokens (hugmesh-host-shell #169/#175), with dark-shell
literals as fallbacks. Measured on a live mesh before they were derived per theme, the
light ramps failed every one of them (warning 1.49:1, code 2.03:1, hover edge 1.74:1,
success 2.50:1). These tests walk the whole preset x ramp matrix through the real
composition and require WCAG on both page surfaces.
"""
import pytest

from hugmesh_studio.core import theme, theme_presets

MATRIX = [(p.preset_id, m) for p in theme_presets.PRESETS for m in theme_presets.MODES]


def _surfaces(t):
    return t["--sd-bg-0"], t["--sd-bg-1"]


@pytest.mark.parametrize("preset,mode", MATRIX)
def test_role_text_reads_on_both_surfaces(preset, mode):
    t = theme_presets.compose_tokens(preset, mode)
    for name in ("--sd-warning", "--sd-code", "--sd-success", "--sd-error",
                 "--sd-accent-soft", "--sd-text-muted"):
        for s in _surfaces(t):
            assert theme.contrast_ratio(t[name], s) >= 4.5, (preset, mode, name, t[name], s)


@pytest.mark.parametrize("preset,mode", MATRIX)
def test_field_edges_are_visible_on_both_surfaces(preset, mode):
    t = theme_presets.compose_tokens(preset, mode)
    for s in _surfaces(t):
        assert theme.contrast_ratio(t["--sd-field-border"], s) >= theme.FIELD_EDGE_TARGET, \
            (preset, mode, t["--sd-field-border"], s)
        # Hover must be at least as strong as rest, never a fade-out.
        assert theme.contrast_ratio(t["--sd-field-border-hover"], s) >= \
            theme.contrast_ratio(t["--sd-field-border"], s), (preset, mode)


@pytest.mark.parametrize("preset,mode", MATRIX)
def test_colour_scheme_follows_the_ramp(preset, mode):
    t = theme_presets.compose_tokens(preset, mode)
    expected = "light" if theme.is_light(t["--sd-bg-0"]) else "dark"
    assert t["--sd-color-scheme"] == expected


@pytest.mark.parametrize("preset,mode", MATRIX)
def test_rgb_twins_match_their_colours(preset, mode):
    t = theme_presets.compose_tokens(preset, mode)
    for name in ("--sd-success", "--sd-error"):
        r, g, b = (int(t[name][i:i + 2], 16) for i in (1, 3, 5))
        assert t[f"{name}-rgb"] == f"{r},{g},{b}", (preset, mode, name)


def test_the_tokens_reach_the_stylesheet_with_hug_twins():
    css = theme_presets.compose_css("dark", "light")
    for name in ("field-border", "field-border-hover", "warning", "code", "color-scheme"):
        assert f"--sd-{name}:" in css and f"--hug-{name}:" in css, name


def test_unthemed_defaults_equal_the_shell_fallbacks():
    """default_tokens() is the shipped page: the shell compiles these literals."""
    d = theme.default_tokens()
    assert d["--sd-field-border"] == "#8a8aa8"
    assert d["--sd-field-border-hover"] == "#b4b4d0"
    assert d["--sd-warning"] == "#ffb74d"
    assert d["--sd-code"] == "#ff8ac4"
    assert d["--sd-color-scheme"] == "dark"


# ── preset fonts and per-domain renders ───────────────────────────────────────
from hugmesh_studio.core import domain_theme, fonts  # noqa: E402


def test_every_preset_font_names_a_catalogue_face():
    for p in theme_presets.PRESETS:
        assert p.font == "" or p.font in fonts.FONT_PRESETS, (p.preset_id, p.font)


def test_preset_font_is_the_default_and_an_explicit_font_wins(monkeypatch):
    p = theme_presets.PRESETS[0]
    monkeypatch.setattr(theme_presets, "by_id",
                        lambda pid: p.__class__(**{**p.__dict__, "font": "Didone"}))
    assert theme_presets.preset_font(p.preset_id) == "Didone"
    assert theme_presets.preset_font(p.preset_id, chosen="Rounded") == "Rounded"
    assert theme_presets.preset_font("") == ""


def test_domain_render_uses_the_selections_own_colours():
    base = domain_theme.ThemeSelection(preset="dark")
    own = domain_theme.ThemeSelection(preset="dark", primary_hex="#00a86b",
                                      secondary_hex="#e0115f")
    css_base, css_own = domain_theme.render_css(base), domain_theme.render_css(own)
    assert "--sd-primary: #00a86b;" in css_own and "--sd-accent: #e0115f;" in css_own
    assert "#00a86b" not in css_base


def test_domain_render_carries_a_preset_font(monkeypatch):
    p = theme_presets.by_id("dark")
    with_font = p.__class__(**{**p.__dict__, "font": "Old style serif"})
    real = theme_presets.by_id
    monkeypatch.setattr(theme_presets, "by_id",
                        lambda pid: with_font if pid == "dark" else real(pid))
    css = domain_theme.render_css(domain_theme.ThemeSelection(preset="dark"))
    assert "--sd-font-sans: " + fonts.FONT_PRESETS["Old style serif"] in css
    assert css.endswith(theme.FORM_FONT_RESET)
