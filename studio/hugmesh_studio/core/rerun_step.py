"""Rerun a build from one of its steps — the logic behind the progress page's rerun icon.

The operator's ask (2026-11-13): *put a rerun icon after each finished step, to stop
and prompt to be sure, then retry the build from that point.*

Qt-free. The progress page asks :func:`plan` what a rerun from a stage means, shows
that sentence for confirmation, and dispatches the session again through
``StudioWizard.start_build_from_session`` with the flags :func:`with_from_step`
returns. Two kinds of rerun exist, and the sentence says which one a stage gets:

* **From the step itself** — the x86 builder's late steps (:data:`LATE_STEPS`). The
  builder skips every step before it, keeps the sysroot and the artifacts those
  steps made, and keeps the earlier run's build stamp
  (``build-x86-host-stage4.sh --resume --from-step STEP``).
* **From the build system** — every other stage. No builder can start in the middle
  of the steps that change the sysroot, so the rerun is ``--resume``: the stage3 is
  not extracted again, and the steps from the spec install onward are repeated.

``--from-step`` rides the session's own ``extra_flags`` (the builder reads that
field last, so it wins), and any earlier ``--from-step`` there is dropped first: a
later plain Restart of the same session therefore never inherits a stale step.
"""
from __future__ import annotations

import shlex
from dataclasses import dataclass

#: The steps each builder can start at, in build order. They must equal the x86
#: builder's ``X86_LATE_STEPS`` and be the tail of the x86 progress table (both pinned
#: by tests/test_rerun_step.py and tests/scripts/test-x86-from-step.sh).
LATE_STEPS: dict[str, tuple[str, ...]] = {
    "x86": ("package-stage4", "image-raw", "image-live", "image-installer"),
}

#: Stage states a rerun icon appears on: the stage has run (or was cut short).
RERUNNABLE_STATES = ("done", "failed", "stopped")

ONE_IMAGE_ONLY = ("Rerun from a step works on a one-image build; restart this "
                  "session from Previous builds instead.")
NO_SESSION = "This build has no session record to rerun."
FLEET = "A fleet run reruns from its own window (Previous builds → Restart)."


@dataclass(frozen=True)
class RerunPlan:
    """What a rerun from one stage does. ``from_step`` is "" for a --resume rerun."""
    from_step: str
    sentence: str


def plan(platform: str, step_id: str, step_label: str) -> RerunPlan:
    """The rerun a click on ``step_id``'s icon dispatches, and the sentence that says so."""
    late = LATE_STEPS.get(platform or "x86", ())
    if step_id in late:
        kept = late[: late.index(step_id)]
        before = ("the build system and everything before it" if not kept else
                  "the build system and what the earlier steps made")
        return RerunPlan(step_id, (
            f"Reruns “{step_label}” and the steps after it. {before[0].upper()}{before[1:]} "
            "are kept, not repeated, and the artifacts keep the earlier run's build stamp."))
    return RerunPlan("", (
        f"A build cannot restart in the middle at “{step_label}”, so this reruns it with "
        "--resume: the build system is kept (no new stage3), and every step from the "
        "spec install onward runs again."))


def strip_from_step(extra_flags: str) -> str:
    """``extra_flags`` without any ``--from-step STEP`` / ``--from-step=STEP``."""
    try:
        toks = shlex.split(extra_flags or "")
    except ValueError:
        return extra_flags or ""          # unparseable: leave it alone (the builder will say)
    out: list[str] = []
    skip = False
    for t in toks:
        if skip:
            skip = False
            continue
        if t == "--from-step":
            skip = True
            continue
        if t.startswith("--from-step="):
            continue
        out.append(t)
    return shlex.join(out)


def with_from_step(extra_flags: str, from_step: str) -> str:
    """``extra_flags`` with exactly the requested ``--from-step`` (none when "")."""
    base = strip_from_step(extra_flags)
    if not from_step:
        return base
    return f"{base} --from-step {shlex.quote(from_step)}".strip()


def refusal(rows: int, has_session: bool, kind: str) -> str:
    """Why this page cannot offer a rerun at all ("" when it can)."""
    if not has_session:
        return NO_SESSION
    if kind == "fleet":
        return FLEET
    if rows != 1:
        return ONE_IMAGE_ONLY
    return ""
