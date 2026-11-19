"""The Brand settings screen's Users tab — one domain's people (2026-11-19).

The operator: "users should be creatable and assignable by domain in another tab after
identity in the domain configuration and adding users should work without the e2e
scripts". Two halves, each with one editing home:

* PLANNED PEOPLE — the image wizard's ``cfg.users`` rows whose domain is this one
  (``BrandView.people``). Adding one here assigns it to this domain; the Users step's
  table is the same list, seen for every domain at once. A route that keeps no list
  (the Docker mesh, the fleet) says so instead.
* ON THE MESH RUNNING ON THIS COMPUTER — the accounts in the Casdoor this domain signs
  in through, listed (on Refresh, never just by opening the tab) and created by ``core.mesh_accounts`` straight through Casdoor's
  admin API: no ``make stack-seed``, no seeder script, no shared e2e password. A
  password left empty is generated and shown once, here, selectable; it is never
  stored or logged.

No modal anywhere; every refusal is a line under the control that caused it; slots
never raise. The network calls run on a worker thread.
"""
from __future__ import annotations

import html
import os
import sys
import traceback

from ..qt import QtCore, QtWidgets, Signal
from ...core import mesh_accounts

__all__ = ["PeopleTab"]

_MUTED = "color: gray;"
_WARN = "color: #a65d00;"
_PUBLIC_HTTPS_PORT = 8488
_FRONT_DOOR_CA = os.path.join("tests", "stack", ".tls-front", "ca.crt")


def _swallowed(where: str) -> None:
    print(f"_people_tab: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


def _label(text: str = "", *, name: str = "", style: str = "") -> QtWidgets.QLabel:
    lab = QtWidgets.QLabel(text)
    lab.setWordWrap(True)
    lab.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
    if name:
        lab.setObjectName(name)
    if style:
        lab.setStyleSheet(style)
    return lab


def _table(name: str, headers) -> QtWidgets.QTableWidget:
    t = QtWidgets.QTableWidget(0, len(headers))
    t.setObjectName(name)
    t.setHorizontalHeaderLabels(list(headers))
    t.verticalHeader().setVisible(False)
    t.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
    t.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
    t.setSelectionMode(QtWidgets.QAbstractItemView.SelectionMode.SingleSelection)
    t.horizontalHeader().setStretchLastSection(True)
    t.setMinimumHeight(110)
    t.setMaximumHeight(190)
    return t


def _fill(t: QtWidgets.QTableWidget, rows) -> None:
    t.setRowCount(0)
    for r, cells in enumerate(rows):
        t.insertRow(r)
        for c, text in enumerate(cells):
            t.setItem(r, c, QtWidgets.QTableWidgetItem(str(text)))
    t.resizeColumnsToContents()


class _Worker(QtCore.QThread):
    """One blocking core call off the GUI thread; never raises out of run()."""
    result = Signal(object)

    def __init__(self, fn):
        super().__init__()
        self._fn = fn

    def run(self):
        try:
            self.result.emit(self._fn())
        except Exception as exc:                # noqa: BLE001 — shown inline
            self.result.emit(mesh_accounts.Outcome(False, f"{type(exc).__name__}: {exc}"))


class PeopleTab(QtWidgets.QWidget):
    """The Users tab's page. ``set_view(view)`` shows one domain (a BrandView)."""

    #: the planned list changed (the host tells the Users step its rows moved)
    people_changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("brand_tab_users")
        self.view = None
        self._worker: _Worker | None = None
        self._listed_for = None
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(6, 6, 6, 6)

        # ── planned people ─────────────────────────────────────────────────────────
        self.plan_box = QtWidgets.QGroupBox("People planned for this domain")
        self.plan_box.setObjectName("brand_people_box")
        pl = QtWidgets.QVBoxLayout(self.plan_box)
        self.plan_note = _label(name="brand_people_note", style=_MUTED)
        pl.addWidget(self.plan_note)
        self.plan_table = _table("brand_people_table", ("User", "Roles", "Email"))
        pl.addWidget(self.plan_table)
        form = QtWidgets.QHBoxLayout()
        form.setContentsMargins(0, 0, 0, 0)
        self.plan_name = QtWidgets.QLineEdit()
        self.plan_name.setObjectName("brand_people_name")
        self.plan_name.setPlaceholderText("user name")
        self.plan_email = QtWidgets.QLineEdit()
        self.plan_email.setObjectName("brand_people_email")
        self.plan_email.setPlaceholderText("email (optional)")
        form.addWidget(self.plan_name, 1)
        form.addWidget(self.plan_email, 1)
        pl.addLayout(form)
        self.plan_roles_row = QtWidgets.QWidget()
        self.plan_roles_row.setObjectName("brand_people_roles")
        _rl = QtWidgets.QHBoxLayout(self.plan_roles_row)
        _rl.setContentsMargins(0, 0, 0, 0)
        _rl.setAlignment(QtCore.Qt.AlignmentFlag.AlignLeft)
        pl.addWidget(self.plan_roles_row)
        self.plan_role_boxes: dict[str, QtWidgets.QCheckBox] = {}
        btns = QtWidgets.QHBoxLayout()
        btns.setContentsMargins(0, 0, 0, 0)
        self.plan_add = QtWidgets.QPushButton("Add to this domain")
        self.plan_add.setObjectName("brand_people_add")
        self.plan_add.setMinimumHeight(28)
        self.plan_add.clicked.connect(self._plan_add_clicked)
        self.plan_remove = QtWidgets.QPushButton("Remove selected")
        self.plan_remove.setObjectName("brand_people_remove")
        self.plan_remove.setMinimumHeight(28)
        self.plan_remove.clicked.connect(self._plan_remove_clicked)
        btns.addWidget(self.plan_add)
        btns.addWidget(self.plan_remove)
        btns.addStretch(1)
        pl.addLayout(btns)
        self.plan_msg = _label(name="brand_people_msg")
        pl.addWidget(self.plan_msg)
        lay.addWidget(self.plan_box)
        self.plan_refusal = _label(name="brand_people_refusal", style=_MUTED)
        lay.addWidget(self.plan_refusal)

        # ── the running mesh ───────────────────────────────────────────────────────
        self.live_box = QtWidgets.QGroupBox("On the mesh running on this computer")
        self.live_box.setObjectName("brand_live_box")
        ll = QtWidgets.QVBoxLayout(self.live_box)
        self.live_where = _label(name="brand_live_where")
        ll.addWidget(self.live_where)
        self.live_table = _table("brand_live_table", ("Account", "Roles", "Email"))
        ll.addWidget(self.live_table)
        top = QtWidgets.QHBoxLayout()
        top.setContentsMargins(0, 0, 0, 0)
        self.live_refresh = QtWidgets.QPushButton("Refresh")
        self.live_refresh.setObjectName("brand_live_refresh")
        self.live_refresh.setMinimumHeight(28)
        self.live_refresh.clicked.connect(self.refresh_live)
        top.addWidget(self.live_refresh)
        self.live_state = _label(name="brand_live_state", style=_MUTED)
        top.addWidget(self.live_state, 1)
        ll.addLayout(top)
        lf = QtWidgets.QHBoxLayout()
        lf.setContentsMargins(0, 0, 0, 0)
        self.live_name = QtWidgets.QLineEdit()
        self.live_name.setObjectName("brand_live_name")
        self.live_name.setPlaceholderText("user name")
        self.live_email = QtWidgets.QLineEdit()
        self.live_email.setObjectName("brand_live_email")
        self.live_email.setPlaceholderText("email (optional)")
        self.live_password = QtWidgets.QLineEdit()
        self.live_password.setObjectName("brand_live_password")
        self.live_password.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.live_password.setPlaceholderText("password (empty: one is made for you)")
        for w in (self.live_name, self.live_email, self.live_password):
            lf.addWidget(w, 1)
        ll.addLayout(lf)
        roles_row = QtWidgets.QWidget()
        roles_row.setObjectName("brand_live_roles")
        grid = QtWidgets.QGridLayout(roles_row)
        grid.setContentsMargins(0, 0, 0, 0)
        self.live_role_boxes: dict[str, QtWidgets.QCheckBox] = {}
        for i, role in enumerate(mesh_accounts.GRANTABLE_ROLES):
            box = QtWidgets.QCheckBox(role[len("ROLE_"):].replace("_", " ").lower())
            box.setObjectName(f"brand_live_role_{role}")
            box.setToolTip(f"{role}: {mesh_accounts.ROLE_WORDS.get(role, '')}")
            if role == mesh_accounts.FLOOR_ROLE:
                box.setChecked(True)
                box.setEnabled(False)       # the gateway floor: every account has it
            grid.addWidget(box, i // 5, i % 5)
            self.live_role_boxes[role] = box
        ll.addWidget(roles_row)
        self.live_register = QtWidgets.QCheckBox(
            "Finish the account's registration now (otherwise the person finishes it "
            "at first sign-in)")
        self.live_register.setObjectName("brand_live_register")
        self.live_register.setChecked(True)
        ll.addWidget(self.live_register)
        cr = QtWidgets.QHBoxLayout()
        cr.setContentsMargins(0, 0, 0, 0)
        self.live_create = QtWidgets.QPushButton("Create account")
        self.live_create.setObjectName("brand_live_create")
        self.live_create.setMinimumHeight(28)
        self.live_create.clicked.connect(self._live_create_clicked)
        cr.addWidget(self.live_create)
        cr.addStretch(1)
        ll.addLayout(cr)
        self.live_msg = _label(name="brand_live_msg")
        ll.addWidget(self.live_msg)
        lay.addWidget(self.live_box)
        lay.addStretch(1)
        self.set_view(None)

    # ── the domain on screen ─────────────────────────────────────────────────────────
    def set_view(self, view) -> None:
        try:
            changed = view is not self.view
            self.view = view
            self._fill_plan()
            self._fill_live_where()
            if changed:
                self._listed_for = None
                self.plan_msg.setText("")
                self.live_msg.setText("")
                _fill(self.live_table, [])
                self.live_state.setText("")
        except Exception:                       # noqa: BLE001 — PyQt6 qFatal guard
            _swallowed("set_view")

    def shown(self) -> None:
        """The tab was opened. It does NOT sign in to list the accounts by itself: a
        Studio run from another checkout holds a different admin password, and every
        refused admin sign-in counts toward Casdoor's throttle on the running mesh.
        Refresh (or a create) reads them."""
        try:
            if (self.view is not None and self.live_box.isVisible()
                    and self._listed_for is not self.view and self._worker is None):
                self.live_state.setStyleSheet(_MUTED)
                self.live_state.setText("Press Refresh to read this domain's accounts.")
        except Exception:                       # noqa: BLE001
            _swallowed("shown")

    def _fill_plan(self) -> None:
        v = self.view
        refusal = v.people_refusal() if v is not None else ""
        self.plan_box.setVisible(v is not None and not refusal)
        self.plan_refusal.setVisible(bool(refusal))
        self.plan_refusal.setText(refusal)
        if v is None or refusal:
            return
        self.plan_box.setTitle(f"People planned for {v.name}")
        self.plan_note.setText(v.people_note())
        _fill(self.plan_table, [(u.username, ", ".join(u.roles), u.email)
                                for u in v.people()])
        want = v.person_roles()
        if tuple(self.plan_role_boxes) != want:
            lay = self.plan_roles_row.layout()
            for box in self.plan_role_boxes.values():
                lay.removeWidget(box)
                box.deleteLater()
            self.plan_role_boxes = {}
            for role in want:
                box = QtWidgets.QCheckBox(role)
                box.setObjectName(f"brand_people_role_{role}")
                lay.addWidget(box)
                self.plan_role_boxes[role] = box
        self.plan_remove.setEnabled(self.plan_table.rowCount() > 0)

    def _target(self):
        if self.view is None or not self.view.live_offered():
            return None, ""
        return self.view.live_target()

    def _fill_live_where(self) -> None:
        offered = self.view is not None and self.view.live_offered()
        self.live_box.setVisible(offered)
        if not offered:
            return
        target, why = self._target()
        self.live_where.setStyleSheet("" if target else _WARN)
        self.live_where.setText(f"Accounts go to {target.words}." if target else why)
        for w in (self.live_table, self.live_refresh, self.live_name, self.live_email,
                  self.live_password, self.live_create, self.live_register):
            w.setEnabled(target is not None and self._worker is None)
        for role, box in self.live_role_boxes.items():
            box.setEnabled(target is not None and role != mesh_accounts.FLOOR_ROLE)
        # registration stage 2 goes through the mesh's front door, which serves the
        # central sign-in; a domain's own Casdoor is reached by its own host name
        self.live_register.setVisible(bool(target and target.central))

    # ── planned people ─────────────────────────────────────────────────────────────
    def _plan_add_clicked(self) -> None:
        try:
            if self.view is None:
                return
            roles = [r for r, b in self.plan_role_boxes.items() if b.isChecked()]
            name = self.plan_name.text().strip()
            problems = self.view.add_person(name, roles, self.plan_email.text())
            if problems:
                self.plan_msg.setStyleSheet(_WARN)
                self.plan_msg.setText("Not added: " + " ".join(problems))
                return
            self.plan_msg.setStyleSheet("")
            self.plan_msg.setText(f"{name} is a planned person of {self.view.name}.")
            self.plan_name.clear()
            self.plan_email.clear()
            for b in self.plan_role_boxes.values():
                b.setChecked(False)
            self._fill_plan()
            self.people_changed.emit()
        except Exception:                       # noqa: BLE001
            _swallowed("_plan_add_clicked")

    def _plan_remove_clicked(self) -> None:
        try:
            if self.view is None:
                return
            row = self.plan_table.currentRow()
            item = self.plan_table.item(row, 0) if row >= 0 else None
            if item is None:
                self.plan_msg.setStyleSheet(_WARN)
                self.plan_msg.setText("Pick a person in the list first.")
                return
            name = item.text()
            problems = self.view.remove_person(name)
            self.plan_msg.setStyleSheet(_WARN if problems else "")
            self.plan_msg.setText(("Not removed: " + problems[0]) if problems
                                  else f"{name} is no longer planned for {self.view.name}.")
            self._fill_plan()
            if not problems:
                self.people_changed.emit()
        except Exception:                       # noqa: BLE001
            _swallowed("_plan_remove_clicked")

    # ── the running mesh ───────────────────────────────────────────────────────────
    def _generator_dir(self) -> str:
        return getattr(getattr(self.view.session, "host", None), "generator_dir", "") or ""

    def _run(self, fn, done, busy: str) -> None:
        if self._worker is not None:
            return
        self.live_state.setText(busy)
        w = _Worker(fn)
        self._worker = w
        self._fill_live_where()

        def finished(out, _w=w):
            try:
                self._worker = None
                self._fill_live_where()
                done(out)
            except Exception:                   # noqa: BLE001
                _swallowed("worker result")
            _w.deleteLater()

        w.result.connect(finished)
        w.start()

    def busy(self) -> bool:
        return self._worker is not None

    def wait(self, ms: int = 30000) -> None:
        """Tests: let a running worker finish and its result land."""
        w = self._worker
        if w is not None:
            w.wait(ms)
            QtCore.QCoreApplication.processEvents()

    def refresh_live(self) -> None:
        try:
            target, why = self._target()
            if target is None:
                return
            view = self.view
            self._listed_for = view
            gd = self._generator_dir()

            def done(out):
                if self.view is not view:
                    return
                if not out.ok:
                    self.live_state.setText(out.message)
                    self.live_state.setStyleSheet(_WARN)
                    _fill(self.live_table, [])
                    return
                mine = [a for a in out.accounts
                        if not target.central or a.domain == view.name
                        or (view.own and not a.domain)]
                self.live_state.setStyleSheet(_MUTED)
                self.live_state.setText(
                    f"{len(mine)} account{'s' if len(mine) != 1 else ''} for {view.name}"
                    + ("" if not target.central else
                       f" ({len(out.accounts)} on the central sign-in in all)"))
                _fill(self.live_table, [(a.name, ", ".join(a.roles), a.email)
                                        for a in mine])

            self._run(lambda: mesh_accounts.list_accounts(target, gd), done,
                      "Reading the accounts …")
        except Exception:                       # noqa: BLE001
            _swallowed("refresh_live")

    def _live_create_clicked(self) -> None:
        try:
            target, why = self._target()
            if target is None:
                self.live_msg.setStyleSheet(_WARN)
                self.live_msg.setText(why)
                return
            name = self.live_name.text().strip()
            password = self.live_password.text()
            email = self.live_email.text().strip()
            problem = mesh_accounts.username_problem(name) or (
                mesh_accounts.password_problem(password) if password else "")
            if problem:
                self.live_msg.setStyleSheet(_WARN)
                self.live_msg.setText("Not created: " + problem)
                return
            roles = [r for r, b in self.live_role_boxes.items() if b.isChecked()]
            register = self.live_register.isChecked() and target.central
            gd = self._generator_dir()
            ca = os.path.join(gd, _FRONT_DOOR_CA)
            port = os.environ.get("PUBLIC_HTTPS_PORT") or _PUBLIC_HTTPS_PORT

            def work():
                out = mesh_accounts.create_account(target, gd, name, password, roles,
                                                   email=email)
                if out.ok and register:
                    _done, words = mesh_accounts.complete_registration(
                        f"https://localhost:{port}", name, password or out.password,
                        cafile=ca if os.path.exists(ca) else "")
                    out.message += f" Registration: {words}."
                return out

            def done(out):
                self.live_msg.setStyleSheet("" if out.ok else _WARN)
                text = html.escape(out.message if out.ok else "Not created: " + out.message)
                if out.ok and out.password:
                    text += ("<br><b>Password, shown this once</b> (hand it to the "
                             f"person; it is not kept anywhere): <code>"
                             f"{html.escape(out.password)}</code>")
                self.live_msg.setText(text)
                if out.ok:
                    self.live_name.clear()
                    self.live_email.clear()
                    self.live_password.clear()
                    self._listed_for = None
                    self.refresh_live()

            self.live_msg.setText("")
            self._run(work, done, f"Creating {name} …")
        except Exception:                       # noqa: BLE001
            _swallowed("_live_create_clicked")
