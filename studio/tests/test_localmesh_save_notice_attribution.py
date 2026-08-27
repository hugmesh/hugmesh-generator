"""A saved run log must contain only the lines THAT run produced.

WHY THIS TEST EXISTS — the corpus symptom (SIG-15).
The one real-operator readiness log in ~/.hugmesh/studio/logs opens by naming a
DIFFERENT run's file:

    # Checking host readiness — succeeded
    # 2 line(s) retained (the pane's ring buffer keeps the last 20000)

    [log] this run was saved to .../20260826-150718-Bootstrapping-FAILED.log
    [readiness] READY — docker daemon, buildx, disk headroom ... all check out.

20260826-150718-Bootstrapping-FAILED.log is the PREVIOUS run's file. Every log in
the corpus that carries a save notice is misattributed the same way, in one
unbroken chain, so an operator triaging "which step wrote which file?" is handed
the wrong answer every time — and the header's retained-line count is inflated by
a line the run never produced.

THE CAUSE is delivery, not the message text. ``_on_line`` only banks into
``_line_inbox``; ``_drain_lines`` files a whole batch against ``_runs[-1]``,
whichever run that happens to be AT DRAIN TIME. ``_verb_done`` stops the 20 Hz
drain timer, writes the file, and only THEN enqueues the "this run was saved to"
notice — so the notice is still sitting in the inbox with no timer behind it when
the next verb starts, and that verb's first flush adopts it as its own first line.
The sentence is true; it is filed against the wrong run.

So the property under test is ATTRIBUTION, not wording: a line banked while a run
is current belongs to that run, and a new run's log opens with its own first line.

These drive the REAL lifecycle — production ``_launch``, a real ``_MeshWorker``
QThread, production ``_on_line``/``_drain_lines``/``_save_run_log``/``_verb_done``
— against trivial verbs. Nothing here re-implements the code it is checking.
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

GENERATOR_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

NOTICE = "[log] this run was saved to "


@pytest.fixture(scope="module")
def qapp():
    yield QtWidgets.QApplication.instance() or QtWidgets.QApplication([])


def _quiet_page():
    """A LocalMeshPage whose post-run DOCKER probes are stubbed out.

    ``_verb_done`` ends by re-reading real mesh state: ``_refresh_status``,
    ``_probe_mesh_state`` and (via ``_set_verbs_enabled``) ``_sync_e2e_gate`` each
    shell out to ``docker compose ps`` on a thread with a 30s timeout. None of that
    is the subject here, and leaving it in would make this test depend on the
    operator's live stack. These three are the ONLY things replaced — every line of
    the attribution path underneath (``_launch``, ``_MeshWorker``, ``_on_line``,
    ``_drain_lines``, ``_save_run_log``, ``_verb_done``) stays production code."""
    page = localmesh.LocalMeshPage(
        SimpleNamespace(generator_dir=GENERATOR_DIR, cfg=SimpleNamespace()))
    page._probe_mesh_state = lambda: None
    page._refresh_status = lambda: None
    page._sync_e2e_gate = lambda: None
    return page


def _run_verb(page, qapp, label, ok, lines, timeout=20.0):
    """One COMPLETE production run: _launch -> _MeshWorker -> _verb_done.

    Deliberately does NOT drain afterwards. The whole defect lives in what survives
    in the inbox once ``_verb_done`` has stopped the drain timer, so a helpful extra
    flush here would paper over the very thing being measured.

    The ``wait()`` is hygiene only: ``done`` is emitted from inside QThread.run, so
    the thread can still be unwinding when the slot returns, and letting the page
    (its parent) be collected first aborts the interpreter with "QThread: Destroyed
    while thread is still running". It joins an already-finished thread and moves
    no lines."""
    page._launch(label, lambda: (ok, list(lines)))
    deadline = time.monotonic() + timeout
    while page._running and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.005)
    assert not page._running, f"{label!r} never reached _verb_done"
    w = page.worker
    assert w is not None and w.wait(10000), f"{label!r}'s verb thread never exited"
    return w


def _saved_logs(state_dir):
    """Every file _save_run_log wrote, in write order (the names are timestamped)."""
    d = os.path.join(state_dir, "logs")
    return sorted(os.path.join(d, f) for f in os.listdir(d)) if os.path.isdir(d) else []


def _body(path):
    """A saved log's real lines — the two '#' header lines and the blank are frame."""
    with open(path, encoding="utf-8") as fh:
        return [ln for ln in fh.read().splitlines()
                if ln.strip() and not ln.startswith("#")]


def test_a_saved_log_never_opens_with_another_runs_filename(qapp, tmp_path, monkeypatch):
    """The corpus symptom itself, reproduced through the real lifecycle."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path))
    page = _quiet_page()

    w_a = _run_verb(page, qapp, "Bootstrapping", False,
                    ["[bootstrap] generating credentials"])
    w_b = _run_verb(page, qapp, "Checking host readiness", True,
                    ["[readiness] READY — docker daemon, buildx all check out."])

    # ---- floors: a silent no-op must not be able to pass this ------------------
    assert w_a is not w_b, "both verbs reused one worker; the runs never separated"
    assert len(page._runs) == 2, f"expected 2 runs, drove {len(page._runs)}"
    files = _saved_logs(str(tmp_path))
    assert len(files) == 2, f"expected 2 saved logs on disk, found {files}"
    a_file, b_file = files          # timestamp-ordered: Bootstrapping, then readiness
    assert os.path.basename(a_file).endswith("-Bootstrapping-FAILED.log"), a_file
    assert os.path.basename(b_file).endswith("-Checking-host-readiness-ok.log"), b_file

    # ---- SIG-15, read straight off the file the operator would open -----------
    b_body = _body(b_file)
    assert b_body, f"{os.path.basename(b_file)} has no body lines at all"
    assert os.path.basename(a_file) not in "\n".join(b_body), (
        f"{os.path.basename(b_file)} names a DIFFERENT run's file "
        f"({os.path.basename(a_file)}) in its body:\n  " + "\n  ".join(b_body))
    assert b_body[0].startswith("[readiness] READY"), (
        "a run's log must open with that run's own first line, not with "
        f"whatever was left banked from the previous one; got: {b_body[0]!r}")


def test_every_saved_logs_lines_were_produced_by_that_run(qapp, tmp_path, monkeypatch):
    """The general invariant, over a CHAIN — no run's file may hold another's line.

    Four runs, each with a line unique to it, so the check is not satisfiable by
    coincidence: any leak across the boundary puts a recognisably foreign line in
    the wrong file. Counters below are floors, so an empty file list or an empty
    body cannot make this pass vacuously."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path))
    page = _quiet_page()

    script = [("Checking host readiness", True, "[readiness] marker-one"),
              ("Bootstrapping", False, "[bootstrap] marker-two"),
              ("Starting the mesh node", True, "[mesh] marker-three"),
              ("Starting the DevOps lane", False, "[devops] marker-four")]
    for label, ok, line in script:
        _run_verb(page, qapp, label, ok, [line])

    files = _saved_logs(str(tmp_path))
    assert len(files) == len(script), \
        f"expected {len(script)} saved logs, found {len(files)}"
    assert len(page._runs) == len(script), f"drove only {len(page._runs)} runs"

    # Pair each run with ITS file by the label the filename carries, never by sort
    # position: _save_run_log stamps to the second, and four trivial verbs finish
    # inside one second, so the sorted order is alphabetical-by-label, not write
    # order. Pairing positionally would compare a run against someone else's file
    # and "fail" on a bug that is the test's own.
    def _file_for(label, ok):
        safe = "".join(c if (c.isalnum() or c in "-_") else "-" for c in label)
        suffix = f"-{safe.strip('-')}-{'ok' if ok else 'FAILED'}.log"
        hits = [f for f in files if os.path.basename(f).endswith(suffix)]
        assert len(hits) == 1, f"expected 1 log ending {suffix!r}, found {hits}"
        return hits[0]

    markers = [line for _, _, line in script]
    examined_files = examined_lines = 0
    for label, ok, mine in script:
        path = _file_for(label, ok)
        body = _body(path)
        assert body, f"{os.path.basename(path)} has no body lines at all"
        examined_files += 1
        examined_lines += len(body)
        text = "\n".join(body)
        assert mine in text, (
            f"{os.path.basename(path)} is missing its OWN line {mine!r} — the run "
            "did not record what it produced:\n  " + "\n  ".join(body))
        for foreign in (m for m in markers if m != mine):
            assert foreign not in text, (
                f"{os.path.basename(path)} (run {label!r}) contains another run's "
                f"line {foreign!r}:\n  " + "\n  ".join(body))
        for other in files:
            if other is not path:
                assert os.path.basename(other) not in text, (
                    f"{os.path.basename(path)} names another run's FILE "
                    f"{os.path.basename(other)}:\n  " + "\n  ".join(body))

    # ---- floors on the derived lists this test iterates -----------------------
    assert examined_files == len(script), \
        f"only {examined_files} log files were actually examined"
    assert examined_lines >= len(script), \
        f"only {examined_lines} body lines were actually examined"


def test_a_finished_run_tells_the_operator_where_its_log_went(qapp, tmp_path,
                                                              monkeypatch):
    """The operator-facing half: the notice must land WHEN THE RUN ENDS.

    ``_verb_done`` stops the drain timer and only then enqueues the notice, so with
    nothing to flush it the line stays banked in ``_line_inbox`` — absent from the
    run's buffer and from the pane — until some LATER verb restarts the timer. For
    the last run of a session that is never: the operator whose DevOps lane just
    failed clicks the run row to ask "where is the log?" and is not told."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path))
    page = _quiet_page()

    _run_verb(page, qapp, "Starting the DevOps lane", False, ["boom: it failed"])

    files = _saved_logs(str(tmp_path))
    assert len(files) == 1, f"expected exactly 1 saved log, found {files}"
    assert len(page._runs) == 1, f"expected 1 run, drove {len(page._runs)}"

    assert not page._line_inbox, (
        "the run ended with lines still banked in the inbox, and nothing will drain "
        f"them until the next verb starts: {list(page._line_inbox)}")

    notices = [ln for ln in page._runs[-1].buffer if ln.startswith(NOTICE)]
    assert len(notices) == 1, (
        f"the finished run holds {len(notices)} save notices, expected exactly 1 — "
        "it never learned where it was written")
    assert notices[0] == NOTICE + files[0], (
        f"the notice names the wrong file:\n  said : {notices[0]}\n"
        f"  wrote: {files[0]}")
    assert NOTICE in page.log.toPlainText(), \
        "the pane the operator is looking at does not say where the log went"
