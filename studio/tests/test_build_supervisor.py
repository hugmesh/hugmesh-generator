"""ASK 16 — a build must SURVIVE its window closing.

Before this lane, ``ProgressPage.__init__`` wired ``self.wiz.finished.connect(
self._abort_run)``. QWizard is a QDialog, so ``finished`` fires on an ordinary window
CLOSE: closing the Studio cancelled the builder and joined the worker thread. These
tests pin the inverse — and the mutation at the bottom of this file re-ties the two and
proves the survival test then FAILS, so it is a guard rather than decoration.

A real builder is never launched here (this environment forbids builds). The driver is a
stub whose ``run_all`` blocks on an Event and whose ``cancel_all`` records the fact —
which is exactly the surface the survival question turns on.
"""
import os
import threading

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.gui import build_supervisor                     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402
from hugmesh_studio.gui.wizard import StudioWizard                  # noqa: E402
from hugmesh_studio.gui.pages import progress as progress_mod       # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _fresh_supervisor():
    build_supervisor.reset_supervisor()
    yield
    sup = build_supervisor.supervisor()
    sup.cancel_all(wait_ms=2000)
    build_supervisor.reset_supervisor()


class _StubDriver:
    """A WorklistDriver stand-in: run_all blocks until released; cancel_all records."""

    def __init__(self):
        self.release = threading.Event()
        self.cancelled = False
        self.results = []
        self.lines = []

    def run_all(self, *, on_entry_start=None, on_line=None, on_entry_done=None,
                on_manifest=None, on_keys=None):
        self._on_line = on_line
        self.release.wait(timeout=20)
        return 0

    def cancel_all(self):
        self.cancelled = True
        self.release.set()

    def cancel(self, _i):
        self.cancel_all()


def _dispatched_page(qapp, monkeypatch, wire_legacy_abort=False, session=False,
                     tmp_path=None):
    """A real StudioWizard whose ProgressPage has a stub run DISPATCHED (worker
    started, supervisor adopted) — the state a window close has to survive.

    ``session=True`` also attaches a real, saved BuildSession record, which is what the
    "a quit must record the build as stopped" test needs.
    """
    from hugmesh_studio.core import build_sessions as bs
    wiz = StudioWizard(GENERATOR_DIR)
    page = next(p for p in wiz._pages if isinstance(p, progress_mod.ProgressPage))
    if wire_legacy_abort:
        # THE MUTATION: re-tie the build's lifetime to the window, exactly as the
        # pre-fix code did.
        wiz.finished.connect(page._abort_run)
    if session:
        workdir = str(tmp_path / "out" / "sessions" / "20260505-000000-eeeeee")
        os.makedirs(workdir, exist_ok=True)
        page._session = bs.BuildSession(id="20260505-000000-eeeeee",
                                        created="2026-05-05T00:00:00",
                                        label="be · x86", workdir=workdir,
                                        images=[])
        page._session_done = False
        bs.save(page._session)
    driver = _StubDriver()
    page.driver = driver
    page._start_worker()
    return wiz, page, driver


# ── the ask ──────────────────────────────────────────────────────────────────────────
def test_closing_the_window_does_not_stop_a_running_build(qapp, monkeypatch):
    wiz, page, driver = _dispatched_page(qapp, monkeypatch)
    try:
        assert page.worker is not None and page.worker.isRunning()
        wiz.show()
        wiz.close()                       # <- the operator closes the Studio window
        qapp.processEvents()
        assert driver.cancelled is False, "closing the window cancelled the builder"
        assert page.worker.isRunning(), "closing the window joined/killed the worker"
        assert build_supervisor.supervisor().count() == 1
    finally:
        driver.cancel_all()
        page.worker.wait(5000)


def test_the_supervisor_owns_the_worker_not_the_page(qapp, monkeypatch):
    """Qt ownership is the thing that makes survival real: the worker's parent must be
    the supervisor (an application-lived QObject), never the page or the window."""
    wiz, page, driver = _dispatched_page(qapp, monkeypatch)
    try:
        assert page.worker.parent() is build_supervisor.supervisor()
        assert page.worker.parent() is not page
        assert page.worker.parent() is not wiz
    finally:
        driver.cancel_all()
        page.worker.wait(5000)


def test_the_supervisor_pins_the_window_alive_while_the_build_runs(qapp, monkeypatch):
    """The crash this defends against: destroying a window under a live worker leaves
    the page's slots streaming into deleted C++ objects (qFatal under PyQt6). While a
    run is live the supervisor holds a strong reference to its window."""
    wiz, page, driver = _dispatched_page(qapp, monkeypatch)
    try:
        build = build_supervisor.supervisor().running()[0]
        assert build.window is wiz.window()
        wiz.show()
        wiz.close()
        qapp.processEvents()
        assert build.window is wiz.window(), "the window pin was dropped on close"
    finally:
        driver.cancel_all()
        page.worker.wait(5000)


def test_the_pin_is_released_when_the_build_finishes(qapp, monkeypatch):
    wiz, page, driver = _dispatched_page(qapp, monkeypatch)
    build = build_supervisor.supervisor().running()[0]
    driver.release.set()                   # the run completes on its own
    page.worker.wait(5000)
    for _ in range(50):
        qapp.processEvents()
        if build.finished:
            break
    assert build.finished is True
    assert build.window is None, "a finished build must not keep pinning its window"
    assert build_supervisor.supervisor().running() == []


def test_a_real_quit_still_cancels(qapp, monkeypatch):
    """Detaching on close is not "never cancel": a REAL process exit must still stop
    the builder rather than orphan it. That is cancel_all(), wired to aboutToQuit."""
    wiz, page, driver = _dispatched_page(qapp, monkeypatch)
    n = build_supervisor.supervisor().cancel_all(wait_ms=5000)
    assert n == 1
    assert driver.cancelled is True
    assert build_supervisor.supervisor().running() == []


def test_detach_stops_the_cosmetic_timers_and_the_flash_queue(qapp, monkeypatch):
    """A closed window paints nothing, so its timers stop — and a QUEUED destructive
    flash must never fire at a window nobody is watching. Neither is a build cancel."""
    wiz, page, driver = _dispatched_page(qapp, monkeypatch)
    try:
        page._flash_queue = [object()]
        page._tick.start()
        page._flash_timer.start()
        wiz.show()
        wiz.close()
        qapp.processEvents()
        assert page._flash_queue == []
        assert not page._tick.isActive()
        assert not page._flash_timer.isActive()
        assert driver.cancelled is False
    finally:
        driver.cancel_all()
        page.worker.wait(5000)


def test_running_roster_reports_the_live_build(qapp, monkeypatch):
    wiz, page, driver = _dispatched_page(qapp, monkeypatch)
    try:
        live = build_supervisor.supervisor().running()
        assert len(live) == 1
        assert live[0].is_running() is True
        assert live[0].label                       # never a blank tray row
        assert ":" in live[0].menu_text()          # label + elapsed mm:ss
    finally:
        driver.cancel_all()
        page.worker.wait(5000)


# ── MUTATION: re-tie the lifetime to the window; the survival test must fail ─────────
def test_mutation_rewiring_abort_to_the_window_breaks_survival(qapp, monkeypatch):
    """Proof that the survival test above BITES: with the pre-fix connection restored,
    closing the window cancels the builder — exactly what the guard forbids."""
    wiz, page, driver = _dispatched_page(qapp, monkeypatch, wire_legacy_abort=True)
    try:
        wiz.show()
        wiz.close()
        qapp.processEvents()
        assert driver.cancelled is True, (
            "the mutation did not reproduce the pre-fix behaviour — the survival "
            "test above would pass for the wrong reason")
    finally:
        driver.cancel_all()
        page.worker.wait(5000)


# ── REPAIR (freeze audit): a quit-stopped build must be RECORDED stopped ─────────────
# Moving the abort off the window close took `_finalize_session(status="stopped")` with
# it: cancel_all() stopped the builder but wrote nothing, so a Studio quit mid-build
# left the session record at "running" with a dead pid — which the build list renders
# as "running (stale?)" forever instead of the truth, "stopped".
def test_a_real_quit_records_the_build_as_stopped(qapp, monkeypatch, tmp_path):
    from hugmesh_studio.core import build_sessions as bs
    wiz, page, driver = _dispatched_page(qapp, monkeypatch, session=True,
                                         tmp_path=tmp_path)
    assert page._session is not None, "the fixture must have a real session record"
    sid = page._session.id
    def _status():
        return next(r.status for r in bs.load_all() if r.id == sid)
    assert _status() == bs.RUNNING
    build_supervisor.supervisor().cancel_all(wait_ms=5000)
    assert _status() == bs.STOPPED, (
        "the Studio stopped this build and then said nothing about it")


def test_the_supervisor_never_writes_the_record_itself(qapp, monkeypatch):
    """It CALLS BACK the owner. A supervisor that wrote session records would be a
    second writer racing the page's own finish write."""
    calls = []
    sup = build_supervisor.supervisor()

    class _W:
        def isRunning(self):
            return True

        def setParent(self, _p):
            pass

        def wait(self, _ms):
            return True

    sup.adopt(session_id="x", label="x", worker=_W(), driver=None,
              on_cancelled=lambda: calls.append(1))
    sup.cancel_all(wait_ms=100)
    assert calls == [1]


def test_a_raising_on_cancelled_cannot_abort_the_teardown(qapp, monkeypatch):
    """cancel_all runs from aboutToQuit; an escaping exception there aborts the process
    mid-exit under PyQt6."""
    sup = build_supervisor.supervisor()

    class _W:
        def isRunning(self):
            return True

        def setParent(self, _p):
            pass

        def wait(self, _ms):
            return True

    def _boom():
        raise RuntimeError("finalise exploded")
    sup.adopt(session_id="x", label="x", worker=_W(), driver=None, on_cancelled=_boom)
    assert sup.cancel_all(wait_ms=100) == 1        # did not raise
