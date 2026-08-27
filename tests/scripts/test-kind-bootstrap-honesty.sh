#!/usr/bin/env bash
# test-kind-bootstrap-honesty.sh — the kind SSO harness must not report work it
# did not do.
#
# WHY THIS EXISTS. Two ways the harness (specs/cluster/bootstrap/kind-local)
# claimed success while doing nothing, or worse:
#
#  (1) THE IDENTITY SEED REPORTED SUCCESS WHILE SEEDING NOTHING.
#      Casdoor answers a DENIED call with HTTP **200** carrying
#      {"status":"error","msg":…}. Upstream controllers/util.go:
#          func (c *ApiController) ResponseError(error string, data ...interface{}) {
#              resp := &Response{Status: "error", Msg: error}
#              c.ResponseJsonData(resp, data...)
#          }
#      — it never sets an HTTP status, and RequireSignedIn()/RequireAdmin() both
#      report their denials through it. The seed hook used `curl -sf`, which
#      fails only on HTTP >= 400, so it could not see a denial at all. On a fresh
#      cluster Casdoor still holds its BUILT-IN default admin password (nothing
#      applies the Vault-minted one), so /api/login was denied, the cookie jar
#      stayed empty, every get-user read "" (indistinguishable from "not created
#      yet"), every add-user was an anonymous denied call, every get-role read
#      empty -> "role missing — skip", and the run exited 0 while the bootstrap
#      printed "SSO slice seeded."
#      Casdoor DOES distinguish absent from denied — GetUser()/GetRole() on a
#      missing id return ResponseOk(nil) = {"status":"ok","data":null} — so the
#      information was there; nothing looked at it.
#
#  (2) "IDEMPOTENT" WAS FALSE AND DESTRUCTIVE under KIND_PROFILE=sso.
#      The KV seed step had no already-done guard (unlike the cluster-CA mint,
#      the Vault init and the KV mount, which all have one), so a re-run invoked
#      gen-cluster-secrets.sh again — and that script mints every password
#      unconditionally with `openssl rand` and overwrites Vault. The Postgres
#      instances keep the FIRST run's passwords (initdb only runs on an empty
#      PGDATA), so a second `make kind-up` wedged the cluster it claimed to
#      converge: `password authentication failed for user "userbff"`.
#
# HOW IT TESTS. Behaviourally, never by grepping for the fix. It RENDERS the real
# apply hook with the real tests/qemu/seed-accounts.sh and RUNS it, plus the real
# verify/seed helpers, against stubs:
#   * a `curl` stub that reproduces Casdoor's actual contract — HTTP 200 for
#     denials, a session cookie only on a correct password, ResponseOk(nil) for
#     absent objects, wrapActionResponse's Affected/Unaffected for writes;
#   * a `vault` stub + a recording fake seeder for the KV idempotence contract.
# The deny controls are DERIVED from the endpoints the rendered hook actually
# calls, so an endpoint added later is covered without editing this file.
#
# Offline: bash + jq + coreutils. No cluster, no kind, no docker, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

KIND_DIR="${REPO}/specs/cluster/bootstrap/kind-local"
BOOTSTRAP="${KIND_DIR}/bootstrap-kind.sh"
SEED_KV="${KIND_DIR}/seed-vault-kv.sh"
VERIFY="${KIND_DIR}/verify-seeded-identities.sh"
KIND_README="${KIND_DIR}/README.md"
SEED_ACCOUNTS="${REPO}/tests/qemu/seed-accounts.sh"
GEN_SECRETS="${REPO}/scripts/gen-cluster-secrets.sh"
CI_FILE="${REPO}/.gitlab-ci.yml"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# Tooling is a HARD requirement, never a skip: a guard that skips in CI is a
# guard that never guards (this repo has shipped several).
for t in bash jq awk sed grep openssl base64; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: ${t} required (refusing to skip — a skipping gate never guards)" >&2; exit 1; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
BIN="${TMP}/bin"; mkdir -p "${BIN}"

# ─────────────────────────────────────────────────────────────────────────────
# The `curl` stub: Casdoor's REAL contract, not a convenient one.
# ─────────────────────────────────────────────────────────────────────────────
cat > "${BIN}/curl" <<'CURLSTUB'
#!/usr/bin/env bash
# Stub curl modelling casdoor's response contract (see the suite header).
#   STUB_STATE          state dir (users/, roles/, log)
#   STUB_ADMIN_PASS     the password /api/login accepts
#   STUB_DENY           space-separated endpoints denied with HTTP 200 + error
#   STUB_HTTP500        space-separated endpoints answered with HTTP 500
#   STUB_NO_COOKIE=1    /api/login says ok but sets no session cookie
#   STUB_NULL_ROLE=1    /api/get-role always answers ResponseOk(nil)
#   STUB_ADD_UNAFFECTED=1  /api/add-user says ok/"Unaffected" and creates nothing
#   STUB_ROLE_NOPERSIST=1  /api/update-role says ok/"Affected" and persists nothing
#   STUB_DROP_USER=NAME    /api/get-user always answers null for NAME
#   STUB_PREMINT=on     the oauth password grant works
set -uo pipefail
S="${STUB_STATE}"; mkdir -p "${S}/users" "${S}/roles"
url=""; out=""; wfmt=""; jar_w=""; jar_r=""; method=""; body=""; form=""; failflag=0
args=("$@"); i=0; n=${#args[@]}
while [ "${i}" -lt "${n}" ]; do
  a="${args[$i]}"
  case "${a}" in
    -o|--output)        i=$((i+1)); out="${args[$i]}" ;;
    -w|--write-out)     i=$((i+1)); wfmt="${args[$i]}" ;;
    -c|--cookie-jar)    i=$((i+1)); jar_w="${args[$i]}" ;;
    -b|--cookie)        i=$((i+1)); jar_r="${args[$i]}" ;;
    -X|--request)       i=$((i+1)); method="${args[$i]}" ;;
    -H|--header)        i=$((i+1)) ;;
    -d|--data|--data-raw) i=$((i+1)); body="${args[$i]}" ;;
    --data-urlencode)   i=$((i+1)); form="${form}&${args[$i]}" ;;
    -s|--silent)        ;;
    -f|--fail)          failflag=1 ;;
    -sf|-fs)            failflag=1 ;;
    http://*|https://*) url="${a}" ;;
    *)                  ;;
  esac
  i=$((i+1))
done
rest="${url#*://}"
case "${rest}" in */*) path="/${rest#*/}" ;; *) path="/" ;; esac
ep="${path%%\?*}"
qid="$(printf '%s' "${url}" | sed -n 's/.*[?&]id=\([^&]*\).*/\1/p')"
qname="${qid#*/}"

emit() { # <http-code> <json-body>
  local code="$1" json="$2"
  printf '%s %s -> %s\n' "${method:-GET}" "${ep}" "${code}" >> "${S}/log"
  if [ -n "${out}" ]; then printf '%s' "${json}" > "${out}"; else printf '%s' "${json}"; fi
  [ -n "${wfmt}" ] && printf '%s' "${code}"
  if [ "${failflag}" = 1 ] && [ "${code}" -ge 400 ]; then exit 22; fi
  exit 0
}
deny() { emit 200 '{"status":"error","msg":"this operation requires administrator to perform","data":null}'; }

case " ${STUB_HTTP500:-} " in *" ${ep} "*) emit 500 '{"status":"error","msg":"internal"}' ;; esac

# Best-effort OAuth2 password grant — checked BEFORE the session gate because it
# is deliberately unauthenticated.
if [ "${ep}" = "/api/login/oauth/access_token" ]; then
  case " ${STUB_DENY:-} " in *" ${ep} "*) deny ;; esac
  if [ "${STUB_PREMINT:-off}" = "on" ]; then emit 200 '{"access_token":"stub-token"}'; fi
  emit 200 '{"status":"error","msg":"grant_type password is not supported"}'
fi

if [ "${ep}" = "/api/login" ]; then
  case " ${STUB_DENY:-} " in *" ${ep} "*) deny ;; esac
  pw="$(printf '%s' "${body}" | jq -r '.password // empty' 2>/dev/null)"
  if [ "${pw}" != "${STUB_ADMIN_PASS:-correct-horse}" ]; then
    # Exactly what a fresh Casdoor does with a password it does not hold:
    # ResponseError -> HTTP 200, status "error", and NO session cookie.
    emit 200 '{"status":"error","msg":"password is incorrect","data":null}'
  fi
  if [ "${STUB_NO_COOKIE:-0}" != "1" ] && [ -n "${jar_w}" ]; then
    { printf '# Netscape HTTP Cookie File\n'
      printf '#HttpOnly_127.0.0.1\tFALSE\t/\tFALSE\t0\tcasdoor_session_id\tstub-session\n'; } > "${jar_w}"
  fi
  emit 200 '{"status":"ok","msg":"","data":{"owner":"built-in","name":"admin"}}'
fi

if [ "${ep}" = "/api/health" ]; then emit 200 '{"status":"ok"}'; fi

# Session gate — every other /api/* call is authorized by the session cookie.
have=0
if [ -n "${jar_r}" ] && [ -f "${jar_r}" ]; then
  awk -F'\t' 'NF>=7 {found=1} END {exit !found}' "${jar_r}" && have=1
fi
if [ "${have}" != 1 ]; then
  emit 200 '{"status":"error","msg":"Please login first","data":null}'
fi
# Keep the caller's jar alive across calls (real curl rewrites what it knows).
if [ -n "${jar_w}" ] && [ -n "${jar_r}" ] && [ "${jar_w}" != "${jar_r}" ] && [ -f "${jar_r}" ]; then
  cp "${jar_r}" "${jar_w}"
fi
case " ${STUB_DENY:-} " in *" ${ep} "*) deny ;; esac

case "${ep}" in
  /api/get-user)
    if [ "${STUB_DROP_USER:-}" = "${qname}" ] || [ ! -f "${S}/users/${qname}" ]; then
      emit 200 '{"status":"ok","msg":"","data":null}'
    fi
    emit 200 "{\"status\":\"ok\",\"msg\":\"\",\"data\":{\"owner\":\"hugmesh\",\"name\":\"${qname}\"}}"
    ;;
  /api/add-user)
    uname_="$(printf '%s' "${body}" | jq -r '.name // empty' 2>/dev/null)"
    if [ "${STUB_ADD_UNAFFECTED:-0}" = "1" ]; then
      emit 200 '{"status":"ok","msg":"","data":"Unaffected"}'
    fi
    if [ -n "${uname_}" ]; then
      printf '%s' "$(printf '%s' "${body}" | jq -r '.password // empty' 2>/dev/null)" > "${S}/users/${uname_}"
    fi
    emit 200 '{"status":"ok","msg":"","data":"Affected"}'
    ;;
  /api/get-role)
    if [ "${STUB_NULL_ROLE:-0}" = "1" ] || [ ! -f "${S}/roles/${qname}" ]; then
      emit 200 '{"status":"ok","msg":"","data":null}'
    fi
    emit 200 "{\"status\":\"ok\",\"msg\":\"\",\"data\":$(cat "${S}/roles/${qname}")}"
    ;;
  /api/update-role)
    if [ "${STUB_ROLE_NOPERSIST:-0}" != "1" ] && [ -n "${body}" ]; then
      printf '%s' "${body}" > "${S}/roles/${qname}"
    fi
    emit 200 '{"status":"ok","msg":"","data":"Affected"}'
    ;;
  /api/set-password)
    # Casdoor's REAL set-password contract (the apply hook's reconcile relies
    # on all three legs of it):
    #   * the target user must exist (controllers/user.go:520-531);
    #   * a new value IDENTICAL to the stored one is REFUSED
    #     (check_password_complexity.go:104-124 -> user.go:629-633) — that
    #     refusal is the only read-back a password has, so a stub that accepted
    #     the same write twice would let a reconciler "verify" against nothing
    #     (exactly the convenient-stub bug this suite's header forbids);
    #   * otherwise the stored value moves.
    # add-user stores the created password in the user file below, so both
    # routes a credential can take into "casdoor" are modelled.
    sname="$(printf '%s' "${form}" | sed -n 's/.*[&]userName=\([^&]*\).*/\1/p')"
    snew="$(printf '%s' "${form}" | sed -n 's/.*[&]newPassword=\([^&]*\).*/\1/p')"
    if [ ! -f "${S}/users/${sname}" ]; then
      emit 200 "{\"status\":\"error\",\"msg\":\"The user: hugmesh/${sname} doesn't exist\",\"data\":null}"
    fi
    cur="$(cat "${S}/users/${sname}")"
    if [ -n "${cur}" ] && [ "${snew}" = "${cur}" ]; then
      emit 200 '{"status":"error","msg":"The new password must be different from your current password","data":null}'
    fi
    printf '%s' "${snew}" > "${S}/users/${sname}"
    emit 200 '{"status":"ok","msg":"","data":null}'
    ;;
esac
emit 200 '{"status":"ok","msg":"","data":null}'
CURLSTUB
chmod +x "${BIN}/curl"

# ─────────────────────────────────────────────────────────────────────────────
# Render the REAL role matrix + apply hook (small catalogue for speed; the
# vacuity control below re-runs with the FULL default catalogue).
# ─────────────────────────────────────────────────────────────────────────────
render_roles() { # <dir> [SYSTEMS_ROLE_USERS override]
  local dir="$1" spec="${2:-}"
  mkdir -p "${dir}"
  if [ -n "${spec}" ]; then
    SYSTEMS_ROLE_USERS="${spec}" bash "${SEED_ACCOUNTS}" --roles "${dir}" >/dev/null 2>&1
  else
    bash "${SEED_ACCOUNTS}" --roles "${dir}" >/dev/null 2>&1
  fi
}

SMALL_SPEC='e2e-user:ROLE_USER:E2E_USER_PASSWORD e2e-admin:ROLE_ADMIN,ROLE_USER:E2E_ADMIN_PASSWORD'
ROLES_SMALL="${TMP}/small"
render_roles "${ROLES_SMALL}" "${SMALL_SPEC}"
APPLY="${ROLES_SMALL}/roles/apply-systems-roles.sh"
MATRIX="${ROLES_SMALL}/roles/casdoor-systems-roles.json"
if [ ! -f "${APPLY}" ] || [ ! -f "${MATRIX}" ]; then
  echo "FATAL: tests/qemu/seed-accounts.sh --roles did not render the hook + matrix" >&2
  exit 1
fi

# A fresh stub state with every declared role PRESENT-but-empty (what a
# casdoor-init-seeded Casdoor looks like).
new_state() { # <name> -> echoes the state dir
  local d="${TMP}/state-$1"
  rm -rf "${d}"; mkdir -p "${d}/users" "${d}/roles"; : > "${d}/log"
  while IFS= read -r rn; do
    [ -n "${rn}" ] || continue
    printf '{"owner":"hugmesh","name":"%s","users":[],"isEnabled":true}' "${rn}" > "${d}/roles/${rn}"
  done < <(jq -r '.roles[].name' "${MATRIX}")
  echo "${d}"
}

# run_apply <state-dir> <admin-pass-given-to-the-script> [env assignments...]
run_apply() {
  local st="$1" givenpw="$2"; shift 2
  ( export PATH="${BIN}:${PATH}" STUB_STATE="${st}" STUB_ADMIN_PASS="s3cr3t-right"
    for kv in "$@"; do export "${kv?}"; done
    CASDOOR_URL="http://127.0.0.1:18000" CASDOOR_ADMIN_PASS="${givenpw}" \
      bash "${APPLY}" ) >"${st}/out" 2>&1
}

echo "== kind SSO harness honesty =="
echo "-- [envelope] the identity seed must not report a seed it did not perform --"

# (v1) VACUITY CONTROL: with the correct password and a cooperative Casdoor the
# hook must SUCCEED, and must actually have talked to every endpoint. Without
# this, every control below could be passing because the hook is simply broken.
st="$(new_state ok)"
if run_apply "${st}" "s3cr3t-right"; then
  miss=""
  for e in /api/login /api/get-user /api/add-user /api/get-role /api/update-role; do
    grep -q " ${e} -> " "${st}/log" || miss="${miss} ${e}"
  done
  if [ -z "${miss}" ]; then
    ok "vacuity: a correct-password run succeeds and exercises login/get-user/add-user/get-role/update-role"
  else
    bad "vacuity: run succeeded but never called:${miss} — the controls below would be vacuous"
  fi
  # and it really created the users + role memberships in the stub
  if [ -f "${st}/users/e2e-user" ] && [ -f "${st}/users/e2e-admin" ] \
     && jq -e '.users | index("hugmesh/e2e-user")' "${st}/roles/ROLE_USER" >/dev/null 2>&1; then
    ok "vacuity: the successful run really created the users and the ROLE_USER membership"
  else
    bad "vacuity: run reported success but created nothing in the stub Casdoor"
  fi
else
  bad "vacuity: a correct-password run against a cooperative Casdoor FAILED — $(tail -3 "${st}/out" | tr '\n' ' ')"
fi

# (v2) VACUITY CONTROL over the FULL default catalogue (15 users, 14 roles), so
# the small spec above cannot be hiding a per-user failure.
ROLES_FULL="${TMP}/full"; render_roles "${ROLES_FULL}"
APPLY_SMALL="${APPLY}"; MATRIX_SMALL="${MATRIX}"
APPLY="${ROLES_FULL}/roles/apply-systems-roles.sh"; MATRIX="${ROLES_FULL}/roles/casdoor-systems-roles.json"
st="$(new_state okfull)"
if run_apply "${st}" "s3cr3t-right"; then
  n="$(ls -1 "${st}/users" | wc -l)"
  d="$(jq '.users | length' "${MATRIX}")"
  if [ "${n}" -eq "${d}" ]; then
    ok "vacuity: the FULL default catalogue applies cleanly (${n}/${d} users created)"
  else
    bad "vacuity: full catalogue created ${n}/${d} users"
  fi
else
  bad "vacuity: the FULL default catalogue FAILED against a cooperative Casdoor — $(tail -3 "${st}/out" | tr '\n' ' ')"
fi
APPLY="${APPLY_SMALL}"; MATRIX="${MATRIX_SMALL}"

# (n1) THE SHIPPED DEFECT, end to end: a WRONG admin password. Casdoor denies
# with HTTP 200, no cookie is set, and every later call is anonymous-denied. The
# hook must FAIL. (`curl -sf` cannot see any of this and exits 0.)
st="$(new_state badpass)"
if run_apply "${st}" "the-vault-password-casdoor-never-got"; then
  bad "negative control: a WRONG admin password (HTTP 200 + {\"status\":\"error\"}) was reported as a SUCCESSFUL seed — this is the shipped defect"
else
  if [ -n "$(ls -A "${st}/users" 2>/dev/null)" ]; then
    bad "negative control: run failed but somehow created users"
  else
    ok "negative control: wrong admin password fails the seed (and creates nothing)"
  fi
fi

# (n2) login denied but the script is told the right password — models a policy
# denial rather than a bad password (RequireAdmin path).
st="$(new_state denylogin)"
if run_apply "${st}" "s3cr3t-right" "STUB_DENY=/api/login"; then
  bad "negative control: a denied /api/login (HTTP 200 envelope error) was treated as success"
else
  ok "negative control: an HTTP-200 denial on /api/login fails the seed"
fi

# (n3) PER-ENDPOINT deny controls, DERIVED from the endpoints the rendered hook
# really calls — so an endpoint added later is covered without editing this file.
# The one documented best-effort call is excluded, and that documentation is
# itself asserted (otherwise "best-effort" becomes a hiding place).
BEST_EFFORT="/api/login/oauth/access_token"
if grep -q 'DELIBERATELY BEST-EFFORT' "${APPLY}"; then
  ok "the only exempt endpoint (${BEST_EFFORT}) is documented as deliberately best-effort in the hook"
else
  bad "an endpoint is exempted from the deny controls but the hook does not document any call as best-effort"
fi
ENDPOINTS="$(grep -oE '/api/[A-Za-z0-9/_-]+' "${APPLY}" | sort -u)"
if [ -z "${ENDPOINTS}" ]; then
  bad "could not derive any /api/ endpoint from the rendered hook — the deny controls below are vacuous"
fi
for ep in ${ENDPOINTS}; do
  [ "${ep}" = "${BEST_EFFORT}" ] && continue
  st="$(new_state "deny$(printf '%s' "${ep}" | tr -c 'A-Za-z0-9' '-')")"
  if run_apply "${st}" "s3cr3t-right" "STUB_DENY=${ep}"; then
    bad "negative control: an HTTP-200 {\"status\":\"error\"} denial on ${ep} was reported as success"
  else
    ok "negative control: an HTTP-200 envelope denial on ${ep} fails the seed"
  fi
done

# (n4) THE "role missing — skip" LIE: Casdoor says ResponseOk(nil) for a role
# that does not exist. Skipping it means the role matrix was never applied.
st="$(new_state nullrole)"
if run_apply "${st}" "s3cr3t-right" "STUB_NULL_ROLE=1"; then
  bad "negative control: a MISSING role ({\"status\":\"ok\",\"data\":null}) was skipped and the run still reported success"
else
  ok "negative control: a missing role is a failure, not a skip"
fi

# (n5) login says ok but sets no session cookie — everything after would be
# anonymous, and anonymous is denied with HTTP 200.
st="$(new_state nocookie)"
if run_apply "${st}" "s3cr3t-right" "STUB_NO_COOKIE=1"; then
  bad "negative control: /api/login returned ok with NO session cookie and the seed still reported success"
else
  ok "negative control: status=ok with no session cookie fails the seed"
fi

# (n6) wrapActionResponse's other half: status=ok with data="Unaffected" means
# the write did nothing, and we only add users we just proved absent.
st="$(new_state unaffected)"
if run_apply "${st}" "s3cr3t-right" "STUB_ADD_UNAFFECTED=1"; then
  bad "negative control: add-user answered ok/\"Unaffected\" (no row written) and the seed reported success"
else
  ok "negative control: add-user ok/\"Unaffected\" fails the seed"
fi

# (n7) update-role reports success but does not persist the member set — a
# LIVE-VERIFIED casdoor behaviour for the sibling update-group call. Only a
# read-back can catch it.
st="$(new_state nopersist)"
if run_apply "${st}" "s3cr3t-right" "STUB_ROLE_NOPERSIST=1"; then
  bad "negative control: update-role reported ok while persisting NO membership and the seed reported success"
else
  ok "negative control: an unpersisted update-role is caught by reading the role back"
fi

# (n8) a plain transport failure must still fail (no regression the other way).
st="$(new_state http500)"
if run_apply "${st}" "s3cr3t-right" "STUB_HTTP500=/api/add-user"; then
  bad "negative control: HTTP 500 on add-user was reported as success"
else
  ok "negative control: HTTP 500 on add-user fails the seed"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "-- [post-condition] the bootstrap must verify the seed independently --"
# ─────────────────────────────────────────────────────────────────────────────
run_verify() { # <state-dir> <pass> [env...]
  local st="$1" givenpw="$2"; shift 2
  ( export PATH="${BIN}:${PATH}" STUB_STATE="${st}" STUB_ADMIN_PASS="s3cr3t-right"
    for kv in "$@"; do export "${kv?}"; done
    CASDOOR_URL="http://127.0.0.1:18000" CASDOOR_ADMIN_PASS="${givenpw}" \
      bash "${VERIFY}" "${ROLES_SMALL}/roles" ) >"${st}/vout" 2>&1
}

if [ ! -f "${VERIFY}" ]; then
  bad "no positive post-condition exists: ${VERIFY#${REPO}/} is missing, so bootstrap-kind.sh can still print 'SSO slice seeded.' over an empty Casdoor"
else
  st="$(new_state verify-ok)"
  run_apply "${st}" "s3cr3t-right" >/dev/null 2>&1
  if run_verify "${st}" "s3cr3t-right"; then
    ok "vacuity: the read-back verifier passes against a genuinely seeded Casdoor"
  else
    bad "vacuity: the read-back verifier FAILED against a genuinely seeded Casdoor — $(tail -3 "${st}/vout" | tr '\n' ' ')"
  fi

  st="$(new_state verify-empty)"                     # nothing ever seeded
  if run_verify "${st}" "s3cr3t-right"; then
    bad "negative control: the verifier passed against an EMPTY Casdoor"
  else
    ok "negative control: the verifier fails against an empty Casdoor"
  fi

  st="$(new_state verify-dropped)"                   # users seeded, one vanished
  run_apply "${st}" "s3cr3t-right" >/dev/null 2>&1
  if run_verify "${st}" "s3cr3t-right" "STUB_DROP_USER=e2e-user"; then
    bad "negative control: the verifier passed while the required user e2e-user was absent"
  else
    ok "negative control: the verifier fails when a seeded user is absent"
  fi

  st="$(new_state verify-norole)"                    # users exist, grants did not land
  run_apply "${st}" "s3cr3t-right" >/dev/null 2>&1
  while IFS= read -r rn; do
    printf '{"owner":"hugmesh","name":"%s","users":[],"isEnabled":true}' "${rn}" > "${st}/roles/${rn}"
  done < <(jq -r '.roles[].name' "${MATRIX}")
  if run_verify "${st}" "s3cr3t-right"; then
    bad "negative control: the verifier passed while NO role carried any member"
  else
    ok "negative control: the verifier fails when role membership did not land"
  fi

  st="$(new_state verify-denied)"
  run_apply "${st}" "s3cr3t-right" >/dev/null 2>&1
  if run_verify "${st}" "wrong-password"; then
    bad "negative control: the verifier 'verified' through a denied (HTTP 200) login"
  else
    ok "negative control: the verifier fails when its own login is denied"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "-- [idempotence] a second kind-up must not re-mint the cluster's secrets --"
# ─────────────────────────────────────────────────────────────────────────────
cat > "${BIN}/vault" <<'VAULTSTUB'
#!/usr/bin/env bash
set -uo pipefail
S="${VSTUB_STATE}"; mkdir -p "${S}/kv"
printf '%s\n' "$*" >> "${S}/log"
if [ "${1:-}" = "kv" ] && [ "${2:-}" = "get" ]; then
  for a in "$@"; do p="${a}"; done      # path is the last argument
  key="$(printf '%s' "${p}" | tr '/' '_')"
  if [ -f "${S}/kv/${key}" ]; then printf '{"data":{"data":%s}}\n' "$(cat "${S}/kv/${key}")"; exit 0; fi
  echo "No value found at ${p}" >&2; exit 2
fi
exit 0
VAULTSTUB
chmod +x "${BIN}/vault"

# Mirrors the real seeder's two relevant behaviours: it mints fresh values on
# EVERY invocation, and it resolves BRAND from brand.conf (which WINS over the
# environment), so the KV base path it writes can differ from the caller's env.
#
# THE PATH LIST IS DERIVED FROM seed-vault-kv.sh, NOT HARDCODED. It used to be a
# literal copy of the six sentinels, and it drifted the moment a seventh
# (cassandra-app-creds) was added on another branch: each branch was green alone,
# and the merge produced a stub that seeds six paths against a contract that
# demands seven, so the real hook's own post-seed check fired —
#     [kv-seed] FATAL: seeding reported success but these KV paths are still
#     empty: cassandra-app-creds
# — and cascaded into five failures on a `main` where nothing was actually wrong.
# That is this repo's recurring failure shape in its purest form: a FIXTURE
# SIMPLER THAN PRODUCTION. A stub that seeds fewer paths than the contract
# requires is not a weaker test, it is a broken one, and hardcoding invited it.
# Deriving the list means adding a sentinel updates the stub for free — and if
# the parse ever yields nothing, the run FAILS rather than quietly seeding zero
# paths and blaming the hook.
SENTINELS="$(sed -n 's/^SENTINEL_PATHS=(\(.*\))$/\1/p' \
  "${REPO}/specs/cluster/bootstrap/kind-local/seed-vault-kv.sh" | head -1)"
if [ -z "${SENTINELS}" ]; then
  bad "could not read SENTINEL_PATHS out of seed-vault-kv.sh — the fake seeder would seed nothing and every kv-seed assertion below would be meaningless"
  SENTINELS="__PARSE_FAILED__"
fi
export FAKE_SEED_PATHS="${SENTINELS}"
cat > "${TMP}/fake-seeder.sh" <<'SEEDER'
#!/usr/bin/env bash
set -uo pipefail
printf 'SEEDER RAN %s\n' "$*" >> "${VSTUB_STATE}/log"
mkdir -p "${VSTUB_STATE}/kv"
BRAND="${BRAND:-hugmesh}"
[ -f "${REPO_ROOT:-}/brand.conf" ] && . "${REPO_ROOT}/brand.conf"
for p in ${FAKE_SEED_PATHS}; do
  printf '{"minted":"%s"}' "$RANDOM" > "${VSTUB_STATE}/kv/secret_${BRAND}_${p}"
done
SEEDER
chmod +x "${TMP}/fake-seeder.sh"

run_kv() { # <state-dir> [env...]
  local st="$1"; shift
  ( export PATH="${BIN}:${PATH}" VSTUB_STATE="${st}" VAULT_TOKEN="stub-token" \
           SEEDER="${TMP}/fake-seeder.sh" BRAND="hugmesh"
    for kv in "$@"; do export "${kv?}"; done
    bash "${SEED_KV}" --out "${st}/bundle" ) >"${st}/out" 2>&1
}
# NB `grep -c` prints 0 AND exits 1 when there is no match, so a `|| echo 0`
# fallback would emit "0\n0" and every comparison against it would be wrong.
seeder_runs() { local n; n="$(grep -c '^SEEDER RAN' "$1/log" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }

if [ ! -f "${SEED_KV}" ]; then
  bad "the KV seed has no already-done guard: ${SEED_KV#${REPO}/} is missing, so a second run re-mints every password while the Postgres volumes keep the first run's (the 'password authentication failed for user \"userbff\"' wedge)"
else
  st="${TMP}/kv-fresh"; rm -rf "${st}"; mkdir -p "${st}/kv"; : > "${st}/log"
  if run_kv "${st}" && [ "$(seeder_runs "${st}")" = "1" ]; then
    ok "vacuity: a FIRST run against empty Vault KV seeds exactly once"
  else
    bad "vacuity: the first run did not seed once (runs=$(seeder_runs "${st}")) — $(tail -3 "${st}/out" | tr '\n' ' ')"
  fi

  # THE DEFECT: run again against the SAME (now populated) Vault.
  before="$(cat "${st}/kv/secret_hugmesh_user_bff_db" 2>/dev/null || cat "${st}/kv/secret_hugmesh_user-bff-db" 2>/dev/null || true)"
  if run_kv "${st}"; then
    if [ "$(seeder_runs "${st}")" = "1" ]; then
      after="$(cat "${st}/kv/secret_hugmesh_user_bff_db" 2>/dev/null || cat "${st}/kv/secret_hugmesh_user-bff-db" 2>/dev/null || true)"
      if [ "${before}" = "${after}" ]; then
        ok "negative control: a SECOND run skips the seed — user-bff-db's password is not re-minted"
      else
        bad "negative control: the second run reported a skip but the KV value changed"
      fi
    else
      bad "negative control: a second run re-invoked the seeder ($(seeder_runs "${st}") runs) — every password is re-minted while Postgres keeps the old one (the live 'password authentication failed for user \"userbff\"' wedge)"
    fi
  else
    bad "a second run against an already-seeded Vault FAILED outright — $(tail -3 "${st}/out" | tr '\n' ' ')"
  fi

  # PARTIAL state (interrupted first run): neither skipping nor re-minting is
  # safe, so it must refuse rather than pick one silently.
  st="${TMP}/kv-partial"; rm -rf "${st}"; mkdir -p "${st}/kv"; : > "${st}/log"
  printf '{"minted":"x"}' > "${st}/kv/secret_hugmesh_casdoor"
  if run_kv "${st}"; then
    bad "negative control: a PARTIALLY seeded Vault was silently re-seeded/skipped instead of refusing"
  else
    if [ "$(seeder_runs "${st}")" = "0" ]; then
      ok "negative control: a partially-seeded Vault refuses, and does not re-mint the populated paths"
    else
      bad "negative control: a partially-seeded Vault ran the seeder anyway"
    fi
  fi

  # The deliberate destructive override must still work (a guard with no escape
  # hatch gets deleted by the next person in a hurry).
  st="${TMP}/kv-reseed"; rm -rf "${st}"; mkdir -p "${st}/kv"; : > "${st}/log"
  run_kv "${st}" >/dev/null 2>&1
  if run_kv "${st}" "KIND_KV_RESEED=1" && [ "$(seeder_runs "${st}")" = "2" ]; then
    ok "KIND_KV_RESEED=1 still re-mints deliberately (documented escape hatch works)"
  else
    bad "KIND_KV_RESEED=1 did not force a re-seed (runs=$(seeder_runs "${st}"))"
  fi

  # brand.conf renames the KV base path and WINS over the environment in the
  # seeder. If the probe does not follow it there, it reads an empty path
  # forever and re-mints on EVERY run — the same wedge, just invisible on the
  # default brand.
  fake="${TMP}/brandroot"; rm -rf "${fake}"; mkdir -p "${fake}"
  printf 'BRAND=otherbrand\n' > "${fake}/brand.conf"
  st="${TMP}/kv-brand"; rm -rf "${st}"; mkdir -p "${st}/kv"; : > "${st}/log"
  run_kv "${st}" "REPO_ROOT=${fake}" >/dev/null 2>&1
  if run_kv "${st}" "REPO_ROOT=${fake}"; then
    if [ "$(seeder_runs "${st}")" = "1" ] && [ -f "${st}/kv/secret_otherbrand_casdoor" ]; then
      ok "the sentinel probe follows brand.conf's BRAND — a re-branded checkout still skips on re-run"
    else
      bad "with brand.conf BRAND=otherbrand the probe missed the seeded paths and re-minted (runs=$(seeder_runs "${st}"))"
    fi
  else
    bad "a re-run against a brand.conf checkout failed — $(tail -3 "${st}/out" | tr '\n' ' ')"
  fi

  # A seeder that "succeeded" without writing must not be reported as seeded.
  cat > "${TMP}/lying-seeder.sh" <<'LIAR'
#!/usr/bin/env bash
printf 'SEEDER RAN %s\n' "$*" >> "${VSTUB_STATE}/log"
exit 0
LIAR
  chmod +x "${TMP}/lying-seeder.sh"
  st="${TMP}/kv-lying"; rm -rf "${st}"; mkdir -p "${st}/kv"; : > "${st}/log"
  if run_kv "${st}" "SEEDER=${TMP}/lying-seeder.sh"; then
    bad "negative control: a seeder that wrote NOTHING was reported as a successful seed"
  else
    ok "negative control: a seeder that exits 0 without writing the KV paths fails"
  fi
fi

# The premise the guard above defends: gen-cluster-secrets.sh mints
# unconditionally and never reads what is already in Vault. If that ever changes,
# this check fires so the caller-side guard is re-examined rather than trusted.
#
# SCOPE NOTE. This used to assert `! grep -q 'vault kv get'` over the WHOLE file,
# which is broader than the premise it defends and fired on a change that did not
# threaten it. A sibling branch gave harbor-robots a read-before-write, so the
# seeder would stop clobbering a path the harbor-provision Job owns and can never
# repair. That read is deliberate, scoped to one path, and leaves the DB-password
# behaviour — the thing the caller-side skip actually guards — untouched. Each
# branch was green alone; the merge turned a correct fix into a red gate.
#
# So the check is now scoped to what it means: DB passwords must still mint
# unconditionally, and no read may target a DB path. A read of any OTHER path is
# still surfaced, because an unreviewed read creeping in is exactly what this
# check exists to notice — it just no longer conflates "read something" with
# "changed the minting contract".
if [ -f "${GEN_SECRETS}" ]; then
  _db_read="$(grep -nE 'vault kv get' "${GEN_SECRETS}" \
              | grep -E '(admin-bff-db|user-bff-db|route-access-db|mod-bff-db|forum-bff-db|wiki-bff-db|mesh-bff-db|character-forge-bff-db|federation-db)' || true)"
  _other_reads="$(grep -cE 'vault kv get' "${GEN_SECRETS}" || true)"
  if grep -qE '^USER_BFF_DB_PASSWORD="\$\(openssl rand' "${GEN_SECRETS}" \
     && grep -qE '^ADMIN_BFF_DB_PASSWORD="\$\(openssl rand' "${GEN_SECRETS}" \
     && [ -z "${_db_read}" ]; then
    ok "premise holds: gen-cluster-secrets.sh still mints DB passwords unconditionally and never reads an existing DB path — the caller-side guard is required (${_other_reads} non-DB KV read(s) present, e.g. the harbor-robots no-clobber probe)"
  else
    [ -n "${_db_read}" ] && echo "     reads a DB path: ${_db_read}"
    bad "gen-cluster-secrets.sh's minting behaviour changed — re-check whether seed-vault-kv.sh's skip is still the right contract"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "-- [mtls] the bring-up must not claim success without an ISSUED certificate --"
# ─────────────────────────────────────────────────────────────────────────────
# WHY. bootstrap-kind.sh seeds vault-ca + vault-token into the three generator
# namespaces and then prints "Done." — for a long time with nothing in between
# asserting that a certificate came out the other end. It did not: all 26
# generator-backed ExternalSecrets sat in SecretSyncedError, not one *-mtls
# Secret had ever been created, and every pod mounting one hung in Init:0/1. The
# bring-up reported that as a success.
#
# So verify_mtls_issuance() is a POST-CONDITION, and a post-condition that cannot
# fail is decoration. This section RUNS the real function out of the real script
# against a kubectl stub and REAL openssl-minted material, and requires it to go
# red on each way the property can actually break — including the one that looks
# most like success: a Secret that exists.
MTLS_FN="$(awk '/^verify_mtls_issuance\(\) \{/,/^\}/' "${BOOTSTRAP}")"
if [ -z "${MTLS_FN}" ]; then
  bad "bootstrap-kind.sh has no verify_mtls_issuance() — there is no post-condition on the thing step 8b exists to produce"
else
  ok "bootstrap-kind.sh defines verify_mtls_issuance()"

  MT="${TMP}/mtls"; mkdir -p "${MT}/bin"
  # ── kubectl stub: only what the post-condition asks of a cluster ──
  cat > "${MT}/bin/kubectl" <<'KSTUB'
#!/usr/bin/env bash
# State layout under ${STUB_STATE}:
#   es.json                       what `get externalsecrets -A -o json` returns
#   secrets/<ns>__<name>.exists   the Secret exists
#   secrets/<ns>__<name>.crt/.key its tls.crt / tls.key (raw PEM)
S="${STUB_STATE}"
ns=""; fmt=""; pos=()
args=("$@"); i=0
while [ "${i}" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  case "${a}" in
    -n|--namespace) i=$((i+1)); ns="${args[$i]}" ;;
    -o|--output)    i=$((i+1)); fmt="${args[$i]}" ;;
    -o=*|--output=*) fmt="${a#*=}" ;;
    -*)             ;;
    *)              pos+=("${a}") ;;
  esac
  i=$((i+1))
done
jp=""; case "${fmt}" in jsonpath=*) jp="${fmt#jsonpath=}" ;; esac
verb="${pos[0]:-}"; res="${pos[1]:-}"; name="${pos[2]:-}"
[ "${verb}" = "get" ] || exit 0
case "${res}" in
  externalsecrets*) cat "${S}/es.json" 2>/dev/null || echo '{"items":[]}'; exit 0 ;;
esac
f="${S}/secrets/${ns}__${name}"
[ -f "${f}.exists" ] || exit 1
case "${jp}" in
  *'tls\.crt'*) [ -s "${f}.crt" ] && base64 < "${f}.crt" | tr -d '\n'; exit 0 ;;
  *'tls\.key'*) [ -s "${f}.key" ] && base64 < "${f}.key" | tr -d '\n'; exit 0 ;;
esac
echo "secret/${name}"
KSTUB
  chmod +x "${MT}/bin/kubectl"

  # ── REAL certificate material: a cluster CA, a leaf it signed, a rogue CA and
  #    a leaf that rogue signed, plus a spare key that matches nothing. openssl
  #    does the work, so "verified" means openssl verified it. ──
  mk_ca() { # <dir> <cn>
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$2" \
      -keyout "$1/ca.key" -out "$1/ca.crt" >/dev/null 2>&1
  }
  mk_leaf() { # <ca-dir> <out-prefix> <cn>
    openssl req -newkey rsa:2048 -nodes -subj "/CN=$3" \
      -keyout "$2.key" -out "$2.csr" >/dev/null 2>&1
    openssl x509 -req -in "$2.csr" -CA "$1/ca.crt" -CAkey "$1/ca.key" \
      -CAcreateserial -days 1 -out "$2.crt" >/dev/null 2>&1
  }
  mkdir -p "${MT}/ca" "${MT}/rogue"
  mk_ca "${MT}/ca" "hugmesh kind local dev CA"
  mk_ca "${MT}/rogue" "somebody elses CA"
  mk_leaf "${MT}/ca" "${MT}/good" "hugmesh-user-bff-api.hugmesh-backend.svc.cluster.local"
  mk_leaf "${MT}/rogue" "${MT}/rogue-leaf" "hugmesh-user-bff-api.hugmesh-backend.svc.cluster.local"
  openssl genrsa -out "${MT}/other.key" 2048 >/dev/null 2>&1
  if [ ! -s "${MT}/good.crt" ] || [ ! -s "${MT}/ca/ca.crt" ]; then
    bad "could not mint test certificates with openssl — this section verified nothing"
  fi

  ES_JSON='{"items":[{"metadata":{"namespace":"hugmesh-backend","name":"hugmesh-user-bff-api-mtls"},"spec":{"target":{"name":"hugmesh-user-bff-api-mtls"},"dataFrom":[{"sourceRef":{"generatorRef":{"kind":"VaultDynamicSecret","name":"hugmesh-user-bff-api-mtls"}}}]}}]}'

  # mtls_state <name> — a fresh stub cluster that always carries vault/cluster-ca
  mtls_state() {
    local st="${MT}/state-$1"
    rm -rf "${st}"; mkdir -p "${st}/secrets"
    printf '%s' "${ES_JSON}" > "${st}/es.json"
    cp "${MT}/ca/ca.crt" "${st}/secrets/vault__cluster-ca.crt"
    : > "${st}/secrets/vault__cluster-ca.exists"
    # The repo half of the state: by default it declares exactly the generator
    # es.json carries, so repo and cluster agree and the controls below isolate
    # the certificate properties. §[mtls-denominator] makes them disagree.
    declare_gen "${st}" hugmesh-backend hugmesh-user-bff-api-mtls
    printf '%s' "${st}"
  }
  seed_secret() { # <state> <ns> <name> <crt|-> <key|->
    local st="$1" ns="$2" nm="$3" crt="$4" key="$5"
    : > "${st}/secrets/${ns}__${nm}.exists"
    [ "${crt}" = "-" ] || cp "${crt}" "${st}/secrets/${ns}__${nm}.crt"
    [ "${key}" = "-" ] || cp "${key}" "${st}/secrets/${ns}__${nm}.key"
  }
  # declare_gen <state> <ns> <name> [marker-reason] — add a generator to the
  # state's FIXTURE MANIFEST TREE, i.e. to what the REPO says must be issued.
  # This is the denominator, and it is deliberately a different input from
  # es.json (the cluster) so the two can be made to disagree.
  declare_gen() {
    local st="$1" ns="$2" nm="$3" reason="${4:-}"
    mkdir -p "${st}/spec/manifests"
    {
      echo '---'
      [ -z "${reason}" ] || echo "# mtls-issuance: not-delivered ${reason}"
      echo 'apiVersion: generators.external-secrets.io/v1alpha1'
      echo 'kind: VaultDynamicSecret'
      echo "metadata: { name: ${nm}, namespace: ${ns} }"
      echo 'spec: { path: pki_int/issue/x }'
    } >> "${st}/spec/manifests/gen.yaml"
  }
  run_mtls() { # <state-dir> [spec-dir-override]
    (
      cd "${TMP}" || exit 2
      PATH="${MT}/bin:${PATH}" STUB_STATE="$1" MTLS_VERIFY_TIMEOUT=5 \
      MTLS_SPEC_DIR="${2:-$1/spec}" \
      bash -c 'set -uo pipefail
               log() { echo "==> $*"; }
               '"${MTLS_FN}"'
               verify_mtls_issuance'
    ) >/dev/null 2>&1
  }

  st="$(mtls_state good)"
  seed_secret "${st}" hugmesh-backend hugmesh-user-bff-api-mtls "${MT}/good.crt" "${MT}/good.key"
  if run_mtls "${st}"; then
    ok "positive control: a real CA-signed leaf with its matching key verifies"
  else
    bad "positive control: a genuinely issued certificate was REJECTED — the post-condition would fail every healthy bring-up"
  fi

  st="$(mtls_state noes)"; echo '{"items":[]}' > "${st}/es.json"
  if run_mtls "${st}"; then
    bad "a cluster with NO generator-backed ExternalSecret passed — the check verified nothing and said so was fine"
  else
    ok "no generator-backed ExternalSecret at all -> RED (a vacuous check is not a pass)"
  fi

  st="$(mtls_state never)"          # ExternalSecret declared, Secret never issued
  if run_mtls "${st}"; then
    bad "THE SHIPPED OUTAGE: no *-mtls Secret was ever created and the bring-up still reported success"
  else
    ok "the shipped outage (declared ExternalSecret, no Secret ever issued) -> RED"
  fi

  st="$(mtls_state empty)"
  seed_secret "${st}" hugmesh-backend hugmesh-user-bff-api-mtls - -
  if run_mtls "${st}"; then
    bad "an EMPTY Secret passed — existence was mistaken for issuance, which is the weaker check this replaced"
  else
    ok "a Secret that exists but carries no tls.crt -> RED"
  fi

  st="$(mtls_state garbage)"
  printf 'not a certificate\n' > "${MT}/garbage.crt"
  seed_secret "${st}" hugmesh-backend hugmesh-user-bff-api-mtls "${MT}/garbage.crt" "${MT}/good.key"
  if run_mtls "${st}"; then
    bad "a Secret whose tls.crt is not X.509 at all passed"
  else
    ok "tls.crt that is not a parseable certificate -> RED"
  fi

  st="$(mtls_state rogue)"
  seed_secret "${st}" hugmesh-backend hugmesh-user-bff-api-mtls "${MT}/rogue-leaf.crt" "${MT}/rogue-leaf.key"
  if run_mtls "${st}"; then
    bad "a leaf signed by a DIFFERENT CA passed — every workload truststore would still reject it"
  else
    ok "a real certificate that does not chain to vault/cluster-ca -> RED"
  fi

  st="$(mtls_state mismatch)"
  seed_secret "${st}" hugmesh-backend hugmesh-user-bff-api-mtls "${MT}/good.crt" "${MT}/other.key"
  if run_mtls "${st}"; then
    bad "a certificate paired with someone else's private key passed — it mounts fine and fails every handshake"
  else
    ok "tls.key that does not match tls.crt -> RED"
  fi

  # ── [mtls-denominator] the expected set must come from the REPO ──────────
  # WHY. The first cut of this post-condition enumerated the generator-backed
  # ExternalSecrets the LIVE CLUSTER declared and verified those. That makes the
  # one failure mode it most needs to see invisible: when the ExternalSecret
  # itself never lands it drops out of the enumeration too, so the denominator
  # shrinks with the failure and the check can only fail at exactly zero.
  #
  # Not hypothetical. On the live kind cluster the repo declared 29
  # VaultDynamicSecret generators under specs/cluster, the cluster carried 26 —
  # hugmesh-pki/cassandra-mtls, hugmesh-backend/coturn-tls and
  # hugmesh-backend/meshbridge-client-mtls were absent ENTIRELY — and the block
  # reported "mTLS verified: 26/26", returned 0 and printed Done.
  #
  # Every control here makes the repo and the cluster DISAGREE, which the old
  # shape could not express at all: it had only one input.
  echo "-- [mtls-denominator] the expected set is read from the repo, not from the cluster --"

  st="$(mtls_state denom)"
  seed_secret "${st}" hugmesh-backend hugmesh-user-bff-api-mtls "${MT}/good.crt" "${MT}/good.key"
  declare_gen "${st}" hugmesh-backend never-delivered-mtls
  if run_mtls "${st}"; then
    bad "THE 26/26 BUG: the repo declares a generator the cluster does not carry, and the post-condition still passed — a delivery failure that removes the ExternalSecret removes itself from the denominator"
  else
    ok "a repo-declared generator with NO ExternalSecret in the cluster -> RED (even though every cert that DOES exist verifies)"
  fi

  st="$(mtls_state denom_ok)"
  seed_secret "${st}" hugmesh-backend hugmesh-user-bff-api-mtls "${MT}/good.crt" "${MT}/good.key"
  declare_gen "${st}" hugmesh-backend never-delivered-mtls \
    "ships dark behind an empty ArgoCD overlay with no automated syncPolicy, and its pki_int issuing role does not exist"
  if run_mtls "${st}"; then
    ok "the same absence, DECLARED not-delivered with a stated reason -> GREEN (optional by design is expressible)"
  else
    bad "a generator declared not-delivered with a real reason was still counted — the post-condition cannot express optional-by-design and will be switched off"
  fi

  st="$(mtls_state denom_bare)"
  seed_secret "${st}" hugmesh-backend hugmesh-user-bff-api-mtls "${MT}/good.crt" "${MT}/good.key"
  declare_gen "${st}" hugmesh-backend never-delivered-mtls "optional"
  if run_mtls "${st}"; then
    bad "a not-delivered marker with no usable reason exempted a missing generator — an exemption that states nothing is a rubber stamp"
  else
    ok "a not-delivered marker carrying no usable reason -> RED"
  fi

  # The analogue of "dead code may not be annotated away": a marker on a
  # generator the cluster DOES carry is stale, and a stale marker would silently
  # absorb the NEXT delivery regression instead of reporting it.
  st="$(mtls_state denom_stale)"
  rm -f "${st}/spec/manifests/gen.yaml"
  declare_gen "${st}" hugmesh-backend hugmesh-user-bff-api-mtls \
    "claiming the one generator this cluster demonstrably does carry is not delivered by default"
  seed_secret "${st}" hugmesh-backend hugmesh-user-bff-api-mtls "${MT}/good.crt" "${MT}/good.key"
  if run_mtls "${st}"; then
    bad "a not-delivered marker on a generator the cluster DOES carry passed — the exemption would mask the next delivery failure"
  else
    ok "a stale not-delivered marker (its generator is live) -> RED"
  fi

  st="$(mtls_state denom_nospec)"
  seed_secret "${st}" hugmesh-backend hugmesh-user-bff-api-mtls "${MT}/good.crt" "${MT}/good.key"
  if run_mtls "${st}" "${st}/no-such-manifest-tree"; then
    bad "the post-condition passed without being able to read the manifest tree — it had no denominator at all"
  else
    ok "an unreadable manifest tree -> RED (an unverifiable post-condition is not a pass)"
  fi

  st="$(mtls_state denom_empty)"
  seed_secret "${st}" hugmesh-backend hugmesh-user-bff-api-mtls "${MT}/good.crt" "${MT}/good.key"
  mkdir -p "${st}/emptyspec"
  if run_mtls "${st}" "${st}/emptyspec"; then
    bad "a manifest tree declaring ZERO generators passed — the expected set was empty so everything passed vacuously"
  else
    ok "a manifest tree declaring zero generators -> RED (vacuity)"
  fi

  # And the real tree must satisfy its own post-condition's REPO half: every
  # generator specs/cluster declares is either expected or carries a reasoned
  # marker. This is what keeps the three real exemptions honest.
  REAL_GENS="$(find "${REPO}/specs/cluster" -type f \( -name '*.yaml' -o -name '*.yml' \) \
                 -exec grep -l '^kind:[[:space:]]*VaultDynamicSecret' {} + 2>/dev/null \
               | xargs -r grep -c '^kind:[[:space:]]*VaultDynamicSecret' 2>/dev/null \
               | awk -F: '{n+=$2} END{print n+0}')"
  if [ "${REAL_GENS}" -ge 20 ]; then
    ok "specs/cluster declares ${REAL_GENS} VaultDynamicSecret generators for the post-condition to key on"
  else
    bad "only ${REAL_GENS} generators found under specs/cluster — the denominator scan is broken or the manifests moved"
  fi

  # The post-condition must be REACHED, and its failure must stop the run.
  if grep -q '^verify_mtls_issuance ||' "${BOOTSTRAP}"; then
    ok "bootstrap-kind.sh runs verify_mtls_issuance and aborts on failure"
  else
    bad "verify_mtls_issuance is defined but not invoked fail-closed — a post-condition nothing runs is not a post-condition"
  fi
  if awk '/^verify_mtls_issuance \|\|/{v=NR} /^log "Done\./{d=NR} END{exit !(v && d && v<d)}' "${BOOTSTRAP}"; then
    ok "the mTLS post-condition runs BEFORE the bring-up prints 'Done.'"
  else
    bad "'Done.' can be printed without the mTLS post-condition having passed"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "-- [gen-creds] step 8b must recover, not abort, on an already-initialized Vault --"
# ─────────────────────────────────────────────────────────────────────────────
# WHY. external-secrets/vault-token is created in exactly ONE place: the
# not-initialized `else` branch of the Vault step. A re-run against an
# already-initialized Vault therefore does not create it. A first cut of the
# generator-credential block read that Secret and `exit 1`-ed when it was empty,
# which aborted the ENTIRE bring-up — vault-pki-init, casdoor-init and the whole
# SSO slice, all of which come after — over a token the script can reconstruct:
# vault/vault-bootstrap holds the same root token and is read 60 lines later.
# Verified byte-identical on a live kind cluster. This runs the real block.
GEN_BLOCK="$(awk '/^log "Seeding per-namespace generator credentials/,/^unset GEN_TOKEN/' "${BOOTSTRAP}")"
if [ -z "${GEN_BLOCK}" ]; then
  bad "could not find the generator-credential block in bootstrap-kind.sh (anchors moved) — this section verified nothing"
else
  GT="${TMP}/gencreds"; mkdir -p "${GT}/bin"
  cat > "${GT}/bin/kubectl" <<'GSTUB'
#!/usr/bin/env bash
# Models a cluster by env: STUB_ES_TOKEN / STUB_BOOTSTRAP_TOKEN empty => absent.
# Everything applied is appended to ${STUB_LOG} so the test can read back what
# the block actually created.
args="$*"
case "${args}" in
  *"-n vault get secret cluster-ca"*)
      printf '%s' "${STUB_CA_B64}"; exit 0 ;;
  *"-n external-secrets get secret vault-token"*)
      [ -n "${STUB_ES_TOKEN}" ] || exit 1; printf '%s' "${STUB_ES_TOKEN}"; exit 0 ;;
  *"-n vault get secret vault-bootstrap"*)
      [ -n "${STUB_BOOTSTRAP_TOKEN}" ] || exit 1; printf '%s' "${STUB_BOOTSTRAP_TOKEN}"; exit 0 ;;
  *"create namespace"*)
      exit 0 ;;
  *apply*)
      cat >> "${STUB_LOG}"; printf '\n---APPLIED---\n' >> "${STUB_LOG}"; exit 0 ;;
esac
cat >/dev/null 2>&1
exit 0
GSTUB
  chmod +x "${GT}/bin/kubectl"

  run_gen() { # <es-token-b64> <bootstrap-token-b64> -> log on stdout
    local log="${GT}/log"; : > "${log}"
    PATH="${GT}/bin:${PATH}" STUB_LOG="${log}" \
    STUB_CA_B64="Q0FDRVJU" STUB_ES_TOKEN="$1" STUB_BOOTSTRAP_TOKEN="$2" \
      bash -c 'set -euo pipefail
               log() { echo "==> $*"; }
               '"${GEN_BLOCK}" >/dev/null 2>&1
    local rc=$?
    printf '%s' "${rc}"
  }

  rc="$(run_gen "" "cm9vdA==")"
  applied="$(cat "${GT}/log" 2>/dev/null || true)"
  if [ "${rc}" != "0" ]; then
    bad "REGRESSION: an already-initialized Vault (no external-secrets/vault-token, vault/vault-bootstrap present) aborts the bring-up with exit ${rc} instead of falling back"
  elif ! printf '%s' "${applied}" | grep 'namespace: external-secrets' >/dev/null; then
    bad "the fallback ran but never restored external-secrets/vault-token — the ClusterSecretStore stays unauthenticated"
  else
    n="$(printf '%s' "${applied}" | grep -c 'name: vault-ca' || true)"
    if [ "${n}" -ge 3 ]; then
      ok "already-initialized Vault: recovers the token from vault/vault-bootstrap, restores external-secrets/vault-token and seeds all three generator namespaces"
    else
      bad "the fallback ran but seeded vault-ca into only ${n} namespace(s), expected 3"
    fi
  fi

  rc="$(run_gen "cm9vdA==" "cm9vdA==")"
  if [ "${rc}" = "0" ]; then
    ok "fresh Vault (external-secrets/vault-token present): unchanged, still seeds the generator credentials"
  else
    bad "the normal path now fails (exit ${rc}) — the fallback broke the case that already worked"
  fi

  rc="$(run_gen "" "")"
  if [ "${rc}" = "0" ]; then
    bad "no token ANYWHERE and the block still reported success — it would seed an empty vault-token and every generator would fail to authenticate"
  else
    ok "no Vault token in either Secret -> hard fail (there is genuinely nothing to seed from)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "-- [repo-access] ArgoCD must be given a repo it can fetch, or the run must say so --"
# ─────────────────────────────────────────────────────────────────────────────
# WHY. Issue #48: the bootstrap was run without ARGOCD_REPO_TOKEN, step 5b only
# WARNED, all 11+ git-path Applications sat in 'ComparisonError: authentication
# required', vault-0 was never created — and the run still exited 0, so make and
# the Studio reported success over a dead cluster. The fix is two-sided:
#   (a) the DEFAULT is a tokenless local sync — the kind node mounts this
#       checkout read-only and an in-cluster read-only git daemon
#       (gitops-repo-server.yaml) serves it, so a LOCAL mesh needs no GitHub
#       credential at all (ARGOCD_REPO_TOKEN stays as the GitHub override);
#   (b) under KIND_PROFILE=sso, a run with NEITHER path exits non-zero naming
#       exactly what is missing.
# This runs the REAL ensure_repo_access() out of the real script against
# kubectl/docker stubs, with the REAL gitops-repo-server.yaml on disk.
RA_FN="$(awk '/^ensure_repo_access\(\) \{/,/^\}/' "${BOOTSTRAP}")"
PROVEN_FN="$(awk '/^argocd_repo_fetch_proven\(\) \{/,/^\}/' "${BOOTSTRAP}")"
if [ -z "${PROVEN_FN}" ]; then
  bad "bootstrap-kind.sh has no argocd_repo_fetch_proven() — a re-run cannot see the credential the cluster already holds, and KIND_PROFILE=sso FATALs on a working cluster"
fi
if [ -z "${RA_FN}" ]; then
  bad "bootstrap-kind.sh has no ensure_repo_access() — the #48 fail-closed/local-sync logic is missing or moved"
else
  RA="${TMP}/repoaccess"; mkdir -p "${RA}/bin"
  cat > "${RA}/bin/kubectl" <<'RSTUB'
#!/usr/bin/env bash
args="$*"
case "${args}" in
  *"get applications"*)
    # What ArgoCD reports about its Applications — the EVIDENCE the fetch-proof
    # reads. Both columns are modelled so a test can say "synced at a commit"
    # and "carrying #48's auth error" independently: on a real cluster they are
    # independent, and collapsing them is how a dead credential would read as a
    # live one.
    case "${args}" in
      *"custom-columns=REPO:"*) printf '%s\n' "${STUB_APPS:-}" ;;
      *"custom-columns=MSG:"*)  printf '%s\n' "${STUB_APP_CONDS:-}" ;;
    esac
    exit "${STUB_APPS_RC:-0}" ;;
  *"create secret generic hugmesh-generator-repo"*)
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: hugmesh-generator-repo\n'; exit 0 ;;
  *"label --local"*)
    cat; printf '  labels: {argocd.argoproj.io/secret-type: repository}\n'; exit 0 ;;
  *"rollout status"*)
    exit "${STUB_ROLLOUT_RC:-0}" ;;
  *"apply -f -"*)
    cat >> "${STUB_LOG}"; printf '\n---APPLIED---\n' >> "${STUB_LOG}"; exit 0 ;;
esac
cat >/dev/null 2>&1
exit 0
RSTUB
  cat > "${RA}/bin/docker" <<'DSTUB'
#!/usr/bin/env bash
case "$*" in
  "exec "*" test -d "*) exit "${STUB_MOUNT_RC:-0}" ;;
esac
exit 0
DSTUB
  chmod +x "${RA}/bin/kubectl" "${RA}/bin/docker"

  # A fake operator checkout: full clone (real .git DIRECTORY) vs linked
  # worktree (.git FILE) are both modeled.
  CLONE_ROOT="${RA}/clone"; mkdir -p "${CLONE_ROOT}/.git"
  WT_ROOT="${RA}/worktree"; mkdir -p "${WT_ROOT}"
  printf 'gitdir: /somewhere/else/.git/worktrees/x\n' > "${WT_ROOT}/.git"

  run_repo_access() { # <repo-root> <profile> [env...] — writes rc + RESULT line
    local root="$1" profile="$2"; shift 2
    : > "${RA}/log"
    ( export PATH="${RA}/bin:${PATH}" STUB_LOG="${RA}/log"
      for kv in "$@"; do export "${kv?}"; done
      T_REPO_ROOT="${root}" T_PROFILE="${profile}" T_SCRIPT_DIR="${KIND_DIR}" \
      bash -c 'set -euo pipefail
        log() { echo "==> $*"; }
        warn() { echo "    WARN: $*" >&2; }
        GITOPS_REPO_DEFAULT="https://github.com/hugmesh/hugmesh-generator.git"
        REPO="${T_REPO:-${GITOPS_REPO_DEFAULT}}"
        REV="${T_REV:-main}"; REV_EXPLICIT="${T_REV:+1}"
        VAULT_BRANCH=main; HARBOR_BRANCH=main
        CLUSTER_NAME=hugmesh-local; ARGOCD_NS=devops
        KIND_PROFILE="${T_PROFILE}"
        REPO_ROOT="${T_REPO_ROOT}"
        SCRIPT_DIR="${T_SCRIPT_DIR}"
        LOCAL_GITOPS_MOUNT=/hugmesh/hugmesh-generator
        LOCAL_GITOPS_URL="git://gitops-repo-server.devops.svc.cluster.local/hugmesh-generator"
        ARGOCD_PROVEN_REV=""
        '"${PROVEN_FN}"'
        '"${RA_FN}"'
        ensure_repo_access
        echo "RESULT REPO=${REPO} REV=${REV} VB=${VAULT_BRANCH} HB=${HARBOR_BRANCH}"'
    ) > "${RA}/out" 2> "${RA}/err"
  }

  # (p1) POSITIVE / the default path: no token, full clone, mount present ->
  # the REAL gitops-repo-server.yaml is applied and every later Application
  # will be rewritten at the in-cluster daemon, targetRevision HEAD.
  if run_repo_access "${CLONE_ROOT}" sso; then
    if grep -q 'RESULT REPO=git://gitops-repo-server.devops.svc.cluster.local/hugmesh-generator REV=HEAD VB=HEAD HB=HEAD' "${RA}/out" \
       && grep -q 'name: gitops-repo-server' "${RA}/log" \
       && grep -q 'kind: Deployment' "${RA}/log"; then
      ok "tokenless local sync is the DEFAULT: no token deploys the read-only git daemon and repoints repoURL/targetRevision at this checkout's HEAD"
    else
      bad "the tokenless path ran but did not deploy the daemon + repoint REPO/REV — $(tail -2 "${RA}/out" | tr '\n' ' ')"
    fi
    # Fetch-only, by construction: no ARG line may enable receive-pack (the
    # manifest's comments are allowed to mention it), and the repo volume must
    # be mounted read-only.
    if grep -Eq '^ *- +--enable=receive-pack' "${RA}/log"; then
      bad "the applied daemon manifest ENABLES receive-pack — the cluster could write into the operator's checkout"
    elif ! grep -q 'readOnly: true' "${RA}/log"; then
      bad "the applied daemon manifest does not mount the repo read-only"
    else
      ok "the applied daemon manifest is fetch-only (no receive-pack arg) and mounts the checkout read-only"
    fi
  else
    bad "the default tokenless path FAILED on a healthy clone+mount — $(tail -3 "${RA}/err" | tr '\n' ' ')"
  fi

  # (p2) the ARGOCD_REPO_TOKEN override still works and never deploys the daemon.
  if run_repo_access "${CLONE_ROOT}" sso "ARGOCD_REPO_TOKEN=tok-abc"; then
    if grep -q 'RESULT REPO=https://github.com/hugmesh/hugmesh-generator.git REV=main' "${RA}/out" \
       && grep -q 'hugmesh-generator-repo' "${RA}/log" \
       && ! grep -q 'gitops-repo-server' "${RA}/log"; then
      ok "ARGOCD_REPO_TOKEN override: registers the repository Secret, keeps the GitHub repoURL, deploys no daemon"
    else
      bad "the token override misbehaved — $(tail -2 "${RA}/out" | tr '\n' ' ')"
    fi
  else
    bad "the token override FAILED outright — $(tail -3 "${RA}/err" | tr '\n' ' ')"
  fi

  # (n1) THE #48 SHAPE, fail-closed: sso + no token + a pre-local-sync cluster
  # (node mount missing) must EXIT NON-ZERO and name both remedies.
  if run_repo_access "${CLONE_ROOT}" sso "STUB_MOUNT_RC=1"; then
    bad "THE #48 SHAPE: KIND_PROFILE=sso with no repo access still exited 0 — make/Studio would again report success over a cluster that can never converge"
  else
    if grep -q 'kind delete cluster' "${RA}/err" && grep -q 'ARGOCD_REPO_TOKEN' "${RA}/err"; then
      ok "sso + no token + missing node mount -> non-zero exit naming BOTH remedies (recreate cluster / export ARGOCD_REPO_TOKEN)"
    else
      bad "sso fail-closed fired but did not name the remedies — $(tail -3 "${RA}/err" | tr '\n' ' ')"
    fi
  fi

  # (n2) a linked worktree cannot be served (its .git is a file pointing at an
  # object store outside the mount) — same fail-closed under sso.
  if run_repo_access "${WT_ROOT}" sso; then
    bad "a linked-worktree checkout (unservable .git file) was accepted for the local sync path"
  else
    grep -qi 'worktree' "${RA}/err" \
      && ok "a linked-worktree checkout -> non-zero exit that says WHY (unservable .git file)" \
      || bad "worktree fail-closed fired without naming the cause — $(tail -2 "${RA}/err" | tr '\n' ' ')"
  fi

  # (n3) core keeps the old warn-and-continue for the no-access case (README
  # documents supplying the token later; ArgoCD retries on its own).
  if run_repo_access "${CLONE_ROOT}" core "STUB_MOUNT_RC=1"; then
    grep -q 'WARN' "${RA}/err" \
      && ok "KIND_PROFILE=core + no repo access still warns-and-continues (documented late-token flow)" \
      || bad "core continued but printed no warning at all"
  else
    bad "KIND_PROFILE=core now hard-fails on missing repo access — the documented supply-the-token-later flow is broken"
  fi

  # (n4) an EXPLICIT non-default HUGMESH_GITOPS_REPO is respected verbatim
  # (an anonymously readable fork needs neither token nor daemon).
  if run_repo_access "${CLONE_ROOT}" sso "T_REPO=https://example.com/fork.git"; then
    if grep -q 'RESULT REPO=https://example.com/fork.git' "${RA}/out" \
       && ! grep -q 'gitops-repo-server' "${RA}/log"; then
      ok "an explicit HUGMESH_GITOPS_REPO override is left alone (no daemon, no token demand)"
    else
      bad "an explicit repo override was second-guessed — $(tail -2 "${RA}/out" | tr '\n' ' ')"
    fi
  else
    bad "an explicit repo override FAILED — $(tail -3 "${RA}/err" | tr '\n' ' ')"
  fi

  # (n5) an explicitly pinned HUGMESH_GITOPS_REV survives the local path
  # (only the DEFAULT retargets to HEAD).
  if run_repo_access "${CLONE_ROOT}" sso "T_REV=fix/my-branch"; then
    grep -q 'REV=fix/my-branch' "${RA}/out" \
      && ok "a pinned HUGMESH_GITOPS_REV wins over the local path's HEAD default" \
      || bad "the local path clobbered an explicitly pinned revision — $(tail -2 "${RA}/out" | tr '\n' ' ')"
  else
    bad "a pinned-revision local run FAILED — $(tail -3 "${RA}/err" | tr '\n' ' ')"
  fi

  # (c1..c5) THE CREDENTIAL THE CLUSTER ALREADY HOLDS (live 2026-08-22).
  # ensure_repo_access only ever asked "$ARGOCD_REPO_TOKEN in *this*
  # environment?" then "is the mount serving?". A cluster bootstrapped once WITH
  # a token keeps a working repository Secret and goes on fetching; re-run from
  # a shell that no longer exports the token and this FATALLED under sso —
  # naming a mount nothing in that cluster reads, while every git-path
  # Application was synced to main's HEAD. The proof must be EVIDENCE, because a
  # stored token expires and "a credential exists" over a dead one is #48 again.
  SHA=6964d0892d8ae4ac4113fded3c0b0c68483f3754
  GH_REPO=https://github.com/hugmesh/hugmesh-generator.git

  # (c1) the live shape: stale mount, no token, ArgoCD synced at a real commit.
  if run_repo_access "${CLONE_ROOT}" sso "STUB_MOUNT_RC=1" "STUB_APPS=${GH_REPO} ${SHA}"; then
    if grep -q "RESULT REPO=${GH_REPO} REV=main" "${RA}/out" \
       && ! grep -q 'gitops-repo-server' "${RA}/log"; then
      ok "a cluster already fetching the repo is left alone: no daemon, no token demanded, repoURL untouched"
    else
      bad "the already-credentialed path ran but changed the repo wiring — $(tail -2 "${RA}/out" | tr '\n' ' ')"
    fi
    grep -q "${SHA}" "${RA}/out" \
      && ok "it names the commit it proved the fetch with, not just 'ok'" \
      || bad "the run accepted the existing credential without naming the evidence — an unfalsifiable claim"
  else
    bad "THE LIVE SHAPE: sso + a cluster demonstrably fetching the repo still FATALLED — $(tail -3 "${RA}/err" | tr '\n' ' ')"
  fi

  # (c2) THE REGRESSION THIS MUST NOT BECOME. A revision recorded from a fetch
  # that worked last week, plus #48's authentication error live on an
  # Application, is a DEAD credential. Accepting it is the outage.
  if run_repo_access "${CLONE_ROOT}" sso "STUB_MOUNT_RC=1" "STUB_APPS=${GH_REPO} ${SHA}" \
       "STUB_APP_CONDS=ComparisonError: authentication required"; then
    bad "an EXPIRED credential (apps reporting 'authentication required') was accepted as proof — this is issue #48 restored"
  else
    ok "an Application reporting 'authentication required' is not proof: the run still fails closed"
  fi

  # (c3) only a RESOLVED commit is evidence. `.status.sync.revision` echoing the
  # branch the spec asked for proves the repo-server never came back.
  #
  # Every value here is deliberately LONGER than the minimum commit length, so
  # this bites on the hex test and not on the length test. Caught by mutation:
  # the first version of this case used only short names ("main", "<none>"),
  # so deleting the hex check entirely left the suite GREEN — the length check
  # was quietly doing all the work and one of the two conditions was untested.
  c3_bad=0
  for badrev in main '<none>' refs/heads/main release/2026-08-22 not-a-sha-at-all; do
    if run_repo_access "${CLONE_ROOT}" sso "STUB_MOUNT_RC=1" "STUB_APPS=${GH_REPO} ${badrev}"; then
      bad "an unresolved revision ('${badrev}') was accepted as a fetched commit"
      c3_bad=1
    fi
  done
  [ "${c3_bad}" -eq 0 ] && ok "an unresolved revision is not a fetch — 5 shapes, all longer than the length floor, so the HEX test is what rejects them"

  # (c4) another repo's Application says nothing about THIS repo's access — the
  # cluster legitimately holds Helm-sourced and forked apps.
  if run_repo_access "${CLONE_ROOT}" sso "STUB_MOUNT_RC=1" \
       "STUB_APPS=https://helm.goharbor.io ${SHA}"; then
    bad "a DIFFERENT repo's synced Application was accepted as proof of access to ${GH_REPO}"
  else
    ok "only an Application on this repo counts — a foreign source is not proof"
  fi

  # (c5) the check may only ever RELAX a re-run. A fresh cluster has no
  # Applications, so a FIRST bootstrap must still take the tokenless local sync.
  if run_repo_access "${CLONE_ROOT}" sso "STUB_APPS="; then
    grep -q 'RESULT REPO=git://gitops-repo-server' "${RA}/out" \
      && ok "no Applications = no evidence: a first bootstrap still takes the tokenless local sync" \
      || bad "a cluster proving nothing skipped the local sync — $(tail -2 "${RA}/out" | tr '\n' ' ')"
  else
    bad "the fetch-proof broke the default first-bootstrap path — $(tail -3 "${RA}/err" | tr '\n' ' ')"
  fi

  # (n6) the daemon never becoming ready is a FAILURE, not a shrug — ArgoCD
  # would have nothing to fetch and every app would sit in ComparisonError.
  if run_repo_access "${CLONE_ROOT}" sso "STUB_ROLLOUT_RC=1"; then
    bad "gitops-repo-server never became ready and the bootstrap continued anyway"
  else
    ok "an unready gitops-repo-server fails the bring-up instead of proceeding credential-less"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "-- [vault-wait] a vault-0 that never runs must fail the run, not exit 0 --"
# ─────────────────────────────────────────────────────────────────────────────
# WHY. The old wait loop warned and exited 0 when vault-0 never reached Running
# — the exact exit behind issue #48's 'make kind-up reported success on a broken
# cluster'. The script itself declares the Vault bootstrap mandatory (it refuses
# SKIP_VAULT_BOOTSTRAP=1 under sso), so a missing vault-0 is a failed bring-up.
VW_FN="$(awk '/^wait_for_vault_pod\(\) \{/,/^\}/' "${BOOTSTRAP}")"
if [ -z "${VW_FN}" ]; then
  bad "bootstrap-kind.sh has no wait_for_vault_pod() — the vault-0 wait is not extractable/testable and may still be the warn+exit-0 shape"
else
  VW="${TMP}/vaultwait"; mkdir -p "${VW}/bin"
  cat > "${VW}/bin/kubectl" <<'VWSTUB'
#!/usr/bin/env bash
case "$*" in
  *"get pod vault-0"*)          printf '%s' "${STUB_VAULT_PHASE:-}"; exit 0 ;;
  *"get application vault"*)    printf '%s' "${STUB_APP_COND:-}"; exit 0 ;;
esac
exit 0
VWSTUB
  chmod +x "${VW}/bin/kubectl"
  run_vault_wait() { # [env...]
    ( export PATH="${VW}/bin:${PATH}" VAULT_POD_WAIT_TRIES=2 VAULT_POD_WAIT_SLEEP=0
      for kv in "$@"; do export "${kv?}"; done
      bash -c 'set -uo pipefail
        log() { echo "==> $*"; }
        ARGOCD_NS=devops
        '"${VW_FN}"'
        wait_for_vault_pod'
    ) > "${VW}/out" 2> "${VW}/err"
  }

  if run_vault_wait "STUB_VAULT_PHASE=Running"; then
    ok "vacuity: a Running vault-0 passes the wait"
  else
    bad "a Running vault-0 FAILED the wait — every healthy bring-up would abort"
  fi

  if run_vault_wait "STUB_VAULT_PHASE=" "STUB_APP_COND=rpc error: authentication required: Repository not found"; then
    bad "THE #48 EXIT: vault-0 never created and the wait still returned success"
  else
    if grep -q 'issue #48' "${VW}/err" && grep -q 'authentication required' "${VW}/err"; then
      ok "vault-0 never created -> non-zero, and the missing-repo-access signature is named (issue #48)"
    else
      bad "the wait failed but did not surface the ArgoCD condition/remedy — $(tail -3 "${VW}/err" | tr '\n' ' ')"
    fi
  fi

  if run_vault_wait "STUB_VAULT_PHASE=Pending"; then
    bad "a vault-0 stuck Pending was reported as a successful wait"
  else
    ok "a vault-0 stuck Pending -> non-zero (storage/scheduling failures no longer masquerade as success)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "-- [wiring] the fixes must be on the path the harness actually runs --"
# ─────────────────────────────────────────────────────────────────────────────
if grep -q '^ensure_repo_access$' "${BOOTSTRAP}"; then
  ok "bootstrap-kind.sh invokes ensure_repo_access (repo access is decided, not assumed)"
else
  bad "ensure_repo_access is defined but never invoked — every Application would again sync from nothing"
fi

# ── one bring-up at a time ──────────────────────────────────────────────────
# This script is neither atomic nor commutative: it applies Applications, seeds
# Vault KV, seeds the identity catalogue, then READS EACH BACK to verify. Two
# runs interleaved means one's read-back can observe the other's half-written
# state, and the failure then names the thing that is CORRECT. Nothing prevented
# it — the Studio guards its own page, which is exactly why the gap was
# invisible from there, while a terminal `make kind-up` is a second door.
#
# Behavioural: HOLD the lock and run the REAL script against tool stubs, so this
# tests the refusal rather than the presence of the word "flock".
if ! command -v flock >/dev/null 2>&1; then
  ok "SKIP lock test: flock absent (the script warns and continues by design)"
else
  LK="${TMP}/lock"; mkdir -p "${LK}/bin"
  for t in kind kubectl docker git jq openssl base64; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${LK}/bin/${t}"; chmod +x "${LK}/bin/${t}"
  done
  # the script derives it as ${TMPDIR}/hugmesh-kind-${CLUSTER_NAME}.lock — hold
  # EXACTLY that path, or the "held" case silently tests an uncontended run.
  LKFILE="${TMP}/hugmesh-kind-lockprobe.lock"
  # hold it in a background subshell, then run the bootstrap with the same name
  ( flock -x 9; sleep 30 ) 9>>"${LKFILE}" &
  LK_HOLDER=$!
  sleep 1
  ( export PATH="${LK}/bin:${PATH}" TMPDIR="${TMP}" KIND_CLUSTER_NAME="lockprobe"
      timeout 60 bash "${BOOTSTRAP}" ) > "${TMP}/lock.out" 2>&1
  LK_RC=$?
  kill "${LK_HOLDER}" 2>/dev/null; wait "${LK_HOLDER}" 2>/dev/null

  if [ "${LK_RC}" -eq 0 ]; then
    bad "a bring-up ran while another held the lock — two runs can interleave the app applies, the KV seed and the identity seed against one cluster"
  elif grep -q 'already running' "${TMP}/lock.out"; then
    ok "a concurrent bring-up is REFUSED (non-zero) instead of interleaving"
    grep -q 'fuser' "${TMP}/lock.out" \
      && ok "the refusal says how to find the holder, not just that it is held" \
      || bad "the refusal does not tell the operator how to identify the other run"
  else
    bad "the run failed but not on the lock — $(head -3 "${TMP}/lock.out" | tr '\n' ' ')"
  fi

  # VACUITY: with the lock FREE the refusal must not fire, or the check above
  # would pass on a script that always refuses.
  ( export PATH="${LK}/bin:${PATH}" TMPDIR="${TMP}" KIND_CLUSTER_NAME="lockprobe2"
    timeout 20 bash "${BOOTSTRAP}" ) > "${TMP}/lock2.out" 2>&1 || true
  grep -q 'already running' "${TMP}/lock2.out" \
    && bad "the bootstrap refuses even with NO other run holding the lock — the guard is inverted" \
    || ok "an uncontended run is not refused (the lock check is not always-on)"

  # STRUCTURAL: the lock must be taken before anything mutates the cluster, or it
  # protects nothing that matters.
  LOCK_LINE="$(grep -n 'KIND_LOCK=' "${BOOTSTRAP}" | head -1 | cut -d: -f1)"
  MUT_LINE="$(grep -n 'kind create cluster' "${BOOTSTRAP}" | head -1 | cut -d: -f1)"
  if [ -n "${LOCK_LINE}" ] && [ -n "${MUT_LINE}" ] && [ "${LOCK_LINE}" -lt "${MUT_LINE}" ]; then
    ok "the lock is taken BEFORE the first cluster mutation (line ${LOCK_LINE} < ${MUT_LINE})"
  else
    # NO BACKTICKS: inside double quotes they are command substitution, and an
    # earlier draft of this line literally RAN `kind create cluster` every time
    # the assertion failed. A guard whose failure path mutates the machine it is
    # checking is worse than no guard.
    bad "the lock is not taken before 'kind create cluster' (lock=${LOCK_LINE} mutate=${MUT_LINE}) — it would guard only the tail of the run"
  fi
fi

# ── the curated slice must install what its own Applications REQUIRE ─────────
# 14-workload-console-rbac carries the deploy-provenance ClusterPolicy. Without
# kyverno.io/v1 registered ArgoCD cannot render it at all — "failed to discover
# server resources for group version kyverno.io/v1" — so on every kind cluster
# ever built that Application sat OutOfSync/Missing and the digest-pinning
# admission backstop was simply absent. apps/15-kyverno.yaml was in the repo the
# whole time (sync-wave -1, for exactly this ordering); it was only ever missing
# from the curated list. Asserted by ORDER, not mere presence: applying the
# policy first is the bug.
KY_LINE="$(grep -n '^  15-kyverno.yaml' "${BOOTSTRAP}" | head -1 | cut -d: -f1)"
WC_LINE="$(grep -n '^  14-workload-console-rbac.yaml' "${BOOTSTRAP}" | head -1 | cut -d: -f1)"
if [ -z "${KY_LINE}" ]; then
  bad "bootstrap-kind.sh's curated list omits apps/15-kyverno.yaml — 14-workload-console-rbac cannot render its ClusterPolicy and the deploy-provenance backstop is ABSENT, not merely unsynced"
elif [ -z "${WC_LINE}" ]; then
  bad "could not find 14-workload-console-rbac.yaml in the curated list (anchor moved) — the kyverno ordering check verified nothing"
elif [ "${KY_LINE}" -ge "${WC_LINE}" ]; then
  bad "apps/15-kyverno.yaml is listed AFTER 14-workload-console-rbac.yaml (lines ${KY_LINE} vs ${WC_LINE}) — the CRDs must be registered before the policy that needs them"
else
  ok "the curated list installs kyverno BEFORE the Application whose ClusterPolicy needs kyverno.io/v1"
fi

# and it must actually WAIT for the CRD: Applications sync asynchronously, so
# list order alone buys nothing.
#
# Both of the checks below read a COMMENT-STRIPPED copy. That is not fussiness:
# the first version of each grepped the whole file, and the prose above happens
# to name both `clusterpolicies.kyverno.io` and every namespace — so deleting
# the real code left them GREEN. Mutation testing caught it. This repo has now
# hit that exact inversion three times (guard-integrity checks 3 and 7 before
# this), which is why it is written down here rather than just fixed.
BOOT_CODE="${TMP}/bootstrap.code"
sed 's/[[:space:]]*#.*$//' "${BOOTSTRAP}" > "${BOOT_CODE}"

if grep -q 'kubectl get crd clusterpolicies.kyverno.io' "${BOOT_CODE}"; then
  ok "bootstrap-kind.sh waits for kyverno.io/v1 to register (order alone does not sequence async syncs)"
else
  bad "bootstrap-kind.sh never probes for clusterpolicies.kyverno.io in executable code — listing kyverno first does not sequence two asynchronous ArgoCD syncs"
fi

# The namespaces the curated Applications target must be ensured. Missing ones
# made external-secrets-config and workload-console-rbac fail to sync with an
# error that names Kubernetes ("namespaces ... not found") rather than the
# cause. Derived from the manifests, never a hardcoded list: a new
# ExternalSecret target that nothing creates must fail this. Matched against the
# ensure LOOP only — the whole file mentions every one of these in prose.
# Every namespace the bootstrap creates, from EVERY create site — there are
# three (the cluster-CA loop, the generator-namespace loop, and the curated-app
# loop), and an earlier version of this check only read one of them, so it
# reported namespaces as missing that a different loop already made. Tokens are
# normalised: the last entry of a `for ns in ... ; do` list carries a trailing
# `;`, which a naive word match silently fails on.
NS_LOOP="$(awk '
  # Buffer each `for ns in ... done` block and emit its namespace list ONLY if
  # the body actually creates them. Reading the loop HEADER alone was not
  # enough: gutting the body while leaving the list in place kept this green
  # (found by mutation). A namespace named by a loop that creates nothing is
  # exactly the vacuity this suite exists to reject.
  /^[[:space:]]*for ns in / { buf = $0; inblk = 1; made = 0; next }
  inblk {
    buf = buf " " $0
    if ($0 ~ /kubectl create namespace/) made = 1
    if ($0 ~ /^[[:space:]]*done[[:space:]]*$/) {
      if (made) print buf
      inblk = 0
    }
    next
  }
  /kubectl create namespace [a-z]/ { print }
' "${BOOT_CODE}" | tr '\\\;' '  ' | tr -s '[:space:]' ' ')"
NS_MISSING=""
NS_SEEN=0
for ns in $(python3 - "${REPO}" <<'PYEOF'
import sys, os, glob, io
try: import yaml
except ImportError: sys.exit(0)
root = sys.argv[1]
want = set()
for f in glob.glob(os.path.join(root, "specs/cluster/manifests/external-secrets/*.y*ml")) + \
         glob.glob(os.path.join(root, "specs/cluster/manifests/workload-console-rbac/*.y*ml")):
    try: docs = list(yaml.safe_load_all(io.open(f, encoding="utf-8")))
    except Exception: continue
    for d in docs:
        if isinstance(d, dict):
            ns = (d.get("metadata") or {}).get("namespace")
            if ns: want.add(ns)
print("\n".join(sorted(want)))
PYEOF
); do
  NS_SEEN=$((NS_SEEN+1))
  case " ${NS_LOOP} " in *" ${ns} "*) : ;; *) NS_MISSING="${NS_MISSING} ${ns}" ;; esac
done
if [ "${NS_SEEN}" -eq 0 ]; then
  bad "derived ZERO target namespaces from the curated manifests — PyYAML missing or the paths moved; this check proved nothing"
elif [ -n "${NS_MISSING}" ]; then
  bad "namespaces targeted by the curated ExternalSecrets/console-RBAC are never created by the bootstrap:${NS_MISSING} — those Applications fail to sync with 'namespaces ... not found'"
else
  ok "all ${NS_SEEN} namespace(s) the curated ExternalSecrets/console-RBAC target are ensured by the bootstrap's create loop"
fi

if grep -q 'wait_for_vault_pod || exit 1' "${BOOTSTRAP}"; then
  ok "the vault-0 wait is invoked fail-closed (|| exit 1)"
else
  bad "wait_for_vault_pod is not invoked fail-closed — a missing vault-0 can again exit 0"
fi
if grep -q 'skipping Vault init/unseal/PKI bootstrap' "${BOOTSTRAP}"; then
  bad "the old warn-and-exit-0 vault-0 message is still in the script — the #48 success-over-broken exit may still be reachable"
else
  ok "the old warn-and-exit-0 vault-0 path is gone"
fi
if [ -f "${KIND_DIR}/gitops-repo-server.yaml" ]; then
  ok "gitops-repo-server.yaml (the tokenless local sync daemon) exists next to the bootstrap"
else
  bad "gitops-repo-server.yaml is missing — the default local sync path has nothing to apply"
fi
if grep -q 'tokenless local sync' "${KIND_README}"; then
  ok "README documents the tokenless local sync default"
else
  bad "README does not document the tokenless local sync path — operators will keep minting GitHub tokens for local clusters"
fi
if grep -q 'seed-vault-kv.sh' "${BOOTSTRAP}"; then
  ok "bootstrap-kind.sh seeds Vault KV through seed-vault-kv.sh"
else
  bad "bootstrap-kind.sh does not call seed-vault-kv.sh — the idempotence guard is bypassed"
fi
if grep -qE 'bash "\$\{REPO_ROOT\}/scripts/gen-cluster-secrets\.sh"' "${BOOTSTRAP}"; then
  bad "bootstrap-kind.sh still invokes gen-cluster-secrets.sh directly, bypassing the already-seeded guard"
else
  ok "bootstrap-kind.sh no longer invokes gen-cluster-secrets.sh directly"
fi
if grep -q 'verify-seeded-identities.sh' "${BOOTSTRAP}"; then
  ok "bootstrap-kind.sh runs the independent read-back before claiming the slice is seeded"
else
  bad "bootstrap-kind.sh never verifies the identity seed — it can still print 'SSO slice seeded.' over an empty Casdoor"
fi
# The idempotence claim in prose must be qualified by the thing that makes it
# true. A README that says "idempotent" with no KV-seed clause is the doc half of
# the same defect.
if grep -qi 'idempotent' "${KIND_README}" && ! grep -q 'KIND_KV_RESEED' "${KIND_README}"; then
  bad "README claims idempotence without documenting the KV-seed skip / KIND_KV_RESEED override"
else
  ok "README's idempotence claim is qualified by the KV-seed skip (KIND_KV_RESEED documented)"
fi
# An unrun guard is not a guard.
if grep -q 'tests/scripts/test-kind-bootstrap-honesty.sh' "${CI_FILE}"; then
  ok "this suite is wired into .gitlab-ci.yml"
else
  bad "this suite is not invoked by .gitlab-ci.yml — an unrun guard is not a guard"
fi

echo
echo "== kind SSO harness honesty: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
