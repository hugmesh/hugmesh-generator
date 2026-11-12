#!/usr/bin/env python3
"""Look up, per candidate board, the mainline U-Boot defconfig and kernel device tree.

The evidence file is ``studio/evidence/mainline-evidence.json``. It names two
upstream trees at release tags and, per board, the mainline device-tree name to look for
(``rockchip/rk3588-rock-5b``). This script clones each tree at its tag (shallow, no
blobs, ``configs/`` only) and records, per board:

* **U-Boot**: every ``configs/*_defconfig`` is read, and a defconfig matches when its
  ``CONFIG_DEFAULT_DEVICE_TREE`` or one of its ``CONFIG_OF_LIST`` entries names the
  board's device tree, in one of the two spellings U-Boot uses. A defconfig that names
  it as the default wins over one that only lists it. The source the spelling points
  at must also exist in U-Boot at the tag, or the match does not count (a defconfig
  that names a tree U-Boot cannot build is not a pair):

  - the upstream spelling ``<vendor>/<name>`` (``CONFIG_OF_UPSTREAM``) needs
    ``dts/upstream/src/<arch>/<vendor>/<name>.dts``;
  - the legacy bare spelling ``<name>`` needs ``arch/<u-boot arch>/dts/<name>.dts``.
    U-Boot keeps its own trees flat, and arm64 boards use ``arch/arm/dts``.

* **Linux**: ``arch/<arch>/boot/dts/<dt>.dts`` exists at the tag, AND a ``dtb-...``
  rule in that directory's Makefile builds ``<name>.dtb`` (not a commented-out rule,
  and not only an input to a composite ``<x>-dtbs :=`` overlay).

Each part is "found" (with the path and the git blob id at the tag) or "not found"
(with what was searched). A board's verdict is "found" only when both parts are.

    scripts/mainline-evidence.py           # look up, print the table, exit 1 on drift
    scripts/mainline-evidence.py --write   # look up and rewrite the evidence file

It needs network access to the two trees, so no test runs it against upstream.
``studio/tests/test_mainline_evidence.py`` checks the committed file offline, and runs
this script against small local git repositories to prove the lookup itself.

Evidence is necessary for promotion, never sufficient: a "found" pair says mainline
names the board, not that a builder supports it.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GENERATOR_DIR = os.path.dirname(HERE)
# Under studio/ so the Studio tests run when it changes; outside the package because
# the Studio does not read it at run time and must not ship it.
DEFAULT_EVIDENCE = os.path.join(GENERATOR_DIR, "studio", "evidence", "mainline-evidence.json")

# catalog arch -> the directory name the Linux tree (and U-Boot's dts/upstream copy of
# it) uses for it.
ARCH_DIRS = {"arm64": "arm64", "riscv64": "riscv", "armv7": "arm"}
# catalog arch -> U-Boot's own arch directory, which holds its legacy (non-upstream)
# trees. U-Boot has no arch/arm64: arm64 boards live under arch/arm.
UBOOT_ARCH_DIRS = {"arm64": "arm", "riscv64": "riscv", "armv7": "arm"}

FOUND = "found"
NOT_FOUND = "not found"

_KCONFIG_STR = re.compile(r'^(CONFIG_[A-Z0-9_]+)="([^"]*)"\s*$', re.M)


def defconfig_trees(text: str) -> tuple[str, list[str]]:
    """(default device tree, OF_LIST entries) from a defconfig's text."""
    vals = dict(_KCONFIG_STR.findall(text))
    default = vals.get("CONFIG_DEFAULT_DEVICE_TREE", "").strip()
    of_list = vals.get("CONFIG_OF_LIST", "").split()
    return default, of_list


def match_defconfigs(defconfigs: dict[str, str], dt: str) -> list[tuple[str, str, str]]:
    """Every (defconfig name, how, spelling) whose trees name ``dt``, as the upstream
    spelling (``dt`` itself, ``vendor/name``) or the legacy bare one (``name``).
    "default" matches come first, then "of-list", each group sorted by name."""
    base = dt.rsplit("/", 1)[-1]
    spellings = [dt] if base == dt else [dt, base]
    hits = []
    for name, text in defconfigs.items():
        default, of_list = defconfig_trees(text)
        if default in spellings:
            hits.append((0, name, "default", default))
        else:
            listed = next((sp for sp in spellings if sp in of_list), None)
            if listed is not None:
                hits.append((1, name, "of-list", listed))
    return [(n, how, sp) for _rank, n, how, sp in sorted(hits)]


def uboot_source(arch: str, spelling: str) -> str:
    """The U-Boot path a defconfig's tree name points at: the upstream copy for a
    ``vendor/name`` spelling, U-Boot's own flat directory for a bare ``name``."""
    if "/" in spelling:
        return f"dts/upstream/src/{ARCH_DIRS[arch]}/{spelling}.dts"
    return f"arch/{UBOOT_ARCH_DIRS[arch]}/dts/{spelling}.dts"


_DTB_RULE = re.compile(r"^dtb-(?:\$\([A-Za-z0-9_]+\)|[A-Za-z0-9_]*)\s*(?:\+=|:=|=)(.*)$")


def makefile_builds(text: str, dtb: str) -> bool:
    """True when a ``dtb-...`` rule in the kbuild Makefile ``text`` lists ``dtb``.
    Continuation lines are joined and comments dropped first; a ``<x>-dtbs :=``
    composite line is not a dtb rule, so a tree that is only an overlay input does
    not count."""
    joined = re.sub(r"\\\n", " ", text)
    for line in joined.splitlines():
        m = _DTB_RULE.match(line.split("#", 1)[0].strip())
        if m and dtb in m.group(1).split():
            return True
    return False


def _git(args: list[str], cwd: str | None = None) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                          text=True).stdout


def fetch_tree(url: str, tag: str, dest: str, sparse: list[str]) -> str:
    """Shallow, blobless clone of ``url`` at ``tag`` into ``dest``; check out only the
    ``sparse`` directories (one batched blob fetch). Returns the peeled commit id."""
    _git(["clone", "--quiet", "--depth", "1", "--filter=blob:none", "--no-checkout",
          "--branch", tag, url, dest])
    if sparse:
        _git(["sparse-checkout", "set", "--no-cone", *[f"/{d}/" for d in sparse]], cwd=dest)
        _git(["checkout", "--quiet"], cwd=dest)
    return _git(["rev-parse", "HEAD^{commit}"], cwd=dest).strip()


def _paths(repo: str, prefix: str) -> set[str]:
    out = _git(["ls-tree", "-r", "--name-only", "HEAD", "--", prefix], cwd=repo)
    return set(out.split())


def _blob(repo: str, path: str) -> str:
    return _git(["rev-parse", f"HEAD:{path}"], cwd=repo).strip()


def _show(repo: str, path: str) -> str:
    return _git(["show", f"HEAD:{path}"], cwd=repo)


def lookup_uboot(repo: str, tag: str, arch: str, dt: str) -> dict:
    cfg_dir = os.path.join(repo, "configs")
    defconfigs = {}
    for name in sorted(os.listdir(cfg_dir)):
        if name.endswith("_defconfig"):
            with open(os.path.join(cfg_dir, name), encoding="utf-8", errors="replace") as fh:
                defconfigs[name] = fh.read()
    hits = match_defconfigs(defconfigs, dt)
    present = (_paths(repo, f"dts/upstream/src/{ARCH_DIRS[arch]}")
               | _paths(repo, f"arch/{UBOOT_ARCH_DIRS[arch]}/dts"))
    base = dt.rsplit("/", 1)[-1]
    spelled = dt if base == dt else f"{dt} (or legacy {base})"
    searched = (f"all {len(defconfigs)} configs/*_defconfig at {tag}, for {spelled} as "
                "CONFIG_DEFAULT_DEVICE_TREE or in CONFIG_OF_LIST")
    if not hits:
        return {"status": NOT_FOUND, "searched": searched}
    paired = [(n, how, sp) for n, how, sp in hits if uboot_source(arch, sp) in present]
    if not paired:
        name, _how, sp = hits[0]
        return {"status": NOT_FOUND,
                "searched": (f"{searched}: configs/{name} names {sp}, but no "
                             f"{uboot_source(arch, sp)} exists at {tag}")}
    name, how, sp = paired[0]
    return {
        "status": FOUND,
        "defconfig": name,
        "path": f"configs/{name}",
        "blob": _blob(repo, f"configs/{name}"),
        "match": how,
        "names": sp,
        "dt_source": uboot_source(arch, sp),
        "also": [n for n, _h, _s in paired[1:]],
    }


def lookup_linux(repo: str, tag: str, arch: str, dt: str) -> dict:
    adir = ARCH_DIRS[arch]
    vendor_dir = f"arch/{adir}/boot/dts/{dt.rsplit('/', 1)[0]}"
    base = dt.rsplit("/", 1)[-1]
    dts = f"arch/{adir}/boot/dts/{dt}.dts"
    present = _paths(repo, vendor_dir)
    if dts not in present:
        return {"status": NOT_FOUND, "searched": f"{dts} at {tag}"}
    makefile = f"{vendor_dir}/Makefile"
    if makefile not in present or not makefile_builds(_show(repo, makefile), f"{base}.dtb"):
        return {"status": NOT_FOUND,
                "searched": f"{dts} exists at {tag}, but no dtb rule in {makefile} builds {base}.dtb"}
    return {"status": FOUND, "path": dts, "blob": _blob(repo, dts), "makefile": makefile}


def lookup(evidence: dict, workdir: str) -> dict:
    """A fresh copy of ``evidence`` with every tree commit and board result looked up."""
    fresh = json.loads(json.dumps(evidence))
    repos = {}
    for key, sparse in (("u-boot", ["configs"]), ("linux", [])):
        tree = fresh["trees"][key]
        dest = os.path.join(workdir, key)
        tree["commit"] = fetch_tree(tree["url"], tree["tag"], dest, sparse)
        repos[key] = dest
    for b in fresh["boards"]:
        b["u-boot"] = lookup_uboot(repos["u-boot"], fresh["trees"]["u-boot"]["tag"],
                                   b["arch"], b["dt"])
        b["linux"] = lookup_linux(repos["linux"], fresh["trees"]["linux"]["tag"],
                                  b["arch"], b["dt"])
        b["verdict"] = (FOUND if b["u-boot"]["status"] == FOUND
                        and b["linux"]["status"] == FOUND else NOT_FOUND)
    return fresh


def table(evidence: dict) -> str:
    rows = [f"{'board':<14} {'u-boot':<10} {'linux':<10} verdict   defconfig / dts"]
    for b in evidence["boards"]:
        u, k = b["u-boot"], b["linux"]
        detail = f"{u.get('defconfig', '-')} ({u.get('match', '-')}) / {k.get('path', '-')}"
        rows.append(f"{b['id']:<14} {u['status']:<10} {k['status']:<10} "
                    f"{b['verdict']:<9} {detail}")
    return "\n".join(rows)


def dump(evidence: dict) -> str:
    return json.dumps(evidence, indent=2, ensure_ascii=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--evidence", default=DEFAULT_EVIDENCE, help="evidence JSON file")
    ap.add_argument("--write", action="store_true",
                    help="rewrite the evidence file with the looked-up results")
    args = ap.parse_args(argv)

    with open(args.evidence, encoding="utf-8") as fh:
        committed = json.load(fh)
    with tempfile.TemporaryDirectory(prefix="mainline-evidence-") as work:
        fresh = lookup(committed, work)
    print(table(fresh))
    if args.write:
        with open(args.evidence, "w", encoding="utf-8") as fh:
            fh.write(dump(fresh))
        print(f"wrote {os.path.relpath(args.evidence, GENERATOR_DIR)}")
        return 0
    if fresh != committed:
        print("DRIFT: the committed evidence differs from what the upstream trees say; "
              "re-run with --write and review the diff", file=sys.stderr)
        return 1
    print("evidence matches the upstream trees")
    return 0


if __name__ == "__main__":
    sys.exit(main())
