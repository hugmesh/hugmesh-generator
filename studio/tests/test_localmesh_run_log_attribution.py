"""A run's log must contain THAT run's lines — and no other run's.

WHY THIS TEST EXISTS. Every saved log in the operator's corpus that carried a
save notice opened with the PREVIOUS run's filename:

    # Checking host readiness — succeeded
    # 2 line(s) retained (the pane's ring buffer keeps the last 20000)

    [log] this run was saved to .../20260826-150718-Bootstrapping-FAILED.log
    [readiness] READY — docker daemon, buildx, disk headroom ... all check out.

That first line is a DIFFERENT run's file. All 5 corpus logs carrying a notice
were misattributed this way, in one unbroken chain — 150529 -> 150718 -> 150723
-> 150731 -> 151100 -> 151118 — so a reader triaging "which step wrote which
file?" is told, every time, the wrong answer, and the run's line count is inflated
by a line it never produced.

THE CAUSE is delivery, not the message. `_on_line` only banks into `_line_inbox`;
`_drain_lines` files a whole batch against `_runs[-1]`, whichever run that is NOW.
`_verb_done` stops the drain timer, writes the file, and only THEN enqueues the
"this run was saved to ..." notice — so the notice is still sitting in the inbox
when the next verb starts, and the next verb's own flush adopts it. The line is
correct; it is attributed to the wrong run because the inbox outlived its owner.

So the property under test is ATTRIBUTION: a line banked while a run is current
belongs to that run, and a new run's log opens with its own first line.

These drive the REAL lifecycle — production `_launch`, a real `_MeshWorker`
thread, production `_verb_done` — against trivial verbs, so nothing here
re-implements the code it is checking.
"""
from __future__ import annotations

import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from types import SimpleNamespace  # noqa: E402

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding installed in this job")

from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402
from hugmesh_studio.gui.pages import localmesh  # noqa: E402

GENERATOR_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", ".."))

NOTICE = "[log] this run was saved to "


@pytest.fixture(scope="module")
def qapp():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


def _quiet_page():
    """A LocalMeshPage whose post-run DOCKER probes are stubbed out.

    `_verb_done` ends by re-reading real mesh state — `_refresh_status`,
    `_probe_mesh_state` and (via `_set_verbs_enabled`) `_sync_e2e_gate` each spawn
    a thread that shells `docker compose ps` with a 30s timeout. None of that is
    the subject here; leaving it in would make the test depend on the operator's
    live stack and leave threads running into interpreter teardown. These three
    are the ONLY things replaced — every line of the log-attribution path
    underneath (`_launch`, `_MeshWorker`, `_on_line`, `_drain_lines`,
    `_save_run_log`, `_verb_done`) stays production code."""
    page = localmesh.LocalMeshPage(
        SimpleNamespace(generator_dir=GENERATOR_DIR, cfg=SimpleNamespace()))
    page._probe_mesh_state = lambda: None
    page._refresh_status = lambda: None
    page._sync_e2e_gate = lambda: None
    return page


def _pump(qapp, until, timeout=20.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        qapp.processEvents()
        if until():
            return
        time.sleep(0.005)
    raise AssertionError("timed out waiting for the verb lifecycle to settle")


def _run_verb(page, qapp, label, ok, lines):
    """One COMPLETE production run: _launch -> _MeshWorker -> _verb_done.

    Deliberately does NOT drain afterwards. The whole defect lives in what
    survives in the inbox after `_verb_done` stops the timer, so a helpful extra
    flush here would paper over exactly the thing being measured.

    The `wait()` is test hygiene only: `done` is emitted from inside QThread.run,
    so the thread can still be unwinding when the slot returns, and letting the
    page (its parent) be collected first aborts the interpreter with "QThread:
    Destroyed while thread is still running". It joins an already-finished thread
    and moves no lines."""
    page._launch(label, lambda: (ok, list(lines)))
    _pump(qapp, lambda: not page._running)
    worker = page.worker
    assert worker is not None and worker.wait(10000), "the verb thread never exited"
    return worker


def _saved_files(state_dir):
    d = os.path.join(state_dir, "logs")
    return sorted(os.path.join(d, f) for f in os.listdir(d)) if os.path.isdir(d) else []


def _notices(text_or_lines):
    lines = (text_or_lines.splitlines()
             if isinstance(text_or_lines, str) else list(text_or_lines))
    return [ln for ln in lines if ln.startswith(NOTICE)]


def test_a_save_notice_is_never_filed_against_the_next_run(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path))
    page = _quiet_page()

    w_a = _run_verb(page, qapp, "Bootstrapping", False,
                    ["[bootstrap] generating credentials"])
    w_b = _run_verb(page, qapp, "Checking host readiness", True, ["[readiness] READY"])
    assert w_a is not w_b, "both verbs reused one worker; the runs did not separate"

    # ---- floors, so a silent no-op cannot pass this ------------------------
    assert len(page._runs) == 2, f"expected 2 runs, drove {len(page._runs)}"
    files = _saved_files(str(tmp_path))
    assert len(files) == 2, f"expected 2 saved logs, found {files}"
    a_file, b_file = files          # timestamp-ordered: Bootstrapping, then readiness
    assert os.path.basename(a_file).endswith("-Bootstrapping-FAILED.log"), a_file
    assert os.path.basename(b_file).endswith(
        "-Checking-host-readiness-ok.log"), b_file

    run_a, run_b = page._runs
    assert run_b.buffer, "run B recorded no lines at all"

    # ---- THE CORPUS SYMPTOM, checked first --------------------------------
    assert os.path.basename(a_file) not in "\n".join(run_b.buffer), (
        f"run B's log names a DIFFERENT run's file ({os.path.basename(a_file)}):\n  "
        + "\n  ".join(run_b.buffer))

    # ---- each run's notice names the file THAT run wrote -------------------
    # Not "run B has no notice": run B is a finished run too, so it must have
    # exactly one. The defect is WHICH file it names. Both counts are floors —
    # a notice that stopped being emitted would fail here, not pass quietly.
    a_notices, b_notices = _notices(run_a.buffer), _notices(run_b.buffer)
    assert len(a_notices) == 1, \
        f"run A produced {len(a_notices)} save notices, expected exactly 1"
    assert len(b_notices) == 1, \
        f"run B produced {len(b_notices)} save notices, expected exactly 1"
    assert a_notices[0] == NOTICE + a_file, (
        "run A's save notice names the wrong file:\n"
        f"  said : {a_notices[0]}\n  wrote: {a_file}")
    assert b_notices[0] == NOTICE + b_file, (
        "run B's save notice names the wrong file:\n"
        f"  said : {b_notices[0]}\n  wrote: {b_file}")

    # ---- the corpus symptom itself: what is ON DISK for run B -------------
    body = open(b_file, encoding="utf-8").read()
    assert os.path.basename(a_file) not in body, (
        f"{os.path.basename(b_file)} names a DIFFERENT run's file in its body:\n"
        + body)
    first = [ln for ln in body.splitlines()
             if ln.strip() and not ln.startswith("#")][:1]
    assert first == ["[readiness] READY"], (
        "run B's log must open with run B's own first line, got: " + repr(first))


def test_a_line_banked_between_runs_lands_on_the_run_that_produced_it(qapp, tmp_path,
                                                                      monkeypatch):
    """The general invariant behind the defect, independent of the save notice.

    `_drain_lines` files a batch against `_runs[-1]`. Anything still banked when a
    new run is appended is therefore silently re-attributed to that new run. A
    straggler must land on its own run, never on the one that follows."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path))
    page = _quiet_page()

    w_a = _run_verb(page, qapp, "Bootstrapping", True, ["[bootstrap] done"])
    # A late line for the run that just ended: the drain timer is stopped, so this
    # is banked with no pump running behind it — exactly the save notice's position.
    page._on_line("[straggler] belongs to Bootstrapping")
    w_b = _run_verb(page, qapp, "Starting the mesh node", True, ["[mesh] up"])
    assert w_a is not w_b

    assert len(page._runs) == 2, f"expected 2 runs, drove {len(page._runs)}"
    run_a, run_b = page._runs
    assert "[straggler] belongs to Bootstrapping" not in list(run_b.buffer), (
        "a line banked for the previous run was adopted by the next one:\n  "
        + "\n  ".join(run_b.buffer))
    assert "[straggler] belongs to Bootstrapping" in list(run_a.buffer), (
        "the straggler was dropped instead of being filed against its own run:\n  "
        + "\n  ".join(run_a.buffer))


def test_a_finished_run_names_its_log_file_immediately(qapp, tmp_path, monkeypatch):
    """The operator-facing half: the notice must be there WHEN THE RUN ENDS.

    `_verb_done` stops the drain timer and only then enqueues the notice, so
    without an explicit flush the line stays banked in `_line_inbox` — invisible
    in the pane and absent from the run's own buffer — until some LATER verb
    restarts the timer. For the last run of a session that is never. An operator
    whose DevOps lane just failed clicks the run row to find "where is the log?"
    and the answer is not there yet."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path))
    page = _quiet_page()

    _run_verb(page, qapp, "Starting the DevOps lane", False, ["boom: it failed"])

    files = _saved_files(str(tmp_path))
    assert len(files) == 1, f"expected exactly 1 saved log, found {files}"
    assert len(page._runs) == 1, f"expected 1 run, drove {len(page._runs)}"

    assert not page._line_inbox, (
        "the run ended with lines still banked in the inbox, which nothing will "
        f"drain until the next verb starts: {list(page._line_inbox)}")

    run = page._runs[-1]
    notices = _notices(run.buffer)
    assert len(notices) == 1, (
        f"the finished run holds {len(notices)} save notices, expected exactly 1 — "
        "it never learned where it was written")
    assert notices[0] == NOTICE + files[0]
    assert NOTICE in page.log.toPlainText(), \
        "the pane the operator is looking at does not show where the log went"
