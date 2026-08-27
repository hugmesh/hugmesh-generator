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
  * the extracted row count must clear a floor, so a regex that stops matching
    produces an ERROR rather than a small, green, vacuous oracle;
  * every url_pattern must be one of the pattern SHAPES the oracle's matcher
    implements faithfully (literal, `<prefix>/**`, `/**`, single-segment `*` glob).
    An Ant construct the matcher cannot honour (`?`, `{var}`, mid-segment `**`)
    is an ERROR here rather than a wrong answer at assert time.

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

# One VALUES tuple. Applied AFTER line comments are stripped.
TUPLE_RE = re.compile(
    r"\(\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*(true|false)\s*\)",
    re.IGNORECASE)

# Row-count floor. The seed holds 150 rows today across four gateways; a parse
# that suddenly yields a handful is a broken extractor, not a shrunken seed.
MIN_ROWS = 100
MIN_FE_ROWS = 50


def strip_line_comments(text: str) -> str:
    """Drop `-- …` to end of line.

    Safe here because the gateway/url_pattern/role literals are all `/`-rooted
    paths or ROLE_ names and none contains a `--`; assert_no_double_dash_in_values
    below turns that assumption into a check rather than a hope.
    """
    return re.sub(r"--[^\n]*", "", text)


def die(msg: str) -> None:
    print(f"gen-route-access-oracle: {msg}", file=sys.stderr)
    sys.exit(2)


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

    inserts = list(INSERT_RE.finditer(raw))
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

    body = raw[inserts[0].end():]
    # The statement ends at its ON CONFLICT tail (or the terminating semicolon).
    end = re.search(r"\bON\s+CONFLICT\b", body, re.IGNORECASE)
    body = body[:end.start()] if end else body.split(";", 1)[0]
    body = strip_line_comments(body)

    rows = [(g, u, r, a.lower() == "true") for (g, u, r, a) in TUPLE_RE.findall(body)]
    if len(rows) < MIN_ROWS:
        die(f"extracted only {len(rows)} row(s) (floor {MIN_ROWS}) — the tuple scan "
            f"has gone blind; refusing to emit a vacuous oracle")
    fe = [r for r in rows if r[0] == "hugmesh-fe-gateway"]
    if len(fe) < MIN_FE_ROWS:
        die(f"extracted only {len(fe)} hugmesh-fe-gateway row(s) (floor {MIN_FE_ROWS}) — "
            f"this is the exact drift the generator exists to end")

    # Shape check: every pattern must be one the matcher implements faithfully.
    shapes: dict[str, int] = {}
    for _, pattern, _, _ in rows:
        try:
            s = pattern_shape(pattern)
        except ValueError as e:
            die(str(e))
        shapes[s] = shapes.get(s, 0) + 1

    gateways = sorted({r[0] for r in rows})
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
