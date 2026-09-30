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

THE PER-DOMAIN SERVICES GATE (#494/#495) lives here, and here specifically because
this is the LAST door before dispatch: ProgressPage dispatches on arrival, and
"build"/"launch"/"progress" are the terminal set nextId() never dynamically skips, so
every wizard build path passes through this page. A domain whose Services step was
never gone through refuses the build BY NAME — inline, through the one override point
``core.domain_services.gate_reason``, which a test drives with a bare ImageConfig. It
is a refusal and not a warning that scrolls past: all three of ``_continue``, the
Continue card's enabled state and ``validatePage`` stop, and the reason is laid out
ABOVE the cards — this page scrolls, the build summary grows one line per worklist
entry, and a reason under two cards is a reason scrolled past while staring at a
Continue card that went grey for no visible cause.

THE OTHER BUILD DOOR IS ``StudioWizard.start_build_from_session`` (the previous-builds
manager's RESTART), which sets the start id to "progress" and jumps there, so it never
touches this page. It is gated separately and NARROWLY, in
``PreviousBuildsWidget.can_restart`` through ``core.domain_services.restart_gate_reason``
— stated here rather than left to be discovered. A restart re-dispatches a session's
EXACT recorded config, and every session recorded before ``domain_services_reviewed``
existed carries no marker at all, so a blanket gate there would refuse every historical
restart on the strength of a question nobody was asked at the time. The narrow gate
bites only for a configuration that already carries at least one reviewed name — one
produced under this feature — and has since gained an unconfigured domain, and its
remedy is Redo, the route that exists from the previous-builds manager.

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
from ..styles import ERROR, muted
from ...core import cross_dracut
from ...core.domain_services import ACTION_IMAGE_BUILD, gate_reason
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
        # The gate's refusal (#495). An inline label, never a modal: this is page
        # logic, and a QMessageBox here would hang the headless suite (the repo's
        # no-modals-in-page-logic rule). Empty and hidden until something refuses.
        #
        # ABOVE the cards, not below them: this whole page is inside scrollable(), the
        # build summary grows one line per worklist entry, and a reason under two
        # ChoiceCards is a reason the operator scrolls past while staring at a
        # Continue card that has gone grey for no visible cause.
        self.gate_err = QtWidgets.QLabel("")
        self.gate_err.setWordWrap(True)
        self.gate_err.setTextFormat(Qt.TextFormat.PlainText)
        self.gate_err.setStyleSheet(f"color: {ERROR};")
        self.gate_err.hide()
        lay.addWidget(self.gate_err)
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
            if self._refuse():
                return
            self.wiz.next()
        except Exception:                     # noqa: BLE001 — see module docstring
            _log_swallowed("_continue")

    # ---- the per-domain services gate (#494/#495) --------------------------------
    def gate_refusal(self) -> str:
        """"" when this build may start; otherwise the refusal naming every domain
        with no recorded service configuration. Pure read of cfg through the one override point,
        so a test can assert the exact sentence without painting anything."""
        return gate_reason(self.wiz.cfg, ACTION_IMAGE_BUILD)

    def _refuse(self) -> bool:
        """Show the refusal and report whether it holds. Called from BOTH doors — the
        Continue card and validatePage — because the wizard's own Next button is still
        live on this page and must not be a way around the gate."""
        reason = self.gate_refusal()
        self.gate_err.setText(reason)
        self.gate_err.setVisible(bool(reason))
        self.continue_card.setEnabled(not reason)
        return bool(reason)

    def validatePage(self):
        """Refuse to leave for the progress page while a domain is unconfigured.

        The Continue card is already disabled by ``_refuse``, but QWizard's own Next
        button is not the card — without this, the gate would be a disabled button the
        operator walks around, which is the "warning that scrolls past" this change
        exists to stop."""
        return not self._refuse()

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
        self._refuse()
