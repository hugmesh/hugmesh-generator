"""DomainsPage 'Base CA' column (issue #335) — the per-domain half of the Vault
step's certificate list.

What is pinned here, and why each one:

* the column EXISTS, is appended after Sign-in (so every index those tests pin stays
  where it was), and is mesh-visible / cloud-hidden for the reason Sign-in is;
* the picker offers ``cfg.base_ca_certs`` with the PATH in the data role and the file
  name as the label, so the config stores a path while the label stays free to change;
* an untouched row writes NO key — ``cfg.domain_ca`` stays the empty dict a config
  that never met this column carries, which is what keeps the round trip byte-stable;
* the table is the SOLE writer of ``cfg.domain_ca``: renaming or deleting a domain
  cannot leave a stranded entry behind;
* the honest limit is stated on the surface, and PROVEN — a full table of choices
  changes the emitted argv by nothing and reaches no manifest;
* the wizard-order wrinkle is pinned rather than papered over: "domains" runs BEFORE
  "vault", so on a first forward pass the list really is empty, the cell says so, and
  a Back from the Secrets store repopulates it.

Runs the REAL wizard on Qt's offscreen platform (test_pages_domains_idp's harness).
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
    _COL_CA, _COL_IDP, _BaseCaCombo)
from hugmesh_studio.gui.pages import vault as vault_mod  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402

from _helpers import (  # noqa: E402
    advance_to, back_to, check_worklist_rows, enable_additional_domains,
    pick_mode)
from ca_fixtures import CA_ALT, CA_ROOT  # noqa: E402

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
            or QtWidgets.QApplication(["hugmesh-studio-domain-ca-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _mesh_domains(wiz, certs=()):
    """A mesh flow at the Domains page, with `certs` already collected as if the
    operator had been to the Secrets store and come back."""
    wiz.cfg.base_ca_certs = list(certs)
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86")
    enable_additional_domains(wiz)
    return advance_to(wiz, wizard_mod.DomainsPage)


# ── the column exists, in the appended position, mesh-only ───────────────────────────
def test_the_column_is_appended_after_sign_in(wiz):
    dom = _mesh_domains(wiz, [CA_ROOT])
    assert _COL_CA == _COL_IDP + 1
    assert dom.table.columnCount() == _COL_CA + 1
    assert dom.table.horizontalHeaderItem(_COL_CA).text() == "Base CA"
    assert not dom.table.isColumnHidden(_COL_CA)                  # mesh: visible


def test_cloud_hides_the_column_and_collects_no_choice(wiz):
    """A cloud client image provisions no domains, so the base CA is as meaningless
    there as the per-domain Casdoor is — hidden for the same reason, and a hidden
    combo still collects its untouched 'None' (leaves the output unchanged either way)."""
    wiz.cfg.base_ca_certs = [CA_ROOT]
    pick_mode(wiz, "cloud")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    assert dom.table.isColumnHidden(_COL_CA)
    dom._add("acme.example", "Acme")
    advance_to(wiz, wizard_mod.UsersPage)
    assert wiz.cfg.domain_ca == {}


# ── what the picker offers ───────────────────────────────────────────────────────────
def test_the_picker_offers_the_certificate_list_with_the_path_in_the_data_role(wiz):
    dom = _mesh_domains(wiz, [CA_ROOT, CA_ALT])
    dom._add("acme.example", "Acme")
    combo = dom.table.cellWidget(0, _COL_CA)
    assert isinstance(combo, _BaseCaCombo)
    assert [combo.itemData(i) for i in range(combo.count())] == ["", CA_ROOT, CA_ALT]
    assert [combo.itemText(i) for i in range(1, combo.count())] == \
        ["ca-root.pem", "ca-alt.pem"]
    assert combo.selected_ca() == ""                              # the default row


def test_with_no_certificates_the_cell_says_where_to_add_them(wiz):
    """WIZARD_PAGE_SLUGS puts "domains" before "vault", so on a first forward pass
    the list really is empty. The cell has to say why rather than look broken."""
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    combo = dom.table.cellWidget(0, _COL_CA)
    assert combo.count() == 1
    assert "Secrets store" in combo.itemText(0)
    assert "Secrets store" in dom.table.horizontalHeaderItem(_COL_CA).toolTip()


# ── the native default: an untouched table writes nothing ────────────────────────────
def test_an_untouched_row_writes_no_key_at_all(wiz):
    dom = _mesh_domains(wiz, [CA_ROOT])
    dom._add("acme.example", "Acme")
    before = wiz.cfg.to_cli_args()
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domain_ca == {}          # absent, not {"acme.example": ""}
    assert wiz.cfg.to_cli_args() == before
    assert "base_ca" not in str(wiz.cfg.mesh_manifest())


# ── a choice reaches cfg, and only cfg ───────────────────────────────────────────────
def test_choosing_a_ca_persists_to_cfg_domain_ca(wiz):
    dom = _mesh_domains(wiz, [CA_ROOT, CA_ALT])
    dom._add("acme.example", "Acme")
    dom._add("team.acme.example", "Team")
    combo = dom.table.cellWidget(1, _COL_CA)
    combo.setCurrentIndex(combo.findData(CA_ALT))
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domain_ca == {"team.acme.example": CA_ALT}
    wiz.cfg.validate_identity()


def test_a_choice_emits_no_flag_and_reaches_no_manifest(wiz):
    """The honest label, proven rather than asserted in a tooltip: no builder parses
    a CA flag and no manifest emitter carries the choice, so a full table changes the
    argv and the manifest by nothing. Wiring one later is what should break this."""
    dom = _mesh_domains(wiz, [CA_ROOT])
    dom._add("acme.example", "Acme")
    before = wiz.cfg.to_cli_args()
    combo = dom.table.cellWidget(0, _COL_CA)
    combo.setCurrentIndex(combo.findData(CA_ROOT))
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domain_ca == {"acme.example": CA_ROOT}
    assert wiz.cfg.to_cli_args() == before
    assert "ca-root" not in str(wiz.cfg.mesh_manifest())


def test_a_loaded_choice_seeds_the_combo_back(wiz):
    c = wiz.cfg
    c.mode = "mesh"
    c.role = "omnibus"
    c.additional_domains = True
    c.base_ca_certs = [CA_ROOT, CA_ALT]
    c.domains = [Domain(name="acme.example", title="Acme")]
    c.domain_ca = {"acme.example": CA_ALT}
    wiz.restart()
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    assert dom.table.cellWidget(0, _COL_CA).selected_ca() == CA_ALT
    advance_to(wiz, wizard_mod.UsersChoicePage)   # round-trips, never rewritten
    assert c.domain_ca == {"acme.example": CA_ALT}


# ── the table is the SOLE writer, so nothing can strand ──────────────────────────────
def test_deleting_a_domain_takes_its_choice_with_it(wiz):
    dom = _mesh_domains(wiz, [CA_ROOT])
    dom._add("acme.example", "Acme")
    dom._add("team.acme.example", "Team")
    for r in (0, 1):
        combo = dom.table.cellWidget(r, _COL_CA)
        combo.setCurrentIndex(combo.findData(CA_ROOT))
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert set(wiz.cfg.domain_ca) == {"acme.example", "team.acme.example"}
    # back_to, not a single back(): the per-domain Services step (#495) now sits
    # between Domains and the Users choice, so one back() lands there instead.
    back_to(wiz, wizard_mod.DomainsPage)
    dom.table.removeRow(1)
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domain_ca == {"acme.example": CA_ROOT}
    wiz.cfg.validate_identity()


def test_renaming_a_domain_does_not_leave_the_old_name_behind(wiz):
    dom = _mesh_domains(wiz, [CA_ROOT])
    dom._add("acme.example", "Acme")
    combo = dom.table.cellWidget(0, _COL_CA)
    combo.setCurrentIndex(combo.findData(CA_ROOT))
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domain_ca == {"acme.example": CA_ROOT}
    back_to(wiz, wizard_mod.DomainsPage)          # see the note above
    dom.table.item(0, 0).setText("renamed.example")
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domain_ca == {"renamed.example": CA_ROOT}


# ── back-nav from the Secrets store repopulates the pickers ──────────────────────────
def test_a_certificate_added_later_shows_up_on_a_back_nav(wiz, monkeypatch):
    """The whole reason _refresh_base_ca exists. Walk the operator's real route:
    Domains with an empty list, on to the Secrets store, add a PEM there, Back — and
    the picker now offers it, with the row's previous choice preserved."""
    dom = _mesh_domains(wiz)
    dom._add("acme.example", "Acme")
    assert dom.table.cellWidget(0, _COL_CA).count() == 1        # None only
    vault = advance_to(wiz, wizard_mod.VaultPage)
    monkeypatch.setattr(vault_mod, "pick_ca_certificates",
                        lambda *a, **k: ([CA_ROOT], ""))
    vault.ca_add.click()
    wiz.next()                                                  # commit the list
    assert wiz.cfg.base_ca_certs == [CA_ROOT]
    while wiz.currentId() != wiz._page_ids["domains"]:
        wiz.back()
    combo = dom.table.cellWidget(0, _COL_CA)
    assert [combo.itemData(i) for i in range(combo.count())] == ["", CA_ROOT]
    combo.setCurrentIndex(combo.findData(CA_ROOT))
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domain_ca == {"acme.example": CA_ROOT}


def test_a_choice_whose_certificate_was_removed_falls_back_to_none(wiz):
    """VaultPage.validatePage already clears cfg.domain_ca for a dropped certificate;
    this is the picker's own belt-and-braces, for the case where cfg is edited by
    anything other than that page (a hand-edited config, a future caller)."""
    dom = _mesh_domains(wiz, [CA_ROOT])
    dom._add("acme.example", "Acme")
    combo = dom.table.cellWidget(0, _COL_CA)
    combo.setCurrentIndex(combo.findData(CA_ROOT))
    wiz.cfg.base_ca_certs = []                       # the certificate is gone
    dom._refresh_base_ca()
    assert dom.table.cellWidget(0, _COL_CA).selected_ca() == ""
    advance_to(wiz, wizard_mod.UsersChoicePage)
    assert wiz.cfg.domain_ca == {}
    wiz.cfg.validate_identity()


# ── the copy ─────────────────────────────────────────────────────────────────────────
def test_the_column_copy_says_recorded_only(wiz):
    dom = _mesh_domains(wiz, [CA_ROOT])
    tip = dom.table.horizontalHeaderItem(_COL_CA).toolTip()
    assert "RECORDED ONLY" in tip
    assert "no builder parses a CA flag" in tip
    assert "consumed by nothing" in dom.table_help.text()
