"""The Domains table's display-only own row is RE-DERIVED on every forward entry
(#494 fix round, PR #595 skeptics).

``DomainsPage.initializePage`` refills the table only when it is empty or the config
object changed (#542), so before this the own row (row 0, mesh only) survived a
same-object Back that changed what it stands for:

* mesh -> Add more domains -> Domains -> Back to Mode -> cloud -> Domains: the stale
  mesh row kept the table non-empty, the cloud prefill never ran, ``rows()`` skipped
  the own row — a cloud client lost its FD-08 ``--domains`` while the table showed
  the domain (origin/main emits ``--domains hugmesh.net`` on this walk);
* the cluster domain renamed on the Network step: row 0 kept the old name while the
  very next step said "Services for <new name>".
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo                # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                   # noqa: E402
from hugmesh_studio.gui.pages import domain_services as page_mod      # noqa: E402
from hugmesh_studio.gui.pages.network import NetworkPage              # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                           # noqa: E402

from _helpers import (  # noqa: E402
    added_names, advance_to, back_to, check_worklist_rows,
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
            or QtWidgets.QApplication(["hugmesh-studio-own-row-reconcile"]))


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


def _own_rows(dom):
    return [r for r in range(dom.table.rowCount()) if dom.is_own_row(r)]


def test_mesh_to_cloud_switch_restores_the_cloud_prefill_and_its_domains_argv(wiz):
    dom = _mesh_domains(wiz)
    own = wiz.cfg.cluster_domain
    assert _own_rows(dom) == [0] and dom.table.item(0, 0).text() == own
    back_to(wiz, wizard_mod.ModePage)
    pick_mode(wiz, "cloud")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    # no stale mesh-only display row: the cloud prefill is a REAL, removable row 0
    assert _own_rows(dom) == []
    assert added_names(dom) == [own]
    assert dom.validatePage() is True
    assert [d.name for d in wiz.cfg.domains] == [own]
    argv = wiz.cfg.to_cli_args()
    assert "--domains" in argv and argv[argv.index("--domains") + 1] == own


def test_mesh_to_cloud_keeps_added_rows_and_drops_only_the_own_row(wiz):
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    back_to(wiz, wizard_mod.ModePage)
    pick_mode(wiz, "cloud")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    assert _own_rows(dom) == []
    assert added_names(dom) == ["acme.example"]      # in-progress edit survives


def test_a_renamed_cluster_domain_renames_row_0_before_the_services_step(wiz):
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    net = back_to(wiz, NetworkPage)
    net.domain.setText("changed.example")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    assert wiz.cfg.cluster_domain == "changed.example"
    assert _own_rows(dom) == [0]
    assert dom.table.item(0, 0).text() == "changed.example"
    assert added_names(dom) == ["acme.example"]      # the added row is untouched
    page = advance_to(wiz, page_mod.DomainServicesPage)
    assert page.current_domain() == dom.table.item(0, 0).text()


def test_an_own_only_table_renamed_keeps_exactly_one_own_row(wiz):
    dom = _mesh_domains(wiz)
    net = back_to(wiz, NetworkPage)
    net.domain.setText("changed.example")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    assert _own_rows(dom) == [0] and dom.table.rowCount() == 1
    assert dom.table.item(0, 0).text() == "changed.example"
    assert dom.validatePage() is True and wiz.cfg.domains == []
