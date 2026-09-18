#!/usr/bin/env bash
# test-stack-clone-credential.sh — scripts/clone-all-repos.sh must PROVE the
# credential it is about to use, and fall through to the next mechanism when the
# one it would have picked cannot actually read the org.
#
# THE DEFECT THIS PINS (#535, measured 2026-09-17/18). `make stack-up` died at its
# FIRST step with `0 ok, 26 failed` and the words "auth/VPN?" on a box whose
# credentials were fine. Same command, same machine, one minute apart, into two
# throwaway directories:
#
#     as the operator's login shell has it   ->   0 ok, 26 failed
#     env -u GH_TOKEN -u GITHUB_TOKEN        ->  26 ok,  0 failed
#
# ~/.profile exports a FINE-GRAINED GH_TOKEN with no read grant on the org. It is
# a VALID token — `gh auth status` exits 0 under it — so every "am I logged in?"
# check said yes while every clone got HTTP 403. The old script preferred it twice
# over: clone_url() injected it into the https URL whenever it was set, and
# `USE_GH=auto` resolved to 1 from `gh auth status` exiting 0.
#
# HOW THIS TEST REPRODUCES THAT WITHOUT GITHUB. It stands up a REAL git smart-HTTP
# server over REAL TLS on 127.0.0.1 (git-http-backend behind a 120-line python
# handler) that 403s one Basic password and serves another — the same status code,
# through the same git transport, as the org returns to an unprivileged token. So
# the run under test uses real `git clone --depth 1 --branch main` over https, and
# the fallback it takes is the fallback an operator would get. The privileged
# credential is reachable ONLY through a shimmed `gh auth git-credential`, exactly
# as the keyring credential is on the operator's box.
#
# WHAT IT CANNOT SEE, stated plainly: it does not exercise `gh repo clone`
# (gh-clone is skipped for a non-github.com GIT_BASE, by design — see the script),
# and it cannot prove anything about the real github.com grants. It proves the
# MECHANISM: probe, fall through, name the credential, never hang.
#
# Runs ANYWHERE with bash + git + python3 + openssl — NO network beyond loopback,
# NO root, NO docker.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${REPO}/scripts/clone-all-repos.sh"

P=0; F=0
ok()   { echo "  PASS $*"; P=$((P+1)); }
bad()  { echo "  FAIL $*"; F=$((F+1)); }
info() { echo "       $*"; }

echo "== stack-clone credential probe + fallback (#535) =="

[ -f "${SCRIPT}" ] || { echo "  FAIL ${SCRIPT} missing" >&2; exit 1; }
for t in git python3 openssl; do
  command -v "${t}" >/dev/null 2>&1 || {
    echo "SKIPPED-LOUDLY: ${t} is required and absent — this guard checked NOTHING." >&2
    echo "Exiting 2 rather than 0." >&2
    exit 2
  }
done
BACKEND="$(git --exec-path)/git-http-backend"
[ -x "${BACKEND}" ] || {
  echo "SKIPPED-LOUDLY: ${BACKEND} is absent, so no real git server can be stood up." >&2
  echo "This guard checked NOTHING. Exiting 2 rather than 0." >&2
  exit 2
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stack-clone-cred.XXXXXX")"
SRV_PID=""
cleanup() {
  [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null
  rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM HUP

BAD_TOKEN="github_pat_11FAKEUNPRIVILEGED535aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
GOOD_TOKEN="gho_FAKEKEYRINGCLASSIC535bbbbbbbbbbbbbbbbbbbb"

# ── the repo names come from the SCRIPT, never from a second list here ────────
# A copy would drift the first time someone adds a repo, and a fixture that is
# missing one name fails for a reason that has nothing to do with credentials.
mapfile -t REPOS < <(awk '/^REPOS=\(/{f=1;next} f&&/^\)/{exit} f&&/^  [a-z0-9][a-z0-9.-]*$/{gsub(/ /,"");print}' "${SCRIPT}")
if [ "${#REPOS[@]}" -lt 5 ]; then
  bad "could not read the REPOS list out of ${SCRIPT} (got ${#REPOS[@]} names) — the fixture would be meaningless"
  echo "== RESULT: ${P} passed, ${F} failed =="; exit 1
fi
ok "read ${#REPOS[@]} repo names out of the script itself (no second copy of the list to drift)"

# ── fixture: one bare repo per name, each with a main branch ──────────────────
mkdir -p "${WORK}/repos" "${WORK}/bin" "${WORK}/home"
git init -q "${WORK}/seed"
echo "hugmesh" > "${WORK}/seed/README.md"
git -C "${WORK}/seed" add README.md
git -C "${WORK}/seed" -c user.email=t@t -c user.name=t commit -q -m init
git -C "${WORK}/seed" branch -M main
git clone -q --bare "${WORK}/seed" "${WORK}/repos/_template.git"
for r in "${REPOS[@]}"; do cp -a "${WORK}/repos/_template.git" "${WORK}/repos/${r}.git"; done
rm -rf "${WORK}/repos/_template.git"

openssl req -x509 -newkey rsa:2048 -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" \
  -days 1 -nodes -subj "/CN=127.0.0.1" >/dev/null 2>&1 \
  || { bad "openssl could not make a self-signed cert"; echo "== RESULT: ${P} passed, ${F} failed =="; exit 1; }

cat > "${WORK}/gitserver.py" <<'PYEOF'
# A throwaway HTTPS git smart-http server with ONE job: 403 the unprivileged
# password and serve the privileged one, so the fallback in clone-all-repos.sh is
# exercised against REAL git over REAL TLS rather than a mock.
import base64, os, ssl, subprocess, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT, CERT, KEY, GOOD, PORTFILE, PREFIX = sys.argv[1:7]
BACKEND = subprocess.run(["git", "--exec-path"], capture_output=True, text=True).stdout.strip() + "/git-http-backend"


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _auth(self):
        h = self.headers.get("Authorization", "")
        if not h.startswith("Basic "):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="git"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        try:
            user, _, pw = base64.b64decode(h[6:]).decode("utf8", "replace").partition(":")
        except Exception:
            user, pw = "", ""
        if pw != GOOD:
            body = b"Write access to repository not granted.\n"
            self.send_response(403)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return None
        return user or "tester"

    def _cgi(self, method, body=b""):
        user = self._auth()
        if user is None:
            return
        path, _, query = self.path.partition("?")
        if PREFIX and path.startswith(PREFIX):
            path = path[len(PREFIX):]
        env = dict(os.environ)
        env.update({
            "GIT_PROJECT_ROOT": ROOT, "GIT_HTTP_EXPORT_ALL": "1",
            "REQUEST_METHOD": method, "PATH_INFO": path, "QUERY_STRING": query,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(body)), "REMOTE_USER": user,
            "REMOTE_ADDR": "127.0.0.1", "SERVER_PROTOCOL": "HTTP/1.1",
        })
        env.pop("HTTP_CONTENT_ENCODING", None)
        if self.headers.get("Content-Encoding"):
            env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
        p = subprocess.run([BACKEND], input=body, env=env, capture_output=True)
        head, _, payload = p.stdout.partition(b"\r\n\r\n")
        status, hdrs = 200, []
        for line in head.split(b"\r\n"):
            if not line:
                continue
            k, _, v = line.partition(b":")
            k, v = k.strip().decode(), v.strip().decode()
            if k.lower() == "status":
                status = int(v.split()[0])
            else:
                hdrs.append((k, v))
        self.send_response(status)
        for k, v in hdrs:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self._cgi("GET")

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self._cgi("POST", self.rfile.read(n) if n else b"")


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CERT, KEY)
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
with open(PORTFILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF

python3 "${WORK}/gitserver.py" "${WORK}/repos" "${WORK}/cert.pem" "${WORK}/key.pem" \
        "${GOOD_TOKEN}" "${WORK}/port" /hugmesh >"${WORK}/server.log" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 60); do [ -s "${WORK}/port" ] && break; sleep 0.2; done
if [ ! -s "${WORK}/port" ]; then
  bad "the fixture git server did not start: $(sed -n '1,5p' "${WORK}/server.log")"
  echo "== RESULT: ${P} passed, ${F} failed =="; exit 1
fi
PORT="$(cat "${WORK}/port")"
BASE="https://127.0.0.1:${PORT}/hugmesh"
info "fixture git server on ${BASE} (403s anything but the privileged password)"

# The privileged credential is reachable ONLY through this shim, exactly as the
# real keyring credential is reachable only through `gh auth git-credential`.
make_gh_shim() { # <mode: works | logged-in-only>
  local emit
  emit=""
  # `logged-in-only` is the #535 shape: `gh auth status` exits 0 (so every
  # "am I logged in?" check says yes) while the credential it can actually hand
  # over reads nothing.
  if [ "$1" = "works" ]; then
    emit="printf 'protocol=https\nhost=127.0.0.1:${PORT}\nusername=oauth2\npassword=${GOOD_TOKEN}\n'"
  fi
  cat > "${WORK}/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "auth git-credential")
      [ "\${3:-}" = "get" ] || exit 0
      cat >/dev/null
      ${emit}
      exit 0 ;;
esac
exit 1
EOF
  chmod +x "${WORK}/bin/gh"
}

run_clone() { # <bindir> <extra env assignments...> ; stdout+stderr -> ${WORK}/run.out
  local bindir
  bindir="$1"; shift
  rm -f "${WORK}/run.out"
  env -i \
    HOME="${WORK}/home" \
    PATH="${bindir}:/usr/bin:/bin:/usr/local/bin" \
    TMPDIR="${WORK}" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_SSL_NO_VERIFY=true \
    GIT_BASE="${BASE}" GIT_REF=main \
    "$@" \
    timeout 300 bash "${SCRIPT}" >"${WORK}/run.out" 2>&1
}

# ── 1. THE PIN: a valid-but-unprivileged token in the environment, and the ────
#       clone still succeeds through the next mechanism.
make_gh_shim works
rm -rf "${WORK}/src1"
run_clone "${WORK}/bin" GH_TOKEN="${BAD_TOKEN}" STACK_SRC="${WORK}/src1"
rc1=$?
out="$(cat "${WORK}/run.out")"
if [ "${rc1}" -eq 0 ]; then
  ok "with a valid-but-unprivileged GH_TOKEN exported, the clone run still EXITS 0 (#535)"
else
  bad "with a valid-but-unprivileged GH_TOKEN exported the run exited ${rc1} — this is exactly #535"
  info "$(printf '%s\n' "${out}" | tail -20)"
fi
cloned=0
for r in "${REPOS[@]}"; do [ -d "${WORK}/src1/${r}/.git" ] && cloned=$((cloned+1)); done
if [ "${cloned}" -eq "${#REPOS[@]}" ]; then
  ok "all ${cloned}/${#REPOS[@]} repos are real checkouts"
else
  bad "only ${cloned}/${#REPOS[@]} repos were cloned"
fi
case "${out}" in
  *"env-token: FAILED"*) ok "the probe REPORTS the unprivileged token as failed, by mechanism name" ;;
  *) bad "the output never names env-token as the mechanism that failed:"; info "$(printf '%s\n' "${out}" | sed -n '1,12p')" ;;
esac
case "${out}" in
  *"using: gh-keyring"*) ok "the run states WHICH credential it fell through to (gh-keyring)" ;;
  *) bad "the output does not name the credential it used" ;;
esac

# ── 2. the token is never echoed ─────────────────────────────────────────────
case "${out}" in
  *"${BAD_TOKEN}"*|*"${GOOD_TOKEN}"*) bad "a token LEAKED into the run output — it must be redacted" ;;
  *) ok "neither token appears anywhere in the run output (redaction holds)" ;;
esac

# ── 3. the second run takes the update path and still works ──────────────────
run_clone "${WORK}/bin" GH_TOKEN="${BAD_TOKEN}" STACK_SRC="${WORK}/src1"
rc2=$?
out2="$(cat "${WORK}/run.out")"
if [ "${rc2}" -eq 0 ] && printf '%s' "${out2}" | grep -a -q "present, updating"; then
  ok "a second run takes the UPDATE path and is still green under the same bad token"
else
  bad "the second (update-path) run exited ${rc2} — the fallback does not survive re-running"
  info "$(printf '%s\n' "${out2}" | tail -15)"
fi

# ── 4. USE_GH must not trust 'gh auth status' ────────────────────────────────
#      The shim is LOGGED IN (auth status exits 0) but hands back no credential.
#      The old code read that exit 0 as "gh can read these repos"; the fixed code
#      must probe, find it cannot, and say so instead of choosing it.
make_gh_shim logged-in-only
rm -rf "${WORK}/src4"
run_clone "${WORK}/bin" GH_TOKEN="${BAD_TOKEN}" STACK_SRC="${WORK}/src4"
rc4=$?
out4="$(cat "${WORK}/run.out")"
if [ "${rc4}" -ne 0 ]; then
  ok "a gh that is LOGGED IN but cannot read is not accepted — the run fails loudly (rc=${rc4})"
else
  bad "the run exited 0 with no credential that can read anything — 'gh auth status exits 0' is still being read as 'gh can read these repos'"
fi
case "${out4}" in
  *"gh-keyring: FAILED"*) ok "the logged-in-but-blind gh is reported FAILED by name, not silently trusted" ;;
  *) bad "gh-keyring is not reported as failed:"; info "$(printf '%s\n' "${out4}" | sed -n '1,14p')" ;;
esac
if [ -d "${WORK}/src4" ] && [ -n "$(ls -A "${WORK}/src4" 2>/dev/null)" ]; then
  bad "the run created checkouts in ${WORK}/src4 although no credential could read"
else
  ok "nothing was cloned when no mechanism could read (it refused before the loop, not 26 times)"
fi

# ── 5. the failure message names the credential and drops 'auth/VPN?' ────────
case "${out4}" in
  *"auth/VPN?"*) bad "the failure still says 'auth/VPN?' — the message #535 was filed about" ;;
  *) ok "the failure message no longer blames 'auth/VPN?'" ;;
esac
case "${out4}" in
  *"GH_TOKEN IS set in your environment"*) ok "the failure names the ambient credential and what would fix it" ;;
  *) bad "the failure does not name which credential was in play" ;;
esac
case "${out4}" in
  *"STACK_NO_CLONE=1"*) ok "the failure offers the documented way to build without cloning" ;;
  *) bad "the failure does not offer STACK_NO_CLONE=1" ;;
esac

# ── 6. no mechanism may hang on a credential prompt ──────────────────────────
# run_clone wraps the script in `timeout 300`; 124 is what a parked
# "Username for 'https://...':" would look like from here.
if [ "${rc4}" -eq 124 ]; then
  bad "the run TIMED OUT — something is waiting on a terminal credential prompt"
else
  ok "no run parked on a credential prompt (GIT_TERMINAL_PROMPT=0 is exported)"
fi

# ── 7. USE_GH=0 removes gh entirely, and then nothing can read ───────────────
make_gh_shim works
rm -rf "${WORK}/src7"
run_clone "${WORK}/bin" GH_TOKEN="${BAD_TOKEN}" STACK_SRC="${WORK}/src7" USE_GH=0
rc7=$?
out7="$(cat "${WORK}/run.out")"
if [ "${rc7}" -ne 0 ] && printf '%s' "${out7}" | grep -a -q "skipped (USE_GH=0)"; then
  ok "USE_GH=0 removes the gh mechanisms by name and the run then fails honestly (rc=${rc7})"
else
  bad "USE_GH=0 did not remove the gh mechanisms (rc=${rc7})"
  info "$(printf '%s\n' "${out7}" | sed -n '1,14p')"
fi

# ── 8. CONTROL: this suite can go RED ────────────────────────────────────────
# Everything above is only good news if the fixture could have said otherwise.
# With NO gh on PATH and the unprivileged token, the run must fail — if it
# passes, the fixture is not actually gating on the credential and every PASS
# above is vacuous.
rm -rf "${WORK}/nogh"; mkdir -p "${WORK}/nogh"
rm -rf "${WORK}/src8"
run_clone "${WORK}/nogh" GH_TOKEN="${BAD_TOKEN}" STACK_SRC="${WORK}/src8"
rc8=$?
if [ "${rc8}" -ne 0 ]; then
  ok "control: with no working credential at all the run FAILS (rc=${rc8}) — the fixture really is gating on the credential"
else
  bad "control: the run exited 0 with NO credential that can read the fixture — every check above is vacuous"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
