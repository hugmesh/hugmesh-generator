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
  ``r`` re-reads, ``q`` goes back. ``ollama docker`` / ``ollama system`` choose which
  Ollama the assistant talks to — the same saved choice as the Studio panel's
  (core/ollama_docker.py), so both faces always use one instance.
* The key and the command are GLOBAL: they work on every screen of both faces, the
  previous-builds review included, and on the Local AI screen itself they re-read the
  state (:meth:`LocalAIScreen.reopen`) instead of opening a second screen or sending
  the word ``local-ai`` to the model. :class:`Standalone` hosts the screen where there
  is no journey to open it over.

Nothing here talks to anything but this machine.
"""
from __future__ import annotations

from ..core import local_ai_status as lai
from ..core import ollama_docker as odk

__all__ = ["OPEN_COMMAND", "FOOTER_KEY", "LocalAIScreen", "Standalone", "status_line",
           "plain_status_line"]

#: Typed into either face, it opens the screen. Hyphenated so it cannot collide with a
#: value a journey step asks for.
OPEN_COMMAND = "local-ai"
FOOTER_KEY = "F2"


def status_line(env: dict | None = None, *, key_hint: bool = True) -> str:
    """The urwid footer line: status plus the key that opens the screen.

    ``key_hint=False`` is for a screen where the key does nothing (the standalone list
    of previous builds has no journey to open the screen over), so the line never
    advertises a key that is dead there."""
    line = lai.quick_line(env)
    return f"{line}   [{FOOTER_KEY}]" if key_hint else line


def plain_status_line(env: dict | None = None) -> str:
    """The plain face's line, printed above each prompt."""
    return f"[{lai.quick_line(env)} | type {OPEN_COMMAND}]"


_HELP = [
    "type a question and press Enter to ask the local model (it stays on this machine)",
    "  start      start the local Ollama and the queue worker",
    "  ollama docker | ollama system   which Ollama to use (Docker starts on 'start')",
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
        # Every default goes through the saved Ollama choice (system or Docker): the
        # environment it names is the one the read, the prompt and the start all use.
        self._snapshot_fn = snapshot_fn or (lambda: odk.adjust_snapshot(
            lai.read_snapshot(env=odk.assistant_env(odk.current_mode())), odk.current_mode()))
        self._prompt_fn = prompt_fn or (lambda text, history: lai.send_prompt(
            text, history=history, env=odk.assistant_env(odk.current_mode())))
        self._start_fn = start_fn or (lambda: odk.start_assistant(
            generator_dir, odk.current_mode()))
        self.generator_dir = generator_dir
        self.snapshot = None
        self.history: list = []
        self.transcript: list[str] = []
        self.message = ""
        self._under = None               # the overlay this one was opened over, if any

    def enter(self, j) -> None:  # noqa: ARG002 — screen-protocol signature
        self.snapshot = self._snapshot_fn()

    def reopen(self) -> None:
        """F2 or ``local-ai`` while this screen is already up: re-read, say so, and send
        nothing to the model. The screen stays the one it was (no second one underneath)."""
        self.snapshot = self._snapshot_fn()
        self.message = "This is the Local AI screen (state re-read); q goes back."

    def lines(self, j) -> list[str]:  # noqa: ARG002
        snap = self.snapshot
        out = lai.format_status(snap).split("\n") if snap is not None else ["(no snapshot)"]
        cmds = lai.commands(self.generator_dir)
        out += ["", odk.describe(odk.current_mode())]
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
        if low.startswith("ollama"):
            words = low.split()
            want = words[1] if len(words) == 2 else ""
            if want not in odk.MODES:
                self.message = "Say: ollama docker, or ollama system."
                return
            odk.set_mode(want)
            self.snapshot = self._snapshot_fn()
            self.message = odk.describe(want) + (
                "  Type start to start it." if want == odk.DOCKER else "")
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
        except Exception as exc:            # noqa: BLE001 — shown on the screen, never out of the loop
            # ``send_prompt`` wraps what it knows about; this is for what it does not. An
            # exception leaving here would leave ``feed``, and with it the whole text-mode
            # input loop, as a traceback.
            self.message = f"The model call failed: {exc.__class__.__name__}: {exc}"
            return
        self.history += [{"role": "user", "content": line.strip()},
                         {"role": "assistant", "content": answer}]
        del self.history[:-40]
        self.transcript += [f"you: {line.strip()}"] + [f"ai:  {ln}" for ln in answer.strip().split("\n")]


class Standalone:
    """Hosts the screen where there is no journey: the previous-builds review opened on
    its own (``tui --sessions``) or from inside the journey, which owns the terminal
    while it is up. It is the two things the screen protocol touches on its host —
    ``overlay`` (None once the screen said back) and ``open_overlay`` — plus the same
    ``lines`` / ``prompt`` / ``feed`` the journey offers a face, so a face drives it
    with the code it already has."""

    def __init__(self, generator_dir: str = ".", **screen_kw):
        self.generator_dir = generator_dir
        self.overlay: LocalAIScreen | None = None
        self.status = ""
        self._screen_kw = screen_kw

    def open(self) -> LocalAIScreen:
        if self.overlay is None:
            self.open_overlay(LocalAIScreen(generator_dir=self.generator_dir, **self._screen_kw))
        else:
            self.overlay.reopen()
        return self.overlay

    def open_overlay(self, screen) -> None:
        self.overlay = screen
        screen.enter(self)

    @property
    def is_open(self) -> bool:
        return self.overlay is not None

    def title(self) -> str:
        return self.overlay.title if self.overlay is not None else ""

    def lines(self) -> list[str]:
        if self.overlay is None:
            return []
        return [self.overlay.title, ""] + self.overlay.lines(self)

    def prompt(self) -> str:
        return self.overlay.prompt(self) if self.overlay is not None else "> "

    def feed(self, line: str) -> None:
        """One input line while the screen is up. ``local-ai`` typed here is a re-read, as
        on the journey; everything else is the screen's own (q = back, closes it)."""
        if self.overlay is None:
            return
        if line.strip().lower() == OPEN_COMMAND:
            self.overlay.reopen()
            return
        self.overlay.feed(self, line)
