"""The Domains step of the generate-a-new-local-mesh route names the INTERNAL domain.

Reported 2026-11-18: "the setup of the internal domain's services vs the rest of the
stack is very confusing on the domains page. Make sure that when making a stack in prd
that the internal domain that starts first has its own entry in the domains page."

On a PROD mesh the table's first row is the public apex the operator types. The internal
root name every node joins under (``<brand>.internal``) had no place on the page, so the
mesh's own infrastructure, chosen once for the whole mesh, read as that apex's services
beside the services of the domains added below it. The step now shows the internal domain
as an ENTRY of its own above the table. Pinned here:

* a prod mesh shows it, named with the superbrand's internal root, saying it starts
  first and that its services are the mesh's infrastructure;
* a test mesh (which publishes nothing) shows nothing new;
* it is display only and NOT a table row: the table still has the own domain as its first
  row, an untouched flow still records no domain, and nothing about the bring-up changes.
"""
import dataclasses
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.pages import domains as domains_mod            # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod        # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                            # noqa: E402

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
            or QtWidgets.QApplication(["hugmesh-studio-internal-entry-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _ctl(wiz):
    return wiz.page(wiz._page_ids["localmesh"])


def _to_env(wiz):
    wiz.next()
    mode = wiz.currentPage()
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    wiz.next()
    wiz.currentPage()._buttons["generate"].setChecked(True)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshEnvPage)


def _to_domains(wiz, *, prod: bool):
    _to_env(wiz)
    ctl = _ctl(wiz)
    if prod:
        ctl.env_prod.setChecked(True)
    for _ in range(6):
        if isinstance(wiz.currentPage(), localmesh_mod.LocalMeshDomainsPage):
            return ctl
        wiz.next()
    raise AssertionError("never reached the Domains step")


def test_a_prod_mesh_shows_the_internal_domain_as_an_entry_of_its_own(wiz):
    ctl = _to_domains(wiz, prod=True)
    entry = ctl.internal_entry
    assert entry.isVisibleTo(entry.parentWidget())
    # named with the superbrand's internal root: <id>.internal unless one was designed
    assert entry.shown_name() == ctl.brand_session().sb.effective_internal_root()
    assert entry.shown_name().endswith(".internal")
    assert entry.name.text().count(entry.shown_name()) == 1
    # it says what it is, that it starts first, and where its services are chosen
    assert "starts first" in entry.role.text()
    assert "never public" in entry.role.text()
    assert "chosen once for the whole mesh" in entry.services.text()
    assert "Services step" in entry.services.text()
    assert "no service page" in entry.services.text()
    assert "no sign-in" in entry.signin.text()


def test_the_entry_follows_a_designed_internal_root(wiz):
    ctl = _to_domains(wiz, prod=True)
    s = ctl.brand_session()
    s.sb = dataclasses.replace(s.sb, internal_root="acme.internal")
    ctl._refresh_internal_entry()
    assert ctl.internal_entry.shown_name() == "acme.internal"


def test_a_test_mesh_shows_no_internal_entry(wiz):
    ctl = _to_domains(wiz, prod=False)
    assert not ctl.internal_entry.isVisibleTo(ctl.internal_entry.parentWidget())
    assert ctl.internal_entry.shown_name() == ""


def test_switching_back_to_a_test_mesh_hides_it_again(wiz):
    ctl = _to_domains(wiz, prod=True)
    assert ctl.internal_entry.shown_name()
    wiz.back()
    ctl.env_test.setChecked(True)
    for _ in range(6):
        if isinstance(wiz.currentPage(), localmesh_mod.LocalMeshDomainsPage):
            break
        wiz.next()
    assert ctl.internal_entry.shown_name() == ""
    assert not ctl.internal_entry.isVisibleTo(ctl.internal_entry.parentWidget())


def test_the_entry_is_not_a_table_row_and_changes_nothing_collected(wiz):
    ctl = _to_domains(wiz, prod=True)
    t = ctl.domains_table
    assert ctl.internal_entry.shown_name()
    # the table is still exactly the own domain, first and alone
    assert t.table.rowCount() == 1 and t.is_own_row(0)
    assert ctl.internal_entry.shown_name() not in [
        t.table.item(r, 0).text() for r in range(t.table.rowCount())]
    t.table.item(0, 0).setText("example.com")
    wiz.next()
    added, _ca = t.rows()
    assert added == []
    cfg = ctl.collect_bootstrap()
    assert cfg.cluster_domain == "example.com"
    assert cfg.domains == ()                    # default-shaped: nothing recorded
    assert cfg.own_idp_domains == ()
    assert [d.name for d in ctl.mesh_domains.domains] == ["example.com"]


def test_the_entry_alone_has_no_name_until_it_is_given_one(qapp):
    entry = domains_mod.InternalDomainEntry()
    try:
        assert entry.shown_name() == "" and not entry.isVisibleTo(entry)
        entry.set_name("  acme.internal ")
        assert entry.shown_name() == "acme.internal"
        entry.set_name("")
        assert entry.shown_name() == ""
    finally:
        entry.close()
        entry.deleteLater()


def test_the_tables_own_wording_is_untouched(wiz):
    """The internal domain is said by its entry, not by the table's help: that help
    still opens with the first-row sentence every face repeats (test_tui_gui_parity)."""
    ctl = _to_domains(wiz, prod=True)
    assert ctl.domains_help.text().startswith("The first row is this mesh's OWN domain")


def test_the_entry_sits_above_the_table_inside_the_page_at_the_default_size(wiz):
    """Geometry, not just state: a control that is not drawn where a person looks is not
    there (the repo's rule 8)."""
    ctl = _to_domains(wiz, prod=True)
    QtWidgets.QApplication.processEvents()
    entry, table = ctl.internal_entry, ctl.domains_table
    top_of_table = table.mapTo(wiz, table.rect().topLeft()).y()
    entry_tl = entry.mapTo(wiz, entry.rect().topLeft())
    assert entry.isVisible() and entry.height() > 0
    assert entry_tl.y() + entry.height() <= top_of_table
    assert entry_tl.x() >= 0 and entry_tl.x() + entry.width() <= wiz.width()
    # every line is drawn whole: word-wrapped labels grow, none is cut to a stub
    for lab in (entry.role, entry.services, entry.signin):
        assert lab.height() >= lab.fontMetrics().height()
