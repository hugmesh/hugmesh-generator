"""Holes the skeptics found in the look pipeline, each closed by a test that fails
when its guard is removed (hugmesh-generator#654, D6, D7, D19).

Qt-free. The mutations these were written against are named in each docstring so a
later reader can repeat them: take the guard out, and the test must go red.
"""
import base64
import struct
import zlib

import pytest

from hugmesh_studio.core import brand_images as bi
from hugmesh_studio.core import brand_look as bl
from hugmesh_studio.core import theme

from test_brand_images import _chunk, PNG_SIG
from test_look_model import png_bytes


# ── a clean picture is judged by its structure, not by this host's zlib ──────────────
def _recompress(png: bytes, level: int, *, idat_pieces: int = 1) -> bytes:
    """The same pixels as ``png`` with the IDAT stream compressed at another level (what
    a different zlib build, or another tool, would have written): still a clean PNG."""
    ihdr = bi.png_raw_scanlines(png)
    chunks = list(bi._png_chunks(png))
    raw = ihdr
    comp = zlib.compress(raw, level)
    out = PNG_SIG + _chunk(b"IHDR", chunks[0][1])
    step = max(1, len(comp) // idat_pieces)
    for i in range(0, len(comp), step):
        out += _chunk(b"IDAT", comp[i:i + step])
    return out + _chunk(b"IEND", b"")


def _uri(png: bytes) -> str:
    return "data:image/png;base64," + base64.b64encode(png).decode()


@pytest.mark.parametrize("level", [0, 1, 6])
def test_a_clean_png_made_by_another_compressor_is_accepted(level):
    """Mutation: compare bytes with a fresh re-encode (the first round's check). The
    re-encoder compresses at level 9, so any other level made the picture 'dirty' and one
    such picture made the whole stylesheet raise."""
    own = bi.reencode(png_bytes(16, 16, noise=True), "logo").data
    other = _recompress(own, level)
    assert other != own, "the fixture must differ from the re-encoder's bytes"
    assert bi.png_raw_scanlines(other) == bi.png_raw_scanlines(own)
    assert bi.leftovers(other, "logo") == ()
    assert bl.check_value("logo_image", _uri(other)) == ""
    css = bl.look_css({"logo_image": _uri(other)})
    assert "--hug-logo-image" in css
    assert bl.Look().try_set("logo_image", _uri(other)).ok


def test_a_png_in_several_idat_chunks_or_with_extras_is_still_called_unclean():
    own = bi.reencode(png_bytes(16, 16, noise=True), "logo").data
    pieces = _recompress(own, 9, idat_pieces=3)
    assert bi.png_chunk_types(pieces).count("IDAT") > 1
    assert "repeated or misplaced" in " ".join(bi.leftovers(pieces, "logo"))
    assert "re-encoder" in bl.check_value("logo_image", _uri(pieces))
    # a metadata chunk and bytes after IEND are named, so the sentence says what is left
    dirty = own[:-12] + _chunk(b"tEXt", b"k\x00v") + own[-12:] + b"tail"
    left = bi.leftovers(dirty, "logo")
    assert "tEXt" in left and "trailing data" in left
    # IDAT before IHDR-adjacent PLTE order is irrelevant for colour type 6, but a PLTE
    # after IDAT would be misplaced
    ihdr = bi._png_chunks(own).__next__()[1]
    idat = [p for k, p in bi._png_chunks(own) if k == b"IDAT"][0]
    misplaced = (PNG_SIG + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", idat)
                 + _chunk(b"PLTE", b"\0\0\0") + _chunk(b"IEND", b""))
    assert "repeated or misplaced" in " ".join(bi.leftovers(misplaced, "logo"))


def test_a_jpeg_stays_judged_by_its_bytes():
    from test_brand_images import JPEG_BASELINE_EXIF
    own = bi.reencode(JPEG_BASELINE_EXIF, "logo")
    assert bi.leftovers(own.data, "logo") == ()
    assert bi.leftovers(JPEG_BASELINE_EXIF, "logo") != ()
    assert "APP1" in bi.leftovers(JPEG_BASELINE_EXIF, "logo")


# ── the size is bounded BEFORE anything is inflated ──────────────────────────────────
def test_a_header_that_declares_a_huge_picture_is_refused_before_inflating(monkeypatch):
    """Mutation: remove the 'nothing larger than' check before inflation. Then a 2.6 MB
    file declaring 30000x30000 asks the inflater for gigabytes (MemoryError under a 3 GiB
    limit). The inflater is replaced by one that fails the test if it is ever reached."""
    def never(*_a, **_k):
        raise AssertionError("the PNG was inflated before its declared size was checked")
    monkeypatch.setattr(bi, "_inflate_exactly", never)
    ihdr = struct.pack(">IIBBBBB", 30000, 30000, 8, 6, 0, 0, 0)
    bomb = (PNG_SIG + _chunk(b"IHDR", ihdr)
            + _chunk(b"IDAT", zlib.compress(bytes(4096), 9)) + _chunk(b"IEND", b""))
    for kind in ("logo", "background"):
        with pytest.raises(bi.PictureRefused, match="nothing larger than 1280x720"):
            bi.reencode(bomb, kind)
    # one side over is enough
    tall = struct.pack(">IIBBBBB", 10, 30000, 8, 6, 0, 0, 0)
    with pytest.raises(bi.PictureRefused, match="30000"):
        bi.reencode(PNG_SIG + _chunk(b"IHDR", tall) + _chunk(b"IDAT", b"x")
                    + _chunk(b"IEND", b""), "logo")


# ── an uploaded font keeps its licence and source in override mode ───────────────────
SUPER = {"font_file": "/usr/share/fonts/super.ttf", "font_licence": "SIL OFL 1.1",
         "font_source": "foundry A"}


def test_a_brands_own_font_file_may_not_borrow_the_superbrands_licence(tmp_path):
    """Mutation: judge the licence and source from the effective look only. A brand that
    picks its own font file then inherits the superbrand's licence for a different file
    and requirements() comes back empty."""
    font = tmp_path / "Own.ttf"
    font.write_bytes(b"\x00\x01\x00\x00" + bytes(200))
    m = bl.Look({}, base=SUPER)
    assert m.requirements() == []                       # the inherited font is attributed
    m.set("font_file", str(font))
    needs = m.requirements()
    assert len(needs) == 2, needs
    assert "licence" in needs[0] and "came from" in needs[1]
    assert all("superbrand's" in n for n in needs)
    m.set("font_licence", "SIL OFL 1.1")
    assert len(m.requirements()) == 1                   # the source is still borrowed
    m.set("font_source", "foundry B")
    assert m.requirements() == []
    # the module function agrees when told which fields are the brand's own
    assert len(bl.requirements(bl.effective_look(SUPER, {"font_file": "x.ttf"}),
                               own={"font_file"})) == 2
    # design mode (no superbrand) is unchanged: everything is its own
    d = bl.Look({"font_file": "x.ttf"})
    assert len(d.requirements()) == 2


# ── refusals leave the record exactly as it was ──────────────────────────────────────
def test_a_look_over_the_budget_is_refused_naming_both_numbers_and_changes_nothing():
    """Mutation: remove the budget refusal in try_set (the text is kept, so the record
    grows past the cap)."""
    m = bl.Look({"header_text": "Hello"})
    m.others = {}
    before = dict(m.own)
    out = m.try_set("header_text", "x" * (bl.LOOK_CSS_BUDGET + 10))
    assert not out.ok
    assert f"{bl.LOOK_CSS_BUDGET:,}" in out.text and "bytes" in out.text, out.text
    assert m.own == before
    assert m.budget().fits


def test_a_font_that_cannot_be_read_leaves_the_record_as_it_was():
    """Mutation: skip the restore after a LookError in try_set."""
    m = bl.Look({"primary": "#336699"})
    before = dict(m.own)
    out = m.try_set("font_file", "/nonexistent/font.ttf")
    assert not out.ok and "font_file" in out.text, out.text
    assert m.own == before
    # and in override mode the field goes back to being the superbrand's
    o = bl.Look({}, base=SUPER)
    out = o.try_set("font_file", "/nonexistent/font.ttf")
    assert not out.ok and o.own == {} and o.source("font_file") == bl.SUPERBRAND


def test_the_meter_says_too_many_with_a_positive_count_when_over():
    """Mutation: flip the sign of the 'too many' count."""
    over = bl.Budget(used=bl.LOOK_CSS_BUDGET + 1234)
    assert not over.fits
    assert over.text() == (f"{bl.LOOK_CSS_BUDGET + 1234:,} of {bl.LOOK_CSS_BUDGET:,} "
                           "bytes used (1,234 too many)")
    under = bl.Budget(used=100)
    assert under.text().endswith(f"({bl.LOOK_CSS_BUDGET - 100:,} free)")


# ── the board's verdict is measured, not asserted ────────────────────────────────────
def test_the_board_verdict_follows_the_measured_ratio_at_4_5(monkeypatch):
    """Mutation: change the 4.5 threshold. The derivation keeps every colour a person can
    type above AA (a scan of 7^3 colours in all eight modes found none below), so the
    'below' branch is reached by feeding the verdict a measured ratio at the boundary."""
    eff = bl.effective_look({})
    assert bl.board(eff).contrast.endswith("all clear AA (4.5:1).")
    real = theme.contrast_ratio
    for ratio, verdict in ((4.5, "all clear AA (4.5:1)."), (4.49, "BELOW AA — check the colours."),
                           (1.0, "BELOW AA — check the colours."), (21.0, "all clear AA (4.5:1).")):
        monkeypatch.setattr(theme, "contrast_ratio", lambda *_a, _r=ratio: _r)
        text = bl.board(eff).contrast
        assert text.endswith(verdict), (ratio, text)
        assert f"{ratio:.1f}:1" in text, text
    # one of the three measured pairs failing is enough, whichever it is
    tokens = bl._board_tokens(eff)
    pairs = {"text": (tokens["--sd-text"], tokens["--sd-bg-0"]),
             "accent": (tokens["--sd-accent-soft"], tokens["--sd-bg-0"]),
             "button": (tokens["--sd-primary-on"], tokens["--sd-primary"])}
    for name, bad in pairs.items():
        monkeypatch.setattr(theme, "contrast_ratio",
                            lambda a, b, _bad=bad: 3.0 if (a, b) == _bad else real(a, b))
        assert bl.board(eff).contrast.endswith("BELOW AA — check the colours."), name
    monkeypatch.setattr(theme, "contrast_ratio", real)
    assert bl.board(eff).contrast.endswith("all clear AA (4.5:1).")


def test_a_picture_that_was_refused_does_not_change_the_budget(tmp_path):
    m = bl.Look()
    used = m.budget().used
    bad = tmp_path / "x.png"
    bad.write_bytes(b"not a picture")
    out = m.load_picture("logo_image", str(bad))
    assert not out.ok and out.text.startswith("Refused:")
    assert m.budget().used == used and m.get("logo_image") == ""
