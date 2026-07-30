#!/usr/bin/env python3
"""Reproduce the USE_EXPAND stacking measurement in docs/PYTHON-TARGETS-SEED-DRIFT.md §1.3.

Builds throwaway PORTAGE_CONFIGROOTs against the host's real gentoo profile and
prints the EFFECTIVE PYTHON_TARGETS / PYTHON_SINGLE_TARGET for each, showing that

  * a USE_EXPAND variable ASSIGNED in make.conf REPLACES the profile default, and
  * the same value expressed as a package.use `*/* PYTHON_TARGETS:` line ADDS to it.

Read-only and offline: it instantiates portage.package.ebuild.config against
temporary config roots. It runs NO emerge, fetches nothing, needs no root, and
never writes outside its own tempdir.

Usage:  python3 tests/scripts/python-targets-semantics-probe.py
Exit:   0 on success, 77 (skip) when no local gentoo profile / portage module is
        available — this is a diagnostic probe, not a gate.
"""

from __future__ import annotations

import glob
import os
import shutil
import sys
import tempfile

SKIP = 77

PROFILE_CANDIDATES = (
    "/var/db/repos/gentoo/profiles/default/linux/amd64/23.0",
    "/var/db/repos/gentoo/profiles/default/linux/amd64/23.0/hardened",
    "/usr/portage/profiles/default/linux/amd64/23.0",
)

MAKE_CONF_BASE = 'CHOST="x86_64-pc-linux-gnu"\nACCEPT_KEYWORDS="amd64"\n'
PKGUSE_LINE = "*/* PYTHON_TARGETS: python3_12\n"


def find_profile() -> str | None:
    for cand in PROFILE_CANDIDATES:
        if os.path.isdir(cand):
            return cand
    hits = sorted(glob.glob("/var/db/repos/*/profiles/default/linux/amd64/*"))
    return hits[-1] if hits else None


def import_portage():
    """Import portage from whichever site-packages actually ships it."""
    try:
        import portage  # noqa: F401

        from portage.package.ebuild.config import config

        return config
    except ImportError:
        pass
    for sp in sorted(glob.glob("/usr/lib/python3.*/site-packages")):
        if os.path.isdir(os.path.join(sp, "portage")):
            sys.path.insert(0, sp)
            try:
                from portage.package.ebuild.config import config

                return config
            except ImportError:
                sys.path.pop(0)
    return None


def make_root(tmp: str, name: str, profile: str, make_conf_extra="", pkg_use=None) -> str:
    root = os.path.join(tmp, name)
    etc = os.path.join(root, "etc", "portage")
    os.makedirs(etc, exist_ok=True)
    os.symlink(profile, os.path.join(etc, "make.profile"))
    with open(os.path.join(etc, "make.conf"), "w") as fh:
        fh.write(MAKE_CONF_BASE + make_conf_extra)
    if pkg_use is not None:
        os.makedirs(os.path.join(etc, "package.use"), exist_ok=True)
        with open(os.path.join(etc, "package.use", "python-targets"), "w") as fh:
            fh.write(pkg_use)
    return root


def report(config_cls, root: str, label: str) -> tuple[str, str]:
    cfg = config_cls(config_root=root, target_root="/", sysroot="/", eprefix="", env={})
    pt = cfg.get("PYTHON_TARGETS", "")
    pst = cfg.get("PYTHON_SINGLE_TARGET", "")
    use = set(cfg.get("USE", "").split())
    flags = " ".join(sorted(x for x in use if x.startswith("python_targets_"))) or "(none)"
    print(f"--- {label}")
    print(f"    PYTHON_TARGETS       = {pt!r}")
    print(f"    PYTHON_SINGLE_TARGET = {pst!r}")
    print(f"    USE python_targets_* = {flags}")
    return pt, pst


def main() -> int:
    config_cls = import_portage()
    if config_cls is None:
        print("SKIP: portage python module not importable on this host")
        return SKIP
    profile = find_profile()
    if profile is None:
        print("SKIP: no local gentoo profile found under /var/db/repos")
        return SKIP

    print(f"profile under test: {profile}\n")
    tmp = tempfile.mkdtemp(prefix="pt-semantics-")
    try:
        a = make_root(tmp, "A-profile-only", profile)
        b = make_root(
            tmp,
            "B-makeconf",
            profile,
            make_conf_extra='PYTHON_TARGETS="python3_12"\nPYTHON_SINGLE_TARGET="python3_12"\n',
        )
        c = make_root(tmp, "C-pkguse", profile, pkg_use=PKGUSE_LINE)
        d = make_root(
            tmp,
            "D-both",
            profile,
            make_conf_extra='PYTHON_TARGETS="python3_12"\nPYTHON_SINGLE_TARGET="python3_12"\n',
            pkg_use=PKGUSE_LINE,
        )

        pt_a, _ = report(config_cls, a, "A. profile only")
        pt_b, _ = report(config_cls, b, 'B. make.conf PYTHON_TARGETS="python3_12"')
        pt_c, _ = report(config_cls, c, "C. package.use '*/* PYTHON_TARGETS: python3_12'")
        pt_d, _ = report(config_cls, d, "D. BOTH (what specs-*/ ship today)")

        profile_targets = set(pt_a.split())
        print()
        rc = 0
        if set(pt_b.split()) == {"python3_12"} and profile_targets - {"python3_12"}:
            print("PASS  make.conf assignment REPLACES the profile default")
        else:
            print(f"FAIL  expected make.conf to replace {pt_a!r}, got {pt_b!r}")
            rc = 1
        if profile_targets <= set(pt_c.split()) and "python3_12" in pt_c.split():
            print("PASS  package.use USE_EXPAND line ADDS to the profile default")
        else:
            print(f"FAIL  expected package.use to widen {pt_a!r}, got {pt_c!r}")
            rc = 1
        if set(pt_d.split()) == set(pt_b.split()):
            print("PASS  with both set, make.conf wins — the package.use widening is inert")
        else:
            print(f"FAIL  expected D to equal B ({pt_b!r}), got {pt_d!r}")
            rc = 1
        return rc
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
