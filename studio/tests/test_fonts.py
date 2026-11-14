"""core/fonts.py — presets, upload gates, @font-face emission.

Pins: (1) "Classic (current)" is byte-identical to login-ui _tokens.scss $font-sans so
picking it changes nothing; (2) the magic-byte gate rejects renamed junk (the real
attack shape we measured: text renamed .bin, urandom renamed .woff2) and accepts all
four real formats; (3) size is a WARNING not a block (#387); (4) emission cannot be
reached with bytes the gate would reject; (5) --sd-font-mono is a real monospace stack,
never the proportional pick (the _tokens.scss stub reproduced would be a bug).
"""
import base64

import pytest

from hugmesh_studio.core import fonts

_WOFF2 = b"wOF2" + b"\x00" * 60
_WOFF = b"wOFF" + b"\x00" * 60
_TTF = b"\x00\x01\x00\x00" + b"\x00" * 60
_OTF = b"OTTO" + b"\x00" * 60


def test_classic_preset_is_byte_identical_to_the_shipped_scss_stub():
    assert fonts.FONT_PRESETS["Classic (current)"] == "Arial, Helvetica, sans-serif"


def test_bootstrap_preset_is_the_real_bootstrap5_stack_not_an_invented_list():
    stack = fonts.FONT_PRESETS["Bootstrap native stack"]
    for probe in ("system-ui", '"Segoe UI"', "Roboto", '"Noto Color Emoji"'):
        assert probe in stack
    # Bootstrap ships no fonts — a URL in a "font stack" would mean someone snuck a
    # CDN in; the shipped CSP (font-src 'self' data:) would block it at runtime.
    assert "http" not in stack and "url(" not in stack


def test_all_presets_are_nonempty_and_csp_safe():
    assert len(fonts.FONT_PRESETS) == 7
    for name, stack in fonts.FONT_PRESETS.items():
        assert stack.strip(), name
        assert "http" not in stack and "url(" not in stack, name


@pytest.mark.parametrize("data,fmt", [
    (_WOFF2, "woff2"), (_WOFF, "woff"), (_TTF, "truetype"), (_OTF, "opentype")])
def test_sniff_recognises_all_four_real_formats(data, fmt):
    assert fonts.sniff_format(data) == fmt


@pytest.mark.parametrize("junk", [b"", b"hello i am not a font", b"\x7fELF junk",
                                  b"wOF3 close but wrong", b"OTT",
                                  b"\x89PNG\r\n\x1a\n"])
def test_sniff_rejects_junk(junk):
    assert fonts.sniff_format(junk) == ""


def test_check_font_blocks_renamed_junk_and_wrong_extensions():
    blocks, _ = fonts.check_font("notes.woff2", b"just some text saved as .woff2")
    assert any("magic bytes" in b for b in blocks)
    blocks, _ = fonts.check_font("font.zip", _WOFF2)
    assert any("extension" in b for b in blocks)
    blocks, _ = fonts.check_font("empty.ttf", b"")
    assert any("empty" in b for b in blocks)
    assert fonts.check_font("brand.woff2", _WOFF2) == ([], [])


def test_oversize_font_warns_but_does_not_block():
    big = b"wOF2" + b"\x00" * fonts.MAX_FONT_BYTES
    blocks, warns = fonts.check_font("big.woff2", big)
    assert blocks == []
    assert warns and "still" in warns[0] and "KB" in warns[0]


def test_font_face_css_embeds_the_exact_bytes_as_a_data_uri():
    css = fonts.font_face_css("Brand Face", _WOFF2)
    assert css.startswith("@font-face {")
    assert 'font-family: "Brand Face";' in css
    assert 'format("woff2")' in css and "data:font/woff2;base64," in css
    b64 = css.split("base64,", 1)[1].split(")", 1)[0]
    assert base64.b64decode(b64) == _WOFF2   # byte round-trip, not just presence


def test_font_face_css_strips_injection_from_family_names():
    """The family name is NOT operator-typed: it is read out of the font FILE's name
    table, so it is attacker-controlled text (see test_font_family_injection.py for the
    full pin). This USED to blacklist backslash and double-quote only, which let the
    css declaration/block characters straight through — it now allowlists, so the
    punctuation is gone and only the word characters survive."""
    css = fonts.font_face_css('Evil"; } body { display:none', _TTF)
    line = css.split("\n")[1]
    assert '"; }' not in line
    assert "Evil body displaynone" in line   # words survive, structure does not
    for ch in ('"', ";", "{", "}", ":"):
        assert ch not in line.split("font-family:", 1)[1].strip(' ";')
    assert css.count('"') % 2 == 0


def test_font_face_css_refuses_ungated_bytes():
    with pytest.raises(ValueError):
        fonts.font_face_css("X", b"not a font at all")


def test_font_tokens_uploaded_family_leads_with_preset_fallback_behind_it():
    t = fonts.font_tokens(fonts.FONT_PRESETS["System UI"], uploaded_family="Brand Face")
    assert t["--sd-font-sans"].startswith('"Brand Face", system-ui')
    assert t["--sd-font-fancy"] == t["--sd-font-sans"]


def test_font_tokens_mono_is_always_a_real_monospace_stack():
    t = fonts.font_tokens(fonts.FONT_PRESETS["Humanist"])
    assert "monospace" in t["--sd-font-mono"]
    assert t["--sd-font-mono"] == fonts.MONO_STACK


def test_font_tokens_blank_stack_falls_back_to_classic_byte_identical():
    t = fonts.font_tokens("")
    assert t["--sd-font-sans"] == "Arial, Helvetica, sans-serif"
