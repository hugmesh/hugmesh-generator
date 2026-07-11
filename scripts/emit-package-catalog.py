#!/usr/bin/env python3
"""Emit ``packages-catalog.json`` from the generator's package lists (design 2.8).

The Studio parses the ``specs-<platform>/portage/packages*.list`` files LIVE, so it can
never drift from the tree; the WEB (admin-ui via admin-bff) needs a checked-in copy the
image-gen container bakes and serves. This script regenerates that copy. A CI drift test
re-runs it and diffs the committed file, so a list-file edit that isn't re-emitted fails.

Besides the raw list tree (``platforms``) and the option->atoms map (``adhoc_adds``,
both byte-compatible with the pre-roles schema), the catalog carries ``roles``: the
per-platform role->{essential, removable, available} DEFAULT-OPTIONS tier baseline
(no adhoc options enabled — the UI layers option atoms client-side from adhoc_adds;
see ``roles_doc`` in the emitted file). Cells come from ROLE_CHOICES, the same grammar
image-catalog.json serves. The emitted map is invariant-checked before writing
(essential is a subset of the default set, tiers disjoint/sorted, exact cell coverage)
— any violation aborts the emit loudly.

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

from snapdragon_studio.core.package_catalog import (  # noqa: E402
    build_catalog, validate_roles_tiers,
)

DEFAULT_OUT = os.path.join("docs", "catalog", "packages-catalog.json")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--generator-dir", default=_GEN_ROOT,
                    help="generator repo root (default: this checkout)")
    ap.add_argument("--out", default=None,
                    help=f"output path (default: <generator-dir>/{DEFAULT_OUT})")
    args = ap.parse_args(argv)

    catalog = build_catalog(args.generator_dir)
    # fail LOUD before writing: essential_floor ⊆ default_set + the partition/coverage
    # invariants must hold in the data we are about to commit (raises ValueError).
    validate_roles_tiers(args.generator_dir, catalog["roles"])
    out = args.out or os.path.join(args.generator_dir, DEFAULT_OUT)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(catalog, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
