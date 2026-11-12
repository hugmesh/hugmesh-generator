"""Size the named-file text-UI and CLI contract list on a BSD or SunOS guest.

hugmesh-generator#1048 (guest host-facts experiment). Two modes:

  candidates   ON THE RUNNER, before the guest boots: list every studio test file
               that never names a Qt binding or the GUI package. It is a static
               text scan and deliberately generous; the guest run is what decides.

                   python3 tests/guest-facts/size_contract.py candidates --repo . > LIST

  run          IN THE GUEST, inside the venv collect.sh built: run each listed file
               in its own pytest process (one file per process, as the Studio suite
               is run everywhere else) with a per-file timeout and an overall
               budget, and write one TSV row per file.

                   python tests/guest-facts/size_contract.py run --repo . --list LIST --out TSV

The verdict column is what the later PR job's named-file list is cut from:
  green     rc 0 with at least one passed test
  skipped   rc 0 and nothing passed (every test skipped on this host)
  red       rc 1, a test failed
  error     rc 2-4, collection or usage error (an import that does not exist here)
  empty     rc 5, nothing collected
  timeout   the file ran past --per-file seconds and was killed
  not-run   the overall --budget ran out first
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time

QT_OR_GUI = re.compile(
    r"\b(PySide6|PySide2|PyQt6|PyQt5|QtWidgets|QtCore|QtGui|QApplication|qtbot)\b"
    r"|hugmesh_studio\.gui\b|from\s+hugmesh_studio\s+import\s+[^\n]*\bgui\b"
    r"|from\s+\.\.?gui\b")

SUMMARY = re.compile(r"(\d+) (passed|failed|skipped|errors?|xfailed|xpassed|deselected|warnings?)")


def candidates(repo: str) -> list[str]:
    tests = os.path.join(repo, "studio", "tests")
    picked = []
    for name in sorted(os.listdir(tests)):
        if not (name.startswith("test_") and name.endswith(".py")):
            continue
        with open(os.path.join(tests, name), encoding="utf-8", errors="replace") as fh:
            if QT_OR_GUI.search(fh.read()):
                continue
        picked.append(f"tests/{name}")
    return picked


def _counts(text: str) -> dict[str, int]:
    counts = {"passed": 0, "failed": 0, "skipped": 0, "errors": 0}
    lines = [ln for ln in text.splitlines() if ln.strip()]
    for kind_n in SUMMARY.findall(lines[-1] if lines else ""):
        n, kind = int(kind_n[0]), kind_n[1]
        if kind.startswith("error"):
            counts["errors"] += n
        elif kind in counts:
            counts[kind] += n
    return counts


def _verdict(rc: int, counts: dict[str, int]) -> str:
    if rc == 0:
        return "green" if counts["passed"] else "skipped"
    return {1: "red", 5: "empty"}.get(rc, "error")


def run(repo: str, list_path: str, out_path: str, per_file: int, budget: int) -> int:
    studio = os.path.join(repo, "studio")
    with open(list_path, encoding="utf-8") as fh:
        files = [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]
    started = time.monotonic()
    rows = []
    for rel in files:
        if time.monotonic() - started > budget:
            rows.append((rel, "", "not-run", {"passed": 0, "failed": 0, "skipped": 0, "errors": 0},
                         0.0, f"budget of {budget}s spent"))
            continue
        t0 = time.monotonic()
        try:
            proc = subprocess.run(
                [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", rel],
                cwd=studio, capture_output=True, text=True, timeout=per_file,
                stdin=subprocess.DEVNULL)
            rc, text = proc.returncode, proc.stdout + proc.stderr
            counts = _counts(proc.stdout)
            verdict = _verdict(rc, counts)
        except subprocess.TimeoutExpired:
            rc, text, verdict = "", "", "timeout"
            counts = {"passed": 0, "failed": 0, "skipped": 0, "errors": 0}
        seconds = time.monotonic() - t0
        last = [ln for ln in text.splitlines() if ln.strip()][-1:] or [""]
        rows.append((rel, rc, verdict, counts, seconds, last[0].replace("\t", " ")[:200]))
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write("file\trc\tverdict\tpassed\tfailed\tskipped\terrors\tseconds\tsummary\n")
        for rel, rc, verdict, c, seconds, last in rows:
            fh.write(f"{rel}\t{rc}\t{verdict}\t{c['passed']}\t{c['failed']}\t{c['skipped']}\t"
                     f"{c['errors']}\t{seconds:.1f}\t{last}\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    c = sub.add_parser("candidates")
    c.add_argument("--repo", required=True)
    r = sub.add_parser("run")
    r.add_argument("--repo", required=True)
    r.add_argument("--list", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--per-file", type=int, default=180)
    r.add_argument("--budget", type=int, default=2400)
    args = ap.parse_args(argv)
    if args.mode == "candidates":
        for rel in candidates(os.path.abspath(args.repo)):
            print(rel)
        return 0
    return run(os.path.abspath(args.repo), args.list, args.out, args.per_file, args.budget)


if __name__ == "__main__":
    raise SystemExit(main())
