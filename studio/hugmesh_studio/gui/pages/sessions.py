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
from ...core.json_files import load_problem
from ..qt import Qt, QtWidgets
from ..styles import ERROR, WARN
from ._scroll import scrollable
from .sessions_widget import PreviousBuildsWidget


def perform_load(wiz, parent) -> tuple[str, str]:
    """Run the "Load config" file dialog against ``wiz`` and return ``(message,
    colour)`` for an INLINE label (G48) — never a QMessageBox: this is page logic
    reachable from a headless test, and a modal here hangs it exactly like one in
    ``validatePage`` would. ``("", "")`` when the dialog was cancelled (no file chosen).

    A malformed/foreign file (bad JSON, the wrong top-level shape, a value the config
    loader's own checks refuse) is reported here and leaves the wizard's current
    config/worklist untouched — ``StudioWizard.load_config`` only reassigns them once
    ``worklist.load_any`` has returned successfully. A file that DOES load but carries
    a plaintext secret (``SECRET_FIELDS`` — a hand-edited or foreign file; the Studio's
    own ``save_config`` never writes one) is still loaded — refusing the whole config
    over one field would be its own surprise — but said inline, because the operator
    just put a secret value into memory without being told."""
    p, _ = QtWidgets.QFileDialog.getOpenFileName(parent, "Load config", "", "JSON (*.json)")
    if not p:
        return "", ""
    try:
        secrets_found = wiz.load_config(p)
    except Exception as exc:                    # noqa: BLE001 — said, not raised
        # An exception that leaves a slot reaches only the crash log (PyQt6 without
        # crashlog's hook aborts the process), and the windowed Windows Studio has no
        # console: a bad file used to show nothing at all.
        return load_problem(p, exc), ERROR
    if secrets_found:
        names = ", ".join(k.replace("_", "-") for k in secrets_found)
        return (f"Loaded {p}. This file carried plaintext secret(s) ({names}) — "
                "loaded for this session only; saving this config again will NOT "
                "write them back out."), WARN
    return f"Loaded {p}", ""


def perform_save(wiz, parent) -> tuple[str, str]:
    """Run the "Save config" file dialog against ``wiz`` and return ``(message,
    colour)`` for an INLINE label (G48/G49) — never a QMessageBox. ``("", "")`` when
    the dialog was cancelled. ``wiz.save_config`` already blanks every ``SECRET_FIELDS``
    value (``ImageConfig.save`` / ``WorklistConfig.save``); its warning list names
    whichever secret was set but therefore NOT persisted, said here rather than
    swallowed."""
    p, _ = QtWidgets.QFileDialog.getSaveFileName(
        parent, "Save config", "hugmesh-image.json", "JSON (*.json)")
    if not p:
        return "", ""
    warnings = wiz.save_config(p)                # writes the worklist envelope when a
    if warnings:                                  # worklist exists, else flat JSON (I1)
        return f"Saved {p}, but: " + " ".join(warnings), WARN
    return f"Saved {p}", ""


class SessionsPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Prior sessions")
        self.setSubTitle(
            "Restart, redo, inspect or delete a previous build — or load a saved "
            "configuration to pick up where you left off. Next continues into a new "
            "build with whatever is loaded.")
        # Scroll, never clip (_scroll.py): the Previous-builds box grows by its
        # gate_note when a button is greyed, and in a window the operator has made
        # short the note used to be squeezed over the Delete row and cut off.
        lay = scrollable(self, squeeze_first=True)
        self._content_scroll.setFocusPolicy(Qt.FocusPolicy.NoFocus)
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
        # Load/Save's outcome, INLINE (never a modal — G48): a malformed file, a
        # secret-bearing one, or a save that blanked a password all land here.
        self.load_save_note = QtWidgets.QLabel("")
        self.load_save_note.setWordWrap(True)
        self.load_save_note.setTextFormat(Qt.TextFormat.PlainText)
        self.load_save_note.setVisible(False)
        lay.addWidget(self.load_save_note)
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

    def _show(self, text: str, colour: str) -> None:
        self.load_save_note.setText(text)
        self.load_save_note.setStyleSheet(f"color: {colour};" if colour else "")
        self.load_save_note.setVisible(bool(text))

    def _load(self):
        # Load EITHER a flat config OR a worklist envelope through the one loader both
        # UIs share (StudioWizard.load_config -> worklist.load_any); restart() so each
        # page's initializePage() re-reads the freshly loaded config.
        text, colour = perform_load(self.wiz, self)
        if text:
            self._show(text, colour)

    def _save(self):
        text, colour = perform_save(self.wiz, self)
        if text:
            self._show(text, colour)

    def _fleet(self):
        # deferred import: the fleet window is self-contained (golive.py precedent)
        # and only needed if the operator actually opens it. open_fleet_window owns
        # the ONE non-modal instance (show(), never exec()) — this page, the
        # Previous-builds manager and the whole wizard stay interactive while the
        # fleet window is open and while a fleet run streams.
        from . import fleet
        fleet.open_fleet_window(self.wiz)
