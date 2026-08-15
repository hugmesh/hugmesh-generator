"""The FLEET log pane must COALESCE worker output, not write + flush per line.

WHY THIS TEST EXISTS. _FleetWorker emits one queued signal per output line, and
FleetPage._on_line used to do three things inline for each of them: appendPlainText (a
document edit + repaint request), ``self._log_fh.write(...)`` and ``self._log_fh.flush()``
— a SYNCHRONOUS filesystem syscall on the GUI thread, once per line. The stream it does
that over is the fan-out of build-all-roles.sh: a SINGLE x86 build measures 3.16M lines /
353 MB (core/emerge_packages.py:12) and a fleet run multiplies that by every role, so a
slow or busy disk blocked the event loop directly.

This is the same contract tests/test_localmesh_log_coalescing.py and
tests/test_progress_log_coalescing.py pin, with the tee added: signal -> enqueue only;
drain -> ONE append, ONE write, ONE flush for the batch; nothing lost, the tee still
line-exact so `tail -F` on <workdir>/fleet.log behaves as before.
"""
from __future__ import annotations

import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.gui.pages import fleet as fleet_mod             # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def page(qapp):
    """A bare FleetPage — no window, no driver, no worker. The log path is exercised
    directly, exactly as the worker's queued signal drives it."""
    p = fleet_mod.FleetPage(GENERATOR_DIR)
    yield p
    p.deleteLater()


class _CountingFile:
    """Stands in for the tee handle, counting the two calls that used to be per line."""

    def __init__(self, path):
        self._fh = open(path, "a", encoding="utf-8")
        self.writes = 0
        self.flushes = 0

    def write(self, s):
        self.writes += 1
        return self._fh.write(s)

    def flush(self):
        self.flushes += 1
        self._fh.flush()

    def close(self):
        self._fh.close()


def test_the_worker_slot_only_enqueues(page):
    """_on_line must touch no widget, no file and no ring buffer. It runs once PER OUTPUT
    LINE on the GUI thread, so anything real here IS the stall, by construction."""
    page._log_fh = None
    before = page.log.toPlainText()

    for i in range(5000):
        page._on_line(f"line {i}")

    assert page.log.toPlainText() == before, "the pane must be untouched until a drain"
    assert len(page._line_inbox) == 5000
    assert not page._tail, "not even the error-tail ring may be fed from the slot"


def test_drain_writes_and_flushes_once_for_the_whole_batch(page, tmp_path):
    """The batch must cost ONE append, ONE write and ONE flush — not 2000 of each."""
    fh = _CountingFile(tmp_path / "fleet.log")
    page._log_fh = fh
    appends = {"n": 0}
    real_append = page.log.appendPlainText

    def counting_append(text):
        appends["n"] += 1
        real_append(text)

    page.log.appendPlainText = counting_append

    for i in range(2000):
        page._on_line(f"line {i}")
    page._drain_lines()

    assert appends["n"] == 1, "one pane append per drain, never one per line"
    assert fh.writes == 1, "one tee write per drain, never one per line"
    assert fh.flushes == 1, "one flush per drain — the syscall that stalled the GUI"
    assert not page._line_inbox, "drain must clear the inbox"
    fh.close()

    # the tee is still LINE-EXACT: `tail -F` on fleet.log must see the same stream
    written = (tmp_path / "fleet.log").read_text(encoding="utf-8").splitlines()
    assert written == [f"line {i}" for i in range(2000)]
    text = page.log.toPlainText()
    assert "line 0" in text and "line 1999" in text


def test_no_lines_are_lost_across_many_drains(page, tmp_path):
    """Interleaved produce/drain must preserve order and count in BOTH sinks — the drain
    snapshots and clears, so a fast producer must not livelock or drop."""
    fh = _CountingFile(tmp_path / "fleet.log")
    page._log_fh = fh
    expected = []
    for batch in range(10):
        for i in range(20):
            ln = f"b{batch}-{i}"
            expected.append(ln)
            page._on_line(ln)
        page._drain_lines()
    fh.close()

    assert (tmp_path / "fleet.log").read_text(
        encoding="utf-8").splitlines() == expected
    assert page.log.toPlainText().splitlines() == expected
    # the error-tail ring is the session record's failure evidence: same lines, in order
    assert list(page._tail) == expected[-len(page._tail):]


def test_drain_on_empty_inbox_is_a_noop(page, tmp_path):
    """The timer fires at ~20 Hz whether or not the fan-out printed anything; an idle tick
    must not append a blank line to the pane or a bare newline to the tee."""
    fh = _CountingFile(tmp_path / "fleet.log")
    page._log_fh = fh
    page._drain_lines()
    fh.close()
    assert page.log.toPlainText() == ""
    assert (tmp_path / "fleet.log").read_text(encoding="utf-8") == ""


def test_a_tee_that_fails_never_costs_the_pane(page):
    """The tee has always been best-effort (an unwritable workdir must not kill the run).
    Batching must not turn one OSError into a lost batch in the PANE."""
    class _Broken:
        def write(self, s):
            raise OSError("disk full")

        def flush(self):
            raise OSError("disk full")

    page._log_fh = _Broken()
    page._on_line("still visible")
    page._drain_lines()                       # must not raise
    assert "still visible" in page.log.toPlainText()


def test_the_live_pane_is_bounded(page):
    """An all-roles fan-out streams for hours; the QTextDocument must not grow without
    bound. This page keeps NO restorable buffer of the run (only the ERROR_TAIL_LINES
    ring), so the cap is deliberately generous and the FULL stream stays durable in
    <workdir>/fleet.log rather than in the widget."""
    page._log_fh = None
    assert page.log.maximumBlockCount() == fleet_mod._LOG_MAX_BLOCKS
    assert fleet_mod._LOG_MAX_BLOCKS >= 100000, (
        "with no in-memory buffer behind it, the cap must be generous enough that no one "
        "scrolls past it")
    for i in range(1000):
        page._on_line(f"line {i}")
    page._drain_lines()
    assert page.log.blockCount() <= fleet_mod._LOG_MAX_BLOCKS
    assert "line 999" in page.log.toPlainText()
