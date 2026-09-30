"""DomainsPage 'Optional services' column — now a READ-ONLY report (#495).

History of this one cell, because each step is what the next one fixed:

* it was a FREEFORM text cell: typing ``akkoma, tuwunel, definitely-not-a-service`` put
  all three verbatim into ``mesh_manifest()["domains"][0]["optional_services"]`` with no
  validation and no catalogue check;
* #227 made it a checkable MENU, which killed the typo — but nothing obliged the
  operator to OPEN that menu, so "what does this domain provide" stayed unanswered on
  most builds;
* #495 moves the CHOICE to its own step (one service page per domain, which the build
  and docker-mesh-start gates require) and leaves this cell REPORTING it.

What these tests pin about the cell that remains:

* it is a widget, not an editable item — nothing can be typed into the column;
* it still carries the row's slugs, in CATALOGUE order, and ``DomainsPage.validatePage``
  reads them straight back out, so this table is still the SOLE writer of
  ``cfg.domains[].optional_services`` (a row added/renamed/removed here still decides);
* it distinguishes "never configured" from "configured as the cluster-wide default",
  which ``optional_services`` alone cannot express and which is exactly what the gate
  refuses on;
* a slug from a loaded config that the catalogue does not offer is still shown, never
  dropped;
* the header tooltip and the page help say where the choice is made now, and neither
  claims the slugs are baked into the image or enforced at the cluster.

The picker itself (the catalogue, the grouping, the carried-over extras, the
normalisation) is tested where it now lives: tests/test_domain_services_page.py.

Same harness as test_pages_domains_idp.py: the real wizard on Qt's offscreen platform,
skipped whole when no Qt binding is installed. Nothing here calls ``.exec()``.
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import Domain  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages.domains import (  # noqa: E402
    _COL_SERVICES, _COL_TITLE, _ServicesCell)
from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402

from _helpers import (
    added_row,   # noqa: E402
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
            or QtWidgets.QApplication(["hugmesh-studio-domain-services-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _mesh_domains(wiz):
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86")
    enable_additional_domains(wiz)
    return advance_to(wiz, wizard_mod.DomainsPage)


# ---- the cell itself -----------------------------------------------------------

def test_services_cell_is_a_widget_not_a_text_cell(wiz):
    """The freeform QTableWidgetItem stayed gone: the cell is a _ServicesCell, so
    QTableWidget.item() on that column is None and there is nothing to type into."""
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    cell = dom.table.cellWidget(added_row(dom, 0), _COL_SERVICES)
    assert isinstance(cell, _ServicesCell)
    assert dom.table.item(added_row(dom, 0), _COL_SERVICES) is None
    assert cell.selected_slugs() == []


def test_the_cell_is_read_only_it_cannot_be_clicked_into_a_picker(wiz):
    """THE POINT OF #495. If this cell were still an interactive picker, the required
    per-domain page would be optional again — two places to answer one question, one of
    which nothing makes you visit. A QLabel has no menu and no clicked signal."""
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    cell = dom.table.cellWidget(added_row(dom, 0), _COL_SERVICES)
    assert isinstance(cell, QtWidgets.QLabel)
    assert not hasattr(cell, "menu")
    assert not hasattr(cell, "clicked")


def test_an_unconfigured_row_does_not_read_like_a_configured_empty_one(wiz):
    """The state ``optional_services`` cannot express. ``[]`` is a real answer — "the
    cluster-wide set applies" — and it is NOT the same fact as "nobody has been through
    this domain's services yet", which is what the build/mesh-start gate refuses on."""
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    cell = dom.table.cellWidget(added_row(dom, 0), _COL_SERVICES)
    assert cell.text() == "not configured yet"
    cell.set_slugs([], reviewed=True)
    assert cell.text() == "cluster default"
    assert "None" not in cell.text()          # SERVICES_NONE is the OPPOSING sentinel


def test_a_loaded_rows_slugs_are_shown_even_before_it_is_configured(wiz):
    """An older worklist's manifest data must be VISIBLE, not hidden behind the
    unconfigured state — otherwise the operator cannot tell a domain that carries
    services from one that carries none."""
    cell = _ServicesCell(["akkoma", "tube"], reviewed=False)
    assert "akkoma" in cell.text() and "tube" in cell.text()
    assert "not confirmed" in cell.text()


# ---- round-trip: this table is still the sole writer ----------------------------

def test_cell_slugs_reach_config_and_the_mesh_manifest(wiz):
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme", ["akkoma", "tube"])
    advance_to(wiz, wizard_mod.UsersChoicePage)      # Next past Domains collects
    c = wiz.cfg
    assert [d.optional_services for d in c.domains] == [["akkoma", "tube"]]
    assert c.mesh_manifest()["domains"][0]["optional_services"] == ["akkoma", "tube"]


def test_loaded_row_seeds_the_cell_back(wiz):
    c = wiz.cfg
    c.mode = "mesh"
    c.role = "omnibus"
    c.additional_domains = True
    c.domains = [Domain(name="acme.example", title="Acme",
                        optional_services=["phpbb", "owncast"])]
    wiz.restart()
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    cell = dom.table.cellWidget(added_row(dom, 0), _COL_SERVICES)
    assert cell.selected_slugs() == ["phpbb", "owncast"]


def test_unknown_slug_from_a_loaded_config_is_kept_not_dropped(wiz):
    """An older worklist can carry a slug this catalogue does not offer (an infra slug
    typed into the original freeform cell, or a service since renamed). Dropping it
    would silently rewrite the operator's manifest."""
    c = wiz.cfg
    c.mode = "mesh"
    c.role = "omnibus"
    c.additional_domains = True
    c.domains = [Domain(name="acme.example", title="Acme",
                        optional_services=["akkoma", "tor"])]
    wiz.restart()
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    cell = dom.table.cellWidget(added_row(dom, 0), _COL_SERVICES)
    assert cell.selected_slugs() == ["akkoma", "tor"]
    assert "tor" in cell.text()
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domains[0].optional_services == ["akkoma", "tor"]


def test_a_typo_can_no_longer_be_entered(wiz):
    """The defect the original issue named: the freeform cell accepted any string.
    Nothing outside the catalogue can be ADDED by hand on this page (only carried over
    from a loaded config, which the test above pins)."""
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    assert dom.table.item(added_row(dom, 0), _COL_SERVICES) is None      # nowhere to type
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domains[0].optional_services == []


def test_add_still_accepts_the_legacy_string_form(wiz):
    """Three test files and the page's own callers pass space/comma-separated strings
    to _add; keeping that shape is what stops this change breaking them."""
    dom = _mesh_domains(wiz)
    dom._add("beta.example", "Beta", "phpbb, owncast")
    cell = dom.table.cellWidget(added_row(dom, 0), _COL_SERVICES)
    assert cell.selected_slugs() == ["phpbb", "owncast"]


def test_the_cell_normalises_to_catalogue_order(wiz):
    """A loaded row whose slugs were in some other order round-trips normalised.
    optional_services is an allow-list — the builders join it into one
    --optional-services string — so order carries no meaning, and a deterministic order
    keeps the manifest byte-stable across a load/save cycle.

    DISCRIMINATING PAIR: games/owncast is the pair where catalogue order
    (... games, owncast, tube ...) and SERVICE_GROUPS presentation order ("Media & Play"
    = owncast, tube, games) DISAGREE, so this assertion can tell the two apart."""
    c = wiz.cfg
    c.mode = "mesh"
    c.role = "omnibus"
    c.additional_domains = True
    c.domains = [Domain(name="acme.example", title="Acme",
                        optional_services=["owncast", "games"])]  # NOT catalogue order
    wiz.restart()
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    cell = dom.table.cellWidget(added_row(dom, 0), _COL_SERVICES)
    assert cell.selected_slugs() == ["games", "owncast"]
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domains[0].optional_services == ["games", "owncast"]


def test_a_carried_over_extra_sorts_after_the_catalogue_slugs(wiz):
    """An unknown slug kept from a loaded config has no catalogue position, so it lands
    last rather than wherever it happened to be typed."""
    cell = _ServicesCell(["tor", "akkoma", "games"])
    assert cell.selected_slugs() == ["akkoma", "games", "tor"]


def test_the_cell_follows_cfg_when_the_services_step_changes_it(wiz):
    """Back-navigation. The Domain services step writes cfg AFTER this page ran, and
    initializePage only fills the table when it is EMPTY — so without the
    currentIdChanged refresh a Back into this page would show the pre-edit slugs of a
    domain the operator had just configured."""
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    advance_to(wiz, wizard_mod.UsersChoicePage)
    wiz.cfg.domains[0].optional_services = ["akkoma"]
    wiz.cfg.domain_services_reviewed = ["acme.example"]
    dom._refresh_services_cells()
    cell = dom.table.cellWidget(added_row(dom, 0), _COL_SERVICES)
    assert cell.selected_slugs() == ["akkoma"]
    assert cell.text() == "akkoma"


# ---- copy: where the choice is made, and what it does NOT do --------------------

def test_title_column_header_says_where_the_title_is_read(wiz):
    """#227 item 1. The operator could not tell what Title was FOR. It is read from
    the mesh manifest by cluster provisioning and appears nowhere on a cloud build."""
    dom = _mesh_domains(wiz)
    tip = dom.table.horizontalHeaderItem(_COL_TITLE).toolTip()
    assert "domains[].title" in tip
    assert "cluster provisioning" in tip
    assert "cloud build" in tip


def test_page_help_explains_title_without_a_hover(wiz):
    """A tooltip alone is discoverable only on hover, which is the complaint. The
    page-level help must agree with it in plain sight."""
    dom = _mesh_domains(wiz)
    help_text = dom.table_help.text()
    assert "‘Title’" in help_text
    assert "mesh manifest" in help_text


def test_page_help_does_not_claim_the_slugs_are_baked_into_the_image(wiz):
    """HONESTY. Per-domain optional_services is provisioning input carried in the
    manifest; nothing in this repo reads it back, and the image-wide selected-services
    cut-over has not happened either. The copy must not imply otherwise."""
    dom = _mesh_domains(wiz)
    help_text = dom.table_help.text()
    assert "not baked into the image" in help_text
    assert "space/comma-separated" not in help_text   # the old, now-false, phrasing


def test_page_help_sends_the_operator_to_the_step_that_owns_the_choice(wiz):
    """A read-only cell that does not say where the choice IS made is just a control
    that stopped working."""
    dom = _mesh_domains(wiz)
    help_text = dom.table_help.text()
    assert "Domain services" in help_text
    assert "READ-ONLY" in help_text
    assert "its own service page" in help_text


def test_services_column_header_carries_the_honesty_claims(wiz):
    """The Services header tooltip carries this change's central honesty claims;
    without a test, deleting them is a green edit."""
    tip = _mesh_domains(wiz).table.horizontalHeaderItem(_COL_SERVICES).toolTip()
    assert "mesh manifest" in tip
    assert "do NOT change which services the image bakes" in tip
    assert "cluster-wide set applies" in tip
    assert "Domain services" in tip                 # where it IS picked
    assert "not yet decide what the cluster runs" in tip   # and what it does not do
    # House style: no GitHub issue ids in user-facing copy (the sign-in tooltip test
    # below pins the same rule for the column beside this one).
    assert "#49" not in tip


def test_no_raw_issue_number_in_the_signin_tooltip(wiz):
    """A GitHub issue id is not user-facing copy."""
    dom = _mesh_domains(wiz)
    from hugmesh_studio.gui.pages.domains import _COL_IDP
    assert "#47" not in dom.table.horizontalHeaderItem(_COL_IDP).toolTip()
