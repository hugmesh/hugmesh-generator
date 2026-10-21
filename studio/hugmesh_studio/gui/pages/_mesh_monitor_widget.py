"""MeshMonitorWidget — the running-mesh table: every pod and container, its in-mesh and
external addresses, an Open button ONLY where the browser may safely go, and — where
the mounting page asks for it — a Replicas control that scales the workload behind the
row.

This is the CONTENT widget of a ``collapsible(...)`` section, so it is the thing that
gets greyed: the page wraps it (collapsed by default) and drives ``setEnabled`` on it
from ONE place. On the local-mesh page that place is ``LocalMeshPage._sync_monitor_gate``;
on the two emulation pages it is :class:`MeshMonitorSection` below, which owns the same
tri-state gate plus the probe, the timer and the scale worker so that neither emulation
page grows its own copy of them.

The widget itself performs no I/O and starts no thread. It renders a
``core.mesh_monitor.MonitorSnapshot`` and emits what the operator pressed.

TWO RENDERING RULES that a timed repaint makes essential:

* Cells are written with ``set_cell`` (``_emulation_common``), which REUSES the item, so
  a 10 s repaint keeps the selection and the scroll anchor under the cursor. Rows are
  keyed ``lane/namespace/name`` and sorted, so a repaint never reorders them either.
* THE WIDGET/ITEM MUTUAL-EXCLUSION RULE for the Open and Replicas columns. A cell
  carries EITHER a widget (``setCellWidget``) OR an item (a dash whose tooltip says why
  there is no door / no scalable workload). A row that GAINS one across refreshes must
  have its item taken out before the widget goes in, and one that LOSES it must have the
  widget removed before the dash is written — otherwise a stale button sits beside a
  stale dash. Widgets are cached per row key and only recreated when that row's answer
  changed.

SCALING IS OPT-IN, AND THAT IS THE COMPATIBILITY CONTRACT (2026-09-09, issue #336).
``scaling=False`` is the default and produces the SAME six-column table the local-mesh
page has always mounted — same header tuple, same column indices, same signals, no
Replicas column and no per-row scale widget. The Replicas column is appended LAST rather
than inserted, so ``_MON_COL_OPEN`` and its neighbours keep their values for every caller
and every test. ``localmesh.py`` needed no change for any of this, and
``test_localmesh_monitor`` PINS that: flip the default and it fails.

The one thing a non-scaling mount did gain is ``scale_status`` — an empty, hidden
QLabel that carries INLINE refusals (the no-modals rule). It exists on both mounts
because the refusal it carries is not only about scaling: a door this widget declines
to open had nowhere to say so on a non-scaling mount, and a refusal that goes nowhere
is the same failure as a control that does nothing. Hidden with empty text it occupies
no layout, which is what keeps the local-mesh page's rendering unchanged.

WHAT THE OPERATOR'S OWN SCREEN STILL DOES NOT HAVE (read this before wiring it).
Umbrella #333 item 4 asks for scaling on the generate-mesh/docker-config screen too.
That screen is ``localmesh.py``, which #336 explicitly forbade this lane from editing,
so it still mounts ``MeshMonitorWidget(self)`` — six columns, no Replicas. Turning it on
is NOT a one-kwarg change: ``scale_requested`` is a signal, and the only thing that runs
it off-thread is :class:`MeshMonitorSection` below. Passing ``scaling=True`` alone would
ship a Replicas column whose Apply emits into no receiver. So ``_apply`` REFUSES, inline
and by name, when nothing is connected — a control that cannot work says so instead of
looking like it worked. Whoever wires localmesh must connect ``scale_requested`` to an
off-thread worker with a busy guard (copy ``MeshMonitorSection._scale``), or mount the
Section instead of the bare widget.

THE ROW IS NOT THE THING THAT SCALES. A row is one pod or one container — an instance.
The control drives the pod's Deployment/StatefulSet or the container's compose service
(``core.mesh_monitor.ScaleTarget``), and a row whose controller cannot be scaled — a
DaemonSet's pod, a Job's, a static control-plane pod — shows a dash carrying that
sentence instead of a control that would silently revert.

WHY THE BUTTONS CAPTURE THE ROW KEY, NEVER THE ROW INDEX. Rows are re-sorted on every
repaint and the key set changes as pods come and go; a lambda holding ``r`` would, after
one pod appeared above it, scale a different workload than the one the operator is
looking at. Every handler here closes over ``u.key``.

Colours come from progress.py's ``_STATUS_GLYPH`` palette — never a second catalogue
(that module's own rule): a green row here means what a green stage means there.

The HSTS ban is enforced HERE too (``unsafe_door_reason``), not only in core: a Door
whose URL the ban refuses is rendered as a blocked dash carrying the reason, so no
code path can put a pinnable hostname behind a button.
"""
from __future__ import annotations

import time

from ..qt import Qt, QtCore, QtGui, QtWidgets, Signal
from ..flow_layout import flow_box
from ...core import mesh_monitor
from ...core.mesh_monitor import MonitorSnapshot, unsafe_door_reason
from ._emulation_common import ReplicaStrip, make_table, set_cell
from ._widgets import collapsible, own_probe, probe_running
from .progress import _STATUS_GLYPH

# Symbolic column indices only (this page's own rule) — a test names the column it
# reads, and inserting one stays a one-line change. _MON_COL_SCALE is APPENDED: it
# exists only on a scaling mount, and appending is what keeps every index before it
# identical for the non-scaling one.
_MON_COL_NAME, _MON_COL_LANE, _MON_COL_STATE, _MON_COL_K8S, _MON_COL_EXT, _MON_COL_OPEN = \
    range(6)
_MON_COL_SCALE = 6
_MON_HEADERS = ("Pod / container", "Lane", "State", "Kubernetes / compose address",
                "External address", "Open")
_MON_HEADERS_SCALING = _MON_HEADERS + ("Replicas",)

_DASH = "—"
_GREY = "#888888"

#: The Replicas column's header tooltip — the one place that says what "now" counts and
#: what Apply actually runs, because both are easy to assume wrongly.
_SCALE_HEADER_TIP = (
    "How many instances of this row's WORKLOAD this snapshot is showing, and what to "
    "ask for. − and + move the target; Apply runs it. Kubernetes rows run `kubectl "
    "scale <deployment|statefulset>/<name> -n <namespace> --replicas=N` — which writes "
    "the spec and returns, so the table's count catches up on the next refresh. "
    "Compose rows run `docker compose -p hugmesh-local up -d --no-deps --no-recreate "
    "--scale <service>=N <service>`, which starts or stops the containers before it "
    "returns and leaves every other service alone. Both run off the GUI thread; one at "
    "a time.")

_SCALE_APPLY_TIP = ("Run the scale now. Enabled only when the target differs from what "
                    "is running and nothing else is scaling.")
_SCALE_MINUS_TIP = "One fewer. 0 stops the workload without deleting it."
_SCALE_PLUS_TIP = ("One more, up to {ceiling} — a mis-click guard, not a limit of the "
                   "lane. Ask for more with kubectl or compose directly.")

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

# The kind lane's stop, and its undo (#356, decision 44 = a). Both tooltips say what
# the verb keeps, because the neighbouring `Delete DevOps lane` on the bring-up page
# is the one that destroys and the two must never be confused.
_HALT_TIP = (
    "`make kind-halt`: STOP the Kubernetes lane without deleting it. Suspends "
    "ArgoCD auto-sync and scales the mesh's Deployments and StatefulSets to 0.\n\n"
    "The cluster, its PVCs, its Vault KV and its Casdoor identities are all KEPT — "
    "this is not `Delete DevOps lane`. Resume puts back exactly what it suspends, "
    "and names every Application it froze plus the state each was in.\n\n"
    "coredns, kyverno, the storage provisioner and ArgoCD itself keep running: "
    "scaling any of them to 0 would make Resume impossible.")
_RESUME_TIP = (
    "`make kind-resume`: undo a halt. Restores the exact replica counts it recorded "
    "and re-arms auto-sync on exactly the Applications it suspended — never "
    "'everything', so an Application suspended for some other reason stays "
    "suspended.")
#: Greyed-with-a-REASON, the idiom this widget already uses. Invariant I5 is that
#: Unknown is never "no": a lane whose state could not be established must not offer
#: a control that acts on it — that is the run-ungated-lane.sh exit-5 mistake in GUI
#: form, where a census that errored gets treated as an answer.
_HALT_TIP_UNKNOWN = (
    "The Kubernetes lane's state could not be read, so this is disabled. Unknown is "
    "not 'nothing running' — halting a lane nobody could census is exactly the "
    "mistake this control refuses to make. Press Refresh, or check `kind get "
    "clusters` and your kubeconfig.")
_HALT_TIP_DOWN = ("The Kubernetes lane is not running — there is nothing to halt. "
                  "Start it with `Start DevOps lane` on the bring-up step.")
_RESUME_TIP_UNKNOWN = (
    "The Kubernetes lane's state could not be read, so this is disabled. Press "
    "Refresh, or check `kind get clusters` and your kubeconfig.")
_RESUME_TIP_DOWN = ("The Kubernetes lane is not running, so there is nothing to "
                    "resume into. A halted lane still reads as running — the halt "
                    "keeps the cluster.")
#: The lane IS halted. A halted lane still reads running=True, so without this the
#: Studio offered Halt on an already-halted lane with no way to see that it was
#: halted, and pressing it a second time was a normal operator action.
_HALT_TIP_ALREADY = (
    "This lane is already HALTED — `make kind-halt` left its record on the cluster. "
    "Its workloads are at 0 and ArgoCD auto-sync is suspended on the Applications "
    "the halt recorded.\n\nResume DevOps lane is the one you want. "
    "`make kind-halt-status` prints exactly what was frozen and the state each "
    "Application was in when it froze.")
_RESUME_TIP_NOT_HALTED = (
    "This lane is not halted — there is no `make kind-halt` record on the cluster, "
    "so this control has nothing to put back. It deliberately will NOT re-arm "
    "'everything': an Application suspended for some other reason is not this "
    "control's to touch.")
#: The halt record could not be READ, which is not the same as 'there is none'. Both
#: controls stay offered and say so — kind-halt.sh itself refuses (exit 5) on this
#: state, so the refusal happens where it can be explained properly.
#: Deliberately worded so it shares no phrase with the lane-unknown tooltips above:
#: two different uncertainties on the same button must not read as the same sentence,
#: and a test that cannot tell them apart cannot pin either.
_HALT_STATE_UNKNOWN = (
    "\n\nNOTE: whether a halt record already exists on this cluster could not be "
    "determined. Unknown is not the same as 'there is none' — run "
    "`make kind-halt-status` before pressing this.")


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
    #: (row key, target replicas) — emitted by Apply. The MOUNTING page runs it off the
    #: GUI thread; this widget never shells anything.
    scale_requested = Signal(str, int)
    #: The kind lane's NON-destructive stop and its undo (#356). They live HERE, on the
    #: monitor, because this is the screen that reads BOTH lanes and therefore the
    #: screen an operator is on when they decide to stop something — the bring-up page
    #: cannot even tell them what is running. Like every other control on this widget
    #: they only EMIT; the mounting page owns the shelling.
    halt_requested = Signal()
    resume_requested = Signal()

    def __init__(self, parent=None, *, scaling: bool = False):
        super().__init__(parent)
        #: Opt-in, default off — see the compatibility contract in the module docstring.
        self.scaling = bool(scaling)
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.note = _grey_note("Checking what is running…")
        lay.addWidget(self.note)
        # setMinimumHeight is MANDATORY: the page body is a QScrollArea and a child
        # table with no minimum collapses to nothing inside it.
        headers = _MON_HEADERS_SCALING if self.scaling else _MON_HEADERS
        self.table = make_table(headers, min_height=220)
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
        if self.scaling:
            hdr.setSectionResizeMode(_MON_COL_SCALE,
                                     QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
            head_item = self.table.horizontalHeaderItem(_MON_COL_SCALE)
            if head_item is not None:
                head_item.setToolTip(_SCALE_HEADER_TIP)
        lay.addWidget(self.table, 1)
        # INLINE status (the no-modals rule): scale progress, scale refusals AND door
        # refusals. Present on BOTH mounts — hidden and empty, so it costs a non-scaling
        # mount no layout, but a refusal on one is no longer swallowed (a non-scaling
        # Section's declined door had nowhere to land before, which is the same bug as
        # a control that does nothing).
        self.scale_status: QtWidgets.QLabel = _grey_note("")
        self.scale_status.setVisible(False)
        lay.addWidget(self.scale_status)
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
        # The kind lane's stop. NO ellipsis and no modal: it is not destructive.
        self.halt_btn = QtWidgets.QPushButton("Halt DevOps lane")
        self.halt_btn.setToolTip(_HALT_TIP)
        self.halt_btn.clicked.connect(self.halt_requested.emit)
        frow.addWidget(self.halt_btn)
        self.resume_btn = QtWidgets.QPushButton("Resume DevOps lane")
        self.resume_btn.setToolTip(_RESUME_TIP)
        self.resume_btn.clicked.connect(self.resume_requested.emit)
        frow.addWidget(self.resume_btn)
        lay.addWidget(footer)
        self.footer = footer

        self._snapshot: MonitorSnapshot | None = None
        self._row_keys: list[str] = []
        self._buttons: dict[str, QtWidgets.QPushButton] = {}
        self._button_urls: dict[str, str] = {}
        self._scale_cells: dict[str, ReplicaStrip] = {}
        #: Pending targets, kept BY KEY across rebuilds — a pod appearing above this
        #: row must not discard a target the operator chose. Cleared when reality
        #: reaches it (see ReplicaStrip) or when the row is gone for good.
        self._scale_targets: dict[str, int] = {}
        self._scale_busy = False
        self.set_view_session(False)
        # No snapshot yet is UNKNOWN, not 'down'. The halt must not be offered
        # before anything has been read (I5).
        self.set_kind_lane(None, "no snapshot has been taken yet", halted=None)

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

    def scale_cell(self, key: str) -> ReplicaStrip | None:
        """The row's −/+/Apply strip, or None when that row offers none."""
        return self._scale_cells.get(key)

    def scale_target(self, key: str) -> int:
        """What Apply on that row would ask for right now."""
        cell = self._scale_cells.get(key)
        return cell.target if cell is not None else 0

    def hide_view_controls(self, why: str) -> None:
        """Take the two `make view` buttons off THIS mount.

        Used by pages that do not own the `make view` session. A disabled button with
        an explanation is still a button an operator presses; a mount that cannot run
        the verb says so in the note instead of showing a control that answers nothing.
        """
        for b in (self.view_up_btn, self.view_down_btn):
            b.setVisible(False)
            b.setToolTip(why)

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

    # ── the kind lane's halt/resume gate ─────────────────────────────────────────
    def set_kind_lane(self, running, reason: str = "", halted=None) -> None:
        """Arm Halt and Resume from the kind lane's TWO tri-states, never a boolean.

        ``running`` is ``mesh_monitor.LaneState.running``: True, False, or **None**
        for "could not be established". Invariant I5 is that unknown is never "no",
        and this is where that bites hardest — a control that acts on an unknown lane
        is the run-ungated-lane.sh exit-5 mistake wearing a button. So None disables
        BOTH, and says why in the tooltip rather than leaving a dead control with a
        stale sentence on it.

        ``halted`` is ``LaneState.halted``, the SECOND tri-state, and it exists
        because a halted lane still reports running=True — the halt keeps the
        cluster. Without it the Studio offered Halt on an already-halted lane and
        Resume on one that was never halted, with nothing on screen saying which it
        was. True greys Halt and points at Resume; False greys Resume; **None** (the
        record could not be read) leaves both offered and says so, because unknown
        is not 'not halted' here either.

        Both tooltips are rewritten on EVERY branch. Writing only the disabled one
        left the enabled button explaining why it was disabled, which is the bug
        set_view_session above already had to fix once."""
        live = running is True
        self.halt_btn.setEnabled(live and halted is not True)
        self.resume_btn.setEnabled(live and halted is not False)
        if live:
            unknown = _HALT_STATE_UNKNOWN if halted is None else ""
            self.halt_btn.setToolTip(
                _HALT_TIP_ALREADY if halted is True else _HALT_TIP + unknown)
            self.resume_btn.setToolTip(
                _RESUME_TIP_NOT_HALTED if halted is False else _RESUME_TIP + unknown)
        elif running is None:
            why = (" (" + reason + ")") if reason else ""
            self.halt_btn.setToolTip(_HALT_TIP_UNKNOWN + why)
            self.resume_btn.setToolTip(_RESUME_TIP_UNKNOWN + why)
        else:
            self.halt_btn.setToolTip(_HALT_TIP_DOWN)
            self.resume_btn.setToolTip(_RESUME_TIP_DOWN)

    # ── the scale busy guard ─────────────────────────────────────────────────────
    def set_scale_busy(self, busy: bool, text: str = "") -> None:
        """ONE scale at a time, and the inline line says which one.

        The guard is on the WIDGET rather than per row: two `docker compose up`
        invocations against the same project race each other's container set, and the
        second one's ``--no-recreate`` does not protect the first one's work.
        """
        self._scale_busy = bool(busy)
        self.set_scale_status(text)
        for cell in self._scale_cells.values():
            cell.paint(cell.observed, busy=self._scale_busy)

    def set_scale_status(self, text: str) -> None:
        """The ONE inline line. Empty text hides it again, so a stale refusal never
        outlives the thing it refused."""
        self.scale_status.setText(text or "")
        self.scale_status.setVisible(bool(text))

    def scale_status_text(self) -> str:
        return self.scale_status.text()

    # ── rendering ────────────────────────────────────────────────────────────────
    def clear(self) -> None:
        """Drop every row. Used when nothing runs or the last read failed: showing
        stale rows as current is precisely the failure the monitor exists to fix."""
        self._snapshot = None
        for r in range(self.table.rowCount()):
            self.table.removeCellWidget(r, _MON_COL_OPEN)
            if self.scaling:
                self.table.removeCellWidget(r, _MON_COL_SCALE)
        self.table.setRowCount(0)
        self._row_keys = []
        self._buttons = {}
        self._button_urls = {}
        self._scale_cells = {}

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
            self._paint_row(r, u, snap)
        if selected_key:
            r = self.row_of(selected_key)
            if r >= 0:
                self.table.selectRow(r)

    def _rebuild_rows(self, keys: list[str]) -> None:
        """The key set changed: reshape the table. Widgets for keys that vanished are
        dropped; the ones that survive are re-seated on their new row below."""
        for r in range(self.table.rowCount()):
            self.table.removeCellWidget(r, _MON_COL_OPEN)
            if self.scaling:
                self.table.removeCellWidget(r, _MON_COL_SCALE)
        self.table.setRowCount(len(keys))
        self._row_keys = list(keys)
        # a removed cell widget is deleted by Qt, so the cache is void: every surviving
        # door gets a fresh button on its new row in _paint_door, and every surviving
        # scalable row a fresh strip in _paint_scale. The PENDING TARGETS are keyed and
        # deliberately survive this — see _scale_targets.
        self._buttons = {}
        self._button_urls = {}
        self._scale_cells = {}

    def _paint_row(self, r: int, u: mesh_monitor.MeshUnit, snap=None) -> None:
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
        if self.scaling:
            self._paint_scale(r, u, snap if snap is not None else self._snapshot)

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

    def _paint_scale(self, r: int, u: mesh_monitor.MeshUnit, snap) -> None:
        """The Replicas cell, under the same widget/item mutual exclusion as the door."""
        key = u.key
        target_spec = u.scale
        if not target_spec.scalable:
            if self.table.cellWidget(r, _MON_COL_SCALE) is not None:
                self.table.removeCellWidget(r, _MON_COL_SCALE)
            self._scale_cells.pop(key, None)
            self._scale_targets.pop(key, None)
            set_cell(self.table, r, _MON_COL_SCALE, _DASH,
                     tooltip=(target_spec.refused or "not scalable"), colour=_GREY)
            return
        if self.table.item(r, _MON_COL_SCALE) is not None:
            self.table.takeItem(r, _MON_COL_SCALE)
        cell = self._scale_cells.get(key)
        if cell is None or self.table.cellWidget(r, _MON_COL_SCALE) is not cell.widget:
            self.table.removeCellWidget(r, _MON_COL_SCALE)
            cell = ReplicaStrip(
                key, ceiling=mesh_monitor.MAX_REPLICAS,
                what=target_spec.describe(), minus_tip=_SCALE_MINUS_TIP,
                plus_tip=_SCALE_PLUS_TIP.format(ceiling=mesh_monitor.MAX_REPLICAS),
                apply_tip=_SCALE_APPLY_TIP)
            cell.minus.clicked.connect(lambda _c=False, k=key: self._bump(k, -1))
            cell.plus.clicked.connect(lambda _c=False, k=key: self._bump(k, +1))
            cell.apply.clicked.connect(lambda _c=False, k=key: self._apply(k))
            self.table.setCellWidget(r, _MON_COL_SCALE, cell.widget)
            self._scale_cells[key] = cell
        observed = mesh_monitor.replicas_now(snap, target_spec) if snap is not None else 0
        pending = self._scale_targets.get(key)
        if pending is None or pending == observed:
            self._scale_targets.pop(key, None)
            cell.target = observed
        else:
            cell.target = pending
        cell.what = target_spec.describe()
        cell.paint(observed, busy=self._scale_busy)

    def _bump(self, key: str, delta: int) -> None:
        cell = self._scale_cells.get(key)
        if cell is None:
            return
        want = cell.bump(delta)
        if want == cell.observed:
            self._scale_targets.pop(key, None)
        else:
            self._scale_targets[key] = want
        cell.paint(cell.observed, busy=self._scale_busy)

    #: What a scaling mount says when its Apply would emit into nothing. Named here
    #: because a test pins it and because the sentence has to name the fix, not just
    #: the fault — the operator cannot connect a signal, but whoever reads the bug
    #: report can.
    NO_SINK = ("This table is not wired to run a scale: the page that mounted it "
               "connected nothing to scale_requested. Nothing was run. Mount "
               "MeshMonitorSection, or connect scale_requested to an off-thread "
               "worker (see #336).")

    def _apply(self, key: str) -> None:
        cell = self._scale_cells.get(key)
        if cell is None or self._scale_busy:
            return
        # A GUI knob that silently does nothing is this repo's named failure mode, and
        # a bare MeshMonitorWidget(parent, scaling=True) is exactly how one would get
        # built — the column paints, the buttons arm, Apply emits into no receiver.
        # Refuse out loud instead. Fail-OPEN if the binding will not answer: a guard
        # that blocks a real scale would be worse than the bug it guards.
        try:
            wired = self.receivers(self.scale_requested) > 0
        except Exception:                      # noqa: BLE001 — binding difference only
            wired = True
        if not wired:
            self.set_scale_status(self.NO_SINK)
            return
        self.scale_requested.emit(key, int(cell.target))

    def forget_scale_target(self, key: str) -> None:
        """Drop a pending target — what the page calls when its scale FINISHED, so the
        next repaint shows the plain count rather than an arrow to a number that has
        already been asked for."""
        self._scale_targets.pop(key, None)

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


# ── the mountable section ──────────────────────────────────────────────────────────

class MeshMonitorProbe(QtCore.QThread):
    """Read BOTH lanes of the running mesh off the GUI thread, for the monitor table.

    A second copy of ``localmesh._MonitorProbe``, and the reason is MECHANICAL, not
    taste: ``localmesh.py`` imports THIS module (``from ._mesh_monitor_widget import
    MeshMonitorWidget``), so importing back from it here is a circular import that
    fails at interpreter start. The dedup therefore has to run the other way — this
    class is the canonical one, and ``localmesh._MonitorProbe`` becomes an alias of it
    — and ``localmesh.py`` is the file #336 forbade this lane from touching. Filed as
    a follow-up.

    Until then the drift the duplication invites is PINNED rather than hoped about:
    ``test_localmesh_monitor.test_the_two_monitor_probes_have_not_drifted`` compares
    the two classes' constructor signature, signal and both run() paths, so a change to
    one that the other does not get fails.

    The shape is identical on purpose — ``mesh_monitor.snapshot()`` is `kind get
    clusters` + ONE `kubectl get … -A -o json` + `docker inspect` + `docker compose
    ps`, each bounded and together up to ~25 s on a hung daemon, so it is never
    called inline.

    Never raises: snapshot() already folds every failure into LaneState.error, and an
    exception escaping run() would leave the table frozen on a stale snapshot with no
    way to say so.
    """
    result = Signal(object)                     # mesh_monitor.MonitorSnapshot

    def __init__(self, generator_dir: str, node, parent=None):
        super().__init__(parent)
        self._dir = generator_dir
        self._node = node

    def run(self):                              # noqa: D102 — QThread contract
        try:
            self.result.emit(mesh_monitor.snapshot(self._dir, self._node))
        except Exception as e:                  # noqa: BLE001 — never kill the page
            self.result.emit(mesh_monitor.MonitorSnapshot(
                taken_at=time.strftime("%H:%M:%S"),
                compose=mesh_monitor.LaneState(None, error=str(e)),
                kind=mesh_monitor.LaneState(None, error=str(e)),
                errors=(f"the monitor read failed: {type(e).__name__}: {e}",)))


class MeshScaleWorker(QtCore.QThread):
    """ONE ``mesh_monitor.scale`` off the GUI thread.

    `docker compose up --scale` pulls and starts containers; `kubectl scale` waits on
    the API server. Neither belongs on the thread that has to keep repainting the table
    that shows the result, and a hung daemon would freeze the window for the whole
    ceiling (``SCALE_TIMEOUT_S``).
    """
    done = Signal(bool, str)

    def __init__(self, generator_dir: str, node, unit, replicas: int, parent=None):
        super().__init__(parent)
        self._dir = generator_dir
        self._node = node
        self._unit = unit
        self._n = int(replicas)

    def run(self):                              # noqa: D102 — QThread contract
        try:
            ok, text = mesh_monitor.scale(self._dir, self._node, self._unit, self._n)
        except Exception as e:                  # noqa: BLE001 — a worker never dies mute
            ok, text = False, f"the scale failed: {type(e).__name__}: {e}"
        self.done.emit(bool(ok), str(text))


class MeshMonitorSection(QtCore.QObject):
    """The monitor, ready to drop onto a page: widget + collapsible + probe + timer +
    the ONE gate that writes ``setEnabled``, the note and the section title.

    Written once here so the two emulation faces cannot grow two versions of it — the
    same reason ``_emulation_common`` exists — and kept OUT of that module only because
    it would import this one back (``MeshMonitorWidget`` already imports its table
    delegates from there).

    It reproduces ``LocalMeshPage._sync_monitor_gate``'s TRI-STATE, which is the part of
    the contract that is easy to get subtly wrong: a lane whose answer could not be
    ESTABLISHED reads "checking" / "could not read", never "no mesh running" — and a
    failed read CLEARS the rows, because showing stale rows as current is the failure
    the monitor exists to fix.

    The page owns nothing but the mount and three lifecycle calls
    (:meth:`start`, :meth:`stop`, :meth:`shutdown`).
    """

    #: Same cadence as the local-mesh page's monitor, and for the same reason: this is
    #: two shell round trips, not a subscription.
    POLL_MS = 10_000

    def __init__(self, page, generator_dir: str, node_factory, *,
                 title: str = "Running mesh — pods, addresses and doors",
                 scaling: bool = True, what: str = ""):
        super().__init__(page)
        self.page = page
        self.generator_dir = generator_dir
        self._node_factory = node_factory
        self.title = title
        #: One sentence naming WHAT this mount reads, appended to the empty-state note.
        #: The emulation screens need it: their own tables are emulated QEMU guests and
        #: this one is the host's compose project and kind cluster, which is a different
        #: mesh entirely.
        self.what = what
        self.snapshot: mesh_monitor.MonitorSnapshot | None = None
        self.monitor = MeshMonitorWidget(page, scaling=scaling)
        self.section = collapsible(title, self.monitor, False)
        self.section.toggle.toggled.connect(self._on_toggled)
        self.monitor.refresh_requested.connect(lambda: self.refresh("button"))
        self.monitor.open_requested.connect(self._open_door)
        self.monitor.scale_requested.connect(self._scale)
        self.timer = QtCore.QTimer(self)
        self.timer.setInterval(self.POLL_MS)
        self.timer.timeout.connect(self._tick)
        self._scaling_key = ""
        #: Threads shutdown() gave up waiting for. See shutdown().
        self.abandoned: tuple[str, ...] = ()
        self._sync_gate()

    # ── mounting and lifecycle ───────────────────────────────────────────────────
    def mount(self, layout) -> None:
        layout.addWidget(self.section)

    def start(self) -> None:
        """The page became visible. Poll only if the operator left it expanded — a
        folded section costs nothing, which is the whole point of folding it."""
        if self.section.is_expanded():
            self.refresh("shown")
            self.timer.start()

    def stop(self) -> None:
        """Off screen, off the clock (the emulation pages' own hideEvent rule)."""
        self.timer.stop()

    #: What ``shutdown`` will wait, per thread, before it gives up — NOT the verb's
    #: own ceiling. A snapshot is bounded near 25 s so it is given 30; a scale's
    #: ceiling is ``SCALE_TIMEOUT_S`` (180 s, and a compose scale that has to BUILD
    #: can want all of it), and freezing the window for three minutes because the
    #: operator pressed Back is not a trade this page gets to make. See the docstring.
    SHUTDOWN_WAIT_MS = {"_probe": 30_000, "_scale_worker": 5_000}

    def shutdown(self) -> tuple[str, ...]:
        """Page teardown: stop the clock, wait a BOUNDED moment per thread, and answer
        which threads were still running when that moment ran out.

        IT DOES NOT DRAIN, and the earlier docstring here said it did. ``_probe`` gets
        30 s, which is longer than a snapshot's own ~25 s ceiling, so in practice it
        does land. ``_scale_worker`` gets 5 s against a 180 s ceiling, so a
        ``docker compose up --scale`` in flight when the operator leaves the page is
        ABANDONED here: it keeps running to completion in the background, unobserved,
        and its result reaches no status line because the page that would show it is
        gone. That is deliberate — the alternative is a three-minute frozen window on a
        Back press — but it is a fact about this method, not a drain.

        Nothing is killed and nothing leaks: ``own_probe`` un-parents both threads and
        holds them in ``_IN_FLIGHT`` for as long as they run, so ``~QWidget``'s
        ``deleteChildren`` cannot reach them and the qFatal that motivated all of this
        cannot fire. The wait is therefore politeness plus an ANSWER, not safety.

        Returns the attribute names still running, so a caller (and a test) can see the
        abandonment rather than infer it. A ``RuntimeError`` from ``wait`` means the
        C++ wrapper is already gone — that thread is finished, not stranded.
        """
        self.timer.stop()
        still: list[str] = []
        for attr, ms in self.SHUTDOWN_WAIT_MS.items():
            t = getattr(self, attr, None)
            if t is None:
                continue
            try:
                if not t.wait(ms):
                    still.append(attr)
            except RuntimeError:
                continue
        if still:
            # The page is going away, so this cannot be shown to the operator; it is
            # for the log the Studio keeps, which is where an orphaned compose scale
            # would otherwise be invisible.
            self.abandoned = tuple(still)
        return tuple(still)

    # ── reading ──────────────────────────────────────────────────────────────────
    def refresh(self, reason: str = "") -> bool:
        """Kick off ONE off-thread snapshot. Re-entrant-safe: a probe already in flight
        is left alone rather than stacking threads."""
        if probe_running(self, "_probe"):
            return False
        try:
            node = self._node_factory()
        except Exception as e:                  # noqa: BLE001 — a bad config, not a crash
            self.snapshot = mesh_monitor.MonitorSnapshot(
                taken_at=time.strftime("%H:%M:%S"),
                compose=mesh_monitor.LaneState(None, error=str(e)),
                kind=mesh_monitor.LaneState(None, error=str(e)),
                errors=(f"no stack node to ask: {type(e).__name__}: {e}",))
            self._sync_gate()
            return True
        self._node = node
        probe = own_probe(self, "_probe",
                          MeshMonitorProbe(self.generator_dir, node))
        probe.result.connect(self._on_snapshot)
        probe.start()
        self._sync_gate()
        return True

    def _tick(self) -> None:
        if not (self.page.isVisible() and self.section.is_expanded()):
            # STOP, do not just skip: a section collapsed between _on_toggled and the
            # next tick otherwise keeps a 10 s no-op timer alive for the life of the
            # page. start() and _on_toggled(True) are the only things that start it.
            self.timer.stop()
            return
        if probe_running(self, "_probe"):
            return
        self.refresh("tick")

    def _on_toggled(self, on: bool) -> None:
        if on:
            self.refresh("expanded")
            self.timer.start()
        else:
            self.timer.stop()

    def _on_snapshot(self, snap) -> None:
        self.snapshot = snap
        self.monitor.set_view_session(bool(getattr(snap, "view_doors", ())),
                                      lane=str(getattr(snap, "view_lane", "") or ""))
        self._sync_gate()

    # ── the ONE gate ─────────────────────────────────────────────────────────────
    def _sync_gate(self) -> None:
        """The only writer of ``setEnabled`` on the widget, of its note and of the
        section title. Tri-state: unknown is "checking…", never "no mesh"; a failed read
        clears the rows and says so."""
        mon = self.monitor
        snap = self.snapshot
        title = self.title
        tail = (" " + self.what) if self.what else ""
        if snap is None:
            mon.setEnabled(False)
            mon.clear()
            note = ("Checking what is running…" if probe_running(self, "_probe")
                    else "Not read yet — expand this section or press Refresh.")
            mon.note.setText(note + tail)
            self.section.toggle.setText(f"{title} — checking…".replace("&", "&&"))
            return
        ready, total = snap.ready_counts
        lanes = (f"compose {_lane_word(snap.compose)} · kind {_lane_word(snap.kind)}")
        # Once a first snapshot exists, every later refresh re-renders THAT one until
        # the new read lands, and "read 10:00:01" beside rows that are being re-read
        # reads as fresh. Say which it is; the "Checking what is running…" branch above
        # only ever fires while there is no snapshot at all.
        rereading = " Re-reading…" if probe_running(self, "_probe") else ""
        if snap.any_running:
            mon.setEnabled(True)
            mon.render(snap)
            note = f"{ready}/{total} ready · {lanes} · read {snap.taken_at}.{rereading}"
            extra = list(snap.errors) + list(snap.notes)
            if extra:
                note += "\n" + " ".join(extra)
            mon.note.setText(note)
            self.section.toggle.setText(
                f"{title} — {ready}/{total} ready".replace("&", "&&"))
        elif snap.any_unknown:
            mon.setEnabled(False)
            mon.clear()
            why = " ".join(snap.errors) or " · ".join(
                f"{name}: {lane.error or lane.detail or 'not established'}"
                for name, lane in (("kind", snap.kind), ("compose", snap.compose))
                if lane.running is None)
            mon.note.setText("Could not read the running mesh: " + why + tail + rereading)
            self.section.toggle.setText(
                f"{title} — could not read".replace("&", "&&"))
        else:
            mon.setEnabled(False)
            mon.clear()
            note = "No mesh is running." + tail + rereading
            if snap.errors or snap.notes:
                note += " " + " ".join(list(snap.errors) + list(snap.notes))
            mon.note.setText(note)
            self.section.toggle.setText(
                f"{title} — nothing running".replace("&", "&&"))

    # ── the two actions ──────────────────────────────────────────────────────────
    def _open_door(self, url: str) -> None:
        """The URL was gated twice already (core + widget); a third refusal here is
        belt-and-braces, and the inline line says why."""
        why = mesh_monitor.unsafe_door_reason(url)
        if why:
            self.monitor.set_scale_status(f"Not opened: {why}")
            return
        QtGui.QDesktopServices.openUrl(QtCore.QUrl(url))

    def _scale(self, key: str, replicas: int) -> None:
        """Apply on a row: run ONE scale off the GUI thread, behind the busy guard."""
        if probe_running(self, "_scale_worker"):
            return
        snap = self.snapshot
        unit = None
        for u in (snap.units if snap is not None else ()):
            if u.key == key:
                unit = u
                break
        if unit is None:
            self.monitor.set_scale_status(
                "That row is no longer in the last read — press Refresh and try again.")
            return
        node = getattr(self, "_node", None)
        if node is None:
            try:
                node = self._node_factory()
            except Exception as e:              # noqa: BLE001
                self.monitor.set_scale_status(f"Cannot scale: {type(e).__name__}: {e}")
                return
            self._node = node
        self._scaling_key = key
        self.monitor.set_scale_busy(
            True, f"Scaling {unit.scale.describe()} to {replicas}…")
        worker = own_probe(self, "_scale_worker",
                           MeshScaleWorker(self.generator_dir, node, unit, replicas))
        worker.done.connect(self._scale_done)
        worker.start()

    def _scale_done(self, ok: bool, text: str) -> None:
        key, self._scaling_key = self._scaling_key, ""
        if key:
            self.monitor.forget_scale_target(key)
        self.monitor.set_scale_busy(False, text)
        # The count the table shows comes from the ROWS, so it only moves once the
        # lanes are read again — which is exactly why a finished scale re-reads.
        self.refresh("post-scale")


def _lane_word(lane) -> str:
    if lane.running is None:
        return "not established"
    return "up" if lane.running else "down"


__all__ = ["MeshMonitorWidget", "MeshMonitorProbe", "MeshScaleWorker",
           "MeshMonitorSection", "_MON_HEADERS", "_MON_HEADERS_SCALING",
           "_MON_COL_NAME", "_MON_COL_LANE", "_MON_COL_STATE", "_MON_COL_K8S",
           "_MON_COL_EXT", "_MON_COL_OPEN", "_MON_COL_SCALE"]
