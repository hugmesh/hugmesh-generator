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

from hugmesh_studio.core import device_catalog  # noqa: E402
from hugmesh_studio.core.config import (  # noqa: E402
    DESKTOP_ROLES, FRITE_BOARDS, FRITE_DESKTOPS, FRITE_FLAVORS, JETSON_BOARDS, NODE_ROLES,
    ORANGEPI5_BOARDS, ORANGEPI5_FLAVORS, ORANGEPIZERO2_FLAVORS, ORANGEPIZERO2W_FLAVORS,
    ORANGEPIZERO3_FLAVORS, ORANGEPI3LTS_FLAVORS, ORANGEPI4LTS_FLAVORS,
    PLATFORM_LABELS, ROLE_CHOICES, image_class, orangepi_flavors_for_role,
    rpi_boards_for_role, x86_desktop_axis,
)

DEFAULT_OUT = os.path.join("docs", "catalog", "image-catalog.json")


def platform_axes(platform: str, role: str) -> dict:
    """The board / flavor / desktop axes a platform exposes (empty where it has none).

    The rpi5 board axis is ROLE-DEPENDENT: rpi3 (1GB RAM) is desktop-only and
    build-rpi5-stage4.sh hard-errors a non-desktop role on --board rpi3, so a node role
    must expose only rpi5/rpi4. We defer to rpi_boards_for_role(role) — the SAME predicate
    the Studio GUI RolePage/WorklistPage use — so the machine-readable catalog the admin-ui
    worklist multi-select consumes never offers a board/role combo that dead-ends in that
    hard-error (honesty rule; mirrors the GUI gating in the web modal).

    The x86 desktop axis is ROLE-DEPENDENT for the same honesty reason (the
    16-phantom inventory audit): client roles take thin|full, weight-pinning
    standalone roles take only their own weight, and cluster node roles have NO
    desktop axis at all (a headless k8s server has no desktop — the builder plans
    DESKTOP=none). x86_desktop_axis(role) is the shared predicate."""
    axes: dict[str, list[str]] = {}
    if platform == "x86":
        weights = x86_desktop_axis(role)
        if weights:
            axes["desktop"] = list(weights)
    elif platform == "rpi5":
        axes["board"] = list(rpi_boards_for_role(role))
    elif platform == "jetson":
        axes["board"] = list(JETSON_BOARDS)
    elif platform == "frite":
        axes["board"] = list(FRITE_BOARDS)
        axes["flavor"] = list(FRITE_FLAVORS)
        axes["desktop"] = list(FRITE_DESKTOPS)
    elif platform == "orangepi5":
        # a cluster NODE role is installer-only (orangepi_flavors_for_role)
        axes["board"] = list(ORANGEPI5_BOARDS)
        axes["flavor"] = list(orangepi_flavors_for_role(platform, role))
    elif platform == "orangepizero2":
        axes["flavor"] = list(ORANGEPIZERO2_FLAVORS)
    elif platform == "orangepizero2w":
        axes["flavor"] = list(ORANGEPIZERO2W_FLAVORS)
    elif platform == "orangepizero3":
        axes["flavor"] = list(ORANGEPIZERO3_FLAVORS)
    elif platform == "orangepi3-lts":
        axes["flavor"] = list(ORANGEPI3LTS_FLAVORS)
    elif platform == "orangepi4-lts":
        axes["flavor"] = list(orangepi_flavors_for_role(platform, role))
    return axes


def device_entry(dev: "device_catalog.Device") -> dict:
    """One web-catalog device: the arch/family/status taxonomy plus the DERIVED
    per-mode role lists and the exact cfg axes selecting it writes. The #351 honesty
    statuses ride through verbatim: an UNSUPPORTED device serializes with NO
    config_axes and NO roles — visible in the modal, never selectable for a build
    (the CAT bucket pins this)."""
    entry = {
        "id": dev.id,
        "label": dev.label,
        "family": dev.family,
        "arch": dev.arch,
        "soc": dev.soc,
        "status": dev.status,
        "reason": dev.reason,
        "notes": dev.notes,
    }
    if dev.status in device_catalog.SELECTABLE_STATUSES:
        entry["config_axes"] = device_catalog.config_axes(dev.id)
        entry["roles"] = {
            mode: [{"role": r, "label": l}
                   for r, l in device_catalog.roles_for(dev.id, mode)]
            for mode in ROLE_CHOICES
        }
    else:
        entry["config_axes"] = None
        entry["roles"] = {}
    return entry


def build_image_catalog() -> dict:
    roles: dict[str, list[dict]] = {}
    for mode, choices in ROLE_CHOICES.items():
        roles[mode] = [
            {
                "role": role,
                "label": label,
                "image_class": image_class(mode, role),
                "platforms": [{"platform": p, "axes": platform_axes(p, role)} for p in platforms],
            }
            for (role, platforms, label) in choices
        ]
    # The arch -> family -> device hierarchy (ADDITIVE keys — the existing
    # roles/platform_labels/role_class grammar is untouched): generated from
    # core/device_catalog, whose role derivation is the SAME ROLE_CHOICES +
    # rpi_boards_for_role predicates used above, so the two views cannot drift.
    cat = device_catalog.load_catalog()
    return {
        "roles": roles,
        "platform_labels": dict(PLATFORM_LABELS),
        "role_class": {"desktop": list(DESKTOP_ROLES), "node": list(NODE_ROLES)},
        "archs": [{"id": a.id, "label": a.label} for a in cat.archs],
        "families": [{"id": f.id, "label": f.label, "vendor": f.vendor, "arch": f.arch}
                     for f in cat.families],
        "devices": [device_entry(d) for d in cat.devices],
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
