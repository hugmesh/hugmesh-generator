"""IdpPage — the mesh-node IDENTITY PROVIDER choice (I6), EARLY in the node flow.

Operator direction: the IdP pick is "one of the first steps, its own screens" — so
this is a REGULAR flow page (slug "idp", immediately BEFORE "role"), not a terminal
side-flow: a mesh (node) run reads welcome -> mode -> idp -> …. The non-node modes
(standalone / cloud client) statically skip it via MODE_SKIPPED_PAGES — their SSO
posture stays the existing with/no-sso axis, byte-identical to before this page.

Casdoor (built-in) is the NATIVE DEFAULT: leaving it selected commits idp="casdoor"
and clears the three external fields, so cfg and the emitted argv are byte-identical
to a config that never saw this page (the #1 invariant). Picking an external
provider (Azure Entra ID / AWS Cognito / Other OIDC) enables the issuer/client-id/
JWKS line-edits (per-provider placeholder hints), gates Next on a valid https
issuer + client id, and emits --idp/--idp-issuer/--idp-client-id [--idp-jwks].

The page carries an HONEST inline note on what external mode does and does not do
(recon-verified): it re-points token VALIDATION (issuer + JWKS pins, idp.conf bake,
Casdoor apps gated out of the baked tree) — it does NOT port the native first-party
/bff/login leg, MFA step-up stamping, the roles/groups token model, or the
signup-gate/role-sync job class, all of which remain Casdoor-only until the service
repos grow provider support. docs/IDENTITY-PROVIDERS.md is the full statement.
"""
from __future__ import annotations

from ..choice_cards import ChoiceCard, ChoiceCardGroup
from ..qt import QtWidgets
from ..styles import muted
from ...core.config import IDP_CHOICES, IDP_LABELS, idp_effective_jwks
from . import idp_provider
from ._scroll import scrollable
from ._widgets import _row

# idp id -> choice_icons registry name (presentation only; ids stay IDP_CHOICES)
_IDP_ICONS = {
    "casdoor": "idp-casdoor",   # shield + keyhole: the built-in IdP
    "entra": "idp-entra",       # our wedge gesture, labelled ENTRA
    "aws": "idp-aws",           # our arc gesture, labelled AWS
    "oidc": "idp-oidc",         # globe, labelled OIDC
}

# Per-provider line-edit hints (the recon's real endpoint shapes).
_ISSUER_HINTS = {
    "entra": "https://login.microsoftonline.com/<tenant-id>/v2.0",
    "aws": "https://cognito-idp.<region>.amazonaws.com/<user-pool-id>",
    "oidc": "https://id.example.org (the token `iss` value, exactly)",
}
_CLIENT_HINTS = {
    "entra": "the app registration's Application (client) ID",
    "aws": "the Cognito app client id",
    "oidc": "the OIDC client id registered for this mesh",
}
_JWKS_HINTS = {
    "entra": "empty = <issuer>/discovery/v2.0/keys",
    "aws": "empty = <issuer>/.well-known/jwks.json",
    "oidc": "empty = <issuer>/.well-known/jwks (override if your provider differs)",
}

_LIMITS_NOTE = (
    "What external mode DOES: bakes /etc/hugmesh/idp.conf, rewrites the baked "
    "cluster tree's issuer + JWKS pins to your provider, and gates the built-in "
    "Casdoor apps out of the image — services then VALIDATE tokens minted by your "
    "IdP.\n"
    "What it does NOT do (yet): the native first-party /bff/login page, MFA step-up "
    "stamping, the roles/permissions/groups token model (headscale/Harbor/desktop-sudo "
    "group gates), signup-gate and the role-sync jobs remain Casdoor-only — they "
    "need service-repo work per provider. Azure Entra additionally mints PAIRWISE "
    "per-app `sub` values and per-resource audiences. See docs/IDENTITY-PROVIDERS.md "
    "for the full per-provider table before shipping an external-IdP mesh.")


class IdpPage(QtWidgets.QWizardPage):
    """Mesh-node IdP picker. Only the mesh (node) flow visits it; casdoor default
    keeps cfg + argv byte-identical (validatePage clears the external fields)."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Identity provider")
        self.setSubTitle(
            "Which identity provider will this mesh's services trust? This is the "
            "DEFAULT every domain inherits; a domain can choose its own on its "
            "Identity tab (Domain services step). Casdoor (built-in) needs nothing "
            "from you — read the limits note below before choosing another.")
        # four cards + the endpoints box + the limits note: scroll, never clip
        lay = scrollable(self)

        self.group = ChoiceCardGroup(self)
        self._buttons: dict[str, ChoiceCard] = {}
        descs = {
            "casdoor": "The built-in, fully-integrated IdP: native login, MFA "
                       "step-up, roles/permissions, signup gate. Zero configuration.",
            "entra": "Validate tokens from a Microsoft Entra ID (Azure AD) tenant. "
                     "Pairwise sub / per-app roles — see the limits note.",
            "aws": "Validate tokens from an AWS Cognito user pool. Groups ride the "
                   "cognito:groups claim, which the platform's role gates don't read.",
            "oidc": "Any other spec-compliant OIDC provider (issuer + JWKS).",
        }
        for i, idp_id in enumerate(IDP_CHOICES):
            card = ChoiceCard(IDP_LABELS[idp_id], descs[idp_id],
                              icon_name=_IDP_ICONS.get(idp_id, ""))
            card.setProperty("idp", idp_id)
            self.group.add_card(card, i)
            self._buttons[idp_id] = card
            lay.addWidget(card)
        self._buttons["casdoor"].setChecked(True)   # the native default, BY ID

        # ASK 17 — the endpoint fields moved OUT of this page and into the per-provider
        # configuration window (pages/idp_provider.py). They live on as hidden line
        # edits so this page keeps one place to hold the values between the window and
        # validatePage — and so cfg round-tripping stays exactly what it was.
        self.ext_box = QtWidgets.QGroupBox("External provider endpoints")
        eb = QtWidgets.QVBoxLayout(self.ext_box)
        self.issuer = QtWidgets.QLineEdit()
        self.issuer.setToolTip(
            "The OIDC issuer URL — must byte-match the `iss` claim in the tokens "
            "your provider mints, and must be https:// (--idp-issuer).")
        eb.addWidget(_row("Issuer URL", self.issuer))
        self.client_id = QtWidgets.QLineEdit()
        self.client_id.setToolTip(
            "The OIDC client id registered at the provider (--idp-client-id). A "
            "PUBLIC identifier — client SECRETS are never entered here, never "
            "baked, and never on any argv.")
        eb.addWidget(_row("Client ID", self.client_id))
        self.jwks = QtWidgets.QLineEdit()
        self.jwks.setToolTip(
            "Optional JWKS (signing-keys) URL override (--idp-jwks). Leave empty "
            "to derive the provider's documented default from the issuer.")
        eb.addWidget(_row("JWKS URL", self.jwks))
        self.jwks_preview = QtWidgets.QLabel("")
        self.jwks_preview.setWordWrap(True)
        self.jwks_preview.setStyleSheet(muted())
        eb.addWidget(self.jwks_preview)
        self.ext_box.setVisible(False)          # the WINDOW is where these are edited
        lay.addWidget(self.ext_box)

        # What the chosen external provider is currently configured to trust — a
        # read-only echo of what the window produced, plus the way back into it.
        self.summary = QtWidgets.QLabel("")
        self.summary.setWordWrap(True)
        self.summary.setStyleSheet(muted())
        self.summary.setVisible(False)
        lay.addWidget(self.summary)
        self.configure_btn = QtWidgets.QPushButton("Configure provider…")
        self.configure_btn.setToolTip(
            "Reopen the provider configuration window for the selected provider.")
        self.configure_btn.clicked.connect(lambda: self.open_provider_window())
        self.configure_btn.setVisible(False)
        lay.addWidget(self.configure_btn)

        note = QtWidgets.QLabel(_LIMITS_NOTE)
        note.setWordWrap(True)
        note.setStyleSheet(muted())
        lay.addWidget(note)
        lay.addStretch(1)

        self.group.buttonToggled.connect(self._sync)
        # ASK 14 + 17 — a CLICK on a card is the decision: casdoor (the default) simply
        # proceeds; anything else opens the per-provider configuration window and then
        # proceeds if it was completed. buttonToggled above still only re-syncs, so a
        # programmatic setChecked() (initializePage, config reload, every existing test)
        # never navigates on its own.
        self.group.buttonClicked.connect(self._card_clicked)
        self.issuer.textChanged.connect(self._sync)
        self.client_id.textChanged.connect(self._sync)
        self.jwks.textChanged.connect(self._sync)
        self._provider_window = None
        self._sync()

    # ── selection helpers ────────────────────────────────────────────────────────
    def selected_idp(self) -> str:
        btn = self.group.checkedButton()
        return btn.property("idp") if btn is not None else "casdoor"

    def _external(self) -> bool:
        return self.selected_idp() != "casdoor"

    def _candidate(self):
        """A throwaway config carrying ONLY this page's fields, for validation —
        so isComplete shares validate_identity()'s exact fail-closed rules
        instead of a second, drifting predicate."""
        from ...core.config import ImageConfig
        return ImageConfig(idp=self.selected_idp(),
                           idp_issuer=self.issuer.text().strip() if self._external() else "",
                           idp_client_id=self.client_id.text().strip() if self._external() else "",
                           idp_jwks=self.jwks.text().strip() if self._external() else "")

    def _sync(self, *_):
        ext = self._external()
        idp = self.selected_idp()
        # enabled IFF external (casdoor needs — and permits — nothing here)
        self.ext_box.setEnabled(ext)
        self.issuer.setPlaceholderText(_ISSUER_HINTS.get(idp, ""))
        self.client_id.setPlaceholderText(_CLIENT_HINTS.get(idp, ""))
        self.jwks.setPlaceholderText(_JWKS_HINTS.get(idp, ""))
        if ext and not self.jwks.text().strip():
            derived = idp_effective_jwks(idp, self.issuer.text().strip(), "")
            self.jwks_preview.setText(
                f"JWKS will derive to: {derived}" if derived
                else "JWKS derives from the issuer once one is entered.")
        else:
            self.jwks_preview.setText("")
        # the read-only echo of what the provider window produced (ask 17)
        self.configure_btn.setVisible(ext)
        self.summary.setVisible(ext)
        if ext:
            issuer = self.issuer.text().strip()
            client = self.client_id.text().strip()
            if issuer or client:
                self.summary.setText(
                    f"Configured: issuer {issuer or '(not set)'} · client "
                    f"{client or '(not set)'}")
            else:
                self.summary.setText(
                    "Not configured yet — open the configuration window to enter this "
                    "provider's issuer and client id.")
        self.completeChanged.emit()

    # ── ASK 17: the card opens a per-provider configuration WINDOW ───────────────
    def _card_clicked(self, _btn=None) -> None:
        """A card CLICK is the decision. Guarded end to end: this is a Qt slot, and an
        escaping exception under PyQt6 calls qFatal and kills the Studio."""
        try:
            idp = self.selected_idp()
            if idp == "casdoor":
                self._proceed()                 # the default: nothing to configure
                return
            if self.open_provider_window():
                self._proceed()
        except Exception:                       # pragma: no cover - defence in depth
            import sys
            import traceback
            print("idp: swallowed exception in _card_clicked", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)

    def open_provider_window(self) -> bool:
        """Open the per-provider configuration wizard; True when it was completed.

        ``has_wizard`` is checked rather than assumed: a provider added to
        IDP_CHOICES without a configuration wizard must say so plainly instead of
        opening an empty window — the one failure mode ask 17 calls out by name.
        """
        idp = self.selected_idp()
        if not idp_provider.has_wizard(idp):
            QtWidgets.QMessageBox.information(
                self, "No configuration wizard",
                f"There is no configuration wizard for “{IDP_LABELS.get(idp, idp)}” "
                "yet. Enter its issuer and client id in a saved config, or pick "
                "another provider.")
            return False
        win = idp_provider.ProviderConfigWindow(
            idp, issuer=self.issuer.text().strip(),
            client_id=self.client_id.text().strip(),
            jwks=self.jwks.text().strip(), parent=self.window())
        self._provider_window = win
        accepted = win.exec() == QtWidgets.QDialog.DialogCode.Accepted
        if accepted:
            issuer, client_id, jwks = win.result_values()
            self.issuer.setText(issuer)
            self.client_id.setText(client_id)
            self.jwks.setText(jwks)
        self._sync()
        return accepted

    def _proceed(self) -> None:
        """Choosing IS proceeding (ask 14): advance the flow, but only when the page
        would let Next through anyway — never bypass the fail-closed identity gate."""
        wiz = self.wizard()
        if wiz is not None and self.isComplete():
            wiz.next()

    def isComplete(self) -> bool:
        # Casdoor is always complete; external gates Next on the SAME fail-closed
        # rules to_cli_args enforces (https issuer + client id + optional jwks).
        try:
            self._candidate().validate_identity()
            return True
        except ValueError:
            return False

    # ── wizard contract ──────────────────────────────────────────────────────────
    def initializePage(self):
        c = self.wiz.cfg
        rb = self._buttons.get(c.idp if c.idp in self._buttons else "casdoor")
        if rb is not None:
            rb.setChecked(True)
        self.issuer.setText(c.idp_issuer)
        self.client_id.setText(c.idp_client_id)
        self.jwks.setText(c.idp_jwks)
        self._sync()

    def validatePage(self):
        c = self.wiz.cfg
        c.idp = self.selected_idp()
        if c.idp == "casdoor":
            # the byte-identity invariant: the built-in default carries ZERO
            # external residue, even if fields were typed then the radio flipped back
            c.idp_issuer = ""
            c.idp_client_id = ""
            c.idp_jwks = ""
        else:
            c.idp_issuer = self.issuer.text().strip()
            c.idp_client_id = self.client_id.text().strip()
            c.idp_jwks = self.jwks.text().strip()
        return True
