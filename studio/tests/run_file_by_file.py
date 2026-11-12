"""Run the Studio suite ONE FILE PER PROCESS: the way it finishes with a Qt binding.

With a Qt binding installed, one process running the whole suite aborts part-way
(SIGABRT/SIGSEGV in Qt's event-loop teardown; .github/workflows/studio-tests.yml's
pytest job says so), so that job installs no binding, ignores six GUI files and lets
every other GUI test importorskip. Every GUI test was therefore green on a pull
request whatever it did, and on 2026-11-11 five Qt test files were red on main with
nobody seeing it. This is the runner of the job that ends that: every
``tests/**/test_*.py`` in its own interpreter, and the job's verdict is every file's.

    QT_QPA_PLATFORM=offscreen python tests/run_file_by_file.py --require-qt --shard 1/4

``--require-qt`` refuses to run anything unless THIS interpreter (the one every child
runs under) imports the Studio's Qt shim and shows a widget on an offscreen
QApplication, and it fails any file whose skip reasons still name a missing Qt binding:
a Qt job whose GUI tests all skip is green and blind, the very defect it exists for.

``--known FILE`` (tests/known-qt-failures.txt) names what was ALREADY red on main when
this job was added, so the job grades the change under review and not that backlog, and
says so on every run rather than hiding it:

* ``tests/x.py::test_y[id]  # why`` is deselected from the file's run, so the rest of
  the file still gates; then it is run on its own and reported (still failing, or
  passing: delete the line). An entry that deselects nothing is red: pytest silently
  ignores a ``--deselect`` that matches no test, and a mute that mutes nothing hides rot.
* ``tests/x.py  exit-abort  # why``: the file's tests gate as usual, but an interpreter
  that aborts at EXIT after a summary with no failure (PySide6's qFatal on a QThread
  still running at teardown) is reported, not red. Any other crash of it is red.

Run from studio/ (pytest.ini's rootdir). Exit 0 when every file passed, 1 when any
did not, 2 when the run could not start (a usage error, a malformed known list or the Qt
preflight).
"""
from __future__ import annotations

import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

#: What a skip reason says when the Studio's Qt shim did not import. The suite's own
#: reasons say "no Qt binding ..." (five spellings, one "... need a Qt binding"), and a
#: bare ``importorskip`` says "could not import 'hugmesh_studio.gui.qt'". A case that
#: pins ONE binding by name ("no PyQt6 binding installed") is not matched: under the
#: other binding that skip is the case's own design, not a blind job.
_NO_QT = re.compile(r"\bno Qt binding\b|\bneed a Qt binding\b|"
                    r"could not import 'hugmesh_studio\.gui\.qt'", re.I)
_SUMMARY = re.compile(r"\b(?:\d+ (?:passed|failed|errors?|skipped|deselected|xfailed|"
                      r"xpassed|warnings?)|no tests ran)\b")


def discover(tests_dir: str = "tests") -> list[str]:
    """Every ``test_*.py`` under ``tests_dir``, sorted, as paths relative to the cwd."""
    found = []
    for root, dirs, files in os.walk(tests_dir):
        dirs[:] = sorted(d for d in dirs if not d.startswith((".", "__")))
        found += [os.path.join(root, f) for f in files
                  if f.startswith("test_") and f.endswith(".py")]
    return sorted(found)


def shard(files: list[str], spec: str) -> list[str]:
    """``K/N``: every N-th file starting at the K-th (1-based), so N shards together run
    every file exactly once whatever the order of the list."""
    m = re.fullmatch(r"(\d+)/(\d+)", spec or "")
    if not m or not 1 <= int(m.group(1)) <= int(m.group(2)):
        raise ValueError(f"--shard wants K/N with 1 <= K <= N, got {spec!r}")
    k, n = int(m.group(1)), int(m.group(2))
    return files[k - 1::n]


def skipped_for_missing_qt(output: str) -> list[str]:
    """The ``SKIPPED`` lines of a ``-rs`` report whose reason is a missing Qt binding."""
    return [ln for ln in output.splitlines()
            if ln.startswith("SKIPPED") and _NO_QT.search(ln)]


class KnownList:
    """A parsed ``--known`` file: node ids per file, and the files allowed to abort at
    exit after their tests passed."""

    def __init__(self, nodes=None, exit_abort=None):
        self.nodes: dict[str, list[str]] = nodes or {}
        self.exit_abort: set[str] = exit_abort or set()


def parse_known(text: str) -> KnownList:
    """Parse a known list (see the module docstring). Raises ValueError on a line it does
    not understand, or one with no ``# reason``: an entry nobody can explain is not kept."""
    known = KnownList()
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        body, sep, why = line.partition("#")
        if not sep or not why.strip():
            raise ValueError(f"known list line {n}: no '# reason': {raw!r}")
        words = body.split()
        if len(words) == 1 and "::" in words[0]:
            path = words[0].split("::", 1)[0]
            known.nodes.setdefault(path, []).append(words[0])
        elif len(words) == 2 and words[1] == "exit-abort" and "::" not in words[0]:
            known.exit_abort.add(words[0])
        else:
            raise ValueError(f"known list line {n}: want 'FILE::TEST  # why' or "
                             f"'FILE  exit-abort  # why', got {raw!r}")
    return known


def _counts(output: str) -> dict:
    """``{"passed": 3, "failed": 1, ...}`` from the last pytest summary line."""
    line = _summary_line(output)
    return {k: int(v) for v, k in re.findall(
        r"(\d+) (passed|failed|errors?|skipped|deselected|xfailed|xpassed)", line)}


def aborted_after_passing(returncode: int | None, output: str) -> bool:
    """The interpreter died AFTER pytest printed a summary with tests passed and none
    failed or errored: a crash in teardown at exit, not a test that failed."""
    if returncode is None or not (returncode < 0 or returncode > 5):
        return False
    c = _counts(output)
    return c.get("passed", 0) > 0 and not c.get("failed") and not c.get("error") \
        and not c.get("errors")


def verdict(returncode: int | None, output: str, require_qt: bool) -> str:
    """"" when a file's run counts as a pass, otherwise why it does not. ``None`` is a
    run that hit the timeout. pytest exits 5 when it collected no test: a module that
    skipped itself whole (``importorskip("urwid")`` at the top, which reports ``1
    skipped``) is a skip like any other and is judged by its reason below; a file that
    collected nothing at all ran nothing."""
    if returncode is None:
        return "timed out"
    if returncode < 0 or returncode > 5:
        return f"the interpreter died (exit {returncode}): a crash, not a test failure"
    if returncode == 5 and not re.search(r"\b\d+ skipped\b", output):
        return "no test ran"
    if returncode not in (0, 5):
        return f"pytest exit {returncode}"
    blind = skipped_for_missing_qt(output)
    if require_qt and blind:
        return f"{len(blind)} skip(s) for a missing Qt binding in a job that has one"
    return ""


def qt_preflight() -> str:
    """"" when this interpreter can import the Studio's Qt shim and SHOW a widget on an
    offscreen QApplication; otherwise what failed. Run in a child, so a binding that
    aborts the process (a missing libEGL does) is reported, not fatal to the runner."""
    probe = ("import os, sys\n"
             "os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')\n"
             "sys.path.insert(0, os.getcwd())\n"
             "from hugmesh_studio.gui import qt\n"
             "app = qt.QtWidgets.QApplication(['qt-preflight'])\n"
             "w = qt.QtWidgets.QLabel('preflight'); w.show(); app.processEvents()\n"
             "assert w.isVisible() and w.width() > 0\n"
             "print(qt.BINDING, qt.QtCore.qVersion(), app.platformName(),"
             " app.style().objectName())\n")
    try:
        r = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True,
                           timeout=120)
    except subprocess.TimeoutExpired:
        return "the Qt preflight timed out"
    if r.returncode != 0:
        return f"the Qt preflight failed (exit {r.returncode}):\n{r.stdout}{r.stderr}"
    print(f"Qt preflight: {r.stdout.strip()}", flush=True)
    return ""


def judge(path: str, returncode, output: str, rerun, known: KnownList,
          require_qt: bool) -> tuple[str, list]:
    """``(why the file is red or "", notes on its known entries)``. ``rerun`` is the
    ``(returncode, output, seconds)`` of its known nodes run on their own, or None."""
    notes = []
    mine = known.nodes.get(path, [])
    if mine and not (returncode is None or returncode < 0 or returncode > 5):
        got = _counts(output).get("deselected", 0)
        if got != len(mine):
            return (f"the known list deselects {len(mine)} test(s) here and pytest "
                    f"deselected {got}: an entry names no test"), notes
    why = verdict(returncode, output, require_qt)
    if why and path in known.exit_abort and aborted_after_passing(returncode, output):
        notes.append(f"aborted at exit (exit {returncode}) after "
                     f"{_counts(output).get('passed', 0)} passed (exit-abort)")
        why = verdict(0, output, require_qt)   # still red on a Qt-less skip
    if rerun is not None:
        rc, out, _secs = rerun
        if rc == 0:
            notes.append(f"{len(mine)} known test(s) now PASS: delete them from the list")
        else:
            failed = [ln.split(" ", 2)[1] for ln in out.splitlines()
                      if ln.startswith(("FAILED ", "ERROR "))]
            notes.append(f"still failing ({_summary_line(out) or f'exit {rc}'}): "
                         + ", ".join(failed or mine))
    return why, notes


def run_one(path: str, timeout: int, basetemp: str, deselect=(), nodes=None,
            ) -> tuple[int | None, str, float]:
    """``(returncode or None on timeout, combined output, seconds)`` for one file (with
    ``deselect`` node ids left out), or for exactly ``nodes`` when given."""
    cmd = [sys.executable, "-m", "pytest", "-q", "-rfEs", "-p", "no:cacheprovider",
           f"--basetemp={basetemp}", *(nodes or [path])]
    for node in deselect:
        cmd += ["--deselect", node]
    t0 = time.monotonic()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
        rc, out = r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired as exc:
        rc = None
        out = ((exc.stdout or b"").decode("utf-8", "replace")
               if isinstance(exc.stdout, bytes) else (exc.stdout or ""))
    finally:
        shutil.rmtree(basetemp, ignore_errors=True)
    return rc, out, time.monotonic() - t0


def _summary_line(output: str) -> str:
    return next((ln.strip("= ") for ln in reversed(output.splitlines())
                 if _SUMMARY.search(ln)), "")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("files", nargs="*", help="test files (default: every tests/**/test_*.py)")
    ap.add_argument("--shard", default="1/1", help="K/N: run every N-th file from the K-th")
    ap.add_argument("-j", "--jobs", type=int, default=1, help="files run at once")
    ap.add_argument("--timeout", type=int, default=900, help="seconds per file")
    ap.add_argument("--require-qt", action="store_true",
                    help="refuse to start without a working Qt binding, and fail any file "
                         "that skipped for want of one")
    ap.add_argument("--known", help="the list of what was already red (module docstring)")
    args = ap.parse_args(argv)
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    try:
        known = parse_known(open(args.known, encoding="utf-8").read()) if args.known \
            else KnownList()
    except (OSError, ValueError) as exc:
        print(exc, file=sys.stderr)
        return 2
    try:
        files = shard(args.files or discover(), args.shard)
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 2
    if not files:
        print("no test files to run", file=sys.stderr)
        return 2
    if args.require_qt:
        why = qt_preflight()
        if why:
            print(why, file=sys.stderr)
            return 2
    root = tempfile.mkdtemp(prefix="ff-")      # short: AF_UNIX paths live under it
    red, reported = [], []
    print(f"{len(files)} file(s), shard {args.shard}, {args.jobs} at a time", flush=True)

    def one(i: int, path: str):
        mine = known.nodes.get(path, [])
        rc, out, secs = run_one(path, args.timeout, os.path.join(root, str(i)), mine)
        rerun = run_one(path, args.timeout, os.path.join(root, f"{i}k"), nodes=mine) \
            if mine else None
        return rc, out, secs, rerun

    try:
        with concurrent.futures.ThreadPoolExecutor(max(1, args.jobs)) as pool:
            futs = {pool.submit(one, i, f): f for i, f in enumerate(files)}
            for fut in concurrent.futures.as_completed(futs):
                path = futs[fut]
                rc, out, secs, rerun = fut.result()
                why, notes = judge(path, rc, out, rerun, known, args.require_qt)
                print(f"{'FAIL' if why else 'ok  '} {secs:6.1f}s {path}  "
                      f"{why or _summary_line(out)}", flush=True)
                for note in notes:
                    print(f"     known: {note}", flush=True)
                    reported.append((path, note))
                if why:
                    red.append((path, why))
                if why or notes:
                    print(f"::group::{path}\n" + "\n".join(out.splitlines()[-80:])
                          + "\n::endgroup::", flush=True)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"## Studio tests with Qt, file by file (shard {args.shard})\n\n"
                     f"{len(files) - len(red)} of {len(files)} file(s) passed.\n\n")
            for path, why in sorted(red):
                fh.write(f"- `{path}`: {why}\n")
            if reported:
                fh.write(f"\n### Known before this job ({args.known}): reported, not "
                         "gating\n\n")
                for path, note in sorted(reported):
                    fh.write(f"- `{path}`: {note}\n")
    if red:
        print(f"\n{len(red)} of {len(files)} file(s) did not pass:", flush=True)
        for path, why in sorted(red):
            print(f"  {path}: {why}", flush=True)
        return 1
    print(f"\nall {len(files)} file(s) passed", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
