"""FREEZE fix: the Review&Build docker probe must run OFF the Qt main thread so the
wizard AND the shared-process tray never stall.

Simulates a SLOW `docker image inspect` (BuildDriver._image_present sleeps), triggers a
docker-backend config-change recompute, and asserts (offscreen) that (1) the Build
button enters a BUSY state and then re-enables, and (2) a tray poll timer sharing the
same event loop keeps firing throughout the probe — i.e. the loop is never blocked.
"""
import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import build_driver as bd            # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo        # noqa: E402
from hugmesh_studio.gui import tray as tray_mod               # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod           # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                   # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# host WITH docker so the (now off-thread) probe actually runs
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _build_page(wiz):
    return wiz.page(wiz._page_ids["build"])


def test_docker_recompute_off_main_thread_tray_never_freezes(qapp, monkeypatch):
    # (1) a SLOW docker probe — the exact call the freeze came from
    def slow_present(self):
        time.sleep(0.4)
        return True
    monkeypatch.setattr(bd.BuildDriver, "_image_present", slow_present)
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    # keep tray construction cheap (its node.status() would otherwise probe docker)
    monkeypatch.setattr(tray_mod._Section, "refresh", lambda self: None)

    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    build = _build_page(wiz)
    build.initializePage()

    # a tray sharing THIS process/event loop; count how often its poll timer fires
    tray = tray_mod.build_tray(GENERATOR_DIR)
    ticks = {"n": 0}
    tray._poll.timeout.disconnect()
    tray._poll.timeout.connect(lambda: ticks.__setitem__("n", ticks["n"] + 1))
    tray._poll.setInterval(10)

    # make the debounce immediate so the test doesn't wait 250ms
    build._recompute_timer.setInterval(0)
    # a CONFIG CHANGE: selecting the docker backend triggers _schedule_recompute()
    build.backend.setCurrentText("docker")
    assert build._recompute_busy                       # busy set synchronously
    assert build.isComplete() is False                 # Build button disabled while busy

    # pump the loop while the worker sleeps OFF-thread; it must never block
    start = time.time()
    while build._recompute_busy and time.time() - start < 8:
        qapp.processEvents()
        time.sleep(0.005)

    elapsed = time.time() - start
    assert not build._recompute_busy                   # recompute finished -> re-enabled
    assert elapsed >= 0.3, elapsed                      # the probe really did sleep off-thread
    # the tray poll timer kept firing DURING the ~0.8s probe -> event loop never stalled
    assert ticks["n"] >= 3, ticks

    build._join_preflight_worker()
    # STOP the poll timer before dropping the tray. It is a 10 ms repeating timer
    # this test rewired to a lambda, and deleteLater() only queues the delete: any
    # later ``processEvents()`` in the same process — the session-end probe drain in
    # tests/conftest.py is one — fires it again against objects this test has
    # finished with, and PyQt6 segfaults inside QTimer::timerEvent with no Python
    # frame to name. Measured 2026-09-04: this file passed all 3 tests and then
    # crashed the interpreter at exit.
    tray._poll.stop()
    tray.deleteLater()
    wiz.close(); wiz.deleteLater()
    qapp.processEvents()


def test_stale_recompute_result_is_dropped(qapp, monkeypatch):
    """Rapid config changes: only the NEWEST req_id's result is applied (stale worker
    results are dropped so the preview never flickers to an outdated preflight)."""
    monkeypatch.setattr(bd.BuildDriver, "_image_present", lambda self: True)
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    build = _build_page(wiz)
    build.initializePage()
    gen_before = build._recompute_gen
    build._schedule_recompute()
    build._schedule_recompute()
    build._schedule_recompute()
    assert build._recompute_gen >= gen_before + 3
    # a result carrying an OLD req_id must be ignored (not applied)
    build._set_problems(["placeholder"])
    build._on_preflight_done(["stale"], True, build._recompute_gen - 1)
    assert build._problems == ["placeholder"]          # stale result dropped
    build._join_preflight_worker()
    wiz.close(); wiz.deleteLater()


def test_run_recompute_rearms_when_a_probe_is_still_in_flight(qapp, monkeypatch):
    """Guard against a stuck-busy Build button: if _run_recompute fires while the just-
    superseded probe worker is still finishing (isRunning), it must RE-ARM the debounce
    (not silently return) so a pending recompute always has a trigger left."""
    monkeypatch.setattr(bd.BuildDriver, "_image_present", lambda self: True)
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    build = _build_page(wiz)
    build.initializePage()

    class _StillRunning:
        def isRunning(self):
            return True
    build._preflight_worker = _StillRunning()          # type: ignore[assignment]
    build._recompute_timer.stop()
    assert not build._recompute_timer.isActive()
    build._run_recompute()                              # worker still in flight
    assert build._recompute_timer.isActive()           # re-armed, not dropped
    build._recompute_timer.stop()
    build._preflight_worker = None
    wiz.close(); wiz.deleteLater()
