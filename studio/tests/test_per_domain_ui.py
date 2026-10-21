"""Each domain's Brand settings tabs carry its OWN look, sign-in, services and ways
(2026-10-21; the operator, verbatim: "The local services option doesn't make any
sense, we should be using the per domain services configuration so please remove
it", "Make sure teh identity provider step is also added per domain", "each domain
in each wizard should also have a secion for themes to be added", "the theme
selection shoujld be there instead of where it is now", and "tor/vpn + egress config"
per domain).

What these pin, each against the real widgets a person uses (and each red when the
production line it names is reverted):

* row 0 (the mesh's own domain) has an EDITABLE Look tab on every route, over the
  session's own look model — the one place a theme is chosen;
* an added domain's Identity tab writes its sign-in through ``set_domain_signin``
  (its own Casdoor, or its own Entra / Cognito / OIDC), refusing inline;
* its Ways tab writes Tor (in step with the Services tab's front door), VPN and
  egress through ``brand_model.set_ways``;
* the Domains table never flips a sign-in back, and a flip clears what the old
  choice carried;
* the Docker route's mesh-wide services table holds the mesh's own infrastructure
  only, and the Docker route's per-domain step has the tabs at all;
* every new control is visible, enabled and of a size a person can use.
"""
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import local_services                                # noqa: E402
from hugmesh_studio.core.config import (DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN,  # noqa: E402
                                        Domain, ImageConfig)
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig  # noqa: E402
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains          # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                # noqa: E402
from hugmesh_studio.gui.pages import domains as dom_mod                       # noqa: E402
from hugmesh_studio.gui.pages import localmesh as lm_mod                      # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                   # noqa: E402
from hugmesh_studio.tui import brand_step                                     # noqa: E402
from hugmesh_studio.tui.domain_services_step import DomainServicesScreen      # noqa: E402
from hugmesh_studio.tui.superbrand_step import session_for                    # noqa: E402

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENTRA = "https://login.microsoftonline.com/0000-tenant/v2.0"


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-per-domain-ui"])


@pytest.fixture
def gen(tmp_path):
    (tmp_path / "brands").mkdir()
    return str(tmp_path)


def _settle(qapp, n=3):
    for _ in range(n):
        qapp.processEvents()


def _usable(w, what, *, min_w=90, min_h=20):
    """Visible, enabled and of a size a person can use — a control a test can set but
    nobody can see is the #647 failure this guards against."""
    assert w.isVisible(), f"{what} is not visible"
    assert w.isEnabled(), f"{what} is not enabled"
    assert w.width() >= min_w, f"{what} is {w.width()}px wide"
    assert w.height() >= min_h, f"{what} is {w.height()}px tall"


def _image_page(qapp, gen, rows=None):
    cfg = ImageConfig()
    cfg.mode = "mesh"
    cfg.domains = rows if rows is not None else [Domain(name="shop.example", title="Shop"),
                                                Domain(name="blog.example", title="Blog")]
    wiz = SimpleNamespace(cfg=cfg, generator_dir=gen)
    page = ds_mod.DomainServicesPage(wiz)
    page.initializePage()
    page.resize(736, 736)
    page.show()
    _settle(qapp)
    return wiz, page


# ── 1. row 0's Look tab is the one place a theme is chosen ──────────────────────────
def test_row_zero_has_an_editable_look_tab_that_writes_the_mesh_look(qapp, gen):
    wiz, page = _image_page(qapp, gen)
    tabs = page.brand_tabs
    assert tabs.view.own, "the walk opens on the mesh's own domain"
    tabs.open_tab("Look")
    _settle(qapp)
    ed = tabs.look_editor
    assert ed is not None
    _usable(ed, "row 0's look editor", min_w=300, min_h=150)
    assert ed.model is session_for(wiz, "image", wiz.cfg, gen).look
    assert ed.model.mode == "design"
    for field in ("primary", "preset"):
        _usable(ed.controls[field], f"row 0's {field} control")
    ed.primary.setText("#336699")
    ed.primary.editingFinished.emit()
    # the image route's look lives on the config's login_* fields (CfgLook)
    assert wiz.cfg.login_primary_color == "#336699"
    assert tabs.look_note.text().startswith("This is the mesh's own look")


def test_an_added_domain_keeps_its_override_editor_and_the_d18_rule(qapp, gen):
    _wiz, page = _image_page(qapp, gen)
    page._step(1)
    tabs = page.brand_tabs
    tabs.open_tab("Look")
    _settle(qapp)
    ed = tabs.look_editor
    assert ed.model.mode == "override"
    # the image route cannot show a brand's own look: drawn, disabled, with the reason
    assert not ed.path_note.isHidden()


# ── 2. the per-domain identity provider ─────────────────────────────────────────────
def test_the_identity_tab_writes_a_domains_own_provider_and_refuses_inline(qapp, gen):
    wiz, page = _image_page(qapp, gen)
    page._step(1)                                       # shop.example
    tabs = page.brand_tabs
    tabs.open_tab("Identity")
    _settle(qapp)
    _usable(tabs.signin_choice, "the sign-in choice")
    assert tabs.signin_fields.isHidden(), "no provider fields while it inherits"
    row = wiz.cfg.domains[0]
    # pick Entra: the fields appear, nothing is written until 'Use this sign-in'
    tabs.signin_choice.setCurrentIndex(tabs.signin_choice.findData("entra"))
    tabs.signin_choice.activated.emit(tabs.signin_choice.currentIndex())
    _settle(qapp)
    for w, what in ((tabs.signin_issuer, "the sign-in address box"),
                    (tabs.signin_client, "the client id box"),
                    (tabs.signin_keys, "the key address box")):
        _usable(w, what)
    _usable(tabs.signin_apply, "Use this sign-in", min_w=60, min_h=24)
    assert row.idp == DOMAIN_IDP_SUPERDOMAIN and row.idp_settings == {}
    # a refusal: said inline, nothing written, the typed values kept
    tabs.signin_issuer.setText("http://not-tls.example")
    tabs.signin_client.setText("client-1")
    tabs.signin_apply.click()
    assert tabs.signin_note.text().startswith("Not changed")
    assert "issuer" not in tabs.signin_note.text().lower()
    assert row.idp == DOMAIN_IDP_SUPERDOMAIN and row.idp_settings == {}
    assert tabs.signin_issuer.text() == "http://not-tls.example"
    # the fix is written through set_domain_signin
    tabs.signin_issuer.setText(ENTRA)
    tabs.signin_apply.click()
    assert row.idp == DOMAIN_IDP_OWN
    assert row.idp_settings == {"provider": "entra", "issuer": ENTRA,
                                "client_id": "client-1"}
    assert "Azure Entra ID" in tabs.signin_now.text()
    # back to the mesh's: one pick, written at once, settings cleared
    tabs.signin_choice.setCurrentIndex(tabs.signin_choice.findData("mesh"))
    tabs.signin_choice.activated.emit(tabs.signin_choice.currentIndex())
    assert row.idp == DOMAIN_IDP_SUPERDOMAIN and row.idp_settings == {}


def test_one_sign_in_address_cannot_be_two_domains(qapp, gen):
    wiz, page = _image_page(qapp, gen)
    shop, blog = wiz.cfg.domains
    view = brand_step.brand_view(session_for(wiz, "image", wiz.cfg, gen), "shop.example")
    assert view.set_signin("oidc", ENTRA, "c1") == []
    other = brand_step.brand_view(session_for(wiz, "image", wiz.cfg, gen), "blog.example")
    problems = other.set_signin("oidc", ENTRA, "c2")
    assert problems and "one address can only be one brand" in problems[0]
    assert blog.idp == DOMAIN_IDP_SUPERDOMAIN


def test_row_zero_shows_the_mesh_sign_in_it_inherits_and_where_it_is_chosen(qapp, gen):
    wiz, page = _image_page(qapp, gen)
    wiz.cfg.idp, wiz.cfg.idp_issuer, wiz.cfg.idp_client_id = "aws", \
        "https://cognito-idp.eu-west-1.amazonaws.com/pool", "mesh-client"
    page._show()
    tabs = page.brand_tabs
    tabs.open_tab("Identity")
    _settle(qapp)
    assert tabs.view.own
    assert "AWS Cognito" in tabs.signin_now.text()
    assert "inherited from the mesh" in tabs.signin_now.text()
    assert tabs.signin_choice.isHidden()
    assert "Identity provider" in tabs.signin_note.text()


def test_row_zero_ways_tab_does_not_show_a_tor_tick_that_reads_off(qapp, gen):
    """Domain-ui skeptic 3: row 0's Ways tab showed a greyed, UNTICKED Tor box even with
    the mesh's Tor on. Row 0's onion is the mesh's own Tor (set on Mesh infrastructure
    or the Network step), so the box is not shown there and the note says so; an added
    domain still gets its own, usable tick."""
    wiz, page = _image_page(qapp, gen)
    wiz.cfg.tor_onion_service = True
    page._show()
    tabs = page.brand_tabs
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    assert tabs.view.own
    assert tabs.tor_box.isHidden()
    assert "the mesh's own Tor address" in tabs.reach_note.text()
    page._step(1)                                       # shop.example
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    assert not tabs.view.own and not tabs.tor_box.isHidden()
    _usable(tabs.tor_box, "the Tor tick", min_w=40, min_h=14)


# ── 3. Tor, VPN and egress per domain ───────────────────────────────────────────────
def test_the_ways_tab_writes_vpn_and_egress_and_tor_follows_the_front_door(qapp, gen):
    wiz, page = _image_page(qapp, gen)
    page._step(1)                                       # shop.example
    tabs = page.brand_tabs
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    for w, what in ((tabs.tailnet_combo, "the VPN choice"),
                    (tabs.egress_combo, "the egress choice")):
        _usable(w, what)
    _usable(tabs.tor_box, "the Tor tick", min_w=40, min_h=14)
    row = wiz.cfg.domains[0]
    tabs.tailnet_combo.setCurrentIndex(tabs.tailnet_combo.findData("off"))
    tabs.tailnet_combo.activated.emit(tabs.tailnet_combo.currentIndex())
    assert row.ways["tailnet"] is False
    assert "this domain's own" in tabs.reach_words.text()
    # egress through a VPN: the file box comes alive; a relative path is refused
    tabs.egress_combo.setCurrentIndex(tabs.egress_combo.findData("vpn"))
    tabs.egress_combo.activated.emit(tabs.egress_combo.currentIndex())
    assert row.ways["egress"] == {"mode": "vpn"}
    _usable(tabs.egress_conf, "the provider file box")
    tabs.egress_conf.setText("relative.conf")
    tabs.egress_conf.editingFinished.emit()
    assert tabs.reach_note.text().startswith("Not changed")
    assert row.ways["egress"] == {"mode": "vpn"}
    tabs.egress_conf.setText("/etc/wireguard/provider.conf")
    tabs.egress_conf.editingFinished.emit()
    assert row.ways["egress"] == {"mode": "vpn", "conf": "/etc/wireguard/provider.conf"}
    # inherit again removes the key
    tabs.tailnet_combo.setCurrentIndex(tabs.tailnet_combo.findData("inherit"))
    tabs.tailnet_combo.activated.emit(tabs.tailnet_combo.currentIndex())
    assert "tailnet" not in row.ways
    # Tor: ONE choice with the Services tab's front door, both ways round
    tabs.tor_box.click()
    assert page.tor_front_door("shop.example") is True
    assert page._tor_box.isChecked()
    page._tor_box.setChecked(False)
    assert not tabs.tor_box.isChecked()
    page._record(wiz.cfg)
    assert row.tor is False


def test_row_zero_ways_are_the_meshs_and_say_so(qapp, gen):
    _wiz, page = _image_page(qapp, gen)
    tabs = page.brand_tabs
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    assert tabs.view.own
    assert not tabs.tailnet_combo.isEnabled() and not tabs.tor_box.isEnabled()
    assert "mesh's own domain" in tabs.reach_note.text()


# ── 4. the Domains table never flips a sign-in back ─────────────────────────────────
def test_the_domains_table_keeps_an_own_provider_and_a_flip_clears_it(qapp):
    rows = [Domain(name="shop.example", title="Shop", idp=DOMAIN_IDP_OWN,
                   idp_settings={"provider": "entra", "issuer": ENTRA, "client_id": "c"})]
    state = LocalMeshDomains(domains=[Domain(name="mesh.example")] + rows,
                             own_name="mesh.example")
    table = dom_mod.DomainsTableWidget(cfg=lambda: state)
    table.fill(state.domains, state.own_name)
    added, _ca = table.rows()
    assert added[0].idp_settings["provider"] == "entra", "an unchanged row keeps it"
    combo = next(table.table.cellWidget(r, dom_mod._COL_IDP)
                 for r in range(table.table.rowCount()) if not table.is_own_row(r))
    combo.setCurrentIndex(combo.findData(DOMAIN_IDP_SUPERDOMAIN))
    added, _ca = table.rows()
    assert added[0].idp == DOMAIN_IDP_SUPERDOMAIN and added[0].idp_settings == {}


def test_a_stale_sign_in_cell_is_refreshed_from_the_row(qapp):
    state = LocalMeshDomains(domains=[Domain(name="mesh.example"),
                                      Domain(name="shop.example", title="Shop")],
                             own_name="mesh.example")
    table = dom_mod.DomainsTableWidget(cfg=lambda: state)
    table.fill(state.domains, state.own_name)
    # the Domain services step's Identity tab wrote an own provider meanwhile
    state.domains[1].idp = DOMAIN_IDP_OWN
    state.domains[1].idp_settings = {"provider": "oidc", "issuer": ENTRA, "client_id": "c"}
    table._refresh_services_cells()
    added, _ca = table.rows()
    assert added[0].idp == DOMAIN_IDP_OWN and added[0].idp_settings["provider"] == "oidc"


# ── 5. the Docker route ─────────────────────────────────────────────────────────────
@pytest.fixture
def ctl(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    shim = SimpleNamespace(generator_dir=GENERATOR_DIR, localmesh_selected=True)
    page = lm_mod.LocalMeshPage(shim)
    page.resize(736, 736)
    page.show()
    page.mount_brand()
    yield page
    page.close()


def test_the_docker_services_step_is_the_meshs_infrastructure_only(ctl):
    assert set(ctl.service_boxes) == set(local_services.mesh_plane_slugs())
    for slug in local_services.domain_local_slugs():
        assert slug not in ctl.service_boxes
    box = ctl.findChild(QtWidgets.QGroupBox, "mesh_infra_box")
    assert box.title() == lm_mod.MESH_INFRA_TITLE
    assert lm_mod.LocalMeshServicesPage.TITLE == "Mesh infrastructure"


def test_the_docker_domain_step_has_the_four_tabs_and_row_zero_themes_the_mesh(ctl, qapp):
    ctl._seed_domains()
    ctl.domain_services.load(ctl.mesh_domains)
    ctl.take_section("domain_services", ctl._body)
    _settle(qapp)
    tabs = ctl.domain_services.brand_tabs
    assert tabs.tabBar().isVisibleTo(ctl), "the Docker route's step has the tabs"
    assert tabs.view is not None and tabs.view.own
    tabs.open_tab("Look")
    _settle(qapp)
    ed = tabs.look_editor
    assert ed.model is ctl.mesh_look() and ed.isEnabled()
    ed.primary.setText("#e91e63")
    ed.primary.editingFinished.emit()
    cfg = ctl.collect_bootstrap()
    assert "#e91e63" in cfg.login_theme_css.lower()
    assert cfg.superbrand["look"]["primary"] == "#e91e63"


def test_the_docker_identity_tab_checks_against_the_pages_own_sign_in(ctl, qapp):
    ctl._seed_domains()
    ctl.mesh_domains.domains.append(Domain(name="shop.example", title="Shop"))
    ctl.domain_services.load(ctl.mesh_domains)
    # the mesh's own provider on the IdP step: an own domain may not reuse its address
    ctl.idp.setCurrentIndex(ctl.idp.findData("oidc"))
    ctl.idp_issuer.setText(ENTRA)
    ctl.idp_client_id.setText("mesh")
    ctl.domain_services._step(1)
    view = ctl.domain_services.brand_tabs.view
    problems = view.set_signin("oidc", ENTRA, "c")
    assert problems and "the mesh's own" in problems[0]
    assert view.set_signin("oidc", "https://id.shop.example", "c") == []
    rows = ctl.collect_bootstrap().domains
    shop = next(r for r in rows if r["name"] == "shop.example")
    assert shop["idp"] == "own" and shop["idp_settings"]["provider"] == "oidc"


# ── 6. the text screens do the same through the same model ──────────────────────────
def test_the_text_screen_and_the_window_write_the_same_rows(qapp, gen):
    def _state():
        return LocalMeshDomains(domains=[Domain(name="mesh.example"),
                                         Domain(name="shop.example", title="Shop")],
                                own_name="mesh.example")
    # window
    st_w = _state()
    s_w = session_for(SimpleNamespace(), "docker", (LocalMeshBootstrapConfig(), st_w), gen)
    w = ds_mod.DomainServicesWidget(brand_session=lambda: s_w, route="docker")
    w.load(st_w)
    w._step(1)
    tabs = w.brand_tabs
    tabs.signin_choice.setCurrentIndex(tabs.signin_choice.findData("aws"))
    tabs.signin_issuer.setText("https://cognito-idp.eu-west-1.amazonaws.com/p")
    tabs.signin_client.setText("c")
    tabs.signin_apply.click()
    tabs.tailnet_combo.setCurrentIndex(tabs.tailnet_combo.findData("on"))
    tabs.tailnet_combo.activated.emit(tabs.tailnet_combo.currentIndex())
    tabs.egress_combo.setCurrentIndex(tabs.egress_combo.findData("direct"))
    tabs.egress_combo.activated.emit(tabs.egress_combo.currentIndex())
    # text
    st_t = _state()
    s_t = session_for(SimpleNamespace(), "docker", (LocalMeshBootstrapConfig(), st_t), gen)
    j = SimpleNamespace(status="", generator_dir=gen, overlay=None, advance=lambda: None)
    sc = DomainServicesScreen(cfg_of=lambda _j: st_t, brand_session_of=lambda _j: s_t,
                              route="docker")
    sc.enter(j)
    sc.feed(j, "n")
    sc.feed(j, "open 1")
    sc.feed(j, "signin aws https://cognito-idp.eu-west-1.amazonaws.com/p c")
    sc.feed(j, "open 4")
    sc.feed(j, "vpn on")
    sc.feed(j, "egress direct")
    a, b = st_w.by_name("shop.example"), st_t.by_name("shop.example")
    assert (a.idp, a.idp_settings, a.ways) == (b.idp, b.idp_settings, b.ways)
    assert a.ways == {"tailnet": True, "egress": {"mode": "direct"}}
