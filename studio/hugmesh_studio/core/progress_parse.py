"""Honest builder-progress parsing — banner phase table -> step-K-of-M estimate.

Qt-free and data-driven (``progress-tables.json``) so the admin-bff pod-log follower can
port the SAME tables + regexes for web progress parity (design 2.9 / spec 10). No FAKE
percent, ever: until a known ``==> `` phase banner is seen the estimate is INDETERMINATE
(``percent is None``); once a phase is reached the bar is
``(phase_index + intra_phase_fraction) / phase_count`` — a coarse but truthful lower bound
that never regresses. The portage ``>>> (Emerging|Installing) (N of M)`` counter (which
survives ``--quiet-build``) refines the fraction WITHIN the current phase; ``!!`` markers
or a nonzero exit mark failure.

Matching is forward-only (monotonic): each banner advances to the EARLIEST not-yet-passed
phase whose pattern matches, so conditional / SKIPPED banners never move the bar backwards
and a build that skips a phase simply steps over it.
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass

_TABLES_PATH = os.path.join(os.path.dirname(__file__), "progress-tables.json")

# ANSI strip is MANDATORY first (design 2.9) — banner colours are unconditional, so a
# banner line arrives wrapped in SGR escapes; strip them before any text match.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_BANNER_RE = re.compile(r"^==>\s*(.*)$")
_EMERGE_RE = re.compile(r">>> (?:Emerging|Installing) \((\d+) of (\d+)\)")
_FAILURE_RE = re.compile(r"^\s*!!")


def strip_ansi(line: str) -> str:
    return _ANSI_RE.sub("", line)


def _load_tables() -> dict:
    with open(_TABLES_PATH, encoding="utf-8") as fh:
        return json.load(fh)


_TABLES = _load_tables()


def platforms() -> list[str]:
    return list(_TABLES["platforms"])


def platform_phases(platform: str) -> list[dict]:
    """The ordered phase table for a platform (falls back to x86 for an unknown one so
    an unrecognised builder still gets coarse determinate progress rather than crashing)."""
    plats = _TABLES["platforms"]
    entry = plats.get(platform or "x86") or plats["x86"]
    return entry["phases"]


def pattern_count(platform: str) -> int:
    """Total number of match patterns across all phases — what the drift probe compares
    to the count of ``banner "..."`` call sites in the corresponding builder script."""
    return sum(len(ph["any"]) for ph in platform_phases(platform))


def declared_callsites(platform: str) -> int:
    """The ``banner_callsites`` count annotated in the table (kept equal to the real
    call-site count by the drift probe)."""
    return _TABLES["platforms"][platform or "x86"]["banner_callsites"]


@dataclass
class ProgressState:
    phase_index: int          # -1 = no known phase reached yet (indeterminate)
    phase_count: int          # M — total phases in the table
    phase_label: str          # human label of the current phase ("" before the first)
    fraction: float | None    # intra-phase emerge fraction 0..1, or None if unknown
    percent: int | None       # 0..100, or None = INDETERMINATE (honest: no phase yet)
    failed: bool
    done: bool


class ProgressParser:
    """Stateful, line-fed progress estimator for ONE image build. Feed each stdout line
    (raw, with ANSI) via :meth:`feed`; read the latest :class:`ProgressState` it returns
    (or call :meth:`state`). Call :meth:`finalize` with the process exit code to settle
    the terminal state (100% on success, failed on nonzero)."""

    def __init__(self, platform: str):
        self.platform = platform or "x86"
        self.phases = platform_phases(self.platform)
        self.phase_count = len(self.phases)
        self.phase_index = -1
        self._emerge_cur = 0
        self._emerge_tot = 0
        self.failed = False
        self.done = False

    def feed(self, raw_line: str) -> ProgressState:
        line = strip_ansi(raw_line)
        if _FAILURE_RE.search(line):
            self.failed = True
        m = _BANNER_RE.match(line.lstrip())
        if m:
            j = self._match_phase(m.group(1))
            if j is not None and j > self.phase_index:
                self.phase_index = j
                self._emerge_cur = 0          # fresh phase -> fresh intra-phase fraction
                self._emerge_tot = 0
        else:
            em = _EMERGE_RE.search(line)
            if em:
                self._emerge_cur = int(em.group(1))
                self._emerge_tot = int(em.group(2))
        return self.state()

    def _match_phase(self, banner_text: str) -> int | None:
        """Earliest not-yet-passed phase whose any-pattern is a substring of the banner —
        forward-only so the estimate is monotonic and skips conditional phases cleanly."""
        for j in range(self.phase_index + 1, self.phase_count):
            for pat in self.phases[j]["any"]:
                if pat in banner_text:
                    return j
        return None

    def _fraction(self) -> float | None:
        if self._emerge_tot > 0:
            return min(self._emerge_cur / self._emerge_tot, 1.0)
        return None

    def _percent(self, frac: float | None) -> int | None:
        if self.done:
            return 100
        if self.phase_index < 0:
            return None                       # no phase yet — honestly indeterminate
        base = self.phase_index + (frac or 0.0)
        return min(int(base / self.phase_count * 100), 99)   # never 100 until finalize()

    def state(self) -> ProgressState:
        frac = self._fraction()
        label = self.phases[self.phase_index]["label"] if self.phase_index >= 0 else ""
        return ProgressState(
            phase_index=self.phase_index, phase_count=self.phase_count,
            phase_label=label, fraction=frac, percent=self._percent(frac),
            failed=self.failed, done=self.done)

    def finalize(self, exit_code: int) -> ProgressState:
        if exit_code == 0:
            self.done = True
        else:
            self.failed = True
        return self.state()


def parse_lines(platform: str, lines, exit_code: int | None = None) -> ProgressState:
    """Convenience: run a whole line iterable through a fresh parser and return the final
    state (used by tests and any batch caller)."""
    p = ProgressParser(platform)
    for ln in lines:
        p.feed(ln)
    if exit_code is not None:
        p.finalize(exit_code)
    return p.state()
