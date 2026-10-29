"""The Ways tab's ‘Set up ways to reach this brand’ button opens the Go-Live wizard
with that domain filled in — on every host that draws it (2026-10-21).

Before this, the button emitted ``ways_requested`` and nothing listened: pressing it did
nothing on the image route, the Docker mesh or the Fleet window. Each test below builds
the REAL host, opens the domain's Ways tab, presses the REAL button, and checks that a
Go-Live wizard is on screen with the domain in its Public domain field.

The driver's ``status`` is pinned (as tests/test_golive_wizard.py does) so no test
reads or changes this machine's go-live posture; nothing past the wizard's first step
is run.
"""
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import Domain, ImageConfig                    # noqa: E402
from hugmesh_studio.core.fleet import FleetDriver                             # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                        # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                # noqa: E402
from hugmesh_studio.gui.pages import fleet as fleet_mod                       # noqa: E402
from hugmesh_studio.gui.pages import golive as golive_mod                     # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod               # noqa: E402
from hugmesh_studio.gui.pages.golive import GOLIVE_PAGE_SLUGS                 # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                   # noqa: E402
from hugmesh_studio.tui import brand_step                                     # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")
WAYS = "Ways to reach it"
#: where the screenshots go when HUGMESH_STUDIO_SHOTS names a folder (unset: none taken)
SHOTS = os.environ.get("HUGMESH_STUDIO_SHOTS", "")


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-ways-button-tests"])


@pytest.fixture(autouse=True)
def _pinned(monkeypatch, tmp_path):
    monkeypatch.setattr(golive_mod.GoLiveDriver, "status_text",
                        lambda self: "Go-live status\n  posture: INTERNAL")
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr("hugmesh_studio.core.build_driver.detect",
                        lambda builder_image="hugmesh-builder": HOST)


def _shot(widget, name: str) -> None:
    if SHOTS:
        os.makedirs(SHOTS, exist_ok=True)
        widget.grab().save(os.path.join(SHOTS, name))


def _inputs(wiz):
    return wiz._pages[GOLIVE_PAGE_SLUGS.index("inputs")]


def _press_and_check(host, body, name: str, shot: str, shot_of=None):
    """Open ``name``'s Ways tab on ``host``, check the button is there to be pressed,
    press it, and check the Go-Live wizard it opened. Returns the wizard."""
    tabs = body.brand_tabs
    assert tabs.view is not None and tabs.view.name == name
    tabs.open_tab(WAYS)
    assert tabs.current_title() == WAYS
    QtWidgets.QApplication.processEvents()
    btn = tabs.ways_btn
    assert btn.isVisible() and btn.isEnabled(), "the button must be on screen"
    assert btn.width() >= 120 and btn.height() >= 24, (btn.width(), btn.height())
    assert tabs.ways_note.text() == brand_step.WAYS_HOME
    _shot(shot_of or host, shot + "-ways-tab.png")
    assert body._golive is None
    btn.click()
    wiz = body._golive
    assert isinstance(wiz, golive_mod.GoLiveWizard), "pressing it opened nothing"
    assert wiz.isVisible()
    assert wiz.generator_dir == os.path.abspath(GENERATOR_DIR)
    inputs = _inputs(wiz)
    assert inputs.domain.text() == name
    assert inputs.domain_hint.text() == golive_mod.FROM_WAYS_TAB_HINT
    assert wiz.opts.domain == name
    assert wiz.windowTitle().endswith(name)                 # said from the first step
    if SHOTS:
        _shot(wiz, shot + "-go-live-opened.png")
        inputs.resize(820, 520)
        _shot(inputs, shot + "-go-live-inputs.png")
    return wiz


def _close(wiz):
    if wiz is not None:
        wiz.close()
        wiz.deleteLater()


# ── the image route: the build wizard's Brand settings page ─────────────────────────
def test_the_image_route_button_opens_go_live_with_its_domain(qapp):
    cfg = ImageConfig()
    cfg.mode = "mesh"
    cfg.domains = [Domain(name="shop.example", title="Shop")]
    page = ds_mod.DomainServicesPage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))
    page.resize(900, 700)
    page.initializePage()
    page.show()
    page._step(1)                                          # past the own domain
    wiz = _press_and_check(page, page, "shop.example", "image")
    try:
        # the Inputs step keeps what the button filled in (it autofills only an
        # empty field), so Next through the first steps still has the domain
        _inputs(wiz).initializePage()
        assert _inputs(wiz).domain.text() == "shop.example"
    finally:
        _close(wiz)
        page.close()


# ── the Docker mesh: the Local mesh page's Brand settings ────────────────────────────
def test_the_docker_route_button_opens_go_live_with_its_domain(qapp):
    page = localmesh_mod.LocalMeshPage(
        SimpleNamespace(generator_dir=GENERATOR_DIR, cfg=ImageConfig(mode="mesh")))
    page.initializePage()
    page.mesh_domains.domains.append(Domain(name="acme.example", title="Acme"))
    body = page.domain_services
    body.load(page.mesh_domains)
    host = body.window()
    host.resize(900, 760)
    host.show()
    body._step(1)                                          # acme.example
    wiz = _press_and_check(host, body, "acme.example", "docker", shot_of=body)
    _close(wiz)
    host.close()


# ── the Fleet window ─────────────────────────────────────────────────────────────────
def test_the_fleet_button_opens_go_live_with_its_domain(qapp):
    page = fleet_mod.FleetPage(GENERATOR_DIR)
    page.driver = FleetDriver(GENERATOR_DIR, HOST)
    page.driver._image_present = lambda: True
    page.driver.run = lambda *a, **k: 0
    page.resize(900, 760)
    page.show()
    page.cluster_domain.setText("mesh.example")
    while page.stack.currentIndex() < fleet_mod.STEP_DOMAINS:
        page.next_btn.click()
    page.domains_table._add("acme.example", "Acme")
    page.next_btn.click()                                  # -> Brand settings
    assert page.stack.currentIndex() == fleet_mod.STEP_DOMAIN_SERVICES
    page.domain_services._step(1)                          # acme.example
    wiz = _press_and_check(page, page.domain_services, "acme.example", "fleet")
    _close(wiz)
    page.close()
    page.deleteLater()


# ── one wizard per host, never a run thrown away ─────────────────────────────────────
def test_a_second_press_refills_the_open_wizard_until_it_is_past_inputs(qapp):
    first = golive_mod.open_go_live(GENERATOR_DIR, "shop.example")
    try:
        again = golive_mod.open_go_live(GENERATOR_DIR, "blog.example", current=first)
        assert again is first
        assert _inputs(first).domain.text() == "blog.example"
        # past the Inputs step: a new wizard, the old run left as it was
        inputs_id = list(first.pageIds())[GOLIVE_PAGE_SLUGS.index("inputs")]
        first.setStartId(inputs_id)
        first.restart()
        first.next()
        assert not first.before_inputs()
        other = golive_mod.open_go_live(GENERATOR_DIR, "news.example", current=first)
        try:
            assert other is not first
            assert _inputs(other).domain.text() == "news.example"
            assert _inputs(first).domain.text() == "blog.example"
        finally:
            _close(other)
        # a closed wizard is not reused either
        first.close()
        reopened = golive_mod.open_go_live(GENERATOR_DIR, "x.example", current=first)
        assert reopened is not first and reopened.isVisible()
        _close(reopened)
    finally:
        _close(first)


# ── a host that cannot open the wizard draws no button ───────────────────────────────
def test_a_host_with_no_checkout_draws_no_button_and_names_the_option(qapp):
    from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains
    state = LocalMeshDomains(domains=[Domain(name="mesh.example"),
                                      Domain(name="acme.example")],
                             own_name="mesh.example")
    page = localmesh_mod.LocalMeshPage(
        SimpleNamespace(generator_dir=GENERATOR_DIR, cfg=ImageConfig(mode="mesh")))
    session = page.brand_session()
    widget = ds_mod.DomainServicesWidget(brand_session=lambda: session, route="docker")
    widget.load(state)
    widget.resize(900, 700)
    widget.show()
    widget._step(1)
    tabs = widget.brand_tabs
    tabs.open_tab(WAYS)
    QtWidgets.QApplication.processEvents()
    assert not tabs.ways_btn.isVisible()
    assert tabs.ways_note.text() == brand_step.WAYS_HOME_NO_BUTTON
    assert "--go-live" in tabs.ways_note.text()
    tabs.ways_btn.click()                                  # even if reached: nothing opens
    assert widget._golive is None
    widget.close()
