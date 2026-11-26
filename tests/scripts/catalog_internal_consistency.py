#!/usr/bin/env python3
"""catalog_internal_consistency.py ROOT — generator-side catalog agreement.

Run by tests/scripts/test-catalog-internal-consistency.sh (on the real tree, then
on mutated copies that must fail). Stdlib only. Prints one PASS/FAIL line per
check, tagged, and exits 1 if any check failed, 2 if the tree could not be read.

WHAT THIS IS NOT. hugmesh-admin-bff-api vendors a copy of docs/catalog/image-catalog.json
and docs/catalog/packages-catalog.json and compares ITS copies against this repo's
originals (ImageCatalogDriftTest, in that repo — see docs/RELEASING.md and CLAUDE.md
"Order matters" / "CI facts"). That cross-repo comparison cannot run here: this repo
has no checkout of admin-bff. What CAN run here, and is worth running on every pull
request, is that the two catalogs THIS repo owns agree with EACH OTHER before either
is ever vendored anywhere:

  [platform-set]   packages-catalog.json's top-level "platforms" keys are exactly
                    the "platform" config_axis values image-catalog.json's "devices"
                    entries carry (a device with no config_axes is a planned/not-yet-
                    supported board and is excluded on both sides).
  [role-set]       the role ids packages-catalog.json names (across every platform's
                    "roles" map) are exactly the role ids image-catalog.json names
                    (across its cloud/mesh/standalone role lists).
  [role-per-platform] for EACH platform, the role ids packages-catalog.json lists
                    under that platform equal the role ids image-catalog.json's
                    devices for that platform actually offer. A role dropped from
                    one catalog's platform entry but not the other is exactly the
                    drift a vendored-copy diff in admin-bff would otherwise be the
                    only thing to notice, and only after a vendor-and-compare cycle.

A real ImageCatalogDriftTest failure in admin-bff still needs a person to re-vendor
the catalog there (CLAUDE.md "CI facts"); this guard only keeps the generator's own
two catalogs from disagreeing before that vendoring ever happens.
"""
import json
import os
import sys

P = [0]
F = [0]


def ok(tag, msg):
    print("  PASS [%s] %s" % (tag, msg))
    P[0] += 1


def fail(tag, msg):
    print("  FAIL [%s] %s" % (tag, msg))
    F[0] += 1


def load(root, rel):
    path = os.path.join(root, rel)
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def device_platforms(img):
    """platform -> set of role ids that platform's devices offer (unioned)."""
    out = {}
    for d in img.get("devices", []):
        axes = d.get("config_axes")
        if not axes or not axes.get("platform"):
            continue
        plat = axes["platform"]
        roles = out.setdefault(plat, set())
        for _cat, lst in (d.get("roles") or {}).items():
            for r in lst:
                if "role" in r:
                    roles.add(r["role"])
    return out


def main():
    if len(sys.argv) != 2:
        print("usage: catalog_internal_consistency.py ROOT", file=sys.stderr)
        return 2
    root = sys.argv[1]

    try:
        img = load(root, "docs/catalog/image-catalog.json")
        pkg = load(root, "docs/catalog/packages-catalog.json")
    except (OSError, ValueError) as exc:
        print("FATAL: could not read a catalog file: %s" % exc, file=sys.stderr)
        return 2

    plat_roles = device_platforms(img)
    img_platforms = set(plat_roles.keys())
    pkg_platforms = set(pkg.get("platforms", {}).keys())

    if img_platforms == pkg_platforms:
        ok("platform-set", "%d platforms agree between the two catalogs" % len(img_platforms))
    else:
        fail(
            "platform-set",
            "image-catalog.json-only: %s; packages-catalog.json-only: %s"
            % (sorted(img_platforms - pkg_platforms), sorted(pkg_platforms - img_platforms)),
        )

    img_role_names = set()
    for _cat, lst in img.get("roles", {}).items():
        for r in lst:
            if "role" in r:
                img_role_names.add(r["role"])

    pkg_roles_by_platform = pkg.get("roles", {})
    pkg_role_names = set()
    for _plat, roles in pkg_roles_by_platform.items():
        pkg_role_names.update(roles.keys())

    if img_role_names == pkg_role_names:
        ok("role-set", "%d role ids agree between the two catalogs" % len(img_role_names))
    else:
        fail(
            "role-set",
            "image-catalog.json-only: %s; packages-catalog.json-only: %s"
            % (sorted(img_role_names - pkg_role_names), sorted(pkg_role_names - img_role_names)),
        )

    mismatches = []
    for plat in sorted(pkg_platforms | img_platforms):
        img_set = plat_roles.get(plat, set())
        pkg_set = set(pkg_roles_by_platform.get(plat, {}).keys())
        if img_set != pkg_set:
            mismatches.append(
                "%s (image-catalog.json-only: %s; packages-catalog.json-only: %s)"
                % (plat, sorted(img_set - pkg_set), sorted(pkg_set - img_set))
            )
    if mismatches:
        fail("role-per-platform", "; ".join(mismatches))
    else:
        ok("role-per-platform", "every platform's role set agrees between the two catalogs")

    print()
    print("== catalog-internal-consistency: %d passed, %d failed ==" % (P[0], F[0]))
    return 1 if F[0] else 0


if __name__ == "__main__":
    sys.exit(main())
