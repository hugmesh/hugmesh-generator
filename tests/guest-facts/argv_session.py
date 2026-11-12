"""Scripted plain-text-UI session and printed build command, with every child argv logged.

hugmesh-generator#1048 (guest host-facts experiment). Run by tests/guest-facts/collect.sh
inside a BSD or SunOS guest, and runnable on any host:

    python3 tests/guest-facts/argv_session.py --repo . --out OUTDIR

It changes no Studio code. Each step runs the REAL entry point in a child Python
process (real stdin pipe, real argv parsing) that first installs an audit hook, so
every process the Studio tries to start is written to OUTDIR/argv-log.jsonl with the
step that caused it:

  1. tui     ``python -m hugmesh_studio.tui --plain`` fed the standalone walk (eight
             Enters, ``s CONFIG``, ``q``), the same script test_tui_journey.py
             drives in-process;
  2. print   ``python -m hugmesh_studio --print-command --config CONFIG --backend docker``,
             the printed command a person hands to a Linux build host.

Only argv is logged, never the environment (it can carry secrets). The checkout path
is replaced by ``<repo>`` and OUTDIR by ``<out>`` so fixtures from different guests
compare as text. The exit status is 0 when both steps ran, whatever they printed;
their own return codes are in steps.tsv.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

AUDITED = ("subprocess.Popen", "os.system", "os.exec", "os.posix_spawn", "os.spawn",
           "os.startfile", "os.fork", "os.forkpty")

STANDALONE_WALK = ["", "", "", "", "", "", "", ""]


def _child(step: str, log_path: str, repo: str, out: str, module: str, argv: list[str]) -> None:
    """In the child: install the audit hook, then run MODULE as ``__main__``."""
    import runpy

    def scrub(value):
        text = os.fsdecode(value) if isinstance(value, (bytes, os.PathLike)) else str(value)
        return text.replace(out, "<out>").replace(repo, "<repo>")

    def hook(event, args):
        if event not in AUDITED:
            return
        if event == "subprocess.Popen":
            argv_ = args[1]
        elif event == "os.system":
            argv_ = args[0]
        elif event in ("os.exec", "os.posix_spawn"):
            argv_ = args[1]
        elif event == "os.spawn":
            argv_ = args[2]
        else:
            argv_ = list(args[:1])
        if isinstance(argv_, (str, bytes, os.PathLike)):
            argv_ = [argv_]
        record = {"step": step, "event": event,
                  "argv": [scrub(a) for a in (argv_ or [])]}
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, sort_keys=True) + "\n")

    sys.addaudithook(hook)
    sys.argv = [module] + argv
    runpy.run_module(module, run_name="__main__", alter_sys=True)


def _run_step(step: str, repo: str, out: str, module: str, argv: list[str],
              stdin_text: str, timeout: int) -> tuple[int, float]:
    studio = os.path.join(repo, "studio")
    log_path = os.path.join(out, "argv-log.jsonl")
    cmd = [sys.executable, os.path.abspath(__file__), "--child", step,
           "--repo", repo, "--out", out, "--module", module, "--"] + argv
    env = dict(os.environ)
    env["PYTHONPATH"] = studio + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    env.setdefault("NO_TUI", "1")
    t0 = time.monotonic()
    try:
        proc = subprocess.run(cmd, input=stdin_text, capture_output=True, text=True,
                              cwd=studio, env=env, timeout=timeout)
        rc, stdout, stderr = proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as exc:
        rc = 124
        stdout = exc.stdout.decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr = (exc.stderr.decode() if isinstance(exc.stderr, bytes) else (exc.stderr or "")) \
            + f"\n[argv_session] timed out after {timeout}s\n"
    seconds = time.monotonic() - t0
    for name, text in (("stdout", stdout), ("stderr", stderr)):
        with open(os.path.join(out, f"{step}.{name}.txt"), "w", encoding="utf-8") as fh:
            fh.write(text.replace(out, "<out>").replace(repo, "<repo>"))
    return rc, seconds


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", required=True, help="the hugmesh-generator checkout")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--timeout", type=int, default=300, help="seconds per step")
    ap.add_argument("--child", help=argparse.SUPPRESS)
    ap.add_argument("--module", help=argparse.SUPPRESS)
    ap.add_argument("rest", nargs=argparse.REMAINDER, help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    repo = os.path.abspath(args.repo)
    out = os.path.abspath(args.out)

    if args.child:
        rest = args.rest[1:] if args.rest[:1] == ["--"] else args.rest
        _child(args.child, os.path.join(out, "argv-log.jsonl"), repo, out, args.module, rest)
        return 0

    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, "argv-log.jsonl"), "w").close()
    config = os.path.join(out, "standalone.json")
    script = "\n".join(STANDALONE_WALK + [f"s {config}", "q"]) + "\n"
    steps = [
        ("tui", "hugmesh_studio.tui", ["--plain", "--generator-dir", repo], script),
        ("print", "hugmesh_studio", ["--print-command", "--config", config,
                                     "--backend", "docker", "--generator-dir", repo], ""),
    ]
    with open(os.path.join(out, "steps.tsv"), "w", encoding="utf-8") as fh:
        fh.write("step\trc\tseconds\targv\n")
        for step, module, step_argv, stdin_text in steps:
            rc, seconds = _run_step(step, repo, out, module, step_argv, stdin_text, args.timeout)
            shown = " ".join(["python", "-m", module] + step_argv)
            fh.write(f"{step}\t{rc}\t{seconds:.1f}\t"
                     f"{shown.replace(out, '<out>').replace(repo, '<repo>')}\n")
    if os.path.exists(config):
        with open(config, encoding="utf-8") as src:
            text = src.read()
        with open(config, "w", encoding="utf-8") as dst:
            dst.write(text.replace(out, "<out>").replace(repo, "<repo>"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
