#!/usr/bin/env python3
r"""route_access_coverage.py — the route-access DROP-COVERAGE sweep.

Used by tests/stack/test-optional-services-exclude.sh (and guarded on its own by
tests/scripts/test-route-access-coverage-scanner.sh).

THE QUESTION IT ANSWERS (issue #143). `gate_optional_services` prunes a
deselected service's route-access rows with `_opt_drop_rows <file> <gateway>
'<path>' …`. A spot-check can only ask "did THIS row go?"; it cannot ask "did the
row go EVERYWHERE it exists". 20-schema.sql grants several paths on more than one
gateway (the Matrix surface is granted on hugmesh-be-gateway AND, for the front
door, on hugmesh-fe-gateway), and tuwunel's case once dropped only the be-gateway
leg, leaving three live ROLE_MATRIX/MOD/ADMIN grants behind a homeserver that had
been excluded from the build. So: for every path any `_opt_drop_rows` call names,
the set of gateways that GRANT it must be covered by the set of gateways that case
actually cleans.

WHY THIS FILE EXISTS AT ALL — the sweep used to be an inline heredoc in
test-optional-services-exclude.sh that read the RAW .sql with a TWO-column regex:

    re.findall(r"\(\s*'([^']+)'\s*,\s*'([^']+)'", sql)

MEASURED on main's own specs/cluster/manifests/route-access/initdb/20-schema.sql
(2026-08-27), that regex is wrong twice over:

  (a) IT PARSES COMMENT PROSE AS DATA. The raw scan reported **99 paths**, one of
      which is literally named `pattern` — harvested out of the mfa_required note
      at :863, which quotes a row shape as `('gw','pattern','role',true|false)`.
      A phantom gateway `gw` came with it. Documenting the table's own row format
      injected a fake row into the coverage map.
  (b) IT COUNTS DENY ROWS AS GRANTS. The regex stops after two columns, so it
      never sees `allow`. All four `allow=false` rows
      (/bff/user/internal/**, /bff/mesh/internal/**, /bff/internal/** on
      hugmesh-fe-gateway; /attest/api/create-account on
      hugmesh-superadmin-gateway) landed in the same map as the grants, and the
      sweep's own failure text — "'%s' still granted on %s" — would have said
      "granted" about an explicit denial.

With comments stripped and the fourth column read, the same scan sees
**94 granted paths + 4 deny paths**. Both spellings report ZERO gaps today, so
this was LATENT, not active: a scanner that would mis-state coverage the moment a
deny row or a commented example mattered.

WHICH HALF KILLS THE PHANTOM — measured by mutation, because the obvious answer is
wrong. EITHER fix rejects it on its own: the stripper because the tuple lives in a
comment, and the 4-column regex because that comment's fourth value is the literal
text `true|false`, which `(true|false)\s*\)` does not match. The old spelling
needed BOTH defects at once to admit it. So the comment stripper's own load-bearing
job is not the phantom — it is a COMMENTED-OUT REAL ROW, which the 4-column regex
matches perfectly happily (`--   ('gw-z','/hmdm/manage/**','ROLE_X', true),`).
That shape is planted by the guard (B4) and by the mutation battery, indented as
well as at column 0, because a line-anchored `^--` stripper passes the second and
fails the first. See docs/ROUTE-ACCESS.md for why the
allow/deny distinction is load-bearing (deny-wins at the longest matching pattern,
and a MISSING row is NO_RULE → forward, not a denial).

PRIOR ART, AND WHY THIS IS A SECOND COPY. scripts/workload-console-posture.sh
already carries a correct character-wise `strip_sql_comments` (mutation-tested by
tests/workload-console/test-console-posture-and-inventory.sh M4b/M4c/M4d, which
plant a `--` tuple, a `/* */` tuple and an over-strip control). It cannot be
imported: that file is a shell script with the python embedded in a heredoc, so
there is no module to import. This copy additionally honours dollar-quoted bodies
(`DO $$ … $$;`), which 20-schema.sql ends with. If either is ever changed, change
both — the two guards plant the same shapes.

USAGE
    route_access_coverage.py <resolved-gate.sh> <20-schema.sql>

EXIT CODES (the shell caller maps each to its own message)
    0  clean — every dropped path is cleaned on every gateway that GRANTS it
    1  gaps — a grant outlives its service on a gateway the case never cleans
    2  the gate text yielded ZERO `_opt_drop_rows` calls — the sweep is vacuous
    3  VACUITY GUARD: the SQL comment stripper removed NOTHING
    4  VACUITY GUARD: the row regex matched NO row
Codes 3 and 4 exist because the two defects above were both invisible: a scanner
that silently reads nothing, or silently strips nothing, still prints "no gaps"
and still exits 0. A sweep is only allowed to say "clean" after proving it looked.
"""

import collections
import re
import sys

# One VALUES tuple of the canonical 4-column INSERT
# (gateway, url_pattern, role, allow). The `allow` column is the whole point:
# reading only the first two makes an explicit DENY indistinguishable from a
# grant. `(?:[^']|'')*` keeps SQL's doubled-quote escape intact.
ROW_RE = re.compile(
    r"\(\s*'((?:[^']|'')*)'\s*,\s*'((?:[^']|'')*)'\s*,\s*'((?:[^']|'')*)'"
    r"\s*,\s*(true|false)\s*\)",
    re.IGNORECASE,
)

# `_opt_drop_rows "<file>" <gateway> '<path>' '<path>' …` as the gate writes it.
DROP_RE = re.compile(
    r"_opt_drop_rows\s+\"[^\"]+\"\s+(\S+)\s*\\?\s*\n?\s*((?:'[^']*'\s*)+)")

_DOLLAR_TAG_RE = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$")


def strip_sql_comments(sql):
    """Remove `-- …` line comments and `/* … */` block comments, CHARACTER-WISE.

    A regex cannot do this: it has no idea whether a `--` is prose or sits inside
    a quoted value, and stripping one that lives inside a literal would corrupt
    the row it belongs to. So walk the text and honour the three literal forms
    Postgres actually has:

      * single-quoted strings, with `''` as the embedded quote (NOT a terminator);
      * dollar-quoted bodies (`$$ … $$`, `$tag$ … $tag$`) — 20-schema.sql ends
        with a `DO $$ … $$;` GRANT block that contains its own `--` lines, and
        those are inside a string literal, not comments;
      * nested `/* … */`, which Postgres permits.

    Newlines inside a line comment are KEPT so line-oriented reporting downstream
    still lines up with the original file.
    """
    out = []
    i = 0
    n = len(sql)
    while i < n:
        c = sql[i]
        if c == "'":                                   # single-quoted literal
            j = i + 1
            while j < n:
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            out.append(sql[i:j])
            i = j
            continue
        if c == "$":                                   # dollar-quoted literal
            m = _DOLLAR_TAG_RE.match(sql, i)
            if m:
                tag = m.group(0)
                end = sql.find(tag, i + len(tag))
                j = n if end < 0 else end + len(tag)
                out.append(sql[i:j])
                i = j
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
        out.append(c)
        i += 1
    return "".join(out)


def parse_rows(code):
    """(granted, denied) — each path -> set of gateways, split on `allow`."""
    granted = collections.defaultdict(set)
    denied = collections.defaultdict(set)
    n_rows = 0
    for gw, path, _role, allow in ROW_RE.findall(code):
        n_rows += 1
        (granted if allow.lower() == "true" else denied)[path].add(gw)
    return granted, denied, n_rows


def parse_drops(gate_text):
    """path -> set of gateways the gate's `_opt_drop_rows` calls clean it on."""
    drops = collections.defaultdict(set)
    for gw, blob in DROP_RE.findall(gate_text):
        for p in re.findall(r"'([^']*)'", blob):
            drops[p].add(gw)
    return drops


def main(argv):
    if len(argv) != 3:
        print("usage: route_access_coverage.py <gate.sh> <20-schema.sql>",
              file=sys.stderr)
        return 64
    gate_text = open(argv[1], encoding="utf-8").read()
    raw = open(argv[2], encoding="utf-8").read()

    code = strip_sql_comments(raw)

    # ── VACUITY GUARD 1: the stripper must have removed something ────────────
    # 20-schema.sql is ~80 KB of which ~78% is commentary. A stripper that
    # regressed to the identity function would put the phantom `pattern` row
    # back and say nothing about it, because the sweep would still exit 0.
    if code == raw:
        print("         VACUITY: the SQL comment stripper removed NOTHING from "
              "%s (%d bytes in, %d out) — comment prose would be parsed as rows"
              % (argv[2], len(raw), len(code)))
        return 3

    granted, denied, n_rows = parse_rows(code)

    # ── VACUITY GUARD 2: the row regex must have matched something ───────────
    # A regex that matches zero rows makes `rows.get(path)` empty for every
    # path, so the gap set is empty and the sweep reports CLEAN after grading
    # nothing. That is the exact failure this whole file exists to refuse.
    if n_rows == 0:
        print("         VACUITY: the row regex matched NO row in %s — the sweep "
              "would report 'clean' after grading nothing" % argv[2])
        return 4

    drops = parse_drops(gate_text)
    if not drops:
        print("         no _opt_drop_rows call parsed — the sweep would be vacuous")
        return 2

    gaps = {p: sorted(granted.get(p, set()) - g)
            for p, g in drops.items() if granted.get(p, set()) - g}
    for p, gws in sorted(gaps.items()):
        print("         '%s' still granted on %s — that case never cleans it there"
              % (p, ", ".join(gws)))
    # Deny rows are reported, never counted as grants: a stale `allow=false` row
    # outliving its service is fail-closed, so it is information, not a gap.
    stale_denies = {p: sorted(denied.get(p, set()) - g)
                    for p, g in drops.items() if denied.get(p, set()) - g}
    for p, gws in sorted(stale_denies.items()):
        print("         note: '%s' keeps an allow=false DENY row on %s "
              "(fail-closed, not a coverage gap)" % (p, ", ".join(gws)))
    print("         swept %d dropped path(s) against %d granted path(s) "
          "+ %d deny path(s) [%d row(s); stripper removed %d of %d bytes]"
          % (len(drops), len(granted), len(denied), n_rows,
             len(raw) - len(code), len(raw)))
    return 1 if gaps else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
