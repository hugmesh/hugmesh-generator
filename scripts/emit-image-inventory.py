#!/usr/bin/env python3
"""Emit ``image-inventory.json`` — the FULL advertised image inventory x per-channel reach.

WHY THIS EXISTS (and why it is not ``image-catalog.json``)
---------------------------------------------------------
``docs/catalog/image-catalog.json`` (scripts/emit-image-catalog.py) is the GRAMMAR: the
role x platform x axes vocabulary the Studio and the admin-ui worklist multi-select share.
``tests/build-matrix/matrix.tsv`` is a hand-curated SAMPLE of that grammar that
tests/build-matrix/check.sh proves across five channels.

Neither answers the operator's actual question — *"can we create ALL the images?"* — because
neither enumerates the grammar's full cross-product and asks, per image, *which channels can
express it*. A cell can be perfectly buildable from the CLI and simply be unreachable from
the ncurses menu or the k8s Job worker; that is the classic defect class in this repo (a menu
offering a build the Studio cannot dispatch, or a catalog entry no channel can produce).

This script closes that: it expands the catalog grammar into EVERY advertised image and then
PROBES each of the six build channels for it, recording per-image reach:

  cli       the platform's builder script, invoked with the row's axis flags + ``--print-plan``
            (exit 0 AND the PLAN_* facts must come back as the row's own values)
  make      ``make -n <target> NATIVE=1 ENV=... <axis vars>`` — the recipe must invoke the
            right builder with the row's axis flags
  menu      scripts/build-menu.sh — the row's tokens must be OFFERED by the real ui_menu
            pickers (parsed out of the script) and the platform must reach build_make_cmd
  gui       the Studio's headless ``--print-command`` path (BuildDriver.command_string on a
            config JSON), in-process
  job       docker/build-image.sh's resolve_build_target(), EXECUTED (the real function,
            extracted into a scratch shell) against the row's HARDWARE_CLASS/IMAGE_TYPE
  worklist  the Studio worklist envelope: a one-entry ``hugmesh-worklist/v1`` must
            materialize into the same builder command (the mesh/fleet dispatch path)

Every probe is DRY-RUN by construction: ``--print-plan`` / ``make -n`` / command printing /
static parsing / a pure shell function. Nothing is built, no root, no network, no docker.

Each channel reach is one of:
  "yes"           first-class: the channel has a real selection for this exact image
  "escape-hatch"  reachable only by typing raw builder flags into the channel's escape hatch
                  (menu "Extra builder flags" / make STANDALONE_FLAGS) — a real gap, softer
  "no"            not expressible at all

Outputs (both committed; ``tests/build-matrix/inventory-check.sh`` regenerates + diffs them,
so a channel/grammar change that is not reflected here FAILS CI instead of rotting silently):
  docs/catalog/image-inventory.json   machine-readable
  docs/IMAGE-INVENTORY.md             the doc table

Usage:  python3 scripts/emit-image-inventory.py [--out …] [--md …] [--generator-dir …]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
_GEN_ROOT = os.path.dirname(_HERE)

DEFAULT_OUT = os.path.join("docs", "catalog", "image-inventory.json")
DEFAULT_MD = os.path.join("docs", "IMAGE-INVENTORY.md")
CATALOG = os.path.join("docs", "catalog", "image-catalog.json")
MATRIX = os.path.join("tests", "build-matrix", "matrix.tsv")

# The envs every image is built for (the hardening tier axis — a real image variant,
# but orthogonal to identity, so it rides each record as a list instead of doubling it).
ENVS = ("test", "prod")

# platform -> builder script (the SAME table tests/build-matrix/check.sh's builder_for uses)
BUILDER = {
    "x86": "build-x86-host-stage4.sh",
    "rpi5": "build-rpi5-stage4.sh",
    "frite": "build-frite-stage4.sh",
    "jetson": "build-jetson-stage4.sh",
    "orangepi5": "build-orangepi5-stage4.sh",
    "orangepizero2": "build-orangepi-zero2-stage4.sh",
    "orangepizero2w": "build-orangepi-zero2w-stage4.sh",
    "orangepizero3": "build-orangepi-zero3-stage4.sh",
    "orangepi3-lts": "build-orangepi3-lts-stage4.sh",
    "orangepi4-lts": "build-orangepi4-lts-stage4.sh",
}

# Studio role id -> the --role value the builder actually takes (config.RPI5_ROLE_MAP /
# JETSON_ROLE_MAP). Platforms with NO --role axis map to "" (frite/orangepi5/appliances):
# their Studio role id IS the platform name and the builder is given board/flavor only.
ROLE_TO_BUILDER_ROLE = {
    ("rpi5", "be"): "backend",
    ("rpi5", "fe"): "frontend",
    ("rpi5", "rpi5-desktop"): "desktop",
    ("jetson", "jetson-desktop"): "desktop",
}
NO_ROLE_AXIS = ("frite", "orangepi5", "orangepizero2", "orangepizero2w",
                "orangepizero3", "orangepi3-lts", "orangepi4-lts")
# The two Orange Pi NODE-axis boards (EXPERIMENTAL): their desktop keeps the no-role-axis
# shape above (Studio role id = the board, no --role), but a cluster node role in their
# scripts/_roles-lib.sh set (HUGMESH_ROLES_ORANGEPI5 / _ORANGEPI4LTS, read through the
# Studio's role reader) is passed as --role, like rpi5's.
NODE_AXIS_PLATFORMS = ("orangepi5", "orangepi4-lts")
# The platforms whose node roles take --ram-gb (the board's RAM). An omnibus record on
# them is probed at the role's floor (the smallest RAM omnibus accepts): one image serves
# every RAM size, so the RAM is a build input, not a separate image.
RAM_PLATFORMS = ("rpi5", "orangepi5", "orangepi4-lts")

# Makefile axis variables per platform (Makefile's own names).
MAKE_AXIS_VARS = {
    "rpi5": {"board": "RPI_BOARD"},
    "jetson": {"board": "JETSON_BOARD"},
    "frite": {"board": "FRITE_BOARD", "flavor": "FRITE_FLAVOR", "desktop": "FRITE_DESKTOP"},
    "orangepi5": {"board": "ORANGEPI5_BOARD", "flavor": "ORANGEPI5_FLAVOR"},
    "orangepizero2": {"flavor": "ORANGEPIZERO2_FLAVOR"},
    "orangepizero2w": {"flavor": "ORANGEPIZERO2W_FLAVOR"},
    "orangepizero3": {"flavor": "ORANGEPIZERO3_FLAVOR"},
    "orangepi3-lts": {"flavor": "ORANGEPI3LTS_FLAVOR"},
    "orangepi4-lts": {"flavor": "ORANGEPI4LTS_FLAVOR"},
    "x86": {},
}

# The ui_menu picker TITLES scripts/build-menu.sh uses, per (platform, axis). The tokens are
# READ OUT of the script (never restated here) so a picker losing an option is a diff, not a
# silent divergence. A platform/axis with no entry has no picker at all in the menu.
MENU_PICKERS = {
    # Two entry pickers reach a platform: the top "Build" screen (which owns the Frite
    # sub-screen outright) and its "A single arch + role …" sub-screen. A platform counts
    # as menu-reachable if EITHER offers it.
    ("__arch__", "build"): "Build",
    ("__arch__", "arch"): "Single role",
    ("rpi5", "role"): "Pi role",
    ("rpi5", "board"): "Pi board",
    ("x86", "role"): "x86 role",
    ("jetson", "role"): "Jetson role",
    ("jetson", "board"): "Jetson board",
    ("frite", "board"): "Frite board",
    ("frite", "flavor"): "Frite flavor",
    ("frite", "desktop"): "Frite desktop",
    ("orangepi5", "role"): "Orange Pi 5 role",
    ("orangepi5", "board"): "Orange Pi 5 board",
    ("orangepi5", "flavor"): "Orange Pi 5 flavor",
    ("orangepizero2", "flavor"): "Orange Pi Zero 2 flavor",
    ("orangepizero2w", "flavor"): "Orange Pi Zero 2W flavor",
    ("orangepizero3", "flavor"): "Orange Pi Zero 3 flavor",
    ("orangepi3-lts", "flavor"): "Orange Pi 3 LTS flavor",
    ("orangepi4-lts", "role"): "Orange Pi 4 LTS role",
    ("orangepi4-lts", "flavor"): "Orange Pi 4 LTS flavor",
}
# The RAM picker (scripts/build-menu.sh ram_screen) builds its options at run time from
# the same scripts/_roles-lib.sh floors the builders enforce, so it has no static tokens
# to read: its PRESENCE is what menu_reach checks for a record that needs a RAM.
MENU_RAM_PICKER = "Board RAM"
# The menu's arch token for a platform (its "Single role" picker spells rpi5 as "rpi").
MENU_ARCH_TOKEN = {"rpi5": "rpi"}

# The Studio mode a record's posture needs, and how each channel spells it.
#   mesh / cloud  -> the mesh plane stays ON (tailnet + SSO)
#   standalone    -> no mesh/SSO: the Studio emits --skip-mesh (ARM) / --no-tailscale
#                    --no-sso (x86); the x86 standalone-* ROLES preset it themselves.
X86_STANDALONE_ROLES = ("standalone-thin", "standalone-thick", "standalone-unaffiliated")


# ── channel helper: scripts/build-menu.sh picker token extraction ────────────────────
_UI_MENU_RE = r'ui_menu\s+"%s"'


def menu_tokens(menu_src: str, title: str) -> list[str]:
    """The option TOKENS a ``ui_menu "<title>" …`` picker offers, read out of the script.

    build-menu.sh's pickers are uniform: ``ui_menu "TITLE" "PROMPT" \\`` then one
    ``TOKEN "description" \\`` line per option, terminated by ``back "‹ back")"``. We scan
    from the title to that terminator and take the leading word of each option line.
    Raises if the title is absent — the pickers moving is a LOUD generator failure, never a
    silently empty option set (which would report every image as menu-unreachable)."""
    m = re.search(_UI_MENU_RE % re.escape(title), menu_src)
    if not m:
        raise SystemExit(f"emit-image-inventory: no ui_menu picker titled {title!r} in "
                         f"scripts/build-menu.sh — the menu moved; update MENU_PICKERS.")
    tail = menu_src[m.end():]
    end = tail.find('back "')
    if end < 0:
        raise SystemExit(f"emit-image-inventory: picker {title!r} has no 'back' terminator")
    toks: list[str] = []
    for line in tail[:end].splitlines()[1:]:     # [1:] skips the prompt line
        mt = re.match(r'\s*([A-Za-z0-9_.+-]+)\s+"', line)
        if mt:
            toks.append(mt.group(1))
    return toks


# ── channel helper: docker/build-image.sh resolve_build_target(), really executed ─────
_JOB_PROBE = r'''
set -u
# THE ROLE VOCABULARY, sourced exactly as docker/build-image.sh sources it. The
# extracted resolve_build_target() body CALLS hugmesh_role_for /
# hugmesh_role_keyprofile; a probe that omitted them would see every row reject and
# would report a total JOB-channel outage as if it were a real regression.
. "$2"
PLATFORM=""; BUILD_ROLE=""; KEYS_ROLE=""
RPI5_BOARD_OUT=""; JETSON_BOARD_OUT=""
FRITE_BOARD_OUT=""; FRITE_FLAVOR_OUT=""
ORANGEPI5_BOARD_OUT=""; ORANGEPI5_FLAVOR_OUT=""
ORANGEPIZERO2_FLAVOR_OUT=""; ORANGEPIZERO2W_FLAVOR_OUT=""; ORANGEPIZERO3_FLAVOR_OUT=""
ORANGEPI3LTS_FLAVOR_OUT=""; ORANGEPI4LTS_FLAVOR_OUT=""; RAM_GB_OUT=""
. "$1"
while IFS='|' read -r key IMAGE_TYPE HARDWARE_CLASS; do
    [ -n "${key}" ] || continue
    # RESET every out-var each iteration: resolve_build_target only assigns the ones its
    # matched platform arm uses, so a stale value from the PREVIOUS row would otherwise be
    # reported as this row's board/flavor (and silently mis-grade the whole JOB channel).
    PLATFORM=""; BUILD_ROLE=""; KEYS_ROLE=""
    RPI5_BOARD_OUT=""; JETSON_BOARD_OUT=""
    FRITE_BOARD_OUT=""; FRITE_FLAVOR_OUT=""
    ORANGEPI5_BOARD_OUT=""; ORANGEPI5_FLAVOR_OUT=""
    ORANGEPIZERO2_FLAVOR_OUT=""; ORANGEPIZERO2W_FLAVOR_OUT=""; ORANGEPIZERO3_FLAVOR_OUT=""
    ORANGEPI3LTS_FLAVOR_OUT=""; ORANGEPI4LTS_FLAVOR_OUT=""; RAM_GB_OUT=""
    if resolve_build_target 2>/dev/null; then
        printf '%s\t1\t%s\t%s\t%s\t%s\t%s\t%s\n' "${key}" "${PLATFORM}" "${BUILD_ROLE}" \
            "${RPI5_BOARD_OUT}${JETSON_BOARD_OUT}${FRITE_BOARD_OUT}${ORANGEPI5_BOARD_OUT}" \
            "${FRITE_FLAVOR_OUT}${ORANGEPI5_FLAVOR_OUT}${ORANGEPIZERO2_FLAVOR_OUT}${ORANGEPIZERO2W_FLAVOR_OUT}${ORANGEPIZERO3_FLAVOR_OUT}${ORANGEPI3LTS_FLAVOR_OUT}${ORANGEPI4LTS_FLAVOR_OUT}" \
            "${RPI5_STANDALONE}${FRITE_STANDALONE}${ORANGEPI5_STANDALONE}${ORANGEPIZERO2_STANDALONE}${ORANGEPIZERO2W_STANDALONE}${ORANGEPIZERO3_STANDALONE}${ORANGEPI3LTS_STANDALONE}${ORANGEPI4LTS_STANDALONE}" \
            "${KEYS_ROLE}"
    else
        printf '%s\t0\t\t\t\t\t\t\n' "${key}"
    fi
done
'''


def extract_resolve_fn(gen_dir: str) -> str:
    """docker/build-image.sh's resolve_build_target() body, verbatim (never re-typed)."""
    src = open(os.path.join(gen_dir, "docker", "build-image.sh"), encoding="utf-8").read()
    start = src.index("\nresolve_build_target() {")
    depth = 0
    for i in range(start + 1, len(src)):
        if src.startswith("\n}", i - 1):
            pass
        if src[i] == "\n" and src[i + 1:i + 2] == "}" and depth == 1:
            return src[start + 1:i + 2]
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
    raise SystemExit("emit-image-inventory: could not extract resolve_build_target()")


def probe_job(gen_dir: str, queries: list[tuple[str, str, str]]) -> dict[str, dict]:
    """Run the REAL resolve_build_target once per (key, IMAGE_TYPE, HARDWARE_CLASS)."""
    fn = extract_resolve_fn(gen_dir)
    with tempfile.TemporaryDirectory() as td:
        fpath = os.path.join(td, "resolve.sh")
        with open(fpath, "w", encoding="utf-8") as fh:
            fh.write(fn)
        stdin = "".join(f"{k}|{t}|{h}\n" for k, t, h in queries)
        roles_lib = os.path.join(gen_dir, "scripts", "_roles-lib.sh")
        res = subprocess.run(["bash", "-c", _JOB_PROBE, "bash", fpath, roles_lib],
                             input=stdin, capture_output=True, text=True)
    if res.returncode != 0:
        raise SystemExit(f"emit-image-inventory: job probe failed: {res.stderr[-800:]}")
    out: dict[str, dict] = {}
    for line in res.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 8:
            continue
        key, ok, plat, role, board, flavor, standalone, keys_role = parts[:8]
        out[key] = {"ok": ok == "1", "platform": plat, "role": role, "board": board,
                    "flavor": flavor, "standalone": "true" in standalone,
                    "keys_role": keys_role}
    return out


# ── record enumeration ───────────────────────────────────────────────────────────────
AXIS_ORDER = ("board", "flavor", "desktop")


def enumerate_records(catalog: dict) -> list[dict]:
    """The FULL advertised cross-product of docs/catalog/image-catalog.json's grammar."""
    recs: list[dict] = []
    for mode in sorted(catalog["roles"]):
        for entry in catalog["roles"][mode]:
            role = entry["role"]
            for pl in entry["platforms"]:
                platform = pl["platform"]
                axes = pl["axes"]
                combos: list[dict[str, str]] = [{}]
                for axis in AXIS_ORDER:
                    vals = axes.get(axis) or [""]
                    combos = [dict(c, **{axis: v}) for c in combos for v in vals]
                for combo in combos:
                    board = combo.get("board", "")
                    flavor = combo.get("flavor", "")
                    desktop = combo.get("desktop", "")
                    ident = [mode, platform, role] + [v for v in (board, flavor, desktop) if v]
                    recs.append({
                        "id": "/".join(ident),
                        "mode": mode,
                        "platform": platform,
                        "role": role,
                        "builder_role": builder_role_for(platform, role),
                        "ram_gb": probe_ram_gb(platform, builder_role_for(platform, role)),
                        "board": board,
                        "flavor": flavor,
                        "desktop": desktop,
                        "image_class": entry["image_class"],
                        "label": entry["label"],
                        "envs": list(ENVS),
                    })
    recs.sort(key=lambda r: r["id"])
    return recs


def builder_role_for(platform: str, role: str) -> str:
    if platform in NODE_AXIS_PLATFORMS:
        from hugmesh_studio.core import roles as role_vocab        # noqa: E402
        if role != "desktop" and role in role_vocab.roles_for_platform(platform):
            return role
    if platform in NO_ROLE_AXIS:
        return ""
    return ROLE_TO_BUILDER_ROLE.get((platform, role), role)


def probe_ram_gb(platform: str, builder_role: str) -> str:
    """The --ram-gb a record is probed with: the role's floor for a role that REQUIRES
    a RAM (omnibus) on a platform that takes one, else "" (no RAM stated)."""
    if platform not in RAM_PLATFORMS or not builder_role:
        return ""
    from hugmesh_studio.core import roles as role_vocab            # noqa: E402
    if not role_vocab.ram_required(builder_role):
        return ""
    return str(role_vocab.min_ram_gb(builder_role))


def cli_args(rec: dict) -> list[str]:
    """The builder argv (axis flags only) for a record — the CLI channel's own vocabulary."""
    p, args = rec["platform"], []
    if rec["builder_role"]:
        args += ["--role", rec["builder_role"]]
    if rec["board"]:
        args += ["--board", rec["board"]]
    if rec.get("ram_gb"):
        args += ["--ram-gb", rec["ram_gb"]]
    if rec["flavor"]:
        args += ["--flavor", rec["flavor"]]
    if rec["desktop"]:
        # x86's --desktop is CLIENT-ONLY (build-x86-host-stage4.sh validates it inside the
        # ROLE_CLIENT arm and ignores it otherwise) — emit it anyway: whether the builder
        # HONORS it is exactly what the PLAN_DESKTOP assertion below decides.
        args += ["--desktop", rec["desktop"]]
    if p == "x86" and rec["mode"] == "standalone" and rec["role"] not in X86_STANDALONE_ROLES:
        args += ["--no-tailscale", "--no-sso"]
    elif p != "x86" and rec["mode"] == "standalone":
        args += ["--skip-mesh"]
    return args


def gui_config(rec: dict) -> dict:
    cfg: dict = {"platform": rec["platform"], "role": rec["role"],
                 "mode": rec["mode"], "env": "test"}
    for axis in AXIS_ORDER:
        if rec[axis]:
            cfg[axis] = rec[axis]
    if rec.get("ram_gb"):
        cfg["ram_gb"] = rec["ram_gb"]
    return cfg


def worklist_envelope(rec: dict) -> dict:
    entry = {"role": rec["role"], "platform": rec["platform"]}
    for axis in AXIS_ORDER:
        if rec[axis]:
            entry[axis] = rec[axis]
    if rec.get("ram_gb"):
        entry["ram_gb"] = rec["ram_gb"]
    return {"schema": "hugmesh-worklist/v1", "mode": rec["mode"], "env": "test",
            "platform": rec["platform"], "role": rec["role"], "entries": [entry]}


def make_target(rec: dict) -> tuple[str, dict[str, str]]:
    """(target, axis vars) — the MAKE channel's own face for a record."""
    p = rec["platform"]
    if p == "x86":
        target = f"x86-{rec['role']}"
    elif p == "rpi5":
        target = f"rpi-{rec['builder_role']}"
    elif p == "jetson":
        target = f"jetson-{rec['builder_role']}"
    elif p in NODE_AXIS_PLATFORMS and rec["builder_role"]:
        target = f"{p}-{rec['builder_role']}"     # orangepi5-<role> / orangepi4-lts-<role>
    else:
        target = p
    axvars = {}
    for axis, var in MAKE_AXIS_VARS[p].items():
        if rec[axis]:
            if axis == "flavor" and p in NODE_AXIS_PLATFORMS and rec["builder_role"]:
                continue        # a node target is installer-only; it takes no flavor var
            axvars[var] = rec[axis]
    if rec.get("ram_gb"):
        axvars["RAM_GB"] = rec["ram_gb"]
    return target, axvars


# ── the probes ───────────────────────────────────────────────────────────────────────
def probe_cli(gen_dir: str, rec: dict, env: str) -> dict:
    builder = BUILDER[rec["platform"]]
    argv = ["bash", os.path.join(gen_dir, builder)] + cli_args(rec) + \
           ["--env", env, "--print-plan"]
    res = subprocess.run(argv, cwd=gen_dir, capture_output=True, text=True)
    plan = dict(l.split("=", 1) for l in res.stdout.splitlines()
                if l.startswith("PLAN_") and "=" in l)
    return {"rc": res.returncode, "plan": plan,
            "stderr": res.stderr.strip().splitlines()[-1] if res.returncode else ""}


def probe_make(gen_dir: str, rec: dict) -> dict:
    target, axvars = make_target(rec)
    argv = ["make", "-n", target, "NATIVE=1", "ENV=test"] + \
           [f"{k}={v}" for k, v in sorted(axvars.items())]
    res = subprocess.run(argv, cwd=gen_dir, capture_output=True, text=True)
    return {"rc": res.returncode, "out": res.stdout, "target": target,
            "vars": axvars, "argv": " ".join(argv)}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--generator-dir", default=_GEN_ROOT)
    ap.add_argument("--out", default=None)
    ap.add_argument("--md", default=None)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)
    gen = os.path.abspath(args.generator_dir)
    sys.path.insert(0, os.path.join(gen, "studio"))

    from hugmesh_studio.core.build_driver import BuildDriver          # noqa: E402
    from hugmesh_studio.core.config import (                          # noqa: E402
        ImageConfig, resolve_installer_ui_default, resolve_platform_defaults,
    )
    from hugmesh_studio.core.worklist import load_any                 # noqa: E402

    catalog = json.load(open(os.path.join(gen, CATALOG), encoding="utf-8"))
    menu_src = open(os.path.join(gen, "scripts", "build-menu.sh"), encoding="utf-8").read()
    records = enumerate_records(catalog)

    # ── menu picker tokens (read once out of the real script) ────────────────────────
    pickers = {k: menu_tokens(menu_src, t) for k, t in MENU_PICKERS.items()}
    pickers["__ram__"] = bool(re.search(_UI_MENU_RE % re.escape(MENU_RAM_PICKER), menu_src))
    menu_arches = set(pickers[("__arch__", "arch")]) | set(pickers[("__arch__", "build")])

    # ── the JOB channel, batched into ONE bash child ─────────────────────────────────
    job_queries: list[tuple[str, str, str]] = []
    for rec in records:
        hw = job_hwclass(rec)
        for itype in ("primary", "client", "mesh-extension"):
            job_queries.append((f"{rec['id']}##{itype}", itype, hw))
    job = probe_job(gen, job_queries)

    driver = BuildDriver(gen)
    tmp = tempfile.mkdtemp(prefix="img-inventory-")
    for rec in records:
        reach: dict[str, str] = {}
        why: dict[str, str] = {}

        # ── CLI ─────────────────────────────────────────────────────────────────────
        cli = probe_cli(gen, rec, "test")
        cli_prod = probe_cli(gen, rec, "prod")
        # Is the record's desktop weight ALREADY what the role produces with no --desktop
        # flag at all? (build-x86-host-stage4.sh's role arms preset it: standalone-thin ->
        # thin, standalone-thick/-unaffiliated/desktop -> full, laptop/chromebook -> the
        # thin default.) Measured, so no channel is scored against a flag it never needs.
        rec["desktop_implied"] = False
        if rec["desktop"]:
            bare = probe_cli(gen, dict(rec, desktop=""), "test")
            rec["desktop_implied"] = (
                bare["rc"] == 0
                and bare["plan"].get("PLAN_DESKTOP", "").split("+")[0] == rec["desktop"])
        mism = plan_mismatch(rec, cli["plan"])
        rec["phantom"] = False
        rec["phantom_reason"] = ""
        if cli["rc"] != 0:
            reach["cli"], why["cli"] = "no", f"builder rejected: {cli['stderr'][:120]}"
        elif cli_prod["rc"] != 0:
            reach["cli"], why["cli"] = "no", "builder rejected --env prod"
        elif mism:
            # The builder ACCEPTS the argv but does not honor the advertised axis, so this
            # is not a distinct image at all — a phantom catalog entry, not a channel gap.
            reach["cli"], why["cli"] = "no", mism
            rec["phantom"], rec["phantom_reason"] = True, mism
        else:
            reach["cli"] = "yes"
        rec["artifacts"] = sorted(
            a for a in cli["plan"].get("PLAN_ARTIFACTS", "").split(",") if a)
        rec["plan_role"] = cli["plan"].get("PLAN_ROLE", "")
        rec["plan_platform"] = cli["plan"].get("PLAN_PLATFORM", "")

        # ── GUI (Studio --print-command, in-process) ────────────────────────────────
        cpath = os.path.join(tmp, "gui.json")
        with open(cpath, "w", encoding="utf-8") as fh:
            json.dump(gui_config(rec), fh)
        try:
            cfg = ImageConfig.load(cpath)
            resolve_platform_defaults(cfg)
            resolve_installer_ui_default(cfg)
            cmd = driver.command_string(cfg, "native")
            miss = argv_missing(rec, cmd)
            reach["gui"] = "yes" if not miss else "no"
            if miss:
                why["gui"] = f"--print-command omits {miss}"
            rec["gui_command"] = normalize_cmd(cmd, gen)
        except Exception as exc:                                   # noqa: BLE001
            reach["gui"], why["gui"] = "no", f"{type(exc).__name__}: {exc}"[:160]
            rec["gui_command"] = ""

        # ── WORKLIST (one-entry envelope -> materialize -> same command) ────────────
        wpath = os.path.join(tmp, "wl.json")
        with open(wpath, "w", encoding="utf-8") as fh:
            json.dump(worklist_envelope(rec), fh)
        try:
            base, wl = load_any(wpath)
            cmds = [driver.command_string(c, "native") for _e, c in wl.materialize()]
            miss = argv_missing(rec, cmds[0]) if cmds else "no materialized image"
            reach["worklist"] = "yes" if (cmds and not miss) else "no"
            if not cmds or miss:
                why["worklist"] = f"materialized command omits {miss}" if cmds else \
                                  "envelope materialized 0 images"
        except Exception as exc:                                   # noqa: BLE001
            reach["worklist"], why["worklist"] = "no", f"{type(exc).__name__}: {exc}"[:160]

        # ── MAKE ────────────────────────────────────────────────────────────────────
        mk = probe_make(gen, rec)
        if mk["rc"] != 0:
            reach["make"], why["make"] = "no", f"no such target: {mk['target']}"
        else:
            miss = argv_missing(rec, mk["out"], make_channel=True)
            if miss:
                reach["make"] = "escape-hatch"
                why["make"] = (f"`make {mk['target']}` recipe omits {miss} "
                               f"(reachable only via STANDALONE_FLAGS)")
            else:
                reach["make"] = "yes"
        rec["make_target"] = mk["target"]
        rec["make_vars"] = mk["vars"]

        # ── MENU ────────────────────────────────────────────────────────────────────
        reach["menu"], why_menu = menu_reach(rec, pickers, menu_arches)
        if why_menu:
            why["menu"] = why_menu

        # ── JOB ─────────────────────────────────────────────────────────────────────
        hwclass = job_hwclass(rec)
        natural = job_natural_type(rec)
        ok_types = []
        for itype in ("primary", "client", "mesh-extension"):
            jr = job.get(f"{rec['id']}##{itype}", {"ok": False})
            if jr["ok"] and not job_mismatch(rec, jr):
                ok_types.append(itype)
        rec["job_token"] = {"IMAGE_TYPE": natural, "HARDWARE_CLASS": hwclass,
                            "accepted_image_types": ok_types}
        if natural in ok_types:
            reach["job"] = "yes"
        elif ok_types:
            reach["job"], why["job"] = "escape-hatch", (
                f"HARDWARE_CLASS={hwclass} is rejected for the mode-natural "
                f"IMAGE_TYPE={natural}; reachable only as IMAGE_TYPE="
                f"{'|'.join(ok_types)} (mislabelled request)")
        else:
            jr = job.get(f"{rec['id']}##{natural}", {"ok": False})
            reach["job"], why["job"] = "no", (
                job_mismatch(rec, jr) if jr["ok"] else
                f"resolve_build_target rejects every IMAGE_TYPE for "
                f"HARDWARE_CLASS={hwclass or '(empty)'}")

        rec["channels"] = reach
        rec["channel_notes"] = why
        rec["reachable"] = sorted(k for k, v in reach.items() if v == "yes")
        if not args.quiet:
            flags = "".join({"yes": ".", "escape-hatch": "~", "no": "X"}[reach[c]]
                            for c in CHANNELS)
            print(f"  [{flags}] {rec['id']}", file=sys.stderr)

    matrix = load_matrix(gen)
    report = build_report(records, matrix, catalog)

    out = args.out or os.path.join(gen, DEFAULT_OUT)
    md = args.md or os.path.join(gen, DEFAULT_MD)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, sort_keys=True)
        fh.write("\n")
    with open(md, "w", encoding="utf-8") as fh:
        fh.write(render_md(report))
    print(f"wrote {out}\nwrote {md}")
    return 0


CHANNELS = ("cli", "make", "menu", "gui", "job", "worklist")


def job_hwclass(rec: dict) -> str:
    """The HARDWARE_CLASS token the k8s Job worker would need for a record —
    docker/build-image.sh's own dot-delimited grammar (see its header comment)."""
    p, role, mode = rec["platform"], rec["role"], rec["mode"]
    if p == "x86":
        return f"x86.{'be-gpu' if role == 'be+gpu' else role}"
    if p == "rpi5":
        role_tok = rec["builder_role"]
        if mode == "standalone" and role_tok == "desktop":
            role_tok = "standalone-desktop"
        ram = f".{rec['ram_gb']}gb" if rec.get("ram_gb") else ""
        return f"rpi5.{role_tok}.{rec['board'] or 'rpi5'}{ram}"
    if p == "jetson":
        return f"jetson.{rec['builder_role']}.{rec['board'] or 'orin-nano'}"
    flavor = rec["flavor"]
    if mode == "standalone" and flavor in ("installer", ""):
        flavor = "standalone"           # the ARM standalone-posture flavor token
    if p == "frite":
        return f"frite.{rec['board'] or 'la-frite'}.{flavor or 'installer'}"
    if p in NODE_AXIS_PLATFORMS and rec["builder_role"]:
        # a cluster NODE: "<platform>.<role>[.<board>][.<N>gb]" (installer only)
        ram = f".{rec['ram_gb']}gb" if rec.get("ram_gb") else ""
        board = f".{rec['board']}" if rec["board"] else ""
        return f"{p}.{rec['builder_role']}{board}{ram}"
    if p == "orangepi5":
        return f"orangepi5.{rec['board'] or 'orange-pi-5-plus'}.{flavor or 'installer'}"
    return f"{p}.{flavor or 'installer'}"


def job_natural_type(rec: dict) -> str:
    """The IMAGE_TYPE the record's MODE naturally maps to: a mesh node is a cluster
    image (primary), a cloud/standalone device is a client. resolve_build_target gates
    several platforms on this, so probing the natural one first is what makes "reachable
    only by mislabelling the request" visible instead of silently passing."""
    return "primary" if rec["mode"] == "mesh" else "client"


def job_mismatch(rec: dict, jr: dict) -> str:
    """The JOB channel resolved — but to the SAME image? (a token that resolves to a
    different platform/role/board/flavor is not expressing THIS record)."""
    bad = []
    if jr["platform"] != rec["platform"]:
        bad.append(f"platform={jr['platform']}")
    want_role = rec["builder_role"]
    if want_role and jr["role"] != want_role:
        bad.append(f"role={jr['role']} (want {want_role})")
    if rec["board"] and jr["board"] and jr["board"] != rec["board"]:
        bad.append(f"board={jr['board']} (want {rec['board']})")
    if rec["flavor"] and jr["flavor"] and jr["flavor"] != rec["flavor"] and not (
            rec["mode"] == "standalone" and jr["flavor"] == "installer"):
        bad.append(f"flavor={jr['flavor']} (want {rec['flavor']})")
    # Standalone POSTURE (probe_job already returns it; comparing it is what keeps a
    # cloud-posture resolution from impersonating a standalone image). Non-x86 only:
    # ARM standalone rides a *_STANDALONE flag the resolver must flip, while x86
    # standalone rides the standalone-* ROLE token the role check above already pins.
    # The classic miss: mode=standalone flavor=live folds to the SAME <platform>.
    # <board>.live token as the cloud live image (job_hwclass only has a 'standalone'
    # token for the installer path), so the resolver accepts it but silently drops
    # --standalone/--skip-mesh — that resolves to a DIFFERENT (mesh-affiliated) image.
    if rec["platform"] != "x86":
        want_standalone = rec["mode"] == "standalone"
        if jr["standalone"] != want_standalone:
            bad.append("standalone posture dropped (resolves to the mesh-affiliated "
                       "image)" if want_standalone else "standalone posture added")
    return "resolved to a DIFFERENT image: " + ", ".join(bad) if bad else ""


def plan_mismatch(rec: dict, plan: dict) -> str:
    """Did the builder HONOR every axis the catalog advertises for this record?

    A flag the builder silently drops (``--desktop full`` on an x86 NODE role -> the plan
    still says PLAN_DESKTOP=none) means the advertised axis produces no distinct image —
    the catalog is over-claiming, and that is a finding, not a pass."""
    bad = []
    # PLAN_DESKTOP can carry a modifier suffix (build-x86-host-stage4.sh prints
    # "full+capable" for the --capable Plasma set) — compare the BASE weight only.
    got_desktop = plan.get("PLAN_DESKTOP", "").split("+")[0]
    if rec["desktop"] and got_desktop not in (rec["desktop"], ""):
        bad.append(f"--desktop {rec['desktop']} not honored (PLAN_DESKTOP="
                   f"{plan.get('PLAN_DESKTOP')})")
    if rec["flavor"] and plan.get("PLAN_FLAVOR", rec["flavor"]) != rec["flavor"]:
        bad.append(f"--flavor {rec['flavor']} -> PLAN_FLAVOR={plan.get('PLAN_FLAVOR')}")
    if rec["board"] and plan.get("PLAN_BOARD", rec["board"]) != rec["board"] \
            and rec["platform"] != "rpi5":
        bad.append(f"--board {rec['board']} -> PLAN_BOARD={plan.get('PLAN_BOARD')}")
    return "; ".join(bad)


def argv_missing(rec: dict, text: str, make_channel: bool = False) -> str:
    """Which of the record's axis flags does an emitted command line NOT carry?"""
    miss = []
    if BUILDER[rec["platform"]] not in text:
        miss.append(BUILDER[rec["platform"]])
    if rec["builder_role"] and f"--role {rec['builder_role']}" not in text:
        miss.append(f"--role {rec['builder_role']}")
    if rec["board"] and f"--board {rec['board']}" not in text:
        miss.append(f"--board {rec['board']}")
    if rec.get("ram_gb") and f"--ram-gb {rec['ram_gb']}" not in text:
        miss.append(f"--ram-gb {rec['ram_gb']}")
    if rec["flavor"] and f"--flavor {rec['flavor']}" not in text:
        miss.append(f"--flavor {rec['flavor']}")
    if rec["desktop"] and f"--desktop {rec['desktop']}" not in text \
            and not rec.get("desktop_implied"):
        # Only a real miss where the flag is LOAD-BEARING: a role that already presets this
        # weight (standalone-thin -> thin, standalone-thick/unaffiliated/desktop -> full,
        # laptop/chromebook -> the builder's thin default) produces the same image without
        # it, so a channel omitting the flag still expresses the image. desktop_implied is
        # measured, not assumed — see the no---desktop --print-plan probe in main().
        miss.append(f"--desktop {rec['desktop']}")
    if rec["mode"] == "standalone":
        if rec["platform"] == "x86":
            if rec["role"] not in X86_STANDALONE_ROLES and "--no-sso" not in text:
                miss.append("--no-sso (standalone posture)")
        elif "--skip-mesh" not in text and "--standalone" not in text:
            miss.append("--skip-mesh (standalone posture)")
    return ", ".join(miss)


def menu_reach(rec: dict, pickers: dict, menu_arches: set) -> tuple[str, str]:
    """Can scripts/build-menu.sh's REAL pickers select this exact image?"""
    p = rec["platform"]
    arch_tok = MENU_ARCH_TOKEN.get(p, p)
    if arch_tok not in menu_arches:
        return "no", f"the 'Single role' arch picker offers no {arch_tok!r} entry"
    missing = []
    role_toks = pickers.get((p, "role"))
    if role_toks is not None:
        # a node-axis board's desktop is its picker's `desktop` entry
        want = rec["builder_role"] or ("desktop" if p in NODE_AXIS_PLATFORMS else rec["role"])
        if want not in role_toks:
            missing.append(f"role {want!r} (picker offers: {', '.join(role_toks)})")
    if rec.get("ram_gb") and not pickers.get("__ram__"):
        missing.append(f"no RAM picker at all (cannot select --ram-gb {rec['ram_gb']})")
    for axis in AXIS_ORDER:
        val = rec[axis]
        if not val:
            continue
        if axis == "desktop" and rec.get("desktop_implied"):
            continue        # the ROLE already produces this weight — no picker needed
        toks = pickers.get((p, axis))
        if toks is None:
            missing.append(f"no {axis} picker at all (cannot select {axis}={val})")
        elif val not in toks:
            missing.append(f"{axis} {val!r} (picker offers: {', '.join(toks)})")
    if missing:
        return "no", "; ".join(missing)
    if rec["mode"] == "standalone":
        # The menu reaches the standalone posture through a ROLE that presets it (x86
        # standalone-*) — every other platform/role needs 'Extra builder flags'.
        if not (p == "x86" and rec["role"] in X86_STANDALONE_ROLES):
            return "escape-hatch", ("no standalone-posture selection; --skip-mesh/"
                                    "--standalone only via 'Extra builder flags'")
    return "yes", ""


def normalize_cmd(cmd: str, gen: str) -> str:
    """Machine-stable form of a printed builder command: drop the host-specific bits
    (work dir, -j, the operator's local user) so the committed JSON is byte-identical on
    every machine and a real grammar change is the ONLY thing that shows up in a diff."""
    toks = shlex.split(cmd)
    out, skip = [], 0
    for i, t in enumerate(toks):
        if skip:
            skip -= 1
            continue
        if t in ("-w", "-j", "--local-user", "--local-pass"):
            out.append(t)
            out.append("<host>")
            skip = 1
            continue
        out.append(t.replace(gen, "<gen>"))
    return " ".join(out)


def load_matrix(gen: str) -> list[tuple[str, ...]]:
    rows = []
    with open(os.path.join(gen, MATRIX), encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = [("" if c == "-" else c) for c in line.split("\t")]
            if len(parts) >= 6:
                rows.append(tuple(parts[:6]))
    return rows


def build_report(records: list[dict], matrix: list[tuple[str, ...]], catalog: dict) -> dict:
    per_channel = {c: {"yes": 0, "escape-hatch": 0, "no": 0} for c in CHANNELS}
    for r in records:
        for c in CHANNELS:
            per_channel[c][r["channels"][c]] += 1

    # A PHANTOM is not a channel gap — it is an image that does not exist (the builder
    # accepts the advertised axis and then ignores it). Report it in its own bucket so the
    # gap list stays "images that ARE real but some channel cannot reach".
    gaps = [{"id": r["id"], "channels": {c: r["channels"][c] for c in CHANNELS
                                         if r["channels"][c] != "yes"},
             "notes": r["channel_notes"]}
            for r in records
            if not r["phantom"] and any(r["channels"][c] != "yes" for c in CHANNELS)]

    phantoms = [{"id": r["id"], "why": r["phantom_reason"]}
                for r in records if r["phantom"]]

    # A matrix.tsv cell with no inventory record = a channel target the catalog does not
    # advertise (undocumented). Compared in the BUILDER vocabulary the .tsv speaks, with
    # the .tsv's JOB-channel standalone spellings normalized exactly the way
    # studio/hugmesh_studio/core/build_matrix.py's MatrixRow.normalized() does.
    inv_cells = set()
    for r in records:
        for cell in rec_matrix_cells(r):
            inv_cells.add(cell)
    undocumented, covered = [], set()
    for (p, role, env, board, flavor, desk) in matrix:
        key = normalize_matrix_cell(p, role, board, flavor, desk)
        covered.add("/".join(x for x in key if x))
        if key not in inv_cells:
            undocumented.append("/".join(x for x in (p, role, board, flavor, desk) if x))
    undocumented = sorted(set(undocumented))

    return {
        "schema": "hugmesh-image-inventory/v1",
        "generated_by": "scripts/emit-image-inventory.py",
        "sources": {
            "grammar": CATALOG,
            "matrix": MATRIX,
            "channels": {
                "cli": "build-*-stage4.sh --print-plan",
                "make": "Makefile targets (make -n)",
                "menu": "scripts/build-menu.sh ui_menu pickers",
                "gui": "studio/hugmesh_studio --print-command",
                "job": "docker/build-image.sh resolve_build_target()",
                "worklist": "hugmesh-worklist/v1 envelope -> materialize()",
            },
        },
        "envs": list(ENVS),
        "image_count": len(records),
        "build_count": len(records) * len(ENVS),
        "per_channel_counts": per_channel,
        "platform_counts": platform_counts(records),
        "mode_counts": mode_counts(records),
        "matrix_cells": len(matrix),
        "matrix_distinct_cells": len(covered),
        "phantom_count": len(phantoms),
        "channel_gaps": gaps,
        "phantoms": phantoms,
        "undocumented": undocumented,
        "images": records,
    }


# matrix.tsv only ever uses the desktop column on the ONE platform whose builder has a
# desktop axis it also tabulates (frite light|none). Everywhere else it is "-".
_MATRIX_DESKTOP_PLATFORMS = ("frite",)


def normalize_matrix_cell(platform: str, role: str, board: str, flavor: str,
                          desktop: str) -> tuple[str, ...]:
    """A matrix.tsv row in real builder vocabulary (MatrixRow.normalized()'s translation:
    rpi5 ``standalone-desktop`` -> ``desktop``; ARM ``flavor=standalone`` -> ``installer``)."""
    if role == "standalone-desktop":
        role = "desktop"
    if flavor == "standalone":
        flavor = "installer"
    if platform not in _MATRIX_DESKTOP_PLATFORMS:
        desktop = ""
    if platform == "rpi5" and not board:
        board = "rpi5"          # the .tsv leaves the DEFAULT board column blank
    return (platform, role, board, flavor, desktop)


def rec_matrix_cells(rec: dict) -> set[tuple[str, ...]]:
    """The matrix.tsv cell(s) an inventory record covers, in the same normalized form.

    Uses the builder's OWN PLAN_ROLE (frite/orangepi5 -> ``desktop``, the appliances ->
    ``appliance``), because that is the vocabulary the .tsv's role column speaks."""
    role = rec["plan_role"] or rec["builder_role"] or rec["role"]
    desktop = rec["desktop"] if rec["platform"] in _MATRIX_DESKTOP_PLATFORMS else ""
    cells = {(rec["platform"], role, rec["board"], rec["flavor"], desktop)}
    if rec["flavor"] == "":
        # a platform with no flavor axis matches a "-" flavor column
        cells.add((rec["platform"], role, rec["board"], "", desktop))
    return cells


def platform_counts(records: list[dict]) -> dict:
    out: dict[str, int] = {}
    for r in records:
        out[r["platform"]] = out.get(r["platform"], 0) + 1
    return dict(sorted(out.items()))


def mode_counts(records: list[dict]) -> dict:
    out: dict[str, int] = {}
    for r in records:
        out[r["mode"]] = out.get(r["mode"], 0) + 1
    return dict(sorted(out.items()))


_MARK = {"yes": "✅", "escape-hatch": "⚠️", "no": "❌"}


def render_md(rep: dict) -> str:
    L: list[str] = []
    a = L.append
    a("# Image inventory — every advertised image x every build channel\n")
    a("<!-- GENERATED by scripts/emit-image-inventory.py — DO NOT EDIT BY HAND.")
    a("     Regenerate: python3 scripts/emit-image-inventory.py")
    a("     CI gate:    bash tests/build-matrix/inventory-check.sh (`make inventory-check`) -->\n")
    a("`docs/catalog/image-catalog.json` is the image GRAMMAR and "
      f"`tests/build-matrix/matrix.tsv` is a curated {rep['matrix_cells']}-cell SAMPLE of it. This table is the "
      "third thing neither of them is: the FULL cross-product of that grammar — every image "
      "the platform advertises — with, per image, which of the six build channels can "
      "actually express it.\n")
    a(f"- **{rep['image_count']} distinct images** "
      f"(x {len(rep['envs'])} hardening envs = {rep['build_count']} builds)")
    a(f"- **{rep['matrix_cells']} matrix.tsv cells** "
      f"({rep['matrix_distinct_cells']} distinct, env-collapsed) — the sampled subset "
      f"`tests/build-matrix/check.sh` proves across five channels")
    a(f"- **{len(rep['channel_gaps'])} images with a channel gap**, "
      f"{len(rep['phantoms'])} phantom, {len(rep['undocumented'])} undocumented\n")
    a("Legend: ✅ first-class selection &nbsp; ⚠️ escape-hatch only (raw builder flags) "
      "&nbsp; ❌ not expressible\n")

    a("## Per-channel reach\n")
    a("| channel | source of truth | ✅ | ⚠️ | ❌ |")
    a("| --- | --- | ---: | ---: | ---: |")
    for c in CHANNELS:
        pc = rep["per_channel_counts"][c]
        a(f"| `{c}` | {rep['sources']['channels'][c]} | {pc['yes']} | "
          f"{pc['escape-hatch']} | {pc['no']} |")
    a("")

    a("## The inventory\n")
    a("| image id | mode | platform | role | builder role | board | flavor | desktop | "
      "artifacts | cli | make | menu | gui | job | worklist |")
    a("| --- | --- | --- | --- | --- | --- | --- | --- | --- | :-: | :-: | :-: | :-: | "
      ":-: | :-: |")
    for r in rep["images"]:
        marks = " | ".join(_MARK[r["channels"][c]] for c in CHANNELS)
        a(f"| `{r['id']}` | {r['mode']} | {r['platform']} | `{r['role']}` | "
          f"`{r['builder_role'] or '—'}` | {r['board'] or '—'} | {r['flavor'] or '—'} | "
          f"{r['desktop'] or '—'} | {', '.join(r['artifacts']) or '—'} | {marks} |")
    a("")

    if rep["channel_gaps"]:
        a("## Channel gaps\n")
        a("An image one channel can express and another cannot. This is the defect class "
          "this inventory exists to catch.\n")
        a("| image id | channel | reach | why |")
        a("| --- | --- | :-: | --- |")
        for g in rep["channel_gaps"]:
            for c, v in sorted(g["channels"].items()):
                note = g["notes"].get(c, "").replace("|", "\\|")
                a(f"| `{g['id']}` | `{c}` | {_MARK[v]} | {note} |")
        a("")

    if rep["phantoms"]:
        a("## Phantoms\n")
        a("Catalog entries no channel produces as a DISTINCT image (an advertised axis the "
          "builder silently drops, or a combination nothing can build).\n")
        a("| image id | why |")
        a("| --- | --- |")
        for p in rep["phantoms"]:
            a(f"| `{p['id']}` | {p['why'].replace('|', chr(92) + '|')} |")
        a("")

    a("## Undocumented channel targets\n")
    if rep["undocumented"]:
        a("`matrix.tsv` cells with no matching catalog entry:\n")
        for u in rep["undocumented"]:
            a(f"- `{u}`")
    else:
        a("None — every `matrix.tsv` cell maps onto an advertised catalog image.")
    a("")
    return "\n".join(L)


if __name__ == "__main__":
    raise SystemExit(main())
