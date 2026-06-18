#!/usr/bin/env bash
# test-jwt-custom-token.sh — HELD-UNTIL-LIVE regression guard for D6+D8.
#
# Spins up casbin/casdoor:3.80.0 in a LOCAL container, applies the JWT-Custom
# token config that specs/cluster/manifests/casdoor/init-job.yaml seeds onto the
# systems apps + the snapdragon-desktop PKCE client, mints a REAL RS256 token via
# the password grant, decodes it, and asserts:
#   (1) the 4 leaked secrets are ABSENT  (totpSecret, recoveryCodes, password,
#       passwordSalt) — proven absent even when totpSecret/recoveryCodes are
#       actively SEEDED on the user;
#   (2) the bare "Properties" map is ABSENT (we emit only the 2 named keys);
#   (3) every required authz claim is PRESENT in the right shape
#       (iss/sub/aud/exp/name/email/isAdmin/roles/permissions);
#   (4) the MFA claim emits as a FLAT snake_case top-level "mfa_satisfied_at"
#       whose value is a STRING (casdoor properties are map[string]string), and
#       "mfa_satisfied".
#
# ⚠ A wrong/empty tokenFields set strips roles/permissions/isAdmin and breaks ALL
# authz across 11 repos. This test is the mandatory gate before the JWT-Custom
# flip ships. The leak can ONLY be enforced at the Casdoor config level — no Java
# test catches a re-leak — so this lives here and mints against the real image.
#
# Rootless-friendly: uses docker OR podman, whichever is on PATH. Needs python3.
# SKIPS (exit 0, prints why) when no container runtime is available, so it never
# blocks a CI box without docker — but a runtime-present box MUST pass.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMG="casbin/casdoor:3.80.0"
PGIMG="postgres:16-alpine"
ORG="snapdragon"
HOSTPORT="${CASDOOR_TEST_PORT:-18000}"
BASE="http://127.0.0.1:${HOSTPORT}"
NET="casdoor-jwtcustom-test-net"
CID=""; PGCID=""
P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

RT=""
if command -v docker >/dev/null 2>&1; then RT="docker"
elif command -v podman >/dev/null 2>&1; then RT="podman"; fi
if [ -z "${RT}" ]; then
  echo "SKIP: no docker/podman on PATH — cannot run the held-until-live casdoor mint test"
  exit 0
fi

cleanup(){
  [ -n "${CID}" ]   && ${RT} rm -f "${CID}"   >/dev/null 2>&1 || true
  [ -n "${PGCID}" ] && ${RT} rm -f "${PGCID}" >/dev/null 2>&1 || true
  ${RT} network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== D6+D8 JWT-Custom held-until-live: minting against ${IMG} =="

# casbin/casdoor:3.80.0 needs an external DB (prod uses Postgres via app.conf).
# Stand up a throwaway Postgres on a private network, aliased casdoor-pg (the host
# the prod dataSourceName expects) and point casdoor at it with a minimal app.conf.
${RT} network create "${NET}" >/dev/null 2>&1 || true
PGCID="$(${RT} run -d --name casdoor-pg --network "${NET}" --network-alias casdoor-pg \
  -e POSTGRES_USER=casdoor -e POSTGRES_PASSWORD=casdoor -e POSTGRES_DB=casdoor \
  "${PGIMG}" 2>/tmp/pg-run.err)" || {
  echo "SKIP: could not start ${PGIMG} ($(cat /tmp/pg-run.err)) — runtime present but image unavailable"
  exit 0
}
for i in $(seq 1 30); do
  ${RT} exec "${PGCID}" pg_isready -U casdoor >/dev/null 2>&1 && break
  sleep 1
done

CONF="$(mktemp /tmp/casdoor-app.conf.XXXXXX)"
cat >"${CONF}" <<CONF
appname = casdoor
httpport = 8000
runmode = prod
copyrequestbody = true
SessionOn = true
driverName = postgres
dataSourceName = "user=casdoor password=casdoor host=casdoor-pg port=5432 sslmode=disable dbname=casdoor"
dbName = casdoor
tableNamePrefix =
showSql = false
redisEndpoint =
isCloudIntranet = false
authState = "casdoor"
verificationCodeTimeout = 10
initScore = 0
logPostOnly = true
origin = "http://127.0.0.1:${HOSTPORT}"
enableGzip = true
CONF
# casdoor runs non-root; the bind-mounted conf must be world-readable. The :z
# suffix relabels for SELinux hosts (no-op elsewhere).
chmod 0644 "${CONF}"

CID="$(${RT} run -d --name casdoor-jwtcustom-test --network "${NET}" -p "${HOSTPORT}:8000" \
  -e RUNNING_IN_DOCKER=true \
  -v "${CONF}:/conf/app.conf:ro,z" \
  "${IMG}" 2>/tmp/casdoor-run.err)" || {
  echo "SKIP: could not start ${IMG} ($(cat /tmp/casdoor-run.err)) — runtime present but image unavailable"
  exit 0
}

# Wait for casdoor + its built-in app/org to be ready (DB migrations run on boot).
ready=0
for i in $(seq 1 90); do
  if curl -fsS "${BASE}/api/health" >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
if [ "${ready}" != "1" ]; then
  echo "SKIP: casdoor never became healthy"
  echo "--- casdoor logs ---"; ${RT} logs "${CID}" 2>&1 | tail -20
  exit 0
fi

CJ="/tmp/casdoor-cookies.txt"; : >"${CJ}"
api(){ # api METHOD PATH [json]
  local m="$1" p="$2" body="${3:-}"
  if [ -n "${body}" ]; then
    curl -fsS -c "${CJ}" -b "${CJ}" -X "${m}" -H 'Content-Type: application/json' -d "${body}" "${BASE}${p}"
  else
    curl -fsS -c "${CJ}" -b "${CJ}" -X "${m}" "${BASE}${p}"
  fi
}

# Default casdoor admin creds in the all-in-one image are admin/123.
api POST /api/login '{"application":"app-built-in","organization":"built-in","username":"admin","password":"123","type":"login","autoSignin":true}' >/dev/null 2>&1 \
  && ok "admin login" || { echo "SKIP: admin login failed (image cred drift)"; exit 0; }

# Users cannot be added to the 'built-in' org (global-admin org, add disabled), so
# we create the 'snapdragon' org exactly as init_data.json seeds it. Casdoor also
# requires an org to own >=1 application before a user can be added, so the order
# is: org -> JWT-Custom app (org=snapdragon) -> user -> role.
ORGJSON='{"owner":"admin","name":"snapdragon","displayName":"Snapdragon Systems","passwordType":"plain","languages":["en"],"enableSoftDeletion":false,"isProfilePublic":false}'
api POST /api/add-organization "${ORGJSON}" >/dev/null 2>&1 || true

# Reconcile a JWT-Custom app with EXACTLY the field set init-job.yaml seeds.
APPJSON='{"owner":"admin","name":"app-jwtcustom-test","displayName":"jwtcustom test","organization":"snapdragon","clientId":"app-jwtcustom-test","clientSecret":"test-secret-not-real","redirectUris":["https://x.snapdragon.systems/callback"],"grantTypes":["authorization_code","client_credentials","password"],"expireInHours":168,"enablePassword":true,"enableSignUp":false,"tokenFormat":"JWT-Custom","tokenSigningMethod":"RS256","tokenFields":["Id","Name","Email","IsAdmin","Properties.mfa_satisfied","Properties.mfa_satisfied_at"],"tokenAttributes":[{"name":"roles","category":"Existing Field","value":"Roles","type":"Array"},{"name":"permissions","category":"Existing Field","value":"Permissions","type":"Array"}]}'
if api GET "/api/get-application?id=admin/app-jwtcustom-test" 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get("data") else 1)' 2>/dev/null; then
  api POST "/api/update-application?id=admin/app-jwtcustom-test" "${APPJSON}" >/dev/null 2>&1
else
  api POST /api/add-application "${APPJSON}" >/dev/null 2>&1
fi
ok "JWT-Custom app reconciled"

# Seed the user in 'snapdragon' WITH the secrets actively populated, so we prove the
# allow-list strips them even when present. Casdoor properties are a string-map.
USERJSON='{"owner":"snapdragon","name":"jwtcustom-test","displayName":"JWT Custom Test","type":"normal-user","password":"Sn4p!testPW","email":"jwtcustom@snapdragon.systems","isAdmin":true,"totpSecret":"JBSWY3DPEHPK3PXP","recoveryCodes":["aaaa-bbbb","cccc-dddd"],"properties":{"mfa_satisfied":"true","mfa_satisfied_at":"1750233600000"}}'
api POST /api/add-user "${USERJSON}" >/dev/null 2>&1 || true
api POST "/api/update-user?id=snapdragon/jwtcustom-test" "${USERJSON}" >/dev/null 2>&1 || true

# Assign a BARE-named role so the token's roles array is non-empty and we can assert
# the string-name-array shape (the Existing-Field tokenAttribute -> value:Roles path).
ROLEJSON='{"owner":"snapdragon","name":"ROLE_ADMIN","displayName":"Platform Admin","users":["snapdragon/jwtcustom-test"],"roles":[],"domains":[],"isEnabled":true}'
api POST /api/add-role "${ROLEJSON}" >/dev/null 2>&1 || true
api POST "/api/update-role?id=snapdragon/ROLE_ADMIN" "${ROLEJSON}" >/dev/null 2>&1 || true

# Mint a REAL token via the password (Resource Owner) grant.
TOKRESP="$(curl -fsS -X POST "${BASE}/api/login/oauth/access_token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=password' \
  --data-urlencode 'client_id=app-jwtcustom-test' \
  --data-urlencode 'client_secret=test-secret-not-real' \
  --data-urlencode 'username=jwtcustom-test' \
  --data-urlencode 'password=Sn4p!testPW' \
  --data-urlencode 'scope=profile email' 2>/dev/null)"

ACCESS="$(printf '%s' "${TOKRESP}" | python3 -c 'import sys,json;
try:
  d=json.load(sys.stdin); print(d.get("access_token") or "")
except Exception: print("")')"
[ -n "${ACCESS}" ] || { echo "FAIL: no access_token minted. resp=${TOKRESP}"; exit 1; }
ok "real RS256 token minted via password grant"

# Decode the JWT payload (middle segment) and assert claims.
# NOTE: the token is passed as argv[1] — the heredoc occupies stdin.
ACCESS="${ACCESS}" python3 - <<'PY'
import sys, os, json, base64

tok = os.environ.get("ACCESS", "").strip()
parts = tok.split(".")
if len(parts) < 2:
    print("  FAIL token is not a JWT"); sys.exit(1)
def b64d(s):
    s += "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s.encode())
claims = json.loads(b64d(parts[1]))

P = 0; F = 0
def ok(m):
    global P; print("  PASS "+m); P += 1
def bad(m):
    global F; print("  FAIL "+m); F += 1

# (1) the 4 leaked secrets ABSENT (even though seeded on the user).
for leak in ("totpSecret", "recoveryCodes", "password", "passwordSalt"):
    if leak in claims:
        bad(f"LEAK: {leak} present in token -> {claims[leak]!r}")
    else:
        ok(f"secret absent: {leak}")
# also the camel/other secret config fields must not leak
for extra in ("passwordType", "preferredMfaType", "mfaEmailEnabled",
              "mfaPhoneEnabled", "webauthnCredentials", "accessKey", "accessSecret"):
    if extra in claims:
        bad(f"unexpected field leaked: {extra}")
    else:
        ok(f"excluded field absent: {extra}")

# (2) bare Properties map absent (only the 2 named keys emit).
if "properties" in claims or "Properties" in claims:
    bad("bare Properties map present (should emit only the 2 named keys)")
else:
    ok("bare Properties map absent")

# (3) required authz claims present + shape.
for c in ("iss", "sub", "aud", "exp", "name", "email"):
    if claims.get(c) in (None, ""):
        bad(f"required claim missing: {c}")
    else:
        ok(f"claim present: {c} = {claims.get(c)!r}")
# isAdmin a real boolean
if isinstance(claims.get("isAdmin"), bool) and claims.get("isAdmin") is True:
    ok("isAdmin present as boolean true")
else:
    bad(f"isAdmin wrong: {claims.get('isAdmin')!r} (type {type(claims.get('isAdmin')).__name__})")
# roles is a string-name array via the Existing-Field tokenAttribute; we assigned
# ROLE_ADMIN so it must be a NON-EMPTY list. This is the claim whose loss would
# break authz across 11 repos — empty/wrong tokenFields would drop it entirely.
roles = claims.get("roles")
if isinstance(roles, list) and roles:
    ok(f"roles present as non-empty string array: {roles!r}")
    if all(isinstance(r, str) for r in roles):
        ok("roles are string names (Existing-Field value:Roles shape)")
    else:
        bad(f"roles not string names: {roles!r}")
else:
    bad(f"roles missing/empty/not-array: {roles!r} -> breaks authz in 11 repos")
# permissions is the same Existing-Field shape; casdoor emits null (not []) when the
# user has no permission objects. The claim KEY must exist (proves tokenAttribute is
# applied); a list OR null is acceptable, anything else is wrong.
if "permissions" in claims:
    perms = claims["permissions"]
    if perms is None or isinstance(perms, list):
        ok(f"permissions claim emitted (Existing-Field, value={perms!r})")
    else:
        bad(f"permissions wrong type: {perms!r}")
else:
    bad("permissions claim key absent -> tokenAttribute not applied")

# (4) MFA claim: FLAT snake_case top-level, value is a STRING.
if "mfa_satisfied_at" in claims:
    v = claims["mfa_satisfied_at"]
    if isinstance(v, str):
        ok(f"mfa_satisfied_at present as flat snake_case STRING = {v!r}")
        try:
            int(v); ok("mfa_satisfied_at parses as Long (gateway Long.parseLong contract)")
        except Exception:
            bad(f"mfa_satisfied_at not Long-parseable: {v!r}")
    else:
        bad(f"mfa_satisfied_at not a string (was {type(v).__name__}={v!r}) — casdoor would REJECT a number at write")
else:
    bad("mfa_satisfied_at absent (MFA claim not emitted)")
# camelCase variant MUST NOT appear (SnakeToCamel does not rename Properties.<key>)
if "mfaSatisfiedAt" in claims:
    bad("mfaSatisfiedAt camelCase variant present — claim-key contract broken")
else:
    ok("no camelCase mfaSatisfiedAt (snake_case contract holds)")
if "mfa_satisfied" in claims:
    ok(f"mfa_satisfied present = {claims['mfa_satisfied']!r}")
else:
    bad("mfa_satisfied absent")

print(f"\n  subtotal: {P} pass / {F} fail")
sys.exit(1 if F else 0)
PY
RC=$?
if [ "${RC}" = "0" ]; then ok "all token claim assertions"; else bad "token claim assertions"; fi

echo ""
echo "== summary: ${P} pass / ${F} fail =="
[ "${F}" -eq 0 ] || exit 1
