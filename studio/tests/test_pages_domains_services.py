"""DomainsPage 'Optional services' column (issue #227) — the freeform cell became a
checkable MENU.

What the old cell did, measured before this change: typing
``akkoma, tuwunel, definitely-not-a-service`` put all three verbatim into
``mesh_manifest()["domains"][0]["optional_services"]`` with no validation, no
warning and no catalogue check. These tests pin the replacement:

* the menu offers exactly ``OPTIONAL_SERVICES_CHOICES`` — the user-level cluster
  slugs — and NOT the infra slugs (tor / egress-vpn / workloadConsole / anubis),
  which are node- or cluster-plane scoped and would be a new lie per DOMAIN;
* every offered action carries its ``SERVICE_DESCRIPTIONS`` line, and the menu has
  ``setToolTipsVisible(True)`` — QMenu suppresses action tooltips by default, so
  without that call the descriptions would ship invisible;
* a checked selection round-trips validatePage -> cfg.domains -> mesh_manifest;
* a slug from a LOADED config that the catalogue does not offer is preserved as an
  extra pre-checked action, so an older worklist never silently loses manifest data;
* the Title column header explains where ``domains[].title`` is actually read
  (issue #227 item 1), and the page-level help says the same thing without a hover.

Same harness as test_pages_domains_idp.py: the real wizard on Qt's offscreen
platform, skipped whole when no Qt binding is installed. Nothing here calls
``.exec()`` — the control is the proven ``_AppliesToButton`` idiom (QToolButton +
InstantPopup QMenu + checkable QActions), which is headless-safe.
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import (  # noqa: E402
    INFRA_SERVICES_CHOICES, OPTIONAL_SERVICES_CHOICES, SERVICE_DESCRIPTIONS,
    Domain)
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages.domains import (  # noqa: E402
    _COL_SERVICES, _COL_TITLE, _ServicesButton)
from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402

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


# ---- the control itself --------------------------------------------------------

def test_services_cell_is_a_menu_not_a_text_cell(wiz):
    """The freeform QTableWidgetItem is gone: the cell is a _ServicesButton, so
    QTableWidget.item() on that column is None and there is nothing to type into."""
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    btn = dom.table.cellWidget(0, _COL_SERVICES)
    assert isinstance(btn, _ServicesButton)
    assert dom.table.item(0, _COL_SERVICES) is None
    assert btn.selected_slugs() == []
    assert btn.text() == "None ▾"


def test_menu_offers_the_user_level_catalogue_and_not_the_infra_slugs(wiz):
    """(a) of the three candidate slug sets: the eight user-level cluster slugs.
    The infra slugs are node- or cluster-plane scoped, so offering them per DOMAIN
    would claim something the builders do not do."""
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    btn = dom.table.cellWidget(0, _COL_SERVICES)
    assert sorted(btn._actions) == sorted(OPTIONAL_SERVICES_CHOICES)
    for infra in INFRA_SERVICES_CHOICES:
        assert infra not in btn._actions


def test_every_offered_service_carries_its_description_and_tips_are_visible(wiz):
    """QMenu hides per-action tooltips unless setToolTipsVisible(True) is called —
    without it the whole point of the menu (you can tell what a slug IS) is invisible."""
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    btn = dom.table.cellWidget(0, _COL_SERVICES)
    assert btn.menu().toolTipsVisible()
    for slug, act in btn._actions.items():
        assert act.toolTip() == SERVICE_DESCRIPTIONS[slug]
        assert act.isCheckable()


def test_button_text_counts_the_selection(wiz):
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    btn = dom.table.cellWidget(0, _COL_SERVICES)
    btn._actions["akkoma"].setChecked(True)
    assert btn.text() == "1 service ▾"
    btn._actions["tube"].setChecked(True)
    assert btn.text() == "2 services ▾"


# ---- round-trip ----------------------------------------------------------------

def test_checked_slugs_reach_config_and_the_mesh_manifest(wiz):
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    btn = dom.table.cellWidget(0, _COL_SERVICES)
    btn._actions["akkoma"].setChecked(True)
    btn._actions["tube"].setChecked(True)
    advance_to(wiz, wizard_mod.UsersChoicePage)      # Next past Domains collects
    c = wiz.cfg
    assert [d.optional_services for d in c.domains] == [["akkoma", "tube"]]
    assert c.mesh_manifest()["domains"][0]["optional_services"] == ["akkoma", "tube"]


def test_loaded_row_seeds_the_menu_back(wiz):
    c = wiz.cfg
    c.mode = "mesh"
    c.role = "omnibus"
    c.additional_domains = True
    c.domains = [Domain(name="acme.example", title="Acme",
                        optional_services=["phpbb", "owncast"])]
    wiz.restart()
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    btn = dom.table.cellWidget(0, _COL_SERVICES)
    assert btn.selected_slugs() == ["phpbb", "owncast"]


def test_unknown_slug_from_a_loaded_config_is_kept_not_dropped(wiz):
    """An older worklist can carry a slug this catalogue does not offer (an infra
    slug typed into the old freeform cell, or a service since renamed). Dropping it
    would silently rewrite the operator's manifest, so it is offered pre-checked."""
    c = wiz.cfg
    c.mode = "mesh"
    c.role = "omnibus"
    c.additional_domains = True
    c.domains = [Domain(name="acme.example", title="Acme",
                        optional_services=["akkoma", "tor"])]
    wiz.restart()
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    btn = dom.table.cellWidget(0, _COL_SERVICES)
    assert "tor" in btn._actions
    assert btn._actions["tor"].isChecked()
    assert "kept from your config" in btn._actions["tor"].text()
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domains[0].optional_services == ["akkoma", "tor"]


def test_a_typo_can_no_longer_be_entered(wiz):
    """The defect this issue names: the old cell accepted any string. The menu has no
    action for a non-service, so nothing outside the catalogue can be ADDED by hand
    (only carried over from a loaded config, which the test above pins)."""
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    btn = dom.table.cellWidget(0, _COL_SERVICES)
    assert "definitely-not-a-service" not in btn._actions
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domains[0].optional_services == []


def test_add_still_accepts_the_legacy_string_form(wiz):
    """Three test files and the page's own callers pass space/comma-separated strings
    to _add; keeping that shape is what stops this change breaking them."""
    dom = _mesh_domains(wiz)
    dom._add("beta.example", "Beta", "phpbb, owncast")
    btn = dom.table.cellWidget(0, _COL_SERVICES)
    assert btn.selected_slugs() == ["phpbb", "owncast"]


# ---- item 1: Title visibility ---------------------------------------------------

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


def test_no_raw_issue_number_in_the_signin_tooltip(wiz):
    """A GitHub issue id is not user-facing copy."""
    dom = _mesh_domains(wiz)
    from hugmesh_studio.gui.pages.domains import _COL_IDP
    assert "#47" not in dom.table.horizontalHeaderItem(_COL_IDP).toolTip()


def test_selection_normalises_to_catalogue_order(wiz):
    """The menu reads back in catalogue order, so a loaded row whose slugs were in
    some other order round-trips normalised. optional_services is an allow-list —
    the builders join it into one --optional-services string — so order carries no
    meaning, and a deterministic order keeps the manifest byte-stable across a
    load/save cycle. Pinned so the normalisation is a decision, not a surprise."""
    c = wiz.cfg
    c.mode = "mesh"
    c.role = "omnibus"
    c.additional_domains = True
    c.domains = [Domain(name="acme.example", title="Acme",
                        optional_services=["tube", "akkoma"])]   # NOT catalogue order
    wiz.restart()
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    btn = dom.table.cellWidget(0, _COL_SERVICES)
    assert btn.selected_slugs() == ["akkoma", "tube"]
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domains[0].optional_services == ["akkoma", "tube"]


def test_a_catalogue_slug_missing_from_the_grouping_is_still_offered(monkeypatch, wiz):
    """SERVICE_GROUPS is a presentation table; OPTIONAL_SERVICES_CHOICES is the
    catalogue. If the two drift, the slug must still be selectable rather than
    silently vanish from the menu — the exact quiet-drop failure this column had."""
    from hugmesh_studio.gui.pages import domains as dom_mod
    monkeypatch.setattr(dom_mod, "SERVICE_GROUPS",
                        (("Social & community", ("akkoma",)),))   # drops 7 slugs
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    btn = dom.table.cellWidget(0, _COL_SERVICES)
    assert sorted(btn._actions) == sorted(OPTIONAL_SERVICES_CHOICES)
