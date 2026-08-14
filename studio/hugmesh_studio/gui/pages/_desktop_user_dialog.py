"""The per-desktop person popup (operator ask 2026-08-14) — Qt half only.

Opened by the mesh WorklistPage when a DESKTOP-class row is checked: collects the
person's username + role for that device. The page keeps the collected pairs in
its on-screen table and stamps them onto the WorklistEntries on Next; the core
half (worklist.desktop_users / _materialize_one 3b) turns them into a manifest
User on the internal orchestration superdomain and the image's --person-role.

Username validation is core.validate.validate_username — the same allowlist every
other surface uses — so the dialog can never hand the manifest a name cluster
provisioning would reject. Cancelling means "not this device after all": the
caller unchecks the row.
"""
from __future__ import annotations

from ..qt import QtWidgets
from ...core.config import PERSON_ROLE_CHOICES
from ...core.validate import validate_username

_ROLE_BLURBS = {
    "user": "regular account on the mesh's apps",
    "mod": "moderation surfaces on top of user",
    "admin": "domain administration on top of mod",
    "superadmin": "whole-mesh administration (orchestration domain)",
}


class DesktopUserDialog(QtWidgets.QDialog):
    """Collect (username, role) for one desktop device; result via user()/role()."""

    def __init__(self, device_label: str, username: str = "",
                 role: str = "user", parent=None):
        super().__init__(parent)
        self.setWindowTitle(f"Who uses this desktop? — {device_label}")
        self.setModal(True)
        lay = QtWidgets.QVBoxLayout(self)

        intro = QtWidgets.QLabel(
            f"<b>{device_label}</b> is a person's device. Name its user — the "
            "account is created on the mesh's internal domain (it can later be "
            "added to other domains, e.g. as an admin, on the Users step). The "
            "role is also baked into this image as its person identity.")
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
        i = self.role.findData(role)
        if i >= 0:
            self.role.setCurrentIndex(i)
        form.addRow("Role", self.role)
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
        return self.role.currentData() or "user"
