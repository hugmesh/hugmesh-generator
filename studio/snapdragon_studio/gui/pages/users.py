"""UsersPage — the superadmin users table + the explicit person-role picker."""
from __future__ import annotations

from ..qt import QtWidgets
from ...core.config import PERSON_ROLE_CHOICES, User
from ._gating import clear_unsupported, gate_widgets
from ._widgets import _row

# Role slugs offerable per user row (G20): the four platform roles PLUS the
# GRANTABLE games roles from the systems Casdoor seed (specs/cluster/manifests/
# casdoor/init-data-configmap.yaml): 'games' -> ROLE_GAMES (Games Member) and
# 'games-services' -> ROLE_GAMES_SERVICES (Games App-Store Access). The DERIVED
# intersection roles (ROLE_GAMES_ADMIN, ROLE_GAMES_SERVICES_ADMIN/_RUNNER) are
# deliberately NOT offered — they are materialized by the admin-sync Jobs from
# role intersections, and seeding them directly would bypass that default-deny.
USER_ROLE_CHOICES = ("superadmin", "admin", "mod", "user", "games", "games-services")


class UsersPage(QtWidgets.QWizardPage):
    """Superadmin: attach users to domains."""
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Users (superadmin)")
        lay = QtWidgets.QVBoxLayout(self)
        self.table = QtWidgets.QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["Username", "Domain", "Role", "Email"])
        self.table.horizontalHeader().setStretchLastSection(True)
        lay.addWidget(self.table)
        btns = QtWidgets.QHBoxLayout()
        add = QtWidgets.QPushButton("Add user")
        rem = QtWidgets.QPushButton("Remove selected")
        add.clicked.connect(lambda: self._add())
        rem.clicked.connect(self._remove)
        btns.addWidget(add); btns.addWidget(rem); btns.addStretch(1)
        lay.addLayout(btns)
        # The EXPLICIT --person-role picker (G18). 'derive' keeps the historical
        # defaults (cloud: users[0].role, mesh: superadmin — config.py's fallback);
        # an explicit pick overrides them. x86-only (gated below): the ARM builders
        # have no --person-role flag, and on an x86 cluster NODE role the builder
        # warns + ignores it, so config.py suppresses emission there (G18's
        # emission half) — the games roles above are per-USER Casdoor roles and
        # intentionally not person-role choices (the builder rejects them).
        self.person_role = QtWidgets.QComboBox()
        self.person_role.addItems(("derive", *PERSON_ROLE_CHOICES))
        self.person_role.setToolTip(
            "The person-role this CLIENT image is tied to at build time "
            "(--person-role). 'derive' = users[0]'s role in cloud mode, "
            "superadmin in mesh mode. Ignored by the builder on cluster NODE roles.")
        self.person_role_row = _row("This device's person role", self.person_role)
        lay.addWidget(self.person_role_row)

    def _add(self, username="", domain="", role="user", email=""):
        r = self.table.rowCount()
        self.table.insertRow(r)
        self.table.setItem(r, 0, QtWidgets.QTableWidgetItem(username))
        self.table.setItem(r, 1, QtWidgets.QTableWidgetItem(domain))
        combo = QtWidgets.QComboBox(); combo.addItems(USER_ROLE_CHOICES)
        combo.setCurrentText(role)
        self.table.setCellWidget(r, 2, combo)
        self.table.setItem(r, 3, QtWidgets.QTableWidgetItem(email))

    def _remove(self):
        for idx in sorted({i.row() for i in self.table.selectedIndexes()}, reverse=True):
            self.table.removeRow(idx)

    def initializePage(self):
        c = self.wiz.cfg
        if self.table.rowCount() == 0:
            for u in c.users:
                self._add(u.username, u.domain, u.role, u.email)
        self.person_role.setCurrentText(c.person_role if c.person_role in PERSON_ROLE_CHOICES
                                        else "derive")
        gate_widgets(c.platform, {"person_role": self.person_role_row})

    def validatePage(self):
        out = []
        for r in range(self.table.rowCount()):
            username = self.table.item(r, 0).text().strip() if self.table.item(r, 0) else ""
            if not username:
                continue
            domain = self.table.item(r, 1).text().strip() if self.table.item(r, 1) else ""
            role = self.table.cellWidget(r, 2).currentText() if self.table.cellWidget(r, 2) else "user"
            email = self.table.item(r, 3).text().strip() if self.table.item(r, 3) else ""
            out.append(User(username=username, domain=domain, role=role, email=email))
        c = self.wiz.cfg
        c.users = out
        pr = self.person_role.currentText()
        c.person_role = "" if pr == "derive" else pr
        # a value picked while an x86 platform was selected must not linger once the
        # platform has no --person-role flag (same rule as NetworkPage's gated fields)
        clear_unsupported(c, ("person_role",))
        return True
