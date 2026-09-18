"""The per-domain Services step and the gate it makes real (#494 / #495).

    "make sure that the service configuration is integrated into the domain setup
     instead of its own separate thing. make sure that for each domain, the service
     page needs to be config, so there's basically a service page per domain you make
     you have to go through before building or starting a mesh in docker or nodes"
                                                        — the operator, 2026-09-17

Four things are pinned here, in the order they can fail:

1. **THE PAGE IS IN THE DOMAIN FLOW.** A registered wizard step right after Domains, in
   mesh and in cloud, skipped where there is no domain to ask about and skipped
   statically on standalone (which has no admin plane at all).
2. **ONE DOMAIN AT A TIME.** The page shows exactly one domain's catalogue and steps;
   what it shows is the domain-scoped catalogue and NOT the node/cluster-plane infra
   slugs, which would be a per-domain lie.
3. **THE GATE REFUSES, AND NAMES THE DOMAIN.** Both doors — the image build
   (``LaunchPage``) and the docker mesh start (``LocalMeshPage._bootstrap_up``) — go
   through the ONE seam ``core.domain_services.gate_reason``, so the refusal can be
   driven with a bare ``ImageConfig`` and no build, no docker and no display.
4. **BACKWARD COMPATIBILITY.** A domain loaded from an older worklist keeps its slugs
   AND counts as unconfigured until someone goes through it — never a silently invented
   selection, and never a silently dropped one.

Nothing here calls ``.exec()``. The page opens no dialog at all (a source scan below
pins that), because a modal in ``validatePage``/``itemChanged`` hangs this suite
forever — the repo's no-modals-in-page-logic rule.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import domain_services as ds          # noqa: E402
from hugmesh_studio.core.config import (                       # noqa: E402
    INFRA_SERVICES_CHOICES, OPTIONAL_SERVICES_CHOICES, SERVICE_DESCRIPTIONS,
    SERVICE_GROUPS, Domain, ImageConfig)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


# ── 0. the seam, with no Qt at all ──────────────────────────────────────────────
def test_gate_passes_when_there_are_no_domains():
    assert ds.gate_reason(ImageConfig()) == ""


def test_gate_names_every_unconfigured_domain():
    cfg = ImageConfig(domains=[Domain(name="a.example"), Domain(name="b.example")])
    msg = ds.gate_reason(cfg)
    assert "a.example" in msg and "b.example" in msg
    assert "2 domains" in msg


def test_gate_names_the_action_it_refused():
    cfg = ImageConfig(domains=[Domain(name="a.example")])
    assert "build these images" in ds.gate_reason(cfg, ds.ACTION_IMAGE_BUILD)
    assert "start this mesh" in ds.gate_reason(cfg, ds.ACTION_MESH_START)


def test_an_empty_selection_is_a_real_answer_once_the_domain_is_configured():
    """``optional_services == []`` means "the cluster-wide set applies" — a real
    answer, and the reason emptiness could not double as "never configured"."""
    cfg = ImageConfig(domains=[Domain(name="a.example", optional_services=[])])
    assert ds.gate_reason(cfg) != ""
    ds.record_reviewed(cfg, ["a.example"])
    assert ds.gate_reason(cfg) == ""
    assert cfg.domains[0].optional_services == []


def test_a_marker_for_a_domain_that_no_longer_exists_is_dropped():
    """REBUILT, never merged: a renamed or deleted domain must not leave a marker that
    would let the gate pass for a domain nobody configured."""
    cfg = ImageConfig(domains=[Domain(name="a.example")])
    ds.record_reviewed(cfg, ["a.example", "ghost.example"])
    assert cfg.domain_services_reviewed == ["a.example"]
    cfg.domains = [Domain(name="renamed.example")]
    ds.record_reviewed(cfg, cfg.domain_services_reviewed)
    assert cfg.domain_services_reviewed == []
    assert "renamed.example" in ds.gate_reason(cfg)


def test_the_marker_never_reaches_either_mesh_manifest():
    """It is the GATE's bookkeeping, not provisioning data — a manifest must be
    byte-identical whether or not the page was walked."""
    cfg = ImageConfig(domains=[Domain(name="a.example")])
    before = cfg.mesh_manifest()
    ds.record_reviewed(cfg, ["a.example"])
    assert cfg.mesh_manifest() == before
    assert "domain_services_reviewed" not in cfg.mesh_manifest()
    assert all("domain_services_reviewed" not in d
               for d in cfg.mesh_manifest()["domains"])


def test_the_marker_round_trips_through_a_saved_config():
    cfg = ImageConfig(domains=[Domain(name="a.example")])
    ds.record_reviewed(cfg, ["a.example"])
    again = ImageConfig.from_dict(cfg.to_dict())
    assert again.domain_services_reviewed == ["a.example"]
    assert ds.gate_reason(again) == ""


def test_a_junk_marker_fails_closed_not_open():
    """A hand-edited config whose marker is not a list must NOT stand in for "all
    reviewed" — absent is the fail-closed reading and the gate then says so."""
    cfg = ImageConfig.from_dict({"domains": [{"name": "a.example"}],
                                 "domain_services_reviewed": "everything"})
    assert cfg.domain_services_reviewed == []
    assert "a.example" in ds.gate_reason(cfg)


def test_the_domain_catalogue_is_the_user_level_set_and_excludes_infra():
    assert tuple(ds.DOMAIN_CATALOGUE) == tuple(OPTIONAL_SERVICES_CHOICES)
    for slug in INFRA_SERVICES_CHOICES:
        assert slug not in ds.DOMAIN_CATALOGUE
        assert ds.scope_of(slug) == ds.SCOPE_NODE
    for slug in ds.DOMAIN_CATALOGUE:
        assert ds.scope_of(slug) == ds.SCOPE_DOMAIN


def test_normalisation_is_catalogue_order_with_extras_last():
    """DISCRIMINATING PAIR: games/owncast is where catalogue order (… games, owncast,
    tube …) and SERVICE_GROUPS presentation order ("Media & Play" = owncast, tube,
    games) DISAGREE, so this can tell the two apart."""
    assert ds.normalise_slugs(["owncast", "games"]) == ["games", "owncast"]
    assert ds.normalise_slugs(["tor", "akkoma"]) == ["akkoma", "tor"]
    assert ds.carried_over_slugs(["tor", "akkoma"]) == ["tor"]


def test_a_catalogue_slug_missing_from_the_grouping_is_still_offered(monkeypatch):
    """SERVICE_GROUPS is presentation; DOMAIN_CATALOGUE is the catalogue. If the two
    drift, the slug must still be offered rather than silently vanish — the exact
    quiet-drop failure this surface has had before."""
    monkeypatch.setattr(ds, "SERVICE_GROUPS",
                        (("Social & Community", ("akkoma",)),))   # drops 7 slugs
    offered = [s for _g, slugs in ds.grouped_domain_catalogue() for s in slugs]
    assert sorted(offered) == sorted(OPTIONAL_SERVICES_CHOICES)
    assert "Other services" in [g for g, _s in ds.grouped_domain_catalogue()]


def test_regrouping_cannot_change_what_a_domain_emits(monkeypatch):
    """SERVICE_GROUPS is presentation ONLY. If a presentation order leaked into the
    recorded value, moving a slug between two group tuples — a purely cosmetic edit —
    would rewrite the bytes of domains[].optional_services in the mesh manifest."""
    def _reordered(slugs):
        rest = [s for s in slugs if s != "games"]
        return ("games", *rest)
    swapped = tuple((title, _reordered(slugs) if "games" in slugs else slugs)
                    for title, slugs in SERVICE_GROUPS)
    assert swapped != SERVICE_GROUPS, "the regrouping mutation did not change anything"
    before = ds.normalise_slugs(["owncast", "games"])
    before_groups = ds.grouped_domain_catalogue()
    monkeypatch.setattr(ds, "SERVICE_GROUPS", swapped)
    after_groups = ds.grouped_domain_catalogue()
    assert before_groups != after_groups, "the regrouping changed no presentation"
    assert ds.normalise_slugs(["owncast", "games"]) == before == ["games", "owncast"]


# ── the Qt half ────────────────────────────────────────────────────────────────
pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo          # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod             # noqa: E402
from hugmesh_studio.gui.pages import domain_services as page_mod  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                     # noqa: E402

from _helpers import (  # noqa: E402
    advance_to, check_worklist_rows, enable_additional_domains, pick_mode)

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
