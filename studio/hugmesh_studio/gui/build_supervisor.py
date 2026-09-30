"""BuildSupervisor — the process-wide owner of RUNNING builds, independent of windows.

Ask 16, stated plainly: *builds must keep running when a window closes.* Before this
module they did not. ``ProgressPage.__init__`` did::

    self.wiz.finished.connect(self._abort_run)

and ``QWizard`` is a ``QDialog``, so ``finished`` fires on an ordinary window CLOSE —
closing the Studio window cancelled the builder and joined the worker thread. "Builds
continue in the background" was not merely unimplemented; the opposite was wired up.

The fix is ownership, not a flag. A run is registered here as a :class:`RunningBuild`,
and this object — a ``QObject`` living on the ``QApplication`` — becomes:

* the worker ``QThread``'s **Qt parent**, so no window's destruction can take it;
* the holder of a **strong reference to the owning window** for as long as the run is
  live. That is the real defence against the crash the ``_DetachedLogWindow`` docstring
  documents: if a window were destroyed under a live worker, the next streamed line
  would hit a deleted C++ object inside a Qt SLOT — which under PyQt6 calls qFatal and
  ABORTS the Studio. Keeping the window object alive until its build finishes means
  the page's slots always have somewhere to land, whether or not a human can see it.

What this module deliberately does NOT do: interpret build output, write session
records, or paint anything. The page keeps all of that. This is lifetime and a roster
— the tray's "Running builds" submenu and the per-build windows both read
:meth:`BuildSupervisor.running` — and nothing else.

Cancellation still exists, but only where it is honest: :meth:`cancel_all` is wired to
``QApplication.aboutToQuit`` (a real exit tears the process down, so orphaning a
builder there would be worse), never to a window close. It does not write the session
record itself — it CALLS BACK the owner that does (``on_cancelled``), because a build
the Studio really stopped must be recorded "stopped", not left at "running" with a dead
pid for the build list to render forever as "running (stale?)".

Qt duality: PySide6 in the venv, PyQt6 for the operator. Every slot here is
exception-guarded — an escaping exception in a PyQt6 slot calls qFatal.
"""
from __future__ import annotations

import sys
import time
import traceback

from .qt import QtCore, QtWidgets, Signal

__all__ = ["RunningBuild", "BuildSupervisor", "supervisor", "reset_supervisor"]


def _log_swallowed(where: str) -> None:
    print(f"build_supervisor: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


class RunningBuild:
    """One live build run, owned by the supervisor rather than by any window."""

    def __init__(self, *, session_id: str, label: str, worker, driver,
                 window=None, workdir: str = "", kind: str = "wizard",
                 on_cancelled=None):
        self.session_id = session_id
        self.label = label or session_id or "build"
        self.worker = worker
        self.driver = driver
        # Called by cancel_all() once the run is really stopped, so the OWNER can write
        # the honest "stopped" record. The supervisor never writes one itself.
        self.on_cancelled = on_cancelled
        # STRONG on purpose (see the module docstring): the window may not be
        # destroyed while its worker is still emitting into its page's slots.
        self.window = window
        self.workdir = workdir
        self.kind = kind
        self.started = time.time()
        self.finished = False
        self.exit_code: int | None = None

    # ---- honesty helpers (pure, unit-testable) ----------------------------------
    def is_running(self) -> bool:
        """True while the run is live. ``finished`` is set by the supervisor's own
        slot; the thread probe is the belt-and-braces second opinion for a worker that
        died without emitting (a crash), so we never advertise a build that does not exist."""
        if self.finished:
            return False
        w = self.worker
        if w is None:
            return False
        try:
            return bool(w.isRunning())
        except RuntimeError:
            return False              # the C++ worker is gone: honestly not running

    def elapsed(self) -> float:
        return max(0.0, time.time() - self.started)

    def menu_text(self) -> str:
        """The tray submenu row for this build: label + elapsed mm:ss."""
        secs = int(self.elapsed())
        return f"{self.label} — {secs // 60}:{secs % 60:02d}"


class BuildSupervisor(QtCore.QObject):
    """Process-wide roster of running builds. One per process; see :func:`supervisor`."""

    #: emitted whenever the roster changes (adopt / finish / cancel) — the tray and any
    #: build window re-read :meth:`running` from it rather than polling.
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._builds: list[RunningBuild] = []

    # ---- registration ------------------------------------------------------------
    def adopt(self, *, session_id: str, label: str, worker, driver,
              window=None, workdir: str = "", kind: str = "wizard",
              on_cancelled=None) -> RunningBuild:
        """Take ownership of a dispatched run. Called by the page at dispatch, BEFORE
        ``worker.start()``.

        Reparents the worker to the supervisor and pins the owning window, so from here
        on the run's lifetime is the process's, not a window's. ``on_cancelled`` is the
        owner's "write the stopped record" hook, invoked only by :meth:`cancel_all`.
        """
        build = RunningBuild(session_id=session_id, label=label, worker=worker,
                             driver=driver, window=window, workdir=workdir, kind=kind,
                             on_cancelled=on_cancelled)
        try:
            if worker is not None and hasattr(worker, "setParent"):
                worker.setParent(self)          # Qt ownership leaves the page/window
        except (RuntimeError, TypeError):
            _log_swallowed("BuildSupervisor.adopt(setParent)")
        try:
            if worker is not None and hasattr(worker, "finished_all"):
                worker.finished_all.connect(
                    lambda code, b=build: self._on_finished(b, code))
        except (RuntimeError, TypeError):
            _log_swallowed("BuildSupervisor.adopt(connect)")
        self._builds.append(build)
        self._emit_changed()
        return build

    def _on_finished(self, build: RunningBuild, code=None) -> None:
        try:
            build.finished = True
            build.exit_code = code
            # release the window pin: with the run over, the shell (or Python's GC)
            # may finally let a closed window go.
            build.window = None
            self._emit_changed()
        except Exception:
            _log_swallowed("BuildSupervisor._on_finished")

    def release(self, build: RunningBuild) -> None:
        """Drop a finished build from the roster (the page calls this when it resets)."""
        if build in self._builds:
            self._builds.remove(build)
            self._emit_changed()

    # ---- reads --------------------------------------------------------------------
    def running(self) -> list[RunningBuild]:
        """The builds that are ACTUALLY running right now, oldest first. Finished rows
        are reaped here rather than lingering as tray entries for builds that no longer exist."""
        live = [b for b in self._builds if b.is_running()]
        if len(live) != len(self._builds):
            for b in list(self._builds):
                if not b.is_running():
                    b.finished = True
                    b.window = None
            self._builds = [b for b in self._builds if b.is_running()]
        return list(live)

    def find(self, session_id: str) -> RunningBuild | None:
        for b in self._builds:
            if b.session_id and b.session_id == session_id:
                return b
        return None

    def count(self) -> int:
        return len(self.running())

    # ---- teardown ------------------------------------------------------------------
    def cancel_all(self, wait_ms: int = 3000) -> int:
        """Cancel + join every live run. Wired to ``QApplication.aboutToQuit`` ONLY —
        a real process exit, where orphaning a builder would be worse than stopping it.
        A window close must never reach here. Returns how many runs were cancelled."""
        n = 0
        for b in list(self._builds):
            if not b.is_running():
                continue
            n += 1
            try:
                if b.driver is not None:
                    b.driver.cancel_all()
            except Exception:
                _log_swallowed("BuildSupervisor.cancel_all(driver)")
            try:
                if b.worker is not None:
                    b.worker.wait(wait_ms)
            except Exception:
                _log_swallowed("BuildSupervisor.cancel_all(join)")
            # The run really stopped, so let its owner say so on disk. Guarded: this
            # runs from aboutToQuit, and an exception escaping there under PyQt6 aborts
            # the process mid-teardown.
            try:
                if b.on_cancelled is not None:
                    b.on_cancelled()
            except Exception:
                _log_swallowed("BuildSupervisor.cancel_all(on_cancelled)")
            b.finished = True
            b.window = None
        self._builds = []
        self._emit_changed()
        return n

    def _emit_changed(self) -> None:
        try:
            self.changed.emit()
        except Exception:
            _log_swallowed("BuildSupervisor._emit_changed")


_SUPERVISOR: BuildSupervisor | None = None


def supervisor() -> BuildSupervisor:
    """The process's one supervisor, parented to the ``QApplication`` when there is
    one (so it outlives every window and dies with the process, not with a page)."""
    global _SUPERVISOR
    if _SUPERVISOR is None:
        app = QtWidgets.QApplication.instance()
        _SUPERVISOR = BuildSupervisor(app)
    return _SUPERVISOR


def reset_supervisor() -> None:
    """Drop the singleton (tests only — never called by the Studio)."""
    global _SUPERVISOR
    _SUPERVISOR = None
