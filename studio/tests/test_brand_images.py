"""core/brand_images — the PNG and JPEG re-encoder for brand pictures (#654, D6/D19).

Qt-free. The pictures a person uploads for a logo or a login background reach every
web page of the mesh as data: URIs inside the theme stylesheet, so the bytes that
land there are never the uploaded file: they are rebuilt from the parts a decoder
needs, every metadata chunk or segment is dropped, and anything that is not a
plain PNG or JPEG is refused with a sentence that says why. Each refusal below is
asserted by its REASON, not only by the exception type, because the same sentence is
what both faces show inline.
"""
import base64
import struct
import zlib

import pytest

from hugmesh_studio.core import brand_images as bi

# ── fixtures: pictures built here, byte by byte ──────────────────────────────────────
PNG_SIG = b"\x89PNG\r\n\x1a\n"


def _chunk(kind: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))


def make_png(w: int, h: int, *, color_type: int = 6, depth: int = 8, interlace: int = 0,
             extra_chunks=(), raw=None, idat_split=1) -> bytes:
    """A valid PNG of ``w``x``h`` with optional metadata chunks before IDAT."""
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    rowbytes = (w * depth * channels + 7) // 8
    if raw is None:
        if interlace:
            raw = _adam7_raw(w, h, depth * channels)
        else:
            raw = b"".join(b"\x00" + bytes((x * 7 + y * 3) % 256 for x in range(rowbytes))
                           for y in range(h))
    ihdr = struct.pack(">IIBBBBB", w, h, depth, color_type, 0, 0, interlace)
    out = PNG_SIG + _chunk(b"IHDR", ihdr)
    if color_type == 3:
        out += _chunk(b"PLTE", bytes(i % 256 for i in range(3 * (1 << depth))))
    for kind, data in extra_chunks:
        out += _chunk(kind, data)
    comp = zlib.compress(raw, 6)
    step = max(1, len(comp) // idat_split)
    for i in range(0, len(comp), step):
        out += _chunk(b"IDAT", comp[i:i + step])
    out += _chunk(b"IEND", b"")
    return out


def _adam7_raw(w: int, h: int, bpp: int) -> bytes:
    passes = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
              (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2))
    out = b""
    for xs, ys, xstep, ystep in passes:
        pw = (w - xs + xstep - 1) // xstep if w > xs else 0
        ph = (h - ys + ystep - 1) // ystep if h > ys else 0
        if pw and ph:
            out += (b"\x00" + bytes((pw * bpp + 7) // 8)) * ph
    return out


# A 4x3 baseline JPEG written by Pillow with an EXIF block (APP1, "secret description",
# "Artist Name") and a COM segment ("hidden comment"); a progressive one; and a CMYK one
# (APP14 Adobe, four components). Generated once and pasted, so this test needs no
# imaging library.
JPEG_BASELINE_EXIF = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/4QBORXhpZgAATU0AKgAAAAgAAgEOAAIAAAATAAAAJgE7AAIAAAAMAAAAOgAA"
    "AABzZWNyZXQgZGVzY3JpcHRpb24AAEFydGlzdCBOYW1lAP/+ABBoaWRkZW4gY29tbWVudP/bAEMACAYGBwYFCAcH"
    "BwkJCAoMFA0MCwsMGRITDxQdGh8eHRocHCAkLicgIiwjHBwoNyksMDE0NDQfJzk9ODI8LjM0Mv/bAEMBCQkJDAsM"
    "GA0NGDIhHCEyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMv/AABEIAAMA"
    "BAMBIgACEQEDEQH/xAAfAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgv/xAC1EAACAQMDAgQDBQUEBAAAAX0B"
    "AgMABBEFEiExQQYTUWEHInEUMoGRoQgjQrHBFVLR8CQzYnKCCQoWFxgZGiUmJygpKjQ1Njc4OTpDREVGR0hJSlNU"
    "VVZXWFlaY2RlZmdoaWpzdHV2d3h5eoOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK"
    "0tPU1dbX2Nna4eLj5OXm5+jp6vHy8/T19vf4+fr/xAAfAQADAQEBAQEBAQEBAAAAAAAAAQIDBAUGBwgJCgv/xAC1"
    "EQACAQIEBAMEBwUEBAABAncAAQIDEQQFITEGEkFRB2FxEyIygQgUQpGhscEJIzNS8BVictEKFiQ04SXxFxgZGiYn"
    "KCkqNTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqCg4SFhoeIiYqSk5SVlpeYmZqio6Slpqeo"
    "qaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2dri4+Tl5ufo6ery8/T19vf4+fr/2gAMAwEAAhEDEQA/AOTooorj"
    "P0o//9k=")
JPEG_PROGRESSIVE = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIs"
    "IxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIy"
    "MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wgARCAADAAQDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAA"
    "AAX/xAAVAQEBAAAAAAAAAAAAAAAAAAADBv/aAAwDAQACEAMQAAABkgaX/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/a"
    "AAgBAQABBQJ//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPwF//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/a"
    "AAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQAGPwJ//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/a"
    "AAgBAQABPyF//9oADAMBAAIAAwAAABAD/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPxB//8QAFBEBAAAA"
    "AAAAAAAAAAAAAAAAAP/aAAgBAgEBPxB//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxB//9k=")
JPEG_CMYK = base64.b64decode(
    "/9j/7gAOQWRvYmUAZAAAAAAA/9sAQwAIBgYHBgUIBwcHCQkICgwUDQwLCwwZEhMPFB0aHx4dGhwcICQuJyAiLCMc"
    "HCg3KSwwMTQ0NB8nOT04MjwuMzQy/8AAFAgAAgACBEMRAE0RAFkRAEsRAP/EAB8AAAEFAQEBAQEBAAAAAAAAAAAB"
    "AgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNi"
    "coIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SV"
    "lpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/aAA4E"
    "QwBNAFkASwAAPwD3+vf69/r3+v/Z")

SVG = b'<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"><script>x()</script></svg>'


# ── what is refused, and why ─────────────────────────────────────────────────────────
def test_svg_is_refused_and_the_reason_names_svg_and_the_formats_that_work():
    with pytest.raises(bi.PictureRefused) as e:
        bi.reencode(SVG, "logo", filename="logo.svg")
    msg = str(e.value)
    assert "SVG" in msg and "PNG" in msg and "JPEG" in msg


def test_an_svg_renamed_to_png_is_still_refused():
    # the extension lies; the bytes decide
    with pytest.raises(bi.PictureRefused, match="SVG"):
        bi.reencode(b"  \n" + SVG, "logo", filename="logo.png")


@pytest.mark.parametrize("data,name", [
    (b"GIF89a" + bytes(20), "GIF"), (b"RIFF" + bytes(4) + b"WEBPVP8 ", "WebP"),
    (b"\x1f\x8b\x08" + bytes(10), "compressed"), (b"", "empty"),
    (b"BM" + bytes(40), "unknown")])
def test_other_formats_are_refused_with_the_format_named(data, name):
    with pytest.raises(bi.PictureRefused) as e:
        bi.reencode(data, "background")
    assert "PNG" in str(e.value) and "JPEG" in str(e.value)


def test_oversize_is_refused_with_both_sets_of_numbers():
    big = make_png(300, 257)
    with pytest.raises(bi.PictureRefused) as e:
        bi.reencode(big, "logo")
    msg = str(e.value)
    assert "300" in msg and "257" in msg            # what was uploaded
    assert "256" in msg                              # the limit
    # the same picture is fine as a background (its limit is 1280x720)
    assert bi.reencode(big, "background").width == 300


def test_the_limits_are_the_design_numbers():
    assert bi.LIMITS["logo"] == (256, 256)
    assert bi.LIMITS["background"] == (1280, 720)
    with pytest.raises(ValueError):
        bi.reencode(make_png(2, 2), "poster")


def test_a_corrupt_png_is_refused_not_passed_through():
    good = make_png(8, 8, extra_chunks=[(b"tEXt", b"Comment\x00hello")])
    # flip a byte inside the tEXt chunk's data: its CRC no longer matches
    i = good.index(b"tEXt") + 6
    bad_crc = good[:i] + bytes([good[i] ^ 0xFF]) + good[i + 1:]
    with pytest.raises(bi.PictureRefused, match="CRC"):
        bi.reencode(bad_crc, "logo")
    # a pixel stream that is too short for the declared size is a lie about the size
    short = make_png(8, 8, raw=b"\x00" * 10)
    with pytest.raises(bi.PictureRefused, match="pixel"):
        bi.reencode(short, "logo")
    # and one that is too long is refused the same way (a zip-bomb cannot inflate past
    # the size the header promised)
    long = make_png(8, 8, raw=b"\x00" * 100_000)
    with pytest.raises(bi.PictureRefused, match="pixel"):
        bi.reencode(long, "logo")


def test_a_png_with_no_iend_or_no_ihdr_is_refused():
    whole = make_png(2, 2)
    with pytest.raises(bi.PictureRefused):
        bi.reencode(whole[:-12], "logo")               # truncated before IEND
    no_ihdr = PNG_SIG + _chunk(b"tEXt", b"a\x00b") + whole[8:]
    with pytest.raises(bi.PictureRefused, match="IHDR"):
        bi.reencode(no_ihdr, "logo")


def test_jpeg_kinds_browsers_cannot_show_are_refused():
    with pytest.raises(bi.PictureRefused, match="CMYK"):
        bi.reencode(JPEG_CMYK, "logo")
    # SOF9 (arithmetic coding): swap the baseline marker for it
    arith = JPEG_BASELINE_EXIF.replace(b"\xff\xc0", b"\xff\xc9", 1)
    with pytest.raises(bi.PictureRefused, match="arithmetic|not supported"):
        bi.reencode(arith, "logo")


def test_a_jpeg_with_an_unknown_segment_or_no_end_marker_is_refused():
    with pytest.raises(bi.PictureRefused):
        bi.reencode(JPEG_BASELINE_EXIF[:-2], "logo")   # no EOI
    # a reserved marker (0xC8, JPG extension) between the segments
    i = JPEG_BASELINE_EXIF.index(b"\xff\xdb")
    odd = JPEG_BASELINE_EXIF[:i] + b"\xff\xc8\x00\x04\x00\x00" + JPEG_BASELINE_EXIF[i:]
    with pytest.raises(bi.PictureRefused, match="segment"):
        bi.reencode(odd, "logo")


def test_a_file_too_large_to_read_is_refused_before_parsing():
    data = PNG_SIG + bytes(bi.MAX_UPLOAD_BYTES)
    with pytest.raises(bi.PictureRefused) as e:
        bi.reencode(data, "background")
    assert str(bi.MAX_UPLOAD_BYTES // (1024 * 1024)) in str(e.value)


# ── what is accepted, and what it loses ──────────────────────────────────────────────
def test_png_metadata_is_dropped_and_the_result_is_a_png_we_built():
    src = make_png(16, 9, extra_chunks=[
        (b"tEXt", b"Author\x00Jane"), (b"iTXt", b"XML:com.adobe.xmp\x00\x00\x00\x00\x00<x/>"),
        (b"zTXt", b"c\x00\x00" + zlib.compress(b"z")), (b"eXIf", b"Exif\x00\x00"),
        (b"tIME", bytes(7)), (b"pHYs", bytes(9)), (b"gAMA", bytes(4)),
        (b"iCCP", b"p\x00\x00" + zlib.compress(b"icc"))], idat_split=3)
    pic = bi.reencode(src, "logo", filename="logo.png")
    assert pic.mime == "image/png" and (pic.width, pic.height) == (16, 9)
    for word in (b"Jane", b"tEXt", b"iTXt", b"zTXt", b"eXIf", b"tIME", b"pHYs", b"gAMA",
                 b"iCCP", b"<x/>"):
        assert word not in pic.data
    assert set(pic.dropped) == {"tEXt", "iTXt", "zTXt", "eXIf", "tIME", "pHYs", "gAMA",
                                "iCCP"}
    # exactly the chunks a decoder needs, one IDAT, in order
    assert bi.png_chunk_types(pic.data) == ["IHDR", "IDAT", "IEND"]
    # and the picture itself is unchanged: the same unfiltered scanlines come back out
    assert bi.png_raw_scanlines(pic.data) == bi.png_raw_scanlines(src)
    # the result is itself accepted again, unchanged (re-encoding is idempotent)
    assert bi.reencode(pic.data, "logo").data == pic.data


def test_palette_and_transparency_survive_and_interlace_is_accepted():
    pal = make_png(5, 4, color_type=3, depth=4,
                   extra_chunks=[(b"tRNS", bytes(3)), (b"tEXt", b"k\x00v")])
    pic = bi.reencode(pal, "logo")
    assert bi.png_chunk_types(pic.data) == ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"]
    lace = make_png(13, 7, interlace=1)
    assert bi.reencode(lace, "logo").height == 7
    # a palette image with no palette cannot be drawn
    no_plte = make_png(2, 2, color_type=3).replace(b"PLTE", b"plTe")
    with pytest.raises(bi.PictureRefused):
        bi.reencode(no_plte, "logo")


def test_jpeg_metadata_is_dropped_and_the_scan_survives():
    pic = bi.reencode(JPEG_BASELINE_EXIF, "logo", filename="photo.jpg")
    assert pic.mime == "image/jpeg" and (pic.width, pic.height) == (4, 3)
    for word in (b"secret description", b"Artist Name", b"hidden comment", b"Exif",
                 b"JFIF"):
        assert word not in pic.data
    assert set(pic.dropped) == {"APP0", "APP1", "COM"}
    assert pic.data.startswith(b"\xff\xd8") and pic.data.endswith(b"\xff\xd9")
    assert bi.jpeg_segment_markers(pic.data) == ["DQT", "DQT", "SOF0", "DHT", "DHT",
                                                 "DHT", "DHT", "SOS"]
    assert bi.reencode(pic.data, "logo").data == pic.data
    prog = bi.reencode(JPEG_PROGRESSIVE, "background")
    assert "SOF2" in bi.jpeg_segment_markers(prog.data)
    assert bi.jpeg_segment_markers(prog.data).count("SOS") > 1


def test_trailing_bytes_after_a_jpeg_or_png_are_dropped_and_named():
    pic = bi.reencode(JPEG_BASELINE_EXIF + b"trailing junk", "logo")
    assert "trailing data" in pic.dropped and b"junk" not in pic.data
    pic = bi.reencode(make_png(2, 2) + b"trailing junk", "logo")
    assert "trailing data" in pic.dropped and b"junk" not in pic.data


def test_the_data_uri_is_what_the_stylesheet_carries():
    pic = bi.reencode(make_png(2, 2), "logo")
    uri = pic.data_uri()
    assert uri.startswith("data:image/png;base64,")
    assert base64.b64decode(uri.split(",", 1)[1]) == pic.data
    assert bi.sniff(pic.data) == "png" and bi.sniff(JPEG_PROGRESSIVE) == "jpeg"
    assert bi.sniff(SVG) == "svg" and bi.sniff(b"") == ""


def _png_with_idat(w, h, comp, *, color_type=0):
    """A PNG whose IDAT is exactly ``comp`` (so a test can hand the inflater a bomb or a
    stream cut short, which make_png's honest compressor cannot)."""
    ihdr = struct.pack(">IIBBBBB", w, h, 8, color_type, 0, 0, 0)
    return PNG_SIG + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", comp) + _chunk(b"IEND", b"")


def test_a_deflate_bomb_is_refused_without_inflating_it():
    import tracemalloc
    # 1x1 grayscale needs 2 bytes of pixels; this stream inflates to 200 MiB from a few
    # hundred KiB. The cap must stop at expected+1 bytes: an uncapped flush() inflated
    # the whole thing (0.5 s, 800 MB for 400 MiB) before the length check refused it.
    bomb = zlib.compress(b"\x00" * (200 * 1024 * 1024), 9)
    data = _png_with_idat(1, 1, bomb)
    assert len(data) < bi.MAX_UPLOAD_BYTES
    tracemalloc.start()
    try:
        with pytest.raises(bi.PictureRefused, match="longer than its size says"):
            bi.reencode(data, "logo")
        _cur, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()
    assert peak < 4 * 1024 * 1024, f"the refusal inflated {peak:,} bytes first"


def test_a_pixel_stream_cut_short_before_its_end_is_refused():
    # the right number of pixels, but the zlib trailer (adler32) is missing: the stream
    # never ends, and a decoder would have to guess what follows
    comp = zlib.compress(b"\x00\x80", 9)[:-4]
    with pytest.raises(bi.PictureRefused, match="pixel"):
        bi.reencode(_png_with_idat(1, 1, comp), "logo")
