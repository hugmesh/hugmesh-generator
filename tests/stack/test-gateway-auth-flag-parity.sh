#!/usr/bin/env bash
# test-gateway-auth-flag-parity.sh — the docker lane and the cluster lane must run
# the SAME auth carrier.
#
# THE DEFECT. Both halves of the bff_ cookie bridge are hard-gated flags on the
# gateway image:
#   BffCookieToBearerWebFilter :48  @ConditionalOnProperty(hugmesh.gateway.bff-exchange.enabled)
#   BffJwtExchangeConfig       :47  @ConditionalOnProperty(hugmesh.gateway.bff-exchange.enabled)
# tests/stack/compose.local.yaml:546 has set HUGMESH_GATEWAY_BFF_EXCHANGE_ENABLED
# since the day the consequence was diagnosed and written down in that file:
#
#   "forum/wiki/tube/owncast-bff are PURE JWT resource servers: they received
#    `Bearer bff_...` ... and answered a bare 401 ... with nothing in any log"
#
# specs/cluster NEVER set it. `grep -rn "BFF_EXCHANGE\|bff-exchange" specs/cluster`
# returned NOTHING. So kind and every baked device image forwarded a cookie-only
# request with the raw opaque bff_ as the Bearer while docker forwarded a real JWT
# — a different auth carrier per environment, with the ONE lane that gets exercised
# locally being the ONE lane that cannot reproduce the failure.
#
# WHY THIS COMPARES EFFECTIVE VALUES, NOT PRESENCE. `bff-exchange.enabled` defaults
# FALSE in the image; `app.bff-session.enabled` defaults TRUE. "compose sets it,
# the cluster does not" is therefore a REAL divergence for the first key and a
# non-event for the second. A presence check would cry wolf on one and — worse —
# go green the day someone writes a key's own default on one side only. Each key's
# default is read from the gateway's OWN application.yml
# (tests/stack/gateway_auth_flags.py defaults) and both lanes resolve through it.
#
# THE GATEWAY CHECKOUT IS PART OF THE GATE. Without it the defaults cannot be read
# and this FAILS as INCOMPLETE rather than skipping. Resolution order:
# $GATEWAY_SRC, $SERVICE_SRC_ROOT/hugmesh-gateway, <repo>/.stack-src/hugmesh-gateway,
# <repo>/../hugmesh-gateway.
#
# WHAT THIS DOES NOT CLAIM. Parity of these flags is not parity of the lanes. The
# kind profile deploys a fraction of the tiers (see
# tests/scripts/test-kind-profile-route-closure.sh for that inventory), and
# be-gateway runs the exchange OFF on BOTH lanes today — this gate pins that
# symmetry rather than asserting it is the right posture.
#
# Offline: python3 + PyYAML. No docker, no cluster, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
EX="${HERE}/gateway_auth_flags.py"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-${HERE}/compose.local.yaml}"
APPS="${APPS_DIR_UNDER_TEST:-${REPO}/specs/cluster/apps}"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required (refusing to skip)" >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: PyYAML required (refusing to skip)" >&2; exit 1; }
[ -r "${EX}" ] || { echo "FATAL: cannot read ${EX}" >&2; exit 1; }
[ -r "${COMPOSE}" ] || { echo "FATAL: cannot read ${COMPOSE}" >&2; exit 1; }

# ── locate the gateway checkout (its application.yml carries the image defaults) ─
GW=""
for cand in "${GATEWAY_SRC:-}" "${SERVICE_SRC_ROOT:-}/hugmesh-gateway" \
            "${REPO}/.stack-src/hugmesh-gateway" "${REPO}/../hugmesh-gateway"; do
  [ -n "${cand}" ] || continue
  [ -f "${cand}/src/main/resources/application.yml" ] && { GW="${cand}"; break; }
done
if [ -z "${GW}" ]; then
  echo "== gateway auth-flag parity: INCOMPLETE =="
  echo "   The image DEFAULTS come from hugmesh-gateway/src/main/resources/application.yml."
  echo "   Set GATEWAY_SRC or SERVICE_SRC_ROOT, or run 'make stack-clone'."
  echo "   A green run without it would be a lie, so this is a FAIL."
  exit 1
fi
GWY="${GW}/src/main/resources/application.yml"

# ── the keys under parity, and the gateway roles that exist on BOTH lanes ──────
# pki-gateway is deliberately absent: it fronts headscale with its own auth model
# and carries no bff_ session surface on either lane.
KEYS=(HUGMESH_GATEWAY_BFF_EXCHANGE_ENABLED APP_BFF_SESSION_ENABLED)
ROLES=("fe:hugmesh-fe-gateway:20-gateway-fe.yaml" "be:hugmesh-be-gateway:20-gateway-be.yaml")

echo "== gateway auth-flag parity (compose vs specs/cluster) =="
echo "   image defaults from: ${GWY}"

T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT

# ── image defaults ────────────────────────────────────────────────────────────
if ! python3 "${EX}" defaults "${GWY}" "${KEYS[@]}" > "${T}/defaults.tsv" 2>"${T}/defaults.err"; then
  cat "${T}/defaults.tsv" "${T}/defaults.err"
  bad "could not read the image defaults for every key — a key that does not exist in the image cannot be 'in parity'"
fi
cat "${T}/defaults.tsv" | sed 's/^/     default: /'
default_of() { awk -F'\t' -v k="$1" '$1==k{print $2}' "${T}/defaults.tsv"; }

compared=0
for role in "${ROLES[@]}"; do
  short="${role%%:*}"; rest="${role#*:}"; svc="${rest%%:*}"; app="${rest#*:}"
  [ -r "${APPS}/${app}" ] || { bad "cannot read ${APPS}/${app}"; continue; }
  python3 "${EX}" compose "${COMPOSE}" "${svc}" "${KEYS[@]}" > "${T}/${short}.compose" 2>/dev/null \
    || { bad "${short}: compose extraction failed"; continue; }
  python3 "${EX}" cluster "${APPS}/${app}" "${KEYS[@]}" > "${T}/${short}.cluster" 2>/dev/null \
    || { bad "${short}: cluster extraction failed"; continue; }
  for k in "${KEYS[@]}"; do
    dflt="$(default_of "${k}")"
    cs="$(awk -F'\t' -v k="${k}" '$2==k{print $3}' "${T}/${short}.compose")"
    cv="$(awk -F'\t' -v k="${k}" '$2==k{print $4}' "${T}/${short}.compose")"
    ks="$(awk -F'\t' -v k="${k}" '$2==k{print $3}' "${T}/${short}.cluster")"
    kv="$(awk -F'\t' -v k="${k}" '$2==k{print $4}' "${T}/${short}.cluster")"
    [ "${cs}" = "PRESENT" ] || cv="${dflt}"
    [ "${ks}" = "PRESENT" ] || kv="${dflt}"
    compared=$((compared+1))
    if [ "${cv}" = "${kv}" ]; then
      ok "${short}-gateway ${k}: both lanes effectively '${cv}' (compose ${cs}, cluster ${ks}, image default '${dflt}')"
    else
      bad "${short}-gateway ${k}: compose='${cv}' but cluster='${kv}' — the two lanes run DIFFERENT auth carriers (image default '${dflt}')"
    fi
  done
done

# ── the swap target must be reachable wherever the exchange is ON ─────────────
# The image default is `http://admin-bff:8080`: a Service name that exists in NO
# namespace of this cluster, over plain http into a listener that serves TLS with
# client-auth=need. Turning the flag on without overriding it is a 503 with a
# stack trace about a premature close, which is how the sibling BFF_BASE_URL bug
# burned a day on kind in 2026-08.
URI_KEY=HUGMESH_GATEWAY_BFF_EXCHANGE_ADMIN_BFF_URI
uri_default="$(python3 "${EX}" defaults "${GWY}" "${URI_KEY}" | awk -F'\t' '{print $2}')"
for role in "${ROLES[@]}"; do
  short="${role%%:*}"; rest="${role#*:}"; svc="${rest%%:*}"; app="${rest#*:}"
  on_cluster="$(awk -F'\t' '$2=="HUGMESH_GATEWAY_BFF_EXCHANGE_ENABLED"{print $4}' "${T}/${short}.cluster")"
  [ "${on_cluster}" = "true" ] || continue
  got="$(python3 "${EX}" cluster "${APPS}/${app}" "${URI_KEY}" | awk -F'\t' '{print $4}')"
  if [ "${got}" = "-" ] || [ "${got}" = "${uri_default}" ]; then
    bad "${short}-gateway: the exchange is ON but ${URI_KEY} is the image default '${uri_default}', which resolves nowhere in this cluster"
  elif [[ "${got}" == https://*.svc.cluster.local:* ]]; then
    ok "${short}-gateway: ${URI_KEY} overridden to an in-cluster https address (${got})"
  else
    bad "${short}-gateway: ${URI_KEY}='${got}' is not an https in-cluster Service address (admin-bff serves TLS with client-auth=need)"
  fi
done

# ── vacuity: a run that compared nothing must not pass ────────────────────────
if [ "${compared}" -ge 4 ]; then
  ok "vacuity: ${compared} (role, key) pair(s) really compared"
else
  bad "vacuity: only ${compared} pair(s) compared — the extractor has gone blind"
fi

# A CHILD run (the negative controls below re-enter this script against synthetic
# fixtures) reports the parity verdict and stops. The flag is a POSITIONAL
# ARGUMENT, never an env var: an inherited env var would silently downgrade a real
# CI run to a control run and nothing would say so.
if [ "${1:-}" = "--parity-only" ]; then
  echo "== child run: ${pass} passed, ${fail} failed =="
  [ "${fail}" -eq 0 ]; exit $?
fi

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
# Each is a PAIR: the defective fixture must FAIL and the pristine one must PASS.
echo
echo "-- negative controls (each is a defect/no-defect PAIR) --"
mkdir -p "${T}/apps"
cp "${APPS}"/20-gateway-*.yaml "${T}/apps/"
cp "${COMPOSE}" "${T}/pristine.yaml"

run_fixture() { # <apps-dir> <compose> -> rc
  APPS_DIR_UNDER_TEST="$1" COMPOSE_FILE_UNDER_TEST="$2" GATEWAY_SRC="${GW}" \
    bash "${BASH_SOURCE[0]}" --parity-only >/dev/null 2>&1
}

pair() { # <name> <bad-apps> <bad-compose>
  if run_fixture "$2" "$3"; then
    bad "control '$1': the DEFECTIVE fixture was not caught"
  elif ! run_fixture "${T}/apps" "${T}/pristine.yaml"; then
    bad "control '$1': the PRISTINE fixture also failed — the control cannot distinguish"
  else
    ok "control '$1': defective fixture caught, pristine fixture clean"
  fi
}

# 1. THE SHIPPED DEFECT: delete the exchange flag from the cluster fe-gateway.
mkdir -p "${T}/b1"; cp "${T}/apps"/*.yaml "${T}/b1/"
grep -v 'name: HUGMESH_GATEWAY_BFF_EXCHANGE_ENABLED' "${T}/apps/20-gateway-fe.yaml" > "${T}/b1/20-gateway-fe.yaml"
if diff -q "${T}/apps/20-gateway-fe.yaml" "${T}/b1/20-gateway-fe.yaml" >/dev/null; then
  bad "control 'cluster loses the exchange flag': the fixture edit changed nothing"
else
  pair "cluster loses the exchange flag (the shipped defect)" "${T}/b1" "${T}/pristine.yaml"
fi

# 2. THE MIRROR IMAGE: compose loses it instead. Same divergence, other direction —
#    a gate that only looks one way is half a gate.
sed 's/^      HUGMESH_GATEWAY_BFF_EXCHANGE_ENABLED: "true"$/      HUGMESH_GATEWAY_BFF_EXCHANGE_UNUSED: "true"/' \
  "${T}/pristine.yaml" > "${T}/b2.yaml"
if diff -q "${T}/pristine.yaml" "${T}/b2.yaml" >/dev/null; then
  bad "control 'compose loses the exchange flag': the fixture edit changed nothing"
else
  pair "compose loses the exchange flag (mirror image)" "${T}/apps" "${T}/b2.yaml"
fi

# 3. THE SWAP TARGET left at the image default while the flag is on.
mkdir -p "${T}/b3"; cp "${T}/apps"/*.yaml "${T}/b3/"
grep -v 'HUGMESH_GATEWAY_BFF_EXCHANGE_ADMIN_BFF_URI' "${T}/apps/20-gateway-fe.yaml" \
  | grep -v 'value: https://hugmesh-admin-bff-api.hugmesh-backend.svc.cluster.local:8080$' > "${T}/b3/20-gateway-fe.yaml"
if diff -q "${T}/apps/20-gateway-fe.yaml" "${T}/b3/20-gateway-fe.yaml" >/dev/null; then
  bad "control 'swap target left at the image default': the fixture edit changed nothing"
else
  pair "swap target left at the image default" "${T}/b3" "${T}/pristine.yaml"
fi

# 4. A VALUE MISMATCH, not just an absence: both lanes set the key, to opposites.
mkdir -p "${T}/b4"; cp "${T}/apps"/*.yaml "${T}/b4/"
sed 's/{ name: HUGMESH_GATEWAY_BFF_EXCHANGE_ENABLED, value: "true" }/{ name: HUGMESH_GATEWAY_BFF_EXCHANGE_ENABLED, value: "false" }/' \
  "${T}/apps/20-gateway-fe.yaml" > "${T}/b4/20-gateway-fe.yaml"
if diff -q "${T}/apps/20-gateway-fe.yaml" "${T}/b4/20-gateway-fe.yaml" >/dev/null; then
  bad "control 'explicit opposite values': the fixture edit changed nothing"
else
  pair "explicit opposite values on the two lanes" "${T}/b4" "${T}/pristine.yaml"
fi

echo
echo "== gateway auth-flag parity: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
