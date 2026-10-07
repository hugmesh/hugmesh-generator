"""The urwid face — imported ONLY after app.have_tui() said urwid is usable.

Deliberately a thin renderer: every string and row comes from :mod:`.model`, so this
module adds navigation and nothing else. The class is constructible (and its
``keypress`` drivable) without a real terminal — the urwid-present tests render it
to a canvas headlessly; only :func:`run_sessions_review` starts a MainLoop.
"""
from __future__ import annotations

import urwid

from ..core import build_sessions
from . import journey as journey_mod
from . import local_ai
from . import model

__all__ = ["JourneyApp", "SessionsReview", "run_journey", "run_sessions_review",
           "run_worklist"]

_LIST_HELP = "enter=inspect  d=delete  w=worklist  r=refresh  q=quit"
_SUB_HELP = "q/esc=back"


def _text_lines(lines: list[str]) -> urwid.ListBox:
    return urwid.ListBox(urwid.SimpleListWalker([urwid.Text(ln) for ln in lines]))


class SessionsReview:
    """SESSIONS REVIEW: list → detail / worklist / delete-with-confirm."""

    def __init__(self) -> None:
        self.mode = "list"                 # list | detail | worklist | confirm
        self.rows: list[model.SessionRow] = []
        self.unreadable: list[str] = []
        self._confirm_row: model.SessionRow | None = None
        self._confirm_stage = ""           # record | artifacts
        self.status = urwid.Text("")
        self.ai_line = urwid.Text(("muted", local_ai.status_line()))
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
        for i, row in enumerate(self.rows, 1):
            button = urwid.Button(model.session_line(row, i),
                                  on_press=self._on_row, user_data=row)
            items.append(urwid.AttrMap(button, None, focus_map="reversed"))
        for path in self.unreadable:
            items.append(urwid.Text(f"  ! unreadable record skipped: {path}"))
        self.mode = "list"
        self.frame.body = urwid.ListBox(urwid.SimpleFocusListWalker(items))
        self._set_help(_LIST_HELP)

    def _set_help(self, text: str) -> None:
        self.ai_line.set_text(("muted", local_ai.status_line()))
        self.frame.footer = urwid.Pile([self.status, urwid.Text(text), self.ai_line])

    def refresh_ai_line(self) -> None:
        self.ai_line.set_text(("muted", local_ai.status_line()))

    def _focused_row(self) -> model.SessionRow | None:
        if self.mode != "list" or not self.rows:
            return None
        widget, _pos = self.frame.body.get_focus()
        base = getattr(widget, "base_widget", widget)
        if isinstance(base, urwid.Button):
            for i, item in enumerate(self.frame.body.body):
                if item is widget:
                    return self.rows[i] if i < len(self.rows) else None
        return None

    def _on_row(self, _button: urwid.Button, row: model.SessionRow) -> None:
        self.show_detail(row)

    def show_detail(self, row: model.SessionRow) -> None:
        self.mode = "detail"
        self.frame.body = _text_lines(model.session_detail_lines(row))
        self._set_help(_SUB_HELP)

    def show_worklist(self, row: model.SessionRow) -> None:
        self.mode = "worklist"
        headers, rows = model.worklist_table(row.session)
        self.frame.body = _text_lines(model.format_table(headers, rows))
        self._set_help(_SUB_HELP)

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

    def _show_confirm(self, question: str) -> None:
        self.mode = "confirm"
        yes = urwid.Button("Yes", on_press=self._confirm_yes)
        no = urwid.Button("No", on_press=self._confirm_no)
        self.frame.body = urwid.ListBox(urwid.SimpleFocusListWalker([
            urwid.Text(question), urwid.Divider(),
            urwid.AttrMap(no, None, focus_map="reversed"),      # No is the default focus
            urwid.AttrMap(yes, None, focus_map="reversed"),
        ]))
        self._set_help("enter=choose  q/esc=cancel")

    def _confirm_yes(self, _button=None) -> None:
        row = self._confirm_row
        if row is None:
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
        self.status.set_text("kept.")
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
        else:
            self.status.set_text("not deleted: the session became active again.")
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
        if self.mode != "list":
            return
        if key in ("r", "R"):
            self.refresh()
        elif key in ("d", "D"):
            row = self._focused_row()
            if row is not None:
                self.start_delete(row)
        elif key in ("w", "W"):
            row = self._focused_row()
            if row is not None:
                self.show_worklist(row)


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


class JourneyApp:
    """The JOURNEY (urwid face): a thin renderer over :class:`~.journey.Journey`.

    One screen shape for every journey page: the shared state machine's lines as
    the body, its prompt as an :class:`urwid.Edit` command line in the footer —
    Enter feeds the exact same strings the plain face would, so the two faces
    cannot diverge. The "sessions" entry point swaps in the existing
    :class:`SessionsReview` widget and returns here when it exits.
    """

    def __init__(self, generator_dir: str = ".", start: str | None = None) -> None:
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
        self.sessions: SessionsReview | None = None
        self.sync()

    def sync(self) -> None:
        """Re-render the current journey screen (lines + prompt) into the frame."""
        j = self.journey
        self.header.set_text(("bold", f"HugMesh Studio — {j.title()}"))
        # lines()[0] repeats the title for the plain face; the frame header
        # already carries it here, so the body starts after it.
        self.frame.body = _text_lines(j.lines()[1:])
        self.input.set_caption(j.prompt())
        self.input.set_edit_text("")
        self.refresh_ai_line()

    def refresh_ai_line(self) -> None:
        """Re-read the Local AI line (files only, no network); also run by a timer."""
        self.ai_line.set_text(("muted", local_ai.status_line()))

    def _open_sessions(self) -> None:
        self.sessions = SessionsReview()
        self.root.original_widget = self.sessions.frame

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
                self._close_sessions()
            return
        if key == "enter":
            self.feed(self.input.edit_text)
        elif key == "f2":
            self.feed(local_ai.OPEN_COMMAND)


def _with_ai_line_timer(loop, app) -> "urwid.MainLoop":
    """Redraw the Local AI line every few seconds (it reads files, never the network)."""
    def tick(lp, _data=None):
        app.refresh_ai_line()
        lp.set_alarm_in(5, tick)
    loop.set_alarm_in(5, tick)
    return loop


def run_journey(generator_dir: str = ".", start: str | None = None) -> int:
    app = JourneyApp(generator_dir, start)
    _with_ai_line_timer(urwid.MainLoop(app.root, palette=_PALETTE,
                                       unhandled_input=app.unhandled), app).run()
    return 0


_PALETTE = [("bold", "bold", ""), ("reversed", "standout", ""), ("muted", "dark gray", "")]


def run_sessions_review() -> int:
    app = SessionsReview()
    _with_ai_line_timer(urwid.MainLoop(app.frame, palette=_PALETTE,
                                       unhandled_input=app.unhandled), app).run()
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
