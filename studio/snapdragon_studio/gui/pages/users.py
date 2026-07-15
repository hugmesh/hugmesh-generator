"""UsersPage — the superadmin users table + the explicit person-role picker.

The per-row Domain cell is a DROPDOWN of the previously-defined domains (spec 6): the
orchestration superdomain plus every name from the shared Domains table (and any rows
a superadmin added this session). Selecting the ``superadmin`` role forces + locks the
row to the superdomain (spec 5): superadmins belong to the orchestration domain, not a
tenant domain. A loaded user whose domain is not (yet) defined is shown suffixed
'(not defined)' with an orange warning — never silently rewritten.
"""
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

# Per-user first-login REGISTRATION method (spec 4/6). "derive" = "" on the User (the
# provisioning default); discord/gmail = OAuth self-registration at first login; password
# = a random password is generated + presented at provisioning (no secret is typed or
# stored here). Manifest-only — never reaches the argv (User is provisioning data).
USER_REGISTRATION_CHOICES = ("derive", "discord", "gmail", "password")

# Registration is appended as the LAST column so the Domain/Role cell indices tests
# read (cellWidget(row, 1) / cellWidget(row, 2)) are unchanged.
_COL_USER, _COL_DOMAIN, _COL_ROLE, _COL_EMAIL, _COL_REG = range(5)
# a loaded domain that is not among the defined domains is kept, but flagged — never
# silently rewritten to a defined one.
_UNDEFINED = " (not defined)"


class UsersPage(QtWidgets.QWizardPage):
    """Superadmin: attach users to domains."""
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Superusers & domain users")
        self.setSubTitle(
            "Name the superusers (locked to the orchestration superdomain) "
            "and add users to each domain. For every user pick how they first sign in: "
            "Discord or Gmail self-registration, or a password issued at provisioning.")
        lay = QtWidgets.QVBoxLayout(self)
        self.table = QtWidgets.QTableWidget(0, 5)
        self.table.setHorizontalHeaderLabels(
            ["Username", "Domain", "Role", "Email", "Registration"])
        self.table.horizontalHeader().setStretchLastSection(True)
        lay.addWidget(self.table)
        # STEP 4/6 clarity: what the Registration column means.
        self.reg_help = QtWidgets.QLabel(
            "Registration: ‘discord’/‘gmail’ let the user self-register with that "
            "account at first login; ‘password’ means a random password is generated "
            "and presented at provisioning (never typed or stored here); ‘derive’ keeps "
            "the provisioning default.")
        self.reg_help.setWordWrap(True)
        self.reg_help.setStyleSheet("color: gray;")
        lay.addWidget(self.reg_help)
        # shown when a row references a domain that is not (yet) defined on the Domains
        # page — kept as-is, flagged (never silently rewritten).
        self.warn = QtWidgets.QLabel("")
        self.warn.setWordWrap(True)
        self.warn.setStyleSheet("color: orange;")
        self.warn.setVisible(False)
        lay.addWidget(self.warn)
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

    # ---- domain-dropdown helpers -------------------------------------------------
    def _domain_choices(self) -> list[str]:
        """The superdomain + every defined domain name (deduped, order-preserving)."""
        out = [self.wiz.cfg.effective_superdomain()]
        for d in self.wiz.cfg.domains:
            if d.name and d.name not in out:
                out.append(d.name)
        return out

    def _raw_domain(self, text: str) -> str:
        """Strip the '(not defined)' flag suffix back to the stored domain value."""
        return text[:-len(_UNDEFINED)] if text.endswith(_UNDEFINED) else text

    def _fill_domain_combo(self, combo, current: str):
        combo.blockSignals(True)
        combo.clear()
        combo.addItems(self._domain_choices())
        if current:
            i = combo.findText(current)
            if i < 0:                       # a loaded/typed domain not (yet) defined
                combo.addItem(current + _UNDEFINED)
                i = combo.count() - 1
            combo.setCurrentIndex(i)
        combo.blockSignals(False)

    def _apply_role_lock(self, dom_combo, role_combo):
        """superadmin belongs to the orchestration superdomain (spec 5): force + lock
        the domain there; any other role unlocks the dropdown."""
        if role_combo.currentText() == "superadmin":
            sd = self.wiz.cfg.effective_superdomain()
            i = dom_combo.findText(sd)
            if i < 0:
                dom_combo.insertItem(0, sd)
                i = 0
            dom_combo.setCurrentIndex(i)
            dom_combo.setEnabled(False)
        else:
            dom_combo.setEnabled(True)
        self._update_warning()

    def _add(self, username="", domain="", role="user", email="", registration=""):
        r = self.table.rowCount()
        self.table.insertRow(r)
        self.table.setItem(r, _COL_USER, QtWidgets.QTableWidgetItem(username))
        dom_combo = QtWidgets.QComboBox()
        self._fill_domain_combo(dom_combo, domain)
        self.table.setCellWidget(r, _COL_DOMAIN, dom_combo)
        role_combo = QtWidgets.QComboBox()
        role_combo.addItems(USER_ROLE_CHOICES)
        role_combo.setCurrentText(role)
        self.table.setCellWidget(r, _COL_ROLE, role_combo)
        role_combo.currentTextChanged.connect(
            lambda _t, d=dom_combo, rc=role_combo: self._apply_role_lock(d, rc))
        dom_combo.currentTextChanged.connect(lambda _t: self._update_warning())
        self.table.setItem(r, _COL_EMAIL, QtWidgets.QTableWidgetItem(email))
        # per-user first-login registration method ("" -> the 'derive' default)
        reg_combo = QtWidgets.QComboBox()
        reg_combo.addItems(USER_REGISTRATION_CHOICES)
        reg_combo.setCurrentText(registration or "derive")
        self.table.setCellWidget(r, _COL_REG, reg_combo)
        self._apply_role_lock(dom_combo, role_combo)

    def _remove(self):
        for idx in sorted({i.row() for i in self.table.selectedIndexes()}, reverse=True):
            self.table.removeRow(idx)
        self._update_warning()

    def _update_warning(self):
        undef = []
        for r in range(self.table.rowCount()):
            dom = self.table.cellWidget(r, _COL_DOMAIN)
            if isinstance(dom, QtWidgets.QComboBox) and dom.currentText().endswith(_UNDEFINED):
                undef.append(self._raw_domain(dom.currentText()))
        if undef:
            self.warn.setText(
                "Domain(s) not defined on the Domains page: " + ", ".join(undef) +
                " — define them there or pick a defined domain.")
            self.warn.setVisible(True)
        else:
            self.warn.setVisible(False)

    def initializePage(self):
        c = self.wiz.cfg
        if self.table.rowCount() == 0:
            for u in c.users:
                self._add(u.username, u.domain, u.role, u.email,
                          getattr(u, "registration", ""))
        else:
            # back-nav: newly-defined domains must appear in every row's dropdown, and
            # a superadmin lock re-pins to the current superdomain.
            for r in range(self.table.rowCount()):
                dom = self.table.cellWidget(r, _COL_DOMAIN)
                role_combo = self.table.cellWidget(r, _COL_ROLE)
                if isinstance(dom, QtWidgets.QComboBox):
                    self._fill_domain_combo(dom, self._raw_domain(dom.currentText()))
                    if role_combo is not None:
                        self._apply_role_lock(dom, role_combo)
        self.person_role.setCurrentText(c.person_role if c.person_role in PERSON_ROLE_CHOICES
                                        else "derive")
        gate_widgets(c.platform, {"person_role": self.person_role_row})
        self._update_warning()

    def validatePage(self):
        out = []
        for r in range(self.table.rowCount()):
            username = self.table.item(r, _COL_USER).text().strip() if self.table.item(r, _COL_USER) else ""
            if not username:
                continue
            dom = self.table.cellWidget(r, _COL_DOMAIN)
            domain = self._raw_domain(dom.currentText()) if isinstance(dom, QtWidgets.QComboBox) else ""
            role_combo = self.table.cellWidget(r, _COL_ROLE)
            role = role_combo.currentText() if role_combo else "user"
            email = self.table.item(r, _COL_EMAIL).text().strip() if self.table.item(r, _COL_EMAIL) else ""
            reg_combo = self.table.cellWidget(r, _COL_REG)
            reg = reg_combo.currentText() if isinstance(reg_combo, QtWidgets.QComboBox) else "derive"
            registration = "" if reg == "derive" else reg
            out.append(User(username=username, domain=domain, role=role, email=email,
                            registration=registration))
        c = self.wiz.cfg
        c.users = out
        pr = self.person_role.currentText()
        c.person_role = "" if pr == "derive" else pr
        # a value picked while an x86 platform was selected must not linger once the
        # platform has no --person-role flag (same rule as NetworkPage's gated fields)
        clear_unsupported(c, ("person_role",))
        return True
