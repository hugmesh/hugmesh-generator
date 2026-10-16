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
     whatever it finds today. The five that ARE covered are tuwunel (19 files),
     akkoma (19), games (11), phpbb (2) and character-forge (1); argocd and
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

TWO COUNTS THAT DO NOT AGREE, AND MUST NOT BE PRESENTED AS ONE. summary.json counts
RESULTS (hugmesh-reporter.ts counts in ``onTestEnd(test, result)`` — once per attempt,
and ``retries: 1`` is configured), while the tree counts TESTS. On the run of
2026-08-22 that is 121/76/62 = 259 results against 221 tests of which 38 failed:
76 = 38 x 2. A banner reading "76 failed / 259 total" over a tree with 38 red rows is
the same reporter-vs-tree disagreement in front of the operator that :func:`parse_tags`
is written to avoid on the role pivot. So :class:`RunSummary`'s fields are NAMED for
what they count (``failed_results``, ``total_results``), :meth:`LastRun.counts` gives
the per-test half, and :attr:`LastRun.retried_results` is the gap between them.

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

THE HAND-OFF POINT FOR THE GHERKIN TRACK. A concurrent track is adding playwright-bdd .feature
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
FEATURES_DIR = os.path.join(E2E_DIR, "features")
STEPS_DIR = os.path.join(E2E_DIR, "steps")

# A checkout whose tree the Studio must NEVER write into. `make stack-clone` wipes
# and re-clones .stack-src, so an edit saved there is lost with no warning and the
# operator's next `make` silently un-does their work. Any source the tree surfaces
# from under it is opened READ-ONLY and says so. (See core/local_mesh_bootstrap: the
# same directory is gitignored, which is why nothing here would even show as dirty.)
STACK_SRC_DIR = ".stack-src"
READONLY_STACK_SRC_REASON = (
    "READ-ONLY: this file lives under .stack-src, which `make stack-clone` deletes "
    "and re-clones. A save here would be silently thrown away.")
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
# it is the hand-off point the playwright-bdd track lands on.
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

# TypeScript comments, stripped before any token search over spec source. HOUSE RULE.
# The `//` form is stripped from ANYWHERE ON THE LINE, not just from a line that
# STARTS with it. A leading-only strip was the bug a review caught here on 2026-08-26:
# `const x = 1;   // this file is about owncast` left the comment in place and reported
# owncast — a service with ZERO specs — as covered, which is exactly the green Run
# button that runs nothing this module exists to refuse. Measured cost of the
# leading-only form on the real specs: tuwunel and akkoma each read one file too many.
#
# `(?<![:/])` keeps `https://`, `http://` and `file:///` out of it — a URL is not a
# comment, and stripping from the `//` of a URL would delete the rest of a real line of
# code (the host, the path, and any service name in it).
_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
_LINE_COMMENT_RE = re.compile(r"(?m)(?<![:/])//.*$")


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
    #: it). These fields are the hand-off point the Gherkin track fills; nothing may infer them.
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
    for att in _as_list(_as_dict(result).get("attachments")):
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
        for ann in _as_list(_as_dict(node).get("annotations")):
            if ann.get("type") not in ("skip", "fixme"):
                continue
            desc = str(ann.get("description") or "").strip()
            if desc:
                return desc, True
    return UNKNOWN_SKIP_REASON, False


# ── shape defence ───────────────────────────────────────────────────────────────
# report.json is written by a tool we do not control, and this module's whole promise
# to the e2e page is "never raises — render the reason the tree is empty". A review on
# 2026-08-26 measured four STRUCTURALLY-WRONG-BUT-VALID payloads escaping every
# handler and propagating out of load_catalogue: `"suites": "oops"` (AttributeError),
# `"duration": "12ms"` (ValueError from int()), `annotations` as a dict, `attachments`
# as a string. json.load's own ValueError was caught; a SHAPE change was not — and a
# shape change is the case this module explicitly anticipates ("the reporter has grown
# fields twice"). Every field read below now goes through one of these three.

def _as_dict(value) -> dict:
    return value if isinstance(value, dict) else {}


def _as_list(value) -> list:
    """A list of DICTS, and nothing else. A string is iterable, which is how
    `"attachments": "nope"` turned into `'str' object has no attribute 'get'`."""
    if not isinstance(value, list):
        return []
    return [v for v in value if isinstance(v, dict)]


def _safe_int(value) -> int:
    """0 for anything that is not a number. A duration of "12ms" is a reporter that
    changed shape, not a reason to take the whole tree down."""
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _walk_suites(suite: dict, ancestors: tuple[str, ...]):
    """Yield ``(title_path_prefix, spec)`` for every spec in a Playwright suite tree.

    Playwright nests: the outermost suite's title is the FILE, inner suites are
    describe() blocks. A flat read of ``suites[i].specs`` misses every describe'd
    test — which in this suite is most of them (33 files, 221 specs).
    """
    suite = _as_dict(suite)
    for spec in _as_list(suite.get("specs")):
        yield ancestors, spec
    for child in _as_list(suite.get("suites")):
        yield from _walk_suites(child, ancestors + (str(child.get("title") or ""),))


def parse_playwright_json(payload: dict, ran: bool) -> list[E2ETest]:
    """Turn Playwright's JSON reporter payload into leaves.

    ``ran`` is the argument that matters. ``--list`` emits the SAME schema as a real
    run but with empty ``results`` and ``"status": "skipped"`` on every test, meaning
    "not run". With ``ran=False`` every leaf is :data:`STATUS_NOT_RUN` and no status
    is read from the payload at all; with ``ran=True`` the LAST result wins (retries
    are configured, so a test can carry two results and the retry is the verdict).
    """
    tests: list[E2ETest] = []
    for suite in _as_list(_as_dict(payload).get("suites")):
        file_title = str(suite.get("title") or suite.get("file") or "")
        for ancestors, spec in _walk_suites(suite, (file_title,)):
            spec_file = str(spec.get("file") or file_title)
            title = str(spec.get("title") or "")
            title_path = tuple(x for x in (*ancestors, title) if x)
            role, layer = parse_tags(title_path)
            for node in _as_list(spec.get("tests")):
                results = _as_list(node.get("results"))
                result = results[-1] if results else None
                if not ran or result is None:
                    status, reason, known, duration, shots = (
                        STATUS_NOT_RUN, "", False, 0, ())
                else:
                    raw = str(result.get("status") or "")
                    status = (STATUS_PASSED if raw == "passed"
                              else STATUS_SKIPPED if raw == "skipped"
                              else STATUS_FAILED)
                    duration = _safe_int(result.get("duration"))
                    shots = tuple(_attachment_shots(result))
                    if status == STATUS_SKIPPED:
                        reason, known = skip_reason_of(node, result)
                    else:
                        reason, known = "", False
                tests.append(E2ETest(
                    spec_file=spec_file, title=title, title_path=title_path,
                    id=str(spec.get("id") or ""), line=_safe_int(spec.get("line")),
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

    ``runner`` is the subprocess override point so parse-level tests can drive recorded JSON.
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
    try:
        listing.tests = parse_playwright_json(payload, ran=False)
    except Exception as e:                       # belt and braces over the shape guards
        listing.error = (f"`{' '.join(LIST_ARGV)}` returned JSON this parser could not "
                         f"read ({type(e).__name__}: {e}) — the reporter shape changed.")
        return listing
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
    reporter has grown fields twice.

    THESE ARE RESULT COUNTS, NOT TEST COUNTS, and the fields are named for it. The
    reporter counts in ``onTestEnd(test, result)`` — once per ATTEMPT — and
    playwright.config.ts sets ``retries: 1``, so every failing test is counted TWICE.
    MEASURED on the run of 2026-08-22 (studio-20260822-193645): summary.json says
    121/76/62 = 259, while report.json holds 221 TESTS of which 38 failed. 76 = 38 x 2.

    This is not a footnote. A banner reading "76 failed / 259 total" over a tree with
    38 red rows out of 224 is the reporter-vs-tree disagreement IN FRONT OF THE
    OPERATOR that :func:`parse_tags` exists to avoid on the role pivot — so the two
    numbers are named differently here and :meth:`LastRun.counts` gives a surface the
    per-test half to render beside it. :attr:`LastRun.retried_results` is the gap.
    """
    tier: str = ""
    run_id: str = ""
    result: str = ""
    #: RESULTS, not tests — see the class docstring. Retries are counted again.
    passed_results: int = 0
    failed_results: int = 0
    skipped_results: int = 0
    finished_at: str = ""
    per_role: tuple[dict, ...] = ()
    per_layer: tuple[dict, ...] = ()

    @property
    def total_results(self) -> int:
        """Attempts the reporter counted — NOT the size of the suite."""
        return self.passed_results + self.failed_results + self.skipped_results


@dataclass
class LastRun:
    """The most recent run's artefacts, or a NAMED reason there are none."""
    directory: str = ""
    tests: list[E2ETest] = field(default_factory=list)
    summary: RunSummary | None = None
    error: str = ""

    def __bool__(self) -> bool:
        return bool(self.tests)

    def counts(self) -> dict[str, int]:
        """Per-TEST status counts from report.json's tree — the half a surface renders
        as rows. Deliberately distinct from :class:`RunSummary`, which counts attempts;
        on the 2026-08-22 run this says 38 failed where the summary says 76."""
        out = {STATUS_PASSED: 0, STATUS_FAILED: 0, STATUS_SKIPPED: 0, STATUS_NOT_RUN: 0}
        for t in self.tests:
            out[t.status] = out.get(t.status, 0) + 1
        return out

    @property
    def retried_results(self) -> int:
        """How many EXTRA attempts the reporter counted beyond one per test — the whole
        of the gap between summary.json's totals and this tree's row count. 0 when
        there is no summary.json to disagree with."""
        if self.summary is None:
            return 0
        return max(0, self.summary.total_results - len(self.tests))


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
    p = _as_dict(payload)
    return RunSummary(
        tier=str(p.get("tier") or ""),
        run_id=str(p.get("runId") or ""),
        result=str(p.get("result") or ""),
        passed_results=_safe_int(p.get("passed")),
        failed_results=_safe_int(p.get("failed")),
        skipped_results=_safe_int(p.get("skipped")),
        finished_at=str(p.get("finishedAt") or ""),
        per_role=tuple(_as_list(p.get("perRole"))),
        per_layer=tuple(_as_list(p.get("perLayer"))),
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
    report = os.path.join(d, "report.json")
    try:
        run.tests = parse_playwright_json(payload, ran=True)
    except Exception as e:                       # belt and braces over the shape guards
        run.error = (f"{report} is not the shape this parser can read "
                     f"({type(e).__name__}: {e}) — the reporter shape changed.")
        return run
    if not run.tests:
        # An empty tree with no stated reason looks like a run that had no tests, which
        # a run that WROTE a report.json definitely did not. Same rule as list_specs.
        run.error = (f"{report} parsed to no tests — the reporter shape changed, or "
                     "the run recorded nothing.")
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
# not the container. MEASURED 2026-08-26 by bypassing this map entirely (bare slug for
# every service) over this checkout's comment-stripped specs:
#
#     tuwunel  19 files -> 1     akkoma  19 -> 7     phpbb  2 -> 0 (UNCOVERED)
#
# So phpbb's verdict itself hangs on the `forum` alias — the forum is reached ONLY as
# ROLE_FORUM / /bff/forum/** and the string "phpbb" appears in this suite in comments
# alone. tuwunel and akkoma do NOT flip; what a bare slug does to them is destroy the
# EVIDENCE — 19 files down to 1 — so a surface would show "covered" next to a single
# incidental mention and no Matrix spec at all.
#
# An earlier version of this comment claimed tuwunel and akkoma would "read as
# uncovered" without the map. A review measured that and it is false; the numbers
# above are what actually happens, and there is a test pinning them.
#
# The map cuts the other way too, and that is the half worth keeping in mind: `tube`,
# `edge-ai-tts` and `media-poisoner` are searched under EVERY spelling the suite
# might use (peertube, piper/tts, poisoner/cloak) and still match nothing. Their
# zero-coverage verdict is stronger for it, not weaker. `tor` was in that list until
# 2026-09-23 (hugmesh-generator#576): it is now reached as `onion` by specs/helpers.ts's
# Tor front door (onionFrontDoor/onionContext — a proxied browser context), which the
# @via:onion Gherkin scenario drives through the real Tor network.
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
    exactly this kind of check four times in this repo.

    WHAT IT ACTUALLY BUYS, measured 2026-08-26 over this checkout's specs — stated
    precisely because the earlier claim here ("`phpbb` occurs ONLY in comments", as if
    stripping were what keeps the forum honest) did not survive review:

      * NO service's covered/uncovered verdict changes today. A raw grep flips nothing
        on: the nine zero-coverage services match nothing in comments either.
      * What changes is the EVIDENCE a surface shows: tuwunel 27 -> 19 files,
        akkoma 24 -> 19, phpbb 3 -> 2. Crediting spec 33 to phpbb because its header
        comment says "phpBB" is the kind of padding that makes a coverage list stop
        meaning anything.
      * It is the standing GUARD for the day a comment is the only mention: with the
        stripper removed, a spec whose only mention of owncast is a comment reports
        owncast — zero specs — as covered. That is measured, in the test suite.
    """
    return _LINE_COMMENT_RE.sub("", _BLOCK_COMMENT_RE.sub("", text))


def _spec_sources(generator_dir: str) -> dict[str, str]:
    """Every .ts under tests/e2e/specs, RAW. Helpers are included on purpose: a
    service reached only through helpers.ts/federation.ts is still reached.

    Comment stripping is NOT done here — it is done in :func:`service_coverage`, over
    whatever sources it was handed. Stripping at the read site left the injectable
    ``sources`` override point un-stripped, so a caller (a test, the eventual GUI) passing its
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
    # NON-ALNUM boundaries, and the difference from \b is EXACTLY ONE CHARACTER:
    # underscore. `_` is a word char, so \b does NOT break on it; it is not alnum, so
    # this lookaround DOES. That makes this pattern LOOSER than \b, deliberately: the
    # suite names services in SCREAMING_SNAKE role constants, and `forum` must match
    # inside `ROLE_FORUM` and `games` inside `ROLE_GAMES_ADMIN` — the gates those two
    # services are actually reached through. MEASURED 2026-08-26: switching to \b
    # drops phpbb from 2 files to 0 (i.e. to UNCOVERED) and games from 11 to 10.
    #
    # An earlier comment here claimed \b would let `tube` match inside `youtube` and
    # `tor` inside `operator`. That is FALSE and a review caught it: \b refuses both
    # of those exactly as this does (re.search(r"\btube\b", "youtubeUrl") is None).
    # Sub-word matches are refused by BOTH forms; only the underscore differs. What a
    # bare `token in text` would wrongly match is pinned separately.
    return re.compile(r"(?<![A-Za-z0-9])" + re.escape(token) + r"(?![A-Za-z0-9])",
                      re.IGNORECASE)


# A .ts under specs/ that PLAYWRIGHT WILL RUN, or a helper that actually DRIVES the
# browser or the API. Everything else under specs/ is a declarative table, and a table
# is not coverage.
#
# WHY THIS EXISTS, MEASURED 2026-08-26 on this checkout. `_spec_sources` reads every
# .ts under specs/ on purpose -- "a service reached only through helpers.ts /
# federation.ts is still reached" -- and that rule is right for a DRIVER. It is wrong
# for a ROW TABLE. tests/e2e/specs/rbac-route-access.seed.ts enumerates every gateway
# route in the platform, including the routes of services no spec ever visits, and it
# is transitively imported by a real spec. Reading it as evidence flipped FOUR of the
# nine zero-coverage services to "covered" on the strength of that ONE file:
#
#     wiki 0 -> 1    owncast 0 -> 1    tube 0 -> 1    character-studio 0 -> 1
#
# Those are the four the operator asked about BY NAME, and "covered by a route table
# that mentions you" is exactly the green Run button that runs nothing this module
# exists to refuse. (This is not hypothetical and it is not this integration's doing:
# the same three tests fail with feat/studio-e2e-catalogue-core alone on top of
# origin/main once PR #177 lands that seed file.)
#
# The discriminator is SHAPE, not a filename: a file is kept if Playwright runs it
# (*.spec.ts) or if it touches page/request/context or calls test()/expect(). MEASURED
# effect on this checkout -- kept: helpers.ts, federation.ts, swarm-driver.ts (the
# three the design paragraph above is about); dropped: rbac-route-access.seed.ts,
# rbac-route-access.ts, rbac-roles.ts, report-tags.ts, totp.ts. The four files that do not exist go
# back to UNCOVERED and no real coverage verdict flips: tuwunel 20 -> 18 files,
# akkoma 20 -> 18, games 12 -> 9, phpbb 3 -> 1, character-forge 2 -> 1, all still
# covered. Only the EVIDENCE shrinks, and it shrinks to evidence that runs.
_DRIVES_RE = re.compile(
    r"\b(?:page|request|context|apiRequest)\s*\.|"
    # The lookbehind excludes a leading DOT as well as word characters, because
    # `RegExp(...).test(p)` is not Playwright's `test(`. Without it a pure
    # source-READER module (governance-sources.ts uses .test() for pattern
    # matching, and starts no browser and opens no port) reads as runnable, and
    # every service it merely NAMES — wiki, via a path string in a map — flips to
    # covered. A false "covered" is worse than an uncovered row: it hides the gap.
    r"(?<![A-Za-z0-9_.])(?:test|expect)\s*\(")


def is_runnable_source(name: str, stripped_text: str) -> bool:
    """True for a spec Playwright runs, or a helper that drives something.

    ``stripped_text`` must already be comment-stripped -- a driving call named only in
    a comment is prose, and this is the same house rule :func:`_strip_ts_comments`
    enforces one line up.
    """
    if name.endswith(".spec.ts"):
        return True
    return bool(_DRIVES_RE.search(stripped_text))


def service_coverage(generator_dir: str,
                     sources: dict[str, str] | None = None
                     ) -> tuple[ServiceCoverage, ...]:
    """Which catalogued local-mesh services the suite exercises, and which it does not.

    The catalogue is core.local_services.LOCAL_SERVICES — imported, not restated, so a
    service added there shows up here as an uncovered row on its first day instead of
    being invisible until someone notices.

    Measured over the specs in this checkout, comments stripped and declarative
    tables excluded (see :func:`is_runnable_source`): wiki, owncast, tube,
    character-studio, anubis, edge-ai-tts, media-poisoner and egress-vpn match
    NOTHING (tor did too until the onion front door landed, hugmesh-generator#576). The five covered are tuwunel (18 files), akkoma (18), games (9),
    phpbb (1) and character-forge (1). The numbers move when the suite does -- they
    are re-measured, and pinned as INEQUALITIES where the exact count is not the
    point; the covered/uncovered VERDICTS are what the tests pin exactly.
    """
    raw = _spec_sources(generator_dir) if sources is None else sources
    # Strip HERE, not at the read site, so every source of text goes through it.
    stripped = {fn: _strip_ts_comments(text) for fn, text in raw.items()}
    # ...and drop the tables for the same reason, in the same place, so the
    # injectable `sources` override point gets both filters or neither.
    src = {fn: text for fn, text in stripped.items() if is_runnable_source(fn, text)}
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


# ── doors a service has on a lane OTHER than the compose specs ──────────────────
#
# service_coverage() reads tests/e2e/specs/*.ts, the compose lane's specs, and is
# right to: a Gherkin .feature is not a spec file and must not flip that verdict.
# A service can ALSO have a door on another lane that the compose verdict never
# mentions. `tor` is the case: the kind lane publishes its front door as a v3 onion
# (`make kind-tor`, hugmesh-generator#577, decision 67 = B) and
# features/platform/tor-onion-kind.feature drives a persona through it. That is
# true whether or not tor is covered on the compose lane (it became covered when
# #576's onion helpers landed), so the e2e tree lists every LaneDoor in its OWN
# group, independent of the coverage verdict, and repeats the line under the
# service's NO COVERAGE / unreachable row when it has one. Each line is CHECKED
# against the tree — a door whose feature file is gone, or lost the tags that
# select it, says so instead of vouching for a scenario that no longer exists.

@dataclass(frozen=True)
class LaneDoor:
    """One lane's own way in to a service, and the scenario that drives it."""
    slug: str
    lane: str
    bring_up: str
    run: str
    #: Repo-relative .feature path.
    feature: str
    #: Tags the feature must carry for `run` to select it.
    tags: tuple[str, ...]


LANE_DOORS: tuple[LaneDoor, ...] = (
    LaneDoor(slug="tor", lane="kind",
             bring_up="make kind-up && make kind-images && make kind-tor",
             run="make kind-e2e-tor",
             feature="tests/e2e/features/platform/tor-onion-kind.feature",
             tags=("@env:kind", "@via:onion")),
)


def _feature_tags(text: str) -> set[str]:
    """Every @tag on a Gherkin TAG line (comments and step text are not tags)."""
    tags: set[str] = set()
    for raw in text.splitlines():
        line = raw.split(" #", 1)[0].strip()
        if line.startswith("@"):
            tags.update(t for t in line.split() if t.startswith("@"))
    return tags


def _door_line(generator_dir: str, door: LaneDoor) -> str:
    """One plain line for ``door``, verified against the checkout at ``generator_dir``."""
    path = os.path.join(generator_dir, door.feature)
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            tags = _feature_tags(fh.read())
    except OSError:
        tags = None
    name = os.path.basename(door.feature)
    if tags is None:
        return (f"{door.lane}: a door is declared ({door.bring_up}) but "
                f"{door.feature} is MISSING — nothing drives it.")
    if not set(door.tags) <= tags:
        missing = " ".join(t for t in door.tags if t not in tags)
        return (f"{door.lane}: {name} lost its {missing} tag(s), so "
                f"`{door.run}` selects nothing — nothing drives this door.")
    return (f"{door.lane}: {name} drives this service through the "
            f"{door.lane} lane's own door. Bring it up with "
            f"`{door.bring_up}`, run it with `{door.run}` — only that live run "
            f"proves the door. It is a .feature, so it is not counted in the "
            f"compose-lane spec coverage.")


def lane_door_lines(generator_dir: str, slug: str) -> tuple[str, ...]:
    """One plain line per lane door of service ``slug`` (the e2e tree's service rows)."""
    return tuple(_door_line(generator_dir, d) for d in LANE_DOORS if d.slug == slug)


def lane_door_lines_for_lane(generator_dir: str, lane: str) -> tuple[str, ...]:
    """The same lines, keyed the other way: every service door ON environment ``lane``
    (the GUI e2e page's and the TUI e2e screen's per-environment plan — one telling,
    authored here, for both faces)."""
    return tuple(f"{d.slug} — {_door_line(generator_dir, d)}"
                 for d in LANE_DOORS if d.lane == lane)


# ── personas the seeder deliberately leaves gated ───────────────────────────────

@dataclass(frozen=True)
class GatedPersona:
    """A persona whose UN-ONBOARDED state is relied on. Marked so nobody fixes it."""
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


# ── gherkin features (the playwright-bdd track's nodes) ─────────────────────────

# The operator asked for GHERKIN by name, so a .feature file is a first-class node,
# not a footnote under the spec that generates it. The harness lands on a CONCURRENT
# branch (feat/e2e-gherkin-harness), so this checkout may legitimately have no
# tests/e2e/features at all — and the difference between "no features yet" and "the
# tree forgot to look" is exactly the kind of silence this module exists to refuse.
# So the absence is a NAMED reason, never an empty list.
GHERKIN_ABSENT_REASON = (
    "tests/e2e/features does not exist in this checkout — the playwright-bdd Gherkin "
    "harness lands on the feat/e2e-gherkin-harness branch. This is 'not merged here "
    "yet', NOT 'there are no feature files'.")
GHERKIN_EMPTY_REASON = (
    "tests/e2e/features exists but holds no .feature file.")

# Gherkin's own keywords. Only the three the tree renders are parsed; a Background or
# a step line is deliberately NOT modelled, because nothing downstream consumes it and
# a half-parser invites a reader to trust it for more than it does.
_FEATURE_RE = re.compile(r"(?m)^\s*Feature:\s*(?P<t>.*?)\s*$")
_SCENARIO_RE = re.compile(
    r"(?m)^\s*(?P<kw>Scenario Outline|Scenario Template|Scenario|Example):"
    r"\s*(?P<t>.*?)\s*$")
# `<>` is in the class on purpose: a Scenario Outline tags itself with the
# PLACEHOLDER (`@platform:<platform>`), and a class that excluded them left those
# tags stranded in the scenario TITLE with `tags` reported empty.
_TAG_RE = re.compile(r"@[A-Za-z0-9_:.<>-]+")


@dataclass(frozen=True)
class GherkinScenario:
    """One ``Scenario:`` line — the leaf a .feature contributes to the tree."""
    name: str
    keyword: str
    line: int
    tags: tuple[str, ...] = ()


@dataclass(frozen=True)
class GherkinFeature:
    """One .feature FILE. ``rel`` is checkout-relative so a surface can show where it
    came from; ``path`` is what an editor opens."""
    path: str
    rel: str
    title: str
    scenarios: tuple[GherkinScenario, ...] = ()
    tags: tuple[str, ...] = ()
    error: str = ""


@dataclass
class GherkinIndex:
    """The .feature files, or a NAMED reason there are none."""
    features: tuple[GherkinFeature, ...] = ()
    root: str = ""
    error: str = ""

    def __bool__(self) -> bool:
        return bool(self.features)


def parse_gherkin(text: str) -> tuple[str, tuple[GherkinScenario, ...], tuple[str, ...]]:
    """``(feature title, scenarios, feature-level tags)`` from .feature SOURCE.

    Tags are attributed by ADJACENCY, the way Gherkin actually scopes them: the
    contiguous run of ``@tag`` lines immediately above a Scenario belongs to it, and a
    run above the ``Feature:`` line belongs to the file. A file-wide tag scan would
    hand every scenario every tag, which reads as coverage nobody wrote.
    """
    lines = text.splitlines()
    pending: list[str] = []
    title = ""
    ftags: tuple[str, ...] = ()
    scenarios: list[GherkinScenario] = []
    for i, raw in enumerate(lines, start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            if not line:
                pending = []          # a blank line breaks the adjacency run
            continue
        if line.startswith("@"):
            pending.extend(_TAG_RE.findall(line))
            continue
        m = _FEATURE_RE.match(raw)
        if m and not title:
            title = m.group("t")
            ftags = tuple(pending)
            pending = []
            continue
        m = _SCENARIO_RE.match(raw)
        if m:
            # This suite writes its per-scenario tags INLINE, at the end of the
            # Scenario line ("... on <platform> @platform:<platform> @layer:ui"),
            # which is legal Gherkin. Leaving them in the title would put raw
            # @-noise in every tree row AND leave `tags` falsely empty, so they are
            # split off the tail — only from the tail, so a '@' inside a scenario's
            # prose is untouched.
            name = m.group("t")
            inline: list[str] = []
            while True:
                tail = name.rsplit(" ", 1)
                if len(tail) == 2 and tail[1].startswith("@") and _TAG_RE.fullmatch(tail[1]):
                    inline.insert(0, tail[1])
                    name = tail[0].rstrip()
                    continue
                break
            scenarios.append(GherkinScenario(
                name=name, keyword=m.group("kw"), line=i,
                tags=tuple(pending) + tuple(inline)))
            pending = []
            continue
        pending = []                   # any other content ends the run
    return title, tuple(scenarios), ftags


def index_gherkin(generator_dir: str) -> GherkinIndex:
    """Every ``*.feature`` under tests/e2e/features, recursively, in path order."""
    root = os.path.join(generator_dir, FEATURES_DIR)
    idx = GherkinIndex(root=root)
    if not os.path.isdir(root):
        idx.error = GHERKIN_ABSENT_REASON
        return idx
    found: list[GherkinFeature] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for fn in sorted(filenames):
            if not fn.endswith(".feature"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, generator_dir)
            try:
                with open(full, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError as e:
                # A feature we could not READ is still a feature. Dropping it would
                # under-report the suite; showing it with the read error is honest.
                found.append(GherkinFeature(path=full, rel=rel, title=fn,
                                            error=f"could not read: {e}"))
                continue
            title, scenarios, tags = parse_gherkin(text)
            found.append(GherkinFeature(path=full, rel=rel, title=title or fn,
                                        scenarios=scenarios, tags=tags))
    idx.features = tuple(found)
    if not idx.features:
        idx.error = GHERKIN_EMPTY_REASON
    return idx


# ── which personas a spec draws from ────────────────────────────────────────────

# Boundaries wider than :func:`_token_re`'s, because a persona handle is not a slug:
# it can carry '-', '@' and '.', and `e2e-pending` occurs INSIDE `rbac-pending` only
# if '-' is treated as a boundary. Excluding all four keeps `e2e-user` from matching
# `e2e-user-2` and `admin` from matching `admin@x`.
def _persona_re(handle: str) -> re.Pattern:
    return re.compile(r"(?<![A-Za-z0-9@._-])" + re.escape(handle)
                      + r"(?![A-Za-z0-9@._-])")


def spec_personas(generator_dir: str, roster: Roster | None = None,
                  sources: dict[str, str] | None = None) -> dict[str, tuple[str, ...]]:
    """``{spec filename: (persona usernames it names, ...)}``.

    The tree must answer "who does this feature log in AS?" — that is the operator's
    "the table of users that they draw from". The answer is derived the same way
    :func:`service_coverage` derives its own: over COMMENT-STRIPPED spec source (house
    rule; a persona named only in a comment is not a persona this spec drives), using
    the roster parsed by core.seeded_credentials rather than a second name list.

    HONEST LIMIT, and the surface must repeat it: this is a textual reference, not a
    login trace. A spec that builds a handle at runtime, or reaches a persona through
    a helper that names it, is not seen here. It under-reports; it does not invent.
    """
    r = load_roster(generator_dir) if roster is None else roster
    raw = _spec_sources(generator_dir) if sources is None else sources
    src = {fn: _strip_ts_comments(text) for fn, text in raw.items()}
    pats = [(u.username, _persona_re(u.username)) for u in r.users]
    out: dict[str, tuple[str, ...]] = {}
    for fn, text in src.items():
        out[fn] = tuple(name for name, pat in pats if pat.search(text))
    return out


# ── resolving a node back to a file the operator can read and edit ──────────────

def spec_path(generator_dir: str, spec_file: str) -> str:
    """Absolute path of a spec FILE as Playwright named it.

    Playwright reports ``file`` relative to ``testDir`` (./specs), but has reported
    both spellings across versions, so a value that ALREADY starts with the specs
    directory is not prefixed twice.
    """
    rel = spec_file.replace("\\", "/").lstrip("/")
    if rel.startswith("specs/"):
        return os.path.join(generator_dir, E2E_DIR, *rel.split("/"))
    return os.path.join(generator_dir, SPECS_DIR, *rel.split("/"))


def is_readonly_source(path: str) -> bool:
    """True for a path the Studio must never write to — see STACK_SRC_DIR."""
    parts = os.path.normpath(path).replace("\\", "/").split("/")
    return STACK_SRC_DIR in parts


# ── the run selection, on its way to argv ───────────────────────────────────────

# What may be handed to `make stack-e2e E2E_SPECS=...`. The Makefile expands that
# variable inside a /bin/sh recipe, so a value is one unquoted shell word: anything
# outside this class could inject. The list comes from Playwright, not from a text
# box, which is exactly why the check belongs HERE and not at the widget — a model
# that only validates what a widget happened to produce validates nothing.
SPEC_ARG_RE = re.compile(r"^specs/[A-Za-z0-9][A-Za-z0-9._/-]*\.ts$")
SPEC_ARG_REJECT_REASON = (
    "not a plain tests/e2e/specs/*.ts path — refused rather than passed to the "
    "shell that runs the suite.")


def spec_run_arg(spec_file: str) -> str:
    """The positional filter Playwright takes for one spec FILE, cwd tests/e2e."""
    rel = spec_file.replace("\\", "/").lstrip("/")
    return rel if rel.startswith("specs/") else "specs/" + rel


def safe_spec_args(paths: Sequence[str]) -> tuple[tuple[str, ...], tuple[str, ...]]:
    """``(accepted, rejected)`` — de-duplicated, sorted, and shell-safe.

    Rejects are RETURNED, not dropped: a surface that silently discards half a
    selection and then runs is the checked-nothing pass this whole unit exists to prevent.
    """
    ok: list[str] = []
    bad: list[str] = []
    for p in paths:
        arg = spec_run_arg(str(p).strip())
        if SPEC_ARG_RE.match(arg):
            ok.append(arg)
        elif p:
            bad.append(str(p))
    return tuple(sorted(set(ok))), tuple(sorted(set(bad)))


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
    #: The .feature files, or a NAMED reason there are none (see :func:`index_gherkin`).
    gherkin: GherkinIndex = field(default_factory=GherkinIndex)
    #: ``{spec filename: (persona usernames it names, ...)}`` — see :func:`spec_personas`.
    personas_by_spec: dict[str, tuple[str, ...]] = field(default_factory=dict)
    #: Screenshots whose filename number matches no spec file. They belong to nobody,
    #: and a tree that only hangs shots off features would drop them silently.
    orphan_screenshots: tuple[Screenshot, ...] = ()
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

    def personas_of(self, spec_file: str) -> tuple[str, ...]:
        """The personas one spec FILE names. Keyed on the basename because
        Playwright has reported ``file`` both bare and specs/-prefixed."""
        return self.personas_by_spec.get(os.path.basename(spec_file), ())


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
    Quietly transplanting the old verdict onto the new title would show a verdict for a
    test under a name that never ran; dropping the orphan would lose a real verdict the
    run recorded, with nothing saying it had been dropped.

    MEASURED 2026-08-26, merging that run's report.json onto today's real ``--list``:
    221 listed + 3 orphans = 224 rows, of which 38 are failed and 3 are not-run. (An
    earlier version of this docstring said "76 failures, 73 rows". A review could not
    reproduce either number and neither could I: 76 is summary.json's RESULT count —
    38 failures x 2 attempts, see :class:`RunSummary` — and 73 matches no artefact.)
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
    shots = index_screenshots(generator_dir)
    cat.features = build_features(tests, shots)
    # Any bucket no feature claimed. Screenshot numbers that match no spec file (and
    # the un-numbered "" bucket) would otherwise be invisible, which is how a flat
    # tracked directory of 38 PNGs stops being looked at.
    claimed = {f.number for f in cat.features}
    cat.orphan_screenshots = tuple(
        sh for num, group in sorted(shots.items()) if num not in claimed
        for sh in group)

    cat.roster = load_roster(generator_dir, env)
    if cat.roster.error:
        cat.problems.append(cat.roster.error)
    cat.gated = gated_personas(generator_dir, cat.roster)
    if not cat.gated:
        cat.problems.append(
            f"could not read SEED_REGISTRATION_SKIP from {GATED_SCRIPT} — the "
            "deliberately-gated personas cannot be marked, and someone will 'fix' them.")

    cat.gherkin = index_gherkin(generator_dir)
    if cat.gherkin.error:
        cat.problems.append(cat.gherkin.error)
    cat.personas_by_spec = spec_personas(generator_dir, cat.roster)

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
