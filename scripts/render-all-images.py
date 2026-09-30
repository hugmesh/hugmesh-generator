#!/usr/bin/env python3
"""Render-prove EVERY inventory image on every channel that claims it — plan level only.

``docs/catalog/image-inventory.json`` records, per advertised image, which build channels
claim to express it. ``tests/build-matrix/inventory-check.sh`` re-proves the CLI and JOB
*verdicts*; this script goes one level deeper and proves each claimed channel actually
RENDERS a coherent build plan for the image, per image, on four channels:

  cli       the platform builder's ``--print-plan`` exits 0 for BOTH envs (test + prod)
            and the plan names the record's own platform/role/board/flavor/desktop
  make      ``make -n <target> NATIVE=1 ENV=test <axis vars>`` renders the dispatch; a
            first-class (yes) claim must carry every axis flag, an escape-hatch claim is
            re-proved by rendering again with ``STANDALONE_FLAGS='<missing flags>'`` and
            requiring the full argv to appear (the claim IS "reachable via
            STANDALONE_FLAGS", so this renders that exact reachability)
  studio    two sub-channels, both against the REAL Studio:
              gui       ``python3 -m hugmesh_studio --print-command`` (subprocess,
                        offscreen, isolated state dir) exits 0 and the printed command
                        carries every axis flag
              worklist  a one-entry ``hugmesh-worklist/v1`` envelope through the REAL
                        WorklistDriver: ``materialize()`` must yield exactly one config
                        and ``command_string()`` must carry every axis flag
  job       ``docker/build-image.sh`` itself (POSIX sh, BUILD_IMAGE_SH_PRINT_ONLY=1 —
            the committed CI preview hatch) with the record's legacy
            IMAGE_TYPE/HARDWARE_CLASS env: the grammar must accept the job string, and
            the assembled argv between the __BUILDER_ARGV_*__ markers must name the
            record's builder/role/board/flavor. escape-hatch claims are rendered with
            their recorded accepted IMAGE_TYPE instead of the mode-natural one.

Plus the MESH worklist guarantee: mesh worklists must materialize EVERY entry — one
envelope per platform holding all of that platform's mesh images, and one all-platform
envelope holding every mesh image, each driven through WorklistDriver.materialize() +
manifest_v2(); every entry must project and render.

A channel that does NOT claim an image (phantom cli=no, job=no) is recorded as skipped
with the inventory's own reason — never silently green.

Everything here is dry-run by construction (--print-plan / make -n / command printing /
PRINT_ONLY). Nothing builds, nothing needs root, docker, or network.

Usage:
  python3 scripts/render-all-images.py [--generator-dir DIR] [--out report.json]
                                       [--jobs N] [--quiet]
Exit: 0 iff every claimed channel rendered green for every image.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
_GEN_ROOT = os.path.dirname(_HERE)

INVENTORY = os.path.join("docs", "catalog", "image-inventory.json")
REPORT_SCHEMA = "hugmesh-image-render-report/v1"


def load_emitter(gen: str):
    """Import scripts/emit-image-inventory.py as a module — argv/axis vocabulary is
    single-sourced from the emitter, never restated here."""
    path = os.path.join(gen, "scripts", "emit-image-inventory.py")
    spec = importlib.util.spec_from_file_location("emit_image_inventory", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


# ── channel 1: CLI --print-plan (both envs) ──────────────────────────────────────────
def render_cli(gen: str, emit, rec: dict) -> dict:
    if rec["channels"]["cli"] != "yes":
        return {"status": "skipped",
                "reason": f"cli={rec['channels']['cli']}: "
                          f"{rec['channel_notes'].get('cli', 'not claimed')}"}
    builder = emit.BUILDER[rec["platform"]]
    for env in rec["envs"]:
        argv = ["bash", os.path.join(gen, builder)] + emit.cli_args(rec) + \
               ["--env", env, "--print-plan"]
        res = subprocess.run(argv, cwd=gen, capture_output=True, text=True,
                             stdin=subprocess.DEVNULL)
        if res.returncode != 0:
            tail = (res.stderr or res.stdout).strip().splitlines()[-1:]
            return {"status": "fail", "env": env,
                    "error": f"--print-plan rc={res.returncode}: {' '.join(tail)[:200]}"}
        plan = dict(l.split("=", 1) for l in res.stdout.splitlines()
                    if l.startswith("PLAN_") and "=" in l)
        bad = []
        if plan.get("PLAN_PLATFORM") != rec["plan_platform"]:
            bad.append(f"PLAN_PLATFORM={plan.get('PLAN_PLATFORM')} "
                       f"(want {rec['plan_platform']})")
        if plan.get("PLAN_ROLE") != rec["plan_role"]:
            bad.append(f"PLAN_ROLE={plan.get('PLAN_ROLE')} (want {rec['plan_role']})")
        mism = emit.plan_mismatch(rec, plan)
        if mism:
            bad.append(mism)
        if bad:
            return {"status": "fail", "env": env, "error": "; ".join(bad)[:300]}
    return {"status": "pass", "envs": list(rec["envs"])}


# ── channel 2: make -n (+ STANDALONE_FLAGS re-render for escape-hatch claims) ────────
_ESCAPE_FLAG = {
    "--skip-mesh (standalone posture)": "--skip-mesh",
    "--no-sso (standalone posture)": "--no-tailscale --no-sso",
}


def render_make(gen: str, emit, rec: dict) -> dict:
    claim = rec["channels"]["make"]
    target, axvars = emit.make_target(rec)
    argv = ["make", "-n", target, "NATIVE=1", "ENV=test"] + \
           [f"{k}={v}" for k, v in sorted(axvars.items())]
    res = subprocess.run(argv, cwd=gen, capture_output=True, text=True,
                         stdin=subprocess.DEVNULL)
    if res.returncode != 0:
        tail = (res.stderr or res.stdout).strip().splitlines()[-1:]
        return {"status": "fail", "target": target,
                "error": f"make -n rc={res.returncode}: {' '.join(tail)[:200]}"}
    miss = emit.argv_missing(rec, res.stdout, make_channel=True)
    if claim == "yes":
        if miss:
            return {"status": "fail", "target": target,
                    "error": f"claimed make=yes but the recipe omits: {miss}"}
        return {"status": "pass", "target": target}
    # escape-hatch: the recorded claim is "reachable only via STANDALONE_FLAGS" — render
    # exactly that: pass the missing flags through the hatch and require a complete argv.
    flags = " ".join(_ESCAPE_FLAG.get(m, m) for m in miss.split(", ") if m)
    if not flags:
        return {"status": "fail", "target": target,
                "error": "claimed make=escape-hatch but the plain recipe already "
                         "carries every axis flag — stale claim, regenerate the "
                         "inventory"}
    res2 = subprocess.run(argv + [f"STANDALONE_FLAGS={flags}"], cwd=gen,
                          capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if res2.returncode != 0:
        tail = (res2.stderr or res2.stdout).strip().splitlines()[-1:]
        return {"status": "fail", "target": target,
                "error": f"make -n STANDALONE_FLAGS rc={res2.returncode}: "
                         f"{' '.join(tail)[:200]}"}
    miss2 = emit.argv_missing(rec, res2.stdout, make_channel=True)
    if miss2:
        return {"status": "fail", "target": target,
                "error": f"escape-hatch STANDALONE_FLAGS='{flags}' still omits: {miss2}"}
    return {"status": "pass", "target": target, "via": f"STANDALONE_FLAGS={flags}"}


# ── channel 3a: Studio --print-command (subprocess, offscreen, isolated state) ───────
def render_gui(gen: str, emit, rec: dict, python: str, tmpdir: str) -> dict:
    if rec["channels"]["gui"] != "yes":
        return {"status": "skipped",
                "reason": f"gui={rec['channels']['gui']}: "
                          f"{rec['channel_notes'].get('gui', 'not claimed')}"}
    slug = rec["id"].replace("/", "_")
    cpath = os.path.join(tmpdir, f"gui-{slug}.json")
    state = os.path.join(tmpdir, f"state-{slug}")
    with open(cpath, "w", encoding="utf-8") as fh:
        json.dump(emit.gui_config(rec), fh)
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen",
               HUGMESH_STUDIO_STATE_DIR=state,
               HUGMESH_STUDIO_NO_ELEVATION="1")   # #304: a headless driver must never elevate
    res = subprocess.run(
        [python, "-m", "hugmesh_studio", "--print-command", "--config", cpath,
         "--backend", "native", "--generator-dir", gen],
        cwd=os.path.join(gen, "studio"), env=env, capture_output=True, text=True,
        stdin=subprocess.DEVNULL)
    if res.returncode != 0:
        tail = res.stderr.strip().splitlines()[-1:]
        return {"status": "fail",
                "error": f"--print-command rc={res.returncode}: {' '.join(tail)[:200]}"}
    miss = emit.argv_missing(rec, res.stdout)
    if miss:
        return {"status": "fail", "error": f"--print-command omits: {miss}"}
    return {"status": "pass"}


# ── channel 3b: Studio WorklistDriver (in-process, one-entry envelope) ───────────────
def render_worklist(gen: str, emit, rec: dict, tmpdir: str, host) -> dict:
    if rec["channels"]["worklist"] != "yes":
        return {"status": "skipped",
                "reason": f"worklist={rec['channels']['worklist']}: "
                          f"{rec['channel_notes'].get('worklist', 'not claimed')}"}
    from hugmesh_studio.core.worklist import load_any
    from hugmesh_studio.core.worklist_driver import WorklistDriver
    slug = rec["id"].replace("/", "_")
    wpath = os.path.join(tmpdir, f"wl-{slug}.json")
    with open(wpath, "w", encoding="utf-8") as fh:
        json.dump(emit.worklist_envelope(rec), fh)
    try:
        _base, wl = load_any(wpath)
        if wl is None:
            return {"status": "fail", "error": "envelope loaded as a FLAT config"}
        driver = WorklistDriver(gen, wl, host=host, backend="native",
                                generate_keys=False)
        mat = driver.materialize()
        if len(mat) != 1:
            return {"status": "fail",
                    "error": f"materialized {len(mat)} images (want 1)"}
        cmd = driver.command_string(mat[0][1], "native")
        miss = emit.argv_missing(rec, cmd)
        if miss:
            return {"status": "fail", "error": f"materialized command omits: {miss}"}
    except Exception as exc:                                        # noqa: BLE001
        return {"status": "fail", "error": f"{type(exc).__name__}: {exc}"[:200]}
    return {"status": "pass"}


# ── channel 4: docker/build-image.sh job grammar (PRINT_ONLY parse path) ─────────────
def render_job(gen: str, emit, rec: dict, tmpdir: str) -> dict:
    claim = rec["channels"]["job"]
    if claim not in ("yes", "escape-hatch"):
        return {"status": "skipped",
                "reason": f"job={claim}: {rec['channel_notes'].get('job', 'not claimed')}"}
    natural = rec["job_token"]["IMAGE_TYPE"]
    if claim == "yes":
        itype = natural
    else:
        accepted = rec["job_token"]["accepted_image_types"]
        if not accepted:
            return {"status": "fail",
                    "error": "claimed job=escape-hatch but no accepted IMAGE_TYPE "
                             "recorded"}
        itype = accepted[0]
    env = dict(os.environ,
               BUILD_IMAGE_SH_PRINT_ONLY="1",
               GENERATOR_DIR=gen,
               BUILD_ID="renderprobe",
               TARGET_USER="render",
               DOMAIN="hugmesh.test",
               IMAGE_TYPE=itype,
               HARDWARE_CLASS=rec["job_token"]["HARDWARE_CLASS"],
               SSH_KEYS_ALLOWED="false",
               INGEST_URL="http://ingest.invalid/x",
               ARTIFACT_DIR="/artifacts/build-renderprobe",
               SCRATCH_PARENT=os.path.join(tmpdir, "jobscratch"))
    res = subprocess.run(["sh", os.path.join(gen, "docker", "build-image.sh")],
                         cwd=gen, env=env, capture_output=True, text=True,
                         stdin=subprocess.DEVNULL)
    if res.returncode != 0:
        tail = (res.stderr or res.stdout).strip().splitlines()[-1:]
        return {"status": "fail", "image_type": itype,
                "error": f"grammar REJECTED (rc={res.returncode}): "
                         f"{' '.join(tail)[:220]}"}
    lines = res.stdout.splitlines()
    try:
        argv = lines[lines.index("__BUILDER_ARGV_BEGIN__") + 1:
                     lines.index("__BUILDER_ARGV_END__")]
    except ValueError:
        return {"status": "fail", "image_type": itype,
                "error": "rc=0 but no __BUILDER_ARGV__ markers — PRINT_ONLY did not "
                         "reach dispatch_builder"}
    bad = []
    builder = emit.BUILDER[rec["platform"]]
    if not argv or os.path.basename(argv[0]) != builder:
        bad.append(f"argv[0]={argv[0] if argv else '<empty>'} (want {builder})")
    pairs = {argv[i]: argv[i + 1] for i in range(len(argv) - 1)}
    if rec["builder_role"] and pairs.get("--role") != rec["builder_role"]:
        # rpi5 standalone rides --standalone on the base desktop role, not a
        # standalone-* --role token — accept the documented projection.
        if not (rec["mode"] == "standalone" and "--standalone" in argv):
            bad.append(f"--role {pairs.get('--role')} (want {rec['builder_role']})")
    if rec["board"] and pairs.get("--board", rec["board"]) != rec["board"]:
        bad.append(f"--board {pairs.get('--board')} (want {rec['board']})")
    if rec["flavor"]:
        got = pairs.get("--flavor", rec["flavor"])
        if got != rec["flavor"] and not (rec["mode"] == "standalone"
                                         and got == "installer"):
            bad.append(f"--flavor {got} (want {rec['flavor']})")
    if rec["mode"] == "standalone" and rec["platform"] != "x86" \
            and "--standalone" not in argv:
        bad.append("--standalone missing (standalone posture)")
    if bad:
        return {"status": "fail", "image_type": itype,
                "error": "assembled argv wrong: " + "; ".join(bad)[:300]}
    return {"status": "pass", "image_type": itype}


# ── the mesh worklist guarantee: EVERY entry materializes ────────────────────────────
def render_mesh_worklists(gen: str, emit, images: list[dict], tmpdir: str,
                          host) -> dict:
    from hugmesh_studio.core.worklist import load_any
    from hugmesh_studio.core.worklist_driver import WorklistDriver
    mesh = [r for r in images if r["mode"] == "mesh"]
    groups: dict[str, list[dict]] = {"__all__": mesh}
    for r in mesh:
        groups.setdefault(r["platform"], []).append(r)
    out: dict[str, dict] = {}
    for gname, recs in sorted(groups.items()):
        entries = []
        for r in recs:
            e = {"role": r["role"], "platform": r["platform"],
                 "id": r["id"].replace("/", ".")}      # explicit UNIQUE id per image
            for axis in emit.AXIS_ORDER:
                if r[axis]:
                    e[axis] = r[axis]
            entries.append(e)
        env = {"schema": "hugmesh-worklist/v1", "mode": "mesh", "env": "test",
               "entries": entries}
        wpath = os.path.join(tmpdir, f"mesh-wl-{gname.replace('__', 'x')}.json")
        with open(wpath, "w", encoding="utf-8") as fh:
            json.dump(env, fh)
        try:
            _base, wl = load_any(wpath)
            driver = WorklistDriver(gen, wl, host=host, backend="native",
                                    generate_keys=False)
            mat = driver.materialize()
            if len(mat) != len(entries):
                out[gname] = {"status": "fail", "entries": len(entries),
                              "error": f"materialized {len(mat)} of "
                                       f"{len(entries)} entries"}
                continue
            misses = []
            for (entry, cfg), r in zip(mat, recs):
                miss = emit.argv_missing(r, driver.command_string(cfg, "native"))
                if miss:
                    misses.append(f"{entry.id}: omits {miss}")
            manifest = driver.manifest_v2()
            if len(manifest["images"]) != len(entries):
                misses.append(f"manifest_v2 lists {len(manifest['images'])} images "
                              f"(want {len(entries)})")
            if misses:
                out[gname] = {"status": "fail", "entries": len(entries),
                              "error": "; ".join(misses)[:400]}
            else:
                out[gname] = {"status": "pass", "entries": len(entries)}
        except Exception as exc:                                    # noqa: BLE001
            out[gname] = {"status": "fail", "entries": len(entries),
                          "error": f"{type(exc).__name__}: {exc}"[:200]}
    return out


CHANNELS = ("cli", "make", "gui", "worklist", "job")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--generator-dir", default=_GEN_ROOT)
    ap.add_argument("--out", default=None,
                    help="report JSON path (default: docs/catalog/"
                         "image-render-report.json under --generator-dir)")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)
    gen = os.path.abspath(args.generator_dir)
    sys.path.insert(0, os.path.join(gen, "studio"))
    emit = load_emitter(gen)

    inv = json.load(open(os.path.join(gen, INVENTORY), encoding="utf-8"))
    images = inv["images"]
    # vacuous-green guard: a truncated/empty inventory must never render an empty pass
    if not images or len(images) != inv["image_count"]:
        print(f"render-all-images: inventory declares image_count={inv['image_count']} "
              f"but carries {len(images)} records — refusing to render a vacuous pass",
              file=sys.stderr)
        return 2

    tmp = tempfile.mkdtemp(prefix="render-all-images-")
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    os.environ["HUGMESH_STUDIO_NO_ELEVATION"] = "1"   # #304: forced, not setdefault
    os.environ.setdefault("HUGMESH_STUDIO_STATE_DIR", os.path.join(tmp, "state"))

    from hugmesh_studio.core.platform_info import detect
    host = detect()

    # subprocess-heavy legs in a thread pool; the in-process worklist legs after, on the
    # main thread (WorklistDriver/host detection are not asserted thread-safe).
    def probe(rec: dict) -> tuple[str, dict]:
        return rec["id"], {
            "cli": render_cli(gen, emit, rec),
            "make": render_make(gen, emit, rec),
            "gui": render_gui(gen, emit, rec, sys.executable, tmp),
            "job": render_job(gen, emit, rec, tmp),
        }

    results: dict[str, dict] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for iid, res in ex.map(probe, images):
            results[iid] = res
            if not args.quiet:
                flags = "".join(
                    {"pass": ".", "fail": "X", "skipped": "-"}[res[c]["status"]]
                    for c in ("cli", "make", "gui", "job"))
                print(f"  [{flags}] {iid}", file=sys.stderr)

    for rec in images:
        results[rec["id"]]["worklist"] = render_worklist(gen, emit, rec, tmp, host)

    mesh_wl = render_mesh_worklists(gen, emit, images, tmp, host)

    per_channel = {c: {"pass": 0, "fail": 0, "skipped": 0} for c in CHANNELS}
    failures = []
    for rec in images:
        for c in CHANNELS:
            r = results[rec["id"]][c]
            per_channel[c][r["status"]] += 1
            if r["status"] == "fail":
                failures.append({"image": rec["id"], "channel": c,
                                 "error": r.get("error", "")})
    for gname, r in mesh_wl.items():
        if r["status"] == "fail":
            failures.append({"image": f"mesh-worklist[{gname}]",
                             "channel": "worklist", "error": r.get("error", "")})

    report = {
        "schema": REPORT_SCHEMA,
        "generated_by": "scripts/render-all-images.py",
        "inventory_schema": inv["schema"],
        "image_count": len(images),
        "per_channel": per_channel,
        "mesh_worklists": {g: {"status": r["status"], "entries": r["entries"]}
                           for g, r in mesh_wl.items()},
        "failures": failures,
        "images": {iid: results[iid] for iid in sorted(results)},
    }
    out = args.out or os.path.join(gen, "docs", "catalog", "image-render-report.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, sort_keys=True)
        fh.write("\n")

    total_pass = sum(per_channel[c]["pass"] for c in CHANNELS)
    total_skip = sum(per_channel[c]["skipped"] for c in CHANNELS)
    print(f"render-all-images: {len(images)} images; per-channel "
          + " ".join(f"{c}={per_channel[c]['pass']}/{per_channel[c]['fail']}"
                     f"/{per_channel[c]['skipped']}" for c in CHANNELS)
          + f"; mesh-worklists={sum(1 for r in mesh_wl.values() if r['status'] == 'pass')}"
            f"/{len(mesh_wl)}; TOTAL pass={total_pass} fail={len(failures)} "
            f"skip={total_skip}")
    print(f"wrote {out}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
