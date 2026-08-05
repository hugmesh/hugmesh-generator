"""The complete-from-the-GUI local mesh bring-up (streaming, cancel, cold timeouts,
the m2 prerequisite verb, readiness check, open-web-UI).

The bug this track fixes first: ``make stack-up`` ran under a FLAT 1800 s
subprocess timeout — a cold build (~28 service images, a dozen fat Maven builds)
routinely exceeds it, so the GUI KILLED every healthy first bring-up at minute 30
and reported it FAILED. Cold builds now get a generous ceiling plus live streamed
output and an operator Cancel (terminating the whole process group), and the two
cold-build dead-ends — "run `make stack-m2-bootstrap` first" with no button, and
no way to see readiness before committing — get first-class verbs.

Core tests monkeypatch ``subprocess.Popen`` to substitute a bash script for
``make`` — the streaming/cancel/timeout machinery under test is the REAL loop
(select, killpg, deadline), not a re-implementation.
"""
import os
import subprocess
import threading
import time
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import local_stack_node as lsn_mod          # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import (               # noqa: E402
    LocalMeshBootstrap, LocalMeshBootstrapConfig)
from hugmesh_studio.core.local_stack_node import (                   # noqa: E402
    COLD_STACK_UP_TIMEOUT_S, M2_BOOTSTRAP_TIMEOUT_S, WARM_STACK_UP_TIMEOUT_S,
    LocalStackNode)
from hugmesh_studio.core.mesh_node import MeshNode                   # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _node() -> LocalStackNode:
    return LocalStackNode(GENERATOR_DIR)


def _fake_make(monkeypatch, script: str):
    """Substitute a bash script for the ``make <target>`` child — everything else
    (pipes, select loop, process group, kill paths) is the real code."""
    real_popen = subprocess.Popen

    def popen(argv, **kw):
        assert argv[0] == "make"
        return real_popen(["bash", "-c", script], **kw)

    monkeypatch.setattr(lsn_mod.subprocess, "Popen", popen)


# ── the streaming loop itself ───────────────────────────────────────────────────────
def test_streaming_make_delivers_lines_live_and_returns_the_tail(monkeypatch):
    _fake_make(monkeypatch, 'echo one; echo two; echo three')
    got = []
    ok, msg = _node()._make("stack-up", timeout=30, on_line=got.append)
    assert ok
    assert got == ["one", "two", "three"]
    assert msg == "one\ntwo\nthree"


def test_streaming_make_reports_child_failure(monkeypatch):
    _fake_make(monkeypatch, 'echo boom >&2; exit 3')
    got = []
    ok, msg = _node()._make("stack-up", timeout=30, on_line=got.append)
    assert not ok
    assert got == ["boom"]          # stderr is merged into the stream


def test_cancel_terminates_the_whole_process_group_fast(monkeypatch):
    _fake_make(monkeypatch, 'echo started; sleep 300; echo never')
    cancel = threading.Event()
    got = []

    def on_line(line):
        got.append(line)
        cancel.set()                 # cancel as soon as the build starts talking

    t0 = time.monotonic()
    ok, msg = _node()._make("stack-up", timeout=600, on_line=on_line, cancel=cancel)
    assert not ok
    assert "cancelled by operator" in msg
    assert "never" not in got
    assert time.monotonic() - t0 < 30   # not the 300 s sleep, not the 600 s timeout


def test_timeout_kills_and_says_so(monkeypatch):
    _fake_make(monkeypatch, 'echo tick; sleep 300')
    ok, msg = _node()._make("stack-up", timeout=2, on_line=lambda _l: None)
    assert not ok and "timed out after 2 s" in msg


def test_buffered_path_is_byte_compatible(monkeypatch):
    seen = {}

    def run(argv, **kw):
        seen["argv"] = argv
        return SimpleNamespace(returncode=0, stdout="all good", stderr="")

    monkeypatch.setattr(lsn_mod.subprocess, "run", run)
    ok, msg = _node()._make("stack-down", timeout=300)   # no on_line, no cancel
    assert ok and msg == "all good"
    assert seen["argv"] == ["make", "stack-down"]


# ── cold-aware ceilings ─────────────────────────────────────────────────────────────
def _capture_make(monkeypatch, node):
    calls = {}

    def make(target, timeout, extra_env=None, on_line=None, cancel=None):
        calls.update(target=target, timeout=timeout)
        return True, "ok"

    monkeypatch.setattr(node, "_make", make)
    return calls


@pytest.mark.parametrize("cold,expect", [(True, COLD_STACK_UP_TIMEOUT_S),
                                         (False, WARM_STACK_UP_TIMEOUT_S)])
def test_stack_up_timeout_follows_cold_build_detection(monkeypatch, cold, expect):
    node = _node()
    monkeypatch.setattr(node, "preflight", lambda: [])
    monkeypatch.setattr(node, "cold_build_expected", lambda: cold)
    calls = _capture_make(monkeypatch, node)
    lines = []
    ok, _ = node.start(on_line=lines.append)
    assert ok and calls == {"target": "stack-up", "timeout": expect}
    # the cold banner tells the operator WHY this will take long — only when cold
    assert any("COLD BUILD" in l for l in lines) == cold


def test_the_old_flat_ceiling_would_have_killed_a_cold_build():
    # the regression this exists to prevent: the cold ceiling must comfortably
    # exceed the old flat 1800 s that killed healthy first bring-ups.
    assert COLD_STACK_UP_TIMEOUT_S >= 4 * 3600
    assert WARM_STACK_UP_TIMEOUT_S == 1800


def test_m2_bootstrap_runs_the_named_target_with_its_own_ceiling(monkeypatch):
    node = _node()
    calls = _capture_make(monkeypatch, node)
    ok, _ = node.m2_bootstrap()
    assert ok and calls == {"target": "stack-m2-bootstrap",
                            "timeout": M2_BOOTSTRAP_TIMEOUT_S}


# ── bootstrap-level: streaming milestones + the m2 passthrough ──────────────────────
def _happy_boot(monkeypatch, tmp_path):
    boot = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig())
    monkeypatch.setattr(boot, "guard_host_local", lambda: (True, ""))
    monkeypatch.setattr(boot, "validate", lambda: [])
    monkeypatch.setattr(boot, "preflight", lambda: [])
    monkeypatch.setattr(boot, "generate_creds", lambda: (True, "minted"))
    monkeypatch.setattr(boot, "read_superadmin",
                        lambda: {"username": "sa", "password": "x"})
    monkeypatch.setattr(LocalStackNode, "start",
                        lambda self, on_line=None, cancel=None:
                        (on_line and on_line("compose says hi")) or (True, "up"))
    monkeypatch.setattr(LocalStackNode, "seed",
                        lambda self, extra_env=None, timeout=600, on_line=None,
                        cancel=None: (True, "seeded"))
    return boot


def test_up_streams_its_milestones_and_the_make_output_live(monkeypatch, tmp_path):
    boot = _happy_boot(monkeypatch, tmp_path)
    streamed = []
    ok, log = boot.up(on_line=streamed.append)
    assert ok
    assert any("minted superadmin 'sa'" in l for l in streamed)
    assert "compose says hi" in streamed            # the live make/compose stream
    assert any(l.startswith("[done] platform up") for l in streamed)
    # the returned summary log holds the milestones but NOT the raw make stream
    assert any("[stack-up] ok" in l for l in log)
    assert "compose says hi" not in log


def test_bootstrap_m2_verb_streams_and_respects_the_host_guard(monkeypatch):
    boot = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig())
    monkeypatch.setattr(boot, "guard_host_local", lambda: (False, "in a pod"))
    ok, lines = boot.m2_bootstrap()
    assert not ok and lines == ["in a pod"]
    monkeypatch.setattr(boot, "guard_host_local", lambda: (True, ""))
    monkeypatch.setattr(LocalStackNode, "m2_bootstrap",
                        lambda self, on_line=None, cancel=None:
                        (on_line and on_line("mvn ...")) or (True, "registry up"))
    streamed = []
    ok, lines = boot.m2_bootstrap(on_line=streamed.append)
    assert ok and streamed == ["mvn ..."]
    assert lines == ["[m2-bootstrap] ok: registry up"]


# ── the GUI verbs ───────────────────────────────────────────────────────────────────
from hugmesh_studio.gui.pages import localmesh as localmesh_mod     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402


@pytest.fixture
def qapp():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


def _drain(qapp, page, timeout_s=15.0):
    deadline = time.monotonic() + timeout_s
    while page._running and time.monotonic() < deadline:
        w = getattr(page, "worker", None)
        if w is not None:
            w.wait(100)
        qapp.processEvents()
    qapp.processEvents()
    assert not page._running, "verb never finished"


def test_check_readiness_reports_problems_with_the_m2_pointer(qapp, monkeypatch):
    monkeypatch.setattr(LocalMeshBootstrap, "preflight",
                        lambda self: ["cold build required but the local maven "
                                      "registry is not up"], raising=True)
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.page.preflight_btn.click()
    _drain(qapp, dlg.page)
    text = dlg.log.toPlainText()
    assert "NOT ready" in text and "maven registry" in text
    assert "Build maven prereqs (m2)" in text       # the fix is named IN the report


def test_check_readiness_green_path(qapp, monkeypatch):
    monkeypatch.setattr(LocalMeshBootstrap, "preflight", lambda self: [],
                        raising=True)
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.page.preflight_btn.click()
    _drain(qapp, dlg.page)
    assert "READY" in dlg.log.toPlainText()


def test_m2_button_streams_the_build_into_the_log(qapp, monkeypatch):
    monkeypatch.setattr(
        LocalMeshBootstrap, "m2_bootstrap",
        lambda self, on_line=None, cancel=None:
            (on_line and on_line("[m2] building hugmesh-parent")) or
            (True, ["[m2-bootstrap] ok: registry up"]),
        raising=True)
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.page.m2_btn.click()
    _drain(qapp, dlg.page)
    text = dlg.log.toPlainText()
    assert "[m2] building hugmesh-parent" in text


def test_cancel_button_shows_during_a_cancellable_verb_and_stops_it(qapp):
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    page = dlg.page

    def slow_verb(on_line, cancel):
        on_line("working…")
        cancel.wait(20)              # returns immediately once Cancel fires
        return (not cancel.is_set()), ["end"]

    page._launch("Slow", slow_verb, stream=True, cancellable=True)
    # isHidden() reads the explicit flag — visibility-to-screen also depends on
    # which TAB is current, which is not what this asserts.
    assert not page.cancel_btn.isHidden() and page.cancel_btn.isEnabled()
    assert not page.m2_btn.isEnabled()          # verbs are one-at-a-time
    page._cancel_clicked()
    _drain(qapp, page)
    assert page.cancel_btn.isHidden()
    assert page.m2_btn.isEnabled()              # verbs re-armed after the cancel


def test_open_web_ui_opens_the_stack_front_door(qapp, monkeypatch):
    opened = []
    monkeypatch.setattr(localmesh_mod.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: opened.append(url.toString()) or True))
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.page.open_web_btn.click()
    assert opened == ["http://localhost:8088"]


# ── Stop says WHAT it did ──────────────────────────────────────────────────────────
def test_stop_says_nothing_was_running_instead_of_echoing_the_make_env(monkeypatch, tmp_path):
    """`make stack-down` echoes its whole STACK_ENV command line and compose prints
    nothing when there is nothing to remove, so a SUCCESSFUL stop rendered as a wall
    of env vars with no outcome — reported as "tried stopping and nothing happened"."""
    from hugmesh_studio.core.local_stack_node import StackStatus
    monkeypatch.setattr(LocalStackNode, "status",
                        lambda self: StackStatus(running=False, detail="not started"),
                        raising=True)
    monkeypatch.setattr(LocalStackNode, "stop",
                        lambda self: (True, "STACK_SRC='/x' CASDOOR_ISSUER_URI='y' "
                                            "PUBLIC_HOST_PORT='8088' docker compose ... down -v"),
                        raising=True)
    monkeypatch.setattr(MeshNode, "stop", lambda self: (True, "not started"), raising=True)
    ok, log = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(out_dir=str(tmp_path))).down()
    assert ok is True
    line = next(ln for ln in log if ln.startswith("[stack-down]"))
    assert "nothing was running" in line
    assert "STACK_SRC" not in line, "the make env wall leaked into the operator-facing line"


def test_stop_reports_what_it_stopped_when_something_was_running(monkeypatch, tmp_path):
    from hugmesh_studio.core.local_stack_node import StackStatus
    monkeypatch.setattr(LocalStackNode, "status",
                        lambda self: StackStatus(running=True, detail="44 container(s)"),
                        raising=True)
    monkeypatch.setattr(LocalStackNode, "stop", lambda self: (True, "noise"), raising=True)
    monkeypatch.setattr(MeshNode, "stop", lambda self: (True, "not started"), raising=True)
    ok, log = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(out_dir=str(tmp_path))).down()
    line = next(ln for ln in log if ln.startswith("[stack-down]"))
    assert "44 container(s)" in line and "dropped its volumes" in line


def test_a_failed_stop_still_shows_the_error_tail(monkeypatch, tmp_path):
    from hugmesh_studio.core.local_stack_node import StackStatus
    monkeypatch.setattr(LocalStackNode, "status",
                        lambda self: StackStatus(running=True, detail="3 container(s)"),
                        raising=True)
    monkeypatch.setattr(LocalStackNode, "stop",
                        lambda self: (False, "banner\n" + "noise\n" * 300 + "permission denied"),
                        raising=True)
    monkeypatch.setattr(MeshNode, "stop", lambda self: (True, "not started"), raising=True)
    ok, log = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(out_dir=str(tmp_path))).down()
    assert ok is False
    line = next(ln for ln in log if ln.startswith("[stack-down]"))
    assert line.endswith("permission denied"), "the failure tail must survive"
