#!/usr/bin/env python3
"""Emit ``image-catalog.json`` — the role x platform build grammar (design 2.8 / 7.3).

ROLE_CHOICES (per Studio mode) + the board/flavor/desktop axes + the role-class table are
the single source of truth for WHAT images can be built. The Studio reads them from
core/config directly; the admin-ui must serve the SAME grammar so its worklist multi-select
offers only valid role x platform tokens (replacing the free-text hardwareClass input) and
computes the SAME branding/home/tailnet predicates from image_class + mode.

This kills the three-way Studio / build-image.sh / admin-ui role-catalog drift. Deterministic
output; run from anywhere. A CI drift test re-runs it and diffs the committed copy.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_GEN_ROOT = os.path.dirname(_HERE)                       # scripts/ -> repo root
sys.path.insert(0, os.path.join(_GEN_ROOT, "studio"))

from snapdragon_studio.core.config import (  # noqa: E402
    DESKTOP_ROLES, FRITE_BOARDS, FRITE_DESKTOPS, FRITE_FLAVORS, JETSON_BOARDS, NODE_ROLES,
    ORANGEPI5_BOARDS, ORANGEPI5_FLAVORS, ORANGEPIZERO2_FLAVORS, PLATFORM_LABELS, RPI_BOARDS,
    ROLE_CHOICES, image_class,
)

DEFAULT_OUT = os.path.join("docs", "catalog", "image-catalog.json")


def platform_axes(platform: str) -> dict:
    """The board / flavor / desktop axes a platform exposes (empty where it has none)."""
    axes: dict[str, list[str]] = {}
    if platform == "x86":
        axes["desktop"] = ["thin", "full"]
    elif platform == "rpi5":
        axes["board"] = list(RPI_BOARDS)
    elif platform == "jetson":
        axes["board"] = list(JETSON_BOARDS)
    elif platform == "frite":
        axes["board"] = list(FRITE_BOARDS)
        axes["flavor"] = list(FRITE_FLAVORS)
        axes["desktop"] = list(FRITE_DESKTOPS)
    elif platform == "orangepi5":
        axes["board"] = list(ORANGEPI5_BOARDS)
        axes["flavor"] = list(ORANGEPI5_FLAVORS)
    elif platform == "orangepizero2":
        axes["flavor"] = list(ORANGEPIZERO2_FLAVORS)
    return axes


def build_image_catalog() -> dict:
    roles: dict[str, list[dict]] = {}
    for mode, choices in ROLE_CHOICES.items():
        roles[mode] = [
            {
                "role": role,
                "label": label,
                "image_class": image_class(mode, role),
                "platforms": [{"platform": p, "axes": platform_axes(p)} for p in platforms],
            }
            for (role, platforms, label) in choices
        ]
    return {
        "roles": roles,
        "platform_labels": dict(PLATFORM_LABELS),
        "role_class": {"desktop": list(DESKTOP_ROLES), "node": list(NODE_ROLES)},
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--generator-dir", default=_GEN_ROOT,
                    help="generator repo root (default: this checkout)")
    ap.add_argument("--out", default=None,
                    help=f"output path (default: <generator-dir>/{DEFAULT_OUT})")
    args = ap.parse_args(argv)

    catalog = build_image_catalog()
    out = args.out or os.path.join(args.generator_dir, DEFAULT_OUT)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(catalog, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
