"""The plain-prompt fallback face — the TUI's NO_TUI degradation path.

The Python twin of scripts/build-menu.sh's numbered text menu: when urwid (or a
usable TTY) is absent the flows still run, over exactly the same :mod:`.model` rows
the rich face renders. Line-oriented ``input()``-style prompts only — no cursor
addressing, safe on a dumb terminal, in the Docker builder image and under a test
harness feeding scripted stdin.

Every function takes injectable ``inp``/``out`` streams so the headless tests drive
it without a TTY and without urwid installed.
"""
from __future__ import annotations

import sys
from typing import IO

from ..core import build_sessions
from . import model

__all__ = ["run_sessions_review", "print_worklist", "prompt_yes_no"]


def _say(out: IO[str], text: str = "") -> None:
    out.write(text + "\n")


def _prompt(inp: IO[str], out: IO[str], prompt: str) -> str | None:
    """One line of input; ``None`` on EOF (the scripted/piped-stdin quit signal)."""
    out.write(prompt)
    out.flush()
    line = inp.readline()
    if line == "":
        _say(out)                     # keep the transcript readable after EOF
        return None
    return line.strip()


def prompt_yes_no(inp: IO[str], out: IO[str], question: str) -> bool:
    """A y/N confirm (default NO, like the menu's ui_yesno text fallback)."""
    answer = _prompt(inp, out, f"{question} [y/N] ")
    return answer is not None and answer.lower() in ("y", "yes")


# ── sessions review ────────────────────────────────────────────────────────────────
_HELP = ("commands: NUMBER=inspect · d NUMBER=delete · w NUMBER=worklist table · "
         "r=refresh · q=quit")


def _print_list(out: IO[str], rows: list[model.SessionRow], unreadable: list[str]) -> None:
    _say(out, "previous builds (newest first):")
    if not rows:
        _say(out, "  (no build sessions recorded yet)")
    for i, row in enumerate(rows, 1):
        _say(out, "  " + model.session_line(row, i))
    for path in unreadable:
        _say(out, f"  ! unreadable record skipped: {path}")
    _say(out, _HELP)


def _pick(rows: list[model.SessionRow], token: str) -> model.SessionRow | None:
    try:
        index = int(token)
    except ValueError:
        return None
    if 1 <= index <= len(rows):
        return rows[index - 1]
    return None


def _delete_flow(inp: IO[str], out: IO[str], row: model.SessionRow) -> None:
    """Delete-with-confirm: refuse an active session WITH the reason, confirm the
    record, then separately confirm the artifact tree (two distinct losses)."""
    s = row.session
    refusal = model.delete_refusal(s)
    if refusal is not None:
        _say(out, f"not deleted: {refusal}")
        return
    if not prompt_yes_no(inp, out, f"delete session {s.id} ({s.label or 'no label'})?"):
        _say(out, "kept.")
        return
    remove_artifacts = False
    if model.artifact_entries(s):
        remove_artifacts = prompt_yes_no(
            inp, out, f"ALSO delete its artifact tree {s.workdir}?")
    if build_sessions.delete(s, remove_artifacts=remove_artifacts):
        _say(out, f"deleted session {s.id}"
                  + (" and its artifacts." if remove_artifacts else " (record only)."))
    else:
        # delete() re-checks activity itself; honour its refusal verbatim.
        _say(out, "not deleted: the session became active again.")


def print_worklist(out: IO[str], s: build_sessions.BuildSession) -> None:
    headers, rows = model.worklist_table(s)
    for line in model.format_table(headers, rows):
        _say(out, line)


def run_sessions_review(inp: IO[str] | None = None, out: IO[str] | None = None) -> int:
    """The SESSIONS REVIEW loop (plain face). Returns a process exit code."""
    inp = inp if inp is not None else sys.stdin
    out = out if out is not None else sys.stdout
    rows, unreadable = model.session_rows()
    _print_list(out, rows, unreadable)
    while True:
        answer = _prompt(inp, out, "> ")
        if answer is None or answer.lower() in ("q", "quit", "exit"):
            return 0
        if answer == "":
            continue
        if answer.lower() in ("r", "refresh"):
            rows, unreadable = model.session_rows()
            _print_list(out, rows, unreadable)
            continue
        verb, _, arg = answer.partition(" ")
        if verb.lower() in ("d", "delete"):
            row = _pick(rows, arg.strip())
            if row is None:
                _say(out, f"no such session number: {arg.strip() or '(missing)'}")
                continue
            _delete_flow(inp, out, row)
            rows, unreadable = model.session_rows()
            _print_list(out, rows, unreadable)
            continue
        if verb.lower() in ("w", "worklist"):
            row = _pick(rows, arg.strip())
            if row is None:
                _say(out, f"no such session number: {arg.strip() or '(missing)'}")
                continue
            print_worklist(out, row.session)
            continue
        row = _pick(rows, verb)
        if row is None:
            _say(out, f"unrecognised command: {answer}")
            _say(out, _HELP)
            continue
        for line in model.session_detail_lines(row):
            _say(out, line)
