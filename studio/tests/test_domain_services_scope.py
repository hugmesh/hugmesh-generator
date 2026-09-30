"""The per-domain Services page's SCOPE surfaces, as GUI (#497).

The scope MODEL — the three scopes, the per-slug where-text, and the two state reads
that are easy to get wrong (`--all-services` vs the infra slugs, the dedicated
`--with-tor` flag) — is tested Qt-free in tests/test_domain_services.py, because the
pre-merge CI job installs no Qt binding and the `importorskip` below skips this whole
module there.

What is pinned here is what only a real page can answer: the Scope column is on every
row, the not-domain-scoped table exists and carries each infra slug's real scope and
where-text, nothing in it is a control, the state column is live, and the legend is the
core-built string rather than a retyped copy.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import domain_services as ds                 # noqa: E402
from hugmesh_studio.core.config import (                              # noqa: E402
    INFRA_SERVICES_CHOICES, Domain, ImageConfig)
from hugmesh_studio.core.platform_info import HostInfo                # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                   # noqa: E402
from hugmesh_studio.gui.pages import domain_services as page_mod      # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                       # noqa: E402

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
