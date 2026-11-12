"""Mainline evidence for candidate boards, and the promotion guard it feeds.

``studio/evidence/mainline-evidence.json`` records, per candidate board, the
mainline U-Boot defconfig and kernel device tree, looked up at named release tags by
``scripts/mainline-evidence.py``. This file:

1. checks that evidence offline: shape, internal consistency, and that every board the
   platform-expansion design names (hugmesh-generator#1057) is listed;
2. refuses any device-catalog row promoted from unsupported (to experimental or
   supported) unless the evidence gives it a "found" verdict. Rows that were already
   promoted when this guard landed are listed in ``GRANDFATHERED``; a row that is
   demoted loses that place, so promoting it again needs evidence too;
3. runs the lookup script against small local git repositories, so the lookup that
   wrote the evidence is itself tested without touching the network.

x86-64 rows are the one exemption: they boot through UEFI, with no U-Boot defconfig
or device tree to look up. Every other arch is checked, including one the catalog
gains later (a new arch must not slip past the guard by not being on a list).
Evidence is necessary for promotion, never sufficient.

Pure-core: no Qt import.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
from types import SimpleNamespace

import pytest

from hugmesh_studio.core import device_catalog as dc

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
EVIDENCE_PATH = os.path.join(STUDIO_ROOT, "evidence", "mainline-evidence.json")
SCRIPT = os.path.join(GENERATOR_DIR, "scripts", "mainline-evidence.py")

FOUND = "found"
NOT_FOUND = "not found"

# The boards hugmesh-generator#1057 names. The evidence may list more, never fewer.
CANDIDATES = {"rock-5b", "nanopc-t6", "visionfive-2", "bpi-f3", "opi5-pro", "opi5-max"}

# The arches the guard exempts: they boot without a U-Boot defconfig or device tree.
# Exempting is explicit; an arch not named here is checked, known or not.
EXEMPT_ARCHES = frozenset({"x86-64"})

# Evidence boards' arch -> the directory name both upstream trees use for it.
DT_ARCHES = {"arm64": "arm64", "riscv64": "riscv", "armv7": "arm"}

# Every non-x86 row that was experimental or supported when this guard landed
# (2026-11-12). Frozen: a new promotion goes through the evidence file, not this list.
GRANDFATHERED = frozenset({
    "rpi5", "rpi4", "rpi3", "la-frite", "le-potato", "sweet-potato",
    "orin-nano", "orin-nano-4gb", "orin-nx-8gb", "orin-nx-16gb",
    "orange-pi-5-plus", "orange-pi-5", "orange-pi-zero2", "orange-pi-zero2w",
    "orange-pi-zero3", "orange-pi-3-lts", "orange-pi-4-lts",
    "rpi400", "rpi-cm4", "rpi500", "rpi-cm5",
})

_BLOB = re.compile(r"^[0-9a-f]{40}$")


def _load(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _evidence() -> dict:
    return _load(EVIDENCE_PATH)


def _catalog_rows() -> list[SimpleNamespace]:
    """The catalog read fresh from disk (not dc's cache), as plain rows."""
    raw = _load(dc.CATALOG_PATH)
    return [SimpleNamespace(id=d["id"], arch=d["arch"], status=d["status"],
                            reason=d.get("reason", "")) for d in raw["devices"]]


def promotion_violations(rows, evidence: dict, grandfathered=GRANDFATHERED) -> list[str]:
    """One sentence per catalog row that is promoted (status not "unsupported") on any
    arch outside EXEMPT_ARCHES, is not grandfathered, and has no "found" verdict in ``evidence``.
    The ONE predicate: the real assertion and every negative case below call it."""
    verdicts = {b["id"]: b.get("verdict") for b in evidence["boards"]}
    out = []
    for r in rows:
        if r.status == "unsupported" or r.arch in EXEMPT_ARCHES or r.id in grandfathered:
            continue
        v = verdicts.get(r.id)
        if v != FOUND:
            why = "has no entry" if v is None else f"has verdict {v!r}"
            out.append(f"{r.id}: promoted to {r.status} on {r.arch}, but "
                       f"mainline-evidence.json {why}; a promotion needs a 'found' "
                       "U-Boot defconfig + kernel device tree (scripts/mainline-evidence.py)")
    return out


# ── 1. the evidence file itself ─────────────────────────────────────────────────

def test_evidence_names_both_trees_at_a_release_tag_and_its_commit():
    ev = _evidence()
    assert ev["schema"] == "mainline-evidence/v1"
    assert set(ev["trees"]) == {"u-boot", "linux"}
    for key, tree in ev["trees"].items():
        assert tree["url"].startswith("https://"), key
        assert re.fullmatch(r"v\d+(\.\d+)+", tree["tag"]), \
            f"{key}: {tree['tag']!r} is not a release tag (no -rc, no branch)"
        assert _BLOB.match(tree["commit"]), f"{key}: commit {tree['commit']!r}"


def test_evidence_covers_every_candidate_board_once():
    ids = [b["id"] for b in _evidence()["boards"]]
    assert len(ids) == len(set(ids)), "duplicate board ids in the evidence"
    missing = CANDIDATES - set(ids)
    assert not missing, f"the evidence lost candidate boards: {sorted(missing)}"


def test_every_found_part_names_its_path_and_blob_and_every_miss_says_what_was_searched():
    ev = _evidence()
    for b in ev["boards"]:
        assert b["arch"] in DT_ARCHES, b["id"]
        adir = DT_ARCHES[b["arch"]]
        dt, base = b["dt"], b["dt"].rsplit("/", 1)[-1]
        u, k = b["u-boot"], b["linux"]
        for part, tag in ((u, ev["trees"]["u-boot"]["tag"]), (k, ev["trees"]["linux"]["tag"])):
            assert part["status"] in (FOUND, NOT_FOUND), (b["id"], part)
            if part["status"] == NOT_FOUND:
                assert tag in part["searched"], (b["id"], "a miss must name the tag searched")
        if u["status"] == FOUND:
            assert u["path"] == f"configs/{u['defconfig']}" and u["defconfig"].endswith("_defconfig")
            assert _BLOB.match(u["blob"]), b["id"]
            assert u["match"] in ("default", "of-list"), b["id"]
            assert u["dt_source"] in (f"dts/upstream/src/{adir}/{dt}.dts",
                                      f"arch/{adir}/dts/{base}.dts"), b["id"]
        if k["status"] == FOUND:
            assert k["path"] == f"arch/{adir}/boot/dts/{dt}.dts", b["id"]
            assert k["makefile"] == f"{os.path.dirname(k['path'])}/Makefile", b["id"]
            assert _BLOB.match(k["blob"]), b["id"]


def test_a_board_verdict_is_found_only_when_both_parts_are():
    for b in _evidence()["boards"]:
        both = b["u-boot"]["status"] == FOUND and b["linux"]["status"] == FOUND
        assert b["verdict"] == (FOUND if both else NOT_FOUND), b["id"]


def test_evidence_rows_agree_with_their_catalog_rows():
    """A board that is in the catalog has the same arch there, and any defconfig or
    .dtb the catalog's reason names is the one the evidence found."""
    rows = {r.id: r for r in _catalog_rows()}
    for b in _evidence()["boards"]:
        r = rows.get(b["id"])
        if r is None:
            continue                               # e.g. visionfive-2: no catalog row yet
        assert r.arch == b["arch"], (b["id"], r.arch, b["arch"])
        for named in re.findall(r"[\w.-]+_defconfig", r.reason):
            assert b["u-boot"].get("defconfig") == named, \
                f"{b['id']}: the catalog reason names {named}, the evidence does not"
        for named in re.findall(r"[\w.-]+\.dtb\b", r.reason):
            assert b["linux"]["status"] == FOUND and named == b["dt"].rsplit("/", 1)[-1] + ".dtb", \
                f"{b['id']}: the catalog reason names {named}, the evidence does not"


# ── 2. the promotion guard ──────────────────────────────────────────────────────

def test_no_catalog_row_is_promoted_without_found_mainline_evidence():
    assert promotion_violations(_catalog_rows(), _evidence()) == []


def test_grandfathered_rows_are_still_promoted_non_x86_catalog_rows():
    rows = {r.id: r for r in _catalog_rows()}
    for rid in sorted(GRANDFATHERED):
        assert rid in rows, f"{rid}: grandfathered but no longer in the catalog — drop it"
        assert rows[rid].status != "unsupported", (
            f"{rid}: demoted to unsupported, so it loses its grandfathered place; remove "
            "it from GRANDFATHERED (promoting it again then needs mainline evidence)")
        assert rows[rid].arch not in EXEMPT_ARCHES, rid


def test_promoting_each_real_not_found_board_is_refused():
    ev = _evidence()
    rows = _catalog_rows()
    in_catalog = {r.id for r in rows}
    misses = [b["id"] for b in ev["boards"]
              if b["verdict"] != FOUND and b["id"] in in_catalog]
    for rid in misses:
        promoted = [SimpleNamespace(**{**vars(r), "status": "experimental"}) if r.id == rid
                    else r for r in rows]
        bad = promotion_violations(promoted, ev)
        assert any(v.startswith(f"{rid}:") for v in bad), rid


def test_promotion_guard_negative_cases_do_not_depend_on_todays_upstream():
    """Synthetic rows, so the guard stays tested after upstream fills today's gaps."""
    ev = {"boards": [{"id": "board-miss", "verdict": NOT_FOUND},
                     {"id": "board-hit", "verdict": FOUND}]}
    row = lambda rid, status, arch="arm64": SimpleNamespace(id=rid, status=status, arch=arch,
                                                            reason="")
    # a "not found" row, promoted to either status, is refused
    assert promotion_violations([row("board-miss", "experimental")], ev, frozenset())
    assert promotion_violations([row("board-miss", "supported")], ev, frozenset())
    # a promoted row with no evidence entry at all is refused on every non-exempt arch,
    # including one no list here names (the design's planned mips64el)
    for arch in (*DT_ARCHES, "mips64el", "some-future-arch"):
        assert promotion_violations([row("board-none", "experimental", arch)], ev, frozenset())
    # and the accepting cases, so the predicate is not simply "always refuse"
    assert promotion_violations([row("board-hit", "experimental")], ev, frozenset()) == []
    assert promotion_violations([row("board-miss", "unsupported")], ev, frozenset()) == []
    assert promotion_violations([row("board-none", "supported", "x86-64")], ev, frozenset()) == []
    assert promotion_violations([row("board-none", "supported")], ev,
                                frozenset({"board-none"})) == []


# ── 3. the lookup script, against local repositories ────────────────────────────

def _load_script():
    spec = importlib.util.spec_from_file_location("mainline_evidence", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_defconfig_trees_and_matching_rank_the_default_tree_first():
    me = _load_script()
    text = ('CONFIG_ARM=y\nCONFIG_DEFAULT_DEVICE_TREE="vendor/board-a"\n'
            'CONFIG_OF_LIST="vendor/board-a vendor/board-b"\n')
    assert me.defconfig_trees(text) == ("vendor/board-a", ["vendor/board-a", "vendor/board-b"])
    assert me.defconfig_trees("CONFIG_ARM=y\n") == ("", [])
    cfgs = {"z_defconfig": text, "a_defconfig": 'CONFIG_OF_LIST="vendor/board-a"\n',
            "c_defconfig": 'CONFIG_DEFAULT_DEVICE_TREE="vendor/board-a-plus"\n'}
    assert me.match_defconfigs(cfgs, "vendor/board-a") == [("z_defconfig", "default"),
                                                            ("a_defconfig", "of-list")]
    assert me.match_defconfigs(cfgs, "vendor/board-b") == [("z_defconfig", "of-list")]
    assert me.match_defconfigs(cfgs, "vendor/board") == []


def _git_env(tmp_path) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(HOME=str(tmp_path), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
               GIT_TERMINAL_PROMPT="0")
    return env


def _repo(path, files: dict[str, str], tag: str, env: dict) -> str:
    os.makedirs(path)
    for rel, text in files.items():
        full = os.path.join(path, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as fh:
            fh.write(text)
    ident = ["-c", "user.name=t", "-c", "user.email=t@example.invalid",
             "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"]
    for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "tree"],
                 ["tag", "-a", "-m", tag, tag]):
        subprocess.run(["git", *ident, *args], cwd=path, env=env, check=True,
                       capture_output=True)
    return "file://" + str(path).replace(os.sep, "/")


def test_the_lookup_script_finds_pairs_and_names_each_miss(tmp_path):
    env = _git_env(tmp_path)
    uboot = _repo(tmp_path / "u-boot", {
        "configs/alpha-soc_defconfig": 'CONFIG_DEFAULT_DEVICE_TREE="rockchip/alpha"\n',
        "configs/multi_defconfig": ('CONFIG_DEFAULT_DEVICE_TREE="spacemit/other"\n'
                                    'CONFIG_OF_LIST="spacemit/other spacemit/beta"\n'),
        "configs/nodts_defconfig": 'CONFIG_DEFAULT_DEVICE_TREE="rockchip/delta"\n',
        "dts/upstream/src/arm64/rockchip/alpha.dts": "/dts-v1/;\n",
        "dts/upstream/src/riscv/spacemit/beta.dts": "/dts-v1/;\n",
    }, "v2099.01", env)
    linux = _repo(tmp_path / "linux", {
        "arch/arm64/boot/dts/rockchip/alpha.dts": "/dts-v1/;\n",
        "arch/arm64/boot/dts/rockchip/gamma.dts": "/dts-v1/;\n",
        "arch/arm64/boot/dts/rockchip/delta.dts": "/dts-v1/;\n",
        "arch/arm64/boot/dts/rockchip/Makefile":
            "dtb-$(CONFIG_ARCH_ROCKCHIP) += alpha.dtb\ndtb-y += gamma-plus.dtb delta.dtb\n",
        "arch/riscv/boot/dts/spacemit/beta.dts": "/dts-v1/;\n",
        "arch/riscv/boot/dts/spacemit/Makefile": "dtb-y += beta.dtb\n",
    }, "v9.1", env)
    ev_path = tmp_path / "evidence.json"
    ev_path.write_text(json.dumps({
        "schema": "mainline-evidence/v1",
        "trees": {"u-boot": {"url": uboot, "tag": "v2099.01", "commit": ""},
                  "linux": {"url": linux, "tag": "v9.1", "commit": ""}},
        "boards": [
            {"id": "alpha", "arch": "arm64", "dt": "rockchip/alpha"},     # default match
            {"id": "beta", "arch": "riscv64", "dt": "spacemit/beta"},     # OF_LIST match
            {"id": "gamma", "arch": "arm64", "dt": "rockchip/gamma"},     # no defconfig, no .dtb rule
            {"id": "delta", "arch": "arm64", "dt": "rockchip/delta"},     # defconfig, no U-Boot dts
            {"id": "eps", "arch": "arm64", "dt": "rockchip/eps"},         # nowhere
        ]}), encoding="utf-8")

    run = lambda *a: subprocess.run([sys.executable, SCRIPT, "--evidence", str(ev_path), *a],
                                    env=env, capture_output=True, text=True)
    first = run()
    assert first.returncode == 1 and "DRIFT" in first.stderr, first.stdout + first.stderr
    wrote = run("--write")
    assert wrote.returncode == 0, wrote.stdout + wrote.stderr
    ev = json.loads(ev_path.read_text(encoding="utf-8"))
    got = {b["id"]: b for b in ev["boards"]}

    assert got["alpha"]["verdict"] == FOUND
    assert got["alpha"]["u-boot"]["defconfig"] == "alpha-soc_defconfig"
    assert got["alpha"]["u-boot"]["match"] == "default"
    assert got["alpha"]["linux"]["makefile"] == "arch/arm64/boot/dts/rockchip/Makefile"
    assert got["beta"]["verdict"] == FOUND
    assert (got["beta"]["u-boot"]["defconfig"], got["beta"]["u-boot"]["match"]) == \
        ("multi_defconfig", "of-list")
    assert got["gamma"]["u-boot"]["status"] == NOT_FOUND
    assert "all 3 configs/*_defconfig at v2099.01" in got["gamma"]["u-boot"]["searched"]
    assert got["gamma"]["linux"]["status"] == NOT_FOUND          # gamma-plus.dtb is not gamma.dtb
    assert "does not build gamma.dtb" in got["gamma"]["linux"]["searched"]
    assert got["delta"]["u-boot"]["status"] == NOT_FOUND
    assert "configs/nodts_defconfig names it" in got["delta"]["u-boot"]["searched"]
    assert got["delta"]["linux"]["status"] == FOUND and got["delta"]["verdict"] == NOT_FOUND
    assert got["eps"]["linux"] == {"status": NOT_FOUND,
                                   "searched": "arch/arm64/boot/dts/rockchip/eps.dts at v9.1"}
    for key in ("u-boot", "linux"):
        commit = subprocess.run(["git", "rev-parse", "v9.1^{commit}" if key == "linux"
                                 else "v2099.01^{commit}"], cwd=tmp_path / key, env=env,
                                check=True, capture_output=True, text=True).stdout.strip()
        assert ev["trees"][key]["commit"] == commit, "must record the PEELED commit, not the tag"
    blob = subprocess.run(["git", "rev-parse", "HEAD:configs/alpha-soc_defconfig"],
                          cwd=tmp_path / "u-boot", env=env, check=True, capture_output=True,
                          text=True).stdout.strip()
    assert got["alpha"]["u-boot"]["blob"] == blob

    again = run()
    assert again.returncode == 0 and "evidence matches" in again.stdout, again.stderr
