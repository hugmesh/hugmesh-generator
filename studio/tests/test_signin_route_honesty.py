"""An added domain's own sign-in says, on screen, what THIS route does with it.

A built image and a Fleet build keep a domain's own Casdoor / Entra ID / Cognito / OIDC
choice without applying it (docs/DOMAIN-IDP.md: no builder takes it, and the
casdoor-domains element writer that would read it is not built), so the Identity tab
says so in the Look tab's orange, the way the Look tab says a domain's own look is not
applied there. The Docker route says what its start stands up, and that the DevOps
(kind) lane does not. Row 0 (the mesh's own sign-in) and a client image say neither.
The text screen prints the same sentence (GUI/TUI parity), and the Domains step's
'Own' help no longer promises a Casdoor "provisioned just for it" on an image.

Looked at, not only asserted: with HUGMESH_SIGNIN_SHOTS set, each route's tab is
grabbed to a PNG.
"""
from __future__ import annotations

import os
from types import SimpleNamespace

import pytest

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import (Domain, ImageConfig,                      # noqa: E402
                                        OWN_SIGNIN_NOT_APPLIED_ON_IMAGE)
from hugmesh_studio.core.fleet import FleetConfig, FleetDomains                  # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig    # noqa: E402
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains              # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                   # noqa: E402
from hugmesh_studio.gui.pages import domains as dom_mod                          # noqa: E402
from hugmesh_studio.gui.pages.brand_screen import TAB_IDENTITY                   # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                      # noqa: E402
from hugmesh_studio.tui import brand_step                                        # noqa: E402
from hugmesh_studio.tui.superbrand_step import session_for                      # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ORANGE = "#a65d00"


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-signin-route-honesty"])


def _settle(qapp):
    for _ in range(3):
        qapp.processEvents()


def _shot(widget, name: str) -> None:
    out = os.environ.get("HUGMESH_SIGNIN_SHOTS", "")
    if out:
        os.makedirs(out, exist_ok=True)
        widget.grab().save(os.path.join(out, f"{name}.png"))


def _sane(label, what):
    """Visible, enabled and of a size a person can read."""
    assert label.isVisible(), f"{what} is not shown"
    assert label.isEnabled(), f"{what} is greyed out"
    g = label.geometry()
    assert g.width() >= 300 and g.height() >= 28, f"{what} is {g.width()}x{g.height()}"


def _session(route, cloud=False):
    """The REAL Domain services widget of ``route``, its session and its state."""
    owner = SimpleNamespace()
    if route == "image":
        cfg = ImageConfig()
        cfg.mode = "cloud" if cloud else "mesh"
        cfg.domains = [Domain(name="shop.example", title="Shop")]
        state, source = cfg, cfg
    elif route == "fleet":
        state = FleetDomains(domains=[Domain(name="mesh.example"),
                                      Domain(name="shop.example")],
                             own_name="mesh.example")
        source = (FleetConfig(), state)
    else:
        state = LocalMeshDomains(domains=[Domain(name="mesh.example"),
                                          Domain(name="shop.example")],
                                 own_name="mesh.example")
        source = (LocalMeshBootstrapConfig(), state)
    return session_for(owner, route, source, REPO), state


def _identity_tab(qapp, route, *, step=1, cloud=False):
    session, state = _session(route, cloud=cloud)
    widget = ds_mod.DomainServicesWidget(brand_session=lambda: session, route=route)
    widget.load(state)
    if step:
        widget._step(step)
    widget.resize(1000, 900)
    widget.show()
    widget.brand_tabs.setCurrentIndex(TAB_IDENTITY)
    _settle(qapp)
    return widget, widget.brand_tabs


def _pick(qapp, tabs, key):
    tabs.signin_choice.setCurrentIndex(tabs.signin_choice.findData(key))
    tabs.signin_choice.activated.emit(tabs.signin_choice.currentIndex())
    _settle(qapp)


# ── the window ────────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("route", ["image", "fleet"])
def test_image_and_fleet_say_a_domains_own_sign_in_is_not_applied(qapp, route):
    widget, tabs = _identity_tab(qapp, route)
    assert not tabs.view.own, "the tab is on the added domain"
    note = tabs.signin_route_note
    assert note.text() == brand_step.SIGNIN_NOT_APPLIED[route]
    assert note.text().startswith("Not applied on this route yet")
    assert "docs/DOMAIN-IDP.md" in note.text()
    _sane(note, f"{route}: the not-applied sign-in sentence")
    assert ORANGE in note.styleSheet(), "said in the Look tab's orange"
    # picking its own Casdoor is still recorded ('Saved: ...'), and the line stays
    _pick(qapp, tabs, "casdoor")
    assert tabs.signin_note.text().startswith("Saved: ")
    assert "own Casdoor" in tabs.signin_note.text()
    _sane(tabs.signin_route_note, f"{route}: the sentence after 'Its own Casdoor'")
    assert tabs.signin_route_note.text() == brand_step.SIGNIN_NOT_APPLIED[route]
    _shot(widget, f"{route}-identity-own-casdoor-not-applied")
    # and an external provider the same: the fields show, the sentence stays
    _pick(qapp, tabs, "entra")
    _sane(tabs.signin_route_note, f"{route}: the sentence with Entra picked")
    _shot(widget, f"{route}-identity-entra-not-applied")
    widget.close()


def test_the_docker_route_says_what_its_start_applies_and_that_kind_does_not(qapp):
    widget, tabs = _identity_tab(qapp, "docker")
    assert not tabs.view.own
    note = tabs.signin_route_note
    assert note.text() == brand_step.SIGNIN_DOCKER_APPLIED
    assert "kind" in note.text() and "does not apply it" in note.text()
    _sane(note, "docker: the applied sign-in sentence")
    assert ORANGE not in note.styleSheet(), "Docker applies it: not the warning colour"
    _pick(qapp, tabs, "casdoor")
    assert tabs.signin_note.text().startswith("Saved: ")
    _sane(tabs.signin_route_note, "docker: the sentence after 'Its own Casdoor'")
    _shot(widget, "docker-identity-own-casdoor-applied")
    widget.close()


@pytest.mark.parametrize("route", ["image", "fleet", "docker"])
def test_row_zero_says_no_route_sentence(qapp, route):
    widget, tabs = _identity_tab(qapp, route, step=0)
    assert tabs.view.own
    assert tabs.signin_route_note.isHidden()
    widget.close()


def test_a_client_image_keeps_its_own_client_sentence_only(qapp):
    widget, tabs = _identity_tab(qapp, "image", cloud=True)
    assert tabs.view.client_image()
    assert tabs.signin_route_note.isHidden()
    widget.close()


# ── the text screen says the same (GUI/TUI parity) ────────────────────────────────────
@pytest.mark.parametrize("route", ["image", "fleet", "docker"])
def test_the_text_screen_prints_the_same_sentence_as_the_window(qapp, route):
    widget, tabs = _identity_tab(qapp, route)
    lines = brand_step.identity_lines(tabs.view)
    assert tabs.signin_route_note.text() in lines
    own_widget, own_tabs = _identity_tab(qapp, route, step=0)
    own_lines = brand_step.identity_lines(own_tabs.view)
    for sentence in (*brand_step.SIGNIN_NOT_APPLIED.values(),
                     brand_step.SIGNIN_DOCKER_APPLIED):
        assert sentence not in own_lines, "row 0 is the mesh's own sign-in"
    widget.close()
    own_widget.close()


# ── the Domains step's 'Own' help, image route ────────────────────────────────────────
def test_the_domains_step_no_longer_promises_a_provisioned_casdoor(qapp, tmp_path):
    cfg = ImageConfig()
    cfg.mode = "mesh"
    wiz = SimpleNamespace(cfg=cfg, generator_dir=str(tmp_path),
                          currentIdChanged=SimpleNamespace(connect=lambda *_: None),
                          currentPage=lambda: None)
    page = dom_mod.DomainsPage(wiz)
    assert OWN_SIGNIN_NOT_APPLIED_ON_IMAGE in page.table_help.text()
    texts = [page.table_help.text(),
             page.table.horizontalHeaderItem(dom_mod._COL_IDP).toolTip(),
             *(tip for _v, _l, tip in dom_mod._IDP_ITEMS)]
    for t in texts:
        assert "provisioned just for it" not in t
        assert "reaches cluster provisioning" not in t
    own_tip = dict((v, tip) for v, _l, tip in dom_mod._IDP_ITEMS)["own"]
    assert "Applied on the Docker mesh only" in own_tip


def test_the_text_domains_step_says_the_same(tmp_path):
    from hugmesh_studio.tui.domains_step import DomainsScreen
    cfg = ImageConfig()
    cfg.mode = "mesh"
    cfg.domains = [Domain(name="shop.example", title="Shop")]
    j = SimpleNamespace(cfg=cfg, status="", generator_dir=str(tmp_path), overlay=None)
    screen = DomainsScreen()
    text = "\n".join(screen.lines(j))
    assert OWN_SIGNIN_NOT_APPLIED_ON_IMAGE in text
