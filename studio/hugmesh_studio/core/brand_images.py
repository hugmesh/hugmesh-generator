"""The PNG and JPEG re-encoder for brand pictures (hugmesh-generator#654, D6 and D19).

A brand's logo and login background reach every web page of the mesh as data: URIs
inside the theme stylesheet, and that stylesheet is served to every visitor. So the
bytes that land there are never the uploaded file. This module rebuilds a picture
from the parts a decoder needs and nothing else:

* PNG: the chunks are walked and each CRC checked; the IDAT stream is inflated and
  must be exactly as long as the IHDR size promises (a file that lies about its size,
  or inflates further, is refused); only IHDR, PLTE, tRNS, IDAT and IEND are written
  back, with the scanlines recompressed into one IDAT. Every other chunk (tEXt, iTXt,
  zTXt, eXIf, tIME, pHYs, gAMA, iCCP, ...) is dropped and named.
* JPEG: the segments are walked; only the tables and scans a decoder needs (DQT, DHT,
  SOF0/1/2, DRI, SOS with its entropy-coded data) are written back between a fresh
  SOI and EOI. APPn (JFIF, EXIF, XMP, ICC) and COM segments are dropped and named.
  Kinds a browser cannot show (CMYK, arithmetic coding, lossless, 12-bit) are refused,
  and so is any marker this module does not know: fail closed, never pass through.
* Anything else is refused with the formats that work. SVG is named in its refusal
  because it is the one people try: an SVG can carry script, and the avatar path
  already refuses it for the same reason.

Pure stdlib, Qt-free, like the rest of core/: the text screens, the window and a
future command line all call the same :func:`reencode`. The pixels are not decoded
(no imaging library is a dependency of the Studio); what is checked is the container,
and what is dropped is everything that is not picture.

Size limits are the design's: a logo at most 256x256, a background at most 1280x720.
The stylesheet budget (100 KiB per brand) is :mod:`brand_look`'s job; this module only
says what a picture would weigh.
"""
from __future__ import annotations

import base64
import struct
import zlib
from dataclasses import dataclass

__all__ = ["LIMITS", "MAX_UPLOAD_BYTES", "Picture", "PictureRefused", "reencode", "sniff",
           "png_chunk_types", "png_raw_scanlines", "jpeg_segment_markers"]

#: kind -> (max width, max height), the design's numbers (D6).
LIMITS: dict[str, tuple[int, int]] = {"logo": (256, 256), "background": (1280, 720)}

#: A file past this is not even parsed. No accepted picture can be anywhere near it
#: (the stylesheet budget is 100 KiB), and refusing early keeps a 2 GiB "png" from
#: being read into memory.
MAX_UPLOAD_BYTES = 8 * 1024 * 1024

_PNG_SIG = b"\x89PNG\r\n\x1a\n"
_FORMATS_SENTENCE = "Pictures are accepted as PNG or JPEG only."


class PictureRefused(ValueError):
    """The sentence both faces show inline. Always says what to do instead."""


@dataclass(frozen=True)
class Picture:
    """A re-encoded picture: the bytes the stylesheet will carry."""
    data: bytes
    mime: str                     # image/png | image/jpeg
    width: int
    height: int
    dropped: tuple[str, ...]      # chunk types / segment names that were removed
    original_bytes: int

    def data_uri(self) -> str:
        return f"data:{self.mime};base64," + base64.b64encode(self.data).decode("ascii")


def sniff(data: bytes) -> str:
    """"png", "jpeg", "svg" or "" from the bytes alone. The file name is never trusted."""
    if data.startswith(_PNG_SIG):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    head = data[:2048].lstrip(b"\xef\xbb\xbf \t\r\n").lower()
    if head.startswith(b"<?xml") or head.startswith(b"<svg") or b"<svg" in head:
        return "svg"
    return ""


def reencode(data: bytes, kind: str, *, filename: str = "") -> Picture:
    """Rebuild ``data`` as a PNG or JPEG of at most the size ``kind`` allows.

    Raises :class:`PictureRefused` with the reason a person can act on; ``filename``
    only decorates the message (the bytes decide the format)."""
    if kind not in LIMITS:
        raise ValueError(f"picture kind must be one of {', '.join(LIMITS)}, got {kind!r}")
    name = f" ({filename})" if filename else ""
    if len(data) > MAX_UPLOAD_BYTES:
        raise PictureRefused(
            f"This file{name} is {len(data):,} bytes; at most "
            f"{MAX_UPLOAD_BYTES // (1024 * 1024)} MiB is read. The web look has a budget "
            f"of 100 KiB in all, so a picture this large could never fit.")
    fmt = sniff(data)
    if fmt == "svg":
        raise PictureRefused(
            f"SVG is not accepted{name}: a drawing file can carry script, and it would be "
            f"served to every visitor. Save it as a PNG or JPEG and upload that.")
    if fmt not in ("png", "jpeg"):
        what = "an empty file" if not data else "not a PNG or JPEG file"
        raise PictureRefused(f"This is {what}{name}. {_FORMATS_SENTENCE}")
    if fmt == "png":
        out, w, h, dropped = _reencode_png(data)
        mime = "image/png"
    else:
        out, w, h, dropped = _reencode_jpeg(data)
        mime = "image/jpeg"
    max_w, max_h = LIMITS[kind]
    if w > max_w or h > max_h:
        raise PictureRefused(
            f"A {kind} may be at most {max_w}x{max_h} pixels; this picture{name} is "
            f"{w}x{h}. Scale it down and upload it again.")
    return Picture(out, mime, w, h, tuple(dropped), len(data))


# ── PNG ──────────────────────────────────────────────────────────────────────────────
_PNG_KEEP = (b"IHDR", b"PLTE", b"tRNS", b"IDAT", b"IEND")
_CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
_ADAM7 = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
          (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2))


def _png_chunks(data: bytes):
    """Yield ``(type, payload)`` for every chunk, checking lengths and CRCs; a broken
    file raises before any of it is trusted. Trailing bytes after IEND are reported as
    one final ``(b"", trailing)`` item."""
    pos = len(_PNG_SIG)
    while True:
        if pos + 8 > len(data):
            raise PictureRefused("This PNG is cut short: it has no IEND chunk.")
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        if length > 0x7FFFFFFF or pos + 12 + length > len(data):
            raise PictureRefused(f"This PNG is cut short inside its {kind.decode('latin-1')} "
                                 "chunk.")
        payload = data[pos + 8:pos + 8 + length]
        (crc,) = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])
        if crc != (zlib.crc32(kind + payload) & 0xFFFFFFFF):
            raise PictureRefused(f"This PNG is damaged: the CRC of its "
                                 f"{kind.decode('latin-1')} chunk does not match.")
        yield kind, payload
        pos += 12 + length
        if kind == b"IEND":
            if pos < len(data):
                yield b"", data[pos:]
            return


def _png_raw_length(w: int, h: int, depth: int, color_type: int, interlace: int) -> int:
    bpp = depth * _CHANNELS[color_type]
    if not interlace:
        return h * (1 + (w * bpp + 7) // 8)
    total = 0
    for xs, ys, xstep, ystep in _ADAM7:
        pw = (w - xs + xstep - 1) // xstep if w > xs else 0
        ph = (h - ys + ystep - 1) // ystep if h > ys else 0
        if pw and ph:
            total += ph * (1 + (pw * bpp + 7) // 8)
    return total


def _inflate_exactly(comp: bytes, expected: int) -> bytes:
    """Inflate ``comp`` and insist on exactly ``expected`` bytes: shorter is a size lie,
    longer is a stream that keeps going past the picture (the inflation is capped, so a
    deflate bomb costs at most ``expected`` + 1 bytes of memory)."""
    d = zlib.decompressobj()
    try:
        raw = d.decompress(comp, expected + 1)
        raw += d.flush(1)
    except zlib.error as exc:
        raise PictureRefused(f"This PNG's pixel data does not inflate: {exc}.") from None
    if len(raw) != expected or d.unconsumed_tail:
        raise PictureRefused(
            f"This PNG's pixel data is {('shorter' if len(raw) < expected else 'longer')} "
            f"than its size says ({len(raw):,} bytes for a picture that needs "
            f"{expected:,}). A file whose pixel data and header disagree is refused.")
    return raw


def _reencode_png(data: bytes) -> tuple[bytes, int, int, list[str]]:
    chunks = list(_png_chunks(data))
    if not chunks or chunks[0][0] != b"IHDR" or len(chunks[0][1]) != 13:
        raise PictureRefused("This PNG does not start with an IHDR chunk.")
    w, h, depth, color_type, comp_m, filt_m, interlace = struct.unpack(
        ">IIBBBBB", chunks[0][1])
    if not (0 < w <= 0x7FFFFFFF and 0 < h <= 0x7FFFFFFF):
        raise PictureRefused("This PNG declares a zero or impossible size.")
    if color_type not in _CHANNELS or comp_m != 0 or filt_m != 0 or interlace not in (0, 1):
        raise PictureRefused("This PNG uses a colour type or method no browser decodes.")
    if depth not in ((1, 2, 4, 8, 16) if color_type == 0 else
                     (1, 2, 4, 8) if color_type == 3 else (8, 16)):
        raise PictureRefused("This PNG's bit depth is not valid for its colour type.")
    # The raw length is bounded by the size limits before anything is inflated: a
    # 30000x30000 header would otherwise ask for a 3.6 GB inflation.
    max_w = max(x for x, _ in LIMITS.values())
    max_h = max(y for _, y in LIMITS.values())
    if w > max_w or h > max_h:
        raise PictureRefused(
            f"This picture is {w}x{h} pixels; nothing larger than {max_w}x{max_h} is read.")
    expected = _png_raw_length(w, h, depth, color_type, interlace)
    idat = bytearray()
    plte = trns = None
    dropped: list[str] = []
    seen_iend = False
    for kind, payload in chunks[1:]:
        if kind == b"":
            dropped.append("trailing data")
        elif kind == b"IDAT":
            idat += payload
        elif kind == b"PLTE":
            plte = payload
        elif kind == b"tRNS":
            trns = payload
        elif kind == b"IEND":
            seen_iend = True
        elif kind == b"IHDR":
            raise PictureRefused("This PNG has two IHDR chunks.")
        else:
            dropped.append(kind.decode("latin-1"))
    if not seen_iend:
        raise PictureRefused("This PNG has no IEND chunk.")
    if color_type == 3 and (plte is None or len(plte) % 3 or not plte):
        raise PictureRefused("This palette PNG has no usable palette (PLTE) chunk.")
    if not idat:
        raise PictureRefused("This PNG has no pixel data (IDAT).")
    raw = _inflate_exactly(bytes(idat), expected)
    out = bytearray(_PNG_SIG)
    out += _chunk(b"IHDR", chunks[0][1])
    if plte is not None and color_type in (2, 3, 6):      # PLTE is meaningless otherwise
        out += _chunk(b"PLTE", plte)
    elif plte is not None:
        dropped.append("PLTE")
    if trns is not None and color_type in (0, 2, 3):
        out += _chunk(b"tRNS", trns)
    elif trns is not None:
        dropped.append("tRNS")
    out += _chunk(b"IDAT", zlib.compress(raw, 9))
    out += _chunk(b"IEND", b"")
    return bytes(out), w, h, sorted(set(dropped))


def _chunk(kind: bytes, payload: bytes) -> bytes:
    return (struct.pack(">I", len(payload)) + kind + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))


def png_chunk_types(data: bytes) -> list[str]:
    """The chunk types of a PNG in order (for tests and the meter's detail line)."""
    return [k.decode("latin-1") for k, _ in _png_chunks(data) if k]


def png_raw_scanlines(data: bytes) -> bytes:
    """The inflated, still-filtered scanlines of a PNG — what the picture IS, apart
    from how it was compressed. Two files with equal scanlines show the same pixels."""
    chunks = list(_png_chunks(data))
    w, h, depth, color_type, _c, _f, interlace = struct.unpack(">IIBBBBB", chunks[0][1])
    idat = b"".join(p for k, p in chunks if k == b"IDAT")
    return _inflate_exactly(idat, _png_raw_length(w, h, depth, color_type, interlace))


# ── JPEG ─────────────────────────────────────────────────────────────────────────────
_SOF_OK = {0xC0: "SOF0", 0xC1: "SOF1", 0xC2: "SOF2"}
_SOF_REFUSED = {
    0xC3: "lossless", 0xC5: "hierarchical", 0xC6: "hierarchical", 0xC7: "hierarchical",
    0xC9: "arithmetic coding", 0xCA: "arithmetic coding", 0xCB: "arithmetic coding",
    0xCD: "arithmetic coding", 0xCE: "arithmetic coding", 0xCF: "arithmetic coding"}
_KEEP = {0xDB: "DQT", 0xC4: "DHT", 0xDD: "DRI", 0xDA: "SOS", **_SOF_OK}
_DROP = {0xFE: "COM", **{0xE0 + i: f"APP{i}" for i in range(16)}}


def _jpeg_segments(data: bytes):
    """Yield ``(marker, name, payload, entropy)`` for each segment between SOI and EOI;
    ``entropy`` is the coded data that follows a SOS. Then ``(None, "trailing data",
    rest, b"")`` if bytes follow EOI."""
    pos = 2                                                   # past SOI
    while True:
        if pos + 2 > len(data):
            raise PictureRefused("This JPEG is cut short: it has no end marker (EOI).")
        if data[pos] != 0xFF:
            raise PictureRefused("This JPEG has stray bytes where a marker should be.")
        marker = data[pos + 1]
        if marker == 0xFF:                                    # fill bytes are legal
            pos += 1
            continue
        if marker == 0xD9:                                    # EOI
            if pos + 2 < len(data):
                yield None, "trailing data", data[pos + 2:], b""
            return
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            raise PictureRefused("This JPEG has a marker out of place (a second start, "
                                 "or a restart marker outside the scan).")
        if pos + 4 > len(data):
            raise PictureRefused("This JPEG is cut short inside a segment header.")
        (length,) = struct.unpack(">H", data[pos + 2:pos + 4])
        if length < 2 or pos + 2 + length > len(data):
            raise PictureRefused("This JPEG is cut short inside a segment.")
        payload = data[pos + 4:pos + 2 + length]
        pos += 2 + length
        entropy = b""
        if marker == 0xDA:                                    # SOS: coded data follows
            start = pos
            while True:
                nxt = data.find(b"\xff", pos)
                if nxt < 0 or nxt + 1 >= len(data):
                    raise PictureRefused("This JPEG's scan runs off the end of the file.")
                after = data[nxt + 1]
                if after == 0x00 or 0xD0 <= after <= 0xD7:    # stuffing / restart
                    pos = nxt + 2
                    continue
                pos = nxt
                break
            entropy = data[start:pos]
        if marker in _SOF_REFUSED:
            raise PictureRefused(f"This JPEG uses {_SOF_REFUSED[marker]}, which browsers "
                                 "do not decode. Save it as a baseline or progressive JPEG.")
        name = _KEEP.get(marker) or _DROP.get(marker)
        if name is None:
            raise PictureRefused(f"This JPEG carries a segment this re-encoder does not "
                                 f"know (marker 0x{marker:02X}); it is refused rather than "
                                 "passed through.")
        yield marker, name, payload, entropy


def _reencode_jpeg(data: bytes) -> tuple[bytes, int, int, list[str]]:
    out = bytearray(b"\xff\xd8")
    dropped: list[str] = []
    size = None
    scans = 0
    for marker, name, payload, entropy in _jpeg_segments(data):
        if marker is None:
            dropped.append(name)
            continue
        if marker in _DROP:
            dropped.append(name)
            continue
        if marker in _SOF_OK:
            if len(payload) < 6:
                raise PictureRefused("This JPEG's frame header is too short.")
            precision, h, w, ncomp = struct.unpack(">BHHB", payload[:6])
            if ncomp == 4:
                raise PictureRefused("This JPEG is CMYK (four colour components), which "
                                     "browsers show with wrong colours. Save it as RGB.")
            if precision != 8:
                raise PictureRefused(f"This JPEG has {precision}-bit samples; browsers "
                                     "decode 8-bit JPEGs only.")
            if w == 0 or h == 0:
                raise PictureRefused("This JPEG does not state its size in the frame header.")
            if size is not None:
                raise PictureRefused("This JPEG has two frame headers.")
            size = (w, h)
        if marker == 0xDA:
            if size is None:
                raise PictureRefused("This JPEG starts a scan before its frame header.")
            scans += 1
        out += b"\xff" + bytes([marker]) + struct.pack(">H", len(payload) + 2) + payload
        out += entropy
    if size is None or scans == 0:
        raise PictureRefused("This JPEG has no frame or no scan: nothing to show.")
    out += b"\xff\xd9"
    return bytes(out), size[0], size[1], sorted(set(dropped))


def jpeg_segment_markers(data: bytes) -> list[str]:
    """The segment names of a JPEG in order (for tests and the meter's detail line)."""
    return [name for marker, name, _p, _e in _jpeg_segments(data) if marker is not None]
