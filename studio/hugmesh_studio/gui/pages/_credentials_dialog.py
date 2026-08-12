"""Seeded sign-in credentials — the dialog the Local-Docker-mesh page opens once a
mesh has been seeded, so the operator can actually LOG IN to what they just started.

The gap this closes (operator-reported): a from-scratch local mesh comes up, the
login page renders — and there is nothing on screen telling you which account to use.
The roster lives in tests/qemu/seed-accounts.sh, so learning it meant reading a shell
script. This shows it as a table with one-click copy.

The data comes from core/seeded_credentials.py (Qt-free, parses the seeder itself, so
the table cannot drift from what `make stack-seed` provisions). This module is the
Qt half ONLY: no parsing, no password precedence logic of its own.

These are deterministic THROWAWAY test credentials for a local stack — the same ones
the Makefile's stack-seed banner already prints in the clear. Nothing here is written
to disk or logged; the clipboard is only touched on an explicit click.
"""
from __future__ import annotations

from ..qt import Qt, QtWidgets
from ...core.seeded_credentials import Roster, as_copyable_text, suggested_signin

# "Opens" sits before "Roles" deliberately: it is the column that answers the
# operator's actual question. The raw ROLE_* strings are kept for the reader who
# needs them, but they are reference, not the answer.
_COLS = ("Username", "Password", "Opens", "Roles")


class CredentialsDialog(QtWidgets.QDialog):
    """A read-only, copyable view of the personas `make stack-seed` created.

    ``front_door`` (e.g. http://localhost:8088) is shown as the place to use them —
    without it the roster is trivia; with it the dialog is a complete instruction.
    """

    def __init__(self, roster: Roster, front_door: str = "", parent=None):
        super().__init__(parent)
        self.roster = roster
        self.setWindowTitle("Local mesh — sign-in credentials")
        self.setModal(True)
        self.resize(680, 460)

        v = QtWidgets.QVBoxLayout(self)

        if roster.error:
            # A roster we could not read must SAY so — a silently empty table would
            # read as "the seed made no users", which is a different (scarier) claim.
            warn = QtWidgets.QLabel(
                f"Could not read the seeded roster.\n\n{roster.error}\n\n"
                f"Looked in: {roster.source}")
            warn.setWordWrap(True)
            warn.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
            v.addWidget(warn)
            v.addWidget(self._buttons(copy_enabled=False))
            return

        lead = suggested_signin(roster)
        intro = QtWidgets.QLabel(
            (f"Sign in at <b>{front_door}/login</b> with any account below."
             if front_door else "Sign in with any account below.")
            + (f"<br>Start with <b>{lead.username}</b> / <b>{lead.password}</b>"
               if lead else ""))
        intro.setWordWrap(True)
        intro.setTextFormat(Qt.TextFormat.RichText)
        intro.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        v.addWidget(intro)

        self.table = QtWidgets.QTableWidget(len(roster.users), len(_COLS), self)
        self.table.setHorizontalHeaderLabels(list(_COLS))
        self.table.verticalHeader().setVisible(False)
        # Read-only, but SELECTABLE: the operator's muscle memory is select+Ctrl-C,
        # and the copy buttons are an accelerator for that, not a replacement.
        self.table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setSelectionBehavior(
            QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
        for row, u in enumerate(roster.users):
            cells = (u.username, u.password, u.apps_display, u.roles_display)
            for col, text in enumerate(cells):
                item = QtWidgets.QTableWidgetItem(text)
                # The operator account is the one to reach for; make it findable in a
                # 31-row table without hiding the rest.
                if roster.operator and u.username == roster.operator:
                    f = item.font(); f.setBold(True); item.setFont(f)
                self.table.setItem(row, col, item)
        hh = self.table.horizontalHeader()
        for c in (0, 1, 2):
            hh.setSectionResizeMode(c, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        hh.setSectionResizeMode(3, QtWidgets.QHeaderView.ResizeMode.Stretch)
        self.table.itemSelectionChanged.connect(self._sync_row_buttons)
        v.addWidget(self.table, 1)

        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        v.addWidget(self.status)
        v.addWidget(self._buttons(copy_enabled=True))
        self.table.selectRow(0)

    # ── buttons ────────────────────────────────────────────────────────────────
    def _buttons(self, copy_enabled: bool) -> QtWidgets.QWidget:
        box = QtWidgets.QWidget(self)
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        if copy_enabled:
            self.copy_user = QtWidgets.QPushButton("Copy username", box)
            self.copy_pass = QtWidgets.QPushButton("Copy password", box)
            self.copy_all = QtWidgets.QPushButton("Copy all", box)
            self.copy_user.clicked.connect(lambda: self._copy_cell(0, "username"))
            self.copy_pass.clicked.connect(lambda: self._copy_cell(1, "password"))
            self.copy_all.clicked.connect(self._copy_all)
            for b in (self.copy_user, self.copy_pass, self.copy_all):
                h.addWidget(b)
        h.addStretch(1)
        close = QtWidgets.QPushButton("Close", box)
        close.setDefault(True)
        close.clicked.connect(self.accept)
        h.addWidget(close)
        return box

    def _selected_row(self) -> int:
        rows = self.table.selectionModel().selectedRows() if self.table.selectionModel() else []
        if rows:
            return rows[0].row()
        return self.table.currentRow()

    def _sync_row_buttons(self) -> None:
        has = self._selected_row() >= 0
        for name in ("copy_user", "copy_pass"):
            b = getattr(self, name, None)
            if b is not None:
                b.setEnabled(has)

    def _set_clipboard(self, text: str) -> None:
        QtWidgets.QApplication.clipboard().setText(text)

    def _copy_cell(self, col: int, what: str) -> None:
        row = self._selected_row()
        if row < 0:
            self.status.setText(f"Select a row first to copy its {what}.")
            return
        item = self.table.item(row, col)
        if item is None:
            return
        self._set_clipboard(item.text())
        user = self.table.item(row, 0)
        self.status.setText(
            f"Copied {what} for {user.text() if user else 'the selected account'}.")

    def _copy_all(self) -> None:
        self._set_clipboard(as_copyable_text(self.roster))
        self.status.setText(
            f"Copied all {len(self.roster.users)} accounts (tab-separated).")
