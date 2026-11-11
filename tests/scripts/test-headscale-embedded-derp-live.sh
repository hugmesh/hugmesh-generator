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
#      answer (UDP true) from the embedded relay. It also pins the documented limit:
#      with that http:// server_url the relay itself refuses (clients speak TLS).
#   B. specs/etc/headscale/config.yaml with the public map OPTED IN: the public URL
#      is in the config, headscale tries it (and cannot reach it, offline) and STILL
#      starts, with the embedded region in the client's map.
#   C. relay through the local stack's REAL TLS front: tests/stack/tls-front/default.conf
#      itself, unedited, in stock nginx (its hs.<domain> server block: TLS on 8443,
#      http2 on, Upgrade/Connection passed through to hugmesh-headscale:8080). Two
#      clients forced onto DERP reach each other "via DERP(<region>)". The same front
#      refuses /derp (403) to a source in a public range and serves it to a private one.
#   D. the SHIPPED node path, nothing edited by hand: gen-provision-keys.sh sticks,
#      keys-provision's own functions in the node's network namespace (HTTPS server_url
#      on the LAN IP, a certificate from the stick's mesh CA), two workers on split
#      networks that migrate their old http:// URL, join and relay "via DERP(hugmesh)"
#      to an IP-literal node with a TCP payload crossing; a capture of headscale's
#      namespace (no Tailscale lookups, no off-net attempts, with a positive control);
#      the pki node's own client at https://127.0.0.1; a worker without the CA does not
#      join.
#
# EXIT: 0 all passed; 1 an assertion failed; 2 could not run (no docker daemon, an
# image could not be pulled) — a job FAILURE, never a skip.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN_SRC="${REPO}/build-x86-host-stage4.sh"
PROV="${REPO}/specs/etc/keys-provision/provision.sh"
FRONT_CONF="${DERP_LIVE_FRONT_CONF:-${REPO}/tests/stack/tls-front/default.conf}"  # override only to mutation-test section C
NGINX_IMAGE="${DERP_LIVE_NGINX_IMAGE:-nginx:1.27-alpine}"
# netshoot (bash, jq, openssl, curl, iproute2, tcpdump) runs keys-provision's functions
# in a node's network namespace and holds the client namespaces. Pinned by digest: the
# tag `latest` moves, and this is the build the suite was measured with.
NSI="${DERP_LIVE_NETSHOOT_IMAGE:-nicolaka/netshoot@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70}"
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
for img in "${HS_IMAGE}" "${TS_IMAGE}" "${NGINX_IMAGE}" "${NSI}"; do
    docker image inspect "${img}" >/dev/null 2>&1 || docker pull -q "${img}" >/dev/null 2>&1 || cannot "could not pull ${img}"
done

SFX="hsderp-live-$$-${RANDOM}"
NET="${SFX}-net"
WORK="$(mktemp -d)"
CONTAINERS=()
EXTRA_NETS=()
cleanup() {
    local c
    for c in "${CONTAINERS[@]}"; do docker rm -fv "${c}" >/dev/null 2>&1; done
    docker network rm "${NET}" >/dev/null 2>&1
    for c in "${EXTRA_NETS[@]}"; do docker network rm "${c}" >/dev/null 2>&1; done
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
# HS_DOCKER_ARGS (array) adds docker run arguments (section C: a network alias).
HS_DOCKER_ARGS=()
HS_NO_PROVISION=""   # set: start the config exactly as given (section 0's negative control)
hs_up() {
    local label="$1" src="$2" url="$3" pub="$4" d="${WORK}/$1" name="${SFX}-$1"
    mkdir -p "${d}/etc" "${d}/lib" "${d}/run" "${d}/hm"
    if [ "${src}" = "-" ]; then cat > "${d}/etc/config.yaml"; else cp "${REPO}/${src}" "${d}/etc/config.yaml"; fi
    printf '%s\n' '{"acls":[{"action":"accept","src":["*"],"dst":["*:*"]}]}' > "${d}/etc/policy.hujson"
    echo "live-test-oidc-secret" > "${d}/lib/oidc_client_secret"
    sed -i "s|^server_url:.*|server_url: ${url}|" "${d}/etc/config.yaml"
    printf '{"hugmesh":{"cluster_domain":"derp.example"},"headscale":{"public_derp":%s}}\n' "${pub}" > "${d}/provision.json"
    [ -n "${HS_NO_PROVISION}" ] || (
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
    docker run -d --name "${name}" --network "${NET}" "${HS_DOCKER_ARGS[@]}" -v "${d}/etc:/etc/headscale" \
        -v "${d}/lib:/var/lib/headscale" -v "${d}/run:/run/headscale" "${HS_IMAGE}" serve >/dev/null 2>&1 || return 1
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
    # The membership user the shipped policies grant tag:hugmesh to (the tag-owners guard
    # reads every literal `preauthkeys create --user` in the tree as a key-minting user).
    docker exec "${hs}" headscale users create hugmesh >/dev/null 2>&1
    key="$(docker exec "${hs}" headscale preauthkeys create --user hugmesh --expiration 1h 2>/dev/null | tail -1)"
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
# The shape every KEYS stick written before 2026-11-10 carries. Started AS IS it must
# die here (that is what proves the network offline); through keys-provision's
# provision_headscale_derp it is migrated (embedded relay on, public map out) and starts.
cat > "${WORK}/old-shape.yaml" <<'YAML'
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
HS_NO_PROVISION=1 hs_up old - "http://${SFX}-old:8080" false < "${WORK}/old-shape.yaml"
sleep 2
if ! hs_running old && hs_log old | grep -F 'initial DERPMap is empty' >/dev/null; then
    ok "the pre-2026-11-10 config exits 'initial DERPMap is empty' here (the network is really offline)"
else
    bad "the public-map-only config did NOT fail — the network is not offline, so nothing below proves offline operation"
fi
hs_up oldmig - "http://${SFX}-oldmig:8080" false < "${WORK}/old-shape.yaml"
sleep 2
if hs_running oldmig && grep -F 'embedded DERP server turned ON' "${WORK}/oldmig/provision.log" >/dev/null \
   && [ -s "${WORK}/oldmig/etc/config.yaml.derp.bak" ]; then
    ok "the same old-shape KEYS config, through keys-provision, is migrated (relay on, public map out, .derp.bak kept) and starts offline"
else
    bad "the old-shape KEYS config was not migrated into a config that starts offline: $(hs_log oldmig | grep -E 'FTL' | head -1) $(grep -E 'DERP' "${WORK}/oldmig/provision.log" | tr '\n' ' ')"
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
    # The documented LIMIT (docs/HEADSCALE-DERP.md "Relaying needs an HTTPS server_url"):
    # clients always speak TLS to a DERP node, so a plain http:// server_url leaves the
    # relay itself unusable. Pinned here so the doc goes red the day that changes.
    dd="$(docker exec "${SFX}-c1" tailscale debug derp 999 2>&1)"
    printf '%s\n' "${dd}" | grep -F 'first record does not look like a TLS handshake' >/dev/null \
        && ok "documented limit holds: an http:// server_url leaves the relay unusable (clients speak TLS to DERP)" \
        || bad "the http:// server_url relay limit changed — update docs/HEADSCALE-DERP.md: $(printf '%s' "${dd}" | tail -2 | tr '\n' ' ')"
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
echo "-- C. DERP relay through the local stack's real TLS front (tests/stack/tls-front/default.conf) --"
# The front runs the repo's file UNEDITED: its hs.<domain> block listens on 8443 with
# http2 on and proxies to hugmesh-headscale:8080 through docker's resolver. So the
# headscale container carries that alias, the front answers as hs.derp.test, and the
# cert sits where the file reads it (/etc/hugmesh-tls/{fullchain.crt,server.key}).
[ -f "${FRONT_CONF}" ] || cannot "missing ${FRONT_CONF}"
FR="${SFX}-front"
FRONT_HOST="hs.derp.test"
mkdir -p "${WORK}/front-tls"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=derp live CA" \
    -keyout "${WORK}/front-tls/ca.key" -out "${WORK}/front-tls/ca.crt" >/dev/null 2>&1
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=${FRONT_HOST}" \
    -keyout "${WORK}/front-tls/server.key" -out "${WORK}/front-tls/server.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\n' "${FRONT_HOST}" > "${WORK}/front-tls/ext"
openssl x509 -req -in "${WORK}/front-tls/server.csr" -CA "${WORK}/front-tls/ca.crt" -CAkey "${WORK}/front-tls/ca.key" -CAcreateserial \
    -days 1 -extfile "${WORK}/front-tls/ext" -out "${WORK}/front-tls/fullchain.crt" >/dev/null 2>&1 || cannot "could not mint the test TLS cert"
HS_DOCKER_ARGS=(--network-alias hugmesh-headscale)
hs_up tls keys-template/headscale/config.yaml "https://${FRONT_HOST}:8443" false || cannot "could not start headscale (tls)"
HS_DOCKER_ARGS=()
chmod -R a+rX "${WORK}/front-tls"
CONTAINERS+=("${FR}")
docker run -d --name "${FR}" --network "${NET}" --network-alias "${FRONT_HOST}" \
    -v "${FRONT_CONF}:/etc/nginx/conf.d/default.conf:ro" -v "${WORK}/front-tls:/etc/hugmesh-tls:ro" \
    "${NGINX_IMAGE}" >/dev/null 2>&1 || cannot "could not start the TLS front"
sleep 2
[ "$(docker inspect -f '{{.State.Running}}' "${FR}" 2>/dev/null)" = "true" ] \
    || cannot "the real tls-front config did not start in ${NGINX_IMAGE}: $(docker logs "${FR}" 2>&1 | tail -3 | tr '\n' ' ')"
DERP_ONLY=(-v "${WORK}/front-tls/ca.crt:/ca.crt:ro" -e SSL_CERT_FILE=/ca.crt -e TS_DEBUG_ALWAYS_USE_DERP=true)
if ts_up r1 tls "https://${FRONT_HOST}:8443" "${DERP_ONLY[@]}" && ts_up r2 tls "https://${FRONT_HOST}:8443" "${DERP_ONLY[@]}"; then
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
# Who the front relays for: /derp answers private sources only (headscale's embedded relay
# has no client verification). The front is also put on a network in a PUBLIC range
# (a documentation prefix, still --internal) and asked from there.
PUBNET="${SFX}-pub"
for sub in 198.51.100.0/24 203.0.113.0/24; do
    docker network create --internal --subnet "${sub}" "${PUBNET}" >/dev/null 2>&1 && { EXTRA_NETS+=("${PUBNET}"); break; }
done
if [ "${EXTRA_NETS[*]:-}" = "${PUBNET}" ] && docker network connect "${PUBNET}" "${FR}" >/dev/null 2>&1; then
    FR_PUB="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${PUBNET}\").IPAddress}}" "${FR}")"
    FR_PRIV="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NET}\").IPAddress}}" "${FR}")"
    probe() {  # probe <network> <front address> <path>
        docker run --rm --network "$1" --entrypoint curl "${NSI}" -sk -o /dev/null -w '%{http_code}' -m 5 \
            --resolve "${FRONT_HOST}:8443:$2" "https://${FRONT_HOST}:8443$3" 2>/dev/null
    }
    pub_derp="$(probe "${PUBNET}" "${FR_PUB}" /derp/probe)"; pub_root="$(probe "${PUBNET}" "${FR_PUB}" /health)"
    priv_derp="$(probe "${NET}" "${FR_PRIV}" /derp/probe)"
    [ "${pub_derp}" = 403 ] && [ "${priv_derp}" = 200 ] && [ "${pub_root}" = 200 ] \
        && ok "the front refuses /derp to a public-range source (403) and serves it to a private one (200); control stays open to both" \
        || bad "front /derp allow-list: public /derp/probe=${pub_derp:-none} (want 403), private=${priv_derp:-none} (want 200), public /health=${pub_root:-none} (want 200)"
else
    bad "could not put the front on a public-range network to test its /derp allow-list"
fi

# ── D. the SHIPPED node path: HTTPS from the mesh CA, peers on split networks ──
echo "-- D. shipped node path: gen-provision-keys sticks -> keys-provision -> headscale HTTPS; peers on split networks relay --"
# Nothing here is edited by hand. The pki stick and the worker sticks are the output
# of scripts/gen-provision-keys.sh (pki: its own mesh CA; workers: --ca-cert of that
# CA). keys-provision's REAL functions (extracted from provision.sh, sourced in a
# netshoot container that shares the node's network namespace) install the stick's
# certs, copy the stick's headscale/config.yaml, resolve the endpoint from the node's
# own route (https://<LAN IP>:8080), issue the serving certificate from the stick's CA
# key and render the DERP block. The workers run provision_certs from their own stick
# and control_url_tls_migrate on the OLD default URL http://<pki LAN IP>:8080 an
# existing stick carries. Topology: the pki node sits on two --internal networks, a
# and b; d1 is on a, d2 on b. d2 reaches the pki node's a-address through a /32 route
# via the pki node's b-address (a second LAN that routes to the control server) and
# has NO path to d1, so d1<->d2 traffic can only go through the embedded relay. No
# TS_DEBUG_* knob forces DERP: the topology does.
command -v keytool >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1 \
    || cannot "keytool and ssh-keygen are required to run scripts/gen-provision-keys.sh (section D)"
NA="${SFX}-a"; NB="${SFX}-b"
for n in "${NA}" "${NB}"; do
    docker network create --internal "${n}" >/dev/null || cannot "could not create network ${n}"
    EXTRA_NETS+=("${n}")
done
D="${WORK}/d"; mkdir -p "${D}"
GPK="${REPO}/scripts/gen-provision-keys.sh"
NONINTERACTIVE=1 HEADSCALE_PUBLIC_DERP= bash "${GPK}" -r pki -o "${D}/keys-pki" --random --no-device-ssh > "${D}/gpk-pki.log" 2>&1 \
    || cannot "gen-provision-keys.sh (pki) failed: $(tail -3 "${D}/gpk-pki.log" | tr '\n' ' ')"
NONINTERACTIVE=1 bash "${GPK}" -r host -o "${D}/keys-w" --random --no-device-ssh --ca-cert "${D}/keys-pki/certs/cluster-ca.crt" > "${D}/gpk-w.log" 2>&1 \
    || cannot "gen-provision-keys.sh (worker) failed: $(tail -3 "${D}/gpk-w.log" | tr '\n' ' ')"
NONINTERACTIVE=1 bash "${GPK}" -r host -o "${D}/keys-noca" --random --no-device-ssh > "${D}/gpk-noca.log" 2>&1 \
    || cannot "gen-provision-keys.sh (worker, no CA) failed: $(tail -3 "${D}/gpk-noca.log" | tr '\n' ' ')"
[ -f "${D}/keys-pki/certs/cluster-ca.key" ] && [ -f "${D}/keys-w/certs/cluster-ca.crt" ] && [ ! -e "${D}/keys-noca/certs/cluster-ca.crt" ] \
    && ok "gen-provision-keys.sh: the pki stick carries its mesh CA pair, the --ca-cert worker stick the CA certificate, the plain worker stick none" \
    || bad "unexpected stick contents: pki CA key $(ls "${D}/keys-pki/certs" 2>&1 | tr '\n' ' '); worker $(ls "${D}/keys-w/certs" 2>&1 | tr '\n' ' ')"

# keys-provision's functions, verbatim, plus the helpers provision.sh defines at its top.
{
    echo 'log()  { echo "[keys-provision] $*"; }; warn() { echo "[keys-provision] WARNING: $*"; }'
    echo 'have() { command -v "$1" >/dev/null 2>&1; }'
    echo 'jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }; jqe() { jq -e "$1" "${MANIFEST}" >/dev/null 2>&1; }'
    for fn in resolve_lan_ip resolve_endpoint resolve_control_endpoint resolve_magic_dns_domain provision_certs \
              control_self_login_server control_url_tls_migrate; do
        sed -n "/^${fn}() {/,/^}/p" "${PROV}"
    done
    sed -n '/^HEADSCALE_CONFIG=/p' "${PROV}"
    awk '/^# ── headscale DERP relay: offline-first/{f=1} /^provision_headscale\(\) \{/{f=0} f' "${PROV}"
} > "${D}/prov-lib.sh"
for fn in resolve_endpoint provision_certs control_self_login_server control_url_tls_migrate provision_headscale_config provision_headscale_tls; do
    grep -E "^${fn}\(\) \{" "${D}/prov-lib.sh" >/dev/null || cannot "${fn} not found in ${PROV}"
done
cat > "${D}/prov-pki.sh" <<'EOF'
# Runs in the pki node's network namespace: provision_certs + the headscale config stage.
set -uo pipefail
. /w/prov-lib.sh
BASE=/w/keys-pki; MANIFEST="${BASE}/provision.json"
HEADSCALE_PUBLIC_DERP_MARKER=/etc/hugmesh/headscale-public-derp
HEADSCALE_DERP_STUN_MARKER=/etc/hugmesh/headscale-derp-stun
provision_certs
cp -f "${BASE}/headscale/config.yaml" /etc/headscale/config.yaml      # provision_headscale's KEYS config copy
provision_headscale_config /etc/headscale/config.yaml
HEADSCALE_CONFIG=/etc/headscale/config.yaml
control_self_login_server > /w/pki/self-login
EOF
cat > "${D}/prov-client.sh" <<'EOF'
# Runs in a worker's network namespace: provision_certs from its stick, then the
# control-URL check on the URL the stick names. $1 = stick dir, $2 = login URL, $3 = out dir.
set -uo pipefail
. /w/prov-lib.sh
BASE="$1"; MANIFEST="${BASE}/provision.json"
provision_certs
control_url_tls_migrate "$2"
printf '%s\n' "${CONTROL_URL}" > "$3/login"
EOF

# The pki node's network namespace: eth0 on a, eth1 on b. Its default route is on-link
# on eth0 (what a LAN node has, and what resolve_lan_ip reads). headscale's resolver is
# a sinkhole address with a static neighbour entry, so every DNS query and every off-net
# connection attempt it makes goes out on the wire, where the capture below sees it
# (an --internal network with no route would make that capture vacuous).
PKI="${SFX}-pki"
mkdir -p "${D}/pki/etc" "${D}/pki/lib" "${D}/pki/run" "${D}/pki/hm" "${D}/pki/ssl" "${D}/cap"
printf '%s\n' '{"acls":[{"action":"accept","src":["*"],"dst":["*:*"]}]}' > "${D}/pki/etc/policy.hujson"
printf 'nameserver 192.0.2.53\n' > "${D}/resolv.conf"
echo "live-test-oidc-secret" > "${D}/pki/lib/oidc_client_secret"
CONTAINERS+=("${PKI}")
docker run -d --name "${PKI}" --network "${NA}" --cap-add NET_ADMIN --cap-add NET_RAW \
    -v "${D}/cap:/cap" --entrypoint sleep "${NSI}" infinity >/dev/null || cannot "could not start the pki namespace"
docker network connect "${NB}" "${PKI}" || cannot "could not attach the pki node to network b"
docker exec "${PKI}" sh -c 'ip route add default dev eth0 && ip neigh replace 192.0.2.53 lladdr 02:00:5e:00:02:35 dev eth0 nud permanent' \
    || cannot "could not set the pki node's on-link default route"
PKI_A="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NA}\").IPAddress}}" "${PKI}")"
PKI_B="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NB}\").IPAddress}}" "${PKI}")"
docker run --rm --network "container:${PKI}" -v "${D}:/w" -v "${D}/pki/etc:/etc/headscale" -v "${D}/pki/lib:/var/lib/headscale" \
    -v "${D}/pki/hm:/etc/hugmesh" -v "${D}/pki/ssl:/etc/ssl/certs" --entrypoint bash "${NSI}" /w/prov-pki.sh > "${D}/prov-pki.log" 2>&1
sed 's/^/     /' "${D}/prov-pki.log" | grep -E 'TLS|server_url|DERP|WARNING' | head -12
SU="$(sed -n 's/^server_url:[[:space:]]*//p' "${D}/pki/etc/config.yaml" | head -1)"
[ "${SU}" = "https://${PKI_A}:8080" ] \
    && ok "keys-provision resolved server_url https://<the node's LAN IP>:8080 (${SU})" \
    || bad "server_url is '${SU}', expected https://${PKI_A}:8080"
grep -E '^tls_cert_path: "/var/lib/headscale/tls.crt"$' "${D}/pki/etc/config.yaml" >/dev/null \
  && grep -E '^tls_key_path: "/var/lib/headscale/tls.key"$' "${D}/pki/etc/config.yaml" >/dev/null \
    && ok "keys-provision pointed tls_cert_path/tls_key_path at the issued pair" \
    || bad "tls_cert_path/tls_key_path not set: $(grep '^tls_' "${D}/pki/etc/config.yaml" | tr '\n' ' ')"
if openssl verify -CAfile "${D}/keys-pki/certs/cluster-ca.crt" "${D}/pki/lib/tls.crt" >/dev/null 2>&1; then
    ok "the serving certificate chains to the pki stick's mesh CA"
else
    bad "the serving certificate does not verify against keys-pki/certs/cluster-ca.crt"
fi
sans="$(openssl x509 -in "${D}/pki/lib/tls.crt" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ')"
miss=""
for a in "${PKI_A}" "${PKI_B}" 127.0.0.1; do
    printf ',%s,' "${sans}" | grep -F ",IPAddress:${a}," >/dev/null || miss="${miss} ${a}"
done
[ -z "${miss}" ] && ok "the certificate names the server_url address, the node's other address and loopback (IP SANs; no hostname needed)" \
                 || bad "the certificate does not name${miss}: ${sans}"
grep -F "$(cat "${D}/keys-pki/certs/cluster-ca.crt" | sed -n 2p)" "${D}/pki/ssl/ca-certificates.crt" >/dev/null 2>&1 \
    && ok "provision_certs put the stick's mesh CA into the node's system trust store" \
    || bad "the mesh CA is not in the pki node's trust store bundle"
[ "$(cat "${D}/pki/self-login" 2>/dev/null)" = "https://127.0.0.1:8080" ] \
    && ok "control_self_login_server: the control node's own client logs in at https://127.0.0.1:8080" \
    || bad "control node self-login URL is '$(cat "${D}/pki/self-login" 2>/dev/null)'"

# Capture A: everything headscale says off the mesh, from before it starts.
docker exec -d "${PKI}" sh -c 'tcpdump -i any -nn -l "udp port 53 or tcp port 53 or arp" > /cap/a.txt 2>/cap/a.err'
sleep 2
HS="${SFX}-hs"
CONTAINERS+=("${HS}")
docker run -d --name "${HS}" --network "container:${PKI}" -v "${D}/resolv.conf:/etc/resolv.conf:ro" -v "${D}/pki/etc:/etc/headscale" \
    -v "${D}/pki/lib:/var/lib/headscale" -v "${D}/pki/run:/run/headscale" "${HS_IMAGE}" serve >/dev/null || cannot "could not start headscale (section D)"
for i in $(seq 1 25); do
    docker logs "${HS}" 2>&1 | grep -E 'listening and serving HTTP|Headscale ran into an error' >/dev/null && break
    sleep 1
done
[ "$(docker inspect -f '{{.State.Running}}' "${HS}" 2>/dev/null)" = "true" ] \
    && ok "headscale ${HS_VER} serves the provisioned config offline" \
    || bad "headscale died: $(docker logs "${HS}" 2>&1 | grep -E 'FTL|ERR' | head -2 | tr '\n' ' ')"
docker exec "${HS}" headscale users create hugmesh >/dev/null 2>&1
DKEY="$(docker exec "${HS}" headscale preauthkeys create --user hugmesh --reusable --expiration 1h 2>/dev/null | tail -1)"
[ -n "${DKEY}" ] || cannot "could not mint a preauth key (section D)"

# client <label> <network> <stick> <login-url> [holder docker args...]
# A netns holder on <network>, the client's own provision_certs + control_url_tls_migrate
# in it, then a stock tailscale client in it that trusts exactly that trust store.
client() {
    local label="$1" net="$2" stick="$3" url="$4" h="${SFX}-$1-ns" c="${SFX}-$1"
    shift 4
    mkdir -p "${D}/${label}/ssl" "${D}/${label}/ts"
    CONTAINERS+=("${h}")
    docker run -d --name "${h}" --network "${net}" "$@" --entrypoint sleep "${NSI}" infinity >/dev/null || return 1
    [ -n "${CLIENT_ROUTE:-}" ] && docker exec "${h}" ip route add ${CLIENT_ROUTE}
    docker run --rm --network "container:${h}" -v "${D}:/w" -v "${D}/${label}/ssl:/etc/ssl/certs" --entrypoint bash "${NSI}" \
        /w/prov-client.sh "/w/${stick}" "${url}" "/w/${label}" > "${D}/${label}/prov.log" 2>&1
    CONTAINERS+=("${c}")
    docker run -d --name "${c}" --network "container:${h}" -v "${D}/${label}/ssl:/etc/ssl/certs:ro" \
        -e TS_AUTHKEY="${DKEY}" -e TS_USERSPACE=true -e TS_STATE_DIR=/var/lib/tailscale \
        -e TS_EXTRA_ARGS="--login-server=$(cat "${D}/${label}/login") --hostname=${label}" "${TS_IMAGE}" >/dev/null || return 1
}
joined() {  # joined <label> <seconds>
    local i
    for i in $(seq 1 "$2"); do
        [ "$(docker exec "${SFX}-$1" tailscale status --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null)" = Running ] && return 0
        sleep 1
    done
    return 1
}
OLD_URL="http://${PKI_A}:8080"
client d1 "${NA}" keys-w "${OLD_URL}" || cannot "could not start client d1"
CLIENT_ROUTE="${PKI_A}/32 via ${PKI_B}" client d2 "${NB}" keys-w "${OLD_URL}" --cap-add NET_ADMIN || cannot "could not start client d2"
for c in d1 d2; do
    [ "$(cat "${D}/${c}/login")" = "https://${PKI_A}:8080" ] && grep -F 'now serves HTTPS (its certificate verifies' "${D}/${c}/prov.log" >/dev/null \
        && ok "${c}: an old stick's http://<pki>:8080 is migrated to https://<pki>:8080 after the certificate verified against the stick's CA" \
        || bad "${c}: login URL '$(cat "${D}/${c}/login")': $(grep -E 'control server|WARNING' "${D}/${c}/prov.log" | tr '\n' ' ')"
done
if joined d1 60 && joined d2 60; then
    ok "both workers join over https with nothing but their stick's CA in the system trust store"
else
    bad "workers did not join: d1=$(docker exec "${SFX}-d1" tailscale status --json 2>/dev/null | jq -r .BackendState) d2=$(docker exec "${SFX}-d2" tailscale status --json 2>/dev/null | jq -r .BackendState) $(docker logs "${SFX}-d2" 2>&1 | grep -iE 'x509|tls|error' | tail -2 | tr '\n' ' ')"
fi
D1_A="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NA}\").IPAddress}}" "${SFX}-d1-ns")"
docker exec "${SFX}-d2-ns" ping -c1 -W2 "${D1_A}" >/dev/null 2>&1 \
    && bad "d2 can reach d1's underlay address ${D1_A}: the networks are not split" \
    || ok "no underlay path d2 -> d1 (${D1_A} unreachable): only a relay can join them"
docker exec "${SFX}-d2-ns" ping -c1 -W2 "${PKI_A}" >/dev/null 2>&1 \
    && ok "d2 reaches the control server's address ${PKI_A} (via its /32 route)" \
    || bad "d2 cannot reach ${PKI_A}: the control path is broken, not split"
dm="$(docker exec "${SFX}-d2" tailscale debug derp-map 2>/dev/null)"
printf '%s' "${dm}" | jq -e --arg h "${PKI_A}" '(.Regions | keys) == ["999"] and .Regions["999"].RegionCode == "hugmesh"
        and .Regions["999"].Nodes[0].HostName == $h and .Regions["999"].Nodes[0].DERPPort == 8080' >/dev/null 2>&1 \
    && ok "DERP map: ONLY region 999 (hugmesh), node ${PKI_A}:8080 — the server_url listener" \
    || bad "DERP map unexpected: $(printf '%s' "${dm}" | jq -c '.Regions | map_values({RegionCode, n: .Nodes[0] | {HostName, DERPPort}})' 2>/dev/null)"
dd="$(docker exec "${SFX}-d2" tailscale debug derp 999 2>&1)"
printf '%s\n' "${dd}" | grep -F 'Successfully established a DERP connection' >/dev/null \
    && ok "tailscale debug derp 999: a DERP connection over TLS to an IP-literal node, verified against the mesh CA" \
    || bad "no DERP connection: $(printf '%s' "${dd}" | grep -iE 'error|tls' | head -2 | tr '\n' ' ')"
ip1="$(docker exec "${SFX}-d1" tailscale ip -4 2>/dev/null)"
pong=""
for i in $(seq 1 30); do
    pong="$(docker exec "${SFX}-d2" tailscale ping -c 1 --timeout 3s "${ip1}" 2>&1)"
    printf '%s\n' "${pong}" | grep -F 'via DERP(hugmesh)' >/dev/null && break
    sleep 1
done
printf '%s\n' "${pong}" | grep -F 'via DERP(hugmesh)' >/dev/null \
    && ok "d2 -> d1: $(printf '%s\n' "${pong}" | grep -F 'pong' | head -1)" \
    || bad "no relayed pong between split peers: $(printf '%s' "${pong}" | tr '\n' ' ')"
docker exec -d "${SFX}-d1-ns" sh -c 'nc -l 7777 > /tmp/got 2>/dev/null'
sleep 1
PAYLOAD="derp-payload-${SFX}"
printf '%s\n' "${PAYLOAD}" | docker exec -i "${SFX}-d2" timeout 10 tailscale nc "${ip1}" 7777 >/dev/null 2>&1
sleep 2
[ "$(docker exec "${SFX}-d1-ns" cat /tmp/got 2>/dev/null)" = "${PAYLOAD}" ] \
    && ok "a TCP payload crossed d2 -> d1 through the relay (tailscale nc)" \
    || bad "the TCP payload did not arrive: '$(docker exec "${SFX}-d1-ns" cat /tmp/got 2>/dev/null)'"

# Capture A ends here: headscale has run, joined three peers and relayed.
docker exec "${PKI}" pkill tcpdump >/dev/null 2>&1; sleep 1
if [ ! -s "${D}/cap/a.err" ] || grep -E 'listening on' "${D}/cap/a.err" >/dev/null; then
    names="$(grep -oE '(A|AAAA)\? [^ ]+' "${D}/cap/a.txt" | awk '{print $2}' | sort -u | tr '\n' ' ')"
    echo "     names headscale looked up: ${names:-none}"
    tq="$(grep -icE 'tailscale\.(com|io)' "${D}/cap/a.txt")"
    [ "${tq}" -eq 0 ] \
        && ok "headscale made ZERO lookups of a Tailscale name (tailscale.com/.io) while it started, joined three peers and relayed" \
        || bad "headscale looked up Tailscale names ${tq} times: $(grep -iE 'tailscale\.(com|io)' "${D}/cap/a.txt" | head -3 | tr '\n' ' ')"
    offnet="$(grep -oE 'Request who-has [0-9.]+' "${D}/cap/a.txt" | awk '{print $3}' | grep -vF -e "${PKI_A%.*}." -e "${PKI_B%.*}.")"
    echo "     ARP requests seen: $(grep -cE 'Request who-has' "${D}/cap/a.txt") (on-mesh only unless listed below)"
    [ -z "${offnet}" ] && ok "...and tried to reach no address off the two meshes (no ARP for an off-net next hop)" \
        || bad "headscale's namespace tried to reach off-net addresses: $(printf '%s' "${offnet}" | sort -u | tr '\n' ' ')"
else
    bad "the capture did not run: $(head -2 "${D}/cap/a.err" | tr '\n' ' ')"
fi
# Capture B: the positive control — the same capture DOES see a lookup and a connection attempt.
docker exec -d "${PKI}" sh -c 'tcpdump -i any -nn -l "udp port 53 or tcp port 53 or arp" > /cap/b.txt 2>/cap/b.err'
sleep 2
docker run --rm --network "container:${PKI}" -v "${D}/resolv.conf:/etc/resolv.conf:ro" --entrypoint sh "${NSI}" \
    -c 'getent hosts controlplane.tailscale.com; nc -z -w 2 198.51.100.7 443' >/dev/null 2>&1
sleep 1
docker exec "${PKI}" pkill tcpdump >/dev/null 2>&1; sleep 1
grep -iE 'controlplane\.tailscale\.com' "${D}/cap/b.txt" >/dev/null && grep -F 'who-has 198.51.100.7' "${D}/cap/b.txt" >/dev/null \
    && ok "positive control: the same capture sees a controlplane.tailscale.com lookup and an off-net connection attempt" \
    || bad "positive control failed — the zero above proves nothing: $(head -4 "${D}/cap/b.txt" | tr '\n' ' ')"

# The control node's own client, in the pki namespace, at the URL keys-provision gives it.
SELF="${SFX}-self"
CONTAINERS+=("${SELF}")
docker run -d --name "${SELF}" --network "container:${PKI}" -v "${D}/pki/ssl:/etc/ssl/certs:ro" \
    -e TS_AUTHKEY="${DKEY}" -e TS_USERSPACE=true -e TS_STATE_DIR=/var/lib/tailscale \
    -e TS_EXTRA_ARGS="--login-server=$(cat "${D}/pki/self-login") --hostname=pki" "${TS_IMAGE}" >/dev/null
joined self 60 && ok "the control node's own client joins at https://127.0.0.1:8080 (the certificate names loopback)" \
    || bad "the control node's own client did not join at $(cat "${D}/pki/self-login"): $(docker logs "${SELF}" 2>&1 | grep -iE 'x509|tls|error' | tail -2 | tr '\n' ' ')"

# NEGATIVE CONTROL: a worker whose stick carries no mesh CA cannot join, and says why.
client d3 "${NA}" keys-noca "${OLD_URL}" || cannot "could not start client d3"
grep -F 'with a certificate this node does NOT trust' "${D}/d3/prov.log" >/dev/null \
    && ok "negative control: a stick without the mesh CA is told so before the join (control_url_tls_migrate)" \
    || bad "negative control: no untrusted-certificate warning: $(grep -E 'control server|WARNING' "${D}/d3/prov.log" | tr '\n' ' ')"
if joined d3 25; then
    bad "negative control: a worker WITHOUT the mesh CA joined — the trust checks above prove nothing"
else
    docker logs "${SFX}-d3" 2>&1 | grep -iE 'x509|certificate signed by unknown authority' >/dev/null \
        && ok "negative control: without the mesh CA the worker does NOT join (x509: unknown authority)" \
        || ok "negative control: without the mesh CA the worker does NOT join"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
