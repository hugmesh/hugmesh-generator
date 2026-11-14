"""The Build page's preflight worker is held while it runs (Windows contract).

The page's debounce timer can fire from ANY event pump, the test suite's end-of-session
drain included: a ``_PreflightWorker`` started there, outside the registry the drain
waits on, was still running when the interpreter exited, a ``QThread: Destroyed while
thread is still running`` qFatal (found 2026-11-13 on Windows 11, once conftest's drain
was made to work under PySide6: tests/test_walkthrough_build_titles.py aborted 12 of 12
runs under load after both tests passed). ``hold_thread`` puts it in that registry for
exactly as long as it runs.
"""
import os
import threading

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo            # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod               # noqa: E402
from hugmesh_studio.gui.pages import _widgets                     # noqa: E402
from hugmesh_studio.gui.pages import build as build_mod           # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                       # noqa: E402
from _helpers import type_login_password                          # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(["hugmesh-studio-tests"])


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _build_page(wiz):
    from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS
    for _ in range(len(WIZARD_PAGE_SLUGS) + 1):
        page = wiz.currentPage()
        if isinstance(page, wizard_mod.BuildPage):
            return page
        type_login_password(page)
        wiz.next()
    raise AssertionError("never reached BuildPage")


def test_a_running_preflight_worker_is_in_the_registry_the_drain_waits_on(
        wiz, qapp, monkeypatch):
    page = _build_page(wiz)
    old = page._preflight_worker
    if old is not None:
        old.wait(10000)
    gate = threading.Event()
    real_run = build_mod._PreflightWorker.run
    monkeypatch.setattr(build_mod._PreflightWorker, "run",
                        lambda self: (gate.wait(10), real_run(self)))
    page._run_recompute()
    worker = page._preflight_worker
    assert worker is not None and worker is not old
    try:
        assert worker.isRunning()
        assert worker in _widgets.in_flight_probes(), \
            "a running preflight worker the end-of-session drain cannot see"
    finally:
        gate.set()
        assert worker.wait(20000)
    for _ in range(50):
        qapp.processEvents()
        if worker not in _widgets.in_flight_probes():
            break
    assert worker not in _widgets.in_flight_probes(), "held after it finished"
