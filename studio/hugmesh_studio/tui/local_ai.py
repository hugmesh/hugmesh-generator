"""The Local AI SCREEN and status line of the terminal UI.

Both faces (urwid and the plain-prompt loop) use this module, so what one shows the
other shows. It reads the same :mod:`..core.local_ai_status` the Studio window's dock
and ``--local-ai-status`` read.

* :func:`status_line` is the one-line status drawn at the bottom of every screen. It
  makes NO network call: it reads the worker's ``status.json`` (see ``quick_snapshot``),
  so redrawing it costs nothing and never waits on a server.
* :class:`LocalAIScreen` is an overlay (a screen, never a popup) opened by the key
  **F2** in the urwid face, or by typing ``local-ai`` in either face. It takes a LIVE
  snapshot when it opens, shows the work list, and treats any line you type as a prompt
  for the local model. ``start`` starts the local Ollama and the queue worker,
  ``r`` re-reads, ``q`` goes back.

Nothing here talks to anything but this machine.
"""
from __future__ import annotations

from ..core import local_ai_status as lai

__all__ = ["OPEN_COMMAND", "FOOTER_KEY", "LocalAIScreen", "status_line", "plain_status_line"]

#: Typed into either face, it opens the screen. Hyphenated so it cannot collide with a
#: value a journey step asks for.
OPEN_COMMAND = "local-ai"
FOOTER_KEY = "F2"


def status_line(env: dict | None = None) -> str:
    """The urwid footer line: status plus the key that opens the screen."""
    return f"{lai.quick_line(env)}   [{FOOTER_KEY}]"


def plain_status_line(env: dict | None = None) -> str:
    """The plain face's line, printed above each prompt."""
    return f"[{lai.quick_line(env)} | type {OPEN_COMMAND}]"


_HELP = [
    "type a question and press Enter to ask the local model (it stays on this machine)",
    "  start      start the local Ollama and the queue worker",
    "  r          read the state again",
    "  clear      forget the conversation",
    "  q          back",
]


class LocalAIScreen:
    """Status, work list and a prompt line — the terminal twin of the dock."""

    slug = "local_ai"
    title = "Local AI"
    wants_q = True                       # q means BACK here, not quit-the-journey

    def __init__(self, *, snapshot_fn=None, prompt_fn=None, start_fn=None, generator_dir: str = "."):
        self._snapshot_fn = snapshot_fn or (lambda: lai.read_snapshot())
        self._prompt_fn = prompt_fn or (lambda text, history: lai.send_prompt(text, history=history))
        self._start_fn = start_fn or (lambda: lai.start_assistant(generator_dir))
        self.generator_dir = generator_dir
        self.snapshot = None
        self.history: list = []
        self.transcript: list[str] = []
        self.message = ""
        self._under = None               # the overlay this one was opened over, if any

    def enter(self, j) -> None:  # noqa: ARG002 — screen-protocol signature
        self.snapshot = self._snapshot_fn()

    def lines(self, j) -> list[str]:  # noqa: ARG002
        snap = self.snapshot
        out = lai.format_status(snap).split("\n") if snap is not None else ["(no snapshot)"]
        cmds = lai.commands(self.generator_dir)
        out += ["", "Run it yourself:  " + cmds["todo"], "                  " + cmds["chat"], ""]
        if self.transcript:
            out += ["conversation:"] + [f"  {t}" for t in self.transcript[-12:]] + [""]
        if self.message:
            out += [self.message, ""]
        return out + _HELP

    def prompt(self, j) -> str:  # noqa: ARG002
        return "local-ai> "

    def feed(self, j, line: str) -> None:
        self.message = ""
        low = line.strip().lower()
        if low in ("q", "quit", "exit", "back", "b"):
            j.overlay = self._under
            return
        if low in ("", "r", "refresh"):
            self.snapshot = self._snapshot_fn()
            return
        if low == "clear":
            self.history.clear()
            self.transcript.clear()
            return
        if low == "start":
            res = self._start_fn()
            self.message = res.message if res.ok else f"{res.message} Run it yourself: {res.command}"
            return
        try:
            answer = self._prompt_fn(line.strip(), list(self.history))
        except lai.LocalAIError as exc:
            self.message = str(exc)
            return
        self.history += [{"role": "user", "content": line.strip()},
                         {"role": "assistant", "content": answer}]
        del self.history[:-40]
        self.transcript += [f"you: {line.strip()}"] + [f"ai:  {ln}" for ln in answer.strip().split("\n")]
