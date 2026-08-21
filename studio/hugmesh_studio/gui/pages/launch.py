"""LaunchPage — ASK 22's separate BUILD screen (slug "launch").

    "Simplify the review screen and make the build screen separate with an option to
     continue the build and go back to the main menu."

Before this page there were two screens doing three jobs: "Review & Build" carried every
build knob AND the command/preflight panes, and its Commit button dropped the operator
straight onto the terminal progress page, which DISPATCHES on arrival
(``ProgressPage.initializePage``). There was no moment between "I have finished
configuring" and "a root build is running", and — because the review page is a Qt commit
page — no way back either: Qt disables Back after a commit, so the only exits were
Cancel and the window's close button.

This page is that moment. It states what is about to run in one short block (image list,
backend, output dir, whether node keys will be generated) and offers exactly the two
actions the operator asked for, as big icon buttons in the choice-card idiom (ask 14):

* **Continue the build** — advances to the progress page, which dispatches exactly as
  before. Nothing about the run itself changed; it simply no longer starts by surprise.
* **Back to the main menu** — ``QWizard.restart()``: back to the first screen with the
  configuration intact, so an operator who spots a wrong output dir can walk the pages
  again instead of killing the Studio. Nothing has been dispatched at this point (the
  worklist commit is in-memory; ``build_sessions.new_session`` is only called on the
  progress page), so leaving here writes nothing and starts nothing.

The wizard's own Next button still works — this page adds a deliberate,
self-describing action pair, it does not take the standard navigation away. (There
is no Finish button here: the page is not final, ProgressPage follows it.)

Qt duality: the venv is PySide6, the operator runs PyQt6 where an exception escaping a
slot calls qFatal and kills the Studio — both slots here are exception-guarded.
"""
from __future__ import annotations

import os
import sys
import traceback

from ..choice_cards import ChoiceCard
from ..qt import Qt, QtWidgets
from ._scroll import scrollable
from ..styles import muted
from ...core import cross_dracut
from ...core.worklist import resolve_encrypt_root


def _log_swallowed(where: str) -> None:
    print(f"launch: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


def launch_summary(wiz, cross_ready: bool | None = None) -> str:
    """One short paragraph: what pressing Continue will actually run. Reads the
    committed worklist + config, touches no widget and no disk, so the claim is testable
    without painting anything.

    ``cross_ready`` is the ask-21 ARM cross-dracut readiness
    (``cross_dracut.preflight_ok``); pass it to keep this function probe-free, leave it
    None and it samples the host itself (two stats on /proc). This is the LAST screen
    before dispatch and Back is disabled from the review commit page onwards, so a build
    that is going to refuse at the builder\'s own preflight has to say so HERE — beside
    the "back to the main menu" card that is the only way to act on it."""
    cfg = wiz.cfg
    wl = getattr(wiz, "worklist", None)
    entries = list(wl.entries) if wl is not None else []
    images = ", ".join(e.id for e in entries) if entries else "the configured image"
    backend = getattr(wiz, "build_backend", None) or wiz.host.default_backend
    out = cfg.output_dir or os.path.join(wiz.generator_dir, "out")
    line = (f"{len(entries) or 1} image(s): {images}\n"
            f"Backend: {backend}   ·   Output: {out}")
    if cfg.mode == "mesh":
        keys = "yes" if getattr(wiz, "generate_node_keys", True) else "no"
        line += f"   ·   Generate node keys: {keys}"
    cross = cross_dracut.cross_fde_note(
        cross_dracut.cross_fde_rows(
            [(e.id, e.platform, resolve_encrypt_root(e, cfg.encrypt_root))
             for e in entries]),
        cross_dracut.preflight_ok() if cross_ready is None else cross_ready)
    if cross:
        line += "\n" + cross
    return line


class LaunchPage(QtWidgets.QWizardPage):
    """The build screen: continue, or go back to the main menu."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Build")
        self.setSubTitle("Nothing has started yet. Continue when you are ready, or go "
                         "back to the main menu — your settings are kept either way.")
        lay = scrollable(self)
        self.summary = QtWidgets.QLabel("")
        self.summary.setWordWrap(True)
        # PLAIN text on purpose: the summary interpolates an output PATH and entry ids,
        # and a path containing '<' or '&' must render as itself, not as broken markup.
        self.summary.setTextFormat(Qt.TextFormat.PlainText)
        lay.addWidget(self.summary)
        lay.addWidget(self._muted_note())
        # ACTION cards, not a pick-one group: each one DOES its thing on click, so they
        # are deliberately not checkable (the tile look of ask 14 without pretending a
        # button is a selection).
        self.continue_card = ChoiceCard(
            "Continue the build",
            "Start building now. The next screen shows one row per image with its live "
            "log, and you can stop any image from there.",
            icon_name="build-run")
        self.continue_card.setCheckable(False)
        self.continue_card.clicked.connect(self._continue)
        lay.addWidget(self.continue_card)
        self.menu_card = ChoiceCard(
            "Back to the main menu",
            "Return to the first screen without building. Everything you configured is "
            "kept — reload it, save it to a file, or walk the steps again.",
            icon_name="main-menu")
        self.menu_card.setCheckable(False)
        self.menu_card.clicked.connect(self._main_menu)
        lay.addWidget(self.menu_card)
        lay.addStretch(1)

    def _muted_note(self) -> QtWidgets.QLabel:
        lab = QtWidgets.QLabel(
            "A native build needs root and will ask for your password; a docker build "
            "drives the builder image. Either way nothing is written until you continue.")
        lab.setWordWrap(True)
        lab.setStyleSheet(muted())
        return lab

    # ---- slots (guarded: PyQt6 qFatals on an exception escaping a slot) -----------
    def _continue(self) -> None:
        try:
            self.wiz.next()
        except Exception:                     # noqa: BLE001 — see module docstring
            _log_swallowed("_continue")

    def _main_menu(self) -> None:
        """Back to the first screen. restart() re-runs each page's initializePage from
        the (unchanged) config, which is exactly what a "main menu" means here — the
        Welcome screen routes to everything, including the sessions screen where
        Load/Save config and the previous-builds manager live."""
        try:
            self.wiz.restart()
        except Exception:                     # noqa: BLE001 — see module docstring
            _log_swallowed("_main_menu")

    def initializePage(self):
        self.summary.setText(launch_summary(self.wiz))
