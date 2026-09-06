"""MeshMonitorWidget — the running-mesh table on the local-mesh page: every pod and
container, its in-mesh and external addresses, and an Open button ONLY where the
browser may safely go.

This is the CONTENT widget of a ``collapsible(...)`` section, so it is the thing that
gets greyed: the page wraps it (collapsed by default) and drives ``setEnabled`` on it
from ONE place, ``LocalMeshPage._sync_monitor_gate``. It performs no I/O and starts no
thread — the page owns the probe, the timer and the browser; this widget only renders
a ``core.mesh_monitor.MonitorSnapshot`` and emits what the operator pressed.

TWO RENDERING RULES that a timed repaint makes load-bearing:

* Cells are written with ``set_cell`` (``_emulation_common``), which REUSES the item, so
  a 10 s repaint keeps the selection and the scroll anchor under the cursor. Rows are
  keyed ``lane/namespace/name`` and sorted, so a repaint never reorders them either.
* THE WIDGET/ITEM MUTUAL-EXCLUSION RULE for the Open column. A cell carries EITHER a
  QPushButton (``setCellWidget``) OR an item (a dash whose tooltip says why there is no
  door). A row that GAINS a door across refreshes must have its item taken out before
  the button goes in, and one that LOSES a door must have the button removed before the
  dash is written — otherwise a stale button sits beside a stale dash. Buttons are
  cached per row key and only recreated when that row's door URL changed.

Colours come from progress.py's ``_STATUS_GLYPH`` palette — never a second catalogue
(that module's own rule): a green row here means what a green stage means there.

The HSTS ban is enforced HERE too (``unsafe_door_reason``), not only in core: a Door
whose URL the ban refuses is rendered as a blocked dash carrying the reason, so no
code path can put a pinnable hostname behind a button.
"""
from __future__ import annotations

from ..qt import Qt, QtCore, QtWidgets, Signal
from ..flow_layout import flow_box
from ...core import mesh_monitor
from ...core.mesh_monitor import MonitorSnapshot, unsafe_door_reason
from ._emulation_common import make_table, set_cell
from .progress import _STATUS_GLYPH

# Symbolic column indices only (this page's own rule) — a test names the column it
# reads, and inserting one stays a one-line change.
_MON_COL_NAME, _MON_COL_LANE, _MON_COL_STATE, _MON_COL_K8S, _MON_COL_EXT, _MON_COL_OPEN = \
    range(6)
_MON_HEADERS = ("Pod / container", "Lane", "State", "Kubernetes / compose address",
                "External address", "Open")

_DASH = "—"
_GREY = "#888888"

# The four view-door tooltips, named once so set_view_session can write BOTH buttons
# in BOTH of its branches (see the note there).
_VIEW_UP_TIP = (
    "Run `make view` in the background: serves the kind front doors as HTTPS on "
    "127.0.0.1:90xx under this machine's loopback-only CA, so the browser never "
    "meets the ingress's fake certificate or its HSTS pin. Binds loopback ports "
    "on this machine — one press, never automatic. Run `make view-trust` once "
    "per machine or the browser still warns.")
#: `{which}` = "the kind lane's doors" / "its lane's doors" (see set_view_session).
#: It names the LANE because the session can outlive what it served: a kind-lane
#: session left running after the cluster was deleted still holds the ports while
#: the compose mesh runs beside it — and compose rows never go through it.
_VIEW_UP_LIVE_TIP = ("A `make view` session is already serving {which} on 127.0.0.1. "
                     "A kind row's Open button goes through it; compose rows open "
                     "their published ports directly and do not need it. Press "
                     "'Stop the browser door' first to serve another lane.")
_VIEW_DOWN_TIP = ("`make view-stop`: stop the background view session and sweep its "
                  "port-forwards.")
_VIEW_DOWN_IDLE_TIP = "No `make view` session is running."


def _grey_note(text: str) -> QtWidgets.QLabel:
    lbl = QtWidgets.QLabel(text)
    lbl.setWordWrap(True)
    lbl.setStyleSheet("color: gray;")
    return lbl


def _colour(state: str) -> str:
    """progress.py's per-status colour; unknown states fall back to grey."""
    return _STATUS_GLYPH.get(state, _STATUS_GLYPH["queued"])[1]


def _glyph(state: str) -> str:
    return _STATUS_GLYPH.get(state, _STATUS_GLYPH["queued"])[0]


class MeshMonitorWidget(QtWidgets.QWidget):
    """The table + note + footer. See the module docstring for the rules it keeps."""

    open_requested = Signal(str)          # a door URL — exactly what openUrl gets
    refresh_requested = Signal()
    view_up_requested = Signal()
    view_down_requested = Signal()
    copy_requested = Signal(str)          # the addresses text

    def __init__(self, parent=None):
        super().__init__(parent)
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.note = _grey_note("Checking what is running…")
        lay.addWidget(self.note)
        # setMinimumHeight is MANDATORY: the page body is a QScrollArea and a child
        # table with no minimum collapses to nothing inside it.
        self.table = make_table(_MON_HEADERS, min_height=220)
        self.table.setSelectionBehavior(
            QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(
            QtWidgets.QAbstractItemView.SelectionMode.SingleSelection)
        self.table.verticalHeader().setVisible(False)
        self.table.setSortingEnabled(False)       # order is ours: sorted by key
        hdr = self.table.horizontalHeader()
        hdr.setSectionResizeMode(_MON_COL_NAME,
                                 QtWidgets.QHeaderView.ResizeMode.Interactive)
        hdr.setSectionResizeMode(_MON_COL_OPEN,
                                 QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        lay.addWidget(self.table, 1)
        footer, frow = flow_box("")
        self.refresh_btn = QtWidgets.QPushButton("Refresh")
        self.refresh_btn.setToolTip(
            "Re-read both lanes now (kind: one kubectl round trip; compose: docker "
            "compose ps). Also happens every 10 s while this section is open, and "
            "after every action finishes.")
        self.refresh_btn.clicked.connect(self.refresh_requested.emit)
        frow.addWidget(self.refresh_btn)
        self.view_up_btn = QtWidgets.QPushButton("Open the browser door (`make view`)")
        self.view_up_btn.setToolTip(_VIEW_UP_TIP)
        self.view_up_btn.clicked.connect(self.view_up_requested.emit)
        frow.addWidget(self.view_up_btn)
        self.view_down_btn = QtWidgets.QPushButton("Stop the browser door")
        self.view_down_btn.setToolTip(_VIEW_DOWN_TIP)
        self.view_down_btn.clicked.connect(self.view_down_requested.emit)
        frow.addWidget(self.view_down_btn)
        self.copy_btn = QtWidgets.QPushButton("Copy all addresses")
        self.copy_btn.setToolTip("Copy every row's addresses (one line per unit) to "
                                 "the clipboard.")
        self.copy_btn.clicked.connect(self._copy_clicked)
        frow.addWidget(self.copy_btn)
        lay.addWidget(footer)
        self.footer = footer

        self._snapshot: MonitorSnapshot | None = None
        self._row_keys: list[str] = []
        self._buttons: dict[str, QtWidgets.QPushButton] = {}
        self._button_urls: dict[str, str] = {}
        self.set_view_session(False)

    # ── what the page reads ──────────────────────────────────────────────────────
    @property
    def snapshot(self) -> MonitorSnapshot | None:
        return self._snapshot

    def row_key(self, row: int) -> str:
        return self._row_keys[row] if 0 <= row < len(self._row_keys) else ""

    def row_of(self, key: str) -> int:
        try:
            return self._row_keys.index(key)
        except ValueError:
            return -1

    def button_for(self, key: str) -> QtWidgets.QPushButton | None:
        return self._buttons.get(key)

    def set_view_session(self, live: bool, lane: str = "") -> None:
        """Arm exactly ONE of the view buttons — never both — from the live-doors
        answer: 'Open' when no session serves, 'Stop' when one does. ``lane`` is
        the lane that session serves (the snapshot's ``view_lane``), named in the
        tooltip so a session serving a lane that is no longer up is not mistaken
        for the one the rows use."""
        self.view_up_btn.setEnabled(not live)
        self.view_down_btn.setEnabled(live)
        # BOTH tooltips, BOTH branches. Writing only one per branch left the other
        # holding the previous state's sentence, so after the first flip the ENABLED
        # button explained why it was disabled ("No `make view` session is running."
        # on a live Stop button, and vice versa).
        if live:
            which = f"the {lane} lane's doors" if lane else "its lane's doors"
            self.view_up_btn.setToolTip(_VIEW_UP_LIVE_TIP.format(which=which))
            self.view_down_btn.setToolTip(_VIEW_DOWN_TIP)
        else:
            self.view_up_btn.setToolTip(_VIEW_UP_TIP)
            self.view_down_btn.setToolTip(_VIEW_DOWN_IDLE_TIP)

    # ── rendering ────────────────────────────────────────────────────────────────
    def clear(self) -> None:
        """Drop every row. Used when nothing runs or the last read failed: showing
        stale rows as current is precisely the failure the monitor exists to fix."""
        self._snapshot = None
        for r in range(self.table.rowCount()):
            self.table.removeCellWidget(r, _MON_COL_OPEN)
        self.table.setRowCount(0)
        self._row_keys = []
        self._buttons = {}
        self._button_urls = {}

    def render(self, snap: MonitorSnapshot) -> None:
        """Repaint from a snapshot, preserving the selected row by key."""
        self._snapshot = snap
        units = sorted(snap.units, key=lambda u: (u.lane, u.namespace, u.name))
        keys = [u.key for u in units]
        selected_key = ""
        sel = self.table.selectionModel().selectedRows() if self.table.selectionModel() else []
        if sel:
            selected_key = self.row_key(sel[0].row())
        if keys != self._row_keys:
            self._rebuild_rows(keys)
        for r, u in enumerate(units):
            self._paint_row(r, u)
        if selected_key:
            r = self.row_of(selected_key)
            if r >= 0:
                self.table.selectRow(r)

    def _rebuild_rows(self, keys: list[str]) -> None:
        """The key set changed: reshape the table. Buttons for keys that vanished are
        dropped; the ones that survive are re-seated on their new row below."""
        for r in range(self.table.rowCount()):
            self.table.removeCellWidget(r, _MON_COL_OPEN)
        self.table.setRowCount(len(keys))
        self._row_keys = list(keys)
        # a removed cell widget is deleted by Qt, so the cache is void: every surviving
        # door gets a fresh button on its new row in _paint_door
        self._buttons = {}
        self._button_urls = {}

    def _paint_row(self, r: int, u: mesh_monitor.MeshUnit) -> None:
        col = _colour(u.state)
        state_tip = u.reason or ("ready" if u.ready else u.phase)
        set_cell(self.table, r, _MON_COL_NAME, f"{u.namespace}/{u.name}",
                 tooltip=u.detail, colour=col)
        set_cell(self.table, r, _MON_COL_LANE, u.lane,
                 tooltip=("docker compose project" if u.lane == "compose"
                          else "kind (Kubernetes) cluster"))
        set_cell(self.table, r, _MON_COL_STATE, f"{_glyph(u.state)} {u.phase}",
                 tooltip=state_tip, colour=col)
        set_cell(self.table, r, _MON_COL_K8S, u.cluster_path or _DASH,
                 tooltip=(u.cluster_path or "no Service selects this unit"),
                 colour="" if u.cluster_path else _GREY)
        set_cell(self.table, r, _MON_COL_EXT, u.external or _DASH,
                 tooltip=(u.external or "not reachable from outside the mesh"),
                 colour="" if u.external else _GREY)
        self._paint_door(r, u)

    def _paint_door(self, r: int, u: mesh_monitor.MeshUnit) -> None:
        door = u.door
        url = door.url if door.openable else ""
        why = door.blocked
        if url:
            bad = unsafe_door_reason(url)      # the GUI-boundary HSTS gate
            if bad:
                url, why = "", bad
        key = u.key
        if url:
            # gaining (or keeping) a door: item OUT first, then the widget
            if self.table.item(r, _MON_COL_OPEN) is not None:
                self.table.takeItem(r, _MON_COL_OPEN)
            btn = self._buttons.get(key)
            if btn is None or self._button_urls.get(key) != url or \
                    self.table.cellWidget(r, _MON_COL_OPEN) is not btn:
                self.table.removeCellWidget(r, _MON_COL_OPEN)
                btn = QtWidgets.QPushButton(door.label or "Open")
                btn.setToolTip(f"Open {url} in your default browser"
                               + (" (through the `make view` door)" if door.via == "view"
                                  else ""))
                btn.clicked.connect(lambda _c=False, u_=url: self.open_requested.emit(u_))
                self.table.setCellWidget(r, _MON_COL_OPEN, btn)
                self._buttons[key] = btn
                self._button_urls[key] = url
        else:
            # losing (or never having) a door: widget OUT first, then the dash
            if self.table.cellWidget(r, _MON_COL_OPEN) is not None:
                self.table.removeCellWidget(r, _MON_COL_OPEN)
            self._buttons.pop(key, None)
            self._button_urls.pop(key, None)
            set_cell(self.table, r, _MON_COL_OPEN, _DASH,
                     tooltip=why or "no browser door", colour=_GREY)

    # ── footer ───────────────────────────────────────────────────────────────────
    def addresses_text(self) -> str:
        return mesh_monitor.addresses_text(self._snapshot) if self._snapshot else ""

    def _copy_clicked(self) -> None:
        text = self.addresses_text()
        cb = QtWidgets.QApplication.clipboard()
        if cb is not None:
            cb.setText(text)
        self.copy_requested.emit(text)

    def door_urls(self) -> list[str]:
        """Every URL an Open button currently carries — what the HSTS test reads."""
        return list(self._button_urls.values())


__all__ = ["MeshMonitorWidget", "_MON_HEADERS", "_MON_COL_NAME", "_MON_COL_LANE",
           "_MON_COL_STATE", "_MON_COL_K8S", "_MON_COL_EXT", "_MON_COL_OPEN"]
