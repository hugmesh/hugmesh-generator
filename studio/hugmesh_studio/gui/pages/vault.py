"""VaultPage — the mesh SECRETS STORE (issue #224), split INTERNAL/EXTERNAL and given
a BASE CA CERTIFICATES surface by issue #335.

Operator ask (Image Studio builder notes, 2026-08-31/09-01): "provide the ability to
configure Vault in the mesh image build (Studio wizard currently exposes no Vault
settings)". Before this page the only Vault knob anywhere in the pipeline was a
hand-edited ``.vault`` block in the KEYS stick's provision.json — nothing in the
Studio, the CLI or any builder script ever wrote it, and the three shipped per-role
example manifests omit it, so first-boot Vault/ESO seeding silently skipped.

What this page does: collects the HashiCorp Vault addresses (an INTERNAL one — the
address a node reaches Vault at from inside the mesh, which is the field that was
always here — plus an optional EXTERNAL one) into ``cfg.vault_*``, and a list of
base CA certificate PEMs into ``cfg.base_ca_certs``. The x86 and rpi5 node builders
take the two as ``--vault-addr [--vault-external-addr]`` and bake CONNECTION FACTS
ONLY into ``/etc/hugmesh/vault.conf``; keys-provision's ``provision_vault()`` then
seeds the External Secrets Operator from that file at first boot whenever the KEYS
manifest carries no ``.vault`` block (a manifest block still wins — it is the
per-stick override).

WHAT THIS PAGE DELIBERATELY DOES NOT ASK (#285; decision 22 on #347, operator
2026-09-16 "A: drop both controls"). It used to carry a KV MOUNT and a BASE PATH
field, threaded as ``--vault-kv-mount`` / ``--vault-base-path``. Both are GONE, with
the flags. The cluster reads ``secret/<brand>/…`` BY DESIGN: the mount is pinned in
the shipped ``manifests/external-secrets/secretstore.yaml`` (``path: "secret"`` at
the in-cluster ``vault.vault.svc`` server), which ``apps/04-external-secrets-config``
serves with ``automated {prune, selfHeal}`` — so ArgoCD re-applies it from git on
every reconcile and no image-side value could ever re-point it — and the base path
IS the brand slug, which is where ``scripts/gen-cluster-secrets.sh`` writes. The two
fields were validated, baked and logged and read by nothing; asking for them was the
dead-knob failure this repo is named for. The builders still write both values into
``vault.conf``, derived, so the first-boot log names the real paths.

HOW FAR EACH FIELD REACHES, stated because the copy used to overstate them.

* INTERNAL ADDRESS — live. A set address is what makes ``provision_vault()`` create
  the ``vault-token`` / ``vault-ca`` Secrets from the KEYS stick at all.
* EXTERNAL ADDRESS (#335) — reaches the ARTEFACT and no reader. It is a real flag
  parsed by both node builders and appended to ``vault.conf`` as
  ``VAULT_EXTERNAL_ADDR``, so the value genuinely lands in the image; keys-provision
  seeds from the INTERNAL address and has no lookup for this key, so what it changes
  at boot today is nothing. ``test_vault_config.py`` proves both halves — that the
  key comes back out of the baked file, and that first-boot resolution is identical
  with and without it — rather than leaving the claim to a tooltip.
* BASE CA CERTIFICATES (#335) — RECORDED ONLY, the weakest of the four and labelled
  as such everywhere it appears. The operator adds PEM files; each is parsed here and
  its subject and expiry shown. Because the value reaches no argv and no image, an
  unreadable path is never allowed to BLOCK anything: ``validate_identity`` checks
  only the structural rules (duplicates, a domain naming a certificate the config
  does not carry), and this page keeps and marks a row it cannot read rather than
  deleting it out from under the domains that point at it. NO builder script parses a CA flag, so nothing copies
  a PEM into an image, into a trust store or onto a KEYS stick, and no manifest
  emitter carries the per-domain choice yet. The list is saved with the config and
  offered as the per-domain "Base CA" column on the Domains step, and that is the
  whole of it. Emitting a flag no builder parses is the failure this repo is named
  for; saying so plainly is the alternative it chose.

What it does NOT do, on purpose: the Vault TOKEN and unseal key are custody material.
They ride the KEYS stick (``vault/token``, ``vault/unseal-key``) and are never a
wizard field, never a flag and never a byte of any image.

The empty INTERNAL address is the NATIVE DEFAULT: it commits nothing and emits
nothing, so cfg and the argv stay byte-identical to a config that never saw this page
(the #1 invariant), and #335 keeps it — an untouched external field, an empty
certificate list and an empty per-domain table all commit and emit nothing too. What
an absent flag then means is the BUILDER's business, and it is the same rule as every
other knob there (built-in < env < brand.conf < CLI): a brand profile's VAULT_ADDR
still applies, and with none set nothing is baked (offline/USB-only delivery). The
copy on this page says so rather than promising "nothing is baked" unconditionally.
Validation is the ONE shared predicate ``config.vault_field_error`` — the same rule
``validate_identity`` enforces on the argv — rendered as an inline note (never a
modal: a message box in validatePage hangs headless tests, and the repo forbids it).

THE ONE DIALOG on this page is the certificate file picker. It sits behind the
module-level ``pick_ca_certificates`` seam so tests drive the add path without a real
dialog, and it is reachable ONLY from the explicit "Add certificate…" click — never
from validatePage, isComplete, initializePage or any signal those fire. A refused PEM
is an inline sentence under the list, for exactly the same reason.

MESH ONLY (MODE_SKIPPED_PAGES): a standalone desktop has no cluster and a cloud
desktop client seeds no ESO, so neither mode ever visits this page.
"""
from __future__ import annotations

import os

from ..qt import Qt, QtWidgets
from ..styles import muted
from ...core.config import (
    VAULT_FIELDS, ImageConfig, ca_cert_error, describe_ca_cert,
    vault_field_error)
from ._gating import gate_widgets_role_class, out_of_scope_note_flow, scope_allows_flow
from ._scroll import scrollable
from ._widgets import _row

#: The certificate file picker, as a MODULE-LEVEL SEAM. Tests monkeypatch it to drive
#: the add-a-certificate path with no real dialog; production keeps Qt's own. It is
#: called from ONE place — the "Add certificate…" click handler — and from nowhere
#: that page validation can reach.
pick_ca_certificates = QtWidgets.QFileDialog.getOpenFileNames

_CERT_FILTER = "Certificates (*.pem *.crt *.cer *.ca-bundle);;All files (*)"

_LIMITS_NOTE = (
    "What a set internal address DOES: bakes /etc/hugmesh/vault.conf (the address, "
    "plus the KV mount and base path the cluster reads — public connection facts, "
    "0644) into every cluster-node image in this flow. At first boot keys-provision "
    "reads it when the KEYS stick's provision.json has no .vault block, and seeds "
    "the External Secrets Operator's vault-token / vault-ca Secrets from the token "
    "on the stick.\n"
    "What it does NOT do: the Vault token and unseal key are never entered here, "
    "never a build flag and never in an image — put them on the KEYS stick "
    "(vault/token, vault/unseal-key; see keys-template/vault/README.md). A .vault "
    "block in provision.json overrides everything on this page. Desktop rows in the "
    "worklist ignore it (the builder says so in the log).\n"
    "WHERE the cluster reads is not asked here, because it is not a choice. The "
    "mount is pinned in the shipped ClusterSecretStore and ArgoCD re-applies that "
    "from git on every reconcile, so nothing on a node can re-point it; and the key "
    "prefix the ExternalSecrets read is the literal 'hugmesh/<service>' — all 143 "
    "remoteRef keys under specs/cluster spell it out and none templates the brand. "
    "vault.conf still carries both values as derived facts so the first-boot log "
    "names the paths the image was built for, with the base path set to the brand "
    "slug because that is the WRITER side (the secret generator writes "
    "secret/<brand>/…). For a brand other than 'hugmesh' writer and reader therefore "
    "disagree — a pre-existing gap, not something this change made. The KV-mount and "
    "base-path fields this page used to show were removed because they were "
    "recorded, logged, and read by nothing.\n"
    "What the external address does NOT do: it is baked into the same file and has "
    "no reader at all — it is there for operators and out-of-cluster tooling, and a "
    "node boots identically with and without it. The internal address itself is "
    "live: it is what enables the vault-token / vault-ca seeding at all.\n"
    "An empty internal address emits no flag. The builders then fall back to a brand "
    "profile's VAULT_ADDR (brand.conf, or the build environment) exactly as they do "
    "for every other knob; with neither set, nothing is baked and secrets come off "
    "the KEYS stick's vault/secrets.json bundle.")

_CA_NOTE = (
    "Add the PEM certificates of the certificate authorities this mesh's domains "
    "chain to. Each file is checked as you add it: -----BEGIN CERTIFICATE----- "
    "framing and a decodable body always, plus a real X.509 parse where the optional "
    "python-cryptography package is installed on this machine — that same package is "
    "what reads the subject and expiry shown beside the file name, and without it "
    "the row says so rather than guessing.\n"
    "A path that is no longer readable when you come back (the file moved, or its "
    "volume is not mounted) is KEPT and marked, never dropped — opening this page "
    "must not be able to destroy your list, and nothing here blocks a build either "
    "way. Remove the row yourself if you mean to.\n"
    "RECORDED, NOT YET CONSUMED — the honest limit of this section. The list is "
    "saved with your config and offered as the per-domain ‘Base CA’ choice on the "
    "Domains step. No builder script parses a CA flag, so nothing here copies a PEM "
    "into an image, into a node's trust store or onto a KEYS stick, and no manifest "
    "carries the per-domain choice yet. It records which CA each domain is meant to "
    "chain to; installing it is still a step you do on the cluster.")


class VaultPage(QtWidgets.QWizardPage):
    """Mesh secrets-store page. Only the mesh (node) flow visits it; the empty
    address keeps cfg + argv byte-identical (validatePage clears the residue)."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Secrets store")
        self.setSubTitle(
            "Where this mesh's nodes fetch cluster secrets from, and the base CA "
            "certificates its domains chain to. Leave the internal address empty and "
            "no flag is emitted: the builders bake nothing unless the brand profile "
            "(brand.conf VAULT_ADDR) names a Vault. Enter a HashiCorp Vault address "
            "to bake it into every node so first-boot provisioning can seed External "
            "Secrets from it.")
        lay = scrollable(self)

        self.box = QtWidgets.QGroupBox("HashiCorp Vault")
        vb = QtWidgets.QVBoxLayout(self.box)
        self.addr = QtWidgets.QLineEdit()
        self.addr.setPlaceholderText(
            "https://vault.example.net:8200  (empty = offline / KEYS-stick only)")
        self.addr.setToolTip(
            "The Vault address baked into every node in this flow (--vault-addr), as "
            "reached from INSIDE the mesh. Must be https:// — it is the secrets "
            "channel's trust anchor. Setting it is what turns first-boot ESO seeding "
            "ON: keys-provision creates the vault-token / vault-ca Secrets from the "
            "KEYS stick. The shipped ClusterSecretStore keeps its own in-cluster "
            "server URL; this value is not substituted into it. Empty = "
            "offline/USB-only: nothing is baked.")
        vb.addWidget(_row("Internal address", self.addr))
        self.external_addr = QtWidgets.QLineEdit()
        self.external_addr.setPlaceholderText(
            "https://vault.example.com:8200  (optional; empty = no such line)")
        self.external_addr.setToolTip(
            "The SAME Vault reached from OUTSIDE the mesh — an operator laptop, a CI "
            "runner, a second site (--vault-external-addr). Both node builders parse "
            "it and append VAULT_EXTERNAL_ADDR to /etc/hugmesh/vault.conf beside the "
            "internal address, so the value really does land in the image. It has NO "
            "reader: keys-provision seeds from the internal address, and a node boots "
            "identically with and without this — it is recorded for operators and "
            "out-of-cluster tooling. Needs the internal address, must differ from it, "
            "and empty writes no line at all.")
        vb.addWidget(_row("External address", self.external_addr))
        # NO KV-mount / base-path fields (#285, decision 22). The cluster reads
        # secret/<brand>/… by design; _LIMITS_NOTE says so on screen and the two
        # builders bake the derived values themselves.
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

        # ── base CA certificates (#335) ──────────────────────────────────────────
        # DELIBERATELY NOT gated by scope_allows_flow: that gate answers "does any
        # builder in this flow parse the flag", and there IS no flag — greying the
        # section would imply one platform could consume it and another could not.
        self.ca_box = QtWidgets.QGroupBox("Base CA certificates")
        cb = QtWidgets.QVBoxLayout(self.ca_box)
        self.ca_list = QtWidgets.QListWidget()
        self.ca_list.setSelectionMode(
            QtWidgets.QAbstractItemView.SelectionMode.ExtendedSelection)
        self.ca_list.setToolTip(
            "The certificate authorities offered as the per-domain ‘Base CA’ on the "
            "Domains step. Each row shows the file name, then the subject and expiry "
            "read out of the certificate. Saved with your config; no builder copies "
            "these into an image.")
        cb.addWidget(self.ca_list)
        ca_btns = QtWidgets.QHBoxLayout()
        self.ca_add = QtWidgets.QPushButton("Add certificate…")
        self.ca_add.setToolTip(
            "Pick one or more PEM files (.pem/.crt/.cer). Each is checked before it "
            "is added — BEGIN/END CERTIFICATE framing, a decodable body, and (when "
            "python-cryptography is installed on this machine) a real X.509 parse. "
            "Anything that fails is refused with the reason shown below, never added "
            "silently. Nothing is copied anywhere: the path is recorded with the "
            "config, and no builder reads it yet.")
        self.ca_remove = QtWidgets.QPushButton("Remove selected")
        self.ca_remove.setToolTip(
            "Drop the selected certificates from the list. Any domain that had "
            "picked one is set back to ‘None’ when you leave this step, so no domain "
            "can name a CA the config no longer carries.")
        self.ca_add.clicked.connect(self._add_certificates)
        self.ca_remove.clicked.connect(self._remove_certificates)
        ca_btns.addWidget(self.ca_add)
        ca_btns.addWidget(self.ca_remove)
        ca_btns.addStretch(1)
        cb.addLayout(ca_btns)
        # the certificate surface's own inline verdict: a refused PEM says why HERE
        self.ca_note = QtWidgets.QLabel("")
        self.ca_note.setWordWrap(True)
        self.ca_note.setStyleSheet(muted())
        cb.addWidget(self.ca_note)
        lay.addWidget(self.ca_box)

        ca_help = QtWidgets.QLabel(_CA_NOTE)
        ca_help.setWordWrap(True)
        ca_help.setStyleSheet(muted())
        lay.addWidget(ca_help)
        lay.addStretch(1)

        #: field name -> widget, in VAULT_FIELDS order — the TUI parity pin reads it.
        self.field_widgets = {"vault_addr": self.addr,
                              "vault_external_addr": self.external_addr}
        assert tuple(self.field_widgets) == VAULT_FIELDS
        for w in self.field_widgets.values():
            w.textChanged.connect(self._sync)
        self._sync()

    # ── helpers ─────────────────────────────────────────────────────────────────
    def values(self) -> tuple[str, str]:
        """The widgets' current text, stripped, in VAULT_FIELDS order."""
        return tuple(w.text().strip() for w in self.field_widgets.values())

    def error(self) -> str:
        """The inline verdict for the widgets' CURRENT text ("" = valid)."""
        addr, external = self.values()
        return vault_field_error(addr, external)

    def certificates(self) -> list[str]:
        """The certificate paths currently listed, in row order. The PATH is the
        item's data role — the visible text carries the subject and expiry too, and
        must stay free to change without moving what the config stores."""
        return [self.ca_list.item(i).data(Qt.ItemDataRole.UserRole)
                for i in range(self.ca_list.count())]

    def _sync(self, *_):
        addr, external = self.values()
        err = self.error()
        if err:
            self.note.setText(f"Cannot continue: {err}.")
        elif addr:
            self.note.setText(
                f"Every node in this flow will bake {addr}"
                + (f" · external {external}" if external else "")
                + " into /etc/hugmesh/vault.conf, and read its secrets from "
                  "the mount and key prefix the shipped ClusterSecretStore pins "
                  "(fixed by design — not a setting here).")
        else:
            self.note.setText(
                "No address from this page: no --vault-addr is emitted. The builder "
                "bakes nothing unless brand.conf sets VAULT_ADDR; secrets then come "
                "off the KEYS stick's vault/secrets.json bundle.")
        self.completeChanged.emit()

    def isComplete(self) -> bool:
        # the SAME fail-closed rule to_cli_args enforces — never a second predicate.
        # The certificate list is deliberately NOT part of this: a bad PEM is refused
        # at the moment it is added, so the list can never hold one, and nothing on
        # this page can strand Next behind a file that has since been moved.
        return self.error() == ""

    # ── base CA certificates ────────────────────────────────────────────────────
    def _append_certificate(self, path: str, problem: str = "") -> None:
        """Add ONE path as a row. describe_ca_cert is read-only and dependency-light
        (stdlib PEM framing; python-cryptography only if installed), so it runs inline
        — nothing here touches docker, kubectl or the runner.

        ``problem`` is the ca_cert_error sentence for a path that is NOT readable
        right now (initializePage's case: a moved file, an unmounted volume). Such a
        row is still added, marked, and still committed by validatePage — see the
        comment there for why losing it would be worse than carrying it."""
        if problem:
            item = QtWidgets.QListWidgetItem(
                f"{os.path.basename(path)} — NOT READABLE RIGHT NOW: {problem}")
            item.setToolTip(f"{path}\n\nKept in the list. Re-mount or restore the "
                            "file, or select it and press Remove selected.")
        else:
            item = QtWidgets.QListWidgetItem(
                f"{os.path.basename(path)} — {describe_ca_cert(path)}")
            item.setToolTip(path)
        item.setData(Qt.ItemDataRole.UserRole, path)
        self.ca_list.addItem(item)

    def _add_certificates(self):
        """The explicit click handler — the ONLY caller of the dialog seam. A file
        that is not a PEM certificate is refused with its reason INLINE (never a
        message box: the repo forbids one anywhere page validation can reach), and a
        cancelled dialog changes nothing and says nothing."""
        paths, _filter = pick_ca_certificates(
            self, "Choose base CA certificates", "", _CERT_FILTER)
        if not paths:
            return
        have = set(self.certificates())
        added, refused = [], []
        for raw in paths:
            path = os.path.abspath(raw)
            if path in have:
                refused.append(f"{os.path.basename(path)}: already in the list")
                continue
            err = ca_cert_error(path)
            if err:
                refused.append(err)
                continue
            self._append_certificate(path)
            have.add(path)
            added.append(os.path.basename(path))
        parts = []
        if added:
            parts.append(f"Added {', '.join(added)}.")
        if refused:
            parts.append("Not added — " + "; ".join(refused) + ".")
        self.ca_note.setText(" ".join(parts))

    def _remove_certificates(self):
        """Explicit click handler. No confirmation dialog: dropping a row destroys
        nothing on disk and the operator can re-add the file, so a modal here would
        be ceremony — and the per-domain choices that pointed at it are repaired on
        the way out (validatePage), not silently left dangling."""
        rows = sorted({i.row() for i in self.ca_list.selectedIndexes()}, reverse=True)
        if not rows:
            self.ca_note.setText("Select a certificate in the list first.")
            return
        gone = []
        for r in rows:
            item = self.ca_list.takeItem(r)
            gone.append(os.path.basename(item.data(Qt.ItemDataRole.UserRole)))
        self.ca_note.setText(
            f"Removed {', '.join(reversed(gone))}. Any domain that had picked one is "
            "set back to ‘None’ when you leave this step.")

    # ── wizard contract ──────────────────────────────────────────────────────────
    def initializePage(self):
        c = self.wiz.cfg
        self.addr.setText(c.vault_addr)
        self.external_addr.setText(c.vault_external_addr)
        # Rebuild the certificate list from cfg. A path that is not readable RIGHT NOW
        # (moved, or on a volume that is not mounted this morning) is KEPT as a marked
        # row, not dropped: merely opening this page must never be able to destroy a
        # recorded list — and with it every domain choice pointing into it — over a
        # condition that may be temporary and that blocks no build (validate_identity
        # does not check readability; base_ca_certs reaches no argv and no image).
        self.ca_list.clear()
        missing = []
        for path in c.base_ca_certs:
            problem = ca_cert_error(path)
            if problem:
                missing.append(os.path.basename(path))
            self._append_certificate(path, problem)
        if missing:
            self.ca_note.setText(
                "Not readable right now, kept in the list: " + ", ".join(missing)
                + ". Restore or re-mount the file, or remove the row yourself — "
                "nothing here changes an image either way.")
        else:
            self.ca_note.setText("")
        # Grey the surface when NO image in this flow can take the flag (a worklist of
        # jetson/orangepi rows: their builders parse no --vault-*), naming the row
        # that rejected — the flag would otherwise be silently stripped per entry.
        # The CA section stays live: it emits no flag on ANY platform, so "no builder
        # here parses it" is not a statement about it (see the note at its creation).
        allowed = scope_allows_flow("vault_addr", c, self.wiz)
        gate_widgets_role_class(
            self.box, allowed,
            "" if allowed else out_of_scope_note_flow("vault_addr", c, self.wiz))
        self._sync()

    def validatePage(self):
        c = self.wiz.cfg
        addr, external = self.values()
        c.vault_addr = addr
        if addr:
            c.vault_external_addr = external
        else:
            # the byte-identity invariant: the offline default carries ZERO residue,
            # even if an external address was typed and the address then cleared.
            # (vault_field_error refuses that combination anyway — this is what makes
            # the refusal unreachable rather than merely enforced.)
            c.vault_external_addr = ""
        if not self.box.isEnabled():
            # greyed = no consumer in this flow: clear rather than strand a value
            # the per-entry strip would drop anyway (emission-neutral)
            c.vault_addr = c.vault_external_addr = ""
        # ── the certificate list, and the per-domain choices that point into it.
        # The list is NOT scope-gated (no flag on any platform), so it is committed
        # unconditionally; every per-domain choice naming a certificate that is no
        # longer listed is cleared HERE, which is what keeps domain_ca_error's rule
        # unreachable through the GUI instead of merely enforced at emission.
        c.base_ca_certs = self.certificates()
        listed = set(c.base_ca_certs)
        c.domain_ca = {d: p for d, p in (c.domain_ca or {}).items() if p in listed}
        return True
