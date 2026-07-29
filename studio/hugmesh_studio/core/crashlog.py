"""Crash evidence for the Studio — write a traceback somewhere it can be found.

WHY THIS EXISTS. On 2026-07-29 the operator reported "both x86 and pi mesh builds
failed and the pi one crashed the gui". Reconstructing it was only possible from
build artifacts and file mtimes, because the GUI left NOTHING behind:

  * the x86 entry failed at 07:52 (a false-positive completeness gate, fixed in #465);
  * the GUI died at that same minute — its session record's last write;
  * the rpi5 entry then ran on headless to a COMPLETE, successful image at 09:31,
    with nothing to record it, so the operator reasonably concluded it had failed too.

There was no traceback anywhere on disk. Under PyQt6 there would not be: an
unhandled Python exception raised inside a slot calls ``qFatal()``, which aborts the
process — and when the Studio is launched from a desktop entry rather than a
terminal, whatever it printed to stderr goes nowhere. (PySide6 is more forgiving,
which is exactly why a crash that only bites one binding can go unexplained for
weeks. The gui/qt.py shim supports both, so the Studio must not depend on which one
the operator installed.)

So: install an excepthook that persists the traceback under the same state dir the
session records use, and CHAIN to the previous hook so the existing stderr behaviour
is byte-identical. This module is Qt-free and safe to import before any binding is
loaded — it is installed as early as possible in app.main(), so a crash while the
wizard is still being constructed is captured too.

Deliberately NOT a crash dialog: a process that PyQt6 is about to ``abort()`` cannot
be relied upon to paint a window. A file always survives.
"""
from __future__ import annotations

import datetime
import os
import sys
import traceback

_MAX_KEPT = 20          # newest N crash files; older ones are pruned on each write


def crashes_dir() -> str:
    """``<state>/crashes``. Honours ``$HUGMESH_STUDIO_STATE_DIR`` exactly like
    :func:`build_sessions.sessions_dir`, so tests (and a hygiene run) never write to
    the real ``~/.hugmesh``."""
    base = os.environ.get("HUGMESH_STUDIO_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".hugmesh", "studio")
    return os.path.join(base, "crashes")


def _qt_binding() -> str:
    """Which Qt binding is actually loaded, and its version — the single most useful
    fact for a crash that reproduces on one binding and not the other. Read from
    sys.modules ONLY: importing a binding here could itself fail, and this runs while
    the process is already dying."""
    for name in ("PyQt6.QtCore", "PySide6.QtCore"):
        mod = sys.modules.get(name)
        if mod is None:
            continue
        ver = (getattr(mod, "QT_VERSION_STR", "")
               or getattr(mod, "__version__", "") or "?")
        return f"{name.split('.')[0]} (Qt {ver})"
    return "none loaded"


def _prune(d: str) -> None:
    try:
        files = sorted(
            (os.path.join(d, f) for f in os.listdir(d) if f.endswith(".log")),
            key=os.path.getmtime, reverse=True)
        for old in files[_MAX_KEPT:]:
            os.unlink(old)
    except OSError:
        pass            # pruning is housekeeping; never let it mask the crash


def write(exc_type, exc, tb, *, context: str = "") -> str:
    """Persist one traceback; return the path written ("" if it could not be).

    Every failure mode here is swallowed: this runs on the way down, and an
    exception raised by the crash handler would replace the real crash with a
    confusing one.
    """
    try:
        d = crashes_dir()
        os.makedirs(d, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        path = os.path.join(d, f"crash-{stamp}.log")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(f"HugMesh Studio crash\n")
            fh.write(f"when:        {datetime.datetime.now().isoformat()}\n")
            fh.write(f"context:     {context or 'main thread'}\n")
            fh.write(f"argv:        {' '.join(sys.argv)}\n")
            fh.write(f"python:      {sys.version.split()[0]} ({sys.executable})\n")
            fh.write(f"qt binding:  {_qt_binding()}\n")
            fh.write(f"cwd:         {os.getcwd()}\n\n")
            traceback.print_exception(exc_type, exc, tb, file=fh)
        _prune(d)
        return path
    except Exception:                                    # noqa: BLE001 — see docstring
        return ""


def install() -> None:
    """Install the process-wide hooks. Idempotent: installing twice does not chain the
    handler to itself (which would write two files per crash)."""
    if getattr(sys.excepthook, "_hugmesh_crashlog", False):
        return
    previous = sys.excepthook

    def _hook(exc_type, exc, tb):
        path = write(exc_type, exc, tb)
        if path:
            # Also say it out loud: when the Studio IS attached to a terminal this
            # line is what points the operator (or a support request) at the file.
            try:
                sys.stderr.write(f"\n[hugmesh-studio] crash log written to {path}\n")
            except Exception:                            # noqa: BLE001
                pass
        previous(exc_type, exc, tb)                      # unchanged stderr behaviour

    _hook._hugmesh_crashlog = True                       # type: ignore[attr-defined]
    sys.excepthook = _hook

    # Worker threads do not go through sys.excepthook (PEP 3151 / threading.excepthook).
    # The Studio runs its builds on a QThread-driven worker, so an exception there is
    # exactly the kind that used to vanish.
    if hasattr(sys.modules.get("threading"), "excepthook"):
        import threading
        if not getattr(threading.excepthook, "_hugmesh_crashlog", False):
            prev_t = threading.excepthook

            def _thook(args):
                write(args.exc_type, args.exc_value, args.exc_traceback,
                      context=f"thread {getattr(args.thread, 'name', '?')}")
                prev_t(args)

            _thook._hugmesh_crashlog = True              # type: ignore[attr-defined]
            threading.excepthook = _thook
