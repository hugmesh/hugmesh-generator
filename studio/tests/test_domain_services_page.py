"""The per-domain Services STEP, as a GUI surface (#494/#495).

The model and the gate are tested Qt-free in tests/test_domain_services.py — that
split is deliberate: the pre-merge CI job installs no Qt binding, and the
`importorskip` below skips this whole module there, so anything that must run on every
pre-merge run has to live in the other file.

What is pinned here is what only a real wizard can answer:

* the step is registered in the domain flow, right after Domains, with the right
  skip rules;
* it shows ONE domain at a time and steps through them — the literal sense of "a
  service page per domain you make you have to go through";
* it offers the domain-scoped catalogue and NOT the node/cluster-plane infra slugs,
  with each service's description in the open rather than on hover;
* what a walk RECORDS, and what it deliberately does not;
* backward compatibility for a domain loaded from an older worklist;
* both gates refusing through the real pages.

Nothing here calls `.exec()`; a source scan pins that the page opens no dialog at all,
because a modal in `validatePage`/`itemChanged` hangs this suite forever.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import domain_services as ds                 # noqa: E402
from hugmesh_studio.core.config import (                              # noqa: E402
    INFRA_SERVICES_CHOICES, OPTIONAL_SERVICES_CHOICES, SERVICE_DESCRIPTIONS,
    SERVICE_GROUPS, Domain, ImageConfig)
from hugmesh_studio.core.platform_info import HostInfo                # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                   # noqa: E402
from hugmesh_studio.gui.pages import domain_services as page_mod      # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                           # noqa: E402

from _helpers import (  # noqa: E402
    advance_to, check_worklist_rows, enable_additional_domains, pick_mode)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-domain-services-page"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _mesh_with_domains(wiz, *names):
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86")
    enable_additional_domains(wiz)
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    for n in names:
        dom._add(n, n.split(".")[0].title())
    return dom


# ── 1. the page is a step in the domain flow ───────────────────────────────────
def test_the_step_is_registered_right_after_domains():
    from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS
    i = WIZARD_PAGE_SLUGS.index("domains")
    assert WIZARD_PAGE_SLUGS[i + 1] == "domain_services"


def test_standalone_skips_it_statically():
    from hugmesh_studio.core.config import MODE_SKIPPED_PAGES
    assert "domain_services" in MODE_SKIPPED_PAGES["standalone"]
    assert "domain_services" not in MODE_SKIPPED_PAGES["cloud"]
    assert "domain_services" not in MODE_SKIPPED_PAGES["mesh"]


def test_a_mesh_flow_lands_on_it_after_domains(wiz):
    _mesh_with_domains(wiz, "acme.example")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.current_domain() == "acme.example"


def test_it_is_skipped_when_no_domain_is_named(wiz):
    """Emission-neutral: with no named domain there is nothing to record and nothing
    for the gate to refuse, so skipping cannot smuggle a domain past it."""
    page = wiz.page(wiz._page_ids["domain_services"])
    assert not page.applies_to(ImageConfig(mode="mesh", additional_domains=True))
    cfg = ImageConfig(mode="mesh", additional_domains=True,
                      domains=[Domain(name="acme.example")])
    assert page.applies_to(cfg)


# ── 2. one domain at a time, with the right catalogue ──────────────────────────
def test_it_shows_one_domain_at_a_time_and_says_which(wiz):
    _mesh_with_domains(wiz, "acme.example", "beta.example")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.current_domain() == "acme.example"
    assert "acme.example" in page.title()
    assert "1 of 2" in page.subTitle()
    page._step(1)
    assert page.current_domain() == "beta.example"
    assert "beta.example" in page.title()
    assert "2 of 2" in page.subTitle()


def test_it_offers_the_domain_catalogue_and_not_the_infra_slugs(wiz):
    """The #227 rule survives being promoted to a page: the infra slugs are node- or
    cluster-plane scoped, so a per-DOMAIN checkbox for them would be a new lie."""
    _mesh_with_domains(wiz, "acme.example")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert sorted(page._boxes) == sorted(OPTIONAL_SERVICES_CHOICES)
    for infra in INFRA_SERVICES_CHOICES:
        assert infra not in page._boxes


def test_every_offered_service_shows_its_description_in_the_open(wiz):
    """A column, not a tooltip: "the operator can see without reading source" is the
    ask, and a hover is not seeing."""
    _mesh_with_domains(wiz, "acme.example")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    for slug, item in page._rows.items():
        assert item.text(page_mod._COL_DESC) == SERVICE_DESCRIPTIONS[slug]


def test_the_rows_are_grouped_by_service_groups(wiz):
    _mesh_with_domains(wiz, "acme.example")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    groups = [page.table.topLevelItem(i).text(page_mod._COL_NAME)
              for i in range(page.table.topLevelItemCount())]
    expected = [g for g, slugs in SERVICE_GROUPS
                if any(s in OPTIONAL_SERVICES_CHOICES for s in slugs)]
    assert groups == expected
    assert len(groups) > 1, "a flat list is not grouped"


def test_the_page_says_the_selection_is_not_yet_enforced(wiz):
    """HONESTY, and it is not optional: a REQUIRED page that implies the mesh will run
    only what was chosen is worse than the optional menu it replaced."""
    _mesh_with_domains(wiz, "acme.example")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    note = page.enforcement.text()
    assert "NOT YET ENFORCED AT THE CLUSTER" in note
    assert "all fifteen" in note
    assert page.enforcement.isVisibleTo(page)


def test_the_page_opens_no_dialog_at_all(wiz):
    """No modal in page logic: a QMessageBox or .exec() in validatePage/itemChanged
    hangs this suite forever with nobody to dismiss it."""
    import inspect
    src = inspect.getsource(page_mod)
    body = src[src.index("class DomainServicesPage"):]
    assert "QMessageBox" not in body
    assert ".exec(" not in body


# ── 3. what a walk records ─────────────────────────────────────────────────────
def test_ticking_reaches_cfg_and_the_mesh_manifest_in_catalogue_order(wiz):
    _mesh_with_domains(wiz, "acme.example")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    page._boxes["owncast"].setChecked(True)
    page._boxes["games"].setChecked(True)
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domains[0].optional_services == ["games", "owncast"]
    assert wiz.cfg.mesh_manifest()["domains"][0]["optional_services"] == \
        ["games", "owncast"]


def test_walking_one_of_two_domains_leaves_the_other_unconfigured(wiz):
    """THE GATE'S REASON TO EXIST. Stepping is what records a domain; a domain the
    operator never opened is not configured, and is named downstream."""
    _mesh_with_domains(wiz, "acme.example", "beta.example")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.unconfigured() == ["beta.example"]
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domain_services_reviewed == ["acme.example"]
    assert ds.unconfigured_domains(wiz.cfg) == ["beta.example"]


def test_stepping_through_every_domain_clears_the_gate(wiz):
    _mesh_with_domains(wiz, "acme.example", "beta.example")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    page._step(1)
    assert page.unconfigured() == []
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert ds.gate_reason(wiz.cfg) == ""


def test_validate_page_records_but_never_refuses(wiz):
    """It RECORDS. collect_all() re-runs a visited page's validatePage to harvest it,
    so a False here would make SAVING a config depend on where the operator was
    standing — and the refusal belongs at the build screen, where it can be acted on."""
    _mesh_with_domains(wiz, "acme.example", "beta.example")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.unconfigured() == ["beta.example"]
    assert page.validatePage() is True


def test_a_per_domain_selection_does_not_leak_onto_the_next_domain(wiz):
    _mesh_with_domains(wiz, "acme.example", "beta.example")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    page._boxes["akkoma"].setChecked(True)
    page._step(1)
    assert not page._boxes["akkoma"].isChecked()
    page._boxes["phpbb"].setChecked(True)
    page.validatePage()
    by_name = {d.name: d.optional_services for d in wiz.cfg.domains}
    assert by_name == {"acme.example": ["akkoma"], "beta.example": ["phpbb"]}


# ── 4. backward compatibility ──────────────────────────────────────────────────
def test_a_loaded_domain_keeps_its_slugs_and_still_counts_as_unconfigured(wiz):
    """Never a silently invented selection, never a silently dropped one: the slugs
    ride forward pre-ticked, and the domain is still named by the gate until someone
    has actually been through it."""
    c = wiz.cfg
    c.mode, c.role, c.additional_domains = "mesh", "omnibus", True
    c.domains = [Domain(name="acme.example", optional_services=["phpbb", "owncast"]),
                 Domain(name="beta.example", optional_services=["akkoma"])]
    wiz.restart()
    assert ds.unconfigured_domains(c) == ["acme.example", "beta.example"]
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.current_domain() == "acme.example"
    assert page.selected_slugs() == ["phpbb", "owncast"]
    assert page._boxes["phpbb"].isChecked() and page._boxes["owncast"].isChecked()
    assert page.unconfigured() == ["beta.example"]


def test_a_slug_this_build_does_not_offer_is_kept_and_pre_ticked(wiz):
    c = wiz.cfg
    c.mode, c.role, c.additional_domains = "mesh", "omnibus", True
    c.domains = [Domain(name="acme.example", optional_services=["akkoma", "tor"])]
    wiz.restart()
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert "tor" in page._boxes and page._boxes["tor"].isChecked()
    assert "kept from your config" in page._rows["tor"].text(page_mod._COL_NAME)
    # The row still says WHAT IT IS as well as where it came from: every infra slug
    # has a SERVICE_DESCRIPTIONS entry, and an infra slug typed into the pre-#227
    # freeform cell is the commonest way one reaches a domain row.
    desc = page._rows["tor"].text(page_mod._COL_DESC)
    assert SERVICE_DESCRIPTIONS["tor"] in desc
    assert ds.CARRIED_OVER_NOTE in desc
    page.validatePage()
    assert wiz.cfg.domains[0].optional_services == ["akkoma", "tor"]


def test_a_config_that_already_recorded_its_domains_is_not_asked_twice(wiz):
    c = wiz.cfg
    c.mode, c.role, c.additional_domains = "mesh", "omnibus", True
    c.domains = [Domain(name="acme.example"), Domain(name="beta.example")]
    c.domain_services_reviewed = ["acme.example", "beta.example"]
    wiz.restart()
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.unconfigured() == []
    assert ds.gate_reason(wiz.cfg) == ""


def test_the_page_resumes_on_the_first_domain_that_still_needs_walking(wiz):
    c = wiz.cfg
    c.mode, c.role, c.additional_domains = "mesh", "omnibus", True
    c.domains = [Domain(name="acme.example"), Domain(name="beta.example")]
    c.domain_services_reviewed = ["acme.example"]
    wiz.restart()
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.current_domain() == "beta.example"


# ── 5. the gate: the image build ───────────────────────────────────────────────
def _launch_page(wiz):
    return wiz.page(wiz._page_ids["launch"])


def test_launch_refuses_the_build_and_names_the_domain(wiz):
    page = _launch_page(wiz)
    wiz.cfg.domains = [Domain(name="unconfigured.example")]
    wiz.cfg.domain_services_reviewed = []
    assert page._refuse() is True
    assert "unconfigured.example" in page.gate_err.text()
    assert not page.gate_err.isHidden()
    assert not page.continue_card.isEnabled()
    assert page.validatePage() is False


def test_launch_lets_a_configured_build_through(wiz):
    page = _launch_page(wiz)
    wiz.cfg.domains = [Domain(name="acme.example")]
    ds.record_reviewed(wiz.cfg, ["acme.example"])
    assert page._refuse() is False
    assert page.gate_err.isHidden()
    assert page.continue_card.isEnabled()
    assert page.validatePage() is True


def test_the_wizards_own_next_is_not_a_way_around_the_launch_gate(wiz):
    """The Continue CARD is disabled by the gate, but QWizard's own Next button is not
    the card — without validatePage refusing too, the gate would be a disabled button
    the operator simply walks around."""
    page = _launch_page(wiz)
    wiz.cfg.domains = [Domain(name="unconfigured.example")]
    wiz.cfg.domain_services_reviewed = []
    assert page.validatePage() is False


def test_the_launch_gate_uses_the_one_seam(wiz):
    page = _launch_page(wiz)
    wiz.cfg.domains = [Domain(name="unconfigured.example")]
    assert page.gate_refusal() == ds.gate_reason(wiz.cfg, ds.ACTION_IMAGE_BUILD)


# ── 6. the gate: the docker mesh start ─────────────────────────────────────────
@pytest.fixture
def local_mesh_page(qapp):
    from types import SimpleNamespace
    from hugmesh_studio.gui.pages.localmesh import LocalMeshPage
    cfg = ImageConfig()
    return LocalMeshPage(SimpleNamespace(generator_dir=GENERATOR_DIR, cfg=cfg))


def test_the_docker_mesh_start_refuses_and_names_the_domain(local_mesh_page,
                                                            monkeypatch):
    page = local_mesh_page
    page.wiz.cfg.domains = [Domain(name="unconfigured.example")]
    started = []
    monkeypatch.setattr(page, "_launch",
                        lambda *a, **k: started.append(a))
    page._bootstrap_up()
    assert started == [], "a refused start must not launch the bootstrap verb"
    assert "unconfigured.example" in page.status.text()
    assert "start this mesh" in page.status.text()


def test_the_docker_mesh_start_proceeds_once_every_domain_is_configured(
        local_mesh_page, monkeypatch):
    page = local_mesh_page
    page.wiz.cfg.domains = [Domain(name="acme.example")]
    ds.record_reviewed(page.wiz.cfg, ["acme.example"])
    assert page._domain_services_refusal() == ""
    started = []
    monkeypatch.setattr(page, "_launch", lambda *a, **k: started.append(a))
    page._bootstrap_up()
    assert started, "a configured mesh must still start"


def test_a_local_mesh_flow_with_no_domains_is_not_gated(local_mesh_page):
    """The local-mesh bootstrap has ONE cluster_domain and no domains table, so on a
    flow that never filled that table there is nothing to refuse. Pinned so the gate
    cannot quietly become a blanket block on the docker lane."""
    assert local_mesh_page.wiz.cfg.domains == []
    assert local_mesh_page._domain_services_refusal() == ""


def test_the_mesh_start_gate_uses_the_one_seam(local_mesh_page):
    page = local_mesh_page
    page.wiz.cfg.domains = [Domain(name="unconfigured.example")]
    assert page._domain_services_refusal() == \
        ds.gate_reason(page.wiz.cfg, ds.ACTION_MESH_START)
