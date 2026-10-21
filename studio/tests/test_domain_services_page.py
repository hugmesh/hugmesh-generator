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
import copy
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
from hugmesh_studio.gui.pages import domains as domains_mod           # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                       # noqa: E402

from _helpers import (  # noqa: E402
    added_names, added_row, advance_to, back_to, check_worklist_rows,
    enable_additional_domains, pick_mode)

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


def _to_added(wiz):
    """Advance to the services step and past the mesh's OWN domain (#494: it opens
    every mesh walk — being shown records it) onto the first ADDED domain."""
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.current_domain() == wiz.cfg.cluster_domain
    page._step(1)
    return page


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
    # the mesh's OWN domain opens the walk (#494), the added one follows
    assert page.current_domain() == wiz.cfg.cluster_domain
    assert "this mesh's own domain" in page.head.text()
    page._step(1)
    assert page.current_domain() == "acme.example"


def test_it_is_skipped_only_when_no_domain_at_all_is_named(wiz):
    """Leaves the output unchanged: with no named domain — no cluster domain and no table row —
    there is nothing to record and nothing for the gate to refuse, so skipping cannot
    smuggle a domain past it. A mesh with a cluster domain always applies (#494: the
    own domain has a services page), with or without the Domains table."""
    page = wiz.page(wiz._page_ids["domain_services"])
    assert not page.applies_to(ImageConfig(mode="mesh", additional_domains=True,
                                           cluster_domain=""))
    assert page.applies_to(ImageConfig(mode="mesh", additional_domains=False))
    assert page.applies_to(ImageConfig(mode="mesh", additional_domains=True))
    cfg = ImageConfig(mode="mesh", additional_domains=True, cluster_domain="",
                      domains=[Domain(name="acme.example")])
    assert page.applies_to(cfg)


# ── 2. one domain at a time, with the right catalogue ──────────────────────────
def test_it_shows_one_domain_at_a_time_and_says_which(wiz):
    _mesh_with_domains(wiz, "acme.example", "beta.example")
    page = advance_to(wiz, page_mod.DomainServicesPage)
    own = wiz.cfg.cluster_domain
    assert page.current_domain() == own
    assert own in page.title()
    assert "1 of 3" in page.subTitle()
    page._step(1)
    assert page.current_domain() == "acme.example"
    assert "acme.example" in page.title()
    assert "2 of 3" in page.subTitle()
    page._step(1)
    assert page.current_domain() == "beta.example"
    assert "beta.example" in page.title()
    assert "3 of 3" in page.subTitle()


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
    page = _to_added(wiz)
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
    page = _to_added(wiz)
    assert page.unconfigured() == ["beta.example"]
    advance_to(wiz, wizard_mod.UsersChoicePage)
    # the own domain first (it was shown too), then the walked table row
    assert wiz.cfg.domain_services_reviewed == [wiz.cfg.cluster_domain, "acme.example"]
    assert ds.unconfigured_domains(wiz.cfg) == ["beta.example"]


def test_stepping_through_every_domain_clears_the_gate(wiz):
    _mesh_with_domains(wiz, "acme.example", "beta.example")
    page = _to_added(wiz)
    page._step(1)
    assert page.unconfigured() == []
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert ds.gate_reason(wiz.cfg) == ""


def test_validate_page_records_but_never_refuses(wiz):
    """It RECORDS. collect_all() re-runs a visited page's validatePage to harvest it,
    so a False here would make SAVING a config depend on where the operator was
    standing — and the refusal belongs at the build screen, where it can be acted on."""
    _mesh_with_domains(wiz, "acme.example", "beta.example")
    page = _to_added(wiz)
    assert page.unconfigured() == ["beta.example"]
    assert page.validatePage() is True


def test_a_per_domain_selection_does_not_leak_onto_the_next_domain(wiz):
    _mesh_with_domains(wiz, "acme.example", "beta.example")
    page = _to_added(wiz)
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
    page = _to_added(wiz)
    assert page.current_domain() == "acme.example"
    assert page.selected_slugs() == ["phpbb", "owncast"]
    assert page._boxes["phpbb"].isChecked() and page._boxes["owncast"].isChecked()
    assert page.unconfigured() == ["beta.example"]


def test_a_slug_this_build_does_not_offer_is_kept_and_pre_ticked(wiz):
    c = wiz.cfg
    c.mode, c.role, c.additional_domains = "mesh", "omnibus", True
    c.domains = [Domain(name="acme.example", optional_services=["akkoma", "tor"])]
    wiz.restart()
    page = _to_added(wiz)
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
    c.domain_services_reviewed = [c.cluster_domain, "acme.example", "beta.example"]
    wiz.restart()
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.unconfigured() == []
    assert ds.gate_reason(wiz.cfg) == ""


def test_the_page_resumes_on_the_first_domain_that_still_needs_walking(wiz):
    c = wiz.cfg
    c.mode, c.role, c.additional_domains = "mesh", "omnibus", True
    c.domains = [Domain(name="acme.example"), Domain(name="beta.example")]
    c.domain_services_reviewed = [c.cluster_domain, "acme.example"]
    wiz.restart()
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.current_domain() == "beta.example"


# ── 5. the gate: the image build ───────────────────────────────────────────────
def _launch_page(wiz):
    # MESH on purpose. ImageConfig.mode defaults to "standalone", where domains emit
    # no --domains and no mesh manifest is written, so `gate_applies` deliberately does
    # not bite (tests/test_domain_services.py pins that against the emission itself).
    # The gate is about the modes where the domains DO reach a cluster.
    wiz.cfg.mode = "mesh"
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
    ds.record_reviewed(wiz.cfg, [wiz.cfg.cluster_domain, "acme.example"])
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
    # mesh: see _launch_page's note — a standalone config's domains reach nothing.
    cfg = ImageConfig(mode="mesh")
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


# ── 7. THE SELECTION HAS TO SURVIVE TO THE BUILD ───────────────────────────────
# Added while landing #495 after the skeptic pass, which found the whole feature's
# output being thrown away one screen before dispatch — and a REGRESSION against the
# row button it replaced. The wipe was invisible: the gate still passed (the reviewed
# marker survives), so the required page was satisfied and its answer discarded.
#
# MECHANISM, so a future edit knows what it must not re-break: DomainsPage's services
# cell is a read-only MIRROR refreshed only when that page becomes current, so on a
# forward walk it still holds the pre-step slugs. DomainsPage.validatePage does NOT
# run only when the operator leaves that page — collect_all() re-runs every visited
# page's validatePage, BuildPage._preview calls collect_all(), and
# BuildPage.validatePage calls _preview, so collect_all re-enters itself and the LAST
# writer in one Build->Launch transition is DomainsPage, hundreds of times over.
#
# test_ticking_reaches_cfg_... above stops at UsersChoicePage — one page after the
# step, and before BuildPage ever calls collect_all. That is why it stayed green.
def test_the_selection_survives_to_the_launch_screen(wiz):
    """THE REGRESSION TEST. Walks to the LAST door before dispatch, not one page past
    the step."""
    _mesh_with_domains(wiz, "acme.example")
    page = _to_added(wiz)
    page._boxes["akkoma"].setChecked(True)
    page._boxes["owncast"].setChecked(True)
    advance_to(wiz, wizard_mod.LaunchPage)
    assert wiz.cfg.domains[0].optional_services == ["akkoma", "owncast"]
    assert wiz.cfg.mesh_manifest()["domains"][0]["optional_services"] == \
        ["akkoma", "owncast"]


def test_collect_all_is_re_entrant_and_domains_is_not_the_last_word(wiz):
    """Pins the MECHANISM rather than only the symptom: a bare collect_all() must not
    be able to undo the step either, however many times it runs."""
    _mesh_with_domains(wiz, "acme.example")
    page = _to_added(wiz)
    page._boxes["akkoma"].setChecked(True)
    advance_to(wiz, wizard_mod.UsersChoicePage)
    for _ in range(5):
        wiz.collect_all()
    assert wiz.cfg.domains[0].optional_services == ["akkoma"]


def test_editing_a_loaded_rows_services_is_not_reverted_to_what_was_loaded(wiz):
    """The other half of the wipe: a row that arrives WITH slugs. Unticking the loaded
    one and ticking another must not come back as the loaded set."""
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86")
    enable_additional_domains(wiz)
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    dom._add("acme.example", "Acme", ["phpbb"])
    page = _to_added(wiz)
    assert page.selected_slugs() == ["phpbb"]
    page._boxes["phpbb"].setChecked(False)
    page._boxes["games"].setChecked(True)
    advance_to(wiz, wizard_mod.LaunchPage)
    assert wiz.cfg.domains[0].optional_services == ["games"]


def test_the_domains_table_still_owns_which_domains_exist(wiz):
    """The fix moves the SLUGS' authority to cfg; it must not move the ROWS'. Adding,
    renaming and dropping rows still decides what exists."""
    dom = _mesh_with_domains(wiz, "acme.example", "beta.example")
    advance_to(wiz, page_mod.DomainServicesPage)
    back_to(wiz, wizard_mod.DomainsPage)
    dom.table.item(added_row(dom, 1), 0).setText("renamed.example")
    dom._add("third.example", "Third")
    advance_to(wiz, page_mod.DomainServicesPage)
    assert [d.name for d in wiz.cfg.domains] == \
        ["acme.example", "renamed.example", "third.example"]


def test_a_renamed_row_keeps_the_slugs_its_cell_carries(wiz):
    """cfg is consulted BY NAME, so a row cfg does not know yet falls back to the
    cell — which is the only carrier of a renamed row's slugs."""
    dom = _mesh_with_domains(wiz, "acme.example")
    page = _to_added(wiz)
    page._boxes["owncast"].setChecked(True)
    back_to(wiz, wizard_mod.DomainsPage)
    dom.table.item(added_row(dom, 0), 0).setText("renamed.example")
    assert dom.validatePage() is True
    assert wiz.cfg.domains[0].name == "renamed.example"
    assert wiz.cfg.domains[0].optional_services == ["owncast"]
    # ...and the marker does NOT follow the rename: nobody configured that name.
    assert "renamed.example" in ds.gate_reason(wiz.cfg)


def test_the_read_only_cell_shows_what_the_step_recorded(wiz):
    """The mirror must not keep displaying the pre-step text once cfg has moved on."""
    dom = _mesh_with_domains(wiz, "acme.example")
    cell = dom.table.cellWidget(added_row(dom, 0), 2)
    assert cell.text() == "not configured yet"
    page = _to_added(wiz)
    page._boxes["games"].setChecked(True)
    back_to(wiz, wizard_mod.DomainsPage)
    assert dom.table.cellWidget(added_row(dom, 0), 2).text() == "games"


def test_validate_page_leaves_the_mirror_consistent_with_what_it_wrote(wiz):
    """A narrow contract, pinned because it is otherwise the one line of this change no
    test holds. DomainsPage.validatePage can run while DomainsPage is the page ON
    SCREEN — collect_all() does exactly that, and Save config calls collect_all — and
    _on_page_changed does not fire without a page change, so the refresh has to happen
    where the write happens."""
    dom = _mesh_with_domains(wiz, "acme.example")
    page = _to_added(wiz)
    page._boxes["games"].setChecked(True)
    page.validatePage()                       # the step records into cfg
    assert dom.table.cellWidget(added_row(dom, 0), 2).text() == "not configured yet"
    dom.validatePage()                        # ...and the mirror catches up with it
    assert dom.table.cellWidget(added_row(dom, 0), 2).text() == "games"


def test_the_cell_renders_cores_one_summary_string(wiz):
    """One wording, one source of truth — the cell used to carry its own copy."""
    dom = _mesh_with_domains(wiz, "acme.example")
    cell = dom.table.cellWidget(added_row(dom, 0), 2)
    for slugs, reviewed in (([], False), (["akkoma"], False),
                            ([], True), (["games", "owncast"], True)):
        cell.set_slugs(slugs, reviewed=reviewed)
        assert cell.text() == ds.services_summary(slugs, reviewed)


# ── 8. the build screen's own refusal arm ──────────────────────────────────────
def test_the_continue_card_click_refuses_on_its_own(wiz, monkeypatch):
    """DEFENCE IN DEPTH, PINNED. _continue's `if self._refuse(): return` was the one
    arm no test held: reverting it to `if False and self._refuse(): return` left the
    whole suite green, because the card-disable arm hides it in the GUI and
    validatePage catches it afterwards. Spying on wiz.next() pins the arm itself."""
    page = _launch_page(wiz)
    wiz.cfg.domains = [Domain(name="unconfigured.example")]
    wiz.cfg.domain_services_reviewed = []
    nexts = []
    monkeypatch.setattr(wiz, "next", lambda: nexts.append(1))
    page._continue()
    assert nexts == [], "the Continue card's own handler must refuse before next()"
    ds.record_reviewed(wiz.cfg, [wiz.cfg.cluster_domain, "unconfigured.example"])
    page._continue()
    assert nexts == [1], "a configured build must still continue"


def test_the_refusal_is_above_the_action_cards_not_below_them(wiz):
    """This page scrolls and the build summary grows one line per worklist entry. A
    reason under two ChoiceCards is a reason the operator scrolls past while staring
    at a Continue card that has gone grey for no visible cause."""
    page = _launch_page(wiz)
    lay = page.gate_err.parentWidget().layout()
    order = [lay.itemAt(i).widget() for i in range(lay.count())]
    assert order.index(page.gate_err) < order.index(page.continue_card)
    assert order.index(page.gate_err) < order.index(page.menu_card)


# ── 9. the page's state belongs to ONE configuration ───────────────────────────
def test_loading_a_different_config_does_not_carry_a_reviewed_marker_into_it(wiz,
                                                                            tmp_path):
    """THE LEAK. `self._reviewed | reviewed_names(cfg)` carried a previous flow's
    walked names across a Load, so a config naming the same domain arrived with that
    domain already marked configured — the gate satisfied for a domain nobody in that
    session had looked at."""
    _mesh_with_domains(wiz, "acme.example")
    _to_added(wiz)
    assert wiz.cfg.domain_services_reviewed == []           # not yet written
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domain_services_reviewed == [wiz.cfg.cluster_domain, "acme.example"]

    # a DIFFERENT configuration file that happens to name the same domain plus one more
    other = ImageConfig(mode="mesh", additional_domains=True,
                        domains=[Domain(name="acme.example"),
                                 Domain(name="zeta.example")])
    path = str(tmp_path / "other.json")
    other.save(path)

    wiz.load_config(path)
    page = wiz.page(wiz._page_ids["domain_services"])
    page.initializePage()
    # The page lands on the first domain that still needs walking, and BEING on a
    # domain's screen is what records it — so the discriminator is WHICH domain it
    # lands on. With the leak, acme.example arrived already marked, the page skipped
    # straight to zeta.example, and one screen later nothing was left unconfigured.
    # (the own domain opens every walk and is recorded by being shown, so the first
    # domain the LEAK could have skipped is the first table row)
    assert page.current_domain() == other.cluster_domain
    page._step(1)
    assert page.current_domain() == "acme.example", \
        "a freshly loaded config must not inherit the last flow's walked domains"
    assert page.unconfigured() == ["zeta.example"]


def test_a_stale_page_cannot_write_its_answers_onto_a_new_config(wiz, tmp_path):
    """QWizard.restart() calls cleanupPage on EVERY visited page, and load_config calls
    restart() — so the page's own recording hook fires with the new cfg in place. It
    must be a no-op until initializePage has adopted that config."""
    _mesh_with_domains(wiz, "acme.example")
    page = _to_added(wiz)
    page._boxes["akkoma"].setChecked(True)

    other = ImageConfig(mode="mesh", additional_domains=True,
                        domains=[Domain(name="acme.example")])
    path = str(tmp_path / "other.json")
    other.save(path)
    wiz.load_config(path)

    assert wiz.cfg.domains[0].optional_services == [], \
        "one config's ticks must not be written onto another's domains"
    assert wiz.cfg.domain_services_reviewed == []


def test_the_working_selection_is_re_seeded_from_cfg_on_every_entry(wiz):
    """ASSIGNED, never merged: a domain dropped from the table must not keep a working
    selection that a later re-add would silently restore."""
    dom = _mesh_with_domains(wiz, "acme.example", "beta.example")
    page = _to_added(wiz)
    page._boxes["akkoma"].setChecked(True)          # acme.example
    back_to(wiz, wizard_mod.DomainsPage)
    dom.table.removeRow(added_row(dom, 0))
    advance_to(wiz, page_mod.DomainServicesPage)
    assert "acme.example" not in page._selection
    back_to(wiz, wizard_mod.DomainsPage)
    dom._add("acme.example", "Acme")
    advance_to(wiz, page_mod.DomainServicesPage)
    assert page._selection.get("acme.example") == []


# ── 10. the SECOND docker mesh-start door ──────────────────────────────────────
# Saved meshes -> Start / Restore. Found by the skeptic pass: _bootstrap_up was gated
# and _start_saved, on the SAME page, from the SAME wiz.cfg, onto the SAME compose
# project, was not — so issue #495's "the docker/local mesh start" was satisfied by
# one button and bypassed by the one next to it.
def _saved_record(**over):
    from types import SimpleNamespace
    from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
    return SimpleNamespace(id="rec-1", label="my-mesh", form={},
                           config=LocalMeshBootstrapConfig(**over).to_dict())


@pytest.mark.parametrize("mode", ["start", "restore"])
def test_the_saved_mesh_start_is_gated_too(local_mesh_page, monkeypatch, mode):
    # THE RECORD's domains are what runs (#631 section 3): the image flow's table in
    # wiz.cfg no longer refuses a saved mesh (test_domains_row_checks_saved_door.py)
    page = local_mesh_page
    started = []
    monkeypatch.setattr(page, "_launch", lambda *a, **k: started.append(a))
    page._start_saved(_saved_record(own_idp_domains=("unconfigured.example",)), mode)
    assert started == [], \
        "Saved meshes -> Start must not bring a docker mesh up with an unconfigured domain"
    assert "unconfigured.example" in page.status.text()
    assert "start this mesh" in page.status.text()


def test_the_saved_mesh_gate_is_the_same_seam_as_the_bootstrap_one(local_mesh_page):
    page = local_mesh_page
    page.wiz.cfg.domains = [Domain(name="unconfigured.example")]
    assert page._domain_services_refusal() == \
        ds.gate_reason(page.wiz.cfg, ds.ACTION_MESH_START)


def test_a_configured_saved_mesh_gets_past_the_services_gate(local_mesh_page,
                                                             monkeypatch):
    """The gate must not become a blanket block on the saved-mesh rows. Past it, the
    record's own refusals (theme errors, boot.validate()) still apply — what this pins
    is that the SERVICES sentence is gone."""
    page = local_mesh_page
    page.wiz.cfg.domains = [Domain(name="acme.example")]
    ds.record_reviewed(page.wiz.cfg, ["acme.example"])
    monkeypatch.setattr(page, "_launch", lambda *a, **k: None)
    page._start_saved(_saved_record(), "start")
    assert "start this mesh" not in page.status.text()


def test_the_saved_mesh_gate_refuses_before_it_rewrites_the_form(local_mesh_page,
                                                                 monkeypatch):
    """_start_saved applies the record to the bootstrap form on its way to launching.
    A refused click must not do that half of the work."""
    page = local_mesh_page
    applied = []
    monkeypatch.setattr(page, "apply_bootstrap",
                        lambda *a, **k: applied.append(a) or [])
    monkeypatch.setattr(page, "_launch", lambda *a, **k: None)
    page._start_saved(_saved_record(own_idp_domains=("unconfigured.example",)), "start")
    assert applied == []


# ── 11. the previous-builds RESTART door ───────────────────────────────────────
# start_build_from_session sets the start id to "progress" and jumps there;
# ProgressPage dispatches on arrival, so no wizard page stands between that button and
# a build. can_restart is the guard that does.
def _session(cfg: ImageConfig, workdir: str):
    """A wizard session record, shaped exactly as build_sessions writes one: the
    WORKLIST ENVELOPE (`build_sessions` line `s.config = wl.to_dict()`), which is also
    what `start_build_from_session` parses. A flat ImageConfig dict would load as an
    EMPTY base through WorklistConfig.from_dict and the gate would have nothing to
    read — so getting this shape wrong is how a restart guard passes vacuously."""
    from types import SimpleNamespace
    from hugmesh_studio.core.worklist import WorklistConfig
    wl = WorklistConfig(base=cfg)
    return SimpleNamespace(id="s1", workdir=workdir, config=wl.to_dict(),
                           kind="wizard", blanked_secrets=[], held_secret_files=[])


def test_restart_refuses_a_recorded_config_that_gained_an_unconfigured_domain(
        monkeypatch, tmp_path):
    from hugmesh_studio.gui.pages import sessions_widget as sw
    monkeypatch.setattr(sw.build_sessions, "is_active", lambda s: False)
    cfg = ImageConfig(mode="mesh", additional_domains=True,
                      domains=[Domain(name="a.example"), Domain(name="b.example")])
    ds.record_reviewed(cfg, ["a.example"])
    ok, why = sw.PreviousBuildsWidget.can_restart(_session(cfg, str(tmp_path)))
    assert ok is False
    assert "b.example" in why
    # the caller branches on this word to OFFER the Redo, which is the route that
    # exists from the previous-builds manager.
    assert "Redo" in why


def test_restart_still_allows_a_session_from_before_the_field_existed(monkeypatch,
                                                                     tmp_path):
    from hugmesh_studio.gui.pages import sessions_widget as sw
    monkeypatch.setattr(sw.build_sessions, "is_active", lambda s: False)
    cfg = ImageConfig(mode="mesh", additional_domains=True,
                      domains=[Domain(name="a.example")])
    assert cfg.domain_services_reviewed == []
    ok, why = sw.PreviousBuildsWidget.can_restart(_session(cfg, str(tmp_path)))
    assert (ok, why) == (True, "")


def test_restart_allows_a_fully_configured_session(monkeypatch, tmp_path):
    from hugmesh_studio.gui.pages import sessions_widget as sw
    monkeypatch.setattr(sw.build_sessions, "is_active", lambda s: False)
    cfg = ImageConfig(mode="mesh", additional_domains=True,
                      domains=[Domain(name="a.example")])
    ds.record_reviewed(cfg, ["a.example"])
    ok, why = sw.PreviousBuildsWidget.can_restart(_session(cfg, str(tmp_path)))
    assert (ok, why) == (True, "")


def test_an_unparseable_session_record_is_not_turned_into_a_services_refusal(tmp_path):
    """This guard answers the SERVICES question only. Turning a parse failure into a
    refusal would break restart for every record shape it does not understand; the
    dispatch preflight is what refuses an unusable record."""
    from types import SimpleNamespace
    from hugmesh_studio.gui.pages import sessions_widget as sw
    assert sw._session_services_refusal(SimpleNamespace(config=None)) == ""
    assert sw._session_services_refusal(SimpleNamespace(config={"junk": object()})) == ""


def test_the_restart_guard_reads_the_same_object_start_build_from_session_does(
        monkeypatch, tmp_path):
    """The RECORD is what a restart re-dispatches, never the wizard's current cfg.
    Pinned by driving the guard from a record whose base disagrees with a wizard."""
    from hugmesh_studio.core.worklist import WorklistConfig
    from hugmesh_studio.gui.pages import sessions_widget as sw
    monkeypatch.setattr(sw.build_sessions, "is_active", lambda s: False)
    cfg = ImageConfig(mode="mesh", additional_domains=True,
                      domains=[Domain(name="a.example")])
    ds.record_reviewed(cfg, ["a.example"])
    cfg.domains.append(Domain(name="late.example"))
    sess = _session(cfg, str(tmp_path))
    base = WorklistConfig.from_dict(sess.config).base
    assert [d.name for d in base.domains] == ["a.example", "late.example"]
    ok, why = sw.PreviousBuildsWidget.can_restart(sess)
    assert ok is False and "late.example" in why


def test_a_fleet_session_is_not_touched_by_the_services_restart_guard(monkeypatch,
                                                                     tmp_path):
    """A fleet run restarts through the fleet window, not start_build_from_session, and
    build_sessions records its config FLAT (`s.config = cfg.to_dict()`), so the
    envelope parse finds an empty base and this guard stays out of that lane."""
    from types import SimpleNamespace
    from hugmesh_studio.gui.pages import sessions_widget as sw
    monkeypatch.setattr(sw.build_sessions, "is_active", lambda s: False)
    cfg = ImageConfig(mode="mesh", additional_domains=True,
                      domains=[Domain(name="a.example")])
    ds.record_reviewed(cfg, ["a.example"])
    cfg.domains.append(Domain(name="late.example"))
    flat = SimpleNamespace(id="f1", workdir=str(tmp_path), config=cfg.to_dict(),
                           kind="fleet", blanked_secrets=[], held_secret_files=[])
    assert sw.PreviousBuildsWidget.can_restart(flat) == (True, "")


# ── 12. THE MESH'S OWN DOMAIN (issue #494, reported 2026-09-23) ────────────────
# "the checkbox doesn't seem to be present on each domain page": ask 19's default
# card skipped the Domains table and, with it, this step — so the one domain every
# mesh serves never had a services page. Now the own domain opens every mesh walk.
def _mesh_default_path(wiz):
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86")
    choice = advance_to(wiz, wizard_mod.DomainsChoicePage)
    assert choice._selected() == "internal"                # the DEFAULT card
    return choice


def test_the_mesh_default_path_visits_the_own_domains_page(wiz):
    _mesh_default_path(wiz)
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.current_domain() == wiz.cfg.cluster_domain
    assert "1 of 1" in page.subTitle()
    assert "this mesh's own domain" in page.head.text()
    assert wiz.cfg.domains == []                            # never a domains row
    assert wiz.cfg.additional_domains is False


def test_the_own_domain_page_is_emission_neutral_when_untouched(wiz):
    """ASK 8's guard, re-pinned against the new page: an operator who never ticks
    anything on the own domain's page emits exactly what the flow emitted before the
    page existed — no --domains, no manifest domains entry, no new manifest key."""
    _mesh_default_path(wiz)
    argv_before = wiz.cfg.to_cli_args()
    manifest_before = copy.deepcopy(wiz.cfg.mesh_manifest())
    advance_to(wiz, page_mod.DomainServicesPage)
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domains == []
    assert "--domains" not in wiz.cfg.to_cli_args()
    assert wiz.cfg.to_cli_args() == argv_before
    after = wiz.cfg.mesh_manifest()
    assert after["domains"] == [] and "cluster_domain_services" not in after
    assert after == manifest_before
    assert wiz.cfg.domain_services_reviewed == [wiz.cfg.cluster_domain]


def test_ticking_on_the_own_domain_records_cluster_domain_services_only(wiz):
    _mesh_default_path(wiz)
    page = advance_to(wiz, page_mod.DomainServicesPage)
    page._boxes["games"].setChecked(True)
    advance_to(wiz, wizard_mod.LaunchPage)
    assert wiz.cfg.cluster_domain_services == ["games"]
    assert wiz.cfg.domains == []
    assert "--domains" not in wiz.cfg.to_cli_args()
    m = wiz.cfg.mesh_manifest()
    assert m["domains"] == [] and m["cluster_domain_services"] == ["games"]


def test_the_domains_table_shows_the_own_domain_as_row_0(wiz):
    dom = _mesh_with_domains(wiz, "acme.example")
    assert dom.is_own_row(0)
    assert dom.table.item(0, 0).text() == wiz.cfg.cluster_domain
    assert not (dom.table.item(0, 0).flags() & Qt.ItemFlag.ItemIsEditable)
    assert added_names(dom) == ["acme.example"]
    assert isinstance(dom.table.cellWidget(0, 2), page_mod.__dict__.get(
        "_ServicesCell", domains_mod._ServicesCell))
    dom.table.selectAll()
    dom._remove()
    assert dom.is_own_row(0) and dom.row_note.isVisibleTo(dom)
    assert dom.validatePage() is True
    assert [d.name for d in wiz.cfg.domains] == []          # removed acme, kept own


def test_the_own_row_mirrors_what_the_step_recorded(wiz):
    dom = _mesh_with_domains(wiz, "acme.example")
    assert dom.table.cellWidget(0, 2).text() == "not configured yet"
    page = advance_to(wiz, page_mod.DomainServicesPage)   # own domain shown
    page._boxes["owncast"].setChecked(True)
    back_to(wiz, wizard_mod.DomainsPage)
    assert dom.table.cellWidget(0, 2).text() == "owncast"
    assert wiz.cfg.cluster_domain_services == ["owncast"]
    assert [d.name for d in wiz.cfg.domains] == ["acme.example"]


# ── 11. #631 section 1: the OWN domain is gated on the build screen too ─────────────
# Before #631 the gate read the table rows only, so the own domain's page was enforced
# by being unavoidable on a fresh walk and nothing else — a config LOADED on the
# Sessions screen that never opened it went straight through the build door.
def test_a_loaded_config_that_never_walked_its_own_domain_is_refused(wiz):
    page = _launch_page(wiz)
    wiz.cfg.domains = [Domain(name="acme.example")]
    ds.record_reviewed(wiz.cfg, ["acme.example"])      # rows walked, own domain never
    assert page._refuse() is True
    text = page.gate_err.text()
    assert "1 domain has no recorded service configuration — " \
        f"{wiz.cfg.cluster_domain}." in text
    assert not page.continue_card.isEnabled()
    assert page.validatePage() is False


def test_the_default_card_with_no_walk_is_refused_by_name(wiz):
    """#589's suggested test, on the real build screen: default card (no rows) + build
    -> the refusal names the primary domain when its services were never confirmed."""
    page = _launch_page(wiz)
    assert wiz.cfg.domains == [] and wiz.cfg.domain_services_reviewed == []
    assert page._refuse() is True
    assert wiz.cfg.cluster_domain in page.gate_err.text()


def test_walking_the_own_domains_page_is_what_lets_the_build_through(wiz):
    """The page walk sets the marker — the remedy the refusal names works."""
    c = wiz.cfg
    c.mode, c.role = "mesh", "omnibus"
    wiz.restart()
    svc = advance_to(wiz, page_mod.DomainServicesPage)
    assert svc.current_domain() == wiz.cfg.cluster_domain
    assert ds.gate_reason(wiz.cfg) != ""               # shown, not yet recorded
    assert svc.validatePage() is True
    assert ds.gate_reason(wiz.cfg) == ""
    assert wiz.cfg.domain_services_reviewed == [wiz.cfg.cluster_domain]


def test_a_fresh_default_card_walk_reaches_a_launch_that_lets_it_through(wiz):
    """An UNTOUCHED fresh flow is not blocked, and still emits no --domains, no
    manifest domains entry and no cluster_domain_services (argv identity across the
    services step itself is pinned above, by the default-path emission test)."""
    _mesh_default_path(wiz)
    launch = advance_to(wiz, wizard_mod.LaunchPage)
    assert launch.gate_refusal() == ""
    assert launch._refuse() is False and launch.continue_card.isEnabled()
    assert "--domains" not in wiz.cfg.to_cli_args()
    m = wiz.cfg.mesh_manifest()
    assert m["domains"] == [] and "cluster_domain_services" not in m
