#!/usr/bin/env bash
# test-bff-admin.sh — integration test for the admin BFF contract the admin-ui
# consumes: per-gateway role->URL route-access CRUD + latest-ISO links, both
# admin-gated. Starts the mock BFF standalone (no ClickHouse needed for these
# paths). Rootless; needs node + python3 + curl.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PORT="${PORT:-8409}"; B="http://localhost:${PORT}"
P=0; F=0; ok(){ echo "  PASS $*"; P=$((P+1)); }; bad(){ echo "  FAIL $*"; F=$((F+1)); }
jqp(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

PORT="${PORT}" node "${REPO}/tests/stack/mock-bff.mjs" >/tmp/test-bff.log 2>&1 &
BFF=$!; trap 'kill ${BFF} 2>/dev/null' EXIT
for i in $(seq 1 20); do curl -s "${B}/bff/admin/isos" >/dev/null 2>&1 && break; sleep 0.3; done

echo "== admin BFF: route-access + ISO links =="
# admin@ is seeded admin; register to create the account, grab the token.
ATOK="$(curl -s -XPOST "${B}/bff/register/google" -H 'content-type: application/json' \
  -d '{"email":"admin@hugmesh.net"}' | jqp 'd["token"]')"
[ -n "${ATOK}" ] && ok "admin session obtained" || bad "no admin token"

n0="$(curl -s "${B}/bff/admin/route-access" -H "authorization: Bearer ${ATOK}" | jqp 'len(d["rules"])')"
[ "${n0}" -ge 3 ] 2>/dev/null && ok "route-access seeded (${n0} rules)" || bad "route-access not seeded (${n0})"

n1="$(curl -s -XPOST "${B}/bff/admin/route-access" -H "authorization: Bearer ${ATOK}" \
  -H 'content-type: application/json' \
  -d '{"gateway":"hugmesh-be-gateway","url_pattern":"/api/admin/**","role":"ROLE_ADMIN"}' | jqp 'len(d["rules"])')"
[ "${n1}" -eq $((n0 + 1)) ] 2>/dev/null && ok "admin added a role->URL rule" || bad "add rule failed (${n1})"

rid="$(curl -s "${B}/bff/admin/route-access" -H "authorization: Bearer ${ATOK}" | jqp 'd["rules"][-1]["id"]')"
n2="$(curl -s -XDELETE "${B}/bff/admin/route-access" -H "authorization: Bearer ${ATOK}" \
  -H 'content-type: application/json' -d "{\"id\":\"${rid}\"}" | jqp 'len(d["rules"])')"
[ "${n2}" -eq "${n0}" ] 2>/dev/null && ok "admin removed a rule" || bad "delete rule failed (${n2})"

ni="$(curl -s "${B}/bff/admin/isos" -H "authorization: Bearer ${ATOK}" | jqp 'len(d["isos"])')"
[ "${ni}" -ge 1 ] 2>/dev/null && ok "ISO download links listed (${ni})" || bad "no ISO links"

code="$(curl -s -o /dev/null -w '%{http_code}' "${B}/bff/admin/route-access")"
[ "${code}" = "403" ] && ok "route-access denied without admin (403)" || bad "expected 403, got ${code}"
code="$(curl -s -o /dev/null -w '%{http_code}' "${B}/bff/admin/isos")"
[ "${code}" = "403" ] && ok "isos denied without admin (403)" || bad "expected 403, got ${code}"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
