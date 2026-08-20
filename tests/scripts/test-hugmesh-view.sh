#!/usr/bin/env bash
# test-hugmesh-view.sh — HERMETIC gate for scripts/hugmesh-view.py, the local
# browsing tool.
#
#   bash tests/scripts/test-hugmesh-view.sh
#
# Nothing here touches a cluster, a compose stack, an emulated device, a real
# browser trust store or the network. `kubectl`, `ssh` and `certutil` are FAKE
# BINARIES on PATH (tests/qemu/devices_test.sh convention), the "upstream" is a
# loopback python server this file starts, HOME is redirected into a temp dir
# before anything looks for an NSS store, and the emulated-device registry is a
# temp directory of JSON records. Every port is bound on 127.0.0.1 and chosen at
# run time, so two copies of this suite can run at once.
#
# WHY THIS FILE EXISTS. The tool's whole job is to make a browser reach a door it
# otherwise cannot, and EVERY failure in that job is silent:
#
#   * a Host header that does not arrive gives a 404 that looks like a broken app;
#   * an un-rewritten `Location:` sends the browser to a name that does not resolve,
#     mid-SSO, so it reads as a login bug;
#   * a `Domain=` cookie is DISCARDED by the browser — the user lands back on the
#     login form with no error anywhere;
#   * an un-stripped `Strict-Transport-Security` does not fail the request at all.
#     HSTS is scoped per HOST, not per port, so ONE pinned response on 127.0.0.1
#     forces every OTHER plain-http service on this workstation's loopback to https
#     for a year — and the damage only shows up much later, somewhere else;
#   * a CA without name constraints is a skeleton key for the entire web sitting in
#     a state directory;
#   * a `kubectl port-forward` that outlives its parent keeps holding the port, so
#     the NEXT run's door quietly serves the PREVIOUS run's service.
#
# So every behaviour below is pinned with a NEGATIVE CONTROL: an arrangement in
# which the same assertion must FAIL. A gate that cannot go red is not a gate — and
# for a proxy in particular, "the page loaded" proves almost nothing about whether
# the rewriting happened.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
VIEW="${REPO}/scripts/hugmesh-view.py"
CATALOG="${REPO}/scripts/hugmesh-view.tsv"
[ -f "${VIEW}" ]    || { echo "cannot find ${VIEW}" >&2; exit 2; }
[ -f "${CATALOG}" ] || { echo "cannot find ${CATALOG}" >&2; exit 2; }
command -v openssl >/dev/null || { echo "openssl is required (the tool mints its own loopback CA with it)" >&2; exit 2; }

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq()   { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (got '$1', want '$2')"; fi; }
has()  { case "$1" in *"$2"*) _ok "$3";; *) _bad "$3 (missing '$2' in '$1')";; esac; }
hasnt(){ case "$1" in *"$2"*) _bad "$3 (found '$2' in '$1')";; *) _ok "$3";; esac; }

TMP="$(mktemp -d)"
# Exported because the python probes below read them out of the environment
# rather than being handed paths through a dozen heredoc substitutions.
export TMP CATALOG VIEW REPO
KIDS=""
cleanup() {
    for pid in ${KIDS}; do kill "${pid}" 2>/dev/null; done
    # Never `pkill -f` in here: the pattern would also match this script's own
    # command line and kill the run (observed in tests/qemu/devices_test.sh).
    rm -rf "${TMP}"
}
trap cleanup EXIT

export HUGMESH_VIEW_STATE="${TMP}/state"
# HOME is redirected BEFORE any probe runs: nss_stores() expanduser()s into the
# real ~/.pki and ~/.mozilla, and a gate that can reach an operator's actual
# browser trust store is a gate that can damage one.
export HOME="${TMP}/home"
mkdir -p "${HOME}"
# The tool reads port overrides out of the environment; a stray one from the
# operator's shell would silently retarget every assertion below.
unset HUGMESH_VIEW_TSV HUGMESH_VIEW_KUBECTL HUGMESH_VIEW_SSH HUGMESH_VIEW_WORK
while IFS= read -r v; do unset "${v}"; done < <(env | sed -n 's/^\(HUGMESH_VIEW_PORT_[A-Z0-9_]*\)=.*/\1/p')

# ── the loader every python probe uses ───────────────────────────────────────────
# The tool is a SCRIPT, not an installed module, so it is loaded by path. Loading it
# once per probe (rather than running the CLI) is what lets the pure functions —
# the rewrite rules, the collision detector, the pid guard — be driven directly.
cat > "${TMP}/hvload.py" <<PYLOAD
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hugmesh_view", "${VIEW}")
hv = importlib.util.module_from_spec(spec)
sys.modules["hugmesh_view"] = hv
spec.loader.exec_module(hv)
PYLOAD
py() { PYTHONPATH="${TMP}${PYTHONPATH:+:${PYTHONPATH}}" python3 -; }

freeport() { python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }

echo
echo "1. catalog parsing — six TAB columns, fail-closed"

eq "$(py <<'PY'
from hvload import hv
import os
rows = hv.load_catalog(os.environ["CATALOG"])
print(len(rows), ",".join(sorted({r.lane for r in rows})))
PY
)" "9 compose,device,kind,kind-svc" "the shipped catalog parses: 9 rows across the four lanes"

printf 'app\tkind\thugmesh.net\thttps://127.0.0.1:8443\t9080\n' > "${TMP}/short.tsv"
printf 'app\tkind\thugmesh.net\thttps://127.0.0.1:8443\t9080\t/login/\n' > "${TMP}/good.tsv"
has "$(py <<'PY'
from hvload import hv
import os
try:
    hv.load_catalog(os.environ["TMP"] + "/short.tsv"); print("ACCEPTED")
except hv.ViewError as e: print(e)
PY
)" "expected 6 TAB-separated columns, got 5" "a 5-column row is refused, not shifted into place"
eq "$(py <<'PY'
from hvload import hv
import os
print(hv.load_catalog(os.environ["TMP"] + "/good.tsv")[0].name)
PY
)" "app" "control: the same row with 6 columns parses (the parser is not simply refusing)"

# Spaces-not-tabs is the likeliest hand-edit mistake and it must be loud: a
# space-separated row parses as ONE column, i.e. a door pointing nowhere.
printf 'app kind hugmesh.net https://127.0.0.1:8443 9080 /login/\n' > "${TMP}/spaces.tsv"
has "$(py <<'PY'
from hvload import hv
import os
try:
    hv.load_catalog(os.environ["TMP"] + "/spaces.tsv"); print("ACCEPTED")
except hv.ViewError as e: print(e)
PY
)" "got 1" "a space-separated row is refused (columns are TABS)"

printf 'app\tkind\ta.net\thttps://127.0.0.1:1\t9080\t/\napp\tkind\tb.net\thttps://127.0.0.1:2\t9081\t/\n' > "${TMP}/dupe.tsv"
has "$(py <<'PY'
from hvload import hv
import os
try:
    hv.load_catalog(os.environ["TMP"] + "/dupe.tsv"); print("ACCEPTED")
except hv.ViewError as e: print(e)
PY
)" "duplicate row name(s): app" "two rows called 'app' are refused (the override var would be ambiguous)"

echo
echo "2. \${VAR:-default} expansion — the compose lane's own port knobs"

printf 'c\tcompose\thugmesh.net\thttp://127.0.0.1:${PUBLIC_HOST_PORT:-8088}\t9090\t/\n' > "${TMP}/env.tsv"
eq "$(py <<'PY'
from hvload import hv
import os
print(hv.load_catalog(os.environ["TMP"] + "/env.tsv", {})[0].upstream)
PY
)" "http://127.0.0.1:8088" "unset -> the documented default"
eq "$(py <<'PY'
from hvload import hv
import os
print(hv.load_catalog(os.environ["TMP"] + "/env.tsv",
                      {"PUBLIC_HOST_PORT": "18088"})[0].upstream)
PY
)" "http://127.0.0.1:18088" "control: the env value wins (the default is not hardcoded)"

printf 'c\tcompose\thugmesh.net\thttp://127.0.0.1:${NO_SUCH_KNOB}\t9090\t/\n' > "${TMP}/envbad.tsv"
has "$(py <<'PY'
from hvload import hv
import os
try:
    hv.load_catalog(os.environ["TMP"] + "/envbad.tsv", {}); print("ACCEPTED")
except hv.ViewError as e: print(e)
PY
)" "is unset and has no default" "an unset \${VAR} with no default fails loudly, not into 'http://127.0.0.1:'"

echo
echo "3. port overrides — a collision is a one-line fix"

eq "$(py <<'PY'
from hvload import hv
print(hv.env_var_for("app"), hv.env_var_for("harbor-portal"), hv.env_var_for("compose-tls"))
PY
)" "HUGMESH_VIEW_PORT_APP HUGMESH_VIEW_PORT_HARBOR_PORTAL HUGMESH_VIEW_PORT_COMPOSE_TLS" \
   "every row's override var is DERIVED from its name (a new row gets one for free)"

eq "$(py <<'PY'
from hvload import hv
import os
d = {r.name: r.port for r in hv.load_catalog(os.environ["CATALOG"],
                                             {"HUGMESH_VIEW_PORT_APP": "19999"})}
print(d["app"], d["registry"])
PY
)" "19999 9081" "HUGMESH_VIEW_PORT_APP moves ONLY that row"
eq "$(py <<'PY'
from hvload import hv
import os
print({r.name: r.port for r in hv.load_catalog(os.environ["CATALOG"], {})}["app"])
PY
)" "9080" "control: with no override the catalog default stands"

has "$(py <<'PY'
from hvload import hv
import os
try:
    hv.load_catalog(os.environ["CATALOG"], {"HUGMESH_VIEW_PORT_APP": "eight-thousand"})
    print("ACCEPTED")
except hv.ViewError as e: print(e)
PY
)" "HUGMESH_VIEW_PORT_APP" "a junk override names the variable that is wrong"

echo
echo "4. rewriting — hostnames, redirects, cookies, CSP"

out="$(py <<'PY'
from hvload import hv
m = {"hugmesh.net": "127.0.0.1:9080", "id.hugmesh.net": "127.0.0.1:9083"}
print("A", hv.rewrite_text("https://hugmesh.net/login/", m))
print("B", hv.rewrite_text('src="//id.hugmesh.net/x.js"', m))
print("C", hv.rewrite_text("go to https://id.hugmesh.net/oidc", m))
print("D", hv.rewrite_text("https://example.com/x https://hugmesh.net.evil.co/y", m))
print("E", hv.rewrite_text("https://cdn.hugmesh.net/asset.js", m))
PY
)"
has "${out}" "A https://127.0.0.1:9080/login/"     "an absolute URL on a mapped host becomes its loopback door"
has "${out}" 'B src="//127.0.0.1:9083/x.js"'       "a protocol-relative URL is rewritten too"
has "${out}" "C go to https://127.0.0.1:9083/oidc" "the SSO bounce lands on the OTHER door's port (cross-row map)"
has "${out}" "D https://example.com/x https://hugmesh.net.evil.co/y" \
    "control: an UNMAPPED host and a lookalike suffix are left exactly as they were"
has "${out}" "E https://cdn.hugmesh.net/asset.js" \
    "control: an unmapped SUBdomain is not clobbered by the apex row"

out="$(py <<'PY'
from hvload import hv
print("A", hv.rewrite_cookie("s=1; Path=/; Domain=hugmesh.net; Secure; HttpOnly; SameSite=None"))
print("B", hv.rewrite_cookie("s=1; Path=/; HttpOnly; SameSite=Lax"))
PY
)"
hasnt "${out}" "Domain=" "Set-Cookie loses Domain= (a domain the browser never visited is discarded)"
has "${out}" "A s=1; Path=/; Secure; HttpOnly; SameSite=None" \
    "Secure and SameSite=None SURVIVE — the door is https, so production's flags are rehearsed, not weakened"
has "${out}" "B s=1; Path=/; HttpOnly; SameSite=Lax" \
    "control: a cookie with no Domain= is passed through byte-identical"

out="$(py <<'PY'
from hvload import hv
m = {"hugmesh.net": "127.0.0.1:9080"}
print("A", hv.rewrite_csp("default-src 'self'; connect-src https://hugmesh.net; upgrade-insecure-requests", m))
print("B", hv.rewrite_csp("default-src 'self'; frame-ancestors 'none'", m))
PY
)"
has "${out}" "A default-src 'self'; connect-src https://127.0.0.1:9080; upgrade-insecure-requests" \
    "the CSP's host sources are re-pointed at the door and the policy is otherwise INTACT"
has "${out}" "B default-src 'self'; frame-ancestors 'none'" \
    "control: a CSP naming no mapped host is unchanged (the rewrite is surgical)"

out="$(py <<'PY'
from hvload import hv
r = {"127.0.0.1:9080": "https://hugmesh.net"}
print("A", hv.rewrite_upward("https://127.0.0.1:9080", r))
print("B", hv.rewrite_upward("https://127.0.0.1:4200", r))
print("C", "strict-transport-security" in hv.STRIP_DOWN, "content-type" in hv.STRIP_DOWN)
PY
)"
has "${out}" "A https://hugmesh.net" "Origin/Referer are rewritten back to the real vhost going UP"
has "${out}" "B https://127.0.0.1:4200" "control: an unmapped local origin is left alone"
has "${out}" "C True False" "HSTS is on the strip list; ordinary headers are NOT"

echo
echo "5. the loopback CA — constrained, or it is a skeleton key"

out="$(py <<'PY'
from hvload import hv
import os, subprocess
paths = hv.ensure_leaf(os.environ["TMP"] + "/ca", out=open(os.devnull, "w"))
text = subprocess.run(["openssl", "x509", "-in", paths["ca_crt"], "-noout", "-text"],
                      capture_output=True, text=True).stdout
print("A", "X509v3 Name Constraints" in text, "critical" in text)
print("B", "DNS:localhost" in text, "IP:127.0.0.0/255.0.0.0" in text)
leaf = subprocess.run(["openssl", "x509", "-in", paths["crt"], "-noout", "-text"],
                      capture_output=True, text=True).stdout
print("C", "IP Address:127.0.0.1" in leaf)
print("D", subprocess.run(["openssl", "verify", "-CAfile", paths["ca_crt"], paths["crt"]],
                          capture_output=True).returncode)
PY
)"
has "${out}" "A True True" "the CA carries a CRITICAL nameConstraints extension"
has "${out}" "B True True" "…permitting only localhost and 127.0.0.0/8"
has "${out}" "C True" "the leaf carries an IP SAN — a DNS-only cert would not match https://127.0.0.1"
has "${out}" "D 0" "the leaf verifies against its own CA"

# THE control that makes the constraint mean something: the same CA must be
# UNABLE to vouch for a name outside the permitted set. Without this, the
# extension could be present, misspelled and inert, and every check above would
# still pass.
out="$(py <<'PY'
from hvload import hv
import os, subprocess
d = os.environ["TMP"] + "/ca"
paths = hv.cert_paths(d)
ext = os.path.join(d, "evil.ext")
open(ext, "w").write("subjectAltName=DNS:www.example.com\n")
subprocess.run(["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout",
                d + "/evil.key", "-out", d + "/evil.csr", "-subj", "/CN=www.example.com"],
               capture_output=True)
subprocess.run(["openssl", "x509", "-req", "-in", d + "/evil.csr", "-days", "30",
                "-CA", paths["ca_crt"], "-CAkey", paths["ca_key"], "-CAcreateserial",
                "-extfile", ext, "-out", d + "/evil.crt"], capture_output=True)
r = subprocess.run(["openssl", "verify", "-CAfile", paths["ca_crt"], d + "/evil.crt"],
                   capture_output=True, text=True)
print("RC", r.returncode)
print((r.stdout + r.stderr).replace("\n", " "))
PY
)"
hasnt "${out}" "RC 0" "control: a cert this CA signs for www.example.com does NOT verify"
has "${out}" "permitted subtree violation" \
    "…and openssl rejects it BY the constraint (the extension is enforced, not decorative)"

echo
echo "6. trusting it — this user's own NSS stores only, never root's"

mkdir -p "${TMP}/bin" "${HOME}/.pki/nssdb" "${HOME}/.mozilla/firefox/abc.default"
: > "${HOME}/.mozilla/firefox/abc.default/cert9.db"
eq "$(py <<'PY'
from hvload import hv
print(len(hv.nss_stores()))
PY
)" "2" "both a Chrome nssdb and a Firefox profile are found under HOME"
hasnt "$(py <<'PY'
from hvload import hv
print(" ".join(hv.nss_stores()))
PY
)" "/etc" "control: nothing outside HOME is ever offered as a trust store"

# A certutil that records what it was asked to do and can be told to fail.
cat > "${TMP}/bin/certutil" <<'FAKE'
#!/usr/bin/env bash
echo "certutil $*" >> "${CERTUTIL_LOG}"
case " $* " in
  *" -L "*) [ -f "${CERTUTIL_INSTALLED}" ] && exit 0 || exit 255 ;;
  *" -A "*) : > "${CERTUTIL_INSTALLED}"; exit 0 ;;
  *" -D "*) rm -f "${CERTUTIL_INSTALLED}"; exit 0 ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin/certutil"
export CERTUTIL_LOG="${TMP}/certutil.log" CERTUTIL_INSTALLED="${TMP}/installed"
export PATH="${TMP}/bin:${PATH}"

trust_out="$(python3 "${VIEW}" trust --state "${TMP}/ca" 2>&1)"
has "${trust_out}" "trusted in" "trust installs the CA into every store it found"
has "${trust_out}" "RESTART the browser" "…and says why nothing changes until the browser restarts"
has "$(cat "${CERTUTIL_LOG}")" "-t C,," \
    "the CA is filed as a TLS-server authority only — not for email or code signing"
has "${trust_out}" "cannot vouch for anything else" "…and the bounded blast radius is stated"

has "$(python3 "${VIEW}" trust --state "${TMP}/ca" 2>&1)" "already trusted" \
    "control: a second trust is a no-op, not a duplicate install"
has "$(python3 "${VIEW}" untrust --state "${TMP}/ca" 2>&1)" "removed from" "untrust removes it again"
has "$(python3 "${VIEW}" untrust --state "${TMP}/ca" 2>&1)" "not installed in any store" \
    "control: untrusting twice says so instead of claiming a removal"

echo
echo "7. the live door — TLS, rewrites, and http on the same port"

cat > "${TMP}/upstream.py" <<'PY'
"""A stand-in front door that emits every hostile thing the real one does."""
import http.server, json, sys

SEEN_LAST = {}

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == "/seen":
            b = json.dumps(SEEN_LAST).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers(); self.wfile.write(b); return
        SEEN_LAST.clear()
        SEEN_LAST.update({k.lower(): v for k, v in self.headers.items()})
        b = b'<a href="https://hugmesh.net/next">next</a>'
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
        self.send_header("Set-Cookie", "sess=abc; Path=/; Domain=hugmesh.net; Secure; SameSite=None")
        self.send_header("Location", "https://hugmesh.net/after")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)

    def log_message(self, *a): pass

srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H)
srv.serve_forever()
PY

UP_PORT="$(freeport)"; DOOR_PORT="$(freeport)"
python3 "${TMP}/upstream.py" "${UP_PORT}" & KIDS="${KIDS} $!"
for _ in $(seq 60); do
    python3 -c "import socket,sys;s=socket.socket();s.settimeout(.3);sys.exit(0 if s.connect_ex(('127.0.0.1',${UP_PORT}))==0 else 1)" && break
    sleep 0.1
done

printf 'app\tkind\thugmesh.net\thttp://127.0.0.1:%s\t%s\t/\n' "${UP_PORT}" "${DOOR_PORT}" > "${TMP}/live.tsv"
python3 "${VIEW}" up --catalog "${TMP}/live.tsv" --lane kind > "${TMP}/up.log" 2>&1 & KIDS="${KIDS} $!"
for _ in $(seq 120); do [ -f "${HUGMESH_VIEW_STATE}/session.json" ] && break; sleep 0.1; done

# The CA file the door was minted with is the ONLY trust anchor this fetch gets:
# passing it (rather than disabling verification) is what proves the certificate
# actually chains and that its SAN matches a literal 127.0.0.1.
cat > "${TMP}/fetch.py" <<'PY'
import json, ssl, sys, urllib.error, urllib.request
ctx = ssl.create_default_context(cafile=sys.argv[2])
try:
    r = urllib.request.urlopen(sys.argv[1], timeout=15, context=ctx)
    h, b = r.headers, r.read()
except urllib.error.HTTPError as e:
    h, b = e.headers, e.read()
for k, v in h.items():
    print(f"H {k.lower()}: {v}")
print("BODY " + b.decode("utf-8", "replace").replace("\n", " "))
PY
CA="${HUGMESH_VIEW_STATE}/tls/ca.crt"
through="$(python3 "${TMP}/fetch.py" "https://127.0.0.1:${DOOR_PORT}/" "${CA}" 2>&1)"
# Read back what the upstream SAW, before the control fetch below overwrites it:
# that control talks to the upstream DIRECTLY, so it would replace the proxied
# request's headers with its own and every Host assertion would pass vacuously.
seen="$(python3 "${TMP}/fetch.py" "https://127.0.0.1:${DOOR_PORT}/seen" "${CA}" | sed -n 's/^BODY //p')"
direct="$(python3 - "http://127.0.0.1:${UP_PORT}/" <<'PY'
import sys, urllib.request
r = urllib.request.urlopen(sys.argv[1], timeout=15)
for k, v in r.headers.items():
    print(f"H {k.lower()}: {v}")
print("BODY " + r.read().decode().replace("\n", " "))
PY
)"

has   "${through}" "H content-type: text/html" "the door serves over TLS, verified against its OWN minted CA"
hasnt "${through}" "strict-transport-security" "HSTS never reaches the browser (it would pin ALL of 127.0.0.1)"
has   "${direct}"  "strict-transport-security" "control: the upstream really does send HSTS"
has   "${through}" "H location: https://127.0.0.1:${DOOR_PORT}/after" "Location is rewritten to the loopback door"
has   "${direct}"  "H location: https://hugmesh.net/after" "control: the upstream really does redirect off-loopback"
has   "${through}" "BODY <a href=\"https://127.0.0.1:${DOOR_PORT}/next\">" "an absolute URL in the BODY is rewritten"
has   "${direct}"  "BODY <a href=\"https://hugmesh.net/next\">" "control: the upstream body really is absolute"
hasnt "${through}" "Domain=hugmesh.net" "the cookie's Domain= is gone"
has   "${through}" "sess=abc; Path=/; Secure; SameSite=None" "…and Secure/SameSite=None survive intact"

has "${seen}" '"host": "hugmesh.net"' "the UPSTREAM sees Host: hugmesh.net — the whole reason the tool exists"
has "${seen}" '"x-forwarded-proto": "https"' "X-Forwarded-Proto is https so the app builds https URLs"
has "${seen}" '"accept-encoding": "identity"' \
    "Accept-Encoding is forced to identity (a br/zstd body would silently defeat the rewrite)"

# An old http:// bookmark must still land, on the SAME port.
redir="$(python3 - "http://127.0.0.1:${DOOR_PORT}/login/" <<'PY'
import sys, urllib.error, urllib.request
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
op = urllib.request.build_opener(NoRedirect)
try:
    r = op.open(sys.argv[1], timeout=15); print(r.status, r.headers.get("Location"))
except urllib.error.HTTPError as e: print(e.code, e.headers.get("Location"))
PY
)"
eq "${redir}" "308 https://127.0.0.1:${DOOR_PORT}/login/" \
   "plain http on the door's own port 308s to https, preserving the path"

python3 "${VIEW}" stop >/dev/null 2>&1

echo
echo "8. port collisions — detected before anything binds"

busy="$(freeport)"
python3 - "${busy}" <<'PY' & KIDS="${KIDS} $!"
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); time.sleep(120)
PY
for _ in $(seq 60); do
    python3 -c "import socket,sys;s=socket.socket();s.settimeout(.3);sys.exit(0 if s.connect_ex(('127.0.0.1',${busy}))==0 else 1)" && break
    sleep 0.1
done

out="$(BUSY="${busy}" py <<'PY'
from hvload import hv
import os, socket
busy = int(os.environ["BUSY"])
s = socket.socket(); s.bind(("127.0.0.1", 0)); free = s.getsockname()[1]; s.close()
E = hv.Entry
same = [E("app", "kind", "a", "http://x:1", 4711, "/"),
        E("registry", "kind", "b", "http://x:2", 4711, "/")]
print("A", "|".join(hv.port_collisions(same)))
print("B", "|".join(hv.port_collisions([E("app", "kind", "a", "http://x:1", free, "/")])) or "NONE")
print("C", "|".join(hv.port_collisions([E("app", "kind", "a", "http://x:1", busy, "/")])))
PY
)"
has "${out}" "rows 'app' and 'registry' both want port 4711" "two rows on one port is caught in the catalog"
has "${out}" "set HUGMESH_VIEW_PORT_REGISTRY=" "…and the message names the exact one-line fix"
has "${out}" "B NONE" "control: distinct free ports produce NO complaint (the detector is not always-red)"
has "${out}" "C port ${busy} (app) is already in use" "a port somebody else LISTENS on is caught before bind"

# The probe must predict the bind it stands in for. TLSServer inherits
# allow_reuse_address=True, so a door that has served traffic leaves TIME_WAIT
# entries on its own port; a probe without SO_REUSEADDR called that a collision
# and told the operator to change a port that was fine. Observed: `make view` ->
# browse -> `make view-stop` -> `make view` failed for ~60s.
tw="$(py <<'PY'
from hvload import hv
import socket, threading
# Produce a real TIME_WAIT on a port by connecting and closing from the CLIENT
# side, which is what a browser does to a door.
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0)); srv.listen(1)
port = srv.getsockname()[1]
c = socket.socket(); c.connect(("127.0.0.1", port))
a, _ = srv.accept()
a.close(); srv.close()
c.close()
print("free_after_timewait", hv.port_is_free(port))
import http.server
print("server_reuses", http.server.ThreadingHTTPServer.allow_reuse_address)
PY
)"
has "${tw}" "free_after_timewait True" \
    "a port left in TIME_WAIT is NOT reported busy — the probe matches the server's SO_REUSEADDR bind"
has "${tw}" "server_reuses True" \
    "control: the server really does set SO_REUSEADDR (which is what makes the above correct, not lax)"

echo
echo "9. kubectl port-forward — lifecycle, health check and cleanup"

# A fake kubectl that behaves like the real one on the ONE surface the tool uses:
# it prints `Forwarding from 127.0.0.1:<port> -> <remote>` and then actually serves,
# so the tool's health check has something real to connect to.
cat > "${TMP}/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
exec python3 - "$@" <<'PY'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        b = b"fake-service-behind-the-port-forward"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
port = srv.server_address[1]
print(f"Forwarding from 127.0.0.1:{port} -> 8000", flush=True)
print(f"Forwarding from [::1]:{port} -> 8000", flush=True)
srv.serve_forever()
PY
FAKE
chmod +x "${TMP}/bin/kubectl"
export HUGMESH_VIEW_KUBECTL="${TMP}/bin/kubectl"

PF_DOOR="$(freeport)"
printf 'casdoor\tkind-svc\t-\tk8s+http://hugmesh-pki/casdoor:8000\t%s\t/\n' "${PF_DOOR}" > "${TMP}/pf.tsv"
python3 "${VIEW}" up --catalog "${TMP}/pf.tsv" --lane kind-svc --background > "${TMP}/pf.log" 2>&1
eq "$?" "0" "a ClusterIP-only row comes up through a port-forward"
body="$(python3 "${TMP}/fetch.py" "https://127.0.0.1:${PF_DOOR}/" "${HUGMESH_VIEW_STATE}/tls/ca.crt" 2>&1 | sed -n 's/^BODY //p')"
eq "${body}" "fake-service-behind-the-port-forward" "the door really proxies THROUGH the forward"

PF_PID="$(python3 -c "import json;print(json.load(open('${HUGMESH_VIEW_STATE}/session.json'))['children'][0]['pid'])")"
eq "$(kill -0 "${PF_PID}" 2>/dev/null && echo alive || echo gone)" "alive" "the forward is recorded and running"

# The negative control for cleanup: an IDENTICAL fake started outside the session.
# Without it, "the child is gone" would also pass for a test that killed nothing and
# merely watched a process exit on its own.
"${TMP}/bin/kubectl" port-forward -n control svc/control :8000 >/dev/null 2>&1 & CTL_PID=$!
KIDS="${KIDS} ${CTL_PID}"
sleep 0.5

python3 "${VIEW}" stop > "${TMP}/stop.log" 2>&1
sleep 0.5
eq "$(kill -0 "${PF_PID}" 2>/dev/null && echo alive || echo gone)" "gone"  "stop() reaps the port-forward it started"
eq "$(kill -0 "${CTL_PID}" 2>/dev/null && echo alive || echo gone)" "alive" \
   "control: an unrelated port-forward is NOT killed (the sweep is targeted, not a pkill)"
has "$(cat "${TMP}/stop.log")" "stopped port-forward for 'casdoor'" "stop() says what it stopped"
kill "${CTL_PID}" 2>/dev/null

echo
echo "10. stale sweep — the leftover that silently squats a port"

"${TMP}/bin/kubectl" port-forward -n stale svc/stale :8000 >/dev/null 2>&1 & STALE_PID=$!
KIDS="${KIDS} ${STALE_PID}"
sleep 0.5
# A pid that is certainly dead: a subshell reports its own pid and exits. The sweep's
# marker check means a REUSED number cannot masquerade as the old owner either.
DEAD_PID="$(bash -c 'echo $$')"
mkdir -p "${HUGMESH_VIEW_STATE}"
python3 - <<PY
import json, os
json.dump({"pid": ${DEAD_PID}, "marker": "hugmesh-view", "children": [
    {"name": "ghost", "kind": "port-forward", "pid": ${STALE_PID},
     "marker": "port-forward", "port": 1}]},
    open(os.path.join("${HUGMESH_VIEW_STATE}", "session.json"), "w"))
PY
SWEEP_DOOR="$(freeport)"
printf 'app\tkind\thugmesh.net\thttp://127.0.0.1:%s\t%s\t/\n' "${UP_PORT}" "${SWEEP_DOOR}" > "${TMP}/sweep.tsv"
python3 "${VIEW}" up --catalog "${TMP}/sweep.tsv" --lane kind --background > "${TMP}/sweep.log" 2>&1
sleep 0.5
has "$(cat "${TMP}/sweep.log")" "swept stale port-forward for 'ghost'" \
    "a crashed run's leftover forward is swept, and SAID so"
eq "$(kill -0 "${STALE_PID}" 2>/dev/null && echo alive || echo gone)" "gone" "…and is really gone"

# A live owner must be refused, not raced: two sessions on one port set is the very
# collision this whole file is about.
second="$(python3 "${VIEW}" up --catalog "${TMP}/sweep.tsv" --lane kind --background 2>&1)"
has "${second}" "already running" "a second session refuses while the first owns the state"
python3 "${VIEW}" stop >/dev/null 2>&1
eq "$(python3 "${VIEW}" up --catalog "${TMP}/sweep.tsv" --lane kind --background >/dev/null 2>&1; echo $?)" "0" \
   "control: after stop, the same lane comes up again on the same port"
python3 "${VIEW}" stop >/dev/null 2>&1

echo
echo "11. the pid guard — a recycled pid must not be signalled"

sleep 120 & SLEEP_PID=$!
KIDS="${KIDS} ${SLEEP_PID}"
out="$(SLEEP_PID="${SLEEP_PID}" py <<'PY'
from hvload import hv
import os, time
pid = int(os.environ["SLEEP_PID"])
print("A", hv.kill_pid(pid, "port-forward"))     # wrong marker: must refuse
time.sleep(0.2)
print("B", hv.pid_matches(pid, "sleep"))          # still alive
print("C", hv.kill_pid(pid, "sleep"))             # right marker: must kill
time.sleep(0.3)
print("D", hv.pid_matches(pid, "sleep"))
PY
)"
has "${out}" "A False" "a pid whose cmdline does not match the marker is NOT signalled"
has "${out}" "B True"  "…and it is still alive afterwards (the refusal was real)"
has "${out}" "C True"  "control: with the recorded marker the same pid IS killed"
has "${out}" "D False" "…and is gone"

echo
echo "12. emulated-device lane — gated on a device actually being up"

mkdir -p "${TMP}/work/devices"
: > "${TMP}/work/id_test"
write_dev() { # label state port
    python3 - "$1" "$2" "$3" <<PY
import json, sys
label, state, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
json.dump({"label": label, "state": state, "ssh_host_port": port,
           "ssh_user": "hugmesh", "ssh_key": "${TMP}/work/id_test",
           "started_at": "2026-08-20T00:00:0%dZ" % (port % 10)},
          open("${TMP}/work/devices/" + label.replace("/", "_") + ".json", "w"))
PY
}

write_dev "rpi5/pki" stopped 22300
write_dev "x86/fe"   stopped 22305
has "$(HUGMESH_VIEW_WORK="${TMP}/work" py <<'PY'
from hvload import hv
import os
try:
    hv.resolve_device("@gateway", os.environ); print("RESOLVED")
except hv.ViewError as e: print(e)
PY
)" "no RUNNING emulated device" "every device stopped -> the lane refuses instead of tunnelling to a dead port"

write_dev "x86/fe" running 22305
out="$(HUGMESH_VIEW_WORK="${TMP}/work" py <<'PY'
from hvload import hv
import os
emu, dev = hv.resolve_device("@gateway", os.environ)
print("A", dev.label, dev.state)
print("B", " ".join(emu.web_tunnel_argv(dev, hv._Planned(label=dev.label, ui_port=9095))))
PY
)"
has "${out}" "A x86/fe running" "control: with a RUNNING device, @gateway resolves to the front-door row"
has "${out}" "B ssh " "the tunnel argv comes from studio's web_tunnel_argv, not a second spelling here"
has "${out}" "-L 9095:127.0.0.1:443" "…and forwards the allocated port onto the guest's own ingress"
has "${out}" "-p 22305" "…over the ssh port the REGISTRY published, never a guessed one"

write_dev "rpi5/pki" running 22300
eq "$(HUGMESH_VIEW_WORK="${TMP}/work" py <<'PY'
from hvload import hv
import os
print(hv.resolve_device("@gateway", os.environ)[1].label)
PY
)" "x86/fe" "control: with two devices running, @gateway still picks the gateway role"

write_dev "x86/fe" stopped 22305
has "$(HUGMESH_VIEW_WORK="${TMP}/work" py <<'PY'
from hvload import hv
import os
try:
    hv.resolve_device("x86/fe", os.environ); print("RESOLVED")
except hv.ViewError as e: print(e)
PY
)" "'x86/fe' is not running" "naming a stopped device by label is refused too"

echo
echo "13. lane selection"

out="$(py <<'PY'
from hvload import hv
import os
rows = hv.load_catalog(os.environ["CATALOG"], {})
print("A", ",".join(e.name for e in hv.select(rows, "kind", [])))
print("B", ",".join(e.name for e in hv.select(rows, "compose", [])))
print("C", ",".join(e.name for e in hv.select(rows, "kind-svc", ["vault"])))
try:
    hv.select(rows, "kind", ["nope"]); print("D ACCEPTED")
except hv.ViewError as e: print("D", e)
PY
)"
eq "$(printf '%s\n' "${out}" | sed -n 's/^A //p')" "app" \
   "the DEFAULT lane is one door — the host shell, not a row of side ports"
has "${out}" "B compose-app,compose-tls" "--lane compose selects only the compose rows"
has "${out}" "C vault" "control: --only overrides the lane and selects one row"
has "${out}" "D no such row(s): nope" "an unknown --only is refused with the list of real names"

echo
printf 'hugmesh-view gate: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
