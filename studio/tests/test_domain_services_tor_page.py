"""The ‘Tor front door’ row on the per-domain services surface — GUI and TUI (#582).

Operator decision 68 = A on #347: ``tor`` is the ONE infra slug with a per-domain
spelling ("a Tor domain = its own HiddenService stanza fronting the SAME gateway,
distinguished by the onion Host"); decision 71 = A: the TUI in the same PR.

What only the real surfaces can answer:

* a domain with ``tor=True`` renders a CHECKED, checkable front-door row whose Scope
  reads "onion (per domain)", and a walk writes ``Domain.tor`` — never
  ``optional_services``;
* the mesh's OWN domain has no control (its front door is the primary onion);
* the services table still offers no infra slug — the relaxed assert admits ``tor``
  alone, and only through the front-door table;
* the inline state says when Tor is off for the mesh, and which login the onion serves;
* the local docker mesh's host of the same body records it on its rows;
* the TUI twin: the same row, command ``t``, the same field.

The GUI half skips without a Qt binding (the Qt-free job); the TUI half never skips.
Nothing here calls ``.exec()`` — every refusal and hint is an inline label.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import domain_services as ds                 # noqa: E402
from hugmesh_studio.core.config import (                              # noqa: E402
    DOMAIN_IDP_OWN, INFRA_SERVICES_CHOICES, Domain)
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains    # noqa: E402
from hugmesh_studio.tui import domain_services_step, journey          # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


# ── TUI (never skipped) ───────────────────────────────────────────────────────────
@pytest.fixture
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _tui_at_added(name="chat.example.org", **dom):
    j = journey.Journey(".")
    for line in ("", "3", "", "1", "", "", "", ""):
        j.feed(line)
    assert j.slug == "domains_choice"
    j.feed("y")
    assert j.slug == "domains"
    j.feed(f"a {name}")
    for k, v in dom.items():
        setattr(j.cfg.domains[-1], k, v)
    j.feed("")
    assert j.slug == "domain_services"
    j.feed("n")                                 # past the own domain
    assert j.screen().current(j).name == name
    return j


def test_tui_front_door_row_toggles_domain_tor_not_the_services(_isolated_state_dir):
    j = _tui_at_added()
    d = j.cfg.domains[0]
    headers, rows = domain_services_step.front_door_table(d)
    assert rows == [["t", "-", ds.TOR_ROW_LABEL, "onion (per domain)", ds.TOR_ROW_DESC]]
    before = list(d.optional_services)
    j.feed("t")
    assert d.tor is True and d.optional_services == before
    assert domain_services_step.front_door_table(d)[1][0][1] == "on"
    text = "\n".join(j.lines())
    assert f"{ds.TOR_ROW_LABEL}: on" in text
    assert "t=toggle the Tor front door" in text
    j.feed("t")
    assert d.tor is False
    # the services table is still the services and nothing else
    h, srows = domain_services_step.service_table(d)
    for infra in INFRA_SERVICES_CHOICES:
        assert infra not in [r[h.index("service")] for r in srows]


def test_tui_own_domain_has_no_toggle(_isolated_state_dir):
    j = _tui_at_added()
    j.feed("p")                                 # back onto the own domain
    own = j.screen().current(j)
    assert own.name == j.cfg.cluster_domain
    j.feed("t")
    assert "own onion" in j.status
    assert not any(getattr(d, "tor", False) for d in j.cfg.domains)
    text = "\n".join(j.lines())
    assert ds.TOR_OWN_DOMAIN_NOTE in text
    assert "t=toggle the Tor front door" not in text


def test_tui_state_line_says_tor_is_off_for_the_mesh(_isolated_state_dir):
    j = _tui_at_added(tor=True)
    j.cfg.optional_services = []
    assert "Tor is off" in "\n".join(j.lines())
    j.cfg.optional_services = ["tor"]
    assert "Tor is off" not in "\n".join(j.lines())


def test_tui_local_mesh_host_records_on_its_rows(_isolated_state_dir):
    md = LocalMeshDomains(domains=[Domain(name="mesh.example"),
                                   Domain(name="b.example", idp=DOMAIN_IDP_OWN)],
                          own_name="mesh.example")
    screen = domain_services_step.DomainServicesScreen(cfg_of=lambda j: md)
    j = journey.Journey(".")
    screen.enter(j)
    screen.feed(j, "t")                         # row 0 is the own domain: refused
    assert md.by_name("mesh.example").tor is False
    screen.feed(j, "n")
    screen.feed(j, "t")
    assert md.by_name("b.example").tor is True
    text = "\n".join(screen.lines(j))
    assert "own login" in text and "must be on for the mesh" in text


# ── GUI (skips only without a Qt binding) ─────────────────────────────────────────
def _qt():
    return pytest.importorskip("hugmesh_studio.gui.qt",
                               reason="no Qt binding (PySide6/PyQt6) installed")


@pytest.fixture(scope="module")
def qapp():
    qt = _qt()
    return (qt.QtWidgets.QApplication.instance()
            or qt.QtWidgets.QApplication(["hugmesh-studio-tor-front-door"]))


@pytest.fixture
def wiz(qapp, monkeypatch):
    from hugmesh_studio.core.platform_info import HostInfo
    from hugmesh_studio.gui import wizard as wizard_mod
    host = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": host)
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _page_at_added(wiz, **dom):
    from _helpers import advance_to
    from hugmesh_studio.gui.pages import domain_services as page_mod
    c = wiz.cfg
    c.mode, c.role, c.additional_domains = "mesh", "omnibus", True
    c.domains = [Domain(name="acme.example", optional_services=["akkoma"], **dom)]
    wiz.restart()
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.current_domain() == wiz.cfg.cluster_domain
    return page


def test_gui_own_domain_front_door_is_data_not_a_control(wiz):
    qt = _qt()
    page = _page_at_added(wiz)
    assert page.front_door_table.topLevelItemCount() == 1
    item = page.front_door_table.topLevelItem(0)
    assert page._tor_box is None
    assert not (item.flags() & qt.Qt.ItemFlag.ItemIsUserCheckable)
    assert item.text(4) == ds.TOR_OWN_DOMAIN_NOTE
    assert item.text(2) == "onion (per domain)"


def test_gui_a_tor_domain_renders_a_checked_row_and_the_walk_records_it(wiz):
    from hugmesh_studio.gui.pages import domain_services as page_mod
    page = _page_at_added(wiz, tor=True)
    page._step(1)
    assert page.current_domain() == "acme.example"
    item = page.front_door_table.topLevelItem(0)
    assert item.text(page_mod._COL_NAME) == ds.TOR_ROW_LABEL
    assert item.text(page_mod._COL_SCOPE) == "onion (per domain)"
    assert page._tor_box is not None and page._tor_box.isChecked()
    assert page.tor_front_door() is True
    page._tor_box.setChecked(False)
    page.validatePage()
    d = wiz.cfg.domains[0]
    assert d.tor is False and d.optional_services == ["akkoma"]
    page._tor_box.setChecked(True)
    page.validatePage()
    assert wiz.cfg.domains[0].tor is True
    assert "tor" not in wiz.cfg.domains[0].optional_services


def test_gui_services_table_offers_no_infra_slug(wiz):
    page = _page_at_added(wiz)
    page._step(1)
    for infra in INFRA_SERVICES_CHOICES:
        assert infra not in page._boxes, infra
    assert page.front_door_table.topLevelItemCount() == len(ds.PER_DOMAIN_INFRA) == 1


def test_gui_inline_state_warns_when_tor_is_off_for_the_mesh(wiz):
    from hugmesh_studio.gui.styles import WARN
    page = _page_at_added(wiz, idp=DOMAIN_IDP_OWN)
    page._step(1)
    # Tor OFF everywhere: mesh-wide (both spellings) and on every worklist node
    wiz.cfg.optional_services = []
    wiz.cfg.tor_onion_service = False
    for e in list(getattr(getattr(wiz, "worklist", None), "entries", None) or ()):
        e.infra_services = ()
    page._tor_box.setChecked(True)
    assert "Tor is off" in page.tor_note.text()
    assert WARN in page.tor_note.styleSheet()
    assert "own login" in page.tor_note.text()
    wiz.cfg.optional_services = ["tor"]
    page._tor_box.setChecked(False)
    page._tor_box.setChecked(True)
    assert "Tor is off" not in page.tor_note.text()
    assert WARN not in page.tor_note.styleSheet()


def test_gui_local_mesh_widget_records_on_its_rows(qapp):
    from hugmesh_studio.gui.pages.domain_services import DomainServicesWidget
    md = LocalMeshDomains(domains=[Domain(name="mesh.example"),
                                   Domain(name="b.example")],
                          own_name="mesh.example")
    w = DomainServicesWidget()
    w.load(md)
    assert w.current_domain() == "mesh.example" and w._tor_box is None
    w._step(1)
    assert w.current_domain() == "b.example"
    w._tor_box.setChecked(True)
    assert "must be on for the mesh" in w.tor_note.text()
    assert "DEFAULT brand" in w.tor_note.text()
    w.record(md)
    assert md.by_name("b.example").tor is True
    assert md.by_name("mesh.example").tor is False
    w.deleteLater()
