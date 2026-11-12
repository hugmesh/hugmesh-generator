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

WHERE THE PERSON IS. The screen reads ``j.slug`` and ``j.screen_for(slug)`` (public)
for the page, and the overlay it was opened over for the domain on screen, and sends
every question with the primer, the page facts, the page's options and the docs
snippets (core/assistant_prompt); each answer ends with its Sources line. ``Tip:`` for
the page is the first line after the status (core/assistant_tips, no model needed;
``tips off|on``). A proposed setting change prints as a block the person answers with
``apply``, ``cancel`` or later ``undo`` (core/assistant_actions, through the same
BrandView and Domain row the domain-services step writes). ``docs <question>`` and
``options`` need no model. :func:`status_line` / :func:`plain_status_line` take an
optional ``slug`` and append the page's tip; the footer call sites may pass it later.

Nothing here talks to anything but this machine.
"""
from __future__ import annotations

from ..core import assistant_actions as aact
from ..core import assistant_catalogue as acat
from ..core import assistant_context as actxt
from ..core import assistant_docs as adocs
from ..core import assistant_prompt as aprompt
from ..core import assistant_tips as atips
from ..core import local_ai_models as lam
from ..core import local_ai_status as lai
from ..core import ollama_docker as odk
from ..core import platform_info

__all__ = ["OPEN_COMMAND", "FOOTER_KEY", "LocalAIScreen", "Standalone", "status_line",
           "plain_status_line"]

#: Typed into either face, it opens the screen. Hyphenated so it cannot collide with a
#: value a journey step asks for.
OPEN_COMMAND = "local-ai"
FOOTER_KEY = "F2"


TIP_FOOTER_CHARS = 70


def _footer_tip(slug: str) -> str:
    """``  Tip: ...`` (elided) for ``slug``, or "" when no slug or tips are hidden."""
    if not slug:
        return ""
    try:
        if atips.tips_hidden():
            return ""
        tip = atips.tip_for(actxt.Where(face="tui", slug=slug))
    except Exception:                        # noqa: BLE001 — a footer never raises
        return ""
    if len(tip) > TIP_FOOTER_CHARS:
        tip = tip[:TIP_FOOTER_CHARS - 1].rstrip() + "\u2026"
    return f"  Tip: {tip}"


def status_line(env: dict | None = None, *, key_hint: bool = True, slug: str = "") -> str:
    """The urwid footer line: status plus the key that opens the screen.

    ``key_hint=False`` is for a screen where the key does nothing (the standalone list
    of previous builds has no journey to open the screen over), so the line never
    advertises a key that is dead there. ``slug`` (optional) appends the page's tip."""
    line = lai.quick_line(env)
    pulling = lam.active_line()           # a model download this process is running
    if pulling:
        line = f"{line}; {pulling}"
    line = f"{line}   [{FOOTER_KEY}]" if key_hint else line
    return line + _footer_tip(slug)


def plain_status_line(env: dict | None = None, slug: str = "") -> str:
    """The plain face's line, printed above each prompt."""
    return f"[{lai.quick_line(env)} | type {OPEN_COMMAND}]" + _footer_tip(slug)


_HELP = [
    "type a question and press Enter to ask the local model (it stays on this machine)",
    "  start      start the local Ollama and the queue worker",
    "  pull [model]   download a model (asks first; shows the size and the free space)",
    "  ollama docker | ollama system   which Ollama to use (Docker starts on 'start')",
    "  docs <question>   what the docs say (no model needed)   options   this page's settings",
    "  apply | cancel | undo   a proposed change    tips on | tips off",
    "  r          read the state again",
    "  clear      forget the conversation",
    "  q          back",
]
#: The ``start`` line where windows_worker_note() is said (native Windows): there System
#: mode starts nothing and Docker mode starts only the container, never the worker.
_WINDOWS_START_HELP = ("  start      in Docker mode, start the Studio's Ollama container "
                       "(the queue worker needs WSL2)")
#: The same line on a Mac without Homebrew's GNU tools: the note above it gives the
#: ``brew install`` line, and WSL2 is not a Mac's answer to anything.
_MACOS_START_HELP = ("  start      in Docker mode, start the Studio's Ollama container "
                     "(the queue worker needs the GNU tools named above)")


def _help_lines(windows: bool, kind: str = "windows") -> list[str]:
    """The help under the screen; ``windows`` = the native-Windows note is shown, and
    ``kind`` is that note's ``platform_info.blocker_kind`` ("darwin" for the Mac
    note)."""
    if not windows:
        return list(_HELP)
    start = _MACOS_START_HELP if kind == "darwin" else _WINDOWS_START_HELP
    return [start if ln.startswith("  start ") else ln for ln in _HELP]


class LocalAIScreen:
    """Status, work list and a prompt line — the terminal twin of the dock."""

    slug = "local_ai"
    title = "Local AI"
    wants_q = True                       # q means BACK here, not quit-the-journey

    def __init__(self, *, snapshot_fn=None, prompt_fn=None, start_fn=None, generator_dir: str = ".",
                 pull_fn=None, free_fn=None):
        # Every default goes through the saved Ollama choice (system or Docker): the
        # environment it names is the one the read, the prompt and the start all use.
        self._snapshot_fn = snapshot_fn or (lambda: _offer_in_tui_words(odk.adjust_snapshot(
            lai.read_snapshot(env=odk.assistant_env(odk.current_mode())), odk.current_mode())))
        # A MODEL OUT OF THE BOX (core/local_ai_models): ``pull`` asks y/n with the size
        # and the free space, then downloads on a thread; the line under the screen and
        # the status block show its progress. Looked up at use time (tests replace them).
        self._pull_fn = pull_fn
        self._free_fn = free_fn
        self._pull_ask = ""              # the model a y/n is pending for
        self._pull_thread = None
        self._pull_stop = None
        self._pull_offer: dict = {}      # from a question that came back NoModel
        self._pending_question = ""
        self._custom_prompt = prompt_fn is not None
        self._prompt_fn = prompt_fn or (lambda text, history: lai.send_prompt(
            text, history=history, env=odk.assistant_env(odk.current_mode())))
        self._start_fn = start_fn or (lambda: odk.start_assistant(
            generator_dir, odk.current_mode()))
        self.generator_dir = generator_dir
        self.snapshot = None
        self.history: list = []
        self.transcript: list[str] = []
        self.message = ""
        self.warning = ""                # the delete-commands warning of the last answer
        self._under = None               # the overlay this one was opened over, if any
        self._j = None                   # the journey (or host) this screen was entered on
        self._pending = None             # a Validated change waiting for apply / cancel
        self._undo: dict = {}            # assistant_actions.undo_key -> Applied (one level per domain)
        self._last_prompt = None

    def enter(self, j) -> None:  # noqa: ARG002 — screen-protocol signature
        self._j = j
        self.snapshot = self._snapshot_fn()

    # ── where the person is ────────────────────────────────────────────────────────
    def _step_and_row(self, j):
        """``(the domain-services step under this overlay, its Domain row)`` or
        ``(None, None)``: the step is public (``current(j)``), the row is a Domain."""
        under = self._under
        if under is None or not hasattr(under, "current"):
            return None, None
        try:
            return under, under.current(j)
        except Exception:                # noqa: BLE001 — no domain on screen
            return under, None

    def where(self, j, question: str = "") -> actxt.Where:
        slug = str(getattr(j, "slug", "") or "")
        title = ""
        try:
            title = str(getattr(j.screen_for(slug), "title", "") or "")
        except Exception:                # noqa: BLE001
            pass
        cfg = getattr(j, "cfg", None)
        mode = str(getattr(cfg, "mode", "") or "") or "docker"
        step, row = self._step_and_row(j)
        domain = str(getattr(row, "name", "") or "") if row is not None else ""
        tab = ""
        if step is not None:
            tab = {1: "identity", 2: "look", 3: "services", 4: "ways"}.get(
                getattr(step, "section", 0), "")
        domains = actxt.domain_rows_from(getattr(cfg, "domains", ()) or ()) if cfg is not None else ()
        brand = actxt.brand_rows_from({"id": getattr(cfg, "brand", "")}) if cfg is not None else ()
        own = False
        if step is not None and row is not None:
            try:
                own = bool(getattr(step._brand(j), "own", False))
            except Exception:            # noqa: BLE001
                own = False
        state = []
        try:
            from ..core import state_paths
            sd = state_paths.state_dir()
            state = actxt.collect([("build", lambda: actxt.build_rows(sd)),
                                   ("assistant", lambda: actxt.assistant_rows(
                                       odk.assistant_env(odk.current_mode())))])
        except Exception:                # noqa: BLE001 — facts, never a crash
            state = []
        try:
            current = aact.current_values(self._target(j))
        except Exception:                # noqa: BLE001 — "current:" is a help, never a crash
            current = ()
        return actxt.Where(face="tui", slug=slug, title=title, mode=mode, domain=domain,
                           own_domain=own, tab=tab, brand=brand, domains=domains,
                           question=question, current=current).with_state(state)

    def _target(self, j):
        step, row = self._step_and_row(j)
        if step is None or row is None:
            return None
        view = None
        try:
            view = step._brand(j)
        except Exception:                # noqa: BLE001
            view = None
        try:
            from ..tui.domain_services_step import _own_name
            own = _own_name(step.cfg(j))
        except Exception:                # noqa: BLE001
            own = ""
        return aact.TuiTarget(view, row, own_name=own)

    def reopen(self) -> None:
        """F2 or ``local-ai`` while this screen is already up: re-read, say so, and send
        nothing to the model. The screen stays the one it was (no second one underneath)."""
        self.snapshot = self._snapshot_fn()
        self.message = "This is the Local AI screen (state re-read); q goes back."

    def lines(self, j) -> list[str]:  # noqa: ARG002
        snap = self.snapshot
        out = lai.format_status(snap).split("\n") if snap is not None else ["(no snapshot)"]
        try:
            if not atips.tips_hidden():
                slug = str(getattr(j, "slug", "") or "")
                if slug:
                    out += ["", "Tip: " + atips.tip_for(self.where_page_only(j))]
        except Exception:                # noqa: BLE001
            pass
        out += ["", odk.describe(odk.current_mode())]
        note = lai.windows_worker_note()
        if note:
            # the lines below are the bash script: PowerShell cannot run them (an
            # unquoted path with spaces besides), so say what is true here instead.
            # Line by line: the Mac note has its brew command on a line of its own.
            out += ["", *note.splitlines(), ""]
        else:
            cmds = odk.commands_for(self.generator_dir)
            out += ["", "Run it yourself:  " + cmds["todo"], "                  " + cmds["chat"], ""]
        if getattr(self, "warning", ""):
            # above the conversation: the transcript shows only its last 12 lines, and a
            # long answer would push a warning above the answer out of view
            out += [f"!! {self.warning}", ""]
        if self.transcript:
            out += ["conversation:"] + [f"  {t}" for t in self.transcript[-12:]] + [""]
        if self.message:
            out += [self.message, ""]
        return out + _help_lines(bool(note), platform_info.blocker_kind(note))

    def where_page_only(self, j) -> actxt.Where:
        """The page half only (no file reads): for the tip line."""
        slug = str(getattr(j, "slug", "") or "")
        step, row = self._step_and_row(j)
        tab = {1: "identity", 2: "look", 3: "services", 4: "ways"}.get(
            getattr(step, "section", 0), "") if step is not None else ""
        return actxt.Where(face="tui", slug=slug, domain=str(getattr(row, "name", "") or ""), tab=tab)

    def prompt(self, j) -> str:  # noqa: ARG002
        return "local-ai> "

    def feed(self, j, line: str) -> None:
        self.message = ""
        self.warning = ""
        low = line.strip().lower()
        if self._pull_ask:
            model, self._pull_ask = self._pull_ask, ""
            if low in ("y", "yes"):
                self._start_pull(model)
            else:
                self.message = "Nothing downloaded."
            return
        if low in ("q", "quit", "exit", "back", "b"):
            j.overlay = self._under
            return
        if low in ("", "r", "refresh"):
            self.snapshot = self._snapshot_fn()
            return
        if low == "clear":
            self.history.clear()
            self.transcript.clear()
            self._pending = None
            self._undo.clear()
            return
        words = low.split()
        # The mode command is the bare word ``ollama`` or ``ollama <one plain word>``
        # (docker / system; anything else gets the hint). A sentence that merely
        # STARTS with the word ("ollama keeps crashing, what should I check?") is a
        # question for the model, as every non-command line always was.
        if words and words[0] == "ollama" and (
                len(words) == 1 or (len(words) == 2 and words[1].isalpha())):
            want = words[1] if len(words) == 2 else ""
            if want not in odk.MODES:
                self.message = "Say: ollama docker, or ollama system."
                return
            odk.set_mode(want)
            self.snapshot = self._snapshot_fn()
            self.message = odk.describe(want) + (
                "  Type start to start it." if want == odk.DOCKER else "")
            return
        if words and words[0] == "pull" and len(words) <= 2:
            self._ask_pull(words[1] if len(words) == 2 else "")
            return
        if low in ("cancel", "stop") and self.pulling:
            self._pull_stop.set()
            self.message = "Stopping the download; what arrived is kept, and the next pull resumes."
            return
        if low == "start":
            res = self._start_fn()
            self.message = (res.message if res.ok or not res.command or res.command in res.message
                            else f"{res.message} Run it yourself: {res.command}")
            return
        if low in ("tips on", "tips off"):
            atips.set_tips_hidden(low == "tips off")
            self.message = "Tips hidden (tips on shows them again)." if low == "tips off" else "Tips shown."
            return
        if low == "options":
            opts = acat.options_for(self.where_page_only(j))
            text = acat.render_options(opts, budget_tokens=2000) or "(no settings on this page)"
            self.transcript += ["options:"] + [f"  {ln}" for ln in text.split("\n")]
            return
        if words and words[0] == "docs" and len(words) > 1:
            self._docs(j, line.strip()[len("docs"):].strip())
            return
        if low in ("apply", "cancel", "undo"):
            self._change_command(j, low)
            return
        try:
            answer = self._ask(j, line.strip())
        except lai.LocalAIError as exc:
            self.message = str(exc)
            if isinstance(exc, lam.NoModel):
                # the offer, in this screen's word; the question is remembered
                self._pull_offer = dict(exc.offer)
                self._pending_question = line.strip()
                self.message += " " + lam.action_words(exc.offer, "tui")
            if self._last_prompt is not None:
                fb = aprompt.fallback_line(self._last_prompt)
                if fb:
                    self.transcript += [f"ai:  {aprompt.NOT_RUNNING}", f"ai:  {fb}"]
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
        self.transcript.append(f"you: {line.strip()}")
        banner = aprompt.danger_banner(answer)
        if banner:
            # ABOVE the answer, never only in the footer: it spells a command that
            # deletes data (assistant_docs.destructive_commands)
            self.transcript += [f"!!   {ln}" for ln in banner.split("\n")]
            self.message = aprompt.DANGER_NOTE
            self.warning = banner
        self.transcript += [f"ai:  {ln}" for ln in answer.strip().split("\n")]
        prompt = self._last_prompt
        if prompt is not None:
            footer = aprompt.after_answer(answer, prompt)
            if footer:
                self.transcript += [f"     {ln}" for ln in footer.split("\n")]
            self._offer(j, answer, line.strip(), prompt)

    # ── a model out of the box ─────────────────────────────────────────────────────
    @property
    def pulling(self) -> bool:
        return self._pull_thread is not None and self._pull_thread.is_alive()

    def _ask_pull(self, model: str) -> None:
        """``pull [model]``: the size and the free space, then a y/n. Nothing is
        downloaded without the y."""
        if self.pulling:
            self.message = (lam.active_line() or "A download is running.") + \
                "  Type cancel to stop it."
            return
        snap_offer = dict(getattr(self.snapshot, "offer", None) or {})
        model = model or str((self._pull_offer or snap_offer).get("model") or "") \
            or lam.RECOMMENDED.name
        env = odk.assistant_env(odk.current_mode())
        free = (self._free_fn or lam.free_bytes)(env)
        problem = lam.space_problem(lam.size_of(model), free)
        if problem:
            self.message = problem
            return
        self._pull_ask = model
        self.message = (f"{lam.consent_line(model, free)}  Into {lam.where_words(env)}. "
                        "Type y to download, anything else to leave it.")

    def _start_pull(self, model: str) -> None:
        import threading
        env = odk.assistant_env(odk.current_mode())
        stop = threading.Event()
        fn = self._pull_fn or lam.pull
        self._pull_stop = stop

        def work():
            try:
                res = fn(model, env, should_stop=stop.is_set)
            except Exception as exc:             # noqa: BLE001 — a sentence on the screen
                res = lam.PullResult(False, model, f"The download failed: {exc}")
            if res.ok:
                self._pull_offer = {}
                try:
                    self.snapshot = self._snapshot_fn()
                except Exception:                # noqa: BLE001 — r re-reads
                    pass
                again = self._pending_question
                self._pending_question = ""
                self.message = res.message + (f" Ask again: {again}" if again else
                                              " Ask your question.")
            else:
                self.message = res.message
        self._pull_thread = threading.Thread(target=work, name="local-ai-tui-pull", daemon=True)
        self._pull_thread.start()
        self.message = (f"Downloading {model} into {lam.where_words(env)}. The line below "
                        "shows the progress (r re-reads this screen); cancel stops it.")

    def wait_pull(self, timeout: float = 30.0) -> bool:
        """Wait for a running download (tests, and the plain face's ``r``)."""
        t = self._pull_thread
        if t is not None:
            t.join(timeout)
        return not self.pulling

    # ── grounded answers ───────────────────────────────────────────────────────────
    def _ask(self, j, text: str) -> str:
        """The question with its context. A ``prompt_fn`` a test injected takes the
        plain (text, history) pair as before and gets no footer."""
        self._last_prompt = None
        if self._custom_prompt:
            return self._prompt_fn(text, list(self.history))
        where = self.where(j, text)
        env = odk.assistant_env(odk.current_mode())
        prompt = aprompt.build(text, where, list(self.history), env=env,
                               generator_dir=self.generator_dir)
        self._last_prompt = prompt                # kept first: a dead model still gets the docs
        return lai.send_prompt(text, env=env, history=prompt.history, system=prompt.system)

    def _docs(self, j, question: str) -> None:
        """``docs <question>``: the top snippets, no model."""
        try:
            idx = adocs.load_index(adocs.generator_dir(self.generator_dir))
            chunks = adocs.retrieve(question, self.where_page_only(j), index=idx, k=3)
        except Exception as exc:         # noqa: BLE001
            self.message = f"could not read the docs: {exc.__class__.__name__}"
            return
        self.transcript.append(f"you: docs {question}")
        for c in chunks:
            self.transcript.append(f"     [doc: {c.label}]")
            self.transcript += [f"     {ln}" for ln in c.text.strip().split("\n")[:12]]
        self.transcript.append("     " + adocs.sources_line(chunks, index=idx))

    def _offer(self, j, answer: str, question: str, prompt) -> None:
        proposal = aact.parse_proposal(answer, question)
        if proposal is None:
            if "```change" in answer:
                self.transcript.append("     " + aact.NO_BLOCK_HINT)
            return
        where = (prompt.where if prompt is not None else self.where_page_only(j)).with_page(
            question=question)
        v = aact.validate(proposal, where, self._target(j))
        self._pending = (v, where) if not isinstance(v, aact.Refusal) else None
        self.transcript += ["     " + ln for ln in aact.card_lines(v)]

    def _change_command(self, j, verb: str) -> None:
        target = self._target(j)
        if verb == "cancel":
            self._pending = None
            self.message = "Cancelled; nothing was changed."
            return
        if verb == "undo":
            # filed under the target AND its domain: an undo on another domain's step
            # finds nothing here (it never writes the step on screen)
            key = aact.undo_key(target) if target is not None else ""
            applied = self._undo.get(key) if key else None
            if applied is None:
                elsewhere = sorted({a.change.domain for a in self._undo.values() if a.change.domain})
                self.message = ("Nothing to undo on this domain; the last change was on "
                                f"{', '.join(elsewhere)} (undo it there)." if elsewhere
                                else "Nothing to undo.")
                return
            res = aact.undo(applied, self.where_page_only(j), target)
            if isinstance(res, aact.Refusal):
                self.message = res.text
                return
            self._undo.pop(key, None)
            self.message = "Undone."
            return
        if self._pending is None:
            self.message = "Nothing is proposed; ask for a change first."
            return
        v, where = self._pending
        if target is None:
            self.message = "Open the domain's step first."
            return
        res = aact.apply(v, where, target)
        if isinstance(res, aact.Refusal):
            self.message = res.text
            return
        self._undo[res.target_id] = res
        self._pending = None
        self.message = "Applied. The step shows the new value (undo puts it back)."


def _offer_in_tui_words(snap):
    """A no-model snapshot's fix in this screen's words (``type pull``), with the
    by-hand line for the Ollama in use."""
    offer = dict(getattr(snap, "offer", None) or {})
    if snap is not None and offer:
        snap.fix = lam.fix_words(offer, "tui", odk.assistant_env(odk.current_mode()))
    return snap


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
