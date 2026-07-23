"""StageTracker — Qt-free, per-image nested-stage state derived from the honest phase table.

The GitHub-Actions-style nested build view (ProgressPage) needs, PER image, a list of
STAGES that advance running -> done/failed/skipped as the build crosses the ``==> `` phase
banners. This module owns exactly that headless bookkeeping so it can be unit-tested the
same way :mod:`.progress_parse` is (no Qt), and so the GUI's per-line path stays O(1).

It reuses the EXACT ordered phase table :class:`~.progress_parse.ProgressParser` already
drives (via :func:`~.progress_parse.platform_phases`), keyed by ``phase_index`` — so the
stages and the progress bar can never disagree. It invents no taxonomy of its own.

Honesty rules (mirror the parser + the #339 failure semantics):

* A stage is only ``done`` (green) once the parser has actually advanced PAST it.
* Phases the forward-only matcher stepped over (a conditional banner that never fired, or
  the pre-first-banner phases before the first real banner lands) become ``skipped`` —
  neutral, never green.
* On a nonzero exit the CURRENTLY-running stage is ``failed``; trailing unreached stages
  stay ``pending`` (the build died there — nothing downstream ran). On a clean exit the
  running stage is ``done`` and any trailing unreached stages are ``skipped`` (NOT
  fabricated done). On a cancel (exit code ``None``) the running stage is ``stopped``
  (neutral), trailing stages stay ``pending``.
* A build that dies before ANY banner has no running stage, so NO stage is marked failed
  — the caller reds the JOB itself and its drill-down is the raw log.
"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field

# Stage lifecycle states. "skipped"/"stopped" are neutral (never rendered green); only a
# stage the parser advanced PAST reaches "done".
PENDING = "pending"
RUNNING = "running"
DONE = "done"
FAILED = "failed"
SKIPPED = "skipped"
STOPPED = "stopped"

_STAGE_LOG_MAXLEN = 2000     # per-stage slice ring buffer (bounded -> no unbounded growth)


@dataclass
class Stage:
    """One phase-table row's live UI+log state (Qt-free)."""
    index: int
    label: str
    state: str = PENDING
    t_start: float | None = None
    t_end: float | None = None
    lines: deque = field(default_factory=lambda: deque(maxlen=_STAGE_LOG_MAXLEN))

    def elapsed(self, now: float | None = None) -> float | None:
        """Seconds this stage has been (or was) running, or None if it never started."""
        if self.t_start is None:
            return None
        end = self.t_end if self.t_end is not None else now
        if end is None:
            return None
        return max(end - self.t_start, 0.0)


@dataclass
class StageDelta:
    """Which stage indices changed state on a single feed()/finalize() — so the GUI only
    touches tree items on a real transition (rare), never per line."""
    started: list[int] = field(default_factory=list)
    finished: list[int] = field(default_factory=list)
    skipped: list[int] = field(default_factory=list)
    failed: list[int] = field(default_factory=list)
    stopped: list[int] = field(default_factory=list)

    def touched(self) -> list[int]:
        return self.started + self.finished + self.skipped + self.failed + self.stopped

    def any(self) -> bool:
        return bool(self.started or self.finished or self.skipped
                    or self.failed or self.stopped)


class StageTracker:
    """Feed each stdout line together with the parser's current ``phase_index``; the tracker
    closes/opens stages on a rise in ``phase_index`` and attributes the line to the stage
    that is running AFTER the transition (GH-Actions semantics: the ``==> Building kernel``
    banner is the first line of the Kernel stage). One tracker per image build."""

    def __init__(self, phases: list[dict]):
        self.stages: list[Stage] = [
            Stage(index=i, label=ph["label"]) for i, ph in enumerate(phases)]
        self.cur = -1            # index of the currently-running stage, -1 = none yet
        self.finalized = False

    def feed(self, line: str, phase_index: int, now: float) -> StageDelta:
        """Apply the phase_index transition (if any) FIRST, then append the line to the
        currently-running stage. Lines before the first banner (cur == -1) belong to NO
        stage — they live only in the caller's raw job buffer. O(1) on the common path
        (an int compare + a deque append)."""
        delta = StageDelta()
        if phase_index > self.cur and phase_index >= 0:
            # close the stage we're leaving
            if self.cur >= 0 and self.stages[self.cur].state == RUNNING:
                self.stages[self.cur].state = DONE
                self.stages[self.cur].t_end = now
                delta.finished.append(self.cur)
            # any stage the forward-only matcher stepped over is honestly skipped
            for j in range(self.cur + 1, phase_index):
                if self.stages[j].state == PENDING:
                    self.stages[j].state = SKIPPED
                    delta.skipped.append(j)
            # open the announced stage
            st = self.stages[phase_index]
            st.state = RUNNING
            st.t_start = now
            self.cur = phase_index
            delta.started.append(phase_index)
        if self.cur >= 0:
            self.stages[self.cur].lines.append(line)
        return delta

    def finalize(self, code: int | None, now: float) -> StageDelta:
        """Settle the terminal state. ``code == 0`` -> running stage done + trailing
        skipped; ``code is None`` (cancel) -> running stage stopped; nonzero -> running
        stage failed. Never fabricates a done/green stage the builder didn't complete."""
        delta = StageDelta()
        self.finalized = True
        if self.cur >= 0 and self.stages[self.cur].state == RUNNING:
            st = self.stages[self.cur]
            st.t_end = now
            if code == 0:
                st.state = DONE
                delta.finished.append(self.cur)
            elif code is None:
                st.state = STOPPED
                delta.stopped.append(self.cur)
            else:
                st.state = FAILED
                delta.failed.append(self.cur)
        if code == 0:
            for j in range(self.cur + 1, len(self.stages)):
                if self.stages[j].state == PENDING:
                    self.stages[j].state = SKIPPED
                    delta.skipped.append(j)
        return delta

    def failed_index(self) -> int | None:
        """The index of the stage that failed (for failure navigation), or None if the
        build died before any banner (no running stage to fail)."""
        if self.cur >= 0 and self.stages[self.cur].state == FAILED:
            return self.cur
        return None
