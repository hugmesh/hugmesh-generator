"""Pod controls per domain — the GUI boundary (2026-10-21).

The rows come from the RECORDED fixtures test_mesh_pod_controls.py describes, run
through the real core join, so what is asserted here is what a real ``docker compose
ps`` of a per-domain own-Casdoor mesh paints. Every visible control is checked to be
VISIBLE, ENABLED (when it should be) and of a sane size — the operator once could not
see a control 193 green tests said existed. Nothing here shells docker, kubectl or a
browser: the page's worker runs a monkeypatched ``run_domain_action``.
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
from hugmesh_studio.gui.qt import QtWidgets                              # noqa: E402

pytestmark = pytest.mark.real_mesh_monitor

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
FIX = os.path.join(STUDIO_ROOT, "tests", "fixtures", "mesh_monitor")
STACK_COMPOSE = os.path.join(GENERATOR_DIR, "tests", "stack", "compose.local.yaml")

ONION_P = "https://" + "p" * 56 + ".onion/"
ONION_A = "https://" + "a" * 56 + ".onion/"
ONION_B = "https://" + "b" * 56 + ".onion/"


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


class _Node:
    public_https_port = 8488
    public_host_port = 8088
    web_url = "https://localhost:8488"
    compose_file = STACK_COMPOSE

    def __init__(self, text, *, onion="", onions=None, tor_domains=()):
        self._text = text
        self._onion = onion
        self._onions = dict(onions or {})
        self.tor_domains = tuple(tor_domains)

    def status(self):
        return SimpleNamespace(running=True, detail="")

    def onion_url(self):
        return self._onion

    def onion_urls(self):
        return dict(self._onions)

    def _probe(self, cmd, timeout=15):
        return 0, self._text


def recorded_snapshot(monkeypatch, *, with_tor=True, kind=True):
    """The recorded compose project (+ a tor row with three onions) and the recorded
    kind objects, through the REAL joins."""
    import json
    monkeypatch.setattr(mm.shutil, "which", lambda t: "/usr/bin/" + t)
    monkeypatch.setattr(mm, "_compose_base", lambda: ["docker", "compose"])
    with open(os.path.join(FIX, "podctl-compose-ps.json"), encoding="utf-8") as fh:
        rows = [json.loads(line) for line in fh if line.strip()]
    rows = [r for r in rows if with_tor or r["Service"] != "hugmesh-tor"]
    for r in rows:                     # the recording is of created containers: up them
        r["State"], r["Status"] = "running", "Up 2 minutes"
    node = _Node(json.dumps(rows), onion=ONION_P if with_tor else "",
                 onions=({"shop-example": ONION_A, "team-example": ONION_B}
                         if with_tor else {}),
                 tor_domains=(("shop.example", "shop-example", "default"),
                              ("team.example", "team-example", "team-example")))
    onions: list = []
    hints = mm.DomainHints(names={"acme-example": "acme.example"},
                           own_domain="mesh.example")
    lane, cunits, _n, _e = mm._compose_units(node, GENERATOR_DIR, [], {},
                                             mm._Budget(25), hints=hints,
                                             onions_out=onions)
    kunits = []
    if kind:
        with open(os.path.join(FIX, "podctl-kind-objects.json"), encoding="utf-8") as fh:
            kunits, _ = mm._join(json.load(fh), {}, [], {}, "hugmesh-local", hints=hints)
    return mm.MonitorSnapshot(taken_at="20:28:00", compose=lane,
                              kind=mm.LaneState(bool(kind), "cluster hugmesh-local"),
                              units=tuple(kunits) + tuple(cunits),
                              onions=tuple(onions))


def _sane(btn):
    assert btn.isVisibleTo(btn.window()), btn.text()
    hint = btn.sizeHint()
    assert hint.width() >= 40 and hint.height() >= 16, (btn.text(), hint)


@pytest.fixture
def widget(qapp):
    w = mw.MeshMonitorWidget(scaling=True)
    w.resize(1400, 900)
    w.show()
    qapp.processEvents()
    yield w
    w.hide()
    w.deleteLater()
    qapp.processEvents()


# ── the Domain column ────────────────────────────────────────────────────────────

def test_every_row_says_which_domain_it_serves(widget, monkeypatch, qapp):
    snap = recorded_snapshot(monkeypatch)
    widget.render(snap)
    t = widget.table
    assert t.horizontalHeaderItem(mw._MON_COL_DOMAIN).text() == "Domain"
    seen = {}
    for r in range(t.rowCount()):
        seen[t.item(r, mw._MON_COL_NAME).text()] = t.item(r, mw._MON_COL_DOMAIN).text()
    assert seen["hugmesh-local/hugmesh-local-casdoor-acme-example-1"] == "acme.example"
    assert seen["hugmesh-local/hugmesh-local-casdoor-acme-example-db-1"] == "acme.example"
    assert seen["hugmesh-local/hugmesh-local-casdoor-1"] == "All domains"
    assert seen["hugmesh-local/hugmesh-local-hugmesh-tor-1"] == "All domains"
    assert seen["hugmesh-local/hugmesh-local-hugmesh-tor-1 · shop.example onion"] == \
        "shop.example"
    assert seen["acme-pki/casdoor-domain-7c9d6b5f4-q8x2m"] == "acme.example"
    assert seen["kube-system/etcd-hugmesh-local-control-plane"] == "All domains"
    r = widget.row_of("compose/hugmesh-local/hugmesh-local-casdoor-acme-example-1")
    assert "hugmesh.net/domain=acme.example" in t.item(r, mw._MON_COL_DOMAIN).toolTip()
    assert t.columnWidth(mw._MON_COL_DOMAIN) > 20


# ── the per-domain strip ─────────────────────────────────────────────────────────

def test_the_domain_strip_is_visible_enabled_and_names_its_targets(widget, monkeypatch,
                                                                   qapp):
    widget.render(recorded_snapshot(monkeypatch))
    qapp.processEvents()
    combo = widget.domain_combo
    assert combo.isVisibleTo(widget) and combo.isEnabled()
    assert [combo.itemData(i) for i in range(combo.count())] == \
        ["acme.example", "shop.example", "team.example"]
    assert widget.select_domain("acme.example")
    for verb in ("restart", "stop", "logs"):
        b = widget.domain_btns[verb]
        _sane(b)
        assert b.isEnabled(), verb
        assert "hugmesh-local-casdoor-acme-example-db-1" in b.toolTip()
        assert "hugmesh-local-casdoor-1" not in b.toolTip().replace(
            "hugmesh-local-casdoor-acme", "")
    # every row of acme.example is up: Start has nothing to act on and says so
    start = widget.domain_btns["start"]
    _sane(start)
    assert not start.isEnabled()
    assert "already running" in start.toolTip()
    # an onion-only domain: its rows ride the shared tor, so stop is refused by name
    widget.select_domain("shop.example")
    assert not widget.domain_btns["stop"].isEnabled()
    assert "SAME hugmesh-tor container" in widget.domain_btns["stop"].toolTip()
    assert widget.domain_btns["logs"].isEnabled()


def test_a_press_emits_domain_and_verb_and_an_unwired_mount_refuses_inline(
        widget, monkeypatch, qapp):
    widget.render(recorded_snapshot(monkeypatch))
    widget.select_domain("acme.example")
    widget.domain_btns["stop"].click()             # nothing connected
    assert widget.scale_status_text() == widget.NO_DOMAIN_SINK
    got = []
    widget.domain_action_requested.connect(lambda d, v: got.append((d, v)))
    widget.domain_btns["stop"].click()
    widget.domain_btns["logs"].click()
    assert got == [("acme.example", "stop"), ("acme.example", "logs")]
    widget.set_domain_busy(True, "Stop acme.example…")
    assert not any(b.isEnabled() for b in widget.domain_btns.values())
    assert widget.scale_status_text() == "Stop acme.example…"
    widget.set_domain_busy(False, "")
    assert widget.domain_btns["stop"].isEnabled()


def test_selecting_a_domain_row_points_the_strip_at_it(widget, monkeypatch, qapp):
    widget.render(recorded_snapshot(monkeypatch))
    widget.select_domain("team.example")
    r = widget.row_of("kind/acme-pki/casdoor-domain-7c9d6b5f4-q8x2m")
    widget.table.selectRow(r)
    qapp.processEvents()
    assert widget.current_domain() == "acme.example"


def test_no_single_domain_row_greys_the_strip_with_the_reason(widget, monkeypatch, qapp):
    snap = recorded_snapshot(monkeypatch, with_tor=False, kind=False)
    shared = tuple(u for u in snap.units if not u.domain)
    widget.render(mm.MonitorSnapshot("t", snap.compose, snap.kind, shared))
    assert widget.domain_combo.count() == 0
    assert not widget.domain_combo.isEnabled()
    assert not any(b.isEnabled() for b in widget.domain_btns.values())
    assert "shared by all domains" in widget.domain_note.text()


def test_logs_show_inline_and_hide(widget, qapp):
    widget.show_logs("Logs — acme.example", "── c ──\npanic: dial tcp")
    qapp.processEvents()
    assert widget.logs_box.isVisibleTo(widget)
    assert "panic" in widget.logs_view.toPlainText()
    assert widget.logs_view.isReadOnly()
    widget.logs_hide_btn.click()
    assert not widget.logs_box.isVisibleTo(widget)


# ── every onion, each with its own Open ──────────────────────────────────────────

def test_every_onion_has_its_own_open_and_copy(widget, monkeypatch, qapp):
    snap = recorded_snapshot(monkeypatch)      # (it stubs shutil.which itself)
    monkeypatch.setattr(mc.shutil, "which",
                        lambda c: "/usr/bin/torbrowser-launcher"
                        if c == "torbrowser-launcher" else None)
    widget.render(snap)
    qapp.processEvents()
    assert widget.onion_box.isVisibleTo(widget)
    assert widget.onion_title.text() == "Tor addresses (3)"
    opened = []
    widget.onion_open_requested.connect(opened.append)
    for url in (ONION_P, ONION_A, ONION_B):
        open_b, copy_b = widget.onion_buttons(url + "login")
        _sane(open_b)
        _sane(copy_b)
        assert open_b.isEnabled() and copy_b.isEnabled()
        open_b.click()
        copy_b.click()
        assert QtWidgets.QApplication.clipboard().text() == url + "login"
        assert widget.scale_status_text().startswith(f"Copied {url}login")
    assert opened == [ONION_P + "login", ONION_A + "login", ONION_B + "login"]


def test_without_tor_browser_open_is_greyed_with_the_reason(widget, monkeypatch, qapp):
    snap = recorded_snapshot(monkeypatch)      # (it stubs shutil.which itself)
    monkeypatch.setattr(mc.shutil, "which", lambda c: None)
    widget.render(snap)
    open_b, copy_b = widget.onion_buttons(ONION_A + "login")
    assert not open_b.isEnabled() and copy_b.isEnabled()
    assert "torbrowser-launcher" in open_b.toolTip()


def test_no_onion_hides_the_tor_strip(widget, monkeypatch, qapp):
    widget.render(recorded_snapshot(monkeypatch, with_tor=False))
    assert not widget.onion_box.isVisibleTo(widget)
    widget.clear()
    assert widget.domain_combo.count() == 0


def test_open_in_tor_browser_refuses_without_a_launcher(monkeypatch):
    monkeypatch.setattr(mc.shutil, "which", lambda c: None)
    assert "No Tor Browser" in mw.open_in_tor_browser(ONION_A + "login")
    started = []
    monkeypatch.setattr(mc.shutil, "which", lambda c: "/usr/bin/" + c)
    monkeypatch.setattr(mw.QtCore.QProcess, "startDetached",
                        staticmethod(lambda prog, args: started.append((prog, args))
                                     or True))
    assert mw.open_in_tor_browser(ONION_A + "login") == ""
    assert started == [("/usr/bin/torbrowser-launcher", [ONION_A + "login"])]


# ── the local-mesh page runs it off the GUI thread ───────────────────────────────

class _Stack:
    web_url = "https://localhost:8488"
    plain_web_url = "http://localhost:8088"

    def status(self):
        return SimpleNamespace(running=True, detail="4 container(s)")

    def e2e_ready(self, environment="docker"):
        return ["not running"]


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
    for name in ("_domain_worker", "_monitor_probe", "_probe", "_scale_worker"):
        t = getattr(p, name, None)
        if t is not None:
            try:
                t.wait(5000)
            except RuntimeError:
                pass
    qapp.processEvents()
    p.deleteLater()
    qapp.processEvents()


def _wait(qapp, pred, timeout_s=8.0):
    deadline = time.monotonic() + timeout_s
    while not pred() and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.01)
    qapp.processEvents()
    return pred()


def test_the_page_wires_both_signals(page):
    mon = page.monitor
    assert mon.receivers(mon.domain_action_requested) > 0
    assert mon.receivers(mon.onion_open_requested) > 0


def test_the_page_runs_a_domain_action_off_thread_and_shows_its_answer(
        page, monkeypatch, qapp):
    snap = recorded_snapshot(monkeypatch)
    page._monitor = snap
    page.monitor.render(snap)
    calls = []

    def fake(gen, node, units, domain, verb, **kw):
        calls.append((domain, verb, threading.get_ident()))
        return mc.DomainResult(True, f"{verb} {domain}: done", "── c ──\nhello",
                               domain=domain, verb=verb)

    monkeypatch.setattr(mc, "run_domain_action", fake)
    page._domain_action("acme.example", "logs")
    assert _wait(qapp, lambda: not localmesh_mod.probe_running(page, "_domain_worker")
                 and bool(calls))
    _wait(qapp, lambda: page.monitor.logs_box.isVisibleTo(page.monitor), 3)
    assert calls[0][:2] == ("acme.example", "logs")
    assert calls[0][2] != threading.get_ident()          # never on the GUI thread
    assert page.monitor.scale_status_text() == "logs acme.example: done"
    assert "hello" in page.monitor.logs_view.toPlainText()


def test_the_page_refuses_a_domain_action_while_a_verb_runs(page, monkeypatch):
    page._monitor = recorded_snapshot(monkeypatch)
    ran = []
    monkeypatch.setattr(mc, "run_domain_action",
                        lambda *a, **k: ran.append(a) or mc.DomainResult(True, "ran"))
    page._running = True
    page._running_label = "Starting the mesh"
    try:
        page._domain_action("acme.example", "stop")
    finally:
        page._running = False
    assert page.monitor.scale_status_text().startswith(
        "Not run: Starting the mesh is still running.")
    assert not localmesh_mod.probe_running(page, "_domain_worker")
    w = getattr(page, "_domain_worker", None)
    if w is not None:
        w.wait(5000)
    assert ran == []


def test_the_page_passes_the_configs_domain_hints_to_the_probe(page, monkeypatch, qapp):
    seen = []
    monkeypatch.setattr(localmesh_mod.mesh_monitor, "snapshot",
                        lambda gen, node, **kw: seen.append(kw.get("hints")) or
                        mm.MonitorSnapshot("t", mm.LaneState(False), mm.LaneState(False)))
    page._refresh_monitor("button")
    assert _wait(qapp, lambda: bool(seen))
    assert isinstance(seen[0], mm.DomainHints)
