"""The Desktop step's "Check with emerge --pretend" worker must outlive its own ``done``.

2026-11-12, operator: "when we try to run the emerge pretend on the new desktop
configuration it just crashes". ``_PretendWorker.run()`` emits ``done`` from INSIDE the
thread, so its queued slot reaches the GUI thread while the QThread is still running (run()
returning, the OS thread exiting). The page dropped its only reference to the worker in that
slot (``self._worker = None``), the wrapper was collected, and Qt aborted the process:
``QThread: Destroyed while thread is still running``.

These tests build the page on a stand-in wizard (cfg / generator_dir / host): the check needs
nothing else, and a walk through the earlier steps would test those steps instead.
"""
from __future__ import annotations

import os
import subprocess
import sys
import textwrap
import threading
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

#: The harness both tests share: a DesktopPage on a stand-in wizard, the machine gate open,
#: and a fake BuildDriver whose _stream replays builder output (no container, no build).
_HARNESS = textwrap.dedent('''
    import os, sys, tempfile, time
    from types import SimpleNamespace
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from hugmesh_studio.core import build_driver as bd
    from hugmesh_studio.core import desktop_pretend as dp
    from hugmesh_studio.core.config import ImageConfig
    from hugmesh_studio.core.platform_info import HostInfo
    from hugmesh_studio.gui.qt import QtWidgets
    from hugmesh_studio.gui.pages import desktop as desktop_mod

    HOST = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    LINES = ["==> Pretend result: status=clean rc=0 seed_python=python3_14 video_cards=intel",
             dp.EXCERPT_BEGIN]
    # a real desktop plan is ~1100 package lines; stream more than that
    LINES += [f"[ebuild  N     ] cat/pkg{i}-1.0::gentoo  USE=\\"x -y\\"" for i in range(N_LINES)]
    LINES += ["Total: %d packages" % N_LINES, dp.EXCERPT_END]

    class FakeDriver:
        def __init__(self, *a, **k):
            self.host = HOST
        def command(self, cfg, backend=None):
            return ["fake-builder", "--pretend-only"]
        def _stream(self, argv, sink, backend):
            for line in LINES:
                sink(line)
            return 0
        def cancel(self):
            pass

    bd.BuildDriver = FakeDriver
    dp.gate = lambda *a, **k: ""
    dp.supported = lambda cfg: ""
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"])
    cfg = ImageConfig(mode="standalone", role="standalone-unaffiliated", platform="x86")
    cfg.output_dir = tempfile.mkdtemp()
    page = desktop_mod.DesktopPage(SimpleNamespace(cfg=cfg, generator_dir=GEN, host=HOST,
                                                   worklist=None))
    page.initializePage()

    def run_once():
        page.last_result = None
        why = page.start_pretend()
        t0 = time.time()
        while why == "A check is already running." and time.time() - t0 < 10:
            app.processEvents()
            why = page.start_pretend()
        assert not why, why
        t0 = time.time()
        while page.last_result is None and time.time() - t0 < 30:
            app.processEvents()
        assert page.last_result is not None, "no result within 30 s"
        return page.last_result
''')


def _run_harness(body: str, *, n_lines: int, timeout: int = 240) -> subprocess.CompletedProcess:
    script = (f"N_LINES = {n_lines}\nGEN = {GENERATOR_DIR!r}\n" + _HARNESS
              + textwrap.dedent(body))
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen",
               PYTHONPATH=STUDIO_ROOT + os.pathsep + os.environ.get("PYTHONPATH", ""))
    return subprocess.run([sys.executable, "-c", script], capture_output=True, text=True,
                          timeout=timeout, env=env, cwd=STUDIO_ROOT)


def test_back_to_back_checks_never_destroy_a_running_worker():
    """The crash itself, in a child process (a qFatal would take pytest down with it): run
    the check again and again the moment each result lands. Before the fix this aborted
    with "QThread: Destroyed while thread is still running" (exit 134) within the run on
    3 of 3 tries; it must now finish every round."""
    p = _run_harness('''
        for i in range(300):
            res = run_once()
            assert res.status == "clean", (res.status, res.reason)
        t0 = time.time()
        while page._worker is not None and time.time() - t0 < 10:
            app.processEvents()
        print("ROUNDS-OK", page.pretend_log.blockCount())
    ''', n_lines=20)
    assert "Destroyed while thread" not in p.stderr, p.stderr[-2000:]
    assert p.returncode == 0, (p.returncode, p.stderr[-2000:])
    assert "ROUNDS-OK" in p.stdout


def test_a_real_sized_plan_streams_into_the_page_without_trouble():
    """~1100 package lines arrive as one queued signal each; the box takes them all."""
    p = _run_harness('''
        res = run_once()
        t0 = time.time()
        while page._worker is not None and time.time() - t0 < 10:
            app.processEvents()
        assert res.status == "clean", (res.status, res.reason)
        print("LINES", page.pretend_log.blockCount())
    ''', n_lines=3000)
    assert p.returncode == 0, (p.returncode, p.stderr[-2000:])
    assert "LINES" in p.stdout
    assert int(p.stdout.split("LINES")[1].split()[0]) >= 3000


# ── the invariant behind it, deterministically, in-process ─────────────────────────────


@pytest.fixture(scope="module")
def qapp():
    from hugmesh_studio.gui.qt import QtWidgets
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"])


def test_the_page_holds_the_worker_until_finished_not_until_done(qapp, monkeypatch, tmp_path):
    """Hold the worker's thread open AFTER it emitted ``done`` (where the real one is
    returning from run()): the page must still hold the worker then, and let it go only on
    ``finished``. On main the ``done`` slot set ``_worker = None`` here."""
    from types import SimpleNamespace
    from hugmesh_studio.core import build_driver as bd
    from hugmesh_studio.core import desktop_pretend as dp
    from hugmesh_studio.core.config import ImageConfig
    from hugmesh_studio.core.platform_info import HostInfo
    from hugmesh_studio.gui.pages import _widgets
    from hugmesh_studio.gui.pages import desktop as desktop_mod

    host = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    release = threading.Event()

    class FakeDriver:
        def __init__(self, *a, **k):
            self.host = host

        def command(self, cfg, backend=None):
            return ["fake-builder"]

        def _stream(self, argv, sink, backend):
            sink("==> Pretend result: status=clean rc=0 seed_python=python3_14 video_cards=intel")
            sink(dp.EXCERPT_BEGIN)
            sink("Total: 1 package")
            sink(dp.EXCERPT_END)
            return 0

        def cancel(self):
            pass

    real_run = desktop_mod._PretendWorker.run

    def run_then_linger(self):
        real_run(self)                  # emits done
        release.wait(20)                # the thread is still running after done

    monkeypatch.setattr(desktop_mod._PretendWorker, "run", run_then_linger)
    monkeypatch.setattr(bd, "BuildDriver", FakeDriver)
    monkeypatch.setattr(dp, "gate", lambda *a, **k: "")
    monkeypatch.setattr(dp, "supported", lambda cfg: "")
    cfg = ImageConfig(mode="standalone", role="standalone-unaffiliated", platform="x86")
    cfg.output_dir = str(tmp_path)
    page = desktop_mod.DesktopPage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR,
                                                   host=host, worklist=None))
    page.initializePage()
    try:
        assert page.start_pretend() == ""
        t0 = time.time()
        while page.last_result is None and time.time() - t0 < 20:
            qapp.processEvents()
        assert page.last_result is not None and page.last_result.status == "clean"
        worker = page._worker
        assert worker is not None, "the done slot dropped a worker that is still running"
        assert worker.isRunning()
        # the check itself is over: the button and a Re-check are available again
        assert page.pretend_btn.isEnabled() or dp.supported(page._pretend_cfg())
        assert not page.stop_btn.isEnabled()
    finally:
        release.set()
    t0 = time.time()
    while page._worker is not None and time.time() - t0 < 20:
        qapp.processEvents()
        time.sleep(0.005)
    assert page._worker is None, "finished did not release the worker"
    assert not [t for t in _widgets.in_flight_probes()
                if isinstance(t, desktop_mod._PretendWorker)]
