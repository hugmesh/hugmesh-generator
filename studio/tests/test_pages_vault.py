"""VaultPage (issue #224) — the GUI face of the mesh secrets store.

Runs the REAL wizard on Qt's offscreen platform (the test_pages_domains_idp harness
style). Pins: the page is mesh-only; the empty address is the byte-identical
default; a set address reaches cfg AND the emitted argv; the fail-closed rule is
the ONE shared predicate rendered inline (never a modal — a QMessageBox in
validatePage hangs headless tests); residue is cleared with the address; a loaded
config seeds the widgets back.
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

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

ADDR = "https://vault.acme.example:8200"
_NEXT = QtWidgets.QWizard.WizardButton.NextButton


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
    page.kv_mount.setText("kv")
    page.base_path.setText("acme/prod")
    assert page.isComplete()
    assert ADDR in page.note.text() and "vault.conf" in page.note.text()
    wiz.next()
    c = wiz.cfg
    assert (c.vault_addr, c.vault_kv_mount, c.vault_base_path) == (ADDR, "kv", "acme/prod")
    args = c.to_cli_args()
    assert ("--vault-addr", ADDR) in list(zip(args, args[1:]))
    assert ("--vault-kv-mount", "kv") in list(zip(args, args[1:]))
    assert ("--vault-base-path", "acme/prod") in list(zip(args, args[1:]))


def test_address_only_leaves_the_builder_defaults_unemitted(wiz):
    page = _mesh_vault(wiz)
    page.addr.setText(ADDR)
    wiz.next()
    args = wiz.cfg.to_cli_args()
    assert "--vault-addr" in args
    assert "--vault-kv-mount" not in args and "--vault-base-path" not in args


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


def test_a_mount_without_an_address_is_refused_until_one_is_entered(wiz):
    page = _mesh_vault(wiz)
    page.kv_mount.setText("kv")
    assert not page.isComplete()
    assert "no Vault address" in page.note.text()
    page.addr.setText(ADDR)
    assert page.isComplete()


def test_a_shell_shaped_path_is_refused(wiz):
    page = _mesh_vault(wiz)
    page.addr.setText(ADDR)
    page.base_path.setText("$(rm -rf /)")
    assert not page.isComplete()
    assert "base path" in page.note.text()


def test_clearing_the_address_clears_the_residue_on_commit(wiz):
    page = _mesh_vault(wiz)
    page.addr.setText(ADDR)
    page.kv_mount.setText("kv")
    page.base_path.setText("acme")
    page.addr.setText("")                         # typed, then thought better of it
    assert not page.isComplete()                  # a stray mount is refused...
    page.kv_mount.setText("")
    page.base_path.setText("")
    assert page.isComplete()
    wiz.next()
    assert all(getattr(wiz.cfg, f) == "" for f in VAULT_FIELDS)


def test_the_page_never_opens_a_modal():
    """The repo rule: no QMessageBox / exec() in a validatePage or change path."""
    src = open(vault_mod.__file__, encoding="utf-8").read()
    assert "QMessageBox" not in src and ".exec(" not in src


# ── reload + the no-consumer flow ────────────────────────────────────────────────────
def test_a_loaded_config_seeds_the_widgets_back(wiz):
    wiz.cfg.vault_addr = ADDR
    wiz.cfg.vault_kv_mount = "kv"
    wiz.cfg.vault_base_path = "acme"
    page = _mesh_vault(wiz)
    assert page.addr.text() == ADDR
    assert page.kv_mount.text() == "kv" and page.base_path.text() == "acme"
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
