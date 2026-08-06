#!/usr/bin/env bash
# verify-seeded-identities.sh — POSITIVE POST-CONDITION for the SSO-slice
# identity seed. Reads the seeded catalogue BACK out of the live Casdoor and
# fails if it is not there, so bootstrap-kind.sh cannot print "SSO slice seeded."
# over an empty Casdoor.
#
#   Usage: verify-seeded-identities.sh <roles-dir>        # dir holding
#                                                        # casdoor-systems-roles.json
#   CASDOOR_URL         (default http://127.0.0.1:8000)
#   CASDOOR_ADMIN_USER  (default admin)
#   CASDOOR_ADMIN_PASS  (required)
#   CASDOOR_ORG         (default hugmesh)
#   VERIFY_REQUIRE_USER (default e2e-user) — one user that MUST exist even if the
#                       catalogue were somehow empty, so an empty matrix cannot
#                       vacuously pass.
#
# WHY THIS EXISTS, SEPARATELY FROM THE APPLY HOOK. The apply hook now checks
# every response envelope, but it is still the same process reporting on its own
# work. This re-authenticates from scratch (fresh cookie jar) and re-reads the
# result, which is the only evidence that survives a hook that lies — the exact
# failure mode this harness shipped with: Casdoor answers a DENIED call with HTTP
# 200 + {"status":"error"} (upstream controllers/util.go ResponseError() sets
# Status:"error" and never touches the HTTP status, and RequireSignedIn()/
# RequireAdmin() both funnel through it), so a `curl -sf` seeding run performed
# entirely anonymously exited 0 with "added"/"skipped" printed for everything.
#
# ABSENT vs DENIED is a real distinction in Casdoor and is treated as one here:
# GetUser()/GetRole() on a non-existent id return ResponseOk(nil) =
# {"status":"ok","data":null}; a denial returns {"status":"error"}. Both are
# failures for this script, but they are reported differently so the operator
# knows whether to fix the password or re-run the seed.
set -euo pipefail

ROLES_DIR="${1:-}"
[ -n "${ROLES_DIR}" ] || { echo "usage: $0 <roles-dir>" >&2; exit 2; }
ROLES_JSON="${ROLES_DIR}/casdoor-systems-roles.json"

BASE="${CASDOOR_URL:-http://127.0.0.1:8000}"
ORG="${CASDOOR_ORG:-hugmesh}"
AU="${CASDOOR_ADMIN_USER:-admin}"
AP="${CASDOOR_ADMIN_PASS:?CASDOOR_ADMIN_PASS required}"
REQUIRE_USER="${VERIFY_REQUIRE_USER:-e2e-user}"

WORK="$(mktemp -d)"; CJ="${WORK}/cookies"; : > "${CJ}"
trap 'rm -rf "${WORK}"' EXIT
log() { echo "[verify-seed] $*"; }
die() { echo "[verify-seed] FATAL: $*" >&2; exit 1; }

for _t in curl jq; do
  command -v "${_t}" >/dev/null 2>&1 || die "missing required tool: ${_t}"
done
[ -f "${ROLES_JSON}" ] || die "role matrix not found: ${ROLES_JSON}"

# Same envelope contract as the apply hook (kept deliberately self-contained:
# this file is committed, the apply hook is RENDERED by tests/qemu/seed-accounts.sh,
# so they cannot share a library without the rendered payload growing a
# dependency on this repo's layout).
casdoor_call() { # <GET|POST> <path> [json-body] -> body on stdout
  local method="$1" path="$2" body="${3:-}" code status msg
  local -a args=(-s -o "${WORK}/body" -w '%{http_code}' -b "${CJ}" -c "${CJ}"
                 -X "${method}" -H 'content-type: application/json')
  [ -n "${body}" ] && args+=(-d "${body}")
  : > "${WORK}/body"
  code="$(curl "${args[@]}" "${BASE}${path}" 2>/dev/null)" \
    || die "${method} ${path}: curl transport failure (is ${BASE} reachable?)"
  case "${code}" in
    2*) : ;;
    *)  die "${method} ${path}: HTTP ${code} — $(head -c 200 "${WORK}/body" 2>/dev/null)" ;;
  esac
  jq -e 'type == "object"' "${WORK}/body" >/dev/null 2>&1 \
    || die "${method} ${path}: HTTP ${code} but the body is not a JSON object — $(head -c 200 "${WORK}/body")"
  status="$(jq -r '.status // empty' "${WORK}/body")"
  if [ "${status}" != "ok" ]; then
    msg="$(jq -r '.msg // "(no msg)"' "${WORK}/body")"
    die "${method} ${path}: DENIED — HTTP ${code}, status='${status:-<absent>}', msg='${msg}'. Casdoor rejected the read, so the seed cannot be verified (a wrong CASDOOR_ADMIN_PASS looks exactly like this)."
  fi
  cat "${WORK}/body"
}

log "re-authenticating at ${BASE} as '${AU}' (fresh session, independent of the apply hook)"
casdoor_call POST /api/login \
  "{\"application\":\"app-built-in\",\"organization\":\"built-in\",\"username\":\"${AU}\",\"password\":\"${AP}\",\"type\":\"login\",\"autoSignin\":true}" \
  >/dev/null
cookies="$(awk -F'\t' 'NF>=7 {n++} END {print n+0}' "${CJ}" 2>/dev/null || echo 0)"
[ "${cookies}" -gt 0 ] \
  || die "/api/login returned status=ok but set NO session cookie — the verification reads that follow would be anonymous"

# ── 1. Every catalogued user must exist ─────────────────────────────────────
declared="$(jq '.users | length' "${ROLES_JSON}")"
[ "${declared}" -gt 0 ] || die "role matrix declares zero users — refusing to 'verify' an empty catalogue"
seen=0; missing_users=""
while IFS= read -r name; do
  [ -n "${name}" ] || continue
  resp="$(casdoor_call GET "/api/get-user?id=${ORG}/${name}")"
  got="$(printf '%s' "${resp}" | jq -r '.data.name // empty')"
  if [ "${got}" = "${name}" ]; then
    seen=$((seen+1))
  else
    missing_users="${missing_users} ${name}"
  fi
done < <(jq -r '.users[].name' "${ROLES_JSON}")
[ -z "${missing_users}" ] \
  || die "Casdoor answered status=ok but does NOT have these seeded user(s):${missing_users} — the seed did not land (${seen}/${declared} present)"

# ── 2. The named required user must exist even if the catalogue changes ─────
# A catalogue that stopped listing e2e-user would otherwise let check 1 pass
# while the login e2e has no identity to log in as.
req="$(casdoor_call GET "/api/get-user?id=${ORG}/${REQUIRE_USER}")"
[ "$(printf '%s' "${req}" | jq -r '.data.name // empty')" = "${REQUIRE_USER}" ] \
  || die "required user ${ORG}/${REQUIRE_USER} is absent from Casdoor (status=ok, data=null) — the SSO slice is NOT seeded"

# ── 3. Every non-empty role grant must be present on the role object ────────
roles_checked=0; bad_roles=""
while IFS= read -r r; do
  [ -n "${r}" ] || continue
  rname="$(printf '%s' "$r" | jq -r '.name')"
  want="$(printf '%s' "$r" | jq -c '.users')"
  [ "$(printf '%s' "${want}" | jq 'length')" -gt 0 ] || continue   # derived/empty by design
  resp="$(casdoor_call GET "/api/get-role?id=${ORG}/${rname}")"
  data="$(printf '%s' "${resp}" | jq -c '.data // empty')"
  if [ -z "${data}" ] || [ "${data}" = "null" ]; then
    bad_roles="${bad_roles} ${rname}(absent)"; continue
  fi
  got="$(printf '%s' "${resp}" | jq -c '.data.users // []')"
  gap="$(jq -nr --argjson want "${want}" --argjson got "${got}" '($want - $got) | join(",")')"
  [ -z "${gap}" ] || bad_roles="${bad_roles} ${rname}(missing:${gap})"
  roles_checked=$((roles_checked+1))
done < <(jq -c '.roles[]' "${ROLES_JSON}")
[ -z "${bad_roles}" ] \
  || die "role membership did not land:${bad_roles}"
[ "${roles_checked}" -gt 0 ] \
  || die "no role carried any member — the matrix would grant nobody anything"

log "OK — ${seen}/${declared} users and ${roles_checked} non-empty role grant(s) read back from ${BASE}"
