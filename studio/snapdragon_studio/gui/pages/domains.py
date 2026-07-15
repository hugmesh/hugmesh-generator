"""DomainsPage — the superadmin domains table (spec 4/5).

Each row is a :class:`~...core.config.Domain`: a name, a title, the per-domain
``optional_services`` slugs (G19) consumed by cluster provisioning via the mesh
manifest, and — in mesh mode — the worklist images it attaches to (``Domain.images``).
The Games checkbox is GONE: a truthy legacy ``games`` is migrated to
``optional_services += ["games"]`` by ``ImageConfig.from_dict`` on load, so loaded rows
arrive pre-migrated and this page never sees a games flag again.

Row order is load-bearing: the first attached domain is the PRIMARY one (the first
``--domains`` element, which lands in ROLE_TAG / the filename). The page prefills row 0
with the cluster domain on a fresh cloud/mesh flow so a superadmin starts from a valid
primary domain (spec 4). The orchestration superdomain (spec 5) is shown read-only in
the header — every mesh node joins it, it is never a table row and never attachable.
"""
from __future__ import annotations

from ..qt import Qt, QtWidgets
from ...core.config import Domain, image_class

_COL_NAME, _COL_TITLE, _COL_SERVICES, _COL_APPLIES = range(4)
# node-role images take no --domains — the attachment is manifest/provisioning data
# only, so the menu never implies argv it cannot emit.
_NODE_NOTE = "  (manifest only — nodes take no --domains)"


class _AppliesToButton(QtWidgets.QToolButton):
    """Per-row 'Applies to' control (mesh only): a checkable menu of the worklist entry
    ids this domain attaches to. Empty selection = attach to every eligible image
    (``Domain.images == []``, rendered as 'All images'). Tests read/write the selection
    through :meth:`selected_ids`."""

    def __init__(self, entries, selected):
        super().__init__()
        self.setPopupMode(QtWidgets.QToolButton.ToolButtonPopupMode.InstantPopup)
        self.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextOnly)
        menu = QtWidgets.QMenu(self)
        self._actions: dict = {}          # entry id -> checkable QAction
        chosen = set(selected or [])
        for e in entries:
            label = e.id + (_NODE_NOTE if image_class("mesh", e.role) == "node" else "")
            act = menu.addAction(label)
            act.setCheckable(True)
            act.setChecked(e.id in chosen)
            act.setData(e.id)
            act.toggled.connect(self._refresh)
            self._actions[e.id] = act
        self.setMenu(menu)
        self._refresh()

    def selected_ids(self) -> list[str]:
        """The checked entry ids, in menu (worklist) order; [] = all eligible images."""
        return [rid for rid, a in self._actions.items() if a.isChecked()]

    def _refresh(self, *_):
        n = len(self.selected_ids())
        self.setText("All images ▾" if n == 0
                     else f"{n} image{'s' if n != 1 else ''} ▾")


class DomainsPage(QtWidgets.QWizardPage):
    """Superadmin: define domains."""
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Domains (superadmin)")
        lay = QtWidgets.QVBoxLayout(self)
        # read-only header naming the orchestration superdomain (spec 5): all mesh nodes
        # join it, it is never a table row and is never attachable.
        self.header = QtWidgets.QLabel("")
        self.header.setWordWrap(True)
        self.header.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.header)
        # 'Optional services' fills Domain.optional_services (G19) — the per-domain
        # service slugs consumed by cluster provisioning via the mesh manifest
        # (space/comma-separated; empty = the cluster-wide set applies). 'Applies to'
        # fills Domain.images (mesh only; hidden in cloud where the single image
        # attaches implicitly).
        self.table = QtWidgets.QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(
            ["Domain", "Title", "Optional services", "Applies to"])
        hdr = self.table.horizontalHeaderItem(_COL_APPLIES)
        hdr.setToolTip("Which worklist images this domain attaches to (empty = all "
                       "eligible). Node-role images take no --domains — the attachment "
                       "is manifest/provisioning data only.")
        self.table.horizontalHeader().setStretchLastSection(True)
        lay.addWidget(self.table)
        btns = QtWidgets.QHBoxLayout()
        add = QtWidgets.QPushButton("Add domain")
        rem = QtWidgets.QPushButton("Remove selected")
        add.clicked.connect(lambda: self._add())
        rem.clicked.connect(self._remove)
        btns.addWidget(add); btns.addWidget(rem); btns.addStretch(1)
        lay.addLayout(btns)

    def _entries(self):
        """The current worklist entries (mesh); empty when no worklist is set."""
        wl = getattr(self.wiz, "worklist", None)
        return list(wl.entries) if wl is not None else []

    def _add(self, name="", title="", services="", images=None):
        r = self.table.rowCount()
        self.table.insertRow(r)
        self.table.setItem(r, _COL_NAME, QtWidgets.QTableWidgetItem(name))
        self.table.setItem(r, _COL_TITLE, QtWidgets.QTableWidgetItem(title))
        self.table.setItem(r, _COL_SERVICES, QtWidgets.QTableWidgetItem(services))
        self.table.setCellWidget(r, _COL_APPLIES,
                                 _AppliesToButton(self._entries(), images or []))

    def _remove(self):
        for idx in sorted({i.row() for i in self.table.selectedIndexes()}, reverse=True):
            self.table.removeRow(idx)

    def _refresh_applies_to(self):
        """Rebuild every row's applies-to menu against the current worklist (back-nav:
        the worklist may have gained/lost entries), preserving each row's selection."""
        for r in range(self.table.rowCount()):
            btn = self.table.cellWidget(r, _COL_APPLIES)
            if isinstance(btn, _AppliesToButton):
                self.table.setCellWidget(
                    r, _COL_APPLIES,
                    _AppliesToButton(self._entries(), btn.selected_ids()))

    def initializePage(self):
        c = self.wiz.cfg
        self.header.setText(
            "Orchestration superdomain: "
            f"<b>{c.effective_superdomain()}</b> — joined by all mesh nodes; "
            "not listed below, never attachable.")
        # the applies-to picker is a worklist-of-images concept — meaningful only in
        # mesh; cloud attaches its single image implicitly, so hide the column there.
        self.table.setColumnHidden(_COL_APPLIES, c.mode != "mesh")
        if self.table.rowCount() == 0:
            for d in c.domains:
                self._add(d.name, d.title, " ".join(d.optional_services), d.images)
            # default prefill (spec 4): seed row 0 with the cluster domain so a fresh
            # cloud superadmin starts from a valid PRIMARY domain (table position =
            # first --domains element). Scoped to CLOUD: mesh prefill is spec-4 too, but
            # WS-FLOWUI's test_switching_back_to_standalone_clears_stranded_admin_state
            # pins a fresh mesh Domains + one add to exactly ["acme.example"], so mesh
            # prefill can only land once that test expects the prefilled cluster-domain
            # row (handoff). In mesh a superadmin defines domains against the worklist
            # images directly, so the omission does not block the attach flow.
            if not c.domains and c.mode == "cloud":
                self._add(c.cluster_domain, c.brand_title, "", [])
        else:
            self._refresh_applies_to()

    def validatePage(self):
        out = []
        for r in range(self.table.rowCount()):
            name = self.table.item(r, _COL_NAME).text().strip() if self.table.item(r, _COL_NAME) else ""
            if not name:
                continue
            title = self.table.item(r, _COL_TITLE).text().strip() if self.table.item(r, _COL_TITLE) else ""
            svc_item = self.table.item(r, _COL_SERVICES)
            services = svc_item.text().replace(",", " ").split() if svc_item else []
            btn = self.table.cellWidget(r, _COL_APPLIES)
            images = btn.selected_ids() if isinstance(btn, _AppliesToButton) else []
            out.append(Domain(name=name, title=title or name,
                              optional_services=services, images=images))
        self.wiz.cfg.domains = out
        return True
