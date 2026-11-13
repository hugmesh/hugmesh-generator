"""UsersPage — the superadmin users table.

ASK 7 moved the ``--person-role`` picker OFF this page. It was a per-IMAGE build-time
control ("This device's person role") sitting at the bottom of a table of CLUSTER
ACCOUNTS, under an "Add user / Remove selected" button row — so it read as "which of
the accounts above owns this device", which is not what it means. It now lives on the
System-identity step beside the other things baked into the image (see
``gui/pages/system.py``); this page is once again only the superadmin users table.
The FIELD, the flag and the derivation are unchanged — ``config.to_cli_args`` still
derives ``--person-role`` from the first row when the tier is left on "derive", so
this table still feeds it (issue #228: from that row's highest TIER — ``User.tier`` —
since a row can now hold several roles).

Multi-role (issue #228): the Role cell is a row of checkboxes (``RoleCell``), one per
``USER_ROLE_CHOICES`` entry, so one account can be, say, admin + games. The collected
``User.roles`` is the full set; ``User.role`` stays the primary (highest tier) for
every consumer that reads the scalar.

The per-row Domain cell is a DROPDOWN of the previously-defined domains (spec 6): the
Tailscale root domain, then every domain the mesh serves — on the mesh route its OWN
domain (``cfg.cluster_domain``, implicit: never a Domains-table row, always served)
first, then every name from the shared Domains table (and any rows a superadmin added
this session); ``core.domain_services.domain_names_for_services`` is that list. Selecting
the ``superadmin`` role forces + locks the row to the root domain (spec 5): superadmins
belong to the Tailscale root domain, not a tenant domain. A loaded user whose domain is
not (yet) defined is shown suffixed '(not defined)' — in the cell, its tooltip and one
orange warning that names each such domain once — never silently rewritten.
"""
from __future__ import annotations

from ..qt import QtCore, QtWidgets
from ...core.config import (SIGNIN_HANDLE_LABELS, SIGNIN_HANDLES_NOT_APPLIED,
                            USER_ROLE_CHOICES, User, clean_signin_handles,
                            normalize_user_roles, signin_handle_problem,
                            user_signin_handle_warnings,
                            users_table_applies)
from ...core.domain_services import domain_names_for_services

# USER_ROLE_CHOICES (G20) moved to core.config with issue #228 so the core's
# multi-role normalization and this page offer ONE vocabulary; re-exported here for
# the tests and callers that read it off the page module.
__all__ = ["UsersPage", "RoleCell", "USER_ROLE_CHOICES", "USER_REGISTRATION_CHOICES"]

# Per-user first-login REGISTRATION method (spec 4/6). "derive" = "" on the User (the
# provisioning default); discord/gmail = OAuth self-registration at first login; password
# = a random password is generated + presented at provisioning (no secret is typed or
# stored here). Manifest-only — never reaches the argv (User is provisioning data).
USER_REGISTRATION_CHOICES = ("derive", "discord", "gmail", "password")

# Registration is appended as the LAST column so the Domain/Role cell indices tests
# read (cellWidget(row, 1) / cellWidget(row, 2)) are unchanged.
_COL_USER, _COL_DOMAIN, _COL_ROLE, _COL_EMAIL, _COL_REG, _COL_GOOGLE, _COL_DISCORD = range(7)
#: the handle columns, by provider (hugmesh-generator#1107)
_HANDLE_COLS = {"google": _COL_GOOGLE, "discord": _COL_DISCORD}
# a loaded domain that is not among the defined domains is kept, but flagged — never
# silently rewritten to a defined one.
_UNDEFINED = " (not defined)"


def _combo_width_for(combo) -> int:
    """The width ``combo`` needs to show its LONGEST entry uncut, the style's frame,
    padding and drop-down arrow included — measured from its items now. Not
    ``combo.sizeHint()``: the default size-adjust policy freezes that at first show,
    so a domain added on Back-navigation would not count, and ``AdjustToContents``
    makes the combo ``adjustSize()`` itself, shrinking it out of its table cell."""
    fm = combo.fontMetrics()
    text = max((fm.horizontalAdvance(combo.itemText(i)) for i in range(combo.count())),
               default=0)
    opt = QtWidgets.QStyleOptionComboBox()
    opt.initFrom(combo)
    opt.editable = combo.isEditable()
    opt.frame = combo.hasFrame()
    return combo.style().sizeFromContents(
        QtWidgets.QStyle.ContentsType.CT_ComboBox, opt,
        QtCore.QSize(text, fm.height()), combo).width()


class RoleCell(QtWidgets.QWidget):
    """The per-row Role cell (issue #228): one checkbox per USER_ROLE_CHOICES entry,
    so an account can hold several roles (admin + games, say) instead of exactly one.
    The same checkbox-list shape the local-mesh Add-user dialog uses for Casdoor
    grants (_add_user_dialog.py). ``roles()`` is the checked set in precedence order
    (normalize_user_roles), never empty — clearing every box reads as ``user``, the
    floor, and the page says so under the table. ``on_change`` fires on every toggle
    (a plain callback, no modal, so validatePage/itemChanged paths stay headless-safe)."""

    def __init__(self, roles=("user",), on_change=None, parent=None):
        super().__init__(parent)
        lay = QtWidgets.QHBoxLayout(self)
        lay.setContentsMargins(4, 0, 4, 0)
        lay.setSpacing(6)
        self.boxes: list[tuple[str, QtWidgets.QCheckBox]] = []
        for role in USER_ROLE_CHOICES:
            box = QtWidgets.QCheckBox(role)
            self.boxes.append((role, box))
            lay.addWidget(box)
        lay.addStretch(1)
        self.set_roles(roles)
        self._on_change = on_change
        for _role, box in self.boxes:
            box.toggled.connect(self._changed)

    def _changed(self, *_):
        if self._on_change is not None:
            self._on_change()

    def choices(self) -> list[str]:
        return [r for r, _box in self.boxes]

    def roles(self) -> list[str]:
        return normalize_user_roles([r for r, box in self.boxes if box.isChecked()])

    def set_roles(self, roles) -> None:
        want = set(normalize_user_roles(roles))
        for role, box in self.boxes:
            box.blockSignals(True)
            box.setChecked(role in want)
            box.blockSignals(False)

    def has(self, role: str) -> bool:
        return any(r == role and box.isChecked() for r, box in self.boxes)


class UsersPage(QtWidgets.QWizardPage):
    """Superadmin: attach users to domains."""
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        #: The CONFIGURATION OBJECT this table was last filled from (#542) — the same
        #: identity check DomainsPage and pages/domain_services.py carry, for the same
        #: reason. ``load_config`` / ``load_session`` / ``start_build_from_session``
        #: replace ``wiz.cfg`` and call ``restart()``; without this, a Users table that
        #: was already populated keeps the PREVIOUS flow's accounts and validatePage
        #: then rebuilds ``cfg.users`` from them, erasing every user the operator just
        #: loaded. A restart() on the same object still preserves in-progress edits.
        self._cfg_seen = None
        self.setTitle("Superusers & domain users")
        self.setSubTitle(
            "Name the superusers (locked to the Tailscale root domain) and each "
            "domain's users, and how each first signs in: Discord or Gmail "
            "self-registration, or an issued password.")
        lay = QtWidgets.QVBoxLayout(self)
        self.table = QtWidgets.QTableWidget(0, 7)
        self.table.setHorizontalHeaderLabels(
            ["Username", "Domain", "Roles", "Email", "Registration",
             SIGNIN_HANDLE_LABELS["google"], SIGNIN_HANDLE_LABELS["discord"]])
        self.table.horizontalHeader().setStretchLastSection(True)
        lay.addWidget(self.table)
        # typing a handle or a name re-checks the registration advice at once
        self.table.itemChanged.connect(self._item_changed)
        # #1107: the selected row's other sign-in handles. The table is wider than the
        # page (the Roles column alone is ~450 px), so its last two columns sit off
        # screen; this row under it is where a person actually types them. It reads
        # and writes the same cells, so the two can never disagree.
        self._handles_loading = False
        self.handles_row = QtWidgets.QWidget()
        self.handles_row.setObjectName("users_handles_row")
        hr = QtWidgets.QHBoxLayout(self.handles_row)
        hr.setContentsMargins(0, 0, 0, 0)
        self.handles_for = QtWidgets.QLabel("")
        self.handles_for.setObjectName("users_handles_for")
        hr.addWidget(self.handles_for)
        self.handle_edits: dict[str, QtWidgets.QLineEdit] = {}
        for prov, placeholder in (("google", "name@gmail.com"),
                                  ("discord", "their Discord username")):
            hr.addWidget(QtWidgets.QLabel(SIGNIN_HANDLE_LABELS[prov]))
            edit = QtWidgets.QLineEdit()
            edit.setObjectName(f"users_handle_{prov}")
            edit.setPlaceholderText(placeholder)
            edit.setMinimumWidth(170)
            edit.textEdited.connect(
                lambda text, p=prov: self._handle_edited(p, text))
            hr.addWidget(edit, 1)
            self.handle_edits[prov] = edit
        lay.addWidget(self.handles_row)
        self.table.currentCellChanged.connect(
            lambda row, _c, _pr, _pc: self._load_handles(row))
        # issue #228: what the Roles checkboxes mean.
        self.roles_help = QtWidgets.QLabel(
            "Roles: tick every role the account holds. The highest tier "
            "(superadmin > admin > mod > user) is the account's primary role; games "
            "and games-services are grants on top of it. A row with nothing ticked "
            "is saved as ‘user’.")
        self.roles_help.setWordWrap(True)
        self.roles_help.setStyleSheet("color: gray;")
        lay.addWidget(self.roles_help)
        # STEP 4/6 clarity: what the Registration column means.
        self.reg_help = QtWidgets.QLabel(
            "Registration: ‘discord’/‘gmail’ let the user self-register with that "
            "account at first login; ‘password’ means a random password is generated "
            "and presented at provisioning (never typed or stored here); ‘derive’ keeps "
            "the provisioning default.")
        self.reg_help.setWordWrap(True)
        self.reg_help.setStyleSheet("color: gray;")
        lay.addWidget(self.reg_help)
        # #1107: the person's other sign-in handles, and what happens to them today
        self.handles_help = QtWidgets.QLabel(
            "Google account / Discord username: the person's other sign-in handles, "
            "each optional. " + SIGNIN_HANDLES_NOT_APPLIED)
        self.handles_help.setObjectName("users_handles_help")
        self.handles_help.setWordWrap(True)
        self.handles_help.setStyleSheet("color: #a65d00;")
        lay.addWidget(self.handles_help)
        # a handle that cannot be an invite: said here, nothing is written (no dialog)
        self.handles_error = QtWidgets.QLabel("")
        self.handles_error.setObjectName("users_handles_error")
        self.handles_error.setWordWrap(True)
        self.handles_error.setStyleSheet("color: #b00020;")
        self.handles_error.setVisible(False)
        lay.addWidget(self.handles_error)
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
        # a new row is selected, so the handles editor under the table edits it
        add.clicked.connect(lambda: (self._add(), self.table.setCurrentCell(
            self.table.rowCount() - 1, _COL_USER)))
        rem.clicked.connect(self._remove)
        btns.addWidget(add); btns.addWidget(rem); btns.addStretch(1)
        lay.addLayout(btns)
        # (ask 7) The --person-role picker used to sit here. It moved to SystemPage —
        # see the module docstring. Nothing else about this page changed.

    # ---- domain-dropdown helpers -------------------------------------------------
    def _domain_choices(self) -> list[str]:
        """The superdomain + every domain the mesh serves (deduped, order-preserving).

        On the mesh route that includes the mesh's OWN domain (``cfg.cluster_domain``):
        it is implicit — never a ``cfg.domains`` row, and the Domains page cannot add
        it as one — yet always served, and it is where the "Create nodes for local
        cloud" import places every non-superadmin account. Built from the domain list
        alone, every imported row read '(not defined)' and the warning told the
        operator to define, on the Domains page, a domain that page cannot hold.
        A cloud client's own domain is a real row 0 there, so nothing changes off the
        mesh route (``domain_names_for_services`` -> ``implicit_own_domain``)."""
        out: list[str] = []
        for name in [self.wiz.cfg.effective_superdomain(),
                     *domain_names_for_services(self.wiz.cfg)]:
            if name and name not in out:
                out.append(name)
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
        self._sync_domain_tooltip(combo)

    def _sync_domain_tooltip(self, combo) -> None:
        """The cell's full text, '(not defined)' flag included, as its tooltip — a
        narrow column must never be the only place the flag could have been read."""
        text = combo.currentText()
        if text.endswith(_UNDEFINED):
            combo.setToolTip(f"{self._raw_domain(text)} is not defined on the Domains "
                             "page — define it there or pick a defined domain.")
        else:
            combo.setToolTip(text)

    def _fit_domain_column(self) -> None:
        """Widen the Domain column to its widest dropdown — every row's longest entry,
        '(not defined)' flag included. The default 100px section cut even the
        Tailscale root domain short ("hugmesh.inte"). Never narrows it: a column the
        operator dragged wider stays wide."""
        need = max((_combo_width_for(w) for w in (
            self.table.cellWidget(r, _COL_DOMAIN) for r in range(self.table.rowCount()))
            if isinstance(w, QtWidgets.QComboBox)), default=0)
        if need > self.table.columnWidth(_COL_DOMAIN):
            self.table.setColumnWidth(_COL_DOMAIN, need)

    def _apply_role_lock(self, dom_combo, role_cell):
        """superadmin belongs to the Tailscale root domain (spec 5): force + lock
        the domain there; a row without superadmin among its roles unlocks the
        dropdown. Multi-role (issue #228): superadmin ANYWHERE in the set locks —
        superadmin + games is still a superadmin."""
        if role_cell.has("superadmin"):
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

    def _add(self, username="", domain="", role="user", email="", registration="",
             handles=None):
        """``role`` is one role name OR an iterable of them (issue #228) — the
        single-string spelling every caller used before multi-role still works."""
        roles = [role] if isinstance(role, str) else list(role)
        r = self.table.rowCount()
        self.table.insertRow(r)
        self.table.setItem(r, _COL_USER, QtWidgets.QTableWidgetItem(username))
        dom_combo = QtWidgets.QComboBox()
        self._fill_domain_combo(dom_combo, domain)
        self.table.setCellWidget(r, _COL_DOMAIN, dom_combo)
        # the callback closes over role_cell (bound by the time a box is toggled)
        role_cell = RoleCell(
            roles, on_change=lambda: self._apply_role_lock(dom_combo, role_cell))
        self.table.setCellWidget(r, _COL_ROLE, role_cell)
        dom_combo.currentTextChanged.connect(
            lambda _t: (self._sync_domain_tooltip(dom_combo), self._update_warning()))
        self.table.setItem(r, _COL_EMAIL, QtWidgets.QTableWidgetItem(email))
        # per-user first-login registration method ("" -> the 'derive' default)
        reg_combo = QtWidgets.QComboBox()
        reg_combo.addItems(USER_REGISTRATION_CHOICES)
        reg_combo.setCurrentText(registration or "derive")
        reg_combo.currentTextChanged.connect(lambda _t: self._update_warning())
        self.table.setCellWidget(r, _COL_REG, reg_combo)
        for prov, col in _HANDLE_COLS.items():
            self.table.setItem(r, col, QtWidgets.QTableWidgetItem(
                str((handles or {}).get(prov) or "")))
        self.table.resizeColumnToContents(_COL_ROLE)
        self._apply_role_lock(dom_combo, role_cell)
        self._fit_domain_column()

    # ---- the selected row's other sign-in handles (#1107) -------------------------
    def _item_changed(self, item) -> None:
        if item is not None and item.row() == self.table.currentRow() \
                and item.column() in (_COL_USER, _COL_GOOGLE, _COL_DISCORD):
            self._load_handles(item.row())
        self._update_warning()

    def _load_handles(self, row: int) -> None:
        """Show row ``row``'s handles in the editor under the table (disabled, with
        nothing in it, when no row is selected)."""
        self._handles_loading = True
        try:
            ok = 0 <= row < self.table.rowCount()
            name = ""
            if ok:
                it = self.table.item(row, _COL_USER)
                name = it.text().strip() if it is not None else ""
            self.handles_for.setText(
                f"Other sign-ins for {name or 'this user'}:" if ok
                else "Other sign-ins (select a user):")
            for prov, edit in self.handle_edits.items():
                it = self.table.item(row, _HANDLE_COLS[prov]) if ok else None
                edit.setText(it.text() if it is not None else "")
                edit.setEnabled(ok)
        finally:
            self._handles_loading = False

    def _handle_edited(self, prov: str, text: str) -> None:
        """Typed in the editor: write the selected row's cell (the one store)."""
        if self._handles_loading:
            return
        row = self.table.currentRow()
        if not 0 <= row < self.table.rowCount():
            return
        col = _HANDLE_COLS[prov]
        it = self.table.item(row, col)
        if it is None:
            self.table.setItem(row, col, QtWidgets.QTableWidgetItem(text))
        else:
            it.setText(text)

    def _remove(self):
        for idx in sorted({i.row() for i in self.table.selectedIndexes()}, reverse=True):
            self.table.removeRow(idx)
        self._update_warning()

    def _update_warning(self):
        # each undefined domain ONCE, in row order: thirty rows on one domain are one
        # thing to define, not thirty.
        undef: list[str] = []
        for r in range(self.table.rowCount()):
            dom = self.table.cellWidget(r, _COL_DOMAIN)
            if isinstance(dom, QtWidgets.QComboBox) and dom.currentText().endswith(_UNDEFINED):
                name = self._raw_domain(dom.currentText())
                if name not in undef:
                    undef.append(name)
        lines = []
        if undef:
            lines.append(
                "Domain(s) not defined on the Domains page: " + ", ".join(undef) +
                " — define them there or pick a defined domain.")
        # #1107: a first-login registration through a provider with no handle for it
        for r in range(self.table.rowCount()):
            item = self.table.item(r, _COL_USER)
            reg = self.table.cellWidget(r, _COL_REG)
            hand = {}
            for prov, col in _HANDLE_COLS.items():
                it = self.table.item(r, col)
                hand[prov] = it.text().strip() if it is not None else ""
            u = User(username=item.text().strip() if item is not None else "",
                     registration=(reg.currentText() if isinstance(
                         reg, QtWidgets.QComboBox) else ""),
                     signin_handles={k: v for k, v in hand.items() if v})
            lines += [w[:1].upper() + w[1:] + "." for w in user_signin_handle_warnings(u)]
        self.warn.setText("\n".join(lines))
        self.warn.setVisible(bool(lines))

    def applies_to(self, cfg) -> bool:
        """Dynamic-skip predicate (wizard.nextId): a cloud NODE image emits no
        --person-role/--domains and writes no manifest, so the users table contributes
        nothing and is skipped (leaves the output unchanged).

        ASK 8 made the mesh arm conditional; ASK 20 gave it its OWN condition. The gate
        is no longer the domains opt-in (``superadmin_plane_applies``) but
        ``users_table_applies`` -> ``cfg.configure_users``, the answer to the users
        CHOICE screen that now precedes this one — because the two questions are
        genuinely independent: a mesh can host a second domain and still want the
        accounts gen-provision-keys.sh mints, and a single-domain mesh can still want a
        named superuser. The page is genuinely UNREACHABLE when the operator kept the
        generated accounts (the wizard skips the id; it is not a disabled table), and
        UsersChoicePage.validatePage clears cfg.users so nothing entered before the
        choice changed can reach the mesh manifest. Cloud client images are unchanged."""
        return users_table_applies(cfg)

    def initializePage(self):
        c = self.wiz.cfg
        if c is not self._cfg_seen:
            # A DIFFERENT configuration object (#542): Load config / Load session /
            # restart-from-session. Drop the previous flow's rows so the fill below
            # re-reads THIS configuration's users — otherwise validatePage writes the
            # old table back over cfg.users and the loaded accounts are gone.
            self.table.setRowCount(0)
            self._cfg_seen = c
        if self.table.rowCount() == 0:
            for u in c.users:
                self._add(u.username, u.domain, list(u.roles), u.email,
                          getattr(u, "registration", ""),
                          getattr(u, "signin_handles", None))
        else:
            # back-nav: newly-defined domains must appear in every row's dropdown, and
            # a superadmin lock re-pins to the current superdomain.
            for r in range(self.table.rowCount()):
                dom = self.table.cellWidget(r, _COL_DOMAIN)
                role_cell = self.table.cellWidget(r, _COL_ROLE)
                if isinstance(dom, QtWidgets.QComboBox):
                    self._fill_domain_combo(dom, self._raw_domain(dom.currentText()))
                    if isinstance(role_cell, RoleCell):
                        self._apply_role_lock(dom, role_cell)
            self._fit_domain_column()
        if self.table.rowCount() and self.table.currentRow() < 0:
            self.table.setCurrentCell(0, _COL_USER)
        self._load_handles(self.table.currentRow())
        self._update_warning()

    def forget_rows(self) -> None:
        """Drop the table: ``cfg.users`` was REPLACED under this page on the SAME
        object (the "Create nodes for local cloud" import, #707), which the identity
        check in ``initializePage`` cannot see. Until the page is entered again it
        writes nothing (``validatePage``) — ``collect_all()`` re-runs every visited
        page's validatePage, and an emptied table must not erase the import."""
        self.table.setRowCount(0)
        self._cfg_seen = None

    def validatePage(self):
        if self.wiz.cfg is not self._cfg_seen:
            return True                     # no table for THIS config yet: write nothing
        out = []
        problems: list[str] = []
        for r in range(self.table.rowCount()):
            username = self.table.item(r, _COL_USER).text().strip() if self.table.item(r, _COL_USER) else ""
            if not username:
                continue
            dom = self.table.cellWidget(r, _COL_DOMAIN)
            domain = self._raw_domain(dom.currentText()) if isinstance(dom, QtWidgets.QComboBox) else ""
            role_cell = self.table.cellWidget(r, _COL_ROLE)
            roles = role_cell.roles() if isinstance(role_cell, RoleCell) else ["user"]
            email = self.table.item(r, _COL_EMAIL).text().strip() if self.table.item(r, _COL_EMAIL) else ""
            reg_combo = self.table.cellWidget(r, _COL_REG)
            reg = reg_combo.currentText() if isinstance(reg_combo, QtWidgets.QComboBox) else "derive"
            registration = "" if reg == "derive" else reg
            # the other sign-in handles (#1107): every row is collected before any
            # refusal (the GUI-20 rule), and a bad handle refuses the page inline
            handles: dict[str, str] = {}
            for prov, col in _HANDLE_COLS.items():
                item = self.table.item(r, col)
                v = item.text().strip() if item is not None else ""
                problem = signin_handle_problem(prov, v)
                if problem:
                    problems.append(f"{username}: {problem}")
                handles[prov] = v
            user = User(username=username, domain=domain, roles=roles, email=email,
                        registration=registration,
                        signin_handles=clean_signin_handles(handles))
            out.append(user)
        if problems:
            self.handles_error.setText("Not saved: " + "; ".join(problems) + ".")
            self.handles_error.setVisible(True)
            return False
        self.handles_error.setVisible(False)
        c = self.wiz.cfg
        c.users = out
        return True
