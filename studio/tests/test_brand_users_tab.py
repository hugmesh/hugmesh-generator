"""The Brand settings screen's Users tab (2026-11-19, the operator: "users should be
creatable and assignable by domain in another tab after identity in the domain
configuration and adding users should work without the e2e scripts").

* the tab is second, right after Identity, on the window and the text screen;
* on the image route a person added here is a ``cfg.users`` row assigned to this
  domain (a superadmin to the root domain), and the wizard's Users step and users
  choice are told so they do not write their stale rows back;
* on the Docker route the tab creates an account on the running mesh through
  ``core.mesh_accounts`` (a live stub Casdoor here), never a seeder;
* a domain with an external provider says where its people are added instead.

Looked at, not only asserted: with HUGMESH_USERS_SHOTS set, the tab is grabbed to PNGs.
"""
from __future__ import annotations

import os
from types import SimpleNamespace

import pytest

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from _casdoor_stub import stub  # noqa: E402,F401  (the fixture)
from hugmesh_studio.core import mesh_accounts as ma                             # noqa: E402
from hugmesh_studio.core.config import Domain, ImageConfig                       # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig    # noqa: E402
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains              # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                   # noqa: E402
from hugmesh_studio.gui.pages.brand_screen import TAB_TITLES, TAB_USERS          # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                      # noqa: E402
from hugmesh_studio.tui import brand_step                                        # noqa: E402
from hugmesh_studio.tui.superbrand_step import session_for                      # noqa: E402

ADMIN_PW = "users-tab-admin-pw-42"


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-users-tab"])


@pytest.fixture(autouse=True)
def _no_real_casdoor(monkeypatch):
    """Opening the tab lists the running mesh's accounts. A test must never reach the
    operator's real Casdoor (a wrong admin password there counts toward its sign-in
    throttle): the central sign-in is a closed loopback port unless a test points it
    at a stub."""
    monkeypatch.setenv("CASDOOR_URL", "http://127.0.0.1:9")
    monkeypatch.delenv("CASDOOR_ADMIN_PASS", raising=False)


def _settle(qapp):
    for _ in range(3):
        qapp.processEvents()


def _shot(widget, name):
    out = os.environ.get("HUGMESH_USERS_SHOTS", "")
    if out:
        os.makedirs(out, exist_ok=True)
        widget.grab().save(os.path.join(out, f"{name}.png"))


def _gen(tmp_path):
    gd = tmp_path / "gen"
    (gd / "tests" / "stack").mkdir(parents=True)
    (gd / "tests" / "stack" / ".env").write_text(f"CASDOOR_ADMIN_PASSWORD={ADMIN_PW}\n")
    return str(gd)


def _users_tab(qapp, route, gd, *, rows=None, step=1):
    owner = SimpleNamespace()
    rows = rows or [Domain(name="shop.example", title="Shop")]
    if route == "image":
        cfg = ImageConfig()
        cfg.mode = "mesh"
        cfg.domains = rows
        state, source = cfg, cfg
    else:
        state = LocalMeshDomains(domains=[Domain(name="mesh.example"), *rows],
                                 own_name="mesh.example")
        source = (LocalMeshBootstrapConfig(), state)
    session = session_for(owner, route, source, gd)
    widget = ds_mod.DomainServicesWidget(brand_session=lambda: session, route=route)
    widget.load(state)
    if step:
        widget._step(step)
    widget.resize(1000, 950)
    widget.show()
    widget.brand_tabs.setCurrentIndex(TAB_USERS)
    _settle(qapp)
    return widget, widget.brand_tabs.people_page, state


def test_users_is_the_tab_after_identity_on_both_faces():
    assert TAB_TITLES[:2] == ("Identity", "Users")
    assert brand_step.SECTIONS[1] == (brand_step.SECTION_USERS, "Users")


def test_image_route_assigns_a_planned_person_to_this_domain(qapp, tmp_path):
    widget, tab, cfg = _users_tab(qapp, "image", _gen(tmp_path))
    assert tab.isVisible() and tab.plan_box.isVisible()
    assert tab.plan_box.title() == "People planned for shop.example"
    told = []
    widget.brand_tabs.people_changed.connect(lambda: told.append(1))
    tab.plan_name.setText("rita")
    tab.plan_email.setText("rita@shop.example")
    tab.plan_role_boxes["mod"].setChecked(True)
    tab.plan_add.click()
    _settle(qapp)
    assert [(u.username, u.domain, u.roles, u.email) for u in cfg.users] == [
        ("rita", "shop.example", ["mod"], "rita@shop.example")]
    assert cfg.configure_users is True, "the users choice must not drop the row"
    assert told == [1]
    assert tab.plan_table.rowCount() == 1 and tab.plan_table.item(0, 0).text() == "rita"
    assert "superadmin" not in tab.plan_role_boxes, "a tenant domain has no superadmin"
    _shot(widget, "image-users-tab")
    # a second person of the same name is refused inline, nothing written
    tab.plan_name.setText("rita")
    tab.plan_add.click()
    _settle(qapp)
    assert "Not added" in tab.plan_msg.text() and len(cfg.users) == 1
    # remove
    tab.plan_table.selectRow(0)
    tab.plan_remove.click()
    _settle(qapp)
    assert cfg.users == [] and told == [1, 1]
    widget.brand_tabs.people_page.wait()
    widget.close()


def test_the_mesh_own_row_offers_superadmin_and_files_it_under_the_root(qapp, tmp_path):
    widget, tab, cfg = _users_tab(qapp, "image", _gen(tmp_path), step=0)
    view = widget.brand_tabs.view
    if not view.own:
        pytest.skip("this flow has no own row on screen first")
    assert "superadmin" in tab.plan_role_boxes
    assert view.add_person("root1", ["superadmin"]) == []
    assert cfg.users[-1].domain == cfg.effective_superdomain()
    assert any(u.username == "root1" for u in view.people())
    widget.brand_tabs.people_page.wait()
    widget.close()


def test_docker_route_creates_an_account_on_the_running_mesh(qapp, tmp_path, stub,  # noqa: F811
                                                            monkeypatch):
    url, journal = stub(admin_pw=ADMIN_PW)
    monkeypatch.setenv("CASDOOR_URL", url)
    monkeypatch.delenv("CASDOOR_ADMIN_PASS", raising=False)
    widget, tab, _state = _users_tab(qapp, "docker", _gen(tmp_path))
    assert not tab.plan_box.isVisible() and tab.plan_refusal.isVisible()
    assert tab.live_box.isVisible() and "central sign-in" in tab.live_where.text()
    tab.wait()
    tab.live_name.setText("sam")
    tab.live_role_boxes["ROLE_MATRIX"].setChecked(True)
    tab.live_register.setChecked(False)
    tab.live_create.click()
    tab.wait()
    _settle(qapp)
    tab.wait()                                   # the refresh that follows
    _settle(qapp)
    assert "sam was created" in tab.live_msg.text(), tab.live_msg.text()
    assert "shown this once" in tab.live_msg.text()
    cd = ma.CasdoorAdmin(url)
    cd.login(ADMIN_PW)
    user = cd.get_user("sam")
    assert user["properties"] == {ma.DOMAIN_PROPERTY: "shop.example"}
    assert "hugmesh/sam" in cd._ok("GET", "/api/get-role?id=hugmesh/ROLE_MATRIX")["users"]
    names = [tab.live_table.item(r, 0).text() for r in range(tab.live_table.rowCount())]
    assert names == ["sam"]
    _shot(widget, "docker-users-tab-created")
    widget.brand_tabs.people_page.wait()
    widget.close()


def test_a_domain_with_an_external_provider_says_where_its_people_are(qapp, tmp_path):
    ext = Domain(name="corp.example", idp="own",
                 idp_settings={"provider": "entra", "issuer": "https://login.example/t",
                               "client_id": "c"})
    widget, tab, _ = _users_tab(qapp, "docker", _gen(tmp_path), rows=[ext])
    assert "entra" in tab.live_where.text() and "add the person there" in tab.live_where.text()
    assert not tab.live_create.isEnabled()
    widget.brand_tabs.people_page.wait()
    widget.close()


def test_the_text_screen_adds_and_lists_planned_people(tmp_path):
    cfg = ImageConfig()
    cfg.mode = "mesh"
    cfg.domains = [Domain(name="shop.example")]
    session = session_for(SimpleNamespace(), "image", cfg, _gen(tmp_path))
    view = brand_step.brand_view(session, "shop.example")
    assert "is now a planned person" in brand_step.feed_people(view, "add tess admin,games")
    assert [u.roles for u in cfg.users] == [["admin", "games"]]
    lines = "\n".join(brand_step.people_lines(view))
    assert "2. Users — shop.example" in lines and "tess" in lines
    assert "Not added" in brand_step.feed_people(view, "add tess")
    assert "no longer" in brand_step.feed_people(view, "remove tess")
