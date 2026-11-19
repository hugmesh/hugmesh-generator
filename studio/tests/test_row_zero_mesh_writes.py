"""Row 0 (the mesh's own domain) EDITS its Identity and Ways in place, and the value
it edits IS the mesh's — one home, two doors (2026-10-21; the operator asked for every
tab per domain, and the domain-ui lane left row 0's sign-in and ways read-only because
a second writer would be reverted by the mesh-wide pages).

The revert was real: ``StudioWizard.collect_all()`` re-runs ``validatePage`` on every
visited page, and the Identity provider step and the Network step write the mesh's
sign-in, Tor and egress file from THEIR widgets. A row-0 write that only touched the
config was undone the moment a build or a save collected. What these pin, through a
real wizard walked from the mode screen:

* row 0's sign-in, Tor and egress land on the fields the mesh-wide steps write, the
  steps' own widgets show the new values at once, and ``collect_all()`` keeps them;
* the mesh's VPN is shown and never chosen on row 0 (it is the mesh's whole posture);
* a bad value is refused inline and changes nothing;
* the Docker route writes into the local mesh page's own controls, which are what the
  start collects;
* a route with no mesh-wide home for a value (the fleet, the text Docker route) says
  so instead of offering a control that would do nothing;
* the text screen writes the same fields as the window.
"""
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import Domain, ImageConfig                    # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig  # noqa: E402
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains          # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                       # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                          # noqa: E402
from hugmesh_studio.gui.pages import domain_services as page_mod             # noqa: E402
from hugmesh_studio.gui.pages import localmesh as lm_mod                     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                  # noqa: E402
from hugmesh_studio.tui.domain_services_step import DomainServicesScreen     # noqa: E402
from hugmesh_studio.tui.superbrand_step import session_for                   # noqa: E402

from _helpers import (advance_to, check_worklist_rows, enable_additional_domains,  # noqa: E402
                      pick_mode)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
ENTRA = "https://login.microsoftonline.com/0000-tenant/v2.0"
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-row-zero-mesh-writes"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.resize(1040, 780)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _settle(qapp, n=3):
    for _ in range(n):
        qapp.processEvents()


def _usable(w, what, *, min_w=40, min_h=14):
    assert w.isVisible(), f"{what} is not visible"
    assert w.isEnabled(), f"{what} is not enabled"
    assert w.width() >= min_w, f"{what} is {w.width()}px wide"
    assert w.height() >= min_h, f"{what} is {w.height()}px tall"


def _row_zero(wiz, qapp, rows=("omnibus.x86",)):
    """Walk a mesh flow from the mode screen (so the Identity provider and Network
    steps are VISITED, which is what makes collect_all re-run them) to the Domain
    services step, which opens on row 0."""
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, *rows)
    enable_additional_domains(wiz)
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    dom._add("shop.example", "Shop")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.current_domain() == wiz.cfg.cluster_domain
    for slug in ("idp", "network"):
        assert wiz.hasVisitedPage(wiz._page_ids[slug]), f"{slug} was not visited"
    _settle(qapp)
    assert page.brand_tabs.view is not None and page.brand_tabs.view.own
    return page


def _pick(combo, key):
    combo.setCurrentIndex(combo.findData(key))
    combo.activated.emit(combo.currentIndex())


def test_row_zero_sign_in_is_the_identity_provider_steps_and_survives_collect(wiz, qapp):
    page = _row_zero(wiz, qapp)
    tabs = page.brand_tabs
    tabs.open_tab("Identity")
    _settle(qapp)
    _usable(tabs.signin_choice, "row 0's sign-in choice", min_w=90, min_h=20)
    assert [tabs.signin_choice.itemData(i) for i in range(tabs.signin_choice.count())] \
        == ["casdoor", "entra", "aws", "oidc"]
    _pick(tabs.signin_choice, "entra")
    _settle(qapp)
    _usable(tabs.signin_issuer, "the sign-in address box", min_w=90, min_h=18)
    _usable(tabs.signin_apply, "Use this sign-in", min_w=60, min_h=20)
    assert wiz.cfg.idp == "casdoor", "an external choice must wait for its values"
    tabs.signin_issuer.setText(ENTRA)
    tabs.signin_client.setText("mesh-client")
    tabs.signin_apply.click()
    _settle(qapp)
    assert (wiz.cfg.idp, wiz.cfg.idp_issuer, wiz.cfg.idp_client_id) == (
        "entra", ENTRA, "mesh-client")
    assert tabs.signin_note.text().startswith("Saved")
    idp_page = wiz.page(wiz._page_ids["idp"])
    assert idp_page.selected_idp() == "entra"
    assert idp_page.issuer.text() == ENTRA
    wiz.collect_all()
    assert (wiz.cfg.idp, wiz.cfg.idp_issuer, wiz.cfg.idp_client_id) == (
        "entra", ENTRA, "mesh-client"), "collect_all wrote the old sign-in back"
    assert "--idp" in wiz.cfg.to_cli_args()
    # back to the built-in Casdoor: written at once, no residue
    _pick(tabs.signin_choice, "casdoor")
    _settle(qapp)
    wiz.collect_all()
    assert (wiz.cfg.idp, wiz.cfg.idp_issuer, wiz.cfg.idp_client_id) == ("casdoor", "", "")


def test_a_bad_row_zero_sign_in_is_refused_inline_and_changes_nothing(wiz, qapp):
    page = _row_zero(wiz, qapp)
    tabs = page.brand_tabs
    tabs.open_tab("Identity")
    _pick(tabs.signin_choice, "oidc")
    tabs.signin_issuer.setText("http://not-https.example")
    tabs.signin_client.setText("c")
    tabs.signin_apply.click()
    _settle(qapp)
    assert tabs.signin_note.text().startswith("Not changed")
    assert "issuer" not in tabs.signin_note.text().lower().replace("sign-in address", "")
    assert wiz.cfg.idp == "casdoor"


def test_row_zero_tor_is_the_network_steps_and_survives_collect(wiz, qapp):
    page = _row_zero(wiz, qapp)
    tabs = page.brand_tabs
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    net = wiz.page(wiz._page_ids["network"])
    # Tor: ticked here -> the Network step's Tor service, both ways round
    _usable(tabs.tor_box, "row 0's Tor tick")
    was = tabs.tor_box.isChecked()
    tabs.tor_box.click()
    _settle(qapp)
    assert net.tor_onion.isChecked() is (not was)
    wiz.collect_all()
    assert (wiz.cfg.tor_onion_service is True) is (not was)
    assert ("--with-tor" in wiz.cfg.to_cli_args()) is (not was)
    tabs.tor_box.click()
    wiz.collect_all()
    assert (wiz.cfg.tor_onion_service is True) is was
    # a mesh of NODE images has no egress VPN setting at all (the Network step offers
    # the file only when every image is a desktop): row 0 greys it with the reason
    assert tabs.egress_combo.isVisible() and not tabs.egress_combo.isEnabled()
    assert "egress VPN file is a desktop image's choice" in tabs.reach_note.text()
    assert tabs.view.set_egress("direct")[0].startswith("This mesh's images have no")


def test_on_a_desktop_mesh_row_zero_egress_is_the_network_steps(wiz, qapp, tmp_path):
    """Where the Network step DOES offer the egress VPN file (every image of the flow is
    an x86 desktop), row 0 writes it, the step's box shows it, and collect keeps it. The
    flow is entered at the Network step so that step is visited (collect re-runs it)."""
    wiz.cfg.mode, wiz.cfg.role, wiz.cfg.platform = "mesh", "laptop", "x86"
    wiz.setStartId(wiz._page_ids["network"])
    wiz.restart()
    _settle(qapp)
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert wiz.hasVisitedPage(wiz._page_ids["network"])
    _settle(qapp)
    tabs = page.brand_tabs
    assert tabs.view is not None and tabs.view.own
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    net = wiz.page(wiz._page_ids["network"])
    # egress: the VPN needs its file; a relative one is refused inline
    _usable(tabs.egress_combo, "row 0's egress choice", min_w=90, min_h=20)
    _pick(tabs.egress_combo, "vpn")
    _settle(qapp)
    assert wiz.cfg.egress_vpn == "", "the VPN choice alone must not write"
    _usable(tabs.egress_conf, "the provider file box", min_w=90, min_h=18)
    tabs.egress_conf.setText("relative.conf")
    tabs.egress_conf.editingFinished.emit()
    assert tabs.reach_note.text().startswith("Not changed")
    assert wiz.cfg.egress_vpn == ""
    conf = str(tmp_path / "provider.conf")
    tabs.egress_combo.setCurrentIndex(tabs.egress_combo.findData("vpn"))
    tabs.egress_conf_row.setEnabled(True)
    tabs.egress_conf.setText(conf)
    tabs.egress_conf.editingFinished.emit()
    _settle(qapp)
    assert wiz.cfg.egress_vpn == conf
    assert net.egress.text() == conf
    wiz.collect_all()
    assert wiz.cfg.egress_vpn == conf, "collect_all wrote the old egress back"
    _pick(tabs.egress_combo, "direct")
    wiz.collect_all()
    assert wiz.cfg.egress_vpn == ""


def test_row_zero_vpn_is_shown_not_chosen(wiz, qapp):
    page = _row_zero(wiz, qapp)
    tabs = page.brand_tabs
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    assert tabs.tailnet_combo.isVisible() and not tabs.tailnet_combo.isEnabled()
    assert tabs.tailnet_combo.currentData() == "on"
    assert "not chosen per domain" in tabs.reach_note.text()
    assert tabs.view.set_tailnet("off")[0].startswith("The mesh's VPN is not chosen")


# ── the Docker route: the local mesh page's own controls ─────────────────────────────
@pytest.fixture
def ctl(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    shim = SimpleNamespace(generator_dir=GENERATOR_DIR, localmesh_selected=True)
    page = lm_mod.LocalMeshPage(shim)
    page.resize(900, 760)
    page.show()
    page.mount_brand()
    page._seed_domains()
    page.mesh_domains.domains.append(Domain(name="shop.example", title="Shop"))
    page.domain_services.load(page.mesh_domains)
    page.take_section("domain_services", page._body)
    _settle(qapp)
    yield page
    page.close()


def test_docker_row_zero_writes_the_local_mesh_pages_controls(ctl, qapp, tmp_path):
    ds = ctl.domain_services
    tabs = ds.brand_tabs
    assert tabs.view is not None and tabs.view.own
    tabs.open_tab("Identity")
    _settle(qapp)
    _usable(tabs.signin_choice, "row 0's sign-in choice", min_w=90, min_h=20)
    _pick(tabs.signin_choice, "aws")
    tabs.signin_issuer.setText("https://cognito-idp.eu-west-1.amazonaws.com/pool")
    tabs.signin_client.setText("mesh-client")
    tabs.signin_apply.click()
    _settle(qapp)
    assert ctl.selected_idp() == "aws"
    boot = ctl.collect_bootstrap()
    assert (boot.idp, boot.idp_client_id) == ("aws", "mesh-client")
    # Tor and egress: the Mesh infrastructure ticks and the provider file
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    _usable(tabs.tor_box, "row 0's Tor tick")
    want = not ctl.service_boxes["tor"].isChecked()
    tabs.tor_box.click()
    assert ctl.service_boxes["tor"].isChecked() is want
    conf = tmp_path / "wg0.conf"
    conf.write_text("[Interface]\nAddress = 10.0.0.2/32\nPrivateKey = "
                    "aGVsbG8taGVsbG8taGVsbG8taGVsbG8taGVsbG8taGU=\n"
                    "[Peer]\nPublicKey = aGVsbG8taGVsbG8taGVsbG8taGVsbG8taGVsbG8taGU=\n"
                    "Endpoint = 192.0.2.1:51820\nAllowedIPs = 0.0.0.0/0\n")
    tabs.egress_combo.setCurrentIndex(tabs.egress_combo.findData("vpn"))
    tabs.egress_conf_row.setEnabled(True)
    tabs.egress_conf.setText(str(conf))
    tabs.egress_conf.editingFinished.emit()
    _settle(qapp)
    assert tabs.reach_note.text() and not tabs.reach_note.text().startswith("Not changed"), \
        tabs.reach_note.text()
    assert ctl.service_boxes["egress-vpn"].isChecked()
    boot = ctl.collect_bootstrap()
    assert boot.egress_vpn_conf == str(conf)
    assert "egress-vpn" in boot.effective_services()
    _pick(tabs.egress_combo, "direct")
    assert not ctl.service_boxes["egress-vpn"].isChecked()
    assert ctl.collect_bootstrap().egress_vpn_conf == ""


# ── routes with no mesh-wide home: say so, offer nothing ─────────────────────────────
def test_the_text_docker_route_says_where_row_zero_is_set(tmp_path):
    st = LocalMeshDomains(domains=[Domain(name="mesh.example"),
                                   Domain(name="shop.example")], own_name="mesh.example")
    s = session_for(SimpleNamespace(), "docker", (LocalMeshBootstrapConfig(), st),
                    str(tmp_path))
    j = SimpleNamespace(status="", generator_dir=str(tmp_path), overlay=None,
                        advance=lambda: None)
    sc = DomainServicesScreen(cfg_of=lambda _j: st, brand_session_of=lambda _j: s,
                              route="docker")
    sc.enter(j)
    assert sc._brand(j).own
    sc.feed(j, "open 1")
    sc.feed(j, f"signin entra {ENTRA} c")
    assert j.status.startswith("Not changed: The local mesh's own sign-in")
    sc.feed(j, "open 4")
    sc.feed(j, "tor on")
    assert j.status.startswith("Not changed: The local mesh's own sign-in, Tor")


def test_the_text_image_route_writes_the_same_mesh_fields(tmp_path):
    cfg = ImageConfig(mode="mesh")
    cfg.domains = [Domain(name="shop.example")]
    owner = SimpleNamespace()
    j = SimpleNamespace(status="", generator_dir=str(tmp_path), overlay=None,
                        advance=lambda: None, cfg=cfg)
    sc = DomainServicesScreen(brand_session_of=lambda _j: session_for(
        owner, "image", cfg, str(tmp_path)), route="image")
    sc.enter(j)
    assert sc._brand(j).own
    sc.feed(j, "open 1")
    assert any("signin casdoor | signin entra" in ln for ln in sc.lines(j))
    sc.feed(j, f"signin entra {ENTRA} mesh-client")
    assert (cfg.idp, cfg.idp_issuer, cfg.idp_client_id) == ("entra", ENTRA, "mesh-client")
    sc.feed(j, "signin mesh")
    assert j.status.startswith("Not changed") and cfg.idp == "entra"
    sc.feed(j, "open 4")
    sc.feed(j, "tor on")
    assert cfg.tor_onion_service is True
    sc.feed(j, "egress vpn /etc/wireguard/mesh.conf")
    assert cfg.egress_vpn == "/etc/wireguard/mesh.conf"
    sc.feed(j, "vpn off")
    assert j.status.startswith("Not changed: The mesh's VPN is not chosen")
    sc.feed(j, "egress direct")
    assert cfg.egress_vpn == ""
