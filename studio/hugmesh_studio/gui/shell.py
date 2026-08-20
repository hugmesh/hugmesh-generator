"""StudioShell — the Studio's window/tray layer (ask 16).

Before this module the Studio had exactly one window, forever. ``app.py`` held a
``nonlocal wizard`` and did *"if wizard is None: create; else show + raise"* — so
"open a NEW studio window" had no code path at all, and a second ``python -m
hugmesh_studio`` simply made a second QApplication with a second tray icon.

This module owns the three things ask 16 asks for, and nothing else — the pages keep
their own content:

**1. The launch question.** If a Studio is already open, the second launch asks, in a
dialog, whether to open a NEW window or to send the EXISTING window back to the first
wizard screen while builds continue in the background. Detection is
:mod:`...core.instance` — a socket handshake with the running process, not a guess —
and both branches are executed BY the running instance over that same socket, which is
what keeps every build in one process where the tray can see them. If detection fails
for any reason we open normally; being locked out of your own tool is worse than an
extra window.

**2. Many windows.** :meth:`StudioShell.open_window` mints a real additional
``StudioWizard`` each call, and :meth:`StudioShell.reset_to_start` walks the existing
one back to page one. Closing a window never stops a build — that is
:mod:`.build_supervisor`, which owns the run and pins the window object alive until it
ends.

**3. The tray roster.** The tray's "Running builds" submenu lists each running build
and opens a window for the selected one: the live window if the build belongs to this
process, otherwise a :class:`~.pages.build_window.BuildActionsWindow` that says what it
truthfully can about someone else's run.

Qt duality: PySide6 in the venv, PyQt6 for the operator — every slot here is
exception-guarded, because an escaping exception in a PyQt6 slot calls qFatal.
"""
from __future__ import annotations

import sys
import traceback

from .qt import Qt, QtCore, QtWidgets
from .choice_cards import ChoiceCard, ChoiceCardGroup
from . import build_supervisor
from . import tray as tray_mod
from ..core import instance

__all__ = ["AlreadyRunningDialog", "ask_already_running", "StudioShell",
           "CHOICE_NEW_WINDOW", "CHOICE_RESET", "CHOICE_CANCEL"]

CHOICE_NEW_WINDOW = "new-window"
CHOICE_RESET = "reset"
CHOICE_CANCEL = ""


def _log_swallowed(where: str) -> None:
    print(f"shell: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


# ── the launch question ──────────────────────────────────────────────────────────────
class AlreadyRunningDialog(QtWidgets.QDialog):
    """"A HugMesh Image Studio is already open." — new window, or reset the open one?

    Presented as choice CARDS rather than a message box with three ambiguous buttons
    (ask 14's idiom: the option and the act of choosing it are the same thing), so
    clicking a card answers and closes. Cancel is a plain button because backing out
    is not one of the options — it is the absence of one.
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("HugMesh Image Studio is already open")
        self.setModal(True)
        self.choice = CHOICE_CANCEL
        lay = QtWidgets.QVBoxLayout(self)
        head = QtWidgets.QLabel(
            "A HugMesh Image Studio is already open on this machine.\n"
            "What would you like to do?")
        head.setWordWrap(True)
        lay.addWidget(head)

        self.group = ChoiceCardGroup(self)
        self.new_card = ChoiceCard(
            "Open a new Studio window",
            "Leave the open window exactly as it is and start a second one. Both "
            "windows share the same Studio, so one tray icon still shows every build.")
        self.new_card.setProperty("choice", CHOICE_NEW_WINDOW)
        self.reset_card = ChoiceCard(
            "Take the open window back to the start",
            "Return the window that is already open to the first wizard screen. "
            "Builds already running KEEP RUNNING in the background.")
        self.reset_card.setProperty("choice", CHOICE_RESET)
        for i, card in enumerate((self.new_card, self.reset_card)):
            self.group.add_card(card, i)
            card.clicked.connect(lambda _=False, c=card: self._pick(c))
            lay.addWidget(card)

        row = QtWidgets.QHBoxLayout()
        row.addStretch(1)
        cancel = QtWidgets.QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        row.addWidget(cancel)
        lay.addLayout(row)

    def _pick(self, card) -> None:
        """Choosing IS proceeding: the card click records the answer and accepts."""
        try:
            self.choice = card.property("choice") or CHOICE_CANCEL
            self.accept()
        except Exception:
            _log_swallowed("AlreadyRunningDialog._pick")
            self.reject()


def ask_already_running(parent=None) -> str:
    """Run the dialog; return ``CHOICE_NEW_WINDOW`` / ``CHOICE_RESET`` / ``""``."""
    dlg = AlreadyRunningDialog(parent)
    if dlg.exec() != QtWidgets.QDialog.DialogCode.Accepted:
        return CHOICE_CANCEL
    return dlg.choice


# ── the shell ────────────────────────────────────────────────────────────────────────
class StudioShell(QtCore.QObject):
    """Owns the Studio's windows, its tray, and the command channel from later launches.

    Deliberately NOT a widget: it outlives every window it opens, which is the whole
    point of a shell in a world where builds keep running after a window closes.
    """

    def __init__(self, generator_dir: str, *,
                 remember_roles_for_passwordless_login: bool = False,
                 login_manifest_path: str | None = None,
                 server: "instance.InstanceServer | None" = None,
                 parent=None):
        super().__init__(parent)
        self.generator_dir = generator_dir
        self.remember_roles_for_passwordless_login = remember_roles_for_passwordless_login
        self.login_manifest_path = login_manifest_path
        self.server = server
        self.windows: list = []
        self.build_windows: list = []
        self.tray = None
        self._drain = None
        # OPT-IN, and app.py is the only caller that sets it (see enable_autoquit).
        # Default OFF so constructing a shell can never quit somebody else's
        # QApplication — a test suite's, most of all.
        self.autoquit = False
        self._watching_builds = False
        if server is not None and server.listening:
            # Commands arrive on a SOCKET thread and are queued; they are executed here,
            # on the GUI thread, where touching a widget is legal.
            self._drain = QtCore.QTimer(self)
            self._drain.setInterval(250)
            self._drain.timeout.connect(self._drain_commands)
            self._drain.start()

    # ---- windows -------------------------------------------------------------------
    def open_window(self):
        """Mint a REAL additional Studio window (ask 16's "open a new studio window").

        Every window gets its own :class:`StudioWizard` — its own config, its own page
        state — so two windows are two independent pieces of work, not two views of one.
        They share the process, which is what lets one tray icon list every build.
        """
        from .wizard import StudioWizard
        wiz = StudioWizard(
            self.generator_dir,
            remember_roles_for_passwordless_login=self.remember_roles_for_passwordless_login,
            login_manifest_path=self.login_manifest_path)
        self.windows.append(wiz)
        try:
            wiz.finished.connect(lambda _code=0, w=wiz: self._on_window_closed(w))
        except Exception:                        # pragma: no cover - defence in depth
            _log_swallowed("StudioShell.open_window(connect)")
        wiz.show()
        wiz.raise_()
        return wiz

    def reset_to_start(self):
        """Ask 16's other branch: return the CURRENT window to the initial wizard
        screen while builds continue in the background.

        ``QWizard.restart()`` walks the flow back to the first page without touching
        any running build — the run is the supervisor's, not the window's. If no window
        is open (everything was closed to the tray) this opens one, because "return the
        current window to the start" with nothing to return means "give me the start".
        """
        wiz = self.current_window()
        if wiz is None:
            return self.open_window()
        try:
            wiz.restart()
        except Exception:
            _log_swallowed("StudioShell.reset_to_start")
        wiz.show()
        wiz.raise_()
        wiz.activateWindow()
        return wiz

    def open_or_raise(self):
        """The tray's "Open Image Studio…": bring back the window that exists, or make
        one if none does. Deliberately NOT open_window() — a tray click is "show me the
        Studio", and answering it with a fresh empty wizard every time would bury the
        operator's in-progress configuration under new windows."""
        wiz = self.current_window()
        if wiz is None:
            return self.open_window()
        wiz.show()
        wiz.raise_()
        wiz.activateWindow()
        return wiz

    def current_window(self):
        """The window a "return to the start" should act on: the most recently opened
        one that still exists."""
        for wiz in reversed(self.windows):
            try:
                wiz.isVisible()                  # probes the C++ object is alive
            except RuntimeError:                 # pragma: no cover - deleted under us
                continue
            return wiz
        return None

    def _on_window_closed(self, wiz) -> None:
        """A window closed. The build is NOT stopped (build_supervisor owns it); we only
        decide whether the process still has a reason to exist."""
        try:
            self._sync_lifetime()
        except Exception:
            _log_swallowed("StudioShell._on_window_closed")

    def _sync_lifetime(self) -> None:
        """Keep the process alive exactly as long as it is useful.

        A tray icon is always a reason to stay. So is a running build — otherwise
        closing the last window on a tray-less desktop would quit the app, fire
        ``aboutToQuit``, and cancel the very build ask 16 exists to protect. With no
        tray, no window and nothing building, there is nothing left to be, so we quit
        rather than linger as an invisible process the operator cannot reach.

        Qt's own ``quitOnLastWindowClosed`` cannot express that rule (it knows about
        windows and nothing else), so it is turned OFF and this decides instead — but
        only when :attr:`autoquit` was explicitly enabled by the launch path.

        Three things can change the answer, and all three must call this: a window
        closing, a build window closing, and a BUILD ENDING. The last one used to be
        missing entirely — see :meth:`_watch_builds_for_lifetime`.
        """
        app = QtWidgets.QApplication.instance()
        if app is None:
            return
        building = build_supervisor.supervisor().count() > 0
        app.setQuitOnLastWindowClosed(False)
        if not self.autoquit or self.tray is not None or building:
            return
        if any(w.isVisible() for w in self.windows if _alive(w)):
            return
        # VISIBLE build windows only. A closed-but-not-destroyed QWidget stays in this
        # list until Qt collects it, and treating one as "a reason to stay" left a
        # tray-less Studio running forever as a process with nothing on screen.
        if any(w.isVisible() for w in self.build_windows if _alive(w)):
            return
        app.quit()

    def enable_autoquit(self, enabled: bool = True) -> None:
        """Let this shell quit the process when nothing is left to be (see
        :meth:`_sync_lifetime`). app.py enables it for the real launch; nothing else
        should, because quitting an application you do not own is not a shell's call.

        Enabling it ALSO turns Qt's own ``quitOnLastWindowClosed`` off, here and now.
        That flag knows about windows and nothing else: left on, closing the last window
        of a tray-less Studio quits the app, which fires ``aboutToQuit``, which cancels
        every running build — the exact thing ask 16 exists to prevent. Doing it at the
        moment the launch path hands lifetime over (rather than on the first window
        close) means the guarantee never depends on which of Qt's two signals happens to
        fire first.
        """
        self.autoquit = bool(enabled)
        if self.autoquit:
            app = QtWidgets.QApplication.instance()
            if app is not None:
                app.setQuitOnLastWindowClosed(False)
            self._watch_builds_for_lifetime()

    def _watch_builds_for_lifetime(self) -> None:
        """Re-decide lifetime whenever the build roster changes.

        ``_sync_lifetime`` was only ever reached from a window or build-window closing,
        so the one case ask 16 actually creates had no trigger at all: on a tray-less
        desktop, closing the last window WHILE A BUILD RUNS correctly declines to quit —
        and then nothing ever asked again once the build ended. With
        ``quitOnLastWindowClosed`` already turned off, the process stayed alive forever
        with no window, no tray and nothing building: exactly the "invisible process the
        operator cannot reach" that ``_sync_lifetime``'s own docstring says it quits
        rather than becomes.

        Subscribed HERE rather than in ``__init__`` because this is the moment the launch
        path hands lifetime over; a shell that was never given it must not be quitting
        anybody's application off a background signal. Connected once (the launch path
        may enable autoquit more than once), and the supervisor is process-global while
        this shell is a QObject, so Qt drops the connection when the shell dies.
        """
        if self._watching_builds:
            return
        try:
            build_supervisor.supervisor().changed.connect(self._on_builds_changed)
            self._watching_builds = True
        except Exception:                        # pragma: no cover - defence in depth
            _log_swallowed("StudioShell._watch_builds_for_lifetime")

    def _on_builds_changed(self) -> None:
        """The build roster changed — re-evaluate lifetime on the NEXT event-loop turn.

        Deferred deliberately: ``changed`` is emitted from inside the worker's
        ``finished_all``, alongside the page's OWN finish handler, and quitting
        synchronously could tear the process down before the page had written the
        session's final record. A zero-timer lets every other handler for that signal
        run first.
        """
        try:
            QtCore.QTimer.singleShot(0, self._safe_sync_lifetime)
        except Exception:                        # pragma: no cover - defence in depth
            _log_swallowed("StudioShell._on_builds_changed")

    def _safe_sync_lifetime(self) -> None:
        """:meth:`_sync_lifetime` as a Qt slot — guarded, because an exception escaping
        one calls qFatal under the operator's PyQt6 binding."""
        try:
            self._sync_lifetime()
        except Exception:                        # pragma: no cover - defence in depth
            _log_swallowed("StudioShell._safe_sync_lifetime")

    # ---- builds --------------------------------------------------------------------
    def open_build_window(self, session):
        """Open a window for one build (the tray submenu's action).

        If the build is running in THIS process, its own Studio window already shows it
        live — raise that, rather than opening a second, poorer view of the same run.
        Otherwise (another Studio, another host, a finished record) open the per-build
        window, which states exactly what is and is not possible for it.
        """
        sid = getattr(session, "id", "")
        live = build_supervisor.supervisor().find(sid) if sid else None
        if live is not None and live.window is not None and _alive(live.window):
            live.window.show()
            live.window.raise_()
            live.window.activateWindow()
            return live.window
        from .pages import build_window as bw
        from .pages import sessions_widget as sw
        row = sw._RowData("session", session=session)
        # EVERY action gets a handler. A BuildActionsWindow built without one shows a
        # button that looks alive and does nothing when clicked — the dead button ask 15
        # forbids — and BuildActionsWindow.offered() now refuses to enable such a button
        # at all, so an unwired window from here would simply offer nothing.
        win = bw.BuildActionsWindow(
            row,
            on_resume=lambda r: self._delegate(r, "resume"),
            on_artifacts=lambda r: self._delegate(r, "artifacts"),
            on_edit=lambda r: self._delegate(r, "edit"),
            on_delete=lambda r: self._delegate(r, "delete"),
            on_log=lambda r: self._delegate(r, "log"),
            parent=self.current_window())
        self.build_windows.append(win)
        try:
            win.destroyed.connect(
                lambda *_a, w=win: self._forget_build_window(w))
            # A build window going off screen is a lifetime event too: with no tray and
            # no wizard left, it may be the last thing on screen.
            win.closed.connect(self._sync_lifetime)
        except Exception:                        # pragma: no cover - defence in depth
            _log_swallowed("StudioShell.open_build_window(connect)")
        win.show()
        win.raise_()
        return win

    def _forget_build_window(self, win) -> None:
        try:
            if win in self.build_windows:
                self.build_windows.remove(win)
            self._sync_lifetime()
        except Exception:                        # pragma: no cover - defence in depth
            _log_swallowed("StudioShell._forget_build_window")

    def builds_manager(self):
        """The Studio's ONE builds manager (``SessionsPage.previous_builds``), opening a
        Studio window if none is up.

        Resume / edit / delete run THROUGH it rather than being re-implemented here: it
        owns every guard — ``can_restart``, the missing-held-secrets refusal, the fleet
        routing, the delete confirmation and its opt-in rmtree — and a second copy would
        drift from it the first time one of those changed.
        """
        wiz = self.open_or_raise()
        for pid in (wiz.pageIds() if hasattr(wiz, "pageIds") else []):
            pb = getattr(wiz.page(pid), "previous_builds", None)
            if pb is not None:
                return pb
        return None                              # pragma: no cover - SessionsPage is fixed

    def _delegate(self, row, name: str) -> bool:
        """Carry out one per-build action from a tray-opened window.

        The record is RE-READ from disk first: this window may have been sitting open
        for an hour, and acting on the stale row we were handed would be acting on a
        build that no longer looks like that. If the record is gone, say so rather than
        pretend.
        """
        try:
            pb = self.builds_manager()
            if pb is None:                       # pragma: no cover - SessionsPage is fixed
                return False
            pb.refresh()
            # ONE re-resolution rule, shared with the widget: by row IDENTITY, which
            # every row kind has. Keying on session.id alone refused every action on a
            # row that has no session record (an unmanaged tree, an unreadable record).
            from .pages import sessions_widget as _sw
            fresh = pb.row_for_identity(_sw.row_identity(row))
            if fresh is None:
                QtWidgets.QMessageBox.warning(
                    self.current_window(), "Build no longer listed",
                    "This build's record is no longer on disk — another Studio may "
                    "have deleted it.")
                return False
            return pb.act_on_row(fresh, name)
        except Exception:
            _log_swallowed(f"StudioShell._delegate({name})")
            return False

    # ---- tray ----------------------------------------------------------------------
    def install_tray(self, *, show_mesh: bool = True, show_stack: bool = True,
                     on_open_golive=None, builds_provider=None):
        """Build the ONE tray icon, wired to this shell's windows and build roster."""
        self.tray = tray_mod.build_tray(
            self.generator_dir, show_mesh=show_mesh, show_stack=show_stack,
            on_open_studio=self.open_or_raise, on_open_golive=on_open_golive,
            on_open_build=self.open_build_window, builds_provider=builds_provider)
        return self.tray

    # ---- the command channel from later launches -----------------------------------
    def _drain_commands(self) -> None:
        try:
            if self.server is None:
                return
            for cmd in self.server.drain():
                self.handle_command(cmd)
        except Exception:
            _log_swallowed("StudioShell._drain_commands")

    def handle_command(self, command: str):
        """Execute one command from a later launch. Unknown commands are IGNORED, not
        guessed at — a future Studio talking to an older one must be inert, never
        surprising."""
        if command == instance.CMD_NEW_WINDOW:
            return self.open_window()
        if command == instance.CMD_RESET:
            return self.reset_to_start()
        return None

    # ---- teardown -------------------------------------------------------------------
    def install_quit_guard(self, app) -> None:
        """A REAL exit cancels every running build (orphaning a builder would be worse)
        — and ONLY a real exit. A window close never reaches here."""
        try:
            app.aboutToQuit.connect(
                lambda: build_supervisor.supervisor().cancel_all())
            if self.server is not None:
                app.aboutToQuit.connect(self.server.close)
        except Exception:                        # pragma: no cover - defence in depth
            _log_swallowed("StudioShell.install_quit_guard")


def _alive(widget) -> bool:
    """True when the widget's C++ object still exists (PySide6 and PyQt6 both raise
    RuntimeError on a deleted wrapper, from different messages)."""
    try:
        widget.isVisible()
        return True
    except RuntimeError:
        return False
