"""The per-domain Services page NAMES each choice's scope (#497).

Service choices in this platform live at three scopes and the split is deliberate:

| scope | chosen | e.g. |
|---|---|---|
| **Domain** | the per-domain Services page (#495) | the `--all-services` catalogue |
| **Image / mesh-wide** | the ‘Network & services’ step | dedicated-flag services, edge-AI, managed backing services |
| **Node / cluster plane** | that step, and (for two of them) the worklist's per-node Services column | tor, egress-vpn, workloadConsole, anubis |

What this file pins:

* the page names the scope of **every** row it shows, on the row and not in a tooltip —
  "the operator can see, WITHOUT READING SOURCE, which of their choices binds the
  domain, which binds the image, and which binds a node", and a hover is not seeing;
* the not-domain-scoped choices are **reachable from the same flow** — printed with
  where each is set and what it is doing right now — so nobody has to hunt for where
  anubis is configured;
* **nothing infra-scoped is a control**: the read-only table has no checkbox anywhere,
  because a per-DOMAIN tick-box for a node- or cluster-plane slug would be a new lie;
* the two *questions* — where a choice is made, and what it binds — stay apart.
  Conflating them is how the scopes got flattened before;
* the per-slug "where" is honest per slug: `workloadConsole` and `anubis` have NO
  per-node control, so telling the operator to look in the worklist would send them
  hunting for something that does not exist.

Both faces read the SAME core data (`core/domain_services.other_scope_rows`), so the
GUI page and the TUI step cannot disagree about which plane a slug binds.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import domain_services as ds            # noqa: E402
from hugmesh_studio.core.config import (                         # noqa: E402
    INFRA_SERVICES_CHOICES, OPTIONAL_SERVICES_CHOICES, Domain, ImageConfig)
from hugmesh_studio.core.worklist import (                       # noqa: E402
    WORKLIST_INFRA_SERVICES, WorklistEntry)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


# ── the scope model, Qt-free ────────────────────────────────────────────────────
def test_the_three_scopes_each_say_where_they_are_set_and_what_they_bind():
    """Two DIFFERENT questions, kept apart. "Where is this set" and "what does this
    bind" are not the same fact, and answering only the first is how a surface ends up
    implying a node-plane toggle is a domain property."""
    for scope in (ds.SCOPE_DOMAIN, ds.SCOPE_IMAGE, ds.SCOPE_NODE):
        assert ds.SCOPE_LABELS[scope]
        assert ds.SCOPE_WHERE[scope]
        assert ds.SCOPE_BINDS[scope]
        assert ds.SCOPE_WHERE[scope] != ds.SCOPE_BINDS[scope]
    assert "domain" in ds.SCOPE_BINDS[ds.SCOPE_DOMAIN]
    assert "not one domain" in ds.SCOPE_BINDS[ds.SCOPE_IMAGE]
    assert "never one domain" in ds.SCOPE_BINDS[ds.SCOPE_NODE]


def test_every_infra_slug_has_its_own_where_and_none_of_them_is_domain_scoped():
    assert set(ds.INFRA_WHERE) == set(INFRA_SERVICES_CHOICES)
    for slug in INFRA_SERVICES_CHOICES:
        assert ds.scope_of(slug) == ds.SCOPE_NODE
        assert slug not in ds.DOMAIN_CATALOGUE


def test_a_slug_with_no_per_node_control_does_not_claim_to_have_one():
    """`workloadConsole` and `anubis` are cluster-plane: `WORKLIST_INFRA_SERVICES` is
    tor + egress-vpn only. Sending the operator to the worklist to find them would be
    a hunt for a control that does not exist — a different failure from hiding them,
    and just as bad."""
    for slug in WORKLIST_INFRA_SERVICES:
        assert "worklist" in ds.INFRA_WHERE[slug]
    for slug in set(INFRA_SERVICES_CHOICES) - set(WORKLIST_INFRA_SERVICES):
        assert "worklist" not in ds.INFRA_WHERE[slug]
        assert "no per-node control" in ds.INFRA_WHERE[slug]


# ── the live state column ──────────────────────────────────────────────────────
def test_the_state_column_reads_the_image_wide_selection():
    cfg = ImageConfig(optional_services=["anubis"])
    assert ds.image_service_state(cfg, "anubis") == "on (mesh-wide)"
    assert ds.image_service_state(cfg, "tor") == "off"


def test_all_services_does_not_claim_to_turn_the_infra_slugs_on():
    """`--all-services` expands to the USER-LEVEL set, which by construction excludes
    every infra slug. A membership test would report "off" for the right reason by
    accident and "on" for the user-level ones not at all — so both arms are pinned."""
    cfg = ImageConfig(optional_services=["all"])
    for slug in INFRA_SERVICES_CHOICES:
        state = ds.image_service_state(cfg, slug)
        assert state.startswith("off")
        assert "does not include the infra slugs" in state
    assert ds.image_service_state(cfg, "akkoma") == "on (mesh-wide)"


def test_the_explicit_none_sentinel_is_reported_as_the_explicit_none_it_is():
    cfg = ImageConfig(optional_services=["none"])
    assert "no optional services at all" in ds.image_service_state(cfg, "anubis")


def test_the_dedicated_tor_flag_counts_as_on():
    """x86 bakes the onion through `--with-tor`, not through the slug list. Reading only
    optional_services would report "off" for a node that really does publish one."""
    cfg = ImageConfig(tor_onion_service=True)
    assert ds.image_service_state(cfg, "tor") == "on (mesh-wide)"


def test_the_state_column_names_the_nodes_that_opted_in():
    entries = [WorklistEntry(role="omnibus", platform="x86",
                             infra_services=("tor",)),
               WorklistEntry(role="pki", platform="rpi5")]
    assert ds.node_service_state(entries, "tor") == "omnibus.x86"
    assert ds.node_service_state(entries, "egress-vpn") == ""
    rows = {r[0]: r for r in ds.other_scope_rows(ImageConfig(), entries)}
    assert "omnibus.x86" in rows["tor"][3]


def test_other_scope_rows_cover_every_infra_slug_plus_the_image_surface():
    rows = ds.other_scope_rows(ImageConfig())
    names = [r[0] for r in rows]
    assert names[:len(INFRA_SERVICES_CHOICES)] == list(INFRA_SERVICES_CHOICES)
    assert names[-1] == ds.IMAGE_SCOPE_ROW_LABEL
    assert rows[-1][1] == ds.SCOPE_IMAGE
    # the image-wide surface is named as a SURFACE, not re-listed slug by slug: a
    # second catalogue here would be one more thing to drift against the first.
    assert "edge-AI" in rows[-1][3]
    assert "managed backing services" in rows[-1][3]


def test_no_domain_catalogue_slug_leaks_into_the_not_domain_scoped_table():
    listed = {r[0] for r in ds.other_scope_rows(ImageConfig())}
    for slug in OPTIONAL_SERVICES_CHOICES:
        assert slug not in listed


# ── the GUI page ───────────────────────────────────────────────────────────────
pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo            # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod               # noqa: E402
from hugmesh_studio.gui.pages import domain_services as page_mod  # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                   # noqa: E402

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
            or QtWidgets.QApplication(["hugmesh-studio-domain-services-scope"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _page(wiz, *names):
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86")
    enable_additional_domains(wiz)
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    for n in names or ("acme.example",):
        dom._add(n, n.split(".")[0].title())
    return advance_to(wiz, page_mod.DomainServicesPage)


def test_every_offered_row_carries_its_scope_on_the_row(wiz):
    """ON THE ROW, not in a tooltip. The requirement is that the operator can SEE it."""
    page = _page(wiz)
    assert "Scope" in [page.table.headerItem().text(c)
                       for c in range(page.table.columnCount())]
    for slug, item in page._rows.items():
        assert item.text(page_mod._COL_SCOPE) == ds.SCOPE_LABELS[ds.SCOPE_DOMAIN], slug


def test_the_not_domain_scoped_table_is_present_and_names_every_infra_slug(wiz):
    page = _page(wiz)
    assert set(page._other_rows) >= set(INFRA_SERVICES_CHOICES)
    for slug in INFRA_SERVICES_CHOICES:
        row = page._other_rows[slug]
        assert row.text(1) == ds.SCOPE_LABELS[ds.SCOPE_NODE]
        assert row.text(2) == ds.INFRA_WHERE[slug]


def test_nothing_in_that_table_is_a_control(wiz):
    """DATA, never controls. A per-DOMAIN tick-box for a node- or cluster-plane slug
    would be a new lie — which is the sentence domains.py has carried since #227, and
    the reason this table is read-only rather than a second catalogue."""
    page = _page(wiz)
    for slug, item in page._other_rows.items():
        for col in range(page.other_table.columnCount()):
            assert page.other_table.itemWidget(item, col) is None, slug
        # Both halves. The flag alone renders no box (only a set check state does),
        # so asserting only the check state would pass on a row that is one
        # setCheckState away from being a control; asserting only the flag would pass
        # on a row whose box is already painted. The page clears the flag on purpose.
        assert not (item.flags() & Qt.ItemFlag.ItemIsUserCheckable), slug
        for col in range(page.other_table.columnCount()):
            assert item.data(col, Qt.ItemDataRole.CheckStateRole) is None, slug


def test_no_infra_slug_is_offered_as_a_per_domain_checkbox(wiz):
    page = _page(wiz)
    for slug in INFRA_SERVICES_CHOICES:
        assert slug not in page._boxes


def test_the_state_column_is_live(wiz):
    """It reads the image-wide selection and the worklist's per-node opt-ins, either of
    which may have changed since the page was last painted — so it is rebuilt on every
    _show(), not filled once in __init__."""
    page = _page(wiz)
    assert page._other_rows["anubis"].text(3) == "off"
    wiz.cfg.optional_services = ["anubis"]
    page._show()
    assert page._other_rows["anubis"].text(3) == "on (mesh-wide)"


def test_the_page_carries_a_legend_for_all_three_scopes(wiz):
    page = _page(wiz)
    legend = page.legend.text()
    for scope in (ds.SCOPE_DOMAIN, ds.SCOPE_IMAGE, ds.SCOPE_NODE):
        assert ds.SCOPE_LABELS[scope] in legend
        assert ds.SCOPE_WHERE[scope] in legend
        assert ds.SCOPE_BINDS[scope] in legend


def test_the_legend_is_built_from_core_not_retyped(wiz):
    """A retyped sentence is a sentence that goes stale in silence. Mutate the core
    wording and the page must follow it."""
    page = _page(wiz)
    assert page.legend.text() == page_mod._scope_legend()
    assert ds.SCOPE_BINDS[ds.SCOPE_NODE] in page_mod._scope_legend()


def test_the_other_table_survives_a_flow_with_no_domains(wiz):
    """The empty-domains arm clears BOTH tables; a stale not-domain-scoped table under
    a "no domains to configure" heading would be the page contradicting itself."""
    page = wiz.page(wiz._page_ids["domain_services"])
    page._names = []
    page._show()
    assert page._other_rows == {}
    assert page.other_table.topLevelItemCount() == 0


# ── the TUI face reads the same data ───────────────────────────────────────────
def test_the_tui_step_prints_the_same_scope_rows():
    from hugmesh_studio.tui import domain_services_step as tui_step
    cfg = ImageConfig(domains=[Domain(name="acme.example")],
                      optional_services=["anubis"])
    headers, rows = tui_step.other_scope_table(cfg)
    assert headers == list(ds.OTHER_SCOPE_HEADERS)
    assert [r[0] for r in rows] == [r[0] for r in ds.other_scope_rows(cfg)]
    assert rows[INFRA_SERVICES_CHOICES.index("anubis")][3] == "on (mesh-wide)"


def test_the_tui_service_table_carries_the_scope_column_too():
    from hugmesh_studio.tui import domain_services_step as tui_step
    headers, rows = tui_step.service_table(Domain(name="acme.example"))
    assert "scope" in headers
    for r in rows:
        assert r[headers.index("scope")] == ds.SCOPE_LABELS[ds.SCOPE_DOMAIN]
