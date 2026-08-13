#!/usr/bin/env bash
# =============================================================================
# seed-e2e.sh — the LIVE-RUN SEED CONTRACT for the local compose stack.
#
# Provisions, against the RUNNING compose stack (front door
# http://localhost:8088, Casdoor http://localhost:8000, social tier
# tuwunel + Mastodon), everything the UI e2e suites assume exists:
#
#   1. PERSONAS (Casdoor, org "hugmesh") — the standard set:
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
#   2. MATRIX (tuwunel) — users e2e-user + e2e-mod; PUBLIC room X
#      (#e2e-public-x:<server>) and INVITE-ONLY room Y (#e2e-invite-y:<server>,
#      created by e2e-mod, e2e-user invited; e2e-user joined to X).
#   3. MASTODON — accounts e2e_usera + e2e_userb (underscore, not hyphen: Mastodon's
#      username validator only accepts [a-z0-9_]+, so the hyphenated e2e- prefix used
#      by every OTHER persona in this script cannot be reused here); follower
#      relationship e2e_userb -> e2e_usera; ONE pending moderation-queue item (an
#      unresolved report of e2e_usera filed by e2e_userb).
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
# social tier is tuwunel + MAINLINE Mastodon — the Matrix half now matches the
# cluster payload (same tuwunel image tag), the fediverse half does not (Akkoma
# on the cluster). Scenarios that drive pleroma-admin-only verbs (mod-bff
# block/ban Akkoma leg) will see the bff's HONEST degraded envelope here (the
# upstream 404s); the mod-bff Matrix leg is STUBBED BY DESIGN (202/STUBBED)
# everywhere. Domain-lock ENFORCEMENT (the Akkoma MRF / egress backstop) does
# not exist on mainline Mastodon, so specs 19-23 stay skipped on compose — the
# personas above are still seeded so the UI surfaces (role badges, disabled
# controls) render.
#
# ENV (all optional; defaults target the compose stack):
#   FRONT_DOOR            default http://localhost:8088   (fe-gateway)
#   CASDOOR_URL           default http://localhost:8000
#   CASDOOR_ADMIN_USER    default admin
#   CASDOOR_ADMIN_PASS    default 123      (the casbin/casdoor FRESH-BOOT dev
#                                           default — override for anything else)
#                         DELIBERATE DIVERGENCE FROM THE CLUSTER: this stack keeps
#                         casdoor's default because it is a throwaway local
#                         Casdoor bound to localhost with a throwaway volume. The
#                         cluster must NOT: manifests/casdoor/init-job.yaml applies
#                         the Vault/ESO password via /api/set-password and then
#                         proves "123" no longer logs in. So this leg is one the
#                         compose stack will never exercise — see
#                         tests/scripts/test-casdoor-init-honesty.sh, which runs
#                         the real cluster script offline instead.
#   CASDOOR_ORG           default hugmesh
#   CASDOOR_BRAND_B_URL   unset            (second-tenant Casdoor; enables leg 1b)
#   SYNAPSE_URL           default http://localhost:8008   (tuwunel; the env NAME
#                                           mirrors the frozen Spring-BFF property
#                                           contract broker.synapse-url)
#   MATRIX_SERVER_NAME    default localhost    (must match up-real.sh / the
#                                           tuwunel service's TUWUNEL_SERVER_NAME)
#   MASTODON_URL          default http://localhost:3000
#   E2E_PASSWORD          default e2e-pass (per-user E2E_<UPPER>_PASSWORD wins —
#                                           the seed-accounts.sh convention)
#   SEED_WORKDIR          default tests/stack/.seed-e2e (rendered JSON + minted
#                                           JWTs land here; gitignored)
#   SEED_STRICT           default 0        (1 = the second-tenant WARN becomes fatal)
#   SEED_WAIT_S           default 180      (seconds the preflight waits for each
#                                           dependency's port to answer. `make
#                                           stack-up` returns before the stack
#                                           SERVES, so a seed run straight after it
#                                           must wait rather than die on the first
#                                           refused connection.)
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
CASDOOR_ORG="${CASDOOR_ORG:-hugmesh}"
# The confidential OAuth app user-bff drives NATIVE login through: user-bff POSTs the
# username/password to the INTERNAL Casdoor /api/login with this app's OIDC/PKCE params,
# gets an auth code, and exchanges it (authorization_code grant). The compose Casdoor has
# NO app (only the cluster seeds one). clientId / secret / redirectUri MUST byte-match
# user-bff's APP_BFF_OIDC_CLIENT_ID / _SECRET / _REDIRECT_URI in compose.local.yaml. The
# redirectUri is an INTERNAL PKCE-match string only — Casdoor validates it against the
# registered app; NO browser ever visits it (native login has no front-channel redirect).
CASDOOR_APP_CLIENT_ID="${CASDOOR_APP_CLIENT_ID:-app-user-bff}"
CASDOOR_APP_SECRET="${CASDOOR_APP_SECRET:-dev-app-user-bff-secret}"
CASDOOR_APP_REDIRECT_URI="${CASDOOR_APP_REDIRECT_URI:-http://hugmesh-user-bff-api:8080/bff/auth/callback}"
CASDOOR_BRAND_B_URL="${CASDOOR_BRAND_B_URL:-}"
SYNAPSE_URL="${SYNAPSE_URL:-http://localhost:8008}"
MATRIX_SERVER_NAME="${MATRIX_SERVER_NAME:-localhost}"
MASTODON_URL="${MASTODON_URL:-http://localhost:3000}"
E2E_PASSWORD="${E2E_PASSWORD:-e2e-pass}"
SEED_WORKDIR="${SEED_WORKDIR:-${HERE}/.seed-e2e}"
SEED_STRICT="${SEED_STRICT:-0}"
# SEED_CASDOOR_ONLY=1 seeds ONLY the Casdoor identity leg (org + roles + app-user-bff
# + personas) and stops before the Matrix/Mastodon social legs — enough for real SSO
# web login on the CORE (non-SOCIAL) stack, which has no tuwunel/Mastodon to seed.
SEED_CASDOOR_ONLY="${SEED_CASDOOR_ONLY:-0}"
# How long the preflight waits for a dependency's port to start answering.
# `make stack-up` returns the moment `compose up -d` has STARTED the containers —
# it does NOT wait for them to serve (fe-gateway's only compose dependents use
# `condition: service_started`), so a `make stack-seed` launched straight after
# stack-up hits a dead port for the whole gateway JVM boot (~17 s measured warm,
# far longer cold / with SOCIAL=1). A single un-retried curl turned that ordinary
# startup latency into "UNMET DEPENDENCY: front door is not answering".
SEED_WAIT_S="${SEED_WAIT_S:-180}"
# Onboard the seeded personas (registration stage 2 + platform provisioning) and
# seed the broad local-mesh operator account. OFF by default — the e2e suite needs
# personas that are still gated. Resolved HERE, with the other knobs, because it is
# read in two places far apart: the EXTRA_SPECS block below and leg 1c.
# Full rationale at leg 1c.
SEED_COMPLETE_REGISTRATION="${SEED_COMPLETE_REGISTRATION:-0}"

log()  { echo "[seed-e2e] $*"; }
warn() { echo "[seed-e2e] WARN: $*" >&2; }
die()  { echo "${PROG}: UNMET DEPENDENCY: $*" >&2; exit 2; }

# ── Preflight: tools + the running stack, each named on failure ──────────────
command -v curl   >/dev/null 2>&1 || die "curl is required"
command -v jq     >/dev/null 2>&1 || die "jq is required"
command -v docker >/dev/null 2>&1 || die "docker is required (the Mastodon leg execs into its container; the Matrix leg is seeded over HTTP and needs no exec)"
[ -f "${SEED_ACCOUNTS}" ]         || die "base seeder not found: ${SEED_ACCOUNTS}"

# A dependency is "up" when its port answers with a REAL status. 401 counts: the
# fe-gateway front door is default-DENY for anonymous, so an auth challenge proves
# the gateway is serving. 5xx does NOT count — a JVM that has bound its port but
# not yet wired its routes answers 502/503, and accepting that would just move the
# failure deeper into the seed with a more confusing message.
# NOTE: the old first probe here was `curl -sf .../actuator/health/readiness`.
# That endpoint is behind auth and ALWAYS answers 401 -> `curl -sf` exits 22, so it
# was dead code and the entire gate was one 5 s shot at `/`. Do not reinstate it.
http_up() {  # <url>
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || echo 000)"
  case "${code}" in 2??|3??|401) return 0 ;; *) return 1 ;; esac
}
wait_up() {  # <label> <url> <die-hint>
  local t=0
  http_up "$2" && return 0
  log "waiting for $1 $2 (up to ${SEED_WAIT_S}s — stack-up does not wait for readiness)"
  while [ "${t}" -lt "${SEED_WAIT_S}" ]; do
    sleep 3; t=$((t+3))
    http_up "$2" && { log "$1: answering after ${t}s"; return 0; }
  done
  die "$1 $2 is not answering after ${SEED_WAIT_S}s — $3"
}
# Casdoor FIRST: it is the seed's only hard dependency (the SEED_CASDOOR_ONLY=1 leg
# that `make stack-seed` runs on the non-SOCIAL path never touches the front door).
wait_up "Casdoor"    "${CASDOOR_URL}/" "bring the stack up first: make stack-up"
wait_up "front door" "${FRONT_DOOR}/"  "bring the stack up first: make stack-up (check: make stack-ps)"
# The Mastodon leg execs INSIDE its container (tootctl / rails runner). Find it
# by compose service name, whichever project (hugmesh-local or hugmesh-real) is
# running it. The Matrix leg needs NO container exec: tuwunel is seeded entirely
# over its HTTP CS-API (the distroless tuwunel image has no shell to exec into).
find_ctr() { # <service-substring>
  docker ps --format '{{.Names}}' | grep -E "(^|[-_])$1([-_][0-9]+)?$" | head -1
}
if [ "${SEED_CASDOOR_ONLY}" != "1" ]; then
  # Same bounded SEED_WAIT_S retry as Casdoor/front door above — a seed launched
  # right after `make stack-up SOCIAL=1` must ride out ordinary boot latency
  # (Mastodon's Rails boot especially). /_matrix/client/versions is tuwunel's
  # readiness surface (the same endpoint the cluster readinessProbe uses;
  # Synapse's /health does not exist here).
  wait_up "tuwunel"  "${SYNAPSE_URL}/_matrix/client/versions" "bring the social tier up: make stack-up SOCIAL=1 (or tests/stack/up-real.sh for the full first-run setup). For SSO login only, use SEED_CASDOOR_ONLY=1 (make stack-seed)."
  wait_up "Mastodon" "${MASTODON_URL}/health" "bring the social tier up: make stack-up SOCIAL=1 (or tests/stack/up-real.sh, which also runs rails db:prepare). For SSO login only, use SEED_CASDOOR_ONLY=1 (make stack-seed)."
  MASTODON_CTR="$(find_ctr mastodon-web || true)"
  [ -n "${MASTODON_CTR}" ] || die "no running mastodon-web container found (docker ps) — is the social tier up?"
fi

mkdir -p "${SEED_WORKDIR}"

# ── Casdoor helpers (same admin-session transport as apply-systems-roles.sh) ──
CJ="$(mktemp)"; trap 'rm -f "${CJ}"' EXIT

casdoor_login() { # <base-url>
  curl -sf -c "${CJ}" "$1/api/login" -H 'content-type: application/json' \
    -d "{\"application\":\"app-built-in\",\"organization\":\"built-in\",\"username\":\"${CASDOOR_ADMIN_USER}\",\"password\":\"${CASDOOR_ADMIN_PASS}\",\"type\":\"login\",\"autoSignin\":true}" \
    | jq -e '.status == "ok"' >/dev/null \
    || die "Casdoor admin login failed at $1 (CASDOOR_ADMIN_USER/CASDOOR_ADMIN_PASS — the compose default is admin/123 on a FRESH casdoor volume)"
}

# A fresh compose Casdoor has NO hugmesh org and NO ROLE_* objects (the
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

# seed-accounts.sh declared_roles, PLUS the two roles this script grants that the
# base matrix does not declare:
#   ROLE_SUPERADMIN  — the base matrix omits it because the cluster seeds it in
#                      init-data; compose has neither.
#   ROLE_FLEET_ADMIN — granted below to the e2e-fleet persona (see EXTRA_SPECS).
# Both MUST be listed here: apply-systems-roles.sh reaches these role objects with
# update-role, which needs a role that already EXISTS in Casdoor. A granted-but-
# undeclared role is a seed failure, not a silent no-op.
# NOTE: character-studio + character-forge deliberately have NO role here — both
# ride the ROLE_USER floor (route-access rows /character-studio/**,
# /character-forge/**, /bff/character-forge/** are all ROLE_USER; ownership is
# enforced inside character-forge-bff), so every persona below can already reach
# them and no new role object is required.
REQUIRED_ROLES="ROLE_SUPERADMIN ROLE_ADMIN ROLE_MOD ROLE_MATRIX ROLE_MASTODON \
ROLE_MATRIX_DOMAINLOCKED ROLE_MASTODON_DOMAINLOCKED \
ROLE_MATRIX_EXTERNAL_CLIENT ROLE_MASTODON_EXTERNAL_CLIENT \
ROLE_FORUM ROLE_FORUM_MOD ROLE_WIKI ROLE_GAMES ROLE_GAMES_ADMIN ROLE_USER \
ROLE_FLEET_ADMIN"

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

# A fresh compose Casdoor has NO OAuth2 application, so user-bff's native-login
# /api/login POST has no client to name and its code->token exchange has no client.
# Create the app-user-bff confidential client, mirroring the cluster's reconcile_app
# (specs/cluster/manifests/casdoor/init-job.yaml): authorization_code + refresh_token +
# password grants (native login uses the authorization_code grant — user-bff drives the
# credentials through /api/login type=code, then exchanges the returned code), JWT-Custom /
# RS256 with the roles + permissions token attributes the gateway RBAC reads from the minted
# JWT (an empty tokenFields set strips roles and breaks authz platform-wide). No `cert` field
# — Casdoor signs with its built-in cert, same as the cluster path. redirectUri / clientId /
# secret byte-match user-bff's APP_BFF_OIDC_*.
ensure_app() { # <base-url> <org>
  local base="$1" org="$2" app
  app="$(jq -n \
    --arg org "${org}" --arg cid "${CASDOOR_APP_CLIENT_ID}" \
    --arg secret "${CASDOOR_APP_SECRET}" --arg redirect "${CASDOOR_APP_REDIRECT_URI}" \
    '{owner:"admin", name:$cid, displayName:"hugmesh user-bff", organization:$org,
      clientId:$cid, clientSecret:$secret, redirectUris:[$redirect],
      grantTypes:["authorization_code","client_credentials","password","refresh_token"],
      expireInHours:168, enablePassword:true, enableSignUp:false,
      tokenFormat:"JWT-Custom", tokenSigningMethod:"RS256",
      tokenFields:["Id","Name","Email","IsAdmin","Properties.mfa_satisfied","Properties.mfa_satisfied_at"],
      tokenAttributes:[
        {name:"roles",       category:"Existing Field", value:"Roles",       type:"Array"},
        {name:"permissions", category:"Existing Field", value:"Permissions", type:"Array"}
      ]}')"
  if curl -s -b "${CJ}" "${base}/api/get-application?id=admin/${CASDOOR_APP_CLIENT_ID}" | jq -e '.data.name // empty | length > 0' >/dev/null; then
    curl -s -b "${CJ}" "${base}/api/update-application?id=admin/${CASDOOR_APP_CLIENT_ID}" \
      -H 'content-type: application/json' -d "${app}" >/dev/null
    log "app ${CASDOOR_APP_CLIENT_ID} updated (redirect ${CASDOOR_APP_REDIRECT_URI})"
  else
    curl -s -b "${CJ}" "${base}/api/add-application" -H 'content-type: application/json' -d "${app}" >/dev/null
    curl -s -b "${CJ}" "${base}/api/get-application?id=admin/${CASDOOR_APP_CLIENT_ID}" | jq -e '.data.name // empty | length > 0' >/dev/null \
      || die "could not create Casdoor application ${CASDOOR_APP_CLIENT_ID} at ${base}"
    log "app ${CASDOOR_APP_CLIENT_ID} created (clientId ${CASDOOR_APP_CLIENT_ID}, redirect ${CASDOOR_APP_REDIRECT_URI})"
  fi
}

# The MACHINE client the remote-fragment sync sidecar mints its service JWT with
# (compose.local.yaml hands it CASDOOR_CLIENT_ID/SECRET, default
# dev-fragment-sync-client/dev-fragment-sync-secret). In-cluster this app is
# provisioned outside the stack (ESO/Vault); locally NOBODY created it, so every
# sync tick died with `invalid_client` -> 401, the shared web root stayed empty,
# and the front page had no service cards. client_credentials ONLY (no browser
# redirect, no password grant) — it is a machine account, not a login surface.
FRAGMENT_SYNC_CLIENT_ID="${FRAGMENT_SYNC_CLIENT_ID:-dev-fragment-sync-client}"
FRAGMENT_SYNC_CLIENT_SECRET="${FRAGMENT_SYNC_CLIENT_SECRET:-dev-fragment-sync-secret}"
ensure_fragment_sync_client() { # <base-url> <org>
  local base="$1" org="$2" app
  app="$(jq -n \
    --arg org "${org}" --arg cid "${FRAGMENT_SYNC_CLIENT_ID}" \
    --arg secret "${FRAGMENT_SYNC_CLIENT_SECRET}" \
    '{owner:"admin", name:$cid, displayName:"hugmesh fragment-sync (machine)", organization:$org,
      clientId:$cid, clientSecret:$secret, redirectUris:[],
      grantTypes:["client_credentials"],
      expireInHours:168, enablePassword:false, enableSignUp:false,
      tokenFormat:"JWT-Custom", tokenSigningMethod:"RS256",
      tokenFields:["Id","Name"],
      tokenAttributes:[
        {name:"roles",       category:"Existing Field", value:"Roles",       type:"Array"},
        {name:"permissions", category:"Existing Field", value:"Permissions", type:"Array"}
      ]}')"
  if curl -s -b "${CJ}" "${base}/api/get-application?id=admin/${FRAGMENT_SYNC_CLIENT_ID}" | jq -e '.data.name // empty | length > 0' >/dev/null; then
    curl -s -b "${CJ}" "${base}/api/update-application?id=admin/${FRAGMENT_SYNC_CLIENT_ID}" \
      -H 'content-type: application/json' -d "${app}" >/dev/null
    log "machine app ${FRAGMENT_SYNC_CLIENT_ID} updated"
  else
    curl -s -b "${CJ}" "${base}/api/add-application" -H 'content-type: application/json' -d "${app}" >/dev/null
    curl -s -b "${CJ}" "${base}/api/get-application?id=admin/${FRAGMENT_SYNC_CLIENT_ID}" | jq -e '.data.name // empty | length > 0' >/dev/null \
      || die "could not create Casdoor application ${FRAGMENT_SYNC_CLIENT_ID} at ${base}"
    log "machine app ${FRAGMENT_SYNC_CLIENT_ID} created (client_credentials only)"
  fi
  # SELF-VERIFY the exact mint the sidecar performs — a created-but-unmintable app
  # (wrong grant type, secret drift) would reproduce the silent empty-web-root state.
  curl -s --max-time 10 -X POST "${base}/api/login/oauth/access_token" \
      -d "grant_type=client_credentials&client_id=${FRAGMENT_SYNC_CLIENT_ID}&client_secret=${FRAGMENT_SYNC_CLIENT_SECRET}" \
    | jq -e '.access_token // empty | length > 0' >/dev/null \
    || die "fragment-sync machine client cannot mint a token (grant_type=client_credentials)"
  log "machine app ${FRAGMENT_SYNC_CLIENT_ID} mint self-check OK"
}

# ══ LEG 1: Casdoor personas (reuses seed-accounts.sh --roles + its apply hook) ══
log "leg 1: Casdoor personas at ${CASDOOR_URL} (org ${CASDOOR_ORG})"
casdoor_login "${CASDOOR_URL}"
ensure_org    "${CASDOOR_URL}" "${CASDOOR_ORG}"
ensure_roles  "${CASDOOR_URL}" "${CASDOOR_ORG}"
ensure_app    "${CASDOOR_URL}" "${CASDOOR_ORG}"
ensure_fragment_sync_client "${CASDOOR_URL}" "${CASDOOR_ORG}"

# The standard persona set = the base seed-accounts.sh matrix (user/mod/admin/
# domain-locked/…) PLUS the three the UI suites additionally assume. Same
# "username:ROLES:passwordEnv" spec shape; appended exactly like
# tests/pentest/seed-personas.sh appends its attacker/load pools.
#
# The ad-hoc identities below (admin@hugmesh.systems, alice../frank@gmail.com,
# dragoneer, rbac-plain@/rbac-login-user@/rbac-pending@/rbac-approved@gmail.com)
# are the sequential, stateful specs/02,04,05,06,07,08,09,13,15,17 personas — per helpers.ts's
# onboard()/registerOnly() doc comment, native login has no self-registration
# surface, so each must exist as a pre-seeded native Casdoor account (username
# = the literal handle these specs hardcode) sharing the common E2E_PASSWORD.
# admin@hugmesh.systems is the sole admin among them (spec 02/08/09
# exercise admin-only views); the rest are bare ROLE_USER (the
# nav-matrix/nav-mastodon gate in menu.component.ts checks only
# capabilities.installed() + session.fullyRegistered(), not a per-service
# role, so plain ROLE_USER is sufficient to reach both). mallory@gmail.com and
# "rando" are DELIBERATELY absent — specs 03/07 assert sign-in is denied for an
# identity no admin ever provisioned.
#
# rbac-plain@ (spec 13) / rbac-login-user@ (spec 15) / rbac-pending@ +
# rbac-approved@gmail.com (spec 17): POST /bff/admin/allowlist
# does NOT gate native sign-in — that's a vestige of the removed Google/Discord
# self-registration flow (SsoAuthController's separate, dark /bff/register
# endpoint); /bff/login always validates against a REAL, pre-existing Casdoor
# account, exactly like every other ad-hoc persona here. Seeded here so spec
# 17's "pending vs completed registration" gate can exercise the SAME real
# registerOnly()/onboard() mechanism as specs 02/03/04, not a self-provisioning
# path that doesn't exist in the current architecture.
# rbac-plain@/rbac-login-user@gmail.com are the "invite then sign in as a plain
# ROLE_USER" personas specs 13 (BFF admin-API gating) + 15 (per-realm login)
# hardcode: the admin INVITES the handle, then the SAME handle signs in and must
# carry EXACTLY ['user'] (spec 15) and be DENIED every /bff/admin/** endpoint
# (spec 13). The invite provisions the account in the MOCK stack, but against a
# real Casdoor /bff/login validates against a pre-existing account only — so, as
# with rbac-pending/rbac-approved, the handle must be pre-seeded as a bare
# ROLE_USER here or the login 401s at setup and the denial/role assertions never
# run. Bare ROLE_USER (no elevated role) is exactly what both specs presuppose.
# The persona list lives in ONE place, sourced by BOTH lanes. It used to be
# inlined here, and the kind lane's bootstrap never had it at all — so a cluster
# that was otherwise fully working answered spec 29 with
# "native login e2e-fleet -> 401", a persona that had simply never been created.
# See tests/e2e-extra-personas.sh for the per-persona reasoning.
# shellcheck source=../e2e-extra-personas.sh
. "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/tests/e2e-extra-personas.sh"
EXTRA_SPECS="${E2E_EXTRA_PERSONAS}"

# ── The LOCAL-MESH OPERATOR persona (opt-in, same flag as stage 2) ────────────
# Every seeded persona is deliberately NARROW, because each one exists to prove a
# specific RBAC boundary: e2e-admin holds ROLE_ADMIN but NOT ROLE_MATRIX, so its
# Matrix tab renders and then 403s; e2e-matrix is the reverse and cannot open the
# admin panel or the API docs; e2e-superadmin reaches those two but holds no
# platform-access role, so it cannot provision Matrix either. That matrix is
# CORRECT for the e2e suite and hostile to an operator who just brought up their
# own mesh and wants to click through it — there is no account that opens
# everything, and nothing on screen says so.
#
# So the local-mesh path seeds ONE broad account. It is added to EXTRA_SPECS, which
# means it flows through the SAME render+apply path as every other persona (no
# special-casing), and it is gated behind SEED_COMPLETE_REGISTRATION so the e2e
# suite's role matrix is untouched — spec 15 walks rbac-roles.ts, not Casdoor, so
# an extra account is invisible to it.
#
# ROLE_GAMES_ADMIN and ROLE_FORUM_MOD are NEVER granted directly (both are DERIVED
# by their reconcile Jobs — seed-accounts.sh declares them present-but-empty), and
# the *_DOMAINLOCKED / *_EXTERNAL_CLIENT markers are RESTRICTIONS, not grants, so
# handing them to an operator would take capability away.
LOCAL_OPERATOR_USER="${LOCAL_OPERATOR_USER:-mesh-operator}"
LOCAL_OPERATOR_ROLES="${LOCAL_OPERATOR_ROLES:-ROLE_SUPERADMIN,ROLE_ADMIN,ROLE_MOD,ROLE_MATRIX,ROLE_MASTODON,ROLE_FORUM,ROLE_WIKI,ROLE_GAMES,ROLE_FLEET_ADMIN,ROLE_USER}"
if [ "${SEED_COMPLETE_REGISTRATION:-0}" = "1" ]; then
  EXTRA_SPECS="${EXTRA_SPECS} ${LOCAL_OPERATOR_USER}:${LOCAL_OPERATOR_ROLES}:E2E_PASSWORD"
fi

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
for persona in e2e-user e2e-mod e2e-admin "${SUPERADMIN_PERSONA}" e2e-banned \
               e2e-fleet e2e-mastodon-domainlocked e2e-matrix-domainlocked; do
  curl -s -b "${CJ}" "${CASDOOR_URL}/api/get-user?id=${CASDOOR_ORG}/${persona}" \
    | jq -e '.data.name // empty | length > 0' >/dev/null \
    || die "persona ${persona} did not land in Casdoor ${CASDOOR_URL} (apply hook incomplete)"
done
log "leg 1 OK: standard persona set verified in Casdoor"

# ── LEG 1c: registration stage 2 (OPT-IN) ────────────────────────────────────
# Seeding a Casdoor identity is only STAGE 1. Until stage 2 (`POST
# /bff/register/complete`) runs, `GET /bff/session` reports
# registrationComplete=false, and the gateway then grants the identity only a
# bare ROLE_USER regardless of the roles Casdoor holds — so EVERY service
# federation remote (/admin, /mod, /user, /social/**, /apidocs) answers 403 and
# the host shell greys its tiles with "Complete your registration to use this."
# A freshly-seeded local mesh therefore renders a login page you can sign into
# and then cannot navigate anywhere from, which reads as a broken mesh.
#
# OFF BY DEFAULT — this is deliberate, not timidity. Several e2e specs need
# personas that are still gated: spec 17 drives the pending-registration UI with
# rbac-pending@gmail.com, and spec 29 asserts it can perform stage 2 itself.
# Completing registration for everyone would delete the very state those specs
# exercise. The Studio's local-mesh bring-up passes 1 because ITS product is a
# clickable mesh, not a test fixture (core/local_stack_node.py seed()).
# (The flag itself is resolved with the other knobs at the top — it is also read by
# the EXTRA_SPECS block, which runs before this point.)
# Personas whose GATED state is load-bearing for the e2e suite; never completed
# even when the flag is on:
#   e2e-pending            — tests/e2e/specs/rbac-roles.ts is the contract, and it
#                            is the single entry declaring registrationComplete:false.
#   rbac-pending-gmail-com — spec 17 drives the pending-registration UI with it and
#                            asserts the gate HOLDS (17-rbac-user-and-pending.spec.ts).
#   e2e-banned             — spec 28 pins it 403 on both homeserver surfaces; its
#                            whole identity is "blocked", so onboarding it would
#                            launder away the state under test.
SEED_REGISTRATION_SKIP="${SEED_REGISTRATION_SKIP:-e2e-pending rbac-pending-gmail-com e2e-banned}"

# Derive BOTH the persona list and each password from the SAME rendered spec set
# leg 1 just applied ("username:ROLES_CSV:passwordEnv"), never a second copy of
# the table — the same no-drift rule the base render above is built on.
ALL_SPECS="${BASE_SPECS}${EXTRA_SPECS}"
REGISTRATION_PERSONAS="$(for s in ${ALL_SPECS}; do printf '%s ' "${s%%:*}"; done)"

persona_password() {  # <username> -> per-user env override, else shared, else default
  local u="$1" spec env_name="" val=""
  for spec in ${ALL_SPECS}; do
    case "${spec}" in "${u}:"*) env_name="${spec##*:}"; break ;; esac
  done
  [ -n "${env_name}" ] && val="$(printenv "${env_name}" 2>/dev/null || true)"
  [ -n "${val}" ] || val="${E2E_PASSWORD}"
  printf '%s' "${val}"
}

persona_roles() {  # <username> -> the ROLES_CSV this persona was rendered with
  local u="$1" spec rest
  for spec in ${ALL_SPECS}; do
    case "${spec}" in "${u}:"*) rest="${spec#*:}"; printf '%s' "${rest%:*}"; return 0 ;; esac
  done
}

# Mint the per-platform account behind the hsproxy. Stage 2 alone does NOT do this:
# it flips registration_complete (which is what makes the gateway map the persona's
# REAL roles instead of the bare ROLE_USER floor), but the Matrix/Mastodon accounts
# are minted separately by `POST /bff/provision/<platform>`. Skipping it leaves the
# operator with a Matrix UI that renders its whole shell and then 403s on
# whoami/joined_rooms/sync — an app that "opens" but shows nothing.
# The browser does this automatically at login (login-ui bff.service.ts); the seeder
# must do it explicitly. Provisioning is ROLE-GATED, so we only ask for a platform
# the persona actually holds the access role for — asking anyway would log a 403 for
# every admin-only persona and teach the operator to ignore the warnings.
provision_platform() {  # <username> <matrix|mastodon> <jar>
  local u="$1" plat="$2" jar="$3" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 40 -b "${jar}" -c "${jar}" \
            -X POST "${FRONT_DOOR}/bff/provision/${plat}" \
            -H 'content-type: application/json' -d '{}' 2>/dev/null || echo 000)"
  case "${code}" in
    200|201|204) return 0 ;;
    *) warn "provision ${plat} for ${u} -> ${code}" ; return 1 ;;
  esac
}

# rc 0 = onboarded, 2 = deliberately left gated, 1 = attempted and failed.
onboard_persona() {  # <username>
  local u="$1" jar="${SEED_WORKDIR}/.reg-${1}.cookies" code roles rc=0
  case " ${SEED_REGISTRATION_SKIP} " in *" ${u} "*) return 2 ;; esac
  # NEVER onboard an EMAIL-shaped handle. Those are the invite-flow fixtures
  # (mallory@, frank@, rbac-pending@, rbac-approved@ …) that the specs drive through
  # the registration UI themselves — spec 03 registers frank@gmail.com and asserts the
  # complete-view appears; spec 17 does the same for rbac-pending@gmail.com. Onboarding
  # them here deletes the very state those specs exist to exercise, and they fail with
  # a bare "getByTestId('complete-view') not found" that points nowhere near the cause.
  # Specs that DO want these complete (e.g. 04's alice@/bob@…) call onboard() in
  # helpers.ts themselves, so skipping here costs them nothing.
  # This is a SHAPE rule, not a list, because the two spellings differ: the roster
  # declares `rbac-pending@gmail.com` while Casdoor stores the normalised
  # `rbac-pending-gmail-com`. A name-list written in either spelling silently misses
  # the other — which is exactly how this regressed.
  case "${u}" in *@*) return 2 ;; esac
  # Stage 1: a real session cookie, exactly as the browser gets one.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -c "${jar}" \
            -X POST "${FRONT_DOOR}/bff/login" -H 'content-type: application/json' \
            -d "$(jq -nc --arg u "${u}" --arg p "$(persona_password "${u}")" \
                    '{username:$u,password:$p}')" 2>/dev/null || echo 000)"
  # A login that does not return 200 is a REAL failure, not a skip: the persona was
  # just seeded, so it must be able to log in.
  [ "${code}" = "200" ] || { warn "onboard: login for ${u} -> ${code}"; rm -f "${jar}"; return 1; }
  # Stage 2: admin-bff's public AuthController, through the gateway, with that
  # cookie — the same call tests/e2e/specs/29-mfa-privileged-floor.spec.ts makes.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -b "${jar}" -c "${jar}" \
            -X POST "${FRONT_DOOR}/bff/register/complete" -H 'content-type: application/json' \
            -d "$(jq -nc --arg d "${u}" '{displayName:$d}')" 2>/dev/null || echo 000)"
  case "${code}" in
    200) ;;
    404) warn "onboard: ${u} -> 404. The gateway route table sends /bff/register/** to a service that does not implement stage 2 (admin-bff does)." ; rm -f "${jar}"; return 1 ;;
    *)   warn "onboard: ${u} -> ${code}" ; rm -f "${jar}"; return 1 ;;
  esac
  # Stage 3: the platform accounts, only for the roles this persona actually holds.
  roles=",$(persona_roles "${u}"),"
  case "${roles}" in *,ROLE_MATRIX,*)   provision_platform "${u}" matrix   "${jar}" || rc=1 ;; esac
  case "${roles}" in *,ROLE_MASTODON,*) provision_platform "${u}" mastodon "${jar}" || rc=1 ;; esac
  rm -f "${jar}"
  return "${rc}"
}

if [ "${SEED_COMPLETE_REGISTRATION}" = "1" ]; then
  log "leg 1c: onboarding personas (registration stage 2 + platform provisioning)"
  reg_ok=0; reg_gated=0; reg_fail=0
  for persona in ${REGISTRATION_PERSONAS}; do
    onboard_persona "${persona}" && { reg_ok=$((reg_ok+1)); continue; }
    case "$?" in
      2) reg_gated=$((reg_gated+1)) ;;
      *) reg_fail=$((reg_fail+1)) ;;
    esac
  done
  # CONFIRM the Mastodon accounts the broker just registered. Mastodon refuses every
  # authenticated API call from an unconfirmed login — `verify_credentials` answers
  # 403 "Your login is missing a confirmed e-mail address" — so provisioning would
  # return a valid access_token that cannot be used, and the operator gets a Mastodon
  # tab that loads and cannot toot. The broker registers over the API and has no way
  # to confirm (no mail is delivered on a throwaway local stack), and the personas
  # seeded in leg 3 dodge this only because `tootctl accounts create --confirmed`
  # bypasses the API entirely.
  # Driven off the DB rather than a derived username: the broker's local username is
  # the Casdoor UUID with '-' -> '_' TRUNCATED to Mastodon's 30-char limit
  # (2158d2dd_f0d8_42a5_8cfc_66dd69), which is fragile to reconstruct here. Asking
  # which logins are unconfirmed is exact, and self-heals accounts left behind by an
  # earlier partial run.
  mastodon_confirm_unconfirmed() {
    local db u n=0
    db="$(find_ctr mastodon-db || true)"
    [ -n "${db}" ] && [ -n "${MASTODON_CTR:-}" ] || return 0
    for u in $(docker exec "${db}" psql -U mastodon -d mastodon -tAc \
                 "select a.username from users u join accounts a on a.id=u.account_id
                   where u.confirmed_at is null;" 2>/dev/null); do
      docker exec "${MASTODON_CTR}" bin/tootctl accounts modify "${u}" --confirm >/dev/null 2>&1 \
        && n=$((n+1)) || warn "could not confirm Mastodon login ${u}"
    done
    [ "${n}" -eq 0 ] || log "confirmed ${n} broker-registered Mastodon login(s)"
  }
  mastodon_confirm_unconfirmed

  log "leg 1c OK: ${reg_ok} onboarded, ${reg_gated} left gated on purpose (${SEED_REGISTRATION_SKIP}), ${reg_fail} failed"
  # A failure here is NOT fatal: leg 1's identities are seeded either way, and the
  # operator can still complete registration from the UI. Say it plainly instead.
  [ "${reg_fail}" -eq 0 ] || warn "leg 1c: ${reg_fail} persona(s) could not be fully onboarded (see the WARNs above)"
  # Which persona opens which app is ROLE-gated, and that is the single most common
  # confusion here: signing in as e2e-admin renders the Matrix UI shell and then 403s
  # on every call, because e2e-admin holds no ROLE_MATRIX. Name the right accounts.
  log "          Matrix needs ROLE_MATRIX (e.g. e2e-matrix); Mastodon needs ROLE_MASTODON (e.g. e2e-mastodon)."
  log "          e2e-admin/e2e-mod hold NO platform-access role — their Matrix/Mastodon tabs will 403 BY DESIGN."
fi
# ── LEG 1b: second-tenant persona (needs a brand-B Casdoor) ──────────────────
if [ -n "${CASDOOR_BRAND_B_URL}" ]; then
  log "leg 1b: second-tenant persona at ${CASDOOR_BRAND_B_URL}"
  curl -sf -o /dev/null --max-time 5 "${CASDOOR_BRAND_B_URL}/" \
    || die "CASDOOR_BRAND_B_URL=${CASDOOR_BRAND_B_URL} set but not answering"
  casdoor_login "${CASDOOR_BRAND_B_URL}"
  ensure_org    "${CASDOOR_BRAND_B_URL}" "${CASDOOR_ORG}"
  ensure_roles  "${CASDOOR_BRAND_B_URL}" "${CASDOOR_ORG}"
  ensure_app    "${CASDOOR_BRAND_B_URL}" "${CASDOOR_ORG}"
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

if [ "${SEED_CASDOOR_ONLY}" = "1" ]; then
  log "SEED_CASDOOR_ONLY=1 — Casdoor identity seeded (org + roles + app-user-bff + personas); skipping the Matrix/Mastodon social legs. Real SSO web login is ready."
  exit 0
fi

# ══ LEG 2: Matrix — users + public room X + invite-only room Y ═══════════════
log "leg 2: Matrix users + rooms at ${SYNAPSE_URL} (server_name=${MATRIX_SERVER_NAME})"

matrix_register() { # <user>
  local first out err
  # Public CS-API UIAA registration (the same flow the BFF's Matrix-account
  # mint uses): POST /register without auth -> 401 carrying a UIAA session
  # advertising m.login.dummy (the tuwunel service enables open registration —
  # compose.real.yaml), then complete the dummy stage. Registered users are
  # PLAIN users (the tuwunel service sets grant_admin_to_first_user=false, so
  # nobody is silently promoted to server admin). M_USER_IN_USE is the
  # idempotent no-op.
  # `|| true` guards: a transient curl failure or a non-JSON body must fall
  # through to the crafted die below, not abort via set -e/pipefail with a raw
  # curl/jq error.
  first="$(curl -s "${SYNAPSE_URL}/_matrix/client/v3/register" -X POST \
    -H 'content-type: application/json' \
    -d "{\"username\":\"$1\",\"password\":\"${E2E_PASSWORD}\"}" || true)"
  if echo "${first}" | jq -e '.user_id // empty | length > 0' >/dev/null; then
    log "matrix user $1 registered"; return 0
  fi
  if echo "${first}" | jq -e '.errcode == "M_USER_IN_USE"' >/dev/null; then
    log "matrix user $1 present"; return 0
  fi
  local session
  session="$(echo "${first}" | jq -r '.session // empty' 2>/dev/null || true)"
  [ -n "${session}" ] \
    || die "could not register Matrix user $1: ${first} (does the tuwunel service enable registration? see compose.real.yaml's TUWUNEL_ALLOW_REGISTRATION env)"
  out="$(curl -s "${SYNAPSE_URL}/_matrix/client/v3/register" -X POST \
    -H 'content-type: application/json' \
    -d "{\"username\":\"$1\",\"password\":\"${E2E_PASSWORD}\",\"auth\":{\"type\":\"m.login.dummy\",\"session\":\"${session}\"}}" || true)"
  if echo "${out}" | jq -e '.user_id // empty | length > 0' >/dev/null; then
    log "matrix user $1 registered"
  elif echo "${out}" | jq -e '.errcode == "M_USER_IN_USE"' >/dev/null; then
    log "matrix user $1 present"
  else
    die "could not register Matrix user $1: ${out} (does the tuwunel service enable registration? see compose.real.yaml's TUWUNEL_ALLOW_REGISTRATION env)"
  fi
}

matrix_token() { # <user>
  curl -sf "${SYNAPSE_URL}/_matrix/client/v3/login" -X POST \
    -H 'content-type: application/json' \
    -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"$1\"},\"password\":\"${E2E_PASSWORD}\"}" \
    | jq -re '.access_token' \
    || die "Matrix login failed for $1 (password mismatch? re-run with the E2E_PASSWORD the user was registered with)"
}

matrix_room_by_alias() { # <alias-localpart> -> room_id or empty
  curl -s "${SYNAPSE_URL}/_matrix/client/v3/directory/room/%23$1%3A${MATRIX_SERVER_NAME}" \
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
      -d "{\"preset\":\"private_chat\",\"room_alias_name\":\"e2e-invite-y\",\"name\":\"E2E Invite-Only Room Y\",\"invite\":[\"@e2e-user:${MATRIX_SERVER_NAME}\"]}" \
    | jq -re '.room_id')" || die "could not create invite-only room Y"
  log "room Y created: ${ROOM_Y} (e2e-user invited)"
else
  log "room Y exists: ${ROOM_Y}"
fi

# VERIFY (fail-honest): both aliases must resolve, and Y must be invite-only.
[ -n "$(matrix_room_by_alias e2e-public-x)" ] || die "room X alias did not resolve after seed"
[ -n "$(matrix_room_by_alias e2e-invite-y)" ] || die "room Y alias did not resolve after seed"
JOIN_RULE="$(curl -s "${SYNAPSE_URL}/_matrix/client/v3/rooms/$(jq -rn --arg r "${ROOM_Y}" '$r|@uri')/state/m.room.join_rules" \
  -H "authorization: Bearer ${MOD_TOK}" | jq -r '.join_rule // empty')"
[ "${JOIN_RULE}" = "invite" ] || die "room Y join_rule is '${JOIN_RULE}', expected 'invite' (invite-only contract)"
log "leg 2 OK: room X (public) + room Y (invite-only) verified"

# ══ LEG 3: Mastodon — accounts, follow userB->userA, pending mod-queue item ══
log "leg 3: Mastodon accounts + follow + pending report at ${MASTODON_URL}"

# OPEN REGISTRATIONS, or the platform-provisioning leg cannot mint an account.
# Mastodon ships `Setting.registrations_mode = 'none'` here, and with it closed
# `POST /api/v1/accounts` answers 403 — so user-bff's Mastodon broker fails with
# "mastodon mint: no access_token" (it gets a client-credentials token fine, is
# refused the register call, then finds no account for the password grant) and
# /bff/provision/mastodon 502s. The operator sees a Mastodon tab that loads and
# cannot toot.
# This was invisible until leg 1c started exercising the API path: the personas
# below are made with `tootctl accounts create`, which bypasses the API and is
# unaffected by registrations_mode. So the seed looked green while the surface a
# real user goes through was closed.
# `open` matches this stack's LAN-test posture (it is a throwaway local Mastodon
# on localhost), and EMAIL_DOMAIN_ALLOWLIST still gates who may actually sign up.
# NOTE: registrations_mode is a DB Setting, not an env var — there is no
# REGISTRATIONS_MODE in the container's environment, so this cannot move to
# gen-mastodon-env.sh.
# Read the REAL setting. `bin/tootctl settings registrations` with no subcommand
# does NOT print the current mode — it prints its HELP TEXT:
#     tootctl registrations approved   # Open approval-based registrations
#     tootctl registrations open       # Open registrations
# registrations_mode is a DB Setting with no tootctl reader, so go through Rails.
mastodon_registrations_mode() {
  docker exec "${MASTODON_CTR}" bin/rails runner 'print Setting.registrations_mode' 2>/dev/null \
    | tr -d '[:space:]' || true
}

mastodon_open_registrations() {
  local mode
  mode="$(mastodon_registrations_mode)"
  # The previous check was `case "$(tootctl settings registrations)" in *open*)`,
  # a SUBSTRING match against the help text above — which contains "open" twice.
  # It therefore matched on EVERY run, logged "already open", and returned
  # without opening anything. registrations_mode stayed `none`, POST
  # /api/v1/accounts kept answering 403, and the damage surfaced far from its
  # cause: user-bff's Mastodon broker could not mint an account, so
  # /bff/user/mastodon/** answered 502 and the Mastodon e2e leg failed with a
  # green-looking seed. Compare the exact value instead.
  if [ "${mode}" = "open" ]; then
    log "mastodon registrations already open"
    return 0
  fi
  docker exec "${MASTODON_CTR}" bin/tootctl settings registrations open >/dev/null 2>&1 || true
  # VERIFY the outcome, not the exit status — re-read the setting.
  local after
  after="$(mastodon_registrations_mode)"
  if [ "${after}" = "open" ]; then
    log "mastodon registrations opened (was: ${mode:-unknown})"
  else
    warn "could not open Mastodon registrations (still '${after:-unknown}') — /bff/user/mastodon/** and /bff/provision/mastodon will 502 with \"mastodon mint: no access_token\" until it is open (tootctl settings registrations open)"
  fi
}
mastodon_open_registrations

mastodon_account() { # <user>
  local out
  # --email domain MUST be in this container's EMAIL_DOMAIN_ALLOWLIST
  # (tests/stack/.mastodon.env: EMAIL_DOMAIN_ALLOWLIST=e2e.local) — any other
  # domain (e.g. the hugmesh.test this used to hardcode) is rejected outright
  # with a generic "email unreachable" failure, regardless of MX reachability.
  out="$(docker exec "${MASTODON_CTR}" bin/tootctl accounts create "$1" \
          --email "$1@e2e.local" --confirmed --approve 2>&1)" \
    || { echo "${out}" | grep -qi "taken\|exists" \
           || die "could not create Mastodon account $1: ${out}"; }
  log "mastodon account $1 present"
}
mastodon_account e2e_usera
mastodon_account e2e_userb

# Follow + report via rails runner INSIDE the container (tootctl has no follow/
# report verb; the runner aborts non-zero on any missing precondition — honest).
docker exec -i "${MASTODON_CTR}" bundle exec rails runner - <<'RUBY' || die "Mastodon follow/report seed failed (see runner output above)"
a = Account.find_local("e2e_usera")
b = Account.find_local("e2e_userb")
abort("SEED-DEP: e2e_usera/e2e_userb missing (tootctl create failed earlier?)") unless a && b

if b.following?(a)
  puts "[seed-e2e] follow e2e_userb -> e2e_usera exists"
else
  FollowService.new.call(b, a)
  abort("SEED-DEP: follow did not take") unless b.reload.following?(a)
  puts "[seed-e2e] follow e2e_userb -> e2e_usera created"
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
