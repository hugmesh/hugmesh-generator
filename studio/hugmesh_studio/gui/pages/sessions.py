"""SessionsPage — "Review prior sessions": load/save of the ImageConfig JSON plus
the first-class Previous-builds manager.

This is the surface the Studio used to OPEN on (WelcomePage hosted it until the
issue-#50 welcome flow landed): the Load/Save config buttons, the expert-mode Fleet
entry, and :class:`.sessions_widget.PreviousBuildsWidget`. It now lives one click
behind the Welcome screen's REVIEW PRIOR SESSIONS card — the same widgets under the
"sessions" slug — so nothing session-shaped changed behaviour with the move:

  - RESTART still jumps straight to the terminal progress page
    (``StudioWizard.start_build_from_session`` — the prior-session resume path);
  - REDO still loads the config back into the wizard and ``restart()``s to Welcome;
  - the fleet window stays the ONE non-modal instance (``open_fleet_window``);
  - ``gui.shell`` and ``pages.fleet`` locate the manager by scanning pages for the
    ``previous_builds`` attribute, so the move is invisible to both.
"""
from __future__ import annotations

from ... import advanced_mode
from ..qt import QtWidgets
from .sessions_widget import PreviousBuildsWidget


def load_problem(path: str, exc: BaseException) -> str:
    """The sentence "Load config" shows when ``path`` did not load. A file that is not
    UTF-8 gets a fix as well as the codec's words: Windows PowerShell 5.1's
    ``Set-Content`` writes the ANSI code page, which a hostname with an accent breaks.
    It names what json_files.decode accepts, not "UTF-16": a UTF-16 file without a byte
    order mark is read as UTF-8 too, and fails here with an accent in it."""
    if isinstance(exc, UnicodeDecodeError):
        return (f"{path} could not be loaded: it is not UTF-8 text, nor UTF-16 with a "
                f"byte order mark ({exc}). Save it again as UTF-8 and load it once more.")
    return f"{path} could not be loaded: {exc}"


class SessionsPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Prior sessions")
        self.setSubTitle(
            "Restart, redo, inspect or delete a previous build — or load a saved "
            "configuration to pick up where you left off. Next continues into a new "
            "build with whatever is loaded.")
        lay = QtWidgets.QVBoxLayout(self)
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
        # single image this wizard configures. Keep it off the ordinary screens unless
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
        # are no sessions/unmanaged builds, so a first visit renders just the buttons).
        self.previous_builds = PreviousBuildsWidget(wiz)
        self.previous_builds.setVisible(False)
        lay.addWidget(self.previous_builds)
        lay.addStretch(1)

    def initializePage(self):
        # refresh every time the screen is (re)shown — a finished/redone build
        # must appear without restarting the Studio.
        self.previous_builds.refresh()

    def _load(self):
        p, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Load config", "", "JSON (*.json)")
        if p:
            # Load EITHER a flat config OR a worklist envelope through the one loader both
            # UIs share (StudioWizard.load_config -> worklist.load_any); restart() so each
            # page's initializePage() re-reads the freshly loaded config.
            try:
                self.wiz.load_config(p)
            except Exception as exc:            # noqa: BLE001 — said, not raised
                # An exception that leaves a slot reaches only the crash log (PyQt6
                # without crashlog's hook aborts the process), and the windowed Windows
                # Studio has no console: a bad file used to show nothing at all.
                QtWidgets.QMessageBox.warning(self, "Could not load", load_problem(p, exc))
                return
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
