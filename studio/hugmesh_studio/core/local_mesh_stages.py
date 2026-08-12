"""Which phase table drives which LOCAL DOCKER MESH verb — Qt-free, table-backed.

The local-mesh page streams `make stack-*` output the same way ProgressPage streams a
builder, so it gets the SAME machinery: :class:`~.progress_parse.ProgressParser` for the
forward-only ``==> `` banner match and :class:`~.stage_tracker.StageTracker` for the
running/done/failed/skipped bookkeeping. Neither of those invents a phase table — the
caller hands one in — and a local bring-up is not an image build, so its tables live in
``progress-tables.json``'s ``tracks`` map (the go-live / cloud-deploy precedent), NOT in
``platforms``.

This module is the single place that says which track id belongs to which GUI verb, so
the page never carries the string ``"localmesh-up"`` in three handlers and a test never
has to guess. It is deliberately Qt-free (``core/`` rule): the mapping and the tables are
data, and the tests that pin the banners against the real Makefile/scripts must run with
no Qt binding at all.

WHY only three verbs have tables. A track exists only where the shell it drives actually
prints ``==> `` banners:

* ``up``    -> ``make stack-up`` and its prerequisites (stack-clone -> patch-stack-src ->
  stack-certs -> [stack-mastodon-env] -> compose build/up) plus the m2 self-heal `up()`
  may run first, and ``make stack-seed``.
* ``m2``    -> ``tests/stack/m2-bootstrap.sh`` (the cold-build prerequisite verb).
* ``clean`` -> ``make stack-clean``'s two banners.

``stack-down``, the readiness preflight and the JOIN-tab node verbs emit NO banners, so
they honestly get NO phase table: :func:`verb_phases` returns ``[]``, the tracker holds
zero stages, and the GUI shows the run as a single row whose drill-down is the raw log.
An empty table is the honest answer — never a fabricated one-stage ladder.

WHAT THE UP TABLE CANNOT SEE (stated here because a stage view that hides this would
lie): the studio's own milestones (``[creds] …``, ``[stack-up] ok``, ``[done] platform
up``) are emitted by :mod:`.local_mesh_bootstrap` WITHOUT a ``==> `` prefix, so they can
never match a phase — they land in whichever stage was running (or, before the first
banner, only in the run's raw log). And ``make stack-m2-check``'s self-heal can fire the
m2 banners LATE (after clone/certs, as a stack-up prerequisite); the matcher is
forward-only, so in that case the maven stage is honestly rendered ``skipped`` rather
than re-opened backwards.
"""
from __future__ import annotations

from .progress_parse import track_banner_sources, track_phases

#: GUI verb id -> ``tracks`` key in progress-tables.json.
VERB_TRACKS: dict[str, str] = {
    "up": "localmesh-up",
    "m2": "localmesh-m2",
    "clean": "localmesh-clean",
}

#: Every local-mesh track id, in verb order — what the drift probe iterates.
LOCALMESH_TRACKS: tuple[str, ...] = tuple(VERB_TRACKS.values())


def verb_track(verb: str) -> str:
    """The track id for a GUI verb, or ``""`` for a verb with no banners."""
    return VERB_TRACKS.get(verb, "")


def verb_phases(verb: str) -> list[dict]:
    """The ordered phase table for a GUI verb — ``[]`` when the verb publishes no
    banners (unknown verb included), which :func:`~.progress_parse.track_phases` already
    returns for an unknown track. A caller can pass the result straight to both
    ``ProgressParser(phases=…)`` and ``StageTracker(…)``."""
    return track_phases(verb_track(verb))


def verb_banner_sources(verb: str) -> list[str]:
    """The files whose ``==>`` echoes a verb's patterns pin (drift-probe input)."""
    return track_banner_sources(verb_track(verb))
