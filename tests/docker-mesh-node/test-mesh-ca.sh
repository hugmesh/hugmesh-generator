#!/usr/bin/env bash
# test-mesh-ca.sh — the docker mesh-node client carries the mesh CA (hugmesh-generator#1040).
#
# THE DEFECT. clients/docker-mesh-node/entrypoint.sh joined with `tailscale up --login-server <url>` and
# ran the Casdoor device-code login with nothing but the Tailscale image's PUBLIC root store. A private mesh
# serves headscale and Casdoor over its own CA, so the join failed with a bare TLS error (or pushed the
# operator toward an insecure flag), and the keys-folder contract never said where the CA goes.
#
# PROVES, with openssl + python3 + curl, no docker, no network beyond 127.0.0.1:
#   (1) a real HTTPS control endpoint signed by a throwaway mesh CA: with the CA in keys/certs/ the entrypoint
#       installs it, probes the endpoint, and runs `tailscale up --login-server https://...` (a fake tailscale
#       records argv); WITHOUT it the entrypoint refuses before tailscaled starts, naming
#       <keys>/certs/cluster-ca.crt, with no raw TLS text; a WRONG CA is refused and says so;
#   (2) a file in certs/ that is not a certificate (a private key) is refused by name and never copied into
#       the trust store; every *.crt and *.pem is installed;
#   (3) http control URLs and a server that is merely down are not trust verdicts: the join goes ahead;
#   (4) an https Casdoor issuer the container does not trust skips the login with the same message, while the
#       mesh join still runs;
#   (5) no insecure flag anywhere in the client (curl -k / --insecure / skip-verify);
#   (6) mutations: the install step removed -> (1) turns red; the TLS probe removed -> the refusal is gone.
# The container's trust store is modelled by SNAP_CA_INSTALL_DIR + a fake update-ca-certificates that rebuilds
# the bundle curl reads (CURL_CA_BUNDLE); the real image's update-ca-certificates does the same job.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
ENTRY="${REPO}/clients/docker-mesh-node/entrypoint.sh"
P=0; F=0
ok()  { echo "  ok   $*"; P=$((P + 1)); }
bad() { echo "  FAIL $*"; F=$((F + 1)); }

for t in bash openssl python3 curl jq timeout; do
  command -v "${t}" >/dev/null 2>&1 || { echo "  FAIL ${t} is required (refusing to skip)"; exit 2; }
done
[ -r "${ENTRY}" ] || { echo "  FAIL ${ENTRY} is missing"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-mesh-ca.XXXXXX")"
SRV_PID=""
cleanup() { [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null; wait 2>/dev/null; rm -rf "${WORK}"; }
trap cleanup EXIT

echo "== docker mesh-node: the mesh CA =="
# ── PKI: a mesh CA, a server leaf it signed (SAN 127.0.0.1), and an unrelated 'public' CA ──
mkca() { # mkca <dir> <cn>
  mkdir -p "$1"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$1/ca.key" -out "$1/ca.crt" -days 2 -subj "/CN=$2" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
}
mkca "${WORK}/mesh" "test mesh CA"
mkca "${WORK}/public" "test public CA"
mkca "${WORK}/other" "test other mesh CA"
openssl req -newkey rsa:2048 -nodes -keyout "${WORK}/srv.key" -out "${WORK}/srv.csr" -subj "/CN=127.0.0.1" >/dev/null 2>&1
printf 'subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > "${WORK}/srv.ext"
openssl x509 -req -in "${WORK}/srv.csr" -CA "${WORK}/mesh/ca.crt" -CAkey "${WORK}/mesh/ca.key" -CAcreateserial \
  -out "${WORK}/srv.crt" -days 2 -extfile "${WORK}/srv.ext" >/dev/null 2>&1
[ -s "${WORK}/srv.crt" ] && ok "built a throwaway mesh CA and a server certificate it signed" || { bad "could not build the test PKI"; exit 1; }

cat > "${WORK}/server.py" <<'PY'
import http.server, ssl, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        b = b'{"publicKey":"mkey:test"}'
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(sys.argv[1], sys.argv[2])
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
open(sys.argv[3], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "${WORK}/server.py" "${WORK}/srv.crt" "${WORK}/srv.key" "${WORK}/port" >"${WORK}/server.log" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "${WORK}/port" ] && break; sleep 0.1; done
PORT="$(cat "${WORK}/port" 2>/dev/null || true)"
[ -n "${PORT}" ] && ok "an HTTPS control endpoint is listening on 127.0.0.1:${PORT}" || { bad "the test server did not start: $(head -3 "${WORK}/server.log")"; exit 1; }
URL="https://127.0.0.1:${PORT}"
CLOSED_URL="https://127.0.0.1:1"

# ── the fakes: tailscale/tailscaled record argv; update-ca-certificates rebuilds the bundle ──
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/tailscale" <<'F'
#!/usr/bin/env bash
printf 'tailscale %s\n' "$*" >> "${FAKE_LOG}"
exit 0
F
cat > "${WORK}/bin/tailscaled" <<'F'
#!/usr/bin/env bash
printf 'tailscaled %s\n' "$*" >> "${FAKE_LOG}"
sock=""; for a in "$@"; do case "$a" in --socket=*) sock="${a#--socket=}";; esac; done
python3 -c "import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); time.sleep(1)" "${sock}"
exit 0
F
cat > "${WORK}/bin/update-ca" <<'F'
#!/usr/bin/env bash
printf 'update-ca\n' >> "${FAKE_LOG}"
cat "${SNAP_CA_INSTALL_DIR}"/*.crt "${FAKE_BASE_BUNDLE}" > "${CURL_CA_BUNDLE}"
F
chmod +x "${WORK}/bin/"*

# run <name> <entrypoint> <keys-dir> [env...] -> OUT, RC; per-run dirs under ${WORK}/<name>
run() {
  local name="$1" entry="$2" keys="$3"; shift 3
  local d="${WORK}/run-${name}"; rm -rf "${d}"; mkdir -p "${d}/state" "${d}/ca"
  cp "${WORK}/public/ca.crt" "${d}/base.pem"; cp "${d}/base.pem" "${d}/bundle.pem"
  : > "${d}/log"
  RUNDIR="${d}"
  OUT="$(env -i PATH="${WORK}/bin:${PATH}" HOME="${d}" TMPDIR="${d}" \
        SNAP_KEYS_DIR="${keys}" SNAP_STATE_DIR="${d}/state" SNAP_TS_SOCKET="${d}/ts.sock" \
        SNAP_CA_INSTALL_DIR="${d}/ca" SNAP_UPDATE_CA_CMD="${WORK}/bin/update-ca" \
        CURL_CA_BUNDLE="${d}/bundle.pem" FAKE_BASE_BUNDLE="${d}/base.pem" FAKE_LOG="${d}/log" \
        "$@" timeout 90 bash "${entry}" 2>&1)"; RC=$?
}
mkkeys() { # mkkeys <name> <login-server> -> dir; an authkey and a login-server, no certs
  local k="${WORK}/keys-$1"; rm -rf "${k}"; mkdir -p "${k}/tailscale"
  printf 'tskey-test-not-a-secret' > "${k}/tailscale/authkey"; printf '%s' "$2" > "${k}/login-server"; echo "${k}"
}
joined() { grep -q "^tailscale up .*--login-server $1" "${RUNDIR}/log"; }
started() { grep -q '^tailscaled ' "${RUNDIR}/log"; }

# (1) with the CA, without it, with the wrong one
K="$(mkkeys with "${URL}")"; mkdir -p "${K}/certs"; cp "${WORK}/mesh/ca.crt" "${K}/certs/cluster-ca.crt"
run with "${ENTRY}" "${K}"
[ "${RC}" -eq 0 ] && joined "${URL}" && ok "with certs/cluster-ca.crt: the CA is installed, the endpoint verifies, tailscale up --login-server ${URL} runs" \
  || bad "with the CA: rc=${RC}, joined=$(joined "${URL}" && echo y || echo n): $(tail -4 <<<"${OUT}")"
cmp -s "${RUNDIR}/ca/hugmesh-mesh-ca-1.crt" "${WORK}/mesh/ca.crt" && ok "the mesh CA landed in the trust-store directory byte for byte" || bad "the CA was not installed as hugmesh-mesh-ca-1.crt"
grep -q '^update-ca$' "${RUNDIR}/log" && ok "update-ca-certificates ran" || bad "update-ca-certificates did not run"
grep -F -q "installed 1 mesh CA certificate" <<<"${OUT}" && ok "the log says one mesh CA certificate was installed" || bad "no install line: ${OUT}"

K="$(mkkeys without "${URL}")"
run without "${ENTRY}" "${K}"
[ "${RC}" -ne 0 ] && ! started && ! joined "${URL}" && grep -F -q "${K}/certs/cluster-ca.crt" <<<"${OUT}" && grep -q 'FATAL' <<<"${OUT}" \
  && ok "without the CA: refused before tailscaled starts, naming ${K##*/}/certs/cluster-ca.crt" \
  || bad "without the CA: rc=${RC}, started=$(started && echo y || echo n): ${OUT}"
grep -qiE 'curl:|SSL certificate problem|certificate verify failed|x509' <<<"${OUT}" && bad "the refusal leaks raw TLS text: ${OUT}" || ok "the refusal is a message, not a TLS error"

K="$(mkkeys wrong "${URL}")"; mkdir -p "${K}/certs"; cp "${WORK}/other/ca.crt" "${K}/certs/cluster-ca.crt"
run wrong "${ENTRY}" "${K}"
[ "${RC}" -ne 0 ] && ! started && grep -F -q 'do not verify it' <<<"${OUT}" \
  && ok "a CA from another mesh: refused, and the message says the files do not verify the server" || bad "wrong CA: rc=${RC}: ${OUT}"

# (2) what may sit in certs/
K="$(mkkeys key "${URL}")"; mkdir -p "${K}/certs"; cp "${WORK}/mesh/ca.crt" "${K}/certs/cluster-ca.crt"; cp "${WORK}/mesh/ca.key" "${K}/certs/mesh-ca.key.pem"
run key "${ENTRY}" "${K}"
[ "${RC}" -ne 0 ] && ! started && grep -F -q "${K}/certs/mesh-ca.key.pem is not a PEM certificate" <<<"${OUT}" && [ -z "$(ls -A "${RUNDIR}/ca")" ] \
  && ok "a private key in certs/ is refused by name and nothing was installed" || bad "key in certs/: rc=${RC}, installed=$(ls "${RUNDIR}/ca" | tr '\n' ' '): ${OUT}"
K="$(mkkeys two "${URL}")"; mkdir -p "${K}/certs"; cp "${WORK}/mesh/ca.crt" "${K}/certs/a.crt"; cp "${WORK}/public/ca.crt" "${K}/certs/b.pem"
run two "${ENTRY}" "${K}"
[ "${RC}" -eq 0 ] && [ -f "${RUNDIR}/ca/hugmesh-mesh-ca-1.crt" ] && [ -f "${RUNDIR}/ca/hugmesh-mesh-ca-2.crt" ] && joined "${URL}" \
  && ok "every *.crt and *.pem in certs/ is installed (2 files, join runs)" || bad "two CA files: rc=${RC}: ${OUT}"

# (3) not trust verdicts
K="$(mkkeys http "http://127.0.0.1:${PORT}")"
run http "${ENTRY}" "${K}"
[ "${RC}" -eq 0 ] && joined "http://127.0.0.1:${PORT}" && ok "an http control URL is not probed and the join goes ahead" || bad "http control URL: rc=${RC}: ${OUT}"
K="$(mkkeys down "${CLOSED_URL}")"
run down "${ENTRY}" "${K}"
[ "${RC}" -eq 0 ] && joined "${CLOSED_URL}" && ok "an https control server that is merely down is not a trust verdict: the join goes ahead (tailscaled retries)" \
  || bad "down control server: rc=${RC}: ${OUT}"
K="$(mkkeys none "")"; : > "${K}/login-server"
run none "${ENTRY}" "${K}"
[ "${RC}" -eq 0 ] && started && ok "no control URL (tailscale's default): no probe, the join goes ahead" || bad "no control URL: rc=${RC}: ${OUT}"

# (4) Casdoor issuer
K="$(mkkeys cd-untrusted "")"; : > "${K}/login-server"
printf '{"issuer":"%s","client_id":"x","domain":"example.test"}' "${URL}" > "${K}/casdoor.json"
run cdun "${ENTRY}" "${K}"
[ "${RC}" -eq 0 ] && started && grep -F -q "Casdoor: ${URL} presents a certificate this container does not trust" <<<"${OUT}" && grep -F -q "${K}/certs/cluster-ca.crt" <<<"${OUT}" \
  && grep -F -q 'Skipping the Casdoor login' <<<"${OUT}" && ok "an untrusted Casdoor issuer: the login is skipped with the CA message, the join still ran" \
  || bad "untrusted Casdoor: rc=${RC}: ${OUT}"
K="$(mkkeys cd-trusted "")"; : > "${K}/login-server"; mkdir -p "${K}/certs"; cp "${WORK}/mesh/ca.crt" "${K}/certs/cluster-ca.crt"
printf '{"issuer":"%s","client_id":"x","domain":"example.test"}' "${URL}" > "${K}/casdoor.json"
run cdok "${ENTRY}" "${K}"
! grep -F -q 'does not trust' <<<"${OUT}" && ok "with the CA the Casdoor issuer is trusted (no trust message)" || bad "trusted Casdoor still reported untrusted: ${OUT}"

# (5) no insecure switch anywhere in the client
hits="$(find "${REPO}/clients/docker-mesh-node" -type f \( -name '*.sh' -o -name '*.ps1' -o -name '*.cmd' -o -name Dockerfile \) -print0 \
        | xargs -0 grep -nE -- '(curl[^|#]*[[:space:]](-k|-[a-zA-Z]*k[a-zA-Z]*)[[:space:]])|--insecure|skip-?verify|--tls-skip|NODE_TLS_REJECT_UNAUTHORIZED|-SkipCertificateCheck' 2>/dev/null | head -3 || true)"
[ -z "${hits}" ] && ok "no curl -k / --insecure / skip-verify anywhere in the client" || bad "an insecure switch in the client: ${hits}"
printf 'curl -k https://x\n' > "${WORK}/ctl.sh"
grep -qE -- '(curl[^|#]*[[:space:]](-k|-[a-zA-Z]*k[a-zA-Z]*)[[:space:]])' "${WORK}/ctl.sh" && ok "control: the scan recognises curl -k" || bad "control: the insecure-flag scan is blind to curl -k"

# (6) mutations
sed 's|^install_mesh_ca$|true|' "${ENTRY}" > "${WORK}/entry-noinstall.sh"
cmp -s "${ENTRY}" "${WORK}/entry-noinstall.sh" && bad "mut no-install: the copy did not change" || {
  K="$(mkkeys m1 "${URL}")"; mkdir -p "${K}/certs"; cp "${WORK}/mesh/ca.crt" "${K}/certs/cluster-ca.crt"
  run m1 "${WORK}/entry-noinstall.sh" "${K}"
  [ "${RC}" -ne 0 ] && ! joined "${URL}" && ok "mut no-install: even with the CA in certs/ the join is refused (case 1 would go red)" || bad "mut no-install: NOT caught (rc=${RC})"; }
python3 - "${ENTRY}" "${WORK}/entry-noprobe.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = 'if [ -n "${LOGIN_SERVER}" ] && tls_untrusted "${LOGIN_SERVER}"; then'
assert s.count(a) == 1
open(sys.argv[2], "w").write(s.replace(a, 'if false; then'))
PY
K="$(mkkeys m2 "${URL}")"
run m2 "${WORK}/entry-noprobe.sh" "${K}"
[ "${RC}" -eq 0 ] && joined "${URL}" && ! grep -F -q 'FATAL' <<<"${OUT}" && ok "mut no-probe: without the CA the join is attempted against an untrusted server (case 'without' would go red)" || bad "mut no-probe: NOT caught (rc=${RC})"

echo
echo "${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
