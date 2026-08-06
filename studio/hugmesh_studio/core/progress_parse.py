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

GENERALIZATION (2026-07): the table's ``platforms`` map is the image-BUILD axis (keyed by
build platform). Non-image-build tracks that stream a subprocess line-by-line the same way
(the go-live wizard's ``plan``, the cloud-deploy wizard's ``plan``/``apply``) are NOT builds
and don't have a "platform" — they live in the table's sibling ``tracks`` map instead
(:func:`track_phases`), keyed by track id and optionally nested by provider (a cloud-deploy
provider's emitted ``apply.sh`` differs a lot between aws-ec2/azure-image/openshift-cnv, the
same way an image build differs between x86/rpi5). :class:`ProgressParser` accepts either an
image ``platform`` (unchanged contract) or an explicit ``phases`` table (the track path) —
the SAME ``==> `` banner regex and forward-only matching drive both, exactly the reuse this
module's docstring always intended.

UNIFORMITY (2026-07): every phase row now carries a CANONICAL stage ``id`` from
``_meta.canonical_stages`` — the same work has the same id, the same label and the same
relative position on every platform, and a canonical stage a platform does not have is
declared with a REASON in that platform's ``not_applicable`` map (:func:`not_applicable`)
instead of being silently absent. Renaming builder banners would ordinarily blank the bar
of a build that was already running when the operator upgraded, so each row may also carry
a ``compat`` list of banner substrings an EARLIER release emitted: the matcher accepts
``any`` + ``compat`` identically, while :func:`pattern_count` (the drift probe's input)
counts ``any`` ONLY — so ``compat`` can never be used to dodge the probe. See
``_meta.compat_policy``.
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
    """Total number of CURRENT match patterns across all phases — what the drift probe
    compares to the count of ``banner "..."`` call sites in the corresponding builder
    script. Deliberately counts ``any`` ONLY: the legacy ``compat`` patterns describe
    banners no builder emits any more, so counting them would break the 1:1 call-site
    invariant and turn ``compat`` into a hole in the drift probe."""
    return sum(len(ph["any"]) for ph in platform_phases(platform))


def phase_patterns(phase: dict) -> list[str]:
    """Every substring that matches this phase: the CURRENT banners (``any``) plus the
    transitional legacy ones (``compat``). This — not ``any`` alone — is what the matcher
    uses, so an archived log and a build that started before a Studio upgrade both keep
    advancing the bar. See ``_meta.compat_policy``."""
    return list(phase["any"]) + list(phase.get("compat", ()))


# ── canonical stage ladder ───────────────────────────────────────────────────────────
def canonical_stages() -> list[dict]:
    """The ONE ordered ``[{id, label}]`` build ladder every platform table is a
    subsequence of."""
    return list(_TABLES["_meta"]["canonical_stages"])


def canonical_labels() -> dict[str, str]:
    return {s["id"]: s["label"] for s in canonical_stages()}


def stage_ids(platform: str) -> list[str]:
    """The canonical stage ids this platform's ladder actually contains, in order."""
    return [ph["id"] for ph in platform_phases(platform)]


def not_applicable(platform: str) -> dict[str, str]:
    """``{canonical stage id: reason}`` for every canonical stage this platform does NOT
    have. Union with :func:`stage_ids` is the whole canonical ladder — that is the
    explicit-absence rule: a rung a board genuinely lacks is declared with its reason so
    the GUI can render it greyed, never silently dropped."""
    plats = _TABLES["platforms"]
    entry = plats.get(platform or "x86") or plats["x86"]
    return dict(entry.get("not_applicable", {}))


# ── canonical emerge-group taxonomy ──────────────────────────────────────────────────
def emerge_group_order() -> list[str]:
    """The five emerge groups in canonical emission order. Same names as
    ``emerge_packages.EMERGE_GROUPS`` (asserted in the tests); this pins the ORDER."""
    return list(_TABLES["_meta"]["emerge_groups"]["order"])


def emerge_groups(platform: str) -> dict:
    """``{"emitted": [...], "not_applicable": {group: reason}}`` for one platform. The two
    together always cover all five canonical groups — a group a platform does not emit is
    declared with a reason, never silently missing."""
    plats = _TABLES["platforms"]
    entry = plats.get(platform or "x86") or plats["x86"]
    g = entry.get("emerge_groups", {})
    return {"emitted": list(g.get("emitted", ())),
            "not_applicable": dict(g.get("not_applicable", {}))}


def emerge_plan(platform: str) -> dict:
    """``{"planned": [...], "not_planned": {group: reason}}`` for one platform — which of
    its emitted emerge groups get a read-only ``--pretend`` plan preview (the
    ``emerge_packages.PLAN_BANNER_PREFIX`` wire) and why the rest deliberately get none.
    ``planned`` + ``not_planned`` always partition ``emerge_groups()["emitted"]`` — a
    group is previewed, or its absence is declared with a reason, never silent."""
    plats = _TABLES["platforms"]
    entry = plats.get(platform or "x86") or plats["x86"]
    g = entry.get("emerge_plan", {})
    return {"planned": list(g.get("planned", ())),
            "not_planned": dict(g.get("not_planned", {}))}


def declared_callsites(platform: str) -> int:
    """The ``banner_callsites`` count annotated in the table (kept equal to the real
    call-site count by the drift probe)."""
    return _TABLES["platforms"][platform or "x86"]["banner_callsites"]


# ── non-image-build TRACKS (go-live plan, cloud-deploy plan/apply, …) ─────────────────
# Sibling of the platforms map above: same table shape (``banner_callsites`` + ``phases``),
# just not keyed by build platform. A track entry is either FLAT (one ``phases`` list used
# for every provider — go-live/cloud-deploy ``plan``, which render quickly regardless of
# provider) or nested under ``providers`` (cloud-deploy ``apply``, whose emitted apply.sh
# genuinely differs per provider — the aws-ec2/azure-image/openshift-cnv split).
def tracks() -> list[str]:
    return list(_TABLES.get("tracks", {}))


def _track_entry(track: str, provider: str = "") -> dict | None:
    entry = _TABLES.get("tracks", {}).get(track)
    if entry is None:
        return None
    if "providers" in entry:
        return entry["providers"].get(provider or "")
    return entry


def track_phases(track: str, provider: str = "") -> list[dict]:
    """The ordered phase table for a TRACK (optionally narrowed to ``provider`` for a
    track nested by provider, e.g. ``clouddeploy-apply``). Unknown track/provider ->
    ``[]`` — honestly no known phases, so a fed line never matches anything and the
    caller's :class:`ProgressParser` stays indeterminate throughout (never a crash, never
    a fabricated phase, mirroring platform_phases' unknown-platform fallback in spirit —
    except here there is no single sane default to fall back to across unrelated tracks)."""
    entry = _track_entry(track, provider)
    return list(entry["phases"]) if entry else []


def track_pattern_count(track: str, provider: str = "") -> int:
    """Total match patterns for one track/provider — the track analogue of
    :func:`pattern_count`, for a drift probe pinning banner call-sites in the driver
    script / provider emit template against the table."""
    return sum(len(ph["any"]) for ph in track_phases(track, provider))


def track_declared_callsites(track: str, provider: str = "") -> int:
    """The ``banner_callsites`` annotation for one track/provider."""
    entry = _track_entry(track, provider)
    return entry["banner_callsites"] if entry else 0


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

    def __init__(self, platform: str | None = None, *, phases: list[dict] | None = None):
        """``platform`` (the original, unchanged contract) looks up an image-BUILD
        table, falling back to x86 for an unknown platform. Pass ``phases=`` instead
        (a track's phase list, e.g. ``track_phases("golive-plan")``) to drive the exact
        same forward-only banner matching over a non-build track — the two are mutually
        exclusive; ``phases=`` wins if both are given."""
        if phases is not None:
            self.platform = platform or ""
            self.phases = phases
        else:
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
        """Earliest not-yet-passed phase whose pattern is a substring of the banner —
        forward-only so the estimate is monotonic and skips conditional phases cleanly.
        Both the CURRENT banners and the transitional ``compat`` ones match (see
        :func:`phase_patterns`), so an archived log — and a build that was already running
        when the operator upgraded the Studio mid-build — still advance the bar."""
        for j in range(self.phase_index + 1, self.phase_count):
            for pat in phase_patterns(self.phases[j]):
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
