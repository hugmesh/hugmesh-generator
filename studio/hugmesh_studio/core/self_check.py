"""``hugmesh-studio --self-check``: can this install run the generator's scripts?
(Qt-free, stdlib only)

The release workflow runs it inside the freshly built Flatpak, after ``--print-specs``,
because --print-specs never touches the generator tree and so passed on bundles that
could not build anything. It checks, and reports as text or ``--json``:

  * the generator dir the Studio resolved is a checkout, and in the Flatpak that it is
    the copy placed from the bundle's seed (core/managed_generator.py);
  * every generator path the Studio's own source names (core/generator_refs.py, run over
    the INSTALLED package) that the seed ships is present there;
  * every make target the Studio runs is defined in that tree's Makefile;
  * every shipped .sh the Studio names parses (``bash -n``);
  * in the Flatpak, whether flatpak-spawn --host reaches the host. That one is REPORTED,
    not counted: a headless CI runner has no session helper, and the bundle is not at
    fault for that.

Exit status 0 when every counted check passed, 1 otherwise.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

from . import flatpak_host, generator_dir, generator_refs, managed_generator

#: Paths the Studio's source names that are not paths in the GENERATOR tree: the org
#: export writes them into the repositories it creates. Each must still be named by the
#: source (tests/test_flatpak_generator_seed.py), so an entry cannot outlive its reason.
NOT_GENERATOR_PATHS = {
    ".github/maven-ci-settings.xml": "written into each exported org repository",
    ".github/workflows/build-all.yml": "the exported org's site repository workflow",
    ".github/workflows/pages.yml": "the exported org's site repository workflow",
}


def _present(rel: str, files: set[str], dirs: set[str]) -> bool:
    return rel in files or rel in dirs


def _dirs_of(files) -> set[str]:
    dirs: set[str] = set()
    for rel in files:
        parts = rel.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add("/".join(parts[:i]))
    return dirs


def check(gen_dir: str) -> dict:
    report: dict = {"generator_dir": gen_dir, "in_flatpak": flatpak_host.in_flatpak(),
                    "problems": []}
    problems: list[str] = report["problems"]
    seed = managed_generator.seed_dir()
    meta = managed_generator.seed_meta(seed) if seed else {}
    report["seed"] = ({"dir": seed, "version": meta.get("version"),
                       "commit": meta.get("commit"), "files": len(meta.get("files") or {})}
                      if seed else None)
    if report["in_flatpak"] and not seed:
        problems.append("this Flatpak carries no generator seed "
                        f"({os.path.join(sys.prefix, managed_generator.SEED_SUBDIR)})")
    if seed:
        placed = managed_generator.last if managed_generator.last.version else \
            managed_generator.ensure()
        report["placed"] = {"path": placed.path, "action": placed.action,
                            "error": placed.error}
        if placed.error:
            problems.append(placed.error)
    if not generator_dir.is_checkout(gen_dir):
        problems.append(generator_dir.not_a_checkout_message(gen_dir))
        return report

    if meta.get("files"):
        shipped = set(meta["files"])
    else:
        shipped = set()
        for directory, _dirs, names in os.walk(gen_dir):
            _dirs[:] = [d for d in _dirs if d not in (".git", "out", ".stack-src")]
            for name in names:
                shipped.add(os.path.relpath(os.path.join(directory, name), gen_dir)
                            .replace(os.sep, "/"))
    shipped_dirs = _dirs_of(shipped)
    top = {rel.split("/", 1)[0] for rel in shipped}
    refs = generator_refs.scan(top)
    missing, checked, scripts = [], 0, []
    for rel in sorted(refs.paths):
        if rel in NOT_GENERATOR_PATHS or not _present(rel, shipped, shipped_dirs):
            continue                      # runtime state, or not a generator path
        checked += 1
        if not os.path.exists(os.path.join(gen_dir, rel)):
            missing.append(rel)
        elif rel.endswith(".sh") and rel in shipped:
            scripts.append(rel)
    report["checked_paths"] = checked
    report["missing_paths"] = missing
    for rel in missing:
        problems.append(f"{rel} is missing from {gen_dir} "
                        f"(named at {', '.join(refs.paths[rel][:2])})")

    try:
        with open(os.path.join(gen_dir, "Makefile"), encoding="utf-8") as fh:
            defined = generator_refs.makefile_targets(fh.read())
    except OSError as exc:
        defined = set()
        problems.append(f"cannot read the Makefile in {gen_dir}: {exc}")
    missing_targets = sorted(t for t in refs.make_targets if t not in defined)
    report["make_targets"] = sorted(refs.make_targets)
    report["missing_make_targets"] = missing_targets
    for target in missing_targets:
        problems.append(f"make {target} is not defined in {gen_dir}/Makefile")

    syntax = []
    for rel in scripts:
        try:
            result = subprocess.run(["bash", "-n", os.path.join(gen_dir, rel)],
                                    capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError) as exc:
            syntax.append(f"{rel}: {exc}")
            continue
        if result.returncode != 0:
            syntax.append(f"{rel}: {result.stderr.strip()[:300]}")
    report["scripts_parsed"] = len(scripts)
    report["syntax_errors"] = syntax
    problems.extend(f"bash -n failed: {line}" for line in syntax)

    if report["in_flatpak"]:
        ok, why = flatpak_host.bridge_status()
        report["host_bridge"] = {"ok": ok, "error": why}
    return report


def run_cli(gen_dir: str, as_json: bool = False) -> int:
    report = check(gen_dir)
    report["ok"] = not report["problems"]
    if as_json:
        print(json.dumps(report, indent=1, sort_keys=True))
    else:
        print(f"generator dir: {report['generator_dir']}")
        if report.get("seed"):
            seed = report["seed"]
            print(f"bundled seed:  hugmesh-generator {seed['version']} "
                  f"({str(seed['commit'])[:12]}, {seed['files']} files)")
        print(f"paths checked: {report.get('checked_paths', 0)}, "
              f"scripts parsed: {report.get('scripts_parsed', 0)}, "
              f"make targets: {len(report.get('make_targets', []))}")
        bridge = report.get("host_bridge")
        if bridge is not None:
            print("host bridge:   " + ("ok" if bridge["ok"] else
                                       f"NOT reachable ({bridge['error']})"))
        for problem in report["problems"]:
            print(f"PROBLEM: {problem}")
        print("ok" if report["ok"] else "FAILED")
    return 0 if report["ok"] else 1
