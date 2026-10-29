#!/usr/bin/env python3
"""private_name_neutrality.py — no tracked file may name the retired private target.

This repository is public. The operator's own private target (a domain and a GitHub
organisation that hugmesh used before its rebrand) must not appear in ANY file git
tracks: code, docs, fixtures, built bundles, certificates, keys, images.

The forbidden stem is spelled from PARTS below, so this file never carries it whole.
Longer private spellings, if wanted, stay OUTSIDE the repository: a file named by
``HUGMESH_ORG_EXPORT_PRIVATE_NAMES`` (one string per line, ``#`` comments) is read when
set — the same variable studio/tests/test_org_export_neutrality.py reads.

WHAT IS SCANNED, per tracked file, read as BYTES (a NUL byte must not blind the scan;
GNU grep skips a whole file on one NUL and exits 1, exactly like a clean miss):

  plain      the stem, case-insensitive
  utf16      the stem as UTF-16 (LE and BE), case-insensitive
  hex        the stem's ASCII as hex digits (lower, Title, UPPER spellings)
  base64     the stem inside a base64 blob, at all three byte alignments, standard
             and URL-safe alphabets, lower/Title/UPPER spellings — this is how it hid
             in two compose dev keys and in the DER bodies of the old test certificates
  png-text   the stem in a PNG's tEXt / zTXt / iTXt metadata chunks (decompressed)

WHAT IS NOT SCANNED: text drawn as PIXELS in an image. A committed screenshot showed
the private domain in its page header and nobody's text scan could see it. Any new
committed screenshot needs a look by eye or an OCR pass (tesseract) before it lands.

Exit status: 0 clean; 1 at least one hit (each printed as ``<path>: <shape>``, never
the matched text); 2 the scan could not be trusted (the self-probe missed a planted
shape, or too few files were tracked for the scan to mean anything).

Usage: private_name_neutrality.py <git work tree> [--min-files N]
"""
from __future__ import annotations

import base64
import os
import struct
import subprocess
import sys
import zlib

# The private target's stem, assembled so it never appears whole in this file.
_STEM = "snap" + "dragon"

DEFAULT_MIN_FILES = 1000


def private_names() -> tuple[str, ...]:
    """The stem plus any extra names from the operator's file outside the repository."""
    names = [_STEM]
    path = os.environ.get("HUGMESH_ORG_EXPORT_PRIVATE_NAMES", "").strip()
    if path:
        try:
            with open(path, encoding="utf-8") as fh:
                for ln in fh:
                    ln = ln.strip().lower()
                    if ln and not ln.startswith("#"):
                        names.append(ln)
        except OSError:
            pass
    # de-duplicate, keep order
    return tuple(dict.fromkeys(n.lower() for n in names if n))


def _spellings(word: str) -> set[str]:
    return {word.lower(), word.title(), word.upper(), word[:1].upper() + word[1:].lower()}


def _b64_cores(word: str) -> set[bytes]:
    """Stable base64 substrings ``word`` produces at each byte alignment, in both
    alphabets: a substring check on these finds the word inside any base64 blob."""
    cores: set[bytes] = set()
    for variant in _spellings(word):
        raw = variant.encode()
        for pad in range(3):
            enc = base64.b64encode(b"\0" * pad + raw)
            lead = {0: 0, 1: 2, 2: 3}[pad]           # chars that depend on the prefix
            core = enc[lead:]
            core = core[: len(core) - (len(core) % 4 or 4)]   # and on the trailing bytes
            if len(core) >= 8:
                cores.add(core)
                cores.add(core.replace(b"+", b"-").replace(b"/", b"_"))
    return cores


class Matcher:
    def __init__(self, names):
        self.names = tuple(names)
        self.plain = [n.encode() for n in self.names]
        self.utf16 = [n.encode(enc) for n in self.names for enc in ("utf-16-le", "utf-16-be")]
        self.hex = sorted({v.encode().hex().encode() for n in self.names for v in _spellings(n)})
        self.b64 = sorted({c for n in self.names for c in _b64_cores(n)})

    def text_shapes(self, data: bytes) -> list[str]:
        low = data.lower()
        shapes: list[str] = []
        if any(p in low for p in self.plain):
            shapes.append("plain")
        if any(u in low for u in self.utf16):
            shapes.append("utf16")
        if any(h in low for h in self.hex):
            shapes.append("hex")
        if any(c in data for c in self.b64):
            shapes.append("base64")
        return shapes

    def shapes(self, data: bytes) -> list[str]:
        shapes = self.text_shapes(data)
        if data.startswith(b"\x89PNG\r\n\x1a\n"):
            for text in png_text_chunks(data):
                if any(p in text.lower() for p in self.plain) or self.text_shapes(text):
                    shapes.append("png-text")
                    break
        return shapes


def png_text_chunks(data: bytes) -> list[bytes]:
    """The payloads of a PNG's tEXt / zTXt / iTXt chunks, decompressed where needed.
    A malformed PNG yields what could be read; the plain byte scan still covers it."""
    out: list[bytes] = []
    pos = 8
    while pos + 8 <= len(data):
        length, ctype = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        try:
            if ctype == b"tEXt":
                out.append(body)
            elif ctype == b"zTXt":
                key, _, rest = body.partition(b"\0")
                out.append(key + b" " + zlib.decompress(rest[1:]))
            elif ctype == b"iTXt":
                key, _, rest = body.partition(b"\0")
                comp_flag = rest[0:1]
                rest = rest[2:]
                lang, _, rest = rest.partition(b"\0")
                tkey, _, text = rest.partition(b"\0")
                if comp_flag == b"\x01":
                    text = zlib.decompress(text)
                out.append(b" ".join((key, lang, tkey, text)))
        except (zlib.error, IndexError):
            out.append(body)
        if ctype == b"IEND":
            break
    return out


def _png_with_text(ctype: bytes, payload: bytes) -> bytes:
    def chunk(t: bytes, b: bytes) -> bytes:
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(ctype, payload) + chunk(b"IEND", b"")


def self_probe(m: Matcher) -> list[str]:
    """Every shape must be reported on a planted sample, and a near-miss must not be.
    Runs on EVERY invocation: a clean tree cannot tell a working matcher from a
    rotted one, so the matcher proves itself each time."""
    s = _STEM
    plants = {
        "plain": b"host: registry." + s.title().encode() + b".example\n",
        "plain-behind-nul": b"\0\0" + s.upper().encode() + b"\0",
        "utf16": ("id." + s + ".example").encode("utf-16-le"),
        "hex": b"name=" + s.encode().hex().upper().encode(),
    }
    for pad in range(3):
        blob = base64.b64encode(b"x" * pad + (s + "-dev-key-32byte").encode())
        plants[f"base64-{pad}"] = b"KEY: ${KEY:-" + blob + b"}\n"
        plants[f"base64url-{pad}"] = base64.urlsafe_b64encode(b"\xfb\xff" * pad + s.title().encode())
    plants["png-zTXt"] = _png_with_text(b"zTXt", b"Comment\0\0" + zlib.compress(("admin@" + s + ".example").encode()))
    plants["png-iTXt"] = _png_with_text(b"iTXt", b"Title\0\x01\0en\0\0" + zlib.compress(s.upper().encode()))
    misses = [name for name, data in plants.items() if not m.shapes(data)]
    near = b"snap dragon snapper dragonfly " + base64.b64encode(b"hugmesh-dev")
    if m.shapes(near):
        misses.append("near-miss reported as a hit")
    return misses


def tracked_files(root: str) -> list[str]:
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True, check=True).stdout
    return [p for p in out.decode("utf-8", "surrogateescape").split("\0") if p]


def main(argv: list[str]) -> int:
    args = list(argv)
    min_files = DEFAULT_MIN_FILES
    if "--min-files" in args:
        i = args.index("--min-files")
        min_files = int(args[i + 1])
        del args[i:i + 2]
    if len(args) != 1:
        print(__doc__.strip().splitlines()[-1])
        return 2
    root = args[0]
    m = Matcher(private_names())

    misses = self_probe(m)
    if misses:
        print("  FAIL [neutrality-probe] the matcher missed planted shapes: " + ", ".join(misses))
        return 2

    try:
        files = tracked_files(root)
    except (subprocess.CalledProcessError, OSError) as exc:
        print(f"  FAIL [neutrality-incomplete] git ls-files failed in {root}: {exc}")
        return 2
    if len(files) < min_files:
        print(f"  FAIL [neutrality-incomplete] only {len(files)} tracked file(s) under {root} "
              f"(floor {min_files}) — the scan would be vacuous")
        return 2

    hits: list[str] = []
    scanned = 0
    for rel in files:
        path = os.path.join(root, rel)
        if os.path.islink(path):
            data = os.fsencode(os.readlink(path))      # git tracks a link as its target text
        elif os.path.isfile(path):
            with open(path, "rb") as fh:
                data = fh.read()
        else:
            continue                                   # a submodule gitlink or a deleted file
        scanned += 1
        for shape in m.shapes(data):
            hits.append(f"{rel}: {shape}")
    for h in sorted(set(hits)):
        print(f"  FAIL [neutrality] {h}")
    if hits:
        print(f"  {len(set(hits))} hit(s) in {scanned} tracked file(s): the private target is named "
              "in a tracked file; replace it with mesh.example / exampleorg")
        return 1
    print(f"  PASS no tracked file names the private target ({scanned} files, "
          f"{len(m.names)} name(s); shapes: plain, utf16, hex, base64, png-text; pixels NOT read)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
