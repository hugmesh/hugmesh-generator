"""KeyZipPage — import an admin key-zip and (opt-in) remember loginable roles."""
from __future__ import annotations

import os

from ..qt import QtWidgets
from ...core import keyzip
from ._widgets import _file_picker, _row


class KeyZipPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Admin key-zip (optional)")
        self.setSubTitle("Drop in the zip your domain admin generated for you (keys, certs, egress, branding).")
        lay = QtWidgets.QVBoxLayout(self)
        self.path = QtWidgets.QLineEdit()
        btn = _file_picker(self, self.path, "Admin key-zip", "Zip (*.zip)")
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.path, 1); h.addWidget(btn)
        lay.addWidget(_row("Key-zip", w))
        # OPT-IN, default OFF (per --remember-roles-for-passwordless-login / the
        # SNAPDRAGON_REMEMBER_ROLES_FOR_PASSWORDLESS_LOGIN env var): this is the
        # actual gate checked at import time, seeded from that CLI/env default so
        # the box still starts unchecked unless the operator asked for it.
        self.remember_roles = QtWidgets.QCheckBox(
            "Remember human-loginable roles (e.g. platform superadmin) from this "
            "key-zip for passwordless login — writes real login credentials to "
            "local disk (~/.config/snapdragon-studio/local-login/roles.json, "
            "mode 0600). Never DB passwords or other machine secrets.")
        self.remember_roles.setChecked(
            bool(getattr(wiz, "remember_roles_for_passwordless_login", False)))
        lay.addWidget(self.remember_roles)
        imp = QtWidgets.QPushButton("Import & apply")
        imp.clicked.connect(self._import)
        lay.addWidget(imp)
        self.out = QtWidgets.QLabel("")
        self.out.setWordWrap(True)
        lay.addWidget(self.out)
        lay.addStretch(1)

    def _import(self):
        p = self.path.text().strip()
        if not p or not os.path.exists(p):
            self.out.setText("Pick a .zip first.")
            return
        try:
            staging = os.path.join(os.path.expanduser("~"), ".snapdragon", "keyzip")
            c = keyzip.extract(p, staging)
            c.apply_to(self.wiz.cfg)
            self.wiz.cfg.keyzip = p
            role_ids = keyzip.emit_passwordless_login_roles(
                c, enabled=self.remember_roles.isChecked(),
                manifest_path=getattr(self.wiz, "login_manifest_path", None))
            msg = f"Imported: {c.summary()}"
            if c.warnings:
                msg += f"  ·  warnings: {'; '.join(c.warnings)}"
            if role_ids:
                msg += f"  ·  passwordless-login roles remembered: {', '.join(role_ids)}"
            self.out.setText(msg)
        except (OSError, ValueError) as e:
            self.out.setText(f"Failed: {e}")

    def isComplete(self):
        return True
