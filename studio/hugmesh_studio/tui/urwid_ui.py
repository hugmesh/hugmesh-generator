"""The urwid face — imported ONLY after app.have_tui() said urwid is usable.

Deliberately a thin renderer: every string and row comes from :mod:`.model`, so this
module adds navigation and nothing else. The class is constructible (and its
``keypress`` drivable) without a real terminal — the urwid-present tests render it
to a canvas headlessly; only :func:`run_sessions_review` starts a MainLoop.
"""
from __future__ import annotations

from typing import Callable

import urwid

from ..core import build_sessions
from . import journey as journey_mod
from . import local_ai
from . import model

__all__ = ["JourneyApp", "LocalAIPanel", "SessionsReview", "SessionsWindow", "run_journey",
           "run_sessions_review", "run_worklist"]

_LIST_HELP = "enter=inspect  d=delete  w=worklist  k=kernel config  r=refresh  q=quit"
_SUB_HELP = "q/esc=back"
#: The GUI's other Previous-builds buttons (B-10), on a footer line of their own.
_LIST_HELP_BUILDS = "build actions: s=restart  e=redo (edit as new)  a=delete all finished"
#: list keys that act on ONE build — an unreadable record says why not (only d applies)
_BUILD_KEYS = {"w": "worklist", "s": "restart", "e": "redo"}


def _text_lines(lines: list[str]) -> urwid.ListBox:
    return urwid.ListBox(urwid.SimpleListWalker([urwid.Text(ln) for ln in lines]))


def _end_in_view(box: urwid.ListBox) -> None:
    """Open ``box`` scrolled to its LAST line instead of its first. A page that fits
    the terminal renders exactly as before; a taller one shows its end, and its top is
    a Page Up away. Focusing the last line is all it takes: a ListBox leaves no row
    empty under its last widget while there are lines above to fill it with."""
    if len(box.body):
        box.set_focus(len(box.body) - 1)


class SessionsReview:
    """SESSIONS REVIEW: list → detail / worklist / delete-with-confirm.

    ``open_local_ai`` is how F2 reaches the Local AI screen: :class:`SessionsWindow`
    passes a callback that opens the screen over this review. Without one (a bare
    review in a test) F2 is not offered and the footer does not claim it."""

    def __init__(self, open_local_ai: Callable[[], None] | None = None,
                 generator_dir: str = ".") -> None:
        self._open_local_ai = open_local_ai
        self.generator_dir = generator_dir
        # ``k`` (kernel config) runs menuconfig IN this terminal, so the screen has to be
        # handed back first: the MainLoop owner sets this to a suspend-run-resume wrapper
        # (_suspender). Without one (a headless test) ``k`` says where to run it instead.
        self.run_external: Callable[[Callable[[], None]], None] | None = None
        self.mode = "list"                 # list | detail | worklist | confirm
        self.rows: list[model.SessionRow] = []
        self.unreadable: list[str] = []
        #: how REDO reaches the journey (its owner sets it, as JourneyApp does): load a
        #: session's configuration there and answer "" (the journey now owns the
        #: screen) or why it refused. None (a bare review): ``e`` says so. The mode
        #: list above gains ``restart`` (the hand-over screen).
        self.on_redo: Callable[[build_sessions.BuildSession], str] | None = None
        #: the list's ONE numbering: rows, then unreadable records (model.list_entries)
        self.entries: list = []
        self._confirm_row = None           # a SessionRow, or an UnreadableRow
        self._viewing: model.UnreadableRow | None = None   # its detail screen is up
        #: record | artifacts | unreadable | all | all-artifacts | redo
        self._confirm_stage = ""
        self.status = urwid.Text("")
        self.ai_line = urwid.Text(("muted", self._ai_text()))
        self.frame = urwid.Frame(
            body=urwid.ListBox(urwid.SimpleFocusListWalker([])),
            header=urwid.Text(("bold", "HugMesh Studio — previous builds")),
            footer=urwid.Pile([self.status, urwid.Text(_LIST_HELP), self.ai_line]))
        self.refresh()

    # ── screens ──────────────────────────────────────────────────────────────
    def refresh(self) -> None:
        self.rows, self.unreadable = model.session_rows()
        items: list[urwid.Widget] = []
        if not self.rows:
            items.append(urwid.Text("  (no build sessions recorded yet)"))
        self._viewing = None
        self.entries = model.list_entries(self.rows, self.unreadable)
        #: (list widget, its entry), matched by identity: the placeholder line above
        #: shifts every position by one when only unreadable records exist
        self._entry_items: list[tuple[urwid.Widget, object]] = []
        for i, entry in enumerate(self.entries, 1):
            # an unreadable record is a BUTTON like every build, so focus reaches it
            # and d deletes it
            unreadable = isinstance(entry, model.UnreadableRow)
            button = urwid.Button(
                model.unreadable_line(entry, i) if unreadable
                else model.session_line(entry, i),
                on_press=self._on_unreadable if unreadable else self._on_row,
                user_data=entry)
            item = urwid.AttrMap(button, None, focus_map="reversed")
            self._entry_items.append((item, entry))
            items.append(item)
        self.mode = "list"
        self.frame.body = urwid.ListBox(urwid.SimpleFocusListWalker(items))
        self._set_help(_LIST_HELP_BUILDS + "\n" + _LIST_HELP)

    def _ai_text(self) -> str:
        return local_ai.status_line(key_hint=self._open_local_ai is not None)

    def _set_help(self, text: str) -> None:
        self.ai_line.set_text(("muted", self._ai_text()))
        self.frame.footer = urwid.Pile([self.status, urwid.Text(text), self.ai_line])

    def refresh_ai_line(self) -> None:
        self.ai_line.set_text(("muted", self._ai_text()))

    def _focused_entry(self):
        """The focused list entry — a SessionRow or an UnreadableRow — or None."""
        if self.mode != "list" or not self.entries:
            return None
        # ``ListBox.focus`` — ``get_focus()`` is gone from current urwid (5.x raises
        # AttributeError), which made d and w crash the whole TUI on the list
        widget = self.frame.body.focus
        return next((entry for item, entry in self._entry_items if item is widget), None)

    def _focused_row(self) -> model.SessionRow | None:
        """The focused BUILD (None on an unreadable record, which is no build)."""
        entry = self._focused_entry()
        return entry if isinstance(entry, model.SessionRow) else None

    def _on_row(self, _button: urwid.Button, row: model.SessionRow) -> None:
        self.show_detail(row)

    def _open(self, mode: str, body: urwid.Widget, help_text: str) -> None:
        """Show another screen of the review (detail, worklist, hand-over, a question).
        The status line answered something on the screen being left — a refusal about
        ONE build, the result of a delete — so it does not follow the person onto the
        next one. (It used to stay until something overwrote it: "not restarted: …
        running in another Studio process" sat under the hand-over, the worklist and
        the delete questions of every other build, and under the list again after
        them.) A result is still shown where it happened: ``refresh`` itself never
        clears the line, because every action sets its answer and then refreshes."""
        self.status.set_text("")
        self.mode = mode
        self.frame.body = body
        self._set_help(help_text)

    def _on_unreadable(self, _button: urwid.Button, row: model.UnreadableRow) -> None:
        self._open("detail", _text_lines(model.unreadable_detail_lines(row)),
                   "d=delete this record file  q/esc=back")
        self._viewing = row

    def show_detail(self, row: model.SessionRow) -> None:
        self._viewing = None
        self._open("detail", _text_lines(model.session_detail_lines(row)), _SUB_HELP)

    def show_worklist(self, row: model.SessionRow) -> None:
        headers, rows = model.worklist_table(row.session)
        self._open("worklist", _text_lines(model.format_table(headers, rows)), _SUB_HELP)

    # ── delete-with-confirm ──────────────────────────────────────────────────
    def start_delete(self, row: model.SessionRow) -> None:
        refusal = model.delete_refusal(row.session)
        if refusal is not None:
            self.status.set_text(f"not deleted: {refusal}")
            return
        self._confirm_row = row
        self._confirm_stage = "record"
        self._show_confirm(
            f"Delete session {row.session.id} ({row.session.label or 'no label'})?")

    def start_delete_unreadable(self, row: model.UnreadableRow) -> None:
        self._viewing = None
        self._confirm_row = row
        self._confirm_stage = "unreadable"
        self._show_confirm(f"Delete this unreadable record file?\n{row.path}")

    def start_delete_all(self) -> None:
        """"Delete all finished…": the GUI's question, then the artifact trees as a
        separate answer (No is the default focus, as the GUI's checkbox starts off)."""
        if not self.rows:
            self.status.set_text("nothing to delete: no readable build session is "
                                 "recorded.")
            return
        self._confirm_row = None
        self._confirm_stage = "all"
        self._show_confirm(model.DELETE_ALL_QUESTION)

    def start_restart(self, row: model.SessionRow) -> None:
        """RESTART: the GUI's gate; a refusal naming Redo offers the Redo (the GUI's
        question), any other refusal is said; a clear gate shows the hand-over — the
        TUI runs no builds."""
        why = model.restart_refusal(row.session)
        if why is not None and "Redo" in why:
            self._confirm_row = row
            self._confirm_stage = "redo"
            self._show_confirm(f"Restart not possible: {why}\n\n"
                               "Load its config into the journey now (Redo)?")
            return
        if why is not None:
            self.status.set_text(f"not restarted: {why}")
            return
        self._open("restart", _text_lines(model.restart_handover_lines(row.session)),
                   _SUB_HELP)

    def redo(self, row: model.SessionRow) -> None:
        """REDO: the recorded configuration into the journey (``on_redo``)."""
        self._confirm_row = None
        if self.on_redo is None:
            self.status.set_text("not redone: this review has no journey to load into "
                                 "— open it from the journey (Review prior sessions)")
            self.refresh()
            return
        why = self.on_redo(row.session)
        if why:
            self.status.set_text(f"not redone: {why}")
            self.refresh()

    def _show_confirm(self, question: str) -> None:
        yes = urwid.Button("Yes", on_press=self._confirm_yes)
        no = urwid.Button("No", on_press=self._confirm_no)
        self._open("confirm", urwid.ListBox(urwid.SimpleFocusListWalker([
            urwid.Text(question), urwid.Divider(),
            urwid.AttrMap(no, None, focus_map="reversed"),      # No is the default focus
            urwid.AttrMap(yes, None, focus_map="reversed"),
        ])), "enter=choose  q/esc=cancel")

    def _confirm_yes(self, _button=None) -> None:
        stage, row = self._confirm_stage, self._confirm_row
        if stage == "all":
            self._confirm_stage = "all-artifacts"
            self._show_confirm("ALSO delete their build artifacts on disk?")
            return
        if stage == "all-artifacts":
            self._delete_all(remove_artifacts=True)
            return
        if stage == "unreadable" and isinstance(row, model.UnreadableRow):
            self._confirm_row = None
            _ok, said = model.delete_unreadable(row)
            self.status.set_text(said)
            self.refresh()
            return
        if stage == "redo" and isinstance(row, model.SessionRow):
            self.redo(row)
            return
        if not isinstance(row, model.SessionRow):
            self.refresh()
            return
        if self._confirm_stage == "record" and model.artifact_entries(row.session):
            self._confirm_stage = "artifacts"
            self._show_confirm(f"ALSO delete its artifact tree {row.session.workdir}?")
            return
        self._delete(remove_artifacts=self._confirm_stage == "artifacts")

    def _confirm_no(self, _button=None) -> None:
        if self._confirm_stage == "artifacts":
            self._delete(remove_artifacts=False)      # record yes, artifacts no
            return
        if self._confirm_stage == "all-artifacts":
            self._delete_all(remove_artifacts=False)  # records yes, artifacts no
            return
        self.status.set_text("not restarted." if self._confirm_stage == "redo"
                             else "kept.")
        self._confirm_row = None
        self.refresh()

    def _delete(self, *, remove_artifacts: bool) -> None:
        row = self._confirm_row
        self._confirm_row = None
        if row is not None and build_sessions.delete(
                row.session, remove_artifacts=remove_artifacts):
            self.status.set_text(
                f"deleted session {row.session.id}"
                + (" and its artifacts." if remove_artifacts else " (record only)."))
        elif row is not None:
            self.status.set_text(build_sessions.not_deleted_reason(row.session))
        self.refresh()

    def _delete_all(self, *, remove_artifacts: bool) -> None:
        self._confirm_row = None
        deleted, skipped = build_sessions.prune(remove_artifacts=remove_artifacts)
        self.status.set_text(model.delete_all_result(deleted, skipped))
        self.refresh()

    # ── input ────────────────────────────────────────────────────────────────
    def unhandled(self, key: str) -> None:
        if not isinstance(key, str):
            return
        if key in ("q", "Q", "esc"):
            if self.mode == "list":
                raise urwid.ExitMainLoop()
            if self.mode == "confirm":
                self.status.set_text("kept.")
                self._confirm_row = None
            self.refresh()
            return
        if key == "f2":
            if self._open_local_ai is not None:
                self._confirm_row = None          # a half-answered delete question is dropped
                self._open_local_ai()
            return
        if self.mode == "detail" and key in ("d", "D") and self._viewing is not None:
            self.start_delete_unreadable(self._viewing)       # d on its detail screen
            return
        if self.mode != "list":
            return
        entry = self._focused_entry()
        if isinstance(entry, model.UnreadableRow) and key.lower() in _BUILD_KEYS:
            self.status.set_text(model.unreadable_refusal(_BUILD_KEYS[key.lower()]))
            return
        if key in ("a", "A"):
            self.start_delete_all()
            return
        if key in ("s", "S") and isinstance(entry, model.SessionRow):
            self.start_restart(entry)
            return
        if key in ("e", "E") and isinstance(entry, model.SessionRow):
            self.redo(entry)
            return
        if key in ("d", "D") and isinstance(entry, model.UnreadableRow):
            self.start_delete_unreadable(entry)
            return
        if key in ("r", "R"):
            self.status.set_text("")       # a fresh read: the last answer was about the old one
            self.refresh()
        elif key in ("d", "D"):
            row = self._focused_row()
            if row is not None:
                self.start_delete(row)
        elif key in ("w", "W"):
            row = self._focused_row()
            if row is not None:
                self.show_worklist(row)
        elif key in ("k", "K"):
            row = self._focused_row()
            if row is not None:
                self.start_kernel_config(row)

    # ── kernel config (core/kernel_reconfig.py, the plain face's ``k`` flow) ────
    def start_kernel_config(self, row: model.SessionRow) -> None:
        from ..core import kernel_reconfig
        t = kernel_reconfig.locate(row.session)
        if isinstance(t, str):
            self.status.set_text(f"kernel config: {t}")
            return
        if self.run_external is None:
            self.status.set_text(
                "kernel config: run it from a terminal — python -m hugmesh_studio "
                f"--kernel-config {row.session.id}:{t.image_id}")
            return
        from .plain import prompt_yes_no
        import sys

        def flow() -> None:
            model.kernel_config_flow(
                row.session, self.generator_dir,
                ask=lambda q: prompt_yes_no(sys.stdin, sys.stdout, q),
                say=lambda s: print(s), out=sys.stdout, err=sys.stdout)
            input("press Enter to return to the build list...")

        self.run_external(flow)
        self.refresh()


#: Keys the footer Edit never uses; the journey frame forwards them to the body so a
#: page taller than the terminal (the 10 mode cards at 80x24) can be read.
_SCROLL_KEYS = frozenset({"up", "down", "page up", "page down"})


class _JourneyFrame(urwid.Frame):
    """Frame whose focus stays in the footer Edit, but whose body still scrolls."""

    def keypress(self, size, key):
        key = super().keypress(size, key)
        if key in _SCROLL_KEYS:
            (top, bottom), _ = self.frame_top_bottom(size, True)
            body_size = (size[0], max(1, size[1] - top - bottom))
            return self.body.keypress(body_size, key)
        return key


class LocalAIPanel:
    """The Local AI screen as its own frame, for the one place the journey is not
    underneath: the previous-builds review. Same shape as a journey screen (lines in
    the body, the ``local-ai>`` Edit and the status line in the footer), driven through
    :class:`~.local_ai.Standalone`; ``on_close`` is called once the screen said back."""

    def __init__(self, generator_dir: str, on_close: Callable[[], None]) -> None:
        self.host = local_ai.Standalone(generator_dir)
        self._on_close = on_close
        self.input = urwid.Edit("")
        self.header = urwid.Text(("bold", ""))
        self.ai_line = urwid.Text(("muted", local_ai.status_line()))
        self.frame = _JourneyFrame(
            body=urwid.ListBox(urwid.SimpleListWalker([])),
            header=self.header,
            footer=urwid.Pile([urwid.AttrMap(self.input, None, focus_map="reversed"),
                               self.ai_line], focus_item=0),
            focus_part="footer")
        self.host.open()
        self.sync()

    def sync(self) -> None:
        self.header.set_text(("bold", f"HugMesh Studio — {self.host.title()}"))
        self.frame.body = _text_lines(self.host.lines()[2:])
        self.input.set_caption(self.host.prompt())
        self.input.set_edit_text("")
        self.refresh_ai_line()

    def refresh_ai_line(self) -> None:
        self.ai_line.set_text(("muted", local_ai.status_line()))

    def feed(self, line: str) -> None:
        self.host.feed(line)
        if not self.host.is_open:
            self._on_close()
            return
        self.sync()

    def unhandled(self, key: str) -> None:
        if key == "enter":
            self.feed(self.input.edit_text)
        elif key == "f2":
            self.feed(local_ai.OPEN_COMMAND)          # already here: a re-read, not a second screen


class SessionsWindow:
    """The previous-builds review plus the Local AI panel F2 opens over it, and q closes
    back onto the list exactly as it was. Used standalone (``tui --sessions``) and by
    the journey, which swaps ``root`` in while the review is up."""

    def __init__(self, generator_dir: str = ".") -> None:
        self.generator_dir = generator_dir
        self.review = SessionsReview(open_local_ai=self.open_local_ai,
                                     generator_dir=generator_dir)
        self.root = urwid.WidgetPlaceholder(self.review.frame)
        self.panel: LocalAIPanel | None = None

    def open_local_ai(self) -> None:
        if self.panel is not None:                    # F2 while it is up: re-read only
            self.panel.feed(local_ai.OPEN_COMMAND)
            return
        self.panel = LocalAIPanel(self.generator_dir, on_close=self._close_local_ai)
        self.root.original_widget = self.panel.frame

    def _close_local_ai(self) -> None:
        self.panel = None
        self.root.original_widget = self.review.frame
        self.review.refresh_ai_line()

    def refresh_ai_line(self) -> None:
        (self.panel or self.review).refresh_ai_line()

    def unhandled(self, key: str) -> None:
        if not isinstance(key, str):
            return
        if self.panel is not None:
            self.panel.unhandled(key)
            return
        self.review.unhandled(key)


class JourneyApp:
    """The JOURNEY (urwid face): a thin renderer over :class:`~.journey.Journey`.

    One screen shape for every journey page: the shared state machine's lines as
    the body, its prompt as an :class:`urwid.Edit` command line in the footer —
    Enter feeds the exact same strings the plain face would, so the two faces
    cannot diverge. The "sessions" entry point swaps in the existing
    :class:`SessionsReview` widget and returns here when it exits.
    """

    def __init__(self, generator_dir: str = ".", start: str | None = None, *,
                 sessions_only: bool = False) -> None:
        self.journey = journey_mod.Journey(generator_dir)
        if start:                 # an expert entry point (--fleet / --go-live, #587)
            self.journey.goto(start)
        self.input = urwid.Edit("> ")
        self.header = urwid.Text(("bold", ""))
        # the Local AI status line sits UNDER the prompt on every screen; the Pile keeps
        # focus on the Edit so every keystroke still lands there
        self.ai_line = urwid.Text(("muted", local_ai.status_line()))
        self.frame = _JourneyFrame(
            body=urwid.ListBox(urwid.SimpleListWalker([])),
            header=self.header,
            footer=urwid.Pile([urwid.AttrMap(self.input, None, focus_map="reversed"),
                               self.ai_line], focus_item=0),
            focus_part="footer")           # every keystroke lands in the Edit
        self.root = urwid.WidgetPlaceholder(self.frame)
        self.sessions: SessionsWindow | None = None
        #: ``tui --sessions``: the review IS the app (q on its list quits), until a REDO
        #: loads a configuration and hands the screen to the journey underneath
        self.sessions_only = sessions_only
        self.sync()
        if sessions_only:
            self._open_sessions()

    def sync(self) -> None:
        """Re-render the current journey screen (lines + prompt) into the frame."""
        j = self.journey
        self.header.set_text(("bold", f"HugMesh Studio — {j.title()}"))
        # lines()[0] repeats the title for the plain face; the frame header
        # already carries it here, so the body starts after it.
        self.frame.body = _text_lines(j.lines()[1:])
        self.input.set_caption(j.prompt())
        self.input.set_edit_text("")
        # a secret line (the NVD API key after `nvd set`) is masked for exactly that
        # one line; the next sync() takes the mask off again
        self.input.set_mask("*" if j.secret_input() else None)
        self.refresh_ai_line()

    def refresh_ai_line(self) -> None:
        """Re-read the Local AI line (files only, no network); also run by a timer."""
        self.ai_line.set_text(("muted", local_ai.status_line()))
        if self.sessions is not None:
            self.sessions.refresh_ai_line()

    def _open_sessions(self) -> None:
        # the review carries its own Local AI panel, so F2 there opens the screen OVER
        # the list and q returns to the list, not to the journey's welcome screen
        self.sessions = SessionsWindow(self.journey.generator_dir)
        self.sessions.review.run_external = getattr(self, "run_external", None)
        self.root.original_widget = self.sessions.root
        self.sessions.review.on_redo = self._redo_from_sessions

    def _redo_from_sessions(self, session) -> str:
        """The review's REDO: load into the journey and show it ("" once done)."""
        why = self.journey.load_session(session)
        if why:
            return why
        self.sessions_only = False          # the journey owns the terminal now
        self._close_sessions()
        # The Redo's message ends with what was NOT loaded — a secret the record never
        # held — which the GUI raises as a dialog. Here it is the last lines of a
        # welcome screen taller than an 80x24 terminal, where it sat below the fold:
        # this one screen opens at its end, so the message is read without scrolling.
        _end_in_view(self.frame.body)
        return ""

    def _close_sessions(self) -> None:
        self.sessions = None
        self.root.original_widget = self.frame
        self.sync()

    def feed(self, line: str) -> None:
        """Feed one command line into the journey and re-render — the exact
        entry point the Enter key uses (tests drive it directly)."""
        self.journey.feed(line)
        if self.journey.done:
            raise urwid.ExitMainLoop()
        if self.journey.effect == "sessions":
            self._open_sessions()
            return
        self.sync()

    def unhandled(self, key: str) -> None:
        if not isinstance(key, str):
            return
        if self.sessions is not None:
            # delegate to the review; its list-screen q raises ExitMainLoop,
            # which HERE means "back to the journey", not "quit the app".
            try:
                self.sessions.unhandled(key)
            except urwid.ExitMainLoop:
                if self.sessions_only:
                    raise                   # `tui --sessions`: q on the list quits
                self._close_sessions()
            return
        if key == "enter":
            self.feed(self.input.edit_text)
        elif key == "f2":
            # on the Local AI screen the journey makes this a re-read (see Journey.feed)
            self.feed(local_ai.OPEN_COMMAND)


def _suspender(loop) -> Callable[[Callable[[], None]], None]:
    """Run ``fn`` on the real terminal with the urwid screen handed back, then resume."""
    def run(fn: Callable[[], None]) -> None:
        loop.screen.stop()
        try:
            fn()
        except (EOFError, KeyboardInterrupt):
            pass
        finally:
            loop.screen.start()
            loop.screen.clear()
    return run


def _with_ai_line_timer(loop, app) -> "urwid.MainLoop":
    """Redraw the Local AI line every few seconds (it reads files, never the network)."""
    def tick(lp, _data=None):
        app.refresh_ai_line()
        lp.set_alarm_in(5, tick)
    loop.set_alarm_in(5, tick)
    return loop


def run_journey(generator_dir: str = ".", start: str | None = None) -> int:
    app = JourneyApp(generator_dir, start)
    loop = urwid.MainLoop(app.root, palette=_PALETTE, unhandled_input=app.unhandled)
    app.run_external = _suspender(loop)
    _with_ai_line_timer(loop, app).run()
    return 0


_PALETTE = [("bold", "bold", ""), ("reversed", "standout", ""), ("muted", "dark gray", "")]


def run_sessions_review(generator_dir: str = ".") -> int:
    app = SessionsWindow(generator_dir)
    loop = urwid.MainLoop(app.root, palette=_PALETTE, unhandled_input=app.unhandled)
    app.review.run_external = _suspender(loop)
    _with_ai_line_timer(loop, app).run()
    return 0


def run_worklist(session: build_sessions.BuildSession) -> int:
    """Read-only worklist table for ONE session (q to quit)."""
    headers, rows = model.worklist_table(session)
    lines = [f"worklist — session {session.id} ({session.label or 'no label'})", ""]
    lines += model.format_table(headers, rows)
    frame = urwid.Frame(body=_text_lines(lines), footer=urwid.Text("q=quit"))

    def quit_on_q(key: str) -> None:
        if isinstance(key, str) and key in ("q", "Q", "esc"):
            raise urwid.ExitMainLoop()

    urwid.MainLoop(frame, palette=_PALETTE, unhandled_input=quit_on_q).run()
    return 0
