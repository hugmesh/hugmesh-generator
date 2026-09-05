#!/usr/bin/env bash
# test-route-access-coverage-scanner.sh — the guard over the route-access
# DROP-COVERAGE SCANNER (tests/scripts/route_access_coverage.py).
#
# WHY IT EXISTS. The scanner used to be an inline heredoc inside
# tests/stack/test-optional-services-exclude.sh that read the RAW
# specs/cluster/manifests/route-access/initdb/20-schema.sql with a TWO-column
# regex, `re.findall(r"\(\s*'([^']+)'\s*,\s*'([^']+)'", sql)`. MEASURED by
# executing it against main's own schema on 2026-08-27:
#
#   RAW  (main, before)  99 paths — including a PHANTOM path literally named
#                        `pattern` on a phantom gateway `gw`, harvested out of the
#                        mfa_required note at 20-schema.sql:863 which quotes a row
#                        shape as `('gw','pattern','role',true|false)`;
#                        and all FOUR `allow=false` DENY rows counted as GRANTS.
#   FIXED (after)        94 granted paths + 4 deny paths, no phantom.
#
# Both spellings report ZERO gaps against today's gate, so the defect was LATENT:
# a scanner that would mis-state coverage the moment a deny row or a commented
# example mattered, and whose failure text would have said "still granted on" about
# an explicit denial. docs/ROUTE-ACCESS.md is why the distinction is load-bearing —
# deny-wins at the longest matching pattern, and a MISSING row is NO_RULE (forward),
# not a denial.
#
# HOW SECTION A IS ITSELF GUARDED (added after the guard was caught failing OPEN).
# Section A drives the scanner's internals through importlib, so a signature change
# in route_access_coverage.py raises INSIDE the heredoc. As first written this file
# discarded that completely — the command substitution had no stderr redirect, its
# `$?` was never taken, and the reader loop only counted the rows that ARRIVED.
# MEASURED at 29e43c18 against a plausible refactor (parse_rows returning a 2-tuple,
# main() updated to match): all ELEVEN section-A assertions vanished, the file
# printed "12 passed, 0 failed" and EXITED 0, and the scanner's production path was
# green as well — so the refactor, together with a genuine `--`-inside-`DO $$`
# regression that only A4 detects, was mergeable with every suite green. That is
# the scanner's own docstring rule ("a sweep is only allowed to say 'clean' after
# proving it looked") broken one level up, in the guard that certifies the sweep,
# and it is the same class tests/platform-capability-rbac/test-argocd-route-honesty.sh
# had closed the day before. Now: stderr goes to a FILE, `$?` is captured, and the
# emitted row count has a FLOOR (A_MIN) — A0a/A0b/A0c — and section D proves each of
# those three bites by re-running the section against synthetic STAND-IN scanners.
#
# WHAT IT ASSERTS, AND HOW. Behaviour, never the scanner's source text: a guard
# that greps for the line it wants is satisfied by a commented-out one. Section A
# runs the scanner's own functions against the REAL schema. Section B runs the
# whole scanner against synthetic scratch trees and asserts its EXIT CODE — which
# is what makes the two vacuity guards (rc 3 / rc 4) provable at all: nothing else
# in the repo can tell the difference between "swept and clean" and "swept nothing
# and said clean". Section B also carries the two shapes a mutation battery plants:
# a COMMENTED-OUT row that must not be seen, and a real DENY row that must not be
# counted as a grant.
#
# MUTATION BATTERY, 2026-08-27 — 15 mutations, each proven APPLIED (file hash
# changed) and REVERTED (byte-identical), 14 caught:
#   stripper -> identity ............................. B1..B8 red (rc 3 everywhere)
#   stripper -> only /* */ (the `--` leg gone) ....... 10 of 23 red
#   stripper -> naive quote-blind `--` regex ......... B4 + B7 red
#   stripper -> line-anchored ^-- regex .............. B4 red (the INDENTED plant)
#   dollar-quote branch removed ...................... A4 red
#   allow/deny split reverted (all rows GRANT) ....... A2 x4 + B5 + B5b red
#   vacuity guard 1 exits 0 .......................... B1 red
#   vacuity guard 2 exits 0 .......................... B2 red
#   drop-vacuity guard exits 0 ....................... B3 red
#   gap set forced empty ............................. B6 + B6b red
#   PLANT a commented-out real row in 20-schema.sql .. invisible (correct); with the
#     `--` strip leg reverted the SAME plant turns the stack suite RED
#   PLANT a real allow=false row in 20-schema.sql .... reported as a note (correct);
#     with the allow/deny split reverted the SAME plant reads "still granted on gw-z"
#   PLANT a real allow=true row in 20-schema.sql ..... RED (positive control)
#
# SECOND BATTERY, 2026-09-04 — over section A's own fail-closed gates. Each mutation
# proven APPLIED (file hash changed) and REVERTED (byte-identical):
#   ON THE SUBJECT (tests/scripts/route_access_coverage.py)
#     parse_rows -> 2-tuple, main() updated ........... was 12/0 EXIT 0; now 17/3 EXIT 1
#     dollar-quote branch removed ..................... 28/2 EXIT 1 (A4, unchanged)
#     BOTH together (the masking case) ................ was 12/0 EXIT 0; now 17/3 EXIT 1
#     parse_rows(code, strict=True) ................... 30/0 — benign, correctly green
#     strip_sql_comments(sql, dialect=...) ............ 30/0 — benign, correctly green
#   ON THIS FILE'S OWN GATES (each caught by exactly one D control)
#     the `2>"${A_ERRF}"` redirect removed ............ D3 red
#     the `A_RC=$?` capture removed ................... D2 red
#     A_MIN lowered to 0 (the floor removed) .......... D4 red
#
# ONE MUTATION OF THE FIX DELIBERATELY NOT CLOSED, recorded rather than papered over:
# deleting the harness's try/except around the importlib load and the parse_rows call
# is NOT caught on its own (30/0). It is not a gate — it only converts a crash into a
# readable FAIL ROW. With it deleted AND the parse_rows arity changed the suite is
# still red, 15/4, on A0a + A0b + A0c, which is the property that matters; what is
# lost is the message, not the verdict. Closing it would mean asserting on this
# file's own source text, which a commented-out line satisfies.
#
# ONE MUTATION DELIBERATELY NOT CLOSED, and it is recorded rather than papered over:
# widening ROW_RE's fourth group to also accept the literal text `true|false` is NOT
# caught (23/0). It would re-admit section A's phantom on its own — except the
# comment stripper still rejects it, and the only way to disable BOTH is an identity
# stripper, which vacuity guard 1 refuses with rc 3. Closing it would mean asserting
# on the scanner's regex source text, which is exactly the kind of assertion a
# commented-out line satisfies. The phantom cannot come back without this file
# going red by some other leg; that is the honest statement of the coverage.
#
# OFFLINE. No stack, no cluster, no network, no root. Needs bash + python3 only.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCAN="${REPO}/tests/scripts/route_access_coverage.py"
SQL="${REPO}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
STACK_SUITE="${REPO}/tests/stack/test-optional-services-exclude.sh"

P=0; F=0
ok(){  echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

echo "== route-access coverage scanner: comment stripping, allow/deny split, vacuity =="

command -v python3 >/dev/null || { echo "  FAIL python3 is required — skipping would leave the scanner unguarded"; exit 1; }
[ -f "${SCAN}" ] || { echo "  FAIL scanner missing: ${SCAN}"; exit 1; }
[ -f "${SQL}"  ] || { echo "  FAIL route-access schema missing: ${SQL}"; exit 1; }

run_case(){   # run_case <gate.sh> <schema.sql>   -> stdout in $OUT, status in $RC
  OUT="$(python3 "${SCAN}" "$1" "$2" 2>&1)"; RC=$?
}

A_MIN=11   # PASS/FAIL rows section A is REQUIRED to emit: A1a A1b A2x4 A3a A3b
           # A3c A4 A5. A FLOOR, not an equality — adding an assertion must not
           # force an edit here, but LOSING one must go red.

run_section_a(){   # run_section_a <route_access_coverage.py> <20-schema.sql>
  # Sets A_OUT (stdout), A_RC (exit status), A_ERRF (stderr FILE), A_ROWS
  # (PASS+FAIL rows emitted), A_FAILS (FAIL rows emitted).
  #
  # WHY THIS IS A FUNCTION AND NOT A BARE COMMAND SUBSTITUTION. Section A drives
  # the scanner's INTERNALS through importlib, so ANY signature change in
  # route_access_coverage.py raises inside this heredoc. The first spelling of
  # this file threw that away: no redirect of stderr, no `$?` capture, and a
  # reader loop that only counted the rows that ARRIVED. Measured against a
  # plausible refactor (parse_rows returning a 2-tuple, main() updated to match):
  # all ELEVEN section-A assertions vanished, stdout read
  # "12 passed, 0 failed", the suite EXITED 0, and the scanner's production path
  # was green too. That is the scanner's own docstring rule — "a sweep is only
  # allowed to say 'clean' after proving it looked" — broken one level up, in the
  # guard that certifies the sweep. Section D plants that mutation and three
  # neighbours and proves each gate below actually bites.
  #
  # Shape borrowed deliberately from tests/platform-capability-rbac/
  # test-argocd-route-honesty.sh (ERRF + RC + a non-vacuity gate), which had
  # closed this same class the day before this file was written.
  A_ERRF="${WORK}/section-a.err"
  : > "${A_ERRF}"
  A_OUT="$(python3 - "$1" "$2" 2>"${A_ERRF}" <<'PYX'
import importlib.util, re, sys

def fail(tag, msg):
    """Turn a setup failure into a FAIL ROW instead of a traceback.

    A traceback goes to stderr, leaves stdout empty, and used to read as
    "0 of these assertions failed"."""
    print("%s FAIL %s" % (tag, msg))

try:
    spec = importlib.util.spec_from_file_location("rac", sys.argv[1])
    rac = importlib.util.module_from_spec(spec); spec.loader.exec_module(rac)
except Exception as exc:                              # noqa: BLE001 - deliberate
    fail("A0", "the scanner could not be IMPORTED (%s: %s) — the eleven "
               "assertions below did not run; they are missing, not passing"
               % (type(exc).__name__, str(exc).splitlines()[0][:160]))
    sys.exit(0)

try:
    raw  = open(sys.argv[2], encoding="utf-8").read()
    code = rac.strip_sql_comments(raw)
    granted, denied, n_rows = rac.parse_rows(code)
except Exception as exc:                              # noqa: BLE001 - deliberate
    fail("A0", "the scanner's own API raised while section A drove it (%s: %s) — "
               "this is a signature or behaviour change in "
               "route_access_coverage.py, not a schema problem, and it would "
               "otherwise DELETE the eleven assertions below in silence"
               % (type(exc).__name__, str(exc).splitlines()[0][:160]))
    sys.exit(0)

# NOTE: everything below is deliberately NOT wrapped. If an assertion body
# raises, the harness must die loudly — non-zero status, traceback on stderr,
# a short row count — and the three shell gates after this heredoc catch all
# three of those. Section D's D4 is that exact shape, planted on purpose.

# A1 the phantom. The OLD two-column spelling, verbatim, so the fixture is proven
# to still CARRY the trap — if the row-shape comment is ever reworded away, this
# half goes red and says so instead of quietly passing on an empty premise.
# NOTE what A1b does NOT prove: EITHER half of the fix rejects this particular
# tuple on its own (the comment stripper because it is prose, the 4-column regex
# because its fourth value is the literal text `true|false`). The old spelling
# needed both defects at once. The stripper's own irreplaceable job is B4's
# commented-out REAL row, which the 4-column regex matches happily.
old = {p for _gw, p in re.findall(r"\(\s*'([^']+)'\s*,\s*'([^']+)'", raw)}
print("A1a %s phantom 'pattern' harvested from a comment by the OLD 2-column raw regex (%d paths)"
      % ("PASS" if "pattern" in old else "FAIL", len(old)))
print("A1b %s the fixed scan does NOT see 'pattern' (granted=%s denied=%s)"
      % ("PASS" if ("pattern" not in granted and "pattern" not in denied) else "FAIL",
         "pattern" in granted, "pattern" in denied))

# A2 every allow=false row is classified DENY and appears in NO grant map.
expected_denies = {
    "/bff/user/internal/**":       "hugmesh-fe-gateway",
    "/bff/mesh/internal/**":       "hugmesh-fe-gateway",
    "/bff/internal/**":            "hugmesh-fe-gateway",
    "/attest/api/create-account":  "hugmesh-superadmin-gateway",
}
for path, gw in sorted(expected_denies.items()):
    good = gw in denied.get(path, set()) and gw not in granted.get(path, set())
    print("A2 %s allow=false row %s on %s is classified DENY, not GRANT"
          % ("PASS" if good else "FAIL", path, gw))

# A3 floors. A collapsed parse (a regex that stops matching) must not read as
# "clean"; a cardinality floor turns that into a failure instead of a silence.
print("A3a %s granted-path floor: %d granted path(s) >= 80" % ("PASS" if len(granted) >= 80 else "FAIL", len(granted)))
print("A3b %s row floor: %d parsed row(s) >= 140" % ("PASS" if n_rows >= 140 else "FAIL", n_rows))
print("A3c %s deny-path floor: %d deny path(s) >= 4" % ("PASS" if len(denied) >= 4 else "FAIL", len(denied)))

# A4 dollar-quoted bodies are STRING LITERALS, not code: the `--` lines inside
# the trailing `DO $$ … $$;` GRANT block must survive the stripper untouched.
marker = "The TAILNET superadmin-gateway's own read-only rule loader."
in_dollar = marker in raw and marker in code
print("A4 %s a `--` line inside the DO $$ … $$ block is preserved (dollar-quoting honoured)"
      % ("PASS" if in_dollar else "FAIL"))

# A5 the stripper is doing real work on this file, and the ratio is stated.
print("A5 %s stripper removed %d of %d bytes of 20-schema.sql"
      % ("PASS" if len(code) < len(raw) else "FAIL", len(raw) - len(code), len(raw)))
PYX
)"
  A_RC=$?
  A_ROWS=0; A_FAILS=0
  while IFS= read -r line; do
    case "${line}" in
      *" PASS "*) A_ROWS=$((A_ROWS+1)) ;;
      *" FAIL "*) A_ROWS=$((A_ROWS+1)); A_FAILS=$((A_FAILS+1)) ;;
    esac
  done <<< "${A_OUT}"
}

# ─────────────────────────────────────────────────────────────────────────────
# A) THE REAL SUBJECT — the scanner's behaviour on main's own 20-schema.sql
# ─────────────────────────────────────────────────────────────────────────────
echo "-- A) against specs/cluster/manifests/route-access/initdb/20-schema.sql --"

run_section_a "${SCAN}" "${SQL}"
while IFS= read -r line; do
  case "${line}" in
    *" PASS "*) ok "${line#* PASS }" ;;
    *" FAIL "*) bad "${line#* FAIL }" ;;
    *) [ -n "${line}" ] && echo "         ${line}" ;;
  esac
done <<< "${A_OUT}"

# A0 — THE THREE FAIL-CLOSED GATES over section A itself. Without them a crash in
#      the harness deletes every row above and the suite still reports 0 failed.
if [ "${A_RC}" -eq 0 ]; then
  ok "A0a section A's harness exited 0 — it delivered a verdict rather than crashing"
else
  bad "A0a section A's harness exited ${A_RC} — it CRASHED; the rows above are MISSING, not passing"
fi
if [ -s "${A_ERRF}" ]; then
  bad "A0b section A's harness wrote to stderr — output an exit-code-only gate would discard:"
  sed 's/^/         | /' "${A_ERRF}"
else
  ok "A0b section A's harness wrote nothing to stderr"
fi
if [ "${A_ROWS}" -ge "${A_MIN}" ]; then
  ok "A0c NON-VACUITY: section A emitted ${A_ROWS} assertion row(s) >= ${A_MIN} — the section really ran"
else
  bad "A0c NON-VACUITY: section A emitted only ${A_ROWS} assertion row(s), floor is ${A_MIN} — assertions VANISHED instead of failing; NOT skipping"
fi

# Recorded for section D: D3's stand-in delegates to the REAL scanner, so it can
# only isolate the stderr gate while the real one is healthy. Without this flag a
# broken scanner makes D3 accuse itself instead of naming the upstream failure.
A_REAL_GREEN=1
if [ "${A_RC}" -eq 0 ] && [ ! -s "${A_ERRF}" ] && [ "${A_FAILS}" -eq 0 ] && [ "${A_ROWS}" -ge "${A_MIN}" ]; then
  A_REAL_GREEN=0
fi

# ─────────────────────────────────────────────────────────────────────────────
# B) NEGATIVE CONTROLS — the scanner is run whole, and its EXIT CODE asserted
# ─────────────────────────────────────────────────────────────────────────────
echo "-- B) synthetic controls: every guard proven to bite --"

GATE_OK="${WORK}/gate-ok.sh"
cat > "${GATE_OK}" <<'GEOF'
_opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" gw-a \
    '/svc/**'
GEOF
GATE_NONE="${WORK}/gate-none.sh"
printf '%s\n' 'echo "this gate drops no rows at all"' > "${GATE_NONE}"

# B1 — the SQL comment stripper removed NOTHING (rc 3).
#     A file with rows and no comments at all: legitimate SQL, but for THIS
#     subject a stripper that removes nothing is a stripper that stopped working.
cat > "${WORK}/no-comments.sql" <<'SEOF'
INSERT INTO gateway_route_access (gateway, url_pattern, role, allow) VALUES
  ('gw-a', '/svc/**', 'ROLE_X', true),
  ('gw-b', '/svc/**', 'ROLE_X', true);
SEOF
run_case "${GATE_OK}" "${WORK}/no-comments.sql"
if [ "${RC}" -eq 3 ]; then ok "B1 vacuity guard 1 BITES: stripper removed nothing -> rc 3"
else bad "B1 stripper-vacuity guard did not bite (rc=${RC}, wanted 3) — a no-op stripper would report clean"; fi

# B2 — the row regex matched NOTHING (rc 4).
cat > "${WORK}/no-rows.sql" <<'SEOF'
-- A schema with plenty of prose and not one parsable row.
-- It even quotes a row shape: ('gw','pattern','role',true|false)
CREATE TABLE gateway_route_access (gateway text, url_pattern text);
SEOF
run_case "${GATE_OK}" "${WORK}/no-rows.sql"
if [ "${RC}" -eq 4 ]; then ok "B2 vacuity guard 2 BITES: zero rows parsed -> rc 4"
else bad "B2 row-vacuity guard did not bite (rc=${RC}, wanted 4) — a scan that matched nothing would report clean"; fi

# B3 — the pre-existing "no _opt_drop_rows parsed" guard still bites (rc 2).
cat > "${WORK}/plain.sql" <<'SEOF'
-- canonical seed
INSERT INTO gateway_route_access (gateway, url_pattern, role, allow) VALUES
  ('gw-a', '/svc/**', 'ROLE_X', true);
SEOF
run_case "${GATE_NONE}" "${WORK}/plain.sql"
if [ "${RC}" -eq 2 ]; then ok "B3 the drop-vacuity guard still BITES: zero _opt_drop_rows parsed -> rc 2"
else bad "B3 drop-vacuity guard did not bite (rc=${RC}, wanted 2)"; fi

# B4 — A COMMENTED-OUT ROW MUST NOT BE SEEN. gw-b/c/d's rows for the dropped path
#      are commented out, so there is nothing left to clean there and the sweep is
#      CLEAN. Revert the stripper and the comments become data: rc 1.
#      THREE forms, because they fail SEPARATELY: a column-0 `--`, an INDENTED `--`
#      (a line-anchored `^--` stripper passes the first and admits this one), and a
#      `/* … */` block. This is also the one shape the 4-column regex cannot reject
#      on its own — unlike the phantom in section A, a commented-out REAL row is a
#      perfectly well-formed tuple, so the stripper is the only thing refusing it.
cat > "${WORK}/commented-row.sql" <<'SEOF'
-- canonical seed. The row shape is ('gw','pattern','role',true|false).
INSERT INTO gateway_route_access (gateway, url_pattern, role, allow) VALUES
  ('gw-a', '/svc/**', 'ROLE_X', true);
-- Historical, deliberately NOT live:
--   ('gw-b', '/svc/**', 'ROLE_X', true),
    --   ('gw-d', '/svc/**', 'ROLE_X', true),
/* and a block-commented one too:
     ('gw-c', '/svc/**', 'ROLE_X', true), */
SEOF
run_case "${GATE_OK}" "${WORK}/commented-row.sql"
if [ "${RC}" -eq 0 ]; then ok "B4 a COMMENTED-OUT row is not parsed as a live grant -> rc 0"
else bad "B4 commented-out rows leaked into the coverage map (rc=${RC}, wanted 0): ${OUT}"; fi

# B5 — A REAL DENY ROW MUST BE CLASSIFIED DENY. gw-b keeps an allow=false row for
#      the dropped path: fail-closed, reported as a note, NOT a coverage gap.
#      Revert the allow/deny split and it reads as a surviving grant: rc 1.
cat > "${WORK}/deny-row.sql" <<'SEOF'
-- canonical seed
INSERT INTO gateway_route_access (gateway, url_pattern, role, allow) VALUES
  ('gw-a', '/svc/**', 'ROLE_X', true),
  ('gw-b', '/svc/**', 'ROLE_X', false);
SEOF
run_case "${GATE_OK}" "${WORK}/deny-row.sql"
if [ "${RC}" -eq 0 ]; then ok "B5 an allow=false row is NOT counted as a surviving grant -> rc 0"
else bad "B5 a DENY row was graded as a grant (rc=${RC}, wanted 0): ${OUT}"; fi
case "${OUT}" in
  *"note: '/svc/**' keeps an allow=false DENY row on gw-b"*)
     ok "B5b the surviving DENY row is REPORTED (fail-closed), not silently dropped" ;;
  *) bad "B5b the surviving DENY row was not reported at all: ${OUT}" ;;
esac

# B6 — POSITIVE CONTROL: a genuine uncleaned GRANT still goes red (rc 1). Without
#      this, every rc-0 above could be a scanner that can no longer fail.
cat > "${WORK}/real-gap.sql" <<'SEOF'
-- canonical seed
INSERT INTO gateway_route_access (gateway, url_pattern, role, allow) VALUES
  ('gw-a', '/svc/**', 'ROLE_X', true),
  ('gw-b', '/svc/**', 'ROLE_X', true);
SEOF
run_case "${GATE_OK}" "${WORK}/real-gap.sql"
if [ "${RC}" -eq 1 ]; then ok "B6 an uncleaned GRANT on a second gateway is still a GAP -> rc 1"
else bad "B6 the sweep can no longer report a real gap (rc=${RC}, wanted 1): ${OUT}"; fi
case "${OUT}" in
  *"'/svc/**' still granted on gw-b"*) ok "B6b the gap NAMES the path and the gateway" ;;
  *) bad "B6b the gap was not named: ${OUT}" ;;
esac

# B7 — A `--` INSIDE A QUOTED VALUE IS NOT A COMMENT. A regex stripper
#      (`re.sub(r"--[^\n]*", "", sql)`) would eat the rest of this row and the
#      gap would vanish, so rc 1 here is the proof the stripper is quote-aware.
GATE_DD="${WORK}/gate-dd.sh"
cat > "${GATE_DD}" <<'GEOF'
_opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" gw-a \
    '/a--b/**'
GEOF
cat > "${WORK}/dashdash.sql" <<'SEOF'
-- canonical seed
INSERT INTO gateway_route_access (gateway, url_pattern, role, allow) VALUES
  ('gw-a', '/a--b/**', 'ROLE_X', true),
  ('gw-b', '/a--b/**', 'ROLE_X', true);
SEOF
run_case "${GATE_DD}" "${WORK}/dashdash.sql"
if [ "${RC}" -eq 1 ]; then ok "B7 a '--' inside a quoted url_pattern is data, not a comment -> the row survives and the gap is seen"
else bad "B7 a quoted '--' was treated as a comment (rc=${RC}, wanted 1): ${OUT}"; fi

# B8 — the doubled-quote escape ('') keeps a row parsable rather than swallowing
#      the rest of the statement.
cat > "${WORK}/escaped.sql" <<'SEOF'
-- canonical seed
INSERT INTO gateway_route_access (gateway, url_pattern, role, allow) VALUES
  ('gw-a', '/it''s/**', 'ROLE_X', true),
  ('gw-a', '/svc/**',  'ROLE_X', true),
  ('gw-b', '/svc/**',  'ROLE_X', true);
SEOF
run_case "${GATE_OK}" "${WORK}/escaped.sql"
if [ "${RC}" -eq 1 ]; then ok "B8 a doubled-quote escape does not desynchronise the parse (the /svc/** gap is still seen)"
else bad "B8 the '' escape broke the parse (rc=${RC}, wanted 1): ${OUT}"; fi

# ─────────────────────────────────────────────────────────────────────────────
# C) ANTI-ROT — the scanner is the one the stack suite actually runs
# ─────────────────────────────────────────────────────────────────────────────
echo "-- C) wiring --"
if [ -f "${STACK_SUITE}" ]; then
  if grep -F 'tests/scripts/route_access_coverage.py' "${STACK_SUITE}" >/dev/null 2>&1; then
    ok "C1 tests/stack/test-optional-services-exclude.sh invokes this scanner"
  else
    bad "C1 the stack suite no longer invokes tests/scripts/route_access_coverage.py — this guard would cover a file nothing runs"
  fi
else
  bad "C1 tests/stack/test-optional-services-exclude.sh is missing"
fi
if python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "${SCAN}" >/dev/null 2>&1; then
  ok "C2 the scanner compiles"
else
  bad "C2 the scanner does not compile"
fi

# ─────────────────────────────────────────────────────────────────────────────
# D) META-CONTROLS — section A's own fail-closed gates, proven to bite
# ─────────────────────────────────────────────────────────────────────────────
# Section B proves the SCANNER's guards bite by running the scanner against
# synthetic schemas. D does the same one level up: it re-runs SECTION A's harness
# against synthetic STAND-INS for route_access_coverage.py, so A0a/A0b/A0c are
# behaviour under test rather than unexercised wiring. Each stand-in is written
# from scratch rather than sed'd out of the real scanner: a textual mutant stops
# applying the moment the subject is reworded, and then proves nothing while
# still printing PASS.
#
# WHAT D DOES NOT COVER, stated rather than papered over: A0c's floor also exists
# to catch assertion ROT — rows DELETED from the heredoc above, all remaining rows
# green, status 0, stderr empty. No stand-in can plant that, because the rows are
# printed unconditionally by this file's own text; only editing this file could,
# and a guard may not assert on its own source. D4 covers the neighbouring shape
# (a PARTIAL section: some rows arrive, then it dies) and that is the honest
# statement of the coverage.
echo "-- D) meta-controls: section A fails CLOSED when the scanner changes shape --"

a_went_red(){   # 0 when section A's gates would have failed the suite
  [ "${A_RC}" -ne 0 ]              && return 0
  [ -s "${A_ERRF}" ]               && return 0
  [ "${A_FAILS}" -gt 0 ]           && return 0
  [ "${A_ROWS}" -lt "${A_MIN}" ]   && return 0
  return 1
}
export RAC_REAL="${SCAN}"

# D1 — THE REGRESSION ITSELF. parse_rows returns a 2-tuple: exactly the plausible
#      refactor that used to delete all eleven assertions and still exit 0.
cat > "${WORK}/rac-arity.py" <<'DEOF'
"""Stand-in whose parse_rows() returns a 2-tuple instead of (granted, denied, n_rows)."""
def strip_sql_comments(s):
    return s.replace("-- ", "")
def parse_rows(code):
    return {}, {}
DEOF
run_section_a "${WORK}/rac-arity.py" "${SQL}"
if a_went_red; then
  ok "D1 a parse_rows() ARITY change turns section A RED (rc=${A_RC} rows=${A_ROWS} fails=${A_FAILS}) — the eleven assertions cannot vanish into a '0 failed'"
else
  bad "D1 section A stayed GREEN against a scanner whose parse_rows returns the wrong arity — eleven assertions can still disappear silently"
fi

# D2 — THE STATUS GATE. SystemExit escapes `except Exception`, so the harness dies
#      with a status and NOTHING on stdout or stderr: only A0a's `$?` capture can
#      see it, and `$?` is precisely what the first spelling never took.
cat > "${WORK}/rac-exit.py" <<'DEOF'
"""Stand-in that terminates the harness with a status and no output at all."""
import sys
sys.exit(3)
DEOF
run_section_a "${WORK}/rac-exit.py" "${SQL}"
if [ "${A_RC}" -eq 3 ] && a_went_red; then
  ok "D2 the harness's EXIT STATUS is captured and asserted (rc=${A_RC}) — a status-only death is not read as success"
else
  bad "D2 a harness that exited with a status was not caught (rc=${A_RC} rows=${A_ROWS} fails=${A_FAILS}) — A0a is not capturing \$?"
fi

# D3 — THE STDERR GATE, ISOLATED. A stand-in that is FULLY FUNCTIONAL: it
#      delegates to the real scanner, so all eleven rows PASS and the status is 0.
#      Nothing but `[ -s "${A_ERRF}" ]` can notice it. Without this control that
#      redirect is untested wiring.
cat > "${WORK}/rac-noisy.py" <<'DEOF'
"""Stand-in that behaves EXACTLY like the real scanner and merely warns on stderr."""
import importlib.util, os, sys
_spec = importlib.util.spec_from_file_location("_rac_real", os.environ["RAC_REAL"])
_real = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_real)
strip_sql_comments = _real.strip_sql_comments
parse_rows = _real.parse_rows
sys.stderr.write("stand-in: a diagnostic that must NOT be discarded\n")
DEOF
run_section_a "${WORK}/rac-noisy.py" "${SQL}"
if [ "${A_RC}" -eq 0 ] && [ "${A_FAILS}" -eq 0 ] && [ "${A_ROWS}" -ge "${A_MIN}" ] && a_went_red; then
  ok "D3 STDERR alone turns section A red: ${A_ROWS} rows all green, rc 0, and the diagnostic is still not discarded"
elif [ "${A_REAL_GREEN}" -ne 0 ]; then
  bad "D3 the stderr gate is UNPROVEN in this run: this control delegates to the REAL scanner, and section A is already failing against it above — fix that failure, not this row"
elif a_went_red; then
  bad "D3 the otherwise-green stand-in went red for the WRONG reason (rc=${A_RC} rows=${A_ROWS} fails=${A_FAILS}) — the stderr gate is not isolated by this control any more"
else
  bad "D3 a harness that wrote to stderr was accepted — a traceback or warning would be discarded"
fi

# D4 — THE PARTIAL SECTION. parse_rows returns the right arity but the wrong
#      TYPES, so the first rows print and then an assertion body raises. No FAIL
#      row is emitted, so this is caught by the status/stderr/floor gates only —
#      the shape that most looks like "it ran and passed".
cat > "${WORK}/rac-partial.py" <<'DEOF'
"""Stand-in with the right arity and the wrong types: section A dies MID-WAY."""
def strip_sql_comments(s):
    return s.replace("-- ", "")
def parse_rows(code):
    return [], [], 0
DEOF
run_section_a "${WORK}/rac-partial.py" "${SQL}"
if [ "${A_FAILS}" -eq 0 ] && [ "${A_ROWS}" -lt "${A_MIN}" ] && a_went_red; then
  ok "D4 a section that dies PART-WAY (${A_ROWS} of ${A_MIN} rows, no FAIL row) is still red — a short section is not a clean one"
else
  bad "D4 a truncated section A was accepted (rc=${A_RC} rows=${A_ROWS} fails=${A_FAILS}) — partial output can pass as a full pass"
fi

echo "== route-access coverage scanner: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
