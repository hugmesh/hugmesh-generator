"""VaultPage — the mesh SECRETS STORE (issue #224): where a cluster node fetches its
cluster secrets from.

Operator ask (Image Studio builder notes, 2026-08-31/09-01): "provide the ability to
configure Vault in the mesh image build (Studio wizard currently exposes no Vault
settings)". Before this page the only Vault knob anywhere in the pipeline was a
hand-edited ``.vault`` block in the KEYS stick's provision.json — nothing in the
Studio, the CLI or any builder script ever wrote it, and the three shipped per-role
example manifests omit it, so first-boot Vault/ESO seeding silently skipped.

What this page does: collects a HashiCorp Vault ADDRESS (plus the KV mount and base
path, both optional overrides of the builders' defaults) into ``cfg.vault_*``. The
x86 and rpi5 node builders take them as ``--vault-addr [--vault-kv-mount]
[--vault-base-path]`` and bake CONNECTION FACTS ONLY into ``/etc/hugmesh/vault.conf``;
keys-provision's ``provision_vault()`` then seeds the External Secrets Operator from
that file at first boot whenever the KEYS manifest carries no ``.vault`` block (a
manifest block still wins — it is the per-stick override).

What it does NOT do, on purpose: the Vault TOKEN and unseal key are custody material.
They ride the KEYS stick (``vault/token``, ``vault/unseal-key``) and are never a
wizard field, never a flag and never a byte of any image.

The empty address is the NATIVE DEFAULT: it commits nothing and emits nothing, so
cfg and the argv stay byte-identical to a config that never saw this page (the #1
invariant). What an absent flag then means is the BUILDER's business, and it is the
same rule as every other knob there (built-in < env < brand.conf < CLI): a brand
profile's VAULT_ADDR still applies, and with none set nothing is baked
(offline/USB-only delivery). The copy on this page says so rather than promising
"nothing is baked" unconditionally. Validation is the ONE shared predicate
``config.vault_field_error`` — the same rule ``validate_identity`` enforces on the
argv — rendered as an inline note (never a modal: a message box in validatePage
hangs headless tests, and the repo forbids it).

MESH ONLY (MODE_SKIPPED_PAGES): a standalone desktop has no cluster and a cloud
desktop client seeds no ESO, so neither mode ever visits this page.
"""
from __future__ import annotations

from ..qt import QtWidgets
from ..styles import muted
from ...core.config import (
    VAULT_FIELDS, VAULT_KV_MOUNT_DEFAULT, ImageConfig, vault_field_error)
from ._gating import gate_widgets_role_class, out_of_scope_note_flow, scope_allows_flow
from ._scroll import scrollable
from ._widgets import _row

_LIMITS_NOTE = (
    "What a set address DOES: bakes /etc/hugmesh/vault.conf (address, KV mount, base "
    "path — public connection facts, 0644) into every cluster-node image in this "
    "flow. At first boot keys-provision reads it when the KEYS stick's provision.json "
    "has no .vault block, and seeds the External Secrets Operator's vault-token / "
    "vault-ca Secrets from the token on the stick.\n"
    "What it does NOT do: the Vault token and unseal key are never entered here, "
    "never a build flag and never in an image — put them on the KEYS stick "
    "(vault/token, vault/unseal-key; see keys-template/vault/README.md). A .vault "
    "block in provision.json overrides everything on this page. Desktop rows in the "
    "worklist ignore it (the builder says so in the log).\n"
    "An empty address emits no flag. The builders then fall back to a brand profile's "
    "VAULT_ADDR (brand.conf, or the build environment) exactly as they do for every "
    "other knob; with neither set, nothing is baked and secrets come off the KEYS "
    "stick's vault/secrets.json bundle.")


class VaultPage(QtWidgets.QWizardPage):
    """Mesh secrets-store page. Only the mesh (node) flow visits it; the empty
    address keeps cfg + argv byte-identical (validatePage clears the residue)."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Secrets store")
        self.setSubTitle(
            "Where this mesh's nodes fetch cluster secrets from. Leave the address "
            "empty and no flag is emitted: the builders bake nothing unless the brand "
            "profile (brand.conf VAULT_ADDR) names a Vault. Enter a HashiCorp Vault "
            "address to bake it into every node so first-boot provisioning can seed "
            "External Secrets from it.")
        lay = scrollable(self)

        self.box = QtWidgets.QGroupBox("HashiCorp Vault")
        vb = QtWidgets.QVBoxLayout(self.box)
        self.addr = QtWidgets.QLineEdit()
        self.addr.setPlaceholderText(
            "https://vault.example.net:8200  (empty = offline / KEYS-stick only)")
        self.addr.setToolTip(
            "The Vault this mesh's nodes seed their External Secrets Operator from "
            "(--vault-addr). Must be https:// — it is the secrets channel's trust "
            "anchor. Empty = offline/USB-only delivery: nothing is baked.")
        vb.addWidget(_row("Vault address", self.addr))
        self.kv_mount = QtWidgets.QLineEdit()
        self.kv_mount.setPlaceholderText(
            f"{VAULT_KV_MOUNT_DEFAULT}  (the builder default; leave empty to keep it)")
        self.kv_mount.setToolTip(
            "The KV v2 mount the ClusterSecretStore reads (--vault-kv-mount). Empty "
            f"keeps the builder default '{VAULT_KV_MOUNT_DEFAULT}' — the same knob "
            "brand.conf calls VAULT_KV_MOUNT.")
        vb.addWidget(_row("KV mount", self.kv_mount))
        self.base_path = QtWidgets.QLineEdit()
        self.base_path.setPlaceholderText(
            "the brand slug  (the builder default; leave empty to keep it)")
        self.base_path.setToolTip(
            "The path prefix under the mount where this mesh's secrets live "
            "(--vault-base-path). Empty keeps the builder default — the brand slug, "
            "which is where scripts/gen-cluster-secrets.sh writes them.")
        vb.addWidget(_row("Base path", self.base_path))
        # the inline verdict — the ONE predicate validate_identity enforces on argv,
        # shown here as text so an operator is told WHY Next is greyed (never a modal)
        self.note = QtWidgets.QLabel("")
        self.note.setWordWrap(True)
        self.note.setStyleSheet(muted())
        vb.addWidget(self.note)
        lay.addWidget(self.box)

        limits = QtWidgets.QLabel(_LIMITS_NOTE)
        limits.setWordWrap(True)
        limits.setStyleSheet(muted())
        lay.addWidget(limits)
        lay.addStretch(1)

        #: field name -> widget, in VAULT_FIELDS order — the TUI parity pin reads it.
        self.field_widgets = {"vault_addr": self.addr, "vault_kv_mount": self.kv_mount,
                              "vault_base_path": self.base_path}
        assert tuple(self.field_widgets) == VAULT_FIELDS
        self.addr.textChanged.connect(self._sync)
        self.kv_mount.textChanged.connect(self._sync)
        self.base_path.textChanged.connect(self._sync)
        self._sync()

    # ── helpers ─────────────────────────────────────────────────────────────────
    def values(self) -> tuple[str, str, str]:
        return (self.addr.text().strip(), self.kv_mount.text().strip(),
                self.base_path.text().strip())

    def error(self) -> str:
        """The inline verdict for the widgets' CURRENT text ("" = valid)."""
        return vault_field_error(*self.values())

    def _sync(self, *_):
        addr, kv_mount, base_path = self.values()
        err = self.error()
        if err:
            self.note.setText(f"Cannot continue: {err}.")
        elif addr:
            self.note.setText(
                f"Every node in this flow will bake {addr} · mount "
                f"{kv_mount or VAULT_KV_MOUNT_DEFAULT} · base path "
                f"{base_path or '<brand>'} into /etc/hugmesh/vault.conf.")
        else:
            self.note.setText(
                "No address from this page: no --vault-addr is emitted. The builder "
                "bakes nothing unless brand.conf sets VAULT_ADDR; secrets then come "
                "off the KEYS stick's vault/secrets.json bundle.")
        self.completeChanged.emit()

    def isComplete(self) -> bool:
        # the SAME fail-closed rule to_cli_args enforces — never a second predicate
        return self.error() == ""

    # ── wizard contract ──────────────────────────────────────────────────────────
    def initializePage(self):
        c = self.wiz.cfg
        self.addr.setText(c.vault_addr)
        self.kv_mount.setText(c.vault_kv_mount)
        self.base_path.setText(c.vault_base_path)
        # Grey the surface when NO image in this flow can take the flag (a worklist of
        # jetson/orangepi rows: their builders parse no --vault-*), naming the row
        # that rejected — the flag would otherwise be silently stripped per entry.
        allowed = scope_allows_flow("vault_addr", c, self.wiz)
        gate_widgets_role_class(
            self.box, allowed,
            "" if allowed else out_of_scope_note_flow("vault_addr", c, self.wiz))
        self._sync()

    def validatePage(self):
        c = self.wiz.cfg
        addr, kv_mount, base_path = self.values()
        c.vault_addr = addr
        if addr:
            c.vault_kv_mount = kv_mount
            c.vault_base_path = base_path
        else:
            # the byte-identity invariant: the offline default carries ZERO residue,
            # even if a mount/path was typed and the address then cleared
            c.vault_kv_mount = ""
            c.vault_base_path = ""
        if not self.box.isEnabled():
            # greyed = no consumer in this flow: clear rather than strand a value
            # the per-entry strip would drop anyway (emission-neutral)
            c.vault_addr = c.vault_kv_mount = c.vault_base_path = ""
        return True
