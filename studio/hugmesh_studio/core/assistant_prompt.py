"""Assembling what the local model is asked, under a hard token budget (Qt-free).

One function, :func:`build`, turns a question into the system message every face
sends: the primer (core/agent_context.primer_text, the ONE description of the
project), the rules, where the person is (core/assistant_context.render_where), the
options on this page (core/assistant_catalogue.render_options), the retrieved doc
snippets (core/assistant_docs.retrieve) and, on a page with proposable options, the
change format (core/assistant_actions). Each part has a cap; the whole must fit the
model's context minus a reserve for the answer. When it cannot, parts are dropped in a
fixed order (options, snippets, where, history) and ``Prompt.budget["dropped"]`` says
which, so a face can tell the person "page facts left out".

:func:`answer` is what the three faces that render a footer call: build, then
``local_ai_status.send_prompt`` with the system message and the trimmed history, then
return the bare answer and the Prompt. :func:`after_answer` makes the footer: the
Sources line (never written by the model) and, when the answer spells a command no
snippet contains, the "Commands not found in the docs I read" line. History stores the
bare answer only, so the token trim never fights the citations.

``LOCAL_AI_GROUNDED=1`` makes ``send_prompt`` itself build a command-line Where and
ground a bare call (``scripts/local-ai.sh prompt|chat`` export it); nothing in this
module passes a grounded system message twice.
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from typing import Callable, Optional

from . import agent_context as actx
from . import assistant_actions as aact
from . import assistant_catalogue as acat
from . import assistant_context as actxt
from . import assistant_docs as adocs
from .assistant_context import Where, render_where, tokens

__all__ = [
    "Prompt", "RULES", "CHANGE_FORMAT", "DIFF_FORMAT", "CAPS", "ANSWER_RESERVE", "build",
    "answer", "after_answer", "trim_history", "tokens", "GROUNDED_ENV", "primer_for",
    "FACTS_DROPPED", "NOT_RUNNING", "fallback_line", "RULES_BLOCK_CAP", "DESTRUCTIVE_WARNING",
    "danger_banner", "WarnGate", "scrub_paths", "DANGER_NOTE", "DANGER_SENTENCES",
]

GROUNDED_ENV = "LOCAL_AI_GROUNDED"
ANSWER_RESERVE = 6000
MIN_RESERVE = 4096
CAPS = {"primer": 600, "rules": 440, "where": 500, "options": 600, "snippets": 3500,
        "history": 3000}
FACTS_DROPPED = "(page facts left out: the question is long)"
NOT_RUNNING = "[Local AI is not running. Press Start local assistant.]"

RULES = (
    "Answer from the primer, the page facts and the snippets only. When they do not "
    "hold the answer, say \"I do not know from the docs I have\" and point at the "
    "walkthrough. Never write a command, flag or path that no snippet contains. Keep "
    "to this page and this domain unless the person names another. Everything stays on "
    "this machine. Answer a how or what question in words first; propose a change only "
    "when the person asks for one, and never claim to have made it (only Apply does). "
    "Never invent a shell command. To wipe, reset or start the local mesh fresh, point "
    "to the Studio's buttons (Stop mesh keeps the data; Stop & clean Docker… removes "
    "its volumes and images after asking) and make stack-halt or make stack-down; never "
    "a command that deletes files, containers, images or volumes."
)

# No angle-bracket placeholders anywhere in these texts: a small model copies them
# verbatim (the 2026-10-29 eval answered "I cannot change <that> here").
CHANGE_FORMAT = (
    "To propose one setting change: one sentence, then one fenced block tagged change "
    "holding a JSON object: domain (the one on screen unless another is named), field (a key under Options), to (one of its choices, true/false, or a "
    "hex colour). For services, to is the whole new list: start from its current list, "
    "then add or remove. A colour described in words is a hex value in look.primary or "
    "look.secondary, never a preset. If the setting is not under Options (a password, "
    "a key, a path), write no block; say so and list the Options keys. "
    # The wording is measured, not decorative: "Example (made up; never copy it):" over
    # a plain sentence kept the code-edit answers' diffs whole (4/4 on qwen3:8b), where a
    # longer "made up and always refused" note broke all of them (0/4; PR #832 round 6).
    "Example (made up; never copy it):\n"
    + aact.EXAMPLE_SENTENCE + "\n"
    "```change\n" + json.dumps(aact.EXAMPLE_PROPOSAL) + "\n```"
)

DIFF_FORMAT = (
    "To edit a file shown under Files: one sentence, then one fenced block tagged diff "
    "holding a unified diff (--- a/path, +++ b/path, @@ -start,count +start,count @@) "
    "against that exact text, paths relative to the code folder. At most 3 files and "
    "120 changed lines. Never suggest git."
)

#: The first words of the warning shown above an answer (and first in its footer) that
#: spells a command which deletes data. :func:`danger_banner` adds one sentence per KIND
#: of delete command (assistant_docs.destructive_kinds), so the warning fits the
#: command: the Docker button for a docker prune, what is lost for an Ollama model or a
#: WSL distro. No sentence ever spells a command itself (a small model copies what it
#: is shown, and the footer must never list the warning's own words).
DESTRUCTIVE_WARNING = ("WARNING: this answer contains commands that delete data. Do not "
                       "run them before you know exactly what each one removes.")
#: One sentence per kind, in assistant_docs.DESTRUCTIVE_KIND_ORDER.
DANGER_SENTENCES = {
    "wsl": ("Unregistering a WSL distro deletes that whole Linux system and every file in "
            "it: your checkouts, the Studio's settings and the mesh's data. Nothing undoes it."),
    "disk": ("The disk ones erase a whole disk or partition, and a wrong device name erases "
             "the wrong one. To write an image to a USB stick or SD card use the Studio's "
             "Flash (DESTRUCTIVE) verb, which checks the device and asks you to type its "
             "serial first (STUDIO-WALKTHROUGH.md)."),
    "files": ("The file ones delete files and folders for good, with no recycle bin; check "
              "every path first."),
    "mesh": ("The Docker ones remove containers, images or volumes, some beyond this mesh. "
             "The documented ways: the Studio's Stop & clean Docker… button on the Local "
             "Docker mesh step (it asks first and lists what it removes; "
             "STUDIO-WALKTHROUGH.md), or make stack-down in the generator checkout (stops the "
             "local stack and drops its volumes; LOCAL-STACK.md). Stop mesh (make stack-halt) "
             "stops it and keeps the data."),
    "cluster": ("The Kubernetes ones delete a cluster or what runs in it, data included. For "
                "the local kind lane the documented control is make kind-down (the next "
                "bring-up comes back empty); make kind-halt stops it and keeps everything "
                "(STUDIO-WALKTHROUGH.md)."),
    "database": "The database ones delete a database and every row in it.",
    "model": ("Removing an Ollama model deletes its downloaded weights from this machine (5 "
              "to 25 GB each, LOCAL-AI-ASSISTANT.md); getting it back means downloading it "
              "again."),
    "app": "Uninstalling an app with its data deletes that app's settings and files too.",
    "git": ("The git ones throw away work that is not committed, or rewrite what is on the "
            "server; commit or stash first."),
}
#: The one-line form for a status line: generic, the warning above says which.
DANGER_NOTE = ("Do not run the delete commands in this answer before you know what each "
               "one removes: read the warning above it.")


def danger_banner(answer_text: str, kinds: "Optional[list]" = None) -> str:
    """The warning for ``answer_text`` when it spells a command that deletes data
    (assistant_docs.destructive_commands), else ``""``: :data:`DESTRUCTIVE_WARNING` and
    one sentence per kind of delete command it holds. One line. Whether or not a doc
    spells the command. ``kinds`` (assistant_docs.destructive_kinds) overrides."""
    if kinds is None:
        kinds = adocs.destructive_kinds(answer_text or "")
    if not kinds:
        return ""
    return " ".join([DESTRUCTIVE_WARNING] + [DANGER_SENTENCES[k] for k in kinds
                                              if k in DANGER_SENTENCES])


class WarnGate:
    """Stream an answer through ``emit`` one line at a time (a fenced block at a time),
    and emit :data:`DESTRUCTIVE_WARNING` BEFORE the first line or block that deletes
    data, so a streaming terminal shows the warning above the command, never after it
    has been read. :meth:`finish` flushes the rest; ``warned`` says whether it fired."""

    _FENCE = re.compile(r"^[ \t]*(?:`{3,}|~{3,})")

    def __init__(self, emit: Callable[[str], None]):
        self.emit = emit
        self.warned = False
        self.kinds: list = []
        self._buf = ""
        self._held = ""
        self._fence = False

    def _release(self, text: str) -> None:
        if not text:
            return
        kinds = adocs.destructive_kinds(text)
        new = [k for k in kinds if k not in self.kinds]
        if new:
            self.kinds += new
            if not self.warned:
                self.warned = True
                self.emit("\n" + danger_banner(text, new) + "\n\n")
            else:                       # a later block deletes something else: say so too
                self.emit("\nWARNING, also: " + " ".join(DANGER_SENTENCES[k] for k in new)
                          + "\n\n")
        self.emit(text)

    def feed(self, chunk: str) -> None:
        self._buf += chunk or ""
        while True:
            nl = self._buf.find("\n")
            if nl < 0:
                return
            line, self._buf = self._buf[:nl + 1], self._buf[nl + 1:]
            if self._FENCE.match(line):
                self._fence = not self._fence
            self._held += line
            if not self._fence:
                held, self._held = self._held, ""
                self._release(held)

    def finish(self) -> None:
        rest, self._held, self._buf = self._held + self._buf, "", ""
        self._release(rest)


# Machine paths never reach the model: it once answered "wipe everything" with
# rm -rf of the checkouts folder and the generator checkout the primer had named
# (PR #832, round 6), and once repeated a build log path on another disk back to the
# person (round 7). Each absolute path under the generator checkout becomes relative
# to it, one under the checkouts folder relative to that, one under the home folder
# starts with ~, and the folders themselves become words. STRICT (every part the
# machine fills in: primer, page facts, options, files, history): ANY other absolute
# path — /mnt/<disk>/..., /media/<user>/..., /run/media/<user>/..., /var/tmp/portage/...,
# C:\Users\<user>\..., \\server\share\... — keeps only its last two parts, never a
# user name. NOT strict (the docs snippets: the repo's own text, the same on every
# machine): only /home, /Users, /var/home, /root, /media and /run/media paths are cut,
# so documented paths such as /etc/wireguard and `-v ollama:/root/.ollama` reach the
# model whole.
_PATH_CHARS = r"[^\s`'\"<>()\[\]{},;|]"
_ABS_PATH_RE = re.compile(
    r"(?P<posix>(?<![\w.~/\\\-])/" + _PATH_CHARS + r"+)"
    r"|(?P<drive>(?<![\w\\/])[A-Za-z]:[\\/]" + _PATH_CHARS + r"*)"
    r"|(?P<unc>(?<![\w\\])\\\\[^\s`'\"<>()\[\]{},;|\\]+\\" + _PATH_CHARS + r"*)")
_HOME_LIKE_RE = re.compile(r"^/(?:home|Users|root|var/home|media|run/media)(?:/|$)")


def _user_slot(parts: "list[str]") -> int:
    """The index of the user-name component of a path split into ``parts`` (/home/<u>,
    /Users/<u>, /var/home/<u>, /media/<u>, /run/media/<u>, /mnt/c/Users/<u>,
    C:/Users/<u>), else -1."""
    low = [p.lower() for p in parts]
    if low[:1] in (["home"], ["users"], ["media"]) and len(parts) > 1:
        return 1
    if low[:2] in (["var", "home"], ["run", "media"]) and len(parts) > 2:
        return 2
    if low[:1] == ["mnt"] and len(parts) > 3 and len(parts[1]) == 1 and low[2] == "users":
        return 3
    if parts and re.fullmatch(r"[A-Za-z]:", parts[0]) and len(parts) > 2 and low[1] == "users":
        return 2
    return -1


def _tail(path: str, n: int = 2, users: "frozenset" = frozenset()) -> str:
    """``…/`` and the last ``n`` parts of ``path``, never its user-name part."""
    sep = "\\" if "\\" in path and "/" not in path.lstrip("/") else "/"
    parts = [p for p in re.split(r"[\\/]+", path) if p]
    slot = _user_slot(parts)
    if slot >= 0:
        parts = parts[slot + 1:]
    parts = [p for p in parts if p not in users]
    return "…" + sep + sep.join(parts[-n:]) if parts else "…"


def _norm(path: str) -> str:
    p = path.replace("\\", "/").rstrip("/")
    return p.lower() if re.match(r"^[A-Za-z]:/", p) else p


def scrub_paths(text: str, *, generator_dir: str = "", checkouts_root: str = "",
                home: str = "", strict: bool = True) -> str:
    """``text`` with this machine's absolute paths made relative or descriptive (see the
    comment above: ``strict`` for what the machine fills in, not for doc snippets)."""
    if not text:
        return text
    roots = []
    users = set()
    for base, word, kind in ((generator_dir, "the generator checkout", "gen"),
                             (checkouts_root, "the checkouts folder", "root"),
                             (home, "the home folder", "home")):
        if not base:
            continue
        for b in {os.path.abspath(base), os.path.realpath(base), base}:
            b = _norm(b)
            if b and b != "/" and not re.fullmatch(r"[a-z]:", b):
                roots.append((b, word, kind))
        if kind == "home":
            users.add(os.path.basename(os.path.normpath(base.replace("\\", "/"))))
    for var in ("USER", "LOGNAME", "USERNAME"):
        if os.environ.get(var):
            users.add(os.environ[var])
    users = frozenset(u for u in users if u and len(u) > 1)
    roots.sort(key=lambda r: -len(r[0]))

    def one(m) -> str:
        tok = m.group(0)
        trail = ""
        while tok and tok[-1] in ".:!?":
            trail = tok[-1] + trail
            tok = tok[:-1]
        if not tok:
            return m.group(0)
        if m.group("posix") is not None and m.start() > 0 and text[m.start() - 1] == ":":
            if tok.startswith("///"):            # file:///home/<user>/...
                return "//" + one_path(tok[2:]) + trail
            if tok.startswith("//") or not strict:
                return m.group(0)    # a URL (https://...), or a doc's name:/path volume
        return one_path(tok) + trail

    def one_path(tok: str) -> str:
        n = _norm(tok)
        for b, word, kind in roots:
            if n == b:
                return word
            if n.startswith(b + "/"):
                rest = tok.replace("\\", "/")[len(b) + 1:]   # n, with its case
                return "~/" + rest if kind == "home" else rest
        if strict or _HOME_LIKE_RE.match(tok):
            return _tail(tok, users=users)
        return tok

    return _ABS_PATH_RE.sub(one, text)


# The rules block is never truncated: a cut here once removed the diff grammar
# entirely (tests/test_assistant_prompt.py pins that every combination fits).
RULES_BLOCK_CAP = CAPS["rules"] + 150


@dataclass(frozen=True)
class Prompt:
    system: str
    history: "list[dict]"
    sources: "list" = field(default_factory=list)
    budget: dict = field(default_factory=dict)
    where: Optional[Where] = None
    primer: str = ""


#: Where the sources are, in words: the coding-agent brief names the two folders, the
#: assistant's primer never does (see scrub_paths).
PRIMER_SOURCES = (
    "\n\n## Where the local sources are\n"
    "- The checkouts folder (a Studio setting) holds the person's checkouts; paths here "
    "are relative to the generator checkout (scripts/, docs/) or start with ~."
)


def checkouts_root_for(generator_dir: str, environ: Optional[dict] = None) -> str:
    try:
        return actx.checkouts_dir(generator_dir, environ)
    except Exception:                        # noqa: BLE001
        return os.path.dirname(os.path.abspath(generator_dir))


def primer_for(generator_dir: str, environ: Optional[dict] = None) -> str:
    """The primer, with the sources described in words, never as this machine's paths
    (settings read; no network)."""
    text = actx.primer_text(generator_dir, with_sources=False) + PRIMER_SOURCES
    return _cap(text, CAPS["primer"])


def _cap(text: str, cap: int) -> str:
    if tokens(text) <= cap:
        return text
    return text[: int(cap * 3.2) - 1].rstrip() + "…"


def trim_history(history: "list[dict]", cap_tokens: int) -> "list[dict]":
    """Newest messages first, pairs kept whole, under ``cap_tokens``."""
    msgs = [m for m in (history or []) if isinstance(m, dict) and m.get("content")]
    pairs: list = []
    i = len(msgs)
    while i > 0:
        if i >= 2 and msgs[i - 2].get("role") == "user" and msgs[i - 1].get("role") == "assistant":
            pairs.append(msgs[i - 2:i])
            i -= 2
        else:
            pairs.append(msgs[i - 1:i])
            i -= 1
    kept: list = []
    used = 0
    for pair in pairs:                        # newest first
        cost = sum(tokens(str(m.get("content", ""))) + 4 for m in pair)
        if used + cost > cap_tokens:
            break
        kept.insert(0, pair)
        used += cost
    return [m for pair in kept for m in pair]


def _options_block(where: Where) -> "tuple[str, bool]":
    try:
        opts = acat.options_for(where)
    except Exception:                        # noqa: BLE001 — the catalogue never blocks an answer
        return "", False
    if not opts:
        return "", False
    cur = dict(getattr(where, "current", ()) or ())
    reader = (lambda o: cur.get(o.key)) if cur else None
    return (acat.render_options(opts, budget_tokens=CAPS["options"], current=reader),
            any(o.setter for o in opts))


def build(question: str, where: Optional[Where], history: "list[dict] | None" = None, *,
          env: Optional[dict] = None, generator_dir: Optional[str] = None,
          ctx_tokens: Optional[int] = None, index: Optional["adocs.Index"] = None,
          snippets: Optional[list] = None, files_block: str = "",
          k: int = 5) -> Prompt:
    """Assemble the system message and the trimmed history for ``question``."""
    from . import local_ai_status as lai
    env = dict(os.environ if env is None else env)
    where = where or Where(face="cli")
    gen = adocs.generator_dir(generator_dir, env)
    ctx = ctx_tokens or lai._context_size(env)
    reserve = max(MIN_RESERVE, min(ANSWER_RESERVE, ctx // 2))
    room = ctx - reserve

    primer = primer_for(gen, env)
    rules = RULES
    options_text, proposable = _options_block(where)
    fmt = ""
    if proposable:
        fmt = CHANGE_FORMAT
    if files_block:
        fmt = (fmt + "\n\n" if fmt else "") + DIFF_FORMAT
    rules_block = rules + ("\n\n# Change format\n" + fmt if fmt else "")
    where_text = render_where(where)
    try:
        from . import assistant_tips as atips
        tip = atips.tip_for(where, rotation=atips.TipRotation()) if where.slug else ""
    except Exception:                        # noqa: BLE001 — a tip is decoration
        tip = ""
    if tip:
        where_text += f"\n- about this page: {tip}"
    if index is None:
        try:
            index = adocs.load_index(gen)
        except Exception:                    # noqa: BLE001
            index = adocs.Index()
    snippet_budget = min(CAPS["snippets"], max(0, room - tokens(primer) - tokens(rules_block)
                                                - tokens(where_text) - tokens(options_text)
                                                - tokens(question) - tokens(files_block)))
    if snippets is None:
        want_k = 1 if files_block else k
        chunks = adocs.retrieve(question, where, index=index, budget_tokens=snippet_budget,
                                k=want_k) if snippet_budget > 0 else []
    else:
        chunks = list(snippets)
    snippets_text = "\n\n".join(f"[doc: {c.label}]\n{c.text}" for c in chunks)

    home = env.get("HOME") or os.path.expanduser("~")
    root = checkouts_root_for(gen, env)

    def scrub(text: str, strict: bool = True) -> str:
        return scrub_paths(text, generator_dir=gen, checkouts_root=root, home=home,
                           strict=strict)

    parts = {"primer": scrub(primer), "rules": rules_block, "where": scrub(where_text),
             "options": scrub(options_text), "snippets": scrub(snippets_text, strict=False),
             "files": scrub(files_block)}
    dropped: list = []
    fixed = tokens(question) + 20

    def total(hist_tokens: int = 0) -> int:
        return fixed + sum(tokens(v) + 8 for v in parts.values() if v) + hist_tokens

    for name in ("options", "snippets", "where"):
        if total() > room and parts.get(name):
            parts[name] = ""
            dropped.append(name)
            if name == "snippets":
                chunks = []
        elif name == "snippets" and snippets is None and snippet_budget <= 0:
            dropped.append(name)                  # there was no room to retrieve any
    hist_cap = min(CAPS["history"], max(0, room - total()))
    hist = [dict(m, content=scrub(str(m.get("content", "")))) if isinstance(m, dict) else m
            for m in trim_history(history or [], hist_cap)]
    if (history or []) and not hist:
        dropped.append("history")
    hist_tokens = sum(tokens(str(m.get("content", ""))) + 4 for m in hist)

    blocks = ["# HugMesh primer\n" + parts["primer"], "# Rules\n" + parts["rules"]]
    if parts["where"]:
        blocks.append("# Where the person is\n" + parts["where"])
    if parts["options"]:
        blocks.append("# Options on this page\n" + parts["options"])
    if parts["snippets"]:
        blocks.append("# Snippets\n" + parts["snippets"])
    if parts["files"]:
        blocks.append("# Files\n" + parts["files"])
    system = "\n\n".join(blocks)
    budget = {k: tokens(v) for k, v in parts.items()}
    budget.update({"question": tokens(question), "history": hist_tokens,
                   "total": total(hist_tokens), "ctx": ctx, "reserve": reserve,
                   "dropped": dropped, "no_docs": bool(index is not None and index.empty)})
    return Prompt(system=system, history=hist, sources=chunks, budget=budget, where=where,
                  primer=parts["primer"])


def after_answer(answer_text: str, prompt: Prompt, *, index: Optional["adocs.Index"] = None) -> str:
    """The footer: :data:`DESTRUCTIVE_WARNING` first when the answer spells a command
    that deletes data, the Sources line, plus the unverified-commands line when needed."""
    if prompt is None:
        return ""
    if prompt.budget.get("no_docs") and not prompt.sources:
        line = adocs.NO_DOCS_SOURCES
    else:
        line = adocs.sources_line(prompt.sources, index=index)
    banner = danger_banner(answer_text)
    if banner:
        line = banner + "\n" + line
    bad = adocs.unverified_commands(answer_text or "", prompt.sources, prompt.primer)
    if bad:
        line += "\nCommands not found in the docs I read: " + ", ".join(bad)
    if "where" in prompt.budget.get("dropped", []):
        line += "\n" + FACTS_DROPPED
    try:
        w = prompt.where
        note = aact.never_set_note(getattr(w, "question", "") or "", w, answer_text)
    except Exception:                        # noqa: BLE001 — a note is a help, never a crash
        note = ""
    if note:
        line += "\n" + note
    return line


def fallback_line(prompt: Prompt) -> str:
    """What a face shows beside NOT_RUNNING when no model answers."""
    if prompt is None:
        return ""
    idx = adocs.Index() if prompt.budget.get("no_docs") else None
    return adocs.fallback_text(prompt.sources, prompt.primer, index=idx)


def answer(question: str, where: Optional[Where], history: "list[dict] | None" = None, *,
           env: Optional[dict] = None, generator_dir: Optional[str] = None,
           on_chunk: Optional[Callable[[str], None]] = None,
           should_stop: Optional[Callable[[], bool]] = None, model: Optional[str] = None,
           options: Optional[dict] = None, timeout: float = 120.0,
           total_timeout: float = 900.0, **build_kw) -> "tuple[str, Prompt]":
    """Build the prompt and ask the model. Returns ``(bare answer, prompt)``; raises
    ``LocalAIError`` as ``send_prompt`` does (the faces show the sentence and the
    model-free fallback). The module attribute is looked up at call time so a test's
    fake ``send_prompt`` is honoured."""
    from . import local_ai_status as lai
    prompt = build(question, where, history, env=env, generator_dir=generator_dir, **build_kw)
    text = lai.send_prompt(question, model, env=env, history=prompt.history,
                           system=prompt.system, on_chunk=on_chunk, should_stop=should_stop,
                           options=options, timeout=timeout, total_timeout=total_timeout)
    return text, prompt
