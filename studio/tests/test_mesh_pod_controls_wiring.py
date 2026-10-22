"""Pod controls per domain — the WIRING the first round left untested (2026-10-21).

The pod-controls skeptic found eight mutations that left every test green: the
emulation pages' per-domain strip could be a no-op (S1), their onion Open could be
unwired (S2), and the local-mesh page's cross-guards between a page verb, a Replicas
change and a domain action could each be deleted (M3, M5, M6, M7), as could a failed
Tor Browser launch reporting "opened" (M12). Every test here drives the REAL handler
and asserts what it did — a ``receivers() > 0`` check would stay green with a handler
that does nothing, which is exactly S1.

Nothing here shells docker, kubectl or a browser: ``run_domain_action`` and the Tor
Browser launch are monkeypatched, and a "still running" worker is a QThread parked on
an Event that every test releases in a ``finally``.
"""
from __future__ import annotations

import os
import threading
import time
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import local_mesh_bootstrap as lmb              # noqa: E402
from hugmesh_studio.core import mesh_controls as mc                      # noqa: E402
from hugmesh_studio.core import mesh_monitor as mm                       # noqa: E402
from hugmesh_studio.core.mesh_node import MeshNode, MeshStatus           # noqa: E402
from hugmesh_studio.gui.pages import _mesh_monitor_widget as mw          # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod          # noqa: E402
from hugmesh_studio.gui.pages._widgets import own_probe, probe_running   # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                      # noqa: E402

from test_mesh_pod_controls_gui import (                                 # noqa: E402
    GENERATOR_DIR, ONION_A, _Node, _Stack, recorded_snapshot)

pytestmark = pytest.mark.real_mesh_monitor


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


def _wait(qapp, pred, timeout_s=8.0):
    deadline = time.monotonic() + timeout_s
    while not pred() and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.01)
    qapp.processEvents()
    return pred()


class _Parked(QtCore.QThread):
    """A worker that is 'still running' until the test lets it go."""

    def __init__(self, gate: threading.Event):
        super().__init__()
        self._gate = gate

    def run(self):                              # noqa: D102 — QThread contract
        self._gate.wait(10)


def _park(owner, attr, qapp):
    gate = threading.Event()
    t = own_probe(owner, attr, _Parked(gate))
    t.start()
    assert _wait(qapp, lambda: probe_running(owner, attr), 3)
    return gate, t


def _release(gate, t, qapp):
    gate.set()
    try:
        t.wait(5000)
    except RuntimeError:
        pass
    qapp.processEvents()


# ── the emulation pages' mount: MeshMonitorSection ───────────────────────────────

@pytest.fixture
def section(qapp, monkeypatch):
    host = QtWidgets.QWidget()
    lay = QtWidgets.QVBoxLayout(host)
    node = _Node("[]")
    sec = mw.MeshMonitorSection(host, GENERATOR_DIR, lambda: node, scaling=True)
    sec.mount(lay)
    host.resize(1400, 900)
    host.show()
    qapp.processEvents()
    # the real arrival path: the probe's result signal lands here
    sec._on_snapshot(recorded_snapshot(monkeypatch))
    qapp.processEvents()
    assert sec.monitor.isEnabled()
    yield sec
    sec.timer.stop()
    sec.shutdown()
    host.hide()
    host.deleteLater()
    qapp.processEvents()


def test_section_strip_press_runs_that_domains_action_off_thread(section, monkeypatch,
                                                                 qapp):
    """S1: the emulation pages' Logs/Stop press must reach run_domain_action with the
    chosen domain and verb, off the GUI thread, and its answer must land inline."""
    calls = []

    def fake(gen, node, units, domain, verb, **kw):
        calls.append((domain, verb, threading.get_ident(), len(tuple(units))))
        return mc.DomainResult(True, f"{verb} {domain}: done", "── c ──\nsection-log",
                               domain=domain, verb=verb)

    monkeypatch.setattr(mc, "run_domain_action", fake)
    mon = section.monitor
    assert mon.select_domain("acme.example")
    mon.domain_btns["logs"].click()
    assert _wait(qapp, lambda: bool(calls)
                 and not probe_running(section, "_domain_worker"))
    _wait(qapp, lambda: mon.logs_box.isVisibleTo(mon), 3)
    assert calls[0][:2] == ("acme.example", "logs")
    assert calls[0][2] != threading.get_ident()
    assert calls[0][3] == len(section.snapshot.units)
    assert mon.scale_status_text() == "logs acme.example: done"
    assert "section-log" in mon.logs_view.toPlainText()


def test_section_non_log_action_re_reads_the_lanes(section, monkeypatch, qapp):
    """After a Stop the section must re-read — the table only moves on a read."""
    monkeypatch.setattr(mc, "run_domain_action",
                        lambda g, n, u, d, v, **k: mc.DomainResult(True, f"{v} {d}: done",
                                                                   domain=d, verb=v))
    reasons = []
    monkeypatch.setattr(section, "refresh", lambda reason="": reasons.append(reason))
    section.monitor.select_domain("acme.example")
    section.monitor.domain_btns["stop"].click()
    assert _wait(qapp, lambda: "post-domain-action" in reasons)


def test_section_refuses_a_domain_action_while_a_scale_runs(section, monkeypatch, qapp):
    ran = []
    monkeypatch.setattr(mc, "run_domain_action",
                        lambda *a, **k: ran.append(a) or mc.DomainResult(True, "ran"))
    gate, t = _park(section, "_scale_worker", qapp)
    try:
        section.monitor.domain_action_requested.emit("acme.example", "stop")
        assert section.monitor.scale_status_text().startswith(
            "Not run: a Replicas change is still running")
        assert not probe_running(section, "_domain_worker")
    finally:
        _release(gate, t, qapp)
    assert ran == []


def test_section_onion_open_hands_the_address_to_tor_browser(section, monkeypatch,
                                                             qapp):
    """S2: an onion row's Open on the emulation pages reaches the Tor Browser hand-off
    with THAT row's address, and says so inline."""
    got = []
    monkeypatch.setattr(mw, "open_in_tor_browser", lambda url: got.append(url) or "")
    section.monitor.onion_open_requested.emit(ONION_A + "login")
    assert got == [ONION_A + "login"]
    assert section.monitor.scale_status_text() == \
        f"Opened {ONION_A}login in Tor Browser."
    monkeypatch.setattr(mw, "open_in_tor_browser", lambda url: "no launcher here")
    section.monitor.onion_open_requested.emit(ONION_A + "login")
    assert section.monitor.scale_status_text() == "Not opened: no launcher here"


# ── the Tor Browser hand-off itself ──────────────────────────────────────────────

@pytest.mark.parametrize("answer", [False, (False, 0)])
def test_a_failed_tor_browser_launch_never_reports_opened(monkeypatch, answer):
    """M12: startDetached answering False (PyQt) or (False, pid) (PySide) is a failure
    sentence, never the empty 'it opened' answer."""
    monkeypatch.setattr(mw.mesh_controls, "tor_browser_argv",
                        lambda url: ["/nonexistent/torbrowser-launcher", url])
    monkeypatch.setattr(mw.QtCore.QProcess, "startDetached",
                        staticmethod(lambda prog, args: answer))
    why = mw.open_in_tor_browser(ONION_A + "login")
    assert why == "Tor Browser could not be started (/nonexistent/torbrowser-launcher)."


# ── the local-mesh page's cross-guards ───────────────────────────────────────────

@pytest.fixture
def page(qapp, monkeypatch):
    st = _Stack()
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "_stack_node", lambda self: st)
    monkeypatch.setattr(MeshNode, "status",
                        lambda self: MeshStatus(running=False, detail="not started"))
    monkeypatch.setattr(localmesh_mod.mesh_monitor, "snapshot",
                        lambda *a, **k: mm.MonitorSnapshot(
                            "t", mm.LaneState(False), mm.LaneState(False)))
    p = localmesh_mod.LocalMeshPage(
        SimpleNamespace(generator_dir=GENERATOR_DIR, cfg=SimpleNamespace(),
                        localmesh_selected=True))
    yield p
    p._monitor_timer.stop()
    for name in ("_domain_worker", "_monitor_probe", "_probe", "_scale_worker",
                 "_worker"):
        t = getattr(p, name, None)
        if t is not None:
            try:
                t.wait(5000)
            except RuntimeError:
                pass
    qapp.processEvents()
    p.deleteLater()
    qapp.processEvents()


def test_page_refuses_a_domain_action_while_a_scale_runs(page, monkeypatch, qapp):
    """M3."""
    page._monitor = recorded_snapshot(monkeypatch)
    ran = []
    monkeypatch.setattr(mc, "run_domain_action",
                        lambda *a, **k: ran.append(a) or mc.DomainResult(True, "ran"))
    gate, t = _park(page, "_scale_worker", qapp)
    try:
        page._domain_action("acme.example", "stop")
        assert page.monitor.scale_status_text().startswith(
            "Not run: a Replicas change is still running")
        assert not probe_running(page, "_domain_worker")
    finally:
        _release(gate, t, qapp)
    assert ran == []


def test_page_re_reads_after_a_domain_stop_but_not_after_logs(page, monkeypatch, qapp):
    """M5: a Stop/Start/Restart re-reads the lanes; Logs shows text and does not."""
    page._monitor = recorded_snapshot(monkeypatch)
    monkeypatch.setattr(mc, "run_domain_action",
                        lambda g, n, u, d, v, **k: mc.DomainResult(
                            True, f"{v} {d}: done", "── c ──\nx", domain=d, verb=v))
    reasons = []
    monkeypatch.setattr(page, "_refresh_monitor", lambda reason="": reasons.append(reason))
    page._domain_action("acme.example", "logs")
    assert _wait(qapp, lambda: not probe_running(page, "_domain_worker"))
    _wait(qapp, lambda: page.monitor.logs_box.isVisibleTo(page.monitor), 2)
    assert "post-domain-action" not in reasons
    page._domain_action("acme.example", "stop")
    assert _wait(qapp, lambda: "post-domain-action" in reasons)


def test_page_verb_is_refused_while_a_domain_action_runs(page, monkeypatch, qapp):
    """M6: Start/Stop/Seed of the whole mesh must wait for a domain's action."""
    ran = []
    gate, t = _park(page, "_domain_worker", qapp)
    try:
        page._launch("Starting the mesh", lambda: ran.append("verb") or (0, ""))
        assert page.status.text().startswith(
            "Still running: a domain's Start/Stop/Restart")
        assert not page._running
    finally:
        _release(gate, t, qapp)
    assert ran == []


def test_page_scale_is_refused_while_a_domain_action_runs(page, monkeypatch, qapp):
    """M7."""
    snap = recorded_snapshot(monkeypatch)
    page._monitor = snap
    page.monitor.render(snap)
    key = next(u.key for u in snap.units if u.lane == "compose")
    started = []
    monkeypatch.setattr(localmesh_mod, "MeshScaleWorker",
                        lambda *a, **k: started.append(a) or (_ for _ in ()).throw(
                            AssertionError("a scale must not start")))
    gate, t = _park(page, "_domain_worker", qapp)
    try:
        page._scale_monitor(key, 2)
        assert page.monitor.scale_status_text().startswith(
            "Not scaled: a domain's Start/Stop/Restart is still running")
        assert not probe_running(page, "_scale_worker")
    finally:
        _release(gate, t, qapp)
    assert started == []


# ── the emulation pages' mount gets the same domain names ────────────────────────

def test_section_hands_its_hints_to_every_read(qapp, monkeypatch):
    seen = []
    monkeypatch.setattr(mm, "snapshot", lambda gen, node, **kw: seen.append(
        kw.get("hints")) or mm.MonitorSnapshot("t", mm.LaneState(False),
                                               mm.LaneState(False)))
    host = QtWidgets.QWidget()
    want = mm.DomainHints(names={"acme-example": "acme.example"})
    sec = mw.MeshMonitorSection(host, GENERATOR_DIR, lambda: _Node("[]"),
                                hints_fn=lambda: want)
    try:
        assert sec.refresh("button")
        assert _wait(qapp, lambda: bool(seen))
        assert seen[0] is want
        # a hints function that raises is a read without hints, never a crash
        sec._hints_fn = lambda: 1 / 0
        _wait(qapp, lambda: not probe_running(sec, "_probe"), 3)
        assert sec.refresh("button")
        assert _wait(qapp, lambda: len(seen) == 2)
        assert seen[1] is None
    finally:
        sec.shutdown()
        host.deleteLater()
        qapp.processEvents()


def test_emulation_hints_name_the_wizards_domains_and_follow_the_local_mesh():
    from hugmesh_studio.core.config import Domain
    from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
    wiz = SimpleNamespace(cfg=SimpleNamespace(
        domains=[Domain(name="acme.example"), {"name": "shop.example"}]))
    h = mw.emulation_hints(wiz)
    assert h.names == {"acme-example": "acme.example", "shop-example": "shop.example"}
    assert h.service_domains == {}
    local = LocalMeshBootstrapConfig(
        domains=({"name": "team.example", "optional_services": ["tuwunel"]},))
    wiz.localmesh_page = SimpleNamespace(boot=SimpleNamespace(cfg=local))
    h = mw.emulation_hints(wiz)
    assert h.service_domains == {"tuwunel": ("team.example",)}
    assert h.names["team-example"] == "team.example"
    assert h.names["acme-example"] == "acme.example"
    assert mw.emulation_hints(SimpleNamespace()) == mm.DomainHints()
