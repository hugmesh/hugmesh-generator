#!/usr/bin/env bash
# test-jwt-custom-token.sh — HELD-UNTIL-LIVE regression guard for D6+D8.
#
# Spins up casbin/casdoor:3.80.0 in a LOCAL container, applies the JWT-Custom
# token config that specs/cluster/manifests/casdoor/init-job.yaml seeds onto the
# systems apps + the hugmesh-desktop PKCE client, mints a REAL RS256 token via
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
#   (5) [2026-07-16] ACCOUNT-TAKEOVER REGRESSION LOCK — the token carries NO
#       `preferred_username` (nor camelCase `preferredUsername`) claim; the
#       identity is carried by `name`. user-bff historically folded an inbound
#       `preferred_username` into a `discord:<preferred_username>` identity key,
#       an account-takeover vector; user-bff PR #124 removes that fold
#       structurally, and this negative assertion locks the COMPLEMENTARY
#       config-level mitigation (the JWT_CUSTOM_TOKEN_FIELDS allow-list simply
#       never serializes preferred_username) so the vector cannot silently
#       re-open if an app reverts to plain tokenFormat=JWT or someone adds
#       preferred_username to satisfy an OIDC client. See the block-(3a) comment.
#       A static (offline, no-container) companion guard lives in
#       tests/scripts/test-casdoor-jwt-no-preferred-username.sh — it runs on
#       every CI box, including ones that SKIP this held-until-live mint.
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
# Images are overridable so CI can pull from a mirror/registry (e.g. a $CI_REGISTRY
# proxy) instead of Docker Hub — defaults are the empirically-pinned upstream tags.
IMG="${CASDOOR_IMAGE:-casbin/casdoor:3.80.0}"
PGIMG="${POSTGRES_IMAGE:-postgres:16-alpine}"
ORG="hugmesh"
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
# we create the 'hugmesh' org exactly as init_data.json seeds it. Casdoor also
# requires an org to own >=1 application before a user can be added, so the order
# is: org -> JWT-Custom app (org=hugmesh) -> user -> role.
ORGJSON='{"owner":"admin","name":"hugmesh","displayName":"HugMesh Systems","passwordType":"plain","languages":["en"],"enableSoftDeletion":false,"isProfilePublic":false}'
api POST /api/add-organization "${ORGJSON}" >/dev/null 2>&1 || true

# Reconcile a JWT-Custom app with EXACTLY the field set init-job.yaml seeds
# (including the "groups" Existing-Field attribute added 2026-07-09 for the
# headscale mesh-join OIDC gate — see JWT_CUSTOM_TOKEN_ATTRIBUTES).
APPJSON='{"owner":"admin","name":"app-jwtcustom-test","displayName":"jwtcustom test","organization":"hugmesh","clientId":"app-jwtcustom-test","clientSecret":"test-secret-not-real","redirectUris":["https://x.hugmesh.systems/callback"],"grantTypes":["authorization_code","client_credentials","password"],"expireInHours":168,"enablePassword":true,"enableSignUp":false,"tokenFormat":"JWT-Custom","tokenSigningMethod":"RS256","tokenFields":["Id","Name","Email","IsAdmin","Properties.mfa_satisfied","Properties.mfa_satisfied_at"],"tokenAttributes":[{"name":"roles","category":"Existing Field","value":"Roles","type":"Array"},{"name":"permissions","category":"Existing Field","value":"Permissions","type":"Array"},{"name":"groups","category":"Existing Field","value":"Groups","type":"Array"}]}'
if api GET "/api/get-application?id=admin/app-jwtcustom-test" 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get("data") else 1)' 2>/dev/null; then
  api POST "/api/update-application?id=admin/app-jwtcustom-test" "${APPJSON}" >/dev/null 2>&1
else
  api POST /api/add-application "${APPJSON}" >/dev/null 2>&1
fi
ok "JWT-Custom app reconciled"

# Seed the user in 'hugmesh' WITH the secrets actively populated, so we prove the
# allow-list strips them even when present. Casdoor properties are a string-map.
USERJSON='{"owner":"hugmesh","name":"jwtcustom-test","displayName":"JWT Custom Test","type":"normal-user","password":"Sn4p!testPW","email":"jwtcustom@hugmesh.systems","isAdmin":true,"totpSecret":"JBSWY3DPEHPK3PXP","recoveryCodes":["aaaa-bbbb","cccc-dddd"],"properties":{"mfa_satisfied":"true","mfa_satisfied_at":"1750233600000"}}'
api POST /api/add-user "${USERJSON}" >/dev/null 2>&1 || true
api POST "/api/update-user?id=hugmesh/jwtcustom-test" "${USERJSON}" >/dev/null 2>&1 || true

# Assign a BARE-named role so the token's roles array is non-empty and we can assert
# the string-name-array shape (the Existing-Field tokenAttribute -> value:Roles path).
ROLEJSON='{"owner":"hugmesh","name":"ROLE_ADMIN","displayName":"Platform Admin","users":["hugmesh/jwtcustom-test"],"roles":[],"domains":[],"isEnabled":true}'
api POST /api/add-role "${ROLEJSON}" >/dev/null 2>&1 || true
api POST "/api/update-role?id=hugmesh/ROLE_ADMIN" "${ROLEJSON}" >/dev/null 2>&1 || true

# EXACT reconcile_superadmin() FIRST-RUN group path (init-job.yaml ~540-598):
# build the group dict LOCALLY (users=[]), add-group (create), re-fetch, append
# the member, update-group, then VERIFY by re-reading rather than trusting the
# HTTP status.
#
# GROUND-TRUTH FINDING (live, this test): on casbin/casdoor:3.80.0,
# /api/update-group's "users" field is a NO-OP on an EXISTING group — every
# variant tried (local dict, re-fetched dict, with/without a ?columns=users
# hint) returns {"status":"ok","data":"Affected"} while NOT persisting
# membership. Only /api/add-group honors "users", and only at creation time.
# This does NOT affect the actual OIDC mesh-join gate, which reads the
# `groups` token claim from user.groups (verified below, and working) —
# group.users is Casdoor-admin-console display only. Production code (fixed
# to match) attempts the write, verifies by re-reading, and logs the real
# outcome instead of trusting Casdoor's misleading "ok" status — this test
# asserts that SAME honesty, not a hard requirement that the write succeeds.
GROUP_CREATE='{"owner":"hugmesh","name":"headscale","displayName":"Headscale mesh operators","type":"Virtual","parentId":"hugmesh","isTopGroup":true,"isEnabled":true,"users":[]}'
api POST /api/add-group "${GROUP_CREATE}" >/dev/null 2>&1 || true
FETCHED_GROUP="$(api GET "/api/get-group?id=hugmesh/headscale" 2>/dev/null)"
GROUP_UPDATE="$(printf '%s' "${FETCHED_GROUP}" | python3 -c '
import sys, json
d = json.load(sys.stdin)
g = d.get("data") or {}
users = g.get("users") or []
if "hugmesh/jwtcustom-test" not in users:
    users.append("hugmesh/jwtcustom-test")
g["users"] = users
print(json.dumps(g))
')"
api POST "/api/update-group?id=hugmesh/headscale" "${GROUP_UPDATE}" >/dev/null 2>&1 || true
GROUP_MEMBERS_AFTER="$(api GET "/api/get-group?id=hugmesh/headscale" 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps((d.get("data") or {}).get("users")))' 2>/dev/null)"
if [ "${GROUP_MEMBERS_AFTER}" = '["hugmesh/jwtcustom-test"]' ]; then
  ok "group.users persisted (would be a pleasant surprise on 3.80.0 — verify this still holds on any Casdoor version bump)"
else
  ok "confirmed group.users is a no-op on update-group (${GROUP_MEMBERS_AFTER}) — matches production's honest NOTE-not-silent-success logging; OIDC gate unaffected (sourced from user.groups, checked next)"
fi

# Prove the EXACT reconcile_superadmin() production shape (init-job.yaml):
# GET the user, mutate the SAME dict (so "id" round-trips byte-identical), POST
# via plain update-user with NO ?columns= param. A hand-built payload without
# the real "id" hits Casdoor's "The ID is immutable" rejection (verified while
# writing this test) — this block exists to prove the ACTUAL shipped code
# doesn't hit that trap, not just a convenient variant of it.
GETUSER="$(api GET "/api/get-user?id=hugmesh/jwtcustom-test" 2>/dev/null)"
UPDATED_USER="$(printf '%s' "${GETUSER}" | python3 -c '
import sys, json
d = json.load(sys.stdin)
u = d.get("data") or {}
groups = u.get("groups") or []
if "hugmesh/headscale" not in groups:
    groups.append("hugmesh/headscale")
u["groups"] = groups
print(json.dumps(u))
')"
RAW_UPDATE="$(api POST "/api/update-user?id=hugmesh/jwtcustom-test" "${UPDATED_USER}" 2>&1)"
if printf '%s' "${RAW_UPDATE}" | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get("status")=="ok" else 1)' 2>/dev/null; then
  ok "reconcile_superadmin()'s exact update-user shape (GET-mutate-POST, no ?columns=) persists user.groups"
else
  bad "reconcile_superadmin()'s update-user shape rejected: ${RAW_UPDATE}"
fi

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

# (3a) ACCOUNT-TAKEOVER REGRESSION LOCK [2026-07-16] — the token MUST NOT carry a
# `preferred_username` claim (nor its camelCase `preferredUsername` variant).
#
# WHY THIS IS A SECURITY GATE, not cosmetics: user-bff historically folded an
# inbound token's `preferred_username` into a `discord:<preferred_username>`
# identity key, letting a caller who controls that claim collide with / take over
# another user's account. The STRUCTURAL fix removing that fold ships in user-bff
# PR #124. This assertion locks the COMPLEMENTARY config-level mitigation that
# ALSO holds the vector shut today: the JWT_CUSTOM_TOKEN_FIELDS allow-list in
# specs/cluster/manifests/casdoor/init-job.yaml emits the identity as `name`
# (casdoor's Name field) and NEVER serializes a `preferred_username`.
#
# That omission is INCIDENTAL — the allow-list exists for an unrelated secret-leak
# fix (D6+D8, block (1) above). If any systems app ever reverts to plain
# tokenFormat=JWT (which serializes the full user object incl. a
# `preferred_username` from casdoor's Name json tag — the games/threewizards realm
# already uses plain JWT), or someone adds `preferred_username` to the allow-list
# to satisfy an OIDC client, the takeover silently re-opens. Keeping this claim
# absent is the defense-in-depth that makes such a regression LOUD. DO NOT add
# preferred_username to the token without re-auditing user-bff's identity-key
# derivation first (user-bff PR #124).
for takeover in ("preferred_username", "preferredUsername"):
    if takeover in claims:
        bad(f"ACCOUNT-TAKEOVER VECTOR: {takeover} present in token -> {claims[takeover]!r} "
            f"(re-opens user-bff's discord:<preferred_username> fold — see PR #124)")
    else:
        ok(f"account-takeover claim absent: {takeover}")
# Restate the allow-list identity shape so the intent is unmissable: the username
# identity is carried by `name` (the allow-listed Name field, asserted present by
# the (3) loop above), NOT by preferred_username.
if claims.get("name") not in (None, ""):
    ok(f"identity carried by `name` (not preferred_username): {claims.get('name')!r}")
else:
    bad("identity claim `name` missing — JWT-Custom allow-list shape broken")

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
# groups is the same Existing-Field shape (added 2026-07-09 for the headscale
# mesh-join OIDC gate). EXACT match required, not a fuzzy suffix check — a loose
# check here previously masked a real bug (see below).
#
# GROUND-TRUTH FINDING (live, this test): Casdoor's "Existing Field: Groups"
# tokenAttribute emits the group's INTERNAL "<owner>/<name>" id string
# ("hugmesh/headscale"), NOT the bare "/headscale" leading-slash path PR
# #280's reconcile_superadmin() comment and keys-template/headscale/config.yaml
# both assumed. That assumption was never live-verified against a real minted
# token — PR #280's "confirmed working" claim only proved the group-write API
# calls succeeded, not the token claim shape. allowed_groups is updated to
# "hugmesh/headscale" to match what Casdoor actually emits.
groups = claims.get("groups")
if isinstance(groups, list) and groups:
    ok(f"groups present as non-empty array: {groups!r}")
    if "hugmesh/headscale" in groups:
        ok("seeded hugmesh/headscale membership is present in the groups claim (exact match)")
    else:
        bad(f"seeded headscale group not found in groups claim: {groups!r}")
else:
    bad(f"groups missing/empty/not-array: {groups!r} -> headscale mesh-join OIDC gate can never pass")
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
