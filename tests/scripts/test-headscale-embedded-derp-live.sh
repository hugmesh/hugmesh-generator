#!/usr/bin/env bash
# test-headscale-embedded-derp-live.sh — the PINNED headscale, fed the configs this
# repo ships, starts and relays with NO internet (operator decision 2026-11-10,
# "Built-in relay on"; docs/HEADSCALE-DERP.md). The static half of this guard is
# tests/scripts/test-headscale-embedded-derp.sh.
#
# Throwaway containers on a private `--internal` docker network (no route out, no
# published ports, unique names, all removed on exit). Images come from the pins in
# build-x86-host-stage4.sh; the TLS front is stock nginx. Each config is rendered the
# way a node renders it at first boot: server_url rewritten, then keys-provision's
# REAL provision_headscale_derp (cluster domain derp.example).
#
#   0. NEGATIVE CONTROL: the pre-2026-11-10 shape (embedded server off, public map
#      only) on the same network exits "initial DERPMap is empty". This proves the
#      network really is offline — without it every check below could pass on a
#      host that quietly reached the internet.
#   A. keys-template/headscale/config.yaml (what a provisioned pki node runs): starts,
#      writes its DERP key under /var/lib/headscale, serves /derp (426 upgrade
#      required) and /derp/probe (200); a stock client joins, receives a DERP map with
#      ONLY region 999 named from the cluster domain, and its netcheck gets a STUN
#      answer (UDP true) from the embedded relay.
#   B. specs/etc/headscale/config.yaml with the public map OPTED IN: the public URL
#      is in the config, headscale tries it (and cannot reach it, offline) and STILL
#      starts, with the embedded region in the client's map.
#   C. relay through a TLS front (nginx terminating TLS, Upgrade passed through, the
#      shape of the local stack's https-front): two clients forced onto DERP reach
#      each other "via DERP(<region>)".
#
# EXIT: 0 all passed; 1 an assertion failed; 2 could not run (no docker daemon, an
# image could not be pulled) — a job FAILURE, never a skip.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN_SRC="${REPO}/build-x86-host-stage4.sh"
PROV="${REPO}/specs/etc/keys-provision/provision.sh"
NGINX_IMAGE="${DERP_LIVE_NGINX_IMAGE:-nginx:1.27-alpine}"
PUBLIC_URL="https://controlplane.tailscale.com/derpmap/default"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
cannot() { echo "CANNOT RUN: $*"; exit 2; }

for t in docker jq openssl awk python3; do command -v "$t" >/dev/null 2>&1 || cannot "$t is required"; done
docker info >/dev/null 2>&1 || cannot "no usable docker daemon"
HS_VER="$(sed -n 's/^HEADSCALE_VERSION="\([0-9.]*\)".*/\1/p' "${PIN_SRC}" | head -1)"
TS_VER="$(sed -n 's/^TAILSCALE_VERSION="\([0-9.]*\)".*/\1/p' "${PIN_SRC}" | head -1)"
[ -n "${HS_VER}" ] && [ -n "${TS_VER}" ] || cannot "could not read the HEADSCALE_VERSION / TAILSCALE_VERSION pins from ${PIN_SRC}"
HS_IMAGE="headscale/headscale:${HS_VER}"
TS_IMAGE="tailscale/tailscale:v${TS_VER}"
echo "== pinned: ${HS_IMAGE} + ${TS_IMAGE} (front: ${NGINX_IMAGE}) =="
for img in "${HS_IMAGE}" "${TS_IMAGE}" "${NGINX_IMAGE}"; do
    docker image inspect "${img}" >/dev/null 2>&1 || docker pull -q "${img}" >/dev/null 2>&1 || cannot "could not pull ${img}"
done

SFX="hsderp-live-$$-${RANDOM}"
NET="${SFX}-net"
WORK="$(mktemp -d)"
CONTAINERS=()
cleanup() {
    local c
    for c in "${CONTAINERS[@]}"; do docker rm -fv "${c}" >/dev/null 2>&1; done
    docker network rm "${NET}" >/dev/null 2>&1
    # headscale wrote its state as root inside the container; remove it the same way.
    docker run --rm -v "${WORK}:/w" --entrypoint /bin/sh "${TS_IMAGE}" -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1
    rm -rf "${WORK}" 2>/dev/null
}
trap cleanup EXIT
docker network create --internal "${NET}" >/dev/null || cannot "could not create the --internal network"
[ "$(docker network inspect -f '{{.Internal}}' "${NET}")" = "true" ] || cannot "network ${NET} is not internal"

# keys-provision's REAL DERP step, extracted from provision.sh.
awk '/^# ── headscale DERP relay: offline-first/{f=1} /^provision_headscale\(\) \{/{f=0} f' "${PROV}" > "${WORK}/derp-fns.sh"
grep -E '^provision_headscale_derp\(\) \{' "${WORK}/derp-fns.sh" >/dev/null || cannot "provision_headscale_derp not found in ${PROV}"

# hs_up <label> <config-src|-> <server_url> <public_derp true|false> [config text on stdin when src is -]
# Renders the config like a first boot and starts headscale as ${SFX}-<label>.
hs_up() {
    local label="$1" src="$2" url="$3" pub="$4" d="${WORK}/$1" name="${SFX}-$1"
    mkdir -p "${d}/etc" "${d}/lib" "${d}/run" "${d}/hm"
    if [ "${src}" = "-" ]; then cat > "${d}/etc/config.yaml"; else cp "${REPO}/${src}" "${d}/etc/config.yaml"; fi
    printf '%s\n' '{"acls":[{"action":"accept","src":["*"],"dst":["*:*"]}]}' > "${d}/etc/policy.hujson"
    echo "live-test-oidc-secret" > "${d}/lib/oidc_client_secret"
    sed -i "s|^server_url:.*|server_url: ${url}|" "${d}/etc/config.yaml"
    printf '{"hugmesh":{"cluster_domain":"derp.example"},"headscale":{"public_derp":%s}}\n' "${pub}" > "${d}/provision.json"
    (
        log()  { echo "[keys-provision] $*"; }; warn() { echo "[keys-provision] WARNING: $*"; }
        jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }
        # shellcheck source=/dev/null
        . "${WORK}/derp-fns.sh"
        HEADSCALE_PUBLIC_DERP_MARKER="${d}/hm/headscale-public-derp"
        HEADSCALE_DERP_STUN_MARKER="${d}/hm/headscale-derp-stun"
        MANIFEST="${d}/provision.json"
        provision_headscale_derp "${d}/etc/config.yaml"
    ) > "${d}/provision.log" 2>&1
    chmod -R a+rwX "${d}"
    CONTAINERS+=("${name}")
    docker run -d --name "${name}" --network "${NET}" -v "${d}/etc:/etc/headscale" -v "${d}/lib:/var/lib/headscale" \
        -v "${d}/run:/run/headscale" "${HS_IMAGE}" serve >/dev/null 2>&1 || return 1
    local i
    for i in $(seq 1 20); do
        docker logs "${name}" 2>&1 | grep -E 'listening and serving HTTP|Headscale ran into an error' >/dev/null && break
        sleep 1
    done
    return 0
}
hs_running() { [ "$(docker inspect -f '{{.State.Running}}' "${SFX}-$1" 2>/dev/null)" = "true" ]; }
hs_log() { docker logs "${SFX}-$1" 2>&1; }
# ts_up <label> <hs-label> <login-server> [extra docker args...]
ts_up() {
    local label="$1" hs="${SFX}-$2" login="$3" name="${SFX}-$1" key
    shift 3
    docker exec "${hs}" headscale users create live >/dev/null 2>&1
    key="$(docker exec "${hs}" headscale preauthkeys create --user live --expiration 1h 2>/dev/null | tail -1)"
    [ -n "${key}" ] || return 1
    CONTAINERS+=("${name}")
    docker run -d --name "${name}" --network "${NET}" "$@" -e TS_AUTHKEY="${key}" -e TS_USERSPACE=true \
        -e TS_STATE_DIR=/var/lib/tailscale -e TS_EXTRA_ARGS="--login-server=${login} --hostname=${label}" \
        "${TS_IMAGE}" >/dev/null 2>&1 || return 1
    local i
    for i in $(seq 1 40); do
        docker exec "${name}" tailscale ip -4 >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}
regions() {  # regions <ts-label> -> "id:code:name" lines
    docker exec "${SFX}-$1" tailscale debug derp-map 2>/dev/null | python3 -c '
import json, sys
m = json.load(sys.stdin)
for rid, r in sorted((m.get("Regions") or {}).items(), key=lambda kv: int(kv[0])):
    print("%s:%s:%s" % (rid, r.get("RegionCode"), r.get("RegionName")))'
}
http_status() {  # http_status <ts-label> <url>
    docker exec "${SFX}-$1" wget -S -q -O /dev/null "$2" 2>&1 | awk '/HTTP\//{print $2; exit}'
}

# ── 0. negative control: the old shape cannot start offline ──────────────────
echo "-- 0. negative control: public-map-only config on the offline network --"
hs_up old - "http://${SFX}-old:8080" false <<'YAML'
server_url: http://placeholder:8080
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
noise:
  private_key_path: /var/lib/headscale/noise_private.key
policy:
  mode: file
  path: /etc/headscale/policy.hujson
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
derp:
  server:
    enabled: false
  urls:
    - https://controlplane.tailscale.com/derpmap/default
disable_check_updates: true
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
dns:
  magic_dns: true
  base_domain: headnet.internal
unix_socket: /run/headscale/headscale.sock
YAML
sleep 2
if ! hs_running old && hs_log old | grep -F 'initial DERPMap is empty' >/dev/null; then
    ok "the pre-2026-11-10 config exits 'initial DERPMap is empty' here (the network is really offline)"
else
    bad "the public-map-only config did NOT fail — the network is not offline, so nothing below proves offline operation"
fi

# ── A. KEYS template, default ────────────────────────────────────────────────
echo "-- A. keys-template/headscale/config.yaml (default: embedded relay only) --"
hs_up keys keys-template/headscale/config.yaml "http://${SFX}-keys:8080" false || cannot "could not start headscale (keys)"
if hs_running keys && ! hs_log keys | grep -F 'initial DERPMap is empty' >/dev/null; then
    ok "headscale ${HS_VER} starts offline with the KEYS-template config"
else
    bad "headscale did not start offline: $(hs_log keys | grep -E 'FTL|ERR' | head -2 | tr '\n' ' ')"
fi
hs_log keys | grep -F 'STUN server started' >/dev/null && ok "embedded STUN listener is up" || bad "no STUN listener in the log"
[ -s "${WORK}/keys/lib/derp_server_private.key" ] && ok "DERP server key persisted under /var/lib/headscale" \
    || bad "no /var/lib/headscale/derp_server_private.key"
[ "$(tr -d '[:space:]' < "${WORK}/keys/hm/headscale-derp-stun" 2>/dev/null)" = "3478" ] \
    && ok "keys-provision handed STUN 3478 to the node firewall" || bad "no STUN hand-off marker"
if ts_up c1 keys "http://${SFX}-keys:8080"; then
    ok "a stock tailscale ${TS_VER} client joins the offline mesh"
    st="$(http_status c1 "http://${SFX}-keys:8080/derp")"
    [ "${st}" = "426" ] && ok "GET /derp -> 426 (the DERP endpoint is served; it wants an Upgrade)" || bad "GET /derp -> ${st:-no answer}"
    st="$(http_status c1 "http://${SFX}-keys:8080/derp/probe")"
    [ "${st}" = "200" ] && ok "GET /derp/probe -> 200" || bad "GET /derp/probe -> ${st:-no answer}"
    r="$(regions c1)"
    [ "${r}" = "999:derp:derp.example embedded relay" ] \
        && ok "the client's DERP map is ONLY the embedded region (999:derp:derp.example embedded relay)" \
        || bad "the client's DERP map is not just the embedded region: $(printf '%s' "${r}" | tr '\n' ' ')"
    nc="$(docker exec "${SFX}-c1" tailscale netcheck 2>&1)"
    printf '%s\n' "${nc}" | grep -E '^[[:space:]]*\* UDP: true' >/dev/null \
        && ok "netcheck: STUN answered by the embedded relay (UDP: true)" || bad "netcheck: no STUN answer"
    printf '%s\n' "${nc}" | grep -F 'Nearest DERP: derp.example embedded relay' >/dev/null \
        && ok "netcheck: nearest DERP is the embedded relay" || bad "netcheck: nearest DERP is not the embedded relay"
else
    bad "a stock client could not join the offline mesh"
fi

# ── B. node config with the public map opted in ─────────────────────────────
echo "-- B. specs/etc/headscale/config.yaml with the public map OPTED IN --"
hs_up optin specs/etc/headscale/config.yaml "http://${SFX}-optin:8080" true || cannot "could not start headscale (optin)"
grep -F "  urls: [\"${PUBLIC_URL}\"]" "${WORK}/optin/etc/config.yaml" >/dev/null \
    && ok "the opt-in put the public DERP map URL in the config" || bad "the opt-in did not add the public URL"
hs_log optin | grep -F "url=${PUBLIC_URL}" >/dev/null \
    && ok "headscale tried the public map (and could not reach it — offline)" || bad "headscale never tried the public map"
if hs_running optin && ! hs_log optin | grep -F 'initial DERPMap is empty' >/dev/null; then
    ok "it still starts: the embedded region keeps the map non-empty"
else
    bad "the opted-in config did not start offline"
fi
if ts_up c2 optin "http://${SFX}-optin:8080"; then
    regions c2 | grep -E '^999:derp:' >/dev/null && ok "the embedded region is in the opted-in client's map" \
        || bad "the embedded region is missing from the opted-in map"
else
    bad "a stock client could not join the opted-in mesh"
fi

# ── C. relay through a TLS front ─────────────────────────────────────────────
echo "-- C. DERP relay through a TLS front (nginx, Upgrade passed through) --"
FR="${SFX}-front"
mkdir -p "${WORK}/front-tls"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=derp live CA" \
    -keyout "${WORK}/front-tls/ca.key" -out "${WORK}/front-tls/ca.crt" >/dev/null 2>&1
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=${FR}" \
    -keyout "${WORK}/front-tls/server.key" -out "${WORK}/front-tls/server.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\n' "${FR}" > "${WORK}/front-tls/ext"
openssl x509 -req -in "${WORK}/front-tls/server.csr" -CA "${WORK}/front-tls/ca.crt" -CAkey "${WORK}/front-tls/ca.key" -CAcreateserial \
    -days 1 -extfile "${WORK}/front-tls/ext" -out "${WORK}/front-tls/server.crt" >/dev/null 2>&1 || cannot "could not mint the test TLS cert"
hs_up tls keys-template/headscale/config.yaml "https://${FR}" false || cannot "could not start headscale (tls)"
cat > "${WORK}/front-tls/default.conf" <<NG
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
server {
    listen 443 ssl;
    server_name ${FR};
    ssl_certificate /tls/server.crt;
    ssl_certificate_key /tls/server.key;
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_buffering off;
    proxy_read_timeout 300s;
    location / { proxy_pass http://${SFX}-tls:8080; }
}
NG
chmod -R a+rX "${WORK}/front-tls"
CONTAINERS+=("${FR}")
docker run -d --name "${FR}" --network "${NET}" -v "${WORK}/front-tls/default.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "${WORK}/front-tls:/tls:ro" "${NGINX_IMAGE}" >/dev/null 2>&1 || cannot "could not start the TLS front"
sleep 2
DERP_ONLY=(-v "${WORK}/front-tls/ca.crt:/ca.crt:ro" -e SSL_CERT_FILE=/ca.crt -e TS_DEBUG_ALWAYS_USE_DERP=true)
if ts_up r1 tls "https://${FR}" "${DERP_ONLY[@]}" && ts_up r2 tls "https://${FR}" "${DERP_ONLY[@]}"; then
    ok "two clients join through the TLS front"
    docker exec "${SFX}-r1" tailscale debug derp 999 2>&1 | grep -F 'Successfully established a DERP connection' >/dev/null \
        && ok "a DERP connection is established through the front (TLS + Upgrade)" \
        || bad "no DERP connection through the front"
    ip1="$(docker exec "${SFX}-r1" tailscale ip -4 2>/dev/null)"
    pong=""
    for i in $(seq 1 15); do
        pong="$(docker exec "${SFX}-r2" tailscale ping -c 1 --until-direct=false "${ip1}" 2>&1)"
        printf '%s\n' "${pong}" | grep -F 'via DERP(derp)' >/dev/null && break
        sleep 1
    done
    printf '%s\n' "${pong}" | grep -F 'via DERP(derp)' >/dev/null \
        && ok "peer traffic is relayed by the embedded DERP (pong via DERP(derp))" \
        || bad "no relayed pong: $(printf '%s' "${pong}" | tr '\n' ' ')"
else
    bad "the clients could not join through the TLS front"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
