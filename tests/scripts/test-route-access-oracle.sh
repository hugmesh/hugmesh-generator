#!/usr/bin/env bash
# test-route-access-oracle.sh — the e2e route-access ORACLE must be the SEED.
#
# WHY THIS EXISTS. tests/e2e/specs/rbac-route-access.ts carried a hand-copied
# mirror of the gateway_route_access seed with the instruction "Keep in lockstep
# with that file". Measured 2026-08-26, by execution:
#
#     gatewayDecision('hugmesh-fe-gateway', '/bff/user/profile',  ['ROLE_USER']) -> DENY
#     gatewayDecision('hugmesh-fe-gateway', '/bff/user/profile/password', [...]) -> DENY
#     fe rows in the oracle: 11        fe rows in the seed: 77
#
# The real gateway ALLOWs every one of those. Six RBAC spec files assert against
# that oracle and all six were green. A mirror maintained by hand is a mirror that
# drifts, and a drifted oracle is worse than no oracle: it manufactures confidence.
#
# THE INVARIANT. tests/e2e/specs/rbac-route-access.seed.ts must be EXACTLY what
# scripts/gen-route-access-oracle.py emits from
# specs/cluster/manifests/route-access/initdb/20-schema.sql. Regenerate with:
#
#     python3 scripts/gen-route-access-oracle.py
#
# WHAT THIS GATE DOES **NOT** COVER, stated out loud: the DECISION FUNCTION in
# rbac-route-access.ts (longest-pattern, deny-wins, NO_RULE-is-not-DENY) is
# TypeScript and is exercised by tests/e2e/specs/12-rbac-gateway-route-access.spec.ts,
# not here. This script is offline python3 + bash so it can run in the same
# lint image as its siblings; it proves the TABLE, not the verdict.
#
# Offline: python3 + diff. No node, no cluster, no network. Writes only in mktemp.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
GEN="${REPO}/scripts/gen-route-access-oracle.py"
SQL="${REPO}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
OUT="${REPO}/tests/e2e/specs/rbac-route-access.seed.ts"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# A guard that skips is a guard that never guards.
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required (refusing to skip)" >&2; exit 1; }
command -v diff    >/dev/null 2>&1 || { echo "FATAL: diff required (refusing to skip)" >&2; exit 1; }
for f in "${GEN}" "${SQL}" "${OUT}"; do
  [ -r "${f}" ] || { echo "FATAL: cannot read ${f}" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT

echo "== route-access oracle: generated from the seed =="

# ── 1. the committed oracle matches a fresh generation ──────────────────────
# THREE outcomes, named apart. Before hugmesh-generator#404 this reported only
# "the committed oracle differs from a fresh run", which reads as "regenerate and
# commit" — the one thing you must not do when the fresh run is the SMALLER file.
python3 "${GEN}" --sql "${SQL}" --out "${T}/fresh.ts" >"${T}/gen.log" 2>&1
gen_rc=$?
if [ "${gen_rc}" -ne 0 ]; then
  cat "${T}/gen.log"
  case "${gen_rc}" in
    2) why="the seed is not the SHAPE the generator models (column list, terminator, pattern)" ;;
    3) why="a VACUITY floor was not cleared — almost nothing parsed" ;;
    4) why="COMPLETENESS: rows exist in the seed that the parse did not emit (hugmesh-generator#404's mode)" ;;
    *) why="the generator crashed" ;;
  esac
  bad "the generator REFUSED to emit (exit ${gen_rc}): ${why}. Fail-closed working as intended — fix the cause named above. There is nothing to commit."
elif diff -u "${OUT}" "${T}/fresh.ts" >"${T}/diff.txt" 2>&1; then
  ok "committed rbac-route-access.seed.ts == generated from 20-schema.sql"
else
  sed -n '1,40p' "${T}/diff.txt"
  have="$(grep -ac "gateway: 'hugmesh-" "${OUT}" || true)"
  fresh="$(grep -ac "gateway: 'hugmesh-" "${T}/fresh.ts" || true)"
  if [ "${fresh}" -lt "${have}" ]; then
    bad "the fresh generation carries FEWER rows than the committed oracle (${have} -> ${fresh}). That is a LOSS, not drift — find out what stopped parsing BEFORE you commit the smaller file."
  else
    bad "the committed oracle has DRIFTED from the seed (${have} -> ${fresh} rows) — if the seed change is intended, run: python3 scripts/gen-route-access-oracle.py"
  fi
fi

# ── 2. vacuity: the committed oracle really carries the whole seed ──────────
# Comment-stripped counts on BOTH sides (comment-token inversion has bitten this
# repo repeatedly), compared to each other rather than to a frozen literal.
sql_rows="$(sed 's/--.*//' "${SQL}" | grep -cE "^[[:space:]]*\('hugmesh-")"
sql_fe="$(sed 's/--.*//' "${SQL}" | grep -cE "^[[:space:]]*\('hugmesh-fe-gateway'")"
ts_rows="$(sed 's|//.*||' "${OUT}" | grep -c "gateway: 'hugmesh-")"
ts_fe="$(sed 's|//.*||' "${OUT}" | grep -c "gateway: 'hugmesh-fe-gateway'")"
if [ "${sql_rows}" -ge 100 ] && [ "${sql_fe}" -ge 50 ]; then
  ok "vacuity: the seed really parsed (${sql_rows} rows, ${sql_fe} on the fe-gateway)"
else
  bad "vacuity: only ${sql_rows} seed row(s) / ${sql_fe} fe row(s) counted — the counter has gone blind"
fi
if [ "${ts_rows}" = "${sql_rows}" ] && [ "${ts_fe}" = "${sql_fe}" ]; then
  ok "row counts agree: oracle ${ts_rows}/${ts_fe} fe == seed ${sql_rows}/${sql_fe} fe"
else
  bad "row counts DISAGREE: oracle ${ts_rows} (${ts_fe} fe) vs seed ${sql_rows} (${sql_fe} fe)"
fi

# ── 3. the oracle must be able to express an explicit DENY ─────────────────
# The old RouteRule interface had no `allow` field, so the seed's four allow=false
# rows were unrepresentable and "correct" only because they were absent.
den="$(sed 's|//.*||' "${OUT}" | grep -c "allow: false")"
sqlden="$(sed 's/--.*//' "${SQL}" | grep -cE "^[[:space:]]*\('hugmesh-.*, *false\)")"
if [ "${den}" -gt 0 ] && [ "${den}" = "${sqlden}" ]; then
  ok "explicit-DENY rows carried through: ${den} (seed has ${sqlden})"
else
  bad "explicit-DENY rows: oracle ${den} vs seed ${sqlden} — allow=false must survive generation"
fi

# ── 4. negative controls: each corruption of the SEED must be caught ────────
# Every control is a PAIR where it can be: the defective input must be rejected
# (or must produce a DIFFERENT oracle), and the pristine input must be accepted —
# otherwise the control could be failing for a reason unrelated to the property.
echo "-- negative controls (each defect must bite) --"

ctl_pristine() { python3 "${GEN}" --sql "$1" --stdout >"${T}/p.ts" 2>"${T}/p.err"; }

# 4a. THE SHIPPED DEFECT, in reverse: delete the single load-bearing row
#     ('hugmesh-fe-gateway','/bff/user/**','ROLE_USER',true) and the generated
#     oracle must CHANGE. If it does not, the generator is not reading the seed.
sed "/('hugmesh-fe-gateway',  '\/bff\/user\/\*\*'/d" "${SQL}" > "${T}/nouser.sql"
if diff -q "${SQL}" "${T}/nouser.sql" >/dev/null; then
  bad "control 'row deletion': the sed did not change the seed copy — the control proves nothing"
elif python3 "${GEN}" --sql "${T}/nouser.sql" --stdout >"${T}/nouser.ts" 2>/dev/null \
     && ! diff -q "${OUT}" "${T}/nouser.ts" >/dev/null 2>&1 \
     && ctl_pristine "${SQL}" && diff -q "${OUT}" "${T}/p.ts" >/dev/null; then
  before="$(grep -c "urlPattern: '/bff/user/\*\*'" "${OUT}")"
  after="$(grep -c "urlPattern: '/bff/user/\*\*'" "${T}/nouser.ts" || true)"
  ok "control 'row deletion': removing /bff/user/** changed the oracle (${before} -> ${after} rows), pristine seed still reproduces it"
else
  bad "control 'row deletion': the oracle did NOT track the seed edit — it is not derived from it"
fi

# 4b. A NEW COLUMN in the INSERT must ABORT, never be silently dropped: `domain`
#     and `casdoor_user` CHANGE the decision.
sed "s/INSERT INTO gateway_route_access (gateway, url_pattern, role, allow) VALUES/INSERT INTO gateway_route_access (gateway, url_pattern, role, allow, domain) VALUES/" \
  "${SQL}" > "${T}/newcol.sql"
if diff -q "${SQL}" "${T}/newcol.sql" >/dev/null; then
  bad "control 'new column': the sed did not change the seed copy"
elif ! python3 "${GEN}" --sql "${T}/newcol.sql" --stdout >/dev/null 2>&1; then
  ok "control 'new column': a changed INSERT column list ABORTS instead of dropping the column"
else
  bad "control 'new column': the generator emitted an oracle for an INSERT shape it does not model"
fi

# 4c. A BLINDED extractor must ABORT, not emit a small green oracle. Simulated by
#     mangling the tuple punctuation so the row regex stops matching.
sed "s/^\([[:space:]]*\)('hugmesh-/\1(hugmesh-/" "${SQL}" > "${T}/blind.sql"
if diff -q "${SQL}" "${T}/blind.sql" >/dev/null; then
  bad "control 'blinded extractor': the sed did not change the seed copy"
elif ! python3 "${GEN}" --sql "${T}/blind.sql" --stdout >/dev/null 2>&1; then
  ok "control 'blinded extractor': a row scan that stops matching ABORTS (row floor), never emits a vacuous oracle"
else
  bad "control 'blinded extractor': a broken row scan still produced an oracle"
fi

# 4d. A PATTERN SHAPE the oracle's matcher cannot honour must ABORT rather than
#     silently mismatch at assert time.
sed "s|'/bff/user/\*\*'|'/bff/user/{id}/**'|" "${SQL}" > "${T}/shape.sql"
if diff -q "${SQL}" "${T}/shape.sql" >/dev/null; then
  bad "control 'unsupported pattern': the sed did not change the seed copy"
elif ! python3 "${GEN}" --sql "${T}/shape.sql" --stdout >/dev/null 2>&1; then
  ok "control 'unsupported pattern': an Ant construct the matcher does not implement ABORTS"
else
  bad "control 'unsupported pattern': a {var} pattern was emitted into a matcher that cannot honour it"
fi

# 4e. A SECOND seed INSERT (a plausible future "additive rows" block) must ABORT
#     rather than have half the rows silently ignored.
{ cat "${SQL}"; echo; echo "INSERT INTO gateway_route_access (gateway, url_pattern, role, allow) VALUES ('hugmesh-fe-gateway','/zz/**','ROLE_USER',true) ON CONFLICT DO NOTHING;"; } > "${T}/two.sql"
if ! python3 "${GEN}" --sql "${T}/two.sql" --stdout >/dev/null 2>&1; then
  ok "control 'second INSERT': more than one row-seeding INSERT ABORTS instead of ignoring one"
else
  bad "control 'second INSERT': a second seed INSERT was silently ignored"
fi

# 4f. hugmesh-generator#404, THE SHIPPED DEFECT: a `--` comment inside the INSERT
#     body that merely NAMED the ON CONFLICT clause used to truncate the row scan
#     at that comment, because the terminator was located BEFORE comments were
#     stripped. Measured 2026-09-16 on the 154-row seed of that day (155 since
#     #347 decision 28): 154 rows -> 119, every hugmesh-superadmin-gateway row
#     and 25 fe rows gone, exit 0, both floors still satisfied. PROSE
#     MUST NOT BE ABLE TO CHANGE THE ORACLE — the output has to be byte-identical.
awk '/^INSERT INTO gateway_route_access/ && !d { print; print "  -- NOTE: the tail of this INSERT is ON CONFLICT DO NOTHING."; d=1; next } { print }' \
  "${SQL}" > "${T}/cmt.sql"
committed_rows="$(grep -ac "gateway: 'hugmesh-" "${OUT}" || true)"
if diff -q "${SQL}" "${T}/cmt.sql" >/dev/null; then
  bad "control '#404 line-comment truncation': the awk did not change the seed copy — the control proves nothing"
elif python3 "${GEN}" --sql "${T}/cmt.sql" --stdout >"${T}/cmt.ts" 2>"${T}/cmt.err" && cmp -s "${OUT}" "${T}/cmt.ts"; then
  ok "control '#404 line-comment truncation': a '-- … ON CONFLICT …' comment in the INSERT body leaves the oracle byte-identical (${committed_rows} rows)"
else
  bad "control '#404 line-comment truncation': naming ON CONFLICT in a comment changed the oracle ($(grep -ac "gateway: 'hugmesh-" "${T}/cmt.ts" 2>/dev/null || echo 0) rows vs ${committed_rows}) — comments are being read as SQL again"
fi

# 4g. Same defect via a BLOCK comment. The old stripper was `re.sub(r"--[^\n]*")`,
#     which could not see `/* … */` at all, so this variant would have survived a
#     fix that only reordered the line-comment strip.
awk '/^INSERT INTO gateway_route_access/ && !d { print; print "  /* tail of this INSERT: ON CONFLICT DO NOTHING */"; d=1; next } { print }' \
  "${SQL}" > "${T}/blk.sql"
if diff -q "${SQL}" "${T}/blk.sql" >/dev/null; then
  bad "control '#404 block-comment truncation': the awk did not change the seed copy"
elif python3 "${GEN}" --sql "${T}/blk.sql" --stdout >"${T}/blk.ts" 2>"${T}/blk.err" && cmp -s "${OUT}" "${T}/blk.ts"; then
  ok "control '#404 block-comment truncation': a '/* … ON CONFLICT … */' comment in the INSERT body leaves the oracle byte-identical"
else
  bad "control '#404 block-comment truncation': a block comment naming ON CONFLICT changed the oracle — the stripper is not character-wise"
fi

# 4h. ACCOUNTABILITY: a row the tuple scan cannot READ must abort, not be skipped.
#     `true` -> `1` is one character and used to cost exactly one row silently,
#     absorbed by the floors. Exit 4 is the generator's "completeness" code, which
#     check 1 above relies on to name the failure mode.
awk -v pat="  ('hugmesh-" 'index($0,pat)==1 && !d && sub(/, *true\)/, ", 1)") { d=1 } { print }' \
  "${SQL}" > "${T}/badrow.sql"
python3 "${GEN}" --sql "${T}/badrow.sql" --stdout >/dev/null 2>"${T}/badrow.err"; badrow_rc=$?
if diff -q "${SQL}" "${T}/badrow.sql" >/dev/null; then
  bad "control 'unreadable row': the awk did not change the seed copy"
elif [ "${badrow_rc}" = "4" ]; then
  ok "control 'unreadable row': a tuple the row scan cannot parse ABORTS (exit 4), never silently costs a row"
else
  bad "control 'unreadable row': exit ${badrow_rc} (wanted 4) — a row the scan cannot read was absorbed instead of reported"
fi

# 4i. A whole GATEWAY reaching zero rows must abort. This is #404's visible
#     symptom: hugmesh-superadmin-gateway went 9 -> 0 and nothing said so, because
#     the only completeness argument was a total-row floor the loss still cleared.
grep -av "^  ('hugmesh-superadmin-gateway'" "${SQL}" > "${T}/nogw.sql"
python3 "${GEN}" --sql "${T}/nogw.sql" --stdout >/dev/null 2>"${T}/nogw.err"; nogw_rc=$?
if diff -q "${SQL}" "${T}/nogw.sql" >/dev/null; then
  bad "control 'gateway to zero': the grep did not change the seed copy"
elif [ "${nogw_rc}" = "4" ]; then
  ok "control 'gateway to zero': losing every hugmesh-superadmin-gateway row ABORTS (exit 4) — the row floors alone did not catch this"
else
  bad "control 'gateway to zero': exit ${nogw_rc} (wanted 4) — a gateway silently reached zero rows, which is exactly #404"
fi

# 4j. THE TERMINATOR MUST BE THE REAL STATEMENT END. A stray `;` mid-body ends the
#     statement early and strands the rows below it. The generator must notice that
#     rows exist in the file which it did not emit, rather than emit the short set.
awk -v pat="  ('hugmesh-superadmin-gateway'" 'index($0,pat)==1 && !d { print; print ";"; d=1; next } { print }' \
  "${SQL}" > "${T}/semi.sql"
python3 "${GEN}" --sql "${T}/semi.sql" --stdout >/dev/null 2>"${T}/semi.err"; semi_rc=$?
if diff -q "${SQL}" "${T}/semi.sql" >/dev/null; then
  bad "control 'early terminator': the awk did not change the seed copy"
elif [ "${semi_rc}" = "4" ]; then
  ok "control 'early terminator': a statement that ends early leaves rows unaccounted for and ABORTS (exit 4)"
else
  bad "control 'early terminator': exit ${semi_rc} (wanted 4) — rows below an early terminator were dropped quietly"
fi

# 4k. A SECOND `ON CONFLICT` inside the one statement is ambiguous, not a hint:
#     the scan must refuse rather than pick the first and stop there.
awk '/^INSERT INTO gateway_route_access/ && !d { print; print "  ON CONFLICT DO NOTHING"; d=1; next } { print }' \
  "${SQL}" > "${T}/twooc.sql"
if diff -q "${SQL}" "${T}/twooc.sql" >/dev/null; then
  bad "control 'two ON CONFLICT clauses': the awk did not change the seed copy"
else
  python3 "${GEN}" --sql "${T}/twooc.sql" --stdout >/dev/null 2>"${T}/twooc.err"; twooc_rc=$?
  # Exit 2 specifically: the ambiguity must be diagnosed AS ambiguity. Exit 4 here
  # would mean only the downstream completeness cross-check noticed, which aborts
  # for the right reason with the wrong explanation.
  if [ "${twooc_rc}" = "2" ]; then
    ok "control 'two ON CONFLICT clauses': an ambiguous terminator ABORTS as a shape error (exit 2), not cut-at-the-first"
  else
    bad "control 'two ON CONFLICT clauses': exit ${twooc_rc} (wanted 2) — the ambiguity was not diagnosed as one"
  fi
fi

# 4l. THE TERMINATOR MUST BE LITERAL-AWARE. A `;` inside a row literal is not the
#     end of the statement. A naive `find(";")` stops inside that value and
#     strands every row below it; the seed is one `/`-path away from this at all
#     times, so the property is checked rather than assumed.
awk -v row="  ('hugmesh-fe-gateway', '/semi;colon/**', 'ROLE_USER', true)," \
  '/^INSERT INTO gateway_route_access/ && !d { print; print row; d=1; next } { print }' \
  "${SQL}" > "${T}/semilit.sql"
python3 "${GEN}" --sql "${T}/semilit.sql" --stdout >"${T}/semilit.ts" 2>"${T}/semilit.err"; semilit_rc=$?
semilit_rows="$(grep -ac "gateway: 'hugmesh-" "${T}/semilit.ts" || true)"
want_rows=$(( committed_rows + 1 ))
if diff -q "${SQL}" "${T}/semilit.sql" >/dev/null; then
  bad "control 'semicolon inside a literal': the awk did not change the seed copy"
elif [ "${semilit_rc}" = "0" ] && [ "${semilit_rows}" = "${want_rows}" ]; then
  ok "control 'semicolon inside a literal': a ';' in a url_pattern does not end the statement (${semilit_rows} rows, all accounted for)"
else
  bad "control 'semicolon inside a literal': exit ${semilit_rc}, ${semilit_rows} rows (wanted 0 / ${want_rows}) — the terminator is not literal-aware"
fi

# 4m. THE NEW GUARD MUST ITSELF BE GUARDED. assert_no_double_dash_in_values was
#     added by hugmesh-generator#404 precisely because the module docstring had
#     CITED a function of that name since the file was written and it did not
#     exist — an assumption documented as checked and never checked. Shipping the
#     real function is worth nothing unless something goes red when it stops
#     working, so this control exists; without it, neutering the guard leaves the
#     whole suite at 17/17 green (measured 2026-09-17).
#     Each token it rejects is exercised SEPARATELY, so dropping one of them from
#     the tuple is caught rather than masked by the other two. These are not parse
#     hazards any more — strip_sql_comments is literal-aware — they corrupt the
#     GATE'S OWN counters in checks 2 and 3 above (`sed 's/--.*//'` over the SQL,
#     `sed 's|//.*||'` over the TS) and the emitter writes literals into
#     TypeScript unescaped, so a `\` changes what the oracle MEANS.
tok_fail=0
tok_why=""
for tok in '--' '//' '\'; do
  printf "%s\n" "  ('hugmesh-fe-gateway', '/tok${tok}tok/**', 'ROLE_USER', true)," > "${T}/tokrow.txt"
  sed "/^INSERT INTO gateway_route_access/r ${T}/tokrow.txt" "${SQL}" > "${T}/tok.sql"
  if diff -q "${SQL}" "${T}/tok.sql" >/dev/null; then
    tok_fail=$((tok_fail+1)); tok_why="${tok_why} [${tok}: not injected, the control proves nothing]"; continue
  fi
  python3 "${GEN}" --sql "${T}/tok.sql" --stdout >"${T}/tok.ts" 2>"${T}/tok.err"; tok_rc=$?
  # Exit 2 specifically: this is a SHAPE refusal. Exit 0 means the guard is gone
  # and a corrupting literal was emitted (measured: 155 rows, happily written).
  if [ "${tok_rc}" != "2" ]; then
    tok_fail=$((tok_fail+1)); tok_why="${tok_why} [${tok}: exit ${tok_rc}, wanted 2]"
  fi
done
if [ "${tok_fail}" -eq 0 ] && ctl_pristine "${SQL}" && diff -q "${OUT}" "${T}/p.ts" >/dev/null; then
  ok "control 'comment token in a row literal': '--', '//' and a backslash inside a url_pattern EACH abort (exit 2), and the pristine seed still reproduces the oracle"
else
  bad "control 'comment token in a row literal': assert_no_double_dash_in_values did not bite —${tok_why:- the pristine seed stopped reproducing the oracle}"
fi

# ── 5. anti-rot: the source path the generator names must exist ─────────────
# The previous mirror pointed at manifests/route-access/schema.sql, a path that
# had not existed for months, and nobody noticed because nothing checked.
src="$(sed -n 's|^// *\(specs/cluster/.*\.sql\) *$|\1|p' "${OUT}" | head -1)"
if [ -n "${src}" ] && [ -r "${REPO}/${src}" ]; then
  ok "anti-rot: the oracle names a source path that exists (${src})"
else
  bad "anti-rot: the oracle's declared source path '${src:-<none>}' does not exist"
fi

echo
echo "== route-access oracle: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
