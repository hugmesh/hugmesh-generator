#!/usr/bin/env python3
"""Emit ``packages-catalog.json`` from the generator's package lists (design 2.8).

The Studio parses the ``specs-<platform>/portage/packages*.list`` files LIVE, so it can
never drift from the tree; the WEB (admin-ui via admin-bff) needs a checked-in copy the
image-gen container bakes and serves. This script regenerates that copy. A CI drift test
re-runs it and diffs the committed file, so a list-file edit that isn't re-emitted fails.

Deterministic output (sorted dict keys; list/section/atom ORDER preserved from the files).
Run from anywhere; defaults to this repo's tree and ``docs/catalog/packages-catalog.json``.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_GEN_ROOT = os.path.dirname(_HERE)                       # scripts/ -> repo root
sys.path.insert(0, os.path.join(_GEN_ROOT, "studio"))

from snapdragon_studio.core.package_catalog import build_catalog  # noqa: E402

DEFAULT_OUT = os.path.join("docs", "catalog", "packages-catalog.json")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--generator-dir", default=_GEN_ROOT,
                    help="generator repo root (default: this checkout)")
    ap.add_argument("--out", default=None,
                    help=f"output path (default: <generator-dir>/{DEFAULT_OUT})")
    args = ap.parse_args(argv)

    catalog = build_catalog(args.generator_dir)
    out = args.out or os.path.join(args.generator_dir, DEFAULT_OUT)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(catalog, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
