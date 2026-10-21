"""J-FLEET — the Fleet window and its text twin offer the same drop-down, and choosing
‘Create a new superbrand’ there writes the same record bytes as the image route
(hugmesh-generator#654, D8; operator decision 71 = A).

THE SCRIPT, three ways over the same inputs (id acme, title Acme Mesh, organisation
example, public name mesh.example, colour #336699):

  1. the IMAGE route: the Branding page (design step) then the Brand settings step;
  2. the FLEET window: the drop-down on Shared options, the Superbrand step, the Domains
     and the Brand settings steps, with the real Next button;
  3. the FLEET text twin: ``brand`` on the options, the design, the Domains and the Brand
     settings screens.

WHAT IS COMPARED. The three record files, byte for byte (the Fleet adds nothing the
person did not type); the drop-down's items in both Fleet faces; and the geometry the
2026-10-01 audit measured — the window opens at 760x700 and scrolled 103 px sideways on
every step; every step of it, and the tabbed Brand settings screen, now fits.
"""
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import brand_model                                   # noqa: E402
from hugmesh_studio.core.config import Domain, ImageConfig                    # noqa: E402
from hugmesh_studio.core.fleet import FleetDriver                             # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                        # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                           # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                # noqa: E402
from hugmesh_studio.gui.pages import fleet as fleet_mod                       # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                   # noqa: E402
from hugmesh_studio.tui.fleet import FleetScreen                              # noqa: E402
from hugmesh_studio.tui.journey import Journey                                # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")

IDENTITY = {"id": "acme", "title": "Acme Mesh", "org": "example",
            "public_name": "mesh.example"}
COLOUR = "#336699"


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-fleet-journey"])


def _record_bytes() -> bytes:
    with open(brand_model.record_path(), "rb") as fh:
        data = fh.read()
    os.remove(brand_model.record_path())
    return data


def _image_route_bytes() -> bytes:
    cfg = ImageConfig()
    cfg.mode = "mesh"
    wiz = SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR)
    branding = wizard_mod.BrandingPage(wiz)
    branding.initializePage()
    st = branding.superbrand
    for f, v in IDENTITY.items():
        st.fields[f].setText(v)
        st.fields[f].editingFinished.emit()
    assert branding.validatePage()
    services = ds_mod.DomainServicesPage(wiz)
    services.initializePage()
    # the mesh's own look: row 0's Look tab (2026-10-21)
    services.brand_tabs.open_tab("Look")
    services.brand_tabs.look_editor.primary.setText(COLOUR)
    services.brand_tabs.look_editor.primary.editingFinished.emit()
    assert services.validatePage()
    return _record_bytes()


@pytest.fixture
def fleet_page(qapp, monkeypatch):
    monkeypatch.setattr("hugmesh_studio.core.build_driver.detect",
                        lambda builder_image="hugmesh-builder": HOST)
    p = fleet_mod.FleetPage(GENERATOR_DIR)
    p.driver = FleetDriver(GENERATOR_DIR, HOST)
    p.driver._image_present = lambda: True
    yield p
    p.deleteLater()


def _fleet_window_bytes(page) -> bytes:
    page._goto(fleet_mod.STEP_SHARED)
    picker = page.brand_picker
    assert picker.item_labels()[0] == "Create a new superbrand"
    assert picker.current_key() == "create"
    picker.select("create")
    page.next_btn.click()                                  # -> Superbrand
    assert page.stack.currentIndex() == fleet_mod.STEP_BRAND
    step = page.superbrand_step
    assert not step.design.isHidden()
    for f, v in IDENTITY.items():
        step.fields[f].setText(v)
        step.fields[f].editingFinished.emit()
    assert step.look_editor is None                      # the look is row 0's tab
    page.next_btn.click()                                  # -> Domains
    assert page.stack.currentIndex() == fleet_mod.STEP_DOMAINS
    assert page.cluster_domain.text() == "mesh.example"
    page.next_btn.click()                                  # -> Brand settings (services)
    assert page.stack.currentIndex() == fleet_mod.STEP_DOMAIN_SERVICES
    tabs = page.domain_services.brand_tabs
    assert tabs.view is not None and tabs.view.own        # row 0: the mesh's own domain
    tabs.open_tab("Look")
    tabs.look_editor.primary.setText(COLOUR)
    tabs.look_editor.primary.editingFinished.emit()
    page.next_btn.click()                                  # -> Review: the record is written
    assert page.stack.currentIndex() == fleet_mod.STEP_REVIEW
    return _record_bytes()


def _fleet_text_bytes() -> bytes:
    j = Journey(GENERATOR_DIR)
    j.goto("fleet")
    fs = j.screen()
    assert isinstance(fs, FleetScreen)
    j.feed("brand")
    assert "*1. Create a new superbrand" in "\n".join(j.lines())
    cmd = {"id": "id", "title": "title", "org": "org", "public_name": "public"}
    for f, v in IDENTITY.items():
        j.feed(f"{cmd[f]} {v}")
    j.feed("")                                             # commit; back on the options
    assert fs.stage == "options" and fs.options(j).cluster_domain == "mesh.example"
    j.feed("")                                             # -> Domains
    j.feed("")                                             # -> Brand settings
    assert fs.stage == "services"
    # the mesh's own look: section 2 of its own domain (2026-10-21)
    j.feed("look")
    j.feed(f"1 {COLOUR}")
    j.feed("services")
    j.feed("")                                             # -> Review: the record is written
    assert fs.stage == "review"
    return _record_bytes()


def test_the_image_route_the_fleet_window_and_the_fleet_text_twin_write_the_same_bytes(
        fleet_page):
    image = _image_route_bytes()
    window = _fleet_window_bytes(fleet_page)
    text = _fleet_text_bytes()
    assert window == image, (window.decode(), image.decode())
    assert text == image, (text.decode(), image.decode())
    assert b'"title": "Acme Mesh"' in image and b'"primary": "#336699"' in image


def test_the_fleet_window_and_its_text_twin_offer_the_same_drop_down(fleet_page):
    fleet_page._goto(fleet_mod.STEP_SHARED)
    gui = fleet_page.brand_picker.item_labels()
    j = Journey(GENERATOR_DIR)
    j.goto("fleet")
    j.feed("brand")
    text = [ln.strip().lstrip("*").strip().split(". ", 1)[1] for ln in j.lines()
            if ln.strip().lstrip("*")[:1].isdigit() and ". " in ln.strip()[:6]]
    assert gui[0] == "Create a new superbrand" and text[:len(gui)] == gui


def test_every_step_of_the_fleet_window_fits_760_by_700_and_so_do_the_tabs(qapp, monkeypatch):
    """The audit measured a 103 px sideways scroll on every step (the Tor tick-box's
    765 px text in a 722 px viewport). It scrolls nowhere now, the new Superbrand step
    included, and the four tabs of the Brand settings screen fit as well."""
    monkeypatch.setattr("hugmesh_studio.core.build_driver.detect",
                        lambda builder_image="hugmesh-builder": HOST)
    win = fleet_mod.FleetWindow(GENERATOR_DIR)
    try:
        win.resize(760, 700)
        win.show()
        for _ in range(4):
            qapp.processEvents()
        scroll = win.findChild(QtWidgets.QScrollArea)
        page = win.page
        page.cluster_domain.setText("mesh.example")
        for i in range(fleet_mod.STEP_REVIEW):
            page._goto(i)
            for _ in range(3):
                qapp.processEvents()
            assert scroll.horizontalScrollBar().maximum() == 0, (
                f"{fleet_mod._STEP_TITLES[i]}: scrolls "
                f"{scroll.horizontalScrollBar().maximum()}px sideways")
        page._goto(fleet_mod.STEP_DOMAINS)
        page.domains_table._add("shop.example", "Shop")
        page._next()
        page._goto(fleet_mod.STEP_DOMAIN_SERVICES)
        page.domain_services._step(1)
        for title in ("Identity", "Look", "Services", "Ways to reach it"):
            page.domain_services.brand_tabs.open_tab(title)
            for _ in range(3):
                qapp.processEvents()
            assert scroll.horizontalScrollBar().maximum() == 0, title
    finally:
        win.close()
        win.deleteLater()


def test_the_fleet_keeps_its_own_flow_when_nobody_touches_the_superbrand(fleet_page):
    """Red when a Next through the new step writes anything: an untouched superbrand
    leaves the fleet's configuration and the state folder exactly as they were."""
    fleet_page.cluster_domain.setText("mesh.example")
    for _ in range(fleet_mod.STEP_REVIEW):
        if fleet_page.stack.currentIndex() >= fleet_mod.STEP_REVIEW:
            break
        fleet_page.next_btn.click()
    assert fleet_page.stack.currentIndex() == fleet_mod.STEP_REVIEW
    assert fleet_page.cluster_domain.text() == "mesh.example"
    assert fleet_page.brand_profile.text() == ""
    assert not os.path.exists(brand_model.record_path())
