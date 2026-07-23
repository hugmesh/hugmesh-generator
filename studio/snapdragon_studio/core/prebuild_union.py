"""Headless role-UNION feed for the shared-binpkg prebuild phase (Lane 4b).

``python3 -m snapdragon_studio.core.prebuild_union <platform>`` prints, one atom per
line (sorted), the UNION of every role's default package set for that platform — the
seed list a ``make prebuild-binaries ARCH=<platform>`` run hands the builder via
``--packages-only --seed-packages-from <list>`` so the per-board binpkg pool is
compiled ONCE and then reused (``--usepkg``) across every per-role image build.

This is Qt-free by construction (it imports only ``package_catalog`` /  ``config``,
no ``PySide6``), so it runs in the same headless context as ``local_mesh``'s module
face and in CI. It adds NO package-resolution logic of its own: the union is
``set().union`` over the EXISTING ``package_catalog.default_set`` applied to the
EXISTING ``default_cell_config`` for every ``(platform, role)`` cell ``role_cells``
enumerates from ``ROLE_CHOICES`` — the same canonical cell iteration ``roles_tiers`` /
``validate_roles_tiers`` use, so it can never drift from what the builders emerge.

NOTE (honest scope): this is the ROLE union (base list + role-gated lists such as
k8s / desktop / gpu). ADHOC_ADDS options that are default-OFF (tor, egress, extra
pam) are not forced on here — a later per-role image build still compiles any such
extra atoms on top of the prebuilt pool (reusing it via --usepkg). Maximizing pool
reuse further would mean enabling options, which is a policy choice left to the
operator; the union stays the honest role baseline with no invented resolution.
"""
from __future__ import annotations

import argparse
import os
import sys

from .package_catalog import default_cell_config, default_set, role_cells

# core/ -> snapdragon_studio/ -> studio/ -> generator repo root (mirrors local_mesh._REPO_ROOT).
_REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, os.pardir))


def platform_roles(platform: str) -> list[str]:
    """Every role ROLE_CHOICES offers on ``platform`` (sorted, de-duplicated)."""
    return sorted({role for (p, role) in role_cells() if p == platform})


def union_atoms(generator_dir: str, platform: str) -> set[str]:
    """Union of ``default_set`` over every ``(platform, role)`` cell for one platform.

    Uses ``default_cell_config`` (the canonical DEFAULT-OPTIONS config builder shared
    with ``roles_tiers``) so no resolution logic is duplicated. ``role_cells`` maps a
    cell to the modes offering it; the role tier is mode-invariant (asserted by
    ``roles_tiers``), so the first mode is sufficient to build the config."""
    atoms: set[str] = set()
    for (p, role), modes in role_cells().items():
        if p != platform:
            continue
        cfg = default_cell_config(modes[0], role, platform)
        atoms |= default_set(generator_dir, cfg)
    return atoms


def known_platforms() -> list[str]:
    return sorted({p for (p, _role) in role_cells()})


def main(argv: list[str] | None = None) -> int:
    platforms = known_platforms()
    p = argparse.ArgumentParser(
        prog="python3 -m snapdragon_studio.core.prebuild_union",
        description="Print the role-union atom list for a platform's shared-binpkg prebuild.")
    p.add_argument("platform", choices=platforms,
                   help="platform id (one of: %(choices)s)")
    p.add_argument("--generator-dir", default=_REPO_ROOT,
                   help="generator repo root (default: this checkout)")
    p.add_argument("--list-roles", action="store_true",
                   help="print the contributing roles to stderr (diagnostic)")
    args = p.parse_args(argv)

    if args.list_roles:
        print(f"# {args.platform} roles: {', '.join(platform_roles(args.platform))}",
              file=sys.stderr)

    atoms = union_atoms(args.generator_dir, args.platform)
    if not atoms:
        print(f"prebuild_union: no atoms resolved for platform '{args.platform}'",
              file=sys.stderr)
        return 1
    for atom in sorted(atoms):
        print(atom)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
