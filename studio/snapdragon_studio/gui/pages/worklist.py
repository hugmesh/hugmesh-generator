"""WorklistPage — the mesh role x platform multi-select (spec 1; slug "worklist").

Mesh replaces the single-image Role/Hardware/Branding pages with ONE checkable
role x platform table: a superadmin picks every image the mesh needs in one place.
Each checked row becomes a :class:`~...core.worklist.WorklistEntry`; the shared
identity plane (domains/users/network/system/disk-encryption default) still lives in
the base ImageConfig, collected by the pages downstream. Per-image hardware/GPU/board
facts derive from the row (no per-image hardware page); theming/home surfaces are
never offered here — a mesh node is node-class (specs 2/7).

PRESENTATION (device-catalog restructure): the rows are grouped under family headers
from ``core.device_catalog`` (x86 PCs / Raspberry Pi / NVIDIA Jetson), with an
architecture filter + search box above the tree, and honest info rows for the devices
that have NO mesh role (frite/opi5/opz2 single-image boards, and every UNSUPPORTED
device with its reason — visible, never checkable, #351). The ENTRY IDENTITY CONTRACT
is untouched: entries remain ``(role, platform, board, flavor, ...)``, ids remain
``f"{role}.{platform}"`` (Domain.images references + the ``rows`` id->item mapping
depend on it), and the per-row Board combo remains the device axis WITHIN a family —
its choices still come from ``rpi_boards_for_role``/the config board tuples, so the
rpi3 node-gate and every emitted entry are byte-identical. (A per-device duplication
of the role rows was considered and rejected: the same ``role.platform`` id under
several device rows cannot satisfy the one-item-per-id contract.)

The page is only VISITED in mesh (MODE_SKIPPED_PAGES); standalone/cloud skip it and
synthesize a 1-entry worklist at Build time instead, so the driver/progress/manifest
have exactly one shape.
"""
from __future__ import annotations

from ..qt import Qt, QtGui, QtWidgets
from ...core import device_catalog
from ...core.config import (
    FRITE_BOARDS, FRITE_FLAVORS, JETSON_BOARDS, ORANGEPI5_BOARDS, ORANGEPI5_FLAVORS,
    ORANGEPIZERO2_FLAVORS, PLATFORM_LABELS, ROLE_CHOICES, RPI_BOARDS, image_class,
    rpi_boards_for_role,
)
from ...core.worklist import WorklistConfig, WorklistEntry, entry_id
from ._widgets import status_badge

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

_COL_CHECK, _COL_ROLE, _COL_PLATFORM, _COL_BOARD, _COL_FLAVOR, _COL_ENC, _COL_NOTES = range(7)

# per-entry encrypt_root override values (worklist.WorklistEntry.encrypt_root):
# "default" inherits the worklist-wide Home-step encrypt_root; on/off force it.
_ENC_CHOICES = ("default", "on", "off")


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
    row per (role, platform) pair, grouped under device-catalog family headers.
    Checking a row adds a WorklistEntry with that row's stable id
    (``f"{role}.{platform}"``); board/flavor are row attributes so an id never dangles
    on a board edit. validatePage reconciles the worklist against the checked rows and
    prunes unchecked ids from every ``Domain.images``."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self._catalog = device_catalog.load_catalog()
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

        # spec 2c convenience: one click checks the pki+be+fe trio (the minimum
        # buildable-together set) on whichever architectures the arch filter admits,
        # without disturbing any GPU/edge rows already picked — additive, never a reset.
        # Plus the arch filter + device search
        # (presentation only — a hidden checked row still builds).
        trio_row = QtWidgets.QWidget()
        trio_lay = QtWidgets.QHBoxLayout(trio_row)
        trio_lay.setContentsMargins(0, 0, 0, 0)
        self.trio_btn = QtWidgets.QPushButton("Select the required trio (pki + be + fe)")
        self.trio_btn.setToolTip(
            "PKI + Backend + Frontend are the minimum a mesh needs and are built "
            "together. Checks them on every architecture the filter beside this button "
            "admits — 'All architectures' selects the trio on x86 AND arm64. GPU / "
            "Edge-AI nodes can be added here or built later from a provided config.")
        self.trio_btn.clicked.connect(self._select_trio)
        trio_lay.addWidget(self.trio_btn)
        self.arch_filter = QtWidgets.QComboBox()
        self.arch_filter.addItem("All architectures", "")
        for arch in self._catalog.archs:
            if self._catalog.devices_for_arch(arch.id):
                self.arch_filter.addItem(arch.label, arch.id)
        trio_lay.addWidget(self.arch_filter)
        self.device_search = QtWidgets.QLineEdit()
        self.device_search.setPlaceholderText("Search devices / roles…")
        self.device_search.setClearButtonEnabled(True)
        trio_lay.addWidget(self.device_search, 1)
        lay.addWidget(trio_row)

        self.tree = QtWidgets.QTreeWidget()
        self.tree.setRootIsDecorated(True)
        self.tree.setHeaderLabels(
            ["", "Role", "Platform", "Board", "Flavor/Desktop", "Encryption", "Notes"])
        self.tree.setColumnWidth(_COL_CHECK, 28)
        # Name what the per-row columns MEAN: Board + Flavor/Desktop are each node's
        # hardware target (spec 2c "pick the hardware per node"); Encryption is the
        # per-node root-disk choice (spec 4); Notes is auto-derived.
        hdr = self.tree.headerItem()
        hdr.setToolTip(_COL_BOARD, "Per-node hardware: the target board for ARM nodes.")
        hdr.setToolTip(_COL_FLAVOR,
                       "Per-node hardware: image flavor (live / installer) or desktop variant.")
        hdr.setToolTip(_COL_ENC,
                       "Per-node root-disk encryption: 'default' inherits the Home-step "
                       "choice; 'on'/'off' override it for THIS node. The unattended LUKS "
                       "passphrase (Home step) is shared by every encrypted node.")
        hdr.setToolTip(_COL_NOTES,
                       "Auto: this node's encryption reality, GPU, and client-brand caveats.")
        lay.addWidget(self.tree, 1)

        # spec 4: answer the WHICH-device question for the fleet-wide LUKS passphrase —
        # it is set ONCE on the Home step and applies to every encrypted node here; the
        # per-row Encryption column above scopes WHETHER each node is encrypted.
        self.enc_hint = QtWidgets.QLabel(
            "Root-disk encryption is per node (the Encryption column). The unattended "
            "LUKS passphrase set on the Home step applies to EVERY encrypted node in "
            "this worklist.")
        self.enc_hint.setWordWrap(True)
        self.enc_hint.setStyleSheet("color: gray;")
        lay.addWidget(self.enc_hint)

        # gray helper: reinforce that each row = one node, the columns = per-node
        # hardware, and point forward to the SERVICES / domains / users steps that
        # follow (STEP 3-6) so the mesh-node path reads as an obvious sequence.
        self.hint = QtWidgets.QLabel(
            "Each row is one server node image, grouped by device family. The Board and "
            "Flavor/Desktop columns set that node's hardware; the Notes column is filled "
            "in automatically. Grayed rows are devices with no mesh role — shown so the "
            "answer is honest, never buildable from here. Next you'll choose the cluster "
            "services each node runs, then the domains and users.")
        self.hint.setWordWrap(True)
        self.hint.setStyleSheet("color: gray;")
        lay.addWidget(self.hint)

        # id -> the checkable QTreeWidgetItem (the _helpers.check_worklist_rows contract:
        # `.rows` is a mapping id -> item, and each item carries the check state on
        # column 0). id -> (board_combo|None, flavor_combo|None) for validatePage reads.
        self.rows: dict[str, QtWidgets.QTreeWidgetItem] = {}
        self._combos: dict[str, tuple[QtWidgets.QComboBox | None,
                                      QtWidgets.QComboBox | None]] = {}
        # id -> per-row encrypt_root combo (None for jetson, which cannot encrypt — its
        # cell is a disabled display and validatePage keeps the prior/default value).
        self._enc_combos: dict[str, QtWidgets.QComboBox | None] = {}
        self._id_axes: dict[str, tuple[str, str]] = {}   # id -> (role, platform)
        # family id -> group header item; per-item arch (for the arch filter).
        self._family_items: dict[str, QtWidgets.QTreeWidgetItem] = {}
        self._item_arch: dict[int, str] = {}

        for role, platforms, _label in ROLE_CHOICES["mesh"]:
            for platform in platforms:
                self._build_row(role, platform)

        # honest info rows (#351): every catalog device with NO mesh role — the
        # single-image-only boards (frite/opi5/opz2, chromebook) and every UNSUPPORTED
        # device with its reason. Visible, disabled, never checkable.
        for dev in self._catalog.devices:
            if dev.status != "unsupported" and device_catalog.roles_for(dev.id, "mesh"):
                continue   # covered by its platform's checkable role rows above
            self._build_info_row(dev)

        # expand the buildable groups; collapse the info-only ones (visibility without
        # noise). A group is buildable iff any child carries an entry id.
        for fitem in self._family_items.values():
            has_rows = any(
                fitem.child(i).data(_COL_CHECK, Qt.ItemDataRole.UserRole) is not None
                for i in range(fitem.childCount()))
            fitem.setExpanded(has_rows)

        self.tree.itemChanged.connect(self._on_item_changed)
        self.arch_filter.currentIndexChanged.connect(self._apply_filter)
        self.device_search.textChanged.connect(self._apply_filter)

    # ---- tree construction ---------------------------------------------------------
    def _family_group(self, family_id: str) -> QtWidgets.QTreeWidgetItem:
        """The (lazily created) family header row: bold label + arch + the family's
        honesty badge (EXPERIMENTAL rides up from its devices, e.g. NVIDIA Jetson)."""
        item = self._family_items.get(family_id)
        if item is not None:
            return item
        fam = self._catalog.family(family_id)
        arch = next((a.label for a in self._catalog.archs if a.id == fam.arch), fam.arch)
        item = QtWidgets.QTreeWidgetItem(self.tree)
        item.setText(_COL_ROLE, f"{fam.label} — {arch}")
        statuses = {d.status for d in self._catalog.devices_in_family(family_id)}
        if "supported" not in statuses and "experimental" in statuses:
            badge, color = status_badge("experimental")
            item.setText(_COL_NOTES, badge)
            item.setForeground(_COL_NOTES, QtGui.QBrush(QtGui.QColor(color)))
        item.setFlags(Qt.ItemFlag.ItemIsEnabled)   # a header: no check, no select
        font = item.font(_COL_ROLE)
        font.setBold(True)
        item.setFont(_COL_ROLE, font)
        self._family_items[family_id] = item
        self._item_arch[id(item)] = fam.arch
        return item

    def _platform_family(self, platform: str) -> str:
        """A mesh platform's device family (via its default catalog device)."""
        return self._catalog.device(
            device_catalog.default_device_for_platform(platform)).family

    def _build_row(self, role: str, platform: str) -> None:
        rid = entry_id(role, platform)
        group = self._family_group(self._platform_family(platform))
        item = QtWidgets.QTreeWidgetItem(group)
        item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
        item.setCheckState(_COL_CHECK, Qt.CheckState.Unchecked)
        item.setText(_COL_ROLE, role)
        item.setText(_COL_PLATFORM, PLATFORM_LABELS.get(platform, platform))
        item.setText(_COL_NOTES, _row_notes(role, platform))
        item.setData(_COL_CHECK, Qt.ItemDataRole.UserRole, rid)
        self._item_arch[id(item)] = self._catalog.device(
            device_catalog.default_device_for_platform(platform)).arch

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

        # per-node root-disk encryption (spec 4). jetson cannot encrypt (its builder
        # forces off, _resolve_encrypt_root), so its cell is a disabled display; every
        # other platform gets a default/on/off combo defaulting to "default" (inherit
        # the Home-step choice) — additive + byte-identical for existing worklists.
        enc_combo = None
        if platform == "jetson":
            disp = QtWidgets.QComboBox()
            disp.addItem("off — jetson cannot encrypt")
            disp.setEnabled(False)
            self.tree.setItemWidget(item, _COL_ENC, disp)
        else:
            enc_combo = QtWidgets.QComboBox()
            enc_combo.addItems(list(_ENC_CHOICES))
            self.tree.setItemWidget(item, _COL_ENC, enc_combo)

        self.rows[rid] = item
        self._combos[rid] = (board_combo, flavor_combo)
        self._enc_combos[rid] = enc_combo
        self._id_axes[rid] = (role, platform)
        self._sync_combo_enabled(rid)

    def _build_info_row(self, dev) -> None:
        """A disabled, uncheckable visibility row (#351): the device exists, and here
        is exactly why it has nothing to build on the mesh path."""
        group = self._family_group(dev.family)
        item = QtWidgets.QTreeWidgetItem(group)
        item.setText(_COL_ROLE, dev.label)
        item.setText(_COL_PLATFORM, dev.soc)
        if dev.status == "unsupported":
            badge, _color = status_badge("unsupported")
            reason = f"{badge} — {dev.reason}"
        else:
            reason = ("no mesh/cluster-node role — "
                      + (dev.notes or "single-image flows only"))
            if dev.status == "experimental":
                reason = f"{status_badge('experimental')[0]} · {reason}"
        item.setText(_COL_NOTES, reason)
        for col in (_COL_ROLE, _COL_PLATFORM, _COL_NOTES):
            item.setToolTip(col, reason)
        item.setFlags(Qt.ItemFlag.NoItemFlags)   # visible, never checkable/selectable
        self._item_arch[id(item)] = dev.arch

    # ---- arch/search filtering (presentation only) ----------------------------------
    def _apply_filter(self, *_a) -> None:
        arch = self.arch_filter.currentData() or ""
        needle = self.device_search.text().strip().lower()
        for fitem in self._family_items.values():
            any_visible = False
            for i in range(fitem.childCount()):
                child = fitem.child(i)
                show = not arch or self._item_arch.get(id(child), "") == arch
                if show and needle:
                    hay = " ".join(child.text(c) for c in
                                   (_COL_ROLE, _COL_PLATFORM, _COL_NOTES)).lower()
                    show = needle in hay
                child.setHidden(not show)
                any_visible = any_visible or show
            fitem.setHidden(not any_visible)

    # ---- id/row exposure (WS-FLOWUI contract for tests + IDENTUI/REVIEWUI) --------
    def row_for_id(self, rid: str) -> QtWidgets.QTreeWidgetItem:
        """The checkable QTreeWidgetItem for a stable entry id (``f"{role}.{platform}"``)."""
        return self.rows[rid]

    # ---- state helpers -----------------------------------------------------------
    def _is_checked(self, item: QtWidgets.QTreeWidgetItem) -> bool:
        return item.checkState(_COL_CHECK) == Qt.CheckState.Checked

    def _sync_combo_enabled(self, rid: str) -> None:
        on = self._is_checked(self.rows[rid])
        for combo in (*self._combos[rid], self._enc_combos[rid]):
            if combo is not None:
                combo.setEnabled(on)

    def _on_item_changed(self, item: QtWidgets.QTreeWidgetItem, _col: int) -> None:
        rid = item.data(_COL_CHECK, Qt.ItemDataRole.UserRole)
        if rid in self._combos:
            self._sync_combo_enabled(rid)
        self.completeChanged.emit()

    def _select_trio(self) -> None:
        """spec 2c: check the pki+be+fe rows in one click, on every architecture the arch
        filter currently admits — "All architectures" checks the trio on x86 AND arm64,
        because pki/be/fe are buildable on both (ROLE_CHOICES gives each of them
        ("x86", "rpi5")), and a superadmin who has not narrowed the filter means all of
        them. Pinning this to x86 (as it did until 2026-07-17) silently ignored the
        dropdown and produced an x86-only mesh from a button that claims to select "the
        required trio".

        Arch membership is read from the SAME ``_item_arch`` map ``_apply_filter`` uses,
        so the button and the filter can never disagree about what an architecture
        contains. Additive — it never unchecks a GPU/edge row the superadmin already
        picked (the trio is the REQUIRED-together minimum, not the whole worklist)."""
        arch = self.arch_filter.currentData() or ""      # "" == All architectures
        self.tree.blockSignals(True)
        for rid, item in self.rows.items():
            if rid.split(".", 1)[0] not in _REQUIRED_TRIO:
                continue
            if arch and self._item_arch.get(id(item), "") != arch:
                continue
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
                    enc_combo = self._enc_combos[rid]
                    if enc_combo is not None and e.encrypt_root:
                        j = enc_combo.findText(e.encrypt_root)
                        if j >= 0:
                            enc_combo.setCurrentIndex(j)
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
            # per-row encryption (spec 4): read the combo where present; jetson (no combo)
            # keeps its prior/default value (materialize forces it off regardless). Combos
            # default to "default", so an untouched worklist is byte-identical to before.
            enc_combo = self._enc_combos[rid]
            if enc_combo is not None:
                encrypt_root = enc_combo.currentText()
            else:
                encrypt_root = keep.encrypt_root if keep else "default"
            entries.append(WorklistEntry(
                role=role, platform=platform, board=board, flavor=flavor,
                desktop=keep.desktop if keep else "",
                encrypt_root=encrypt_root,
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
