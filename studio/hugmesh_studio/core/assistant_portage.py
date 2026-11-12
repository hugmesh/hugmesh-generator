"""The local AI assistant's portage tool for the Desktop step — Qt-free.

The assistant does not call functions: it answers in text, and a fenced block in that
text becomes a card the operator applies or ignores (``change`` -> a proposal card,
core/assistant_actions.py; ``diff`` -> a code-edit card, core/assistant_code_edits.py).
This module adds the third block, for the Desktop step only:

    ```portage
    package.use >=media-video/ffmpeg-7.1.5 opus x264
    accept_keywords =media-video/obs-studio-32.2.2 ~amd64
    ```

* The model READS the last emerge --pretend run (its status, the changes portage named
  and the tail of the resolver output — core/desktop_pretend.facts, given to it under its
  own token budget, :data:`PRETEND_TOKEN_CAP`) and PROPOSES overlay lines.
* :func:`parse` takes the first ``portage`` block; every line is checked with the SAME
  grammar the builder enforces (core/desktop_spec.check_change, which mirrors
  scripts/_desktop-config-lib.sh): no wildcards, no video_cards_*/python_* flags, only
  the image's own testing keyword, never a mask or licence edit.
* A line portage itself did not name in the last run is allowed but LABELLED ("not
  portage's own suggestion; Re-check decides").
* Nothing changes until the operator presses Apply on the card; Apply records each line
  in the spec's append-only history (source "assistant") and offers Re-check, and Undo
  removes exactly what that Apply added.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from . import desktop_spec as ds

#: The prompt's token budget for the pretend facts (the page facts' own cap is ~500).
PRETEND_TOKEN_CAP = 1500

PORTAGE_FORMAT = (
    "To propose portage changes for this image: one sentence, then one fenced block "
    "tagged portage, one change per line, each line either 'package.use' then an atom "
    "and its USE flags, or 'accept_keywords' then an atom and the testing keyword. Use "
    "the atoms and flags the emerge --pretend result names; never a wildcard, never "
    "video_cards or python_targets flags, never a mask or licence change. Nothing "
    "changes until the person presses Apply, and Re-check decides whether it worked.\n"
    "Example (made up; never copy it):\n"
    "Portage asks for these two changes.\n"
    "```portage\n"
    "package.use >=media-libs/example-1.0 foo\n"
    "accept_keywords =app-misc/example-2.0 ~amd64\n"
    "```"
)

NOT_PORTAGES_OWN = "not portage's own suggestion; Re-check decides"
_FENCE_RE = re.compile(r"```portage\s*\n(.*?)```", re.S)
_KINDS = {"package.use": "package.use", "use": "package.use",
          "accept_keywords": "accept_keywords", "package.accept_keywords": "accept_keywords",
          "keywords": "accept_keywords"}


@dataclass
class PortageLine:
    kind: str
    line: str
    problem: str = ""            # why it can never be applied ("" = applicable)
    note: str = ""               # e.g. NOT_PORTAGES_OWN

    @property
    def change(self) -> ds.OverlayChange:
        return ds.OverlayChange(self.kind, self.line)


@dataclass
class PortageProposal:
    sentence: str
    lines: list[PortageLine] = field(default_factory=list)

    def applicable(self) -> list[ds.OverlayChange]:
        return [x.change for x in self.lines if not x.problem]

    def refused(self) -> list[PortageLine]:
        return [x for x in self.lines if x.problem]


def has_block(answer: str) -> bool:
    return "```portage" in (answer or "")


def parse(answer: str, cfg, last_needs: list[tuple[str, str]] | None = None) -> PortageProposal | None:
    """The first ```portage block as a checked proposal, or None (no block)."""
    m = _FENCE_RE.search(answer or "")
    if not m:
        return None
    sentence = (answer[:m.start()].strip().splitlines() or [""])[-1].strip()
    needs = {(k, ds.normalise_line(v)) for k, v in (last_needs or [])}
    out = PortageProposal(sentence=sentence)
    seen: set[tuple[str, str]] = set()
    for raw in m.group(1).splitlines():
        text = raw.strip().lstrip("-*").strip()
        if not text or text.startswith("#"):
            continue
        head, _, rest = text.partition(" ")
        kind = _KINDS.get(head.lower().rstrip(":"))
        if kind is None:
            if head.lower().rstrip(":") in ("mask", "package.unmask", "license", "package.license"):
                out.lines.append(PortageLine(head, rest.strip(),
                                             "mask and licence changes are the operator's decision, "
                                             "made in the specs, never from here"))
            else:
                out.lines.append(PortageLine("?", text, "not a package.use or accept_keywords line"))
            continue
        line = ds.normalise_line(rest)
        key = (kind, line)
        if key in seen:
            continue
        seen.add(key)
        problem = ds.check_change(ds.OverlayChange(kind, line), cfg)
        note = "" if problem or key in needs else NOT_PORTAGES_OWN
        out.lines.append(PortageLine(kind, line, problem, note))
    return out


def diff_text(cfg, proposal: PortageProposal) -> str:
    return "\n".join(ds.overlay_diff(ds.spec_of(cfg), proposal.applicable()))


def apply(cfg, proposal: PortageProposal, pretend_run: str = "") -> list[ds.OverlayChange]:
    """Apply the legal lines (the operator pressed Apply); returns what to Undo."""
    return ds.apply_changes(cfg, proposal.applicable(), source="assistant", pretend_run=pretend_run)


def undo(cfg, applied: list[ds.OverlayChange]) -> None:
    ds.undo_changes(cfg, applied, source="assistant")


def pretend_block(cfg, last_result=None) -> str:
    """The facts the model reads on the Desktop step: the overlay it would change and
    the last pretend run. Redacted like every other page fact, then capped."""
    from . import assistant_context as actxt
    from . import desktop_pretend as dp
    spec = ds.spec_of(cfg)
    lines = ["Desktop step facts:"] + [f"- {x}" for x in ds.summary_lines(cfg)]
    lines.append("current package.use overlay: " + ("; ".join(spec.use_lines) or "none"))
    lines.append("current accept_keywords overlay: " + ("; ".join(spec.keyword_lines) or "none"))
    lines += dp.facts(last_result if last_result is not None else (spec.last_pretend or None))
    text = actxt.redact("\n".join(lines))
    if actxt.tokens(text) > PRETEND_TOKEN_CAP:
        kept: list[str] = []
        for ln in text.splitlines():
            if actxt.tokens("\n".join(kept + [ln])) > PRETEND_TOKEN_CAP:
                kept.append("(resolver output trimmed)")
                break
            kept.append(ln)
        text = "\n".join(kept)
    return text
