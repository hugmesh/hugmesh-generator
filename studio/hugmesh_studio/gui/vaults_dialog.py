"""The Vaults & volumes manager — one dialog over a running mesh's durable state.

OPERATOR ASK (2026-08-14): "add a vaults management menu button and modal display menu
which lets a studio user who started a mesh locally or with qemu emulation manage
entries in vault and managed volumes".

Two tabs because the two subjects have genuinely different availability, and collapsing
them would misreport one of them (see core/vaults.py for the split):

* MANAGED VOLUMES exist the moment a local mesh is up and need no credential. This is
  where the mesh's durable state lives — every BFF's postgres, cassandra, the uploads —
  so the tab shows size and WHO HOLDS each volume, and the delete is deliberately hard
  to fire by accident.
* VAULT ENTRIES come from a cluster-lane service: vault-0 on the kind (DevOps) lane,
  read through `kubectl exec` (core/vaults.py picks the route). When it cannot be read —
  lane not up, lane halted, Vault sealed, no token — the tab renders the exact reason +
  remedy instead of an empty table. An empty table would read as "vault is running and
  has nothing in it", inviting an operator to add an entry that goes nowhere — the
  do-nothing-control trap this codebase keeps hitting.

TWO RULES INHERITED FROM EARLIER BUGS IN THIS TREE, both relied on:

1. EVERY docker call is off the GUI thread. `docker system df -v` alone can take tens of
   seconds on a large install and a hung daemon blocks for the full timeout; running
   that inline is precisely the freeze already fixed on the local-mesh and progress
   pages. The probe is owned via own_probe() so it is released rather than merely
   re-referenced (a probe still running when its page dies takes the Studio down).
2. NO NESTED MODAL for the destructive confirm. A QMessageBox.exec() nested inside a
   dialog hangs headless tests (see the no-modals-in-page-logic note), so the delete is
   gated by an INLINE acknowledgement the test can click: the operator types the volume's
   own name, which also makes a mis-click physically unable to delete the wrong row.
"""

from __future__ import annotations

from .qt import QtCore, QtWidgets, Signal
from ..core import vaults
from .pages._widgets import own_probe, probe_running

_COLS = ("Volume", "Size", "In use by", "Mount point")


class _VaultsProbe(QtCore.QThread):
    """Gather everything the dialog renders, off the GUI thread.

    One probe for BOTH tabs on purpose: they are read in the same breath, and two
    probes would double the hung-daemon exposure for no benefit. Never raises — an
    exception escaping run() would leave the dialog stuck on 'Loading…' forever."""

    result = Signal(object)          # (volumes, (vault_entries, vault_cap), docker_cap)

    def __init__(self, project: str, parent=None):
        super().__init__(parent)
        self._project = project

    def run(self):
        try:
            docker_cap = vaults.docker_available()
            vols = vaults.list_volumes(self._project) if docker_cap.available else []
            # The vault listing is a kubectl exec per folder — it runs HERE, never on the
            # GUI thread. Only entries + capability cross back: the route (which holds
            # the token) stays on this thread.
            route = vaults.vault_route(self._project)
            listing = vaults.list_entries(route=route)
            self.result.emit((vols, listing, docker_cap))
        except Exception as e:                       # noqa: BLE001 — never kill the dialog
            self.result.emit(([], ([], vaults.Capability(
                False, f"The vault probe failed: {type(e).__name__}: {e}",
                "Press Refresh; if it repeats, the Studio log has the traceback.")),
                vaults.Capability(False, "probe failed")))


def _blocker_label(cap: vaults.Capability) -> QtWidgets.QLabel:
    """The honest 'why not, and what to do' row. Selectable so the remedy's commands can
    be copied straight out, matching the device-table gate."""
    lab = QtWidgets.QLabel(f"{cap.detail}\n\n{cap.remedy}".strip())
    lab.setObjectName("vaultBlocker")
    lab.setWordWrap(True)
    lab.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
    lab.setStyleSheet("color: #a05000;")
    return lab


class VaultsDialog(QtWidgets.QDialog):
    """Manage the mesh's vault entries and managed volumes."""

    def __init__(self, parent=None, *, project: str = vaults.DEFAULT_PROJECT):
        super().__init__(parent)
        self._project = project
        self._volumes: list[vaults.ManagedVolume] = []
        self.vault_entries: list[vaults.VaultEntry] = []
        self.setWindowTitle("Vaults & managed volumes")
        self.resize(820, 520)

        outer = QtWidgets.QVBoxLayout(self)
        self.tabs = QtWidgets.QTabWidget()
        outer.addWidget(self.tabs, 1)

        # ── volumes tab ───────────────────────────────────────────────────────────
        vol_page = QtWidgets.QWidget()
        vl = QtWidgets.QVBoxLayout(vol_page)
        self.status = QtWidgets.QLabel("Loading…")
        self.status.setStyleSheet("color: gray;")
        vl.addWidget(self.status)
        self.table = QtWidgets.QTableWidget(0, len(_COLS))
        self.table.setHorizontalHeaderLabels(list(_COLS))
        self.table.verticalHeader().setVisible(False)
        self.table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setSelectionBehavior(
            QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.itemSelectionChanged.connect(self._sync_delete)
        vl.addWidget(self.table, 1)

        # DESTRUCTIVE ROW — inline, never a nested modal (see the module docstring).
        self.danger = QtWidgets.QLabel("")
        self.danger.setWordWrap(True)
        self.danger.setStyleSheet("color: #a05000;")
        vl.addWidget(self.danger)
        confirm_row = QtWidgets.QHBoxLayout()
        self.confirm = QtWidgets.QLineEdit()
        self.confirm.setPlaceholderText("type the volume name to enable Delete")
        self.confirm.textChanged.connect(self._sync_delete)
        self.delete_btn = QtWidgets.QPushButton("Delete volume")
        self.delete_btn.setEnabled(False)
        self.delete_btn.clicked.connect(self._delete_selected)
        confirm_row.addWidget(self.confirm, 1)
        confirm_row.addWidget(self.delete_btn)
        vl.addLayout(confirm_row)
        self.tabs.addTab(vol_page, "Managed volumes")

        # ── vault tab ─────────────────────────────────────────────────────────────
        self.vault_page = QtWidgets.QWidget()
        self.vault_layout = QtWidgets.QVBoxLayout(self.vault_page)
        self.vault_status = QtWidgets.QLabel("Loading…")
        self.vault_status.setStyleSheet("color: gray;")
        self.vault_layout.addWidget(self.vault_status)
        self.vault_layout.addStretch(1)
        self.tabs.addTab(self.vault_page, "Vault entries")

        # ── footer ────────────────────────────────────────────────────────────────
        foot = QtWidgets.QHBoxLayout()
        self.refresh_btn = QtWidgets.QPushButton("Refresh")
        self.refresh_btn.clicked.connect(self.refresh)
        close = QtWidgets.QPushButton("Close")
        close.clicked.connect(self.reject)
        foot.addWidget(self.refresh_btn)
        foot.addStretch(1)
        foot.addWidget(close)
        outer.addLayout(foot)

        self.refresh()

    # ---- probing ------------------------------------------------------------------
    def refresh(self) -> None:
        """Kick the off-thread probe. Re-entrant-safe: a probe in flight is left alone
        rather than stacking threads."""
        if probe_running(self, "_probe"):
            return
        self.status.setText("Loading…")
        self.refresh_btn.setEnabled(False)
        probe = own_probe(self, "_probe", _VaultsProbe(self._project, parent=self))
        probe.result.connect(self._on_probe)
        probe.start()

    def _on_probe(self, payload) -> None:
        volumes, (vault_entries, vault_cap), docker_cap = payload
        self.refresh_btn.setEnabled(True)
        self._volumes = list(volumes)
        if not docker_cap.available:
            self.status.setText(f"{docker_cap.detail} — {docker_cap.remedy}")
        else:
            total = sum(v.size_bytes or 0 for v in self._volumes)
            held = sum(1 for v in self._volumes if v.in_use)
            self.status.setText(
                f"{len(self._volumes)} volume(s) in project '{self._project}' · "
                f"{held} in use · {vaults.ManagedVolume('', '', '', size_bytes=total).human_size()} total")
        self._repopulate()
        self._render_vault(vault_entries, vault_cap)

    # ---- volumes ------------------------------------------------------------------
    def _repopulate(self) -> None:
        self.table.setRowCount(len(self._volumes))
        for i, v in enumerate(self._volumes):
            self.table.setItem(i, 0, QtWidgets.QTableWidgetItem(v.short))
            self.table.setItem(i, 1, QtWidgets.QTableWidgetItem(v.human_size()))
            self.table.setItem(i, 2, QtWidgets.QTableWidgetItem(
                ", ".join(v.in_use_by) if v.in_use_by else "—"))
            self.table.setItem(i, 3, QtWidgets.QTableWidgetItem(v.mountpoint))
        self.table.resizeColumnsToContents()
        self._sync_delete()

    def selected_volume(self) -> vaults.ManagedVolume | None:
        rows = {i.row() for i in self.table.selectedIndexes()}
        if len(rows) != 1:
            return None
        row = rows.pop()
        return self._volumes[row] if 0 <= row < len(self._volumes) else None

    def _sync_delete(self) -> None:
        """Delete is armed only by an EXACT name match on the selected row.

        Typing the name is the acknowledgement (no nested modal), and because the typed
        text must match the SELECTED volume, a mis-click onto a different row disarms the
        button instead of retargeting a confirmed deletion at the wrong data."""
        vol = self.selected_volume()
        if vol is None:
            self.danger.setText("")
            self.delete_btn.setEnabled(False)
            return
        if vol.in_use:
            self.danger.setText(
                f"'{vol.short}' is in use by {', '.join(vol.in_use_by)} — stop the mesh "
                f"before deleting it.")
            self.delete_btn.setEnabled(False)
            return
        self.danger.setText(
            f"Deleting '{vol.short}' destroys its data permanently. No rebuild restores "
            f"it. Type the volume name below to confirm.")
        self.delete_btn.setEnabled(self.confirm.text().strip() == vol.short)

    def _delete_selected(self) -> None:
        vol = self.selected_volume()
        if vol is None or self.confirm.text().strip() != vol.short:
            return                                   # cannot happen via the UI; belt-and-braces
        cap = vaults.remove_volume(vol, confirm=True)
        self.danger.setText(cap.detail if cap.available
                            else f"{cap.detail} — {cap.remedy}")
        self.confirm.clear()
        self.refresh()

    # ---- vault --------------------------------------------------------------------
    def _render_vault(self, entries, cap: vaults.Capability) -> None:
        """Render what the probe already fetched. NOTHING here may block: the listing
        is a kubectl exec per folder and used to run right here, on the GUI thread."""
        while self.vault_layout.count():
            item = self.vault_layout.takeAt(0)
            w = item.widget()
            if w is not None:
                w.setParent(None)
        self.vault_entries = list(entries)
        if not cap.available:
            # NOT an empty table — see the module docstring.
            head = QtWidgets.QLabel("Vault entries cannot be shown:")
            head.setStyleSheet("font-weight: bold;")
            self.vault_layout.addWidget(head)
            self.vault_layout.addWidget(_blocker_label(cap))
            self.vault_layout.addStretch(1)
            return
        if entries:
            summary = (f"{len(entries)} entry path(s) — {cap.detail}. Values are never "
                       f"listed here.")
        else:
            summary = (f"Vault is running and has NO entries under {vaults.KV_MOUNT}/ — "
                       f"{cap.detail}.")
        lab = QtWidgets.QLabel(summary)
        lab.setObjectName("vaultSummary")
        lab.setWordWrap(True)
        lab.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        self.vault_layout.addWidget(lab)
        if not entries:
            self.vault_layout.addStretch(1)
            return
        lst = QtWidgets.QListWidget()
        lst.setObjectName("vaultEntries")
        for e in entries:
            lst.addItem(e.path)
        self.vault_layout.addWidget(lst, 1)

    # ---- lifecycle ----------------------------------------------------------------
    def closeEvent(self, event):                     # noqa: N802 — Qt contract
        """Never leave the probe running past the dialog: it is parented here, and a
        QThread still running when its parent is destroyed aborts the Studio."""
        probe = getattr(self, "_probe", None)
        if probe is not None:
            try:
                if probe.isRunning():
                    probe.wait(3000)
            except RuntimeError:
                pass
        super().closeEvent(event)
