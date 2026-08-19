"""TUI entry point — decide ONCE between the urwid face and the plain fallback.

The decision mirrors scripts/build-menu.sh's whiptail gate line for line (its
``HAVE_TUI`` block): the rich renderer is used only when ``NO_TUI`` is unset, stdin
AND stdout are interactive TTYs, ``TERM`` is not dumb, and the renderer (urwid here,
whiptail there) is actually present. Anything else degrades to the plain
numbered-prompt loop — with the menu's own warning wording — never a crash.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import sys

from ..core import build_sessions, crashlog

__all__ = ["have_tui", "main"]

#: The degradation notice — the Python twin of build-menu.sh's
#: "whiptail/TTY not available — using the plain text menu …" warn line.
FALLBACK_NOTICE = ("urwid/TTY not available — using the plain text prompts "
                   "(set NO_TUI= to re-enable; install dev-python/urwid for the "
                   "rich UI — it is ~arch on Gentoo, see studio/README.md).")


def have_tui(stdin=None, stdout=None) -> bool:
    """True when the rich urwid renderer is usable — build-menu.sh's gate, ported:
    ``NO_TUI`` unset, a real interactive TTY on both ends, a sane ``TERM``, and
    urwid importable. Checked with ``find_spec`` so a *no* never half-imports it."""
    if os.environ.get("NO_TUI"):
        return False
    stdin = stdin if stdin is not None else sys.stdin
    stdout = stdout if stdout is not None else sys.stdout
    try:
        if not (stdin.isatty() and stdout.isatty()):
            return False
    except (AttributeError, ValueError):
        return False                       # closed/replaced streams: not a TTY
    if os.environ.get("TERM", "dumb") == "dumb":
        return False
    try:
        return importlib.util.find_spec("urwid") is not None
    except (ImportError, ValueError):
        return False


def _load_session(session_id: str) -> build_sessions.BuildSession | None:
    path = os.path.join(build_sessions.sessions_dir(), f"{session_id}.json")
    try:
        return build_sessions.load(path)
    except (OSError, ValueError):
        return None


def main(argv=None, *, inp=None, out=None) -> int:
    """``python -m hugmesh_studio.tui`` — see the package docstring for the flows.

    ``inp``/``out`` exist for the headless tests: they drive the PLAIN face with
    scripted streams (a non-TTY stream also disables the rich face by itself)."""
    crashlog.install()                     # same first-thing rule as the GUI entry point
    ap = argparse.ArgumentParser(
        prog="python -m hugmesh_studio.tui",
        description="HugMesh Image Studio — terminal UI (parity lane). "
                    "Default flow: sessions review (durable build history).")
    ap.add_argument("--worklist", metavar="SESSION_ID",
                    help="read-only worklist TABLE for one recorded session "
                         "(rows + per-image status) instead of the sessions review")
    ap.add_argument("--plain", action="store_true",
                    help="force the plain numbered-prompt fallback (same as NO_TUI=1)")
    args = ap.parse_args(argv)

    rich = not args.plain and inp is None and out is None and have_tui()
    err = sys.stderr
    if not rich:
        print(FALLBACK_NOTICE, file=err)

    if args.worklist:
        session = _load_session(args.worklist)
        if session is None:
            print(f"error: no readable session record named {args.worklist!r} "
                  f"under {build_sessions.sessions_dir()}", file=err)
            return 2
        if rich:
            from . import urwid_ui
            return urwid_ui.run_worklist(session)
        from . import plain
        plain.print_worklist(out if out is not None else sys.stdout, session)
        return 0

    if rich:
        from . import urwid_ui
        return urwid_ui.run_sessions_review()
    from . import plain
    return plain.run_sessions_review(inp=inp, out=out)


if __name__ == "__main__":
    raise SystemExit(main())
