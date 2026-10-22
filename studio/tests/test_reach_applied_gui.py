"""The Ways tab tells the truth about a domain's own VPN and egress, and what it says
on the Docker route is what the start does (2026-10-21 round 2; core/reach_apply).

Driven through the real widgets: the Docker route's LocalMeshPage with its Domain
services step, and the image route's DomainServicesPage. Every note checked here is
visible, enabled and of a usable size, and is rendered to a PNG
(HUGMESH_REACH_SHOTS=<dir> keeps them; otherwise they go to the test's tmp dir).
"""
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import reach_apply                                    # noqa: E402
from hugmesh_studio.core.config import Domain, ImageConfig                     # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrap        # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                 # noqa: E402
from hugmesh_studio.gui.pages import localmesh as lm_mod                       # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                    # noqa: E402
from hugmesh_studio.tui import brand_step                                      # noqa: E402

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_WG = ("[Interface]\nPrivateKey = x=\nAddress = 10.2.0.2/32\n"
       "[Peer]\nPublicKey = y=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51820\n")


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-reach-applied"])


def _settle(qapp, n=4):
    for _ in range(n):
        qapp.processEvents()


def _scroll_to(w, qapp):
    """Bring ``w`` into its scroll area's viewport, as a person would scroll to it."""
    p = w.parentWidget()
    while p is not None:
        if isinstance(p, QtWidgets.QScrollArea):
            p.ensureWidgetVisible(w, 0, 0)
        p = p.parentWidget()
    _settle(qapp)


def _usable(w, what, *, min_w=200, min_h=20):
    assert w.isVisible(), f"{what} is not visible"
    assert not w.visibleRegion().isEmpty(), f"{what} is scrolled out of sight"
    assert w.isEnabled(), f"{what} is not enabled"
    assert w.width() >= min_w, f"{what} is {w.width()}px wide"
    assert w.height() >= min_h, f"{what} is {w.height()}px tall"


def _shot(widget, tmp_path, name) -> str:
    out = os.environ.get("HUGMESH_REACH_SHOTS") or str(tmp_path)
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, name)
    assert widget.grab().save(path), path
    assert os.path.getsize(path) > 1000
    return path


@pytest.fixture
def ctl(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    shim = SimpleNamespace(generator_dir=GENERATOR_DIR, localmesh_selected=True)
    page = lm_mod.LocalMeshPage(shim)
    page.resize(900, 900)
    page.show()
    page.mount_brand()
    yield page
    page.close()


def _ways_for(ctl, qapp, name):
    ds = ctl.domain_services
    ds._step(-99)
    ds._step(ds._names.index(name))
    tabs = ds.brand_tabs
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    assert tabs.view is not None and tabs.view.name == name
    return tabs


def test_the_docker_ways_tab_says_applied_and_the_start_carries_it(ctl, qapp, tmp_path):
    conf = tmp_path / "shop-wg0.conf"
    conf.write_text(_WG)
    ctl._seed_domains()
    ctl.mesh_domains.domains += [
        Domain(name="shop.example", title="Shop", optional_services=["tuwunel"]),
        Domain(name="blog.example", title="Blog", optional_services=["phpbb"])]
    ctl.domains_table.fill(ctl.mesh_domains.domains, ctl.mesh_domains.own_name)
    ctl.domain_services.load(ctl.mesh_domains)
    ctl.take_section("domain_services", ctl._body)
    _settle(qapp)
    tabs = _ways_for(ctl, qapp, "shop.example")
    # choose an egress VPN with this domain's own provider file, through the controls
    tabs.egress_combo.setCurrentIndex(tabs.egress_combo.findData("vpn"))
    tabs.egress_combo.activated.emit(tabs.egress_combo.currentIndex())
    tabs.egress_conf.setText(str(conf))
    tabs.egress_conf.editingFinished.emit()
    _settle(qapp)
    note = tabs.reach_note.text()
    assert note == tabs.view.reach_effect(), "window and text screen say one thing"
    assert note.startswith("Egress: applied") and "shop-wg0.conf" in note
    assert reach_apply.DOCKER_TAILNET_NOT_APPLIED in note
    assert reach_apply.KIND_NOT_APPLIED in note
    assert brand_step.REACH_RECORDED_ONLY not in note
    _scroll_to(tabs.reach_note, qapp)
    _usable(tabs.reach_note, "the Ways note")
    _shot(ctl, tmp_path, "docker-ways-shop-applied.png")
    _shot(tabs.reach_box, tmp_path, "docker-ways-shop-applied-box.png")
    # the start: the page's own configuration carries the domain's file to the stack
    boot = LocalMeshBootstrap(GENERATOR_DIR, ctl.collect_bootstrap())
    env = boot._stack_node()._build_env(write_overlays=False)
    assert env["EGRESS_VPN"] == "1"
    assert env["EGRESS_VPN_CONF"] == str(conf)
    assert "PER-DOMAIN EGRESS" in boot.plan()
    # a domain that runs no Mastodon is told its egress is not applied
    tabs = _ways_for(ctl, qapp, "blog.example")
    tabs.egress_combo.setCurrentIndex(tabs.egress_combo.findData("direct"))
    tabs.egress_combo.activated.emit(tabs.egress_combo.currentIndex())
    tabs.tailnet_combo.setCurrentIndex(tabs.tailnet_combo.findData("on"))
    tabs.tailnet_combo.activated.emit(tabs.tailnet_combo.currentIndex())
    _settle(qapp)
    note = tabs.reach_note.text()
    assert note.startswith("Egress: not applied for this domain")
    assert "asks to be on the VPN" in note
    _scroll_to(tabs.reach_note, qapp)
    _usable(tabs.reach_note, "the Ways note")
    _shot(ctl, tmp_path, "docker-ways-blog-not-applied.png")
    _shot(tabs.reach_box, tmp_path, "docker-ways-blog-not-applied-box.png")
    # production with an auth key: the mesh's VPN container joins, and a domain that
    # asked to stay off is told it does anyway (the page's typed key reaches the note)
    tabs.tailnet_combo.setCurrentIndex(tabs.tailnet_combo.findData("off"))
    tabs.tailnet_combo.activated.emit(tabs.tailnet_combo.currentIndex())
    ctl.env_prod.setChecked(True)
    ctl.boot_auth_key.setText("tskey-auth-example")
    tabs = _ways_for(ctl, qapp, "blog.example")
    assert "asks to stay off the VPN; the mesh's VPN container joins anyway" in (
        tabs.reach_note.text())


def test_the_image_ways_tab_says_an_image_applies_neither(qapp, tmp_path):
    cfg = ImageConfig()
    cfg.mode = "mesh"
    cfg.domains = [Domain(name="shop.example", title="Shop",
                          ways={"egress": {"mode": "direct"}})]
    wiz = SimpleNamespace(cfg=cfg, generator_dir=str(tmp_path))
    (tmp_path / "brands").mkdir()
    page = ds_mod.DomainServicesPage(wiz)
    page.initializePage()
    page.resize(900, 900)
    page.show()
    _settle(qapp)
    page._step(1)
    tabs = page.brand_tabs
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    assert tabs.view.name == "shop.example"
    assert tabs.reach_note.text() == reach_apply.ROUTE_NOT_APPLIED["image"]
    _scroll_to(tabs.reach_note, qapp)
    _usable(tabs.reach_note, "the Ways note")
    _shot(page, tmp_path, "image-ways-shop-not-applied.png")
    page.close()
