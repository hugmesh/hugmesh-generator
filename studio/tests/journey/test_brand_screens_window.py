"""The window's superbrand drop-down, design step and Brand settings tabs
(hugmesh-generator#654, D8, D9, D20).

These drive the real widgets the way a person does (pick, type, click) and read what
they wrote. What each group of tests turns red on is named in its first line.
Geometry, two styles and two font sizes are tests/test_brand_screens_look.py.
"""
import json
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import brand_model                                   # noqa: E402
from hugmesh_studio.core.config import DOMAIN_IDP_OWN, Domain, ImageConfig    # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                           # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                # noqa: E402
from hugmesh_studio.gui.pages import domains as dom_mod                       # noqa: E402
from hugmesh_studio.gui.pages.brand_picker import BrandPicker                 # noqa: E402
from hugmesh_studio.gui.pages.brand_screen import (TAB_TITLES, TAB_IDENTITY,  # noqa: E402
                                                   TAB_LOOK, TAB_SERVICES, TAB_WAYS)
from hugmesh_studio.gui.pages.superbrand import SuperbrandStep                # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                   # noqa: E402
from hugmesh_studio.tui import brand_step             # noqa: E402
from hugmesh_studio.tui.superbrand_step import (CREATE_LABEL, UNAFFILIATED_REASON,  # noqa: E402
                                                session_for)


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-brand-screens-tests"])


@pytest.fixture
def gen(tmp_path):
    (tmp_path / "brands").mkdir()
    (tmp_path / "brands" / "example.conf").write_text("BRAND=example\n")
    return str(tmp_path)


def _cfg(**kw) -> ImageConfig:
    c = ImageConfig()
    c.mode = "mesh"
    for k, v in kw.items():
        setattr(c, k, v)
    return c


def _wiz(gen, cfg=None):
    return SimpleNamespace(cfg=cfg or _cfg(), generator_dir=gen)


# ── the drop-down ────────────────────────────────────────────────────────────────────
def test_the_drop_down_starts_on_create_and_lists_the_profiles_after_it(qapp, gen):
    w = _wiz(gen)
    p = BrandPicker(session_for(w, "image", w.cfg, gen))
    assert p.item_labels()[0] == CREATE_LABEL
    assert p.current_key() == "create"
    assert p.item_labels()[1:] == ["example (a brands/ profile)"]
    # no existing choice yet, so no summary and no Change it
    assert p.summary.isHidden() and p.change_btn.isHidden()


def test_picking_a_profile_shows_a_read_only_summary_and_change_it_opens_the_design(qapp, gen):
    w = _wiz(gen)
    s = session_for(w, "image", w.cfg, gen)
    p = BrandPicker(s)
    seen = []
    p.designing_changed.connect(lambda: seen.append(s.designing))
    p.select("profile:example")
    assert s.sb.id == "example" and not s.designing and seen == [False]
    assert not p.summary.isHidden() and "example" in p.summary.text()
    assert not p.change_btn.isHidden() and p.change_btn.text() == "Change it"
    p.change_btn.click()
    assert s.designing and seen == [False, True]
    assert p.change_btn.isHidden()


def test_an_unaffiliated_image_has_the_drop_down_disabled_with_the_reason_drawn(qapp, gen):
    w = _wiz(gen, _cfg(unaffiliated=True))
    p = BrandPicker(session_for(w, "image", w.cfg, gen))
    assert not p.combo.isEnabled() and p.combo.count() == 0
    assert not p.note.isHidden() and p.note.text() == UNAFFILIATED_REASON


# ── the design step ──────────────────────────────────────────────────────────────────
def test_the_design_step_edits_the_identity_through_the_session(qapp, gen):
    w = _wiz(gen)
    st = SuperbrandStep(session_for(w, "image", w.cfg, gen), look_in_step=False)
    st.show()
    assert not st.design.isHidden()
    for f, v in (("id", "acme"), ("title", "Acme Mesh"), ("public_name", "mesh.example")):
        st.fields[f].setText(v)
        st.fields[f].editingFinished.emit()
    assert st.commit() == []
    assert (w.cfg.brand, w.cfg.brand_title, w.cfg.cluster_domain) == (
        "acme", "Acme Mesh", "mesh.example")


def test_a_refused_identity_is_a_sentence_in_the_step_and_the_box_goes_back(qapp, gen):
    w = _wiz(gen)
    st = SuperbrandStep(session_for(w, "image", w.cfg, gen), look_in_step=False)
    st.show()
    st.fields["id"].setText("Not A Slug")
    st.fields["id"].editingFinished.emit()
    assert not st.note.isHidden() and "DNS label" in st.note.text()
    assert st.fields["id"].text() == "" and w.cfg.brand == "hugmesh"


def test_tabbing_through_the_boxes_is_not_an_edit(qapp, gen):
    w = _wiz(gen)
    s = session_for(w, "image", w.cfg, gen)
    st = SuperbrandStep(s, look_in_step=False)
    for f in st.fields:
        st.fields[f].editingFinished.emit()
    assert not s.touched


def test_an_unaffiliated_image_hides_the_identity_and_says_why_inline(qapp, gen):
    w = _wiz(gen, _cfg(unaffiliated=True))
    st = SuperbrandStep(session_for(w, "image", w.cfg, gen), look_in_step=False)
    st.show()
    assert st.identity_box.isHidden() and st.keep_row.isHidden()
    # said once, beside the drop-down; the design's own label carries it only where the
    # drop-down is not drawn (the Fleet window keeps it on its Shared options step)
    assert not st.picker.note.isHidden() and st.picker.note.text() == UNAFFILIATED_REASON
    assert st.reason.isHidden()
    assert not st.design.isHidden(), "the look is still the person's"
    fleet_style = SuperbrandStep(session_for(w, "image", w.cfg, gen), look_in_step=False,
                                 with_picker=False)
    fleet_style.show()
    assert not fleet_style.reason.isHidden() and fleet_style.reason.text() == UNAFFILIATED_REASON
    ed = st.ensure_look_editor()
    assert ed.model.identity_allowed is False and ed.identity_note.text()


def test_an_existing_choice_hides_the_design_until_change_it(qapp, gen):
    w = _wiz(gen, _cfg(brand="acme", brand_title="Acme Mesh", org="example"))
    st = SuperbrandStep(session_for(w, "image", w.cfg, gen), look_in_step=False)
    st.show()
    assert st.design.isHidden() and not st.picker.summary.isHidden()
    st.picker.change_btn.click()
    assert not st.design.isHidden()


def test_an_existing_choice_summary_is_a_two_column_table_not_spaces(qapp, gen):
    w = _wiz(gen)
    p = BrandPicker(session_for(w, "image", w.cfg, gen))
    p.select("profile:example")
    html_text = p.summary.text()
    assert "<table" in html_text and "<b>Superbrand id</b>" in html_text
    assert "  " not in html_text.replace("&nbsp;", "")[html_text.index("<table"):], \
        "alignment is the table's, never runs of spaces"


def test_the_pictures_the_record_cannot_hold_are_said_in_the_step(qapp, gen, tmp_path):
    from test_look_model import png_bytes
    w = _wiz(gen)
    s = session_for(w, "image", w.cfg, gen)
    st = SuperbrandStep(s)
    st.show()
    logo = tmp_path / "logo.png"
    logo.write_bytes(png_bytes(48, 48, opaque=True))
    st.look_editor.picture_paths["logo_image"].setText(str(logo))
    assert not st.record_note.isHidden()
    assert "logo" in st.record_note.text() and "Not saved in the brand record" in st.record_note.text()


# ── the Branding page (the image route's host) ───────────────────────────────────────
def test_the_branding_page_hosts_the_drop_down_in_mesh_and_the_look_in_its_section(qapp, gen):
    w = _wiz(gen)
    page = wizard_mod.BrandingPage(w)
    page.initializePage()
    assert not page.superbrand.isHidden()
    assert page.superbrand.picker.item_labels()[0] == CREATE_LABEL
    # one editor, one home: the look is in the existing section, the compact group is
    # hidden but still loaded and committed
    assert page.login_collapsible.title() == "Web login theme"
    assert page.superbrand.look_editor.parentWidget() is page.login_host
    assert page.login_theme.isHidden() and page.login_theme.isEnabled()


def test_a_colour_set_in_the_look_editor_survives_the_pages_next(qapp, gen):
    """Red when the hidden compact group is not re-read: its commit would put the old
    colour back over the edit."""
    w = _wiz(gen)
    page = wizard_mod.BrandingPage(w)
    page.initializePage()
    page.superbrand.look_editor.primary.setText("#336699")
    page.superbrand.look_editor.primary.editingFinished.emit()
    assert w.cfg.login_primary_color == "#336699"
    assert page.validatePage()
    assert w.cfg.login_primary_color == "#336699"


def test_outside_a_mesh_the_page_is_what_it_was_and_owns_no_superbrand_boxes(qapp, gen):
    cfg = _cfg()
    cfg.mode = "standalone"
    page = wizard_mod.BrandingPage(_wiz(gen, cfg))
    page.initializePage()
    assert page.superbrand is None, "a standalone image has no brands: nothing is built"
    assert page.login_collapsible.isHidden()
    cfg.mode = "mesh"
    page.initializePage()
    assert not page.superbrand.isHidden()
    cfg.mode = "standalone"
    page.initializePage()
    assert page.superbrand.isHidden() and not page.login_theme.isHidden()


def test_next_on_the_branding_page_writes_the_design_to_the_configuration(qapp, gen):
    w = _wiz(gen)
    page = wizard_mod.BrandingPage(w)
    page.initializePage()
    st = page.superbrand
    st.fields["title"].setText("Acme Mesh")
    st.fields["title"].editingFinished.emit()
    assert w.cfg.brand_title == "HugMesh Systems", "nothing is written before Next"
    page.validatePage()
    assert w.cfg.brand_title == "Acme Mesh"


def test_a_page_nobody_touched_leaves_the_configuration_exactly_as_it_was(qapp, gen):
    import dataclasses
    w = _wiz(gen)
    before = dataclasses.asdict(w.cfg)
    page = wizard_mod.BrandingPage(w)
    page.initializePage()
    page.validatePage()
    assert dataclasses.asdict(w.cfg) == before


# ── the Network page's mirrors ───────────────────────────────────────────────────────
def test_the_network_pages_brand_rows_are_read_only_mirrors_on_a_mesh(qapp, gen):
    w = SimpleNamespace(cfg=_cfg(brand="acme", brand_title="Acme Mesh"), generator_dir=gen,
                        worklist=None)
    page = wizard_mod.NetworkPage(w)
    page.initializePage()
    for edit in (page.brand, page.brand_title, page.org, page.domain):
        assert edit.isReadOnly()
    assert page.brand.text() == "acme" and not page.brand_mirror_note.isHidden()
    assert "superbrand step" in page.brand_mirror_note.text()
    w.cfg.mode = "standalone"
    page.initializePage()
    for edit in (page.brand, page.brand_title, page.org, page.domain):
        assert not edit.isReadOnly()
    assert page.brand_mirror_note.isHidden()


# ── the brands table ─────────────────────────────────────────────────────────────────
def _table_page(gen, rows):
    w = SimpleNamespace(cfg=_cfg(domains=rows), generator_dir=gen,
                        currentIdChanged=SimpleNamespace(connect=lambda *_: None),
                        currentPage=lambda: None)
    return w, dom_mod.DomainsPage(w)


def test_the_brands_table_shows_one_read_only_summary_line_per_brand_on_a_mesh(qapp, gen):
    w, page = _table_page(gen, [Domain(name="shop.example", title="Shop", tor=True,
                                       look={"primary": "#aa0000"}),
                                Domain(name="blog.example")])
    page.initializePage()
    # the table's columns are an interface: the summary is NOT an extra one (the last
    # column is the GitHub org of the Go-Live export step)
    assert page.table.columnCount() == dom_mod._COL_ORG + 1, \
        "the brand summary must not add a column to the table"
    lines = dict(page.brand_summaries())
    assert lines["shop.example"] == (
        "signs in through the superbrand; 1 look setting of its own; reached by Tor")
    assert lines["blog.example"].startswith("signs in through the superbrand; inherits")
    own = next(v for k, v in lines.items() if k not in ("shop.example", "blog.example"))
    assert own.startswith("the superbrand")
    box = page.summary_box
    assert not box.isHidden()
    for name, text in lines.items():
        assert name in box.text() and text.split(";")[0] in box.text()
    # a label: nothing in it can be typed
    assert not box.textInteractionFlags() & dom_mod.Qt.TextInteractionFlag.TextEditable


def test_the_summary_follows_the_sign_in_cell_before_anything_is_saved(qapp, gen):
    w, page = _table_page(gen, [Domain(name="shop.example")])
    page.initializePage()
    t = page.table
    r = next(i for i in range(t.rowCount()) if t.item(i, dom_mod._COL_NAME).text() == "shop.example")
    t.cellWidget(r, dom_mod._COL_IDP).setCurrentIndex(1)       # Own Casdoor
    assert dict(page.brand_summaries())["shop.example"].startswith("has its own sign-in")
    assert "has its own sign-in" in page.summary_box.text()


def test_a_host_with_no_session_has_no_summary(qapp, gen):
    w = _wiz(gen, _cfg())
    w.cfg.mode = "cloud"
    t = dom_mod.DomainsTableWidget(cfg=lambda: None)
    t.fill([], "mesh.example")
    assert t.brand_summaries() == [] and t.summary_box.isHidden()
    t.set_brand_session(lambda: session_for(w, "image", _cfg(), gen))
    assert not t.summary_box.isHidden()


def test_a_next_through_the_table_keeps_each_brands_id_look_ways_and_port(qapp, gen):
    """The table rebuilt a row from its cells and erased what it has no cell for
    (the table's rows() builds a row from its cells alone). Red when rows() builds only from cells."""
    kept = Domain(name="shop.example", title="Shop", id="shop-example",
                  look={"primary": "#aa0000"}, ways={"internal_name": "shop.acme.internal"},
                  issuer_port=8002, idp=DOMAIN_IDP_OWN, optional_services=["akkoma"], tor=True)
    w, page = _table_page(gen, [kept])
    page.initializePage()
    assert page.validatePage()
    row = w.cfg.domains[0]
    assert (row.id, row.look, row.ways, row.issuer_port) == (
        "shop-example", {"primary": "#aa0000"}, {"internal_name": "shop.acme.internal"}, 8002)
    assert row.optional_services == ["akkoma"] and row.tor is True
    assert row.look is not kept.look, "the row is a copy: editing it never edits the old one"


# ── the four tabs ────────────────────────────────────────────────────────────────────
def _page(gen, cfg=None):
    w = _wiz(gen, cfg or _cfg(domains=[
        Domain(name="shop.example", title="Shop"),
        Domain(name="blog.example", title="Blog", idp=DOMAIN_IDP_OWN)]))
    page = ds_mod.DomainServicesPage(w)
    page.initializePage()
    return w, page


def test_the_four_tabs_are_in_the_designs_order_and_services_is_open(qapp, gen):
    w, page = _page(gen)
    tabs = page.brand_tabs
    assert [tabs.tabText(i) for i in range(4)] == list(TAB_TITLES) == [
        "Identity", "Look", "Services", "Ways to reach it"]
    assert tabs.currentIndex() == TAB_SERVICES
    assert (TAB_IDENTITY, TAB_LOOK, TAB_SERVICES, TAB_WAYS) == (0, 1, 2, 3)
    # the Services tab IS the body: its widgets stay in the body's layout, under the
    # page's own content widget, below the tab bar
    assert page.brand_tabs.bar.parentWidget() is page.table.parentWidget()
    assert page.brand_tabs.bar.geometry().bottom() <= page.table.geometry().top() or \
        not page.isVisible()


def test_a_host_with_no_session_draws_no_tab_bar(qapp, gen):
    w = _wiz(gen)
    w.cfg.mode = "cloud"
    w.cfg.domains = [Domain(name="shop.example")]
    page = ds_mod.DomainServicesPage(w)
    page._load(w.cfg, ["shop.example"], "")
    assert page.brand_tabs.tabBar().isHidden()
    assert page.brand_tabs.currentIndex() == TAB_SERVICES
    assert page.table.isVisibleTo(page) and page.brand_tabs.identity_page.isHidden()


def test_a_tab_hides_the_services_body_and_back_restores_it_as_it_was(qapp, gen):
    """Red when switching tabs forgets which widgets were hidden on purpose (the lane
    note is hidden until a host gives it a sentence) or leaves the body showing under
    another tab."""
    w, page = _page(gen)
    page.show()
    body = [page.table, page.front_door_table, page.tor_note, page.enforcement,
            page.help, page.other_table, page.legend, page.remaining]
    assert page.lane_note.isHidden()
    assert all(not x.isHidden() for x in body)
    page.brand_tabs.open_tab("Identity")
    assert all(x.isHidden() for x in body + [page.lane_note])
    assert not page.brand_tabs.identity_page.isHidden()
    page.brand_tabs.open_tab("Services")
    assert all(not x.isHidden() for x in body)
    assert page.lane_note.isHidden(), "a widget hidden on purpose stays hidden"
    assert page.brand_tabs.identity_page.isHidden()


def test_the_identity_tab_mirrors_the_row_and_says_where_it_is_changed(qapp, gen):
    w, page = _page(gen)
    page._step(1)                                        # shop.example
    tabs = page.brand_tabs
    labels = [tabs.identity_form.itemAt(i).widget().text()
              for i in range(tabs.identity_form.count())]
    assert "shop.example" in labels and "Shop" in labels and "shop-example" in labels
    assert tabs.identity_home.text() == brand_step.IDENTITY_HOME
    for i in range(tabs.identity_form.count()):
        assert isinstance(tabs.identity_form.itemAt(i).widget(), QtWidgets.QLabel), \
            "a mirror has no editable control"


def test_the_certificate_authority_is_mirrored_on_the_image_route_only(qapp, gen):
    cfg = _cfg(domains=[Domain(name="shop.example", title="Shop")],
               domain_ca={"shop.example": "/example/ca/mesh-root.pem"})
    w, page = _page(gen, cfg)
    page._step(1)
    tabs = page.brand_tabs
    labels = [tabs.identity_form.itemAt(i).widget().text()
              for i in range(tabs.identity_form.count())]
    assert "Certificate authority" in labels and "mesh-root.pem" in labels
    state, session, widget = _docker_widget(gen, [Domain(name="shop.example")])
    widget._step(1)
    docker = [widget.brand_tabs.identity_form.itemAt(i).widget().text()
              for i in range(widget.brand_tabs.identity_form.count())]
    assert "Certificate authority" not in docker, \
        "the Docker route has no Secrets-store step, so no certificate authority to show"


def test_the_own_domain_is_labelled_the_superbrand_and_points_at_its_step(qapp, gen):
    w, page = _page(gen)
    tabs = page.brand_tabs
    assert tabs.view.own and tabs.identity_home.text() == brand_step.SUPERBRAND_HOME
    assert tabs.look_editor is None or tabs.look_editor.isHidden()
    assert tabs.look_note.text() == brand_step.LOOK_HOME


def test_the_ways_tab_is_read_only_with_one_button_that_asks_for_the_wizard(qapp, gen):
    w, page = _page(gen)
    page._step(1)
    tabs = page.brand_tabs
    asked = []
    tabs.ways_requested.connect(asked.append)
    text = tabs.ways_text.text()
    assert "internal name:" in text and "Tor address:" in text and "Docker mesh" in text
    assert tabs.ways_btn.text() == "Set up ways to reach this brand"
    tabs.ways_btn.click()
    assert asked == ["shop.example"]
    assert "Go-Live wizard" in tabs.ways_note.text()


def test_off_the_docker_mesh_the_look_tab_is_drawn_disabled_with_the_reason(qapp, gen):
    w, page = _page(gen)
    page._step(1)
    ed = page.brand_tabs.look_editor
    assert ed is not None and not ed.path_note.isHidden()
    assert "Docker mesh only" in ed.path_note.text()
    assert all(not c.isEnabled() for c in ed.controls.values())


def _docker_widget(gen, rows):
    from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains
    from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
    state = LocalMeshDomains(domains=[Domain(name="mesh.example")] + rows,
                             own_name="mesh.example")
    boot = LocalMeshBootstrapConfig()
    owner = SimpleNamespace()
    # the Docker route keeps its rows on the step's state while the step is open
    session = session_for(owner, "docker", (boot, state), gen)
    widget = ds_mod.DomainServicesWidget(brand_session=lambda: session, route="docker")
    widget.load(state)
    return state, session, widget


def test_on_the_docker_mesh_a_brands_colour_is_overridden_and_given_back_by_two_clicks(
        qapp, gen):
    state, session, widget = _docker_widget(gen, [Domain(name="shop.example")])
    session.look.try_set("primary", "#336699")
    widget._step(1)
    ed = widget.brand_tabs.look_editor
    assert ed.path_note.isHidden() and ed.primary.isEnabled()
    assert ed.source_labels["primary"].text() == "inherited from the superbrand"
    ed.primary.setText("#aa0000")
    ed.primary.editingFinished.emit()
    assert state.by_name("shop.example").look == {"primary": "#aa0000"}
    assert ed.source_labels["primary"].text() == "this brand's own"
    btn = ed.use_buttons["primary"]
    btn.click()                                           # armed: nothing changes yet
    assert state.by_name("shop.example").look == {"primary": "#aa0000"}
    assert btn.text() == "Click again to use the superbrand's value"
    btn.click()
    assert state.by_name("shop.example").look == {}
    assert ed.source_labels["primary"].text() == "inherited from the superbrand"


def test_a_brands_look_edit_on_one_brand_never_reaches_another(qapp, gen):
    state, session, widget = _docker_widget(
        gen, [Domain(name="shop.example"), Domain(name="blog.example")])
    widget._step(1)
    ed = widget.brand_tabs.look_editor
    ed.primary.setText("#aa0000")
    ed.primary.editingFinished.emit()
    widget._step(1)
    assert widget.current_domain() == "blog.example"
    assert widget.brand_tabs.look_editor.primary.text() == ""
    assert state.by_name("blog.example").look == {}
    assert state.by_name("shop.example").look == {"primary": "#aa0000"}


def test_leaving_the_page_writes_the_record_once_something_changed(qapp, gen):
    w, page = _page(gen)
    assert page.validatePage()
    assert not os.path.exists(brand_model.record_path())
    sess = page._brand_session()
    sess.set_identity("title", "Acme Mesh")
    assert page.validatePage()
    saved = json.loads(open(brand_model.record_path(), encoding="utf-8").read())
    assert saved["superbrand"]["title"] == "Acme Mesh"
    assert [b["name"] for b in saved["brands"]] == ["shop.example", "blog.example"]


def test_no_page_of_this_lane_opens_a_modal_dialog():
    """The static scan (the repo's no-modal rule): no QMessageBox and no exec( in the
    pages and screens this lane owns."""
    import re
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    pkg = os.path.join(root, "hugmesh_studio")
    files = [os.path.join(pkg, "gui", "pages", n) for n in (
        "brand_picker.py", "superbrand.py", "brand_screen.py", "domain_services.py",
        "domains.py", "branding.py", "fleet.py")]
    files += [os.path.join(pkg, "tui", n) for n in (
        "superbrand_step.py", "brand_step.py", "domain_services_step.py", "domains_step.py",
        "fleet.py")]
    bad = []
    for path in files:
        with open(path, encoding="utf-8") as fh:
            code = re.sub(r'""".*?"""', "", fh.read(), flags=re.S)
        # the fleet window's close event has asked "stop the build?" with a box since
        # before this lane (a running build, not page logic); every other method is scanned
        chunks = re.split(r"(?m)^(?=    def )", code)
        code = "".join(c for c in chunks
                       if not (os.path.basename(path) == "fleet.py"
                               and c.startswith("    def closeEvent(")))
        for n, line in enumerate(code.splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if re.search(r"QMessageBox|\.exec_?\(|QFileDialog\.get|QInputDialog", line):
                bad.append(f"{os.path.basename(path)}:{n}: {line.strip()}")
    assert not bad, "\n".join(bad)
