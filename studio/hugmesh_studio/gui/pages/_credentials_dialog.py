"""Seeded sign-in credentials — the dialog the Local-Docker-mesh page opens so the
operator can actually LOG IN to what they just started.

The gap this closes (operator-reported): a from-scratch local mesh comes up, the
login page renders — and there is nothing on screen telling you which account to use.
The roster lives in tests/qemu/seed-accounts.sh, so learning it meant reading a shell
script. This shows it as a table with one-click copy.

The data comes from core/seeded_credentials.py (Qt-free, parses the seeder itself, so
the table cannot drift from what `make stack-seed` provisions) joined with
core/credentials_truth.py (Qt-free, asks the RUNNING mesh what is actually seeded).
This module is the Qt half ONLY: no parsing, no password precedence, no state
machine of its own.

WHAT THE PASSWORDS ARE. They are GENERATED per run by tests/stack/e2e-password.sh (a
CSPRNG value, never a fixed literal) and read here from the run-state file that
script writes — plus the superadmin MINTED into keys-out/vault/secrets.json by the
Studio's own bring-up. Nothing here can prove a shown value opens the running mesh
unless a seed completed after it was written, so the banner and the Live column mark
every row live / stale / halted / not seeded / not on this lane / unverified /
unknown, and the "Start with …" lead is shown ONLY when the mesh is proven seeded.
Nothing is written to disk or logged; the clipboard is only touched on an explicit
click.
"""
from __future__ import annotations

from ..qt import Qt, QtWidgets
from ...core import credentials_truth as _truth
from ...core.credentials_truth import CredentialTruth
from ...core.seeded_credentials import Roster, as_copyable_text, suggested_signin
# The banner colours are progress.py's stage palette, imported rather than
# re-declared: green means exactly what the build screen's green means.
from .progress import _STAGE_GLYPH

# "Live" sits between the credential and what it opens: it is the column that says
# whether the row is TRUE of the running mesh, which is the question the whole
# banner exists to answer. "Opens" stays before "Roles" (the operator's actual
# question; raw ROLE_* strings are reference, not the answer).
_COLS = ("Username", "Password", "Live", "Opens", "Roles")
COL_USER, COL_PASSWORD, COL_LIVE, COL_OPENS, COL_ROLES = range(len(_COLS))

# state -> banner colour. ONE positive state is green; the two the operator must
# act on are red; everything unproven is grey (unknown is not "no").
_BANNER_COLOUR = {
    _truth.STATE_SEEDED: _STAGE_GLYPH["done"][1],
    _truth.STATE_SEEDED_SUSPECT: _STAGE_GLYPH["failed"][1],
    _truth.STATE_UNREADABLE: _STAGE_GLYPH["failed"][1],
}
_BANNER_DEFAULT = _STAGE_GLYPH["pending"][1]


def banner_colour(state: str) -> str:
    return _BANNER_COLOUR.get(state, _BANNER_DEFAULT)


class CredentialsDialog(QtWidgets.QDialog):
    """A read-only, copyable view of the personas the seeder created — marked
    against the mesh that is running.

    ``truth`` (a CredentialTruth) drives the banner and the lead line; without it
    (legacy call sites) the roster renders unassessed and no lead is offered, since
    nothing has vouched for any row. ``front_door`` (e.g. https://localhost:8488) is
    where to use them — without it the roster is trivia.
    """

    def __init__(self, roster: Roster, truth: CredentialTruth | None = None,
                 front_door: str = "", parent=None):
        super().__init__(parent)
        self.roster = roster
        self.truth = truth if truth is not None else roster.truth
        self.setWindowTitle("Local mesh — sign-in credentials")
        self.setModal(True)
        self.resize(760, 480)

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

        truth = self.truth
        # THE BANNER: one sentence about whether what follows is true of the mesh
        # that is running, coloured by state, with the longer reason (and the fix)
        # in its tooltip. Password-free by core contract.
        self.banner = QtWidgets.QLabel(
            truth.headline if truth is not None else
            "Not checked against a running mesh — this is the seeder's roster.")
        self.banner.setWordWrap(True)
        self.banner.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        colour = banner_colour(truth.state) if truth is not None else _BANNER_DEFAULT
        self.banner.setStyleSheet(f"color: {colour}; font-weight: bold;")
        if truth is not None:
            self.banner.setToolTip(truth.detail)
        v.addWidget(self.banner)
        if truth is not None:
            f = truth.file
            src = (f"Read {f.path} (written {f.written})." if f.exists and f.readable
                   else (f"{f.path}: {f.error}." if f.exists
                         else f"No run-state credentials file at {f.path or '(no path)'}."))
            self.source_line = QtWidgets.QLabel(
                f"{src} Checked {truth.checked_at}"
                + (f"; last completed seed {truth.seeded_at}." if truth.seeded_at
                   else "; no completed seed recorded by this Studio."))
            self.source_line.setWordWrap(True)
            self.source_line.setStyleSheet("color: gray;")
            self.source_line.setTextInteractionFlags(
                Qt.TextInteractionFlag.TextSelectableByMouse)
            v.addWidget(self.source_line)

        # The "Start with X / Y" lead ONLY when the mesh is proven seeded. Leading
        # with a credential nothing can vouch for is the bug this dialog used to have.
        lead = suggested_signin(roster) if (truth is not None and truth.verified) else None
        where = (f"Sign in at <b>{front_door}/login</b>" if front_door else "Sign in")
        if lead is not None:
            intro_text = (f"{where} with any account marked live below.<br>"
                          f"Start with <b>{lead.username}</b> / <b>{lead.password}</b>")
        elif truth is not None and truth.state in (
                _truth.STATE_NO_MESH, _truth.STATE_UP_UNSEEDED,
                _truth.STATE_MINTED_NOT_SEEDED):
            intro_text = ("The accounts below are what a seed CREATES; none of them "
                          "can sign in anywhere right now.")
        else:
            intro_text = (f"{where} once the banner above says seeded; the Live "
                          "column says what is known about each row.")
        self.intro = QtWidgets.QLabel(intro_text)
        self.intro.setWordWrap(True)
        self.intro.setTextFormat(Qt.TextFormat.RichText)
        self.intro.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        v.addWidget(self.intro)

        self.table = QtWidgets.QTableWidget(len(roster.users), len(_COLS), self)
        self.table.setHorizontalHeaderLabels(list(_COLS))
        self.table.verticalHeader().setVisible(False)
        # Read-only, but SELECTABLE: the operator's muscle memory is select+Ctrl-C,
        # and the copy buttons are an accelerator for that, not a replacement.
        self.table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setSelectionBehavior(
            QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
        for row, u in enumerate(roster.users):
            cells = (u.username, u.password, u.live or "—", u.apps_display,
                     u.roles_display)
            # The operator account is the one to reach for; make it findable in a
            # 31-row table without hiding the rest — unless the assessment says it
            # is not there, in which case bold would be a lie in a bigger font.
            featured = (roster.operator and u.username == roster.operator
                        and u.live not in (_truth.NOT_ON_LANE, _truth.NOT_SEEDED))
            for col, text in enumerate(cells):
                item = QtWidgets.QTableWidgetItem(text)
                if featured:
                    f = item.font(); f.setBold(True); item.setFont(f)
                if col == COL_LIVE and u.note:
                    item.setToolTip(u.note)
                self.table.setItem(row, col, item)
        hh = self.table.horizontalHeader()
        for c in (COL_USER, COL_PASSWORD, COL_LIVE, COL_OPENS):
            hh.setSectionResizeMode(c, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        hh.setSectionResizeMode(COL_ROLES, QtWidgets.QHeaderView.ResizeMode.Stretch)
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
            self.copy_user.clicked.connect(lambda: self._copy_cell(COL_USER, "username"))
            self.copy_pass.clicked.connect(lambda: self._copy_cell(COL_PASSWORD, "password"))
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
        user = self.table.item(row, COL_USER)
        self.status.setText(
            f"Copied {what} for {user.text() if user else 'the selected account'}.")

    def _copy_all(self) -> None:
        self._set_clipboard(as_copyable_text(self.roster))
        self.status.setText(
            f"Copied all {len(self.roster.users)} accounts (tab-separated).")
