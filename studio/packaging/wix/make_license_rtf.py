#!/usr/bin/env python3
"""Convert the repository LICENSE into the RTF that the MSI's licence page shows.

Generated rather than committed so there is ONE licence text in the repo. A
hand-converted RTF is a second copy that silently stops matching the first the day
anybody edits LICENSE, and the copy people legally agree to during installation is
exactly the wrong one to let drift.

    python packaging/wix/make_license_rtf.py --in LICENSE --out build/License.rtf
"""
from __future__ import annotations

import argparse
import os


def to_rtf(text: str) -> str:
    """Wrap plain text as RTF 1.0.

    RTF's escapes are minimal but mandatory: a literal backslash or brace is a
    control character, and a non-ASCII byte must be a \\u escape or the reader shows
    mojibake (the MIT text is ASCII, but a licence file is not guaranteed to be).
    """
    out = []
    for ch in text:
        if ch in "\\{}":
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\par\n")
        elif ord(ch) > 127:
            # RTF \u takes a SIGNED 16-bit code unit, then an ASCII fallback char.
            code = ord(ch)
            out.append(f"\\u{code if code < 32768 else code - 65536}?")
        else:
            out.append(ch)
    body = "".join(out)
    return (
        "{\\rtf1\\ansi\\ansicpg1252\\deff0"
        "{\\fonttbl{\\f0\\fnil\\fcharset0 Segoe UI;}}"
        "\\viewkind4\\uc1\\pard\\f0\\fs18\n"
        f"{body}"
        "}\n"
    )


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", default="LICENSE")
    ap.add_argument("--out", dest="dest", default="build/License.rtf")
    args = ap.parse_args(argv)

    with open(args.src, "r", encoding="utf-8") as fh:
        text = fh.read()

    os.makedirs(os.path.dirname(os.path.abspath(args.dest)), exist_ok=True)
    with open(args.dest, "w", encoding="ascii") as fh:
        fh.write(to_rtf(text))
    print(f"{args.dest}  ({os.path.getsize(args.dest)} bytes) from {args.src}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
