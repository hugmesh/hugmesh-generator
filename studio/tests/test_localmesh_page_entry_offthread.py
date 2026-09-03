"""Entering the local-mesh page must not block on docker.

WHY THIS TEST EXISTS. LocalMeshPage.initializePage ran FOUR blocking docker probes inline,
on the GUI thread, before the page had painted:

  * ``_refresh_status`` -> ``MeshNode.status()``            — subprocess.run(timeout=30)
                                                              (core/mesh_node.py:135)
  * ``_sync_e2e_gate``  -> ``LocalStackNode.e2e_ready()``, which is
      - ``status()``                                        — timeout=30
                                                              (core/local_stack_node.py:872)
      - ``running_env()``: `compose ps -q` then `docker inspect`
                                                            — timeout=30 twice
                                                              (local_stack_node.py:690, :697)
      - ``e2e_seeded()``                                     — urlopen(timeout=5)

A wedged or merely busy docker daemon blocks each of those for its FULL timeout, so simply
arriving at the page could freeze the window for ~95 seconds with nothing on screen. The
verbs on this page were always off-thread (_MeshWorker); it was the page-entry probes that
were not. ``_probe_mesh_state``/_StatusProbe already established the right shape for
exactly this, and its docstring already named the defect class — these two probes were
just never converted.

Also pinned here: the TRI-STATE. While a probe is out, "unknown" must be rendered as
unknown ("checking…"), never as "stopped"/"not ready" — a claim about the operator's mesh
that nothing has established.
"""
from __future__ import annotations

import os
import threading
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from types import SimpleNamespace                                   # noqa: E402

from hugmesh_studio.core import local_mesh_bootstrap as lmb         # noqa: E402
from hugmesh_studio.core.mesh_node import MeshNode, MeshStatus      # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

#: The budget initializePage is held to. The faked probes park on an Event rather than a
#: clock (a sleep would only prove the freeze took less than the sleep), so this is purely
#: the ceiling: entering the page must cost milliseconds, not a fraction of a second.
_PROBE_S = 1.0


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


class _SlowStack:
    """A LocalStackNode stand-in whose probes block, and record the thread they ran on."""

    #: read by the plan preview (non-probe, non-blocking) — a real LocalStackNode's value
    web_url = "http://localhost:8088"

    def __init__(self):
        self.threads: list[int] = []
        self.gate = threading.Event()
        self.environments_asked: list[str] = []

    def status(self):
        self.threads.append(threading.get_ident())
        self.gate.wait(10)
        return SimpleNamespace(running=True, detail="49 container(s)")

    def e2e_ready(self, environment="docker"):
        # `environment` arrived 2026-08-26 with the Studio's e2e environment
        # chooser: the readiness question is now asked ABOUT a named mesh, so the
        # probe carries which one. Recorded rather than ignored, so this fake
        # also witnesses that the page asks about the environment it is showing
        # instead of always asking about docker.
        self.threads.append(threading.get_ident())
        self.environments_asked.append(environment)
        self.gate.wait(10)
        return []                              # ready


@pytest.fixture
def page(qapp, monkeypatch):
    """A LocalMeshPage whose every docker probe is slow and faked — no docker is ever
    shelled, and every probe records which thread it ran on."""
    stack = _SlowStack()
    node_threads: list[int] = []

    def slow_node_status(self):
        node_threads.append(threading.get_ident())
        stack.gate.wait(10)
        return MeshStatus(running=False, detail="not started")

    monkeypatch.setattr(MeshNode, "status", slow_node_status)
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "_stack_node", lambda self: stack)
    p = localmesh_mod.LocalMeshPage(
        SimpleNamespace(generator_dir=GENERATOR_DIR, cfg=SimpleNamespace(),
                        localmesh_selected=True))
    p.stack, p.node_threads = stack, node_threads
    yield p
    # Never let a live QThread outlive its page: destroying one aborts under Qt.
    stack.gate.set()
    for name in ("_probe", "_node_probe", "_e2e_probe", "_monitor_probe"):
        t = getattr(p, name, None)
        if t is not None:
            t.wait(5000)
    qapp.processEvents()
    p.deleteLater()


_PROBE_ATTRS = ("_probe", "_node_probe", "_e2e_probe", "_monitor_probe")


def _settle(qapp, page, timeout_s=8.0):
    """Run the event loop until every probe has finished AND its queued signal has been
    delivered — including probes a delivered signal starts in turn (_on_mesh_state
    re-gates, which can launch a fresh e2e probe). Quiescence is only believed after
    several consecutive idle passes: QThread.isRunning() is still False in the instant
    between start() and the OS thread actually running."""
    deadline = time.monotonic() + timeout_s
    idle = 0
    while time.monotonic() < deadline and idle < 20:
        for n in _PROBE_ATTRS:
            t = getattr(page, n, None)
            if t is not None:
                t.wait(200)
        qapp.processEvents()
        busy = any(getattr(page, n, None) is not None and getattr(page, n).isRunning()
                   for n in _PROBE_ATTRS)
        idle = 0 if busy else idle + 1
        time.sleep(0.005)
    qapp.processEvents()


def test_entering_the_page_returns_immediately(qapp, page):
    """THE freeze test. Every probe is parked; initializePage must still return at once."""
    t0 = time.monotonic()
    page.initializePage()
    elapsed = time.monotonic() - t0

    assert elapsed < _PROBE_S / 2, (
        f"initializePage blocked for {elapsed:.2f}s — the docker probes are back on the "
        f"GUI thread")
    # all three probes are genuinely in flight, off-thread
    assert page._node_probe.isRunning()
    assert page._e2e_probe.isRunning()
    assert page._probe.isRunning()
    qapp.processEvents()                       # the event loop still turns; no freeze

    page.stack.gate.set()
    _settle(qapp, page)
    gui = threading.get_ident()
    assert page.node_threads and gui not in page.node_threads, \
        "MeshNode.status() ran on the GUI thread"
    assert page.stack.threads and gui not in page.stack.threads, \
        "a LocalStackNode probe ran on the GUI thread"


def test_unknown_is_rendered_as_unknown_not_as_no(qapp, page):
    """Tri-state. While the probes are out the page must say it is CHECKING — rendering
    'stopped' / listing blockers would state something nothing has established."""
    page.initializePage()

    assert "checking" in page.status.text().lower()
    assert "stopped" not in page.status.text().lower()
    assert page._mesh_up is None, "the mesh state must stay unknown until answered"
    assert "checking" in page._mesh_state_label.text().lower()
    # the e2e action cannot be ARMED on an unverified stack, but the reason offered must
    # be "still checking", never a list of blockers nobody established
    assert not page.e2e_btn.isEnabled()
    tip = page.e2e_btn.toolTip()
    assert "Checking" in tip and "Disabled:" not in tip

    page.stack.gate.set()
    _settle(qapp, page)

    assert "checking" not in page.status.text().lower()
    assert "stopped" in page.status.text().lower()      # the faked node really is down
    assert page._mesh_up is True                        # …while the STACK is up
    assert page.e2e_btn.isEnabled(), "no problems were reported, so the gate must open"
    assert "Disabled:" not in page.e2e_btn.toolTip()


def test_a_second_entry_does_not_stack_probe_threads(qapp, page):
    """Re-entering (or a verb finishing) while a probe is still out must reuse it, not
    launch another docker subprocess per visit."""
    page.initializePage()
    first = (page._node_probe, page._e2e_probe, page._probe)
    page.initializePage()
    assert (page._node_probe, page._e2e_probe, page._probe) == first

    page.stack.gate.set()
    _settle(qapp, page)


def test_a_blocked_gate_never_arms_the_e2e_button(qapp, page):
    """The gate's ANSWER owns e2e enablement, never the busy-verb blanket.

    _set_verbs_enabled(True) re-enables every verb button when a run ends or the mesh-
    state probe reports in. e2e is not a verb-busy question but a claim about the RUNNING
    stack (test env + up + seeded), and since the gate went off-thread that claim is not
    instantly available — so a blanket enable here would arm the action on evidence nobody
    gathered, including in the window while the gate's own probe is still out."""
    page.initializePage()

    # WHILE the gate probe is parked: the blanket re-enable must not arm it
    assert page._e2e_probe.isRunning()
    page._set_verbs_enabled(True)
    assert page.preflight_btn.isEnabled(), "the real verb buttons still re-enable"
    assert not page.e2e_btn.isEnabled(), "unverified is not 'enabled'"
    assert "Checking" in page.e2e_btn.toolTip()

    page.stack.gate.set()
    _settle(qapp, page)
    assert page.e2e_btn.isEnabled(), "no problems were reported, so the gate opens"

    # and once the stack reports a blocker, the button closes with the honest reason
    assert set(page.stack.environments_asked) == {"docker"}, (
        "the gate must be asked about the environment the chooser is showing "
        "(default docker), not about an unspecified one")
    page.stack.e2e_ready = (
        lambda environment="docker": ["the local stack is not running — bring it up first."])
    page._set_verbs_enabled(True)
    assert not page.e2e_btn.isEnabled()
    _settle(qapp, page)
    assert not page.e2e_btn.isEnabled()
    assert "not running" in page.e2e_btn.toolTip()
