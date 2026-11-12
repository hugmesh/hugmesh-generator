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
    fault for that;
  * on macOS, that bash 4+ and the GNU tools the scripts are written for are on PATH
    (COUNTED: without them every script dies on a BSD flag, and ``bash -n`` itself is
    skipped when only macOS's bash 3.2 is there, because 3.2 would report bash 4 syntax
    as errors in scripts that are fine), plus the Docker runtime, the Mac's architecture
    and the state dir's mode (REPORTED).

Exit status 0 when every counted check passed, 1 otherwise.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

from . import flatpak_host, generator_dir, generator_refs, managed_generator, platform_info

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


def macos_report(*, which=None, run=None) -> dict:
    """What a Mac needs to run the generator's scripts, probed now (core/macos_host)."""
    from . import macos_host, state_paths
    missing = macos_host.gnu_userland_missing(which=which, run=run)
    vm = macos_host.docker_vm(which=which, run=run)
    state = state_paths.state_dir()
    try:
        mode = oct(os.stat(state).st_mode & 0o777)
    except OSError:
        mode = "absent"
    return {"arch": macos_host.mac_arch(run=run), "gnu_missing": missing,
            "bash_major": macos_host.bash_major(which=which, run=run),
            "docker_runtime": vm.runtime or "none", "docker_vm_mem": vm.mem_bytes,
            "state_dir": state, "state_dir_mode": mode}


def check(gen_dir: str, *, sysplatform: str | None = None, mac_probe=None) -> dict:
    report: dict = {"generator_dir": gen_dir, "in_flatpak": flatpak_host.in_flatpak(),
                    "problems": []}
    problems: list[str] = report["problems"]
    on_mac = platform_info.host_kind(sysplatform=sysplatform) == "darwin"
    if on_mac:
        report["macos"] = (mac_probe or macos_report)()
        gnu = report["macos"]["gnu_missing"]
        if gnu:
            problems.append(platform_info.host_script_blocker(
                "The generator", runs="bash scripts and make", sysplatform="darwin",
                gnu_missing=gnu))
    seed = managed_generator.seed_dir()
    meta = managed_generator.seed_meta(seed) if seed else {}
    report["seed"] = ({"dir": seed, "version": meta.get("version"),
                       "commit": meta.get("commit"), "files": len(meta.get("files") or {})}
                      if seed else None)
    if report["in_flatpak"] and not seed:
        problems.append("this Flatpak carries no generator seed (looked in "
                        f"{', '.join(managed_generator.seed_candidates())})")
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
    # The repository's top level as the seed recorded it (a directory cut from the seed
    # still counts), else what is on disk.
    top = set(meta.get("top") or ()) | {rel.split("/", 1)[0] for rel in shipped}
    refs = generator_refs.scan(top)
    # A frozen build (the MSI, the tarball, the macOS app) carries bytecode only, and
    # the scan reads source: it finds nothing, so "0 paths checked, ok" would be a pass
    # that checked nothing. Said, not counted: the bundle is not broken, the check is
    # just unavailable in it.
    report["refs_unavailable"] = bool(getattr(sys, "frozen", False)) and not refs.paths
    missing, checked, scripts = [], 0, []
    for rel in sorted(refs.paths):
        if rel in NOT_GENERATOR_PATHS:
            continue
        if not _present(rel, shipped, shipped_dirs):
            first = rel.split("/", 1)[0]
            cut = [c for c in meta.get("excluded") or () if rel == c or rel.startswith(c + "/")]
            if meta.get("files") and (cut or (first not in shipped_dirs
                                              and first not in shipped)):
                # the seed was cut (make_generator_seed.EXCLUDE) under a path the
                # Studio uses
                missing.append(rel)
            continue                      # runtime state the Studio writes
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
    if on_mac and report["macos"]["bash_major"] < 4:
        # macOS's own bash 3.2 reports bash 4 syntax as errors; the missing bash is
        # already the problem above, so the scripts are not parsed with the wrong one.
        report["scripts_skipped"] = len(scripts)
        scripts = []
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
        if report.get("refs_unavailable"):
            print("note:          this frozen build carries no Python sources, so the "
                  "generator paths the Studio names were not listed; run --self-check "
                  "from a checkout for that part")
        mac = report.get("macos")
        if mac is not None:
            vm = (f"{mac['docker_runtime']}, {mac['docker_vm_mem'] / 2**30:.0f} GiB VM"
                  if mac["docker_vm_mem"] else mac["docker_runtime"])
            print(f"macOS:         {mac['arch']}, bash {mac['bash_major'] or 'missing'}, "
                  f"GNU tools {'ok' if not mac['gnu_missing'] else 'MISSING'}, docker {vm}, "
                  f"state dir {mac['state_dir_mode']}")
        bridge = report.get("host_bridge")
        if bridge is not None:
            print("host bridge:   " + ("ok" if bridge["ok"] else
                                       f"NOT reachable ({bridge['error']})"))
        for problem in report["problems"]:
            print(f"PROBLEM: {problem}")
        print("ok" if report["ok"] else "FAILED")
    return 0 if report["ok"] else 1
