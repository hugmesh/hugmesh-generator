"""DomainsPage — the superadmin domains table."""
from __future__ import annotations

from ..qt import Qt, QtWidgets
from ...core.config import Domain


class DomainsPage(QtWidgets.QWizardPage):
    """Superadmin: define domains."""
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Domains (superadmin)")
        lay = QtWidgets.QVBoxLayout(self)
        # 'Optional services' fills Domain.optional_services (G19) — the per-domain
        # service slugs consumed by cluster provisioning via the mesh manifest
        # (space/comma-separated; empty = the cluster-wide set applies).
        self.table = QtWidgets.QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["Domain", "Title", "Games", "Optional services"])
        self.table.horizontalHeader().setStretchLastSection(True)
        lay.addWidget(self.table)
        btns = QtWidgets.QHBoxLayout()
        add = QtWidgets.QPushButton("Add domain")
        rem = QtWidgets.QPushButton("Remove selected")
        add.clicked.connect(lambda: self._add())
        rem.clicked.connect(self._remove)
        btns.addWidget(add); btns.addWidget(rem); btns.addStretch(1)
        lay.addLayout(btns)

    def _add(self, name="", title="", games=False, services=""):
        r = self.table.rowCount()
        self.table.insertRow(r)
        self.table.setItem(r, 0, QtWidgets.QTableWidgetItem(name))
        self.table.setItem(r, 1, QtWidgets.QTableWidgetItem(title))
        chk = QtWidgets.QTableWidgetItem()
        chk.setCheckState(Qt.CheckState.Checked if games else Qt.CheckState.Unchecked)
        self.table.setItem(r, 2, chk)
        self.table.setItem(r, 3, QtWidgets.QTableWidgetItem(services))

    def _remove(self):
        for idx in sorted({i.row() for i in self.table.selectedIndexes()}, reverse=True):
            self.table.removeRow(idx)

    def initializePage(self):
        if self.table.rowCount() == 0:
            for d in self.wiz.cfg.domains:
                self._add(d.name, d.title, d.games, " ".join(d.optional_services))

    def validatePage(self):
        out = []
        for r in range(self.table.rowCount()):
            name = self.table.item(r, 0).text().strip() if self.table.item(r, 0) else ""
            if not name:
                continue
            title = self.table.item(r, 1).text().strip() if self.table.item(r, 1) else ""
            games = self.table.item(r, 2).checkState() == Qt.CheckState.Checked if self.table.item(r, 2) else False
            services = self.table.item(r, 3).text().replace(",", " ").split() if self.table.item(r, 3) else []
            out.append(Domain(name=name, title=title or name, games=games,
                              optional_services=services))
        self.wiz.cfg.domains = out
        return True
