"""The e2e suite as a CATALOGUE the Studio can render as a tree — parsed out of the
suite itself, never restated here.

WHY THIS EXISTS. The Studio's e2e surface was one "Run e2e suite" button: it either
went green or it went red, and an operator who wanted to know WHICH feature broke, or
WHO the failing persona was, or what the run actually looked like, had nothing to
click. The replacement is a feature TREE (one node per spec file, one leaf per test)
with the persona roster beside it and the screenshots a run produced underneath. This
module is that tree's MODEL. It is Qt-free by contract — no widget, no signal, no
import of hugmesh_studio.gui — so it can be tested in the plain-python CI lane and so
a future non-Qt surface (a report page, a CLI) can reuse it.

PARSE, NEVER RESTATE — the same discipline as core/seeded_credentials.py, for the same
reason. There are 221 specs across 33 files today. A hardcoded copy of that list would
be wrong the first time someone adds a spec, and a tree that silently omits a spec is
worse than the button it replaces: the button at least ran the whole suite. So:

  * the SPEC LIST comes from shelling out to Playwright's own
    ``npx playwright test -c playwright.config.ts --list --reporter=json`` in
    tests/e2e. VERIFIED 2026-08-26 on this box: that command works OFFLINE with the
    whole stack DOWN, exits 0 in ~0.3s, and enumerates 221 specs. It needs only
    tests/e2e/node_modules; it launches no browser and reaches no network.
  * the RESULTS come from the last run's report.json + summary.json under
    tests/e2e/test-results (see :func:`find_last_run`).
  * the PERSONAS come from core.seeded_credentials.load_roster VERBATIM. That parser
    already reads all three shell sources — including the 15 personas
    tests/e2e/specs/rbac-roles.ts omits — and a second parser here would be a second
    thing to drift.
  * the SERVICE CATALOGUE comes from core.local_services.LOCAL_SERVICES, the module
    that already owns "which services this local mesh can run".

WHAT --list DOES NOT TELL YOU, and the trap that follows. In ``--list`` output EVERY
test carries ``"status": "skipped"`` and the run stats read
``{expected: 0, skipped: 221}``. That is Playwright saying "not run", not "this test
skips". Reading it as a status would paint the whole tree grey with 221 skips and no
reasons — precisely the failure mode this module exists to prevent. So the list parse
records :data:`STATUS_NOT_RUN` and the run parse is the ONLY thing that may set a real
status.

THE THREE THINGS THAT MUST BE FIRST-CLASS DATA, not footnotes. Each of these is a way
the tree could look healthier than the suite is, and a tree that flatters the suite is
worse than a button that doesn't.

  1. SERVICES WITH ZERO COVERAGE (:func:`service_coverage`). A tree node with a green
     Run button that runs nothing is a lie. Measured 2026-08-26 against the specs in
     this checkout, NINE of the 16 catalogued local services have no spec that names
     them under any spelling: wiki, owncast, tube, character-studio (the four the
     operator asked about) plus tor, anubis, edge-ai-tts, media-poisoner and
     egress-vpn. All nine are reported as UNCOVERED with a named reason. The set is
     DERIVED, not listed: this paragraph is a measurement, and the module reports
     whatever it finds today. The five that ARE covered are tuwunel (20 files),
     akkoma (20), games (11), phpbb (2) and character-forge (1); argocd and
     workloadConsole are reported UNREACHABLE rather than uncovered, because they
     are Kubernetes-lane services this suite structurally cannot drive.
  2. SKIP REASONS (:func:`skip_reason_of`). In the run of 2026-08-22 (studio-20260822-
     193645) 62 of 259 results were skipped. 48 of those DO carry a machine-readable
     reason — Playwright records the ``test.skip(cond, 'why')`` description as a
     ``skip`` annotation on the result — and 14 do NOT. A grey row that cannot explain
     itself must SAY SO: an unexplained skip gets :data:`UNKNOWN_SKIP_REASON`, never an
     empty string, because an empty string renders as a blank cell and a blank cell
     reads as "fine".
  3. PERSONAS DELIBERATELY LEFT UN-ONBOARDED (:func:`gated_personas`). e2e-pending,
     rbac-pending-gmail-com and e2e-banned are gated ON PURPOSE — their gated state is
     the thing specs 17/28/29 assert. A roster that renders them as broken accounts
     invites someone to "fix" them and quietly turn three specs vacuous. The list is
     PARSED from seed-e2e.sh's ``SEED_REGISTRATION_SKIP`` default, together with that
     script's second, SHAPE-based rule (any ``*@*`` handle is never onboarded), so
     both mechanisms are modelled rather than one being restated.

SCREENSHOTS: MODEL WHAT EXISTS, PROMISE NOTHING MORE (:func:`index_screenshots`).
Today there is no per-step screenshot data and this module does not pretend otherwise.
There are exactly two real sources:

  * tests/e2e/screenshots/ — 38 flat, GIT-TRACKED PNGs written by helpers.ts ``shot()``
    with a caller-chosen name and OVERWRITTEN IN PLACE every run. Nothing in the file
    ties a shot to a test, a run or a persona: helpers.ts even keeps a ``personaOf()``
    WeakMap and does not put it in the name. The ONLY link that exists is the leading
    ``NN-`` number matching the ``NN-*.spec.ts`` filename, so that is the ONLY link
    claimed — :data:`LINK_FILENAME_PREFIX`, with ``persona`` and ``step`` left EMPTY
    and ``from_last_run`` False, because a tracked file that predates the run cannot
    honestly be labelled as the run's output.
  * per-test ``attachments`` in report.json — genuinely per-test
    (:data:`LINK_TEST`), but Playwright is configured ``screenshot: 'only-on-failure'``
    so they exist only for failures, and they live under the gitignored per-run
    test-results/ tree.

THE SEAM FOR THE GHERKIN TRACK. A concurrent track is adding playwright-bdd .feature
files, which will give each step its own name and (eventually) its own shot.
:class:`Screenshot` therefore already carries ``step`` and ``persona`` fields that are
EMPTY TODAY and a ``linkage`` field naming how the link was made, so per-step data
arrives as a better ``linkage`` value on the same shape rather than a new one. For the
same reason :class:`E2ETest` keeps ``kind`` (:data:`KIND_SPEC` today,
:data:`KIND_SCENARIO` when a .feature-generated test appears) and the parser reads
Playwright's JSON — which playwright-bdd also emits, since it generates ordinary
Playwright specs — rather than the .ts source.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field

from . import local_services
from .seeded_credentials import Roster, load_roster

# ── where everything lives, relative to a generator checkout ─────────────────────
E2E_DIR = os.path.join("tests", "e2e")
SPECS_DIR = os.path.join(E2E_DIR, "specs")
SHOTS_DIR = os.path.join(E2E_DIR, "screenshots")
RESULTS_DIR = os.path.join(E2E_DIR, "test-results")
PLAYWRIGHT_CONFIG = "playwright.config.ts"

# The enumeration command, as a tuple so no shell ever sees it. `-c` is explicit
# because the Studio may run this from a cwd Playwright would not auto-discover the
# config from, and `--reporter=json` OVERRIDES the config's reporter list — which
# matters: the config's default list includes the custom hugmesh reporter, which
# WRITES summary.json. Enumerating must never overwrite the last run's results.
LIST_ARGV: tuple[str, ...] = (
    "npx", "playwright", "test", "-c", PLAYWRIGHT_CONFIG, "--list", "--reporter=json")
LIST_TIMEOUT_SEC = 180

# Statuses. The first three are Playwright's own; the fourth is OURS and is the whole
# point of the list/run split (see the module docstring): `--list` reports every test
# as "skipped" meaning NOT RUN, and rendering that as a skip would grey out the tree.
STATUS_PASSED = "passed"
STATUS_FAILED = "failed"
STATUS_SKIPPED = "skipped"
STATUS_NOT_RUN = "not-run"

# What a skipped test says when nothing said why. NEVER "" — a blank cell reads as
# "fine", and 14 of the 62 skips in the 2026-08-22 run had no reason to show.
UNKNOWN_SKIP_REASON = "unknown — this test skipped without a machine-readable reason"

# How a screenshot was tied to the thing it sits under. Ordered weakest-last so a
# surface can render the weak ones differently instead of implying they are equal.
LINK_TEST = "test-attachment"        # Playwright attached it to THIS test result.
LINK_FILENAME_PREFIX = "filename-prefix"  # only the leading NN- matched the spec file.
LINK_NONE = "unlinked"               # a shot whose NN- matches no spec file at all.

# What kind of node a leaf is. KIND_SCENARIO is unused today and deliberately so:
# it is the seam the playwright-bdd track lands on.
KIND_SPEC = "spec"
KIND_SCENARIO = "scenario"

# Personas the seeder deliberately never completes, and the shape rule that gates a
# second, larger group. Parsed from seed-e2e.sh rather than copied: a stale copy here
# would either miss a newly-gated persona or, worse, mark a live one "gated on
# purpose" — and "gated on purpose" is a label that tells the next reader to leave a
# broken account alone.
GATED_SCRIPT = os.path.join("tests", "stack", "seed-e2e.sh")
_GATED_RE = re.compile(
    r'^\s*SEED_REGISTRATION_SKIP="\$\{SEED_REGISTRATION_SKIP:-(?P<v>[^}]*)\}"',
    re.MULTILINE)
GATED_NAMED_REASON = (
    "left un-onboarded ON PURPOSE (seed-e2e.sh SEED_REGISTRATION_SKIP) — its gated "
    "state is what specs 17/28/29 assert. Completing its registration would make "
    "those specs pass vacuously.")
GATED_EMAIL_REASON = (
    "left un-onboarded ON PURPOSE (seed-e2e.sh onboard_persona() skips every `*@*` "
    "handle) — these are the invite-flow fixtures the registration specs drive "
    "through the UI themselves.")

# `@role:` / `@layer:` in a test title. MIRRORS specs/report-tags.ts parseTags(),
# including its LAST-occurrence rule and its 'unknown' fallback: the tree and the
# reporter's per-role pivot must bucket a test identically or the two disagree in
# front of the operator.
_ROLE_TAG_RE = re.compile(r"@role:([A-Za-z0-9_-]+)")
_LAYER_TAG_RE = re.compile(r"@layer:([A-Za-z0-9_-]+)")
UNKNOWN_TAG = "unknown"

# A leading `NN-` on a spec filename or a screenshot name. The only thing that ties
# tests/e2e/screenshots/04-user-2-bob.png to specs/04-five-users.spec.ts.
_NUMBER_RE = re.compile(r"^(\d+)[-_]")

# TypeScript comments, stripped before any token search over spec source. HOUSE RULE,
# and it bites here specifically: `phpbb` appears in this suite ONLY inside comments,
# so a raw grep would report the forum as covered by specs that never touch it.
_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
_LINE_COMMENT_RE = re.compile(r"(?m)^[ \t]*//.*$")


# ── screenshots ─────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Screenshot:
    """One image the tree can show, and an HONEST account of how it got there."""
    path: str
    name: str
    #: LINK_TEST / LINK_FILENAME_PREFIX / LINK_NONE — how this shot was tied to the
    #: node it renders under. A surface that treats all three as equal is claiming a
    #: precision the repo does not have.
    linkage: str
    #: True only for a shot the LAST RUN produced. The tracked screenshots/ PNGs are
    #: overwritten in place, so on disk they are indistinguishable from a shot taken
    #: three runs ago; calling them this run's output would be a guess.
    from_last_run: bool = False
    #: EMPTY TODAY, both of them. helpers.ts shot() takes a caller-chosen name and
    #: records neither the step nor the persona (it has personaOf() and does not use
    #: it). These fields are the seam the Gherkin track fills; nothing may infer them.
    step: str = ""
    persona: str = ""

    @property
    def linked_to_a_test(self) -> bool:
        return self.linkage == LINK_TEST


def _spec_number(name: str) -> str:
    """The leading ``NN`` of ``04-five-users.spec.ts`` / ``04-user-2-bob.png``."""
    m = _NUMBER_RE.match(os.path.basename(name))
    return m.group(1) if m else ""


def index_screenshots(generator_dir: str) -> dict[str, tuple[Screenshot, ...]]:
    """The FLAT, git-tracked tests/e2e/screenshots/ tree, bucketed by spec number.

    Returns ``{"04": (Screenshot, ...), ...}`` plus a ``""`` bucket for shots whose
    name carries no number — those are :data:`LINK_NONE` and must still be shown
    somewhere, because a shot the tree drops is a shot nobody looks at again.

    Every entry here is :data:`LINK_FILENAME_PREFIX` at best: the directory is
    overwritten in place each run and nothing in it names a test, a run or a persona.
    """
    out: dict[str, list[Screenshot]] = {}
    shots_dir = os.path.join(generator_dir, SHOTS_DIR)
    try:
        names = sorted(os.listdir(shots_dir))
    except OSError:
        return {}
    for fn in names:
        if not fn.lower().endswith(".png"):
            continue
        num = _spec_number(fn)
        out.setdefault(num, []).append(Screenshot(
            path=os.path.join(shots_dir, fn),
            name=os.path.splitext(fn)[0],
            linkage=LINK_FILENAME_PREFIX if num else LINK_NONE,
        ))
    return {k: tuple(v) for k, v in out.items()}


def _attachment_shots(result: dict) -> list[Screenshot]:
    """Image attachments Playwright tied to THIS test result — the only per-test
    screenshot link that exists today. `screenshot: 'only-on-failure'` in
    playwright.config.ts means these appear for failures only, so their ABSENCE says
    nothing about a passing test."""
    shots: list[Screenshot] = []
    for att in result.get("attachments") or []:
        if not str(att.get("contentType") or "").startswith("image/"):
            continue
        path = att.get("path") or ""
        shots.append(Screenshot(
            path=path,
            name=str(att.get("name") or os.path.basename(path)),
            linkage=LINK_TEST,
            from_last_run=True,
        ))
    return shots


# ── tests + features (the tree itself) ──────────────────────────────────────────

@dataclass(frozen=True)
class E2ETest:
    """One leaf: a single Playwright ``test()``, with the last run's verdict merged in."""
    spec_file: str
    title: str
    #: The full describe-path, outermost first, ENDING in ``title``. This is what the
    #: reporter tags against, so role/layer here match the reporter's pivot exactly.
    title_path: tuple[str, ...]
    id: str = ""
    line: int = 0
    role: str = UNKNOWN_TAG
    layer: str = UNKNOWN_TAG
    kind: str = KIND_SPEC
    status: str = STATUS_NOT_RUN
    #: Populated for STATUS_SKIPPED only, and NEVER empty when it is populated —
    #: :data:`UNKNOWN_SKIP_REASON` stands in when the suite gave no reason.
    skip_reason: str = ""
    #: False when :attr:`skip_reason` is the stand-in. The distinction is the point:
    #: "skipped because LIVE_GATEWAY is unset" and "skipped, nobody knows why" are
    #: different facts and a grey row must not blur them.
    skip_reason_known: bool = False
    duration_ms: int = 0
    screenshots: tuple[Screenshot, ...] = ()

    @property
    def ran(self) -> bool:
        return self.status != STATUS_NOT_RUN

    @property
    def status_display(self) -> str:
        if self.status == STATUS_NOT_RUN:
            return "not run"
        if self.status == STATUS_SKIPPED:
            return f"skipped — {self.skip_reason or UNKNOWN_SKIP_REASON}"
        return self.status


@dataclass(frozen=True)
class Feature:
    """One tree node: a spec FILE and its tests."""
    file: str
    #: The ``NN`` prefix, or "" — the only handle the screenshots have on this file.
    number: str
    tests: tuple[E2ETest, ...]
    #: The flat narrative shots whose filename number matches :attr:`number`.
    screenshots: tuple[Screenshot, ...] = ()

    def counts(self) -> dict[str, int]:
        out = {STATUS_PASSED: 0, STATUS_FAILED: 0, STATUS_SKIPPED: 0, STATUS_NOT_RUN: 0}
        for t in self.tests:
            out[t.status] = out.get(t.status, 0) + 1
        return out

    @property
    def unexplained_skips(self) -> int:
        """Skipped tests this node cannot explain. A tree that shows a skip count and
        not THIS number lets 14 mystery greys hide inside 62 explained ones."""
        return sum(1 for t in self.tests
                   if t.status == STATUS_SKIPPED and not t.skip_reason_known)


def parse_tags(title_path: Sequence[str]) -> tuple[str, str]:
    """``(role, layer)`` for a test — a MIRROR of specs/report-tags.ts parseTags():
    last occurrence wins, missing tag becomes 'unknown' rather than being dropped."""
    joined = " ".join(title_path)
    roles = _ROLE_TAG_RE.findall(joined)
    layers = _LAYER_TAG_RE.findall(joined)
    return (roles[-1] if roles else UNKNOWN_TAG,
            layers[-1] if layers else UNKNOWN_TAG)


def skip_reason_of(test_node: dict, result: dict | None) -> tuple[str, bool]:
    """``(reason, is_known)`` for a skipped test, from Playwright's annotations.

    ``test.skip(cond, 'why')`` / ``test.fixme(...)`` land as an annotation of type
    ``skip``/``fixme`` carrying the text as ``description`` — on the RESULT when the
    run recorded one, and statically on the TEST node (which is why ``--list`` alone
    already knows 52 skip + 6 fixme reasons, with no run at all).

    An annotation with no description is NOT a reason: it is the bare ``test.skip()``
    form, and treating its empty string as an explanation is exactly how a mystery
    skip renders as a confident blank.
    """
    for node in (result, test_node):
        for ann in (node or {}).get("annotations") or []:
            if ann.get("type") not in ("skip", "fixme"):
                continue
            desc = str(ann.get("description") or "").strip()
            if desc:
                return desc, True
    return UNKNOWN_SKIP_REASON, False


def _walk_suites(suite: dict, ancestors: tuple[str, ...]):
    """Yield ``(title_path_prefix, spec)`` for every spec in a Playwright suite tree.

    Playwright nests: the outermost suite's title is the FILE, inner suites are
    describe() blocks. A flat read of ``suites[i].specs`` misses every describe'd
    test — which in this suite is most of them (33 files, 221 specs).
    """
    for spec in suite.get("specs") or []:
        yield ancestors, spec
    for child in suite.get("suites") or []:
        yield from _walk_suites(child, ancestors + (str(child.get("title") or ""),))


def parse_playwright_json(payload: dict, ran: bool) -> list[E2ETest]:
    """Turn Playwright's JSON reporter payload into leaves.

    ``ran`` is the load-bearing argument. ``--list`` emits the SAME schema as a real
    run but with empty ``results`` and ``"status": "skipped"`` on every test, meaning
    "not run". With ``ran=False`` every leaf is :data:`STATUS_NOT_RUN` and no status
    is read from the payload at all; with ``ran=True`` the LAST result wins (retries
    are configured, so a test can carry two results and the retry is the verdict).
    """
    tests: list[E2ETest] = []
    for suite in payload.get("suites") or []:
        file_title = str(suite.get("title") or suite.get("file") or "")
        for ancestors, spec in _walk_suites(suite, (file_title,)):
            spec_file = str(spec.get("file") or file_title)
            title = str(spec.get("title") or "")
            title_path = tuple(x for x in (*ancestors, title) if x)
            role, layer = parse_tags(title_path)
            for node in spec.get("tests") or []:
                results = node.get("results") or []
                result = results[-1] if results else None
                if not ran or result is None:
                    status, reason, known, duration, shots = (
                        STATUS_NOT_RUN, "", False, 0, ())
                else:
                    raw = str(result.get("status") or "")
                    status = (STATUS_PASSED if raw == "passed"
                              else STATUS_SKIPPED if raw == "skipped"
                              else STATUS_FAILED)
                    duration = int(result.get("duration") or 0)
                    shots = tuple(_attachment_shots(result))
                    if status == STATUS_SKIPPED:
                        reason, known = skip_reason_of(node, result)
                    else:
                        reason, known = "", False
                tests.append(E2ETest(
                    spec_file=spec_file, title=title, title_path=title_path,
                    id=str(spec.get("id") or ""), line=int(spec.get("line") or 0),
                    role=role, layer=layer, status=status, skip_reason=reason,
                    skip_reason_known=known, duration_ms=duration, screenshots=shots))
    return tests


# ── enumerating the suite (the shell-out) ───────────────────────────────────────

@dataclass
class SpecListing:
    """What ``--list`` found, or a NAMED reason it found nothing. Never raises: the
    e2e page must be able to render "here is why the tree is empty"."""
    tests: list[E2ETest] = field(default_factory=list)
    #: The argv actually executed, so a surface can show the operator what to retry.
    command: tuple[str, ...] = ()
    cwd: str = ""
    error: str = ""

    def __bool__(self) -> bool:
        return bool(self.tests)


Runner = Callable[..., subprocess.CompletedProcess]


def list_specs(generator_dir: str, timeout: int = LIST_TIMEOUT_SEC,
               runner: Runner | None = None) -> SpecListing:
    """Enumerate the suite by asking PLAYWRIGHT, in tests/e2e.

    This is the anti-restatement guarantee of the whole module: the spec list is
    whatever Playwright says it is, in this checkout, right now. It works offline with
    the stack down (verified 2026-08-26, rc=0, 221 specs) because ``--list`` compiles
    the specs and walks the registry without launching a browser.

    ``runner`` is the subprocess seam so parse-level tests can drive recorded JSON.
    """
    e2e_dir = os.path.join(generator_dir, E2E_DIR)
    listing = SpecListing(command=LIST_ARGV, cwd=e2e_dir)
    if not os.path.isdir(os.path.join(e2e_dir, "node_modules")):
        # NAMED, not silent. An empty tree with no explanation would look like a suite
        # that has no specs, which is the one thing it definitely is not.
        listing.error = (f"tests/e2e/node_modules is missing — run `npm ci` in "
                         f"{e2e_dir} before the suite can be enumerated.")
        return listing
    run = runner or subprocess.run
    try:
        proc = run(list(LIST_ARGV), cwd=e2e_dir, capture_output=True, text=True,
                   timeout=timeout)
    except FileNotFoundError:
        listing.error = "npx not found on PATH — Node.js is required to enumerate the suite."
        return listing
    except subprocess.TimeoutExpired:
        listing.error = f"`{' '.join(LIST_ARGV)}` did not finish within {timeout}s."
        return listing
    except OSError as e:                                   # pragma: no cover - rare
        listing.error = f"could not run `{' '.join(LIST_ARGV)}`: {e}"
        return listing
    if proc.returncode != 0:
        # Playwright exits non-zero on a compile error in ANY spec, and then lists
        # nothing. Carrying its stderr through is the difference between "the tree is
        # empty" and "spec 28 has a type error on line 41".
        listing.error = (f"`{' '.join(LIST_ARGV)}` exited {proc.returncode}: "
                         f"{(proc.stderr or proc.stdout or '').strip()[:2000]}")
        return listing
    try:
        payload = json.loads(proc.stdout)
    except ValueError as e:
        listing.error = f"could not parse --list JSON: {e}"
        return listing
    listing.tests = parse_playwright_json(payload, ran=False)
    if not listing.tests:
        listing.error = ("--list produced JSON with no specs — the reporter shape "
                         "changed, or every spec failed to compile.")
    return listing


# ── the last run ────────────────────────────────────────────────────────────────

@dataclass
class RunSummary:
    """The custom reporter's summary.json, as it is ACTUALLY written (reporters/
    hugmesh-reporter.ts onEnd): tier/runId/result/passed/failed/skipped plus perRole
    and perLayer counter lists. Absent fields stay at zero rather than raising — the
    reporter has grown fields twice."""
    tier: str = ""
    run_id: str = ""
    result: str = ""
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    finished_at: str = ""
    per_role: tuple[dict, ...] = ()
    per_layer: tuple[dict, ...] = ()

    @property
    def total(self) -> int:
        return self.passed + self.failed + self.skipped


@dataclass
class LastRun:
    """The most recent run's artefacts, or a NAMED reason there are none."""
    directory: str = ""
    tests: list[E2ETest] = field(default_factory=list)
    summary: RunSummary | None = None
    error: str = ""

    def __bool__(self) -> bool:
        return bool(self.tests)


def find_last_run(generator_dir: str) -> str:
    """Newest directory under tests/e2e/test-results holding a report.json.

    The runner writes per-run subdirectories (SNAP_REPORT_DIR — `studio-<stamp>`,
    `fix-verify`, …) and older runs wrote straight into test-results/, so BOTH shapes
    are searched. Newest by report.json mtime, not by name: the names are not sortable
    across those two conventions.
    """
    base = os.path.join(generator_dir, RESULTS_DIR)
    candidates: list[tuple[float, str]] = []
    direct = os.path.join(base, "report.json")
    if os.path.isfile(direct):
        candidates.append((os.path.getmtime(direct), base))
    try:
        entries = sorted(os.listdir(base))
    except OSError:
        entries = []
    for name in entries:
        d = os.path.join(base, name)
        rep = os.path.join(d, "report.json")
        if os.path.isfile(rep):
            candidates.append((os.path.getmtime(rep), d))
    if not candidates:
        return ""
    return max(candidates)[1]


def parse_summary(payload: dict) -> RunSummary:
    return RunSummary(
        tier=str(payload.get("tier") or ""),
        run_id=str(payload.get("runId") or ""),
        result=str(payload.get("result") or ""),
        passed=int(payload.get("passed") or 0),
        failed=int(payload.get("failed") or 0),
        skipped=int(payload.get("skipped") or 0),
        finished_at=str(payload.get("finishedAt") or ""),
        per_role=tuple(payload.get("perRole") or ()),
        per_layer=tuple(payload.get("perLayer") or ()),
    )


def load_last_run(generator_dir: str, directory: str = "") -> LastRun:
    """Read report.json (+ summary.json when present) from the last run."""
    d = directory or find_last_run(generator_dir)
    if not d:
        return LastRun(error="no run found under tests/e2e/test-results — the tree "
                             "will show the suite, but no pass/fail verdicts.")
    run = LastRun(directory=d)
    try:
        with open(os.path.join(d, "report.json"), encoding="utf-8") as fh:
            payload = json.load(fh)
    except (OSError, ValueError) as e:
        run.error = f"could not read {os.path.join(d, 'report.json')}: {e}"
        return run
    run.tests = parse_playwright_json(payload, ran=True)
    # summary.json is the custom reporter's, so it can be absent (a run driven with
    # --reporter=json only). Its absence must not lose the per-test verdicts above.
    try:
        with open(os.path.join(d, "summary.json"), encoding="utf-8") as fh:
            run.summary = parse_summary(json.load(fh))
    except (OSError, ValueError):
        run.summary = None
    return run


# ── service coverage ────────────────────────────────────────────────────────────

# The identifiers a spec uses to NAME a service. Default is the slug itself; entries
# exist only where the suite calls the service something else, and each says what.
#
# WHY THIS MAP AND NOT A BARE SLUG MATCH: the specs name the PROTOCOL or the product,
# not the container. Matching `tuwunel` alone finds 2 files while the Matrix specs
# (05/10/11/20/26/31/32) exercise it, and `akkoma` alone misses every Mastodon spec.
# Reporting those two as uncovered would be a false alarm, and a coverage warning that
# cries wolf is one an operator learns to ignore — which would take the four REAL
# gaps down with it.
SPEC_TOKENS: dict[str, tuple[str, ...]] = {
    "tuwunel": ("tuwunel", "matrix"),          # the specs say "matrix" throughout
    "akkoma": ("akkoma", "mastodon", "pleroma"),  # local social tier is Mastodon
    "phpbb": ("phpbb", "forum"),               # ROLE_FORUM is the forum's gate
    "tube": ("tube", "peertube"),
    "character-forge": ("character-forge", "chat3d"),  # spec 32 is the forge's 3D room
    "edge-ai-tts": ("edge-ai-tts", "piper", "tts"),
    "media-poisoner": ("media-poisoner", "poisoner", "cloak"),
    "tor": ("tor", "onion"),
}

UNCOVERED_REASON = (
    "NO spec names this service. The tree must not offer a Run button here: it would "
    "run nothing and report green.")
UNREACHABLE_REASON = (
    "not reachable from this suite: it is a Kubernetes-lane service (`make kind-up`), "
    "and the Playwright suite drives the docker-compose stack.")


@dataclass(frozen=True)
class ServiceCoverage:
    """Whether the e2e suite touches a service AT ALL, and if not, why not."""
    slug: str
    mechanism: str
    spec_files: tuple[str, ...] = ()
    #: False for a service whose LANE the suite cannot drive. Distinct from
    #: uncovered: "nobody wrote a test" and "no test could exist here" are different
    #: asks, and merging them turns one into an excuse for the other.
    reachable: bool = True
    reason: str = ""

    @property
    def covered(self) -> bool:
        return bool(self.spec_files)

    @property
    def needs_a_test(self) -> bool:
        """The set a surface should surface LOUDLY: reachable by this suite, and
        untested."""
        return self.reachable and not self.covered


def _strip_ts_comments(text: str) -> str:
    """Comments out before any token search. A comment naming a token has inverted
    exactly this kind of check four times in this repo — and does here too: `phpbb`
    occurs in this suite ONLY in comments."""
    return _LINE_COMMENT_RE.sub("", _BLOCK_COMMENT_RE.sub("", text))


def _spec_sources(generator_dir: str) -> dict[str, str]:
    """Every .ts under tests/e2e/specs, RAW. Helpers are included on purpose: a
    service reached only through helpers.ts/federation.ts is still reached.

    Comment stripping is NOT done here — it is done in :func:`service_coverage`, over
    whatever sources it was handed. Stripping at the read site left the injectable
    ``sources`` seam un-stripped, so a caller (a test, the eventual GUI) passing its
    own text would silently get the raw-grep behaviour this module exists to avoid.
    """
    d = os.path.join(generator_dir, SPECS_DIR)
    out: dict[str, str] = {}
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return {}
    for fn in names:
        if not fn.endswith(".ts"):
            continue
        try:
            with open(os.path.join(d, fn), encoding="utf-8", errors="replace") as fh:
                out[fn] = fh.read()
        except OSError:
            continue
    return out


def _token_re(token: str) -> re.Pattern:
    # Boundaries that are NOT \b: slugs contain '-', so \b would let `tube` match
    # inside `youtube` and `tor` match inside `operator`/`selector`/`generator`.
    return re.compile(r"(?<![A-Za-z0-9])" + re.escape(token) + r"(?![A-Za-z0-9])",
                      re.IGNORECASE)


def service_coverage(generator_dir: str,
                     sources: dict[str, str] | None = None
                     ) -> tuple[ServiceCoverage, ...]:
    """Which catalogued local-mesh services the suite exercises, and which it does not.

    The catalogue is core.local_services.LOCAL_SERVICES — imported, not restated, so a
    service added there shows up here as an uncovered row on its first day instead of
    being invisible until someone notices.

    Measured 2026-08-26 over the specs in this checkout: wiki, owncast, tube,
    character-studio, tor, anubis, edge-ai-tts and media-poisoner match NOTHING.
    """
    raw = _spec_sources(generator_dir) if sources is None else sources
    # Strip HERE, not at the read site, so every source of text goes through it.
    src = {fn: _strip_ts_comments(text) for fn, text in raw.items()}
    out: list[ServiceCoverage] = []
    for svc in local_services.LOCAL_SERVICES:
        if svc.is_kind():
            out.append(ServiceCoverage(slug=svc.slug, mechanism=svc.mechanism,
                                       reachable=False, reason=UNREACHABLE_REASON))
            continue
        tokens = SPEC_TOKENS.get(svc.slug, (svc.slug,))
        patterns = [_token_re(t) for t in tokens]
        hits = tuple(fn for fn, text in sorted(src.items())
                     if any(p.search(text) for p in patterns))
        out.append(ServiceCoverage(
            slug=svc.slug, mechanism=svc.mechanism, spec_files=hits,
            reason="" if hits else UNCOVERED_REASON))
    return tuple(out)


def uncovered_services(coverage: Sequence[ServiceCoverage]) -> tuple[ServiceCoverage, ...]:
    """The rows a surface must render as "no coverage", never as a green Run button."""
    return tuple(c for c in coverage if c.needs_a_test)


# ── personas the seeder deliberately leaves gated ───────────────────────────────

@dataclass(frozen=True)
class GatedPersona:
    """A persona whose UN-ONBOARDED state is load-bearing. Marked so nobody fixes it."""
    username: str
    reason: str
    source: str = GATED_SCRIPT


def gated_personas(generator_dir: str, roster: Roster | None = None
                   ) -> tuple[GatedPersona, ...]:
    """Personas seed-e2e.sh never completes registration for.

    TWO mechanisms, both modelled, because the script itself says a name-list alone
    misses half: (1) the explicit ``SEED_REGISTRATION_SKIP`` default —
    ``e2e-pending rbac-pending-gmail-com e2e-banned`` — and (2) the SHAPE rule in
    onboard_persona(), which returns "gated" for ANY handle containing ``@``. That
    second rule is why the roster's ``rbac-pending@gmail.com`` and Casdoor's
    normalised ``rbac-pending-gmail-com`` are BOTH gated while only one of the two
    spellings appears in the list.

    ``roster`` (default: parsed here) supplies the @-shaped handles.
    """
    named: list[str] = []
    try:
        with open(os.path.join(generator_dir, GATED_SCRIPT), encoding="utf-8") as fh:
            m = _GATED_RE.search(fh.read())
        if m:
            named = m.group("v").split()
    except OSError:
        named = []
    out: list[GatedPersona] = []
    seen: set[str] = set()
    for u in named:
        if u not in seen:
            seen.add(u)
            out.append(GatedPersona(username=u, reason=GATED_NAMED_REASON))
    r = load_roster(generator_dir) if roster is None else roster
    for user in r.users:
        if "@" in user.username and user.username not in seen:
            seen.add(user.username)
            out.append(GatedPersona(username=user.username, reason=GATED_EMAIL_REASON))
    return tuple(out)


# ── the whole catalogue ─────────────────────────────────────────────────────────

@dataclass
class Catalogue:
    """Everything the e2e tree renders, plus what could not be determined.

    ``problems`` is deliberately a first-class field and not a log line: every entry
    is a way the tree would otherwise look healthier than the suite is."""
    features: list[Feature] = field(default_factory=list)
    services: tuple[ServiceCoverage, ...] = ()
    roster: Roster = field(default_factory=Roster)
    gated: tuple[GatedPersona, ...] = ()
    run: LastRun = field(default_factory=LastRun)
    listing: SpecListing = field(default_factory=SpecListing)
    problems: list[str] = field(default_factory=list)

    def __bool__(self) -> bool:
        return bool(self.features)

    @property
    def tests(self) -> tuple[E2ETest, ...]:
        return tuple(t for f in self.features for t in f.tests)

    @property
    def unexplained_skips(self) -> tuple[E2ETest, ...]:
        return tuple(t for t in self.tests
                     if t.status == STATUS_SKIPPED and not t.skip_reason_known)

    @property
    def uncovered(self) -> tuple[ServiceCoverage, ...]:
        return uncovered_services(self.services)

    def gated_usernames(self) -> frozenset[str]:
        return frozenset(g.username for g in self.gated)


def _merge_run(tests: Sequence[E2ETest], run_tests: Sequence[E2ETest]) -> list[E2ETest]:
    """Overlay the last run's verdicts onto the enumerated suite.

    Matched on ``(spec_file, title_path)``. Playwright's spec ``id`` is NOT a stabler
    key: measured 2026-08-26 against the 2026-08-22 run, three tests in spec 25 were
    retitled ("superadmin" -> "e2e-superadmin") and their ids drifted with them
    (218/221 ids in common), because the id is a hash over file+title. So neither key
    survives a rename, and title_path at least exists in every payload shape and is
    what the reporter's own per-role pivot keys on.

    A renamed test is therefore reported HONESTLY as two rows: the listing entry stays
    :data:`STATUS_NOT_RUN`, and the run entry is KEPT as an orphan rather than dropped.
    Dropping it would make the run's own failure count unexplainable (76 failures, 73
    rows), and quietly transplanting the old verdict onto the new title would show a
    verdict for a test under a name that never ran.
    """
    by_key = {(t.spec_file, t.title_path): t for t in run_tests}
    out: list[E2ETest] = []
    used: set[tuple] = set()
    for t in tests:
        key = (t.spec_file, t.title_path)
        hit = by_key.get(key)
        if hit is None:
            out.append(t)
            continue
        used.add(key)
        out.append(E2ETest(
            spec_file=t.spec_file, title=t.title, title_path=t.title_path,
            id=t.id or hit.id, line=t.line or hit.line, role=t.role, layer=t.layer,
            kind=t.kind, status=hit.status, skip_reason=hit.skip_reason,
            skip_reason_known=hit.skip_reason_known, duration_ms=hit.duration_ms,
            screenshots=hit.screenshots))
    out += [t for k, t in by_key.items() if k not in used]
    return out


def build_features(tests: Sequence[E2ETest],
                   shots: dict[str, tuple[Screenshot, ...]] | None = None
                   ) -> list[Feature]:
    """Group leaves into one node per spec file, in filename order."""
    shots = shots or {}
    grouped: dict[str, list[E2ETest]] = {}
    for t in tests:
        grouped.setdefault(t.spec_file, []).append(t)
    out: list[Feature] = []
    for file in sorted(grouped):
        num = _spec_number(file)
        out.append(Feature(file=file, number=num, tests=tuple(grouped[file]),
                           screenshots=shots.get(num, ())))
    return out


def load_catalogue(generator_dir: str, env: dict[str, str] | None = None,
                   runner: Runner | None = None) -> Catalogue:
    """Assemble the whole model for a generator checkout. Never raises.

    Every half degrades independently and says so in ``problems``: no node_modules
    still yields the last run's tests and the service/persona data; no run still
    yields the full tree marked :data:`STATUS_NOT_RUN`.
    """
    cat = Catalogue()
    cat.listing = list_specs(generator_dir, runner=runner)
    if cat.listing.error:
        cat.problems.append(cat.listing.error)
    cat.run = load_last_run(generator_dir)
    if cat.run.error:
        cat.problems.append(cat.run.error)

    tests = _merge_run(cat.listing.tests, cat.run.tests)
    cat.features = build_features(tests, index_screenshots(generator_dir))

    cat.roster = load_roster(generator_dir, env)
    if cat.roster.error:
        cat.problems.append(cat.roster.error)
    cat.gated = gated_personas(generator_dir, cat.roster)
    if not cat.gated:
        cat.problems.append(
            f"could not read SEED_REGISTRATION_SKIP from {GATED_SCRIPT} — the "
            "deliberately-gated personas cannot be marked, and someone will 'fix' them.")

    cat.services = service_coverage(generator_dir)
    missing = uncovered_services(cat.services)
    if missing:
        cat.problems.append(
            f"{len(missing)} service(s) have NO e2e coverage: "
            + ", ".join(c.slug for c in missing))
    unexplained = cat.unexplained_skips
    if unexplained:
        cat.problems.append(
            f"{len(unexplained)} skipped test(s) gave no machine-readable reason.")
    return cat
