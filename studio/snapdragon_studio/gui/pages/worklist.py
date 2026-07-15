"""WorklistPage — the mesh role x platform multi-select (spec 1; slug "worklist").

Mesh replaces the single-image Role/Hardware/Branding pages with ONE checkable
role x platform table: a superadmin picks every image the mesh needs in one place.
Each checked row becomes a :class:`~...core.worklist.WorklistEntry`; the shared
identity plane (domains/users/network/system/disk-encryption default) still lives in
the base ImageConfig, collected by the pages downstream. Per-image hardware/GPU/board
facts derive from the row (no per-image hardware page); theming/home surfaces are
never offered here — a mesh node is node-class (specs 2/7).

The page is only VISITED in mesh (MODE_SKIPPED_PAGES); standalone/cloud skip it and
synthesize a 1-entry worklist at Build time instead, so the driver/progress/manifest
have exactly one shape.
"""
from __future__ import annotations

from ..qt import Qt, QtWidgets
from ...core.config import (
    FRITE_BOARDS, FRITE_FLAVORS, JETSON_BOARDS, ORANGEPI5_BOARDS, ORANGEPI5_FLAVORS,
    ORANGEPIZERO2_FLAVORS, PLATFORM_LABELS, ROLE_CHOICES, RPI_BOARDS, image_class,
    rpi_boards_for_role,
)
from ...core.worklist import WorklistConfig, WorklistEntry, entry_id

# The GPU-bearing mesh roles (Notes-column callout); mirrors the builder's GPU roles.
_GPU_ROLES = ("be+gpu", "edge_ai", "gpu-host")

# spec 2c: PKI + Backend + Frontend are the minimum a mesh needs and are meant to be
# built TOGETHER (the "Select the required trio" convenience checks their standard x86
# rows). GPU / Edge-AI nodes are deferrable — buildable here or later from a provided
# config — so they are deliberately NOT part of this trio.
_REQUIRED_TRIO = ("pki", "be", "fe")

# Per-platform structural axes surfaced as inline combos (only where the platform HAS
# the axis — the same tables RolePage drives the single-image board/flavor knobs from).
_BOARD_CHOICES = {
    "rpi5": RPI_BOARDS, "jetson": JETSON_BOARDS,
    "frite": FRITE_BOARDS, "orangepi5": ORANGEPI5_BOARDS,
}
_FLAVOR_CHOICES = {
    "frite": FRITE_FLAVORS, "orangepi5": ORANGEPI5_FLAVORS,
    "orangepizero2": ORANGEPIZERO2_FLAVORS,
}

_COL_CHECK, _COL_ROLE, _COL_PLATFORM, _COL_BOARD, _COL_FLAVOR, _COL_NOTES = range(6)


def _row_notes(role: str, platform: str) -> str:
    """The auto, read-only Notes cell (design 3.4): encryption reality + GPU + the
    'brand defaults only' caveat for the ARM desktop-client mesh rows."""
    cls = image_class("mesh", role)
    parts: list[str] = []
    if platform == "jetson":
        parts.append("no root encryption — jetson builder limitation")
    elif cls == "node":
        parts.append("root-encrypted (LUKS)")
    if role in _GPU_ROLES:
        parts.append("GPU")
    if cls == "desktop":
        parts.append("desktop client — brand defaults, no per-image theming")
    return " · ".join(parts)


class WorklistPage(QtWidgets.QWizardPage):
    """A checkable role x platform table sourced from ``ROLE_CHOICES["mesh"]`` — one
    top-level row per (role, platform) pair. Checking a row adds a WorklistEntry with
    that row's stable id (``f"{role}.{platform}"``); board/flavor are row attributes so
    an id never dangles on a board edit. validatePage reconciles the worklist against
    the checked rows and prunes unchecked ids from every ``Domain.images``."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        # spec 2c: this IS the "mesh node" path's multi-image step. Say plainly that each
        # row is one server node image, that pki+be+fe are required together, and that
        # GPU / Edge-AI nodes can wait — the core "make each step clear" ask.
        self.setTitle("Choose the node images to build")
        self.setSubTitle(
            "Select every server node this mesh needs. PKI + Backend + Frontend are "
            "required together; GPU / Edge-AI nodes can be built later from a provided "
            "config.")
        lay = QtWidgets.QVBoxLayout(self)

        self.header = QtWidgets.QLabel("")
        self.header.setWordWrap(True)
        self.header.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.header)

        # spec 2c convenience: one click checks the standard x86 pki+be+fe trio (the
        # minimum buildable-together set) without disturbing any GPU/edge rows already
        # picked — additive, never a reset.
        trio_row = QtWidgets.QWidget()
        trio_lay = QtWidgets.QHBoxLayout(trio_row)
        trio_lay.setContentsMargins(0, 0, 0, 0)
        self.trio_btn = QtWidgets.QPushButton("Select the required trio (pki + be + fe)")
        self.trio_btn.setToolTip(
            "PKI + Backend + Frontend are the minimum a mesh needs and are built "
            "together. GPU / Edge-AI nodes can be added here or built later from a "
            "provided config.")
        self.trio_btn.clicked.connect(self._select_trio)
        trio_lay.addWidget(self.trio_btn)
        trio_lay.addStretch(1)
        lay.addWidget(trio_row)

        self.tree = QtWidgets.QTreeWidget()
        self.tree.setRootIsDecorated(False)
        self.tree.setHeaderLabels(["", "Role", "Platform", "Board", "Flavor/Desktop", "Notes"])
        self.tree.setColumnWidth(_COL_CHECK, 28)
        # Name what the per-row columns MEAN: Board + Flavor/Desktop are each node's
        # hardware target (spec 2c "pick the hardware per node"); Notes is auto-derived.
        hdr = self.tree.headerItem()
        hdr.setToolTip(_COL_BOARD, "Per-node hardware: the target board for ARM nodes.")
        hdr.setToolTip(_COL_FLAVOR,
                       "Per-node hardware: image flavor (live / installer) or desktop variant.")
        hdr.setToolTip(_COL_NOTES,
                       "Auto: this node's encryption reality, GPU, and client-brand caveats.")
        lay.addWidget(self.tree, 1)

        # gray helper: reinforce that each row = one node, the columns = per-node
        # hardware, and point forward to the SERVICES / domains / users steps that
        # follow (STEP 3-6) so the mesh-node path reads as an obvious sequence.
        self.hint = QtWidgets.QLabel(
            "Each row is one server node image. The Board and Flavor/Desktop columns "
            "set that node's hardware; the Notes column is filled in automatically. "
            "Next you'll choose the cluster services each node runs, then the domains "
            "and users.")
        self.hint.setWordWrap(True)
        self.hint.setStyleSheet("color: gray;")
        lay.addWidget(self.hint)

        # id -> top-level QTreeWidgetItem (the _helpers.check_worklist_rows contract:
        # `.rows` is a mapping id -> item, and each item carries the check state on
        # column 0). id -> (board_combo|None, flavor_combo|None) for validatePage reads.
        self.rows: dict[str, QtWidgets.QTreeWidgetItem] = {}
        self._combos: dict[str, tuple[QtWidgets.QComboBox | None,
                                      QtWidgets.QComboBox | None]] = {}
        self._id_axes: dict[str, tuple[str, str]] = {}   # id -> (role, platform)

        for role, platforms, _label in ROLE_CHOICES["mesh"]:
            for platform in platforms:
                self._build_row(role, platform)

        self.tree.itemChanged.connect(self._on_item_changed)

    def _build_row(self, role: str, platform: str) -> None:
        rid = entry_id(role, platform)
        item = QtWidgets.QTreeWidgetItem(self.tree)
        item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
        item.setCheckState(_COL_CHECK, Qt.CheckState.Unchecked)
        item.setText(_COL_ROLE, role)
        item.setText(_COL_PLATFORM, PLATFORM_LABELS.get(platform, platform))
        item.setText(_COL_NOTES, _row_notes(role, platform))
        item.setData(_COL_CHECK, Qt.ItemDataRole.UserRole, rid)

        board_combo = flavor_combo = None
        # rpi5's board choices are ROLE-dependent: a node role (pki/be/fe) may target
        # rpi5/rpi4 only — rpi3 is desktop-only (1GB RAM can't host the node stack), so
        # offering it here would let a superadmin queue a build that hard-errors. Every
        # other platform's board list is role-independent (_BOARD_CHOICES).
        boards = rpi_boards_for_role(role) if platform == "rpi5" else _BOARD_CHOICES.get(platform)
        if boards:
            board_combo = QtWidgets.QComboBox()
            board_combo.addItems(list(boards))
            self.tree.setItemWidget(item, _COL_BOARD, board_combo)
        if _FLAVOR_CHOICES.get(platform):
            flavor_combo = QtWidgets.QComboBox()
            flavor_combo.addItems(list(_FLAVOR_CHOICES[platform]))
            self.tree.setItemWidget(item, _COL_FLAVOR, flavor_combo)

        self.rows[rid] = item
        self._combos[rid] = (board_combo, flavor_combo)
        self._id_axes[rid] = (role, platform)
        self._sync_combo_enabled(rid)

    # ---- id/row exposure (WS-FLOWUI contract for tests + IDENTUI/REVIEWUI) --------
    def row_for_id(self, rid: str) -> QtWidgets.QTreeWidgetItem:
        """The top-level QTreeWidgetItem for a stable entry id (``f"{role}.{platform}"``)."""
        return self.rows[rid]

    # ---- state helpers -----------------------------------------------------------
    def _is_checked(self, item: QtWidgets.QTreeWidgetItem) -> bool:
        return item.checkState(_COL_CHECK) == Qt.CheckState.Checked

    def _sync_combo_enabled(self, rid: str) -> None:
        on = self._is_checked(self.rows[rid])
        for combo in self._combos[rid]:
            if combo is not None:
                combo.setEnabled(on)

    def _on_item_changed(self, item: QtWidgets.QTreeWidgetItem, _col: int) -> None:
        rid = item.data(_COL_CHECK, Qt.ItemDataRole.UserRole)
        if rid in self._combos:
            self._sync_combo_enabled(rid)
        self.completeChanged.emit()

    def _select_trio(self) -> None:
        """spec 2c: check the standard x86 pki+be+fe rows in one click. Additive — it
        never unchecks a GPU/edge row the superadmin already picked (the trio is the
        REQUIRED-together minimum, not the whole worklist)."""
        self.tree.blockSignals(True)
        for role in _REQUIRED_TRIO:
            item = self.rows.get(entry_id(role, "x86"))
            if item is not None:
                item.setCheckState(_COL_CHECK, Qt.CheckState.Checked)
        self.tree.blockSignals(False)
        for rid in self.rows:
            self._sync_combo_enabled(rid)
        self.completeChanged.emit()

    def isComplete(self) -> bool:
        return any(self._is_checked(it) for it in self.rows.values())

    # ---- (de)serialize the check/axes state against the worklist -----------------
    def initializePage(self) -> None:
        cfg = self.wiz.cfg
        self.header.setText(
            "All nodes join the orchestration superdomain "
            f"<b>{cfg.effective_superdomain()}</b> (edit on the Network page). "
            "Superadmins belong to it.")

        wl = getattr(self.wiz, "worklist", None)
        self.tree.blockSignals(True)
        if wl is not None and wl.entries:
            by_id = {e.id: e for e in wl.entries}
            for rid, item in self.rows.items():
                e = by_id.get(rid)
                item.setCheckState(_COL_CHECK,
                                   Qt.CheckState.Checked if e else Qt.CheckState.Unchecked)
                if e is not None:
                    self._apply_axes_to_combos(rid, e.board, e.flavor)
        else:
            # fresh mesh entry: pre-check the mode-default row so the flow is navigable
            # (like RolePage preselecting MODE_DEFAULT_ROLE) — the superadmin adds more.
            for it in self.rows.values():
                it.setCheckState(_COL_CHECK, Qt.CheckState.Unchecked)
            default_id = self._default_row_id(cfg.role, cfg.platform)
            if default_id is not None:
                self.rows[default_id].setCheckState(_COL_CHECK, Qt.CheckState.Checked)
        self.tree.blockSignals(False)
        for rid in self.rows:
            self._sync_combo_enabled(rid)
        self.completeChanged.emit()

    def _apply_axes_to_combos(self, rid: str, board: str, flavor: str) -> None:
        board_combo, flavor_combo = self._combos[rid]
        if board_combo is not None and board:
            i = board_combo.findText(board)
            if i >= 0:
                board_combo.setCurrentIndex(i)
        if flavor_combo is not None and flavor:
            i = flavor_combo.findText(flavor)
            if i >= 0:
                flavor_combo.setCurrentIndex(i)

    def _default_row_id(self, role: str, platform: str) -> str | None:
        """The row to pre-check on a fresh mesh entry: the (role, platform) combo if it
        exists, else the role's first platform, else the first row overall."""
        exact = entry_id(role, platform)
        if exact in self.rows:
            return exact
        for rid, (r, _p) in self._id_axes.items():
            if r == role:
                return rid
        return next(iter(self.rows), None)

    def validatePage(self) -> bool:
        cfg = self.wiz.cfg
        wl = getattr(self.wiz, "worklist", None)
        prior = {e.id: e for e in wl.entries} if wl is not None else {}

        entries: list[WorklistEntry] = []
        for rid, item in self.rows.items():          # dict preserves row (table) order
            if not self._is_checked(item):
                continue
            role, platform = self._id_axes[rid]
            board_combo, flavor_combo = self._combos[rid]
            board = board_combo.currentText() if board_combo is not None else ""
            flavor = flavor_combo.currentText() if flavor_combo is not None else ""
            keep = prior.get(rid)                     # a row staying checked KEEPS its state
            entries.append(WorklistEntry(
                role=role, platform=platform, board=board, flavor=flavor,
                desktop=keep.desktop if keep else "",
                encrypt_root=keep.encrypt_root if keep else "default",
                packages_add=keep.packages_add if keep else "",
                packages_drop=keep.packages_drop if keep else "",
            ))
        if not entries:
            return False   # isComplete() already blocks Next; guard the collect path too

        checked = {e.id for e in entries}
        # dangling-ref reconciliation: an unchecked row's id can no longer be attached.
        for d in cfg.domains:
            d.images = [i for i in d.images if i in checked]

        # the shared downstream pages gate on the OPTION-SUPERSET (x86 supports the most
        # fields); per-entry correctness is materialize()'s job (its platform gates make
        # a stale base field a no-op). role is the first checked row's (primary).
        cfg.role = entries[0].role
        cfg.platform = "x86"
        self.wiz.worklist = WorklistConfig(base=cfg, entries=entries)
        return True
