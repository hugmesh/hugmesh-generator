"""#588 — where a Mesh desktop client (cloud mode) gets its certificate authorities.

The issue offered two fixes: stop skipping the Secrets store (VaultPage) in cloud mode,
or keep skipping it and say on the Domains step where a client inherits its CA. This
round picked the second, and the reason is two facts in the builders, not a preference:

* ``bake_vault_conf`` (build-x86-host-stage4.sh) warns and RETURNS on a client role, so
  a Vault address offered to a client build is discarded;
* the per-domain Base CA is recorded-only (no builder parses a CA flag), while the
  thing that really decides a client's trust is keys-provision's bulk import of the
  KEYS stick's ``certs/`` folder into the system trust store — mesh-wide, not per domain.

So this file pins, in order:

1. those three facts against the SCRIPTS (so ``CLIENT_CA_INHERITANCE_NOTE`` goes red the
   day one of them stops being true, instead of quietly becoming a lie);
2. that cloud mode keeps skipping the step and keeps the column hidden, and the Domains
   step SAYS where the trust comes from — on both faces, the same string;
3. that the hidden column no longer erases a loaded config's ``domain_ca`` record (a
   cloud walk used to rebuild it from pickers the skipped step never filled), pruned to
   the domains still in the table so the stranded-entry rule holds.
"""
import os
import re

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core.config import (                               # noqa: E402
    CLIENT_CA_INHERITANCE_NOTE, MODE_SKIPPED_PAGES, Domain, ImageConfig)
from hugmesh_studio.tui import journey                                  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
BUILDER_X86 = os.path.join(GENERATOR_DIR, "build-x86-host-stage4.sh")
PROVISION = os.path.join(GENERATOR_DIR, "specs", "etc", "keys-provision", "provision.sh")


def _read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def _function_body(src, name):
    m = re.search(r"^%s\(\) \{\n(.*?)^\}\n" % re.escape(name), src, re.S | re.M)
    assert m, f"{name}() not found — the builder moved it; re-derive this pin"
    return m.group(1)


# ── 1. the facts the note rests on, measured against the scripts ─────────────────────
def test_the_builder_discards_a_vault_address_on_a_client_role():
    """Un-skipping VaultPage for cloud would offer this knob; the builder throws it
    away. Pinned by ORDER inside bake_vault_conf: the client arm returns before the
    vault.conf write."""
    body = _function_body(_read(BUILDER_X86), "bake_vault_conf")
    client = body.find("if ${ROLE_CLIENT}; then")
    ret = body.find("return 0", client)
    write = body.find('> "${SYSROOT}/etc/hugmesh/vault.conf"')
    assert -1 < client < ret < write, (
        "bake_vault_conf no longer returns on a client role before writing vault.conf "
        "— a client build may now honour --vault-addr, so #588's decision to keep the "
        "Secrets store skipped in cloud (config.CLIENT_CA_INHERITANCE_NOTE) must be "
        "re-made")
    assert "ignoring" in body[client:ret]


def test_keys_provision_imports_every_stick_certificate_into_the_trust_store():
    src = _read(PROVISION)
    for needle in ('cp -f "${BASE}/certs/"*.crt /usr/local/share/ca-certificates/',
                   'cp -f "${BASE}/certs/"*.pem /usr/local/share/ca-certificates/',
                   "update-ca-certificates"):
        assert needle in src, (
            f"keys-provision no longer does {needle!r} — the client trust path the "
            "cloud Domains step describes (CLIENT_CA_INHERITANCE_NOTE) has changed")


def test_no_builder_parses_a_ca_flag():
    """The per-domain Base CA stays recorded-only: nothing a builder reads carries it,
    so a client-facing picker would be a dead knob."""
    args = ImageConfig(mode="cloud", role="laptop", cluster_domain="mesh.example",
                       domains=[Domain(name="mesh.example")],
                       base_ca_certs=["/ca/root.pem"],
                       domain_ca={"mesh.example": "/ca/root.pem"}).to_cli_args()
    ca_flags = [a for a in args if a.startswith("--")
                and re.search(r"(^|-)(ca|cert|certs)(-|$)", a[2:].lower())]
    assert not ca_flags, args
    assert "/ca/root.pem" not in args


def test_the_note_names_the_mechanism_it_describes():
    for needle in ("KEYS", "certs/", "*.crt", "*.pem", "trust store",
                   "--vault-addr", "Secrets store step is skipped"):
        assert needle in CLIENT_CA_INHERITANCE_NOTE, needle


# ── 2. the decision, on both faces ───────────────────────────────────────────────────
def test_cloud_mode_keeps_skipping_the_secrets_store_step():
    assert "vault" in MODE_SKIPPED_PAGES["cloud"]
    assert "vault" not in MODE_SKIPPED_PAGES["mesh"]


def _tui_domains(mode):
    j = journey.Journey(".")
    j.cfg.mode = mode
    j.cfg.domains = [Domain(name="chat.example.org")]
    j.goto("domains")
    return j


def test_the_tui_domains_step_says_where_a_client_inherits_its_ca():
    cloud = _tui_domains("cloud").lines()
    mesh = _tui_domains("mesh").lines()
    assert CLIENT_CA_INHERITANCE_NOTE in cloud
    assert CLIENT_CA_INHERITANCE_NOTE not in mesh


# ── the GUI face ─────────────────────────────────────────────────────────────────────
gui = pytest.importorskip("hugmesh_studio.gui.qt",
                          reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.pages.domains import _COL_CA                   # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                            # noqa: E402

from _helpers import advance_to, check_worklist_rows, enable_additional_domains, pick_mode  # noqa: E402

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch, tmp_path):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-client-ca-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def test_the_cloud_domains_step_shows_the_note_and_keeps_the_column_hidden(wiz):
    pick_mode(wiz, "cloud")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    assert dom.table.isColumnHidden(_COL_CA)
    assert not dom.client_ca_note.isHidden()
    assert dom.client_ca_note.text() == CLIENT_CA_INHERITANCE_NOTE
    walked = _walk_to_build(wiz)
    assert isinstance(walked[-1], wizard_mod.BuildPage), (
        f"the walk stalled at {type(walked[-1]).__name__} — the skip below is vacuous")
    assert not any(isinstance(p, wizard_mod.VaultPage) for p in walked)


def test_the_mesh_domains_step_does_not(wiz):
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86")
    enable_additional_domains(wiz)
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    assert dom.client_ca_note.isHidden()
    assert not dom.table.isColumnHidden(_COL_CA)


def _walk_to_build(wiz):
    seen = []
    for _ in range(40):
        page = wiz.currentPage()
        seen.append(page)
        if isinstance(page, wizard_mod.BuildPage):
            break
        wiz.next()
    return seen


def test_a_cloud_walk_keeps_a_loaded_domain_ca_record_pruned_to_live_domains(wiz):
    """The hidden column used to be rebuilt from pickers that only offer
    cfg.base_ca_certs — which the skipped Secrets store never fills in cloud — so a
    loaded config's record was erased on the first Next. Now it is kept for the
    domains still in the table and dropped for the ones that are not; and the
    config a build records (to_dict -> from_dict) still carries it."""
    pick_mode(wiz, "cloud")
    wiz.cfg.domains = [Domain(name="mesh.example")]
    wiz.cfg.domain_ca = {"mesh.example": "/ca/root.pem", "gone.example": "/ca/root.pem"}
    wiz.cfg.base_ca_certs = []
    advance_to(wiz, wizard_mod.DomainsPage)
    advance_to(wiz, wizard_mod.UsersPage)
    assert [d.name for d in wiz.cfg.domains] == ["mesh.example"]
    assert wiz.cfg.domain_ca == {"mesh.example": "/ca/root.pem"}
    assert ImageConfig.from_dict(wiz.cfg.to_dict()).domain_ca == {
        "mesh.example": "/ca/root.pem"}
