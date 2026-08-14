"""The "Add user…" dialog — ONE named account for the RUNNING local mesh.

Qt half only, mirroring ``_credentials_dialog.py``: every fact it renders comes
from the Qt-free core (``seeded_credentials.grantable_roles`` for the role
catalogue, ``ROLE_APPS`` for the "opens …" annotations). The dialog COLLECTS;
the page's ``_add_user`` verb applies, by re-running the idempotent seeder with
``EXTRA_ROLE_USERS`` appended — never a bespoke Casdoor call, so the account is
created by exactly the machinery that created every other persona.

Validation mirrors the seeder's own gates so the dialog can never hand the verb
a spec the render would reject:
  * seed-accounts.sh's Casdoor legal-name regex
    ``^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$``, plus rejects for the
    double-separator forms it disallows;
  * ``@`` (leg 1c deliberately skips email-shaped handles from onboarding),
    ``:`` and whitespace (the EXTRA_ROLE_USERS spec grammar's delimiters);
  * ROLE_USER is forced-checked — the gateway floor requires it.
"""
from __future__ import annotations

import re

from ..qt import QtCore, QtWidgets
from ...core.seeded_credentials import ROLE_APPS, grantable_roles

_LEGAL_NAME = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$")
_BAD_PAIRS = ("--", "__", "-_", "_-")


def _password_env_for(username: str) -> str:
    """The per-user password env var name, in the ``E2E_<UPPER>_PASSWORD``
    convention both seed-accounts.sh role_password() and seed-e2e.sh
    persona_password() resolve via printenv: non-alphanumerics fold to '_'."""
    slug = re.sub(r"[^A-Za-z0-9]", "_", username.upper())
    return f"STUDIO_USER_{slug}_PASSWORD"


class AddUserDialog(QtWidgets.QDialog):
    def __init__(self, generator_dir: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Add a user to this mesh")
        self.setModal(True)
        lay = QtWidgets.QVBoxLayout(self)

        intro = QtWidgets.QLabel(
            "Creates ONE named account through the same seeder that provisions "
            "every persona (idempotent: existing accounts are re-applied "
            "unchanged). The account gets registration stage 2, so it can sign "
            "in and use its roles immediately.")
        intro.setWordWrap(True)
        lay.addWidget(intro)

        form = QtWidgets.QFormLayout()
        self.username = QtWidgets.QLineEdit()
        self.username.setPlaceholderText("letters/digits, - or _ inside (Casdoor legal name)")
        self.username.textChanged.connect(self._revalidate)
        form.addRow("Username", self.username)

        self.password = QtWidgets.QLineEdit()
        self.password.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.password.setPlaceholderText("empty = the shared default e2e-pass")
        form.addRow("Password", self.password)
        lay.addLayout(form)

        lay.addWidget(QtWidgets.QLabel("Roles:"))
        self._role_boxes: list[tuple[str, QtWidgets.QCheckBox]] = []
        for role in grantable_roles(generator_dir):
            label = role
            app = ROLE_APPS.get(role)
            if app:
                label = f"{role}  (opens {app})"
            box = QtWidgets.QCheckBox(label)
            if role == "ROLE_USER":
                # The gateway floor: every principal needs it; not optional.
                box.setChecked(True)
                box.setEnabled(False)
            box.toggled.connect(self._revalidate)
            self._role_boxes.append((role, box))
            lay.addWidget(box)

        self.err = QtWidgets.QLabel("")
        self.err.setWordWrap(True)
        self.err.setStyleSheet("color: #c62828;")
        self.err.setVisible(False)
        lay.addWidget(self.err)

        note = QtWidgets.QLabel(
            "Note: the password is materialized into the seeder's gitignored "
            "render (tests/stack/.seed-e2e/) like every seeded credential, and "
            "a later re-seed run from a TERMINAL (which does not carry this "
            "page's EXTRA_ROLE_USERS) keeps the account but STRIPS its role "
            "memberships — re-add it from this page after such a re-seed.")
        note.setWordWrap(True)
        note.setStyleSheet("color: #777;")
        lay.addWidget(note)

        btns = QtWidgets.QDialogButtonBox(
            QtWidgets.QDialogButtonBox.StandardButton.Ok
            | QtWidgets.QDialogButtonBox.StandardButton.Cancel)
        btns.accepted.connect(self.accept)
        btns.rejected.connect(self.reject)
        self._ok = btns.button(QtWidgets.QDialogButtonBox.StandardButton.Ok)
        self._ok.setEnabled(False)
        lay.addWidget(btns)

    # ── validation (never raises: slots) ─────────────────────────────────────────
    def _username_error(self) -> str:
        name = self.username.text().strip()
        if not name:
            return "Enter a username."
        if any(c.isspace() for c in name) or "@" in name or ":" in name:
            return ("Usernames cannot contain spaces, '@' or ':' — '@' handles are "
                    "deliberately skipped from onboarding, and ':' is the spec "
                    "grammar's delimiter.")
        if not _LEGAL_NAME.match(name):
            return ("Casdoor legal name: start/end with a letter or digit; '-' and "
                    "'_' allowed inside.")
        if any(p in name for p in _BAD_PAIRS):
            return "Doubled separators (--, __, -_, _-) are rejected by the seeder."
        return ""

    def _revalidate(self, *_):
        err = self._username_error()
        self.err.setText(err)
        self.err.setVisible(bool(err))
        self._ok.setEnabled(not err)

    # ── result ───────────────────────────────────────────────────────────────────
    def result_spec(self) -> tuple[str, str, str]:
        """(EXTRA_ROLE_USERS spec, password env var name, password value).

        Spec grammar is seed-e2e.sh's ``name:ROLE_A,ROLE_B:PASSWORD_ENV``; the
        password itself travels ONLY in the env var (never argv, never logged).
        An empty password keeps the shared E2E_PASSWORD default — the spec then
        names that env instead."""
        name = self.username.text().strip()
        roles = [r for r, box in self._role_boxes if box.isChecked()]
        password = self.password.text()
        if password:
            env_name = _password_env_for(name)
        else:
            env_name = "E2E_PASSWORD"
        return f"{name}:{','.join(roles)}:{env_name}", env_name, password
