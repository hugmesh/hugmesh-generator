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

``mesh_monitor.snapshot`` is monkeypatched at the module override point; nothing here shells
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
from hugmesh_studio.gui.pages import _emulation_common as common_mod     # noqa: E402
from hugmesh_studio.gui.qt import QtGui, QtWidgets                       # noqa: E402

#: This module exercises the REAL snapshot (tests/conftest.py makes it do nothing for
#: every other suite).
pytestmark = pytest.mark.real_mesh_monitor

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# ``_scale_worker`` is the page's Replicas worker (issue #341) — a QThread the page owns
# only after an Apply, so a fixture that waited on the probes alone would drop a page
# mid-scale and take the interpreter with it.
_PROBE_ATTRS = ("_probe", "_node_probe", "_e2e_probe", "_monitor_probe", "_scale_worker")


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
    rides that same override point: a silenced state probe means no monitor read and no stray
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


def test_a_verb_time_refresh_never_leaves_the_previous_reads_rows(qapp, page, fake,
                                                                  stack):
    """The paused branch quotes a snapshot in its note and its title, so the TABLE
    must come from that same read. The widget's own Refresh stays live while a verb
    runs (_set_verbs_enabled does not reach it), so this is one click away: rows
    showing green ticks under a note that says the mesh is down is exactly the
    stale-as-current failure the monitor exists to fix."""
    stack.running = True
    fake.answers = [snap_compose()]
    page.initializePage()
    _settle(qapp, page)
    assert page.monitor.table.rowCount() == 1
    page._running = True
    page._running_label = "Stopping the mesh"
    page._sync_monitor_gate()
    assert page.monitor.refresh_btn.isEnabled(), "the premise: Refresh is still live"
    fake.answers = [snap_none()]                    # the mesh went away
    page._refresh_monitor("button")
    _settle(qapp, page)
    assert "compose down" in page.monitor.note.text()
    assert "paused" in page.monitor_section.toggle.text()
    assert page.monitor.table.rowCount() == 0, (
        "the paused note quoted a nothing-running read while the table still showed "
        "the previous read's rows")


def test_a_verb_time_refresh_repaints_rows_that_are_still_there(qapp, page, fake,
                                                                stack):
    """The other half of the same branch: pausing must not blank a live mesh."""
    stack.running = True
    fake.answers = [snap_compose()]
    page.initializePage()
    _settle(qapp, page)
    page._running = True
    page._running_label = "Running the e2e suite"
    fake.answers = [snap_kind()]
    page._refresh_monitor("button")
    _settle(qapp, page)
    assert page.monitor.isEnabled()
    assert page.monitor.table.rowCount() == 3, "a paused read that still sees a mesh"


def test_show_event_restarts_the_poll_when_the_section_was_left_open(qapp, page, fake):
    """hideEvent stops the 10 s poll, but the FOLD STATE survives the visit — so
    leaving and re-entering the page (LocalMeshPage is wizard page 4 of 27; Next/Back
    is ordinary navigation) must not leave an expanded, visible table frozen while
    its own tooltip still promises a 10 s refresh."""
    page.monitor_section.set_expanded(True)
    _settle(qapp, page)
    assert page._monitor_timer.isActive()
    page.hideEvent(QtGui.QHideEvent())
    assert not page._monitor_timer.isActive()
    page.showEvent(QtGui.QShowEvent())
    assert page.monitor_section.is_expanded()
    assert page._monitor_timer.isActive(), (
        "the section is still open, so the poll the tooltip promises must be back")


def test_show_event_leaves_a_folded_section_unpolled(qapp, page, fake):
    """The restart is conditional: a folded section costs no ticks."""
    assert not page.monitor_section.is_expanded()
    page.showEvent(QtGui.QShowEvent())
    assert not page._monitor_timer.isActive()


def test_a_folded_nothing_running_title_is_re_derived_on_re_entry(qapp, page, fake,
                                                                  stack):
    """`running` in _on_mesh_state is the COMPOSE-only answer, so it cannot speak for
    a kind cluster that came up behind a folded section — the two-lane case this
    feature exists for. A title still saying 'nothing running' must always re-read."""
    page.initializePage()
    _settle(qapp, page)
    assert "nothing running" in page.monitor_section.toggle.text()
    first = fake.calls
    fake.answers = [snap_kind()]                    # kind up, compose still down
    page.initializePage()
    _settle(qapp, page)
    assert fake.calls == first + 1, "a folded 'nothing running' title never re-read"
    assert "nothing running" not in page.monitor_section.toggle.text()
    assert "1/3 ready" in page.monitor_section.toggle.text()


def test_a_folded_title_that_already_names_a_mesh_costs_no_extra_read(qapp, page, fake,
                                                                      stack):
    """The re-derive above must not become an unconditional probe on every entry."""
    fake.answers = [snap_kind()]
    page.initializePage()
    _settle(qapp, page)
    assert "1/3 ready" in page.monitor_section.toggle.text()
    first = fake.calls
    page.initializePage()
    _settle(qapp, page)
    assert fake.calls == first, "a folded title that already names a mesh re-read"


def test_both_view_tooltips_follow_the_session_state(qapp, page, fake):
    """set_view_session used to write ONE tooltip per branch, so after the first flip
    the ENABLED button carried the other state's sentence — a live 'Stop the browser
    door' reading 'No `make view` session is running.'"""
    w = page.monitor
    w.set_view_session(True)
    assert "already serving" in w.view_up_btn.toolTip()
    assert "No `make view` session is running" not in w.view_down_btn.toolTip()
    assert "view-stop" in w.view_down_btn.toolTip()
    w.set_view_session(False)
    assert "already serving" not in w.view_up_btn.toolTip()
    assert "make view-trust" in w.view_up_btn.toolTip()
    assert w.view_down_btn.toolTip() == "No `make view` session is running."


def test_a_folded_title_that_names_a_mesh_re_reads_when_compose_goes_down(qapp, page,
                                                                        fake, stack):
    """The converse of the two tests above, and the one an operator actually hits:
    the compose mesh was read UP behind a folded section, then a terminal
    `make stack-halt` (or a crash) took it down. The next mesh-state answer says
    "not running" — the folded title, its rows and its Open buttons must not go on
    saying "1/1 ready" under a page whose own mesh-state line says the opposite.
    Showing stale rows as current is the failure this monitor exists to fix."""
    stack.running = True
    fake.answers = [snap_compose()]
    page.initializePage()
    _settle(qapp, page)
    assert "1/1 ready" in page.monitor_section.toggle.text()
    assert page.monitor.isEnabled() and page.monitor.table.rowCount() == 1
    assert len(page.monitor.door_urls()) == 1
    assert not page.monitor_section.is_expanded()
    stack.running = False                     # stopped OUTSIDE the Studio
    fake.answers = [snap_none()]
    first = fake.calls
    page.initializePage()                     # the operator comes back to the page
    _settle(qapp, page)
    assert "not running" in page._mesh_state_label.text()
    assert fake.calls == first + 1, \
        "a folded title naming a mesh never re-read after compose went down"
    assert "nothing running" in page.monitor_section.toggle.text()
    assert not page.monitor.isEnabled()
    assert page.monitor.table.rowCount() == 0 and page.monitor.door_urls() == []


def test_the_live_view_tooltip_names_the_lane_the_session_serves(qapp, page, fake):
    """A kind-lane session left running after the cluster was deleted still holds
    the ports while the compose mesh runs beside it; "the Open buttons above use
    it" was then false for every row (compose rows open directly). The sentence
    names the lane and says which rows go through it."""
    w = page.monitor
    w.set_view_session(True, lane="kind")
    tip = w.view_up_btn.toolTip()
    assert "already serving the kind lane's doors" in tip
    assert "compose rows open their published ports directly" in tip
    assert "Stop the browser door" in tip
    assert "the Open buttons above use it" not in tip
    w.set_view_session(True)                  # lane unknown: still no false claim
    assert "already serving its lane's doors" in w.view_up_btn.toolTip()
    # isEnabledTo(w), not isEnabled(): with no mesh running the page greys the
    # WHOLE monitor widget, so every child reports disabled whatever this method
    # did. The claim under test is which of the two THIS method armed.
    assert not w.view_up_btn.isEnabledTo(w) and w.view_down_btn.isEnabledTo(w)


def test_the_snapshots_view_lane_reaches_the_tooltip(qapp, page, fake):
    """The lane rides the snapshot (read off-thread with the doors), never a
    session-file read on the GUI thread."""
    snap = mm.MonitorSnapshot(taken_at="10:00:04",
                              compose=mm.LaneState(True, "41 container(s)"),
                              kind=mm.LaneState(False, "no kind cluster"),
                              units=snap_compose().units,
                              view_doors=("app",), view_lane="kind")
    page._on_monitor(snap)
    assert "the kind lane's doors" in page.monitor.view_up_btn.toolTip()
    page._on_monitor(snap_compose())          # no session: the Open side is armed
    assert page.monitor.view_up_btn.isEnabled()
    assert "make view-trust" in page.monitor.view_up_btn.toolTip()


def test_view_up_with_no_snapshot_follows_the_pages_own_compose_answer(qapp, page, fake,
                                                                    stack, monkeypatch):
    """Footer button pressed before the first read answered: with only compose up,
    `make view LANE=kind` would bind a door to a cluster that does not exist."""
    launched, noted = [], []
    monkeypatch.setattr(page, "_launch",
                        lambda label, fn, **kw: launched.append(label))
    monkeypatch.setattr(page, "_note", lambda text: noted.append(text))
    page._monitor = None
    page._mesh_up = True
    page._view_up()
    assert launched == ["Opening the browser door"]
    assert noted and "LANE=compose" in noted[-1]
    page._mesh_up = False                     # nothing known to be up: kind, as before
    page._view_up()
    assert "LANE=kind" in noted[-1]


# ══════════════════════════════════════════════════════════════════════════════════
# SCALING (#336). The monitor stopped being read-only, and everything below is a
# guard for one of the rules that makes that safe. Written after a refutation ran a
# 13-mutation battery against the original branch and every mutation SURVIVED: the
# code was careful and nothing in the repo held it in place. Each test names the
# mutation it kills, so a future change that "simplifies" one of these knows what it
# is spending.
#
# WHY THE CORE-ONLY TESTS ARE IN THIS FILE. Their natural home is
# tests/test_mesh_monitor.py, which the #336 fan-out gave to no lane; this lane owns
# this file. They are pure-core (no Qt) and should move there once the fan-out closes.
# ══════════════════════════════════════════════════════════════════════════════════

def _scalable(ns, name, *, lane="kind", kind="deployment", ctrl="gw", state="ok",
              namespace_of_target=None):
    """A row whose Replicas control is armed, and the controller behind it."""
    return mm.MeshUnit(
        lane=lane, namespace=ns, name=name, owner="rs", phase="Running 1/1",
        ready=True, reason="", state=state, cluster_path="", external="",
        door=mm.Door(blocked="no door"), detail="d",
        scale=mm.ScaleTarget(kind, ctrl, namespace_of_target or ns, refused=""))


def _unscalable(ns, name, why, *, lane="kind"):
    return mm.MeshUnit(
        lane=lane, namespace=ns, name=name, owner="", phase="Running 1/1", ready=True,
        reason="", state="ok", cluster_path="", external="",
        door=mm.Door(blocked="no door"), detail="d",
        scale=mm.ScaleTarget(refused=why))


def _snap(*units, taken_at="11:00:00"):
    return mm.MonitorSnapshot(taken_at=taken_at,
                              compose=mm.LaneState(True, "1 container(s)"),
                              kind=mm.LaneState(True, "cluster hugmesh-local"),
                              units=tuple(units))


class _ScaleNode:
    """A stack node that records the argv a scale would run, and answers it."""
    compose_file = "/gen/tests/stack/compose.local.yaml"

    def __init__(self, rc=0, out="ok"):
        self.calls: list[tuple[list[str], int]] = []
        self.rc, self.out = rc, out

    def _probe(self, cmd, timeout=None):
        self.calls.append((list(cmd), timeout))
        return self.rc, self.out


# ── the compatibility contract with localmesh.py ───────────────────────────────────

def test_the_default_monitor_widget_is_still_the_six_column_table(qapp):
    """M1. The DEFAULT is the compatibility contract: any mount that says nothing gets
    the six-column table and no Replicas knob. ``localmesh.py`` now opts IN with an
    explicit ``scaling=True`` (issue #341) and wires ``scale_requested`` — pinned by
    ``test_the_pages_own_monitor_mounts_the_replicas_column_and_wires_it`` — so a
    default that flipped to True would hand every OTHER bare mount a seventh column
    whose Apply emits into nothing. This is the test that fails for it."""
    w = mw.MeshMonitorWidget()
    try:
        assert w.scaling is False
        assert w.table.columnCount() == len(mw._MON_HEADERS) == 7
        got = tuple(w.table.horizontalHeaderItem(c).text() for c in range(7))
        assert got == mw._MON_HEADERS
        assert "Replicas" not in got
        w.render(_snap(_scalable("hugmesh", "gw-1")))
        assert w.table.rowCount() == 1
        assert w.scale_cell("kind/hugmesh/gw-1") is None
        assert w.table.cellWidget(0, mw._MON_COL_SCALE) is None
    finally:
        w.deleteLater()
        qapp.processEvents()


def test_the_replicas_column_is_appended_so_no_existing_index_moved(qapp):
    """M1's other half: the Replicas column may only ever be LAST. (The Domain
    column, 2026-10-21, was inserted at 1 deliberately: every caller reads the
    indices through these names.)"""
    assert (mw._MON_COL_NAME, mw._MON_COL_DOMAIN, mw._MON_COL_LANE, mw._MON_COL_STATE,
            mw._MON_COL_K8S, mw._MON_COL_EXT, mw._MON_COL_OPEN,
            mw._MON_COL_SCALE) == (0, 1, 2, 3, 4, 5, 6, 7)
    assert mw._MON_HEADERS_SCALING == mw._MON_HEADERS + ("Replicas",)
    w = mw.MeshMonitorWidget(scaling=True)
    try:
        assert w.table.columnCount() == 8
        assert w.table.horizontalHeaderItem(mw._MON_COL_OPEN).text() == "Open"
        assert w.table.horizontalHeaderItem(mw._MON_COL_SCALE).text() == "Replicas"
        assert "kubectl" in w.table.horizontalHeaderItem(mw._MON_COL_SCALE).toolTip()
    finally:
        w.deleteLater()
        qapp.processEvents()


def test_a_scaling_table_with_nothing_connected_refuses_instead_of_doing_nothing(qapp):
    """The hazard behind M1, head-on. A bare ``MeshMonitorWidget(scaling=True)`` paints
    the column and arms the buttons, and its Apply emits into no receiver — this repo's
    named failure mode, a GUI knob that silently does nothing. It must say so."""
    w = mw.MeshMonitorWidget(scaling=True)
    try:
        w.render(_snap(_scalable("hugmesh", "gw-1")))
        cell = w.scale_cell("kind/hugmesh/gw-1")
        assert cell is not None
        cell.plus.click()
        assert cell.target == 2 and cell.apply.isEnabled()
        cell.apply.click()
        assert "not wired" in w.scale_status_text()
        assert "Nothing was run." in w.scale_status_text()
        # isVisibleTo(w), not isVisible(): the widget is never shown in this
        # test, so every child reports hidden whatever the method did.
        assert w.scale_status.isVisibleTo(w)
        # and once it IS wired, the same press emits
        seen = []
        w.scale_requested.connect(lambda k, n: seen.append((k, n)))
        cell.apply.click()
        assert seen == [("kind/hugmesh/gw-1", 2)]
    finally:
        w.deleteLater()
        qapp.processEvents()


# ── which object a press actually touches ──────────────────────────────────────────

def test_the_scale_target_is_the_deployment_never_the_replicaset():
    """M4. Scaling a ReplicaSet a Deployment owns is undone by the Deployment
    controller within seconds — a control that appears to work and silently reverts.
    The Deployment's name is the ReplicaSet's minus the pod-template-hash, and that
    hash is read off the POD rather than guessed at as "some trailing characters"."""
    pod = {"metadata": {"name": "gateway-6d4b7f9c8-abcde",
                        "labels": {"pod-template-hash": "6d4b7f9c8"},
                        "ownerReferences": [{"kind": "ReplicaSet",
                                             "name": "gateway-6d4b7f9c8"}]}}
    t = mm._pod_scale_target(pod, "hugmesh")
    assert (t.kind, t.name, t.namespace) == ("deployment", "gateway", "hugmesh")
    assert t.scalable and t.key == "deployment/hugmesh/gateway"

    # no hash to strip: refuse and SAY why, never scale the ReplicaSet directly
    nohash = {"metadata": {"name": "gateway-x",
                           "ownerReferences": [{"kind": "ReplicaSet",
                                                "name": "gateway-x"}]}}
    r = mm._pod_scale_target(nohash, "hugmesh")
    assert not r.scalable
    assert "undone by its controller" in r.refused


@pytest.mark.parametrize("kind,expect_kind,expect_in_refusal", [
    ("StatefulSet", "statefulset", ""),
    ("ReplicationController", "replicationcontroller", ""),
    ("DaemonSet", "", "one pod per node"),
    ("Job", "", "fixed when it is created"),
    ("CronJob", "", "no standing"),
    ("Node", "", "kubelet"),
    ("Frobnicator", "", "does not drive"),
])
def test_every_other_owner_is_answered_with_a_fact(kind, expect_kind,
                                                   expect_in_refusal):
    """M4's neighbours. A refusal here is a FACT about that controller, so a row that
    cannot be scaled explains itself rather than offering a control that reverts."""
    pod = {"metadata": {"name": "p-1",
                        "ownerReferences": [{"kind": kind, "name": "owner"}]}}
    t = mm._pod_scale_target(pod, "kube-system")
    if expect_kind:
        assert t.scalable and t.kind == expect_kind and t.name == "owner"
    else:
        assert not t.scalable and expect_in_refusal in t.refused


def test_a_bare_pod_is_refused():
    t = mm._pod_scale_target({"metadata": {"name": "p"}}, "default")
    assert not t.scalable and "bare pod" in t.refused


def test_replicas_now_does_not_count_finished_rows():
    """M5. A Succeeded pod and an exited compose one-shot are finished work, not
    running replicas. Counting them makes a "+1" from this table hand the lane a
    number it immediately undoes."""
    target = mm.ScaleTarget("deployment", "gw", "hugmesh", refused="")
    snap = _snap(_scalable("hugmesh", "gw-1"),
                 _scalable("hugmesh", "gw-2"),
                 _scalable("hugmesh", "gw-3", state="stopped"),
                 _scalable("hugmesh", "other-1", ctrl="other"),
                 _unscalable("kube-system", "etcd-1", "static pod"))
    assert mm.replicas_now(snap, target) == 2
    assert mm.replicas_now(snap.units, target) == 2      # bare sequence too
    assert mm.replicas_now(snap, mm.ScaleTarget()) == 0  # never-scalable counts nothing
    # a `completed` one-shot is finished work too (Decision 99 = A, #378)
    snap = _snap(_scalable("hugmesh", "gw-1"),
                 _scalable("hugmesh", "gw-job", state="completed"))
    assert mm.replicas_now(snap, target) == 1


# ── what the two lanes actually run ────────────────────────────────────────────────

def test_the_compose_scale_pins_the_project_and_does_not_recreate():
    """M7 and M11. Without ``-p hugmesh-local`` a scale can land in a second project
    that happens to share the compose file; without ``--no-recreate`` a plain ``up``
    RE-CREATES every listed container, i.e. restarts a healthy 54-service mesh to
    change one service's count. ``--no-deps`` keeps the blast radius to the service."""
    unit = _scalable("hugmesh-local", "hugmesh-local-fe-1", lane="compose",
                     kind="compose-service", ctrl="fe-gateway")
    argv, refused = mm.scale_argv(unit, 3, generator_dir="/gen", node=_ScaleNode())
    assert refused == ""
    assert argv[argv.index("-p") + 1] == "hugmesh-local"
    assert "--no-recreate" in argv and "--no-deps" in argv
    assert "up" in argv and "-d" in argv
    assert argv[argv.index("--scale") + 1] == "fe-gateway=3"
    assert argv[-1] == "fe-gateway"          # the ONE service `up` is allowed to touch
    assert "down" not in argv and "restart" not in argv


def test_a_compose_scale_with_no_compose_file_refuses_rather_than_guessing():
    unit = _scalable("hugmesh-local", "c-1", lane="compose", kind="compose-service",
                     ctrl="fe")

    class _NoFile:
        compose_file = ""
    argv, refused = mm.scale_argv(unit, 1, generator_dir="/gen", node=_NoFile())
    assert argv == [] and "guess which project" in refused


def test_the_kubectl_scale_names_the_kind_context_the_kind_and_the_namespace(monkeypatch):
    monkeypatch.setattr(mm.devops_tools, "which", lambda tool, d: "/usr/bin/" + tool)
    unit = _scalable("hugmesh", "gw-1", kind="deployment", ctrl="gateway")
    argv, refused = mm.scale_argv(unit, 3, generator_dir="/gen", node=_ScaleNode())
    assert refused == ""
    assert argv[:2] == ["/usr/bin/kubectl", "--context"]
    assert argv[2].startswith("kind-")
    assert "scale" in argv and "deployment/gateway" in argv
    assert argv[argv.index("-n") + 1] == "hugmesh"
    assert argv[-1] == "--replicas=3"
    # never the pod, never delete
    assert "gw-1" not in argv and "delete" not in argv


def test_the_ceiling_refuses_rather_than_asking_for_it():
    """M8. Raising MAX_REPLICAS to 100000 must not stay silent: the number is a
    fat-finger guard on a "+" one pixel from "Apply", so it stays small AND the
    refusal is what a press past it produces."""
    assert 1 < mm.MAX_REPLICAS <= 20, "this is a mis-click guard, not a lane's limit"
    unit = _scalable("hugmesh", "gw-1", ctrl="gateway")
    argv, refused = mm.scale_argv(unit, mm.MAX_REPLICAS + 1, generator_dir="/gen",
                                  node=_ScaleNode())
    assert argv == [] and str(mm.MAX_REPLICAS) in refused and "ceiling" in refused


def test_a_negative_or_nonsense_replica_count_is_refused():
    """M12. -1 through to `kubectl scale --replicas=-1` is an API error the operator
    reads as a broken button; on compose it is worse, because `up --scale svc=-1`
    fails after the flag has already been parsed."""
    unit = _scalable("hugmesh", "gw-1", ctrl="gateway")
    for bad in (-1, -100):
        argv, refused = mm.scale_argv(unit, bad, generator_dir="/gen",
                                      node=_ScaleNode())
        assert argv == [] and "cannot be negative" in refused
    argv, refused = mm.scale_argv(unit, "three", generator_dir="/gen",
                                  node=_ScaleNode())
    assert argv == [] and "not a replica count" in refused


def test_an_unscalable_row_is_refused_with_its_own_sentence():
    unit = _unscalable("kube-system", "etcd-1",
                       "a static pod, run directly by this node's kubelet")
    argv, refused = mm.scale_argv(unit, 2, generator_dir="/gen", node=_ScaleNode())
    assert argv == [] and "kubelet" in refused


def test_scale_never_raises_and_says_which_verb_ran(monkeypatch):
    monkeypatch.setattr(mm.devops_tools, "which", lambda tool, d: "/usr/bin/" + tool)
    unit = _scalable("hugmesh", "gw-1", ctrl="gateway")
    node = _ScaleNode(rc=0, out="deployment.apps/gateway scaled")
    ok, text = mm.scale("/gen", node, unit, 3)
    assert ok and "asked for 3 replica(s)" in text and "next refresh" in text
    assert node.calls and node.calls[0][1] == mm.SCALE_TIMEOUT_S

    class _Boom:
        compose_file = "/c.yaml"

        def _probe(self, cmd, timeout=None):
            raise OSError("docker daemon is not running")
    ok, text = mm.scale("/gen", _Boom(), unit, 3)          # folded, not raised
    assert ok is False and "failed" in text


def test_a_compose_scale_timeout_says_the_build_is_probably_still_running():
    """Every first-party service in the local compose file is `build:`-ed from
    ${STACK_SRC}, so `up --scale` on a service whose image is absent BUILDS it, which
    can far exceed SCALE_TIMEOUT_S. Left as a bare TimeoutExpired string that reads as
    a broken daemon."""
    unit = _scalable("hugmesh-local", "c-1", lane="compose", kind="compose-service",
                     ctrl="fe-gateway")
    node = _ScaleNode(rc=1, out="TimeoutExpired: timed out after 180s")
    ok, text = mm.scale("/gen", node, unit, 2)
    assert ok is False
    assert "BUILDING it" in text and "still running in the background" in text
    # the kind lane must NOT claim a build
    node2 = _ScaleNode(rc=1, out="TimeoutExpired: timed out")
    ok2, text2 = mm.scale("/gen", node2, _scalable("hugmesh", "gw-1", ctrl="gw"), 2)
    assert ok2 is False and "BUILDING" not in text2


# ── the ReplicaStrip's own arithmetic ──────────────────────────────────────────────

def test_the_replica_strip_clamps_to_the_floor_and_the_ceiling(qapp):
    """M13. Without the clamp, holding "−" walks the target negative (which every
    lane then refuses) and holding "+" walks it past a ceiling the tooltip promised."""
    strip = common_mod.ReplicaStrip("k", ceiling=3, what="deployment/gw")
    strip.paint(1)
    for _ in range(20):
        strip.bump(+1)
    assert strip.target == 3
    for _ in range(20):
        strip.bump(-1)
    assert strip.target == 0
    strip.paint(1)
    assert strip.count.text() == "1 → 0"
    assert not strip.minus.isEnabled()          # already at the floor
    assert strip.plus.isEnabled() and strip.apply.isEnabled()
    strip.bump(+1)
    strip.paint(1)
    assert strip.count.text() == "1"            # reality reached: a plain count
    assert not strip.apply.isEnabled()          # nothing to ask for


def test_a_busy_strip_arms_nothing(qapp):
    strip = common_mod.ReplicaStrip("k", ceiling=5)
    strip.bump(+2)
    strip.paint(0, busy=True)
    assert not any(b.isEnabled() for b in (strip.minus, strip.plus, strip.apply))
    strip.paint(0, busy=False)
    assert all(b.isEnabled() for b in (strip.minus, strip.plus, strip.apply))


def test_the_pending_target_survives_a_repaint_but_not_the_verb(qapp):
    strip = common_mod.ReplicaStrip("k", ceiling=5)
    # the MOUNT syncs target to reality (MeshMonitorWidget._paint_scale /
    # MeshEmulationPage._arm_replicas); paint() deliberately does not, so a target the
    # operator moved cannot be taken away by a repaint the strip does not control.
    strip.target = 1
    strip.paint(1)
    strip.bump(+2)
    assert strip.pending and strip.target == 3
    strip.paint(1)                              # a 10 s repaint mid-decision
    assert strip.target == 3 and strip.count.text() == "1 → 3"
    strip.clear_pending()
    assert not strip.pending


# ── the widget/item mutual exclusion, both directions ─────────────────────────────

def test_the_replicas_cell_never_holds_a_widget_and_a_dash_at_once(qapp):
    """M6. A row that GAINS a scalable controller across refreshes must lose its dash
    before the strip goes in, and one that LOSES it must lose the strip before the
    dash is written — otherwise a live −/+/Apply sits beside a stale "—"."""
    w = mw.MeshMonitorWidget(scaling=True)
    try:
        key = "kind/hugmesh/gw-1"
        w.render(_snap(_unscalable("hugmesh", "gw-1", "owned by DaemonSet/x")))
        assert w.table.cellWidget(0, mw._MON_COL_SCALE) is None
        item = w.table.item(0, mw._MON_COL_SCALE)
        assert item is not None and item.text() == "—"
        assert "DaemonSet" in item.toolTip()

        w.render(_snap(_scalable("hugmesh", "gw-1")))       # same key, now scalable
        assert w.table.cellWidget(0, mw._MON_COL_SCALE) is not None
        assert w.table.item(0, mw._MON_COL_SCALE) is None
        assert w.scale_cell(key) is not None

        w.render(_snap(_unscalable("hugmesh", "gw-1", "a bare pod")))  # and back
        assert w.table.cellWidget(0, mw._MON_COL_SCALE) is None
        assert w.table.item(0, mw._MON_COL_SCALE).text() == "—"
        assert w.scale_cell(key) is None
    finally:
        w.deleteLater()
        qapp.processEvents()


def test_a_repaint_does_not_eat_a_target_the_operator_is_still_choosing(qapp):
    w = mw.MeshMonitorWidget(scaling=True)
    try:
        key = "kind/hugmesh/gw-1"
        w.render(_snap(_scalable("hugmesh", "gw-1")))
        w.scale_cell(key).plus.click()
        w.scale_cell(key).plus.click()
        assert w.scale_target(key) == 3
        # a pod appears ABOVE it: rows are rebuilt and re-sorted
        w.render(_snap(_scalable("hugmesh", "gw-1"),
                       _unscalable("aaa", "other-1", "a bare pod")))
        assert w.row_of(key) == 1
        assert w.scale_target(key) == 3, "the repaint took the operator's target away"
    finally:
        w.deleteLater()
        qapp.processEvents()


# ── the section: off-thread, one at a time, honest teardown ───────────────────────

@pytest.fixture
def host(qapp):
    """A shown host widget for a MeshMonitorSection — the Section reads
    ``page.isVisible()`` on every tick."""
    h = QtWidgets.QWidget()
    h.setLayout(QtWidgets.QVBoxLayout())
    h.show()
    qapp.processEvents()
    yield h
    h.hide()
    h.deleteLater()
    qapp.processEvents()


@pytest.fixture
def section(qapp, host, monkeypatch):
    """A real MeshMonitorSection whose snapshot read is instant and does nothing."""
    monkeypatch.setattr(mm, "snapshot",
                        lambda gen, node, **kw: _snap(_scalable("hugmesh", "gw-1")))
    sec = mw.MeshMonitorSection(host, GENERATOR_DIR, lambda: _ScaleNode(),
                                scaling=True, what="the host's own mesh.")
    sec.mount(host.layout())
    yield sec
    sec.timer.stop()
    sec.shutdown()
    qapp.processEvents()


def _drain(qapp, sec, timeout_s=10.0):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        busy = False
        for n in ("_probe", "_scale_worker"):
            t = getattr(sec, n, None)
            if t is not None:
                try:
                    busy = busy or t.isRunning()
                    t.wait(100)
                except RuntimeError:
                    pass
        qapp.processEvents()
        if not busy:
            return
    raise AssertionError("a section thread never finished")


def test_apply_runs_the_scale_off_the_gui_thread_one_at_a_time(qapp, section,
                                                               monkeypatch):
    """M2 and M3 together.

    M3: ``mesh_monitor.scale`` inline on the GUI thread freezes the window for the
    whole SCALE_TIMEOUT_S ceiling on a hung daemon — 180 s of an unrepainting table
    that is showing the thing being scaled.
    M2: two `docker compose up --scale` invocations against one project race each
    other's container set, and the second's ``--no-recreate`` does not protect the
    first's work. One at a time, and the inline line says which one.
    """
    gui = threading.get_ident()
    ran: list[int] = []
    gate = threading.Event()

    def fake_scale(gen, node, unit, n, **kw):
        ran.append(threading.get_ident())
        gate.wait(10)
        return True, f"scaled to {n}"
    monkeypatch.setattr(mm, "scale", fake_scale)

    section.refresh("test")
    _drain(qapp, section)
    key = "kind/hugmesh/gw-1"
    cell = section.monitor.scale_cell(key)
    assert cell is not None, "the section did not paint a scalable row"
    cell.plus.click()
    cell.plus.click()
    assert section.monitor.scale_target(key) == 3

    cell.apply.click()
    qapp.processEvents()
    assert section.monitor._scale_busy, "the busy guard never latched"
    assert "Scaling deployment/gw in hugmesh to 3" in section.monitor.scale_status_text()
    for b in (cell.minus, cell.plus, cell.apply):
        assert not b.isEnabled(), "a control stayed live while a scale was running"

    # a SECOND press, and a second emit straight into the slot, must not stack
    cell.apply.click()
    section.monitor.scale_requested.emit(key, 5)
    qapp.processEvents()
    gate.set()
    _drain(qapp, section)
    assert len(ran) == 1, f"{len(ran)} scales ran concurrently against one project"
    assert ran[0] != gui, "the scale ran ON the GUI thread"
    assert not section.monitor._scale_busy
    assert "scaled to 3" in section.monitor.scale_status_text()


def test_a_row_that_left_the_last_read_is_refused_not_guessed_at(qapp, section):
    section.refresh("test")
    _drain(qapp, section)
    section._scale("kind/hugmesh/vanished", 2)
    assert "no longer in the last read" in section.monitor.scale_status_text()


def test_a_failed_scale_on_the_section_drops_the_pending_arrow(qapp, section,
                                                               monkeypatch):
    """The Section twin of the page pin (issue #341 landing review): ``_scale_done``
    is where a REFUSED target is forgotten; the re-read cannot do it because the
    count it observes still differs from the target the operator asked for."""
    monkeypatch.setattr(mm, "scale", lambda *a, **k: (False, "scale failed: refused"))
    section.refresh("test")
    _drain(qapp, section)
    key = "kind/hugmesh/gw-1"
    cell = section.monitor.scale_cell(key)
    observed = cell.observed
    cell.plus.click()
    cell.plus.click()
    assert section.monitor.scale_target(key) == observed + 2
    cell.apply.click()
    qapp.processEvents()
    _drain(qapp, section)
    assert not section.monitor._scale_busy
    assert "scale failed: refused" in section.monitor.scale_status_text()
    cell = section.monitor.scale_cell(key)
    assert cell.observed == observed
    assert section.monitor.scale_target(key) == observed, "the refused target lingered"
    assert key not in section.monitor._scale_targets


def test_shutdown_says_which_thread_it_abandoned(qapp, host, monkeypatch):
    """The refutation's third major: the docstring promised a drain it does not do.
    A compose scale has a 180 s ceiling and shutdown waits 5 s for it, so one in
    flight when the operator leaves the page is ABANDONED — it keeps running,
    unobserved. That is the trade; it must be visible rather than implied."""
    assert (mw.MeshMonitorSection.SHUTDOWN_WAIT_MS["_scale_worker"]
            < mm.SCALE_TIMEOUT_S * 1000), "ms vs s — the wait is the shorter one"
    monkeypatch.setattr(mm, "snapshot",
                        lambda gen, node, **kw: _snap(_scalable("hugmesh", "gw-1")))
    gate = threading.Event()
    monkeypatch.setattr(mm, "scale",
                        lambda *a, **k: (gate.wait(20), (True, "done"))[1])
    sec = mw.MeshMonitorSection(host, GENERATOR_DIR, lambda: _ScaleNode(), scaling=True)
    sec.mount(host.layout())
    try:
        sec.refresh("test")
        _drain(qapp, sec)
        monkeypatch.setitem(mw.MeshMonitorSection.SHUTDOWN_WAIT_MS, "_scale_worker", 50)
        sec.monitor.scale_requested.emit("kind/hugmesh/gw-1", 3)
        qapp.processEvents()
        still = sec.shutdown()
        assert still == ("_scale_worker",), f"shutdown claimed a drain it did not do: {still}"
        assert sec.abandoned == ("_scale_worker",)
        assert not sec.timer.isActive()
    finally:
        gate.set()
        _drain(qapp, sec, timeout_s=25)
        sec.shutdown()
        qapp.processEvents()


def test_a_collapsed_section_stops_the_clock_rather_than_ticking_into_nothing(qapp,
                                                                              section):
    """A section collapsed between _on_toggled and the next tick otherwise keeps a
    10 s no-op timer alive for the life of the page."""
    section.section.toggle.setChecked(True)
    qapp.processEvents()
    assert section.timer.isActive()
    _drain(qapp, section)
    section.section.setVisible(False)
    section.monitor.setVisible(False)
    section.section.toggle.setChecked(False)     # collapsed: _on_toggled stops it
    assert not section.timer.isActive()
    section.timer.start()                        # pretend the window was missed
    section._tick()
    assert not section.timer.isActive(), "a collapsed section kept a no-op timer alive"


def test_a_refresh_over_an_existing_snapshot_says_it_is_re_reading(qapp, section,
                                                                   monkeypatch):
    """Nit: once a first snapshot exists, _sync_gate re-renders THAT one until the
    new read lands, and "read 11:00:00" beside rows being re-read reads as fresh."""
    section.refresh("first")
    _drain(qapp, section)
    assert "read 11:00:00" in section.monitor.note.text()
    assert "Re-reading" not in section.monitor.note.text()
    gate = threading.Event()

    def slow(gen, node, **kw):
        gate.wait(10)
        return _snap(_scalable("hugmesh", "gw-1"), taken_at="11:00:09")
    monkeypatch.setattr(mm, "snapshot", slow)
    section.refresh("second")
    qapp.processEvents()
    assert "Re-reading…" in section.monitor.note.text()
    gate.set()
    _drain(qapp, section)
    assert "read 11:00:09" in section.monitor.note.text()
    assert "Re-reading" not in section.monitor.note.text()


def test_a_declined_door_is_said_out_loud_even_on_a_non_scaling_mount(qapp, host,
                                                                      monkeypatch):
    """Nit: the door refusal routed into set_scale_status, which used to return early
    when the label did not exist — i.e. exactly on a non-scaling mount. A refusal that
    goes nowhere is the same bug as a control that does nothing."""
    monkeypatch.setattr(mm, "snapshot", lambda gen, node, **kw: snap_none())
    opened = []
    monkeypatch.setattr(QtGui.QDesktopServices, "openUrl", lambda u: opened.append(u))
    sec = mw.MeshMonitorSection(host, GENERATOR_DIR, lambda: _ScaleNode(), scaling=False)
    try:
        assert sec.monitor.scaling is False
        assert sec.monitor.table.columnCount() == len(mw._MON_HEADERS)
        sec._open_door("https://localhost:8443/")        # the HSTS ban
        assert opened == []
        assert "Not opened:" in sec.monitor.scale_status_text()
        assert sec.monitor.scale_status.isVisibleTo(sec.monitor)
    finally:
        sec.shutdown()
        qapp.processEvents()


def test_the_two_monitor_probes_have_not_drifted():
    """The refutation's second major, closed by issue #341's second item.
    ``MeshMonitorProbe`` was a hand copy of ``localmesh._MonitorProbe`` that could not
    import it (localmesh.py imports THIS module, so the import would be circular), and
    this test pinned the two against each other by shape. The dedup ran the only way
    it could — ``localmesh._MonitorProbe`` is now an ALIAS of the canonical class —
    so the pin is IDENTITY, and the shape checks below are kept as the contract the
    page's ``_refresh_monitor`` relies on (constructor, ``result`` signal, both run()
    paths). A second class reappearing in localmesh.py fails on the first line."""
    a, b = mw.MeshMonitorProbe, localmesh_mod._MonitorProbe
    assert a is b, "localmesh._MonitorProbe must be an alias of MeshMonitorProbe, not a copy"
    import inspect as _i
    assert (list(_i.signature(a.__init__).parameters)
            == list(_i.signature(b.__init__).parameters))
    assert hasattr(a, "result") and hasattr(b, "result")

    class _Node:
        pass
    for cls in (a, b):
        seen = []
        p = cls(GENERATOR_DIR, _Node())
        p.result.connect(seen.append)
        p.run()                                  # inline: this is a shape check
        assert len(seen) == 1
        assert isinstance(seen[0], mm.MonitorSnapshot)

    def _boom(*_a, **_k):
        raise RuntimeError("the daemon went away")
    import unittest.mock as _m
    for cls in (a, b):
        seen = []
        with _m.patch.object(mm, "snapshot", _boom):
            p = cls(GENERATOR_DIR, _Node())
            p.result.connect(seen.append)
            p.run()                              # never raises, folds into the snapshot
        assert len(seen) == 1
        assert "the monitor read failed" in " ".join(seen[0].errors)
        assert seen[0].kind.running is None and seen[0].compose.running is None


def test_the_widget_busy_guard_holds_for_a_click_that_was_already_in_the_queue(qapp):
    """M2, on the path the disabled buttons do NOT cover.

    ``set_scale_busy`` disables the whole strip, so a press made after a scale starts
    emits nothing whatever ``_apply`` does — which is why deleting the guard leaves
    every button-driven test green. The press it is actually for is the one ALREADY IN
    QT'S EVENT QUEUE when the guard latched: the operator double-pressed Apply, both
    clicks were posted, and the second is delivered into an enabled-when-posted button
    a moment later. Two `docker compose up --scale` runs against one project race each
    other's container set, and the second's --no-recreate does not protect the first's
    work.
    """
    w = mw.MeshMonitorWidget(scaling=True)
    try:
        seen = []
        w.scale_requested.connect(lambda k, n: seen.append((k, n)))
        key = "kind/hugmesh/gw-1"
        w.render(_snap(_scalable("hugmesh", "gw-1")))
        w.scale_cell(key).plus.click()
        w._apply(key)                        # the first press
        assert seen == [(key, 2)]
        w.set_scale_busy(True, "Scaling deployment/gw in hugmesh to 2…")
        w._apply(key)                        # the queued second press, delivered late
        assert seen == [(key, 2)], "a second scale was emitted while one was running"
        w.set_scale_busy(False, "done")
        w._apply(key)
        assert len(seen) == 2                # and the guard lifts
    finally:
        w.deleteLater()
        qapp.processEvents()


# ══════════════════════════════════════════════════════════════════════════════════
# RESIDUE FROM THE ADJUDICATION OF WORKTREE studio/c-336 (#336, #341).
#
# A parallel draft of the #342 tests was left uncommitted in that worktree. Every test
# in it was matched against this file by what it ASSERTS, not by name; the eight below
# are the residue that pins something nothing above pinned. Each is proven by a
# production mutation that SURVIVED this whole file and is killed by the test:
#
#   X1   _join attaches ScaleTarget() instead of the derived target
#   X2   localmesh.py mounts MeshMonitorWidget(self, scaling=True)
#   X3   the widget hands its strips ceiling=100000, not MAX_REPLICAS
#   X5   set_scale_busy paints only the FIRST strip busy
#   X6   clear() keeps _scale_cells
#   X7   the compose argv gains --remove-orphans
#   X8   the kubectl --context drifts to kind-<cluster>-ctl
#   X15  _probe folds an exception WITHOUT its message
# ══════════════════════════════════════════════════════════════════════════════════

def test_join_puts_the_target_on_the_unit():
    """X1. ``_pod_scale_target`` is pinned above; this pins that ``_join`` actually
    CALLS it for every pod row. A join that attached ``ScaleTarget()`` paints a dash on
    every row of a healthy cluster, and nothing above notices."""
    pod = {"kind": "Pod",
           "metadata": {"namespace": "hugmesh-pki", "name": "casdoor-6d4f8b9c7-abcde",
                        "labels": {"pod-template-hash": "6d4f8b9c7"},
                        "ownerReferences": [{"kind": "ReplicaSet",
                                             "name": "casdoor-6d4f8b9c7"}]},
           "spec": {}, "status": {"phase": "Running", "containerStatuses": []}}
    units, _notes = mm._join({"items": [pod]}, {}, [], {}, "hugmesh-local")
    assert len(units) == 1
    assert units[0].scale.scalable, units[0].scale.refused
    assert (units[0].scale.kind, units[0].scale.name) == ("deployment", "casdoor")


def test_the_pages_own_monitor_mounts_the_replicas_column_and_wires_it(qapp, page,
                                                                      fake):
    """X2, re-pointed when #341 landed. ``test_the_default_monitor_widget_is_still_
    the_six_column_table`` pins the DEFAULT; this pins the MOUNT: ``localmesh.py``
    builds ``MeshMonitorWidget(self, scaling=True)`` AND connects ``scale_requested``
    to ``_scale_monitor``. Until 2026-09-16 this test pinned the bare six-column
    mount, because the kwarg alone would have shipped a knob whose Apply emitted
    into nothing. Both halves are asserted: the column, and a receiver behind it —
    the widget's own NO_SINK refusal must never be what the operator's screen says."""
    assert page.monitor.scaling is True
    assert page.monitor.table.columnCount() == len(mw._MON_HEADERS_SCALING)
    assert page.monitor.table.horizontalHeaderItem(mw._MON_COL_SCALE).text() == "Replicas"
    fake.answers = [_snap(_scalable("hugmesh", "gw-1"))]
    page.initializePage()
    _settle(qapp, page)
    cell = page.monitor.scale_cell("kind/hugmesh/gw-1")
    assert cell is not None, "the page did not paint a Replicas strip for a scalable row"
    # a receiver exists (the same protected-method probe the widget's _apply uses)
    assert page.monitor.receivers(page.monitor.scale_requested) >= 1
    # …and pressing Apply with a target that differs never lands on the NO_SINK line
    cell.plus.click()
    cell.apply.click()
    qapp.processEvents()
    assert "not wired" not in page.monitor.scale_status_text()
    assert mw.MeshMonitorWidget.NO_SINK not in page.monitor.scale_status_text()
    _settle(qapp, page)


def _scale_snapshot_page(qapp, page, fake):
    """Enter the page with one scalable kind row on screen, settled."""
    fake.answers = [_snap(_scalable("hugmesh", "gw-1"))]
    page.initializePage()
    _settle(qapp, page)
    cell = page.monitor.scale_cell("kind/hugmesh/gw-1")
    assert cell is not None, "the page did not paint a scalable row"
    return cell


def test_the_pages_apply_runs_the_scale_off_the_gui_thread_one_at_a_time(
        qapp, page, fake, monkeypatch):
    """Issue #341: the page's receiver is ``MeshMonitorSection._scale`` copied, so it
    carries the same two guarantees — M3 (never on the GUI thread) and M2 (one scale
    per project at a time, including an Apply already in Qt's queue when the first one
    latched) — and the same finish: the busy guard released with the verb's answer on
    the inline line, the pending target forgotten, and ONE re-read of the lanes."""
    gui = threading.get_ident()
    ran: list[int] = []
    gate = threading.Event()

    def fake_scale(gen, node, unit, n, **kw):
        ran.append(threading.get_ident())
        gate.wait(10)
        return True, f"scaled to {n}"
    monkeypatch.setattr(mm, "scale", fake_scale)
    cell = _scale_snapshot_page(qapp, page, fake)
    reads_before = fake.calls
    key = "kind/hugmesh/gw-1"
    cell.plus.click()
    cell.plus.click()
    assert page.monitor.scale_target(key) == 3

    cell.apply.click()
    qapp.processEvents()
    assert page.monitor._scale_busy, "the busy guard never latched"
    assert localmesh_mod.probe_running(page, "_scale_worker")
    assert "Scaling deployment/gw in hugmesh to 3" in page.monitor.scale_status_text()
    for b in (cell.minus, cell.plus, cell.apply):
        assert not b.isEnabled(), "a control stayed live while a scale was running"

    # a SECOND press, and a second emit straight into the slot, must not stack
    cell.apply.click()
    page.monitor.scale_requested.emit(key, 5)
    qapp.processEvents()
    gate.set()
    _settle(qapp, page)
    assert len(ran) == 1, f"{len(ran)} scales ran concurrently against one project"
    assert ran[0] != gui, "the scale ran ON the GUI thread"
    assert not page.monitor._scale_busy
    assert "scaled to 3" in page.monitor.scale_status_text()
    assert page._scaling_key == ""
    assert fake.calls > reads_before, "a finished scale must re-read the lanes"


def test_the_pages_scale_is_refused_out_loud_while_a_verb_runs(qapp, page, fake,
                                                              monkeypatch):
    """Issue #341: this page runs mesh VERBS, which the Section never does. A
    `docker compose up --scale` racing `make stack-up` against the same project is
    the container-set race the busy guard exists for — so Apply during a verb is
    refused on the table's inline line (never silently), and no worker starts."""
    ran = []
    monkeypatch.setattr(mm, "scale", lambda *a, **k: ran.append(1) or (True, "x"))
    cell = _scale_snapshot_page(qapp, page, fake)
    page._running, page._running_label = True, "Start mesh"
    try:
        cell.plus.click()
        cell.apply.click()
        qapp.processEvents()
        assert not localmesh_mod.probe_running(page, "_scale_worker")
        assert getattr(page, "_scale_worker", None) is None
        text = page.monitor.scale_status_text()
        assert "Not scaled" in text and "Start mesh" in text, text
        assert page.monitor.scale_status.isVisibleTo(page.monitor)
        assert ran == []
    finally:
        page._running, page._running_label = False, ""


def test_a_verb_is_refused_out_loud_while_the_pages_scale_runs(qapp, page, fake,
                                                              monkeypatch):
    """The mirror guard (issue #341): ``_launch`` refuses a verb while a scale worker
    is in flight, says so on the page's status line, and leaves ``_running`` False —
    so the buttons it would have disarmed stay live for when the scale lands."""
    gate = threading.Event()
    monkeypatch.setattr(mm, "scale", lambda *a, **k: (gate.wait(10), (True, "done"))[1])
    cell = _scale_snapshot_page(qapp, page, fake)
    cell.plus.click()
    cell.apply.click()
    qapp.processEvents()
    assert localmesh_mod.probe_running(page, "_scale_worker")
    launched = []
    page._launch("Start mesh", lambda: launched.append(1) or (True, []))
    qapp.processEvents()
    assert page._running is False
    assert launched == []
    assert "Replicas change" in page.status.text(), page.status.text()
    gate.set()
    _settle(qapp, page)
    assert not localmesh_mod.probe_running(page, "_scale_worker")


def test_the_pages_scale_refuses_a_row_that_left_the_last_read(qapp, page, fake):
    _scale_snapshot_page(qapp, page, fake)
    page._scale_monitor("kind/hugmesh/vanished", 2)
    assert "no longer in the last read" in page.monitor.scale_status_text()
    assert not localmesh_mod.probe_running(page, "_scale_worker")


def test_a_failed_scale_on_the_page_drops_the_pending_arrow(qapp, page, fake,
                                                            monkeypatch):
    """Issue #341 (the landing review's one surviving mutation): ``_on_scale_done``
    must ``forget_scale_target`` — the widget keeps a pending target across repaints
    ON PURPOSE (so a tick between + and Apply does not snap the number back), and
    the only thing that clears a target the daemon REFUSED is the page saying the
    scale is over. Without it the strip keeps showing "1 → 3" after "scaled to 3"
    failed, until the operator presses − twice. Pinned on the failure path because
    the success path hides it: a re-read that observes 3 pops the target itself."""
    monkeypatch.setattr(mm, "scale", lambda *a, **k: (False, "scale failed: refused"))
    cell = _scale_snapshot_page(qapp, page, fake)
    key = "kind/hugmesh/gw-1"
    observed = cell.observed
    cell.plus.click()
    cell.plus.click()
    assert page.monitor.scale_target(key) == observed + 2
    reads_before = fake.calls
    cell.apply.click()
    qapp.processEvents()
    _settle(qapp, page)
    assert not page.monitor._scale_busy
    assert "scale failed: refused" in page.monitor.scale_status_text()
    assert fake.calls > reads_before, "a finished scale must re-read the lanes"
    cell = page.monitor.scale_cell(key)
    assert cell.observed == observed, "the fake never scaled anything"
    assert page.monitor.scale_target(key) == observed, "the refused target lingered"
    assert key not in page.monitor._scale_targets
    for b in (cell.minus, cell.plus):
        assert b.isEnabled(), "a strip stayed dead after the scale finished"


def test_the_widgets_strip_stops_at_zero_and_at_MAX_REPLICAS(qapp):
    """X3. ``test_the_ceiling_refuses_rather_than_asking_for_it`` pins MAX_REPLICAS and
    scale_argv's refusal; ``test_the_replica_strip_clamps…`` pins the strip's clamp for
    a ceiling IT is handed. Neither pins that the WIDGET hands its strips MAX_REPLICAS:
    a widget built with ``ceiling=100000`` keeps both green, and every press past the
    ceiling becomes a refusal the operator only meets after Apply."""
    w = mw.MeshMonitorWidget(scaling=True)
    try:
        key = "kind/hugmesh/gw-1"
        w.render(_snap(_scalable("hugmesh", "gw-1")))
        cell = w.scale_cell(key)
        for _ in range(5):
            cell.minus.click()
        assert cell.target == 0 and not cell.minus.isEnabled()
        for _ in range(mm.MAX_REPLICAS + 5):
            cell.plus.click()
        assert cell.target == mm.MAX_REPLICAS and not cell.plus.isEnabled()
        assert w.scale_target(key) == mm.MAX_REPLICAS
    finally:
        w.deleteLater()
        qapp.processEvents()


def test_the_busy_guard_disables_every_apply_not_just_the_one_being_scaled(qapp):
    """X5. ``test_apply_runs_the_scale_off_the_gui_thread_one_at_a_time`` checks the
    controls of the ONE row it scaled. The guard is on the widget because two compose
    ``up`` runs against one project race each other — so it is the OTHER rows' Apply
    that must be dead while one runs, and that is what this pins."""
    w = mw.MeshMonitorWidget(scaling=True)
    try:
        a = _scalable("hugmesh", "gw-1", ctrl="gw")
        b = _scalable("hugmesh-wiki", "wiki-1", ctrl="wiki")
        w.render(_snap(a, b))
        for u in (a, b):
            w.scale_cell(u.key).plus.click()
        w.set_scale_busy(True, "Scaling deployment/gw in hugmesh to 2…")
        for u in (a, b):
            cell = w.scale_cell(u.key)
            assert not cell.apply.isEnabled(), f"{u.key}'s Apply stayed live"
            assert not cell.plus.isEnabled() and not cell.minus.isEnabled()
        assert "Scaling deployment/gw" in w.scale_status_text()
        w.set_scale_busy(False, "done")
        for u in (a, b):
            assert w.scale_cell(u.key).apply.isEnabled(), "the guard did not lift"
    finally:
        w.deleteLater()
        qapp.processEvents()


def test_clear_drops_the_scale_strips_with_the_rows(qapp):
    """X6. A failed read CLEARS the rows (the tri-state gate). A strip cache that
    survives ``clear()`` hands ``scale_cell()`` a widget Qt has already deleted, and
    the next render seats a fresh strip beside a stale entry."""
    w = mw.MeshMonitorWidget(scaling=True)
    try:
        key = "kind/hugmesh/gw-1"
        w.render(_snap(_scalable("hugmesh", "gw-1")))
        assert w.scale_cell(key) is not None
        w.clear()
        assert w.table.rowCount() == 0
        assert w.scale_cell(key) is None, "clear() kept a strip for a row it dropped"
    finally:
        w.deleteLater()
        qapp.processEvents()


def test_the_compose_scale_argv_is_exact(monkeypatch):
    """X7. The flag test above asserts what must be PRESENT; a flag that must be ABSENT
    slips past it — ``--remove-orphans`` (removes every container the compose file does
    not name), ``--build``, ``--force-recreate`` — each a real ``up`` flag one edit
    away. So: the whole argv, byte for byte, ``-p hugmesh-local`` included."""
    monkeypatch.setattr(mm, "_compose_base", lambda: ["docker", "compose"])
    unit = _scalable("hugmesh-local", "hugmesh-local-fe-1", lane="compose",
                     kind="compose-service", ctrl="fe-gateway")
    node = _ScaleNode()
    argv, refused = mm.scale_argv(unit, 3, generator_dir="/gen", node=node)
    assert refused == ""
    assert argv == ["docker", "compose", "-p", "hugmesh-local", "-f", node.compose_file,
                    "up", "-d", "--no-deps", "--no-recreate",
                    "--scale", "fe-gateway=3", "fe-gateway"]


def test_the_kubectl_scale_argv_is_exact(monkeypatch):
    """X8. ``startswith("kind-")`` above lets the context name drift, and a wrong
    context is ``kubectl scale`` against a DIFFERENT cluster with a clean exit code.
    The default cluster name is the Makefile's (bootstrap-kind.sh reads the same
    KIND_CLUSTER_NAME override), so it is pinned literally with the override cleared."""
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    monkeypatch.setattr(mm.devops_tools, "which", lambda tool, d: "/usr/bin/" + tool)
    unit = _scalable("hugmesh", "gw-1", kind="deployment", ctrl="gateway")
    argv, refused = mm.scale_argv(unit, 3, generator_dir="/gen", node=_ScaleNode())
    assert refused == ""
    assert argv == ["/usr/bin/kubectl", "--context", "kind-hugmesh-local", "scale",
                    "deployment/gateway", "-n", "hugmesh", "--replicas=3"]


def test_a_scale_whose_probe_explodes_says_what_exploded(monkeypatch):
    """X15. ``test_scale_never_raises…`` pins that it folds and says "failed"; this
    pins that the fold keeps the EXCEPTION'S OWN WORDS. "scaling … failed: probe
    failed" for a dead daemon is a refusal with the reason cut off — this repo's named
    anti-pattern — and it is exactly what a ``_probe`` folding to a constant produces."""
    monkeypatch.setattr(mm.devops_tools, "which", lambda tool, d: "/usr/bin/" + tool)

    class _Boom:
        compose_file = "/c.yaml"

        def _probe(self, cmd, timeout=None):
            raise RuntimeError("the daemon went away")

    ok, text = mm.scale("/gen", _Boom(), _scalable("hugmesh", "gw-1", ctrl="gw"), 2)
    assert ok is False
    assert "RuntimeError" in text and "the daemon went away" in text


def test_completed_has_its_own_glyph_distinct_from_stopped_and_queued():
    """The state rides progress.py's palette (no second catalogue): `completed` must not
    fall back to the 'queued' glyph an unknown state gets, nor wear the halted
    service's 'stopped' square."""
    from hugmesh_studio.gui.pages import _mesh_monitor_widget as w
    assert w._glyph("completed") not in (w._glyph("queued"), w._glyph("stopped"))
    assert w._colour("completed") != w._colour("failed")
