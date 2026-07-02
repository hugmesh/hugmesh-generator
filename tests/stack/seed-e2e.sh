#!/usr/bin/env bash
# =============================================================================
# seed-e2e.sh — the LIVE-RUN SEED CONTRACT for the local compose stack.
#
# Provisions, against the RUNNING compose stack (front door
# http://localhost:8088, Casdoor http://localhost:8000, social tier
# Synapse + Mastodon), everything the UI e2e suites assume exists:
#
#   1. PERSONAS (Casdoor, org "snapdragon") — the standard set:
#        e2e-user / e2e-mod / e2e-admin / e2e-superadmin
#        e2e-banned              (ban = ABSENCE of the platform access roles —
#                                 seeded ROLE_USER only, the post-ban state;
#                                 see docs/DOMAIN-LOCK.md "ADD-semantics, not a ban")
#        e2e-mastodon-domainlocked / e2e-matrix-domainlocked  (lock = PRESENCE
#                                 of the ROLE_*_DOMAINLOCKED marker, access kept)
#        e2e-tenant2-user        (second-tenant — seeded into the BRAND-B Casdoor
#                                 when CASDOOR_BRAND_B_URL is set; the single-
#                                 Casdoor compose stack cannot model a second
#                                 tenant, so without it this leg WARNs loudly)
#      Rendering + apply reuse tests/qemu/seed-accounts.sh --roles (the SAME
#      machinery the cluster/pentest seeds use — tests/pentest/seed-personas.sh
#      wraps it the same way), extended via SYSTEMS_ROLE_USERS.
#   2. MATRIX (Synapse) — users e2e-user + e2e-mod; PUBLIC room X
#      (#e2e-public-x:<server>) and INVITE-ONLY room Y (#e2e-invite-y:<server>,
#      created by e2e-mod, e2e-user invited; e2e-user joined to X).
#   3. MASTODON — accounts e2e-usera + e2e-userb; follower relationship
#      e2e-userb -> e2e-usera; ONE pending moderation-queue item (an unresolved
#      report of e2e-usera filed by e2e-userb).
#
# IDEMPOTENT: every step probes before it creates (add-user skipped when
# present, room aliases resolved before createRoom, tootctl "taken" tolerated,
# follow/report only created when absent). Safe to re-run.
#
# FAIL-HONEST: every unmet dependency dies with a message NAMING it (which
# service, which bring-up command). It never prints success for something it
# did not verify. The ONLY soft leg is the second tenant (WARN unless
# SEED_STRICT=1), because the standard compose stack simply has no brand-B
# Casdoor — that limitation is documented in docs/LOCAL-STACK.md.
#
# NOTE for suite authors (documented in docs/LOCAL-STACK.md): the compose
# social tier is MAINLINE Synapse + Mastodon, not tuwunel + Akkoma. Scenarios
# that drive pleroma-admin-only verbs (mod-bff block/ban Akkoma leg) will see
# the bff's HONEST degraded envelope here (the upstream 404s); the mod-bff
# Matrix leg is STUBBED BY DESIGN (202/STUBBED) everywhere. Domain-lock
# ENFORCEMENT (the Akkoma MRF / egress backstop) does not exist on mainline
# Mastodon, so specs 19-23 stay skipped on compose — the personas above are
# still seeded so the UI surfaces (role badges, disabled controls) render.
#
# ENV (all optional; defaults target the compose stack):
#   FRONT_DOOR            default http://localhost:8088   (fe-gateway)
#   CASDOOR_URL           default http://localhost:8000
#   CASDOOR_ADMIN_USER    default admin
#   CASDOOR_ADMIN_PASS    default 123      (the casbin/casdoor FRESH-BOOT dev
#                                           default — override for anything else)
#   CASDOOR_ORG           default snapdragon
#   CASDOOR_BRAND_B_URL   unset            (second-tenant Casdoor; enables leg 1b)
#   SYNAPSE_URL           default http://localhost:8008
#   SYNAPSE_SERVER_NAME   default localhost    (must match up-real.sh)
#   MASTODON_URL          default http://localhost:3000
#   E2E_PASSWORD          default e2e-pass (per-user E2E_<UPPER>_PASSWORD wins —
#                                           the seed-accounts.sh convention)
#   SEED_WORKDIR          default tests/stack/.seed-e2e (rendered JSON + minted
#                                           JWTs land here; gitignored)
#   SEED_STRICT           default 0        (1 = the second-tenant WARN becomes fatal)
# =============================================================================
set -euo pipefail

PROG="$(basename "$0")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN_DIR="$(cd "${HERE}/../.." && pwd)"
SEED_ACCOUNTS="${GEN_DIR}/tests/qemu/seed-accounts.sh"

FRONT_DOOR="${FRONT_DOOR:-http://localhost:8088}"
CASDOOR_URL="${CASDOOR_URL:-http://localhost:8000}"
CASDOOR_ADMIN_USER="${CASDOOR_ADMIN_USER:-admin}"
CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS:-123}"
CASDOOR_ORG="${CASDOOR_ORG:-snapdragon}"
CASDOOR_BRAND_B_URL="${CASDOOR_BRAND_B_URL:-}"
SYNAPSE_URL="${SYNAPSE_URL:-http://localhost:8008}"
SYNAPSE_SERVER_NAME="${SYNAPSE_SERVER_NAME:-localhost}"
MASTODON_URL="${MASTODON_URL:-http://localhost:3000}"
E2E_PASSWORD="${E2E_PASSWORD:-e2e-pass}"
SEED_WORKDIR="${SEED_WORKDIR:-${HERE}/.seed-e2e}"
SEED_STRICT="${SEED_STRICT:-0}"

log()  { echo "[seed-e2e] $*"; }
warn() { echo "[seed-e2e] WARN: $*" >&2; }
die()  { echo "${PROG}: UNMET DEPENDENCY: $*" >&2; exit 2; }

# ── Preflight: tools + the running stack, each named on failure ──────────────
command -v curl   >/dev/null 2>&1 || die "curl is required"
command -v jq     >/dev/null 2>&1 || die "jq is required"
command -v docker >/dev/null 2>&1 || die "docker is required (the social-tier legs exec into the compose containers)"
[ -f "${SEED_ACCOUNTS}" ]         || die "base seeder not found: ${SEED_ACCOUNTS}"

curl -sf -o /dev/null --max-time 5 "${FRONT_DOOR}/actuator/health/readiness" \
  || curl -sf -o /dev/null --max-time 5 "${FRONT_DOOR}/" \
  || die "front door ${FRONT_DOOR} is not answering — bring the stack up first: make stack-up"
curl -sf -o /dev/null --max-time 5 "${CASDOOR_URL}/" \
  || die "Casdoor ${CASDOOR_URL} is not answering — bring the stack up first: make stack-up"
curl -sf -o /dev/null --max-time 5 "${SYNAPSE_URL}/health" \
  || die "Synapse ${SYNAPSE_URL} is not answering — bring the social tier up: make stack-up SOCIAL=1 (or tests/stack/up-real.sh for the full first-run setup)"
curl -sf -o /dev/null --max-time 5 "${MASTODON_URL}/health" \
  || die "Mastodon ${MASTODON_URL} is not answering — bring the social tier up: make stack-up SOCIAL=1 (or tests/stack/up-real.sh, which also runs rails db:prepare)"

# The social-tier legs exec INSIDE the containers (register_new_matrix_user /
# tootctl / rails runner). Find them by compose service name, whichever project
# (snapdragon-local or snapdragon-real) is running them.
find_ctr() { # <service-substring>
  docker ps --format '{{.Names}}' | grep -E "(^|[-_])$1([-_][0-9]+)?$" | head -1
}
SYNAPSE_CTR="$(find_ctr synapse || true)"
MASTODON_CTR="$(find_ctr mastodon-web || true)"
[ -n "${SYNAPSE_CTR}" ]  || die "no running synapse container found (docker ps) — is the social tier up?"
[ -n "${MASTODON_CTR}" ] || die "no running mastodon-web container found (docker ps) — is the social tier up?"

mkdir -p "${SEED_WORKDIR}"

# ── Casdoor helpers (same admin-session transport as apply-systems-roles.sh) ──
CJ="$(mktemp)"; trap 'rm -f "${CJ}"' EXIT

casdoor_login() { # <base-url>
  curl -sf -c "${CJ}" "$1/api/login" -H 'content-type: application/json' \
    -d "{\"application\":\"app-built-in\",\"organization\":\"built-in\",\"username\":\"${CASDOOR_ADMIN_USER}\",\"password\":\"${CASDOOR_ADMIN_PASS}\",\"type\":\"login\",\"autoSignin\":true}" \
    | jq -e '.status == "ok"' >/dev/null \
    || die "Casdoor admin login failed at $1 (CASDOOR_ADMIN_USER/CASDOOR_ADMIN_PASS — the compose default is admin/123 on a FRESH casdoor volume)"
}

# A fresh compose Casdoor has NO snapdragon org and NO ROLE_* objects (the
# cluster seeds them via manifests/casdoor/init-*; the compose stack does not —
# docs/LOCAL-STACK.md "Casdoor is empty on first boot"). Ensure both so the
# apply hook's round-trip update-role finds real role objects.
ensure_org() { # <base-url> <org>
  local base="$1" org="$2"
  if curl -s -b "${CJ}" "${base}/api/get-organization?id=admin/${org}" | jq -e '.data.name // empty | length > 0' >/dev/null; then
    log "org ${org} exists"
    return 0
  fi
  curl -s -b "${CJ}" "${base}/api/add-organization" -H 'content-type: application/json' \
    -d "{\"owner\":\"admin\",\"name\":\"${org}\",\"displayName\":\"${org}\",\"passwordType\":\"plain\",\"tags\":[],\"languages\":[],\"initScore\":2000,\"enableSoftDeletion\":false,\"isProfilePublic\":true}" >/dev/null
  curl -s -b "${CJ}" "${base}/api/get-organization?id=admin/${org}" | jq -e '.data.name // empty | length > 0' >/dev/null \
    || die "could not create Casdoor organization ${org} at ${base}"
  log "org ${org} created"
}

# Mirrors seed-accounts.sh declared_roles + ROLE_SUPERADMIN (which the base
# matrix omits because the cluster seeds it in init-data; compose has neither).
REQUIRED_ROLES="ROLE_SUPERADMIN ROLE_ADMIN ROLE_MOD ROLE_MATRIX ROLE_MASTODON \
ROLE_MATRIX_DOMAINLOCKED ROLE_MASTODON_DOMAINLOCKED \
ROLE_MATRIX_EXTERNAL_CLIENT ROLE_MASTODON_EXTERNAL_CLIENT \
ROLE_FORUM ROLE_GAMES ROLE_GAMES_ADMIN ROLE_USER"

ensure_roles() { # <base-url> <org>
  local base="$1" org="$2" r
  for r in ${REQUIRED_ROLES}; do
    if curl -s -b "${CJ}" "${base}/api/get-role?id=${org}/${r}" | jq -e '.data.name // empty | length > 0' >/dev/null; then
      continue
    fi
    curl -s -b "${CJ}" "${base}/api/add-role" -H 'content-type: application/json' \
      -d "{\"owner\":\"${org}\",\"name\":\"${r}\",\"displayName\":\"${r}\",\"users\":[],\"roles\":[],\"isEnabled\":true}" >/dev/null
    curl -s -b "${CJ}" "${base}/api/get-role?id=${org}/${r}" | jq -e '.data.name // empty | length > 0' >/dev/null \
      || die "could not create Casdoor role ${org}/${r} at ${base}"
    log "role ${r} created (present-but-empty)"
  done
}

# ══ LEG 1: Casdoor personas (reuses seed-accounts.sh --roles + its apply hook) ══
log "leg 1: Casdoor personas at ${CASDOOR_URL} (org ${CASDOOR_ORG})"
casdoor_login "${CASDOOR_URL}"
ensure_org    "${CASDOOR_URL}" "${CASDOOR_ORG}"
ensure_roles  "${CASDOOR_URL}" "${CASDOOR_ORG}"

# The standard persona set = the base seed-accounts.sh matrix (user/mod/admin/
# domain-locked/…) PLUS the three the UI suites additionally assume. Same
# "username:ROLES:passwordEnv" spec shape; appended exactly like
# tests/pentest/seed-personas.sh appends its attacker/load pools.
EXTRA_SPECS="\
e2e-superadmin:ROLE_SUPERADMIN:E2E_SUPERADMIN_PASSWORD \
e2e-banned:ROLE_USER:E2E_BANNED_PASSWORD"

ROLES_DIR="${SEED_WORKDIR}/roles-render"
BASE_RENDER="${SEED_WORKDIR}/roles-render-base"
mkdir -p "${ROLES_DIR}" "${BASE_RENDER}"

# Pass 1: render the seeder's OWN default matrix (single source of truth — we
# never copy the persona table into this script, so the two cannot drift).
SYSTEMS_CASDOOR_URL="${CASDOOR_URL}" E2E_PASSWORD="${E2E_PASSWORD}" \
  bash "${SEED_ACCOUNTS}" --roles "${BASE_RENDER}" >/dev/null \
  || die "seed-accounts.sh --roles failed (base matrix render)"

# Reconstruct the base "username:ROLES_CSV:passwordEnv" specs FROM that render
# (users[] + role memberships), then append our extras and re-render the whole
# set through the same emit path. update-role sets each role's members to
# EXACTLY the rendered list, so base + extras MUST go through one render.
BASE_SPECS="$(jq -r --arg org "${CASDOOR_ORG}" '
  . as $root
  | .users[]
  | .name as $n | .passwordEnv as $p
  | ([$root.roles[] | select(.users | index($org + "/" + $n)) | .name] | join(",")) as $rs
  | "\($n):\($rs):\($p)"' "${BASE_RENDER}/roles/casdoor-systems-roles.json" | tr '\n' ' ')"
[ -n "${BASE_SPECS// /}" ] || die "could not reconstruct the base persona specs from ${BASE_RENDER}"

SYSTEMS_ROLE_USERS="${BASE_SPECS}${EXTRA_SPECS}" \
SYSTEMS_CASDOOR_URL="${CASDOOR_URL}" E2E_PASSWORD="${E2E_PASSWORD}" \
  bash "${SEED_ACCOUNTS}" --roles "${ROLES_DIR}" >/dev/null \
  || die "seed-accounts.sh --roles failed (base matrix + e2e extras)"

log "applying rendered matrix to Casdoor (idempotent add-user + update-role + JWT pre-mint)"
CASDOOR_URL="${CASDOOR_URL}" \
CASDOOR_ADMIN_USER="${CASDOOR_ADMIN_USER}" \
CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS}" \
CASDOOR_ORG="${CASDOOR_ORG}" \
PREMINT_DIR="${SEED_WORKDIR}/jwt-cache" \
  bash "${ROLES_DIR}/roles/apply-systems-roles.sh" \
  || die "apply-systems-roles.sh failed against ${CASDOOR_URL}"

# VERIFY (fail-honest): every persona the UI suites assume must now resolve.
for persona in e2e-user e2e-mod e2e-admin e2e-superadmin e2e-banned \
               e2e-mastodon-domainlocked e2e-matrix-domainlocked; do
  curl -s -b "${CJ}" "${CASDOOR_URL}/api/get-user?id=${CASDOOR_ORG}/${persona}" \
    | jq -e '.data.name // empty | length > 0' >/dev/null \
    || die "persona ${persona} did not land in Casdoor ${CASDOOR_URL} (apply hook incomplete)"
done
log "leg 1 OK: standard persona set verified in Casdoor"

# ── LEG 1b: second-tenant persona (needs a brand-B Casdoor) ──────────────────
if [ -n "${CASDOOR_BRAND_B_URL}" ]; then
  log "leg 1b: second-tenant persona at ${CASDOOR_BRAND_B_URL}"
  curl -sf -o /dev/null --max-time 5 "${CASDOOR_BRAND_B_URL}/" \
    || die "CASDOOR_BRAND_B_URL=${CASDOOR_BRAND_B_URL} set but not answering"
  casdoor_login "${CASDOOR_BRAND_B_URL}"
  ensure_org    "${CASDOOR_BRAND_B_URL}" "${CASDOOR_ORG}"
  ensure_roles  "${CASDOOR_BRAND_B_URL}" "${CASDOOR_ORG}"
  SYSTEMS_ROLE_USERS="e2e-tenant2-user:ROLE_USER:E2E_TENANT2_PASSWORD" \
  SYSTEMS_CASDOOR_URL="${CASDOOR_BRAND_B_URL}" E2E_PASSWORD="${E2E_PASSWORD}" \
    bash "${SEED_ACCOUNTS}" --roles "${SEED_WORKDIR}/roles-render-brandb" >/dev/null
  CASDOOR_URL="${CASDOOR_BRAND_B_URL}" \
  CASDOOR_ADMIN_USER="${CASDOOR_ADMIN_USER}" \
  CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS}" \
  CASDOOR_ORG="${CASDOOR_ORG}" \
  PREMINT_DIR="${SEED_WORKDIR}/jwt-cache-brandb" \
    bash "${SEED_WORKDIR}/roles-render-brandb/roles/apply-systems-roles.sh" \
    || die "apply-systems-roles.sh failed against brand-B ${CASDOOR_BRAND_B_URL}"
  # re-login to brand-A style verification against brand B:
  curl -s -b "${CJ}" "${CASDOOR_BRAND_B_URL}/api/get-user?id=${CASDOOR_ORG}/e2e-tenant2-user" \
    | jq -e '.data.name // empty | length > 0' >/dev/null \
    || die "e2e-tenant2-user did not land in brand-B Casdoor"
  log "leg 1b OK: e2e-tenant2-user verified in brand-B Casdoor"
  casdoor_login "${CASDOOR_URL}"   # restore the brand-A admin session
else
  MSG="second-tenant persona NOT seeded — the standard compose stack runs a SINGLE Casdoor, so cross-tenant (brand-wall) scenarios are unverifiable here. Set CASDOOR_BRAND_B_URL (e.g. the tests/pentest two-brand profile) to seed e2e-tenant2-user."
  if [ "${SEED_STRICT}" = "1" ]; then die "${MSG}"; else warn "${MSG}"; fi
fi

# ══ LEG 2: Matrix — users + public room X + invite-only room Y ═══════════════
log "leg 2: Matrix users + rooms at ${SYNAPSE_URL} (server_name=${SYNAPSE_SERVER_NAME})"

matrix_register() { # <user>
  local out
  # register_new_matrix_user reads registration_shared_secret from the config
  # up-real.sh ensured; "User ID already taken" is the idempotent no-op.
  out="$(docker exec "${SYNAPSE_CTR}" register_new_matrix_user \
          -u "$1" -p "${E2E_PASSWORD}" --no-admin -c /data/homeserver.yaml \
          "http://localhost:8008" 2>&1)" \
    || { echo "${out}" | grep -qi "already taken\|already exists\|M_USER_IN_USE" \
           || die "could not register Matrix user $1: ${out} (did up-real.sh set registration_shared_secret?)"; }
  log "matrix user $1 present"
}

matrix_token() { # <user>
  curl -sf "${SYNAPSE_URL}/_matrix/client/v3/login" -X POST \
    -H 'content-type: application/json' \
    -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"$1\"},\"password\":\"${E2E_PASSWORD}\"}" \
    | jq -re '.access_token' \
    || die "Matrix login failed for $1 (password mismatch? re-run with the E2E_PASSWORD the user was registered with)"
}

matrix_room_by_alias() { # <alias-localpart> -> room_id or empty
  curl -s "${SYNAPSE_URL}/_matrix/client/v3/directory/room/%23$1%3A${SYNAPSE_SERVER_NAME}" \
    | jq -r '.room_id // empty'
}

matrix_register e2e-mod
matrix_register e2e-user
MOD_TOK="$(matrix_token e2e-mod)"
USER_TOK="$(matrix_token e2e-user)"

ROOM_X="$(matrix_room_by_alias e2e-public-x)"
if [ -z "${ROOM_X}" ]; then
  ROOM_X="$(curl -sf "${SYNAPSE_URL}/_matrix/client/v3/createRoom" -X POST \
      -H "authorization: Bearer ${MOD_TOK}" -H 'content-type: application/json' \
      -d '{"preset":"public_chat","visibility":"public","room_alias_name":"e2e-public-x","name":"E2E Public Room X"}' \
    | jq -re '.room_id')" || die "could not create public room X"
  log "room X created: ${ROOM_X}"
else
  log "room X exists: ${ROOM_X}"
fi
# e2e-user joins X (idempotent — joining an already-joined room is a no-op 200).
curl -sf -o /dev/null "${SYNAPSE_URL}/_matrix/client/v3/join/$(jq -rn --arg r "${ROOM_X}" '$r|@uri')" \
  -X POST -H "authorization: Bearer ${USER_TOK}" -H 'content-type: application/json' -d '{}' \
  || die "e2e-user could not join public room X ${ROOM_X}"

ROOM_Y="$(matrix_room_by_alias e2e-invite-y)"
if [ -z "${ROOM_Y}" ]; then
  ROOM_Y="$(curl -sf "${SYNAPSE_URL}/_matrix/client/v3/createRoom" -X POST \
      -H "authorization: Bearer ${MOD_TOK}" -H 'content-type: application/json' \
      -d "{\"preset\":\"private_chat\",\"room_alias_name\":\"e2e-invite-y\",\"name\":\"E2E Invite-Only Room Y\",\"invite\":[\"@e2e-user:${SYNAPSE_SERVER_NAME}\"]}" \
    | jq -re '.room_id')" || die "could not create invite-only room Y"
  log "room Y created: ${ROOM_Y} (e2e-user invited)"
else
  log "room Y exists: ${ROOM_Y}"
fi

# VERIFY (fail-honest): both aliases must resolve, and Y must be invite-only.
[ -n "$(matrix_room_by_alias e2e-public-x)" ] || die "room X alias did not resolve after seed"
[ -n "$(matrix_room_by_alias e2e-invite-y)" ] || die "room Y alias did not resolve after seed"
JOIN_RULE="$(curl -s "${SYNAPSE_URL}/_matrix/client/v3/rooms/$(jq -rn --arg r "${ROOM_Y}" '$r|@uri')/state/m.room.join_rules/" \
  -H "authorization: Bearer ${MOD_TOK}" | jq -r '.join_rule // empty')"
[ "${JOIN_RULE}" = "invite" ] || die "room Y join_rule is '${JOIN_RULE}', expected 'invite' (invite-only contract)"
log "leg 2 OK: room X (public) + room Y (invite-only) verified"

# ══ LEG 3: Mastodon — accounts, follow userB->userA, pending mod-queue item ══
log "leg 3: Mastodon accounts + follow + pending report at ${MASTODON_URL}"

mastodon_account() { # <user>
  local out
  out="$(docker exec "${MASTODON_CTR}" bin/tootctl accounts create "$1" \
          --email "$1@snapdragon.test" --confirmed --approve 2>&1)" \
    || { echo "${out}" | grep -qi "taken\|exists" \
           || die "could not create Mastodon account $1: ${out}"; }
  log "mastodon account $1 present"
}
mastodon_account e2e-usera
mastodon_account e2e-userb

# Follow + report via rails runner INSIDE the container (tootctl has no follow/
# report verb; the runner aborts non-zero on any missing precondition — honest).
docker exec -i "${MASTODON_CTR}" bundle exec rails runner - <<'RUBY' || die "Mastodon follow/report seed failed (see runner output above)"
a = Account.find_local("e2e-usera")
b = Account.find_local("e2e-userb")
abort("SEED-DEP: e2e-usera/e2e-userb missing (tootctl create failed earlier?)") unless a && b

if b.following?(a)
  puts "[seed-e2e] follow e2e-userb -> e2e-usera exists"
else
  FollowService.new.call(b, a)
  abort("SEED-DEP: follow did not take") unless b.reload.following?(a)
  puts "[seed-e2e] follow e2e-userb -> e2e-usera created"
end

if Report.unresolved.where(account: b, target_account: a).exists?
  puts "[seed-e2e] pending moderation-queue item exists (unresolved report b->a)"
else
  ReportService.new.call(b, a, comment: "seed-e2e: pending moderation queue item")
  abort("SEED-DEP: report did not land unresolved") \
    unless Report.unresolved.where(account: b, target_account: a).exists?
  puts "[seed-e2e] pending moderation-queue item created"
end
RUBY
log "leg 3 OK: follow + pending moderation-queue item verified"

log "DONE. Seeded against ${FRONT_DOOR} / ${CASDOOR_URL} / ${SYNAPSE_URL} / ${MASTODON_URL}"
log "JWT pre-mint cache (for SNAP_PREMINT_DIR): ${SEED_WORKDIR}/jwt-cache"
log "Re-run any time — every leg is idempotent."
