"""The per-domain ways to sign in on the screens (hugmesh-generator#1107).

The operator, verbatim: "make sure it's a studio option per domain whether to allow
each sign in option". Each domain's Identity tab (window) and section 1 (text screen)
shows Password / Google / Discord, writes them through ``set_domain_signin_methods``
(row 0: where its route keeps the mesh's own list), refuses inline, says the list is
kept but not applied yet, and offers nothing when the domain's sign-in is an external
provider. Every control is visible, enabled and unclipped at the default size.
"""
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import (DOMAIN_IDP_OWN, SIGNIN_METHODS_NOT_APPLIED,  # noqa: E402
                                        Domain, ImageConfig)
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig  # noqa: E402
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains          # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                           # noqa: E402
from hugmesh_studio.tui import brand_step                                     # noqa: E402
from hugmesh_studio.tui.domain_services_step import DomainServicesScreen      # noqa: E402
from hugmesh_studio.tui.superbrand_step import session_for                    # noqa: E402

ENTRA = "https://login.microsoftonline.com/0000-tenant/v2.0"
SHOT = os.environ.get("HUGMESH_SIGNIN_METHODS_SHOT", "")


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-signin-methods"])


@pytest.fixture
def gen(tmp_path):
    (tmp_path / "brands").mkdir()
    return str(tmp_path)


def _settle(qapp, n=3):
    for _ in range(n):
        qapp.processEvents()


def _image_page(qapp, gen, rows=None, **cfg_kw):
    cfg = ImageConfig(mode="mesh", **cfg_kw)
    cfg.domains = rows if rows is not None else [Domain(name="shop.example", title="Shop")]
    wiz = SimpleNamespace(cfg=cfg, generator_dir=gen)
    page = ds_mod.DomainServicesPage(wiz)
    page.initializePage()
    page.resize(736, 736)
    page.show()
    _settle(qapp)
    return wiz, page


def _ticked(tabs):
    return [k for k, b in tabs.method_boxes.items() if b.isChecked()]


def _assert_unclipped(tabs):
    """Each box is visible, enabled, at least its own size hint wide (a check box never
    wraps, so a narrower one is clipped text), and inside the sign-in group."""
    group = tabs.signin_box
    for key, box in tabs.method_boxes.items():
        assert box.isVisible() and box.isEnabled(), key
        assert box.width() >= box.sizeHint().width(), (key, box.width(), box.sizeHint())
        assert box.height() >= 18, (key, box.height())
        top_left = box.mapTo(group, QtCore.QPoint(0, 0))
        assert top_left.x() >= 0 and top_left.x() + box.width() <= group.width(), key
    note = tabs.methods_note
    assert note.isVisible() and note.wordWrap()
    assert note.mapTo(group, QtCore.QPoint(0, 0)).x() + note.width() <= group.width()


# ── an added domain on the image route ──────────────────────────────────────────────
def test_an_added_domain_writes_its_ways_to_sign_in(qapp, gen):
    wiz, page = _image_page(qapp, gen)
    page._step(1)
    tabs = page.brand_tabs
    tabs.open_tab("Identity")
    _settle(qapp)
    row = wiz.cfg.domains[0]
    assert _ticked(tabs) == ["password"]                 # the default: password only
    _assert_unclipped(tabs)
    if SHOT:
        page.grab().save(SHOT)
    assert SIGNIN_METHODS_NOT_APPLIED in tabs.methods_note.text()
    tabs.method_boxes["google"].click()
    tabs.method_boxes["discord"].click()
    assert row.signin_methods == ["password", "google", "discord"]
    assert tabs.methods_note.text().startswith("Saved: Password, Google, Discord.")
    tabs.method_boxes["password"].click()
    assert row.signin_methods == ["google", "discord"]


def test_clearing_every_box_is_refused_and_the_boxes_come_back(qapp, gen):
    wiz, page = _image_page(qapp, gen)
    page._step(1)
    tabs = page.brand_tabs
    tabs.open_tab("Identity")
    _settle(qapp)
    tabs.method_boxes["password"].click()                # the last one
    assert tabs.methods_note.text().startswith("Not changed: choose at least one way")
    assert _ticked(tabs) == ["password"]
    assert wiz.cfg.domains[0].signin_methods == []


def test_an_external_provider_offers_no_methods_and_clears_them(qapp, gen):
    wiz, page = _image_page(qapp, gen, rows=[
        Domain(name="shop.example", signin_methods=["password", "google"])])
    page._step(1)
    tabs = page.brand_tabs
    tabs.open_tab("Identity")
    _settle(qapp)
    assert _ticked(tabs) == ["password", "google"]
    tabs.signin_choice.setCurrentIndex(tabs.signin_choice.findData("entra"))
    tabs.signin_choice.activated.emit(tabs.signin_choice.currentIndex())
    tabs.signin_issuer.setText(ENTRA)
    tabs.signin_client.setText("client-1")
    tabs.signin_apply.click()
    _settle(qapp)
    row = wiz.cfg.domains[0]
    assert row.idp == DOMAIN_IDP_OWN and row.signin_methods == []
    assert tabs.methods_row.isHidden()
    assert "external provider" in tabs.methods_note.text()


# ── row 0, the mesh's own domain ───────────────────────────────────────────────────
def test_row_zero_writes_the_meshs_own_list_on_the_image_route(qapp, gen):
    wiz, page = _image_page(qapp, gen)
    page._show()
    tabs = page.brand_tabs
    tabs.open_tab("Identity")
    _settle(qapp)
    assert tabs.view.own
    _assert_unclipped(tabs)
    tabs.method_boxes["discord"].click()
    assert wiz.cfg.cluster_domain_signin_methods == ["password", "discord"]
    tabs.method_boxes["discord"].click()
    assert wiz.cfg.cluster_domain_signin_methods == []


def test_row_zero_with_an_external_mesh_provider_offers_none(qapp, gen):
    wiz, page = _image_page(qapp, gen, idp="aws",
                            idp_issuer="https://cognito-idp.eu-west-1.amazonaws.com/p",
                            idp_client_id="mesh")
    page._show()
    tabs = page.brand_tabs
    tabs.open_tab("Identity")
    _settle(qapp)
    assert tabs.methods_row.isHidden()
    assert "external provider" in tabs.methods_note.text()


def _docker_state():
    return LocalMeshDomains(domains=[Domain(name="mesh.example"),
                                     Domain(name="shop.example", title="Shop")],
                            own_name="mesh.example")


def test_row_zero_on_the_docker_route_says_it_keeps_no_list(qapp, gen):
    st = _docker_state()
    s = session_for(SimpleNamespace(), "docker", (LocalMeshBootstrapConfig(), st), gen)
    view = brand_step.brand_view(s, "mesh.example", own=True)
    assert view.own
    why = view.signin_methods_refusal()
    assert why.startswith("This route keeps no list of ways to sign in")
    assert view.set_signin_methods(["google"]) == [why]
    lines = "\n".join(brand_step.identity_lines(view))
    assert why in lines and brand_step.METHODS_COMMAND_LINE not in lines


# ── the two faces write the same rows ──────────────────────────────────────────────
def test_the_text_screen_and_the_window_write_the_same_list(qapp, gen):
    st_w = _docker_state()
    s_w = session_for(SimpleNamespace(), "docker", (LocalMeshBootstrapConfig(), st_w), gen)
    w = ds_mod.DomainServicesWidget(brand_session=lambda: s_w, route="docker")
    w.load(st_w)
    w._step(1)
    w.brand_tabs.method_boxes["discord"].click()
    st_t = _docker_state()
    s_t = session_for(SimpleNamespace(), "docker", (LocalMeshBootstrapConfig(), st_t), gen)
    j = SimpleNamespace(status="", generator_dir=gen, overlay=None, advance=lambda: None)
    sc = DomainServicesScreen(cfg_of=lambda _j: st_t, brand_session_of=lambda _j: s_t,
                              route="docker")
    sc.enter(j)
    sc.feed(j, "n")
    sc.feed(j, "open 1")
    text = "\n".join(sc.lines(j)) if hasattr(sc, "lines") else ""
    sc.feed(j, "methods discord password")
    assert "ways to sign in -> Password, Discord" in j.status
    a, b = st_w.by_name("shop.example"), st_t.by_name("shop.example")
    assert a.signin_methods == b.signin_methods == ["password", "discord"]
    sc.feed(j, "methods")
    assert j.status.startswith("Not changed: choose at least one way")
    sc.feed(j, "methods github")
    assert j.status.startswith("Not changed:") and "github" in j.status
    assert b.signin_methods == ["password", "discord"]
    del text


def test_the_text_section_shows_the_list_the_note_and_the_command(gen):
    cfg = ImageConfig(mode="mesh", domains=[Domain(name="shop.example",
                                                   signin_methods=["google"])])
    wiz = SimpleNamespace(cfg=cfg, generator_dir=gen)
    view = brand_step.brand_view(session_for(wiz, "image", cfg, gen), "shop.example")
    lines = brand_step.identity_lines(view)
    assert "   Ways to sign in  Google" in lines
    assert "   " + SIGNIN_METHODS_NOT_APPLIED in lines
    assert brand_step.METHODS_COMMAND_LINE in lines
