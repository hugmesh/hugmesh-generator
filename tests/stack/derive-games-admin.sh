#!/usr/bin/env bash
# derive-games-admin.sh — materialise the DERIVED systems Casdoor role
#
#     ROLE_GAMES_ADMIN  =  ROLE_GAMES  ∩  (ROLE_ADMIN  ∪  ROLE_MOD)
#
# on the COMPOSE lane. This is the compose twin of the cluster's games-admin-sync
# Job (specs/cluster/manifests/casdoor/games-admin-sync-job.yaml): same rule, same
# Casdoor transport (admin login -> cookie -> get-role / update-role), same
# default-deny semantics (the role's users[] is overwritten with EXACTLY the
# verified intersection, so anyone who lost ROLE_GAMES or admin|mod is PRUNED).
#
# WHY A SEPARATE SCRIPT and not a few lines in seed-e2e.sh: the deploy step for
# the games screens must be able to (re)derive the role on a stack whose e2e
# password it must not rotate — seed-e2e.sh re-renders and re-applies every
# persona credential, this script touches ONE role's membership and nothing
# else. seed-e2e.sh calls it after apply-systems-roles.sh (which deliberately
# sends ROLE_GAMES_ADMIN EMPTY — the derived role is never granted directly).
#
# Casdoor role nesting is UNION (inheritance), never intersection, so the AND
# cannot be expressed as a nested role — it has to be reconciled, here.
#
# USAGE
#   tests/stack/derive-games-admin.sh                 # reconcile against CASDOOR_URL
#   tests/stack/derive-games-admin.sh --dry-run       # read Casdoor, compute, print, never write
#   tests/stack/derive-games-admin.sh --fixture F.json # NO NETWORK: read the four role
#                                                     # memberships from a JSON file
#                                                     # {"ROLE_GAMES":[..],"ROLE_ADMIN":[..],
#                                                     #  "ROLE_MOD":[..],"ROLE_GAMES_ADMIN":[..]}
#                                                     # (implies --dry-run)
#
# ENV (the same names seed-e2e.sh uses, same defaults — the compose dev Casdoor):
#   CASDOOR_URL          default http://localhost:8000
#   CASDOOR_ADMIN_USER   default admin
#   CASDOOR_ADMIN_PASS   default 123        (never printed)
#   CASDOOR_ORG          default hugmesh
#   GAMES_ADMIN_ROLE     default ROLE_GAMES_ADMIN   (the role this script OWNS)
#   GAMES_ROLE           default ROLE_GAMES
#   PRIV_ROLES           default "ROLE_ADMIN ROLE_MOD" (the (admin|mod) half)
#
# OUTPUT: counts and member handles only — `ROLE_GAMES_ADMIN -> N member(s)
# (+a added, -r removed)`. No secret, no request body, no cookie ever reaches
# stdout/stderr.
#
# HONESTY RULES, carried over from the Job and apply-systems-roles.sh:
#   * Casdoor answers a DENIED call with HTTP 200 + {"status":"error"}, so every
#     response envelope is checked (.status == "ok"); curl's exit code alone is
#     not evidence.
#   * /api/login returning ok is not proof of a session: /api/get-account must
#     resolve to the admin user, or every role below reads as empty and a prune
#     to empty would be announced as a reconcile.
#   * get-role answers ok + data:null for an ABSENT role; status error is a
#     DENIAL, never an absence. An absent GAMES_ADMIN_ROLE is fatal (seed-e2e.sh's
#     ensure_roles creates it).
#   * A write is only announced after a READ-BACK through the same checked path
#     shows the new membership (Casdoor has answered ok/"Affected" to writes it
#     did not persist).
#   * Exit non-zero on ANY failed call — never a partial reconcile reported whole.
set -euo pipefail

CASDOOR_URL="${CASDOOR_URL:-http://localhost:8000}"
CASDOOR_ADMIN_USER="${CASDOOR_ADMIN_USER:-admin}"
CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS:-123}"
CASDOOR_ORG="${CASDOOR_ORG:-hugmesh}"
GAMES_ADMIN_ROLE="${GAMES_ADMIN_ROLE:-ROLE_GAMES_ADMIN}"
GAMES_ROLE="${GAMES_ROLE:-ROLE_GAMES}"
PRIV_ROLES="${PRIV_ROLES:-ROLE_ADMIN ROLE_MOD}"

DRY_RUN=0
FIXTURE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --fixture) FIXTURE="${2:?--fixture needs a file}"; DRY_RUN=1; shift 2 ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "derive-games-admin: unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { echo "[derive-games-admin] $*"; }
die() { echo "[derive-games-admin] FATAL: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"
[ -n "${FIXTURE}" ] || command -v curl >/dev/null 2>&1 || die "curl is required"

# ── the ONE way this script talks to Casdoor ─────────────────────────────────
CJ=""
cleanup() { [ -n "${CJ}" ] && rm -f "${CJ}"; return 0; }
trap cleanup EXIT

# casdoor_call <GET|POST> <path> [json-body]  -> prints the response body
# Dies unless the envelope says status ok. The request body is never echoed.
casdoor_call() {
  local method
  local path
  local body
  local resp
  local status
  method="$1"; path="$2"; body="${3:-}"
  if [ "${method}" = "POST" ]; then
    resp="$(curl -s --max-time 15 -b "${CJ}" -c "${CJ}" -X POST "${CASDOOR_URL}${path}" \
              -H 'content-type: application/json' --data-binary "${body}" 2>/dev/null)" \
      || die "${method} ${path}: Casdoor at ${CASDOOR_URL} did not answer"
  else
    resp="$(curl -s --max-time 15 -b "${CJ}" -c "${CJ}" "${CASDOOR_URL}${path}" 2>/dev/null)" \
      || die "${method} ${path}: Casdoor at ${CASDOOR_URL} did not answer"
  fi
  status="$(printf '%s' "${resp}" | jq -r '.status // empty' 2>/dev/null || true)"
  if [ "${status}" != "ok" ]; then
    die "${method} ${path}: Casdoor did not report success ($(printf '%s' "${resp}" | jq -r '.msg // "non-JSON or no status"' 2>/dev/null || echo 'unparseable response'))"
  fi
  printf '%s' "${resp}"
}

casdoor_login() {
  local me
  local name
  local payload
  CJ="$(mktemp "${TMPDIR:-/tmp}/derive-games-admin.cj.XXXXXX")"
  payload="$(jq -nc --arg u "${CASDOOR_ADMIN_USER}" --arg p "${CASDOOR_ADMIN_PASS}" \
    '{application:"app-built-in",organization:"built-in",username:$u,password:$p,type:"login",autoSignin:true}')"
  casdoor_call POST "/api/login" "${payload}" >/dev/null \
    || die "Casdoor admin login failed at ${CASDOOR_URL} (CASDOOR_ADMIN_USER/CASDOOR_ADMIN_PASS)"
  # Prove the session: a 200/ok from /api/login is not one (casdoor-init once
  # reconciled anonymously behind an unchecked login).
  me="$(casdoor_call GET "/api/get-account")"
  name="$(printf '%s' "${me}" | jq -r '.data.name // .name // empty')"
  [ "${name}" = "${CASDOOR_ADMIN_USER}" ] \
    || die "Casdoor admin login did not yield an admin session (the session resolves to '${name:-nobody}')"
}

# role_members <role> -> JSON array of member ids ("org/name"), [] when absent.
# role_object  <role> -> the full role object, or empty when the role is absent.
role_object() {
  local resp
  resp="$(casdoor_call GET "/api/get-role?id=${CASDOOR_ORG}/$1")"
  printf '%s' "${resp}" | jq -c '.data // empty'
}
role_members_from_object() {  # <role-object-json-or-empty>
  if [ -z "$1" ] || [ "$1" = "null" ]; then printf '[]'; else printf '%s' "$1" | jq -c '.users // []'; fi
}

# ── 1. read the inputs ───────────────────────────────────────────────────────
games_members='[]'
priv_members='[]'
target_object=''
current_members='[]'

if [ -n "${FIXTURE}" ]; then
  [ -r "${FIXTURE}" ] || die "fixture ${FIXTURE} is not readable"
  jq -e 'type == "object"' "${FIXTURE}" >/dev/null 2>&1 || die "fixture ${FIXTURE} is not a JSON object"
  games_members="$(jq -c --arg r "${GAMES_ROLE}" '.[$r] // []' "${FIXTURE}")"
  for r in ${PRIV_ROLES}; do
    priv_members="$(jq -nc --argjson a "${priv_members}" --argjson b "$(jq -c --arg r "${r}" '.[$r] // []' "${FIXTURE}")" '$a + $b | unique')"
  done
  jq -e --arg r "${GAMES_ADMIN_ROLE}" 'has($r)' "${FIXTURE}" >/dev/null 2>&1 \
    || die "fixture ${FIXTURE} has no ${GAMES_ADMIN_ROLE} key — the derived role must exist before it can be derived into"
  current_members="$(jq -c --arg r "${GAMES_ADMIN_ROLE}" '.[$r] // []' "${FIXTURE}")"
  log "fixture ${FIXTURE}: no network, dry run"
else
  casdoor_login
  games_members="$(role_members_from_object "$(role_object "${GAMES_ROLE}")")"
  for r in ${PRIV_ROLES}; do
    priv_members="$(jq -nc --argjson a "${priv_members}" --argjson b "$(role_members_from_object "$(role_object "${r}")")" '$a + $b | unique')"
  done
  target_object="$(role_object "${GAMES_ADMIN_ROLE}")"
  [ -n "${target_object}" ] \
    || die "${CASDOOR_ORG}/${GAMES_ADMIN_ROLE} does not exist in Casdoor ${CASDOOR_URL} — seed-e2e.sh ensure_roles creates it; refusing to derive into a role that is not there"
  current_members="$(role_members_from_object "${target_object}")"
fi

# ── 2. the AND ───────────────────────────────────────────────────────────────
qualified="$(jq -nc --argjson g "${games_members}" --argjson p "${priv_members}" \
  '[$g[] | select(. as $x | $p | index($x) != null)] | unique')"
added="$(jq -nc --argjson q "${qualified}" --argjson c "${current_members}" '($q - $c) | sort')"
removed="$(jq -nc --argjson q "${qualified}" --argjson c "${current_members}" '($c - $q) | sort')"
n_q="$(printf '%s' "${qualified}" | jq 'length')"
n_a="$(printf '%s' "${added}" | jq 'length')"
n_r="$(printf '%s' "${removed}" | jq 'length')"

report() {
  local verb
  verb="$1"
  log "${GAMES_ADMIN_ROLE} ${verb} ${n_q} member(s) (+${n_a} added, -${n_r} removed) = ${GAMES_ROLE} ∩ (${PRIV_ROLES// / ∪ })"
  [ "${n_q}" -eq 0 ] || log "  members: $(printf '%s' "${qualified}" | jq -r 'join(", ")')"
  [ "${n_a}" -eq 0 ] || log "  + $(printf '%s' "${added}" | jq -r 'join(", ")')"
  [ "${n_r}" -eq 0 ] || log "  - $(printf '%s' "${removed}" | jq -r 'join(", ")')"
}

if [ "${n_a}" -eq 0 ] && [ "${n_r}" -eq 0 ]; then
  report "already =="
  log "no change"
  exit 0
fi

if [ "${DRY_RUN}" = "1" ]; then
  report "would ->"
  log "DRY RUN: nothing written"
  exit 0
fi

# ── 3. write EXACTLY the intersection, then read it back ─────────────────────
upd="$(printf '%s' "${target_object}" | jq -c --argjson members "${qualified}" '.users = $members')"
casdoor_call POST "/api/update-role?id=${CASDOOR_ORG}/${GAMES_ADMIN_ROLE}" "${upd}" >/dev/null
verified_object="$(role_object "${GAMES_ADMIN_ROLE}")"
[ -n "${verified_object}" ] \
  || die "update-role reported success but ${GAMES_ADMIN_ROLE} is no longer readable — refusing to report a membership change"
verified="$(role_members_from_object "${verified_object}" | jq -c 'sort')"
if [ "${verified}" != "$(printf '%s' "${qualified}" | jq -c 'sort')" ]; then
  die "update-role reported success but ${GAMES_ADMIN_ROLE} membership did not change (read back $(printf '%s' "${verified}" | jq 'length') member(s), wanted ${n_q})"
fi
report "->"
log "verified by read-back"
