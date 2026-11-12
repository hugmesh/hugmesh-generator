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

import getpass
import sys
from typing import IO

from ..core import build_sessions
from . import journey as journey_mod
from . import local_ai
from . import model

__all__ = ["run_journey", "run_sessions_review", "run_local_ai", "print_worklist",
           "print_meshemu", "prompt_yes_no"]


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


def _secret_prompt(inp: IO[str], out: IO[str], prompt: str) -> str | None:
    """One HIDDEN line (the NVD API key): getpass on a real terminal, so nothing is
    echoed; a scripted/piped stdin is read as a plain line and still not echoed.
    ``None`` on EOF, like :func:`_prompt`."""
    isatty = getattr(inp, "isatty", None)
    if inp is sys.stdin and callable(isatty) and isatty():
        try:
            return getpass.getpass(prompt)
        except EOFError:
            _say(out)
            return None
    out.write(prompt)
    out.flush()
    line = inp.readline()
    _say(out)
    if line == "":
        return None
    return line.strip()


def prompt_yes_no(inp: IO[str], out: IO[str], question: str) -> bool:
    """A y/N confirm (default NO, like the menu's ui_yesno text fallback)."""
    answer = _prompt(inp, out, f"{question} [y/N] ")
    return answer is not None and answer.lower() in ("y", "yes")


# ── sessions review ────────────────────────────────────────────────────────────────
_HELP = ("commands: NUMBER=inspect · d NUMBER=delete · w NUMBER=worklist table · "
         "k NUMBER=kernel config · r=refresh · local-ai=the Local AI screen · q=quit")

#: The GUI's other Previous-builds buttons (B-10), on a line of their own ABOVE the
#: commands line, which keeps the Local AI status line directly under that one.
_HELP_BUILDS = ("build actions: s NUMBER=restart · e NUMBER=redo (edit as new) · "
                "a=delete all finished")


def _print_list(out: IO[str], rows: list[model.SessionRow], unreadable: list[str]) -> None:
    _say(out, "previous builds (newest first):")
    if not rows:
        _say(out, "  (no build sessions recorded yet)")
    for i, entry in enumerate(model.list_entries(rows, unreadable), 1):
        _say(out, "  " + (model.unreadable_line(entry, i)
                          if isinstance(entry, model.UnreadableRow)
                          else model.session_line(entry, i)))
    _say(out, _HELP_BUILDS)
    _say(out, _HELP)
    _say(out, local_ai.plain_status_line())


def run_local_ai(inp: IO[str], out: IO[str], generator_dir: str = ".") -> bool:
    """The Local AI screen on its own — where there is no journey underneath (the
    previous-builds review). Returns when the person types ``q``; False on EOF, which
    is the quit signal everywhere in this face and the caller passes on."""
    host = local_ai.Standalone(generator_dir)
    host.open()
    while host.is_open:
        _say(out)
        for line in host.lines():
            _say(out, line)
        _say(out, local_ai.plain_status_line())
        answer = _prompt(inp, out, host.prompt())
        if answer is None:
            return False
        host.feed(answer)
    return True


def _pick(rows: list, token: str):
    """The row numbered ``token`` (1-based) of ``rows``, or None."""
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
        # delete() re-checks activity itself (and on native Windows keeps a session
        # whose tree could not be fully removed); say which refusal it was.
        _say(out, build_sessions.not_deleted_reason(s))


def _delete_unreadable_flow(inp: IO[str], out: IO[str], row: model.UnreadableRow) -> None:
    """An unreadable record: one confirm, then the unlink — and what is true after it."""
    if not prompt_yes_no(inp, out, f"delete this unreadable record file {row.path}?"):
        _say(out, "kept.")
        return
    _ok, said = model.delete_unreadable(row)
    _say(out, said)


def _delete_all_flow(inp: IO[str], out: IO[str], rows: list[model.SessionRow]) -> None:
    """"Delete all finished…": every record but an active build's, through
    ``build_sessions.prune`` — then, as a separate answer defaulting to NO, their
    artifact trees (the GUI's checkbox, which starts unticked)."""
    if not rows:
        _say(out, "nothing to delete: no readable build session is recorded.")
        return
    if not prompt_yes_no(inp, out, model.DELETE_ALL_QUESTION):
        _say(out, "kept.")
        return
    remove = prompt_yes_no(inp, out, "ALSO delete their build artifacts on disk?")
    deleted, skipped = build_sessions.prune(remove_artifacts=remove)
    _say(out, model.delete_all_result(deleted, skipped))


def _restart_flow(inp: IO[str], out: IO[str], row: model.SessionRow) -> bool:
    """RESTART: the GUI's gate, then the hand-over (the TUI runs no builds). True when
    the gate said Redo and the person took it — the GUI's "Load its config into the
    wizard now (Redo)?" question."""
    why = model.restart_refusal(row.session)
    if why is not None:
        _say(out, "not restarted: " + why)
        return "Redo" in why and prompt_yes_no(
            inp, out, "Load its config into the journey now (Redo)?")
    for line in model.restart_handover_lines(row.session):
        _say(out, line)
    return False


def _redo(inp: IO[str], out: IO[str], s: build_sessions.BuildSession,
          generator_dir: str, journey) -> int | None:
    """REDO: the recorded configuration into the journey. ``None`` keeps the review
    open (refused); otherwise the review is over and this is its exit code — the
    journey that opened it resumes on its first screen, or (``--sessions``, no journey
    underneath) a journey starts here with the configuration loaded."""
    target = journey if journey is not None else journey_mod.Journey(generator_dir)
    why = target.load_session(s)
    if why:
        _say(out, f"not redone: {why}")
        return None
    if journey is None:
        return run_journey(inp, out, generator_dir=generator_dir, journey=target)
    return 0


def print_meshemu(out: IO[str], generator_dir: str, session_name: str) -> bool:
    """The whole-mesh emulation status list for ONE session, headlessly (#69):
    plan summary + the per-device section-status table. False when no session of
    that name holds bootable images (the caller words the error)."""
    from ..core import mesh_emulation as me
    from ..core import qemu_devices, qemu_tests
    from . import meshemu
    for sess in qemu_tests.discover_sessions(generator_dir,
                                             only_with_images=True):
        if sess.name == session_name:
            plan = me.plan_mesh(sess, generator_dir)
            for line in meshemu.plan_summary_lines(plan):
                _say(out, line)
            headers, rows = meshemu.device_table(
                plan, qemu_devices.discover_devices(plan.work_dir))
            for line in model.format_table(headers, rows):
                _say(out, line)
            return True
    return False


def run_journey(inp: IO[str] | None = None, out: IO[str] | None = None, *,
                generator_dir: str = ".", start: str | None = None,
                journey: "journey_mod.Journey | None" = None) -> int:
    """The JOURNEY loop (plain face): welcome -> the canonical page walk.

    One screen per iteration — render the current screen's lines, prompt, feed
    the answer back into the shared :class:`~.journey.Journey` state machine.
    The "sessions" entry point drops into the existing sessions-review loop and
    resumes the journey when it quits (the GUI's welcome -> sessions -> back
    shape). EOF quits, as everywhere in this face. ``journey`` runs one that already
    holds state (a REDO from ``--sessions`` loaded a configuration into it)."""
    inp = inp if inp is not None else sys.stdin
    out = out if out is not None else sys.stdout
    j = journey if journey is not None else journey_mod.Journey(generator_dir)
    if start:                     # an expert entry point (--fleet / --go-live, #587)
        j.goto(start)
    while not j.done:
        _say(out)
        for line in j.lines():
            _say(out, line)
        _say(out, local_ai.plain_status_line())
        if j.secret_input():
            answer = _secret_prompt(inp, out, j.prompt())
        else:
            answer = _prompt(inp, out, j.prompt())
        if answer is None:
            return 0
        j.feed(answer)
        if j.effect == "sessions":
            # the review owns the terminal until it quits; then the journey
            # resumes right where it was (the welcome screen).
            run_sessions_review(inp=inp, out=out, generator_dir=generator_dir,
                                journey=j)
    return 0


def print_worklist(out: IO[str], s: build_sessions.BuildSession) -> None:
    headers, rows = model.worklist_table(s)
    for line in model.format_table(headers, rows):
        _say(out, line)


def run_sessions_review(inp: IO[str] | None = None, out: IO[str] | None = None, *,
                        generator_dir: str = ".", journey=None) -> int:
    """The SESSIONS REVIEW loop (plain face). Returns a process exit code.

    ``journey`` is the journey that opened the review (welcome -> Review prior
    sessions); a REDO loads into it and returns. Without one (``--sessions``) a REDO
    starts the journey here."""
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
        if answer.lower() == local_ai.OPEN_COMMAND:
            # the same screen the journey opens, over this list; q comes back here
            if not run_local_ai(inp, out, generator_dir):
                return 0
            _print_list(out, rows, unreadable)
            continue
        if answer.lower() in ("a", "delete-all"):
            _delete_all_flow(inp, out, rows)
            rows, unreadable = model.session_rows()
            _print_list(out, rows, unreadable)
            continue
        verb, _, arg = answer.partition(" ")
        # ONE numbering: the sessions, then the unreadable records (model.list_entries)
        entries = model.list_entries(rows, unreadable)
        if verb.lower() in ("s", "restart", "e", "redo"):
            row = _pick(entries, arg.strip())
            if row is None:
                _say(out, f"no such session number: {arg.strip() or '(missing)'}")
                continue
            redo = verb.lower() in ("e", "redo")
            if isinstance(row, model.UnreadableRow):
                _say(out, model.unreadable_refusal("redo" if redo else "restart"))
                continue
            if not redo and not _restart_flow(inp, out, row):
                continue
            code = _redo(inp, out, row.session, generator_dir, journey)
            if code is not None:
                return code
            continue
        if verb.lower() in ("d", "delete"):
            row = _pick(entries, arg.strip())
            if row is None:
                _say(out, f"no such session number: {arg.strip() or '(missing)'}")
                continue
            if isinstance(row, model.UnreadableRow):
                _delete_unreadable_flow(inp, out, row)
            else:
                _delete_flow(inp, out, row)
            rows, unreadable = model.session_rows()
            _print_list(out, rows, unreadable)
            continue
        if verb.lower() in ("k", "kernel"):
            row = _pick(rows, arg.strip())
            if row is None:
                _say(out, f"no such session number: {arg.strip() or '(missing)'}")
                continue
            model.kernel_config_flow(
                row.session, generator_dir,
                ask=lambda q: prompt_yes_no(inp, out, q), say=lambda s: _say(out, s),
                out=out, err=out)
            continue
        if verb.lower() in ("w", "worklist"):
            row = _pick(entries, arg.strip())
            if row is None:
                _say(out, f"no such session number: {arg.strip() or '(missing)'}")
                continue
            if isinstance(row, model.UnreadableRow):
                _say(out, model.unreadable_refusal("worklist"))
                continue
            print_worklist(out, row.session)
            continue
        row = _pick(entries, verb)
        if row is None:
            _say(out, f"unrecognised command: {answer}")
            _say(out, _HELP_BUILDS)
            _say(out, _HELP)
            continue
        for line in (model.unreadable_detail_lines(row)
                     if isinstance(row, model.UnreadableRow)
                     else model.session_detail_lines(row)):
            _say(out, line)
