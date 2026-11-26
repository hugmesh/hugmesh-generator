"""The Ways tab's "New Tor address" row on the Docker route (hugmesh-generator#652).

The renew call is faked: nothing reaches docker or a mesh. Pinned: the row is drawn only
on the Docker route, for a domain that is not the mesh's own and has its Tor tick; the
first click only asks (inline, no modal); Cancel runs nothing; the second click runs the
renew for THIS domain and shows the new address, selectable; a refusal is shown inline
and changes nothing. HUGMESH_ONION_SHOTS=<dir> saves what was measured.
"""
from __future__ import annotations

import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import onion_renew                                      # noqa: E402
from hugmesh_studio.core.config import Domain, ImageConfig                       # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig    # noqa: E402
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains              # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                   # noqa: E402
from hugmesh_studio.gui.pages.brand_screen import TAB_WAYS                       # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                      # noqa: E402
from hugmesh_studio.tui.superbrand_step import session_for                      # noqa: E402

NEW, OLD = "c" * 56 + ".onion", "a" * 56 + ".onion"


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(["onion-renew"])


@pytest.fixture(autouse=True)
def _isolated(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("HUGMESH_STUDIO_NO_ELEVATION", "1")


def _settle(qapp):
    for _ in range(4):
        qapp.processEvents()


def _shot(widget, name):
    out = os.environ.get("HUGMESH_ONION_SHOTS", "")
    if out:
        os.makedirs(out, exist_ok=True)
        widget.grab().save(os.path.join(out, f"{name}.png"))


def _ways(qapp, tmp_path, route="docker", tor=True, step=1):
    gd = tmp_path / "gen"
    (gd / "tests" / "stack").mkdir(parents=True, exist_ok=True)
    rows = [Domain(name="shop.example", title="Shop", tor=tor)]
    if route == "image":
        cfg = ImageConfig()
        cfg.mode = "mesh"
        cfg.domains = rows
        state, source = cfg, cfg
    else:
        state = LocalMeshDomains(domains=[Domain(name="mesh.example"), *rows],
                                 own_name="mesh.example")
        source = (LocalMeshBootstrapConfig(), state)
    session = session_for(SimpleNamespace(), route, source, str(gd))
    widget = ds_mod.DomainServicesWidget(brand_session=lambda: session, route=route)
    widget.load(state)
    if step:
        widget._step(step)
    widget.resize(1000, 950)
    widget.show()
    widget.brand_tabs.setCurrentIndex(TAB_WAYS)
    _settle(qapp)
    return widget, widget.brand_tabs


def _fake(calls, outcome):
    def renew(name, sid=""):
        calls.append((name, sid))
        return outcome
    return renew


def test_the_row_asks_first_then_shows_the_new_address(qapp, tmp_path):
    widget, tabs = _ways(qapp, tmp_path)
    row = tabs.onion_renew
    if not tabs.tor_box.isChecked():
        tabs.tor_box.click()            # the domain's own Tor tick, as a person sets it
        _settle(qapp)
    assert row.isVisibleTo(tabs.ways_page), "the New Tor address row is not drawn"
    calls = []
    row._renew = _fake(calls, onion_renew.RenewOutcome(True, "shop.example has a new Tor address.",
                                                       old=OLD, new=NEW))
    _shot(widget, "1-ways-tab")
    row.button.click()
    _settle(qapp)
    assert row.confirm.isVisibleTo(tabs.ways_page) and not calls, "the first click must only ask"
    assert onion_renew.CONFIRM_SENTENCE in row.confirm_text.text()
    _shot(widget, "2-confirm")
    row.cancel.click()
    _settle(qapp)
    assert not row.confirm.isVisibleTo(tabs.ways_page) and not calls
    row.button.click()
    row.go.click()
    row.wait()
    _settle(qapp)
    assert calls == [("shop.example", "")]
    assert f"https://{NEW}/" in row.status.text() and OLD in row.status.text()
    assert row.button.isEnabled()
    _shot(widget, "3-renewed")
    # the whole row fits the tab: nothing past the right edge at the default size
    right = row.mapTo(widget, row.rect().topRight()).x()
    assert right <= widget.width(), f"the row reaches past the window ({right} > {widget.width()})"


def test_a_refusal_is_shown_inline(qapp, tmp_path):
    widget, tabs = _ways(qapp, tmp_path)
    if not tabs.tor_box.isChecked():
        tabs.tor_box.click()
        _settle(qapp)
    row = tabs.onion_renew
    calls = []
    row._renew = _fake(calls, onion_renew.RenewOutcome(False, "The mesh's Tor container is not running."))
    row.button.click()
    row.go.click()
    row.wait()
    _settle(qapp)
    assert row.status.text().startswith("Not changed:")
    assert "not running" in row.status.text()


def test_no_row_without_the_tor_tick_on_the_image_route_or_on_the_mesh_own_row(qapp, tmp_path):
    widget, tabs = _ways(qapp, tmp_path / "a", tor=False)
    if tabs.tor_box.isChecked():
        tabs.tor_box.click()
        _settle(qapp)
    assert not tabs.onion_renew.isVisibleTo(tabs.ways_page)
    widget, tabs = _ways(qapp, tmp_path / "b", route="image")
    assert not tabs.onion_renew.isVisibleTo(tabs.ways_page)
    widget, tabs = _ways(qapp, tmp_path / "c", step=0)        # row 0: the mesh's own
    assert tabs.view is not None and tabs.view.own
    assert not tabs.onion_renew.isVisibleTo(tabs.ways_page)
