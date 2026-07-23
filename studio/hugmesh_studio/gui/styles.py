"""Shared semantic colours for inline label styling.

The GUI grew ~36 ad-hoc ``setStyleSheet("color: …")`` calls with three different
conventions (``gray`` / ``#888888`` / ``#a65d00``). ``gray`` (#808080) in particular
goes near-invisible on some dark system palettes. These few constants give one name per
intent; the values are the cross-theme compromise that stays legible on BOTH a light and
a dark background (a single fixed colour can't be optimal for both, but a mid-tone is
readable on either — the same reason editors default secondary text to a mid grey).
"""
from __future__ import annotations

MUTED = "#8a8a8a"   # secondary / help / description text
WARN = "#c2410c"    # a degraded-but-usable state that needs attention
ERROR = "#c5221f"   # a hard failure (matches the tray/progress red)


def muted() -> str:
    """``color:`` style-sheet fragment for muted secondary text."""
    return f"color: {MUTED};"
