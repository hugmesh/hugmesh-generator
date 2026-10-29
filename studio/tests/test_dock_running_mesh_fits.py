"""The bottom panel's Running mesh tab, DOCKED, at the Studio's default window size
(1040x780, ``wizard.medium_size`` on any 1080p-or-larger screen): the pod table shows
at least six whole rows, and the domain strip and every Tor address row are drawn
INSIDE the tab's scroll viewport — on screen without scrolling, not merely "visible to"
a parent that has scrolled them away (round 2 of the 2026-10-21 pod controls; the
integrator measured three rows and both strips below the fold).

Every check maps the control into the tab's QScrollArea viewport and asserts the whole
rectangle is inside it. ``isVisibleTo`` is true for a widget scrolled out of view,
which is how a control 193 green tests said existed stayed invisible to the operator.

The rows are the RECORDED fixtures of test_mesh_pod_controls (12 rows, three onions);
no docker, kubectl, model or browser is reached. Screenshots are written to
STUDIO_PANEL_SHOTS (or a temp folder) and their paths printed.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import local_mesh_bootstrap as lmb            # noqa: E402
from hugmesh_studio.core import mesh_controls as mc                    # noqa: E402
from hugmesh_studio.core.mesh_node import MeshNode, MeshStatus         # noqa: E402
from hugmesh_studio.gui import _local_ai_dock as dock_mod              # noqa: E402
from hugmesh_studio.gui.pages import localmesh as lm                   # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                    # noqa: E402

from test_studio_panel import (NORMAL, SMALLEST, _pinned, open_at,     # noqa: E402,F401
                               qapp, settle, shell, shot, wait_for)
from test_mesh_pod_controls_gui import _Stack, recorded_snapshot       # noqa: E402

#: how many whole table rows the docked tab must show at the default size
MIN_ROWS = 6


@pytest.fixture
def mesh(monkeypatch):
    st = _Stack()
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "_stack_node", lambda self: st)
    monkeypatch.setattr(MeshNode, "status",
                        lambda self: MeshStatus(running=False, detail="not started"))
    snap = recorded_snapshot(monkeypatch)
    monkeypatch.setattr(mc.shutil, "which", lambda c: "/usr/bin/torbrowser-launcher"
                        if c == "torbrowser-launcher" else None)
    monkeypatch.setattr(lm.mesh_monitor, "snapshot", lambda *a, **k: snap)
    monkeypatch.setattr(mc, "run_domain_action", lambda g, n, u, d, v, **k: mc.DomainResult(
        True, f"{v} {d}: done", "── casdoor-acme ──\nready\n", domain=d, verb=v))
    return snap


def _open_pods(shell, qapp, mesh, size):
    wiz = open_at(shell, qapp, size)
    ctl = wiz.localmesh_page
    ctl._monitor = mesh
    ctl.monitor.render(mesh)
    dock = wiz.local_ai_dock
    dock.show_tab("pods")
    settle(qapp, 8)
    return wiz, dock, ctl.monitor


def _viewport(w):
    sa = w.parentWidget()
    while sa is not None and not isinstance(sa, QtWidgets.QScrollArea):
        sa = sa.parentWidget()
    assert sa is not None, "the Running mesh tab is not in a scroll area"
    return sa.viewport()


def _rect(vp, w):
    return QtCore.QRect(w.mapTo(vp, QtCore.QPoint(0, 0)), w.size())


def _on_screen(vp, w, wiz):
    """w is shown, and ALL of it is inside the tab's viewport and the window."""
    r = _rect(vp, w)
    return (w.isVisibleTo(wiz) and vp.rect().contains(r)
            and wiz.rect().contains(QtCore.QRect(w.mapTo(wiz, QtCore.QPoint(0, 0)),
                                                 w.size())))


def _rows_on_screen(vp, table):
    tvp = table.viewport()
    n = 0
    for r in range(table.rowCount()):
        y, h = table.rowViewportPosition(r), table.rowHeight(r)
        top = tvp.mapTo(vp, QtCore.QPoint(0, y)).y()
        if y >= 0 and y + h <= tvp.height() and top >= 0 and top + h <= vp.height():
            n += 1
    return n


def _sane(b):
    assert b.width() >= 40 and b.height() >= 18, (b.text(), b.size())


def test_docked_running_mesh_shows_six_rows_the_domain_strip_and_every_tor_row(
        shell, qapp, mesh):
    wiz, dock, mon = _open_pods(shell, qapp, mesh, NORMAL)
    vp = _viewport(mon)
    print("dock", dock.geometry().getRect(), "viewport", vp.size().width(),
          vp.size().height())
    shot(wiz, "running-mesh-docked-1040x780")
    assert dock.tall, "the Running mesh tab must open the panel tall"
    assert mon.table.rowCount() >= MIN_ROWS + 1
    rows = _rows_on_screen(vp, mon.table)
    assert rows >= MIN_ROWS, f"only {rows} whole rows in view"
    # the domain strip: picker and its four buttons, on screen, sane, the right ones on
    assert _on_screen(vp, mon.domain_combo, wiz)
    assert mon.domain_combo.isEnabled() and mon.domain_combo.width() >= 120
    assert mon.current_domain() == "acme.example"
    for verb, b in mon.domain_btns.items():
        assert _on_screen(vp, b, wiz), verb
        _sane(b)
    for verb in ("stop", "restart", "logs"):
        assert mon.domain_btns[verb].isEnabled(), verb
    assert _on_screen(vp, mon.domain_note, wiz)
    # the Tor list: its title and EVERY onion's Open and Copy
    assert _on_screen(vp, mon.onion_title, wiz)
    assert mon.onion_title.text() == "Tor addresses (3)"
    assert len(mon._onion_rows) == 3
    for login, (open_b, copy_b) in mon._onion_rows.items():
        for b in (open_b, copy_b):
            assert _on_screen(vp, b, wiz), (login, b.text())
            assert b.isEnabled(), (login, b.text())
            _sane(b)
    # the page above keeps the wizard's buttons
    nxt = wiz.button(QtWidgets.QWizard.WizardButton.NextButton)
    assert nxt.isVisible() and nxt.mapTo(wiz, QtCore.QPoint(0, 0)).y() + nxt.height() \
        <= dock.y()


def test_logs_open_in_view_in_the_docked_tab(shell, qapp, mesh):
    wiz, dock, mon = _open_pods(shell, qapp, mesh, NORMAL)
    vp = _viewport(mon)
    mon.domain_btns["logs"].click()
    assert wait_for(qapp, lambda: mon.logs_box.isVisibleTo(wiz))
    settle(qapp, 8)
    shot(wiz, "running-mesh-docked-logs-1040x780")
    assert "ready" in mon.logs_view.toPlainText()
    r = _rect(vp, mon.logs_view)
    # the log text's first lines are on screen (the box may be taller than the tab)
    assert r.top() >= 0 and r.top() + 60 <= vp.height(), (r, vp.size())
    assert _on_screen(vp, mon.logs_hide_btn, wiz)


def test_only_the_running_mesh_tab_takes_the_tall_height(shell, qapp, mesh):
    wiz, dock, mon = _open_pods(shell, qapp, mesh, NORMAL)
    tall_h = dock.height()
    dock.show_tab("assistant")
    settle(qapp, 6)
    assert not dock.tall and dock.height() <= dock_mod.EXPANDED_PX
    assert tall_h > dock.height() + 100
    # the page's own request and the tab are one writer: a page that drops its
    # request while the Running mesh tab is open leaves the panel tall
    dock.show_tab("pods")
    settle(qapp, 6)
    dock.set_tall(True)
    dock.set_tall(False)
    settle(qapp, 6)
    assert dock.tall and dock.height() == tall_h
    # popped out, the strip is just its bar again
    dock.pop_out()
    settle(qapp, 6)
    assert dock.height() < 80
    dock.put_back()
    settle(qapp, 6)
    assert dock.height() == tall_h


def test_the_smallest_window_still_shows_six_rows_and_scrolls_to_the_strip(
        shell, qapp, mesh):
    """942x552 (a 1024x600 netbook) is NOT the default size. There the tall panel holds
    six rows and the strip and Tor list are one scroll below — reachable, and said so
    in the lane note rather than claimed to fit."""
    wiz, dock, mon = _open_pods(shell, qapp, mesh, SMALLEST)
    vp = _viewport(mon)
    shot(wiz, "running-mesh-docked-942x552")
    assert dock.tall
    assert _rows_on_screen(vp, mon.table) >= MIN_ROWS
    sa = vp.parentWidget()
    sa.ensureWidgetVisible(mon.controls_row, 0, 0)
    settle(qapp, 4)
    shot(wiz, "running-mesh-docked-942x552-scrolled")
    assert _on_screen(vp, mon.domain_btns["stop"], wiz)
    for open_b, copy_b in mon._onion_rows.values():
        assert _on_screen(vp, open_b, wiz) and _on_screen(vp, copy_b, wiz)
