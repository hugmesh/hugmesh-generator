"""The Mesh desktop CLIENT image (the image wizard in cloud mode) gets the same four
Brand settings tabs on its Domain services step as the image, Docker and Fleet routes
— Identity, Look, Services, Ways to reach it — and every tab says plainly what a
client image does with its choices: nothing but keep them with the configuration.

Before this, ``DomainServicesPage._brand_session`` returned None off a mesh, so the
cloud step showed only the services table (completeness critic, 2026-10-21: "The cloud
wizard has no Identity, Look or Ways tabs at all"), while the TUI showed all four
sections on cloud with no word that the client ignores them.

What these pin, each against the real widgets:

* the cloud page draws the tab bar with the four tabs, and each of Identity, Look and
  Ways carries the client sentence (the TUI prints the same sentence);
* a sign-in or a way written on the cloud tabs lands on the domain row, and leaving
  the step writes NO brand record file (that file is the mesh's);
* the VPN a client domain inherits is the client's own Tailscale setting, not "off";
* the Go-Live pointer (a mesh device's wizard) is not offered on a client.
"""
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import brand_model                                   # noqa: E402
from hugmesh_studio.core.config import DOMAIN_IDP_OWN, Domain, ImageConfig    # noqa: E402
from hugmesh_studio.gui.pages import brand_screen as bs_mod                   # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                   # noqa: E402
from hugmesh_studio.tui import brand_step                                     # noqa: E402
from hugmesh_studio.tui.domain_services_step import DomainServicesScreen      # noqa: E402
from hugmesh_studio.tui.superbrand_step import session_for                    # noqa: E402

ENTRA = "https://login.microsoftonline.com/0000-tenant/v2.0"


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-cloud-brand-tabs"])


@pytest.fixture
def gen(tmp_path):
    (tmp_path / "brands").mkdir()
    return str(tmp_path)


def _settle(qapp, n=3):
    for _ in range(n):
        qapp.processEvents()


def _usable(w, what, *, min_w=90, min_h=20):
    assert w.isVisible(), f"{what} is not visible"
    assert w.isEnabled(), f"{what} is not enabled"
    assert w.width() >= min_w, f"{what} is {w.width()}px wide"
    assert w.height() >= min_h, f"{what} is {w.height()}px tall"


def _cloud_cfg(**kw) -> ImageConfig:
    cfg = ImageConfig(mode="cloud", role="laptop", **kw)
    cfg.domains = [Domain(name=cfg.cluster_domain, title="Mesh"),
                   Domain(name="shop.example", title="Shop")]
    return cfg


def _page(qapp, gen, cfg):
    wiz = SimpleNamespace(cfg=cfg, generator_dir=gen)
    page = ds_mod.DomainServicesPage(wiz)
    page.initializePage()
    page.resize(900, 760)
    page.show()
    _settle(qapp)
    return wiz, page


def test_the_cloud_step_draws_the_four_tabs_with_the_client_sentence(qapp, gen):
    _wiz, page = _page(qapp, gen, _cloud_cfg())
    tabs = page.brand_tabs
    _usable(tabs.bar, "the tab bar", min_w=200)
    assert [tabs.tabText(i) for i in range(tabs.count())] == [
        "Identity", "Look", "Services", "Ways to reach it"]
    expect = {bs_mod.TAB_IDENTITY: brand_step.CLIENT_SIGNIN_NOTE,
              bs_mod.TAB_LOOK: brand_step.CLIENT_LOOK_NOTE,
              bs_mod.TAB_WAYS: brand_step.CLIENT_WAYS_NOTE}
    for tab, text in expect.items():
        tabs.setCurrentIndex(tab)
        _settle(qapp)
        note = tabs.client_notes[tab]
        _usable(note, f"the client sentence on {tabs.tabText(tab)}", min_h=12)
        assert note.text() == text
    # and the Identity tab's controls are there to use on a client, too
    page._step(1)
    tabs.open_tab("Identity")
    _settle(qapp)
    _usable(tabs.signin_choice, "the sign-in choice")
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    for w, what in ((tabs.tor_box, "the Tor tick"), (tabs.tailnet_combo, "the VPN choice"),
                    (tabs.egress_combo, "the egress choice")):
        _usable(w, what, min_h=14)


def test_a_mesh_shows_no_client_sentence(qapp, gen):
    cfg = ImageConfig(mode="mesh")
    cfg.domains = [Domain(name="shop.example", title="Shop")]
    _wiz, page = _page(qapp, gen, cfg)
    tabs = page.brand_tabs
    for tab in tabs.client_notes:
        tabs.setCurrentIndex(tab)
        _settle(qapp)
        assert tabs.client_notes[tab].isHidden()
    tabs.open_tab("Ways to reach it")
    page._step(1)
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    assert tabs.ways_btn.isVisible()
    assert tabs.ways_note.text() == brand_step.WAYS_HOME


def test_cloud_tab_writes_land_on_the_row_and_no_brand_record_is_written(qapp, gen):
    cfg = _cloud_cfg()
    wiz, page = _page(qapp, gen, cfg)
    page._step(1)
    tabs = page.brand_tabs
    tabs.open_tab("Identity")
    tabs.signin_choice.setCurrentIndex(tabs.signin_choice.findData("entra"))
    tabs.signin_choice.activated.emit(tabs.signin_choice.currentIndex())
    tabs.signin_issuer.setText(ENTRA)
    tabs.signin_client.setText("client-1")
    tabs.signin_apply.click()
    tabs.open_tab("Ways to reach it")
    tabs.egress_combo.setCurrentIndex(tabs.egress_combo.findData("direct"))
    tabs.egress_combo.activated.emit(tabs.egress_combo.currentIndex())
    _settle(qapp)
    row = next(d for d in cfg.domains if d.name == "shop.example")
    assert row.idp == DOMAIN_IDP_OWN
    assert row.idp_settings.get("issuer") == ENTRA
    assert row.ways.get("egress") == {"mode": "direct"}
    assert page._brand_session().touched
    assert page.validatePage() is True
    assert not os.path.exists(brand_model.record_path()), \
        "a client image's step wrote the mesh's brand record file"
    # the domains still carry their answers after the page recorded
    assert next(d for d in wiz.cfg.domains if d.name == "shop.example").idp == DOMAIN_IDP_OWN


def test_a_client_domain_inherits_the_clients_own_vpn(qapp, gen):
    for tailscale, want in (("", "VPN: on"), (False, "VPN: off")):
        _wiz, page = _page(qapp, gen, _cloud_cfg(tailscale=tailscale))
        page._step(1)
        tabs = page.brand_tabs
        tabs.open_tab("Ways to reach it")
        _settle(qapp)
        assert tabs.reach_words.text().startswith(want), tabs.reach_words.text()


def test_the_go_live_pointer_is_not_offered_on_a_client(qapp, gen):
    _wiz, page = _page(qapp, gen, _cloud_cfg())
    page._step(1)
    tabs = page.brand_tabs
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    assert tabs.ways_btn.isHidden()
    assert tabs.ways_note.text() == ""


def test_the_text_screen_prints_the_same_client_sentences(gen):
    cfg = _cloud_cfg()
    owner = SimpleNamespace()
    j = SimpleNamespace(status="", generator_dir=gen, overlay=None, advance=lambda: None,
                        cfg=cfg)
    sc = DomainServicesScreen(brand_session_of=lambda _j: session_for(
        owner, "image", cfg, gen), route="image")
    sc.enter(j)
    sc.feed(j, "n")
    for n, text in ((1, brand_step.CLIENT_SIGNIN_NOTE), (2, brand_step.CLIENT_LOOK_NOTE),
                    (4, brand_step.CLIENT_WAYS_NOTE)):
        sc.feed(j, f"open {n}")
        assert text in sc.lines(j), f"section {n} lacks the client sentence"
    sc.feed(j, "open 4")
    assert brand_step.WAYS_HOME not in sc.lines(j)
    # a sign-in typed on the text screen lands on the same row the window writes
    sc.feed(j, "open 1")
    sc.feed(j, f"signin entra {ENTRA} client-1")
    row = next(d for d in cfg.domains if d.name == "shop.example")
    assert row.idp == DOMAIN_IDP_OWN and row.idp_settings.get("client_id") == "client-1"
    # leaving the step writes no brand record on a client
    sc.feed(j, "")
    assert not os.path.exists(brand_model.record_path())


def test_the_cloud_services_tab_says_a_client_keeps_its_ticks_only(qapp, gen):
    """The cluster's "RECORDED, NOT YET ENFORCED AT THE CLUSTER" banner and the "they
    ride the mesh manifest" help were both untrue on a client image, which has no
    cluster and writes no manifest: the client's own line replaces them, both faces."""
    from hugmesh_studio.core.domain_services import ENFORCEMENT_NOTE
    _wiz, page = _page(qapp, gen, _cloud_cfg())
    assert page.brand_tabs.current_title() == "Services"
    _usable(page.lane_note, "the client services line", min_h=12)
    assert page.lane_note.text() == brand_step.CLIENT_SERVICES_NOTE
    assert page.enforcement.isHidden() and page.help.isHidden()
    _usable(page.table, "the services table", min_w=200, min_h=60)
    # a mesh keeps the banner and the help, and has no client line
    mcfg = ImageConfig(mode="mesh")
    mcfg.domains = [Domain(name="shop.example", title="Shop")]
    _wiz, mpage = _page(qapp, gen, mcfg)
    assert not mpage.enforcement.isHidden() and not mpage.help.isHidden()
    assert mpage.lane_note.isHidden()
    # the text screen
    cfg = _cloud_cfg()
    j = SimpleNamespace(status="", generator_dir=gen, overlay=None, advance=lambda: None,
                        cfg=cfg)
    sc = DomainServicesScreen(brand_session_of=lambda _j: session_for(
        SimpleNamespace(), "image", cfg, gen), route="image")
    sc.enter(j)
    lines = sc.lines(j)
    assert brand_step.CLIENT_SERVICES_NOTE in lines
    assert ENFORCEMENT_NOTE not in lines


def test_coming_back_to_the_step_keeps_the_tab_that_was_open(qapp, gen):
    """The first entry opens on Services; Back and Next again (a second
    initializePage) must not throw away the tab the person was on (skeptic concern 2:
    the page reset to Services on every entry)."""
    for mode in ("cloud", "mesh"):
        cfg = (_cloud_cfg() if mode == "cloud"
               else ImageConfig(mode="mesh", role="backend", platform="rpi5"))
        _wiz, page = _page(qapp, gen, cfg)
        tabs = page.brand_tabs
        assert tabs.currentIndex() == bs_mod.TAB_SERVICES
        tabs.setCurrentIndex(bs_mod.TAB_WAYS)
        _settle(qapp)
        page.initializePage()
        _settle(qapp)
        assert tabs.currentIndex() == bs_mod.TAB_WAYS, mode


def test_a_mesh_image_always_joins_its_vpn_and_only_a_client_reads_its_setting():
    """Skeptic concern 1: a mesh's row-0 note says every node joins, so the mesh's
    VPN must read on even with a hand-set tailscale=False; a client reads its own."""
    from hugmesh_studio.core import domain_reach
    mesh = ImageConfig(mode="mesh", role="backend", platform="rpi5", tailscale=False)
    assert domain_reach.mesh_tailnet_default(mesh) is True
    assert domain_reach.mesh_tailnet_default(_cloud_cfg(tailscale=False)) is False
    assert domain_reach.mesh_tailnet_default(_cloud_cfg()) is True
    assert domain_reach.mesh_tailnet_default(
        ImageConfig(mode="standalone", role="laptop")) is False


def test_a_client_domains_ways_never_claim_the_node_image_sentence(qapp, gen):
    """The reach-applied lane gave every route its own sentence under the Ways
    controls; on a client (route 'image' in the session) that was the NODE image's
    "a node image's private network ... cover the whole computer". A client gets its
    own sentence, in the window and on the text screen."""
    _wiz, page = _page(qapp, gen, _cloud_cfg())
    page._step(1)
    tabs = page.brand_tabs
    tabs.open_tab("Ways to reach it")
    _settle(qapp)
    assert tabs.reach_note.text() == brand_step.CLIENT_REACH_EFFECT
    _usable(tabs.reach_note, "the client reach sentence", min_w=200, min_h=12)
    view = tabs.view
    text = "\n".join(brand_step.ways_lines(view))
    assert brand_step.CLIENT_REACH_EFFECT in text
    assert "a node image's private network" not in text
    assert "a node image's private network" not in tabs.reach_note.text()
