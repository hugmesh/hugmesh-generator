"""The BUILD log pane must COALESCE worker output, not repaint per line.

WHY THIS TEST EXISTS. _WorklistWorker emits one queued signal per output line, and
ProgressPage._on_line used to run the whole pipeline inline for each of them: sanitise,
flag join, raw buffer, ProgressParser, _apply_state (progress bar + phase label),
StageTracker, EmergePackageParser, _render_package, _render_scheduler, _sync_pkg_expand,
_write_status, _refresh_overall, appendPlainText. Six of those touch a widget, so the GUI
thread paid a repaint request PER LINE.

That is the same defect tests/test_localmesh_log_coalescing.py pins for the local-mesh
page, on a much bigger stream. ONE real x86 standalone build measured 3.16M lines /
353 MB (core/emerge_packages.py:12) against kind-up's "tens of thousands", and this page
drives EVERY image build — the product's longest-running verb. The builds were always off
the GUI thread; it was the DELIVERY that blocked.

So the property under test is not "the lines arrive" (they always did) but "arriving does
not cost one repaint per line". These assert the batching contract directly: signal ->
enqueue only; drain -> one append, one bar write, one overall refresh for the batch;
nothing lost; and the per-PACKAGE accounting the local-mesh page does not have preserved
exactly — every atom, every step, every group, nested under the same stage as before.
"""
from __future__ import annotations

import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo                  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                             # noqa: E402
from hugmesh_studio.gui.pages import progress as progress_mod           # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")

_CYAN, _BOLD, _RST = "\x1b[36m", "\x1b[1m", "\x1b[0m"


def _banner(text: str) -> str:
    return f"{_CYAN}{_BOLD}==> {text}{_RST}"


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    yield w
    w.close()
    w.deleteLater()


def _fresh_page(wiz, rows=(("acme-x86", "x86"),)):
    """A page with N direct-slot rows (no driver, no worker) — the established harness
    every other progress test uses."""
    page = wiz.page(wiz._page_ids["progress"])
    page._reset()
    for i, (label, platform) in enumerate(rows):
        page._build_row(i, label, platform)
    page._select_row(0)
    return page


# ── 1. the slot itself ────────────────────────────────────────────────────────────────

def test_the_worker_slot_only_enqueues(wiz):
    """_on_line must not touch a widget, a parser or a buffer. It runs once PER OUTPUT
    LINE on the GUI thread over a 3.16M-line stream, so anything real here IS the freeze,
    by construction."""
    page = _fresh_page(wiz)
    row = page._rows[0]
    before_log = page.log.toPlainText()
    before_bar = row.bar.value()

    for i in range(5000):
        page._on_line(0, f"line {i}")

    assert page.log.toPlainText() == before_log, "the pane must be untouched until a drain"
    assert row.bar.value() == before_bar, "the progress bar must not move per line"
    assert len(page._line_inbox) == 5000
    # and no parsing has happened either: that is the drain's job
    assert len(row.buffer) == 0
    assert row.parser.phase_index == -1


def test_drain_appends_once_for_the_whole_batch(wiz):
    """The batch must reach the pane in ONE appendPlainText, not one per line."""
    page = _fresh_page(wiz)
    row = page._rows[0]
    appends = {"n": 0}
    real_append = page.log.appendPlainText

    def counting_append(text):
        appends["n"] += 1
        real_append(text)

    page.log.appendPlainText = counting_append

    for i in range(2000):
        page._on_line(0, f"line {i}")
    page._drain_lines()

    assert appends["n"] == 1, "one append per drain, never one per line"
    assert len(row.buffer) == 2000, "every line still reaches the authoritative buffer"
    text = page.log.toPlainText()
    assert "line 0" in text and "line 1999" in text
    assert not page._line_inbox, "drain must clear the inbox"


def test_the_progress_bar_is_written_once_per_drain(wiz):
    """_apply_state paints the job's bar + phase label. It used to run per line; now it
    runs once per row per drain, off the parser's CURRENT state — so the visible result is
    the same and the cost is O(ticks)."""
    page = _fresh_page(wiz)
    row = page._rows[0]
    writes = {"n": 0}
    real_set = row.bar.setValue

    def counting_set(v):
        writes["n"] += 1
        real_set(v)

    row.bar.setValue = counting_set

    # two x86 banners, in the table's own order (phase 0 then phase 1)
    page._on_line(0, _banner("Verifying prerequisites"))
    for i in range(500):
        page._on_line(0, f"  configuring thing {i}")
    page._on_line(0, _banner("Preparing build directories"))
    page._drain_lines()

    assert writes["n"] == 1, "one bar write per drain, never one per line"
    # …and it shows the LAST state of the batch, not the first: both banners were parsed,
    # and the label painted is the one the SECOND banner opened.
    assert row.parser.phase_index == 1
    assert row.phase.text() == row.parser.state().phase_label == "Prepare build dirs"


def test_no_lines_are_lost_across_many_drains(wiz):
    """Interleaved produce/drain must preserve order and count — the drain snapshots and
    clears, so a fast producer must not livelock or drop."""
    page = _fresh_page(wiz)
    row = page._rows[0]
    expected = []
    for batch in range(10):
        for i in range(100):
            ln = f"b{batch}-{i}"
            expected.append(ln)
            page._on_line(0, ln)
        page._drain_lines()

    assert list(row.buffer) == expected


def test_drain_on_empty_inbox_is_a_noop(wiz):
    """The timer fires at ~20 Hz whether or not the builder printed anything; an idle tick
    must not append a blank line or repaint the overall bar."""
    page = _fresh_page(wiz)
    page._drain_lines()
    assert page.log.toPlainText() == ""


def test_lines_for_a_row_that_no_longer_exists_are_dropped_not_fatal(wiz):
    """_reset() empties self._rows while an old worker can still be emitting. The old slot
    indexed self._rows directly, and an IndexError escaping a Qt slot calls qFatal and
    ABORTS the Studio on PyQt6."""
    page = _fresh_page(wiz)
    page._on_line(7, "output for a row that was never built")
    page._drain_lines()            # must not raise
    assert not page._line_inbox


# ── 2. the per-PACKAGE machinery localmesh.py does not have ───────────────────────────

def test_the_package_ladder_is_accounted_exactly_despite_batching(wiz):
    """Batching the RENDER must not batch the PARSE: every atom, its final step and its
    group must be identical to the per-line behaviour, and each package's row must nest
    under the stage that was running when it appeared."""
    page = _fresh_page(wiz)
    row = page._rows[0]
    lines = [_banner("Native emerge inside chroot"), _banner("Emerge group: image")]
    atoms = ["dev-lang/duktape-2.7.0-r3", "sys-libs/zlib-1.3.1-r1",
             "media-libs/freetype-2.14.3"]
    for n, atom in enumerate(atoms, start=1):
        lines.append(f">>> Emerging ({n} of 3) {atom}::gentoo")
        lines.append(f">>> Completed ({n} of 3) {atom}::gentoo")
    # ONE batch: every line arrives before a single drain runs
    for ln in lines:
        page._on_line(0, ln)
    page._drain_lines()

    assert set(row.pkg_items) == {f"{a}::gentoo".split("::")[0] for a in atoms} or \
        set(row.pkg_items) == set(atoms), f"unexpected atoms: {sorted(row.pkg_items)}"
    assert row.pkg_parser.totals() == (3, 3), "the done/total counter must be exact"
    assert "image" in row.group_items, "the group node must exist"
    # the group nests under the STAGE that was running when its first package appeared —
    # deferring item creation to the end of the batch would file it under a later stage.
    parent = row.group_items["image"].parent()
    assert parent is row.stage_items[row.tracker.cur]
    for atom in atoms:
        assert row.pkg_progress[atom].step == progress_mod.STEP_DONE


def test_a_package_repainted_by_a_burst_costs_one_repaint_per_drain(wiz):
    """74,998 lines of a real build are ninja counters for the SAME atom, each of which
    changed tool_info and so defeated the fingerprint guard and repainted. They must now
    cost ONE repaint for the whole batch, showing the LAST counter."""
    page = _fresh_page(wiz)
    row = page._rows[0]
    for ln in (_banner("Native emerge inside chroot"),
               _banner("Emerge group: image"),
               ">>> Emerging (1 of 8) media-gfx/inkscape-1.4.3::gentoo",
               ">>> Compiling source in /var/tmp/portage/media-gfx/inkscape-1.4.3/work"):
        page._on_line(0, ln)
    page._drain_lines()

    atom = "media-gfx/inkscape-1.4.3"
    tool = row.pkg_tools[atom]
    writes = {"n": 0}
    real_set = tool.setText

    def counting_set(t):
        writes["n"] += 1
        real_set(t)

    tool.setText = counting_set

    for k in range(1, 501):
        page._on_line(0, f"[{k}/1186] /usr/bin/x86_64-pc-linux-gnu-g++ -c src/f{k}.cc")
    page._drain_lines()

    assert writes["n"] == 1, "one package repaint per drain, never one per line"
    assert "[500/1186]" in tool.text(), "and it must show the LAST line of the batch"


# ── 3. the bounded document ───────────────────────────────────────────────────────────

def test_the_live_pane_is_bounded_and_the_drill_down_still_restores_it(wiz):
    """An hours-long build must not grow the QTextDocument without bound. The cap is safe
    only because the job's authoritative raw log is _Row.buffer (a bounded deque) and
    clicking the job row reloads the pane from THAT — so the cap can only ever drop lines
    the drill-down had already dropped."""
    page = _fresh_page(wiz)
    row = page._rows[0]
    assert page.log.maximumBlockCount() == progress_mod._LOG_MAX_BLOCKS
    assert progress_mod._LOG_MAX_BLOCKS > row.buffer.maxlen, (
        "the live cap must exceed the buffer the drill-down restores, or capping WOULD "
        "lose recoverable scrollback")

    n = progress_mod._LOG_MAX_BLOCKS + 500
    for i in range(n):
        page._on_line(0, f"line {i}")
    page._drain_lines()

    assert page.log.blockCount() <= progress_mod._LOG_MAX_BLOCKS
    assert f"line {n - 1}" in page.log.toPlainText(), "the newest output must survive"
    # the drill-down is unaffected: it reloads from the ring buffer, whole
    page._load_detail(0, None)
    assert len(row.buffer) == row.buffer.maxlen
    assert page.log.toPlainText().endswith(f"line {n - 1}")


def test_a_package_log_view_lifts_the_cap(wiz, tmp_path):
    """A PACKAGE's own emerge log is a FILE read (tail-bounded at _PKG_LOG_TAIL_BYTES),
    not a ring buffer, so capping that pane would silently eat its HEAD."""
    page = _fresh_page(wiz)
    row = page._rows[0]
    row.log_root = str(tmp_path)
    for ln in (_banner("Native emerge inside chroot"),
               _banner("Emerge group: image"),
               ">>> Emerging (1 of 1) dev-lang/duktape-2.7.0-r3::gentoo"):
        page._on_line(0, ln)
    page._drain_lines()

    page._load_package_detail(0, "dev-lang/duktape-2.7.0-r3")
    assert page.log.maximumBlockCount() == 0, "the file view must be uncapped"
    page._load_detail(0, None)                      # back to the stream view
    assert page.log.maximumBlockCount() == progress_mod._LOG_MAX_BLOCKS
