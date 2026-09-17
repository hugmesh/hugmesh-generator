#!/usr/bin/env python3
"""gen-route-access-oracle.py — emit the e2e route-access ORACLE from the SEED.

WHY THIS EXISTS. tests/e2e/specs/rbac-route-access.ts used to carry a HAND-COPIED
mirror of the gateway_route_access seed, with a header instructing the next writer
to "keep in lockstep with that file". It did not stay in lockstep: measured on
2026-08-26 the mirror held 11 hugmesh-fe-gateway rows against the seed's 77, and
the path it named (manifests/route-access/schema.sql) had not existed for months.
Every /bff/user/** profile+password surface the seed ALLOWs was absent from the
mirror, so the oracle answered DENY for exactly the flows the specs exist to
protect — and the specs were green, because they asserted the mirror.

A mirror that must be maintained by hand is a mirror that drifts. This derives it.

INPUT   specs/cluster/manifests/route-access/initdb/20-schema.sql
        (the ONE canonical `INSERT INTO gateway_route_access (...) VALUES` seed)
OUTPUT  tests/e2e/specs/rbac-route-access.seed.ts   (generated; committed)

The output is checked in and tests/scripts/test-route-access-oracle.sh fails when
the committed file differs from a fresh run, so the seed and the oracle cannot
diverge without CI saying so.

FAIL-CLOSED, never "emit what I could parse":
  * the INSERT's column list must be exactly (gateway, url_pattern, role, allow) —
    a new column (domain / casdoor_user / mfa_required moved into the seed) changes
    the DECISION and must not be silently dropped;
  * the parse must ACCOUNT FOR the whole VALUES body, and for every row-shaped
    tuple anywhere in the file — see "HOW COMPLETENESS IS PINNED" below;
  * every url_pattern must be one of the pattern SHAPES the oracle's matcher
    implements faithfully (literal, `<prefix>/**`, `/**`, single-segment `*` glob).
    An Ant construct the matcher cannot honour (`?`, `{var}`, mid-segment `**`)
    is an ERROR here rather than a wrong answer at assert time.

HOW COMPLETENESS IS PINNED (hugmesh-generator#404). This generator used to locate
the end of the INSERT with a regex for `ON CONFLICT` applied BEFORE it stripped
`--` comments, so a comment inside the INSERT body that merely NAMED that clause
truncated the row scan at the comment and everything below it was dropped.
Measured 2026-09-16: 154 rows -> 119, every hugmesh-superadmin-gateway row and 25
hugmesh-fe-gateway rows gone, exit 0, both vacuity floors still satisfied. The
floors were the only completeness argument and a 23% loss cleared them easily.

Four checks now pin it, and none of them is a magic number:

  1. COMMENTS ARE GONE BEFORE ANYTHING IS LOCATED, and they are removed
     CHARACTER-WISE (strip_sql_comments), so a `--` or `/* */` run inside a
     quoted literal is not mistaken for a comment and a comment can never be
     mistaken for SQL. A regex `--[^\n]*` could do neither, and it could not see
     block comments at all.
  2. THE TERMINATOR IS THE REAL STATEMENT END: the statement runs to the first
     semicolon that is OUTSIDE any literal (single- or dollar-quoted; this file
     ends with a `DO $$ … $$;` GRANT block). `ON CONFLICT` is then located INSIDE
     that statement and must occur at most ONCE there — an earlier one can no
     longer exist, and a second one is an error rather than a silent early cut.
  3. THE PARSE MUST ACCOUNT FOR THE BODY: after every matched tuple is removed
     from the VALUES part, what remains must be whitespace and commas ONLY. A row
     the tuple regex cannot match (`1` instead of `true`, a stray fifth column, a
     double-quoted literal) used to be skipped and absorbed by the floors; it now
     aborts and prints what it could not account for.
  4. NO ROW MAY LIVE OUTSIDE THE EXTRACTED BODY: the same tuple regex is run over
     the WHOLE comment-free file and must find exactly the rows that were
     emitted. This is the direct statement of the defect — "rows exist in the file
     that the oracle does not carry" — and it is checked without knowing why.
     Plus EXPECTED_GATEWAYS, the same pin EXPECTED_COLUMNS already is: the set of
     gateways the seed feeds is a decision, so gaining or losing one is an error
     here rather than a quieter oracle.

MIN_ROWS / MIN_FE_ROWS survive as VACUITY floors only — "did we read a seed at
all" — and are deliberately NOT the completeness argument any more. Checks 3 and 4
are, because they are derived from the seed itself and a floor is not.

Exit codes, so a caller can tell the failure MODES apart:
    2  shape error   — the seed is not the shape this generator models
    3  vacuity       — a floor was not cleared; we read (almost) nothing
    4  completeness  — rows were lost between the file and the emitted oracle

Offline: stdlib only, reads one file, writes one file.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_SQL = REPO / "specs/cluster/manifests/route-access/initdb/20-schema.sql"
DEFAULT_OUT = REPO / "tests/e2e/specs/rbac-route-access.seed.ts"

# The seed's canonical INSERT. Anything else in the file (DDL, ALTERs, the
# mfa_required UPDATE, the ON CONFLICT tail) is not a row source.
INSERT_RE = re.compile(
    r"INSERT\s+INTO\s+gateway_route_access\s*\(([^)]*)\)\s*VALUES", re.IGNORECASE)
EXPECTED_COLUMNS = ["gateway", "url_pattern", "role", "allow"]

# The gateways this seed feeds. Pinned for the same reason EXPECTED_COLUMNS is:
# adding or retiring a gateway is a DECISION, and #404 was a silent loss of one
# (hugmesh-superadmin-gateway went to zero rows and nothing said so). If you are
# here because a gateway legitimately arrived or left, change this line in the
# same commit as the seed.
EXPECTED_GATEWAYS = {
    "hugmesh-be-gateway",
    "hugmesh-fe-gateway",
    "hugmesh-pki-gateway",
    "hugmesh-superadmin-gateway",
}

# One VALUES tuple. Applied AFTER comments are stripped.
TUPLE_RE = re.compile(
    r"\(\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*(true|false)\s*\)",
    re.IGNORECASE)

ON_CONFLICT_RE = re.compile(r"\bON\s+CONFLICT\b", re.IGNORECASE)

# Row-count floor. VACUITY ONLY — "did we read a seed at all". Completeness is
# pinned by the body-accountability and whole-file cross-checks, not by these;
# see HOW COMPLETENESS IS PINNED above. A 23% row loss cleared both of these.
MIN_ROWS = 100
MIN_FE_ROWS = 50

_DOLLAR_TAG_RE = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$")


def _skip_literal(sql: str, i: int) -> int | None:
    """If a literal starts at `i`, return the index just past it, else None.

    Handles the two literal forms this seed actually uses: single-quoted strings
    with `''` as the embedded quote (NOT a terminator), and dollar-quoted bodies
    (`$$ … $$`, `$tag$ … $tag$`) — 20-schema.sql ends with a `DO $$ … $$;` block
    whose body contains both `--` lines and semicolons.
    """
    n = len(sql)
    if sql[i] == "'":
        j = i + 1
        while j < n:
            if sql[j] == "'":
                if j + 1 < n and sql[j + 1] == "'":
                    j += 2
                    continue
                return j + 1
            j += 1
        return n
    if sql[i] == "$":
        m = _DOLLAR_TAG_RE.match(sql, i)
        if m:
            tag = m.group(0)
            end = sql.find(tag, i + len(tag))
            return n if end < 0 else end + len(tag)
    return None


def strip_sql_comments(sql: str) -> str:
    """Remove `-- …` line comments and `/* … */` block comments, CHARACTER-WISE.

    A regex cannot do this: it has no idea whether a `--` is prose or sits inside
    a quoted value, and it cannot see block comments at all. Walk the text and
    honour the literal forms Postgres has, plus nested `/* … */`, which it
    permits. Newlines inside a line comment are KEPT so offsets stay line-aligned
    with the original file.

    This replaced a `re.sub(r"--[^\\n]*", "", text)` that ran AFTER the statement
    terminator had already been located — hugmesh-generator#404.
    """
    out: list[str] = []
    i = 0
    n = len(sql)
    while i < n:
        end = _skip_literal(sql, i)
        if end is not None:
            out.append(sql[i:end])
            i = end
            continue
        if sql.startswith("--", i):                    # line comment
            j = sql.find("\n", i)
            i = n if j < 0 else j                      # keep the newline
            continue
        if sql.startswith("/*", i):                    # block comment (nestable)
            depth = 1
            j = i + 2
            while j < n and depth:
                if sql.startswith("/*", j):
                    depth += 1
                    j += 2
                elif sql.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            i = j
            continue
        out.append(sql[i])
        i += 1
    return "".join(out)


def top_level_semicolon(sql: str, start: int) -> int:
    """Index of the first `;` at or after `start` that is OUTSIDE any literal.

    Returns -1 if there is none. `sql` must already be comment-free; literals are
    still present, which is exactly why this cannot be `sql.find(";", start)`.
    """
    i = start
    n = len(sql)
    while i < n:
        end = _skip_literal(sql, i)
        if end is not None:
            i = end
            continue
        if sql[i] == ";":
            return i
        i += 1
    return -1


def die(msg: str, code: int = 2) -> None:
    print(f"gen-route-access-oracle: {msg}", file=sys.stderr)
    sys.exit(code)


def assert_no_double_dash_in_values(values_part: str) -> None:
    """No emitted literal may contain a comment token.

    The generator no longer NEEDS this to parse — strip_sql_comments is
    character-wise and leaves literals alone. It is still a hard error because
    the things downstream of here are not that careful:

      * tests/scripts/test-route-access-oracle.sh counts rows with
        `sed 's/--.*//'` over the SQL and `sed 's|//.*||'` over the generated TS;
        a literal carrying `--` or `//` would corrupt the GATE's own counters and
        make it agree with itself about the wrong number;
      * the emitter below writes each literal into TypeScript between single
        quotes with no escaping, so a backslash would change what it means.

    The old docstring claimed a function of this name already enforced the `--`
    assumption. It did not exist (hugmesh-generator#404); now it does.
    """
    for value in re.findall(r"'([^']*)'", values_part):
        for token in ("--", "//", "\\"):
            if token in value:
                die(f"the seed VALUES body has a row literal {value!r} carrying {token!r}. "
                    f"Comment tokens and backslashes inside a row literal break the row "
                    f"counters in tests/scripts/test-route-access-oracle.sh and the "
                    f"unescaped TypeScript emitted below; spell the value without it")


def pattern_shape(p: str) -> str:
    """Classify a url_pattern into a shape the oracle's matcher implements.

    Returns the shape name, or raises ValueError naming what is unsupported.
    """
    if not p.startswith("/"):
        raise ValueError(f"url_pattern {p!r} is not absolute")
    if "?" in p or "{" in p:
        raise ValueError(f"url_pattern {p!r} uses an Ant construct the oracle does not implement")
    if p == "/**":
        return "root-glob"
    if p.endswith("/**"):
        head = p[:-3]
        if "*" in head:
            raise ValueError(f"url_pattern {p!r} has a `*` before its trailing /**")
        return "prefix-glob"
    if "**" in p:
        raise ValueError(f"url_pattern {p!r} has a mid-pattern ** the oracle does not implement")
    if "*" in p:
        # e.g. /*.css — a single-segment glob. `*` must not span a `/`.
        if p.count("/") != 1:
            raise ValueError(f"url_pattern {p!r} globs across more than one segment")
        return "segment-glob"
    return "literal"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sql", default=str(DEFAULT_SQL))
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    ap.add_argument("--stdout", action="store_true", help="write to stdout instead of --out")
    args = ap.parse_args()

    sql_path = Path(args.sql)
    try:
        raw = sql_path.read_text(encoding="utf-8")
    except OSError as e:
        die(f"cannot read {sql_path}: {e}")

    # (1) Comments go FIRST, character-wise, so nothing below can be fooled by
    #     prose that happens to name a SQL keyword. #404 did this last.
    clean = strip_sql_comments(raw)

    inserts = list(INSERT_RE.finditer(clean))
    if len(inserts) != 1:
        die(f"expected exactly ONE `INSERT INTO gateway_route_access (...) VALUES` in "
            f"{sql_path}, found {len(inserts)} — the seed shape changed and this "
            f"generator must be taught the new one rather than guess")
    cols = [c.strip().lower() for c in inserts[0].group(1).replace("\n", " ").split(",")]
    cols = [c for c in cols if c]
    if cols != EXPECTED_COLUMNS:
        die(f"the seed INSERT column list is {cols}, expected {EXPECTED_COLUMNS}. "
            f"A new column (domain / casdoor_user / mfa_required) CHANGES the gateway "
            f"decision; teach the oracle about it instead of dropping it silently")

    # (2) The statement ends at its real terminator: the first semicolon outside
    #     a literal. ON CONFLICT is then found INSIDE the statement, and a second
    #     one is an error rather than an earlier, quieter cut.
    stmt_end = top_level_semicolon(clean, inserts[0].end())
    if stmt_end < 0:
        die(f"the seed INSERT in {sql_path} is never terminated by a `;` outside a "
            f"literal — refusing to guess where the statement ends")
    stmt = clean[inserts[0].end():stmt_end]

    conflicts = list(ON_CONFLICT_RE.finditer(stmt))
    if len(conflicts) > 1:
        die(f"the seed INSERT contains {len(conflicts)} `ON CONFLICT` clauses; exactly "
            f"one statement may have at most one, so this parse cannot say where the "
            f"rows stop — fix the seed rather than let the scan pick the first")
    values_part = stmt[:conflicts[0].start()] if conflicts else stmt

    assert_no_double_dash_in_values(values_part)

    matches = list(TUPLE_RE.finditer(values_part))
    rows = [(m.group(1), m.group(2), m.group(3), m.group(4).lower() == "true") for m in matches]

    # (3) ACCOUNTABILITY: every character of the VALUES body must be either a row
    #     we matched, a comma, or whitespace. A row shaped in a way the tuple
    #     regex cannot read used to be skipped and absorbed by the floors.
    residue = re.sub(r"[\s,]+", "", TUPLE_RE.sub("", values_part))
    if residue:
        leftover = TUPLE_RE.sub("", values_part).strip()
        die(f"the INSERT's VALUES body has {len(residue)} non-row character(s) this "
            f"parse could not account for — it read {len(rows)} row(s) and does not "
            f"know what the rest is, so it refuses to emit a partial oracle. "
            f"Unaccounted text begins: {leftover[:200]!r}", code=4)

    # (4) NO ROW OUTSIDE THE BODY: the same regex over the whole comment-free file
    #     must find exactly what we emitted. This is #404 stated directly — rows
    #     present in the file that the oracle does not carry — and it does not
    #     need to know HOW they were lost.
    everywhere = TUPLE_RE.findall(clean)
    if len(everywhere) != len(rows):
        seen: dict[str, int] = {}
        for g, _, _, _ in everywhere:
            seen[g] = seen.get(g, 0) + 1
        got: dict[str, int] = {}
        for g, _, _, _ in rows:
            got[g] = got.get(g, 0) + 1
        delta = ", ".join(
            f"{g}: file {seen.get(g, 0)} vs emitted {got.get(g, 0)}"
            for g in sorted(set(seen) | set(got))
            if seen.get(g, 0) != got.get(g, 0))
        die(f"{len(everywhere)} row-shaped tuple(s) exist in {sql_path} but only "
            f"{len(rows)} were extracted from the INSERT body — the statement "
            f"extraction LOST rows ({delta}). This is hugmesh-generator#404's "
            f"failure mode; refusing to emit a truncated oracle", code=4)

    # Vacuity floors. These say "we read a seed at all"; checks (3) and (4) above
    # are what say "we read ALL of it".
    if len(rows) < MIN_ROWS:
        die(f"extracted only {len(rows)} row(s) (floor {MIN_ROWS}) — the tuple scan "
            f"has gone blind; refusing to emit a vacuous oracle", code=3)
    fe = [r for r in rows if r[0] == "hugmesh-fe-gateway"]
    if len(fe) < MIN_FE_ROWS:
        die(f"extracted only {len(fe)} hugmesh-fe-gateway row(s) (floor {MIN_FE_ROWS}) — "
            f"this is the exact drift the generator exists to end", code=3)

    gateways = sorted({r[0] for r in rows})
    if set(gateways) != EXPECTED_GATEWAYS:
        missing = sorted(EXPECTED_GATEWAYS - set(gateways))
        extra = sorted(set(gateways) - EXPECTED_GATEWAYS)
        die(f"the emitted oracle covers gateways {gateways}, expected "
            f"{sorted(EXPECTED_GATEWAYS)} (missing: {missing or 'none'}; "
            f"unknown: {extra or 'none'}). A gateway silently reaching zero rows is "
            f"hugmesh-generator#404; if this change is intended, update "
            f"EXPECTED_GATEWAYS in the same commit as the seed", code=4)

    # Shape check: every pattern must be one the matcher implements faithfully.
    shapes: dict[str, int] = {}
    for _, pattern, _, _ in rows:
        try:
            s = pattern_shape(pattern)
        except ValueError as e:
            die(str(e))
        shapes[s] = shapes.get(s, 0) + 1

    per_gw = {g: sum(1 for r in rows if r[0] == g) for g in gateways}

    lines: list[str] = []
    A = lines.append
    A("// rbac-route-access.seed.ts — GENERATED FILE. DO NOT EDIT BY HAND.")
    A("//")
    A("// Source of truth:")
    A("//   specs/cluster/manifests/route-access/initdb/20-schema.sql")
    A("// Regenerate:")
    A("//   python3 scripts/gen-route-access-oracle.py")
    A("// Gate (CI):")
    A("//   bash tests/scripts/test-route-access-oracle.sh")
    A("//")
    A("// The previous hand-maintained mirror drifted to 11 of the seed's 77")
    A("// hugmesh-fe-gateway rows, which made the oracle answer DENY for every")
    A("// /bff/user/** profile and password surface the real gateway ALLOWs.")
    A("// Nothing is copied by hand any more.")
    A("//")
    A(f"// Rows: {len(rows)} total — " + ", ".join(f"{g} {per_gw[g]}" for g in gateways))
    A("// Pattern shapes: " + ", ".join(f"{k} {v}" for k, v in sorted(shapes.items())))
    A("//")
    A("// Every seed row is UNSCOPED (no domain) and UNPINNED (no casdoor_user):")
    A("// the INSERT names exactly (gateway, url_pattern, role, allow), which the")
    A("// generator asserts. Per-domain sibling rows are a RUNTIME concern")
    A("// (docs/MFA-ROLLOUT.md §1.2a) and are deliberately not modelled here.")
    A("")
    A("import type { RouteRule } from './rbac-route-access';")
    A("")
    A("export const ROUTE_ACCESS_SEED: readonly RouteRule[] = [")
    for gateway, pattern, role, allow in rows:
        A(f"  {{ gateway: '{gateway}', urlPattern: '{pattern}', "
          f"role: '{role}', allow: {'true' if allow else 'false'} }},")
    A("];")
    A("")
    out_text = "\n".join(lines)

    if args.stdout:
        sys.stdout.write(out_text)
        return 0
    Path(args.out).write_text(out_text, encoding="utf-8")
    print(f"wrote {args.out}: {len(rows)} rows "
          + ", ".join(f"{g}={per_gw[g]}" for g in gateways))
    return 0


if __name__ == "__main__":
    sys.exit(main())
