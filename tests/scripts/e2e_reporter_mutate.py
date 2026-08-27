#!/usr/bin/env python3
"""e2e_reporter_mutate.py — the negative controls for the e2e reporter guard.

    python3 e2e_reporter_mutate.py --list
    python3 e2e_reporter_mutate.py --apply <name> <copy-of-hugmesh-reporter.ts>

Each entry BREAKS the reporter in a way that would matter, in a COPY of the file
(tests/scripts/test-e2e-reporter-shape.sh makes the copy; nothing here ever
writes to tests/e2e). The guard then replays the same fixtures through the broken
reporter and REQUIRES the checks to go red. A control that survives is reported
by name — a guard whose negative controls are not themselves checked is the
disease this repo keeps relapsing into.

`caught_by` is DECLARED, not discovered: "schema" means the shape check must
catch it, "check" means the content check must. A mutation caught only by the
other one, or only by the reporter crashing, is a finding about the guard and is
printed as such.

An `old` string that no longer occurs is a hard error. A mutation that silently
patched nothing would leave the guard testing the pristine file and calling it a
control.
"""

from __future__ import annotations

import sys


def comment_mask(text: str) -> list[bool]:
    """True for every character that is inside a // or /* */ comment.

    COMMENT-TOKEN INVERSION is the defect this repo keeps relapsing into: an
    assertion greps for a token, the token is present only in a COMMENT, and the
    check passes over production that no longer contains it. The mutation side of
    that same coin is an anchor that matches a comment: `--apply` rewrites the
    comment, the file genuinely changes, `cmp` is satisfied, and the control has
    stopped controlling anything while still looking applied. The scanner is
    string-literal aware (', ", `, escapes) so that a `//` inside a string is not
    mistaken for the start of a comment.
    """
    mask = [False] * len(text)
    i, n = 0, len(text)
    quote = ""
    while i < n:
        c = text[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = ""
            i += 1
            continue
        if c in ("'", '"', "`"):
            quote = c
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                mask[k] = True
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                mask[k] = True
            i = j
            continue
        i += 1
    return mask


def anchor_hits_code(text: str, mask: list[bool], start: int, length: int) -> bool:
    """Does this anchor occurrence touch at least one character of real CODE?"""
    return any(not mask[k] and not text[k].isspace()
               for k in range(start, min(start + length, len(text))))

# name -> (what it simulates, caught_by, [(old, new), ...])
MUTATIONS: dict[str, tuple[str, str, list[tuple[str, str]]]] = {
    "drop-per-spec": (
        "the per-spec-file pivot is gone again - the exact defect this unit fixed",
        "schema",
        [("      perSpec,\n", "")],
    ),
    "drop-tests-array": (
        "per-test records are gone; only aggregates remain, so no tree can name a test",
        "schema",
        [("      tests,\n", "")],
    ),
    "drop-legacy-per-role": (
        "the legacy role pivot is dropped - the admin-ui console and "
        "e2e_catalogue.parse_summary both read it",
        "schema",
        [("      perRole: [...this.perRole.entries()].map(([role, c]) => ({ role, ...c })),\n", "")],
    ),
    "blank-skip-reason": (
        "every skipped test reports an EMPTY reason: the blank cell that reads as 'fine'",
        "check",
        [("      ? skipReasonOf(test, result)", "      ? { reason: '', known: false }")],
    ),
    "empty-annotation-is-a-reason": (
        "an annotation with no description is accepted as an explanation, so 3 mystery "
        "skips render as explained",
        "check",
        [("      if (desc) return { reason: desc, known: true };",
          "      return { reason: desc, known: true };")],
    ),
    "drop-unexplained-count": (
        "the run-level unexplained-skip count is hard-zeroed",
        "check",
        [("      (t) => t.status === 'skipped' && !t.skipReasonKnown).length;",
          "      () => false).length;")],
    ),
    "drop-per-spec-unexplained": (
        "the per-spec unexplained-skip count is hard-zeroed, so a file full of "
        "mystery greys looks explained",
        "check",
        [("      if (t.status === 'skipped' && !t.skipReasonKnown) c.unexplainedSkips++;\n", "")],
    ),
    "unscrubbed-error": (
        "a failure's error message reaches the report unscrubbed (bearer tokens, "
        "passwords and access_tokens land in assertion dumps)",
        "check",
        [("    const error = status === 'failed' ? scrub(result.error?.message) : '';",
          "    const error = status === 'failed' ? (result.error?.message || '') : '';")],
    ),
    "unscrubbed-skip-reason": (
        "the skip REASON - the string a grey row renders verbatim - is not scrubbed",
        "check",
        [("      const desc = scrub(ann?.description).trim();",
          "      const desc = (ann?.description || '').trim();")],
    ),
    "unscrubbed-title-path": (
        "titlePath reaches the report unscrubbed; helpers build titles from URLs",
        "check",
        [("    const titlePath = rawPath.filter((p) => p !== '').map((p) => scrub(p));",
          "    const titlePath = rawPath.filter((p) => p !== '');")],
    ),
    "unscrubbed-title": (
        "the test title itself is not scrubbed",
        "check",
        [("        title: scrub(test.title),", "        title: test.title,")],
    ),
    "unscrubbed-attachment": (
        "an attachment's name and on-disk path are not scrubbed",
        "check",
        [("        name: scrub(att.name),", "        name: att.name,"),
         ("        path: scrub(att.path || ''),", "        path: att.path || '',")],
    ),
    "drop-attachments": (
        "attachments are dropped, so a failing row has no screenshot and no trace",
        "check",
        [("    for (const att of result.attachments || []) {", "    for (const att of []) {")],
    ),
    "row-per-attempt": (
        "a retried test emits one row PER ATTEMPT, so the tree shows it twice and "
        "the per-spec counts silently become attempt counts",
        "check",
        [("    const key = this.keyOf(test, specFile, titlePath);",
          "    const key = this.keyOf(test, specFile, titlePath) + ':' + String(retry);")],
    ),
    "absolute-spec-file": (
        "specFile stays absolute, so it no longer joins to report.json's spec.file "
        "and every tree node is a different node from the one report.json names",
        "check",
        [("      const r = path.relative(this.rootDir, abs);", "      const r = abs;")],
    ),
    "test-totals-are-result-counts": (
        "testTotals is emitted as a copy of the LEGACY per-RESULT totals, so a "
        "retried test is counted - and drawn - twice; the exact defect the key exists "
        "to prevent, and it keeps four plausible non-zero integers while doing it",
        "check",
        [("    const testTotals = { ...emptyCounter(), total: tests.length };\n"
          "    for (const t of tests) testTotals[t.status]++;\n",
          "    const testTotals = { ...this.totals,\n"
          "      total: this.totals.passed + this.totals.failed + this.totals.skipped };\n")],
    ),
    "test-totals-zeroed": (
        "testTotals is hard-zeroed - still four integers >= 0, so the schema is "
        "perfectly happy and every tree renders an empty run",
        "check",
        [("    const testTotals = { ...emptyCounter(), total: tests.length };\n"
          "    for (const t of tests) testTotals[t.status]++;\n",
          "    const testTotals = { passed: 0, failed: 0, skipped: 0, total: 0 };\n")],
    ),
    "constant-skip-reason": (
        "every EXPLAINED skip reports the same constant reason: skipReasonKnown stays "
        "true, the cell is not blank, and every grey row renders a confident lie",
        "check",
        [("      if (desc) return { reason: desc, known: true };",
          "      if (desc) return { reason: 'skipped', known: true };")],
    ),
    "attempts-all-passed": (
        "every attempt is recorded as 'passed', so the retried test's failed first "
        "attempt disappears while attempts[] keeps exactly the right LENGTH",
        "check",
        [("      retry, status,\n      durationMs: result.duration || 0,",
          "      retry, status: 'passed',\n      durationMs: result.duration || 0,")],
    ),
    "attempts-zero-duration": (
        "every attempt's duration is zeroed - the count of attempts is still right and "
        "no attempt says how long it took",
        "check",
        [("      retry, status,\n      durationMs: result.duration || 0,",
          "      retry, status,\n      durationMs: 0,")],
    ),
    "attempts-lose-retry-index": (
        "every attempt claims retry 0, so retry-1's verdict can no longer be told from "
        "retry-0's and neither joins to the attachments tagged with their retry",
        "check",
        [("      retry, status,\n      durationMs: result.duration || 0,",
          "      retry: 0, status,\n      durationMs: result.duration || 0,")],
    ),
    "zero-test-duration": (
        "the per-test duration is zeroed on both the first attempt and the retry, so "
        "every row in the tree claims to have taken no time",
        "check",
        [("        durationMs: result.duration || 0,", "        durationMs: 0,"),
         ("      rec.durationMs = result.duration || 0;", "      rec.durationMs = 0;")],
    ),
    "drop-test-line": (
        "every test record reports line 0, so a tree cannot open the test at its "
        "declaration and the within-file ordering collapses",
        "check",
        [("        line: loc.line || 0,", "        line: 0,")],
    ),
    "unsorted-tests": (
        "tests[] comes out in arrival order, so the tree reshuffles between runs",
        "check",
        [("      (a, b) => (a.specFile.localeCompare(b.specFile) || a.line - b.line\n"
          "                 || a.title.localeCompare(b.title)),", "      () => 0,")],
    ),
}


def selftest(target: str) -> int:
    """Prove the comment scanner can still tell a comment from code.

    The refusal above is itself a guard, and a guard nothing exercises is the
    disease. This runs it both ways against the REAL reporter: a line that is
    unambiguously a comment must be rejected as an anchor, and every anchor the
    battery actually ships must be accepted. A scanner that drifted into calling
    everything code would silently re-open comment-token inversion while every
    control still looked green.
    """
    with open(target, encoding="utf-8") as fh:
        text = fh.read()
    mask = comment_mask(text)
    fails = []

    probes = [ln for ln in text.split("\n")
              if ln.strip().startswith("//") and len(ln.strip()) > 30
              and text.count(ln) == 1]
    if len(probes) < 3:
        fails.append(f"only {len(probes)} unique comment line(s) to probe with - "
                     f"the scanner is being tested on almost nothing")
    for ln in probes[:5]:
        if anchor_hits_code(text, mask, text.index(ln), len(ln)):
            fails.append(f"comment line accepted as a code anchor: {ln.strip()[:60]!r}")

    for name, (_what, _caught, edits) in MUTATIONS.items():
        for old, _new in edits:
            if text.count(old) != 1:
                fails.append(f"{name}: anchor occurs {text.count(old)}x")
                continue
            if not anchor_hits_code(text, mask, text.index(old), len(old)):
                fails.append(f"{name}: its anchor is classed as comment-only")
    for f in fails:
        print(f"  FAIL {f}")
    if fails:
        return 1
    print(f"  comment scanner: {len(probes[:5])} comment line(s) refused as anchors, "
          f"all {len(MUTATIONS)} shipped anchors accepted as code")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--selftest":
        return selftest(argv[2])
    if len(argv) == 2 and argv[1] == "--list":
        for name in MUTATIONS:
            print(name)
        return 0
    if len(argv) == 4 and argv[1] == "--apply":
        name, target = argv[2], argv[3]
        if name not in MUTATIONS:
            print(f"unknown mutation: {name}", file=sys.stderr)
            return 2
        what, caught_by, edits = MUTATIONS[name]
        with open(target, encoding="utf-8") as fh:
            text = fh.read()
        original = text
        for old, new in edits:
            n = text.count(old)
            if n != 1:
                print(f"MUTATION {name} DID NOT APPLY: its anchor occurs {n} time(s) "
                      f"in {target}, expected exactly 1. The reporter was edited and "
                      f"this control has stopped controlling anything.\n"
                      f"  anchor: {old!r}", file=sys.stderr)
                return 2
            mask = comment_mask(text)
            if not anchor_hits_code(text, mask, text.index(old), len(old)):
                print(f"MUTATION {name} REFUSED: its anchor matches only COMMENT text "
                      f"in {target}. Rewriting a comment changes the file without "
                      f"changing the reporter, so the control would look applied and "
                      f"assert nothing (comment-token inversion).\n"
                      f"  anchor: {old!r}", file=sys.stderr)
                return 2
            text = text.replace(old, new)
        if text == original:
            print(f"MUTATION {name} changed nothing", file=sys.stderr)
            return 2
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"{caught_by}\t{what}")
        return 0
    print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
