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
# NATIVE LOGIN, not the old OAuth-shaped mint. `POST /bff/register/google` was
# deliberately removed (509e042f, 2026-07-03) when the UI moved to the native
# username/password form; it 404s now, so `d["token"]` raised a KeyError, ATOK
# came back empty, and every assertion below cascaded into a false failure. The
# session lives in an httpOnly bff_session cookie; mock-bff.mjs's sessionOf()
# still accepts that same value as a Bearer, so only the MINT has to change.
LOGIN_PW="${E2E_PASSWORD:-e2e-pass}"
mint() { # <username> -> its bff_session token, or empty
  local hdrs
  hdrs="$(curl -s -D - -o /dev/null -XPOST "${B}/bff/login" \
      -H 'content-type: application/json' \
      -d "{\"username\":\"$1\",\"password\":\"${LOGIN_PW}\"}")"
  # No `| head -1` / `| grep -q`: an early-exiting downstream SIGPIPEs the writer
  # and `pipefail` turns that into a failure. See #156.
  printf '%s' "${hdrs}" | tr -d '\r' \
    | sed -n 's/^[Ss]et-[Cc]ookie:[[:space:]]*bff_session=\([^;]*\).*/\1/p'
}
ATOK="$(mint 'admin@hugmesh.net')"
[ -n "${ATOK}" ] && ok "admin session obtained (native login)" || bad "no admin token"

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

# ANON is 401, NOT 403 — and the distinction is the point, not a technicality.
# The BFF split them deliberately (0e8799e6, 2026-07-16) to mirror the real
# gateway: unauthenticated stops at anyExchange().authenticated() and is 401;
# 403 is what an AUTHENTICATED caller gets when the route-access role rule denies
# them. Asserting 403 for an anonymous caller passed only while the two were
# conflated, and it never tested the role rule at all.
for path in route-access isos; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "${B}/bff/admin/${path}")"
  [ "${code}" = "401" ] && ok "${path}: anonymous is 401 (unauthenticated)" \
    || bad "${path}: expected 401 for anon, got ${code}"
done

# ...and the assertion that was MISSING entirely: an authenticated NON-admin must
# be 403. Only this one exercises the admin role rule; probing anonymously proves
# nothing about it. alice@ is seeded with roles ['user'] and no admin.
UTOK="$(mint 'alice@gmail.com')"
if [ -n "${UTOK}" ]; then
  ok "non-admin session obtained (native login)"
  for path in route-access isos; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${B}/bff/admin/${path}" \
        -H "authorization: Bearer ${UTOK}")"
    [ "${code}" = "403" ] && ok "${path}: authenticated non-admin is 403 (role rule denies)" \
      || bad "${path}: expected 403 for an authenticated non-admin, got ${code}"
  done
else
  bad "could not mint a non-admin session — the 403 role-rule assertions did not run"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
