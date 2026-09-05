"""The per-desktop person popup (operator ask 2026-08-14) — Qt half only.

Opened by the mesh WorklistPage when a DESKTOP-class row is checked: collects the
person's username + roles for that device. The page keeps the collected pairs in
its on-screen table and stamps them onto the WorklistEntries on Next; the core
half (worklist.desktop_users / _materialize_one 3b) turns them into a manifest
User on the internal Tailscale root domain and the image's --person-role.

Multi-role (issue #228): the roles are a TIER (PERSON_ROLE_CHOICES — one exclusive
pick, the value --person-role bakes into the image) plus any GRANTS
(USER_GRANT_CHOICES — games / games-services — checkboxes, riding the account
only). ``person_role()`` is the tier, ``person_roles()`` the full set; the entry
derives the tier from the set, so the two can never disagree.

Username validation is core.validate.validate_username — the same allowlist every
other surface uses — so the dialog can never hand the manifest a name cluster
provisioning would reject. Cancelling means "not this device after all": the
caller unchecks the row.
"""
from __future__ import annotations

from ..qt import QtWidgets
from ...core.config import (PERSON_ROLE_CHOICES, USER_GRANT_CHOICES,
                            normalize_user_roles, person_tier)
from ...core.validate import validate_username

_ROLE_BLURBS = {
    "user": "regular account on the mesh's apps",
    "mod": "moderation surfaces on top of user",
    "admin": "domain administration on top of mod",
    "superadmin": "whole-mesh administration (the Tailscale root domain)",
}
# The grants' meaning, from the systems Casdoor seed (see config.USER_ROLE_CHOICES).
_GRANT_BLURBS = {
    "games": "Games Member (ROLE_GAMES)",
    "games-services": "Games App-Store Access (ROLE_GAMES_SERVICES)",
}


class DesktopUserDialog(QtWidgets.QDialog):
    """Collect (username, roles) for one desktop device; result via user() /
    person_role() (the tier) / person_roles() (tier + grants)."""

    def __init__(self, device_label: str, username: str = "",
                 roles="user", parent=None):
        """``roles`` is one role name OR an iterable of them (issue #228) — the
        single-string spelling every caller used before multi-role still works."""
        super().__init__(parent)
        roles = normalize_user_roles([roles] if isinstance(roles, str) else roles)
        self.setWindowTitle(f"Who uses this desktop? — {device_label}")
        self.setModal(True)
        lay = QtWidgets.QVBoxLayout(self)

        intro = QtWidgets.QLabel(
            f"<b>{device_label}</b> is a person's device. Name its user — the "
            "account is created on the mesh's internal domain (it can later be "
            "added to other domains, e.g. as an admin, on the Users step). The "
            "tier is also baked into this image as its person identity; grants "
            "go on the account only.")
        intro.setWordWrap(True)
        lay.addWidget(intro)

        form = QtWidgets.QFormLayout()
        self.username = QtWidgets.QLineEdit(username)
        self.username.setPlaceholderText("username on the internal domain")
        self.username.textChanged.connect(self._revalidate)
        form.addRow("Username", self.username)
        self.role = QtWidgets.QComboBox()
        for r in PERSON_ROLE_CHOICES:
            self.role.addItem(f"{r} — {_ROLE_BLURBS.get(r, '')}", r)
        i = self.role.findData(person_tier(roles))
        if i >= 0:
            self.role.setCurrentIndex(i)
        form.addRow("Tier", self.role)
        # issue #228: the grants — one checkbox each, the same shape as the Users
        # table's RoleCell and the local-mesh Add-user dialog.
        grants = QtWidgets.QWidget()
        gl = QtWidgets.QHBoxLayout(grants)
        gl.setContentsMargins(0, 0, 0, 0)
        self.grants: list[tuple[str, QtWidgets.QCheckBox]] = []
        for g in USER_GRANT_CHOICES:
            box = QtWidgets.QCheckBox(g)
            box.setToolTip(_GRANT_BLURBS.get(g, ""))
            box.setChecked(g in roles)
            self.grants.append((g, box))
            gl.addWidget(box)
        gl.addStretch(1)
        form.addRow("Grants", grants)
        lay.addLayout(form)

        self.err = QtWidgets.QLabel("")
        self.err.setWordWrap(True)
        self.err.setStyleSheet("color: #c62828;")
        self.err.setVisible(False)
        lay.addWidget(self.err)

        btns = QtWidgets.QDialogButtonBox(
            QtWidgets.QDialogButtonBox.StandardButton.Ok
            | QtWidgets.QDialogButtonBox.StandardButton.Cancel)
        btns.accepted.connect(self.accept)
        btns.rejected.connect(self.reject)
        self._ok = btns.button(QtWidgets.QDialogButtonBox.StandardButton.Ok)
        lay.addWidget(btns)
        self._revalidate()

    # never raises: slot
    def _revalidate(self, *_):
        name = self.username.text().strip()
        err = ""
        if not name:
            err = "Enter a username."
        else:
            try:
                validate_username(name)
            except Exception:
                err = ("Unix login name: starts with a lowercase letter or '_', "
                       "then lowercase letters/digits/'-'/'_', max 32 chars.")
        self.err.setText(err)
        self.err.setVisible(bool(err))
        self._ok.setEnabled(not err)

    def user(self) -> str:
        return self.username.text().strip()

    def person_role(self) -> str:
        """The tier — the one value --person-role bakes into the image."""
        return self.role.currentData() or "user"

    def person_roles(self) -> list[str]:
        """The full account (issue #228): the tier plus every ticked grant, in
        precedence order — never empty, the tier is always in it."""
        return normalize_user_roles(
            [self.person_role(), *[g for g, box in self.grants if box.isChecked()]])
