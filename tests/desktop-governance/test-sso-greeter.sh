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
#   FAILNOTE   a refused attempt leaves "Sign-in as 'X' failed ..." at the top of the
#              hint the greeter's RETRY shows first (lightdm-gtk-greeter 2.0.9
#              prints nothing of its own while our INFO hint is on screen): pam-auth
#              arms it, a local success takes it down through `pam-ok` after the
#              include, an SSO success inside the helper; through the REAL pambase
#              chain a wrong password keeps it, a right one or SSO does not; plus
#              5 planted defects (helper and stack), each caught.
#   HINT       probe writes the hint (how to use SSO / SSO off / a first-boot
#              one-time password went to the console) and never a hash.
#   STACK      specs/etc/pam.d/lightdm, executed through libpam with the REAL
#              helper (pam_exec stdout + expose_authtok): a typed password reaches
#              the local path untouched, an empty password with the issuer down
#              shows the reason and fails, an empty password with the issuer up
#              signs in and `success=done` short-circuits a pam_deny local path.
#   ORDER      the stack over #860's wired include chain (system-local-login ->
#              system-login -> system-auth with pam_ecryptfs after the LAST line):
#              local login prompted once and reaches the unwrap line; SSO ends at
#              success=done before it; the pre-#860 placement breaks local login.
#   ACCOUNTS   root / daemon / an account SSO did not create are refused before any
#              request; the managed registry outlives `revoke`; a replaced uid is
#              refused.
#   NETWORK    a sys.addaudithook logs every connect / lookup to ANY host: zero on
#              the standalone conf (every subcommand), zero with SSO disabled but
#              an issuer set, zero for probe and typed passwords with SSO on; the
#              opt-in sign-in IS logged (control).
#   CONFIGURE  the runtime admin surface: enable / issuer / offline bound / admin
#              role / disable, in place, no network; refusals leave the conf alone.
#   MUTATION   five defects planted in a copy of the helper, each verified to have
#              changed the file, each caught by a check above.
#   GUARDS     the named guards (no wheel without the admin role, no token in
#              output, cache expiry, fallback with a visible reason, zero network
#              until opt-in, no system/unmanaged account, config validation) as
#              check functions: green on the real helper, red on 18 planted
#              defects (each verified to change the file and still parse), plus
#              3 planted control-flag defects in the PAM stack (libpam).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER_SRC="${REPO}/specs/usr/lib/hugmesh/sso-greeter"
STACK_SRC="${REPO}/specs/etc/pam.d/lightdm"
for f in "${HELPER_SRC}" "${STACK_SRC}"; do
    [ -f "${f}" ] || { echo "  FAIL missing: ${f}"; exit 1; }
done
command -v python3 >/dev/null || { echo "  FAIL python3 required"; exit 1; }
command -v openssl >/dev/null || { echo "  FAIL openssl required"; exit 1; }

# The libpam legs (STACK, PAM ORDER, the stack battery) are REQUIRED on the
# Debian CI job (python:3.12-slim ships libpam-modules) and with
# HUGMESH_REQUIRE_LIBPAM=1; elsewhere (the Alpine job has no linux-pam) they NOTE.
if [ "${GITHUB_ACTIONS:-}" = true ] && [ -f /etc/debian_version ]; then HUGMESH_REQUIRE_LIBPAM=1; fi

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
# The uid the account shims hand out. The helper never signs in to uid 0 (nor
# below UID_MIN), so under root (CI containers) the test accounts get 4242,
# which root can chown to; otherwise our own uid, which we can.
TUID="${MYUID}"; [ "${TUID}" -eq 0 ] && TUID=4242
# UID_MIN the helper is told (HSG_UID_MIN): 1 so a CI runner's own uid counts as a
# person's; the SYSTEM case sets 1000 explicitly.
UIDMIN=1
# Network audit: every socket connect / name lookup the helper makes is logged
# (sys.addaudithook in a sitecustomize on PYTHONPATH) to ${CASE}/net.log. This
# sees ANY destination, not only the fake issuer.
mkdir -p "${WORK}/netaudit"
cat > "${WORK}/netaudit/sitecustomize.py" <<'NETPY'
import os, sys
_LOG = os.environ.get("HSG_NETLOG", "")
if _LOG:
    def _hook(event, args):
        if event in ("socket.connect", "socket.getaddrinfo", "socket.gethostbyname", "socket.sendto"):
            try:
                with open(_LOG, "a") as f:
                    f.write("%s %r\n" % (event, args[1:] if event == "socket.connect" else args[:2]))
            except OSError:
                pass
    sys.addaudithook(_hook)
NETPY

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
printf '%s:x:%s:%s:SSO user:/home/%s:/bin/bash\n' "\${n}" "${TUID}" "${MYGID}" "\${n}" >> "${CASE}/etc/passwd"
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
    printf '%s:x:%s:%s:%s:/home/%s:/bin/bash\n' "$1" "${TUID}" "${MYGID}" "$1" "$1" >> "${CASE}/etc/passwd"
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
        HSG_UID_MIN="${UIDMIN}" HSG_NETLOG="${CASE}/net.log" PYTHONPATH="${WORK}/netaudit" \
        timeout 60 python3 "${helper}" pam-auth > "${CASE}/out" 2> "${CASE}/err"
}
helper_cmd() {  # HELPER subcommand... (operator commands / pam-session), same seams
    local helper="$1"; shift
    PATH="${CASE}/bin:${PATH}" HSG_INSECURE_TEST=1 HSG_CONF="${CASE}/conf" HSG_STATE_DIR="${CASE}/state" \
        HSG_RUN_DIR="${CASE}/run" HSG_GOV_DIR="${GOV}" HSG_PASSWD="${CASE}/etc/passwd" HSG_SHADOW="${CASE}/etc/shadow" \
        HSG_RUNTIME_BASE="${CASE}/runtime" HSG_USERS_CREATED="${CASE}/users.created" \
        HSG_UID_MIN="${UIDMIN}" HSG_NETLOG="${CASE}/net.log" PYTHONPATH="${WORK}/netaudit" \
        timeout 60 python3 "${helper}" "$@" > "${CASE}/out" 2> "${CASE}/err"
}
nreq(){ [ -f "${SRV}/requests.log" ] && wc -l < "${SRV}/requests.log" || echo 0; }
mode(){ stat -c '%a' "$1" 2>/dev/null; }
CACHE(){ echo "${CASE}/state/users/$1.json"; }
PARK(){ echo "${CASE}/run/handoff/${TUID}"; }
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
# The approval page asks a fresh phone/browser to sign in to the IdP (#958
# follow-up): the greeter must say so, say MFA applies, and say the SSO password
# goes on that page and never into this greeter's password box.
grep -q 'on your phone or any browser' "${CASE}/out" && grep -q 'Sign in to 127.0.0.1 there if it asks (MFA applies), then approve' "${CASE}/out" \
    && grep -q 'SSO password only on that page, never on this screen' "${CASE}/out" \
    && ok "ONLINE: the greeter says where to sign in (phone/browser, IdP page, MFA) and never here" \
    || bad "ONLINE: sign-in guidance missing: $(cat "${CASE}/out")"
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
mkdir -p "${CASE}/runtime/${TUID}"
helper_cmd "${HELPER}" pam-session; : # PAM_TYPE unset => no-op
[ -e "$(PARK)" ] && ok "SESSION: no PAM_TYPE => park untouched" || bad "SESSION: park consumed without open_session"
PAM_USER=alice PAM_TYPE=open_session helper_cmd "${HELPER}" pam-session; rc=$?
DROP="${CASE}/runtime/${TUID}/hugmesh/oidc-token.src"
[ "${rc}" -eq 0 ] && [ "$(cat "${DROP}" 2>/dev/null)" = "${TOK_ALICE}" ] && [ "$(mode "${DROP}")" = 600 ] \
    && [ "$(mode "${CASE}/runtime/${TUID}/hugmesh")" = 700 ] && [ ! -e "$(PARK)" ] \
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

# ── CANCEL: the greeter goes away mid-flow (lightdm kills the session child) ─
# The helper is orphaned (reparented); the approval that then arrives must NOT
# create an account, a cache record or a parked token for a session nobody
# started. The helper is started from a subshell that lives 0.3 s and then
# exits, so its parent changes while it is polling; the issuer answers ok on
# the 12th poll (0.05 s each), after the parent is gone.
new_case true "${ISSUER}"; printf 'pending,pending,pending,pending,pending,pending,pending,pending,pending,pending,pending,ok' > "${SRV}/seq"
( printf '' | PATH="${CASE}/bin:${PATH}" PAM_USER=alice PAM_TYPE=auth \
    HSG_INSECURE_TEST=1 HSG_CONF="${CASE}/conf" HSG_STATE_DIR="${CASE}/state" HSG_RUN_DIR="${CASE}/run" \
    HSG_GOV_DIR="${GOV}" HSG_PASSWD="${CASE}/etc/passwd" HSG_SHADOW="${CASE}/etc/shadow" \
    HSG_RUNTIME_BASE="${CASE}/runtime" HSG_USERS_CREATED="${CASE}/users.created" HSG_POLL_SCALE=0.05 \
    HSG_UID_MIN="${UIDMIN}" python3 "${HELPER}" pam-auth > "${CASE}/out" 2> "${CASE}/err" & sleep 0.3 )   # the subshell IS the parent for 0.3 s, like pam_exec's session child until Cancel; no `timeout` wrapper (it would stay the parent)
for _ in $(seq 1 100); do grep -q 'greeter gone\|Signed in' "${CASE}/err" "${CASE}/out" 2>/dev/null && break; sleep 0.1; done
sleep 0.5
grep -q 'greeter gone (cancelled)' "${CASE}/err" && ! grep -q useradd "${CASE}/log" && [ ! -e "$(CACHE alice)" ] && [ ! -e "$(PARK)" ] \
    && ok "CANCEL: an orphaned helper abandons the flow — no account, no cache, no parked token" \
    || bad "CANCEL: err='$(tail -2 "${CASE}/err" | tr '\n' '|')' useradd=$(grep -c useradd "${CASE}/log") cache=$([ -e "$(CACHE alice)" ] && echo yes || echo no) park=$([ -e "$(PARK)" ] && echo yes || echo no)"

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
grep -q 'SSO sign-in is not enabled on this device' "${CASE}/run/hint" && grep -q 'sso-greeter configure' "${CASE}/run/hint" \
    && ok "HINT: SSO off => the hint says so and how an administrator turns it on" || bad "HINT off: $(cat "${CASE}/run/hint")"

# ── FAILNOTE: a refused attempt is announced on the retry ─────────────────────
echo "== FAILNOTE: the retry says the last attempt failed =="
FAILRE="^Sign-in as 'alice' failed: the password was not accepted"
new_case true "${ISSUER}"; add_local alice
auth "${HELPER}" alice "wrong"; rc=$?
[ "${rc}" -eq 1 ] && head -1 "${CASE}/run/hint" | grep "${FAILRE}, or SSO did not finish. Try again.$" >/dev/null \
    && ok "FAILNOTE: a typed password handed to the local path ARMS the notice, first line of the hint, naming the user" \
    || bad "FAILNOTE arm: rc ${rc} hint: $(cat "${CASE}/run/hint" 2>/dev/null)"
grep -q 'Leave the password empty to sign in with Acme Desktops SSO' "${CASE}/run/hint" \
    && ok "FAILNOTE: …and the usual instructions stay below it" || bad "FAILNOTE: the instructions were dropped: $(cat "${CASE}/run/hint")"
PAM_USER=alice PAM_TYPE=setcred helper_cmd "${HELPER}" pam-ok
grep -q "${FAILRE}" "${CASE}/run/hint" && ok "FAILNOTE: pam-ok outside the auth phase changes nothing" || bad "FAILNOTE: pam-ok disarmed on PAM_TYPE=setcred"
PAM_USER=alice PAM_TYPE=auth helper_cmd "${HELPER}" pam-ok; rc=$?
[ "${rc}" -eq 0 ] && ! grep -q 'failed' "${CASE}/run/hint" && grep -q 'Leave the password empty' "${CASE}/run/hint" && [ ! -e "${CASE}/run/failed" ] \
    && ok "FAILNOTE: pam-ok (a local success) disarms it, drops the armed state and exits 0" || bad "FAILNOTE pam-ok: rc ${rc} state: $(ls "${CASE}/run") hint: $(cat "${CASE}/run/hint")"
auth "${HELPER}" alice "wrong"; helper_cmd "${HELPER}" probe
! grep -q 'failed' "${CASE}/run/hint" && ok "FAILNOTE: a new greeter (probe) starts clean" || bad "FAILNOTE: probe kept the notice: $(cat "${CASE}/run/hint")"
new_case true "${ISSUER}"; auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 0 ] && ! grep -q 'failed' "${CASE}/run/hint" && [ ! -e "${CASE}/run/failed" ] \
    && ok "FAILNOTE: an SSO sign-in (rc 0) leaves no notice and no armed state behind" || bad "FAILNOTE SSO: rc ${rc} state: $(ls "${CASE}/run") hint: $(cat "${CASE}/run/hint")"
new_case false "${ISSUER}"; add_local alice; auth "${HELPER}" alice "wrong"
head -1 "${CASE}/run/hint" | grep "${FAILRE}. Try again.$" >/dev/null \
    && ok "FAILNOTE: with SSO off the notice does not mention SSO" || bad "FAILNOTE off: $(cat "${CASE}/run/hint")"
new_case true "${ISSUER}"; auth "${HELPER}" "Bad/Name" "x"
head -1 "${CASE}/run/hint" | grep "^Sign-in failed: the password was not accepted" >/dev/null && ! grep -q 'Bad/Name' "${CASE}/run/hint" \
    && ok "FAILNOTE: an invalid user name is never echoed into the hint" || bad "FAILNOTE badname: $(cat "${CASE}/run/hint")"
# WHOSE notice: `pam-hint` (the auth line before pam_echo) recomposes the hint for
# the conversation that is starting, so only the refused user's own retry shows it.
new_case true "${ISSUER}"; add_local alice; add_local bob; auth "${HELPER}" alice "wrong"
[ "$(stat -c %a "${CASE}/run/hint" 2>/dev/null)" = 600 ] && [ "$(stat -c %a "${CASE}/run/failed" 2>/dev/null)" = 600 ] \
    && ok "FAILNOTE: the hint and the armed state are 0600 (they name the refused user; pam_echo reads as root)" \
    || bad "FAILNOTE modes: hint $(stat -c %a "${CASE}/run/hint" 2>/dev/null) failed $(stat -c %a "${CASE}/run/failed" 2>/dev/null)"
PAM_USER=bob PAM_TYPE=auth helper_cmd "${HELPER}" pam-hint; rc=$?
[ "${rc}" -eq 0 ] && ! grep -q 'failed' "${CASE}/run/hint" && ! grep -q 'alice' "${CASE}/run/hint" && grep -q 'Leave the password empty' "${CASE}/run/hint" \
    && ok "FAILNOTE: picking ANOTHER user (bob) after alice was refused shows bob the plain hint, never alice's notice" \
    || bad "FAILNOTE whose (bob): rc ${rc} hint: $(cat "${CASE}/run/hint" 2>/dev/null)"
PAM_USER='' PAM_TYPE=auth helper_cmd "${HELPER}" pam-hint
! grep -q 'failed' "${CASE}/run/hint" && ok "FAILNOTE: …nor does a conversation that has no user name yet" || bad "FAILNOTE whose (no user): $(cat "${CASE}/run/hint" 2>/dev/null)"
PAM_USER=alice PAM_TYPE=auth helper_cmd "${HELPER}" pam-hint
head -1 "${CASE}/run/hint" | grep "${FAILRE}" >/dev/null \
    && ok "FAILNOTE: …while alice's own retry still leads with it" || bad "FAILNOTE whose (alice): $(cat "${CASE}/run/hint" 2>/dev/null)"
helper_cmd "${HELPER}" probe; PAM_USER=alice PAM_TYPE=auth helper_cmd "${HELPER}" pam-hint
! grep -q 'failed' "${CASE}/run/hint" && [ ! -e "${CASE}/run/failed" ] \
    && ok "FAILNOTE: after a new greeter (probe) not even alice's next conversation brings it back" || bad "FAILNOTE probe/state: $(cat "${CASE}/run/hint" 2>/dev/null)"
new_case true "${ISSUER}"; add_local bob; auth "${HELPER}" "Bad/Name" "x"
PAM_USER=bob PAM_TYPE=auth helper_cmd "${HELPER}" pam-hint
head -1 "${CASE}/run/hint" | grep "^Sign-in failed: the password was not accepted" >/dev/null && ! grep -q 'Bad/Name' "${CASE}/run/hint" \
    && ok "FAILNOTE: an attempt with no valid name arms an UNNAMED notice, which names nobody and is shown to whoever comes next" \
    || bad "FAILNOTE unnamed: $(cat "${CASE}/run/hint" 2>/dev/null)"

# ── STACK: the real /etc/pam.d/lightdm through libpam with the real helper ──
echo "== STACK: specs/etc/pam.d/lightdm executed through libpam =="
PAMPY="${WORK}/pam.py"
cat > "${PAMPY}" <<'PY'
import ctypes, ctypes.util, os, sys
confdir, service, answer, envfile = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
user = sys.argv[5] if len(sys.argv) > 5 else "alice"
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
rc = libpam.pam_start_confdir(service.encode(), user.encode(), ctypes.byref(c), confdir.encode(), ctypes.byref(h))
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
HSG_UID_MIN=${UIDMIN}
EOF
}
new_case true "${ISSUER}"; envfile
PO="${CASE}/pam.out"
python3 "${PAMPY}" "$(stack probe pam_permit.so)" lightdm "x" "${CASE}/env" > "${PO}" 2>&1
probe_out="$(tr '\n' '|' < "${PO}")"
PAM_OK=false
if grep -q '^RC 0$' "${PO}"; then
    PAM_OK=true
    # (a) a typed password: the helper steps aside, the local stand-in (permit) decides
    new_case true "${ISSUER}"; add_local alice; envfile
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(stack a pam_permit.so)" lightdm "hunter2" "${CASE}/env" > "${PO}" 2>/dev/null
    grep -q '^RC 0$' "${PO}" && grep -q 'MSG style=1 Password: ' "${PO}" && [ "$(nreq)" -eq 0 ] \
        && ok "STACK: typed password => prompted once, helper silent, local path authenticates (rc 0), no request" \
        || bad "STACK (a): $(tr '\n' '|' < "${PO}") requests $(nreq)"
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(stack a2 pam_deny.so)" lightdm "hunter2" "${CASE}/env" > "${PO}" 2>/dev/null
    grep -q '^RC [1-9]' "${PO}" && ok "STACK: typed password with a denying local path => still denied (helper grants nothing)" \
        || bad "STACK (a2): $(tr '\n' '|' < "${PO}")"
    # (a3) ONE prompt: the answer pam_exec collected stays in PAM_AUTHTOK for the
    # local path. Stand-in: a second `pam_exec expose_authtok` that logs what it
    # receives — it must get the same bytes WITHOUT prompting again.
    cat > "${CASE}/authtok-logger" <<EOF
#!/usr/bin/env bash
cat > "${CASE}/authtok.seen"
EOF
    chmod +x "${CASE}/authtok-logger"
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(stack a3 "pam_exec.so expose_authtok ${CASE}/authtok-logger")" lightdm "hunter2" "${CASE}/env" > "${PO}" 2>/dev/null
    [ "$(grep -c 'MSG style=1 ' "${PO}")" -eq 1 ] && [ "$(cat "${CASE}/authtok.seen" 2>/dev/null)" = "hunter2" ] && grep -q '^RC 0$' "${PO}" \
        && ok "STACK: exactly ONE password prompt; the local path receives the same PAM_AUTHTOK (no second prompt)" \
        || bad "STACK (a3): prompts=$(grep -c 'MSG style=1 ' "${PO}") seen='$(cat "${CASE}/authtok.seen" 2>/dev/null)' $(tr '\n' '|' < "${PO}")"
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
    bad "libpam execution unavailable here (probe='${probe_out}') and HUGMESH_REQUIRE_LIBPAM=1 (implied on the Debian CI job)"
else
    echo "  NOTE libpam execution layer not runnable here (probe tail: '${probe_out: -160}'); the helper checks above are the gate"
fi

# ── PAM ORDER with #860: the lightdm stack over the REAL include chain ────────
# #860 wires pam_ecryptfs after the LAST line of each system-auth stack (never
# right after pambase's `[success=1 ...] pam_unix.so`, whose jump would then land
# on `[default=die] pam_faillock.so authfail`). The greeter stack `include`s
# system-local-login -> system-login -> system-auth and never edits system-auth,
# so the two compose. Executed here: the real stack file, an include chain built
# from #860's pambase fixture, wired by #860's OWN wire_pam_ecryptfs (lifted from
# specs/usr/sbin/hugmesh-home-setup), with stand-ins only for what needs root:
# pam_unix -> a pam_exec password checker (same [success=1 ...] control),
# faillock authfail -> pam_deny (same [default=die]: reaching it kills the
# attempt), pam_ecryptfs unwrap -> a pam_exec marker that records it ran.
echo "== PAM ORDER: greeter stack + #860's wired system-auth through libpam =="
PAMFIX="${REPO}/tests/scripts/fixtures/pam/system-auth.gentoo-pambase"
HOMESETUP="${REPO}/specs/usr/sbin/hugmesh-home-setup"
order_confdir() {  # $1=label $2=lightdm-stack-file $3=system-auth-file -> confdir
    local d="${CASE}/order-$1"; mkdir -p "${d}"
    # Includes are spelled as ABSOLUTE paths into the confdir: Debian's libpam
    # (1.7.0-5) resolves a bare `include NAME` against /etc/pam.d even under
    # pam_start_confdir, where Gentoo's resolves it in the confdir. An absolute
    # include is the same stack on both.
    sed -e "s#/usr/lib/hugmesh/sso-greeter#${STACK_HELPER:-${HELPER}}#g" -e "s#/run/hugmesh/sso-greeter/hint#${CASE}/run/hint#" \
        -e "s#^\([a-z]*[[:space:]]*include[[:space:]]*\)system-local-login#\1${d}/system-local-login#" "$2" > "${d}/lightdm"
    grep -q "include[[:space:]]*${d}/system-local-login" "${d}/lightdm" || echo "  NOTE order_confdir: no include rewritten in $2" >&2
    printf 'auth\t\tinclude\t\t%s/system-login\naccount\t\tinclude\t\t%s/system-login\npassword\tinclude\t\t%s/system-login\nsession\t\tinclude\t\t%s/system-login\n' "${d}" "${d}" "${d}" "${d}" > "${d}/system-local-login"
    printf 'auth\t\tinclude\t\t%s/system-auth\naccount\t\tinclude\t\t%s/system-auth\npassword\tinclude\t\t%s/system-auth\nsession\t\tinclude\t\t%s/system-auth\n' "${d}" "${d}" "${d}" "${d}" > "${d}/system-login"
    sed -e "s#pam_unix\.so .*#pam_exec.so quiet expose_authtok ${WORK}/pw-check#" \
        -e 's#pam_faillock\.so preauth#pam_permit.so#' -e 's#pam_faillock\.so authfail#pam_deny.so#' \
        -e 's#pam_env\.so#pam_permit.so#' -e 's#pam_cap\.so#pam_permit.so#' \
        -e "s#pam_ecryptfs\.so unwrap#pam_exec.so quiet ${WORK}/ecryptfs-marker#" "$3" > "${d}/system-auth"
    echo "${d}"
}
cat > "${WORK}/pw-check" <<'EOF'
#!/usr/bin/env python3
import sys
sys.exit(0 if sys.stdin.buffer.read().rstrip(b"\0\n") == b"hunter2" else 1)
EOF
cat > "${WORK}/ecryptfs-marker" <<EOF
#!/usr/bin/env bash
echo "ecryptfs-unwrap-reached" >> "\${HSG_ORDER_MARK:-/dev/null}"
exit 0
EOF
chmod +x "${WORK}/pw-check" "${WORK}/ecryptfs-marker"
WFN="$(sed -n '/^wire_pam_ecryptfs() {/,/^}/p' "${HOMESETUP}" 2>/dev/null)"
if [ -f "${PAMFIX}" ] && [ -n "${WFN}" ] && ${PAM_OK}; then
    eval "${WFN}"
    cp "${PAMFIX}" "${WORK}/system-auth.wired"; wire_pam_ecryptfs "${WORK}/system-auth.wired"
    la="$(grep -n '^auth' "${WORK}/system-auth.wired" | tail -1)"
    case "${la}" in *pam_ecryptfs.so\ unwrap*) ok "ORDER: #860's wiring put auth pam_ecryptfs on the LAST auth line of system-auth" ;;
                    *) bad "ORDER: last auth line is not pam_ecryptfs: ${la}" ;; esac
    order_env() { envfile; printf 'HSG_ORDER_MARK=%s\n' "${CASE}/order.mark" >> "${CASE}/env"; : > "${CASE}/order.mark"; }
    # L1: a LOCAL user with the right password: one prompt, authenticated, and
    # the ecryptfs unwrap line IS reached (a local encrypted home unwraps).
    new_case true "${ISSUER}"; add_local alice; order_env
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(order_confdir l1 "${STACK_SRC}" "${WORK}/system-auth.wired")" lightdm "hunter2" "${CASE}/env" > "${PO}" 2>/dev/null
    grep -q '^RC 0$' "${PO}" && [ "$(grep -c 'MSG style=1 ' "${PO}")" -eq 1 ] && grep -q ecryptfs-unwrap-reached "${CASE}/order.mark" && [ "$(nreq)" -eq 0 ] \
        && ok "ORDER: local password through the real include chain => ONE prompt, rc 0, pam_ecryptfs unwrap reached, no request" \
        || bad "ORDER L1: $(tr '\n' '|' < "${PO}") mark='$(cat "${CASE}/order.mark")' requests $(nreq)"
    [ -s "${CASE}/run/hint" ] && ! grep -q 'failed' "${CASE}/run/hint" \
        && ok "FAILNOTE ORDER: a correct local password reaches pam-ok after the include: no notice left armed" \
        || bad "FAILNOTE ORDER L1: notice left armed after a SUCCESS: $(cat "${CASE}/run/hint" 2>/dev/null)"
    # L2: wrong local password: denied (the helper grants nothing, faillock path dies).
    new_case true "${ISSUER}"; add_local alice; order_env
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(order_confdir l2 "${STACK_SRC}" "${WORK}/system-auth.wired")" lightdm "wrong" "${CASE}/env" > "${PO}" 2>/dev/null
    grep -q '^RC [1-9]' "${PO}" && ok "ORDER: wrong local password through the chain => denied" || bad "ORDER L2: $(tr '\n' '|' < "${PO}")"
    head -1 "${CASE}/run/hint" | grep "^Sign-in as 'alice' failed" >/dev/null \
        && ok "FAILNOTE ORDER: a wrong password ends at pambase's faillock die, so the notice stays ARMED for the retry" \
        || bad "FAILNOTE ORDER L2: notice missing after a refused attempt: $(cat "${CASE}/run/hint" 2>/dev/null)"
    # The retry, through the same chain, as the greeter runs it: the notice is
    # the FIRST thing said, before the password prompt; the right password then
    # signs in and pam-ok takes the notice down.
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(order_confdir l2r "${STACK_SRC}" "${WORK}/system-auth.wired")" lightdm "hunter2" "${CASE}/env" > "${PO}" 2>/dev/null
    first="$(grep -m1 '^MSG ' "${PO}")"
    case "${first}" in
        "MSG style=4 Sign-in as 'alice' failed"*) ok "FAILNOTE ORDER: the retry shows 'Sign-in as alice failed' first, before the prompt" ;;
        *) bad "FAILNOTE ORDER retry: first message was '${first}'" ;;
    esac
    grep -q '^RC 0$' "${PO}" && ! grep -q 'failed' "${CASE}/run/hint" \
        && ok "FAILNOTE ORDER: the right password on the retry signs in and pam-ok disarms the notice" \
        || bad "FAILNOTE ORDER retry: $(tr '\n' '|' < "${PO}") hint: $(cat "${CASE}/run/hint" 2>/dev/null)"
    # WHOSE: alice is refused, then bob is picked. bob's conversation opens with the
    # plain hint and never names alice; bob is refused too, and HIS retry leads
    # with HIS notice.
    new_case true "${ISSUER}"; add_local alice; add_local bob; order_env
    python3 "${PAMPY}" "$(order_confdir w1 "${STACK_SRC}" "${WORK}/system-auth.wired")" lightdm "wrong" "${CASE}/env" alice > /dev/null 2>&1
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(order_confdir w2 "${STACK_SRC}" "${WORK}/system-auth.wired")" lightdm "wrong" "${CASE}/env" bob > "${PO}" 2>/dev/null
    first="$(grep -m1 '^MSG ' "${PO}")"
    case "${first}" in
        "MSG style=4 Leave the password empty"*) ! grep -q alice "${PO}" \
            && ok "FAILNOTE WHOSE: after alice is refused, bob's conversation opens with the plain hint and never names alice" \
            || bad "FAILNOTE WHOSE: bob's conversation named alice: $(tr '\n' '|' < "${PO}")" ;;
        *) bad "FAILNOTE WHOSE: bob's first message was '${first}'" ;;
    esac
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(order_confdir w3 "${STACK_SRC}" "${WORK}/system-auth.wired")" lightdm "hunter2" "${CASE}/env" bob > "${PO}" 2>/dev/null
    first="$(grep -m1 '^MSG ' "${PO}")"
    case "${first}" in
        "MSG style=4 Sign-in as 'bob' failed"*) grep -q '^RC 0$' "${PO}" && ok "FAILNOTE WHOSE: bob's own retry leads with bob's notice, and signs him in" \
            || bad "FAILNOTE WHOSE bob retry: $(tr '\n' '|' < "${PO}")" ;;
        *) bad "FAILNOTE WHOSE: bob's retry opened with '${first}'" ;;
    esac
    # S1: an SSO sign-in: success=done ends auth BEFORE system-auth, so neither the
    # password check nor faillock nor the ecryptfs unwrap runs for it.
    new_case true "${ISSUER}"; order_env
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(order_confdir s1 "${STACK_SRC}" "${WORK}/system-auth.wired")" lightdm "" "${CASE}/env" > "${PO}" 2>/dev/null
    grep -q '^RC 0$' "${PO}" && ! grep -q ecryptfs-unwrap-reached "${CASE}/order.mark" && grep -q useradd "${CASE}/log" \
        && ok "ORDER: SSO sign-in through the chain => rc 0, account created, system-auth (faillock, ecryptfs) never reached" \
        || bad "ORDER S1: $(tr '\n' '|' < "${PO}") mark='$(cat "${CASE}/order.mark")'"
    [ -s "${CASE}/run/hint" ] && ! grep -q 'failed' "${CASE}/run/hint" \
        && ok "FAILNOTE ORDER: an SSO sign-in (success=done, pam-ok never reached) leaves no notice armed" \
        || bad "FAILNOTE ORDER S1: notice left armed after an SSO success: $(cat "${CASE}/run/hint" 2>/dev/null)"
    # Control: the pre-#860 placement (ecryptfs right after pam_unix) breaks the
    # local login through this same chain — the leg can see PAM order.
    sed '/^auth.*pam_unix\.so/a auth\t\toptional\tpam_ecryptfs.so unwrap' "${PAMFIX}" > "${WORK}/system-auth.old"
    new_case true "${ISSUER}"; add_local alice; order_env
    PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(order_confdir ctl "${STACK_SRC}" "${WORK}/system-auth.old")" lightdm "hunter2" "${CASE}/env" > "${PO}" 2>/dev/null
    grep -q '^RC [1-9]' "${PO}" && ok "ORDER control: the pre-#860 wiring rejects a correct local password through the greeter stack (the leg sees order)" \
        || bad "ORDER control: pre-#860 wiring accepted — this leg cannot see PAM order"
elif [ "${HUGMESH_REQUIRE_LIBPAM:-0}" = 1 ]; then
    bad "PAM ORDER leg not runnable (fixture/wire function/libpam missing) and HUGMESH_REQUIRE_LIBPAM=1"
else
    echo "  NOTE PAM ORDER leg skipped (libpam layer not runnable here)"
fi

# ── ACCOUNTS: never root, a daemon, or an account SSO did not create ─────────
echo "== ACCOUNTS: system and unmanaged accounts are never adopted =="
chk_system_account() {  # HELPER -> 0 iff an IdP user named root/daemon is refused before any request
    local h="$1" rc
    new_case true "${ISSUER}"; printf '%s' "$(mint "$(payload root)")" > "${SRV}/access"
    auth "${h}" root ""; rc=$?
    [ "${rc}" -eq 1 ] && grep -q 'system account' "${CASE}/out" && [ "$(nreq)" -eq 0 ] && ! grep -q 'usermod\|useradd' "${CASE}/log" || return 1
    printf 'daemon:x:2:2:daemon:/sbin:/sbin/nologin\n' >> "${CASE}/etc/passwd"; printf 'daemon:*:19000:0:99999:7:::\n' >> "${CASE}/etc/shadow"
    printf '%s' "$(mint "$(payload daemon)")" > "${SRV}/access"
    UIDMIN=1000 auth "${h}" daemon ""; rc=$?
    [ "${rc}" -eq 1 ] && grep -q 'system account' "${CASE}/out" && [ "$(nreq)" -eq 0 ] && ! grep -q 'usermod\|useradd' "${CASE}/log"
}
chk_unmanaged_account() {  # HELPER -> 0 iff a locked account SSO did not create is refused, no request
    local h="$1" rc
    new_case true "${ISSUER}"
    printf 'keysuser:x:%s:%s:KEYS user:/home/keysuser:/bin/bash\n' "${TUID}" "${MYGID}" >> "${CASE}/etc/passwd"
    printf 'keysuser:!:19000:0:99999:7:::\n' >> "${CASE}/etc/shadow"
    printf '%s' "$(mint "$(payload keysuser)")" > "${SRV}/access"
    auth "${h}" keysuser ""; rc=$?
    [ "${rc}" -eq 1 ] && grep -q 'not an SSO account' "${CASE}/out" && [ "$(nreq)" -eq 0 ] && ! grep -q 'usermod\|useradd\|gpasswd' "${CASE}/log"
}
chk_system_account "${HELPER}" && ok "ACCOUNTS: an IdP user named root (uid 0) or daemon (uid < UID_MIN) => refused, rc 1, NO request, no account change" \
    || bad "ACCOUNTS: system account: rc ${rc:-?}; out: $(cat "${CASE}/out"); requests $(nreq)"
chk_unmanaged_account "${HELPER}" && ok "ACCOUNTS: a locked account SSO did not create (e.g. a KEYS user) => refused, rc 1, NO request, groups untouched" \
    || bad "ACCOUNTS: unmanaged: out: $(cat "${CASE}/out"); requests $(nreq); log: $(tr '\n' '|' < "${CASE}/log")"
new_case true "${ISSUER}"
auth "${HELPER}" alice "" && [ "$(cat "${CASE}/state/managed/alice" 2>/dev/null)" = "${TUID}" ] && [ "$(mode "${CASE}/state/managed/alice")" = 600 ] \
    && ok "ACCOUNTS: an SSO-created account is recorded (managed/<name> = its uid, 0600)" || bad "ACCOUNTS: managed registry: '$(cat "${CASE}/state/managed/alice" 2>/dev/null)'"
helper_cmd "${HELPER}" revoke alice; rm -f "${SRV}/n" "${SRV}/requests.log"
auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 0 ] && ok "ACCOUNTS: after 'revoke' (offline cache gone) the SSO user can still sign in ONLINE (the registry is kept)" || bad "ACCOUNTS: revoked user locked out online: $(cat "${CASE}/out")"
printf '99999\n' > "${CASE}/state/managed/alice"; rm -f "${SRV}/n" "${SRV}/requests.log"
auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 1 ] && [ "$(nreq)" -eq 0 ] && ok "ACCOUNTS: registry uid != the account's uid (account replaced) => refused, no request" || bad "ACCOUNTS: uid mismatch rc ${rc}"

# ── NETWORK: a standalone image contacts nothing until SSO is opted in ───────
# The audit hook (sitecustomize) logs EVERY socket connect / name lookup, to any
# host. Opt-in = SSO enabled with an issuer AND the user leaving the password
# empty at the greeter. Everything else must log nothing.
echo "== NETWORK: zero connections until SSO is opted in =="
standalone_case() {  # the conf the bake writes for a standalone image (SSO off, no issuer)
    new_case false ""
    sed -i -e 's/^POSTURE=.*/POSTURE=standalone/' "${CASE}/conf"
}
net_quiet() { [ ! -s "${CASE}/net.log" ] && [ "$(nreq)" -eq 0 ]; }
chk_net_standalone() {  # HELPER -> 0 iff the standalone conf makes no connection on any path
    local h="$1"
    standalone_case; add_local localuser
    helper_cmd "${h}" probe; helper_cmd "${h}" status; helper_cmd "${h}" list
    auth "${h}" localuser "hunter2"; auth "${h}" localuser ""; auth "${h}" alice ""; auth "${h}" alice "typed"
    PAM_USER=alice PAM_TYPE=open_session helper_cmd "${h}" pam-session
    helper_cmd "${h}" configure --issuer https://id.example.org
    auth "${h}" alice ""
    grep -q 'not enabled' "${CASE}/out" && net_quiet
}
chk_net_disabled_with_issuer() {  # HELPER -> 0 iff SSO_ENABLED=false with a live issuer still contacts nothing
    local h="$1"
    new_case false "${ISSUER}"
    auth "${h}" alice ""; auth "${h}" alice "typed"; helper_cmd "${h}" probe
    net_quiet
}
chk_net_probe_on() {  # HELPER -> 0 iff, with SSO ON, the greeter start + typed passwords contact nothing
    local h="$1"
    new_case true "${ISSUER}"; add_local localuser
    helper_cmd "${h}" probe; auth "${h}" localuser "hunter2"; auth "${h}" localuser ""; auth "${h}" stranger "typed"
    net_quiet
}
chk_net_standalone "${HELPER}" && ok "NETWORK: standalone conf (SSO off, no issuer): probe/status/list/pam-auth/pam-session/configure => ZERO connections or lookups" \
    || bad "NETWORK standalone: net.log: $(head -3 "${CASE}/net.log" 2>/dev/null | tr '\n' '|') requests $(nreq) out: $(cat "${CASE}/out")"
chk_net_disabled_with_issuer "${HELPER}" && ok "NETWORK: SSO disabled with a reachable issuer configured => ZERO connections" \
    || bad "NETWORK disabled+issuer: $(head -3 "${CASE}/net.log" 2>/dev/null | tr '\n' '|')"
chk_net_probe_on "${HELPER}" && ok "NETWORK: SSO on — greeter start (probe), typed local passwords, an unknown user's typed password => ZERO connections" \
    || bad "NETWORK SSO-on quiet paths: $(head -3 "${CASE}/net.log" 2>/dev/null | tr '\n' '|')"
new_case true "${ISSUER}"; auth "${HELPER}" alice ""
grep -q "socket.connect .*127.0.0.1" "${CASE}/net.log" 2>/dev/null \
    && ok "NETWORK control: the opt-in gesture (empty password, SSO on) IS logged by the audit hook — the hook is not blind" \
    || bad "NETWORK control: the audit hook saw nothing on a real sign-in (vacuous)"

# ── CONFIGURE: the runtime admin surface ─────────────────────────────────────
echo "== CONFIGURE: sso-greeter configure (root) =="
standalone_case; printf '# kept comment\nUNKNOWN_KEY=kept\n' >> "${CASE}/conf"
helper_cmd "${HELPER}" configure --enable --issuer "${ISSUER}/" --offline-days 3 --admin-role ops-admin; rc=$?
[ "${rc}" -eq 0 ] && grep -q '^SSO_ENABLED=true$' "${CASE}/conf" && grep -q "^ISSUER=${ISSUER}$" "${CASE}/conf" \
    && grep -q '^OFFLINE_MAX_AGE_DAYS=3$' "${CASE}/conf" && grep -q '^ADMIN_ROLE=ops-admin$' "${CASE}/conf" \
    && grep -q '^# kept comment$' "${CASE}/conf" && grep -q '^UNKNOWN_KEY=kept$' "${CASE}/conf" && [ "$(grep -c '^ISSUER=' "${CASE}/conf")" -eq 1 ] \
    && [ "$(mode "${CASE}/conf")" = 644 ] \
    && ok "CONFIGURE: --enable --issuer --offline-days --admin-role rewrite the conf in place (comments, unknown keys, 0644 kept; trailing / dropped)" \
    || bad "CONFIGURE: rc ${rc}: $(tr '\n' '|' < "${CASE}/conf") err: $(cat "${CASE}/err")"
grep -q 'Leave the password empty to sign in with' "${CASE}/run/hint" && ok "CONFIGURE: the greeter hint is refreshed (SSO now offered)" || bad "CONFIGURE: hint not refreshed: $(cat "${CASE}/run/hint" 2>/dev/null)"
net_quiet && ok "CONFIGURE: contacts nothing" || bad "CONFIGURE: made a connection"
auth "${HELPER}" alice ""; rc=$?
[ "${rc}" -eq 0 ] && ok "CONFIGURE: a standalone image opted in at runtime signs an SSO user in" || bad "CONFIGURE: sign-in after configure rc ${rc}: $(cat "${CASE}/out")"
grep -q '"offline_until"' "$(CACHE alice)" && python3 -c "import json,sys,time; r=json.load(open(sys.argv[1])); sys.exit(0 if 2*86400 < r['offline_until']-time.time() <= 3*86400 else 1)" "$(CACHE alice)" \
    && ok "CONFIGURE: --offline-days 3 bounds the offline cache to 3 days" || bad "CONFIGURE: offline bound not 3 days"
helper_cmd "${HELPER}" configure --disable; rc=$?
auth "${HELPER}" alice ""; rc2=$?
[ "${rc}" -eq 0 ] && [ "${rc2}" -eq 1 ] && grep -q 'not enabled' "${CASE}/out" && grep -q 'local password' "${CASE}/out" \
    && ok "CONFIGURE: --disable turns SSO off; the greeter says so and points at the local password" || bad "CONFIGURE --disable: rc ${rc}/${rc2}: $(cat "${CASE}/out")"
cfg_refused() {  # $1=label, rest=args -> must exit 2 and leave the conf unchanged
    local label="$1"; shift
    cp "${CASE}/conf" "${CASE}/conf.before"
    helper_cmd "${HELPER}" configure "$@"; local r=$?
    [ "${r}" -eq 2 ] && cmp -s "${CASE}/conf" "${CASE}/conf.before" && ok "CONFIGURE refuses ${label} (rc 2, conf unchanged)" || bad "CONFIGURE accepted ${label} (rc ${r})"
}
standalone_case
cfg_refused "--enable with no issuer" --enable
cfg_refused "a non-URL issuer" --issuer 'ftp://id.example.org'
cfg_refused "an issuer with a query" --issuer 'https://id.example.org/?x=1'
cfg_refused "an issuer carrying a newline (KEY=VALUE injection)" --issuer "$(printf 'https://id.example.org\nSSO_ENABLED=true')"
cfg_refused "--offline-days 999" --offline-days 999
cfg_refused "an unknown option" --frobnicate
cfg_refused "a client id with a space" --client-id 'a b'
if [ "${MYUID}" -ne 0 ]; then
    ( cd "${CASE}" && env -u HSG_INSECURE_TEST python3 "${HELPER}" configure --disable > "${CASE}/out" 2> "${CASE}/err" ); rc=$?
    [ "${rc}" -eq 1 ] && grep -q 'run as root' "${CASE}/err" && ok "CONFIGURE: refused for a non-root caller on a real image (no seams)" || bad "CONFIGURE non-root: rc ${rc} err: $(cat "${CASE}/err")"
fi

# ── GUARDS named by the requirement, as reusable checks (the battery re-runs them) ─
echo "== GUARDS =="
chk_no_wheel_without_admin() {  # HELPER -> 0 iff no wheel without the admin role (ungoverned), and never when governed
    local h="$1"
    new_case true "${ISSUER}"; printf '%s' "${TOK_ALICE}" > "${SRV}/access"
    auth "${h}" alice "" || return 1
    grep -q '^useradd ' "${CASE}/log" && ! grep -q '^useradd .*wheel' "${CASE}/log" && ! sed -n 's/^alice://p' "${CASE}/etc/groups" | grep wheel >/dev/null || return 1
    new_case true "${ISSUER}" governed; printf '%s' "${TOK_ALICE_ADMIN}" > "${SRV}/access"
    auth "${h}" alice "" || return 1
    ! sed -n 's/^alice://p' "${CASE}/etc/groups" | grep wheel >/dev/null
}
chk_no_token_in_logs() {  # HELPER -> 0 iff an online sign-in + session hand-off never print the token or the typed password
    local h="$1"
    new_case true "${ISSUER}"
    auth "${h}" alice "" || return 1
    cat "${CASE}/out" "${CASE}/err" > "${CASE}/all"
    auth "${h}" alice "my-offline-secret" || return 1
    cat "${CASE}/out" "${CASE}/err" >> "${CASE}/all"
    mkdir -p "${CASE}/runtime/${TUID}"
    PAM_USER=alice PAM_TYPE=open_session helper_cmd "${h}" pam-session
    cat "${CASE}/out" "${CASE}/err" >> "${CASE}/all"
    helper_cmd "${h}" status alice; cat "${CASE}/out" "${CASE}/err" >> "${CASE}/all"
    helper_cmd "${h}" list; cat "${CASE}/out" "${CASE}/err" >> "${CASE}/all"
    ! grep -qF "${TOK_ALICE}" "${CASE}/all" && ! grep -qF "$(printf '%s' "${TOK_ALICE}" | cut -d. -f3)" "${CASE}/all" \
        && ! grep -qF 'my-offline-secret' "${CASE}/all" && ! grep -qF 'DEVCODE123' "${CASE}/all"
}
chk_cache_expiry() {  # HELPER -> 0 iff an expired offline record does not sign in (issuer down)
    local h="$1"
    new_case true "${ISSUER}"; auth "${h}" alice "" || return 1; auth "${h}" alice "pw1" || return 1
    python3 -c "import json,sys,time; p=sys.argv[1]; r=json.load(open(p)); r['offline_until']=int(time.time())-5; json.dump(r,open(p,'w'))" "$(CACHE alice)"
    sed -i "s#^ISSUER=.*#ISSUER=${DOWN}#" "${CASE}/conf"
    ! auth "${h}" alice "pw1" && grep -q 'expired' "${CASE}/out"
}
chk_fallback_reason() {  # HELPER -> 0 iff issuer down => rc 1, the reason AND the local-password pointer on the greeter, fast
    local h="$1" t0 t1
    new_case true "${DOWN}"
    t0="$(date +%s)"; auth "${h}" alice ""; local rc=$?; t1="$(date +%s)"
    [ "${rc}" -eq 1 ] && grep -q 'SSO sign-in unavailable: cannot reach' "${CASE}/out" \
        && grep -q 'Sign in with your local password instead' "${CASE}/out" && [ $((t1 - t0)) -le 15 ] || return 1
    new_case false ""
    auth "${h}" alice ""; rc=$?
    [ "${rc}" -eq 1 ] && grep -q 'not enabled' "${CASE}/out" && grep -q 'local password' "${CASE}/out"
}
for g in no_wheel_without_admin no_token_in_logs cache_expiry fallback_reason; do
    "chk_${g}" "${HELPER}" && ok "GUARD ${g}: holds on the real helper" || bad "GUARD ${g}: FAILS on the real helper (out: $(head -c 300 "${CASE}/out"))"
done

# ── MUTATION battery: each defect planted in a copy must be caught ──────────
echo "== MUTATION: planted defects in a helper copy =="
# Every caller runs mutate in $(...), a SUBSHELL: a bad() in here used to raise F
# in the subshell only, so a plant that no longer applied (the code it targets
# was rewritten) vanished from the battery and the suite stayed green. Its
# refusals are recorded in VOID and counted as failures before the RESULT line.
VOID="${WORK}/mutate.void"; : > "${VOID}"
mutate() {  # $1=label $2=sed-expr -> path of the mutated copy (fails if nothing changed)
    local m="${WORK}/mut-$1"
    sed -e "$2" "${HELPER}" > "${m}"; chmod 0755 "${m}"
    if cmp -s "${HELPER}" "${m}"; then echo "MUTATION $1: the plant changed nothing (vacuous control)" >> "${VOID}"; return 1; fi
    # a plant that breaks the syntax would go red for the wrong reason
    python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "${m}" 2>/dev/null \
        || { echo "MUTATION $1: the plant does not parse (a red here would prove nothing)" >> "${VOID}"; return 1; }
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
if m="$(mutate local 's/if local and rec is None:/if False:/;s/^    if entry is not None and not is_managed(user, entry):$/    if False:/')"; then
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
# The two FAILNOTE rules the libpam battery below cannot see: a new greeter drops
# the armed state, and the files that name a refused user are 0600.
if m="$(mutate probe-keeps 's/^    clear_failure_notice()          # a new greeter starts clean$/    pass/')"; then
    new_case true "${ISSUER}"; add_local alice; auth "${m}" alice "wrong"
    helper_cmd "${m}" probe; PAM_USER=alice PAM_TYPE=auth helper_cmd "${m}" pam-hint
    grep -q 'failed' "${CASE}/run/hint" && ok "MUTATION probe-keeps: a probe that keeps the armed state brings the notice back — the FAILNOTE probe/state check catches it" \
        || bad "MUTATION probe-keeps: the notice did not come back; the probe/state check cannot tell"
fi
if m="$(mutate hint-0644 '/^def write_hint/,/os.replace/ s/0o600)$/0o644)/')"; then
    new_case true "${ISSUER}"; add_local alice; auth "${m}" alice "wrong"
    [ "$(stat -c %a "${CASE}/run/hint" 2>/dev/null)" = 644 ] && ok "MUTATION hint-0644: a world-readable hint is visible to the FAILNOTE modes check" \
        || bad "MUTATION hint-0644: the hint mode did not change ($(stat -c %a "${CASE}/run/hint" 2>/dev/null))"
fi

# ── GUARD battery: every guard the requirement names, re-run against a planted
# defect. Each plant must change the file (else the control is vacuous) and the
# SAME check function that is green on the real helper must go red on it.
echo "== GUARD battery: the named guards against planted defects =="
chk_cfg_validation() {  # HELPER -> 0 iff configure refuses a non-https issuer and a KEY=VALUE injection
    local h="$1"
    standalone_case; cp "${CASE}/conf" "${CASE}/conf.before"
    helper_cmd "${h}" configure --issuer 'ftp://id.example.org'; [ $? -eq 2 ] || return 1
    helper_cmd "${h}" configure --issuer "$(printf 'https://id.example.org\nSSO_ENABLED=true')"; [ $? -eq 2 ] || return 1
    cmp -s "${CASE}/conf" "${CASE}/conf.before"
}
chk_cfg_validation "${HELPER}" && ok "GUARD cfg_validation: holds on the real helper" || bad "GUARD cfg_validation: FAILS on the real helper"
guard_mut() {  # $1=label $2=sed-expr $3=check-function
    local m
    m="$(mutate "$1" "$2")" || return
    if "$3" "${m}"; then
        bad "GUARD battery $1: ${3} stayed GREEN on the planted defect (the guard is not what it claims)"
    else
        ok "GUARD battery $1: ${3} goes red on the planted defect"
    fi
}
guard_mut wheel-always   's/wants_wheel = (not is_governed()) and has_role(roles, conf.get("ADMIN_ROLE", ""))/wants_wheel = True/' chk_no_wheel_without_admin
guard_mut wheel-governed 's/wants_wheel = (not is_governed()) and /wants_wheel = /' chk_no_wheel_without_admin
guard_mut role-any       's/^def has_role(roles, role):/def has_role(roles, role):\n    return True/' chk_no_wheel_without_admin
guard_mut token-handoff-log 's/^        token = read_private(src)$/&\n        log("handing off %s" % token)/' chk_no_token_in_logs
guard_mut token-park-log 's/^def park_handoff(uid, token):/&\n    log("parking %s" % token)/' chk_no_token_in_logs
guard_mut typed-pw-log   's/^    if typed.endswith("\\n"):/    log("typed %s" % typed)\n&/' chk_no_token_in_logs
guard_mut cache-no-expiry 's/if rec.get("pin") and now < float(rec.get("offline_until", 0)):/if rec.get("pin"):/' chk_cache_expiry
guard_mut fallback-accepts 's/^        if result != "SSO sign-in cancelled.":/        return 0\n&/' chk_fallback_reason
guard_mut fallback-no-reason 's/^        say(result)$/        pass/' chk_fallback_reason
guard_mut fallback-no-pointer 's/^            say(FALLBACK_LINE)$/            pass/' chk_fallback_reason
guard_mut off-no-reason  's/^            say(off_reason(conf) + " " + FALLBACK_LINE)$/            pass/' chk_fallback_reason
guard_mut reach-bypass   's/^    ok, why = reachable(conf, timeout)$/    ok, why = True, ""/' chk_fallback_reason
guard_mut net-off-gate   's/^    if not enabled(conf) or not issuer_ok(conf):$/    if not issuer_ok(conf):/' chk_net_disabled_with_issuer
guard_mut net-probe      '/^def cmd_probe/,/return 0/ s/^    write_hint(conf)$/    reachable(conf, 1)\n    write_hint(conf)/' chk_net_probe_on
guard_mut net-typed      's/^    if typed != "" and rec is None:$/    if typed != "" and rec is None and not reachable(conf, 1)[0]:/' chk_net_probe_on
guard_mut system-guards  's/^    if entry is not None and is_system_account(entry):$/    if False:/;s/^    if entry is not None and not is_managed(user, entry):$/    if False:/' chk_system_account
guard_mut managed-guard  's/^    if entry is not None and not is_managed(user, entry):$/    if False:/' chk_unmanaged_account
guard_mut cfg-any-issuer 's/^            if not valid_issuer(v):$/            if False:/' chk_cfg_validation

# The STACK half of "fallback to local": the control flags on the exec line.
if ${PAM_OK}; then
    chk_stack_fallback() {  # STACKFILE -> 0 iff typed local password passes a permitting local path AND SSO short-circuits a denying one
        local sf="$1" d
        new_case true "${ISSUER}"; add_local alice; envfile
        d="${CASE}/cd-chk-a"; mkdir -p "${d}"
        sed -e "s#/usr/lib/hugmesh/sso-greeter#${HELPER}#g" -e "s#/run/hugmesh/sso-greeter/hint#${CASE}/run/hint#" \
            -e "s#include\t\tsystem-local-login#required\tpam_permit.so#" "${sf}" > "${d}/lightdm"
        python3 "${PAMPY}" "${d}" lightdm "hunter2" "${CASE}/env" 2>/dev/null | grep '^RC 0$' >/dev/null || return 1
        new_case true "${ISSUER}"; envfile
        d="${CASE}/cd-chk-c"; mkdir -p "${d}"
        sed -e "s#/usr/lib/hugmesh/sso-greeter#${HELPER}#g" -e "s#/run/hugmesh/sso-greeter/hint#${CASE}/run/hint#" \
            -e "s#include\t\tsystem-local-login#required\tpam_deny.so#" "${sf}" > "${d}/lightdm"
        python3 "${PAMPY}" "${d}" lightdm "" "${CASE}/env" 2>/dev/null | grep '^RC 0$' >/dev/null
    }
    stack_mut() {  # $1=label $2=sed-expr
        local m="${WORK}/stackmut-$1"
        sed -e "$2" "${STACK_SRC}" > "${m}"
        if cmp -s "${STACK_SRC}" "${m}"; then bad "STACK battery $1: the plant changed nothing (vacuous control)"; return; fi
        chk_stack_fallback "${m}" && bad "STACK battery $1: stayed GREEN on the planted stack" || ok "STACK battery $1: chk_stack_fallback goes red"
    }
    chk_stack_fallback "${STACK_SRC}" && ok "GUARD stack_fallback: holds on the real stack" || bad "GUARD stack_fallback: FAILS on the real stack"
    stack_mut exec-required 's/\[success=done default=ignore\]\tpam_exec/required\tpam_exec/'
    stack_mut exec-die      's/\[success=done default=ignore\]/[success=done default=die]/'
    stack_mut no-done       's/\[success=done default=ignore\]/[success=ok default=ignore]/'

    # The failure notice, through the REAL pambase chain (its die is what keeps
    # the notice armed): wrong password => denied AND notice; right password =>
    # signed in AND no notice; SSO => signed in AND no notice.
    if [ -n "${WFN}" ] && [ -f "${WORK}/system-auth.wired" ]; then
        chk_fail_notice() {  # STACKFILE [HELPER] -> 0 iff all five hold
            local sf="$1" PO first
            local STACK_HELPER="${2:-${HELPER}}"
            new_case true "${ISSUER}"; add_local alice; add_local bob; order_env
            PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(order_confdir fn1 "${sf}" "${WORK}/system-auth.wired")" lightdm "wrong" "${CASE}/env" > "${PO}" 2>/dev/null
            grep -q '^RC [1-9]' "${PO}" && head -1 "${CASE}/run/hint" | grep "^Sign-in as 'alice' failed" >/dev/null || return 1
            # alice's retry, through the stack, opens with her notice
            PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(order_confdir fn1r "${sf}" "${WORK}/system-auth.wired")" lightdm "hunter2" "${CASE}/env" alice > "${PO}" 2>/dev/null
            first="$(grep -m1 '^MSG ' "${PO}")"
            case "${first}" in "MSG style=4 Sign-in as 'alice' failed"*) ;; *) return 1 ;; esac
            grep -q '^RC 0$' "${PO}" && [ ! -e "${CASE}/run/failed" ] || return 1
            # refused again, then bob is picked: bob never sees alice's notice
            python3 "${PAMPY}" "$(order_confdir fn1w "${sf}" "${WORK}/system-auth.wired")" lightdm "wrong" "${CASE}/env" alice > /dev/null 2>&1
            PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(order_confdir fn1b "${sf}" "${WORK}/system-auth.wired")" lightdm "hunter2" "${CASE}/env" bob > "${PO}" 2>/dev/null
            grep -q '^RC 0$' "${PO}" && ! grep -q alice "${PO}" || return 1
            new_case true "${ISSUER}"; add_local alice; order_env
            PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(order_confdir fn2 "${sf}" "${WORK}/system-auth.wired")" lightdm "hunter2" "${CASE}/env" > "${PO}" 2>/dev/null
            grep -q '^RC 0$' "${PO}" && [ -s "${CASE}/run/hint" ] && ! grep -q 'failed' "${CASE}/run/hint" || return 1
            new_case true "${ISSUER}"; order_env
            PO="${CASE}/pam.out"; python3 "${PAMPY}" "$(order_confdir fn3 "${sf}" "${WORK}/system-auth.wired")" lightdm "" "${CASE}/env" > "${PO}" 2>/dev/null
            grep -q '^RC 0$' "${PO}" && [ -s "${CASE}/run/hint" ] && ! grep -q 'failed' "${CASE}/run/hint"
        }
        chk_fail_notice "${STACK_SRC}" && ok "GUARD fail_notice: holds on the real stack + helper" || bad "GUARD fail_notice: FAILS on the real stack + helper"
        notice_stack_mut() {  # $1=label $2=sed-expr over the stack
            local m="${WORK}/stackmut-$1"
            sed -e "$2" "${STACK_SRC}" > "${m}"
            if cmp -s "${STACK_SRC}" "${m}"; then bad "FAILNOTE battery $1: the plant changed nothing (vacuous control)"; return; fi
            chk_fail_notice "${m}" && bad "FAILNOTE battery $1: stayed GREEN on the planted stack" || ok "FAILNOTE battery $1: chk_fail_notice goes red"
        }
        notice_helper_mut() {  # $1=label $2=sed-expr over the helper
            local m
            m="$(mutate "notice-$1" "$2")" || return
            chk_fail_notice "${STACK_SRC}" "${m}" && bad "FAILNOTE battery $1: stayed GREEN on the planted helper" || ok "FAILNOTE battery $1: chk_fail_notice goes red"
        }
        notice_stack_mut  no-pam-ok      '/pam_exec\.so quiet \/usr\/lib\/hugmesh\/sso-greeter pam-ok$/d'
        notice_stack_mut  pam-ok-first   '/sso-greeter pam-ok$/d; /^auth[[:space:]]*include[[:space:]]*system-local-login/i auth\t\toptional\tpam_exec.so quiet /usr/lib/hugmesh/sso-greeter pam-ok'
        notice_stack_mut  no-pam-hint    '/sso-greeter pam-hint$/d'
        notice_stack_mut  hint-after-echo '/sso-greeter pam-hint$/d; /pam_echo\.so file=/a auth\t\toptional\tpam_exec.so quiet /usr/lib/hugmesh/sso-greeter pam-hint'
        notice_helper_mut no-arm         's/^    arm_failure_notice(name)$/    pass/; s/^    write_hint(conf, name or None, failed=name)$/    write_hint(conf, name or None)/'
        notice_helper_mut no-state       's/^    arm_failure_notice(name)$/    pass/'
        notice_helper_mut any-user       's/^    if valid_username(armed) and armed == user:$/    if valid_username(armed):/'
        notice_helper_mut ok-no-disarm   '/^def cmd_pam_ok():/,/^    return 0$/ s/^        disarm_failure_notice()$/        pass/'
        notice_helper_mut sso-no-disarm  '/^def cmd_pam_auth():/,/^    return rc$/ s/^        disarm_failure_notice()$/        pass/'
    fi
fi

while IFS= read -r v; do bad "${v}"; done < "${VOID}"

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
