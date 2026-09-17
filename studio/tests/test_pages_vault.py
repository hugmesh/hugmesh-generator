"""VaultPage (issue #224, extended by #335) — the GUI face of the mesh secrets store.

Runs the REAL wizard on Qt's offscreen platform (the test_pages_domains_idp harness
style). Pins: the page is mesh-only; the empty address is the byte-identical
default; a set address reaches cfg AND the emitted argv; the fail-closed rule is
the ONE shared predicate rendered inline (never a modal — a QMessageBox in
validatePage hangs headless tests); residue is cleared with the address; a loaded
config seeds the widgets back.

#335 adds two surfaces and both are pinned for what they REALLY do rather than what
the copy could claim: the EXTERNAL address (a real flag, a real baked key, no reader
— test_vault_config.py owns the builder half) and the BASE CA CERTIFICATE list
(recorded only, emitting nothing anywhere). The certificate picker is the page's one
dialog: it is driven here through the module-level ``pick_ca_certificates`` seam, and
a test asserts it is reachable from nothing but the explicit Add click.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import VAULT_FIELDS  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages import vault as vault_mod  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402

from _helpers import advance_to, check_worklist_rows, pick_mode  # noqa: E402
from ca_fixtures import (CA_ALT, CA_FRAMED_NOT_DER, CA_ROOT,  # noqa: E402
                         HAVE_CRYPTOGRAPHY)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

ADDR = "https://vault.acme.example:8200"          # INTERNAL — the pre-#335 field
EXT = "https://vault.acme.example.com:8200"      # EXTERNAL (#335) — must differ
_NEXT = QtWidgets.QWizard.WizardButton.NextButton


def _picks(*paths):
    """A stand-in for the file dialog seam: returns exactly these paths, once."""
    return lambda *a, **k: (list(paths), "")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-vault-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _mesh_vault(wiz, *rows):
    """A mesh flow with the given worklist rows, advanced to the secrets-store page."""
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, *(rows or ("omnibus.x86",)))
    return advance_to(wiz, wizard_mod.VaultPage)


# ── placement + mode gating ──────────────────────────────────────────────────────────
def test_the_page_is_registered_after_system_identity(wiz):
    ids = wiz.pageIds()
    assert ids.index(wiz._page_ids["vault"]) == ids.index(wiz._page_ids["system"]) + 1
    assert isinstance(wiz.page(wiz._page_ids["vault"]), vault_mod.VaultPage)


@pytest.mark.parametrize("mode", ["standalone", "cloud"])
def test_the_non_node_modes_never_visit_it(wiz, mode):
    pick_mode(wiz, mode)
    advance_to(wiz, wizard_mod.BuildPage)
    assert not wiz.hasVisitedPage(wiz._page_ids["vault"])
    assert wiz.cfg.vault_addr == ""


def test_the_mesh_flow_visits_it(wiz):
    page = _mesh_vault(wiz)
    assert isinstance(page, vault_mod.VaultPage)
    assert page.box.isEnabled()                  # an x86 node row can take the flag


# ── the offline default: byte identity ───────────────────────────────────────────────
def test_untouched_page_commits_nothing_and_emits_nothing(wiz):
    page = _mesh_vault(wiz)
    assert page.isComplete()
    assert "no --vault-addr is emitted" in page.note.text()
    assert "brand.conf" in page.note.text()        # honest about the builder fallback
    before = wiz.cfg.to_cli_args()
    wiz.next()
    assert wiz.currentId() != wiz._page_ids["vault"]
    assert all(getattr(wiz.cfg, f) == "" for f in VAULT_FIELDS)
    assert wiz.cfg.to_cli_args() == before
    assert not any(a.startswith("--vault") for a in before)


# ── a set address reaches cfg + argv ─────────────────────────────────────────────────
def test_a_set_address_reaches_cfg_and_the_emitted_argv(wiz):
    page = _mesh_vault(wiz)
    page.addr.setText(ADDR)
    page.external_addr.setText(EXT)
    assert page.isComplete()
    assert ADDR in page.note.text() and "vault.conf" in page.note.text()
    wiz.next()
    c = wiz.cfg
    assert (c.vault_addr, c.vault_external_addr) == (ADDR, EXT)
    args = c.to_cli_args()
    assert ("--vault-addr", ADDR) in list(zip(args, args[1:]))
    assert ("--vault-external-addr", EXT) in list(zip(args, args[1:]))


def test_the_removed_path_flags_are_never_emitted_from_this_page(wiz):
    """#285, decision 22: --vault-kv-mount / --vault-base-path are GONE from both
    node builders, so emitting either would abort a real build with "Unknown
    option" — a harder failure than the dead knob they used to be. Nothing on this
    page can produce them, and the page carries no widget for them either."""
    page = _mesh_vault(wiz)
    page.addr.setText(ADDR)
    page.external_addr.setText(EXT)
    wiz.next()
    args = wiz.cfg.to_cli_args()
    assert "--vault-addr" in args
    assert "--vault-kv-mount" not in args and "--vault-base-path" not in args
    assert not hasattr(page, "kv_mount") and not hasattr(page, "base_path")


# ── the fail-closed rule, rendered inline (never a modal) ────────────────────────────
def test_an_http_address_greys_next_with_the_reason_inline(wiz, qapp):
    """Asserted on the BUTTON, not by calling wiz.next(): QWizard.next() bypasses
    the button bar entirely (it never consults isComplete), so the operator's
    actual route — a greyed Next — is what must be pinned."""
    page = _mesh_vault(wiz)
    qapp.processEvents()
    assert wiz.button(_NEXT).isEnabled()
    page.addr.setText("http://vault.acme.example")
    qapp.processEvents()
    assert not page.isComplete()
    assert "https://" in page.note.text()
    assert not wiz.button(_NEXT).isEnabled()      # the gate held
    page.addr.setText(ADDR)
    qapp.processEvents()
    assert page.isComplete()
    assert wiz.button(_NEXT).isEnabled()


def test_an_external_address_without_an_internal_one_is_refused(wiz):
    page = _mesh_vault(wiz)
    page.external_addr.setText(EXT)
    assert not page.isComplete()
    assert "no Vault address" in page.note.text()
    page.addr.setText(ADDR)
    assert page.isComplete()


def test_a_shell_shaped_external_address_is_refused(wiz):
    page = _mesh_vault(wiz)
    page.addr.setText(ADDR)
    page.external_addr.setText("$(rm -rf /)")
    assert not page.isComplete()
    assert "external Vault address" in page.note.text()


def test_clearing_the_address_clears_the_residue_on_commit(wiz):
    page = _mesh_vault(wiz)
    page.addr.setText(ADDR)
    page.external_addr.setText(EXT)
    page.addr.setText("")                         # typed, then thought better of it
    assert not page.isComplete()                  # a stray external address is refused
    page.external_addr.setText("")
    assert page.isComplete()
    wiz.next()
    assert all(getattr(wiz.cfg, f) == "" for f in VAULT_FIELDS)


def test_a_committed_pair_is_cleared_on_a_SECOND_commit(wiz):
    """The residue branch is only REACHED once a non-empty pair has already been
    committed and the operator then clears it. The test above clears the widgets
    before its only next(), so it never commits the intermediate state the branch
    exists to fix — deleting the branch survived a 2043-test sweep in the 2026-09-04
    adversarial review while leaving a real regression: cfg kept the residue with an
    empty address, and validate_identity() then refused the build. Walk the
    operator's actual route: commit, go back, clear both, commit again.

    (Written over the mount/base-path trio; #285 decision 22 removed those two
    fields, and the EXTERNAL address is now the residue this branch must clear. The
    separate `test_clearing_the_address_clears_the_external_one_too` that used to sit
    below walked this exact route once the two path widgets were gone — its rationale
    is folded in here rather than kept as a duplicate: the external address is residue
    exactly as the mount and base path were, and a SECOND commit after clearing must
    leave cfg at the native default.)"""
    page = _mesh_vault(wiz)
    page.addr.setText(ADDR)
    page.external_addr.setText(EXT)
    wiz.next()                                     # COMMIT 1: the full pair
    assert (wiz.cfg.vault_addr, wiz.cfg.vault_external_addr) == (ADDR, EXT)
    wiz.back()
    assert wiz.currentId() == wiz._page_ids["vault"]
    page.addr.setText("")
    page.external_addr.setText("")
    assert page.isComplete()
    wiz.next()                                     # COMMIT 2: back to the default
    assert all(getattr(wiz.cfg, f) == "" for f in VAULT_FIELDS)
    wiz.cfg.validate_identity()                    # stranded residue raises here
    assert not any(a.startswith("--vault") for a in wiz.cfg.to_cli_args())


# ── the copy says how far each field actually reaches ────────────────────────────────
def test_the_page_offers_no_mount_or_base_path_control_and_says_why(wiz):
    """#285, decision 22 on #347 ("A: drop both controls"). The KV-mount and
    base-path fields were validated, threaded as flags, baked into vault.conf and
    logged at first boot — and read by NOTHING. They are gone. What replaces them is
    a statement, not a knob: the cluster reads secret/<brand>/... by design.

    Pinned as a NEGATIVE (no widget, no flag anywhere in the module source) plus the
    positive claim in the copy, so re-adding either field fails here rather than
    shipping a second dead knob."""
    page = _mesh_vault(wiz)
    assert not hasattr(page, "kv_mount") and not hasattr(page, "base_path")
    src = open(vault_mod.__file__, encoding="utf-8").read()
    # the flags may be NAMED in the prose that explains their removal, but never
    # emitted: no argv list on this page may contain them (the page emits none at
    # all — cfg._vault_args does — so assert on the config's own emission).
    page.addr.setText(ADDR)
    wiz.next()
    assert not any("--vault-kv-mount" == a or "--vault-base-path" == a
                   for a in wiz.cfg.to_cli_args())
    # the copy states the design and names both pinning sites, so the claim is
    # checkable rather than a bare assertion
    assert "secret/<brand>/" in vault_mod._LIMITS_NOTE
    assert "ClusterSecretStore" in vault_mod._LIMITS_NOTE
    assert "brand slug" in vault_mod._LIMITS_NOTE
    assert "removed" in vault_mod._LIMITS_NOTE
    assert "secret/<brand>/" in src
    # the ADDRESS, by contrast, IS live — it is what enables the seeding at all
    assert "seeding ON" in page.addr.toolTip()


def test_the_page_never_opens_a_modal():
    """The repo rule: no QMessageBox / exec() in a validatePage or change path."""
    src = open(vault_mod.__file__, encoding="utf-8").read()
    assert "QMessageBox" not in src and ".exec(" not in src


# ── reload + the no-consumer flow ────────────────────────────────────────────────────
def test_a_loaded_config_seeds_the_widgets_back(wiz):
    wiz.cfg.vault_addr = ADDR
    wiz.cfg.vault_external_addr = EXT
    page = _mesh_vault(wiz)
    assert page.addr.text() == ADDR
    assert page.external_addr.text() == EXT
    assert page.isComplete()


def test_a_worklist_no_builder_of_which_parses_the_flag_greys_the_group(wiz):
    """Only jetson rows: no builder in the flow takes --vault-*, so the surface greys
    with the reason and a stale value is cleared rather than stranded (the per-entry
    strip would drop it anyway — emission-neutral, but now visibly so)."""
    wiz.cfg.vault_addr = ADDR
    page = _mesh_vault(wiz, "edge-ai.jetson")
    assert not page.box.isEnabled()
    assert page.box.toolTip()
    wiz.next()
    assert wiz.cfg.vault_addr == ""


# ── the internal/external split (#335) ───────────────────────────────────────────────
def test_the_external_address_is_a_separate_field_that_keeps_the_internal_key(wiz):
    """The split had to be additive: today's single field STAYS cfg.vault_addr and
    --vault-addr (every saved config, every builder, every test that pins it), and
    the external one is a NEW key beside it. Pin both halves so a future rename
    cannot quietly reassign which address is which."""
    page = _mesh_vault(wiz)
    assert tuple(page.field_widgets) == VAULT_FIELDS
    assert page.field_widgets["vault_addr"] is page.addr
    assert page.field_widgets["vault_external_addr"] is page.external_addr
    page.addr.setText(ADDR)
    page.external_addr.setText(EXT)
    assert page.isComplete()
    wiz.next()
    assert wiz.cfg.vault_addr == ADDR and wiz.cfg.vault_external_addr == EXT
    args = wiz.cfg.to_cli_args()
    assert ("--vault-addr", ADDR) in list(zip(args, args[1:]))
    assert ("--vault-external-addr", EXT) in list(zip(args, args[1:]))


def test_an_untouched_external_field_emits_nothing(wiz):
    page = _mesh_vault(wiz)
    page.addr.setText(ADDR)
    wiz.next()
    assert wiz.cfg.vault_external_addr == ""
    assert "--vault-external-addr" not in wiz.cfg.to_cli_args()


@pytest.mark.parametrize("bad, fragment", [
    ("http://ext.acme.example", "https://"),
    (ADDR, "same as the internal"),
])
def test_a_bad_external_address_greys_next_with_the_reason_inline(wiz, qapp, bad,
                                                                  fragment):
    page = _mesh_vault(wiz)
    page.addr.setText(ADDR)
    qapp.processEvents()
    assert wiz.button(_NEXT).isEnabled()
    page.external_addr.setText(bad)
    qapp.processEvents()
    assert not page.isComplete()
    assert fragment in page.note.text()
    assert not wiz.button(_NEXT).isEnabled()      # the gate held; no modal anywhere


def test_the_external_tooltip_says_it_has_no_reader(wiz):
    """It IS baked (test_vault_config.py reads it back out of vault.conf), and it
    changes nothing at boot. Both halves have to be in the tooltip: claiming only the
    first would oversell it, claiming only the second would understate a real flag."""
    tip = page_tip = _mesh_vault(wiz).external_addr.toolTip()
    assert "--vault-external-addr" in tip and "vault.conf" in tip
    assert "no reader" in page_tip.lower() or "NO reader" in tip
    assert "must differ" in tip


# ── base CA certificates (#335): recorded, checked, and honest about it ──────────────
def test_the_certificate_list_starts_empty_and_commits_nothing(wiz):
    page = _mesh_vault(wiz)
    assert page.ca_list.count() == 0
    before = wiz.cfg.to_cli_args()
    wiz.next()
    assert wiz.cfg.base_ca_certs == [] and wiz.cfg.domain_ca == {}
    assert wiz.cfg.to_cli_args() == before


def test_adding_a_pem_records_its_path_and_shows_subject_and_expiry(wiz, monkeypatch):
    page = _mesh_vault(wiz)
    monkeypatch.setattr(vault_mod, "pick_ca_certificates", _picks(CA_ROOT))
    page.ca_add.click()
    assert page.ca_list.count() == 1
    row = page.ca_list.item(0)
    assert row.data(vault_mod.Qt.ItemDataRole.UserRole) == CA_ROOT
    assert "ca-root.pem" in row.text()
    assert "HugMesh Studio Test Root CA" in row.text()      # read from the certificate
    assert "expires 2126" in row.text()
    assert "Added ca-root.pem" in page.ca_note.text()
    wiz.next()
    assert wiz.cfg.base_ca_certs == [CA_ROOT]


def test_adding_a_file_that_is_not_a_certificate_is_refused_inline(wiz, monkeypatch,
                                                                   tmp_path):
    """The whole point of the check: the list cannot fill with files that are not
    certificates. Refusal is an inline sentence naming the file — never a modal, and
    never a silent no-op that leaves the operator thinking it worked."""
    junk = tmp_path / "notes.txt"
    junk.write_text("this is not a certificate\n", encoding="utf-8")
    page = _mesh_vault(wiz)
    monkeypatch.setattr(vault_mod, "pick_ca_certificates", _picks(str(junk)))
    page.ca_add.click()
    assert page.ca_list.count() == 0
    assert "Not added" in page.ca_note.text()
    assert "notes.txt" in page.ca_note.text()
    assert "BEGIN CERTIFICATE" in page.ca_note.text()


@pytest.mark.skipif(not HAVE_CRYPTOGRAPHY,
                    reason="python-cryptography is optional; without it the picker "
                           "degrades to the framing-only check on purpose")
def test_the_picker_refuses_pem_framing_that_is_not_a_certificate(wiz, monkeypatch):
    """The skeptic's gap, at the GUI door: a file with real BEGIN/END CERTIFICATE
    framing over a decodable body that is NOT DER used to be ADDED, and its row then
    read "could not read its fields" — the list saying a thing is a CA when it is not.
    It is now refused where every other refusal happens, inline and named."""
    page = _mesh_vault(wiz)
    monkeypatch.setattr(vault_mod, "pick_ca_certificates", _picks(CA_FRAMED_NOT_DER))
    page.ca_add.click()
    assert page.ca_list.count() == 0
    assert "Not added" in page.ca_note.text()
    assert "framed-not-der.pem" in page.ca_note.text()
    assert "not an X.509 certificate" in page.ca_note.text()


def test_a_private_key_is_named_for_what_it_is(wiz, monkeypatch, tmp_path):
    key = tmp_path / "ca.key"
    key.write_text("-----BEGIN PRIVATE KEY-----\nQUJD\n-----END PRIVATE KEY-----\n",
                   encoding="utf-8")
    page = _mesh_vault(wiz)
    monkeypatch.setattr(vault_mod, "pick_ca_certificates", _picks(str(key)))
    page.ca_add.click()
    assert page.ca_list.count() == 0
    assert "PRIVATE KEY" in page.ca_note.text()


def test_a_multi_select_adds_the_good_ones_and_names_the_rest(wiz, monkeypatch,
                                                              tmp_path):
    junk = tmp_path / "junk.pem"
    junk.write_text("nope\n", encoding="utf-8")
    page = _mesh_vault(wiz)
    monkeypatch.setattr(vault_mod, "pick_ca_certificates",
                        _picks(CA_ROOT, str(junk), CA_ALT))
    page.ca_add.click()
    assert page.certificates() == [CA_ROOT, CA_ALT]
    assert "Added ca-root.pem, ca-alt.pem" in page.ca_note.text()
    assert "junk.pem" in page.ca_note.text()


def test_the_same_certificate_cannot_be_added_twice(wiz, monkeypatch):
    page = _mesh_vault(wiz)
    monkeypatch.setattr(vault_mod, "pick_ca_certificates", _picks(CA_ROOT))
    page.ca_add.click()
    page.ca_add.click()
    assert page.certificates() == [CA_ROOT]
    assert "already in the list" in page.ca_note.text()


def test_a_cancelled_dialog_changes_nothing_and_says_nothing(wiz, monkeypatch):
    page = _mesh_vault(wiz)
    monkeypatch.setattr(vault_mod, "pick_ca_certificates", lambda *a, **k: ([], ""))
    page.ca_add.click()
    assert page.ca_list.count() == 0 and page.ca_note.text() == ""


def test_removing_a_certificate_clears_the_domains_that_picked_it(wiz, monkeypatch):
    """The repair that makes domain_ca_error's rule UNREACHABLE through the GUI
    rather than merely enforced at emission: a domain may not name a CA the config no
    longer carries, so removing one clears it from every domain on commit."""
    page = _mesh_vault(wiz)
    monkeypatch.setattr(vault_mod, "pick_ca_certificates", _picks(CA_ROOT, CA_ALT))
    page.ca_add.click()
    wiz.cfg.domain_ca = {"a.example": CA_ROOT, "b.example": CA_ALT}
    page.ca_list.setCurrentRow(0)                  # ca-root.pem
    page.ca_remove.click()
    assert page.certificates() == [CA_ALT]
    assert "Removed ca-root.pem" in page.ca_note.text()
    wiz.next()
    assert wiz.cfg.base_ca_certs == [CA_ALT]
    assert wiz.cfg.domain_ca == {"b.example": CA_ALT}
    wiz.cfg.validate_identity()                    # a stranded choice raises here


def test_remove_with_nothing_selected_says_so(wiz):
    page = _mesh_vault(wiz)
    page.ca_remove.click()
    assert "Select a certificate" in page.ca_note.text()


def test_a_loaded_certificate_that_has_since_moved_is_KEPT_and_marked(wiz, tmp_path):
    """A saved config names an absolute path; the file can be unreadable by the time
    it is re-opened — moved, or on a volume that is not mounted this morning. Merely
    OPENING this page must not destroy the recorded list over that: the row is kept,
    marked, and still committed. Nothing about it blocks a build (validate_identity
    does not check readability), so the operator decides, not initializePage."""
    gone = str(tmp_path / "moved-away.pem")
    wiz.cfg.base_ca_certs = [CA_ROOT, gone]
    page = _mesh_vault(wiz)
    assert page.certificates() == [CA_ROOT, gone]           # KEPT, in order
    assert "moved-away.pem" in page.ca_note.text()
    assert "kept in the list" in page.ca_note.text()
    row = page.ca_list.item(1)
    assert "NOT READABLE RIGHT NOW" in row.text()
    assert "not a readable file" in row.text()
    wiz.next()
    assert wiz.cfg.base_ca_certs == [CA_ROOT, gone]         # and still committed
    wiz.cfg.validate_identity()


def test_a_domain_choice_survives_a_temporarily_unreadable_certificate(wiz, tmp_path):
    """The consequence that makes the KEEP matter: dropping the row would also strip
    every domain pointing at it (validatePage prunes domain_ca to the listed set), so
    one page visit with a volume unmounted would silently lose the operator's per-domain
    trust choices for good."""
    moved = tmp_path / "later-gone.pem"
    moved.write_text(open(CA_ROOT, encoding="utf-8").read(), encoding="utf-8")
    wiz.cfg.base_ca_certs = [str(moved)]
    wiz.cfg.domain_ca = {"acme.example": str(moved)}
    moved.unlink()                                          # the volume goes away
    page = _mesh_vault(wiz)
    assert page.certificates() == [str(moved)]
    wiz.next()
    assert wiz.cfg.domain_ca == {"acme.example": str(moved)}
    wiz.cfg.validate_identity()


def test_removing_a_kept_unreadable_row_is_still_the_operators_call(wiz, tmp_path):
    """Keeping it is not trapping it: the row selects and removes like any other, and
    the domain choice pointing at it is repaired on the way out as always."""
    gone = str(tmp_path / "moved-away.pem")
    wiz.cfg.base_ca_certs = [CA_ROOT, gone]
    wiz.cfg.domain_ca = {"acme.example": gone}
    page = _mesh_vault(wiz)
    page.ca_list.item(1).setSelected(True)
    page.ca_remove.click()
    assert page.certificates() == [CA_ROOT]
    wiz.next()
    assert wiz.cfg.base_ca_certs == [CA_ROOT]
    assert wiz.cfg.domain_ca == {}
    wiz.cfg.validate_identity()


def test_a_loaded_certificate_list_seeds_the_widget_back(wiz):
    wiz.cfg.base_ca_certs = [CA_ROOT, CA_ALT]
    page = _mesh_vault(wiz)
    assert page.certificates() == [CA_ROOT, CA_ALT]
    assert page.ca_note.text() == ""


def test_the_ca_surface_emits_no_flag_on_any_platform(wiz, monkeypatch):
    """The honest label, proven: a full certificate list changes the argv by nothing.
    If someone later wires a --base-ca flag, this test is what makes them come back
    and rewrite the copy that says it is recorded only."""
    page = _mesh_vault(wiz)
    before = wiz.cfg.to_cli_args()
    monkeypatch.setattr(vault_mod, "pick_ca_certificates", _picks(CA_ROOT, CA_ALT))
    page.ca_add.click()
    wiz.next()                                     # certificates ONLY, no address
    assert wiz.cfg.base_ca_certs == [CA_ROOT, CA_ALT]
    assert wiz.cfg.to_cli_args() == before         # byte-identical argv
    assert "ca-root.pem" not in " ".join(wiz.cfg.to_cli_args())
    # ...and the same holds with a per-domain choice on top of the list
    wiz.cfg.domain_ca = {"a.example": CA_ROOT}
    assert wiz.cfg.to_cli_args() == before
    wiz.cfg.validate_identity()


def test_the_ca_copy_says_recorded_not_consumed(wiz):
    """The named failure mode is a knob that silently does nothing. This one really
    does nothing to the image, so every place it appears has to say so."""
    page = _mesh_vault(wiz)
    assert "RECORDED, NOT YET CONSUMED" in vault_mod._CA_NOTE
    assert "No builder script parses a CA flag" in vault_mod._CA_NOTE
    assert "no builder" in page.ca_list.toolTip().lower()


# ── the one dialog on the page ───────────────────────────────────────────────────────
def test_the_certificate_dialog_is_a_module_seam_reached_only_from_the_add_click():
    """A modal is legal here ONLY as an explicit click handler behind a seam tests can
    patch. Pin both halves: the seam exists at module level, and the ONE call site is
    inside _add_certificates — nothing validatePage / isComplete / initializePage can
    reach, which is what a headless run would hang on."""
    src = open(vault_mod.__file__, encoding="utf-8").read()
    assert "QMessageBox" not in src and ".exec(" not in src
    assert callable(vault_mod.pick_ca_certificates)
    calls = [i for i, ln in enumerate(src.splitlines())
             if "pick_ca_certificates(" in ln]
    assert len(calls) == 1, "the dialog seam must have exactly one call site"
    body = src.split("def _add_certificates")[1]
    assert "pick_ca_certificates(" in body.split("\n    def ")[0]
    for hook in ("def validatePage", "def isComplete", "def initializePage",
                 "def _sync"):
        after = src.split(hook)[1].split("\n    def ")[0]
        assert "pick_ca_certificates" not in after, hook


def test_the_ca_group_is_never_greyed_by_the_platform_gate(wiz):
    """scope_allows_flow answers "does a builder in this flow parse the flag". There
    IS no CA flag on any platform, so greying the section would imply one platform
    could consume it and another could not. A jetson-only worklist greys the Vault
    group and leaves the certificate section live."""
    page = _mesh_vault(wiz, "edge-ai.jetson")
    assert not page.box.isEnabled()
    assert page.ca_box.isEnabled()
