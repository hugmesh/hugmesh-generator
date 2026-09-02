"""The running-mesh monitor on the local-mesh page (GUI boundary).

Pins the operator's interpretation flags and the page's discipline:
  * collapsed by default; greyed + empty when NEITHER lane runs; enabled + populated
    when EITHER runs — kind alone counts (the two-lane bug, ``_mesh_up`` is compose-only);
  * unknown renders as "checking", never as "no mesh";
  * entering the page starts NO monitor probe; the probe runs off the GUI thread; a
    refresh is re-entrant-safe; the 10 s timer runs only while expanded and is stopped
    by the EXISTING hideEvent without losing the egress-conf enforcement;
  * every verb's end refreshes the table;
  * Open buttons call QDesktopServices.openUrl with the door URL, blocked rows carry the
    reason, a row that loses its door loses its button, a repaint keeps the selection,
    a failed read clears the rows, and NO row ever offers a localhost:8443 URL.

``mesh_monitor.snapshot`` is monkeypatched at the module seam; nothing here shells
docker or kubectl, and no browser is ever opened.
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
from hugmesh_studio.core import mesh_monitor as mm                       # noqa: E402
from hugmesh_studio.core.mesh_node import MeshNode, MeshStatus           # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod          # noqa: E402
from hugmesh_studio.gui.pages import _mesh_monitor_widget as mw          # noqa: E402
from hugmesh_studio.gui.qt import QtGui, QtWidgets                       # noqa: E402

#: This module exercises the REAL snapshot (tests/conftest.py makes it inert for
#: every other suite).
pytestmark = pytest.mark.real_mesh_monitor

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

_PROBE_ATTRS = ("_probe", "_node_probe", "_e2e_probe", "_monitor_probe")


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


# ── canned snapshots ────────────────────────────────────────────────────────────────

def _unit(ns, name, *, lane="kind", phase="Running 1/1", ready=True, state="ok",
          cluster_path="", external="", door=None, reason=""):
    return mm.MeshUnit(lane=lane, namespace=ns, name=name, owner="rs", phase=phase,
                       ready=ready, reason=reason, state=state, cluster_path=cluster_path,
                       external=external, door=door or mm.Door(blocked="no door"),
                       detail="detail")


def snap_none():
    return mm.MonitorSnapshot(taken_at="10:00:00",
                              compose=mm.LaneState(False, "not started"),
                              kind=mm.LaneState(False, "no kind cluster named hugmesh-local"))


def snap_kind(*, door_url="https://127.0.0.1:9080/", phase_suffix=""):
    fe = _unit("hugmesh-frontend", "fe-gateway-1", phase="Init:0/1" + phase_suffix,
               ready=False, state="queued",
               cluster_path="http://hugmesh-fe-gateway.hugmesh-frontend.svc.cluster.local:8080",
               external="hugmesh.net/ (ingress)",
               door=(mm.Door(label="Open", url=door_url, via="view") if door_url
                     else mm.Door(blocked=mm.HSTS_REASON)))
    cas = _unit("hugmesh-pki", "casdoor-1", phase="Running 1/1" + phase_suffix,
                ready=False, state="running", reason="selected but not ready",
                cluster_path="http://casdoor.hugmesh-pki.svc.cluster.local:8000",
                door=mm.Door(blocked="ClusterIP only — kubectl --context kind-hugmesh-local "
                                     "port-forward -n hugmesh-pki svc/casdoor :8000"))
    etcd = _unit("kube-system", "etcd-1", phase="Running 1/1" + phase_suffix)
    return mm.MonitorSnapshot(taken_at="10:00:01",
                              compose=mm.LaneState(False, "not started"),
                              kind=mm.LaneState(True, "cluster hugmesh-local · 3 pod(s)"),
                              units=(fe, cas, etcd))


def snap_compose():
    fe = _unit("hugmesh-local", "hugmesh-local-fe-1", lane="compose",
               phase="running (healthy)", cluster_path="hugmesh-fe-gateway:8080",
               external="0.0.0.0:8488->8443",
               door=mm.Door(label="Open", url="https://localhost:8488", via="compose"))
    return mm.MonitorSnapshot(taken_at="10:00:02",
                              compose=mm.LaneState(True, "41 container(s)"),
                              kind=mm.LaneState(False, "no kind cluster"),
                              units=(fe,))


def snap_unknown():
    return mm.MonitorSnapshot(taken_at="10:00:03",
                              compose=mm.LaneState(None, error="docker is not installed"),
                              kind=mm.LaneState(None, error="kubectl is not installed"),
                              errors=("kind: kubectl is not installed — press 'Install "
                                      "DevOps prerequisites'",
                                      "compose: docker is not installed"))


# ── fixtures ────────────────────────────────────────────────────────────────────────

class _Stack:
    """A LocalStackNode stand-in: compose status scripted, e2e gate quiet."""
    web_url = "https://localhost:8488"
    plain_web_url = "http://localhost:8088"

    def __init__(self):
        self.running = False
        self.gate = threading.Event()
        self.gate.set()

    def status(self):
        self.gate.wait(10)
        return SimpleNamespace(running=self.running,
                               detail="41 container(s)" if self.running else "not started")

    def e2e_ready(self, environment="docker"):
        return ["the local stack is not running — bring it up first."]


class _Fake:
    """The seamed mesh_monitor.snapshot: answers from a queue, records threads."""

    def __init__(self, first):
        self.answers = [first]
        self.calls = 0
        self.threads: list[int] = []
        self.gate = threading.Event()
        self.gate.set()

    def __call__(self, generator_dir, node, **kw):
        self.calls += 1
        self.threads.append(threading.get_ident())
        self.gate.wait(10)
        return self.answers[-1] if len(self.answers) == 1 else self.answers.pop(0)


@pytest.fixture
def stack(monkeypatch):
    st = _Stack()
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "_stack_node", lambda self: st)
    monkeypatch.setattr(MeshNode, "status",
                        lambda self: MeshStatus(running=False, detail="not started"))
    return st


@pytest.fixture
def fake(monkeypatch):
    f = _Fake(snap_none())
    monkeypatch.setattr(localmesh_mod.mesh_monitor, "snapshot", f)
    return f


@pytest.fixture
def page(qapp, stack, fake):
    p = localmesh_mod.LocalMeshPage(
        SimpleNamespace(generator_dir=GENERATOR_DIR, cfg=SimpleNamespace(),
                        localmesh_selected=True))
    yield p
    stack.gate.set()
    fake.gate.set()
    p._monitor_timer.stop()
    for name in _PROBE_ATTRS:
        t = getattr(p, name, None)
        if t is not None:
            try:
                t.wait(5000)
            except RuntimeError:
                pass
    w = getattr(p, "worker", None)
    if w is not None:
        try:
            w.wait(5000)
        except RuntimeError:
            pass
    qapp.processEvents()
    p.deleteLater()
    qapp.processEvents()


def _settle(qapp, page, timeout_s=8.0):
    deadline = time.monotonic() + timeout_s
    idle = 0
    while time.monotonic() < deadline and idle < 20:
        for n in _PROBE_ATTRS:
            t = getattr(page, n, None)
            if t is not None:
                try:
                    t.wait(200)
                except RuntimeError:
                    pass
        qapp.processEvents()
        busy = any(localmesh_mod.probe_running(page, n) for n in _PROBE_ATTRS)
        idle = 0 if busy else idle + 1
        time.sleep(0.005)
    qapp.processEvents()


def _wait(qapp, pred, timeout_s=8.0):
    deadline = time.monotonic() + timeout_s
    while not pred() and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.01)
    qapp.processEvents()
    return pred()


def _open_col():
    return mw._MON_COL_OPEN


# ── tests ───────────────────────────────────────────────────────────────────────────

def test_monitor_section_is_collapsed_by_default(page):
    assert page.monitor_section.is_expanded() is False
    assert page.monitor.isHidden(), "the content is folded away, not merely disabled"
    assert not page._monitor_timer.isActive()
    # the section sits on the bootstrap tab, after the Actions box
    assert page.monitor_section.parentWidget() is not None


def test_monitor_is_disabled_and_empty_when_nothing_runs(qapp, page, fake):
    page.initializePage()
    _settle(qapp, page)
    assert fake.calls == 1, "one snapshot rides the mesh-state answer"
    assert page.monitor.isEnabled() is False
    assert page.monitor.table.rowCount() == 0
    assert page.monitor.toolTip(), "a disabled cluster carries its reason"
    assert "No mesh is running" in page.monitor.note.text()
    assert "nothing running" in page.monitor_section.toggle.text()


def test_monitor_is_enabled_and_populated_when_a_lane_runs(qapp, page, fake, stack):
    stack.running = True
    fake.answers = [snap_compose()]
    page.initializePage()
    _settle(qapp, page)
    assert page._mesh_up is True
    assert page.monitor.isEnabled()
    t = page.monitor.table
    assert t.rowCount() == 1
    assert t.item(0, mw._MON_COL_NAME).text() == "hugmesh-local/hugmesh-local-fe-1"
    assert t.item(0, mw._MON_COL_LANE).text() == "compose"
    assert "running (healthy)" in t.item(0, mw._MON_COL_STATE).text()
    assert t.item(0, mw._MON_COL_K8S).text() == "hugmesh-fe-gateway:8080"
    assert t.item(0, mw._MON_COL_EXT).text() == "0.0.0.0:8488->8443"
    assert isinstance(t.cellWidget(0, _open_col()), QtWidgets.QPushButton)
    assert "1/1 ready" in page.monitor.note.text()
    assert "compose up" in page.monitor.note.text() and "kind down" in page.monitor.note.text()


def test_kind_running_alone_does_not_grey_the_monitor(qapp, page, fake, stack):
    """THE two-lane bug: compose is down, kind is up with pods. The compose-only
    ``_mesh_up`` says False; the monitor must still be enabled and populated."""
    stack.running = False
    fake.answers = [snap_kind()]
    page.initializePage()
    _settle(qapp, page)
    assert page._mesh_up is False
    assert page.monitor.isEnabled() is True
    assert page.monitor.table.rowCount() == 3
    assert "3" in page.monitor_section.toggle.text()
    # the boot-down gate still follows compose (nothing to `stack-halt`) — unchanged
    assert not page.boot_down_btn.isEnabled()


def test_unknown_state_says_checking_not_no_mesh(qapp, page, fake, stack):
    stack.gate.clear()                     # park the mesh-state probe
    page.initializePage()
    assert page._mesh_up is None and page._monitor is None
    assert "Checking" in page.monitor.note.text()
    assert "No mesh" not in page.monitor.note.text()
    assert not page.monitor.isEnabled()
    assert "checking" in page.monitor_section.toggle.text()
    # a read that could establish NEITHER lane is not "no mesh" either
    fake.answers = [snap_unknown()]
    stack.gate.set()
    _settle(qapp, page)
    assert page._monitor is not None and page._monitor.any_unknown
    note = page.monitor.note.text()
    assert "No mesh is running" not in note
    assert "Could not read" in note and "kubectl is not installed" in note
    assert not page.monitor.isEnabled() and page.monitor.table.rowCount() == 0


def test_probe_runs_off_the_gui_thread(qapp, page, fake):
    page.initializePage()
    _settle(qapp, page)
    assert fake.threads and threading.get_ident() not in fake.threads


def test_entering_the_page_starts_no_monitor_probe(qapp, page, fake, stack):
    stack.gate.clear()
    t0 = time.monotonic()
    page.initializePage()
    assert time.monotonic() - t0 < 0.5
    assert getattr(page, "_monitor_probe", None) is None, \
        "initializePage must not start the monitor probe — it rides _on_mesh_state"
    assert fake.calls == 0
    stack.gate.set()
    _settle(qapp, page)
    assert fake.calls == 1


def test_expanding_starts_the_timer_and_collapsing_stops_it(qapp, page, fake):
    page.initializePage()
    _settle(qapp, page)
    before = fake.calls
    page.monitor_section.set_expanded(True)
    assert page._monitor_timer.isActive()
    assert page._monitor_timer.interval() == 10_000
    _settle(qapp, page)
    assert fake.calls == before + 1, "expanding refreshes once"
    page.monitor_section.set_expanded(False)
    assert not page._monitor_timer.isActive()
    # a tick while collapsed (or while the page is not visible) reads nothing
    page._on_monitor_tick()
    _settle(qapp, page)
    assert fake.calls == before + 1


def test_hide_event_stops_the_timer_and_still_enforces_the_egress_conf(qapp, page,
                                                                       monkeypatch):
    page.monitor_section.set_expanded(True)
    assert page._monitor_timer.isActive()
    seen = []
    monkeypatch.setattr(page, "_enforce_egress_conf", lambda: seen.append(True))
    page.hideEvent(QtGui.QHideEvent())
    assert not page._monitor_timer.isActive()
    assert seen == [True], "the existing hideEvent body must survive the extension"


def test_refresh_is_reentrant_safe(qapp, page, fake):
    page.initializePage()
    _settle(qapp, page)
    fake.gate.clear()
    page._refresh_monitor("button")
    first = page._monitor_probe
    page._refresh_monitor("button")
    page.monitor.refresh_btn.click()
    assert page._monitor_probe is first
    fake.gate.set()
    _settle(qapp, page)
    assert fake.calls == 2                 # the entry read + exactly one more


def test_verb_done_refreshes_the_monitor(qapp, page, fake, stack):
    page.initializePage()
    _settle(qapp, page)
    assert fake.calls == 1
    # a verb ends -> _verb_done -> one monitor refresh, collapsed or not
    fake.answers = [snap_kind()]
    page._launch("Doing nothing", lambda: (True, ["ok"]))
    assert "Paused" in page.monitor.note.text() or not page.monitor.isEnabled()
    assert _wait(qapp, lambda: not page._running)
    _settle(qapp, page)
    assert fake.calls >= 2
    assert page.monitor.table.rowCount() == 3
    assert page.monitor.isEnabled()


def test_open_button_calls_openurl_with_the_door_url(qapp, page, fake, monkeypatch):
    fake.answers = [snap_kind()]
    page.initializePage()
    _settle(qapp, page)
    opened = []
    monkeypatch.setattr(localmesh_mod.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: opened.append(url.toString()) or True))
    btn = page.monitor.button_for("kind/hugmesh-frontend/fe-gateway-1")
    assert isinstance(btn, QtWidgets.QPushButton)
    btn.click()
    assert opened == ["https://127.0.0.1:9080/"]


def test_open_button_is_disabled_with_a_reason_when_there_is_no_safe_door(qapp, page, fake):
    fake.answers = [snap_kind()]
    page.initializePage()
    _settle(qapp, page)
    r = page.monitor.row_of("kind/hugmesh-pki/casdoor-1")
    assert r >= 0
    assert page.monitor.table.cellWidget(r, _open_col()) is None
    item = page.monitor.table.item(r, _open_col())
    assert item.text() == "—"
    assert "port-forward -n hugmesh-pki svc/casdoor :8000" in item.toolTip()


def test_row_that_loses_its_door_loses_its_button(qapp, page, fake):
    fake.answers = [snap_kind()]
    page.initializePage()
    _settle(qapp, page)
    key = "kind/hugmesh-frontend/fe-gateway-1"
    r = page.monitor.row_of(key)
    assert isinstance(page.monitor.table.cellWidget(r, _open_col()), QtWidgets.QPushButton)
    assert page.monitor.table.item(r, _open_col()) is None, "widget XOR item"
    # the view session dies: same rows, no door
    page._on_monitor(snap_kind(door_url=""))
    assert page.monitor.row_of(key) == r
    assert page.monitor.table.cellWidget(r, _open_col()) is None
    item = page.monitor.table.item(r, _open_col())
    assert item is not None and item.text() == "—" and "HSTS" in item.toolTip()
    assert page.monitor.button_for(key) is None
    # …and it comes back: item out, widget in
    page._on_monitor(snap_kind())
    assert isinstance(page.monitor.table.cellWidget(r, _open_col()), QtWidgets.QPushButton)
    assert page.monitor.table.item(r, _open_col()) is None


def test_repaint_preserves_the_selected_row(qapp, page, fake):
    fake.answers = [snap_kind()]
    page.initializePage()
    _settle(qapp, page)
    t = page.monitor.table
    t.selectRow(1)
    key = page.monitor.row_key(1)
    item_before = t.item(1, mw._MON_COL_STATE)
    page._on_monitor(snap_kind(phase_suffix=" (t+10s)"))
    rows = t.selectionModel().selectedRows()
    assert len(rows) == 1 and rows[0].row() == 1
    assert page.monitor.row_key(1) == key
    assert t.item(1, mw._MON_COL_STATE) is item_before, "set_cell reuses the item"
    assert "(t+10s)" in t.item(1, mw._MON_COL_STATE).text()


def test_failed_read_clears_the_rows_and_says_so(qapp, page, fake):
    fake.answers = [snap_kind()]
    page.initializePage()
    _settle(qapp, page)
    assert page.monitor.table.rowCount() == 3
    page._on_monitor(snap_unknown())
    assert page.monitor.table.rowCount() == 0
    assert not page.monitor.isEnabled()
    assert "docker is not installed" in page.monitor.note.text()
    assert "could not read" in page.monitor_section.toggle.text()


def test_no_row_offers_a_localhost_8443_url(qapp, page, fake, monkeypatch):
    """THE HSTS GUARD at the GUI boundary: even a snapshot that (wrongly) carries a
    pinnable URL must not put it behind a button, and _open_door refuses it too."""
    bad = snap_kind(door_url="https://localhost:8443/")
    page._on_monitor(bad)
    assert page.monitor.door_urls() == []
    r = page.monitor.row_of("kind/hugmesh-frontend/fe-gateway-1")
    assert page.monitor.table.cellWidget(r, _open_col()) is None
    assert "HSTS" in page.monitor.table.item(r, _open_col()).toolTip()
    opened = []
    monkeypatch.setattr(localmesh_mod.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: opened.append(url.toString()) or True))
    page._open_door("https://hugmesh.net:8443/")
    page._open_door("https://localhost:8443/")
    assert opened == [] and "Not opened" in page.status.text()
    page._open_door("https://127.0.0.1:9080/")
    assert opened == ["https://127.0.0.1:9080/"]
    # and over every canned snapshot, no button carries a name or the kind port
    for snap in (snap_kind(), snap_compose()):
        page._on_monitor(snap)
        for url in page.monitor.door_urls():
            assert mm.unsafe_door_reason(url) == "", url
            assert ":8443" not in url


def test_open_web_tooltip_matches_the_live_front_door(qapp, page, fake, stack):
    page.initializePage()
    _settle(qapp, page)
    tip = page.open_web_btn.toolTip()
    assert stack.web_url in tip and stack.plain_web_url in tip
    assert tip.index(stack.web_url) < tip.index(stack.plain_web_url), \
        "the TLS door the button opens is named first"
    assert "front door (https://localhost:8488)" in tip


def test_view_buttons_are_never_both_armed(qapp, page, fake):
    fake.answers = [snap_kind()]
    page.initializePage()
    _settle(qapp, page)
    assert page.monitor.view_up_btn.isEnabled() and not page.monitor.view_down_btn.isEnabled()
    live = mm.MonitorSnapshot(taken_at="x", compose=snap_kind().compose,
                              kind=snap_kind().kind, units=snap_kind().units,
                              view_doors=("app",))
    page._on_monitor(live)
    assert not page.monitor.view_up_btn.isEnabled() and page.monitor.view_down_btn.isEnabled()


def test_view_up_runs_make_view_through_launch_never_directly(qapp, page, fake, stack,
                                                              monkeypatch):
    fake.answers = [snap_kind()]
    page.initializePage()
    _settle(qapp, page)
    launched = []
    monkeypatch.setattr(page, "_launch",
                        lambda label, fn, **kw: launched.append((label, kw)))
    page.monitor.view_up_btn.click()
    assert launched and launched[0][0] == "Opening the browser door"
    assert launched[0][1].get("stream") is True and launched[0][1].get("cancellable") is True
    page.monitor.view_down_btn.setEnabled(True)
    page.monitor.view_down_btn.click()
    assert launched[1][0] == "Stopping the browser door"


def test_verb_done_with_a_silenced_status_probe_starts_no_monitor_read(qapp, page, fake):
    """Two suites (save-notice and run-log attribution) silence _probe_mesh_state to
    a no-op to keep a page QUIET while they drive verbs. The monitor's verb-end read
    rides that same seam: a silenced state probe means no monitor read and no stray
    thread — the flag is simply remembered for the next state answer."""
    page._probe_mesh_state = lambda: None
    page._launch("Doing nothing", lambda: (True, ["ok"]))
    assert _wait(qapp, lambda: not page._running)
    _settle(qapp, page)
    assert fake.calls == 0
    assert getattr(page, "_monitor_probe", None) is None
    assert page._monitor_stale is True


def test_a_read_in_flight_at_verb_end_is_followed_by_a_fresh_one(qapp, page, fake, stack):
    """A read parked when the verb ends may predate the verb's effect: the state
    answer cannot start another (re-entrancy), so the flag survives until the
    parked read finishes and exactly ONE fresh read follows it."""
    page.initializePage()
    _settle(qapp, page)
    assert fake.calls == 1
    fake.gate.clear()
    assert page._refresh_monitor("button") is True
    assert localmesh_mod.probe_running(page, "_monitor_probe")
    page._launch("Doing nothing", lambda: (True, ["ok"]))
    assert _wait(qapp, lambda: not page._running)
    assert _wait(qapp, lambda: not localmesh_mod.probe_running(page, "_probe"))
    qapp.processEvents()
    assert page._monitor_stale is True, "the in-flight read could not be restarted"
    fake.answers = [snap_kind()]
    fake.gate.set()
    _settle(qapp, page)
    assert fake.calls == 3, "entry + the parked read + exactly one follow-up"
    assert page._monitor_stale is False
    assert page.monitor.table.rowCount() == 3


def test_unknown_without_error_text_is_not_reported_as_no_mesh(qapp, page, fake):
    """I5 inside the gate itself: a read that established NEITHER lane, even one
    that carried no error sentence, is 'could not read', never 'No mesh'."""
    both_none = mm.MonitorSnapshot(
        taken_at="x", compose=mm.LaneState(None, detail="not asked"),
        kind=mm.LaneState(None, detail="not asked"))
    page._on_monitor(both_none)
    note = page.monitor.note.text()
    assert "No mesh is running" not in note
    assert "Could not read" in note and "not asked" in note
    assert not page.monitor.isEnabled() and page.monitor.table.rowCount() == 0
    assert "could not read" in page.monitor_section.toggle.text()
