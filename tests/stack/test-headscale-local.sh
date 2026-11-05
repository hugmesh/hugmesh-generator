#!/usr/bin/env bash
# test-headscale-local.sh — the guard for `make stack-up HEADSCALE=1`: a tailnet
# control server in the LOCAL docker mesh (docs/LOCAL-MESH-HEADSCALE.md).
#
# STATIC LEG (always; no docker, no network; python3 + PyYAML + jq + ssh-keygen,
# which the debian shell-suites job installs):
#   1. compose.local.yaml: hugmesh-headscale exists ONLY behind the `headscale`
#      profile, builds ./headscale, publishes NO host port, mounts the device
#      policy template read-only, and carries the five Studio auto-detect labels.
#      admin-bff in this file mentions no mesh-token/headscale wiring at all (that
#      lives in the overlay), and nothing turns APP_REGISTRY_HEADSCALE_ACL_ENABLED on.
#   2. compose.headscale.yaml (the HEADSCALE=1 overlay): admin-bff gets the
#      APP_MESH_TOKEN_* settings, the API-key volume READ-ONLY and the issuer key
#      as a file secret, and depends on a healthy headscale. With the docker CLI
#      present, the unprofiled `docker compose config` is compared byte for byte
#      with the config of the same file minus the headscale service and volumes.
#   3. tls-front/default.conf: an `hs.` virtual host on the same :8443 listener
#      that proxies to hugmesh-headscale:8080 with the re-resolve idiom and the
#      Upgrade/Connection pass-through, keeps headscale's /api and /swagger off
#      the door, and leaves the main server block on the fe-gateway.
#   4. Makefile: a plain stack-up/build/ps/logs argv is unchanged by the knob
#      (no headscale, no HUGMESH_DOMAIN); HEADSCALE=1 adds the profile, the
#      overlay and the env, mints the issuer key BEFORE compose runs, and
#      threads the SAME domain stack-certs mints the leaf for; down/halt/clean
#      reap the profile unconditionally.
#   5. stack-mesh-token-key, run for real into a temp dir: an ed25519 key, 0600,
#      kept on a second run (same fingerprint, not re-minted), a refusal when a
#      directory sits at the path, and output that is the fingerprint and nothing
#      of the key. The key dir is gitignored.
#   6. The entrypoint, in render-only mode: server_url, the policy rendered from
#      the device template with one ownerless tag:mesh_<id> and only the
#      superadmin ssh rule, bad inputs refused before anything is written, no xtrace, and no
#      line that could print the API key.
#   7. The Dockerfile copies the fleet-pinned headscale 0.23.0 binary.
# Then NEGATIVE CONTROLS: each mutates a copy of the tree in one way and
# re-runs this file's static leg over it (HS_GUARD_ROOT); every one must go red,
# and an unmutated copy must stay green.
#
# LIVE LEG (HUGMESH_HEADSCALE_LIVE=1; needs docker and the network to pull):
# a THROWAWAY compose project (unique name, a free high port, its own CA in a
# temp dir; never hugmesh-local, never 8000/8088/8488/9080) brings up ONLY
# hugmesh-headscale + hugmesh-https-front, then asserts:
#   * the container goes healthy; the API key file is 0600 root and its value
#     appears in no container log;
#   * POST /api/v1/preauthkey (Bearer key, in-network) with aclTags
#     ["tag:hugmesh"] stores a key carrying exactly that tag (read back with
#     GET: 0.23's create response echoes aclTags as []); without the bearer it
#     is refused; through the front door /api is 404;
#   * a tailscale probe joins through https://hs.<domain>:<port> with that key
#     while self-advertising tag:superadmin, and headscale reports
#     forced_tags == ["tag:hugmesh"] and tag:superadmin NOT valid (invalid_tags).
#     The probe must also come ONLINE (0.23 builds no map while the policy
#     names a tag nothing resolves). The tag:superadmin check needs the device
#     template to stop listing the node user as tag:superadmin's owner
#     (mesh-token fix group G5); until that lands it is red, and says so. A
#     positive control restarts the mesh on a copy of the template with that
#     owner removed and must see the check go green.
# plus live negative controls (an untagged key must fail the forced-tags check,
# a planted key must be found by the log scan, a 0644 file must fail the mode
# check). Everything is torn down with `down -v --rmi local` in a trap.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
ROOT="${HS_GUARD_ROOT:-${REPO}}"
SELF="${HERE}/$(basename "${BASH_SOURCE[0]}")"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hs-guard.XXXXXX")"
LIVE_PROJECT=""
LIVE_PROBE=""
LIVE_PROBE2=""
cleanup() {
    if [ -n "${LIVE_PROBE}" ]; then docker rm -f "${LIVE_PROBE}" >/dev/null 2>&1 || true; fi
    if [ -n "${LIVE_PROBE2}" ]; then docker rm -f "${LIVE_PROBE2}" >/dev/null 2>&1 || true; fi
    if [ -n "${LIVE_PROJECT}" ]; then
        live_compose down -v --rmi local --remove-orphans >/dev/null 2>&1 || true
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

echo "== local-mesh headscale (HEADSCALE=1) guard =="
[ "${ROOT}" = "${REPO}" ] || echo "   (static leg over ${ROOT})"

need() { command -v "$1" >/dev/null 2>&1; }
for t in python3 jq make ssh-keygen awk; do
    need "$t" || bad "required tool '$t' is not installed (this guard does not skip)"
done
python3 -c 'import yaml' 2>/dev/null || bad "python3 PyYAML is not installed (this guard does not skip)"

STACK="${ROOT}/tests/stack"

# relay <text>: turn a checker's "PASS m" / "FAIL m" lines into this file's
# counters; any other line is printed as-is. An EMPTY relay is itself a failure
# (a checker that crashed before its first verdict must not read as green).
relay() {
    local line
    local n=0
    while IFS= read -r line; do
        case "${line}" in
            "PASS "*) ok "${line#PASS }"; n=$((n+1)) ;;
            "FAIL "*) bad "${line#FAIL }"; n=$((n+1)) ;;
            "") ;;
            *) echo "    ${line}" ;;
        esac
    done <<< "$1"
    [ "${n}" -gt 0 ] || bad "a checker produced no verdict at all (crashed?)"
}

# ── 1-3. compose + overlay + tls-front (python) ─────────────────────────────
echo "-- 1-3) compose, the HEADSCALE=1 overlay, the hs. door --"
compose_py_out="$(python3 - "${ROOT}" <<'PY'

import re, sys
try:
    import yaml
except ImportError:
    print("FAIL PyYAML missing"); sys.exit(0)
root = sys.argv[1]
st = root + "/tests/stack"
def ok(m): print("PASS " + m)
def bad(m): print("FAIL " + m)

def load(p):
    try:
        with open(p) as f:
            return yaml.safe_load(f) or {}
    except Exception as e:
        bad("cannot parse %s: %s" % (p, e)); return {}

base = load(st + "/compose.local.yaml")
svcs = base.get("services") or {}
hs = svcs.get("hugmesh-headscale")
if not isinstance(hs, dict):
    bad("compose.local.yaml has no hugmesh-headscale service"); hs = {}
else:
    ok("compose.local.yaml has a hugmesh-headscale service")
(ok if hs.get("profiles") == ["headscale"] else bad)(
    "hugmesh-headscale is ONLY behind profiles: [headscale] (got %r)" % (hs.get("profiles"),))
b = hs.get("build") or {}
ctx = b.get("context") if isinstance(b, dict) else b
(ok if ctx == "./headscale" else bad)("hugmesh-headscale builds ./headscale (got %r)" % (ctx,))
(ok if "ports" not in hs and "expose" not in hs else bad)(
    "hugmesh-headscale publishes NO host port (the door is hugmesh-https-front)")
(ok if "network_mode" not in hs else bad)("hugmesh-headscale stays on the compose network")
want_labels = {
    "net.hugmesh.role": "headscale",
    "net.hugmesh.headscale.user": "hugmesh",
    "net.hugmesh.headscale.login-server": "https://hs.${HUGMESH_DOMAIN:-hugmesh.net}:${PUBLIC_HTTPS_PORT:-8488}",
    "net.hugmesh.headscale.domain": "${HUGMESH_DOMAIN:-hugmesh.net}",
    "net.hugmesh.headscale.key-tags": "tag:hugmesh",
}
labels = hs.get("labels") or {}
if isinstance(labels, list):
    labels = dict(x.split("=", 1) for x in labels)
for k, v in want_labels.items():
    (ok if labels.get(k) == v else bad)("label %s = %s (got %r)" % (k, v, labels.get(k)))
env = hs.get("environment") or {}
for k, v in (("HUGMESH_DOMAIN", "${HUGMESH_DOMAIN:-hugmesh.net}"),
             ("PUBLIC_HTTPS_PORT", "${PUBLIC_HTTPS_PORT:-8488}"),
             ("HEADSCALE_MESH_ID", "${HEADSCALE_MESH_ID:-hugmesh-local}")):
    (ok if env.get(k) == v else bad)(
        "headscale env %s follows the same variable as the labels (got %r)" % (k, env.get(k)))
vols = [str(v) for v in (hs.get("volumes") or [])]
(ok if "../../specs/etc/headscale/policy.hujson.tmpl:/etc/hugmesh/headscale/policy.hujson.tmpl:ro" in vols else bad)(
    "mounts the DEVICE policy template read-only")
(ok if "headscale-data:/var/lib/headscale" in vols else bad)("persists /var/lib/headscale in headscale-data")
(ok if "headscale-admin-key:/run/hugmesh-headscale" in vols else bad)(
    "writes the API key into the headscale-admin-key volume")
hc = hs.get("healthcheck") or {}
hct = " ".join(hc.get("test") or []) if isinstance(hc.get("test"), list) else str(hc.get("test"))
(ok if "headscale users list" in hct and "admin-bff.apikey" in hct else bad)(
    "healthcheck = the socket answers AND the API key exists")
topv = base.get("volumes") or {}
for v in ("headscale-data", "headscale-admin-key"):
    (ok if v in topv else bad)("top-level volume %s declared" % v)

# Every OTHER service in the base file: nothing about headscale or mesh tokens.
leak = []
for name, s in svcs.items():
    if name == "hugmesh-headscale":
        continue
    blob = yaml.safe_dump(s)
    if re.search(r"MESH_TOKEN|mesh_token|headscale-admin-key|\.mesh-token", blob):
        leak.append(name)
    if (s.get("profiles") or []) == ["headscale"]:
        leak.append(name + "(profiled headscale)")
(ok if not leak else bad)("no unprofiled service in compose.local.yaml carries mesh-token/headscale wiring (got %r)" % leak)
adm = svcs.get("hugmesh-admin-bff-api") or {}
aenv = adm.get("environment") or {}
(ok if "APP_REGISTRY_HEADSCALE_ACL_ENABLED" not in aenv or str(aenv.get("APP_REGISTRY_HEADSCALE_ACL_ENABLED")).strip().lower() in ("false", "${app_registry_headscale_acl_enabled:-false}") else bad)(
    "admin-bff's headscale ACL push stays off in compose.local.yaml (file mode)")

ov = load(st + "/compose.headscale.yaml")
osv = (ov.get("services") or {})
(ok if set(osv) == {"hugmesh-admin-bff-api"} else bad)(
    "the overlay touches admin-bff ONLY (got %r)" % sorted(osv))
oa = osv.get("hugmesh-admin-bff-api") or {}
oenv = oa.get("environment") or {}
want_env = {
    "APP_MESH_TOKEN_ENABLED": "true",
    "APP_MESH_TOKEN_HEADSCALE_BASE_URL": "http://hugmesh-headscale:8080",
    "APP_MESH_TOKEN_HEADSCALE_API_KEY_PATH": "/run/hugmesh-headscale/admin-bff.apikey",
    "APP_MESH_TOKEN_HEADSCALE_USER": "hugmesh",
    "APP_MESH_TOKEN_MESH": "${HEADSCALE_MESH_ID:-hugmesh-local}",
    "APP_MESH_TOKEN_LOGIN_SERVERS": "${HUGMESH_DOMAIN:-hugmesh.net}=https://hs.${HUGMESH_DOMAIN:-hugmesh.net}:${PUBLIC_HTTPS_PORT:-8488}",
    "APP_MESH_TOKEN_ISSUER_KEY_PATH": "/run/secrets/mesh_token_issuer",
}
for k, v in want_env.items():
    (ok if str(oenv.get(k)) == v else bad)("overlay admin-bff %s=%s (got %r)" % (k, v, oenv.get(k)))
extra = sorted(k for k in oenv if k not in want_env)
(ok if not extra else bad)("overlay sets no other admin-bff env (got %r)" % extra)
(ok if "APP_REGISTRY_HEADSCALE_ACL_ENABLED" not in oenv else bad)(
    "overlay leaves APP_REGISTRY_HEADSCALE_ACL_ENABLED alone (file mode: that leg needs policy mode database)")
ovols = [str(v) for v in (oa.get("volumes") or [])]
(ok if ovols == ["headscale-admin-key:/run/hugmesh-headscale:ro"] else bad)(
    "admin-bff mounts the API-key volume READ-ONLY and nothing else (got %r)" % ovols)
(ok if (oa.get("secrets") or []) == ["mesh_token_issuer"] else bad)("admin-bff gets the issuer key as a file secret")
osec = (ov.get("secrets") or {}).get("mesh_token_issuer") or {}
(ok if osec == {"file": "./.mesh-token/issuer"} else bad)(
    "the issuer secret is the gitignored ./.mesh-token/issuer (got %r)" % osec)
dep = (oa.get("depends_on") or {}).get("hugmesh-headscale") or {}
(ok if dep.get("condition") == "service_healthy" else bad)("admin-bff waits for a HEALTHY headscale (the key exists)")
blob = open(st + "/compose.headscale.yaml").read()
(ok if not re.search(r"^\s*ports\s*:", blob, re.M) else bad)("the overlay publishes nothing")

# The entrypoint writes the key where the overlay says admin-bff reads it.
try:
    ep = open(st + "/headscale/entrypoint.sh").read()
    m1 = re.search(r'^KEY_DIR=(\S+)$', ep, re.M); m2 = re.search(r'^KEY_FILE="\$\{KEY_DIR\}/([^"]+)"$', ep, re.M)
    path = (m1.group(1) + "/" + m2.group(1)) if (m1 and m2) else None
    (ok if path == want_env["APP_MESH_TOKEN_HEADSCALE_API_KEY_PATH"] else bad)(
        "entrypoint writes the key at the path admin-bff reads (%r)" % path)
except OSError as e:
    bad("cannot read the entrypoint: %s" % e)

# ── tls-front ──
try:
    conf = open(st + "/tls-front/default.conf").read()
except OSError as e:
    bad("cannot read tls-front/default.conf: %s" % e); conf = ""
code = "\n".join(l.split("#", 1)[0] for l in conf.splitlines())
blocks = []
i = 0
for m in re.finditer(r"\bserver\s*\{", code):
    if m.start() < i:
        continue
    depth = 0; j = m.end() - 1
    while j < len(code):
        if code[j] == "{": depth += 1
        elif code[j] == "}":
            depth -= 1
            if depth == 0: break
        j += 1
    blocks.append(code[m.start():j + 1]); i = j + 1
hsb = [b for b in blocks if re.search(r"server_name\s+~\^hs\\\.\s*;", b)]
(ok if len(hsb) == 1 else bad)("exactly one `server_name ~^hs\\.` server block (got %d)" % len(hsb))
hb = hsb[0] if hsb else ""
(ok if re.search(r"listen\s+8443\s+ssl\s*;", hb) else bad)("the hs. block listens on the SAME 8443 ssl listener")
(ok if "ssl_certificate     /etc/hugmesh-tls/fullchain.crt;" in hb and "/etc/hugmesh-tls/server.key;" in hb else bad)(
    "the hs. block serves the per-machine leaf (DNS:*.<domain> covers hs.)")
(ok if re.search(r"resolver\s+127\.0\.0\.11\b", hb) and re.search(r"set\s+\$headscale\s+hugmesh-headscale\s*;", hb) else bad)(
    "re-resolves hugmesh-headscale per request (resolver 127.0.0.11 + variable)")
pp = re.findall(r"proxy_pass\s+([^;]+);", hb)
(ok if pp == ["http://$headscale:8080$request_uri"] else bad)("the hs. block proxies only to $headscale:8080 (got %r)" % pp)
(ok if re.search(r"proxy_set_header\s+Upgrade\s+\$http_upgrade\s*;", hb) and re.search(r"proxy_set_header\s+Connection\s+\$connection_upgrade\s*;", hb) else bad)(
    "passes Upgrade/Connection (ts2021 + DERP are HTTP/1.1 upgrades)")
(ok if re.search(r"proxy_http_version\s+1\.1\s*;", hb) and re.search(r"proxy_buffering\s+off\s*;", hb) else bad)(
    "HTTP/1.1 upstream, buffering off")
(ok if re.search(r"location\s+\^~\s+/api/\s*\{\s*return\s+404\s*;", hb) else bad)("headscale's /api/ is NOT served through the door")
(ok if re.search(r"location\s+\^~\s+/swagger\s*\{\s*return\s+404\s*;", hb) else bad)("headscale's /swagger is NOT served through the door")
main = [b for b in blocks if re.search(r"server_name\s+localhost\s*;", b)]
mb = main[0] if main else ""
(ok if mb and "hugmesh-headscale" not in mb and "$headscale" not in mb else bad)(
    "the main (localhost) block still proxies to the fe-gateway only")
(ok if re.search(r"map\s+\$http_upgrade\s+\$connection_upgrade", code) else bad)("the Upgrade/Connection map still exists")
PY
)"
relay "${compose_py_out}"
# ── 2b. unprofiled config, byte for byte (docker CLI only; the static checks
#        above already pin the same property structurally) ──────────────────
echo "-- 2b) unprofiled docker compose config is byte-identical without the service --"
if docker compose version >/dev/null 2>&1; then
    stripped="${STACK}/.compose.hs-guard-$$.yaml"
    awk '
        /^  hugmesh-headscale:$/ { skip=1; next }
        skip && /^  [A-Za-z#]/ && !/^  hugmesh-headscale:/ { if ($0 !~ /^  #/) skip=0 }
        skip && /^[^ ]/ { skip=0 }
        skip { next }
        /^  headscale-data:$/ || /^  headscale-admin-key:$/ { next }
        { print }
    ' "${STACK}/compose.local.yaml" > "${stripped}"
    a="$(ROUTE_ACCESS_DB_PASSWORD=guard docker compose -p hsguard -f "${STACK}/compose.local.yaml" config 2>/dev/null)"; ra=$?
    b="$(ROUTE_ACCESS_DB_PASSWORD=guard docker compose -p hsguard -f "${stripped}" config 2>/dev/null)"; rb=$?
    rm -f "${stripped}"
    if [ "${ra}" -ne 0 ] || [ "${rb}" -ne 0 ] || [ -z "${a}" ]; then
        bad "docker compose config failed (rc ${ra}/${rb})"
    elif [ "${a}" = "${b}" ]; then
        ok "unprofiled config is byte-identical to the file without hugmesh-headscale ($(printf '%s\n' "${a}" | wc -l) lines)"
    else
        bad "the unprofiled config CHANGES with the headscale service present (it must only exist behind its profile)"
    fi
    c="$(ROUTE_ACCESS_DB_PASSWORD=guard docker compose -p hsguard -f "${STACK}/compose.local.yaml" -f "${STACK}/compose.headscale.yaml" --profile headscale config 2>/dev/null)"
    case "${c}" in
        *"hugmesh-headscale:"*"APP_MESH_TOKEN_ENABLED"*|*"APP_MESH_TOKEN_ENABLED"*"hugmesh-headscale:"*)
            ok "with --profile headscale + the overlay, the service and admin-bff's mesh-token env are both in the model" ;;
        *) bad "the HEADSCALE=1 model is missing the service or admin-bff's mesh-token env" ;;
    esac
else
    echo "    (docker compose CLI absent: the byte-for-byte render is not run here; checks 1-2 pin the same property)"
fi

# ── 4. Makefile (make -n) ────────────────────────────────────────────────────
echo "-- 4) Makefile wiring (make -n) --"
mkn() { make -C "${ROOT}" --no-print-directory -n "$@" STACK_NO_CLONE=1 2>/dev/null; }
compose_lines() { grep -a -E 'docker compose ' || true; }
plain="$( { mkn stack-up; mkn stack-build; mkn stack-ps; mkn stack-logs; } | compose_lines)"
if [ -z "${plain}" ]; then
    bad "make -n printed no compose call for stack-up/build/ps/logs"
else
    case "${plain}" in
        *"--profile headscale"*|*compose.headscale.yaml*|*HUGMESH_DOMAIN=*|*HEADSCALE_MESH_ID=*) bad "a PLAIN stack-up/build/ps/logs argv mentions headscale (the knob must expand to nothing)" ;;
        *) ok "a plain stack-up/build/ps/logs argv carries no headscale profile, overlay or env" ;;
    esac
fi
hsup="$(mkn stack-up HEADSCALE=1)"
hsupc="$(printf '%s\n' "${hsup}" | compose_lines)"
nup="$(printf '%s\n' "${hsupc}" | grep -a -c -E -- '--profile headscale -f tests/stack/compose.headscale.yaml .*(build|up -d)$' || true)"
[ "${nup}" = 2 ] && ok "HEADSCALE=1 stack-up passes --profile headscale + the overlay to BOTH build and up" \
                 || bad "HEADSCALE=1 stack-up: build+up lines with the profile and overlay = ${nup} (want 2)"
nb="$(mkn stack-build HEADSCALE=1 | compose_lines | grep -a -c -E -- '--profile headscale -f tests/stack/compose.headscale.yaml .*build$' || true)"
[ "${nb}" = 1 ] && ok "HEADSCALE=1 stack-build passes the profile + overlay" || bad "HEADSCALE=1 stack-build is missing the profile/overlay (${nb})"
for t in stack-ps stack-logs; do
    n="$(mkn "${t}" HEADSCALE=1 | compose_lines | grep -a -c -E -- '--profile headscale' || true)"
    [ "${n}" -ge 1 ] && ok "HEADSCALE=1 ${t} sees the profile" || bad "HEADSCALE=1 ${t} does not pass --profile headscale"
done
for t in stack-down stack-halt stack-clean; do
    out="$(mkn "${t}" | compose_lines)"
    case "${out}" in
        *"--profile headscale "*) ok "${t} reaps the headscale profile UNCONDITIONALLY" ;;
        *) bad "${t} does not pass --profile headscale without the knob (an earlier HEADSCALE=1 up would be stranded)" ;;
    esac
    case "${out}" in
        *compose.headscale.yaml*) bad "${t} names the overlay (a down must not need the issuer key file)" ;;
        *) ok "${t} does not need the overlay" ;;
    esac
done
# The env line, with and without DOMAIN, against stack-certs' own expression.
for dom in "" "acme.example"; do
    o="$(mkn stack-up HEADSCALE=1 ${dom:+DOMAIN=${dom}})"
    hd="$(printf '%s\n' "${o}" | grep -a -o -E "HUGMESH_DOMAIN='[^']*'" | sort -u)"
    cd_="$(printf '%s\n' "${o}" | grep -a -o -E "SNAP_DOMAIN='[^']*'" | sort -u)"
    want="${dom:-hugmesh.net}"
    [ "${hd}" = "HUGMESH_DOMAIN='${want}'" ] && [ "${cd_}" = "SNAP_DOMAIN='${want}'" ] \
        && ok "DOMAIN=${dom:-<unset>}: HUGMESH_DOMAIN and stack-certs' leaf domain agree ('${want}')" \
        || bad "DOMAIN=${dom:-<unset>}: HUGMESH_DOMAIN=[${hd}] vs stack-certs [${cd_}] (want '${want}' for both)"
done
printf '%s\n' "${hsup}" | grep -a -F "HEADSCALE_MESH_ID='hugmesh-local'" >/dev/null \
    && ok "HEADSCALE=1 threads HEADSCALE_MESH_ID (default hugmesh-local)" || bad "HEADSCALE=1 does not thread HEADSCALE_MESH_ID"
kl="$(printf '%s\n' "${hsup}" | grep -a -n -F 'mesh-token issuer fingerprint' | head -1 | cut -d: -f1)"
cl="$(printf '%s\n' "${hsup}" | grep -a -n -E 'docker compose .* up -d$' | head -1 | cut -d: -f1)"
[ -n "${kl}" ] && [ -n "${cl}" ] && [ "${kl}" -lt "${cl}" ] \
    && ok "HEADSCALE=1 stack-up mints/reads the issuer key BEFORE compose runs" \
    || bad "HEADSCALE=1 stack-up does not run stack-mesh-token-key before up (key line ${kl:-none}, up line ${cl:-none})"
case "$(mkn stack-up)" in
    *"mesh-token issuer fingerprint"*) bad "a PLAIN stack-up runs stack-mesh-token-key (it must be HEADSCALE=1 only)" ;;
    *) ok "a plain stack-up does not touch the issuer key" ;;
esac

# ── 5. stack-mesh-token-key, for real ────────────────────────────────────────
echo "-- 5) stack-mesh-token-key (run into a temp dir) --"
kd="${WORK}/mesh-token"
o1="$(make -C "${ROOT}" --no-print-directory stack-mesh-token-key STACK_MESH_TOKEN_DIR="${kd}" </dev/null 2>&1)"; r1=$?
if [ "${r1}" -ne 0 ] || [ ! -f "${kd}/issuer" ]; then
    bad "stack-mesh-token-key failed (rc ${r1}): $(printf '%s' "${o1}" | tail -1)"
else
    mode="$(stat -c '%a' "${kd}/issuer" 2>/dev/null)"
    [ "${mode}" = 600 ] && ok "the issuer key is 0600" || bad "the issuer key is mode ${mode} (want 600)"
    dmode="$(stat -c '%a' "${kd}" 2>/dev/null)"
    [ "${dmode}" = 700 ] && ok "its directory is 0700" || bad "the key directory is mode ${dmode} (want 700)"
    kt="$(ssh-keygen -lf "${kd}/issuer" </dev/null 2>/dev/null | awk '{print $NF}')"
    [ "${kt}" = "(ED25519)" ] && ok "the issuer key is ed25519" || bad "the issuer key type is ${kt:-unreadable}"
    fp="$(ssh-keygen -lf "${kd}/issuer" </dev/null 2>/dev/null | awk '{print $2}')"
    printf '%s\n' "${o1}" | grep -a -x -F "==> mesh-token issuer fingerprint: ${fp}" >/dev/null \
        && ok "prints the fingerprint ssh-keygen -lf reports" || bad "the printed fingerprint is not ssh-keygen's (${fp})"
    case "${o1}" in
        *"PRIVATE KEY"*|*"ssh-ed25519 "*) bad "stack-mesh-token-key printed key material" ;;
        *) ok "prints no key material (only the fingerprint and the minted path)" ;;
    esac
    other="$(printf '%s\n' "${o1}" | grep -a -v -E '^==> (stack-mesh-token-key: minted |mesh-token issuer fingerprint: SHA256:)' || true)"
    [ -z "${other}" ] && ok "prints nothing else" || bad "stack-mesh-token-key printed more than its two lines: ${other}"
    m1="$(stat -c '%Y:%i' "${kd}/issuer")"
    o2="$(make -C "${ROOT}" --no-print-directory stack-mesh-token-key STACK_MESH_TOKEN_DIR="${kd}" </dev/null 2>&1)"; r2=$?
    m2="$(stat -c '%Y:%i' "${kd}/issuer")"
    fp2="$(printf '%s\n' "${o2}" | sed -n 's/^==> mesh-token issuer fingerprint: //p')"
    [ "${r2}" -eq 0 ] && [ "${fp2}" = "${fp}" ] && [ "${m1}" = "${m2}" ] \
        && ok "a second run KEEPS the key (same fingerprint, file untouched)" \
        || bad "a second run changed or failed on the key (rc ${r2}, fp ${fp2:-none})"
    case "${o2}" in *minted*) bad "the second run says it minted again" ;; *) ok "the second run does not re-mint" ;; esac
fi
mkdir -p "${WORK}/dirtrap/issuer"
make -C "${ROOT}" --no-print-directory stack-mesh-token-key STACK_MESH_TOKEN_DIR="${WORK}/dirtrap" </dev/null >/dev/null 2>&1 \
    && bad "stack-mesh-token-key accepted a DIRECTORY at the key path (Docker's missing-bind-mount trap)" \
    || ok "refuses a directory at the key path"
grep -a -x -F 'tests/stack/.mesh-token/' "${ROOT}/.gitignore" >/dev/null \
    && ok ".gitignore lists tests/stack/.mesh-token/" || bad ".gitignore does not list tests/stack/.mesh-token/"
if [ "${ROOT}" = "${REPO}" ] && git -C "${REPO}" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "${REPO}" check-ignore -q tests/stack/.mesh-token/issuer \
        && ok "git ignores tests/stack/.mesh-token/issuer" || bad "git would track tests/stack/.mesh-token/issuer"
fi

# ── 6. entrypoint, render-only ───────────────────────────────────────────────
echo "-- 6) entrypoint renders config + the DEVICE policy (render-only) --"
EP="${STACK}/headscale/entrypoint.sh"
TMPL="${ROOT}/specs/etc/headscale/policy.hujson.tmpl"
render() {  # render <outdir> [VAR=value ...]
    local out="$1"; shift
    env -i PATH="${PATH}" HUGMESH_HS_RENDER_ONLY=1 \
        HUGMESH_HS_CONFIG_TMPL="${STACK}/headscale/config.yaml.tmpl" HUGMESH_HS_POLICY_TMPL="${TMPL}" \
        HUGMESH_HS_CONFIG_OUT="${out}/config.yaml" HUGMESH_HS_POLICY_OUT="${out}/policy.hujson" \
        "$@" bash "${EP}"
}
r1d="${WORK}/r1"; mkdir -p "${r1d}"
if render "${r1d}" HUGMESH_DOMAIN=example.test PUBLIC_HTTPS_PORT=18488 >/dev/null 2>&1; then
    ok "render-only run succeeds"
else
    bad "render-only run failed"
fi
r2d="${WORK}/r2"; mkdir -p "${r2d}"
render "${r2d}" HUGMESH_DOMAIN=acme.example PUBLIC_HTTPS_PORT=443 HEADSCALE_MESH_ID=west HEADSCALE_SSH_USER=ops >/dev/null 2>&1 \
    || bad "render-only run with a non-default mesh id failed"
ep_py_out="$(python3 - "${r1d}" "${r2d}" "${TMPL}" "${STACK}/headscale/config.yaml.tmpl" <<'PY'
import json, re, sys
r1, r2, tmpl, ctmpl = sys.argv[1:5]
def ok(m): print("PASS " + m)
def bad(m): print("FAIL " + m)
def hujson(text):
    lines = [l for l in text.splitlines() if not l.lstrip().startswith("//")]
    return json.loads("\n".join(lines))
def yaml_get(p, key):
    for l in open(p):
        m = re.match(r"^%s:\s*(\S+)\s*$" % re.escape(key), l)
        if m: return m.group(1)
try:
    su = yaml_get(r1 + "/config.yaml", "server_url")
    (ok if su == "https://hs.example.test:18488" else bad)("server_url = https://hs.<HUGMESH_DOMAIN>:<PUBLIC_HTTPS_PORT> (got %r)" % su)
    su2 = yaml_get(r2 + "/config.yaml", "server_url")
    (ok if su2 == "https://hs.acme.example:443" else bad)("server_url follows the inputs (got %r)" % su2)
    import yaml
    c = yaml.safe_load(open(r1 + "/config.yaml"))
    (ok if c.get("policy") == {"mode": "file", "path": "/etc/headscale/policy.hujson"} else bad)("policy mode file at /etc/headscale/policy.hujson (the device's mode)")
    d = c.get("derp") or {}
    srv = d.get("server") or {}
    (ok if srv.get("enabled") is True and srv.get("region_id") == 999 and d.get("urls") == [] and d.get("paths") == [] else bad)(
        "embedded DERP on (region 999), no public DERP map")
    (ok if c.get("listen_addr") == "0.0.0.0:8080" and c.get("grpc_allow_insecure") is False else bad)("plain :8080 in-network, no insecure gRPC")
    (ok if c.get("unix_socket") == "/run/headscale/headscale.sock" else bad)("unix socket at /run/headscale/headscale.sock")
    (ok if (c.get("database") or {}).get("type") == "sqlite" else bad)("sqlite database")
    (ok if "@@" not in open(r1 + "/config.yaml").read() else bad)("no leftover marker in the config")
    (ok if open(ctmpl).read().count("@@") == 2 else bad)("the config template spells its one marker exactly once")
except Exception as e:
    bad("config render unreadable: %r" % e)
try:
    t = open(tmpl).read()
    base = hujson(t.replace("@@HUGMESH_TAGOWNERS_DYNAMIC@@", "").replace("@@HUGMESH_SSH_EDGES@@", ""))
    for rd, mesh, user in ((r1, "hugmesh-local", "admin"), (r2, "west", "ops")):
        txt = open(rd + "/policy.hujson").read()
        (ok if "@@" not in txt else bad)("no leftover marker in the policy (%s)" % mesh)
        pol = hujson(txt)
        want_owners = dict(base.get("tagOwners") or {})
        want_owners["tag:mesh_" + mesh] = []
        (ok if pol.get("tagOwners") == want_owners else bad)(
            "tagOwners = the device template's static owners + ONLY \"tag:mesh_%s\": [] (owned by nobody) (got %r)" % (mesh, sorted(set(pol.get("tagOwners") or {}) - set(base.get("tagOwners") or {}))))
        (ok if pol.get("acls") == base.get("acls") and pol.get("autoApprovers") == base.get("autoApprovers") else bad)(
            "acls + autoApprovers are the device template's (%s)" % mesh)
        want = [{"action": "accept", "src": ["tag:superadmin"], "dst": ["tag:mesh_" + mesh], "users": [user]}]
        (ok if pol.get("ssh") == want else bad)("ssh = ONLY the superadmin rule -> tag:mesh_%s (got %r)" % (mesh, pol.get("ssh")))
        (ok if set(pol) == set(base) else bad)("no extra top-level policy keys (%s)" % mesh)
except Exception as e:
    bad("policy render unreadable: %r" % e)
PY
)"
relay "${ep_py_out}"
refuse() {  # refuse <label> VAR=value ...
    local label="$1"; shift
    local d="${WORK}/refuse.$RANDOM$RANDOM"
    mkdir -p "${d}"
    if render "${d}" "$@" >/dev/null 2>&1; then
        bad "the entrypoint ACCEPTED ${label}"
    elif [ -e "${d}/config.yaml" ] || [ -e "${d}/policy.hujson" ]; then
        bad "the entrypoint refused ${label} but wrote a file first"
    else
        ok "refuses ${label} before writing anything"
    fi
}
refuse "a domain with a quote" 'HUGMESH_DOMAIN=ev"il.example'
refuse "a one-label domain" HUGMESH_DOMAIN=localhost
refuse "an upper-case domain" HUGMESH_DOMAIN=Acme.Example
refuse "port 0" PUBLIC_HTTPS_PORT=0
refuse "port 70000" PUBLIC_HTTPS_PORT=70000
refuse "a non-numeric port" PUBLIC_HTTPS_PORT=8488x
refuse "an upper-case mesh id" HEADSCALE_MESH_ID=Bad_ID
refuse "a mesh id with a quote" 'HEADSCALE_MESH_ID=a"b'
refuse "an ssh user with a space" 'HEADSCALE_SSH_USER=a b'
refuse "a renewal window longer than the key lifetime" HEADSCALE_APIKEY_RENEW_DAYS=91
ep_code="$(sed -e 's/[[:space:]]#.*$//' -e '/^[[:space:]]*#/d' "${EP}")"
case "${ep_code}" in
    *"set -x"*|*"set -o xtrace"*|*"-o xtrace"*) bad "the entrypoint enables xtrace (it would print the API key)" ;;
    *) ok "the entrypoint never enables xtrace" ;;
esac
leak_lines="$(printf '%s\n' "${ep_code}" | grep -a -n -E '(\blog|\bdie|echo|printf)\b.*\$\{?(new_key|cur)\}?([^_A-Za-z0-9]|$)' | grep -a -v -F "printf '%s' \"\${new_key}\" > \"\${tmp}\"" || true)"
[ -z "${leak_lines}" ] && ok "no log/echo/printf line can print the API key (only the write to the temp file names it)" \
                       || bad "an output line names the key variable: ${leak_lines}"
printf '%s\n' "${ep_code}" | grep -a -E '^\s*umask 077\s*$' >/dev/null && ok "umask 077 before anything is written" || bad "the entrypoint does not set umask 077"
printf '%s\n' "${ep_code}" | grep -a -E 'chmod 0600 "\$\{tmp\}"' >/dev/null && printf '%s\n' "${ep_code}" | grep -a -E 'mv -f "\$\{tmp\}" "\$\{KEY_FILE\}"' >/dev/null \
    && ok "the key is written 0600 to a temp file and renamed into place" || bad "the key write is not chmod 0600 + rename"
printf '%s\n' "${ep_code}" | grep -a -E -- '--tags|aclTags|acl_tags' >/dev/null \
    && bad "the entrypoint mints tagged keys itself (key minting belongs to admin-bff/Studio)" || ok "the entrypoint mints no pre-auth keys"

# ── 7. Dockerfile ────────────────────────────────────────────────────────────
echo "-- 7) image --"
DF="${STACK}/headscale/Dockerfile"
grep -a -x -F 'FROM headscale/headscale:0.23.0 AS hs' "${DF}" >/dev/null && ok "binary comes from the fleet pin headscale/headscale:0.23.0" \
    || bad "the Dockerfile does not take the binary from headscale/headscale:0.23.0"
grep -a -x -F 'COPY --from=hs /ko-app/headscale /usr/local/bin/headscale' "${DF}" >/dev/null && ok "copies /ko-app/headscale (the distroless image's binary)" \
    || bad "the Dockerfile does not copy /ko-app/headscale"
grep -a -E '^FROM alpine:[0-9]+\.[0-9]+$' "${DF}" >/dev/null && ok "runtime base is a pinned alpine" || bad "runtime base is not a pinned alpine:<x.y>"
grep -a -E '^\s*(EXPOSE|VOLUME)\b' "${DF}" >/dev/null && bad "the Dockerfile EXPOSEs or declares an anonymous VOLUME" || ok "no EXPOSE/VOLUME in the image"

# ── negative controls ────────────────────────────────────────────────────────
if [ -z "${HS_GUARD_NO_CONTROLS:-}" ]; then
    echo "-- negative controls: each mutation must turn the static leg red --"
    mktree() {  # mktree <dir>: the files the static leg reads
        local d="$1"
        local f
        mkdir -p "${d}/tests/stack/headscale" "${d}/tests/stack/tls-front" "${d}/specs/etc/headscale"
        for f in Makefile .gitignore tests/stack/compose.local.yaml tests/stack/compose.headscale.yaml \
                 tests/stack/tls-front/default.conf tests/stack/headscale/Dockerfile \
                 tests/stack/headscale/entrypoint.sh tests/stack/headscale/config.yaml.tmpl \
                 specs/etc/headscale/policy.hujson.tmpl tests/stack/test-headscale-local.sh; do
            cp -p "${REPO}/${f}" "${d}/${f}" || return 1
        done
        # compose.local.yaml includes these; copy them so a config render resolves.
        for f in compose.real.yaml compose.social-profile.yaml compose.alt-social.yaml compose.brand-b.yaml \
                 compose.edge-ai-tts.yaml compose.games.yaml compose.media-poisoner.yaml; do
            [ -f "${REPO}/tests/stack/${f}" ] && cp -p "${REPO}/tests/stack/${f}" "${d}/tests/stack/${f}"
        done
        return 0
    }
    child() { HS_GUARD_ROOT="$1" HS_GUARD_NO_CONTROLS=1 HUGMESH_HEADSCALE_LIVE= bash "${SELF}" </dev/null 2>&1; }
    pos="${WORK}/ctl-pos"
    if mktree "${pos}" && child "${pos}" >/dev/null; then
        ok "positive control: an unmutated copy of the tree passes"
    else
        bad "positive control: an unmutated copy FAILS (the controls below would prove nothing): $(child "${pos}" | grep -a FAIL | head -3)"
    fi
    n=0
    control() {  # control <label> <file> <python-literal old> <python-literal new>
        local label="$1" ; local file="$2" ; local old="$3" ; local new="$4"
        local d
        n=$((n+1)); d="${WORK}/ctl-${n}"
        mktree "${d}" || { bad "control '${label}': could not copy the tree"; return; }
        if ! python3 - "${d}/${file}" "${old}" "${new}" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if s.count(old) < 1:
    sys.exit(3)
open(p, "w").write(s.replace(old, new))
PY
        then bad "control '${label}': the mutation's anchor is not in ${file} (the control is stale)"; return; fi
        cmp -s "${REPO}/${file}" "${d}/${file}" && { bad "control '${label}': the mutation did not change ${file}"; return; }
        local out
        local first
        if out="$(child "${d}")"; then bad "control '${label}' did NOT turn the guard red"
        else
            first="$(printf '%s\n' "${out}" | grep -a -m1 '^  FAIL ' | sed 's/^  FAIL //' | cut -c1-110)"
            ok "control bites: ${label}  [red on: ${first:-exit status only}]"
        fi
    }
    NL=$'\n'
    control "profile removed from hugmesh-headscale" tests/stack/compose.local.yaml \
        '  hugmesh-headscale:'"${NL}"'    profiles: ["headscale"]'"${NL}" '  hugmesh-headscale:'"${NL}"
    control "a host port published on hugmesh-headscale" tests/stack/compose.local.yaml \
        '    restart: unless-stopped'"${NL}"''"${NL}"'volumes:' '    restart: unless-stopped'"${NL}"'    ports: ["18080:8080"]'"${NL}${NL}"'volumes:'
    control "key-tags label widened to tag:superadmin" tests/stack/compose.local.yaml \
        'net.hugmesh.headscale.key-tags: tag:hugmesh' 'net.hugmesh.headscale.key-tags: tag:superadmin'
    control "login-server label pinned to a literal port" tests/stack/compose.local.yaml \
        'net.hugmesh.headscale.login-server: https://hs.${HUGMESH_DOMAIN:-hugmesh.net}:${PUBLIC_HTTPS_PORT:-8488}' 'net.hugmesh.headscale.login-server: https://hs.${HUGMESH_DOMAIN:-hugmesh.net}:8488'
    control "mesh-token env moved into compose.local.yaml's admin-bff" tests/stack/compose.local.yaml \
        '      APP_MFA_FACTOR_KEY:' '      APP_MESH_TOKEN_ENABLED: "true"'"${NL}"'      APP_MFA_FACTOR_KEY:'
    control "policy template mounted read-write" tests/stack/compose.local.yaml \
        'policy.hujson.tmpl:/etc/hugmesh/headscale/policy.hujson.tmpl:ro' 'policy.hujson.tmpl:/etc/hugmesh/headscale/policy.hujson.tmpl'
    control "admin-bff mounts the API-key volume read-write" tests/stack/compose.headscale.yaml \
        'headscale-admin-key:/run/hugmesh-headscale:ro' 'headscale-admin-key:/run/hugmesh-headscale'
    control "overlay flips the headscale ACL push on" tests/stack/compose.headscale.yaml \
        '      APP_MESH_TOKEN_ENABLED: "true"' '      APP_MESH_TOKEN_ENABLED: "true"'"${NL}"'      APP_REGISTRY_HEADSCALE_ACL_ENABLED: "true"'
    control "issuer key handed over as an env var" tests/stack/compose.headscale.yaml \
        'APP_MESH_TOKEN_ISSUER_KEY_PATH: /run/secrets/mesh_token_issuer' 'APP_MESH_TOKEN_ISSUER_KEY: ${MESH_TOKEN_ISSUER_KEY:-}'
    control "admin-bff stops waiting for a healthy headscale" tests/stack/compose.headscale.yaml \
        'condition: service_healthy' 'condition: service_started'
    control "hs. door proxied to the fe-gateway" tests/stack/tls-front/default.conf \
        'proxy_pass http://$headscale:8080$request_uri;' 'proxy_pass http://hugmesh-fe-gateway:8080$request_uri;'
    control "hs. door drops the Upgrade header" tests/stack/tls-front/default.conf \
        '    proxy_set_header Upgrade $http_upgrade;'"${NL}"'    proxy_set_header Connection $connection_upgrade;'"${NL}"'    proxy_buffering off;'"${NL}"'    proxy_read_timeout 300s;'"${NL}"'    proxy_send_timeout 300s;' \
        '    proxy_set_header Connection $connection_upgrade;'"${NL}"'    proxy_buffering off;'"${NL}"'    proxy_read_timeout 300s;'"${NL}"'    proxy_send_timeout 300s;'
    control "headscale's /api exposed through the door" tests/stack/tls-front/default.conf \
        '    location ^~ /api/ {'"${NL}"'        return 404;' '    location ^~ /api-disabled/ {'"${NL}"'        return 404;'
    control "the knob made unconditional (profile on every bring-up)" Makefile \
        'STACK_HEADSCALE_PROFILE := $(if $(strip $(HEADSCALE)), --profile headscale,)' 'STACK_HEADSCALE_PROFILE := --profile headscale'
    control "stack-down stops reaping the profile" Makefile \
        '-f $(STACK_TOR_DOMAINS_COMPOSE) --profile social --profile tor --profile headscale --profile anubis --profile phpbb --profile akkoma --profile games --profile brandb --profile edge-ai-tts --profile media-poisoner --profile egress-vpn $(STACK_OWN_CASDOOR_DOWN_FLAGS) down -v'"${NL}" \
        '-f $(STACK_TOR_DOMAINS_COMPOSE) --profile social --profile tor --profile anubis --profile phpbb --profile akkoma --profile games --profile brandb --profile edge-ai-tts --profile media-poisoner --profile egress-vpn $(STACK_OWN_CASDOOR_DOWN_FLAGS) down -v'"${NL}"
    control "HUGMESH_DOMAIN decoupled from stack-certs' domain" Makefile \
        'STACK_HUGMESH_DOMAIN := $(if $(strip $(DOMAIN)),$(DOMAIN),hugmesh.net)' 'STACK_HUGMESH_DOMAIN := hugmesh.net'
    control "stack-up no longer mints the key first" Makefile \
        'STACK_HEADSCALE_DEP := $(if $(strip $(HEADSCALE)),stack-mesh-token-key,)' 'STACK_HEADSCALE_DEP :='
    control "stack-mesh-token-key re-mints every run" Makefile \
        '	if [ ! -f "$$k" ]; then \' '	rm -f "$$k" "$$k.pub"; if [ ! -f "$$k" ]; then \'
    control "stack-mesh-token-key leaves the key world-readable" Makefile \
        '	chmod 0600 "$$k" || exit 1; \' '	chmod 0644 "$$k" || exit 1; \'
    control "stack-mesh-token-key prints the public key" Makefile \
        '	echo "==> mesh-token issuer fingerprint: $$fp"' '	echo "==> mesh-token issuer fingerprint: $$fp"; cat "$$k.pub"'
    control ".gitignore stops ignoring the issuer key" .gitignore \
        'tests/stack/.mesh-token/'"${NL}" ''
    control "entrypoint lets the node user self-advertise tag:mesh_<id>" tests/stack/headscale/entrypoint.sh \
        "to_suffix=\"\$(printf ',\\n    \"%s\": []' \"\${MESH_TAG}\")\"" "to_suffix=\"\$(printf ',\\n    \"%s\": [\"hugmesh\"]' \"\${MESH_TAG}\")\""
    control "entrypoint drops the ownerless tag:mesh_<id> (every map would fail)" tests/stack/headscale/entrypoint.sh \
        'SNAP_TO_SUFFIX="${to_suffix}" SNAP_SSH_SPLICE' 'SNAP_TO_SUFFIX="" SNAP_SSH_SPLICE'
    control "entrypoint opens ssh from tag:hugmesh" tests/stack/headscale/entrypoint.sh \
        "src:[\"tag:superadmin\"],dst:[\$meshtag]" "src:[\"tag:hugmesh\"],dst:[\$meshtag]"
    control "entrypoint domain check loosened" tests/stack/headscale/entrypoint.sh \
        '[[ "${DOMAIN}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]' '[[ "${DOMAIN}" =~ . ]]'
    control "entrypoint logs the API key" tests/stack/headscale/entrypoint.sh \
        '    new_prefix="${new_key%%.*}"' '    new_prefix="${new_key%%.*}"; log "key ${new_key}"'
    control "entrypoint turns on xtrace" tests/stack/headscale/entrypoint.sh \
        'umask 077'"${NL}" 'umask 077'"${NL}"'set -x'"${NL}"
    control "entrypoint writes the key without the 0600 temp+rename" tests/stack/headscale/entrypoint.sh \
        '    chmod 0600 "${tmp}"'"${NL}" ''
    control "image moves off the fleet pin" tests/stack/headscale/Dockerfile \
        'FROM headscale/headscale:0.23.0 AS hs' 'FROM headscale/headscale:0.26.1 AS hs'
    control "config template drops the embedded DERP" tests/stack/headscale/config.yaml.tmpl \
        '  server:'"${NL}"'    enabled: true' '  server:'"${NL}"'    enabled: false'
    control "config template switches to policy mode database" tests/stack/headscale/config.yaml.tmpl \
        'policy:'"${NL}"'  mode: file' 'policy:'"${NL}"'  mode: database'
fi

# ── LIVE leg ─────────────────────────────────────────────────────────────────
LIVE_TS_IMAGE="${HS_GUARD_TS_IMAGE:-tailscale/tailscale:v1.76.6}"
live_compose() {
    env -u STACK_SRC HUGMESH_DOMAIN="${LIVE_DOMAIN}" PUBLIC_HTTPS_PORT="${LIVE_PORT}" ROUTE_ACCESS_DB_PASSWORD=hs-guard-unused \
        docker compose -p "${LIVE_PROJECT}" -f "${REPO}/tests/stack/compose.local.yaml" -f "${WORK}/live-override.yaml" \
        --profile headscale "$@"
}
free_port() {
    local p
    local i
    for i in $(seq 1 50); do
        p=$(( 20000 + RANDOM % 9000 ))
        case "${p}" in 8000|8088|8488|9080) continue ;; esac
        if ! (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then echo "${p}"; return 0; fi
    done
    return 1
}
# forced_tags_ok <nodes-json> <hostname>: exactly [tag:hugmesh] forced.
forced_tags_ok() { jq -e --arg h "$2" '[.[]? | select(.given_name == $h or .name == $h)] | length == 1 and (.[0].forced_tags == ["tag:hugmesh"])' >/dev/null <<<"$1"; }
superadmin_invalid() { jq -e --arg h "$2" '[.[]? | select(.given_name == $h or .name == $h)][0] | ((.invalid_tags // []) | index("tag:superadmin")) != null and ((.valid_tags // []) | index("tag:superadmin")) == null' >/dev/null <<<"$1"; }
logs_clean() { ! grep -a -F -q -- "$2" "$1"; }  # reads a FILE, so -q cannot SIGPIPE a producer

if [ "${HUGMESH_HEADSCALE_LIVE:-}" = 1 ] && [ "${ROOT}" = "${REPO}" ]; then
    echo "-- LIVE: throwaway compose project (headscale + https-front only) --"
    if ! docker info >/dev/null 2>&1; then
        bad "HUGMESH_HEADSCALE_LIVE=1 but docker is not reachable"
    else
        LIVE_DOMAIN=hsguard.example
        LIVE_PORT="$(free_port)" || LIVE_PORT=""
        LIVE_PROJECT="hsguard-$$-${RANDOM}"
        [ -n "${LIVE_PORT}" ] || bad "no free high port found"
        echo "    project ${LIVE_PROJECT}, https port ${LIVE_PORT}, domain ${LIVE_DOMAIN}"
        SNAP_DOMAIN="${LIVE_DOMAIN}" bash "${REPO}/tests/stack/gen-certs.sh" "${WORK}/tls" >/dev/null 2>&1 \
            || bad "could not mint the throwaway CA/leaf"
        # The door's own healthcheck fetches `/` from the fe-gateway, which this
        # project does not start (--no-deps), so it is off here; the hs. vhost is
        # probed directly below instead.
        cat > "${WORK}/live-override.yaml" <<EOF
services:
  hugmesh-https-front:
    volumes:
      - ${WORK}/tls:/etc/hugmesh-tls:ro
    healthcheck:
      disable: true
EOF
        if ! live_compose up -d --build --no-deps --wait --wait-timeout 180 hugmesh-headscale hugmesh-https-front >"${WORK}/up.log" 2>&1; then
            bad "the throwaway project did not come up healthy: $(tail -3 "${WORK}/up.log")"
        else
            ok "hugmesh-headscale + hugmesh-https-front up and healthy"
            hsx() { live_compose exec -T hugmesh-headscale "$@"; }
            # A --force-recreate drops the old container's log, so each one is saved
            # first; the key scan at the end reads all of them.
            : > "${WORK}/logs.txt"
            snap_logs() { live_compose logs --no-color >>"${WORK}/logs.txt" 2>&1; }
            # 1. the key file, its mode, and the logs
            st="$(hsx stat -c '%a %u' /run/hugmesh-headscale/admin-bff.apikey 2>/dev/null)"
            [ "${st}" = "600 0" ] && ok "API key file is 0600 root" || bad "API key file is '${st}' (want '600 0')"
            KEY="$(hsx cat /run/hugmesh-headscale/admin-bff.apikey 2>/dev/null)"
            [[ "${KEY}" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] && ok "the key file holds one API key (not shown)" || bad "the key file does not hold an API key"
            # 2. restart keeps the key (rotation only near expiry)
            live_compose restart hugmesh-headscale >/dev/null 2>&1
            live_compose up -d --no-deps --wait --wait-timeout 120 hugmesh-headscale >/dev/null 2>&1
            KEY2="$(hsx cat /run/hugmesh-headscale/admin-bff.apikey 2>/dev/null)"
            [ -n "${KEY}" ] && [ "${KEY2}" = "${KEY}" ] && ok "a restart keeps the same key" || bad "a restart replaced the key"
            # 2b. rotation: a start that finds the key inside the renewal window
            # (HEADSCALE_APIKEY_RENEW_DAYS=90, the whole lifetime, makes any key qualify) writes a
            # NEW key and expires the old prefix in headscale.
            cat "${WORK}/live-override.yaml" > "${WORK}/live-override-rot.yaml"
            printf '  hugmesh-headscale:\n    environment:\n      HEADSCALE_APIKEY_RENEW_DAYS: "90"\n' >> "${WORK}/live-override-rot.yaml"
            old_prefix="${KEY%%.*}"
            snap_logs
            if env -u STACK_SRC HUGMESH_DOMAIN="${LIVE_DOMAIN}" PUBLIC_HTTPS_PORT="${LIVE_PORT}" ROUTE_ACCESS_DB_PASSWORD=hs-guard-unused \
                    docker compose -p "${LIVE_PROJECT}" -f "${REPO}/tests/stack/compose.local.yaml" -f "${WORK}/live-override-rot.yaml" \
                    --profile headscale up -d --no-deps --force-recreate --wait --wait-timeout 120 hugmesh-headscale >/dev/null 2>&1; then
                KEY3="$(hsx cat /run/hugmesh-headscale/admin-bff.apikey 2>/dev/null)"
                st3="$(hsx stat -c '%a %u' /run/hugmesh-headscale/admin-bff.apikey 2>/dev/null)"
                keys_json="$(hsx headscale apikeys list -o json 2>/dev/null)"
                now_s="$(date +%s)"
                if [ -n "${KEY3}" ] && [ "${KEY3}" != "${KEY}" ] && [ "${st3}" = "600 0" ]; then
                    ok "inside the renewal window a start writes a NEW key, still 0600 root"
                else
                    bad "rotation did not write a new 0600 key (mode '${st3}')"
                fi
                jq -e --arg p "${old_prefix}" --argjson now "${now_s}" '[.[]? | select(.prefix == $p) | .expiration.seconds] | length == 1 and .[0] <= $now' >/dev/null 2>&1 <<<"${keys_json}" \
                    && ok "the OLD key is expired in headscale after the rotation" \
                    || bad "the old key's prefix is not expired after the rotation"
                snap_logs
                live_compose up -d --no-deps --force-recreate --wait --wait-timeout 120 hugmesh-headscale >/dev/null 2>&1 \
                    || bad "headscale did not come back on the normal settings after the rotation check"
                KEY="$(hsx cat /run/hugmesh-headscale/admin-bff.apikey 2>/dev/null)"
                [ "${KEY}" = "${KEY3}" ] && ok "back on the 30-day window, the rotated key is kept" || bad "the rotated key was replaced again on a normal start"
                KEY3=""
            else
                bad "headscale did not come up with HEADSCALE_APIKEY_RENEW_DAYS=90"
            fi
            # 3. in-network API: preauthkey with tag:hugmesh, via https-front's busybox wget
            exp="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
            body="{\"user\":\"hugmesh\",\"reusable\":false,\"ephemeral\":false,\"expiration\":\"${exp}\",\"aclTags\":[\"tag:hugmesh\"]}"
            resp="$(live_compose exec -T hugmesh-https-front wget -q -O - --header "Authorization: Bearer ${KEY}" --header 'Content-Type: application/json' --post-data "${body}" http://hugmesh-headscale:8080/api/v1/preauthkey 2>/dev/null)"
            PAK="$(jq -r '.preAuthKey.key // empty' <<<"${resp}" 2>/dev/null)"
            pak_id="$(jq -r '.preAuthKey.id // empty' <<<"${resp}" 2>/dev/null)"
            if jq -e '.preAuthKey.user == "hugmesh" and .preAuthKey.reusable == false and .preAuthKey.ephemeral == false and (.preAuthKey.key | length) > 0' >/dev/null 2>&1 <<<"${resp}"; then
                ok "POST /api/v1/preauthkey (in-network, Bearer) -> a single-use, non-ephemeral key for user hugmesh"
            else
                bad "POST /api/v1/preauthkey failed: $(jq -c '.preAuthKey | del(.key)' <<<"${resp}" 2>/dev/null || echo unparseable)"
            fi
            # headscale 0.23's CREATE response leaves aclTags EMPTY even when it stored
            # them (measured: the response says [], `preauthkeys list` says
            # [tag:hugmesh]). A caller must read the tags back, not trust the echo.
            jq -e '.preAuthKey.aclTags == []' >/dev/null 2>&1 <<<"${resp}" \
                && echo "    (note: headscale 0.23 echoed aclTags [] on create; reading the stored key back)"
            listed="$(live_compose exec -T hugmesh-https-front wget -q -O - --header "Authorization: Bearer ${KEY}" "http://hugmesh-headscale:8080/api/v1/preauthkey?user=hugmesh" 2>/dev/null)"
            if [ -n "${pak_id}" ] && jq -e --arg id "${pak_id}" '[.preAuthKeys[]? | select(.id == $id)] | length == 1 and (.[0].aclTags == ["tag:hugmesh"])' >/dev/null 2>&1 <<<"${listed}"; then
                ok "the stored key (GET /api/v1/preauthkey?user=hugmesh, id ${pak_id}) carries aclTags EXACTLY [tag:hugmesh]"
            else
                bad "the stored key's aclTags are not exactly [tag:hugmesh]: $(jq -c --arg id "${pak_id}" '[.preAuthKeys[]? | select(.id == $id) | .aclTags]' <<<"${listed}" 2>/dev/null || echo unparseable)"
            fi
            noauth="$(live_compose exec -T hugmesh-https-front wget -S -q -O /dev/null --header 'Content-Type: application/json' --post-data "${body}" http://hugmesh-headscale:8080/api/v1/preauthkey 2>&1 | grep -a -o -E 'HTTP/1\.[01] [0-9]{3}' | tail -1 | awk '{print $2}')"
            [ "${noauth}" = 401 ] && ok "the same POST without the bearer is refused (401)" || bad "the API without a bearer answered '${noauth:-nothing}' (want 401)"
            door="$(curl -s -o /dev/null -w '%{http_code}' --cacert "${WORK}/tls/ca.crt" --resolve "hs.${LIVE_DOMAIN}:${LIVE_PORT}:127.0.0.1" "https://hs.${LIVE_DOMAIN}:${LIVE_PORT}/api/v1/apikey" -H "Authorization: Bearer ${KEY}")"
            [ "${door}" = 404 ] && ok "through the front door /api/ is 404 (the API stays on the compose network)" || bad "the front door answered ${door} for /api/v1/apikey (want 404)"
            health="$(curl -s -o /dev/null -w '%{http_code}' --cacert "${WORK}/tls/ca.crt" --resolve "hs.${LIVE_DOMAIN}:${LIVE_PORT}:127.0.0.1" "https://hs.${LIVE_DOMAIN}:${LIVE_PORT}/health")"
            [ "${health}" = 200 ] && ok "https://hs.<domain>:<port>/health answers 200 through the door, TLS verified against the stack CA" || bad "the hs. door /health answered ${health}"
            # 4. a tailscale probe joins with that key while asking for tag:superadmin
            if [ -n "${PAK}" ]; then
                LIVE_PROBE="${LIVE_PROJECT}-probe"
                docker run -d --name "${LIVE_PROBE}" --network host --add-host "hs.${LIVE_DOMAIN}:127.0.0.1" \
                    -v "${WORK}/tls/ca.crt:/etc/hs-guard-ca.crt:ro" -e SSL_CERT_FILE=/etc/hs-guard-ca.crt \
                    --entrypoint tailscaled "${LIVE_TS_IMAGE}" --tun=userspace-networking --state=mem: --port=0 \
                    --socket=/tmp/tailscaled.sock >/dev/null 2>&1 || bad "could not start the tailscale probe (${LIVE_TS_IMAGE})"
                sleep 2
                if docker exec "${LIVE_PROBE}" tailscale --socket=/tmp/tailscaled.sock up --login-server="https://hs.${LIVE_DOMAIN}:${LIVE_PORT}" \
                        --authkey="${PAK}" --hostname=hs-guard-probe --advertise-tags=tag:superadmin --accept-dns=false --timeout=60s >"${WORK}/ts-up.log" 2>&1; then
                    ok "a tailscale node joined through https://hs.<domain>:<port> with the minted key"
                else
                    bad "tailscale up failed: $(tail -2 "${WORK}/ts-up.log" | tr -d '\r')"
                fi
                nodes="$(hsx headscale nodes list -o json 2>/dev/null)"
                jq -e '[.[]? | select(.given_name == "hs-guard-probe")][0].online == true' >/dev/null 2>&1 <<<"${nodes}" \
                    && ok "headscale: the probe is ONLINE (its map was built: the rendered policy resolves every tag it names)" \
                    || bad "headscale: the probe is not online (a policy tag that resolves to nothing makes 0.23 refuse every map)"
                forced_tags_ok "${nodes}" hs-guard-probe && ok "headscale: forced_tags == [\"tag:hugmesh\"] (the key's tag, server-forced)" \
                    || bad "headscale: the probe's forced_tags are not exactly [tag:hugmesh]: $(jq -c '[.[]? | {given_name, forced_tags}]' <<<"${nodes}" 2>/dev/null)"
                if superadmin_invalid "${nodes}" hs-guard-probe; then
                    ok "headscale: a self-advertised tag:superadmin lands in invalid_tags"
                else
                    bad "headscale: a self-advertised tag:superadmin is NOT invalid ($(jq -c '[.[]? | {given_name, valid_tags, invalid_tags}]' <<<"${nodes}" 2>/dev/null)) — EXPECTED until fix group G5 stops specs/etc/headscale/policy.hujson.tmpl naming the node user \"hugmesh\" as tag:superadmin's owner"
                fi
                # live negative control: the forced-tags check must reject a node whose key had no tags
                fake='[{"given_name":"hs-guard-probe","forced_tags":[],"valid_tags":["tag:superadmin"],"invalid_tags":[]}]'
                forced_tags_ok "${fake}" hs-guard-probe && bad "control: the forced-tags check accepted an untagged node" || ok "control bites: an untagged node fails the forced-tags check"
                superadmin_invalid "${fake}" hs-guard-probe && bad "control: the superadmin check accepted a VALID tag:superadmin" || ok "control bites: a valid tag:superadmin fails the superadmin check"
                # POSITIVE control for the superadmin check (it must not be always-red):
                # the same mesh restarted on a copy of the template whose tag:superadmin
                # has NO owner (the shape of the G5 fix) must put it in invalid_tags.
                python3 - "${REPO}/specs/etc/headscale/policy.hujson.tmpl" "${WORK}/g5sim.tmpl" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
t, n = re.subn(r'"tag:superadmin":\s*\[[^\]]*\]', '"tag:superadmin": []', s, count=1)
open(sys.argv[2], "w").write(t)
sys.exit(0 if n == 1 else 3)
PY
                cat "${WORK}/live-override.yaml" > "${WORK}/live-override-g5.yaml"
                printf '  hugmesh-headscale:\n    volumes:\n      - %s:/etc/hugmesh/headscale/policy.hujson.tmpl:ro\n' "${WORK}/g5sim.tmpl" >> "${WORK}/live-override-g5.yaml"
                snap_logs
                if env -u STACK_SRC HUGMESH_DOMAIN="${LIVE_DOMAIN}" PUBLIC_HTTPS_PORT="${LIVE_PORT}" ROUTE_ACCESS_DB_PASSWORD=hs-guard-unused \
                        docker compose -p "${LIVE_PROJECT}" -f "${REPO}/tests/stack/compose.local.yaml" -f "${WORK}/live-override-g5.yaml" \
                        --profile headscale up -d --no-deps --force-recreate --wait --wait-timeout 120 hugmesh-headscale >/dev/null 2>&1; then
                    pak2="$(hsx headscale preauthkeys create -u hugmesh --tags tag:hugmesh -e 1h 2>/dev/null | tail -1 | tr -d '[:space:]')"
                    LIVE_PROBE2="${LIVE_PROJECT}-probe2"
                    docker run -d --name "${LIVE_PROBE2}" --network host --add-host "hs.${LIVE_DOMAIN}:127.0.0.1" \
                        -v "${WORK}/tls/ca.crt:/etc/hs-guard-ca.crt:ro" -e SSL_CERT_FILE=/etc/hs-guard-ca.crt \
                        --entrypoint tailscaled "${LIVE_TS_IMAGE}" --tun=userspace-networking --state=mem: --port=0 \
                        --socket=/tmp/tailscaled.sock >/dev/null 2>&1
                    sleep 2
                    docker exec "${LIVE_PROBE2}" tailscale --socket=/tmp/tailscaled.sock up --login-server="https://hs.${LIVE_DOMAIN}:${LIVE_PORT}" \
                        --authkey="${pak2}" --hostname=hs-guard-probe2 --advertise-tags=tag:superadmin --accept-dns=false --timeout=60s >/dev/null 2>&1
                    nodes2="$(hsx headscale nodes list -o json 2>/dev/null)"
                    superadmin_invalid "${nodes2}" hs-guard-probe2 && forced_tags_ok "${nodes2}" hs-guard-probe2 \
                        && ok "positive control: with tag:superadmin owned by nobody (the G5 shape) the same join lands it in invalid_tags" \
                        || bad "positive control: even an ownerless tag:superadmin was not invalid ($(jq -c '[.[]? | {given_name, forced_tags, valid_tags, invalid_tags}]' <<<"${nodes2}" 2>/dev/null))"
                    pak2=""
                else
                    bad "positive control: headscale did not come back on the G5-shaped template"
                fi
            else
                bad "no pre-auth key to join with (see the POST above)"
            fi
            # 5. no key in any log
            snap_logs
            [ -n "${LIVE_PROBE}" ] && docker logs "${LIVE_PROBE}" >>"${WORK}/logs.txt" 2>&1
            [ -n "${LIVE_PROBE2}" ] && docker logs "${LIVE_PROBE2}" >>"${WORK}/logs.txt" 2>&1
            cat "${WORK}/up.log" >>"${WORK}/logs.txt"
            if [ -n "${KEY}" ] && [ -n "${KEY2}" ] && logs_clean "${WORK}/logs.txt" "${KEY}" && logs_clean "${WORK}/logs.txt" "${KEY#*.}" \
                && logs_clean "${WORK}/logs.txt" "${KEY2}" && logs_clean "${WORK}/logs.txt" "${KEY2#*.}"; then
                ok "neither API key (before/after rotation, nor their secret halves) appears in any container log ($(wc -l < "${WORK}/logs.txt") lines scanned)"
            else
                bad "the API key appears in the logs (or was never read)"
            fi
            printf 'noise\nBearer %s\n' "${KEY:-x.y}" > "${WORK}/planted.txt"
            logs_clean "${WORK}/planted.txt" "${KEY:-x.y}" && bad "control: the log scan missed a planted key" || ok "control bites: the log scan finds a planted key"
            printf 'x' > "${WORK}/mode644"; chmod 0644 "${WORK}/mode644"
            [ "$(stat -c '%a' "${WORK}/mode644")" = 600 ] && bad "control: mode check" || ok "control bites: a 0644 file is not 0600"
            KEY=""; KEY2=""; PAK=""; resp=""
        fi
    fi
elif [ "${ROOT}" = "${REPO}" ]; then
    echo "-- LIVE leg not run (HUGMESH_HEADSCALE_LIVE=1 runs it; needs docker + network) --"
fi

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
