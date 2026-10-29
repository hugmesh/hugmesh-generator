"""The Look tab says, truthfully, where an added domain's own look shows (theme survey
item B): served by Host on the Docker mesh when the checkout's front door serves it,
"recorded only" when it does not, and "not applied on this route yet" on the image and
Fleet routes. Looked at, not only asserted: with HUGMESH_LOOK_SHOTS set, each case is
grabbed to a PNG.
"""
from __future__ import annotations

import os
from types import SimpleNamespace

import pytest

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import brand_look                                     # noqa: E402
from hugmesh_studio.core.config import Domain, ImageConfig                     # noqa: E402
from hugmesh_studio.core.fleet import FleetConfig, FleetDomains                # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig  # noqa: E402
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains            # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                 # noqa: E402
from hugmesh_studio.gui.pages._lookeditor import LookEditor                    # noqa: E402
from hugmesh_studio.gui.pages.brand_screen import TAB_LOOK                     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                    # noqa: E402
from hugmesh_studio.tui.superbrand_step import session_for                     # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-look-served-tests"])


def _shot(widget, name: str) -> None:
    out = os.environ.get("HUGMESH_LOOK_SHOTS", "")
    if out:
        os.makedirs(out, exist_ok=True)
        widget.grab().save(os.path.join(out, f"{name}.png"))


def _settle(qapp):
    for _ in range(3):
        qapp.processEvents()


def _docker_tab(qapp, generator_dir):
    state = LocalMeshDomains(domains=[Domain(name="mesh.example"), Domain(name="shop.example")],
                             own_name="mesh.example")
    session = session_for(SimpleNamespace(), "docker",
                          (LocalMeshBootstrapConfig(), state), generator_dir)
    widget = ds_mod.DomainServicesWidget(brand_session=lambda: session, route="docker")
    widget.load(state)
    widget._step(1)                                   # the added domain
    widget.resize(1000, 900)
    widget.show()
    widget.brand_tabs.setCurrentIndex(TAB_LOOK)
    _settle(qapp)
    return state, widget, widget.brand_tabs.look_editor


def _sane(label, what):
    assert label.isVisible(), f"{what} is not shown"
    assert label.isEnabled(), f"{what} is greyed out"
    g = label.geometry()
    assert g.width() >= 200 and g.height() >= 14, f"{what} is {g.width()}x{g.height()}"


def test_docker_route_says_the_added_domains_look_is_served(qapp):
    state, widget, ed = _docker_tab(qapp, REPO)
    assert ed is not None and ed.model.mode == "override"
    assert ed.served_note.text() == brand_look.DOCKER_SERVED_SENTENCE
    # plain words on screen: no markdown backticks (round-1 skeptic concern)
    assert "`" not in ed.served_note.text()
    _sane(ed.served_note, "the served sentence")
    assert ed.path_note.isHidden() and ed.primary.isEnabled()
    _shot(widget, "docker-added-domain-look-served")
    widget.close()


def test_docker_route_on_a_checkout_without_the_door_says_recorded_only(qapp, tmp_path):
    state, widget, ed = _docker_tab(qapp, str(tmp_path))
    assert ed.served_note.text() == brand_look.DOCKER_NOT_SERVED_SENTENCE
    _sane(ed.served_note, "the recorded-only sentence")
    _shot(widget, "docker-added-domain-look-recorded-only")
    widget.close()


@pytest.mark.parametrize("path", ["image", "fleet"])
def test_image_and_fleet_say_plainly_it_is_not_applied(qapp, path):
    base = brand_look.Look({"primary": "#3355aa"})
    ed = LookEditor(brand_look.Look({}, base=base.effective()), path=path,
                    generator_dir=REPO)
    ed.resize(900, 700)
    ed.show()
    _settle(qapp)
    assert ed.path_note.text() == brand_look.DOCKER_ONLY_SENTENCE
    assert ed.path_note.text().startswith("Not applied on this route yet")
    _sane(ed.path_note, "the not-applied sentence")
    assert ed.served_note.isHidden()
    assert not ed.primary.isEnabled()
    _shot(ed, f"{path}-added-domain-look-not-applied")
    ed.close()


def _route_tab(qapp, route):
    """The image or Fleet route's Domain services page, the REAL widget, opened on the
    added domain's Look tab (the round-1 skeptic could render only the image route
    through it; this builds the Fleet session from a FleetConfig/FleetDomains pair)."""
    owner = SimpleNamespace()
    if route == "image":
        cfg = ImageConfig()
        cfg.domains = [Domain(name="shop.example", title="Shop")]
        state, source = cfg, cfg
    else:
        state = FleetDomains(domains=[Domain(name="mesh.example"),
                                      Domain(name="shop.example")],
                             own_name="mesh.example")
        source = (FleetConfig(), state)
    session = session_for(owner, route, source, REPO)
    widget = ds_mod.DomainServicesWidget(brand_session=lambda: session, route=route)
    widget.load(state)
    widget._step(1)                                   # the added domain
    widget.resize(1000, 900)
    widget.show()
    widget.brand_tabs.setCurrentIndex(TAB_LOOK)
    _settle(qapp)
    return widget, widget.brand_tabs.look_editor


@pytest.mark.parametrize("route", ["image", "fleet"])
def test_the_real_page_on_image_and_fleet_says_not_applied(qapp, route):
    widget, ed = _route_tab(qapp, route)
    assert ed is not None, f"{route}: no Look tab editor on the added domain"
    assert ed.path_note.text() == brand_look.DOCKER_ONLY_SENTENCE
    _sane(ed.path_note, f"{route}: the not-applied sentence")
    assert ed.served_note.isHidden()
    assert not ed.primary.isEnabled()
    _shot(widget, f"{route}-page-added-domain-look-not-applied")
    widget.close()


def test_the_mesh_own_look_row_has_no_where_sentence(qapp):
    ed = LookEditor(brand_look.Look({"primary": "#3355aa"}), path="docker", generator_dir=REPO)
    ed.show()
    _settle(qapp)
    assert ed.served_note.isHidden() and ed.path_note.isHidden()
    ed.close()


def test_the_real_docker_page_serves_an_added_domain_the_meshs_whole_look(qapp, tmp_path,
                                                                          monkeypatch):
    """Skeptic 2's chain, through the REAL Docker page: row 0's header background (a
    field outside the record's eight look keys) set, shop.example given its own
    primary. Its served stylesheet must carry both, as its Look tab says."""
    from hugmesh_studio.core import look_serving
    from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrap
    from hugmesh_studio.gui.pages import localmesh as lm
    from hugmesh_studio.gui.wizard import StudioWizard
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(lm.LocalMeshPage, "_probe_mesh_state", lambda self: None)
    wiz = StudioWizard(REPO)
    wiz.localmesh_selected = True
    wiz.localmesh_join_selected = False
    page = wiz.localmesh_page
    page._seed_domains()
    own = page.mesh_domains.domains[0].name
    page.mesh_domains.domains.append(Domain(name="shop.example", title="Shop"))
    page.domain_services.load(page.mesh_domains)
    wiz.setStartId(wiz._page_ids["localmesh_domain_services"])
    wiz.restart()
    wiz.show()
    _settle(qapp)
    ds = page.domain_services
    for _ in range(4):
        if ds.current_domain() == own:
            break
        ds._step(-1)
        _settle(qapp)
    tabs = ds.brand_tabs
    tabs.open_tab("Look")
    _settle(qapp)
    tabs.look_editor._write("primary", "#00aa00")
    tabs.look_editor._write("header_bg", "#123456")
    for _ in range(4):
        if ds.current_domain() == "shop.example":
            break
        ds._step(1)
        _settle(qapp)
    tabs.open_tab("Look")
    _settle(qapp)
    ed = tabs.look_editor
    assert ed.model.mode == "override"
    ed._write("primary", "#ff0000")
    _settle(qapp)
    assert ed.model.effective()["header_bg"] == "#123456"     # what the tab shows
    cfg = page.collect_bootstrap()
    assert "123456" in cfg.login_theme_css.lower()
    node = LocalMeshBootstrap(REPO, cfg)._stack_node()
    out = str(tmp_path / "gen")
    look_serving.write(out, node.superbrand_look, node.look_brands)
    served = open(os.path.join(look_serving.looks_dir(out), look_serving.HOSTS_DIRNAME,
                               "shop.example", "hug-theme.css"), encoding="utf-8").read()
    assert "#ff0000" in served.lower()
    assert "#123456" in served.lower(), "the mesh's header colour is not carried"
    wiz.close()
