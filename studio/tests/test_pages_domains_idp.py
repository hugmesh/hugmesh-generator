"""DomainsPage 'Sign-in' column (issue #47) — the first SURFACE of the per-domain
'own Casdoor vs superdomain Casdoor' choice:

* the column exists, is mesh-visible / cloud-hidden (a cloud client hosts no
  Casdoor and writes no manifest — the _COL_APPLIES precedent), and its combo
  carries the SCHEMA values in the data role (labels are free to change);
* an untouched row collects the superdomain default (today's behavior — the
  manifest emits NO idp key at all);
* choosing Own persists through validatePage -> cfg.domains -> mesh_manifest,
  and a loaded config's 'own' row seeds the combo back.

Runs the REAL wizard on Qt's offscreen platform (test_pages_identity.py's
harness style); skipped whole when no Qt binding is installed.
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import (  # noqa: E402
    DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, Domain)
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages.domains import _COL_IDP, _IdpCombo  # noqa: E402
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
            or QtWidgets.QApplication(["hugmesh-studio-domain-idp-tests"]))


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


def test_combo_offers_both_choices_by_schema_value(wiz):
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    combo = dom.table.cellWidget(added_row(dom, 0), _COL_IDP)
    assert isinstance(combo, _IdpCombo)
    values = [combo.itemData(i) for i in range(combo.count())]
    assert values == [DOMAIN_IDP_SUPERDOMAIN, DOMAIN_IDP_OWN]
    assert combo.selected_idp() == DOMAIN_IDP_SUPERDOMAIN      # the default
    assert not dom.table.isColumnHidden(_COL_IDP)              # mesh: visible


def test_untouched_row_persists_the_superdomain_default(wiz):
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    advance_to(wiz, wizard_mod.UsersChoicePage)     # Next past Domains collects
    c = wiz.cfg
    assert [d.idp for d in c.domains] == [DOMAIN_IDP_SUPERDOMAIN]
    # today's behavior byte-for-byte: the manifest emits NO idp key at all
    assert "idp" not in c.mesh_manifest()["domains"][0]


def test_choosing_own_persists_to_config_and_manifest(wiz):
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    dom._add("team.acme.example", "Team")
    combo = dom.table.cellWidget(added_row(dom, 1), _COL_IDP)
    combo.setCurrentIndex(combo.findData(DOMAIN_IDP_OWN))
    advance_to(wiz, wizard_mod.UsersChoicePage)
    c = wiz.cfg
    assert [d.idp for d in c.domains] == [DOMAIN_IDP_SUPERDOMAIN, DOMAIN_IDP_OWN]
    assert c.own_idp_domains() == ("team.acme.example",)
    assert c.mesh_manifest()["domains"][1]["idp"] == DOMAIN_IDP_OWN


def test_loaded_own_row_seeds_the_combo_back(wiz):
    c = wiz.cfg
    c.mode = "mesh"
    c.role = "omnibus"
    c.additional_domains = True
    c.domains = [Domain(name="acme.example", title="Acme", idp=DOMAIN_IDP_OWN)]
    wiz.restart()
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    combo = dom.table.cellWidget(added_row(dom, 0), _COL_IDP)
    assert combo.selected_idp() == DOMAIN_IDP_OWN
    advance_to(wiz, wizard_mod.UsersChoicePage)     # round-trips, never rewritten
    assert [d.idp for d in c.domains] == [DOMAIN_IDP_OWN]


def test_cloud_hides_the_signin_column_and_collects_the_default(wiz):
    pick_mode(wiz, "cloud")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    assert dom.table.isColumnHidden(_COL_IDP)
    advance_to(wiz, wizard_mod.UsersPage)           # Next past Domains collects
    assert all(d.idp == DOMAIN_IDP_SUPERDOMAIN for d in wiz.cfg.domains)
