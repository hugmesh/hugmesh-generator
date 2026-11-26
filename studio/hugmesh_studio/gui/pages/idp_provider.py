"""ASK 17 — the per-provider identity-provider configuration WINDOW.

    "identity provider screen should be buttons that go to a new window to configure a
     new provider in a cloud provider wizard unless the default casdoor is selected in
     which case proceed"

So: the IdP cards stay, Casdoor proceeds with nothing to configure, and any other
provider opens THIS — a real window, a real multi-step wizard, one page per thing the
operator actually has to do.

**What this wizard is, exactly, and what it is not.** It configures the mesh's side of
the trust relationship: the issuer, the client id, and (optionally) the JWKS override —
the three values ``core/config.py`` emits as ``--idp-issuer`` / ``--idp-client-id`` /
``--idp-jwks`` and the builder bakes into ``/etc/hugmesh/idp.conf``. It does NOT reach
into anyone's cloud account: it does not create the Entra app registration or the
Cognito user pool, it holds no cloud credentials, and it makes no network calls at all
(the Studio never does). The "before you start" page therefore lists the console steps
the operator performs THEMSELVES, in that provider's own console, and names where each
value comes from — because the alternative is a wizard that implies it did work it did
not do.

Validation is not re-implemented here. ``_candidate()`` builds a throwaway
:class:`ImageConfig` and calls ``validate_identity()`` — the exact fail-closed rule
``to_cli_args`` enforces — so a value this window accepts is a value the build accepts,
and there is no second predicate to drift.

Qt duality: PySide6 in the venv, PyQt6 for the operator — an exception escaping a slot
under PyQt6 calls qFatal, so every slot here is guarded.
"""
from __future__ import annotations

import sys
import traceback

from ..qt import Qt, QtWidgets
from ..branding_icon import brand_icon
from ..styles import muted
from ...core.config import IDP_LABELS, ImageConfig, idp_effective_jwks
from ._scroll import scrollable
from ._widgets import _row

__all__ = ["PROVIDER_STEPS", "ProviderConfigWindow", "has_wizard"]

# The console work the OPERATOR does, per provider, before this window can be filled
# in. Written as instructions for a human at that vendor's console — never as a claim
# that the Studio performed any of it.
PROVIDER_STEPS: dict[str, tuple[str, ...]] = {
    "entra": (
        "In the Azure portal, open Microsoft Entra ID → App registrations → "
        "New registration.",
        "Register a single-tenant (or multi-tenant, if that is your posture) "
        "application for this mesh and add the mesh's redirect URI to it.",
        "Copy the Application (client) ID from the app's Overview blade — that is "
        "the Client ID below.",
        "Take the Issuer from the tenant's OpenID configuration: "
        "https://login.microsoftonline.com/<tenant-id>/v2.0 . It must byte-match the "
        "`iss` claim in the tokens the tenant actually mints.",
        "Entra mints PAIRWISE per-app `sub` values and per-resource audiences — read "
        "docs/IDENTITY-PROVIDERS.md before you ship a mesh on it.",
    ),
    "aws": (
        "In the AWS console, open Amazon Cognito → User pools and create (or pick) "
        "the pool this mesh will trust.",
        "Add an app client for the mesh and copy its Client ID.",
        "The Issuer is https://cognito-idp.<region>.amazonaws.com/<user-pool-id> — "
        "shown on the pool's overview.",
        "Cognito carries groups in the `cognito:groups` claim, which the platform's "
        "role gates do NOT read: group-based authorization will not work until the "
        "service repos grow it.",
    ),
    "oidc": (
        "At your provider, register an OIDC client for this mesh and note its "
        "client id.",
        "Take the Issuer from the provider's discovery document — the `issuer` value "
        "in /.well-known/openid-configuration, exactly as written.",
        "If the provider does not publish keys at <issuer>/.well-known/jwks, set the "
        "JWKS URL override below.",
    ),
}

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

_SCOPE_NOTE = (
    "This wizard configures the MESH's side of the trust only: the issuer, the client "
    "id and an optional JWKS override, which are baked into /etc/hugmesh/idp.conf and "
    "pinned through the cluster tree. It does not create anything in your cloud "
    "account, never asks for cloud credentials, and makes no network calls — the "
    "Studio never does. The steps above are yours to perform in the provider's own "
    "console.")


def has_wizard(idp: str) -> bool:
    """True when this provider has a real configuration wizard behind its card.

    Casdoor deliberately has none — it is the built-in default and needs nothing — and
    the card for it simply proceeds. Every EXTERNAL provider in ``IDP_CHOICES`` has one,
    which is what lets the IdP page promise a window and mean it.
    """
    return idp in PROVIDER_STEPS


def _log_swallowed(where: str) -> None:
    print(f"idp_provider: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


class _StepsPage(QtWidgets.QWizardPage):
    """"Before you start": the console work the operator does, at their provider."""

    def __init__(self, idp: str):
        super().__init__()
        label = IDP_LABELS.get(idp, idp)
        self.setTitle(f"{label} — before you start")
        self.setSubTitle(
            "Do these in your provider's console first; this wizard only records the "
            "values they produce.")
        lay = scrollable(self)
        for i, step in enumerate(PROVIDER_STEPS.get(idp, ()), start=1):
            row = QtWidgets.QLabel(f"{i}.  {step}")
            row.setWordWrap(True)
            lay.addWidget(row)
        note = QtWidgets.QLabel(_SCOPE_NOTE)
        note.setWordWrap(True)
        note.setStyleSheet(muted())
        lay.addWidget(note)
        lay.addStretch(1)


class _EndpointsPage(QtWidgets.QWizardPage):
    """The three values, gated by the SAME fail-closed rule the build enforces."""

    def __init__(self, win: "ProviderConfigWindow"):
        super().__init__()
        self.win = win
        label = IDP_LABELS.get(win.idp, win.idp)
        self.setTitle(f"{label} — endpoints")
        self.setSubTitle(
            "The issuer must be https and must byte-match the `iss` claim in the "
            "tokens your provider mints.")
        lay = scrollable(self)

        self.issuer = QtWidgets.QLineEdit(win.issuer)
        self.issuer.setPlaceholderText(_ISSUER_HINTS.get(win.idp, ""))
        self.issuer.setToolTip(
            "The OIDC issuer URL (--idp-issuer). Must byte-match the `iss` claim.")
        lay.addWidget(_row("Issuer URL", self.issuer))

        self.client_id = QtWidgets.QLineEdit(win.client_id)
        self.client_id.setPlaceholderText(_CLIENT_HINTS.get(win.idp, ""))
        self.client_id.setToolTip(
            "The OIDC client id registered at the provider (--idp-client-id). A "
            "PUBLIC identifier — client SECRETS are never entered here, never baked, "
            "and never on any argv.")
        lay.addWidget(_row("Client ID", self.client_id))

        self.jwks = QtWidgets.QLineEdit(win.jwks)
        self.jwks.setPlaceholderText(_JWKS_HINTS.get(win.idp, ""))
        self.jwks.setToolTip(
            "Optional JWKS (signing-keys) URL override (--idp-jwks). Leave empty to "
            "derive the provider's documented default from the issuer.")
        lay.addWidget(_row("JWKS URL", self.jwks))

        self.preview = QtWidgets.QLabel("")
        self.preview.setWordWrap(True)
        self.preview.setStyleSheet(muted())
        lay.addWidget(self.preview)

        secrets = QtWidgets.QLabel(
            "No client secret is collected here. Nothing on this page is a secret: "
            "all three values are public identifiers that ride the build's argv.")
        secrets.setWordWrap(True)
        secrets.setStyleSheet(muted())
        lay.addWidget(secrets)
        lay.addStretch(1)

        for edit in (self.issuer, self.client_id, self.jwks):
            edit.textChanged.connect(self._sync)
        self._sync()

    def _sync(self, *_a) -> None:
        try:
            derived = idp_effective_jwks(self.win.idp, self.issuer.text().strip(),
                                         self.jwks.text().strip())
            self.preview.setText(
                f"JWKS will resolve to: {derived}" if derived
                else "JWKS derives from the issuer once one is entered.")
            self.completeChanged.emit()
        except Exception:
            _log_swallowed("_EndpointsPage._sync")

    def _candidate(self) -> ImageConfig:
        """A throwaway config carrying ONLY these fields — validated by the build's own
        ``validate_identity()`` so this window can never accept what the build rejects."""
        return ImageConfig(idp=self.win.idp,
                           idp_issuer=self.issuer.text().strip(),
                           idp_client_id=self.client_id.text().strip(),
                           idp_jwks=self.jwks.text().strip())

    def isComplete(self) -> bool:  # noqa: N802 (Qt override)
        try:
            self._candidate().validate_identity()
            return True
        except ValueError:
            return False
        except Exception:                        # pragma: no cover - defence in depth
            _log_swallowed("_EndpointsPage.isComplete")
            return False

    def validatePage(self) -> bool:  # noqa: N802 (Qt override)
        try:
            self.win.issuer = self.issuer.text().strip()
            self.win.client_id = self.client_id.text().strip()
            self.win.jwks = self.jwks.text().strip()
            return True
        except Exception:                        # pragma: no cover - defence in depth
            _log_swallowed("_EndpointsPage.validatePage")
            return False


class _ReviewPage(QtWidgets.QWizardPage):
    """What will be baked, and — plainly — what this provider still cannot do."""

    _LIMITS = (
        "External mode re-points token VALIDATION: it bakes /etc/hugmesh/idp.conf, "
        "rewrites the cluster tree's issuer + JWKS pins to your provider, and gates "
        "the built-in Casdoor apps out of the image.\n\n"
        "It does NOT port the native first-party /bff/login page, MFA step-up "
        "stamping, the roles/permissions/groups token model (headscale / Harbor / "
        "desktop-sudo group gates), the signup gate, or the role-sync jobs — all of "
        "which remain Casdoor-only until the service repos grow provider support. "
        "See docs/IDENTITY-PROVIDERS.md for the full per-provider table.")

    def __init__(self, win: "ProviderConfigWindow"):
        super().__init__()
        self.win = win
        self.setTitle("Review")
        self.setSubTitle("What this mesh will be built to trust.")
        lay = scrollable(self)
        self.summary = QtWidgets.QLabel("")
        self.summary.setWordWrap(True)
        self.summary.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.summary)
        limits = QtWidgets.QLabel(self._LIMITS)
        limits.setWordWrap(True)
        limits.setStyleSheet(muted())
        lay.addWidget(limits)
        lay.addStretch(1)

    def initializePage(self):  # noqa: N802 (Qt override)
        try:
            self.summary.setText(self.win.summary_text())
        except Exception:                        # pragma: no cover - defence in depth
            _log_swallowed("_ReviewPage.initializePage")


class ProviderConfigWindow(QtWidgets.QWizard):
    """The NEW WINDOW ask 17 asks for: a per-provider configuration wizard.

    A real top-level window rather than a modal box (``exec()`` is still how the IdP
    page waits for an answer, but nothing here is a one-shot dialog — it is three
    pages with Back). On accept, :attr:`issuer` / :attr:`client_id` / :attr:`jwks` hold
    the validated values for the caller to read.
    """

    def __init__(self, idp: str, *, issuer: str = "", client_id: str = "",
                 jwks: str = "", parent=None):
        super().__init__(parent)
        self.idp = idp
        self.issuer = issuer
        self.client_id = client_id
        self.jwks = jwks
        label = IDP_LABELS.get(idp, idp)
        self.setWindowTitle(f"Configure identity provider — {label}")
        self.setWindowIcon(brand_icon())
        self.setWizardStyle(QtWidgets.QWizard.WizardStyle.ModernStyle)
        self.resize(760, 560)
        self.steps_page = _StepsPage(idp)
        self.endpoints_page = _EndpointsPage(self)
        self.review_page = _ReviewPage(self)
        for page in (self.steps_page, self.endpoints_page, self.review_page):
            self.addPage(page)

    def summary_text(self) -> str:
        derived = idp_effective_jwks(self.idp, self.issuer, self.jwks)
        return (f"Provider: {IDP_LABELS.get(self.idp, self.idp)}\n"
                f"Issuer:    {self.issuer}\n"
                f"Client ID: {self.client_id}\n"
                f"JWKS:      {self.jwks or (derived + '  (derived)')}")

    def result_values(self) -> tuple[str, str, str]:
        """``(issuer, client_id, jwks)`` — what the IdP page writes back into cfg."""
        return self.issuer, self.client_id, self.jwks
