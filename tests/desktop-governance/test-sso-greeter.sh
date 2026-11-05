#!/usr/bin/env bash
# test-sso-greeter.sh — the greeter SSO login path (specs/usr/lib/hugmesh/sso-greeter
# behind specs/etc/pam.d/lightdm), executed for real.
#
# Headless, NO root, NO network, NO display. The issuer is a local fake speaking
# OIDC discovery + the RFC 8628 device grant and serving RS256 tokens this suite
# signed with openssl (the same shape test-sso-token-producer.sh uses). Account
# tools (useradd/usermod/gpasswd/getent/id) are PATH shims that keep passwd /
# shadow / group state under the case directory and record every call.
#
# Proves:
#   OFF        SSO_ENABLED=false => the greeter is told SSO is off, exit 1, no request.
#   UNREACH    issuer down => "SSO sign-in unavailable: ..." within seconds, exit 1.
#   ONLINE     empty password => device flow; code + URL shown; the RS256 token is
#              verified; the account is CREATED with audio/video/usb/plugdev and NO
#              wheel; the cache record is 0600 and holds no token; the token is
#              parked for the session (0600) and never printed; exit 0.
#   PRIVILEGE  wheel only with the admin role on an UNGOVERNED image; never on a
#              governed one; wheel REMOVED when the role is gone at the next login.
#   REFUSALS   token for another user / bad signature / expired / wrong issuer /
#              wrong audience / alg none => rejected, no account, no cache.
#   LOCAL      a local account (usable shadow hash) is never taken over: empty
#              password says so, a typed password is left to pam_unix (silent,
#              NO request); an unknown user with a typed password: no request.
#   OFFLINE    typed password + online approval sets the offline password; it then
#              signs in with the issuer DOWN (no request); wrong password fails;
#              the bound (offline_until) is enforced; `revoke` kills it;
#              access_denied at the IdP clears the record.
#   SESSION    pam-session open_session moves the parked token into
#              <runtime>/<uid>/hugmesh/oidc-token.src (0600, owner) and removes
#              the park; close_session removes a leftover park.
#   HINT       probe writes the hint (how to use SSO / SSO off / a first-boot
#              one-time password went to the console) and never a hash.
#   STACK      specs/etc/pam.d/lightdm, executed through libpam with the REAL
#              helper (pam_exec stdout + expose_authtok): a typed password reaches
#              the local path untouched, an empty password with the issuer down
#              shows the reason and fails, an empty password with the issuer up
#              signs in and `success=done` short-circuits a pam_deny local path.
#   MUTATION   five defects planted in a copy of the helper, each verified to have
#              changed the file, each caught by a check above.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER_SRC="${REPO}/specs/usr/lib/hugmesh/sso-greeter"
STACK_SRC="${REPO}/specs/etc/pam.d/lightdm"
for f in "${HELPER_SRC}" "${STACK_SRC}"; do
    [ -f "${f}" ] || { echo "  FAIL missing: ${f}"; exit 1; }
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

HELPER="${WORK}/sso-greeter"
cp "${HELPER_SRC}" "${HELPER}"; chmod 0755 "${HELPER}"
python3 -m py_compile "${HELPER}" 2>/dev/null && ok "helper compiles" || bad "helper does not compile"

# ── Key material + JWKS + minting (openssl RS256) ───────────────────────────
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${WORK}/key.pem" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${WORK}/rogue.pem" 2>/dev/null
MOD="$(openssl rsa -in "${WORK}/key.pem" -noout -modulus | sed 's/^Modulus=//')"
python3 - "${MOD}" > "${WORK}/jwks.json" <<'PY'
import base64, json, sys
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
print(json.dumps({"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": "t1",
                            "n": b64(bytes.fromhex(sys.argv[1])), "e": "AQAB"}]}))
PY
b64url(){ openssl base64 -A | tr '+/' '-_' | tr -d '='; }
mint() {  # $1=payload-json [$2=key.pem] [$3=header-json] -> signed JWT
    local h p s key="${2:-${WORK}/key.pem}"
    h="$(printf '%s' "${3:-{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"t1\"\}}" | b64url)"
    p="$(printf '%s' "$1" | b64url)"
    printf '%s.%s' "${h}" "${p}" > "${WORK}/si"
    openssl dgst -sha256 -sign "${key}" -out "${WORK}/sig.bin" "${WORK}/si"
    s="$(b64url < "${WORK}/sig.bin")"
    printf '%s.%s.%s' "${h}" "${p}" "${s}"
}
NOW="$(date +%s)"
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
        open(os.path.join(D, "requests.log"), "a").write("GET " + self.path + "\n")
        if self.path.endswith("/.well-known/openid-configuration"):
            return self.out(200, {"issuer": base, "device_authorization_endpoint": base + "/dev",
                                  "token_endpoint": base + "/tok", "jwks_uri": base + "/jwks"})
        if self.path.endswith("/jwks"):
            return self.out(200, json.loads(open(os.path.join(D, "jwks.json")).read()))
        self.out(404, {})
    def do_POST(self):
        base = "http://127.0.0.1:%d" % self.server.server_port
        f = dict(urllib.parse.parse_qsl(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()))
        open(os.path.join(D, "requests.log"), "a").write("POST " + self.path + " " + json.dumps(f, sort_keys=True) + "\n")
        if self.path == "/dev":
            return self.out(200, {"device_code": "DEVCODE123", "user_code": "ABCD-EFGH",
                                  "verification_uri": base + "/activate",
                                  "verification_uri_complete": base + "/activate?user_code=ABCD-EFGH",
                                  "expires_in": 60, "interval": 1})
        if self.path == "/tok":
            seq = rd("seq", "ok").split(",")
            n = int(rd("n", "0")); open(os.path.join(D, "n"), "w").write(str(n + 1))
            step = seq[min(n, len(seq) - 1)]
            if step == "pending":  return self.out(400, {"error": "authorization_pending"})
            if step == "slow_down": return self.out(400, {"error": "slow_down"})
            if step == "denied":   return self.out(400, {"error": "access_denied"})
            if step == "expired":  return self.out(400, {"error": "expired_token"})
            if step == "ok":
                return self.out(200, {"access_token": rd("access"), "token_type": "Bearer", "expires_in": 3600})
        self.out(404, {})
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "port"), "w").write(str(s.server_port))
s.serve_forever()
PY
cp "${WORK}/jwks.json" "${SRV}/jwks.json"
python3 "${WORK}/fake-issuer.py" "${SRV}" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "${SRV}/port" ] && break; sleep 0.1; done
PORT="$(cat "${SRV}/port" 2>/dev/null)"
[ -n "${PORT}" ] && ok "fake issuer up on 127.0.0.1:${PORT}" || { bad "fake issuer did not start"; exit 1; }
ISSUER="http://127.0.0.1:${PORT}"
DOWN="http://127.0.0.1:1"
payload(){ # $1=name [$2=roles-json] [$3=exp-offset] [$4=iss] [$5=aud]
    printf '{"iss":"%s","aud":%s,"exp":%s,"sub":"u-%s","name":"%s","roles":%s}' \
        "${4:-${ISSUER}}" "${5:-[\"hugmesh-desktop\"]}" "$((NOW + ${3:-3600}))" "$1" "$1" "${2:-[\"ROLE_USER\"]}"
}
TOK_ALICE="$(mint "$(payload alice)")"
TOK_ALICE_ADMIN="$(mint "$(payload alice '["ROLE_USER","desktop-admin"]')")"
TOK_BOB="$(mint "$(payload bob)")"
TOK_ROGUE="$(mint "$(payload alice)" "${WORK}/rogue.pem")"
TOK_EXPIRED="$(mint "$(payload alice '["ROLE_USER"]' -3600)")"
TOK_WRONG_ISS="$(mint "$(payload alice '["ROLE_USER"]' 3600 https://id.other.example)")"
TOK_WRONG_AUD="$(mint "$(payload alice '["ROLE_USER"]' 3600 "${ISSUER}" '["something-else"]')")"
TOK_NONE="$(mint "$(payload alice)" "${WORK}/key.pem" '{"alg":"none","typ":"JWT"}')"
MYUID="$(id -u)"; MYGID="$(id -g)"

# ── Per-case sandbox: conf, state, run, passwd/shadow, shims ────────────────
new_case() {  # $1=enabled true|false  $2=issuer  [$3=governed]
    CASE="$(mktemp -d "${WORK}/case.XXXXXX")"
    mkdir -p "${CASE}/bin" "${CASE}/state" "${CASE}/run" "${CASE}/runtime" "${CASE}/etc"
    chmod 0700 "${CASE}/state"
    GOV="${CASE}/no-gov"; [ "${3:-}" = governed ] && { GOV="${CASE}/gov"; mkdir -p "${GOV}"; }
    cat > "${CASE}/conf" <<EOF
SSO_ENABLED=$1
ISSUER=$2
CLIENT_ID=hugmesh-desktop
BRAND_TITLE=Acme Desktops
OFFLINE_MAX_AGE_DAYS=14
ADMIN_ROLE=desktop-admin
LOGIN_TIMEOUT=30
CONNECT_TIMEOUT=2
POSTURE=mesh
EOF
    printf 'root:x:0:0:root:/root:/bin/bash\n' > "${CASE}/etc/passwd"
    printf 'root:!:19000:0:99999:7:::\n' > "${CASE}/etc/shadow"
    : > "${CASE}/etc/groups"       # "user:g1,g2" per line
    : > "${CASE}/log"
    rm -f "${SRV}"/{requests.log,n,seq,access}
    printf 'ok' > "${SRV}/seq"; printf '%s' "${TOK_ALICE}" > "${SRV}/access"
    # shims (state lives under the case; every call is logged)
    cat > "${CASE}/bin/getent" <<EOF
#!/usr/bin/env bash
echo "getent \$*" >> "${CASE}/log"
case "\$1:\$2" in group:audio|group:video|group:usb|group:plugdev|group:wheel) echo "\$2:x:1:"; exit 0 ;; esac
exit 2
EOF
    cat > "${CASE}/bin/useradd" <<EOF
#!/usr/bin/env bash
echo "useradd \$*" >> "${CASE}/log"
g=""; while [ \$# -gt 1 ]; do case "\$1" in -G) g="\$2"; shift ;; -s|-c|-u) shift ;; esac; shift; done
n="\$1"
printf '%s:x:%s:%s:SSO user:/home/%s:/bin/bash\n' "\${n}" "${MYUID}" "${MYGID}" "\${n}" >> "${CASE}/etc/passwd"
printf '%s:!:19000:0:99999:7:::\n' "\${n}" >> "${CASE}/etc/shadow"
printf '%s:%s\n' "\${n}" "\${g}" >> "${CASE}/etc/groups"
EOF
    cat > "${CASE}/bin/id" <<EOF
#!/usr/bin/env bash
[ "\$1" = "-Gn" ] || exec /usr/bin/id "\$@"
sed -n "s/^\$2://p" "${CASE}/etc/groups" | tr ',' ' '
EOF
    cat > "${CASE}/bin/usermod" <<EOF
#!/usr/bin/env bash
echo "usermod \$*" >> "${CASE}/log"
[ "\$1" = "-aG" ] || exit 1
cur="\$(sed -n "s/^\$3://p" "${CASE}/etc/groups")"
sed -i "/^\$3:/d" "${CASE}/etc/groups"; printf '%s:%s\n' "\$3" "\${cur:+\${cur},}\$2" >> "${CASE}/etc/groups"
EOF
    cat > "${CASE}/bin/gpasswd" <<EOF
#!/usr/bin/env bash
echo "gpasswd \$*" >> "${CASE}/log"
[ "\$1" = "-d" ] || exit 1
cur="\$(sed -n "s/^\$2://p" "${CASE}/etc/groups" | tr ',' '\n' | grep -vx "\$3" | paste -sd, -)"
sed -i "/^\$2:/d" "${CASE}/etc/groups"; printf '%s:%s\n' "\$2" "\${cur}" >> "${CASE}/etc/groups"
EOF
    chmod +x "${CASE}/bin/"*
}
# add_local NAME [HASH] [LASTCHG] — a local account with a usable password hash.
add_local() {
    printf '%s:x:%s:%s:%s:/home/%s:/bin/bash\n' "$1" "${MYUID}" "${MYGID}" "$1" "$1" >> "${CASE}/etc/passwd"
    printf '%s:%s:%s:0:99999:7:::\n' "$1" "${2:-\$y\$j9T\$abc\$def}" "${3:-19000}" >> "${CASE}/etc/shadow"
    printf '%s:wheel,audio\n' "$1" >> "${CASE}/etc/groups"
}
# auth HELPER USER TYPED [PAM_TYPE] -> rc; stdout in $CASE/out, stderr in $CASE/err
auth() {
    local helper="$1" user="$2" typed="$3" ptype="${4:-auth}"
    printf '%s' "${typed}" | PATH="${CASE}/bin:${PATH}" PAM_USER="${user}" PAM_TYPE="${ptype}" \
        HSG_INSECURE_TEST=1 HSG_CONF="${CASE}/conf" HSG_STATE_DIR="${CASE}/state" HSG_RUN_DIR="${CASE}/run" \
        HSG_GOV_DIR="${GOV}" HSG_PASSWD="${CASE}/etc/passwd" HSG_SHADOW="${CASE}/etc/shadow" \
        HSG_RUNTIME_BASE="${CASE}/runtime" HSG_USERS_CREATED="${CASE}/users.created" HSG_POLL_SCALE=0.05 \
        timeout 60 python3 "${helper}" pam-auth > "${CASE}/out" 2> "${CASE}/err"
}
helper_cmd() {  # HELPER subcommand... (operator commands / pam-session), same seams
    local helper="$1"; shift
    PATH="${CASE}/bin:${PATH}" HSG_INSECURE_TEST=1 HSG_CONF="${CASE}/conf" HSG_STATE_DIR="${CASE}/state" \
        HSG_RUN_DIR="${CASE}/run" HSG_GOV_DIR="${GOV}" HSG_PASSWD="${CASE}/etc/passwd" HSG_SHADOW="${CASE}/etc/shadow" \
        HSG_RUNTIME_BASE="${CASE}/runtime" HSG_USERS_CREATED="${CASE}/users.created" \
        timeout 60 python3 "${helper}" "$@" > "${CASE}/out" 2> "${CASE}/err"
}
nreq(){ [ -f "${SRV}/requests.log" ] && wc -l < "${SRV}/requests.log" || echo 0; }
mode(){ stat -c '%a' "$1" 2>/dev/null; }
CACHE(){ echo "${CASE}/state/users/$1.json"; }
PARK(){ echo "${CASE}/run/handoff/${MYUID}"; }
no_secret_in_output() {  # the token (and any typed password) must never reach the greeter/log
    ! grep -qF "${TOK_ALICE}" "${CASE}/out" "${CASE}/err" 2>/dev/null \
    && ! grep -qF "${TOK_ALICE_ADMIN}" "${CASE}/out" "${CASE}/err" 2>/dev/null
}

echo "== greeter SSO helper =="

# ── OFF ─────────────────────────────────────────────────────────────────────
new_case false "${ISSUER}"
auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 1 ] && grep -q 'not enabled' "${CASE}/out" && [ "$(nreq)" -eq 0 ] \
    && ok "OFF: empty password => 'not enabled' on the greeter, rc 1, no request" \
    || bad "OFF: rc ${rc}, requests $(nreq), out: $(head -c 200 "${CASE}/out")"
auth "${HELPER}" alice "typed"; rc=$?
[ "${rc}" -eq 1 ] && [ ! -s "${CASE}/out" ] && ok "OFF: typed password => silent rc 1 (local path untouched)" \
    || bad "OFF: typed password rc ${rc} out='$(cat "${CASE}/out")'"

# ── UNREACHABLE ─────────────────────────────────────────────────────────────
new_case true "${DOWN}"
t0="$(date +%s)"; auth "${HELPER}" alice ""; rc=$?; t1="$(date +%s)"
[ "${rc}" -eq 1 ] && grep -q 'SSO sign-in unavailable: cannot reach 127.0.0.1' "${CASE}/out" && [ $((t1 - t0)) -le 10 ] \
    && ok "UNREACH: issuer down => reason on the greeter within $((t1 - t0))s, rc 1" \
    || bad "UNREACH: rc ${rc} in $((t1 - t0))s out: $(head -c 200 "${CASE}/out")"
grep -q 'no tailnet agent' "${CASE}/out" && ok "UNREACH: the reason names the tailnet state (no agent here)" || bad "UNREACH: no tailnet state in: $(cat "${CASE}/out")"
cat > "${CASE}/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
[ "$1" = status ] && { echo '{"BackendState":"NeedsLogin"}'; exit 0; }; exit 1
EOF
chmod +x "${CASE}/bin/tailscale"
auth "${HELPER}" alice ""
grep -q 'tailnet needs login' "${CASE}/out" && ok "UNREACH: with a tailnet agent present the reason reports its state (NeedsLogin)" || bad "UNREACH: tailnet state missing: $(cat "${CASE}/out")"

# ── ONLINE first sign-in: account created, least privilege, token parked ────
new_case true "${ISSUER}"
printf 'pending,slow_down,ok' > "${SRV}/seq"
auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 0 ] && ok "ONLINE: empty password + approval => rc 0" || bad "ONLINE: rc ${rc}; out: $(cat "${CASE}/out"); err: $(tail -3 "${CASE}/err")"
grep -q 'enter the code ABCD-EFGH' "${CASE}/out" && grep -q '/activate' "${CASE}/out" \
    && ok "ONLINE: the code and URL were shown on the greeter" || bad "ONLINE: code/URL missing: $(cat "${CASE}/out")"
grep -q '^useradd .* -G audio,video,usb,plugdev alice$' "${CASE}/log" \
    && ok "ONLINE: account created with audio,video,usb,plugdev and NO wheel" || bad "ONLINE: useradd line: $(grep useradd "${CASE}/log")"
grep -q '^alice:!:' "${CASE}/etc/shadow" && ok "ONLINE: the SSO-managed account has a LOCKED local password" || bad "ONLINE: shadow: $(grep alice "${CASE}/etc/shadow")"
[ "$(mode "$(CACHE alice)")" = 600 ] && [ "$(mode "${CASE}/state/users")" = 700 ] \
    && ok "ONLINE: cache record 0600 in a 0700 dir" || bad "ONLINE: cache modes $(mode "$(CACHE alice)") / $(mode "${CASE}/state/users")"
! grep -qF "${TOK_ALICE}" "$(CACHE alice)" && grep -q '"offline_until"' "$(CACHE alice)" && grep -q '"pin": null' "$(CACHE alice)" \
    && ok "ONLINE: the record holds the bound and NO token, NO offline password yet" || bad "ONLINE: record: $(cat "$(CACHE alice)")"
[ "$(mode "$(PARK)")" = 600 ] && [ "$(cat "$(PARK)")" = "${TOK_ALICE}" ] \
    && ok "ONLINE: verified token parked for the session (0600)" || bad "ONLINE: park: mode $(mode "$(PARK)")"
no_secret_in_output && ok "ONLINE: the token never reached stdout/stderr" || bad "ONLINE: token leaked to the greeter or the log"
grep -q 'GET /jwks' "${SRV}/requests.log" && [ -f "${CASE}/state/jwks.json" ] \
    && ok "ONLINE: JWKS fetched and cached last-good" || bad "ONLINE: JWKS not fetched/cached"
grep -q 'type an offline password next time' "${CASE}/out" && ok "ONLINE: the greeter explains how to enable offline sign-in" || bad "ONLINE: no offline hint: $(cat "${CASE}/out")"

# ── SESSION hand-off ────────────────────────────────────────────────────────
mkdir -p "${CASE}/runtime/${MYUID}"
helper_cmd "${HELPER}" pam-session; : # PAM_TYPE unset => no-op
[ -e "$(PARK)" ] && ok "SESSION: no PAM_TYPE => park untouched" || bad "SESSION: park consumed without open_session"
PAM_USER=alice PAM_TYPE=open_session helper_cmd "${HELPER}" pam-session; rc=$?
DROP="${CASE}/runtime/${MYUID}/hugmesh/oidc-token.src"
[ "${rc}" -eq 0 ] && [ "$(cat "${DROP}" 2>/dev/null)" = "${TOK_ALICE}" ] && [ "$(mode "${DROP}")" = 600 ] \
    && [ "$(mode "${CASE}/runtime/${MYUID}/hugmesh")" = 700 ] && [ ! -e "$(PARK)" ] \
    && ok "SESSION: open_session moved the token to <runtime>/<uid>/hugmesh/oidc-token.src (0600 in 0700) and removed the park" \
    || bad "SESSION: rc ${rc}, drop='$(head -c 20 "${DROP}" 2>/dev/null)' mode $(mode "${DROP}") park=$([ -e "$(PARK)" ] && echo present || echo gone)"
mkdir -p "${CASE}/run/handoff"; printf 'stale' > "$(PARK)"
PAM_USER=alice PAM_TYPE=close_session helper_cmd "${HELPER}" pam-session
[ ! -e "$(PARK)" ] && ok "SESSION: close_session removes a leftover park" || bad "SESSION: leftover park survived close_session"
printf 'old' > "$(PARK)"; touch -d '-20 minutes' "$(PARK)"
PAM_USER=alice PAM_TYPE=open_session helper_cmd "${HELPER}" pam-session
[ ! -e "$(PARK)" ] && [ "$(cat "${DROP}")" = "${TOK_ALICE}" ] && ok "SESSION: a stale park (>10 min) is discarded, not delivered" || bad "SESSION: stale park delivered or kept"

# ── PRIVILEGE: wheel only with the admin role, only ungoverned; re-synced ────
new_case true "${ISSUER}"
printf '%s' "${TOK_ALICE_ADMIN}" > "${SRV}/access"
auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 0 ] && grep -q '^useradd .* -G audio,video,usb,plugdev,wheel alice$' "${CASE}/log" \
    && ok "PRIVILEGE: desktop-admin role on an ungoverned image => wheel" || bad "PRIVILEGE: rc ${rc} useradd: $(grep useradd "${CASE}/log")"
grep -q '"desktop-admin"' "$(CACHE alice)" && ok "PRIVILEGE: roles recorded in the cache" || bad "PRIVILEGE: roles missing from the record"
rm -f "${SRV}/requests.log" "${SRV}/n"; printf '%s' "${TOK_ALICE}" > "${SRV}/access"
auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 0 ] && grep -q '^gpasswd -d alice wheel$' "${CASE}/log" && ! grep -q 'wheel' <(sed -n 's/^alice://p' "${CASE}/etc/groups") \
    && ok "PRIVILEGE: role gone at the next online sign-in => wheel removed" || bad "PRIVILEGE: wheel not removed: $(grep -E 'gpasswd|^alice' "${CASE}/log" "${CASE}/etc/groups")"
new_case true "${ISSUER}" governed
printf '%s' "${TOK_ALICE_ADMIN}" > "${SRV}/access"
auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 0 ] && grep -q '^useradd .* -G audio,video,usb,plugdev alice$' "${CASE}/log" \
    && ok "PRIVILEGE: GOVERNED image => no wheel even with the admin role (sudo is the desktop-sudo claim)" \
    || bad "PRIVILEGE governed: rc ${rc} useradd: $(grep useradd "${CASE}/log")"

# ── REFUSALS ────────────────────────────────────────────────────────────────
refused() {  # $1=label $2=token $3=expected-text
    new_case true "${ISSUER}"
    printf '%s' "$2" > "${SRV}/access"
    auth "${HELPER}" alice ""; rc=$?
    [ "${rc}" -eq 1 ] && grep -q "$3" "${CASE}/out" && ! grep -q useradd "${CASE}/log" && [ ! -e "$(CACHE alice)" ] && [ ! -e "$(PARK)" ] \
        && ok "REFUSE: $1 => rc 1 ('$3'), no account, no cache, no park" \
        || bad "REFUSE: $1 => rc ${rc}; out: $(cat "${CASE}/out"); useradd=$(grep -c useradd "${CASE}/log")"
}
refused "token for another user (bob)" "${TOK_BOB}" "name mismatch"
refused "signature from a rogue key" "${TOK_ROGUE}" "signature invalid"
refused "expired token" "${TOK_EXPIRED}" "token expired"
refused "wrong issuer" "${TOK_WRONG_ISS}" "issuer mismatch"
refused "wrong audience" "${TOK_WRONG_AUD}" "audience mismatch"
refused "alg=none" "${TOK_NONE}" "RS256"
new_case true "${ISSUER}"; printf 'denied' > "${SRV}/seq"
auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 1 ] && grep -q 'access_denied' "${CASE}/out" && ok "REFUSE: access_denied => rc 1 with the reason" || bad "REFUSE: access_denied rc ${rc}: $(cat "${CASE}/out")"
new_case true "${ISSUER}"; printf 'pending' > "${SRV}/seq"; sed -i 's/^LOGIN_TIMEOUT=.*/LOGIN_TIMEOUT=30/' "${CASE}/conf"
# the fake's expires_in is 60 and LOGIN_TIMEOUT floor is 30: the poll is scaled 0.05x
auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 1 ] && grep -q 'timed out' "${CASE}/out" && ok "REFUSE: never approved => bounded, 'timed out', rc 1" || bad "REFUSE: timeout rc ${rc}: $(cat "${CASE}/out")"
new_case true "${ISSUER}"
auth "${HELPER}" '../root' ""; rc=$?
[ "${rc}" -eq 1 ] && [ "$(nreq)" -eq 0 ] && ok "REFUSE: an invalid user name never reaches the issuer" || bad "REFUSE: invalid name rc ${rc} requests $(nreq)"
auth "${HELPER}" alice "" account; rc=$?
[ "${rc}" -eq 1 ] && [ "$(nreq)" -eq 0 ] && ok "REFUSE: PAM_TYPE other than auth => rc 1, nothing done" || bad "REFUSE: PAM_TYPE=account rc ${rc} requests $(nreq)"

# ── LOCAL accounts are never taken over ─────────────────────────────────────
new_case true "${ISSUER}"; add_local alice
auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 1 ] && grep -q 'local account' "${CASE}/out" && [ "$(nreq)" -eq 0 ] \
    && ok "LOCAL: empty password for a local account => told to use its password, NO request" || bad "LOCAL: rc ${rc} requests $(nreq): $(cat "${CASE}/out")"
auth "${HELPER}" alice "hunter2"; rc=$?
[ "${rc}" -eq 1 ] && [ ! -s "${CASE}/out" ] && [ "$(nreq)" -eq 0 ] \
    && ok "LOCAL: typed password for a local account => silent rc 1, NO request (pam_unix decides)" || bad "LOCAL: typed rc ${rc} out='$(cat "${CASE}/out")' requests $(nreq)"
! grep -q 'hunter2' "${CASE}/out" "${CASE}/err" && ok "LOCAL: the typed password never appears in any output" || bad "LOCAL: typed password leaked"
new_case true "${ISSUER}"
auth "${HELPER}" nobody-here "hunter2"; rc=$?
[ "${rc}" -eq 1 ] && [ "$(nreq)" -eq 0 ] && ! grep -q useradd "${CASE}/log" \
    && ok "LOCAL: unknown user + typed password => rc 1, no request, no account" || bad "LOCAL: unknown+typed rc ${rc} requests $(nreq)"

# ── OFFLINE password: set online, used offline, bounded, revocable ──────────
new_case true "${ISSUER}"
auth "${HELPER}" alice ""                         # first online sign-in (no pin)
auth "${HELPER}" alice "off-line-pw"; rc=$?       # typed + approval => pin set
[ "${rc}" -eq 0 ] && grep -q '"kdf": "scrypt"' "$(CACHE alice)" && grep -q 'now your offline password' "${CASE}/out" \
    && ok "OFFLINE: typed password + online approval => offline password set (scrypt), explained" || bad "OFFLINE: set rc ${rc}: $(cat "${CASE}/out")"
grep -q 'No offline password is set for alice yet' "${CASE}/out" && ok "OFFLINE: the greeter said this approval sets it" || bad "OFFLINE: missing 'sets it' line"
! grep -q 'off-line-pw' "$(CACHE alice)" "${CASE}/out" "${CASE}/err" && ok "OFFLINE: the offline password is stored only as a hash" || bad "OFFLINE: plaintext offline password found"
sed -i "s#^ISSUER=.*#ISSUER=${DOWN}#" "${CASE}/conf"; rm -f "${SRV}/requests.log" "$(PARK)"
auth "${HELPER}" alice "off-line-pw"; rc=$?
[ "${rc}" -eq 0 ] && grep -q 'offline password' "${CASE}/out" && [ "$(nreq)" -eq 0 ] \
    && ok "OFFLINE: issuer down + correct offline password => rc 0, NO request" || bad "OFFLINE: rc ${rc} requests $(nreq): $(cat "${CASE}/out")"
[ ! -e "$(PARK)" ] && ok "OFFLINE: an offline sign-in parks no token (there is none)" || bad "OFFLINE: a token was parked offline"
auth "${HELPER}" alice "wrong-pw"; rc=$?
[ "${rc}" -eq 1 ] && grep -q 'unavailable' "${CASE}/out" && ok "OFFLINE: wrong offline password offline => rc 1" || bad "OFFLINE: wrong pw rc ${rc}: $(cat "${CASE}/out")"
auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 1 ] && ok "OFFLINE: empty password offline => rc 1 (no silent cached sign-in)" || bad "OFFLINE: empty offline rc ${rc}"
python3 - "$(CACHE alice)" <<'PY'
import json, sys, time
p = sys.argv[1]; r = json.load(open(p)); r["offline_until"] = int(time.time()) - 5; json.dump(r, open(p, "w"))
PY
auth "${HELPER}" alice "off-line-pw"; rc=$?
[ "${rc}" -eq 1 ] && grep -q 'expired' "${CASE}/out" && ok "OFFLINE: past offline_until => rc 1, 'expired' on the greeter (the bound holds)" || bad "OFFLINE: expired rc ${rc}: $(cat "${CASE}/out")"
sed -i "s#^ISSUER=.*#ISSUER=${ISSUER}#" "${CASE}/conf"; rm -f "${SRV}/n"
auth "${HELPER}" alice "off-line-pw"; rc=$?
[ "${rc}" -eq 0 ] && python3 -c "import json,sys,time; r=json.load(open(sys.argv[1])); sys.exit(0 if r['offline_until'] > time.time()+13*86400 else 1)" "$(CACHE alice)" \
    && ok "OFFLINE: an online sign-in renews the bound (14 days)" || bad "OFFLINE: renew rc ${rc}"
helper_cmd "${HELPER}" status alice; grep -q 'pin=set' "${CASE}/out" && ok "OPERATOR: status shows the record (pin=set, no secret)" || bad "OPERATOR: status: $(cat "${CASE}/out")"
helper_cmd "${HELPER}" list; grep -q '^alice offline_until=' "${CASE}/out" && ok "OPERATOR: list names the record" || bad "OPERATOR: list: $(cat "${CASE}/out")"
helper_cmd "${HELPER}" revoke alice; rc=$?
[ "${rc}" -eq 0 ] && [ ! -e "$(CACHE alice)" ] && ok "OPERATOR: revoke removes the record" || bad "OPERATOR: revoke rc ${rc}"
sed -i "s#^ISSUER=.*#ISSUER=${DOWN}#" "${CASE}/conf"
auth "${HELPER}" alice "off-line-pw"; rc=$?
[ "${rc}" -eq 1 ] && ok "OFFLINE: after revoke the offline password no longer signs in" || bad "OFFLINE: revoked record still signs in"
new_case true "${ISSUER}"
auth "${HELPER}" alice ""; auth "${HELPER}" alice "pw1"; [ -e "$(CACHE alice)" ] || bad "OFFLINE/denied setup: no cache"
printf 'denied' > "${SRV}/seq"; rm -f "${SRV}/n"
auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 1 ] && [ ! -e "$(CACHE alice)" ] && ok "OFFLINE: access_denied at the IdP clears the offline record (fails closed)" || bad "OFFLINE: denied rc ${rc} cache=$([ -e "$(CACHE alice)" ] && echo kept || echo gone)"

# ── HINT ────────────────────────────────────────────────────────────────────
new_case true "${ISSUER}"
helper_cmd "${HELPER}" probe
H="${CASE}/run/hint"
grep -q 'Leave the password empty to sign in with Acme Desktops SSO (127.0.0.1)' "${H}" && ok "HINT: probe writes the SSO instruction with the brand and the issuer host" || bad "HINT: $(cat "${H}" 2>/dev/null)"
add_local fallback '$y$j9T$salt$hashhashhash' 0
helper_cmd "${HELPER}" probe
grep -q "'fallback' has a ONE-TIME password that the keyless first boot printed on the text console" "${H}" && grep -q 'Ctrl+Alt+F1' "${H}" \
    && ok "HINT: a first-boot one-time password (shadow lastchg 0) is announced with where to read it" || bad "HINT: one-time notice missing: $(cat "${H}")"
! grep -q 'hashhashhash' "${H}" && ok "HINT: the hash never appears in the hint" || bad "HINT: hash leaked"
touch "${CASE}/users.created"; helper_cmd "${HELPER}" probe
grep -q 'standalone first boot printed' "${H}" && ok "HINT: with users.created the notice names the standalone first boot" || bad "HINT: standalone wording missing"
new_case false "${ISSUER}"; helper_cmd "${HELPER}" probe
grep -q 'SSO sign-in is not enabled on this image' "${CASE}/run/hint" && ok "HINT: SSO off => the hint says so" || bad "HINT off: $(cat "${CASE}/run/hint")"

# ── STACK: the real /etc/pam.d/lightdm through libpam with the real helper ──
echo "== STACK: specs/etc/pam.d/lightdm executed through libpam =="
PAMPY="${WORK}/pam.py"
cat > "${PAMPY}" <<'PY'
import ctypes, ctypes.util, os, sys
confdir, service, answer, envfile = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
libpam = ctypes.CDLL(ctypes.util.find_library("pam") or "libpam.so.0")
libc = ctypes.CDLL(None); libc.calloc.restype = ctypes.c_void_p; libc.strdup.restype = ctypes.c_void_p
class Msg(ctypes.Structure): _fields_ = [("style", ctypes.c_int), ("msg", ctypes.c_char_p)]
class Resp(ctypes.Structure): _fields_ = [("resp", ctypes.c_void_p), ("rc", ctypes.c_int)]
CONV = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.POINTER(Msg)),
                        ctypes.POINTER(ctypes.POINTER(Resp)), ctypes.c_void_p)
class Conv(ctypes.Structure): _fields_ = [("conv", CONV), ("appdata", ctypes.c_void_p)]
@CONV
def conv(n, msgs, resp, app):
    arr = ctypes.cast(libc.calloc(n, ctypes.sizeof(Resp)), ctypes.POINTER(Resp))
    for i in range(n):
        m = msgs[i].contents
        print("MSG style=%d %s" % (m.style, (m.msg or b"").decode("utf-8", "replace")), flush=True)
        if m.style in (1, 2):
            arr[i].resp = libc.strdup(answer.encode())
    resp[0] = arr
    return 0
h = ctypes.c_void_p(); c = Conv(conv, None)
libpam.pam_start_confdir.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(Conv),
                                     ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
rc = libpam.pam_start_confdir(service.encode(), b"alice", ctypes.byref(c), confdir.encode(), ctypes.byref(h))
if rc != 0:
    sys.exit(100)
# pam_exec gives its child the PAM environment, not ours: pass the seams through it.
for line in open(envfile):
    line = line.rstrip("\n")
    if line:
        libpam.pam_putenv(h, line.encode())
rc = libpam.pam_authenticate(h, 0)
libpam.pam_end(h, rc)
print("RC", rc)
PY
stack() {  # $1=label $2=local-stand-in (pam_permit.so|pam_deny.so) -> confdir
    local d="${CASE}/cd-$1"; mkdir -p "${d}"
    sed -e "s#/usr/lib/hugmesh/sso-greeter#${HELPER}#g" -e "s#/run/hugmesh/sso-greeter/hint#${CASE}/run/hint#" \
        -e "s#include\t\tsystem-local-login#required\t$2#" "${STACK_SRC}" > "${d}/lightdm"
    echo "${d}"
}
envfile() {
    cat > "${CASE}/env" <<EOF
PATH=${CASE}/bin:${PATH}
HSG_INSECURE_TEST=1
HSG_CONF=${CASE}/conf
HSG_STATE_DIR=${CASE}/state
HSG_RUN_DIR=${CASE}/run
HSG_GOV_DIR=${GOV}
HSG_PASSWD=${CASE}/etc/passwd
HSG_SHADOW=${CASE}/etc/shadow
HSG_RUNTIME_BASE=${CASE}/runtime
HSG_USERS_CREATED=${CASE}/users.created
HSG_POLL_SCALE=0.05
EOF
}
new_case true "${ISSUER}"; envfile
PO="${CASE}/pam.out"
python3 "${PAMPY}" "$(stack probe pam_permit.so)" lightdm "x" "${CASE}/env" > "${PO}" 2>/dev/null
if grep -q '^RC 0$' "${PO}"; then
    # (a) a typed password: the helper steps aside, the local stand-in (permit) decides
    new_case true "${ISSUER}"; add_local alice; envfile
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(stack a pam_permit.so)" lightdm "hunter2" "${CASE}/env" > "${PO}" 2>/dev/null
    grep -q '^RC 0$' "${PO}" && grep -q 'MSG style=1 Password: ' "${PO}" && [ "$(nreq)" -eq 0 ] \
        && ok "STACK: typed password => prompted once, helper silent, local path authenticates (rc 0), no request" \
        || bad "STACK (a): $(tr '\n' '|' < "${PO}") requests $(nreq)"
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(stack a2 pam_deny.so)" lightdm "hunter2" "${CASE}/env" > "${PO}" 2>/dev/null
    grep -q '^RC [1-9]' "${PO}" && ok "STACK: typed password with a denying local path => still denied (helper grants nothing)" \
        || bad "STACK (a2): $(tr '\n' '|' < "${PO}")"
    # (b) empty password, issuer down: reason shown, denied
    new_case true "${DOWN}"; envfile; helper_cmd "${HELPER}" probe
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(stack b pam_deny.so)" lightdm "" "${CASE}/env" > "${PO}" 2>/dev/null
    grep -q 'MSG style=4 SSO sign-in unavailable: cannot reach' "${PO}" && grep -q '^RC [1-9]' "${PO}" \
        && ok "STACK: empty password + issuer down => 'SSO sign-in unavailable' shown as PAM text, denied" \
        || bad "STACK (b): $(tr '\n' '|' < "${PO}")"
    grep -q 'MSG style=4 Leave the password empty to sign in with Acme Desktops SSO' "${PO}" \
        && ok "STACK: the hint (pam_echo) reaches the conversation before the prompt" || bad "STACK (b): hint missing: $(tr '\n' '|' < "${PO}")"
    # (c) empty password, issuer up: signed in; success=done never reaches pam_deny
    new_case true "${ISSUER}"; envfile
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(stack c pam_deny.so)" lightdm "" "${CASE}/env" > "${PO}" 2>/dev/null
    grep -q '^RC 0$' "${PO}" && grep -q 'MSG style=4 SSO sign-in for alice: open' "${PO}" \
        && grep -q 'MSG style=4 Signed in as alice via SSO' "${PO}" && grep -q useradd "${CASE}/log" \
        && ok "STACK: empty password + approval => code shown, signed in, success=done short-circuits a denying local path (rc 0)" \
        || bad "STACK (c): $(tr '\n' '|' < "${PO}")"
    ! grep -qF "${TOK_ALICE}" "${PO}" && ok "STACK: the token never reached the conversation" || bad "STACK: token in the conversation"
elif [ "${HUGMESH_REQUIRE_LIBPAM:-0}" = 1 ]; then
    bad "libpam execution unavailable here (probe='${probe_out}') and HUGMESH_REQUIRE_LIBPAM=1"
else
    echo "  NOTE libpam execution layer not runnable here (probe='$(printf '%s' "${probe_out}" | tail -1)'); the helper checks above are the gate"
fi

# ── MUTATION battery: each defect planted in a copy must be caught ──────────
echo "== MUTATION: planted defects in a helper copy =="
mutate() {  # $1=label $2=sed-expr -> path of the mutated copy (fails if nothing changed)
    local m="${WORK}/mut-$1"
    sed -e "$2" "${HELPER}" > "${m}"; chmod 0755 "${m}"
    if cmp -s "${HELPER}" "${m}"; then bad "MUTATION $1: the plant changed nothing (vacuous control)"; return 1; fi
    echo "${m}"
}
if m="$(mutate sig 's/if not any(rsa_verify(k, signing_input, sig) for k in keys):/if False:/')"; then
    new_case true "${ISSUER}"; printf '%s' "${TOK_ROGUE}" > "${SRV}/access"
    auth "${m}" alice ""; rc=$?
    [ "${rc}" -eq 0 ] && ok "MUTATION sig: a helper without the signature check accepts the rogue token — the REFUSE check above catches it" \
        || bad "MUTATION sig: the mutated helper still refused (rc ${rc}); the signature check is not what refuses rogue tokens"
fi
if m="$(mutate name 's/if not isinstance(name, str) or name != username:/if False:/')"; then
    new_case true "${ISSUER}"; printf '%s' "${TOK_BOB}" > "${SRV}/access"
    auth "${m}" alice ""; rc=$?
    [ "${rc}" -eq 0 ] && ok "MUTATION name: without the name binding bob's token signs alice in — the REFUSE check catches it" \
        || bad "MUTATION name: mutated helper still refused (rc ${rc})"
fi
if m="$(mutate bound 's/if rec.get("pin") and now < float(rec.get("offline_until", 0)):/if rec.get("pin"):/')"; then
    new_case true "${ISSUER}"; auth "${HELPER}" alice ""; auth "${HELPER}" alice "pw1"
    python3 -c "import json,sys,time; p=sys.argv[1]; r=json.load(open(p)); r['offline_until']=int(time.time())-5; json.dump(r,open(p,'w'))" "$(CACHE alice)"
    sed -i "s#^ISSUER=.*#ISSUER=${DOWN}#" "${CASE}/conf"
    auth "${m}" alice "pw1"; rc=$?
    [ "${rc}" -eq 0 ] && ok "MUTATION bound: without the offline_until check an expired record signs in — the OFFLINE bound check catches it" \
        || bad "MUTATION bound: mutated helper still refused (rc ${rc})"
fi
if m="$(mutate local 's/if local and rec is None:/if False:/')"; then
    new_case true "${ISSUER}"; add_local alice
    auth "${m}" alice ""; rc=$?
    [ "${rc}" -eq 0 ] && ok "MUTATION local: without the local-account guard SSO takes over a local account — the LOCAL check catches it" \
        || bad "MUTATION local: mutated helper still refused (rc ${rc})"
fi
if m="$(mutate pin 's/^def pin_matches(rec, password):/def pin_matches(rec, password):\n    return True/')"; then
    new_case true "${ISSUER}"; auth "${HELPER}" alice ""; auth "${HELPER}" alice "pw1"; sed -i "s#^ISSUER=.*#ISSUER=${DOWN}#" "${CASE}/conf"
    auth "${m}" alice "wrong"; rc=$?
    [ "${rc}" -eq 0 ] && ok "MUTATION pin: a helper that accepts any offline password signs in with a wrong one — the OFFLINE wrong-password check catches it" \
        || bad "MUTATION pin: mutated helper still refused (rc ${rc})"
fi

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
