#!/usr/bin/env python3
"""Fail if the rendered application icon has no letter in it.

gen_icons.py draws the mark with Qt. Under Qt's ``offscreen`` platform there are no
fonts, so the "S" comes out as an empty box and an installer built from it would carry
a blank icon. An empty box has about 0 white pixels in the middle of the 256px icon, a
bold sans "S" several thousand (build-msi-wine.sh applies the same guard under Wine).

    python packaging/check_icon.py build/icons/icon-256.png
"""
from __future__ import annotations

import sys

MIN_WHITE = 1000


def white_centre(path: str) -> int:
    from PIL import Image

    im = Image.open(path).convert("RGBA")
    w, h = im.size
    px = im.load()
    return sum(
        1
        for x in range(int(w * 0.3), int(w * 0.7))
        for y in range(int(h * 0.3), int(h * 0.7))
        if px[x, y][3] > 200 and min(px[x, y][:3]) > 200
    )


def main(argv: list[str]) -> int:
    path = argv[1] if len(argv) > 1 else "build/icons/icon-256.png"
    white = white_centre(path)
    print(f"white pixels in the centre of {path}: {white} (need more than {MIN_WHITE})")
    return 0 if white > MIN_WHITE else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
