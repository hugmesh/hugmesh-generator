"""The checked verbs both faces edit a look through, and the files that carry them
(hugmesh-generator#654: D6 pictures and the meter, D7 inherit and override, D19 the
ceilings). Qt-free: the window and the text screen are thin over these.

Every refusal is asserted by the sentence a person reads, because both faces show the
same one. Where a number is in the sentence the test computes it independently.
"""
import base64
import os
import re
import struct
import zlib

import pytest

from hugmesh_studio.core import brand_images as bi
from hugmesh_studio.core import brand_look as bl
from hugmesh_studio.core import theme

from test_look_model import png_bytes

SVG_BYTES = (b'<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg">'
             b'<script>x()</script></svg>')


def _write(tmp_path, name, data):
    p = tmp_path / name
    p.write_bytes(data)
    return str(p)


# ── pictures: re-encoded, refused with a reason, measured against the meter ─────────
def test_a_png_upload_is_accepted_and_the_meter_moves(tmp_path):
    m = bl.Look()
    before = m.budget().used
    out = m.load_picture("logo_image", _write(tmp_path, "logo.png", png_bytes(32, 32)))
    assert out.ok and out.text.startswith("Accepted: 32x32 PNG,")
    assert m.budget().used > before
    assert m.get("logo_image").startswith("data:image/png;base64,")
    css = m.css()
    assert "--sd-logo-image: url(data:image/png;base64," in css
    assert "--hug-logo-image: url(data:image/png;base64," in css


def test_an_svg_is_refused_with_the_reason_and_the_record_keeps_its_picture(tmp_path):
    m = bl.Look()
    assert m.load_picture("logo_image", _write(tmp_path, "a.png", png_bytes(8, 8))).ok
    kept = m.get("logo_image")
    out = m.load_picture("logo_image", _write(tmp_path, "logo.svg", SVG_BYTES))
    assert not out.ok
    assert out.text.startswith("Refused: SVG is not accepted")
    assert "PNG or JPEG" in out.text
    assert m.get("logo_image") == kept


def test_a_picture_that_would_not_fit_is_refused_with_the_numbers(tmp_path):
    m = bl.Look({"preset": "ocean"})
    path = _write(tmp_path, "big.png", png_bytes(220, 220, noise=True))
    used = m.budget().used
    out = m.load_picture("logo_image", path)
    assert not out.ok and out.text.startswith("Refused: This picture does not fit.")
    for number in ("102,400", f"{used:,}", f"{bl.LOOK_CSS_BUDGET - used:,}", "220x220"):
        assert number in out.text, (number, out.text)
    assert m.get("logo_image") == ""
    assert m.budget().used == used


def test_a_picture_over_the_size_limit_is_refused_with_both_sizes(tmp_path):
    m = bl.Look()
    out = m.load_picture("logo_image", _write(tmp_path, "wide.png", png_bytes(300, 20)))
    assert not out.ok and "at most 256x256" in out.text and "300x20" in out.text


def test_an_unreadable_path_and_an_empty_path(tmp_path):
    m = bl.Look()
    out = m.load_picture("logo_image", str(tmp_path / "missing.png"))
    assert not out.ok and out.text.startswith("Cannot read this file")
    assert m.load_picture("logo_image", _write(tmp_path, "a.png", png_bytes(8, 8))).ok
    assert m.load_picture("logo_image", "").ok and m.get("logo_image") == ""


def test_the_configmap_ceiling_is_wired_into_the_upload(tmp_path):
    """The other looks already fill all but 276 bytes of the ConfigMap; this one's
    picture tips it over, and the sentence carries the ceiling."""
    m = bl.Look()
    m.others = {"brand0": "x" * (bl.CONFIGMAP_LIMIT - 276)}
    out = m.load_picture("logo_image", _write(tmp_path, "a.png", png_bytes(32, 32)))
    assert not out.ok
    assert "1,048,576" in out.text and "a ConfigMap holds at most" in out.text
    m.others = {"brand0": "x" * 100_000}
    assert m.load_picture("logo_image", _write(tmp_path, "b.png", png_bytes(32, 32))).ok


def test_a_longer_text_that_breaks_a_ceiling_is_refused_by_the_same_gate():
    m = bl.Look()
    m.others = {"brand0": "x" * (bl.CONFIGMAP_LIMIT - 276)}
    out = m.try_set("header_text", "h" * 600)
    assert not out.ok and "ConfigMap" in out.text
    assert m.get("header_text") == ""


# ── fonts ────────────────────────────────────────────────────────────────────────────
def test_a_font_that_is_not_a_font_is_refused_and_a_missing_one_is_unreadable(tmp_path):
    m = bl.Look()
    out = m.load_font(_write(tmp_path, "x.woff2", b"not a font at all"))
    assert not out.ok and out.text.startswith("REJECTED: ")
    assert m.get("font_file") == ""
    assert m.load_font(str(tmp_path / "nope.ttf")).text.startswith("cannot read")


def test_an_uploaded_font_needs_its_licence_and_source_and_both_faces_say_so(tmp_path):
    m = bl.Look()
    assert bl.requirements(m.effective()) == []
    m.set("font_file", str(tmp_path / "f.woff2"))
    needs = bl.requirements(m.effective())
    assert len(needs) == 2 and "licence" in needs[0] and "came from" in needs[1]
    m.set("font_licence", "SIL OFL 1.1")
    m.set("font_source", "example foundry")
    assert bl.requirements(m.effective()) == []
    m.set("font_source", "bad\x07source")
    assert len(bl.requirements(m.effective())) == 1


# ── the checked verbs ────────────────────────────────────────────────────────────────
def test_try_set_refuses_what_check_value_refuses_and_changes_nothing():
    m = bl.Look({"style": "sharp"})
    for field, value in (("primary", "blue"), ("style", "wobbly"), ("decor", "glitter"),
                         ("header_size", "huge"), ("font", "Comic"), ("mode", "noon"),
                         ("preset", "nope"), ("bg_effect", "lava"),
                         ("bg_effect", "vanta-net"), ("logo_image", "url(https://x)")):
        out = m.try_set(field, value)
        assert not out.ok and out.text, (field, value)
    assert m.record() == {"style": "sharp"}
    assert m.try_set("bg_effect", "none").ok


def test_a_picture_field_takes_only_the_re_encoders_data_uri():
    m = bl.Look()
    out = m.try_set("login_bg_image", "data:image/svg+xml;base64,PHN2Zz4=")
    assert not out.ok and "re-encoder" in out.text
    assert m.get("login_bg_image") == ""


def _dirty(uri: str) -> str:
    """The re-encoder's own picture with a metadata chunk before IEND and a script after
    it: bytes the re-encoder accepts on upload (and would clean) but did not make."""
    raw = base64.b64decode(uri.split(",", 1)[1])
    body, iend = raw[:-12], raw[-12:]
    text = b"Comment\x00gps 51.5N 0.1W"
    chunk = (struct.pack(">I", len(text)) + b"tEXt" + text
             + struct.pack(">I", zlib.crc32(b"tEXt" + text) & 0xFFFFFFFF))
    dirty = body + chunk + iend + b"<script>alert(1)</script>"
    return "data:image/png;base64," + base64.b64encode(dirty).decode()


def test_a_record_holds_only_pictures_the_re_encoder_made():
    clean = bi.reencode(png_bytes(8, 8), "logo").data_uri()
    assert bl.check_value("logo_image", clean) == ""
    m = bl.Look()
    assert m.try_set("logo_image", clean).ok
    dirty = _dirty(clean)
    # the re-encoder ACCEPTS these bytes (it would clean them), so "would it accept" is
    # not the test; "is it exactly what it makes" is
    assert bi.reencode(base64.b64decode(dirty.split(",", 1)[1]), "logo")
    why = bl.check_value("logo_image", dirty)
    assert "not made by the Studio's re-encoder" in why and "tEXt" in why, why
    m2 = bl.Look()
    out = m2.try_set("logo_image", dirty)
    assert not out.ok and "re-encoder" in out.text and m2.get("logo_image") == ""
    # a record built by hand (an imported brand) cannot ship the bytes either
    with pytest.raises(bl.LookError, match="re-encoder"):
        bl.look_css({"logo_image": dirty})
    # and the upload path still cleans the same file into something the record takes
    assert m2.try_set("logo_image", bi.reencode(
        base64.b64decode(dirty.split(",", 1)[1]), "logo").data_uri()).ok


def test_the_record_in_design_mode_is_what_differs_and_in_override_mode_is_the_overrides():
    sb = bl.Look()
    sb.choose_preset("forest")
    sb.try_set("style", "sharp")
    rec = sb.record()
    assert rec["preset"] == "forest" and rec["style"] == "sharp" and "decor" not in rec
    brand = bl.Look(base=sb.effective())
    assert brand.record() == {}
    brand.try_set("style", "glass")
    brand.try_set("decor", "arrows")
    assert brand.record() == {"style": "glass", "decor": "arrows"}
    assert brand.source("style") == bl.OWN and brand.source("primary") == bl.SUPERBRAND
    assert brand.get("primary") == sb.get("primary")           # inherited, not copied


def test_use_the_superbrands_value_arms_on_the_first_click_and_applies_on_the_second():
    sb = bl.Look({"style": "sharp"})
    brand = bl.Look({"style": "glass", "decor": "arrows"}, base=sb.effective())
    assert brand.click_use_superbrand("style") == "armed"
    assert brand.armed == "style" and brand.get("style") == "glass"
    assert brand.click_use_superbrand("style") == "applied"
    assert brand.armed is None and brand.get("style") == "sharp"
    assert brand.record() == {"decor": "arrows"}               # only the other override left
    # arming one field and clicking another re-arms; any edit disarms
    assert brand.click_use_superbrand("decor") == "armed"
    assert brand.click_use_superbrand("style") == "armed"
    assert brand.try_set("primary", "#123456").ok and brand.armed is None
    assert bl.Look().click_use_superbrand("style") == ""        # design mode: nothing above


def test_an_override_changes_that_brand_only():
    sb = bl.Look({"style": "sharp"})
    a = bl.Look(base=sb.effective())
    b = bl.Look(base=sb.effective())
    a.try_set("style", "glass")
    assert a.get("style") == "glass" and b.get("style") == "sharp"
    sb.try_set("style", "flat")                                 # the superbrand moves on
    assert bl.Look({"style": "glass"}, base=sb.effective()).get("style") == "glass"
    assert b.get("style") == "sharp"          # a snapshot base; hosts rebuild on change


# ── the preview page ─────────────────────────────────────────────────────────────────
def test_the_preview_page_draws_the_pictures_from_the_tokens_it_ships(tmp_path):
    m = bl.Look({"preset": "ocean"})
    assert m.load_picture("logo_image", _write(tmp_path, "a.png", png_bytes(16, 16))).ok
    page = bl.preview_html(m.css())
    assert "var(--hug-logo-image)" in page and "look-pictures" in page
    assert m.get("logo_image") in page                          # the data: URI, delivered
    assert "look-pictures" not in bl.preview_html(bl.look_css({"preset": "ocean"}))
    path = bl.write_look_preview(m.css(), str(tmp_path / "out"))
    assert os.path.basename(path) == "hugmesh-platform-preview.html"
    assert os.path.getsize(path) > 10_000


# ── the board ────────────────────────────────────────────────────────────────────────
def test_the_board_carries_measured_contrast_and_the_flag_stripes():
    data = bl.board(bl.effective_look({"preset": "ocean"}))
    assert len(data.rows) == 2 and all(len(r) == 5 for r in data.rows)
    assert re.search(r"Measured contrast on #[0-9a-f]{6}: text [\d.]+:1", data.contrast)
    assert data.contrast.endswith(("all clear AA (4.5:1).", "BELOW AA — check the colours."))
    pride = bl.board(bl.effective_look({"preset": "pride"}))
    assert len(pride.stripes) >= 3
    assert bl.board(bl.effective_look({})).problem == ""


# ── the new files carry no modal and no raw property ─────────────────────────────────
HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.join(os.path.dirname(HERE), "hugmesh_studio")
NEW_FILES = (os.path.join(PKG, "core", "brand_images.py"),
             os.path.join(PKG, "core", "brand_look.py"),
             os.path.join(PKG, "gui", "pages", "_lookeditor.py"))


@pytest.mark.parametrize("path", NEW_FILES, ids=os.path.basename)
def test_no_modal_dialog_in_the_new_files(path):
    """No QMessageBox and no exec( in page logic: a nested event loop hangs a headless
    test and an inline sentence is what both faces show (feedback_no_modals)."""
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    code = "\n".join(re.sub(r"#.*", "", ln) for ln in src.splitlines())
    assert "QMessageBox" not in code
    assert not re.search(r"\.exec_?\(", code), "a nested event loop in page logic"
    assert not re.search(r"\bexec\(", code)


def test_the_pick_a_colour_dialog_is_the_one_exception_and_it_is_not_a_prompt():
    """The colour chooser is a picker the person opens by pressing Pick…, not a question
    page logic asks mid-edit; it is the only dialog the editor opens (and its static
    getColor form runs no exec( in our code)."""
    with open(NEW_FILES[2], encoding="utf-8") as fh:
        src = fh.read()
    assert src.count("QColorDialog") == 1


def test_the_budget_sits_inside_the_environment_entry_and_the_configmap():
    assert bl.LOOK_CSS_BUDGET == 102400
    assert bl.LOOK_CSS_BUDGET <= bl.ENV_VALUE_LIMIT < bl.ENV_ENTRY_LIMIT
    assert 10 * bl.LOOK_CSS_BUDGET <= bl.CONFIGMAP_LIMIT        # ten brands at the cap fit
    assert bl.LOOK_CSS_BUDGET == 100 * 1024


def test_a_whole_look_at_its_limits_composes_within_the_cap():
    """Both pictures, a preset, a font style, a shape, a decoration and long header and
    footer text — the biggest look the screens allow short of an uploaded font."""
    m = bl.Look()
    assert m.choose_preset("pride").ok
    for field, value in (("font", "Humanist"), ("style", "glass"), ("decor", "sparkle"),
                         ("header_text", "h" * 400), ("footer_text", "f" * 400),
                         ("bg_effect", "none")):
        assert m.try_set(field, value).ok
    css = m.css()
    assert len(css.encode("utf-8")) <= 102400
    assert theme.css_root({"--sd-primary": "#112233"})   # the writer still takes plain tokens


# ── D7: a brand's field stays the superbrand's until the person CHANGES it ──────────
def test_setting_a_field_to_the_value_it_already_shows_does_not_make_it_the_brands_own():
    sb = bl.Look({"primary": "#336699", "secondary": "#993366", "header_text": "Hello",
                  "style": "sharp"})
    brand = bl.Look(base=sb.effective())
    for field, value in (("primary", "#336699"), ("secondary", "#993366"),
                         ("header_text", "Hello"), ("style", "sharp"),
                         ("font_licence", ""), ("color_scheme", ""), ("header_hidden", False)):
        assert brand.try_set(field, value).ok
    assert brand.own == {} and brand.record() == {}
    assert brand.source("primary") == bl.SUPERBRAND
    # a different value is a real override, and the same value typed over an OWN one
    # leaves it own
    assert brand.try_set("primary", "#112233").ok and brand.own == {"primary": "#112233"}
    assert brand.try_set("primary", "#112233").ok and brand.own == {"primary": "#112233"}


def test_an_emptied_colour_in_override_mode_means_the_superbrands_not_an_empty_own_value():
    sb = bl.Look({"primary": "#336699"})
    brand = bl.Look({"primary": "#112233"}, base=sb.effective())
    out = brand.try_set("primary", "")
    assert out.ok
    assert brand.source("primary") == bl.SUPERBRAND and brand.get("primary") == "#336699"
    assert brand.own == {}
    # nothing own to drop: still the superbrand's
    assert brand.try_set("primary", "").ok and brand.get("primary") == "#336699"
    # in DESIGN mode an empty colour is simply empty (the shipped colour)
    assert sb.try_set("primary", "").ok and sb.get("primary") == ""


def test_an_override_can_say_no_picture_and_no_text_over_an_inherited_one():
    clean = bi.reencode(png_bytes(8, 8), "logo").data_uri()
    sb = bl.Look({"logo_image": clean, "header_text": "Hello"})
    brand = bl.Look(base=sb.effective())
    assert brand.try_set("logo_image", "").ok and brand.try_set("header_text", "").ok
    assert brand.own == {"logo_image": "", "header_text": ""}
    assert brand.get("logo_image") == "" and brand.get("header_text") == ""
    assert brand.source("logo_image") == bl.OWN
