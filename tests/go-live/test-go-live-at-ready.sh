#!/usr/bin/env bash
# test-go-live-at-ready.sh — offline logic test for "Go live when ready" (#1201):
# specs/usr/sbin/hugmesh-go-live-at-ready driving the REAL hugmesh-go-live driver and
# provider registry inside a throwaway /etc (GL_ETC_HUGMESH), with kubectl and curl
# replaced by stubs whose answers each case sets. No root, no network, no cluster.
#
# Asserts:
#   (a) no intent file -> does nothing (no state dir, no marker);
#   (b) a node that is not the public edge records not-edge and never flips;
#   (c) pods not ready -> waiting, with the first unready pod named; no marker;
#   (d) pods ready but the front door does not answer -> waiting; no marker;
#   (e) ready -> settling first (no marker), then live only after STABLE_SECONDS;
#   (f) going live runs plan (artifacts under the state dir) and commit: the marker
#       names the domain and provider, and release-state=public is persisted;
#   (g) applied is final: after a manual rollback the agent does NOT re-flip;
#   (h) readiness lost while settling resets the clock;
#   (i) tor-onion is refused for good, posture untouched;
#   (j) a failing commit retries, then gives up after MAX_ATTEMPTS, staying internal;
#   (k) malformed intent lines are ignored; --status prints every domain;
#   (l) a state change is logged once, not on every run.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="${REPO}/specs/usr/sbin/hugmesh-go-live-at-ready"
DRIVER="${REPO}/specs/usr/sbin/hugmesh-go-live"
LIB="${REPO}/specs/usr/lib/hugmesh/go-live-providers.sh"
for f in "${AGENT}" "${DRIVER}" "${LIB}"; do
    [ -r "${f}" ] || { echo "  FAIL missing: ${f}"; exit 1; }
done
. "$(dirname "${BASH_SOURCE[0]}")/../lib/guard-preflight.sh"
guard_require_tools bash awk sed grep mktemp

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

# ── stubs: kubectl answers from files, curl prints a code from a file ───────────────
BIN="${WORK}/bin"; mkdir -p "${BIN}"
cat > "${BIN}/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"get node"*) cat "${STUB_DIR}/edge" 2>/dev/null ;;
    *"get pods"*) cat "${STUB_DIR}/pods" 2>/dev/null ;;
    *) exit 1 ;;
esac
EOF
cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
cat "${STUB_DIR}/code" 2>/dev/null || printf '000'
EOF
chmod +x "${BIN}/kubectl" "${BIN}/curl"

READY_PODS='hugmesh gateway-1 Running true
kube-system coredns-1 Running true,true
argocd job-1 Succeeded <none>'

# fresh SANDBOX ETC STATE STUB_DIR for one case
setup() {
    CASE="${WORK}/$1"; ETC="${CASE}/etc"; STATE="${CASE}/state"; export STUB_DIR="${CASE}/stub"
    mkdir -p "${ETC}" "${STUB_DIR}"
    printf 'example.com\n' > "${ETC}/cluster-domain"
    printf 'internal\n' > "${ETC}/release-state"
    printf 'true' > "${STUB_DIR}/edge"
    printf '%s\n' "${READY_PODS}" > "${STUB_DIR}/pods"
    printf '200' > "${STUB_DIR}/code"
    LOG="${CASE}/agent.log"
}
agent() {   # agent NOW [args]
    local t="$1"; shift
    GL_ETC_HUGMESH="${ETC}" GL_PROVIDERS_LIB="${LIB}" GLW_STATE_DIR="${STATE}" \
    GLW_DRIVER="${DRIVER}" GLW_KUBECTL="${BIN}/kubectl" GLW_CURL="${BIN}/curl" \
    GLW_KUBECONFIG=/dev/null GLW_NODE_NAME=edge-1 GLW_NOW="${t}" GLW_STABLE_SECONDS=120 \
    GLW_MAX_ATTEMPTS=3 GLW_SYSLOG=0 bash "${AGENT}" "$@" </dev/null >>"${LOG}" 2>&1
}
st() { sed -n "s/^$2=//p" "${STATE}/$1.state" 2>/dev/null | head -1; }

# (a) no intent file
setup a
agent 1000
[ ! -e "${STATE}" ] && [ ! -e "${ETC}/go-live" ] && ok "(a) no intent file: nothing created, no marker" \
    || bad "(a) no intent file still created state or a marker"

# (b) not the edge node
setup b; printf 'example.com=byo-domain\n' > "${ETC}/domain-go-live"; printf '' > "${STUB_DIR}/edge"
agent 1000; agent 2000
[ "$(st example.com status)" = not-edge ] && [ ! -e "${ETC}/go-live" ] \
    && grep -q 'not the public edge' "${STATE}/example.com.state" \
    && ok "(b) non-edge node: not-edge, never flips" || bad "(b) non-edge: status=$(st example.com status)"

# (c) pods not ready
setup c; printf 'example.com=byo-domain\n' > "${ETC}/domain-go-live"
printf 'hugmesh gateway-1 Running true\nhugmesh casdoor-0 Pending <none>\n' > "${STUB_DIR}/pods"
agent 1000
[ "$(st example.com status)" = waiting ] && grep -q 'hugmesh/casdoor-0 (Pending)' "${STATE}/example.com.state" \
    && [ ! -e "${ETC}/go-live" ] && ok "(c) unready pod: waiting, names hugmesh/casdoor-0" \
    || bad "(c) unready pod: $(cat "${STATE}/example.com.state" 2>/dev/null)"
printf 'hugmesh gateway-1 Running true,false\n' > "${STUB_DIR}/pods"
agent 1100
grep -q 'gateway-1 (Running)' "${STATE}/example.com.state" && ok "(c) a Running pod with an unready container is not ready" \
    || bad "(c) partial readiness not caught"

# (d) front door not answering
setup d; printf 'example.com=byo-domain\n' > "${ETC}/domain-go-live"; printf '000' > "${STUB_DIR}/code"
agent 1000
[ "$(st example.com status)" = waiting ] && grep -q 'does not answer' "${STATE}/example.com.state" \
    && [ ! -e "${ETC}/go-live" ] && ok "(d) silent front door: waiting" || bad "(d) $(cat "${STATE}/example.com.state")"
printf '502' > "${STUB_DIR}/code"; agent 1100
grep -q 'HTTP 502' "${STATE}/example.com.state" && ok "(d) a 5xx front door is not ready" || bad "(d) 5xx not caught"

# (e)+(f) settle, then go live
setup e; printf 'example.com=byo-domain\n' > "${ETC}/domain-go-live"
agent 1000
[ "$(st example.com status)" = settling ] && [ ! -e "${ETC}/go-live" ] && ok "(e) first ready run: settling, no marker" \
    || bad "(e) first ready run: $(st example.com status)"
agent 1060
[ "$(st example.com status)" = settling ] && [ ! -e "${ETC}/go-live" ] && ok "(e) 60s in: still settling" \
    || bad "(e) went live before the stable window"
agent 1130
if [ "$(st example.com status)" = applied ] && [ -e "${ETC}/go-live" ]; then
    ok "(e) after 120s ready: applied, marker written"
else
    bad "(e) not applied: $(cat "${STATE}/example.com.state"); $(tail -5 "${STATE}/driver.log" 2>/dev/null)"
fi
grep -q '^domain=example.com$' "${ETC}/go-live" 2>/dev/null && grep -q '^provider=byo-domain$' "${ETC}/go-live" 2>/dev/null \
    && ok "(f) marker names domain and provider" || bad "(f) marker content: $(cat "${ETC}/go-live" 2>/dev/null)"
[ "$(tr -d '[:space:]' < "${ETC}/release-state")" = public ] && ok "(f) release-state persisted public" \
    || bad "(f) release-state not persisted"
[ -n "$(ls -A "${STATE}/example.com.plan" 2>/dev/null)" ] && ok "(f) plan artifacts kept under the state dir" \
    || bad "(f) no plan artifacts"

# (g) applied is final
GL_ETC_HUGMESH="${ETC}" GL_PROVIDERS_LIB="${LIB}" bash "${DRIVER}" rollback --revert-release-state -y </dev/null >/dev/null 2>&1
agent 5000; agent 6000
[ ! -e "${ETC}/go-live" ] && [ "$(st example.com status)" = applied ] && ok "(g) a manual rollback is not overridden" \
    || bad "(g) agent re-flipped after rollback"

# (h) readiness lost while settling resets the clock
setup h; printf 'example.com=byo-domain\n' > "${ETC}/domain-go-live"
agent 1000                                   # settling since 1000
printf '000' > "${STUB_DIR}/code"; agent 1050  # lost
printf '200' > "${STUB_DIR}/code"; agent 1100  # settling again, since 1100
agent 1150
[ "$(st example.com status)" = settling ] && [ "$(st example.com ready_since)" = 1100 ] && [ ! -e "${ETC}/go-live" ] \
    && ok "(h) lost readiness restarts the 120s window" || bad "(h) $(cat "${STATE}/example.com.state")"

# (i) tor-onion refused
setup i; printf 'example.com=tor-onion\n' > "${ETC}/domain-go-live"
agent 1000; agent 2000
[ "$(st example.com status)" = refused ] && [ ! -e "${ETC}/go-live" ] && ok "(i) tor-onion refused, posture untouched" \
    || bad "(i) tor-onion: $(st example.com status)"

# (j) failing commit retries then gives up (unknown provider makes the driver refuse)
setup j; printf 'example.com=no-such-provider\n' > "${ETC}/domain-go-live"
agent 1000; agent 1200
[ "$(st example.com status)" = waiting ] && [ "$(st example.com attempts)" = 1 ] && ok "(j) failed go-live: retry 1 recorded" \
    || bad "(j) after one failure: $(cat "${STATE}/example.com.state")"
agent 1300; agent 1500; agent 1700; agent 1900; agent 2100
[ "$(st example.com status)" = gave-up ] && [ ! -e "${ETC}/go-live" ] && ok "(j) gave up after MAX_ATTEMPTS, still internal" \
    || bad "(j) $(cat "${STATE}/example.com.state")"

# (m) a build-supplied token reaches plan --token-file; its value is never logged
setup m; printf 'example.com=duckdns\n' > "${ETC}/domain-go-live"
mkdir -p "${ETC}/go-live-tokens"; printf 'SECRET-TOKEN-VALUE-1201\n' > "${ETC}/go-live-tokens/example.com.token"
agent 1000; agent 1130
if [ "$(st example.com status)" = applied ] && grep -rq 'SECRET-TOKEN-VALUE-1201' "${ETC}/keys" 2>/dev/null; then
    ok "(m) the token was stored by plan into the provider's keys layout"
else
    bad "(m) token not stored: $(cat "${STATE}/example.com.state"); $(ls -R "${ETC}" 2>/dev/null | head -20)"
fi
if grep -rq 'SECRET-TOKEN-VALUE-1201' "${LOG}" "${STATE}"/*.state "${STATE}/driver.log" 2>/dev/null; then
    bad "(m) the token VALUE appears in a log or state file"
else
    ok "(m) the token value is in no log or state file"
fi

# (k) malformed lines + --status
setup k; printf '# comment\n\nBAD DOMAIN=byo-domain\nexample.com=byo-domain\nshop.example=router-portforward\n' > "${ETC}/domain-go-live"
agent 1000
grep -q "ignoring malformed line" "${LOG}" && [ -e "${STATE}/example.com.state" ] && [ -e "${STATE}/shop.example.state" ] \
    && ok "(k) malformed line ignored, good lines handled" || bad "(k) malformed handling"
out="$(agent 1000 --status; cat "${LOG}" | tail -3)"
grep -q 'example.com via byo-domain: settling' "${LOG}" && grep -q 'shop.example via router-portforward: settling' "${LOG}" \
    && ok "(k) --status lists each domain" || bad "(k) --status: ${out}"

# (l) logged once per change
setup l; printf 'example.com=byo-domain\n' > "${ETC}/domain-go-live"; printf '000' > "${STUB_DIR}/code"
agent 1000; agent 1060; agent 1120
n="$(grep -c 'example.com: waiting' "${LOG}")"
[ "${n}" = 1 ] && ok "(l) an unchanged waiting state is logged once" || bad "(l) logged ${n} times"

echo "go-live-at-ready: ${P} passed, ${F} failed"
[ "${F}" -eq 0 ] || exit 1
