"""WelcomePage — intro blurb + load/save of the ImageConfig JSON."""
from __future__ import annotations

from ..qt import Qt, QtWidgets


class WelcomePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Snapdragon Image Studio")
        self.setSubTitle(
            "Build a mesh server node, run a local Docker mesh, build a mesh desktop "
            "client, or build a standalone Gentoo desktop — you'll pick which on the next screen.")
        lay = QtWidgets.QVBoxLayout(self)
        info = QtWidgets.QLabel(
            "This studio assembles and runs a Snapdragon image build.\n\n"
            f"Backend: <b>{wiz.host.default_backend}</b> ({wiz.host.summary()})\n\n"
            "On Gentoo it can build natively; everywhere else (including Windows) it drives "
            "the dockerized build. Everything you set here maps to the generator's flags.")
        info.setWordWrap(True)
        info.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(info)
        btns = QtWidgets.QHBoxLayout()
        load = QtWidgets.QPushButton("Load config…")
        save = QtWidgets.QPushButton("Save config…")
        fleet = QtWidgets.QPushButton("Fleet build…")
        fleet.setToolTip(
            "Build EVERY role for the selected platforms in one run — the GUI "
            "front-end to scripts/build-all-roles.sh, for when you want a whole "
            "release worth of images instead of the single image this wizard "
            "configures. Also reachable as `snapdragon_studio --fleet`.")
        load.clicked.connect(self._load)
        save.clicked.connect(self._save)
        fleet.clicked.connect(self._fleet)
        btns.addWidget(load)
        btns.addWidget(save)
        btns.addStretch(1)
        btns.addWidget(fleet)
        lay.addLayout(btns)
        lay.addStretch(1)

    def _load(self):
        p, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Load config", "", "JSON (*.json)")
        if p:
            # Load EITHER a flat config OR a worklist envelope through the one loader both
            # UIs share (StudioWizard.load_config -> worklist.load_any); restart() so each
            # page's initializePage() re-reads the freshly loaded config.
            self.wiz.load_config(p)
            QtWidgets.QMessageBox.information(self, "Loaded", f"Loaded {p}")

    def _save(self):
        p, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Save config", "snapdragon-image.json", "JSON (*.json)")
        if p:
            # writes the worklist envelope when a worklist exists, else flat JSON (I1)
            warnings = self.wiz.save_config(p)
            if warnings:  # plaintext secrets are blanked on save — tell the user
                QtWidgets.QMessageBox.warning(self, "Passwords not saved", "\n".join(warnings))

    def _fleet(self):
        # deferred import: FleetDialog is self-contained (golive.py precedent)
        # and only needed if the operator actually opens it
        from .fleet import FleetDialog
        FleetDialog(self.wiz.generator_dir, parent=self.wiz).exec()
