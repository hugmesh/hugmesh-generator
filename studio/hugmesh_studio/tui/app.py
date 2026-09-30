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


def _default_generator_dir() -> str:
    # studio/ lives inside the generator repo; default to the repo root (the
    # same derivation the GUI entry point uses).
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(os.path.join(here, "..", "..", ".."))
    if os.path.exists(os.path.join(repo, "build-x86-host-stage4.sh")):
        return repo
    return os.getcwd()


def main(argv=None, *, inp=None, out=None) -> int:
    """``python -m hugmesh_studio.tui`` — see the package docstring for the flows.

    ``inp``/``out`` exist for the headless tests: they drive the PLAIN face with
    scripted streams (a non-TTY stream also disables the rich face by itself)."""
    crashlog.install()                     # same first-thing rule as the GUI entry point
    ap = argparse.ArgumentParser(
        prog="python -m hugmesh_studio.tui",
        description="HugMesh Image Studio — terminal UI (parity lane). "
                    "Default flow: the guided journey (welcome screen first, "
                    "the GUI wizard's canonical page order).")
    ap.add_argument("--generator-dir", default=_default_generator_dir(),
                    help="path to the hugmesh-generator checkout")
    ap.add_argument("--sessions", action="store_true",
                    help="open the sessions review (durable build history) "
                         "directly — the pre-#67 default screen, demoted to a "
                         "welcome entry point")
    ap.add_argument("--worklist", metavar="SESSION_ID",
                    help="read-only worklist TABLE for one recorded session "
                         "(rows + per-image status) instead of the journey")
    ap.add_argument("--meshemu", metavar="SESSION_NAME",
                    help="whole-mesh emulation status list for one artifact "
                         "session (per-device boot/ssh/provision/web) instead "
                         "of the journey")
    ap.add_argument("--fleet", action="store_true",
                    help="open the fleet build (build-all-roles.sh) flow directly — "
                         "the GUI's `hugmesh_studio --fleet` window, TUI face (#587)")
    ap.add_argument("--go-live", dest="go_live", action="store_true",
                    help="open the Go-Live flow directly — provider, the domain this "
                         "run exposes, and the per-domain exposure plan (#587)")
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

    if args.meshemu:
        from . import plain
        if not plain.print_meshemu(out if out is not None else sys.stdout,
                                   args.generator_dir, args.meshemu):
            print(f"error: no artifact session named {args.meshemu!r} with "
                  f"bootable images under {args.generator_dir}/out/sessions",
                  file=err)
            return 2
        return 0

    if args.sessions:
        if rich:
            from . import urwid_ui
            return urwid_ui.run_sessions_review()
        from . import plain
        return plain.run_sessions_review(inp=inp, out=out)

    start = "fleet" if args.fleet else ("golive" if args.go_live else None)
    if rich:
        from . import urwid_ui
        return urwid_ui.run_journey(args.generator_dir, start=start)
    from . import plain
    return plain.run_journey(inp=inp, out=out, generator_dir=args.generator_dir,
                             start=start)


if __name__ == "__main__":
    raise SystemExit(main())
