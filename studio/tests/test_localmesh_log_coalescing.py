"""The local-mesh log pane must COALESCE worker output, not repaint per line.

WHY THIS TEST EXISTS. _MeshWorker emits one queued signal per output line, and the
slot used to run the whole pipeline inline — sanitise, parse, track, re-render the
touched stage rows, appendPlainText. Fine for a chatty verb, fatal for a torrential
one: `make kind-up` (kind cluster create + image pulls + ArgoCD rollouts) emits tens
of thousands of lines in bursts, so the GUI thread got tens of thousands of queued
slot calls each doing a widget repaint. The event loop never got back to painting or
input, and the window went unresponsive — operator report 2026-08-14, "starting the
devops pipeline seemed to freeze the window". The verb was ALWAYS off-thread; it was
the DELIVERY that blocked.

So the property under test is not "the lines arrive" (they always did) but "arriving
does not cost one repaint per line". These assert the batching contract directly:
signal -> enqueue only; drain -> one append for the batch; nothing lost.
"""
from __future__ import annotations

import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from types import SimpleNamespace  # noqa: E402

from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402
from hugmesh_studio.gui.pages import localmesh  # noqa: E402

GENERATOR_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", ".."))


def _new_page():
    """LocalMeshPage needs a wizard host; the same SimpleNamespace shim the
    egress-gate tests use is enough for the log path."""
    return localmesh.LocalMeshPage(
        SimpleNamespace(generator_dir=GENERATOR_DIR, cfg=SimpleNamespace()))


@pytest.fixture(scope="module")
def qapp():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


def _page(qapp):
    """A LocalMeshPage with one active run, ready to receive lines."""
    page = _new_page()
    run = localmesh._StageRun("test verb", [])
    page._runs.append(run)
    page._build_run_item(run)
    page._selected = 0
    page._selected_stage = None
    return page, run


def test_the_worker_slot_only_enqueues(qapp):
    """_on_line must not touch a widget. It runs once PER LINE on the GUI thread,
    so anything expensive here is the freeze, by construction."""
    page, run = _page(qapp)
    before = page.log.toPlainText()

    for i in range(5000):
        page._on_line(f"line {i}")

    # Nothing rendered yet — the pane is untouched until the drain runs.
    assert page.log.toPlainText() == before
    assert len(page._line_inbox) == 5000
    # And the parser has not run either: that is the drain's job.
    assert len(run.buffer) == 0


def test_drain_appends_once_for_the_whole_batch(qapp):
    """The batch must reach the pane in ONE appendPlainText, not one per line."""
    page, run = _page(qapp)
    appends = {"n": 0}
    real_append = page.log.appendPlainText

    def counting_append(text):
        appends["n"] += 1
        real_append(text)

    page.log.appendPlainText = counting_append

    for i in range(2000):
        page._on_line(f"line {i}")
    page._drain_lines()

    assert appends["n"] == 1, "one append per drain, never one per line"
    # every line still made it into the pane and the raw buffer
    assert len(run.buffer) == 2000
    text = page.log.toPlainText()
    assert "line 0" in text and "line 1999" in text
    assert not page._line_inbox, "drain must clear the inbox"


def test_no_lines_are_lost_across_many_drains(qapp):
    """Interleaved produce/drain must preserve order and count — the drain
    snapshots and clears, so a fast producer must not livelock or drop."""
    page, run = _page(qapp)
    expected = []
    for batch in range(10):
        for i in range(100):
            ln = f"b{batch}-{i}"
            expected.append(ln)
            page._on_line(ln)
        page._drain_lines()

    assert list(run.buffer) == expected


def test_drain_on_empty_inbox_is_a_noop(qapp):
    """The timer fires at ~20 Hz whether or not the verb printed anything; an idle
    tick must not append a blank line to the pane."""
    page, _run = _page(qapp)
    page._drain_lines()
    assert page.log.toPlainText() == ""


def test_lines_with_no_run_still_surface(qapp):
    """Defensive path: output that arrives before any run exists must not vanish —
    it is usually the pre-flight explaining why nothing started."""
    page = _new_page()
    page._on_line("orphan line")
    page._drain_lines()
    assert "orphan line" in page.log.toPlainText()


def test_the_live_pane_is_bounded_and_the_run_buffer_still_restores_it(qapp):
    """Coalescing fixed the per-line COST; it did not bound the DOCUMENT. An hours-long
    cold `make stack-up` is ~100k lines, every one of them appended and none ever dropped,
    so the QTextDocument grew for the whole run and repaints got steadily slower.

    The cap is safe only because the drill-down does not read the widget: clicking the run
    row reloads the pane from _StageRun.buffer, itself a deque(maxlen=_RUN_LOG_MAXLEN), so
    a line the cap drops is one the buffer had already dropped."""
    page, run = _page(qapp)
    cap = localmesh._LOG_MAX_BLOCKS
    assert page.log.maximumBlockCount() == cap
    assert cap >= run.buffer.maxlen, (
        "the live cap must not be smaller than the buffer the drill-down restores, or "
        "capping WOULD lose recoverable scrollback")

    n = cap + 500
    for i in range(n):
        page._on_line(f"line {i}")
    page._drain_lines()

    assert page.log.blockCount() <= cap
    assert f"line {n - 1}" in page.log.toPlainText(), "the newest output must survive"
    # the drill-down is unaffected — it reloads from the ring buffer, whole
    page._load_detail(0, None)
    assert len(run.buffer) == run.buffer.maxlen
    assert page.log.toPlainText().endswith(f"line {n - 1}")
