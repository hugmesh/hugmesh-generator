"""Per-domain Tor front door — the END-TO-END Studio journeys (hugmesh-generator#582,
operator decision 68 = A on #347; decision 71 = A: the text-mode face in the same PR).

Each test here is a person's route, headless, from the FIRST screen to the EFFECT the
choice has — not a widget or a field read in isolation (studio/tests/
test_domain_services_tor_page.py covers those). Two routes, both faces:

* THE LOCAL DOCKER MESH, the one route that acts on the tick today. GUI: Welcome ->
  Mode "Local Docker mesh" -> Generate -> Env & brand -> Domains (add one) -> Domain
  services (tick the domain's Tor front door) -> ... -> the mesh page, Tor on -> Start.
  The effect is what `make stack-up` is handed: ``TOR_ONION_DOMAINS`` naming the
  domain's key directory and tenant, ``TOR=1``, and a plan that names the onion. Tor
  off for the mesh: the same walk hands over NO per-domain list, and the plan says the
  domain gets no onion. Text-mode: Welcome -> Local Docker mesh -> Generate -> Domains
  -> Domain services (command ``t``) -> review, whose hand-over is the SAME record a
  GUI bring-up keeps (``records()``); that record, given to the bring-up with Tor on,
  yields the same env.
* NODE IMAGES: Welcome -> Mode "mesh" -> ... -> Domains (add one) -> Domain services
  (tick) -> the mesh manifest carries ``domains[].tor: true`` — the whole effect this
  route has today (RECORDED; no builder reads it, and the row says so), GUI and
  text-mode alike.

The GUI half skips without a Qt binding (the Qt-free job); the text-mode half never
skips. Nothing here calls ``.exec()``; no stack, no docker, no root.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import domain_services as ds                 # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import (                # noqa: E402
    LocalMeshBootstrap, LocalMeshBootstrapConfig)
from hugmesh_studio.core.local_mesh_domains import (                  # noqa: E402
    bootstrap_domain_records)
from hugmesh_studio.core.platform_info import HostInfo                # noqa: E402
from hugmesh_studio.tui import journey                                # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

DOMAIN = "acme.example"
SLUG = "acme-example"


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


# ── text-mode (never skipped) ─────────────────────────────────────────────────────
def test_tui_local_mesh_journey_hands_over_the_front_door_the_bring_up_reads(tmp_path):
    j = journey.Journey(".")
    j.feed("")                                  # welcome -> mode
    j.feed("1")                                 # Local Docker mesh
    assert j.slug == "localmesh"
    j.feed("2")                                 # Generate a new mesh
    j.feed(f"a {DOMAIN}")
    j.feed("")                                  # -> Domain services, the own domain
    assert "t=toggle the Tor front door" not in "\n".join(j.lines())
    j.feed("n")                                 # -> acme.example
    assert "t=toggle the Tor front door" in "\n".join(j.lines())
    j.feed("t")
    text = "\n".join(j.lines())
    assert f"{ds.TOR_ROW_LABEL}: on — its own onion, key directory ‘{SLUG}’" in text
    assert ds.TOR_REACH[ds.TOR_ROUTE_COMPOSE] in text
    j.feed("")                                  # -> review
    screen = j.screen_for("localmesh")
    assert screen.stage == "review"
    assert screen.refusal(j) == ""
    recs = screen.records(j)
    row = next(r for r in recs if r["name"] == DOMAIN)
    assert row["tor"] is True
    # the hand-over IS the GUI's own record function on the same rows
    md = j.localmesh_domains
    assert recs == bootstrap_domain_records(md.domains, md.own_name)
    # ...and that record, given to the bring-up with Tor on, is the stack env
    boot = LocalMeshBootstrap(str(tmp_path),
                              LocalMeshBootstrapConfig(with_tor=True, domains=recs))
    env = boot._stack_node()._build_env(write_overlays=False)
    assert env["TOR"] == "1" and env["TOR_ONION_DOMAINS"] == f"{SLUG}=default"
    assert boot.tor_domains() == [(DOMAIN, SLUG, "default")]
    # untoggled again: the record carries no key, the env nothing per-domain.
    # ``b`` from the review lands on the FIRST domain (the mesh's own, whose front
    # door is the mesh's onion — ``t`` has nothing to toggle there), so step onto the
    # added domain first, as a person reading the screen would.
    j.feed("b")
    assert screen.stage == "services"
    j.feed("t")
    assert "nothing to toggle" in j.status
    j.feed("n")
    j.feed("t")
    assert j.status == f"{DOMAIN}: {ds.TOR_ROW_LABEL} -> off"
    assert "tor" not in next(r for r in screen.records(j) if r["name"] == DOMAIN)
    off = LocalMeshBootstrap(str(tmp_path), LocalMeshBootstrapConfig(
        with_tor=True, domains=screen.records(j)))
    assert "TOR_ONION_DOMAINS" not in off._stack_node()._build_env(write_overlays=False)


def test_tui_image_journey_puts_the_front_door_into_the_mesh_manifest():
    j = journey.Journey(".")
    for line in ("", "3", "", "1", "", "", "", ""):
        j.feed(line)
    assert j.slug == "domains_choice"
    j.feed("y")
    assert j.slug == "domains"
    j.feed(f"a {DOMAIN}")
    j.feed("")
    assert j.slug == "domain_services"
    j.feed("n")                                 # past the own domain
    assert j.screen().current(j).name == DOMAIN
    j.feed("t")
    text = "\n".join(j.lines())
    # this route only RECORDS the tick, and says so before the operator relies on it
    assert ds.TOR_REACH[ds.TOR_ROUTE_IMAGE] in text
    doms = j.cfg.mesh_manifest()["domains"]
    assert [d["name"] for d in doms] == [DOMAIN] and doms[0]["tor"] is True
    assert "tor" not in doms[0].get("optional_services", [])
    j.feed("t")
    assert "tor" not in j.cfg.mesh_manifest()["domains"][0]


# ── GUI (skips only without a Qt binding) ─────────────────────────────────────────
def _qt():
    return pytest.importorskip("hugmesh_studio.gui.qt",
                               reason="no Qt binding (PySide6/PyQt6) installed")


@pytest.fixture(scope="module")
def qapp():
    qt = _qt()
    return (qt.QtWidgets.QApplication.instance()
            or qt.QtWidgets.QApplication(["hugmesh-studio-tor-front-door-journey"]))


@pytest.fixture
def wiz(qapp, monkeypatch):
    from hugmesh_studio.gui import wizard as wizard_mod
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _to(wiz, cls, limit=14):
    for _ in range(limit):
        if isinstance(wiz.currentPage(), cls):
            return wiz.currentPage()
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, \
            f"flow stuck on {type(wiz.currentPage()).__name__}"
    raise AssertionError(f"never reached {cls.__name__}: "
                         + type(wiz.currentPage()).__name__)


def test_gui_local_mesh_journey_hands_the_front_door_to_the_stack(wiz, monkeypatch):
    from hugmesh_studio.gui.pages import localmesh as localmesh_mod
    # Welcome -> Mode "Local Docker mesh" -> Generate -> Env & brand
    wiz.next()
    mode = wiz.currentPage()
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    wiz.next()
    wiz.currentPage()._buttons["generate"].setChecked(True)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshEnvPage)
    # Domains: add one
    _to(wiz, localmesh_mod.LocalMeshDomainsPage)
    ctl = wiz.page(wiz._page_ids["localmesh"])
    ctl.domains_table._add(DOMAIN, "Acme")
    # Domain services: the own domain has no front door; the added one gets its tick
    _to(wiz, localmesh_mod.LocalMeshDomainServicesPage)
    body = ctl.domain_services
    assert body._tor_box is None
    body._step(1)
    assert body.current_domain() == DOMAIN and body._tor_box is not None
    body._tor_box.setChecked(True)
    assert ds.TOR_REACH[ds.TOR_ROUTE_COMPOSE] in body.tor_note.text()
    # Back to the Domains step and Next through it again, as a person who goes back to
    # fix a title would: the table has no front-door cell, so it carries the tick by
    # name (gui/pages/domains.py), and the step keeps its working copy for the same
    # walk — either way the tick must still be there, or the stack never sees it.
    while not isinstance(wiz.currentPage(), localmesh_mod.LocalMeshDomainsPage):
        wiz.back()
    _to(wiz, localmesh_mod.LocalMeshDomainServicesPage)
    if body.current_domain() != DOMAIN:
        body._step(1)
    assert body.current_domain() == DOMAIN and body._tor_box.isChecked()
    # on to the mesh page: Tor on for the mesh, then Start
    _to(wiz, localmesh_mod.LocalMeshPage)
    ctl.with_tor.setChecked(True)
    launched = []
    monkeypatch.setattr(ctl, "_launch",
                        lambda label, fn, *a, **k: launched.append(label))
    ctl._bootstrap_up()
    assert launched == ["Bootstrapping"], ctl.status.text()
    boot = ctl.boot
    # THE EFFECT: what `make stack-up` is handed, the plan, and the saved record
    env = boot._stack_node()._build_env(write_overlays=False)
    assert env["TOR"] == "1" and env["TOR_ONION_DOMAINS"] == f"{SLUG}=default"
    assert boot.tor_domains() == [(DOMAIN, SLUG, "default")]
    assert f"{DOMAIN}: its own onion (key ‘{SLUG}’)" in boot.plan()
    rec = next(r for r in boot.cfg.domains if r["name"] == DOMAIN)
    assert rec["tor"] is True
    # Tor off for the mesh: the same walk passes nothing per-domain, and says why
    ctl.with_tor.setChecked(False)
    ctl._bootstrap_up()
    assert launched == ["Bootstrapping", "Bootstrapping"], ctl.status.text()
    env = ctl.boot._stack_node()._build_env(write_overlays=False)
    assert env["TOR"] == "" and "TOR_ONION_DOMAINS" not in env
    assert f"NO onion for the Tor domains ({DOMAIN})" in ctl.boot.plan()


def test_gui_image_journey_puts_the_front_door_into_the_mesh_manifest(wiz):
    from _helpers import advance_to, enable_additional_domains, pick_mode
    from hugmesh_studio.gui import wizard as wizard_mod
    from hugmesh_studio.gui.pages import domain_services as page_mod
    pick_mode(wiz, "mesh")
    enable_additional_domains(wiz)
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    dom._add(DOMAIN, "Acme")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.current_domain() == wiz.cfg.cluster_domain and page._tor_box is None
    page._step(1)
    assert page.current_domain() == DOMAIN
    page._tor_box.setChecked(True)
    # this route only RECORDS the tick, and the page says so before Next is pressed
    assert ds.TOR_REACH[ds.TOR_ROUTE_IMAGE] in page.tor_note.text()
    assert page.validatePage()
    doms = wiz.cfg.mesh_manifest()["domains"]
    assert [d["name"] for d in doms] == [DOMAIN] and doms[0]["tor"] is True
    assert "tor" not in wiz.cfg.domains[0].optional_services
    # and a config saved from here loads with the front door
    from hugmesh_studio.core.config import ImageConfig
    assert ImageConfig.from_dict(wiz.cfg.to_dict()).domains[0].tor is True
    # Back to the Domains table and Next through it again, as a person who goes back
    # to fix a title would: the table has no front-door cell, so it carries the tick
    # BY NAME (gui/pages/domains.py) — or this Next would silently drop the onion.
    from _helpers import back_to
    assert back_to(wiz, wizard_mod.DomainsPage) is dom
    page = advance_to(wiz, page_mod.DomainServicesPage)
    page._step(1)
    assert page.current_domain() == DOMAIN and page._tor_box.isChecked()
    assert wiz.cfg.mesh_manifest()["domains"][0]["tor"] is True
