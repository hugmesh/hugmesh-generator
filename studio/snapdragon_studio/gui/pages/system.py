"""SystemPage — baked host identity (-H/--hostname, -T/--timezone, -u/--user; G26)
and the x86 node FALLBACK credentials --user-password/--root-password (G27).

Kept separate from NetworkPage (mesh/brand plane) and HomePage (local login /
encryption): these fields describe the IMAGE's baked system identity, which every
builder parses, plus the credentials a GUI-built mesh fleet would otherwise ship
as builder defaults.

Registration: StudioWizard/WIZARD_PAGE_SLUGS register this page under the slug
"system" (between "users" and "home") — the page itself only needs a wiz-like
object exposing ``.cfg``, so tests can instantiate it directly.
"""
from __future__ import annotations

from ..qt import QtWidgets
from ._gating import clear_unsupported, gate_widgets
from ._widgets import _row


class SystemPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("System identity")
        self.setSubTitle("The host identity baked into this node/desktop image — "
                         "hostname, timezone and default account. Blank fields keep the "
                         "builder's role-derived hostname, UTC and default account.")
        lay = QtWidgets.QVBoxLayout(self)
        self.hostname = QtWidgets.QLineEdit()
        self.hostname.setPlaceholderText("role-derived when blank (-H/--hostname)")
        lay.addWidget(_row("Hostname", self.hostname))
        self.timezone = QtWidgets.QLineEdit()
        self.timezone.setPlaceholderText("Area/Location, e.g. Europe/Berlin; UTC when blank (-T/--timezone)")
        lay.addWidget(_row("Timezone", self.timezone))
        self.user = QtWidgets.QLineEdit()
        self.user.setPlaceholderText("baked default account name (-u/--user; distinct from --local-user)")
        lay.addWidget(_row("Default user", self.user))
        # node FALLBACK credentials (G27): without these, a GUI-built mesh fleet
        # ships the builder's DEFAULT credentials. x86 only — rpi5's equivalents
        # are deprecated no-ops, so the group greys per the capability table.
        creds = QtWidgets.QGroupBox("Node fallback credentials")
        cl = QtWidgets.QVBoxLayout(creds)
        self.creds_note = QtWidgets.QLabel(
            "Fallback login for the baked user/root account on x86 nodes — without "
            "them a GUI-built mesh fleet ships the builder's default credentials. "
            "Hashed at build time; NEVER written to a saved config.")
        self.creds_note.setWordWrap(True)
        cl.addWidget(self.creds_note)
        self.user_password = QtWidgets.QLineEdit()
        self.user_password.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.user_password.setPlaceholderText("hashed at build time; NOT saved to configs")
        cl.addWidget(_row("User password", self.user_password))
        self.root_password = QtWidgets.QLineEdit()
        self.root_password.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.root_password.setPlaceholderText("hashed at build time; NOT saved to configs")
        cl.addWidget(_row("Root password", self.root_password))
        lay.addWidget(creds)
        lay.addStretch(1)

    def initializePage(self):
        c = self.wiz.cfg
        self.hostname.setText(c.hostname)
        self.timezone.setText(c.timezone)
        self.user.setText(c.user)
        self.user_password.setText(c.user_password)
        self.root_password.setText(c.root_password)
        # hostname/timezone/user are all-platform (-H/-T/-u, every builder); only
        # the fallback credentials are x86-only — greyed per the capability table
        # (G10 pattern) instead of silently dropping the values from an ARM argv.
        gate_widgets(c.platform, {
            "user_password": self.user_password,
            "root_password": self.root_password,
        })

    def validatePage(self):
        c = self.wiz.cfg
        c.hostname = self.hostname.text().strip()
        c.timezone = self.timezone.text().strip()
        c.user = self.user.text().strip()
        c.user_password = self.user_password.text()
        c.root_password = self.root_password.text()
        # x86-only fields — force-clear on every other platform so a stale secret
        # typed while platform was x86 can never linger into the live command for
        # an ARM build (never saved to configs regardless: SECRET_FIELDS).
        clear_unsupported(c, ("user_password", "root_password"))
        return True
