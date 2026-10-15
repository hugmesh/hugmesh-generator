"""core/brand_look and the stylesheet writer's allow-list (#654: D6, D7, D19).

Qt-free. One function resolves a brand's look field by field (the superbrand's value
unless the brand overrides that one field), one function turns a look into the
stylesheet, and the writer underneath refuses anything that is not a known custom
property or carries a url( that is not a data: picture made by the re-encoder. The
budget is 100 KiB of finished stylesheet per brand, and the two bigger ceilings (one
environment string, the ConfigMap) are checked with their numbers in the sentence.
"""
import base64
import os
import struct
import zlib

import pytest

from hugmesh_studio.core import brand_images as bi
from hugmesh_studio.core import brand_look as bl
from hugmesh_studio.core import theme, theme_presets
from hugmesh_studio.core.config import ImageConfig

PNG_SIG = b"\x89PNG\r\n\x1a\n"


def _chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))


def png_bytes(w: int, h: int, *, noise: bool = False, opaque: bool = False) -> bytes:
    """A real PNG; ``noise`` makes one zlib cannot shrink (for the budget tests),
    ``opaque`` a visible colour gradient (the default is fully transparent, which a
    screenshot cannot tell from no picture at all)."""
    if opaque:
        raw = b"".join(b"\x00" + b"".join(bytes((x * 255 // max(1, w - 1), y * 255 // max(1, h - 1),
                                                  160, 255)) for x in range(w))
                       for y in range(h))
    elif noise:
        rnd = zlib.crc32(b"seed")
        rows = []
        for y in range(h):
            row = bytearray(b"\x00")
            for x in range(w * 4):
                rnd = (rnd * 1103515245 + 12345) & 0xFFFFFFFF
                row.append(rnd >> 24)
            rows.append(bytes(row))
        raw = b"".join(rows)
    else:
        raw = (b"\x00" + bytes(w * 4)) * h
    return (PNG_SIG + _chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + _chunk(b"IDAT", zlib.compress(raw, 9)) + _chunk(b"IEND", b""))


def picture(w=8, h=8, kind="logo", noise=False):
    return bi.reencode(png_bytes(w, h, noise=noise), kind)


# ── the field table ──────────────────────────────────────────────────────────────────
def test_every_field_has_a_default_and_the_cfg_projection_names_real_fields():
    assert set(bl.LOOK_DEFAULTS) == set(bl.LOOK_FIELDS)
    cfg = ImageConfig()
    for field, attr in bl.CFG_FIELDS.items():
        assert field in bl.LOOK_FIELDS
        assert hasattr(cfg, attr), f"{field} is projected to cfg.{attr}, which does not exist"
    # the fields the config cannot hold yet are the ones the brand record carries
    assert set(bl.LOOK_FIELDS) - set(bl.CFG_FIELDS) == {
        "style", "decor", "logo_image", "login_bg_image"}
    assert "desktop_logo" in bl.IDENTITY_FIELDS       # a logo is an affiliation


def test_unknown_fields_are_refused_not_dropped():
    with pytest.raises(bl.LookError, match="tenant_colour"):
        bl.normalise({"primary": "#112233", "tenant_colour": "#000000"})


# ── D7: inherit, then override, field by field ───────────────────────────────────────
def test_effective_look_is_the_superbrand_unless_the_brand_overrides_that_field():
    sb = {"preset": "ocean", "primary": "#1976d2", "secondary": "#0097a7", "style": "glass"}
    brand = {"primary": "#123456"}
    eff = bl.effective_look(sb, brand)
    assert eff["primary"] == "#123456"                  # the brand's own
    assert eff["secondary"] == "#0097a7"                # inherited
    assert eff["style"] == "glass"                      # inherited
    assert eff["decor"] == bl.LOOK_DEFAULTS["decor"]    # neither set: the default
    res = bl.resolve(sb, brand)
    assert res["primary"] == bl.Resolved("#123456", bl.OWN)
    assert res["secondary"] == bl.Resolved("#0097a7", bl.SUPERBRAND)
    assert res["decor"].source == bl.SUPERBRAND         # a default is the superbrand's value
    # the superbrand's own resolution says every field is its own
    assert all(r.source == bl.OWN for r in bl.resolve(sb).values())


def test_an_override_changes_only_that_brand_and_the_two_click_removes_it():
    sb = bl.Look({"preset": "forest", "primary": "#2e7d32"})
    a = bl.Look({}, base=sb.effective())
    b = bl.Look({}, base=sb.effective())
    a.set("primary", "#ff0000")
    assert a.get("primary") == "#ff0000" and a.source("primary") == bl.OWN
    assert b.get("primary") == "#2e7d32" and b.source("primary") == bl.SUPERBRAND
    assert sb.get("primary") == "#2e7d32"
    assert a.record() == {"primary": "#ff0000"}        # only the fields it changed
    a.use_superbrand("primary")
    assert a.record() == {} and a.source("primary") == bl.SUPERBRAND
    # using the superbrand's value for a field that was never overridden changes nothing
    a.use_superbrand("secondary")
    assert a.record() == {}


def test_setting_a_field_to_the_superbrand_value_still_counts_as_the_brands_own():
    """A brand that typed the same colour as the superbrand has made a choice: if
    the superbrand changes later, this brand keeps its colour. Only the two-click
    puts the field back under the superbrand."""
    sb = bl.Look({"primary": "#2e7d32"})
    a = bl.Look({}, base=sb.effective())
    a.set("primary", "#2e7d32")
    assert a.source("primary") == bl.OWN and a.record() == {"primary": "#2e7d32"}


def test_design_mode_records_only_what_differs_from_the_defaults():
    sb = bl.Look({})
    assert sb.mode == "design" and sb.record() == {}
    sb.set("preset", "ocean")
    sb.set("header_hidden", True)
    sb.set("header_hidden", False)
    assert sb.record() == {"preset": "ocean"}
    assert all(sb.source(f) == bl.OWN for f in bl.LOOK_FIELDS)
    with pytest.raises(bl.LookError):
        sb.set("nope", 1)
    with pytest.raises(bl.LookError):
        bl.Look({"primary": "#1"}).css()               # a malformed value fails closed


# ── the stylesheet: tokens under both names, byte-identical to the config's own ─────
def test_composed_css_emits_every_token_under_its_sd_and_hug_names():
    css = bl.look_css({"preset": "ocean", "style": "sharp", "decor": "arrows",
                       "header_text": "Hello"})
    for name in ("--sd-primary: #1976d2", "--hug-primary: #1976d2",
                 "--sd-radius: 0", "--hug-radius: 0",
                 "--sd-nav-suffix-hover: ' \\2192'", "--hug-nav-suffix-hover: ' \\2192'",
                 "--sd-header-content: 'Hello'", "--hug-header-content: 'Hello'"):
        assert name in css, name


@pytest.mark.parametrize("fields", [
    {},
    {"login_theme_preset": "pride", "login_theme_mode": "light"},
    {"login_primary_color": "#e91e63", "login_secondary_color": "#00bcd4",
     "login_font": "Humanist"},
    {"login_header_hidden": True, "login_footer_size": "tall", "login_footer_bg": "#001122",
     "login_footer_text": "(c) example", "login_bg_effect": "none"},
    {"login_theme_preset": "nord", "login_font": "Monospace", "login_header_size": "compact"},
])
def test_a_look_read_from_a_config_composes_the_configs_own_bytes(fields):
    """The switch-over is safe: for every choice the config can hold today, look_css
    writes exactly what cfg.login_theme_css() writes. Shape, decoration and pictures
    (which the config cannot hold) are omit-when-default, so they add nothing here."""
    cfg = ImageConfig(**fields)
    look = bl.look_from_cfg(cfg)
    assert bl.look_css(look) == cfg.login_theme_css()
    # and the projection back is lossless for the fields the config carries
    other = ImageConfig()
    bl.apply_look_to_cfg(other, look)
    assert other.login_theme_css() == cfg.login_theme_css()
    for field, attr in bl.CFG_FIELDS.items():
        assert getattr(other, attr) == getattr(cfg, attr), field


def test_picture_tokens_ride_the_same_root_block_as_hug_twins():
    pic = picture()
    css = bl.look_css({"logo_image": pic.data_uri()})
    assert f"--sd-logo-image: url({pic.data_uri()});" in css
    assert f"--hug-logo-image: url({pic.data_uri()});" in css
    assert "--sd-login-bg-image" not in css              # nothing chosen, no token
    both = bl.look_css({"logo_image": pic.data_uri(), "login_bg_image": pic.data_uri()})
    assert both.count("url(data:image/png;base64,") == 4   # two tokens, two names each


def test_an_unknown_preset_style_or_effect_fails_closed():
    for bad in ({"preset": "nope"}, {"style": "wobbly"}, {"decor": "glitter"},
                {"bg_effect": "lava"}, {"mode": "noon"}, {"header_size": "huge"},
                {"font": "Comic"}, {"primary": "red"}):
        with pytest.raises(bl.LookError):
            bl.look_css(bad)


# ── D19: the writer's allow-list ─────────────────────────────────────────────────────
def test_css_root_refuses_a_property_outside_the_allow_list():
    for name in ("color", "background", "--x-custom", "--sd-", "--SD-primary",
                 "--sd-primary; color: red", "--sd-primary}"):
        with pytest.raises(ValueError, match="allow"):
            theme.css_root({name: "#000000"})
    # every token the derivation emits today is inside it
    theme.css_root(theme.derive("#112233", "#445566", ["#777777", "#888888"]))
    theme.css_root(theme_presets.compose_tokens("pride", "light"))
    theme.css_root({**theme.style_tokens("glass"), **theme.decor_tokens("uwu"),
                    **theme.chrome_tokens(header_text="x", footer_bg="#123456",
                                          bg_effect="none")})


def test_css_root_refuses_url_except_a_data_picture_on_a_picture_token():
    uri = picture().data_uri()
    ok = theme.css_root({"--sd-logo-image": f"url({uri})"})
    assert f"--hug-logo-image: url({uri});" in ok
    for name, value in (("--sd-logo-image", "url(https://x)"),
                        ("--sd-logo-image", "url(data:text/html;base64,PGI+)"),
                        ("--sd-logo-image", "url(data:image/svg+xml;base64,PHN2Zz4=)"),
                        ("--sd-logo-image", f"url({uri}) , url(https://x)"),
                        ("--sd-logo-image", f"URL({uri})"),
                        ("--sd-bg-gradient", f"url({uri})"),      # not a picture token
                        ("--sd-header-content", "'a' url(https://x) 'b'"),  # outside the strings
                        ("--sd-logo-image", "url(data:image/png;base64,QUJDRA==)")):  # not a PNG
        with pytest.raises(ValueError, match="url"):
            theme.css_root({name: value})
    # INSIDE a string literal the letters u-r-l-( are inert, and header text saying
    # url(https://x) still reaches the page as text (the C-STYLE scenario's case)
    css = theme.css_root(theme.chrome_tokens(header_text="see url(https://x) here"))
    assert "--sd-header-content: 'see url(https://x) here';" in css


def test_css_root_refuses_the_spellings_that_hide_a_url_or_end_a_declaration():
    """The plain 'url(' text is the easy case. Each of these was ACCEPTED by the first
    version of the rule; the escape one made chromium fetch a remote address."""
    uri = picture().data_uri()
    for value in ("/* ' */url(https://evil/x) /* ' */",     # a comment hides the quotes
                  "\\75rl(https://evil/x)",                  # a CSS escape spells url(
                  "u\\72l(https://evil/x)",
                  "red; } .a { background: image-set(\"https://evil/x.png\" 1x) } .b{",
                  "red; } @import \"https://evil/x.css\"; .b{",
                  'image-set("https://evil/x.png" 1x)',
                  'src("https://evil")',
                  "-webkit-image-set('https://evil/x.png' 1x)",
                  "red; color: blue",
                  "red } :root { --y: 1",
                  "'unterminated",
                  "\"unterminated"):
        with pytest.raises(ValueError):
            theme.css_root({"--sd-x": value})
        with pytest.raises(ValueError):
            theme.css_root({"--sd-logo-image": value})
    # the same spellings are INERT inside a string literal, so header text can say them
    css = theme.css_root(theme.chrome_tokens(
        header_text="u\\72l( a; b } @import /* c */ image-set(x)"))
    assert "--sd-header-content: 'u\\\\72l( a; b } @import /* c */ image-set(x)';" in css
    # a name that only ends in a newline is not an allow-listed name
    with pytest.raises(ValueError, match="allow"):
        theme.css_root({"--sd-x\n": "1"})
    # one picture is the whole value of a picture token: nothing rides along
    with pytest.raises(ValueError, match="control"):
        theme.css_root({"--sd-logo-image": f"url({uri})\n"})
    # a data: URL whose label says PNG but whose bytes are not (long enough to get past
    # the shape check, so the byte check is the one that refuses it)
    fake = base64.b64encode(b"this is not a picture at all").decode()
    with pytest.raises(ValueError, match="not that picture"):
        theme.css_root({"--sd-logo-image": f"url(data:image/png;base64,{fake})"})


def test_css_root_refuses_a_raw_control_character_in_a_value():
    with pytest.raises(ValueError, match="control"):
        theme.css_root({"--sd-primary": "#000000\f}"})
    # css_string has already escaped it, so chrome text still passes
    theme.css_root(theme.chrome_tokens(header_text="a\fb}c"))


# ── D6/D19: the budget, the meter and the two ceilings ──────────────────────────────
def test_the_budget_is_the_design_numbers():
    assert bl.LOOK_CSS_BUDGET == 102400
    assert bl.ENV_ENTRY_LIMIT == 131071
    assert bl.ENV_VALUE_LIMIT == 131071 - len("HUG_THEME_CSS=")
    assert bl.CONFIGMAP_LIMIT == 1048576


def test_the_meter_is_the_byte_length_of_the_finished_stylesheet():
    look = {"preset": "ocean"}
    b = bl.budget(look)
    assert b.used == len(bl.look_css(look).encode("utf-8"))
    assert b.limit == bl.LOOK_CSS_BUDGET and b.free == b.limit - b.used
    assert f"{b.used:,}" in b.text() and "102,400" in b.text()
    # an empty look costs nothing (no stylesheet is emitted at all)
    assert bl.budget({}).used == 0


def test_a_picture_costs_its_base64_twice_once_per_token_name():
    pic = picture(16, 16)
    before = bl.budget({"preset": "ocean"}).used
    after = bl.budget({"preset": "ocean", "logo_image": pic.data_uri()}).used
    cost = bl.picture_cost("logo_image", len(pic.data), pic.mime)
    # the two declarations, plus the pictures' own :root block opened once
    assert after - before == cost + len("\n:root:root {\n}\n")
    assert cost >= 2 * (len(pic.data) * 4 // 3)
    # a second picture adds only its own two declarations
    twice = bl.budget({"preset": "ocean", "logo_image": pic.data_uri(),
                       "login_bg_image": pic.data_uri()}).used
    assert twice - after == bl.picture_cost("login_bg_image", len(pic.data), pic.mime)


def test_a_brands_own_colour_wins_over_an_inherited_preset():
    sb = {"preset": "ocean"}
    css = bl.look_css(bl.effective_look(sb, {"primary": "#123456"}))
    assert "--sd-primary: #123456;" in css
    assert "--sd-secondary: #0097a7;" in css             # the preset's, inherited
    # the screens fill the colours from the preset, so a look they wrote composes the
    # config's bytes exactly (the preset's own colours are the typed colours)
    filled = {"preset": "ocean", "primary": "#1976d2", "secondary": "#0097a7"}
    cfg = ImageConfig(login_theme_preset="ocean", login_primary_color="#1976d2",
                      login_secondary_color="#0097a7")
    assert bl.look_css(filled) == cfg.login_theme_css()


def test_a_picture_past_the_budget_is_refused_with_the_numbers():
    big = picture(220, 220, noise=True)                 # ~190 KiB of noise: too big
    look = {"preset": "ocean"}
    ok, why = bl.picture_fits(look, "logo_image", big)
    assert not ok
    used = bl.budget(look).used
    total = bl.budget({**look, "logo_image": big.data_uri()}).used
    for number in (f"{total:,}", "102,400", f"{used:,}", f"{bl.LOOK_CSS_BUDGET - used:,}",
                   f"{len(big.data):,}", "220x220"):
        assert number in why, (number, why)
    assert "bytes" in why
    small = picture(16, 16)
    ok, why = bl.picture_fits(look, "logo_image", small)
    assert ok and why == ""
    # a look that is already past the budget composes nothing
    with pytest.raises(bl.LookBudgetError) as e:
        bl.look_css({"preset": "ocean", "logo_image": big.data_uri()})
    assert e.value.used > e.value.limit == bl.LOOK_CSS_BUDGET
    assert bl.look_css({"preset": "ocean", "logo_image": big.data_uri()},
                       enforce_budget=False)             # the meter can still measure it


def test_replacing_a_picture_frees_its_old_cost_first():
    old = picture(32, 32, noise=True)
    look = {"preset": "ocean", "logo_image": old.data_uri()}
    same = picture(32, 32, noise=True)
    ok, _ = bl.picture_fits(look, "logo_image", same)
    assert ok                                            # the old picture's bytes are freed


def test_the_configmap_is_checked_with_its_numbers_and_no_environment_check_exists():
    """The budget (102,400) sits under the environment entry (131,057 of value), so a
    look inside the budget always starts a container and there is no separate check
    (a refusal that could never fire was removed); the ConfigMap is the carrier that
    can run out."""
    assert not hasattr(bl, "fits_environment")
    assert bl.LOOK_CSS_BUDGET < bl.ENV_VALUE_LIMIT
    css = bl.look_css({"preset": "ocean"})
    ok, why = bl.fits_configmap({"default": css, "shop": css})
    assert ok
    huge = {"default": "x" * 600_000, "shop": "x" * 500_000}
    ok, why = bl.fits_configmap(huge)
    assert not ok and "1,100,000" in why and "1,048,576" in why and "shop" in why


# ── D18: the per-brand stylesheet files the Docker front reads ──────────────────────
def test_write_look_files_lays_out_one_folder_per_brand_with_both_file_names(tmp_path):
    sb = {"preset": "ocean"}
    brands = {"shop": {"primary": "#123456"}, "club": {}}
    written = bl.write_look_files(sb, brands, str(tmp_path))
    rel = sorted(os.path.relpath(p, tmp_path) for p in written)
    assert rel == ["club/hug-theme.css", "club/snap-theme.css",
                   "default/hug-theme.css", "default/snap-theme.css",
                   "shop/hug-theme.css", "shop/snap-theme.css"]
    default = (tmp_path / "default" / "hug-theme.css").read_text()
    assert default == bl.look_css(sb)
    assert (tmp_path / "default" / "snap-theme.css").read_text() == default
    shop = (tmp_path / "shop" / "hug-theme.css").read_text()
    assert "--sd-primary: #123456;" in shop and "--sd-secondary: #0097a7;" in shop
    assert (tmp_path / "club" / "hug-theme.css").read_text() == default
    # idempotent and never leaves a stale brand behind
    bl.write_look_files(sb, {"shop": {}}, str(tmp_path))
    assert not (tmp_path / "club").exists()


def test_write_look_files_refuses_ids_that_are_not_safe_folder_names(tmp_path):
    for bad in ("default", "Shop", "a/b", "..", "", "-x", "x" * 60):
        with pytest.raises(bl.LookError):
            bl.write_look_files({}, {bad: {}}, str(tmp_path))
    assert not os.listdir(tmp_path)                      # nothing half-written


def test_a_brand_whose_own_look_is_past_the_budget_stops_the_write(tmp_path):
    big = picture(220, 220, noise=True)
    with pytest.raises(bl.LookBudgetError):
        bl.write_look_files({}, {"shop": {"logo_image": big.data_uri()}}, str(tmp_path))
    assert not os.listdir(tmp_path)


# ── the model the two faces edit ─────────────────────────────────────────────────────
def test_cfg_look_writes_through_to_the_config_and_keeps_the_rest_for_the_record():
    cfg = ImageConfig(login_primary_color="#111111")
    m = bl.CfgLook(cfg)
    assert m.get("primary") == "#111111" and m.mode == "design"
    m.set("primary", "#222222")
    assert cfg.login_primary_color == "#222222"
    m.set("style", "sharp")                               # the config has no field for it
    assert m.get("style") == "sharp"
    assert m.record() == {"primary": "#222222", "style": "sharp"}
    assert "--sd-radius: 0;" in m.css()


def test_the_picture_uri_in_a_record_must_be_one_the_re_encoder_made():
    for bad in ("https://x/logo.png", "data:image/svg+xml;base64,PHN2Zz4=",
                "data:image/png;base64,QUJDRA==", "url(data:image/png;base64,AA==)"):
        with pytest.raises(bl.LookError):
            bl.look_css({"logo_image": bad})
    assert bl.look_css({"logo_image": picture().data_uri()})
    assert base64.b64decode(picture().data_uri().split(",", 1)[1])[:8] == PNG_SIG


def test_write_look_files_removes_a_dropped_brands_folder_but_not_a_folder_it_did_not_write(
        tmp_path):
    bl.write_look_files({}, {"shop": {}, "gone": {}}, str(tmp_path))
    (tmp_path / "unrelated").mkdir()
    (tmp_path / "unrelated" / "keep.txt").write_text("mine")
    (tmp_path / "gone" / "notes.txt").write_text("not a look file")
    (tmp_path / "shop2").mkdir()
    bl.write_look_files({}, {"shop": {}}, str(tmp_path))
    assert (tmp_path / "unrelated" / "keep.txt").read_text() == "mine"
    assert (tmp_path / "gone" / "notes.txt").exists(), "a folder with other files stays"
    assert not (tmp_path / "shop2").exists(), "an empty stale folder is a look folder"
    bl.write_look_files({}, {"shop": {}}, str(tmp_path / "fresh"))
    (tmp_path / "fresh" / "dropped").mkdir()
    (tmp_path / "fresh" / "dropped" / "hug-theme.css").write_text("x")
    bl.write_look_files({}, {"shop": {}}, str(tmp_path / "fresh"))
    assert not (tmp_path / "fresh" / "dropped").exists()
