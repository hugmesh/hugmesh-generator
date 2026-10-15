#!/usr/bin/env bash
# test-sso-token-producer.sh — unit test for the SSO token PRODUCER
# (specs/etc/hugmesh/desktop-governance/sso/hugmesh-sso-token.py.tmpl), the half of
# the desktop-governance chain that had no code at all (FD-07 increment 2).
#
# The consumers (oidc-token-deposit.sh, bearer-forward.sh, the desktop-sudo mapper)
# were shipped against a documented drop: ${XDG_RUNTIME_DIR}/hugmesh/oidc-token.src.
# This suite proves the producer writes exactly that drop, and then proves the
# CONTRACT END TO END by feeding its output through the REAL rendered deposit
# script and the REAL rendered mapper (real RSA keypair, real RS256 signatures).
#
# Headless, NO root, NO network, NO display: the issuer is a local fake that speaks
# OIDC discovery + the RFC 8628 device authorization grant + the refresh grant. It
# serves tokens this suite signed with openssl, so the mapper can verify them.
# What it does NOT prove: that a live Casdoor answers the same way (see the PR).
#
# Proves:
#   GATE        ungoverned => no request, no drop; `clear` honoured regardless.
#   FLOW        governed => device grant for client hugmesh-desktop; pending and
#               slow_down are survived; drop is 0600 in a 0700 dir, atomic (no temp
#               left), content == token; the token is never on stdout/stderr.
#   FALLBACK    discovery missing => Casdoor's fixed /api/device-auth path is used.
#   REFUSALS    access_denied / expired_token / server refusal / timeout => rc 1 and
#               NO drop; a token for another user or an expired token => not stored.
#   --if-needed a valid pre-dropped token (greeter/PAM) is honoured, never replaced.
#   REFRESH     rotates a near-expiry token; invalid_grant CLEARS (revocation fails
#               closed); a transient server error KEEPS what is there.
#   LOGOUT      clear / --pam close_session remove the drop and the refresh token;
#               --pam open_session is a no-op; --pam never fails a PAM stack.
#   HARDENING   a planted symlink at the drop is replaced, not followed; a non-https
#               issuer is refused.
#   CONTRACT    producer -> real deposit -> real mapper => the user is added to
#               desktop-sudo; producer drop for another user => not added.
#   WRAPPER     the session wrapper runs the producer BEFORE the deposit and
#               --clear-all on logout; --clear keeps a pre-session drop.
#   INSTALL     session-install renders the producer 0755 with the domain in.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL="${REPO}/specs/etc/hugmesh/desktop-governance"
PROD_TPL="${TPL}/sso/hugmesh-sso-token.py.tmpl"
MAPPER_TPL="${TPL}/sudo/desktop-sudo-mapper.py.tmpl"
DEP_TPL="${TPL}/discover/oidc-token-deposit.sh.tmpl"
WRAP_TPL="${TPL}/autostart/hugmesh-desktop-sso-start.sh.tmpl"
INSTALL_TPL="${TPL}/autostart/session-install.sh.tmpl"
for f in "${PROD_TPL}" "${MAPPER_TPL}" "${DEP_TPL}" "${WRAP_TPL}" "${INSTALL_TPL}"; do
    [ -f "${f}" ] || { echo "  FAIL template missing: ${f}"; exit 1; }
done
command -v python3 >/dev/null || { echo "  FAIL python3 required"; exit 1; }
command -v openssl >/dev/null || { echo "  FAIL openssl required"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup(){ [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null; rm -rf "${WORK}"; }
trap cleanup EXIT

ME="$(id -un)"

# ── Render exactly as session-install / provision do (domain substitution) ────
PROD="${WORK}/hugmesh-sso-token"
sed 's/@@CLUSTER_DOMAIN@@/acme.example/g' "${PROD_TPL}" > "${PROD}"; chmod 0755 "${PROD}"
MAPPER="${WORK}/desktop-sudo-mapper"
sed 's/@@CLUSTER_DOMAIN@@/acme.example/g' "${MAPPER_TPL}" > "${MAPPER}"; chmod 0755 "${MAPPER}"
grep -q '@@CLUSTER_DOMAIN@@' "${PROD}" && { echo "  FAIL placeholder left in producer render"; exit 1; }
python3 -m py_compile "${PROD}" 2>/dev/null && ok "producer render compiles" || bad "producer render does not compile"

# ── Real key material + JWKS (same shape as test-desktop-sudo-mapper.sh) ─────
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${WORK}/key.pem" 2>/dev/null
MOD="$(openssl rsa -in "${WORK}/key.pem" -noout -modulus | sed 's/^Modulus=//')"
python3 - "${MOD}" > "${WORK}/jwks.json" <<'PY'
import base64, json, sys
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
print(json.dumps({"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": "t1",
                            "n": b64(bytes.fromhex(sys.argv[1])), "e": "AQAB"}]}))
PY
b64url(){ openssl base64 -A | tr '+/' '-_' | tr -d '='; }
mint() {  # $1=payload-json -> signed JWT
    local h p s
    h="$(printf '%s' '{"alg":"RS256","typ":"JWT","kid":"t1"}' | b64url)"
    p="$(printf '%s' "$1" | b64url)"
    printf '%s.%s' "${h}" "${p}" > "${WORK}/si"
    openssl dgst -sha256 -sign "${WORK}/key.pem" -out "${WORK}/sig.bin" "${WORK}/si"
    s="$(b64url < "${WORK}/sig.bin")"
    printf '%s.%s.%s' "${h}" "${p}" "${s}"
}
NOW="$(date +%s)"
payload(){ # $1=name [$2=exp-offset-seconds]
    printf '{"iss":"https://id.acme.example","aud":["hugmesh-desktop"],"exp":%s,"name":"%s","roles":["ROLE_USER","desktop-sudo"]}' \
        "$((NOW + ${2:-3600}))" "$1"
}
TOK_ME="$(mint "$(payload "${ME}")")"
TOK_ME2="$(mint "$(payload "${ME}" 7200)")"
TOK_ME_SOON="$(mint "$(payload "${ME}" 60)")"       # inside the 5-minute refresh window
TOK_OTHER="$(mint "$(payload someone-else)")"
TOK_EXPIRED="$(mint "$(payload "${ME}" -3600)")"
REFRESH_1="refresh-token-one"; REFRESH_2="refresh-token-two"

# ── The fake issuer: discovery + RFC 8628 device grant + refresh grant ────────
# Behaviour is driven by files in $SRV: `seq` is a comma list of poll outcomes
# consumed in order (the last repeats): pending | slow_down | denied | expired |
# ok | refresh_ok | revoked | http500. Every POST body is appended to requests.log.
SRV="${WORK}/srv"; mkdir -p "${SRV}"
cat > "${WORK}/fake-issuer.py" <<'PY'
import http.server, json, os, sys, urllib.parse
D = sys.argv[1]
def rd(n, d=""):
    try: return open(os.path.join(D, n)).read().strip()
    except OSError: return d
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def out(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        base = "http://127.0.0.1:%d" % self.server.server_port
        if rd("scenario") == "no_discovery":
            return self.out(404, {})
        if self.path.endswith("/.well-known/openid-configuration"):
            return self.out(200, {"issuer": base, "device_authorization_endpoint": base + "/dev",
                                  "token_endpoint": base + "/tok"})
        self.out(404, {})
    def do_POST(self):
        base = "http://127.0.0.1:%d" % self.server.server_port
        f = dict(urllib.parse.parse_qsl(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()))
        open(os.path.join(D, "requests.log"), "a").write(self.path + " " + json.dumps(f, sort_keys=True) + "\n")
        import time
        open(os.path.join(D, "ts.log"), "a").write("%s %.4f\n" % (self.path, time.time()))
        if self.path in ("/dev", "/api/device-auth"):
            if rd("scenario") == "no_device":
                return self.out(400, {"error": "unauthorized_client"})
            return self.out(200, {"device_code": "DEVCODE123", "user_code": "ABCD-EFGH",
                                  "verification_uri": base + "/activate",
                                  "expires_in": int(rd("device_expires", "60")), "interval": 1})
        if self.path in ("/tok", "/api/login/oauth/access_token"):
            seq = rd("seq", "ok").split(",")
            n = int(rd("n", "0")); open(os.path.join(D, "n"), "w").write(str(n + 1))
            step = seq[min(n, len(seq) - 1)]
            if step == "pending":  return self.out(400, {"error": "authorization_pending"})
            if step == "slow_down": return self.out(400, {"error": "slow_down"})
            if step == "denied":   return self.out(400, {"error": "access_denied"})
            if step == "expired":  return self.out(400, {"error": "expired_token"})
            if step == "revoked":  return self.out(400, {"error": "invalid_grant"})
            if step == "http500":  return self.out(500, {})
            if step == "ok":
                return self.out(200, {"access_token": rd("access"), "refresh_token": rd("refresh"),
                                      "token_type": "Bearer", "expires_in": 3600})
            if step == "refresh_ok":
                return self.out(200, {"access_token": rd("access"), "refresh_token": rd("refresh"),
                                      "token_type": "Bearer", "expires_in": 3600})
        self.out(404, {})
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "port"), "w").write(str(s.server_port))
s.serve_forever()
PY
python3 "${WORK}/fake-issuer.py" "${SRV}" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "${SRV}/port" ] && break; sleep 0.1; done
PORT="$(cat "${SRV}/port" 2>/dev/null)"
[ -n "${PORT}" ] && ok "fake issuer up on 127.0.0.1:${PORT}" || { bad "fake issuer did not start"; exit 1; }

# ── Per-case sandbox ─────────────────────────────────────────────────────────
GOVDIR=""
new_case() {  # $1 = governed|ungoverned; remaining: scenario seq, access, refresh
    CASE="$(mktemp -d "${WORK}/case.XXXXXX")"
    RUN="${CASE}/run"; GOVDIR="${CASE}/gov"
    mkdir -p "${RUN}" "${GOVDIR}"; chmod 0700 "${RUN}"
    if [ "${1:-governed}" = "governed" ]; then
        printf '#!/bin/sh\nexit 0\n' > "${GOVDIR}/desktop-sudo-mapper"; chmod 0700 "${GOVDIR}/desktop-sudo-mapper"
    fi
    rm -f "${SRV}"/{requests.log,ts.log,n,scenario,seq,access,refresh,device_expires}
    printf '%s' "${2:-ok}" > "${SRV}/seq"
    printf '%s' "${3:-${TOK_ME}}" > "${SRV}/access"
    printf '%s' "${4:-${REFRESH_1}}" > "${SRV}/refresh"
}
prod() {  # run the producer against the fake issuer; stdout+stderr -> $CASE/out
    XDG_RUNTIME_DIR="${RUN}" HSP_INSECURE_TEST=1 HSP_ISSUER="http://127.0.0.1:${PORT}" \
    HSP_GOV_DIR="${GOVDIR}" HSP_POLL_SCALE=0.05 DISPLAY="" WAYLAND_DISPLAY="" \
    timeout 60 python3 "${PROD}" "$@" > "${CASE}/out" 2>&1 < /dev/null
}
DROP(){ echo "${RUN}/hugmesh/oidc-token.src"; }
nreq(){ [ -f "${SRV}/requests.log" ] && wc -l < "${SRV}/requests.log" || echo 0; }
mode(){ stat -c '%a' "$1" 2>/dev/null; }

echo "== SSO token producer unit test =="

# ── GATE: ungoverned => nothing; clear still honoured ─────────────────────────
new_case ungoverned
prod login; rc=$?
[ "${rc}" -eq 0 ] && [ "$(nreq)" -eq 0 ] && [ ! -e "$(DROP)" ] \
    && ok "ungoverned: login is inert (rc 0, no request, no drop)" \
    || bad "ungoverned: login not inert (rc ${rc}, requests $(nreq))"
mkdir -p "${RUN}/hugmesh"; printf 'x' > "$(DROP)"
prod clear
[ ! -e "$(DROP)" ] && ok "ungoverned: clear still removes the drop" || bad "ungoverned: clear did not remove the drop"

# ── FLOW: pending -> slow_down -> ok ──────────────────────────────────────────
new_case governed "pending,slow_down,ok"
prod login --ui none; rc=$?
[ "${rc}" -eq 0 ] && ok "device flow completes (rc 0)" || bad "device flow rc ${rc}: $(cat "${CASE}/out")"
[ "$(cat "$(DROP)" 2>/dev/null)" = "${TOK_ME}" ] && ok "drop content == the issued access token" || bad "drop content wrong"
[ "$(mode "$(DROP)")" = "600" ] && ok "drop file mode 0600" || bad "drop mode $(mode "$(DROP)")"
[ "$(mode "${RUN}/hugmesh")" = "700" ] && ok "drop dir mode 0700" || bad "dir mode $(mode "${RUN}/hugmesh")"
[ -z "$(find "${RUN}/hugmesh" -name '*.tmp')" ] && ok "no temp file left behind (atomic rename)" || bad "temp file left"
[ "$(cat "${RUN}/hugmesh/oidc-refresh" 2>/dev/null)" = "${REFRESH_1}" ] && [ "$(mode "${RUN}/hugmesh/oidc-refresh")" = "600" ] \
    && ok "refresh token kept 0600 in the runtime dir" || bad "refresh token missing or loose"
grep -q '^/dev ' "${SRV}/requests.log" && grep -q '"client_id": "hugmesh-desktop"' "${SRV}/requests.log" \
    && ok "device authorization asked for client hugmesh-desktop" || bad "no device request for hugmesh-desktop"
grep '^/tok ' "${SRV}/requests.log" | grep -c 'urn:ietf:params:oauth:grant-type:device_code' >/dev/null \
    && grep '^/tok ' "${SRV}/requests.log" | grep -c 'DEVCODE123' >/dev/null \
    && ok "poll used the device_code grant with the device code" || bad "poll request wrong"
[ "$(grep -c '^/tok ' "${SRV}/requests.log")" -eq 3 ] && ok "pending and slow_down were survived (3 polls)" || bad "poll count $(grep -c '^/tok ' "${SRV}/requests.log") != 3"
python3 - "${SRV}/ts.log" <<'PY' && ok "slow_down lengthened the poll interval (RFC 8628: +5 s, here scaled)" || bad "slow_down did not lengthen the interval"
import sys
t = [float(l.split()[1]) for l in open(sys.argv[1]) if l.startswith("/tok")]
# polls: 1 pending, 2 slow_down, 3 ok. Scale 0.05: gap before poll 3 is 6*0.05 = 0.30 s.
sys.exit(0 if len(t) == 3 and (t[2] - t[1]) >= 0.25 else 1)
PY
grep -qF "${TOK_ME}" "${CASE}/out" && bad "the access token leaked into producer output" || ok "token never printed"
grep -qF "${REFRESH_1}" "${CASE}/out" && bad "the refresh token leaked into producer output" || ok "refresh token never printed"
grep -q 'ABCD-EFGH' "${CASE}/out" && bad "ui none still printed" || ok "--ui none shows nothing"

# the user code reaches the human on the fallback channel
new_case governed "ok"
prod login; grep -q 'ABCD-EFGH' "${CASE}/out" && grep -q '/activate' "${CASE}/out" \
    && ok "user code + verification URL reach the user (stderr fallback)" || bad "user code not shown"

# ── FALLBACK: no discovery => Casdoor's fixed paths ───────────────────────────
new_case governed "ok"; printf 'no_discovery' > "${SRV}/scenario"
prod login --ui none; rc=$?
[ "${rc}" -eq 0 ] && grep -q '^/api/device-auth ' "${SRV}/requests.log" && grep -q '^/api/login/oauth/access_token ' "${SRV}/requests.log" \
    && ok "no discovery => /api/device-auth + /api/login/oauth/access_token fallback" || bad "fallback paths not used (rc ${rc})"

# ── REFUSALS: nothing written ────────────────────────────────────────────────
for scen in denied expired; do
    new_case governed "pending,${scen}"
    prod login --ui none; rc=$?
    [ "${rc}" -eq 1 ] && [ ! -e "$(DROP)" ] && ok "${scen}: rc 1, no drop" || bad "${scen}: rc ${rc}, drop exists"
done
new_case governed "ok"; printf 'no_device' > "${SRV}/scenario"
prod login --ui none; rc=$?
[ "${rc}" -eq 1 ] && [ ! -e "$(DROP)" ] && ok "device endpoint refusal: rc 1, no drop" || bad "device refusal rc ${rc}"
new_case governed "pending"; printf '1' > "${SRV}/device_expires"
prod login --ui none; rc=$?
[ "${rc}" -eq 1 ] && [ ! -e "$(DROP)" ] && grep -q 'timed out' "${CASE}/out" \
    && ok "never approved: times out at the code's expiry, no drop" || bad "timeout case rc ${rc}: $(cat "${CASE}/out")"
new_case governed "ok" "${TOK_OTHER}"
prod login --ui none; rc=$?
[ "${rc}" -eq 1 ] && [ ! -e "$(DROP)" ] && ok "token for another user is NOT stored" || bad "other-user token stored (rc ${rc})"
new_case governed "ok" "${TOK_EXPIRED}"
prod login --ui none; rc=$?
[ "${rc}" -eq 1 ] && [ ! -e "$(DROP)" ] && ok "already-expired token is NOT stored" || bad "expired token stored (rc ${rc})"
new_case governed "ok" "not-a-jwt"
prod login --ui none; rc=$?
[ "${rc}" -eq 1 ] && [ ! -e "$(DROP)" ] && ok "non-JWT token is NOT stored" || bad "garbage token stored (rc ${rc})"

# ── --if-needed ───────────────────────────────────────────────────────────────
new_case governed "ok" "${TOK_ME2}"
mkdir -p "${RUN}/hugmesh"; chmod 0700 "${RUN}/hugmesh"; printf '%s' "${TOK_ME}" > "$(DROP)"
prod login --if-needed --ui none; rc=$?
[ "${rc}" -eq 0 ] && [ "$(nreq)" -eq 0 ] && [ "$(cat "$(DROP)")" = "${TOK_ME}" ] \
    && ok "--if-needed honours a valid pre-dropped (greeter/PAM) token: no request, untouched" \
    || bad "--if-needed replaced a valid token (rc ${rc}, requests $(nreq))"
printf '%s' "${TOK_OTHER}" > "$(DROP)"
prod login --if-needed --ui none
[ "$(cat "$(DROP)")" = "${TOK_ME2}" ] && ok "--if-needed replaces a token that belongs to someone else" || bad "other-user drop kept"
printf '%s' "${TOK_ME_SOON}" > "$(DROP)"; rm -f "${SRV}/n" "${SRV}/requests.log"
prod login --if-needed --ui none
[ "$(cat "$(DROP)")" = "${TOK_ME2}" ] && ok "--if-needed replaces a token inside the 5-minute window" || bad "near-expiry drop kept"

# ── REFRESH ───────────────────────────────────────────────────────────────────
new_case governed "refresh_ok" "${TOK_ME2}" "${REFRESH_2}"
mkdir -p "${RUN}/hugmesh"; chmod 0700 "${RUN}/hugmesh"
printf '%s' "${TOK_ME_SOON}" > "$(DROP)"; printf '%s' "${REFRESH_1}" > "${RUN}/hugmesh/oidc-refresh"
prod refresh; rc=$?
[ "${rc}" -eq 0 ] && [ "$(cat "$(DROP)")" = "${TOK_ME2}" ] && [ "$(cat "${RUN}/hugmesh/oidc-refresh")" = "${REFRESH_2}" ] \
    && ok "refresh rotates the access token and the refresh token" || bad "refresh did not rotate (rc ${rc}: $(cat "${CASE}/out"))"
grep -q '"grant_type": "refresh_token"' "${SRV}/requests.log" && grep -q "${REFRESH_1}" "${SRV}/requests.log" \
    && ok "refresh sent grant_type=refresh_token with the held refresh token" || bad "refresh request wrong"
rm -f "${SRV}/requests.log"; printf '%s' "${TOK_ME}" > "$(DROP)"
prod refresh; [ "$(nreq)" -eq 0 ] && ok "refresh is a no-op while the token has life left" || bad "refresh ran with life left"

new_case governed "revoked"
mkdir -p "${RUN}/hugmesh"; chmod 0700 "${RUN}/hugmesh"
printf '%s' "${TOK_ME_SOON}" > "$(DROP)"; printf '%s' "${REFRESH_1}" > "${RUN}/hugmesh/oidc-refresh"
prod refresh; rc=$?
[ "${rc}" -eq 1 ] && [ ! -e "$(DROP)" ] && [ ! -e "${RUN}/hugmesh/oidc-refresh" ] \
    && ok "invalid_grant (revoked at the IdP) CLEARS the drop and the refresh token" || bad "revocation did not clear (rc ${rc})"

new_case governed "http500"
mkdir -p "${RUN}/hugmesh"; chmod 0700 "${RUN}/hugmesh"
printf '%s' "${TOK_ME_SOON}" > "$(DROP)"; printf '%s' "${REFRESH_1}" > "${RUN}/hugmesh/oidc-refresh"
prod refresh; rc=$?
[ "${rc}" -eq 1 ] && [ "$(cat "$(DROP)")" = "${TOK_ME_SOON}" ] && [ -e "${RUN}/hugmesh/oidc-refresh" ] \
    && ok "transient server error KEEPS the current token (mapper's exp check governs)" || bad "transient error cleared state (rc ${rc})"
new_case governed "ok"
mkdir -p "${RUN}/hugmesh"; chmod 0700 "${RUN}/hugmesh"; printf '%s' "${TOK_ME_SOON}" > "$(DROP)"
prod refresh; rc=$?
[ "${rc}" -eq 1 ] && [ "$(cat "$(DROP)")" = "${TOK_ME_SOON}" ] && ok "no refresh token: nothing to do, drop untouched" || bad "refresh without token rc ${rc}"

# ── LOGOUT / PAM ──────────────────────────────────────────────────────────────
new_case governed "ok"
mkdir -p "${RUN}/hugmesh"; printf 'a' > "$(DROP)"; printf 'b' > "${RUN}/hugmesh/oidc-refresh"
prod clear
[ ! -e "$(DROP)" ] && [ ! -e "${RUN}/hugmesh/oidc-refresh" ] && ok "clear removes drop + refresh token" || bad "clear left files"
mkdir -p "${RUN}/hugmesh"; printf 'a' > "$(DROP)"; printf 'b' > "${RUN}/hugmesh/oidc-refresh"
PAM_TYPE=open_session prod --pam; rc=$?
[ "${rc}" -eq 0 ] && [ -e "$(DROP)" ] && ok "--pam open_session is a no-op (a greeter drop survives)" || bad "--pam open_session touched the drop (rc ${rc})"
PAM_TYPE=close_session prod --pam; rc=$?
[ "${rc}" -eq 0 ] && [ ! -e "$(DROP)" ] && [ ! -e "${RUN}/hugmesh/oidc-refresh" ] && ok "--pam close_session clears, rc 0" || bad "--pam close_session rc ${rc}, drop $( [ -e "$(DROP)" ] && echo kept)"
rm -rf "${RUN}"; PAM_TYPE=close_session prod --pam; rc=$?
[ "${rc}" -eq 0 ] && ok "--pam close_session with the runtime dir already gone still exits 0" || bad "--pam failed a PAM stack (rc ${rc})"

# ── HARDENING ─────────────────────────────────────────────────────────────────
new_case governed "ok"
mkdir -p "${RUN}/hugmesh"; chmod 0700 "${RUN}/hugmesh"
printf 'VICTIM' > "${CASE}/victim"; ln -s "${CASE}/victim" "$(DROP)"
prod login --ui none; rc=$?
[ "${rc}" -eq 0 ] && [ "$(cat "${CASE}/victim")" = "VICTIM" ] && [ ! -L "$(DROP)" ] && [ "$(cat "$(DROP)")" = "${TOK_ME}" ] \
    && ok "a symlink planted at the drop is replaced, never followed" || bad "symlink followed or not replaced (rc ${rc}, victim: $(cat "${CASE}/victim"))"
new_case governed "ok"
XDG_RUNTIME_DIR="${RUN}" HSP_INSECURE_TEST=1 HSP_ISSUER="ftp://127.0.0.1:${PORT}" HSP_GOV_DIR="${GOVDIR}" \
    python3 "${PROD}" login --ui none > "${CASE}/out" 2>&1 < /dev/null; rc=$?
[ "${rc}" -eq 1 ] && [ ! -e "$(DROP)" ] && ok "a non-https issuer is refused" || bad "non-https issuer accepted (rc ${rc})"
if [ ! -e /etc/hugmesh/desktop-governance/desktop-sudo-mapper ] && [ ! -e /etc/hugmesh/desktop-governance/bearer-forward.sh ]; then
    new_case governed "ok"
    XDG_RUNTIME_DIR="${RUN}" HSP_ISSUER="http://127.0.0.1:${PORT}" HSP_GOV_DIR="${GOVDIR}" HSP_POLL_SCALE=0.05 \
        python3 "${PROD}" login --ui none > "${CASE}/out" 2>&1 < /dev/null; rc=$?
    [ "${rc}" -eq 0 ] && [ "$(nreq)" -eq 0 ] && [ ! -e "$(DROP)" ] \
        && ok "HSP_* overrides are ignored without HSP_INSECURE_TEST (real /etc gate, no request)" \
        || bad "override honoured without the gate (rc ${rc}, requests $(nreq))"
else
    ok "(skipped: this host is itself a governed image; override-ignored case needs an ungoverned /etc)"
fi

# transport guard, called directly: production (no HSP_INSECURE_TEST) takes https only
python3 - "${PROD}" <<'PY' && ok "production accepts only https issuer/endpoint URLs (http, file, ftp refused)" || bad "require_https lets a non-https URL through"
import importlib.machinery, importlib.util, os, sys
os.environ.pop("HSP_INSECURE_TEST", None)
loader = importlib.machinery.SourceFileLoader("hst", sys.argv[1])
spec = importlib.util.spec_from_loader("hst", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
assert m.require_https("https://id.acme.example/x") == "https://id.acme.example/x"
for bad in ("http://id.acme.example/x", "file:///etc/passwd", "ftp://h/x", "//h/x", ""):
    try:
        m.require_https(bad)
    except ValueError:
        continue
    sys.exit("accepted %r" % bad)
PY

# a transient network error (issuer unreachable) must KEEP the token, not clear it
new_case governed "ok"
mkdir -p "${RUN}/hugmesh"; chmod 0700 "${RUN}/hugmesh"
printf '%s' "${TOK_ME_SOON}" > "$(DROP)"; printf '%s' "${REFRESH_1}" > "${RUN}/hugmesh/oidc-refresh"
XDG_RUNTIME_DIR="${RUN}" HSP_INSECURE_TEST=1 HSP_ISSUER="http://127.0.0.1:1" HSP_GOV_DIR="${GOVDIR}" \
    timeout 60 python3 "${PROD}" refresh > "${CASE}/out" 2>&1 < /dev/null; rc=$?
[ "${rc}" -eq 1 ] && [ "$(cat "$(DROP)")" = "${TOK_ME_SOON}" ] && [ -e "${RUN}/hugmesh/oidc-refresh" ] \
    && ok "issuer unreachable: refresh KEEPS the token and the refresh token" || bad "unreachable issuer cleared state (rc ${rc})"

# ── CONTRACT: producer -> REAL deposit -> REAL mapper ─────────────────────────
GS_STUB="${WORK}/stub-bin"; mkdir -p "${GS_STUB}"
cat > "${GS_STUB}/getent" <<'SH'
#!/usr/bin/env bash
[ "$1" = "group" ] || exit 2
[ -f "${GROUP_STATE}" ] || exit 2
printf 'desktop-sudo:x:990:%s\n' "$(cat "${GROUP_STATE}")"
SH
cat > "${GS_STUB}/groupadd" <<'SH'
#!/usr/bin/env bash
: > "${GROUP_STATE}"
SH
cat > "${GS_STUB}/gpasswd" <<'SH'
#!/usr/bin/env bash
case "$1" in -a) printf '%s' "$2" > "${GROUP_STATE}" ;; -d) : > "${GROUP_STATE}" ;; esac
SH
chmod 0755 "${GS_STUB}"/*

contract_case() {  # $1=access token the issuer serves
    new_case governed "ok" "$1"
    UROOT="${CASE}/run-user"; mkdir -p "${UROOT}/1001"; chmod 0700 "${UROOT}/1001"
    RUN="${UROOT}/1001"
    prod login --ui none
    # the REAL deposit, rendered with the sandbox governance dir
    sed "s#/etc/hugmesh/desktop-governance#${GOVDIR}#g" "${DEP_TPL}" > "${CASE}/deposit.sh"
    XDG_RUNTIME_DIR="${RUN}" bash "${CASE}/deposit.sh"
    : > "${CASE}/group"
    GROUP_STATE="${CASE}/group" DSM_RUN_USER_ROOT="${UROOT}" DSM_JWKS_FILE="${WORK}/jwks.json" \
    DSM_CACHE_DIR="${CASE}/cache" DSM_UID_MAP="1001=${ME}" PATH="${GS_STUB}:${PATH}" \
    "${MAPPER}" > "${CASE}/mapper.log" 2>&1
}
contract_case "${TOK_ME}"
[ -f "${RUN}/hugmesh/oidc-token" ] && [ "$(cat "${RUN}/hugmesh/oidc-token")" = "${TOK_ME}" ] \
    && ok "contract: the REAL deposit picks up the producer's drop" || bad "contract: deposit did not pick up the drop"
[ "$(cat "${CASE}/group")" = "${ME}" ] \
    && ok "contract: the REAL mapper verifies the produced token and grants desktop-sudo" \
    || bad "contract: mapper did not grant (log: $(cat "${CASE}/mapper.log"))"
contract_case "${TOK_OTHER}"
[ ! -s "${CASE}/group" ] && [ ! -e "${RUN}/hugmesh/oidc-token" ] \
    && ok "contract: a token for another user never reaches the deposit or the group" || bad "contract: other-user token granted"

# ── deposit --clear vs --clear-all ───────────────────────────────────────────
new_case governed "ok"
mkdir -p "${RUN}/hugmesh"; printf 'S' > "$(DROP)"; printf 'D' > "${RUN}/hugmesh/oidc-token"; printf 'R' > "${RUN}/hugmesh/oidc-refresh"
sed "s#/etc/hugmesh/desktop-governance#${GOVDIR}#g" "${DEP_TPL}" > "${CASE}/deposit.sh"
XDG_RUNTIME_DIR="${RUN}" bash "${CASE}/deposit.sh" --clear
[ ! -e "${RUN}/hugmesh/oidc-token" ] && [ -e "$(DROP)" ] && [ -e "${RUN}/hugmesh/oidc-refresh" ] \
    && ok "deposit --clear removes only the deposit (a pre-session drop survives the start-of-session clear)" || bad "--clear scope wrong"
printf 'D' > "${RUN}/hugmesh/oidc-token"
XDG_RUNTIME_DIR="${RUN}" bash "${CASE}/deposit.sh" --clear-all
[ ! -e "${RUN}/hugmesh/oidc-token" ] && [ ! -e "$(DROP)" ] && [ ! -e "${RUN}/hugmesh/oidc-refresh" ] \
    && ok "deposit --clear-all removes deposit + drop + refresh token" || bad "--clear-all left files"

# ── WRAPPER: producer runs BEFORE the deposit; logout uses --clear-all ───────
wrapper_case() {  # $1=governed|ungoverned
    new_case "$1" "ok"
    HOMED="${CASE}/home"; mkdir -p "${HOMED}"
    : > "${CASE}/order"
    cat > "${GOVDIR}/hugmesh-sso-token" <<SH
#!/bin/sh
echo "producer \$*" >> "${CASE}/order"
SH
    cat > "${GOVDIR}/oidc-token-deposit.sh" <<SH
#!/bin/sh
echo "deposit \$*" >> "${CASE}/order"
SH
    cat > "${GOVDIR}/bearer-forward.sh" <<SH
#!/bin/sh
echo "forward \$*" >> "${CASE}/order"
SH
    chmod 0755 "${GOVDIR}"/hugmesh-sso-token "${GOVDIR}"/oidc-token-deposit.sh "${GOVDIR}"/bearer-forward.sh
    [ "$1" = "ungoverned" ] && rm -f "${GOVDIR}/bearer-forward.sh" "${GOVDIR}/desktop-sudo-mapper"
    sed "s#/etc/hugmesh/desktop-governance#${GOVDIR}#g" "${WRAP_TPL}" > "${CASE}/wrap.sh"
    XDG_RUNTIME_DIR="${RUN}" HOME="${HOMED}" bash "${CASE}/wrap.sh"
}
wrapper_case governed
prod_line="$(grep -n '^producer login --if-needed' "${CASE}/order" | head -1 | cut -d: -f1)"
dep_line="$(grep -n '^deposit $' "${CASE}/order" | head -1 | cut -d: -f1)"
fwd_line="$(grep -n '^forward $' "${CASE}/order" | head -1 | cut -d: -f1)"
[ -n "${prod_line}" ] && [ -n "${dep_line}" ] && [ -n "${fwd_line}" ] && [ "${prod_line}" -lt "${dep_line}" ] && [ "${dep_line}" -lt "${fwd_line}" ] \
    && ok "wrapper order: producer -> deposit -> bearer-forward" || bad "wrapper order wrong: $(tr '\n' '|' < "${CASE}/order")"
first="$(sed -n 1p "${CASE}/order")"
[ "${first}" = "deposit --clear" ] && ok "wrapper still clears the stale deposit FIRST (--clear, not --clear-all)" || bad "wrapper first call: ${first}"
grep -qF -- '--clear-all' "${HOMED}/.bash_logout" \
    && ok "logout hook uses deposit --clear-all (drop + refresh token die with the session)" || bad "logout hook does not use --clear-all"
wrapper_case ungoverned
[ ! -s "${CASE}/order" ] && ok "wrapper on an ungoverned image runs nothing (producer included)" || bad "ungoverned wrapper ran: $(tr '\n' '|' < "${CASE}/order")"

# ── INSTALL: session-install renders the producer ─────────────────────────────
new_case governed "ok"
KEYS="${CASE}/keys"; mkdir -p "${KEYS}"; cp -r "${TPL}" "${KEYS}/desktop-governance"
ROOT="${CASE}/root"; mkdir -p "${ROOT}/etc/hugmesh"; printf 'acme.example\n' > "${ROOT}/etc/hugmesh/domains"
sed -e "s#/etc/hugmesh#${ROOT}/etc/hugmesh#g" -e "s#/etc/flatpak#${ROOT}/etc/flatpak#g" \
    -e "s#/etc/xdg/autostart#${ROOT}/etc/xdg/autostart#g" "${INSTALL_TPL}" > "${CASE}/install.sh"
mkdir -p "${ROOT}/etc/hugmesh/desktop-governance"
KEYS_BASE="${KEYS}" bash "${CASE}/install.sh" > "${CASE}/install.out" 2>&1
RP="${ROOT}/etc/hugmesh/desktop-governance/hugmesh-sso-token"
[ -f "${RP}" ] && [ "$(mode "${RP}")" = "755" ] && ! grep -q '@@CLUSTER_DOMAIN@@' "${RP}" && grep -q 'https://id.acme.example' "${RP}" \
    && ok "session-install renders the producer (0755, domain substituted)" || bad "producer not rendered ($(tr '\n' '|' < "${CASE}/install.out"))"
rm -rf "${ROOT}/etc/hugmesh/desktop-governance"/* "${KEYS}/desktop-governance/sso"
mkdir -p "${ROOT}/etc/hugmesh/desktop-governance"
KEYS_BASE="${KEYS}" bash "${CASE}/install.sh" > "${CASE}/install.out" 2>&1
[ ! -e "${RP}" ] && [ -f "${ROOT}/etc/hugmesh/desktop-governance/hugmesh-desktop-sso-start.sh" ] && grep -q 'no token producer' "${CASE}/install.out" \
    && ok "a KEYS dir without sso/ still installs the rest and says the producer is missing" || bad "missing-sso case wrong"

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
