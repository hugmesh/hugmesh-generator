"""core/theme.py — the login-theme derivation contract.

The two claims that MUST be tests, not comments (they die silently otherwise):
  1. AA BY CONSTRUCTION: ``on_color`` guarantees >= 4.5:1 for ANY sRGB colour ONLY
     because it picks pure #000000/#ffffff. The palette's softer near-black/near-white
     greys measurably FAIL (4.031:1 worst case) — so if anyone "improves" the endpoints
     the guarantee dies. The sweep below re-proves it on a coarse grid every run.
  2. GOLDEN PIN: ``default_tokens()`` must stay byte-identical to the literals shipped
     in login-ui (styles.scss :root + _tokens.scss), because the unbranded fallback and
     the injected default must render the SAME pixels. derive() deliberately CANNOT
     reproduce the hand-tuned $neon-dim hue drift, which is why the defaults are
     literal — this test is what keeps that arrangement honest.
"""
import pytest

from hugmesh_studio.core import theme
from hugmesh_studio.core import theme_presets

# ── golden pin: the shipped login-ui literals ───────────────────────────────────────
# styles.scss :root (the consumed --sd-* contract)
_SHIPPED_ROOT = {
    "--sd-bg-0": "#0a0a12",
    "--sd-bg-1": "#12121e",
    "--sd-bg-2": "#1a1a2e",
    "--sd-border": "#1e1e32",
    "--sd-text": "#e8e8f0",
    "--sd-text-muted": "#a8acc4",
    "--sd-accent": "#7c4dff",
    "--sd-accent-soft": "#b388ff",
    "--sd-success": "#4caf50",
    "--sd-error": "#ff6b6b",
}
# _tokens.scss neutral ramp + the neon triple
_SHIPPED_TOKENS_SCSS = {
    "--sd-black": "#0a0a0a",
    "--sd-charcoal": "#111111",
    "--sd-surface": "#1c1c1c",
    "--sd-mid": "#3a3a3a",
    "--sd-muted": "#777777",
    "--sd-light": "#bbbbbb",
    "--sd-offwhite": "#e8e8e8",
    "--sd-primary": "#ffd700",         # $neon
    "--sd-primary-bright": "#ffe566",  # $neon-bright (L70)
    "--sd-primary-dim": "#cc9900",     # $neon-dim (hand-tuned: hue drifted 50.6->45)
}


def test_default_tokens_pin_the_shipped_bytes():
    got = theme.default_tokens()
    for name, value in {**_SHIPPED_ROOT, **_SHIPPED_TOKENS_SCSS}.items():
        assert got[name] == value, f"{name}: {got[name]} != shipped {value}"


def test_default_secondary_is_the_shipped_accent_pair():
    got = theme.default_tokens()
    assert got["--sd-secondary"] == "#7c4dff"
    assert got["--sd-secondary-soft"] == "#b388ff"   # AAA accent text, kept literal
    assert got["--sd-accent"] == got["--sd-secondary"]
    assert got["--sd-accent-soft"] == got["--sd-secondary-soft"]


def test_derive_cannot_reproduce_the_hand_tuned_dim__so_defaults_stay_literal():
    # The reason default_tokens() exists: $neon-dim's hue drift is not derivable.
    assert theme._dim("#ffd700") != "#cc9900"
    # ...but the L-movement rule is exact at L=50: bright lands on L70, dim on L40.
    assert theme._lightness(theme._bright("#ffd700")) == pytest.approx(0.70, abs=0.005)
    assert theme._lightness(theme._dim("#ffd700")) == pytest.approx(0.40, abs=0.005)


# ── AA by construction ──────────────────────────────────────────────────────────────
_STRIDE = 17  # 16 steps/channel -> 4096 colours; includes both 0x00 and 0xff endpoints


def _grid():
    steps = list(range(0, 256, _STRIDE)) + [255]
    for r in steps:
        for g in steps:
            for b in steps:
                yield f"#{r:02x}{g:02x}{b:02x}"


def test_on_color_is_AA_for_every_swept_srgb_colour_and_uses_pure_endpoints_only():
    worst = 21.0
    for c in _grid():
        on = theme.on_color(c)
        assert on in ("#000000", "#ffffff"), (
            f"on_color({c}) = {on}: the AA-for-all-sRGB theorem holds ONLY for pure "
            "endpoints (brand greys measurably fail at 4.031:1) — do not soften these")
        worst = min(worst, theme.contrast_ratio(on, c))
    assert worst >= 4.5, f"AA guarantee broken: worst swept contrast {worst:.3f}"


def test_soft_for_text_clears_AA_on_the_shell_for_every_swept_colour():
    steps = list(range(0, 256, 51)) + [255]  # coarser: soft_for_text iterates internally
    for r in steps:
        for g in steps:
            for b in steps:
                c = f"#{r:02x}{g:02x}{b:02x}"
                soft = theme.soft_for_text(c)
                cr = theme.contrast_ratio(soft, theme.SHELL_BG)
                assert cr >= 4.5, f"soft({c})={soft} only {cr:.3f}:1 on the shell"


def test_soft_keeps_the_exact_hex_when_it_already_passes():
    assert theme.soft_for_text("#b388ff") == "#b388ff"   # 7.38:1 shipped AAA
    assert theme.soft_for_text("#ffffff") == "#ffffff"


# ── measured regressions (the numbers that fixed real doc/UI bugs) ──────────────────
def test_shipped_accent_measures_4_10_as_text_not_the_3_22_the_old_comment_claimed():
    assert theme.contrast_ratio("#7c4dff", "#0a0a12") == pytest.approx(4.096, abs=0.01)


def test_shipped_mfa_button_text_fails_AA_and_derived_on_fixes_it():
    # mfa.component.scss hardcoded #0a0a12 text on the accent: 4.096:1 < 4.5 (AA fail).
    assert theme.contrast_ratio("#0a0a12", "#7c4dff") < 4.5
    # the derived -on for that accent is white, and it passes.
    assert theme.on_color("#7c4dff") == "#ffffff"
    assert theme.contrast_ratio("#ffffff", "#7c4dff") >= 4.5


def test_contrast_ratio_endpoints():
    assert theme.contrast_ratio("#ffffff", "#000000") == pytest.approx(21.0, abs=0.01)
    assert theme.contrast_ratio("#808080", "#808080") == pytest.approx(1.0, abs=0.001)


# ── derive(): the contract shape ────────────────────────────────────────────────────
def test_derive_key_set_is_exactly_the_default_key_set():
    # No dead tokens, no missing tokens: a branded map answers every name the
    # unbranded fallback answers, and nothing extra.
    assert set(theme.derive("#336699", "#996633")) == set(theme.default_tokens())


def test_derive_blank_secondary_falls_back_to_the_shipped_accent():
    d = theme.derive("#336699")
    assert d["--sd-secondary"] == "#7c4dff"
    assert d["--sd-accent"] == "#7c4dff"


def test_derive_rgb_triples_are_bare_channel_lists_for_rgba_composition():
    # rgba(var(--sd-primary-rgb), .85) needs "r,g,b" — a hex here fails SILENTLY in
    # the browser (Sass passes it through verbatim; verified on dart-sass 1.101.0).
    d = theme.derive("#336699", "#996633")
    assert d["--sd-primary-rgb"] == "51,102,153"
    assert d["--sd-secondary-rgb"] == "153,102,51"
    assert d["--sd-surface-rgb"] == "28,28,28"


@pytest.mark.parametrize("bad", ["", "336699", "#36c", "#3366zz", "#33669", "blue"])
def test_derive_blocks_malformed_hex(bad):
    with pytest.raises(ValueError):
        theme.derive(bad)
    with pytest.raises(ValueError):
        theme.derive("#336699", bad if bad else "x")


# ── warnings(): non-blocking legibility guidance (#387: warn where it renders) ──────
def test_warnings_flag_close_pair_shellalike_and_dark_primary_but_never_block():
    assert theme.warnings("#336699", "#996633") == []
    assert any("close" in w for w in theme.warnings("#336699", "#33669a"))
    assert any("shell background" in w for w in theme.warnings("#0b0b13"))
    dark = theme.warnings("#101010", "#7c4dff")
    assert any("paler than the swatch" in w for w in dark)
    assert theme.warnings("nonsense") == []   # malformed is validation's block, not ours


# ── css emission ────────────────────────────────────────────────────────────────────
def test_css_root_emits_doubled_root_selector_and_every_token():
    d = theme.derive("#336699", "#996633")
    css = theme.css_root(d)
    assert css.startswith(":root:root {\n")
    assert css.rstrip().endswith("}")
    for name, value in d.items():
        assert f"  {name}: {value};" in css


def test_css_root_prepends_font_faces_before_the_root_block():
    css = theme.css_root({"--sd-x": "#000000"}, font_faces="@font-face { /* f */ }\n")
    assert css.index("@font-face") < css.index(":root:root")


def test_css_root_refuses_non_literal_tokens():
    with pytest.raises(ValueError):
        theme.css_root({"--sd-x": "var(--sd-y)"})


class TestAccentOnAndRgbTwins:
    """Two token families that were promised and never emitted.

    Both are the same class of bug: a token the UIs need did not exist, so the UIs
    improvised — and both improvisations are broken in ways nothing would report.
    """

    def test_accent_has_an_on_twin_like_primary_and_secondary(self):
        # The module docstring promises a "*-on" twin that auto-picks #000/#fff by
        # luminance. It delivered that for primary and secondary but not for --sd-accent,
        # which is the token the UIs actually use as a BUTTON BACKGROUND.
        t = theme.derive("#7c4dff")
        assert "--sd-accent-on" in t
        assert t["--sd-accent-on"] in ("#000000", "#ffffff")

    def test_the_default_theme_has_it_too(self):
        assert "--sd-accent-on" in theme.default_tokens()

    def test_accent_on_clears_AA_for_every_shipped_preset_and_ramp(self):
        # WHY THIS MATTERS: with no token to reach for, a dozen components hardcoded
        # `color: #fff` on an accent background. Measured against the shipped presets that
        # FAILS AA on 24 of 38 — white on the nonbinary flag's #fcf434 is 1.16:1.
        failures = []
        for preset in theme_presets.PRESETS:
            for mode in theme_presets.MODES:
                tokens = theme_presets.compose_tokens(preset.preset_id, mode)
                accent, on = tokens.get("--sd-accent", ""), tokens.get("--sd-accent-on", "")
                assert on, f"{preset.preset_id}/{mode} has no --sd-accent-on"
                ratio = theme.contrast_ratio(on, accent)
                if ratio < 4.5:
                    failures.append((preset.preset_id, mode, round(ratio, 2)))
        assert failures == [], f"accent text below AA: {failures}"

    def test_it_reuses_the_existing_derivation_rather_than_a_second_one(self):
        # --sd-accent IS secondary, so the correct value is the one already computed for
        # --sd-secondary-on. Any drift between them means a second implementation crept in.
        for hexv in ("#7c4dff", "#fcf434", "#00ffff", "#0a0a12", "#ffffff"):
            t = theme.derive("#ffd700", hexv)
            assert t["--sd-accent-on"] == t["--sd-secondary-on"]

    def test_every_hex_neutral_has_a_channel_triple(self):
        # `rgba(var(--x), a)` needs channels, not a hex — a hex makes the whole
        # declaration invalid and the browser drops it SILENTLY. hugmesh-matrix-ui has
        # five such declarations rendering with no border today.
        t = theme.derive("#7c4dff")
        for name, value in list(t.items()):
            if name.endswith("-rgb") or not theme.HEX_RE.match(str(value)):
                continue
            if not name.startswith("--sd-"):
                continue
            # Only the fixed neutral ramp is guaranteed a twin; derived brand tokens
            # already carry their own where consumers need them.
            if name in theme._NEUTRALS:
                assert f"{name}-rgb" in t, f"{name} has no channel triple"

    @pytest.mark.parametrize("token", [
        "--sd-success-rgb", "--sd-error-rgb", "--sd-text-rgb", "--sd-bg-0-rgb",
    ])
    def test_the_specific_twins_live_consumers_already_reference(self, token):
        assert token in theme.derive("#7c4dff")

    def test_triples_are_comma_separated_channels_not_hex(self):
        t = theme.derive("#7c4dff")
        assert t["--sd-success-rgb"] == "76,175,80"
        assert "#" not in t["--sd-error-rgb"]
