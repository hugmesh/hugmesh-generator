"""WelcomePage — intro blurb + load/save of the ImageConfig JSON + previous builds."""
from __future__ import annotations

from ... import advanced_mode
from ..qt import Qt, QtWidgets
from ..styles import WARN
from .sessions_widget import PreviousBuildsWidget


class WelcomePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("HugMesh Image Studio")
        self.setSubTitle(
            "Build a mesh server node, run a local Docker mesh, build a mesh desktop "
            "client, or build a standalone Gentoo desktop — you'll pick which on the next screen.")
        lay = QtWidgets.QVBoxLayout(self)
        info = QtWidgets.QLabel(self._intro_html())
        info.setWordWrap(True)
        info.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(info)
        btns = QtWidgets.QHBoxLayout()
        load = QtWidgets.QPushButton("Load config…")
        load.setToolTip("Reopen a previously saved image configuration (or worklist).")
        save = QtWidgets.QPushButton("Save config…")
        save.setToolTip("Save the current settings to a JSON file to build later or share.")
        load.clicked.connect(self._load)
        save.clicked.connect(self._save)
        btns.addWidget(load)
        btns.addWidget(save)
        btns.addStretch(1)
        # Fleet build is a power tool — it builds EVERY role for a whole release, not the
        # single image this wizard configures. Keep it off the public first screen unless
        # expert mode is on ($HUGMESH_STUDIO_ADVANCED); `hugmesh_studio --fleet`
        # stays available regardless, so no power user loses access.
        if advanced_mode():
            fleet = QtWidgets.QPushButton("Fleet build…")
            fleet.setToolTip(
                "Build EVERY role for the selected platforms in one run — the GUI "
                "front-end to scripts/build-all-roles.sh, for when you want a whole "
                "release worth of images instead of the single image this wizard "
                "configures. Also reachable as `hugmesh_studio --fleet`.")
            fleet.clicked.connect(self._fleet)
            btns.addWidget(fleet)
        lay.addLayout(btns)
        # "Previous builds" — the first-class session manager (hides itself when there
        # are no sessions/unmanaged builds, so a first run renders exactly as before).
        self.previous_builds = PreviousBuildsWidget(wiz)
        self.previous_builds.setVisible(False)
        lay.addWidget(self.previous_builds)
        lay.addStretch(1)

    def _intro_html(self) -> str:
        """The intro paragraph, keyed on whether this machine can actually build.

        Pure method (returns HTML, touches no widget) so a headless test can assert the
        no-backend guidance appears WITHOUT a Docker/Gentoo host. When the host has no
        build backend, ``default_backend`` is "none" — the old page cheerfully printed
        "Backend: none" and the user only hit the wall at Build time; now it says so
        up-front and how to fix it."""
        host = self.wiz.host
        if host.default_backend == "none":
            return (
                "This studio assembles and runs a HugMesh image build.<br><br>"
                f'<b style="color:{WARN}">This machine can\'t build images yet.</b> '
                "Install Docker Desktop on Windows or macOS (and start it), or run "
                "Studio on a Gentoo host to build natively. You can still configure and "
                "save an image now, then build it on a machine that can.<br><br>"
                f"Detected: {host.summary()}")
        return (
            "This studio assembles and runs a HugMesh image build.<br><br>"
            f"Build backend: <b>{host.default_backend}</b> ({host.summary()})<br><br>"
            "On Gentoo it builds natively; everywhere else (including Windows) it drives "
            "the dockerized build.")

    def initializePage(self):
        # refresh every time the first screen is (re)shown — a finished/redone build
        # must appear without restarting the Studio.
        self.previous_builds.refresh()

    def _load(self):
        p, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Load config", "", "JSON (*.json)")
        if p:
            # Load EITHER a flat config OR a worklist envelope through the one loader both
            # UIs share (StudioWizard.load_config -> worklist.load_any); restart() so each
            # page's initializePage() re-reads the freshly loaded config.
            self.wiz.load_config(p)
            QtWidgets.QMessageBox.information(self, "Loaded", f"Loaded {p}")

    def _save(self):
        p, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Save config", "hugmesh-image.json", "JSON (*.json)")
        if p:
            # writes the worklist envelope when a worklist exists, else flat JSON (I1)
            warnings = self.wiz.save_config(p)
            if warnings:  # plaintext secrets are blanked on save — tell the user
                QtWidgets.QMessageBox.warning(self, "Passwords not saved", "\n".join(warnings))

    def _fleet(self):
        # deferred import: the fleet window is self-contained (golive.py precedent)
        # and only needed if the operator actually opens it. open_fleet_window owns
        # the ONE non-modal instance (show(), never exec()) — this page, the
        # Previous-builds manager and the whole wizard stay interactive while the
        # fleet window is open and while a fleet run streams.
        from . import fleet
        fleet.open_fleet_window(self.wiz)
