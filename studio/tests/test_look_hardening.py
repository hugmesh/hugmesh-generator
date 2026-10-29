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


# ── round 2 findings ─────────────────────────────────────────────────────────────────
# L1: the budget's edge. The mutations these were written against: `used > LOOK_CSS_BUDGET`
# to `>=`, and `total <= LOOK_CSS_BUDGET` to `<`, each survived every other test.
def _pad_look(monkeypatch, size):
    """Make the stylesheet for an otherwise empty look exactly ``size`` bytes."""
    monkeypatch.setattr(theme, "compose_login_css", lambda *a, **k: "x" * size)


def test_a_stylesheet_of_exactly_the_budget_is_accepted_and_one_byte_more_is_refused(monkeypatch):
    _pad_look(monkeypatch, bl.LOOK_CSS_BUDGET)
    assert len(bl.look_css({}).encode()) == 102400
    assert bl.budget({}).fits and bl.budget({}).free == 0
    _pad_look(monkeypatch, bl.LOOK_CSS_BUDGET + 1)
    with pytest.raises(bl.LookBudgetError, match="102,401"):
        bl.look_css({})
    assert not bl.budget({}).fits and bl.budget({}).free == -1


def test_a_picture_that_makes_the_sheet_exactly_the_budget_fits_and_one_more_byte_does_not(
        monkeypatch):
    pic = bi.reencode(png_bytes(16, 16, noise=True), "logo")
    _pad_look(monkeypatch, 0)
    with_pic_only = len(bl.look_css({"logo_image": pic.data_uri()},
                                    enforce_budget=False).encode())
    room = bl.LOOK_CSS_BUDGET - with_pic_only - 1          # one byte of newline joins them
    _pad_look(monkeypatch, room)
    ok, why = bl.picture_fits({}, "logo_image", pic)
    assert ok, why
    assert len(bl.look_css({"logo_image": pic.data_uri()}).encode()) == bl.LOOK_CSS_BUDGET
    _pad_look(monkeypatch, room + 1)
    ok, why = bl.picture_fits({}, "logo_image", pic)
    assert not ok and "102,401" in why


def test_an_edit_that_makes_the_sheet_exactly_the_budget_is_taken_and_one_byte_more_is_refused(
        monkeypatch):
    """The checked edit path (Look.try_set) has its own edge, apart from look_css's."""
    probe = bl.Look()
    assert probe.try_set("primary", "#123456").ok
    exact = len(probe.css().encode())
    monkeypatch.setattr(bl, "LOOK_CSS_BUDGET", exact)
    assert bl.Look().try_set("primary", "#123456").ok
    monkeypatch.setattr(bl, "LOOK_CSS_BUDGET", exact - 1)
    refused = bl.Look().try_set("primary", "#123456")
    assert not refused.ok and f"{exact:,}" in refused.text


# L2: a data: URI that says png over JPEG bytes. Mutation: delete the sniff comparison in
# brand_look._check_picture_uri.
def test_a_data_uri_whose_label_does_not_match_its_bytes_is_refused_by_check_value():
    from test_brand_images import JPEG_BASELINE_EXIF
    jpeg = bi.reencode(JPEG_BASELINE_EXIF, "logo")
    assert jpeg.mime == "image/jpeg"
    mislabelled = "data:image/png;base64," + base64.b64encode(jpeg.data).decode()
    why = bl.check_value("logo_image", mislabelled)
    assert "says image/png but the bytes are jpeg" in why
    assert bl.check_value("logo_image", jpeg.data_uri()) == ""


# L3: bytes after the end of the zlib stream, INSIDE the one IDAT chunk. The chunk walk
# and the CRC cannot see them; a decoder stops at the end of the stream. Mutation: drop
# the _idat_trailing line from leftovers.
def test_text_after_the_end_of_the_pixel_stream_inside_the_idat_is_not_clean():
    own = bi.reencode(png_bytes(16, 16, noise=True), "logo").data
    chunks = list(bi._png_chunks(own))
    ihdr = chunks[0][1]
    idat = [p for k, p in chunks if k == b"IDAT"][0]
    evil = (PNG_SIG + _chunk(b"IHDR", ihdr)
            + _chunk(b"IDAT", idat + b"<script>alert(1)</script>") + _chunk(b"IEND", b""))
    assert bi.png_chunk_types(evil) == ["IHDR", "IDAT", "IEND"]      # the walk sees nothing
    assert bi.leftovers(evil, "logo") == ("bytes after the pixel data",)
    why = bl.check_value("logo_image", _uri(evil))
    assert "bytes after the pixel data" in why and "re-encoder" in why
    with pytest.raises(bl.LookError):
        bl.look_css({"logo_image": _uri(evil)})
    assert bl.check_value("logo_image", _uri(own)) == ""
    # the upload path cleans it: re-encoding recompresses only the pixels
    cleaned = bi.reencode(evil, "logo").data
    assert b"script" not in cleaned and bi.leftovers(cleaned, "logo") == ()


# L5: design-mode edits are checked against each brand's finished sheet.
def test_a_superbrand_edit_that_would_push_a_brand_over_its_budget_is_refused_by_name(
        monkeypatch, tmp_path):
    pic = bi.reencode(png_bytes(16, 16, noise=True), "logo")
    pic2 = bi.reencode(png_bytes(40, 40, noise=True), "background")
    brands = {"shop": {"login_bg_image": pic2.data_uri()}, "blog": {}}
    m = bl.Look({})
    m.dependents = lambda: brands
    # room for either picture alone, but not for the brand's own picture under the logo
    both = len(bl.look_css({"login_bg_image": pic2.data_uri(),
                            "logo_image": pic.data_uri()}).encode())
    alone = max(len(bl.look_css({"login_bg_image": pic2.data_uri()}).encode()),
                len(bl.look_css({"logo_image": pic.data_uri()}).encode()))
    assert alone < both - 1
    monkeypatch.setattr(bl, "LOOK_CSS_BUDGET", both - 1)
    out = m.try_set("logo_image", pic.data_uri())
    assert not out.ok and "brand shop" in out.text and f"{both:,}" in out.text
    assert m.get("logo_image") == ""                   # the record is as it was
    # a picture chosen through the upload path is held to the same rule
    out = m.load_picture("logo_image", _png_file(tmp_path, png_bytes(16, 16, noise=True)))
    assert not out.ok and "brand shop" in out.text
    # the same edit is fine once no brand carries a picture ...
    brands["shop"] = {}
    assert m.try_set("logo_image", pic.data_uri()).ok
    # ... and a brand's own edit (override mode) is not checked against its siblings
    brands["shop"] = {"login_bg_image": pic2.data_uri()}
    ov = bl.Look({}, base={})
    ov.dependents = lambda: brands
    assert ov.mode == "override" and ov.try_set("logo_image", pic.data_uri()).ok


def _png_file(tmp_path, data):
    path = tmp_path / "logo.png"
    path.write_bytes(data)
    return str(path)


def test_a_superbrand_edit_that_would_overfill_the_shared_configmap_is_refused(monkeypatch):
    """The kind cluster carries every brand's stylesheet in one ConfigMap: a superbrand
    edit is checked against the sum of the brands' finished sheets plus its own."""
    m = bl.Look({})
    m.dependents = lambda: {"shop": {}, "blog": {}}
    assert m.try_set("primary", "#123456").ok
    each = len(bl.look_css({"primary": "#123456"}).encode())
    monkeypatch.setattr(bl, "CONFIGMAP_LIMIT", 3 * each - 1)
    out = bl.Look({})
    out.dependents = lambda: {"shop": {}, "blog": {}}
    refused = out.try_set("primary", "#123456")
    assert not refused.ok and "ConfigMap" in refused.text and "shop" in refused.text
    monkeypatch.setattr(bl, "CONFIGMAP_LIMIT", 3 * each)
    ok = bl.Look({})
    ok.dependents = lambda: {"shop": {}, "blog": {}}
    assert ok.try_set("primary", "#123456").ok
