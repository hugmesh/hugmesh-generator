"""The e2e catalogue model — the tree that replaces the single "Run e2e suite" button.

WHAT THESE TESTS ARE FOR. The button was honest by accident: it ran everything and
went one colour. A TREE can lie in ways a button cannot — a node with a green Run
button that runs nothing, a grey row that will not say why it is grey, a persona shown
as broken that is gated on purpose. Every test below pins one of those.

Two layers, on purpose:
  * PARSE-LEVEL, against RECORDED fixtures in fixtures/e2e-catalogue/ (a trimmed
    report.json + summary.json from the real run of 2026-08-22, and a trimmed
    `--list --reporter=json` payload recorded 2026-08-26). These run anywhere.
  * CONTRACT-LEVEL, shelling out to the REAL `npx playwright test --list` in this
    checkout. A stub-only suite proves the parser and NOT the contract: the whole
    anti-restatement claim of this module is that the spec list comes from Playwright,
    and only running Playwright tests that. It SKIPS LOUDLY, with the named reason,
    when tests/e2e/node_modules is absent.

The Qt half does not exist yet; this file is Qt-free and runs in the system-python
lane, with the repo's fresh-interpreter import guard at the bottom.
"""
import json
import os
import shutil
import subprocess

import pytest

from hugmesh_studio.core import e2e_catalogue as ec
from hugmesh_studio.core.e2e_catalogue import (
    LINK_FILENAME_PREFIX, LINK_TEST, STATUS_FAILED, STATUS_NOT_RUN, STATUS_PASSED,
    STATUS_SKIPPED, UNKNOWN_SKIP_REASON, Catalogue, E2ETest, build_features,
    find_last_run, gated_personas, index_screenshots, list_specs, load_catalogue,
    load_last_run, parse_playwright_json, parse_summary, parse_tags, service_coverage,
    skip_reason_of, uncovered_services,
)

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "fixtures", "e2e-catalogue")


def _fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as fh:
        return json.load(fh)


def _fixture_text(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as fh:
        return fh.read()


def _stub_runner(stdout, returncode=0, stderr=""):
    """Stand in for subprocess.run so the parse tests never need Node."""
    def run(argv, **kwargs):
        run.calls.append((tuple(argv), kwargs))
        return subprocess.CompletedProcess(argv, returncode, stdout, stderr)
    run.calls = []
    return run


@pytest.fixture
def neutral_dir(tmp_path_factory):
    """A tmp dir whose PATH carries none of the tokens the assertions search for.

    The plain ``tmp_path`` fixture names the directory after the TEST (truncated to 30
    chars), so a test called ``test_no_node_modules_...`` gets
    ``.../test_no_node_modules_still_yie0`` — and every problem string this module
    builds embeds that path, which makes a substring assertion pass with the
    production guard deleted. ``tmp_path_factory.mktemp`` takes the name from us
    instead, so nothing the test is named can satisfy a content assertion. Measured
    2026-08-26; see test_no_node_modules_still_yields_the_last_runs_tests.
    """
    return tmp_path_factory.mktemp("co")


def _e2e_tree(tmp_path, list_payload=None, run_payload=None, summary=None):
    """A throwaway checkout shaped like the real one, so list_specs' node_modules
    precondition and find_last_run's directory walk are exercised for real."""
    e2e = tmp_path / "tests" / "e2e"
    (e2e / "node_modules").mkdir(parents=True)
    (e2e / "specs").mkdir()
    (e2e / "screenshots").mkdir()
    if run_payload is not None:
        d = e2e / "test-results" / "studio-20260822-193645"
        d.mkdir(parents=True)
        (d / "report.json").write_text(json.dumps(run_payload))
        if summary is not None:
            (d / "summary.json").write_text(json.dumps(summary))
    return str(tmp_path)


# ── the spec list is PARSED, never restated ──────────────────────────────────

def test_list_specs_returns_exactly_what_playwright_reported(tmp_path):
    """THE anti-restatement pin. Whatever `--list` says is the tree — no more, no
    less. A hardcoded spec list inside the module fails here on the count alone."""
    payload = {"suites": [{"title": "aa.spec.ts", "file": "aa.spec.ts",
                           "specs": [{"title": "one", "id": "i1", "line": 3,
                                      "tests": [{"results": []}]}]}]}
    runner = _stub_runner(json.dumps(payload))
    got = list_specs(_e2e_tree(tmp_path), runner=runner)
    assert got.error == "", got.error
    assert [t.title for t in got.tests] == ["one"]
    assert got.tests[0].spec_file == "aa.spec.ts"


def test_list_specs_runs_playwright_in_tests_e2e_with_the_json_reporter(tmp_path):
    # --reporter=json is not cosmetic: it OVERRIDES the config's reporter list, which
    # contains the custom hugmesh reporter. That reporter WRITES summary.json, so
    # enumerating with the config's reporters would overwrite the last run's results
    # this module is about to read.
    runner = _stub_runner('{"suites": []}')
    root = _e2e_tree(tmp_path)
    list_specs(root, runner=runner)
    argv, kwargs = runner.calls[0]
    assert argv == ec.LIST_ARGV
    assert "--list" in argv and "--reporter=json" in argv
    assert kwargs["cwd"] == os.path.join(root, "tests", "e2e")


def test_list_walks_nested_describe_suites(tmp_path):
    # Playwright nests describe() blocks. A flat read of suites[i].specs would miss
    # most of this suite (33 files, 221 specs, nearly all inside a describe).
    payload = {"suites": [{"title": "a.spec.ts", "file": "a.spec.ts", "specs": [],
                           "suites": [{"title": "outer", "suites": [
                               {"title": "inner", "specs": [
                                   {"title": "deep", "file": "a.spec.ts",
                                    "tests": [{"results": []}]}]}]}]}]}
    got = list_specs(_e2e_tree(tmp_path), runner=_stub_runner(json.dumps(payload)))
    assert [t.title for t in got.tests] == ["deep"]
    assert got.tests[0].title_path == ("a.spec.ts", "outer", "inner", "deep")


def test_recorded_list_fixture_parses_to_its_specs():
    payload = _fixture("list.json")
    tests = parse_playwright_json(payload, ran=False)
    assert len(tests) == 10
    assert {t.spec_file for t in tests} == {
        "01-frontpage.spec.ts", "12-rbac-gateway-route-access.spec.ts",
        "14-rbac-gateway-live.spec.ts", "18-rbac-phase8-10-pending.spec.ts",
        "23-domainlock-mod-ban-interaction.spec.ts"}


def test_the_list_path_yields_no_verdict_even_if_the_payload_carries_results(tmp_path):
    """Belt and braces on the list/run split, and NOT a hypothetical: today's --list
    emits ``results: []``, so a `ran=True` slip in list_specs is invisible — it only
    turns into a fully-grey tree the day Playwright starts emitting a stale result
    there. The listing path must refuse to read a status FROM THE PAYLOAD, not merely
    happen not to find one.

    (Found by mutation-testing this module 2026-08-26: flipping list_specs to
    ran=True survived the whole suite until this test existed.)"""
    payload = {"suites": [{"title": "a.spec.ts", "file": "a.spec.ts", "specs": [
        {"title": "t", "file": "a.spec.ts", "tests": [{"results": [
            {"status": "failed", "duration": 99}]}]}]}]}
    got = list_specs(_e2e_tree(tmp_path), runner=_stub_runner(json.dumps(payload)))
    assert [t.status for t in got.tests] == [STATUS_NOT_RUN]
    assert got.tests[0].duration_ms == 0
    assert got.tests[0].screenshots == ()


def test_list_output_never_yields_a_status(tmp_path):
    """--list marks EVERY test "skipped", meaning NOT RUN. Reading that as a status
    would paint the whole tree grey with 221 unexplained skips — the exact failure
    this model exists to prevent."""
    tests = parse_playwright_json(_fixture("list.json"), ran=False)
    assert {t.status for t in tests} == {STATUS_NOT_RUN}
    assert not any(t.ran for t in tests)
    assert all(t.skip_reason == "" for t in tests)
    # and the raw payload really does say "skipped" everywhere, so this is not vacuous
    raw = _fixture_text("list.json")
    assert '"status": "skipped"' in raw


# ── failure paths are NAMED, never silent ────────────────────────────────────

def test_missing_node_modules_is_a_named_error_not_an_empty_tree(neutral_dir):
    # neutral_dir, not tmp_path: this test's NAME contains "node_modules", pytest
    # derives tmp_path from the name, and the error string embeds the path — so
    # asserting `"node_modules" in got.error` from inside tmp_path itself is satisfied
    # by the path alone. See the fixture's docstring; measured 2026-08-26.
    root = neutral_dir
    (root / "tests" / "e2e").mkdir(parents=True)
    got = list_specs(str(root))
    assert got.tests == []
    assert "node_modules" not in str(root), "the fixture must not supply the token"
    assert "node_modules" in got.error and "npm ci" in got.error


def test_playwright_compile_failure_carries_its_stderr(tmp_path):
    runner = _stub_runner("", returncode=1, stderr="specs/28-x.spec.ts:41 TS2339")
    got = list_specs(_e2e_tree(tmp_path), runner=runner)
    assert "TS2339" in got.error and "exited 1" in got.error


def test_unparseable_list_json_is_reported(tmp_path):
    got = list_specs(_e2e_tree(tmp_path), runner=_stub_runner("not json"))
    assert "could not parse" in got.error


def test_valid_json_with_no_specs_is_reported_not_accepted(tmp_path):
    got = list_specs(_e2e_tree(tmp_path), runner=_stub_runner('{"suites": []}'))
    assert got.tests == []
    assert "no specs" in got.error


def test_missing_npx_is_named(tmp_path, monkeypatch):
    def boom(*a, **k):
        raise FileNotFoundError("npx")
    got = list_specs(_e2e_tree(tmp_path), runner=boom)
    assert "npx not found" in got.error


def test_list_timeout_is_named(tmp_path):
    def boom(*a, **k):
        raise subprocess.TimeoutExpired(cmd="npx", timeout=7)
    got = list_specs(_e2e_tree(tmp_path), runner=boom, timeout=7)
    assert "did not finish within 7s" in got.error


# ── the last run merges in ───────────────────────────────────────────────────

def test_recorded_run_fixture_yields_real_statuses():
    run = parse_playwright_json(_fixture("report.json"), ran=True)
    statuses = {}
    for t in run:
        statuses[t.status] = statuses.get(t.status, 0) + 1
    assert statuses == {STATUS_FAILED: 1, STATUS_PASSED: 2, STATUS_SKIPPED: 7}


def test_the_retry_is_the_verdict_not_the_first_attempt():
    # retries: 1 in playwright.config.ts, so a test can carry two results. Reading the
    # FIRST would report a flake that later passed as a failure.
    spec = {"title": "t", "file": "a.spec.ts",
            "tests": [{"results": [{"status": "failed", "duration": 1},
                                   {"status": "passed", "duration": 2}]}]}
    payload = {"suites": [{"title": "a.spec.ts", "file": "a.spec.ts", "specs": [spec]}]}
    got = parse_playwright_json(payload, ran=True)
    assert [(t.status, t.duration_ms) for t in got] == [(STATUS_PASSED, 2)]


def test_find_last_run_picks_the_newest_report(tmp_path):
    base = tmp_path / "tests" / "e2e" / "test-results"
    for name in ("studio-20260814-120248", "fix-verify"):
        (base / name).mkdir(parents=True)
        (base / name / "report.json").write_text("{}")
    os.utime(base / "fix-verify" / "report.json", (2_000_000_000, 2_000_000_000))
    # Newest by MTIME, not by name: `fix-verify` and `studio-<stamp>` are not sortable
    # against each other, and the runner writes both shapes.
    assert find_last_run(str(tmp_path)) == str(base / "fix-verify")


def test_find_last_run_also_sees_the_flat_legacy_layout(tmp_path):
    base = tmp_path / "tests" / "e2e" / "test-results"
    base.mkdir(parents=True)
    (base / "report.json").write_text("{}")
    assert find_last_run(str(tmp_path)) == str(base)


def test_no_run_is_a_named_absence_not_a_crash(tmp_path):
    run = load_last_run(str(tmp_path))
    assert run.tests == [] and bool(run) is False
    assert "no run found" in run.error


def test_run_verdicts_overlay_the_enumerated_suite(tmp_path):
    root = _e2e_tree(tmp_path, run_payload=_fixture("report.json"),
                     summary=_fixture("summary.json"))
    cat = load_catalogue(root, runner=_stub_runner(_fixture_text("list.json")))
    assert cat.listing.error == ""
    by_title = {t.title: t for t in cat.tests}
    # every listed test is accounted for, and the ones the run covered carry verdicts
    assert len(cat.tests) == 10
    assert {t.status for t in cat.tests} == {STATUS_FAILED, STATUS_PASSED, STATUS_SKIPPED}
    assert by_title["front page loads over generated certs and gates anonymous "
                    "visitors to native sign-in"].status == STATUS_FAILED


def test_a_renamed_test_is_reported_twice_never_given_a_stale_verdict(tmp_path):
    """Measured on the real artefacts: three spec-25 tests were retitled between the
    2026-08-22 run and 2026-08-26, and Playwright's spec `id` (a hash over file+title)
    drifted with the title, so NO key survives a rename. The honest answer is two rows
    — the new title not-run, the old one an orphan — not a verdict shown under a name
    that never ran."""
    listed = [E2ETest(spec_file="a.spec.ts", title="new", title_path=("a.spec.ts", "new"))]
    ran = [E2ETest(spec_file="a.spec.ts", title="old", title_path=("a.spec.ts", "old"),
                   status=STATUS_FAILED)]
    merged = ec._merge_run(listed, ran)
    assert {(t.title, t.status) for t in merged} == {
        ("new", STATUS_NOT_RUN), ("old", STATUS_FAILED)}


def test_a_feature_node_counts_its_own_rows_by_status():
    """Feature.counts() is what a tree node renders beside its name ("2 passed, 1
    failed"). ADDED AFTER A BATTERY MISS, 2026-08-26: a mutation that doubled every
    count left the whole suite green, because no test asserted a number this method
    produces — only the derived unexplained_skips was pinned. A node that overstates
    its own rows is the same lie as a green Run button that runs nothing."""
    features = build_features(parse_playwright_json(_fixture("report.json"), ran=True))
    by_file = {f.file: f for f in features}
    assert by_file["01-frontpage.spec.ts"].counts() == {
        STATUS_PASSED: 0, STATUS_FAILED: 1, STATUS_SKIPPED: 0, STATUS_NOT_RUN: 0}
    assert by_file["12-rbac-gateway-route-access.spec.ts"].counts() == {
        STATUS_PASSED: 2, STATUS_FAILED: 0, STATUS_SKIPPED: 0, STATUS_NOT_RUN: 0}
    assert by_file["18-rbac-phase8-10-pending.spec.ts"].counts() == {
        STATUS_PASSED: 0, STATUS_FAILED: 0, STATUS_SKIPPED: 3, STATUS_NOT_RUN: 0}
    # and every node's counts sum to the rows it actually holds — no double-count
    for f in features:
        assert sum(f.counts().values()) == len(f.tests), f.file


def test_summary_json_parses_in_the_shape_the_reporter_actually_writes():
    # Recorded verbatim from the run of 2026-08-22 — the pin against the custom
    # reporter (reporters/hugmesh-reporter.ts onEnd) changing shape under us.
    #
    # The fields are named *_results on purpose: hugmesh-reporter.ts counts in
    # onTestEnd(test, result), once per ATTEMPT, and retries: 1 is configured. These
    # 259 are ATTEMPTS over 221 tests; the 76 are 38 failed tests counted twice. A
    # review found the old names presenting them as test counts.
    s = parse_summary(_fixture("summary-20260822-full.json"))
    assert (s.passed_results, s.failed_results, s.skipped_results) == (121, 76, 62)
    assert s.total_results == 259
    assert s.tier == "LEAN" and s.result == "failed"
    assert {r["role"] for r in s.per_role} >= {"ROLE_ADMIN", "unknown"}
    assert {r["layer"] for r in s.per_layer} >= {"gateway", "ui"}


def test_the_summary_counts_ATTEMPTS_and_the_tree_counts_TESTS():
    """A review's MAJOR: summary.json and the tree disagree, and the model exposed
    both side by side with nothing reconciling them. A banner reading "76 failed /
    259 total" over a tree with 38 red rows is the reporter-vs-tree disagreement in
    front of the operator that parse_tags is written to avoid on the role pivot.

    MEASURED on the real artefacts of studio-20260822-193645: report.json holds 221
    tests, 38 of them failed; summary.json says 121/76/62 = 259 results. 76 = 38 x 2,
    because retries: 1 means every failure is counted again. Pinned here on a payload
    with exactly one retried failure, so the arithmetic is visible rather than
    asserted about a file this test cannot see."""
    payload = {"suites": [{"title": "a.spec.ts", "file": "a.spec.ts", "specs": [
        {"title": "flaky", "file": "a.spec.ts", "tests": [{"results": [
            {"status": "failed", "duration": 1}, {"status": "failed", "duration": 2}]}]},
        {"title": "clean", "file": "a.spec.ts", "tests": [{"results": [
            {"status": "passed", "duration": 3}]}]}]}]}
    run = ec.LastRun(tests=parse_playwright_json(payload, ran=True),
                     summary=parse_summary({"passed": 1, "failed": 2, "skipped": 0}))
    # the tree: TWO tests, ONE red row
    assert len(run.tests) == 2
    assert run.counts()[STATUS_FAILED] == 1
    # the reporter: THREE attempts, TWO of them failures — for the SAME run
    assert run.summary.total_results == 3
    assert run.summary.failed_results == 2
    # and the model states the gap instead of letting a surface trip over it
    assert run.retried_results == 1
    assert run.summary.total_results - len(run.tests) == run.retried_results


def test_retried_results_is_zero_when_there_is_no_summary_to_disagree_with():
    run = ec.LastRun(tests=[E2ETest(spec_file="a", title="t", title_path=("a", "t"))])
    assert run.summary is None
    assert run.retried_results == 0


def test_a_missing_summary_does_not_lose_the_per_test_verdicts(tmp_path):
    root = _e2e_tree(tmp_path, run_payload=_fixture("report.json"))  # no summary.json
    run = load_last_run(root)
    assert run.summary is None
    assert len(run.tests) == 10 and run.error == ""


# ── skip reasons: "unknown" must be said out loud ────────────────────────────

def test_a_skip_with_a_reason_keeps_it():
    run = parse_playwright_json(_fixture("report.json"), ran=True)
    live = [t for t in run if t.spec_file == "14-rbac-gateway-live.spec.ts"]
    assert live and all(t.status == STATUS_SKIPPED for t in live)
    for t in live:
        assert t.skip_reason_known is True
        assert "LIVE_GATEWAY=1" in t.skip_reason


def test_a_skip_with_no_reason_says_unknown_and_is_flagged():
    """14 of the 62 skips in the run of 2026-08-22 carried no annotation. A grey row
    that renders an empty cell reads as "fine"; this is the difference."""
    run = parse_playwright_json(_fixture("report.json"), ran=True)
    mystery = [t for t in run if t.spec_file == "18-rbac-phase8-10-pending.spec.ts"]
    assert mystery and all(t.status == STATUS_SKIPPED for t in mystery)
    for t in mystery:
        assert t.skip_reason_known is False
        assert t.skip_reason == UNKNOWN_SKIP_REASON
        assert t.skip_reason != ""              # never blank
        assert "unknown" in t.status_display


def test_an_annotation_with_no_description_is_not_a_reason():
    # bare `test.skip()` produces an annotation whose description is absent. Taking
    # its empty string as an explanation is exactly how a mystery skip renders as a
    # confident blank cell.
    reason, known = skip_reason_of({"annotations": [{"type": "skip"}]},
                                   {"annotations": [{"type": "skip", "description": ""}]})
    assert known is False and reason == UNKNOWN_SKIP_REASON


def test_a_static_annotation_on_the_test_node_still_counts():
    # `--list` alone already knows 52 skip + 6 fixme reasons with no run at all,
    # because describe-level test.skip() lands statically on the test node.
    reason, known = skip_reason_of(
        {"annotations": [{"type": "fixme", "description": "pending: needs a real gateway"}]},
        None)
    assert known is True and "pending" in reason


def test_the_catalogue_counts_its_own_unexplained_skips(tmp_path):
    root = _e2e_tree(tmp_path, run_payload=_fixture("report.json"))
    cat = load_catalogue(root, runner=_stub_runner(_fixture_text("list.json")))
    assert len(cat.unexplained_skips) == 3          # the three spec-18 rows
    assert any("no machine-readable reason" in p for p in cat.problems)
    feature = next(f for f in cat.features if f.file == "18-rbac-phase8-10-pending.spec.ts")
    assert feature.unexplained_skips == 3


# ── service coverage: an uncovered service must never look covered ───────────

def test_the_named_zero_coverage_services_are_reported_uncovered():
    """A tree node with a green Run button that runs nothing is worse than the button
    it replaces. These four are the ones the operator asked about by name."""
    cov = {c.slug: c for c in service_coverage(GENERATOR_DIR)}
    for slug in ("owncast", "tube", "wiki", "character-studio"):
        assert cov[slug].covered is False, f"{slug} looks covered"
        assert cov[slug].needs_a_test is True
        assert cov[slug].spec_files == ()
        assert "NO spec names this service" in cov[slug].reason
    named = {c.slug for c in uncovered_services(service_coverage(GENERATOR_DIR))}
    assert {"owncast", "tube", "wiki", "character-studio"} <= named


def test_services_the_suite_really_does_exercise_are_reported_covered():
    # The other half of the guard: a coverage warning that cries wolf is one an
    # operator learns to ignore, which would take the real gaps down with it.
    cov = {c.slug: c for c in service_coverage(GENERATOR_DIR)}
    for slug in ("tuwunel", "akkoma", "games", "character-forge"):
        assert cov[slug].covered is True, f"{slug} looks uncovered"
        assert cov[slug].needs_a_test is False
        assert cov[slug].spec_files


def test_coverage_scans_specs_with_comments_stripped():
    """HOUSE RULE: a comment naming a token must never make a zero-coverage service
    read as covered. owncast has NO specs at all, so every case here must be False."""
    only_a_comment = {"a.spec.ts": "// this file is about owncast\nconst x = 1;\n",
                      "b.spec.ts": "/* owncast\n   lives here */\n"}
    cov = {c.slug: c for c in service_coverage(GENERATOR_DIR, sources=only_a_comment)}
    assert cov["owncast"].covered is False
    assert cov["owncast"].spec_files == ()


def test_a_TRAILING_comment_is_stripped_too_not_only_a_leading_one():
    """A REVIEW CAUGHT THE STRIPPER HALF-DONE, 2026-08-26. _LINE_COMMENT_RE was
    anchored to line start, so `const x = 1;   // owncast` survived stripping and
    reported owncast — a service with ZERO specs — as COVERED, with a spec_files list
    naming the file. That is precisely the green Run button that runs nothing this
    module exists to refuse, and the committed guard exercised only the LEADING form,
    so it could not see it in either direction."""
    trailing = {"a.spec.ts": "const x = 1;   // this file is about owncast\n"}
    cov = {c.slug: c for c in service_coverage(GENERATOR_DIR, sources=trailing)}
    assert cov["owncast"].covered is False, "a trailing // comment is still a comment"
    assert cov["owncast"].spec_files == ()
    # ...and a URL is NOT a comment: stripping from the `//` of https:// would delete
    # the rest of a real line of code, taking any service named in it with it.
    url = {"a.spec.ts": "await page.goto('https://gw/social/forum/threads');\n"}
    assert {c.slug: c for c in service_coverage(
        GENERATOR_DIR, sources=url)}["phpbb"].covered is True


def test_coverage_tokens_break_on_UNDERSCORE_which_is_the_whole_point():
    """THE \\b DISCRIMINATOR, and the one the old test did NOT provide.

    `_` is a word char, so \\b does not break on it; it is not alnum, so _token_re's
    lookarounds do. That single character is the ENTIRE difference between the two
    forms, and it is load-bearing: the suite reaches the forum and the games realm
    through SCREAMING_SNAKE role constants. Measured 2026-08-26 — swapping _token_re
    to \\b takes phpbb from 2 files to 0 (UNCOVERED) and games from 11 to 10."""
    sources = {"a.spec.ts": "roles: ['ROLE_FORUM', 'ROLE_GAMES_ADMIN'],\n"}
    cov = {c.slug: c for c in service_coverage(GENERATOR_DIR, sources=sources)}
    assert cov["phpbb"].covered is True, "`forum` must match inside ROLE_FORUM"
    assert cov["games"].covered is True, "`games` must match inside ROLE_GAMES_ADMIN"


def test_coverage_tokens_do_not_match_inside_longer_words():
    """Sub-word matches are refused. NOTE, corrected after review: this is NOT what
    separates _token_re from \\b — measured, `re.search(r"\\btube\\b", "youtubeUrl")` is
    None too, so \\b refuses these exactly as the lookarounds do. What this pins is
    that the search is not a bare `token in text`, which would match all three."""
    sources = {"a.spec.ts": "const youtubeUrl = selector('generator');\n"}
    cov = {c.slug: c for c in service_coverage(GENERATOR_DIR, sources=sources)}
    assert cov["tube"].covered is False
    assert cov["tor"].covered is False
    hit = {c.slug: c for c in service_coverage(
        GENERATOR_DIR, sources={"a.spec.ts": "await page.goto('/tube/channels');\n"})}
    assert hit["tube"].covered is True


def test_the_alias_map_is_what_makes_the_matrix_and_forum_specs_count():
    """SPEC_TOKENS is the module's ONE self-declared restatement — the thing most
    likely to drift — and a review found NOTHING protecting it: bypassing the map
    entirely (bare slug for every service) left the whole suite green, because the
    only coverage test asserted `covered is True` and tuwunel still matched 1 file.

    So this pins the map's EFFECT, measured 2026-08-26 over this checkout's
    comment-stripped specs. Bare-slug: tuwunel 19 -> 1, akkoma 19 -> 7, phpbb 2 -> 0.
    Correcting the record while I am here: only phpbb's VERDICT flips; tuwunel and
    akkoma stay 'covered' and merely lose their evidence, which the commit message
    originally got wrong."""
    cov = {c.slug: c for c in service_coverage(GENERATOR_DIR)}
    # the Matrix specs are tuwunel's coverage, and they never say "tuwunel"
    assert len(cov["tuwunel"].spec_files) > 10, cov["tuwunel"].spec_files
    assert "05-matrix-chat.spec.ts" in cov["tuwunel"].spec_files
    assert "31-matrix-group-chat.spec.ts" in cov["tuwunel"].spec_files
    # the Mastodon specs are akkoma's
    assert len(cov["akkoma"].spec_files) > 10, cov["akkoma"].spec_files
    assert "06-mastodon-post.spec.ts" in cov["akkoma"].spec_files
    # and phpbb is reached ONLY as ROLE_FORUM / /bff/forum/** — bare slug loses it
    assert cov["phpbb"].covered is True
    assert "26-rbac-cross-realm-matrix.spec.ts" in cov["phpbb"].spec_files


def test_the_alias_map_does_not_rescue_a_service_with_no_specs():
    """The other direction: tube/tor/edge-ai-tts/media-poisoner are searched under
    EVERY spelling the suite might use (peertube, onion, piper/tts, poisoner/cloak)
    and still match nothing. Their zero-coverage verdict is stronger for it."""
    cov = {c.slug: c for c in service_coverage(GENERATOR_DIR)}
    for slug in ("tube", "tor", "edge-ai-tts", "media-poisoner"):
        assert len(ec.SPEC_TOKENS[slug]) > 1, f"{slug} lost its aliases"
        assert cov[slug].covered is False, f"{slug} looks covered"


def test_a_kind_lane_service_is_unreachable_not_uncovered():
    # "nobody wrote a test" and "no test could exist in this lane" are different asks.
    # Merging them turns one into an excuse for the other.
    cov = {c.slug: c for c in service_coverage(GENERATOR_DIR)}
    argocd = cov["argocd"]
    assert argocd.reachable is False
    assert argocd.needs_a_test is False
    assert "kind-up" in argocd.reason
    assert argocd not in uncovered_services(service_coverage(GENERATOR_DIR))


def test_every_catalogued_local_service_gets_a_row():
    from hugmesh_studio.core import local_services
    # The catalogue is IMPORTED, so a service added there surfaces here as an
    # uncovered row on day one instead of being invisible until someone notices.
    assert {c.slug for c in service_coverage(GENERATOR_DIR)} == set(
        local_services.catalogue_slugs())


def test_uncovered_services_reach_the_catalogue_problem_list(tmp_path):
    # Only specs/ is copied (440K). The whole tests/stack tree is 49M and this
    # assertion needs none of it.
    root = _e2e_tree(tmp_path)
    shutil.copytree(os.path.join(GENERATOR_DIR, "tests", "e2e", "specs"),
                    os.path.join(root, "tests", "e2e", "specs"), dirs_exist_ok=True)
    cat = load_catalogue(root, runner=_stub_runner(_fixture_text("list.json")))
    problem = next(p for p in cat.problems if "NO e2e coverage" in p)
    for slug in ("owncast", "tube", "wiki", "character-studio"):
        assert slug in problem


# ── personas ─────────────────────────────────────────────────────────────────

def test_the_roster_is_the_seeded_credentials_parser_verbatim():
    # VERBATIM, asserted as object identity: there must be exactly one parser for the
    # persona roster in this repo. A second one here would drift the day a persona is
    # added to a shell source only one of them reads.
    from hugmesh_studio.core import seeded_credentials
    assert ec.load_roster is seeded_credentials.load_roster
    cat = Catalogue()
    cat.roster = ec.load_roster(GENERATOR_DIR)
    names = {u.username for u in cat.roster.users}
    # the 15 personas rbac-roles.ts omits are in here because load_roster reads all
    # three shell sources; a second parser in this module would be a second drift.
    assert {"e2e-admin", "e2e-superadmin", "e2e-fleet", "e2e-banned",
            "rbac-pending@gmail.com"} <= names
    assert len(names) > 30


def test_deliberately_gated_personas_are_marked_so_nobody_fixes_them():
    gated = {g.username: g for g in gated_personas(GENERATOR_DIR)}
    for u in ("e2e-pending", "rbac-pending-gmail-com", "e2e-banned"):
        assert u in gated, f"{u} is not marked as deliberately gated"
        assert "ON PURPOSE" in gated[u].reason
        assert "17/28/29" in gated[u].reason
        assert gated[u].source.endswith("seed-e2e.sh")


def test_the_email_shape_rule_is_modelled_not_just_the_name_list():
    """seed-e2e.sh gates by TWO mechanisms and says so: the SEED_REGISTRATION_SKIP
    list AND onboard_persona()'s `*@*` shape rule. That second rule is why the
    roster's `rbac-pending@gmail.com` and Casdoor's normalised
    `rbac-pending-gmail-com` are BOTH gated while only one spelling is on the list."""
    gated = {g.username: g for g in gated_personas(GENERATOR_DIR)}
    assert "rbac-pending-gmail-com" in gated          # the named list
    assert "rbac-pending@gmail.com" in gated          # the shape rule
    assert "`*@*`" in gated["rbac-pending@gmail.com"].reason


def test_the_catalogue_can_mark_a_roster_row_as_gated_on_purpose():
    """What the persona TABLE needs: a set it can test each row against, so the three
    deliberately-gated accounts render as "gated on purpose" rather than as three
    broken logins somebody helpfully repairs."""
    cat = Catalogue()
    cat.roster = ec.load_roster(GENERATOR_DIR)
    cat.gated = gated_personas(GENERATOR_DIR, cat.roster)
    marked = cat.gated_usernames()
    assert "e2e-pending" in marked and "e2e-banned" in marked
    assert "e2e-admin" not in marked          # an ordinary persona is NOT marked
    rows = [u for u in cat.roster.users if u.username in marked]
    assert rows, "no roster row lines up with the gated set"


def test_an_unreadable_seed_script_is_a_named_problem_not_a_quiet_empty_list(tmp_path):
    root = _e2e_tree(tmp_path)
    cat = load_catalogue(root, runner=_stub_runner(_fixture_text("list.json")))
    assert cat.gated == ()
    assert any("SEED_REGISTRATION_SKIP" in p for p in cat.problems)


# ── screenshots: model what exists, promise nothing more ─────────────────────

def test_narrative_screenshots_are_linked_by_filename_prefix_only():
    shots = index_screenshots(GENERATOR_DIR)
    assert "04" in shots, "the tracked screenshots/ tree moved"
    for s in shots["04"]:
        assert s.linkage == LINK_FILENAME_PREFIX
        # Nothing in tests/e2e/screenshots names a test, a persona or a step —
        # helpers.ts shot() takes a caller-chosen name and does not record any of it.
        assert s.persona == "" and s.step == ""
        # ...and they are overwritten in place, so they are NOT this run's output.
        assert s.from_last_run is False
        assert s.linked_to_a_test is False


def test_a_numberless_screenshot_is_kept_and_marked_unlinked(tmp_path):
    root = _e2e_tree(tmp_path)
    d = os.path.join(root, "tests", "e2e", "screenshots")
    open(os.path.join(d, "ad-hoc.png"), "wb").close()
    open(os.path.join(d, "07-discord-denied.png"), "wb").close()
    shots = index_screenshots(root)
    # a shot the tree drops is a shot nobody ever looks at again
    assert [s.name for s in shots[""]] == ["ad-hoc"]
    assert shots[""][0].linkage == ec.LINK_NONE
    assert shots["07"][0].linkage == LINK_FILENAME_PREFIX


def test_screenshots_hang_off_the_feature_whose_number_they_share():
    tests = parse_playwright_json(_fixture("list.json"), ran=False)
    features = build_features(tests, index_screenshots(GENERATOR_DIR))
    frontpage = next(f for f in features if f.number == "01")
    assert [s.name for s in frontpage.screenshots] == ["01-frontpage"]


def test_a_failure_screenshot_attached_by_playwright_is_linked_to_the_test():
    """The only genuinely per-test screenshot link that exists. `screenshot:
    'only-on-failure'` means these appear for failures ONLY, so their absence on a
    passing test says nothing at all."""
    run = parse_playwright_json(_fixture("report.json"), ran=True)
    failed = next(t for t in run if t.status == STATUS_FAILED)
    shots = [s for s in failed.screenshots if s.linkage == LINK_TEST]
    assert shots, "the per-test attachment link is gone"
    assert shots[0].from_last_run is True
    assert shots[0].linked_to_a_test is True
    assert shots[0].step == "" and shots[0].persona == ""   # still no per-step data


def test_non_image_attachments_are_not_shown_as_screenshots():
    # The recorded run attached 76 `error-context` markdown files and zero images.
    payload = {"suites": [{"title": "a.spec.ts", "file": "a.spec.ts", "specs": [
        {"title": "t", "file": "a.spec.ts", "tests": [{"results": [
            {"status": "failed", "attachments": [
                {"name": "error-context", "contentType": "text/markdown",
                 "path": "x.md"}]}]}]}]}]}
    got = parse_playwright_json(payload, ran=True)
    assert got[0].screenshots == ()


# ── tags mirror the reporter's own pivot ─────────────────────────────────────

def test_tags_mirror_report_tags_ts_parse_tags():
    # last occurrence wins; a missing tag becomes 'unknown' rather than being dropped
    # (specs/report-tags.ts parseTags). The tree and the reporter must bucket a test
    # identically or the two disagree in front of the operator.
    assert parse_tags(("f.spec.ts", "d @role:ROLE_USER", "t @role:ROLE_MOD @layer:bff")) \
        == ("ROLE_MOD", "bff")
    assert parse_tags(("f.spec.ts", "untagged")) == ("unknown", "unknown")


def test_real_tagged_titles_bucket_by_role_and_layer():
    tests = parse_playwright_json(_fixture("list.json"), ran=False)
    tagged = [t for t in tests if t.role != "unknown"]
    assert tagged, "the @role: tag convention vanished from the recorded specs"
    assert all(t.layer for t in tagged)


# ── "Never raises" has to survive a report.json that changed shape ───────────

# A review measured four structurally-wrong-but-VALID payloads escaping every handler
# and propagating out of load_catalogue, which documents itself as "Never raises" —
# the contract the future e2e page depends on to render "here is WHY the tree is
# empty". json.load's own ValueError was caught; a SHAPE change was not, and a shape
# change is the case this module explicitly anticipates ("the reporter has grown
# fields twice"). Each id below is one of the four, verbatim.
MALFORMED_REPORTS = {
    "suites-is-a-string": {"suites": "oops"},
    "duration-is-not-a-number": {"suites": [{"title": "a.spec.ts", "file": "a.spec.ts",
        "specs": [{"title": "t", "file": "a.spec.ts", "tests": [
            {"results": [{"status": "passed", "duration": "12ms"}]}]}]}]},
    "annotations-is-a-dict": {"suites": [{"title": "a.spec.ts", "file": "a.spec.ts",
        "specs": [{"title": "t", "file": "a.spec.ts", "tests": [
            {"annotations": {"type": "skip", "description": "why"},
             "results": [{"status": "skipped"}]}]}]}]},
    "attachments-is-a-string": {"suites": [{"title": "a.spec.ts", "file": "a.spec.ts",
        "specs": [{"title": "t", "file": "a.spec.ts", "tests": [
            {"results": [{"status": "failed", "attachments": "nope"}]}]}]}]},
}


@pytest.mark.parametrize("shape", sorted(MALFORMED_REPORTS))
def test_a_malformed_report_json_never_raises_out_of_load_catalogue(neutral_dir, shape):
    """All four of these used to propagate an AttributeError/ValueError straight
    through load_catalogue. Measured 2026-08-26."""
    root = neutral_dir
    d = root / "tests" / "e2e" / "test-results" / "r1"
    d.mkdir(parents=True)
    (d / "report.json").write_text(json.dumps(MALFORMED_REPORTS[shape]))
    cat = load_catalogue(str(root))            # must not raise
    assert isinstance(cat, Catalogue)
    assert cat.problems, "a degraded catalogue with no stated reason is the worst case"


def test_a_structurally_broken_suites_field_is_a_NAMED_problem_not_an_empty_tree(neutral_dir):
    """`"suites": "oops"` must not read as "this run had no tests" — a run that wrote
    a report.json definitely ran some. Same rule as list_specs' "no specs" branch."""
    root = neutral_dir
    d = root / "tests" / "e2e" / "test-results" / "r1"
    d.mkdir(parents=True)
    (d / "report.json").write_text(json.dumps({"suites": "oops"}))
    run = load_last_run(str(root))
    assert run.tests == []
    assert "report.json" in run.error and "no tests" in run.error


def test_junk_field_values_degrade_the_row_they_are_on_and_nothing_else(tmp_path):
    """The rows still render; only the junk field is lost. A reporter that grows a
    field must not be able to blank the tree."""
    got = parse_playwright_json(MALFORMED_REPORTS["duration-is-not-a-number"], ran=True)
    assert [(t.title, t.status, t.duration_ms) for t in got] == [("t", STATUS_PASSED, 0)]
    ann = parse_playwright_json(MALFORMED_REPORTS["annotations-is-a-dict"], ran=True)
    assert [(t.status, t.skip_reason_known) for t in ann] == [(STATUS_SKIPPED, False)]
    assert ann[0].skip_reason == UNKNOWN_SKIP_REASON     # never blank
    att = parse_playwright_json(MALFORMED_REPORTS["attachments-is-a-string"], ran=True)
    assert att[0].screenshots == ()


def test_a_parser_that_raises_is_caught_and_NAMED_by_both_callers(tmp_path, neutral_dir, monkeypatch):
    """Belt and braces over the isinstance guards above. The shape guards handle the
    four measured payloads; this pins that ANY future explosion in the parser still
    comes out as a named reason rather than up through load_catalogue."""
    def boom(payload, ran):
        raise RuntimeError("the reporter grew a third head")
    monkeypatch.setattr(ec, "parse_playwright_json", boom)

    root = neutral_dir
    d = root / "tests" / "e2e" / "test-results" / "r1"
    d.mkdir(parents=True)
    (d / "report.json").write_text(json.dumps(_fixture("report.json")))
    run = load_last_run(str(root))
    assert "third head" in run.error and "report.json" in run.error

    listing = list_specs(_e2e_tree(tmp_path), runner=_stub_runner('{"suites": []}'))
    assert "third head" in listing.error and "shape changed" in listing.error


# ── the whole catalogue degrades honestly ────────────────────────────────────

def test_no_node_modules_still_yields_the_last_runs_tests(neutral_dir):
    """A REVIEW CAUGHT THIS ONE GREEN AND VACUOUS, 2026-08-26. The old body asserted
    `any("node_modules" in p for p in cat.problems)` from a pytest tmp_path derived
    from this test's own name — `.../test_no_node_modules_still_yie0`, which CONTAINS
    the substring — and load_catalogue appends an unrelated roster problem that embeds
    that path. Deleting the guard entirely (`if False:` around the problems.append)
    left it PASSING. It is the house rule about a token appearing in incidental text,
    committed as a test.

    Two things fix it and both are kept: the tmp dir comes from the neutral_dir
    fixture, and the assertion is identity against the listing's OWN error rather than
    a substring hunt."""
    root = neutral_dir
    (root / "tests" / "e2e").mkdir(parents=True)
    d = root / "tests" / "e2e" / "test-results" / "r1"
    d.mkdir(parents=True)
    (d / "report.json").write_text(json.dumps(_fixture("report.json")))
    cat = load_catalogue(str(root))
    assert "node_modules" not in str(root), "the fixture must not supply the token"
    assert cat.listing.error, "no named reason for the empty listing"
    assert cat.listing.error in cat.problems     # the reason REACHED the problem list
    assert any("npm ci" in p for p in cat.problems)
    assert len(cat.tests) == 10           # the run alone still populates the tree
    assert cat.services                   # and the service/persona halves still work


def test_an_empty_checkout_never_raises(tmp_path):
    cat = load_catalogue(str(tmp_path))
    assert bool(cat) is False
    assert cat.problems, "an empty catalogue with no stated reason is the worst case"


# ── the CONTRACT: the real `--list`, or a LOUD skip ──────────────────────────

def test_the_real_playwright_list_enumerates_this_checkouts_specs():
    """A stub-only suite proves the parser and NOT the contract. The whole
    anti-restatement claim of this module is that the spec list comes from
    Playwright's own --list, and only running it tests that.

    Verified 2026-08-26: this works OFFLINE with the stack DOWN — --list compiles the
    specs and walks the registry without launching a browser or touching the network
    — in ~0.3s, exit 0, 221 specs across 33 files.
    """
    e2e = os.path.join(GENERATOR_DIR, "tests", "e2e")
    if not os.path.isdir(os.path.join(e2e, "node_modules")):
        pytest.skip(f"tests/e2e/node_modules is absent — run `npm ci` in {e2e} to "
                    "exercise the real `npx playwright test --list` contract "
                    "(this test is the ONLY one that proves the spec list is parsed "
                    "rather than restated)")
    if shutil.which("npx") is None:
        pytest.skip("npx is not on PATH — Node.js is required to run the real "
                    "`playwright test --list` contract test")
    got = list_specs(GENERATOR_DIR)
    assert got.error == "", got.error
    # Deliberately NOT pinned to 221: pinning the count would make every new spec a
    # test failure, which is the pressure that produces a hardcoded list. What is
    # pinned is that the number is LARGE and comes from Playwright.
    assert len(got.tests) > 150, f"only {len(got.tests)} specs — did --list break?"
    files = {t.spec_file for t in got.tests}
    assert len(files) > 25
    assert "01-frontpage.spec.ts" in files
    assert all(t.status == STATUS_NOT_RUN for t in got.tests)
    # and the tree really is built from it
    features = build_features(got.tests, index_screenshots(GENERATOR_DIR))
    assert len(features) == len(files)


def test_module_imports_no_qt():
    # Qt-free by contract, proven in a FRESH interpreter (this suite may import Qt
    # elsewhere, which would make an in-process check vacuous).
    import sys
    studio_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    probe = (
        "import hugmesh_studio.core.e2e_catalogue as m, sys;"
        "assert callable(m.load_catalogue);"
        "bad=[x for x in sys.modules if x.startswith(('PySide6','PyQt6','PyQt5'))];"
        "assert not bad, bad;"
        "assert 'hugmesh_studio.gui' not in sys.modules"
    )
    env = dict(os.environ, PYTHONPATH=studio_root)
    r = subprocess.run([sys.executable, "-c", probe], env=env,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
