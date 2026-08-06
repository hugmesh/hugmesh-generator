"""Platform-build UNIFORMITY gates for the canonical stage ladder + emerge-group taxonomy.

The uniformity pass gave every phase row a canonical stage ``id``, so the same work has the
same name and the same relative position on every platform, and a stage a board genuinely
lacks is declared in ``not_applicable`` WITH A REASON instead of vanishing silently. All of
that was documented in ``progress-tables.json:_meta`` — this module is what actually
ENFORCES it. Without these probes the whole scheme is a comment.

Four families here, in increasing order of how much they would have cost to find in the
field:

1. SHAPE — every platform ladder is a subsequence of ``_meta.canonical_stages`` (same ids,
   same labels, same relative order) and ``phases`` + ``not_applicable`` together cover the
   canonical ladder exactly once. A platform cannot quietly drop, reorder or rename a rung.
2. GROUPS — ``_meta.emerge_groups.order`` is the same five names as
   ``emerge_packages.EMERGE_GROUPS``, every platform accounts for all five as either
   emitted or not-applicable-with-a-reason, and the declared ``emitted`` set matches what
   that builder's source ACTUALLY greps out. Three-way: constant <-> table <-> source.
3. EXECUTION ORDER — the forward-only matcher's load-bearing assumption is that builders
   emit banners in table order. That is NOT the same as file order (a banner inside a shell
   function runs when the function is CALLED, and if/else arms are alternatives), so this
   probe models both and replays every call site. A table row parked at the wrong index
   would strand every rung before it — exactly the class of bug that made "Rebrand baked
   config" unreachable at index 0 before this pass.
4. COMPATIBILITY — the rename must not blank the bar of a build that was already running
   when the operator upgraded the Studio, nor of an archived log. ``compat`` holds the
   previous release's banner substrings; these probes prove the legacy vocabulary still
   drives a FULL ladder, prove ``compat`` is excluded from the drift probe's count so it
   can never be used to dodge it, and prove no live banner is parked in ``compat``.
"""
from __future__ import annotations

import json
import os
import re

import pytest

from hugmesh_studio.core import progress_parse as pp
from hugmesh_studio.core.emerge_packages import EMERGE_GROUPS, GROUP_BANNER_PREFIX

_GEN = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# The ten image builders, keyed by the platform id used in progress-tables.json.
BUILDERS = {
    "x86": "build-x86-host-stage4.sh",
    "rpi5": "build-rpi5-stage4.sh",
    "jetson": "build-jetson-stage4.sh",
    "frite": "build-frite-stage4.sh",
    "orangepi5": "build-orangepi5-stage4.sh",
    "orangepizero2": "build-orangepi-zero2-stage4.sh",
    "orangepizero2w": "build-orangepi-zero2w-stage4.sh",
    "orangepizero3": "build-orangepi-zero3-stage4.sh",
    "orangepi3-lts": "build-orangepi3-lts-stage4.sh",
    "orangepi4-lts": "build-orangepi4-lts-stage4.sh",
}
PLATFORMS = sorted(BUILDERS)

_CYAN, _BOLD, _RST = "\x1b[36m", "\x1b[1m", "\x1b[0m"


def _banner(text: str) -> str:
    return f"{_CYAN}{_BOLD}==> {text}{_RST}"


def _src(platform: str) -> list[str]:
    with open(os.path.join(_GEN, BUILDERS[platform]), encoding="utf-8",
              errors="replace") as fh:
        return fh.read().splitlines()


# ══ 1. SHAPE ════════════════════════════════════════════════════════════════════════
def test_canonical_ladder_ids_are_unique_and_labelled():
    stages = pp.canonical_stages()
    ids = [s["id"] for s in stages]
    assert len(ids) == len(set(ids)), f"duplicate canonical stage id: {ids}"
    assert all(s.get("label") for s in stages), "every canonical stage needs a label"


@pytest.mark.parametrize("platform", PLATFORMS)
def test_platform_ladder_is_a_subsequence_of_the_canonical_ladder(platform):
    """Same ids, same relative ORDER. A platform may omit rungs (declared below); it may
    never reorder them, because the ladder is what the operator compares side by side."""
    canon = [s["id"] for s in pp.canonical_stages()]
    mine = pp.stage_ids(platform)
    assert len(mine) == len(set(mine)), f"{platform}: a stage id appears twice: {mine}"
    it = iter(canon)
    assert all(sid in it for sid in mine), (
        f"{platform} ladder is not a subsequence of the canonical ladder.\n"
        f"  canonical: {canon}\n  {platform}: {mine}")


@pytest.mark.parametrize("platform", PLATFORMS)
def test_platform_labels_are_the_canonical_labels_verbatim(platform):
    """Platform-specific colour belongs in the BANNER text's parenthetical, never in the
    label — two builds side by side must show the same words for the same work."""
    want = pp.canonical_labels()
    for ph in pp.platform_phases(platform):
        assert ph["label"] == want[ph["id"]], (
            f"{platform}/{ph['id']}: label {ph['label']!r} != canonical {want[ph['id']]!r}")


@pytest.mark.parametrize("platform", PLATFORMS)
def test_every_canonical_stage_is_present_or_declared_absent_with_a_reason(platform):
    """The explicit-absence rule this whole pass exists to enforce: present + declared-
    absent must partition the canonical ladder, and an absence must carry a REASON."""
    canon = {s["id"] for s in pp.canonical_stages()}
    present = set(pp.stage_ids(platform))
    absent = pp.not_applicable(platform)
    assert present <= canon, f"{platform}: non-canonical stage id(s) {present - canon}"
    assert set(absent) <= canon, f"{platform}: not_applicable names non-canonical {set(absent) - canon}"
    overlap = present & set(absent)
    assert not overlap, f"{platform}: {overlap} is both present and declared not-applicable"
    missing = canon - present - set(absent)
    assert not missing, (
        f"{platform}: canonical stage(s) {sorted(missing)} are neither in `phases` nor "
        f"declared in `not_applicable` — that is exactly the silent difference the "
        f"uniformity pass forbids")
    for sid, reason in absent.items():
        assert isinstance(reason, str) and len(reason.strip()) >= 20, (
            f"{platform}/{sid}: not_applicable needs a real reason, got {reason!r}")


# ══ 2. GROUPS ═══════════════════════════════════════════════════════════════════════
def test_emerge_group_order_is_the_emerge_packages_constant():
    assert set(pp.emerge_group_order()) == set(EMERGE_GROUPS), (
        "progress-tables _meta.emerge_groups.order and emerge_packages.EMERGE_GROUPS "
        "must name the SAME five groups (the table additionally pins their order)")
    assert len(pp.emerge_group_order()) == len(EMERGE_GROUPS)


@pytest.mark.parametrize("platform", PLATFORMS)
def test_every_platform_accounts_for_all_five_emerge_groups(platform):
    order = pp.emerge_group_order()
    g = pp.emerge_groups(platform)
    emitted, absent = g["emitted"], g["not_applicable"]
    assert set(emitted) | set(absent) == set(order), (
        f"{platform}: groups {set(order) - set(emitted) - set(absent)} are neither "
        f"declared emitted nor declared not-applicable")
    assert not (set(emitted) & set(absent)), f"{platform}: a group is both emitted and absent"
    it = iter(order)
    assert all(x in it for x in emitted), (
        f"{platform}: emitted {emitted} is not in canonical order {order}")
    for grp, reason in absent.items():
        assert isinstance(reason, str) and len(reason.strip()) >= 20, (
            f"{platform}/{grp}: a group a platform does not emit needs a documented "
            f"reason, got {reason!r}")


@pytest.mark.parametrize("platform", PLATFORMS)
def test_declared_emitted_groups_match_the_builder_source(platform):
    """Three-way agreement: the table's `emitted` is re-derived from the builder itself,
    counting BOTH call-site shapes (host-side `banner`, and the bare `echo` x86 must use
    inside its chroot heredocs). tests/build-matrix/check.sh's EGB bucket pins the same
    sets from the shell side; this is the Python side of the same fact."""
    rx = re.compile(r'^\s*(?:banner|echo)\s+"(?:==> )?' + re.escape(
        GROUP_BANNER_PREFIX.replace("==> ", "")) + r'([a-z]+)"')
    found = {m.group(1) for m in (rx.match(l) for l in _src(platform)) if m}
    assert found == set(pp.emerge_groups(platform)["emitted"]), (
        f"{platform}: builder emits {sorted(found)} but the table declares "
        f"{sorted(pp.emerge_groups(platform)['emitted'])}")


# ── plan preview (the emerge_plan declaration; the wire-format pin itself lives in
# test_emerge_packages.py) ─────────────────────────────────────────────────────────
_PLAN_CALLSITE = re.compile(r'^\s*emerge_plan_emit\s+([a-z]+)\s')


@pytest.mark.parametrize("platform", PLATFORMS)
def test_every_emitted_group_is_planned_or_declared_not_planned(platform):
    """planned + not_planned must partition the platform's emitted groups, planned must
    follow canonical order, and a group deliberately not previewed needs a REAL reason —
    the same explicit-absence rule the stage ladder and the group taxonomy already obey."""
    emitted = set(pp.emerge_groups(platform)["emitted"])
    plan = pp.emerge_plan(platform)
    planned, not_planned = plan["planned"], plan["not_planned"]
    assert set(planned) | set(not_planned) == emitted, (
        f"{platform}: emitted group(s) {sorted(emitted - set(planned) - set(not_planned))} "
        f"are neither planned nor declared not_planned — that silence is exactly what the "
        f"declaration forbids")
    assert not (set(planned) & set(not_planned)), (
        f"{platform}: a group is both planned and not_planned")
    it = iter(pp.emerge_group_order())
    assert all(g in it for g in planned), (
        f"{platform}: planned {planned} is not in canonical group order")
    for grp, reason in not_planned.items():
        assert isinstance(reason, str) and len(reason.strip()) >= 20, (
            f"{platform}/{grp}: not_planned needs a real reason, got {reason!r}")


@pytest.mark.parametrize("platform", PLATFORMS)
def test_declared_planned_groups_match_the_builder_source(platform):
    """The table's `planned` set re-derived from the builder's own emerge_plan_emit call
    sites (the x86 no-op fallback definition has no group word, so it never counts).
    tests/build-matrix/check.sh's EPL bucket pins the same fact — plus the pretend pass's
    argument parity with the real merge — from the shell side; this is the Python side."""
    found = {m.group(1) for m in (_PLAN_CALLSITE.match(l) for l in _src(platform)) if m}
    assert found == set(pp.emerge_plan(platform)["planned"]), (
        f"{platform}: builder plans {sorted(found)} but the table declares "
        f"{sorted(pp.emerge_plan(platform)['planned'])}")


# ══ 3. EXECUTION ORDER ══════════════════════════════════════════════════════════════
_BANNER_CS = re.compile(r'^\s*banner\s+"(.*?)"')
_ECHO_CS = re.compile(r'^\s*echo "==> (.*?)"')
_FUNCDEF = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{\s*$')
_IF, _ELSE, _FI = re.compile(r'^\s*if\s'), re.compile(r'^\s*(else|elif)\b'), re.compile(r'^\s*fi\b')


def _events(lines: list[str]):
    """(kind, line, text) in EXECUTION order. Two corrections to file order, both real:
    a banner inside a top-level `name() { ... }` runs at the CALL site, and if/else arms
    are alternatives rather than a sequence."""
    fn_of: dict[int, str] = {}
    i = 0
    while i < len(lines):
        m = _FUNCDEF.match(lines[i])
        if m:
            j = i + 1
            while j < len(lines) and lines[j] != "}":
                j += 1
            for k in range(i + 1, j + 2):
                fn_of.setdefault(k, m.group(1))
            i = j + 1
            continue
        i += 1

    raw = []
    for n, line in enumerate(lines, 1):
        m = _BANNER_CS.match(line) or _ECHO_CS.match(line)
        if m:
            raw.append((n, m.group(1), fn_of.get(n)))

    call_at: dict[str, int] = {}
    for fn in {f for (_, _, f) in raw if f}:
        pat = re.compile(r'(^|[\s;&|(])' + re.escape(fn) + r'([\s;&|)]|$)')
        for n, line in enumerate(lines, 1):
            s = line.strip()
            if fn_of.get(n) == fn or s.startswith("#") or _FUNCDEF.match(s):
                continue
            if pat.search(line):
                call_at.setdefault(fn, n)
                break

    ev = []
    for n, line in enumerate(lines, 1):
        if fn_of.get(n):
            continue
        if _IF.match(line):
            ev.append(("if", n, ""))
        elif _ELSE.match(line):
            ev.append(("else", n, ""))
        elif _FI.match(line):
            ev.append(("fi", n, ""))
    for n, text, fn in raw:
        ev.append(("banner", call_at.get(fn, n) if fn else n, text))
    ev.sort(key=lambda t: (t[1], t[0] == "banner"))
    return ev, len(raw)


@pytest.mark.parametrize("platform", PLATFORMS)
def test_banner_execution_order_is_monotonic_over_the_phase_table(platform):
    """The forward-only matcher can only ever advance. If a table row sits EARLIER than
    the point its banner is really emitted, every rung before it becomes unreachable and
    the operator's bar jumps then stalls — silently. This replays the builder's own call
    sites against its own table and demands every rung be reachable in order."""
    phases = pp.platform_phases(platform)
    ev, _ = _events(_src(platform))
    cur, seen, problems = -1, set(), []
    stack: list[list[int]] = []
    for kind, ln, text in ev:
        if kind == "if":
            stack.append([cur, cur])
            continue
        if kind == "else":
            if stack:
                stack[-1][1] = max(stack[-1][1], cur)
                cur = stack[-1][0]
            continue
        if kind == "fi":
            if stack:
                _entry, mx = stack.pop()
                cur = max(mx, cur)
            continue
        hit = next((j for j in range(cur + 1, len(phases))
                    if any(p in text for p in pp.phase_patterns(phases[j]))), None)
        if hit is None:
            if cur >= 0 and any(p in text for p in pp.phase_patterns(phases[cur])):
                seen.add(cur)      # same-phase re-entry (e.g. a group banner): documented no-op
                continue
            back = [j for j in range(cur) if any(p in text for p in pp.phase_patterns(phases[j]))]
            problems.append(
                f":{ln} {text[:70]!r} -> "
                + (f"phase {back[0]} ({phases[back[0]]['id']}) already passed (at {cur})"
                   if back else "matches NO phase"))
        else:
            cur, _ = hit, seen.add(hit)
    assert not problems, f"{platform}: banner/table order disagreement:\n  " + "\n  ".join(problems)
    never = [phases[j]["id"] for j in range(len(phases)) if j not in seen]
    assert not never, f"{platform}: phase(s) {never} are unreachable from the builder's banners"


# ══ 4. COMPATIBILITY ════════════════════════════════════════════════════════════════
@pytest.mark.parametrize("platform", PLATFORMS)
def test_compat_patterns_are_truly_legacy(platform):
    """Parking a LIVE banner in `compat` would dodge the drift probe (which counts `any`
    only), so `compat` must never match a banner the builder still emits. Named verbatim
    in progress-tables.json:_meta.compat_policy."""
    live = []
    for line in _src(platform):
        m = _BANNER_CS.match(line) or _ECHO_CS.match(line)
        if m:
            live.append(m.group(1))
    for ph in pp.platform_phases(platform):
        for pat in ph.get("compat", ()):
            hits = [t for t in live if pat in t]
            assert not hits, (
                f"{platform}/{ph['id']}: compat pattern {pat!r} still matches a LIVE "
                f"banner {hits!r} — move it to `any` (compat is excluded from the drift "
                f"probe's count, so this would be a hole in the gate)")


@pytest.mark.parametrize("platform", PLATFORMS)
def test_pattern_count_excludes_compat(platform):
    """pattern_count() feeds the 1:1 call-site drift probe, so it must count `any` only."""
    phases = pp.platform_phases(platform)
    n_any = sum(len(ph["any"]) for ph in phases)
    n_compat = sum(len(ph.get("compat", ())) for ph in phases)
    assert pp.pattern_count(platform) == n_any
    assert pp.phase_patterns(phases[0]) == list(phases[0]["any"]) + list(
        phases[0].get("compat", ()))
    if n_compat:
        assert pp.pattern_count(platform) < n_any + n_compat


@pytest.mark.parametrize("platform", PLATFORMS)
def test_legacy_banner_vocabulary_still_drives_a_full_ladder(platform):
    """THE REGRESSION THIS PASS COULD HAVE SHIPPED. A build already running when the
    operator upgrades the Studio keeps emitting the OLD banners; an archived log replays
    them too. Reconstruct that old stream — the previous release's wording wherever a rung
    has one (`compat`), the current wording where the rename did not touch it — and demand
    it still reaches every rung, in order. A rename that blanks a running build's bar is a
    regression, not an improvement."""
    phases = pp.platform_phases(platform)
    legacy = [(ph.get("compat") or ph["any"])[0] for ph in phases]
    p = pp.ProgressParser(platform)
    reached = []
    for text in legacy:
        st = p.feed(_banner(text))
        reached.append(st.phase_index)
    assert reached == list(range(len(phases))), (
        f"{platform}: replaying the legacy banner vocabulary walked {reached}, expected "
        f"every rung 0..{len(phases) - 1}. A pre-upgrade build's bar would freeze.")
    assert p.state().phase_index == len(phases) - 1


@pytest.mark.parametrize("platform", PLATFORMS)
def test_current_banner_vocabulary_drives_a_full_ladder(platform):
    """The mirror of the legacy probe: the CURRENT wording must reach every rung too."""
    phases = pp.platform_phases(platform)
    p = pp.ProgressParser(platform)
    reached = [p.feed(_banner(ph["any"][0])).phase_index for ph in phases]
    assert reached == list(range(len(phases))), f"{platform}: current vocabulary walked {reached}"


# ── replay of the REAL archived builder logs ────────────────────────────────────────
# Defaults to this checkout's own artifact tree. A worktree has no out/, and the operator's
# real archive lives in their primary checkout, so HUGMESH_ARCHIVED_SESSIONS points the
# probe at a read-only session tree elsewhere. Nothing is ever written there.
_SESSIONS = os.environ.get("HUGMESH_ARCHIVED_SESSIONS") or os.path.join(_GEN, "out", "sessions")
# NB: [\w-] because two platform ids carry a hyphen (orangepi3-lts / orangepi4-lts) —
# plain \w* would truncate their log suffix at "orangepi3" and silently drop the log.
_LOG_RE = re.compile(r"^build-.+\.(x86|rpi5|jetson|frite|orangepi[\w-]*)\.log$")


def _archived_logs() -> list[tuple[str, str]]:
    out = []
    if not os.path.isdir(_SESSIONS):
        return out
    for d in sorted(os.listdir(_SESSIONS)):
        dd = os.path.join(_SESSIONS, d)
        if not os.path.isdir(dd):
            continue
        try:
            names = sorted(os.listdir(dd))
        except OSError:
            continue
        for f in names:
            m = _LOG_RE.match(f)
            if m and m.group(1) in BUILDERS:
                out.append((os.path.join(dd, f), m.group(1)))
    return out


@pytest.mark.parametrize("platform", PLATFORMS)
def test_archived_real_logs_still_advance_the_bar(platform):
    """Ground truth. These are the operator's OWN builds, written by the PREVIOUS release
    of the builders, and they must still drive a determinate bar under the new table.
    Streaming and banner-filtered on purpose — the archived x86 logs run to hundreds of MB.
    Parametrized over ALL platforms so a future archived log of any board is replayed the
    day it appears; today only x86/rpi5/jetson have archived sessions, the rest SKIP
    (never silently pass) — same as when the artifact tree is absent entirely, e.g. in CI."""
    logs = [(p, pl) for (p, pl) in _archived_logs() if pl == platform]
    if not logs:
        pytest.skip(f"no archived {platform} log under out/sessions")
    for path, _ in logs:
        parser = pp.ProgressParser(platform)
        advanced = 0
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "==>" not in line:
                    continue
                before = parser.phase_index
                if parser.feed(line.rstrip("\n")).phase_index != before:
                    advanced += 1
        assert advanced > 0 and parser.phase_index >= 0, (
            f"{os.path.basename(path)}: the bar never left indeterminate under the new "
            f"table — the rename regressed an archived {platform} log")
