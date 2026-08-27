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
if python3 "${GEN}" --sql "${SQL}" --out "${T}/fresh.ts" >"${T}/gen.log" 2>&1; then
  if diff -u "${OUT}" "${T}/fresh.ts" >"${T}/diff.txt" 2>&1; then
    ok "committed rbac-route-access.seed.ts == generated from 20-schema.sql"
  else
    sed -n '1,40p' "${T}/diff.txt"
    bad "the committed oracle has DRIFTED from the seed — run: python3 scripts/gen-route-access-oracle.py"
  fi
else
  cat "${T}/gen.log"
  bad "the generator could not run against the real seed"
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
