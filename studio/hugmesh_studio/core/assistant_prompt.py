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

import os
from dataclasses import dataclass, field
from typing import Callable, Optional

from . import agent_context as actx
from . import assistant_catalogue as acat
from . import assistant_context as actxt
from . import assistant_docs as adocs
from .assistant_context import Where, render_where, tokens

__all__ = [
    "Prompt", "RULES", "CHANGE_FORMAT", "DIFF_FORMAT", "CAPS", "ANSWER_RESERVE", "build",
    "answer", "after_answer", "trim_history", "tokens", "GROUNDED_ENV", "primer_for",
    "FACTS_DROPPED", "NOT_RUNNING", "fallback_line", "RULES_BLOCK_CAP",
]

GROUNDED_ENV = "LOCAL_AI_GROUNDED"
ANSWER_RESERVE = 6000
MIN_RESERVE = 4096
CAPS = {"primer": 600, "rules": 300, "where": 500, "options": 600, "snippets": 3500,
        "history": 3000}
FACTS_DROPPED = "(page facts left out: the question is long)"
NOT_RUNNING = "[Local AI is not running. Press Start local assistant.]"

RULES = (
    "Answer from the primer, the page facts and the snippets only. When they do not "
    "hold the answer, say \"I do not know from the docs I have\" and point at the "
    "walkthrough. Never write a command, flag or path that no snippet contains. Keep "
    "to this page and this domain unless the person names another. Everything stays on "
    "this machine. Never claim to have changed anything; only the Apply button does."
)

# No angle-bracket placeholders anywhere in these texts: a small model copies them
# verbatim (the 2026-10-29 eval answered "I cannot change <that> here").
CHANGE_FORMAT = (
    "To propose one setting change: one sentence, then one fenced block tagged change "
    "holding a JSON object: domain (the domain on screen unless the person named "
    "another), field (a key under Options), to (one of its choices, true/false, a list "
    "of service names, or a hex colour). A colour described in words is a hex value "
    "in look.primary or look.secondary, never a preset. Nothing else in the block. If "
    "the setting is not under Options (a password, a key, a file path), write no block: "
    "say this page cannot change it and list the keys under Options. Example:\n"
    "I can turn the forum off for shop.example.\n"
    "```change\n{\"domain\": \"shop.example\", \"field\": \"services\", "
    "\"to\": [\"akkoma\"]}\n```"
)

DIFF_FORMAT = (
    "To edit a file shown under Files: one sentence, then one fenced block tagged diff "
    "holding a unified diff (--- a/path, +++ b/path, @@ -start,count +start,count @@) "
    "against that exact text, paths relative to the code folder. At most 3 files and "
    "120 changed lines. Applied only when the person presses Apply; never suggest git."
)

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


def primer_for(generator_dir: str, environ: Optional[dict] = None) -> str:
    """The primer with this machine's two paths (settings read; no network)."""
    try:
        root = actx.checkouts_dir(generator_dir, environ)
    except Exception:                        # noqa: BLE001
        root = os.path.dirname(os.path.abspath(generator_dir))
    text = actx.primer_text(generator_dir, root)
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

    parts = {"primer": primer, "rules": rules_block, "where": where_text,
             "options": options_text, "snippets": snippets_text, "files": files_block}
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
    hist = trim_history(history or [], hist_cap)
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
                  primer=primer)


def after_answer(answer_text: str, prompt: Prompt, *, index: Optional["adocs.Index"] = None) -> str:
    """The footer: the Sources line, plus the unverified-commands line when needed."""
    if prompt is None:
        return ""
    if prompt.budget.get("no_docs") and not prompt.sources:
        line = adocs.NO_DOCS_SOURCES
    else:
        line = adocs.sources_line(prompt.sources, index=index)
    bad = adocs.unverified_commands(answer_text or "", prompt.sources, prompt.primer)
    if bad:
        line += "\nCommands not found in the docs I read: " + ", ".join(bad)
    if "where" in prompt.budget.get("dropped", []):
        line += "\n" + FACTS_DROPPED
    try:
        from . import assistant_actions as aact
        w = prompt.where
        note = aact.secret_request_note(getattr(w, "question", "") or "", w, answer_text)
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
