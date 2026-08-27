#!/usr/bin/env python3
"""e2e_reporter_shape_check.py — does the emitted summary.json say what the run
actually contained?

    python3 e2e_reporter_shape_check.py <fixture.json> <summary.json>

The schema (reporters/summary.schema.json, checked separately by
jsonschema_min.py) pins the SHAPE. This pins the CONTENT: every number here is
recomputed from the replayed fixture by code that shares nothing with the
reporter, so "the reporter agrees with itself" cannot pass it.

WHAT IT REFUSES TO ACCEPT
  * a skipped test whose skipReason is empty, or whose skipReasonKnown is true
    while its only annotation had no description (that is a blank cell wearing a
    reason's clothes);
  * a per-spec pivot that is missing a file, or that counts ATTEMPTS where it
    promises TESTS (the retried test in the recorded fixture is the probe);
  * a testTotals that does not count TESTS - including the subtle spelling of
    that defect, testTotals emitted as a copy of the legacy per-RESULT totals,
    which draws the retried test twice;
  * an explained skip whose reason TEXT is not the text the run carried (a
    constant reason keeps skipReasonKnown true and lies on every grey row);
  * an attempts[] of the right LENGTH whose attempts say the wrong thing - a
    failed first attempt relabelled 'passed', or a zeroed duration;
  * an attachment the run produced and the report dropped;
  * a legacy per-RESULT count that has drifted;
  * ANY secret-shaped string from the fixture surviving into the report.

ANTI-VACUITY. A fixture declares, in its `_expect` block, the floors that make it
worth replaying at all (how many unexplained skips it contains, how many
attachments, whether anything retried, how many secret-shaped strings). Editing
the interesting cases out of a fixture fails here instead of quietly turning
every assertion into a no-op over an empty list.
"""

from __future__ import annotations

import json
import os
import re
import sys

# Mirrors specs/report-tags.ts parseTags: LAST occurrence wins, missing -> unknown.
ROLE_RE = re.compile(r"@role:([A-Za-z0-9_@.-]+)")
LAYER_RE = re.compile(r"@layer:([A-Za-z0-9_-]+)")

# Secret SHAPES, independent of the reporter's scrub(). Group 1 is the part that
# must not survive. Kept deliberately close to the credential spellings that have
# actually reached a test title or an assertion dump in this suite.
SECRET_SHAPES = [
    re.compile(r"Bearer\s+([A-Za-z0-9._-]{8,})"),
    re.compile(r"access_token\"?\s*[:=]\s*\"?([A-Za-z0-9._-]{8,})"),
    re.compile(r"password\"?\s*[:=]\s*\"?([^\"\s,&}]{6,})"),
]
REDACTED = "REDACTED"

P = 0
F = 0


def ok(msg: str) -> None:
    global P
    P += 1
    print(f"  PASS {msg}")


def bad(msg: str) -> None:
    global F
    F += 1
    print(f"  FAIL {msg}")


def ok_since(mark: int, msg: str) -> None:
    """A section's PASS line, printed only if the section actually passed.

    An unconditional ok() after a block of bad() calls prints 'PASS perSpec
    pivots all 5 spec files' directly under 'FAIL perSpec is EMPTY'. The exit
    status stays right and the transcript lies, which is how a green-looking log
    ends up quoted as evidence.
    """
    if F == mark:
        ok(msg)


def all_strings(node) -> list[str]:
    """Every string value in a JSON document, keys included.

    The scan runs over DECODED strings, never the file text: in the file a
    credential reads as `\\"password\\": \\"hunter2\\"`, and a regex written for
    the credential as it appears in a log then matches nothing and reports a
    clean run. That failure mode is silent and always in the safe-looking
    direction, which is exactly why it is not used here.
    """
    out: list[str] = []
    if isinstance(node, str):
        out.append(node)
    elif isinstance(node, dict):
        for k, v in node.items():
            out.append(k)
            out.extend(all_strings(v))
    elif isinstance(node, list):
        for v in node:
            out.extend(all_strings(v))
    return out


def canon(s: str) -> str:
    """A string with every secret-shaped VALUE replaced by a placeholder.

    Attachment names and paths are compared through this. They must survive the
    report intact, but a name or path that CARRIES a credential is supposed to
    come back redacted, so a raw == comparison would demand the leak it is meant
    to forbid. Canonicalising both sides asserts the right thing: the attachment
    is still there, and only the credential inside it changed. That the
    credential is gone is asserted separately, by the leak scan.
    """
    for rx in SECRET_SHAPES:
        s = rx.sub(lambda m: m.group(0).replace(m.group(1), "<SECRET>"), s)
    return s


def parse_tags(title: str) -> tuple[str, str]:
    roles = ROLE_RE.findall(title)
    layers = LAYER_RE.findall(title)
    return (roles[-1] if roles else "unknown",
            layers[-1] if layers else "unknown")


def spec_file_of(loc: dict, root_dir: str) -> str:
    abs_path = str(loc.get("file") or "")
    if not abs_path or not root_dir:
        return abs_path
    rel = os.path.relpath(abs_path, root_dir)
    return abs_path if rel.startswith("..") else rel


def status_of(raw: str) -> str:
    return "passed" if raw == "passed" else "skipped" if raw == "skipped" else "failed"


def annotation_reason(anns: list) -> str:
    """The description of the first skip/fixme annotation that HAS one. An
    annotation with no description is the bare test.skip() form, not a reason."""
    for ann in anns or []:
        if ann.get("type") not in ("skip", "fixme"):
            continue
        desc = str(ann.get("description") or "").strip()
        if desc:
            return desc
    return ""


def expected_from_fixture(fixture: dict) -> dict:
    root = str((fixture.get("config") or {}).get("rootDir") or "")
    per_result = {"passed": 0, "failed": 0, "skipped": 0}
    per_role: dict[str, dict] = {}
    per_layer: dict[str, dict] = {}
    tests: dict[str, dict] = {}
    order: list[str] = []
    for ev in fixture["events"]:
        t = ev["test"]
        r = ev["result"]
        st = status_of(str(r.get("status") or ""))
        per_result[st] += 1
        joined = " ".join(t.get("titlePath") or [])
        role, layer = parse_tags(joined)
        per_role.setdefault(role, {"passed": 0, "failed": 0, "skipped": 0})[st] += 1
        per_layer.setdefault(layer, {"passed": 0, "failed": 0, "skipped": 0})[st] += 1

        spec_file = spec_file_of(t.get("location") or {}, root)
        title_path = [p for p in (t.get("titlePath") or []) if p != ""]
        key = f"id:{t['id']}" if t.get("id") else f"path:{spec_file} {' '.join(title_path)}"
        retry = int(r.get("retry") or 0)
        dur = int(r.get("duration") or 0)
        reason = ""
        known = False
        if st == "skipped":
            reason = annotation_reason(r.get("annotations") or []) \
                or annotation_reason(t.get("annotations") or [])
            known = bool(reason)
        rec = tests.get(key)
        if rec is None:
            rec = {"specFile": spec_file, "title": t.get("title") or "",
                   "titlePath": title_path, "id": t.get("id") or "",
                   "line": int((t.get("location") or {}).get("line") or 0),
                   "role": role, "layer": layer, "status": st, "retries": retry,
                   "durationMs": dur,
                   "skipReasonKnown": known, "skipReason": reason,
                   "attachments": [], "attempts": []}
            tests[key] = rec
            order.append(key)
        elif retry >= rec["retries"]:
            rec.update(status=st, retries=retry, role=role, layer=layer,
                       durationMs=dur, skipReasonKnown=known, skipReason=reason)
        # The ATTEMPT ITSELF, not a tally of attempts. A counter here can only
        # ever assert "the report has as many attempts as the run did", which a
        # report that relabels every attempt 'passed' satisfies exactly.
        rec["attempts"].append((retry, st, dur, known))
        for att in r.get("attachments") or []:
            rec["attachments"].append((str(att.get("name") or ""),
                                       str(att.get("contentType") or ""),
                                       str(att.get("path") or ""), retry))

    per_spec: dict[str, dict] = {}
    for rec in tests.values():
        c = per_spec.setdefault(rec["specFile"],
                                {"passed": 0, "failed": 0, "skipped": 0,
                                 "total": 0, "unexplainedSkips": 0})
        c[rec["status"]] += 1
        c["total"] += 1
        if rec["status"] == "skipped" and not rec["skipReasonKnown"]:
            c["unexplainedSkips"] += 1
    test_totals = {"passed": 0, "failed": 0, "skipped": 0, "total": len(tests)}
    for rec in tests.values():
        test_totals[rec["status"]] += 1
    return {"rootDir": root, "perResult": per_result, "perRole": per_role,
            "perLayer": per_layer, "tests": tests, "order": order,
            "perSpec": per_spec, "testTotals": test_totals}


def check(fixture_path: str, summary_path: str) -> int:
    with open(fixture_path, encoding="utf-8") as fh:
        fixture = json.load(fh)
    with open(summary_path, encoding="utf-8") as fh:
        summary = json.load(fh)
    fixture_strings = all_strings(fixture)
    summary_strings = all_strings(summary)

    exp = expected_from_fixture(fixture)
    want = fixture.get("_expect") or {}

    print(f"-- {os.path.basename(fixture_path)}: "
          f"{len(fixture['events'])} recorded event(s) -> "
          f"{len(exp['tests'])} test(s) over {len(exp['perSpec'])} spec file(s) --")

    # ── 0) the fixture still exercises what it claims to ─────────────────────
    n_unexplained = sum(1 for t in exp["tests"].values()
                        if t["status"] == "skipped" and not t["skipReasonKnown"])
    n_explained = sum(1 for t in exp["tests"].values()
                      if t["status"] == "skipped" and t["skipReasonKnown"])
    n_atts = sum(len(t["attachments"]) for t in exp["tests"].values())
    n_retried = sum(1 for t in exp["tests"].values() if len(t["attempts"]) > 1)
    fixture_secrets = [m.group(1) for s_ in fixture_strings
                       for rx in SECRET_SHAPES for m in rx.finditer(s_) if m.group(1)]
    n_secrets = len(fixture_secrets)
    floors = [("minTests", len(exp["tests"])), ("minSpecFiles", len(exp["perSpec"])),
              ("minUnexplainedSkips", n_unexplained), ("minExplainedSkips", n_explained),
              ("minAttachments", n_atts), ("minRetriedTests", n_retried),
              ("minSecretShapedStrings", n_secrets)]
    floors_ok = True
    for name, got in floors:
        floor = int(want.get(name, 0))
        if got < floor:
            floors_ok = False
            bad(f"fixture no longer exercises {name}: declares >= {floor}, contains {got} "
                f"- the assertions below would run over an empty case")
    (ok if floors_ok else print)(f"fixture floors met (tests={len(exp['tests'])} specs={len(exp['perSpec'])} "
       f"unexplained={n_unexplained} explained={n_explained} attachments={n_atts} "
       f"retried={n_retried} secretShaped={n_secrets})")

    # ── 1) the LEGACY per-RESULT pivot is unchanged ──────────────────────────
    mark = F
    for k in ("passed", "failed", "skipped"):
        if summary.get(k) != exp["perResult"][k]:
            bad(f"legacy {k} is {summary.get(k)}, the run had {exp['perResult'][k]} "
                f"result(s) with that status")
    got_role = {r["role"]: {k: r[k] for k in ("passed", "failed", "skipped")}
                for r in summary.get("perRole") or []}
    if got_role != exp["perRole"]:
        bad(f"perRole pivot drifted:\n    emitted  {got_role}\n    expected {exp['perRole']}")
    got_layer = {r["layer"]: {k: r[k] for k in ("passed", "failed", "skipped")}
                 for r in summary.get("perLayer") or []}
    if got_layer != exp["perLayer"]:
        bad(f"perLayer pivot drifted:\n    emitted  {got_layer}\n    expected {exp['perLayer']}")
    ok_since(mark, "legacy per-RESULT totals and the role/layer pivots match the run")

    # ── 1b) the PER-TEST totals — the number a tree actually renders ─────────
    # The schema types testTotals (four integers, minimum 0) and a document full
    # of zeroes satisfies that perfectly. The failure this key exists to prevent
    # is subtler still: emit the legacy per-RESULT counts here and a retried test
    # is drawn TWICE. Both numbers are therefore asserted, and asserted against
    # EACH OTHER on a fixture that retried.
    mark = F
    got_totals = summary.get("testTotals")
    if got_totals != exp["testTotals"]:
        bad(f"testTotals is {got_totals}, the run had {exp['testTotals']} "
            f"(a per-RESULT count where a per-TEST count was promised?)")
    n_results = sum(exp["perResult"].values())
    if n_retried:
        legacy_shaped = dict(exp["perResult"], total=n_results)
        if got_totals == legacy_shaped:
            bad(f"testTotals is bit-identical to the legacy per-RESULT totals "
                f"({legacy_shaped}) although {n_retried} test(s) retried - a tree "
                f"built on it would render the retried test twice")
    if got_totals and got_totals.get("total") != len(exp["tests"]):
        bad(f"testTotals.total is {got_totals.get('total')}, the run had "
            f"{len(exp['tests'])} test(s) over {n_results} result(s)")
    ok_since(mark, f"testTotals counts {exp['testTotals']['total']} TEST(s) "
             f"({exp['testTotals']}), distinct from the {n_results} RESULT(s) the "
             f"run produced")

    # ── 2) the PER-SPEC pivot ────────────────────────────────────────────────
    mark = F
    got_spec = {s["file"]: {k: s[k] for k in
                            ("passed", "failed", "skipped", "total", "unexplainedSkips")}
                for s in summary.get("perSpec") or []}
    if not got_spec:
        bad("perSpec is EMPTY - a feature tree cannot be rendered from this report")
    missing = set(exp["perSpec"]) - set(got_spec)
    extra = set(got_spec) - set(exp["perSpec"])
    if missing:
        bad(f"perSpec is missing spec file(s): {sorted(missing)}")
    if extra:
        bad(f"perSpec invented spec file(s) the run never had: {sorted(extra)}")
    for f, c in exp["perSpec"].items():
        if f in got_spec and got_spec[f] != c:
            bad(f"perSpec[{f}] is {got_spec[f]}, the run had {c} "
                f"(a per-ATTEMPT count where a per-TEST count was promised?)")
    ok_since(mark, f"perSpec pivots all {len(exp['perSpec'])} spec file(s), per TEST")

    # ── 3) per-TEST records, joinable back to file and attachment ────────────
    mark = F
    got_tests = summary.get("tests") or []
    if len(got_tests) != len(exp["tests"]):
        bad(f"tests[] has {len(got_tests)} record(s), the run had {len(exp['tests'])} "
            f"test(s) (retries emitted as separate rows?)")
    by_key = {}
    for t in got_tests:
        key = (f"id:{t['id']}" if t.get("id")
               else f"path:{t['specFile']} {' '.join(t['titlePath'])}")
        by_key[key] = t
    for key, want_t in exp["tests"].items():
        got = by_key.get(key)
        if got is None:
            bad(f"tests[] has no record for {key}")
            continue
        for field in ("specFile", "status", "role", "layer", "retries", "line",
                      "durationMs"):
            if got.get(field) != want_t[field]:
                bad(f"tests[{want_t['title'][:40]}].{field} is {got.get(field)!r}, "
                    f"expected {want_t[field]!r}")
        # title/titlePath through canon(), for the reason canon() documents: they
        # must survive intact, but one CARRYING a credential must come back
        # redacted, and the leak scan is what asserts the credential is gone.
        if canon(str(got.get("title") or "")) != canon(want_t["title"]):
            bad(f"tests[{want_t['title'][:40]}].title is {got.get('title')!r}, "
                f"expected {want_t['title']!r}")
        got_path = [canon(str(p_)) for p_ in got.get("titlePath") or []]
        want_path = [canon(p_) for p_ in want_t["titlePath"]]
        if got_path != want_path:
            bad(f"tests[{want_t['title'][:40]}].titlePath is {got_path!r}, "
                f"expected {want_path!r}")
        # THE REASON TEXT, not just the flag. A report that answers every
        # explained skip with a constant string keeps skipReasonKnown true and
        # renders a wrong, confident-looking reason on every grey row - one step
        # removed from the blank cell this unit exists to close.
        if want_t["skipReasonKnown"]:
            if canon(str(got.get("skipReason") or "")) != canon(want_t["skipReason"]):
                bad(f"tests[{want_t['title'][:40]}].skipReason is "
                    f"{got.get('skipReason')!r}, the run said "
                    f"{want_t['skipReason']!r}")
        elif want_t["status"] != "skipped" and str(got.get("skipReason") or "").strip():
            bad(f"tests[{want_t['title'][:40]}] did not skip but carries a "
                f"skipReason: {got.get('skipReason')!r}")
        # ATTEMPTS BY VALUE. A length check asserts only that the report has as
        # many attempts as the run had; the retried test (failed@0 -> passed@1)
        # is exactly the row that becomes unreadable when every attempt claims
        # to have passed, or when every duration is zero.
        got_attempts_raw = got.get("attempts") or []
        if len(got_attempts_raw) != len(want_t["attempts"]):
            bad(f"tests[{want_t['title'][:40]}].attempts has "
                f"{len(got_attempts_raw)} entry(ies), the run made "
                f"{len(want_t['attempts'])} attempt(s)")
        got_attempts = [(int(a.get("retry") or 0), str(a.get("status") or ""),
                         int(a.get("durationMs") or 0), bool(a.get("skipReasonKnown")))
                        for a in got_attempts_raw]
        if sorted(got_attempts) != sorted(want_t["attempts"]):
            bad(f"tests[{want_t['title'][:40]}] attempts differ "
                f"(retry, status, durationMs, skipReasonKnown):\n"
                f"    emitted  {sorted(got_attempts)}\n"
                f"    expected {sorted(want_t['attempts'])}")
        retries_seen = [a[0] for a in got_attempts]
        if retries_seen != sorted(retries_seen):
            bad(f"tests[{want_t['title'][:40]}].attempts is not in retry order: "
                f"{retries_seen} - attempt 1 would render above attempt 0")
        got_atts = [(canon(a["name"]), a["contentType"], canon(a["path"]), a["retry"])
                    for a in got.get("attachments") or []]
        want_atts = [(canon(n), ct, canon(pa), r) for (n, ct, pa, r) in want_t["attachments"]]
        if sorted(got_atts) != sorted(want_atts):
            bad(f"tests[{want_t['title'][:40]}] attachments differ:\n"
                f"    emitted  {sorted(got_atts)}\n"
                f"    expected {sorted(want_atts)}")
    ok_since(mark, f"every one of the {len(exp['tests'])} test(s) is present with "
             f"its file, line, verdict, duration, title, skip reason, attempts "
             f"(by value) and attachments")

    # sorted, so a tree renders the same order twice running
    order = [(t["specFile"], t["line"], t["title"]) for t in got_tests]
    if order != sorted(order):
        bad("tests[] is not sorted by (specFile, line, title) - the tree would "
            "reshuffle between runs")
    else:
        ok("tests[] is deterministically ordered by (specFile, line, title)")

    # ── 4) NO SKIP IS UNEXPLAINED, AND NO BLANK PRETENDS TO BE A REASON ──────
    mark = F
    for t in got_tests:
        if t["status"] != "skipped":
            continue
        if not str(t.get("skipReason") or "").strip():
            bad(f"skipped test {t['title'][:50]!r} has an EMPTY skipReason - "
                f"a blank cell reads as 'fine'")
        if t.get("skipReasonKnown") is True and not str(t.get("skipReason") or "").strip():
            bad(f"skipped test {t['title'][:50]!r} claims a KNOWN reason and has none")
    got_unexplained = sum(1 for t in got_tests
                          if t["status"] == "skipped" and not t["skipReasonKnown"])
    if got_unexplained != n_unexplained:
        bad(f"unexplained-skip count is {got_unexplained}, the run had {n_unexplained} "
            f"skip(s) with no annotation description (an EMPTY description counted "
            f"as a reason?)")
    if summary.get("unexplainedSkips") != n_unexplained:
        bad(f"summary.unexplainedSkips is {summary.get('unexplainedSkips')}, "
            f"expected {n_unexplained}")
    for key, want_t in exp["tests"].items():
        got = by_key.get(key)
        if got is None or want_t["status"] != "skipped":
            continue
        if got.get("skipReasonKnown") != want_t["skipReasonKnown"]:
            bad(f"tests[{want_t['title'][:40]}].skipReasonKnown is "
                f"{got.get('skipReasonKnown')}, expected {want_t['skipReasonKnown']}")
        if not want_t["skipReasonKnown"] and not str(
                got.get("skipReason") or "").lower().startswith("unknown"):
            bad(f"tests[{want_t['title'][:40]}] has no reason but does not SAY so: "
                f"{got.get('skipReason')!r}")
    ok_since(mark, f"every skipped test carries a reason; {n_unexplained} of them "
             f"say 'unknown' explicitly and {n_explained} carry the suite's own text")

    # ── 5) SCRUB. Not assumed - measured against the fixture's own secrets ───
    leaked = [secret for secret in fixture_secrets
              if any(secret in s_ for s_ in summary_strings)]
    if leaked:
        bad(f"{len(leaked)} secret-shaped string(s) from the run survived into "
            f"summary.json: {sorted(set(leaked))!r}")
    elif n_secrets:
        if not any(REDACTED in s_ for s_ in summary_strings):
            bad(f"the run carried {n_secrets} secret-shaped string(s), none leaked, "
                f"and no {REDACTED} marker is present either - were they dropped "
                f"silently instead of scrubbed?")
        else:
            ok(f"all {n_secrets} secret-shaped string(s) in the run were scrubbed "
               f"to {REDACTED}")
    else:
        print(f"  n/a  this fixture carries no secret-shaped strings; the scrub leg "
              f"is exercised by edge-cases-run.json")

    # ── 6) the join back to report.json ──────────────────────────────────────
    mark = F
    if summary.get("rootDir") != exp["rootDir"]:
        bad(f"rootDir is {summary.get('rootDir')!r}, the run's was {exp['rootDir']!r} "
            f"- specFile could not be resolved against report.json")
    for t in got_tests:
        if os.path.isabs(t["specFile"]):
            # only legitimate for a file OUTSIDE rootDir
            if exp["rootDir"] and not os.path.relpath(
                    t["specFile"], exp["rootDir"]).startswith(".."):
                bad(f"specFile {t['specFile']!r} is absolute although it lives under "
                    f"rootDir - it will not join to report.json's spec.file")
    ok_since(mark, "specFile/perSpec.file are rootDir-relative, so they join to "
             "report.json")

    print(f"-- {P} passed, {F} failed --")
    return 1 if F else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: e2e_reporter_shape_check.py <fixture.json> <summary.json>",
              file=sys.stderr)
        sys.exit(2)
    sys.exit(check(sys.argv[1], sys.argv[2]))
