#!/usr/bin/env python3
"""Package resolution report for riscv64 and MIPS (platform expansion, lane X1).

Measures, for every role on riscv64 (with and without SELinux), mips64el and mips64,
whether the role's package set
resolves under Gentoo's own keywords and masks for that arch, and if not, which component
is the first one missing. The committed result is the measured source of every greyed
role reason the catalog gives for those arches:

  docs/catalog/package-resolution-report.json   the data (dated, machine-read by tests)
  docs/PACKAGE-RESOLUTION-RISCV-MIPS.md          the same data as tables, rendered from it

How it measures. Nothing is built and nothing is fetched. Inside the EXISTING builder
image (default hugmesh-builder:latest; no image build, --network none), for each
(arch, role) it assembles a throwaway Portage config root:

  * make.profile is a directory whose `parent` stacks the arch's base profile with
    features/hardened and features/selinux, the stack every hugmesh image carries (the
    riscv64-noselinux variant drops features/selinux and the SELinux packages);
  * ACCEPT_KEYWORDS is "<arch> ~<arch>", so a component counted missing has NO keyword
    for the arch at all (riscv and mips are mostly testing-keyworded; accepting ~arch is
    the most generous reading, so it never invents a gap);
  * USE / POLICY_TYPES come from the reference platform's make.conf.tmpl and its
    package.use and package.mask are copied in, so the resolve sees the same flags the
    real builders use;

and runs a NATIVE resolve of that arch: ROOT=/ under that config, with an empty tmpfs
over /var/db/pkg so nothing counts as installed, so build, run and install time
dependencies all have to resolve under the arch's own keywords and flags:

  emerge --pretend --autounmask=n <the role's atoms>

A role is "resolvable" when that exits 0. Otherwise the report keeps the first component
emerge stopped on and why, every top-level atom with no visible ebuild (read through the
Portage API, with the masking reason of its newest version), and a second resolve with
those atoms removed, which shows the next wall behind them.

Role package sets. riscv64 and MIPS have no builder, so each role's set is the default
install set (essential + removable tiers) of the nearest existing platform's role, from
docs/catalog/packages-catalog.json, minus the board plumbing a riscv/MIPS builder would
replace (PLATFORM_PLUMBING below says what and why). The source of every set is recorded.

Usage:
  scripts/package-resolution-report.py              # docker run + write both files
  scripts/package-resolution-report.py --render     # re-render the .md from the .json
  scripts/package-resolution-report.py --check-catalog
        # exit 1 if a greyed catalog reason on a measured arch cites a component the
        # report does not mark missing (the check studio/tests runs)
  scripts/package-resolution-report.py --probe      # INSIDE the builder: JSON to stdout

IMAGE (env) or --image picks the builder image. On a host with no builder image, run it
where one exists (a build host, or a CI job that has the image); never build one here.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
GEN_ROOT = os.path.dirname(_HERE)
GENERATOR = "scripts/package-resolution-report.py"
REPORT_JSON = os.path.join("docs", "catalog", "package-resolution-report.json")
REPORT_MD = os.path.join("docs", "PACKAGE-RESOLUTION-RISCV-MIPS.md")
DEVICE_CATALOG = os.path.join("studio", "hugmesh_studio", "core", "device-catalog.json")
PACKAGES_CATALOG = os.path.join("docs", "catalog", "packages-catalog.json")
SCHEMA = "package-resolution-report/v1"
DEFAULT_IMAGE = "hugmesh-builder:latest"

GENTOO = "/var/db/repos/gentoo"
STACK = ("features/hardened", "features/selinux")
STACK_NO_SELINUX = ("features/hardened",)

# The measured arches. `catalog_arch` is the catalog arch id a greyed reason is filed
# under; `id` names the measured variant. riscv64 is measured twice: with the stack every
# image carries, and (operator decision 2026-11-12: riscv64 ships labelled "no SELinux")
# without features/selinux, the SELinux policy packages and the SELinux userland.
ARCHES = (
    {"id": "riscv64", "catalog_arch": "riscv64", "label": "RISC-V 64 (rv64, lp64d)",
     "profile": "default/linux/riscv/23.0/rv64/lp64d", "keyword": "riscv",
     "stack": list(STACK), "selinux": True},
    {"id": "riscv64-noselinux", "catalog_arch": "riscv64",
     "label": "RISC-V 64 (rv64, lp64d), shipped without SELinux",
     "profile": "default/linux/riscv/23.0/rv64/lp64d", "keyword": "riscv",
     "stack": list(STACK_NO_SELINUX), "selinux": False},
    {"id": "mips64el", "catalog_arch": "mips64el",
     "label": "MIPS64 little-endian (mipsel, n64)",
     "profile": "default/linux/mips/23.0/mipsel/n64", "keyword": "mips",
     "stack": list(STACK), "selinux": True},
    {"id": "mips64", "catalog_arch": "mips64", "label": "MIPS64 big-endian (n64)",
     "profile": "default/linux/mips/23.0/n64", "keyword": "mips",
     "stack": list(STACK), "selinux": True},
)

# What a no-SELinux variant leaves out of every role set.
SELINUX_USERLAND = ("app-admin/setools", "sys-apps/checkpolicy",
                    "sys-apps/policycoreutils", "sys-apps/semodule-utils",
                    "sys-libs/libselinux", "sys-apps/selinux-python")


def atoms_for(role: dict, arch: dict) -> list[str]:
    """The role's atoms as measured on this arch variant."""
    if arch["selinux"]:
        return list(role["atoms"])
    return [a for a in role["atoms"]
            if not a.startswith("sec-policy/") and a not in SELINUX_USERLAND]

# Every role measured on every arch: (id, what it is, reference platform, reference
# role, tiers taken, extra atoms this role drops from its reference set).
TARGET_ROLES = (
    ("appliance", "headless mesh-client appliance (--desktop none)",
     "frite", "frite", ("essential",),
     ("x11-base/xorg-server", "x11-misc/lightdm", "x11-wm/openbox")),
    ("appliance-light", "mesh-client appliance with the light desktop (--desktop light: "
     "LXDE, lightdm, a browser)", "frite", "frite", ("essential", "removable"), ()),
    ("generic", "generic server node", "rpi5", "generic", ("essential", "removable"), ()),
    ("pki", "PKI node", "rpi5", "pki", ("essential", "removable"), ()),
    ("backend", "backend node", "rpi5", "backend", ("essential", "removable"), ()),
    ("frontend", "frontend node", "rpi5", "frontend", ("essential", "removable"), ()),
    ("omnibus", "omnibus node", "rpi5", "omnibus", ("essential", "removable"), ()),
    ("backend-gpu", "GPU backend node", "x86", "backend-gpu",
     ("essential", "removable"), ()),
    ("edge-ai", "edge-AI node", "x86", "edge-ai", ("essential", "removable"), ()),
)

# Board plumbing of the reference platforms. A riscv/MIPS builder replaces these with
# its own boot chain, so counting them as "missing" would be a false wall. Value: why,
# and the substitute atom measured instead (None = nothing is emerged in its place).
PLATFORM_PLUMBING = {
    "dev-embedded/raspberrypi-utils": ("Raspberry Pi board tool", None),
    "dev-embedded/rpi-eeprom": ("Raspberry Pi bootloader EEPROM", None),
    "sys-boot/raspberrypi-firmware": ("Raspberry Pi GPU firmware boot chain", None),
    "sys-firmware/raspberrypi-wifi-ucode": ("Raspberry Pi Wi-Fi firmware", None),
    "sys-kernel/raspberrypi-sources": ("Raspberry Pi kernel fork",
                                       "sys-kernel/gentoo-sources"),
    "sys-boot/grub": ("x86 boot chain; riscv64 boots OpenSBI + U-Boot, not compiled "
                      "here", None),
    "sys-firmware/intel-microcode": ("x86 CPU microcode", None),
    "app-crypt/efitools": ("Secure Boot chain, x86-only, greyed as its own feature",
                           None),
    "app-crypt/sbsigntools": ("Secure Boot chain, x86-only, greyed as its own feature",
                              None),
}

# Components the design's greyed reasons name beyond the role sets: probed for
# visibility on every arch so a reason that cites them is checkable too.
EXTRA_COMPONENTS = (
    "sys-boot/shim", "net-vpn/tailscale", "net-vpn/headscale", "www-client/firefox",
    "www-client/firefox-bin", "www-client/chromium", "www-client/netsurf",
    "sys-apps/selinux-python", "sec-policy/selinux-base-policy",
)


# ── role sets (host side; pure) ──────────────────────────────────────────────────────


def role_sets(gen_root: str = GEN_ROOT) -> list[dict]:
    """Every target role's atom set, derived from the committed packages catalog."""
    with open(os.path.join(gen_root, PACKAGES_CATALOG), encoding="utf-8") as fh:
        cat = json.load(fh)
    out = []
    for rid, what, plat, ref_role, tiers, role_drops in TARGET_ROLES:
        cell = cat["roles"][plat][ref_role]
        src: list[str] = []
        for tier in tiers:
            src.extend(cell[tier])
        atoms, dropped, substituted = [], [], {}
        for atom in src:
            if atom in role_drops:
                dropped.append({"atom": atom, "why": "not part of this role's desktop axis"})
                continue
            if atom in PLATFORM_PLUMBING:
                why, sub = PLATFORM_PLUMBING[atom]
                dropped.append({"atom": atom, "why": why})
                if sub:
                    substituted[atom] = sub
                    if sub not in atoms and sub not in src:
                        atoms.append(sub)
                continue
            if atom not in atoms:
                atoms.append(atom)
        out.append({
            "id": rid, "what": what,
            "source": {"platform": plat, "role": ref_role, "tiers": list(tiers),
                       "file": PACKAGES_CATALOG},
            "atoms": sorted(atoms), "dropped": dropped, "substituted": substituted,
        })
    return out


# ── probe (inside the builder image) ─────────────────────────────────────────────────


def _make_conf_vars(platform: str) -> dict[str, str]:
    """USE and POLICY_TYPES from the reference platform's make.conf.tmpl, with
    @@PLACEHOLDER@@ tokens dropped and ${USE} expanded."""
    path = os.path.join(GEN_ROOT, f"specs-{platform}", "portage", "make.conf.tmpl")
    use: list[str] = []
    policy = ""
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r'^(USE|POLICY_TYPES)="(.*)"\s*$', line.strip())
            if not m:
                continue
            val = re.sub(r"@@[A-Z_]+@@", "", m.group(2))
            if m.group(1) == "USE":
                toks = val.split()
                if toks and toks[0] == "${USE}":
                    toks = toks[1:]
                else:
                    use = []
                use.extend(toks)
            else:
                policy = val.strip()
    return {"USE": " ".join(use), "POLICY_TYPES": policy}


def _config_root(base: str, arch: dict, platform: str | None) -> str:
    """A throwaway PORTAGE_CONFIGROOT for (arch variant, reference platform)."""
    cfg = os.path.join(base, f"{arch['id']}-{platform or 'bare'}")
    prof = os.path.join(cfg, "etc", "portage", "make.profile")
    os.makedirs(prof, exist_ok=True)
    with open(os.path.join(prof, "parent"), "w", encoding="utf-8") as fh:
        for p in [arch["profile"], *arch["stack"]]:
            fh.write(f"{GENTOO}/profiles/{p}\n")
    kw = arch["keyword"]
    lines = [f'ACCEPT_KEYWORDS="{kw} ~{kw}"', 'ACCEPT_LICENSE="*"']
    if platform:
        mc = _make_conf_vars(platform)
        use = mc["USE"]
        if not arch["selinux"]:
            use = " ".join([t for t in use.split() if t != "selinux"] + ["-selinux"])
        lines.append(f'USE="{use}"')
        if mc["POLICY_TYPES"] and arch["selinux"]:
            lines.append(f'POLICY_TYPES="{mc["POLICY_TYPES"]}"')
        for name_ in ("package.use", "package.mask"):
            src = os.path.join(GEN_ROOT, f"specs-{platform}", "portage", name_)
            dst = os.path.join(cfg, "etc", "portage", name_)
            if os.path.isdir(src):
                shutil.copytree(src, dst, dirs_exist_ok=True)
            elif os.path.isfile(src):
                shutil.copy(src, dst)
    with open(os.path.join(cfg, "etc", "portage", "make.conf"), "w",
              encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    return cfg


def _visibility(cfg: str, root: str, atoms: list[str]) -> dict[str, dict]:
    """Per-atom visibility through the Portage API, in a child process (portage reads
    PORTAGE_CONFIGROOT/ROOT once, at import)."""
    env = dict(os.environ, PORTAGE_CONFIGROOT=cfg, ROOT=root)
    res = subprocess.run([sys.executable, os.path.abspath(__file__), "--visibility"],
                         input=json.dumps(atoms), capture_output=True, text=True,
                         env=env)
    if res.returncode != 0:
        raise SystemExit(f"visibility probe failed under {cfg}:\n{res.stderr[-4000:]}")
    return json.loads(res.stdout)


def _visibility_child() -> int:
    import portage  # noqa: PLC0415 — only exists inside the builder
    atoms = json.load(sys.stdin)
    eroot = portage.settings["EROOT"]
    pdb = portage.db[eroot]["porttree"].dbapi
    settings = portage.config(clone=portage.settings)  # the global one is locked
    out = {}
    for atom in atoms:
        every = pdb.xmatch("match-all", atom)
        if not every:
            out[atom] = {"visible": False, "reason": "no ebuild in the tree"}
            continue
        if pdb.xmatch("match-visible", atom):
            out[atom] = {"visible": True, "reason": ""}
            continue
        released = [c for c in every if not c.endswith("-9999")]
        newest = portage.best(released or every)  # a released version, not live 9999
        why = portage.getmaskingstatus(newest, settings=settings, portdb=pdb,
                                       myrepo="gentoo")
        out[atom] = {"visible": False,
                     "reason": f"{newest}: masked by " + ", ".join(why)}
    json.dump(out, sys.stdout)
    return 0


_RE_MASKED = re.compile(r'^!!! All ebuilds that could satisfy "([^"]+)"( for \S+)?')
_RE_NOEBUILD = re.compile(r'^emerge: there are no ebuilds (built with USE flags )?to '
                          r'satisfy "([^"]+)"( for \S+)?')
_RE_UNMET = re.compile(r'^!!! The ebuild selected to satisfy "([^"]+)"( for \S+)? has '
                       r'unmet')
_RE_MASKLINE = re.compile(r'^- (\S+?)::\S+ \(masked by: ([^)]+)\)')
_RE_REQBY = re.compile(r'^\(dependency required by "([^"]+)"')


def parse_failure(text: str) -> dict:
    """The first component a failed `emerge --pretend` stopped on, and why."""
    lines = [ln.rstrip() for ln in text.splitlines()]
    atom, reason = "", ""
    required_by: list[str] = []
    for i, ln in enumerate(lines):
        m = _RE_MASKED.match(ln)
        if m and not atom:
            atom = m.group(1)
            masked = []
            for nxt in lines[i + 1:]:
                mm = _RE_MASKLINE.match(nxt)
                if mm:
                    masked.append(mm)
                elif masked:
                    break
            # name a released version when there is one, not the live 9999 ebuild
            pick = next((mm for mm in masked if not mm.group(1).endswith("-9999")),
                        masked[0] if masked else None)
            reason = (f"{pick.group(1)}: masked by {pick.group(2)}" if pick
                      else "every ebuild masked")
        m = _RE_NOEBUILD.match(ln)
        if m and not atom:
            atom = m.group(2)
            reason = ("no ebuild with the required USE flags" if m.group(1)
                      else "no ebuild in the tree")
        m = _RE_UNMET.match(ln)
        if m and not atom:
            atom = m.group(1)
            reason = "unmet REQUIRED_USE"
        m = _RE_REQBY.match(ln.strip())
        if m and atom:
            required_by.append(m.group(1))
    if not atom:
        if any("slot conflict" in ln or "Multiple package instances" in ln
               for ln in lines):
            reason = "slot conflict"
        elif any("blocks" in ln and "[blocks" in ln for ln in lines):
            reason = "blocker"
        else:
            bang = [ln for ln in lines if ln.startswith("!!!")]
            reason = "unparsed: " + (bang[0][4:] if bang else "emerge failed")
    return {"atom": atom, "reason": reason, "required_by": required_by[:6]}


def _pretend(cfg: str, root: str, atoms: list[str]) -> dict:
    env = dict(os.environ, PORTAGE_CONFIGROOT=cfg, ROOT=root, NOCOLOR="true")
    cmd = ["emerge", "--pretend", "--autounmask=n", "--color=n", "--nospinner", *atoms]
    res = subprocess.run(cmd, capture_output=True, text=True, env=env)
    return judge(res.returncode, res.stdout + "\n" + res.stderr)


def judge(returncode: int, text: str) -> dict:
    """Resolved or not, from an `emerge --pretend` exit code and output. A run whose
    graph completed (a `Total:` line) and failed ONLY on a circular dependency found
    every component: the cycle is an artefact of resolving from an empty root, which a
    stage3 seed breaks, so it counts as resolved and says so."""
    total = re.search(r"^Total: (\d+) packages", text, re.M)
    n = int(total.group(1)) if total else 0
    if returncode == 0:
        return {"resolved": True, "packages": n, "first_missing": None, "note": ""}
    walls = (_RE_MASKED, _RE_NOEBUILD, _RE_UNMET)
    hit_wall = any(rx.match(ln) for ln in text.splitlines() for rx in walls)
    if total and "circular dependencies" in text and not hit_wall:
        return {"resolved": True, "packages": n, "first_missing": None,
                "note": "only a dependency cycle, which a stage3 seed breaks"}
    return {"resolved": False, "packages": 0, "first_missing": parse_failure(text),
            "note": ""}


def probe() -> dict:
    # The resolve runs as a NATIVE root of the measured arch: ROOT=/ under the arch's
    # config, with nothing installed, so every dependency class (build, run, install
    # time) must resolve under that arch's keywords and flags, which is what Gentoo's
    # keywording policy holds every keyworded package to. A cross resolve
    # (--root-deps=rdeps) would instead send build-time dependencies to the builder's
    # own amd64 root, whose keyword and flag walls are not the arch's. The host side
    # runs the container with an empty tmpfs over /var/db/pkg; refuse anything else,
    # since installed amd64 packages would satisfy dependencies and hide every gap.
    if not (os.path.exists("/.dockerenv") or os.path.exists("/run/.containerenv")):
        raise SystemExit("--probe runs only inside a throwaway builder container")
    if os.listdir("/var/db/pkg"):
        raise SystemExit("--probe needs an empty /var/db/pkg (docker run --tmpfs "
                         "/var/db/pkg); installed packages would hide every gap")
    base = tempfile.mkdtemp(prefix="pkgres-")
    roles = role_sets()
    with open(os.path.join(GENTOO, "metadata", "timestamp.chk"), encoding="utf-8") as fh:
        stamp = fh.read().strip()
    with open(os.path.join(GENTOO, "profiles", "categories"), encoding="utf-8") as fh:
        categories = sorted(ln.strip() for ln in fh if ln.strip())
    ver = subprocess.run(["emerge", "--version"], capture_output=True, text=True).stdout
    cells: dict = {}
    components: dict = {}
    extras = sorted(set(EXTRA_COMPONENTS) | {a for r in roles for a in r["atoms"]})
    for arch in ARCHES:
        print(f"== {arch['id']}", file=sys.stderr)
        cfg = _config_root(base, arch, None)
        components[arch["id"]] = _visibility(cfg, "/", extras)
        cells[arch["id"]] = {}
        for role in roles:
            plat = role["source"]["platform"]
            cfg = _config_root(base, arch, plat)
            root = "/"
            atoms = atoms_for(role, arch)
            vis = _visibility(cfg, root, atoms)
            missing = [{"atom": a, "reason": vis[a]["reason"]}
                       for a in atoms if not vis[a]["visible"]]
            first = _pretend(cfg, root, atoms)
            cell = {"status": "resolvable" if first["resolved"] else "unresolvable",
                    "packages": first["packages"], "note": first["note"],
                    "first_missing": first["first_missing"],
                    "missing_atoms": missing, "residual": None}
            if not first["resolved"] and missing:
                rest = [a for a in atoms if vis[a]["visible"]]
                res2 = _pretend(cfg, root, rest)
                cell["residual"] = {
                    "status": "resolvable" if res2["resolved"] else "unresolvable",
                    "packages": res2["packages"], "note": res2["note"],
                    "first_missing": res2["first_missing"]}
            print(f"   {role['id']}: {cell['status']}"
                  + (f" ({cell['first_missing']['atom']})" if cell["first_missing"]
                     else ""), file=sys.stderr)
            cells[arch["id"]][role["id"]] = cell
    shutil.rmtree(base, ignore_errors=True)
    return {
        "schema": SCHEMA,
        "measured": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d"),
        "generator": GENERATOR,
        "tree": {"timestamp": stamp, "portage": ver.split(" (")[0].strip(),
                 "categories": categories},
        "method": {
            "command": "emerge --pretend --autounmask=n <atoms>",
            "root": "/ as a native root of the measured arch, with nothing installed "
                    "(an empty tmpfs over /var/db/pkg), so build, run and install time "
                    "dependencies all resolve under the arch's own keywords and flags",
            "profile_stack": list(STACK),
            "no_selinux_variant": "features/hardened only, USE=-selinux, and every "
                                  "sec-policy/* atom and " + ", ".join(SELINUX_USERLAND)
                                  + " left out of the role sets",

            "accept_keywords": "<arch> ~<arch>",
            "use": "USE and POLICY_TYPES from the reference platform's make.conf.tmpl; "
                   "its package.use and package.mask copied in",
        },
        "arches": [dict(a) for a in ARCHES],
        "roles": roles,
        "cells": cells,
        "components": components,
    }


# ── the report's "missing" sets and the catalog citation check (pure) ────────────────


def _wall(fm: dict | None) -> str:
    """The atom of a wall that is a MISSING component (masked, or no ebuild at all). A
    flag conflict (no ebuild with the required USE, unmet REQUIRED_USE) names a package
    that exists for the arch, so it is not counted as missing."""
    if not fm or not fm.get("atom"):
        return ""
    reason = fm.get("reason", "")
    return fm["atom"] if ("masked by" in reason or reason == "no ebuild in the tree") \
        else ""


def missing_components(report: dict, catalog_arch: str) -> set[str]:
    """Every component the report marks missing on a catalog arch, in any measured
    variant of it: a role's first wall, the wall behind it, a top-level atom with no
    visible ebuild, or an invisible extra component."""
    out: set[str] = set()
    variants = [a["id"] for a in report["arches"] if a["catalog_arch"] == catalog_arch]
    for vid in variants:
        for cell in report["cells"].get(vid, {}).values():
            out.add(_wall(cell.get("first_missing")))
            out.update(m["atom"] for m in cell.get("missing_atoms", []))
            out.add(_wall((cell.get("residual") or {}).get("first_missing")))
        for atom, vis in report.get("components", {}).get(vid, {}).items():
            if not vis["visible"]:
                out.add(atom)
    out.discard("")
    return {_cp(a) for a in out}


def _cp(atom: str) -> str:
    """category/package of an atom (operators, versions, slots and USE deps stripped)."""
    a = re.sub(r"^[<>=~!]+", "", atom).split(":")[0].split("[")[0]
    m = re.match(r"^([^/]+/.+?)(-[0-9][^/]*)?$", a)
    return m.group(1) if m else a


def cited_components(text: str, categories: set[str]) -> list[str]:
    """The cat/pkg atoms a reason text cites (a token whose category is a real one)."""
    out = []
    for m in re.finditer(r"(?<![\w/.-])([a-z0-9][a-z0-9+_-]*)/([A-Za-z0-9][A-Za-z0-9+_.-]*"
                         r"[A-Za-z0-9+_])", text):
        if m.group(1) in categories:
            out.append(_cp(f"{m.group(1)}/{m.group(2)}"))
    return out


def _reasons(entry: dict):
    """Every reason string an entry carries: `reason` and any nested *reason* value
    (a later lane may file greyed-role reasons as a role -> reason map)."""
    for key, val in entry.items():
        if "reason" not in key:
            continue
        if isinstance(val, str):
            yield key, val
        elif isinstance(val, dict):
            for sub, txt in val.items():
                if isinstance(txt, str):
                    yield f"{key}.{sub}", txt


def catalog_citation_violations(catalog: dict, report: dict) -> list[str]:
    """Greyed catalog reasons on a measured arch that cite a component the report does
    not mark missing. A supported entry is not greyed and is skipped."""
    cats = set(report["tree"]["categories"])
    measured = {a["catalog_arch"] for a in report["arches"]}
    bad = []
    for arch in catalog.get("archs", []):
        if arch.get("id") in measured:
            missing = missing_components(report, arch["id"])
            for atom in cited_components(arch.get("label", ""), cats):
                if atom not in missing:
                    bad.append(f"arch {arch['id']} label cites {atom}, which the report "
                               f"does not mark missing on {arch['id']}")
    for dev in catalog.get("devices", []):
        if dev.get("arch") not in measured or dev.get("status", "supported") == "supported":
            continue
        missing = missing_components(report, dev["arch"])
        for key, text in _reasons(dev):
            for atom in cited_components(text, cats):
                if atom not in missing:
                    bad.append(f"device {dev['id']} {key} cites {atom}, which the report "
                               f"does not mark missing on {dev['arch']}")
    return bad


# ── rendering (pure) ──────────────────────────────────────────────────────────────────


def _fm(fm: dict | None) -> str:
    if not fm:
        return ""
    s = f"`{fm['atom']}` ({fm['reason']})" if fm["atom"] else fm["reason"]
    if fm.get("required_by"):
        s += f", required by `{fm['required_by'][0]}`"
    return s


def render_markdown(report: dict) -> str:
    out = [
        "# Package resolution report: riscv64 and MIPS",
        "",
        f"Measured {report['measured']} by `{report['generator']}` against the Gentoo "
        f"tree of {report['tree']['timestamp']} ({report['tree']['portage']}). "
        f"Generated from `{REPORT_JSON}`; do not edit by hand, re-run the script.",
        "",
        "This is the measured source of every greyed role reason the catalog gives for "
        "riscv64 and MIPS. `studio/tests/test_package_resolution_report.py` fails if a "
        "greyed catalog reason on one of these arches cites a component this report does "
        "not mark missing.",
        "",
        "## Method",
        "",
        f"- Command: `{report['method']['command']}`, with ROOT "
        f"{report['method']['root']}, run inside the existing builder image. Nothing is "
        "built or fetched.",
        "- Profile: the arch's base profile stacked with "
        + " and ".join(f"`{p}`" for p in report["method"]["profile_stack"])
        + ". Gentoo ships no hardened or SELinux profile for these arches, so the stack "
        "is assembled by the project.",
        f"- riscv64 is also measured without SELinux (the operator's 2026-11-12 decision "
        f"ships it labelled \"no SELinux\"): {report['method']['no_selinux_variant']}.",

        f"- Keywords: `{report['method']['accept_keywords']}`. A component counted missing "
        "has no keyword for the arch at all, testing included.",
        f"- Flags: {report['method']['use']}.",
        "- Role package sets: the default install set of the nearest existing platform's "
        "role, minus board plumbing a riscv or MIPS builder replaces (listed below).",
        "- `First missing` is the component `emerge` stopped on. `Missing top-level atoms` "
        "lists every atom of the set with no visible ebuild. `Behind it` is a second "
        "resolve with those atoms removed.",
        "",
        "## Arches",
        "",
        "| Measured | Catalog arch | Base profile | Stacked with | Keywords |",
        "|---|---|---|---|---|",
    ]
    for a in report["arches"]:
        out.append(f"| {a['id']} ({a['label']}) | {a['catalog_arch']} | "
                   f"`{a['profile']}` | {', '.join(f'`{x}`' for x in a['stack'])} | "
                   f"`{a['keyword']} ~{a['keyword']}` |")
    for a in report["arches"]:
        out += ["", f"## {a['id']}", "",
                "| Role | Result | First missing | Missing top-level atoms | Behind it |",
                "|---|---|---|---|---|"]
        for role in report["roles"]:
            cell = report["cells"][a["id"]][role["id"]]
            if cell["status"] == "resolvable":
                result = f"resolvable ({cell['packages']} packages)"
                if cell.get("note"):
                    result += f"; {cell['note']}"
            else:
                result = "unresolvable"
            miss = ", ".join(f"`{m['atom']}`" for m in cell["missing_atoms"]) or "none"
            res = cell.get("residual")
            if res is None:
                behind = ""
            elif res["status"] == "resolvable":
                behind = f"resolvable ({res['packages']} packages)"
                if res.get("note"):
                    behind += f"; {res['note']}"
            else:
                behind = _fm(res["first_missing"])
            out.append(f"| {role['id']} | {result} | {_fm(cell['first_missing'])} | "
                       f"{miss} | {behind} |")
        comp = report["components"][a["id"]]
        gone = [f"`{k}` ({v['reason']})" for k, v in sorted(comp.items())
                if not v["visible"]]
        out += ["", f"Components with no visible ebuild on {a['id']}: "
                + ("; ".join(gone) if gone else "none") + "."]
    out += ["", "## Role package sets", "",
            "| Role | What | Source | Atoms | Dropped (why) |", "|---|---|---|---|---|"]
    for role in report["roles"]:
        src = role["source"]
        dropped = "; ".join(f"`{d['atom']}` ({d['why']})" for d in role["dropped"]) or "none"
        if role["substituted"]:
            dropped += "; substituted: " + ", ".join(
                f"`{k}` by `{v}`" for k, v in sorted(role["substituted"].items()))
        out.append(f"| {role['id']} | {role['what']} | {src['platform']} "
                   f"{src['role']} ({' + '.join(src['tiers'])}) | {len(role['atoms'])} | "
                   f"{dropped} |")
    out += ["", "## Re-running it", "",
            "```sh",
            "scripts/package-resolution-report.py            # needs the builder image",
            "scripts/package-resolution-report.py --render   # .md from the .json only",
            "scripts/package-resolution-report.py --check-catalog",
            "```", ""]
    return "\n".join(out)


# ── host side ─────────────────────────────────────────────────────────────────────────


def _load(rel: str) -> dict:
    with open(os.path.join(GEN_ROOT, rel), encoding="utf-8") as fh:
        return json.load(fh)


def _write_md(report: dict) -> None:
    with open(os.path.join(GEN_ROOT, REPORT_MD), "w", encoding="utf-8") as fh:
        fh.write(render_markdown(report))


def run_in_builder(image: str) -> dict:
    image_id = subprocess.run(["docker", "image", "inspect", "--format", "{{.Id}}", image],
                              capture_output=True, text=True, check=True).stdout.strip()
    res = subprocess.run(
        ["docker", "run", "--rm", "--network", "none", "--tmpfs", "/var/db/pkg",
         "-v", f"{GEN_ROOT}:/src:ro",
         "-w", "/src", image, "python3", f"/src/{GENERATOR}", "--probe"],
        stdout=subprocess.PIPE, check=True, text=True)
    report = json.loads(res.stdout)
    report["image"] = {"name": image, "id": image_id}
    return report


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", default=os.environ.get("IMAGE") or DEFAULT_IMAGE)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--probe", action="store_true", help=argparse.SUPPRESS)
    mode.add_argument("--visibility", action="store_true", help=argparse.SUPPRESS)
    mode.add_argument("--render", action="store_true")
    mode.add_argument("--check-catalog", action="store_true")
    args = ap.parse_args(argv)
    if args.visibility:
        return _visibility_child()
    if args.probe:
        json.dump(probe(), sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    if args.render:
        _write_md(_load(REPORT_JSON))
        print(f"wrote {REPORT_MD}")
        return 0
    if args.check_catalog:
        bad = catalog_citation_violations(_load(DEVICE_CATALOG), _load(REPORT_JSON))
        for b in bad:
            print(f"FAIL: {b}", file=sys.stderr)
        return 1 if bad else 0
    report = run_in_builder(args.image)
    with open(os.path.join(GEN_ROOT, REPORT_JSON), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, sort_keys=True)
        fh.write("\n")
    _write_md(report)
    print(f"wrote {REPORT_JSON} and {REPORT_MD}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
