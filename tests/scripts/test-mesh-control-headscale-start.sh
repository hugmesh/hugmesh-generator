#!/usr/bin/env bash
# test-mesh-control-headscale-start.sh — the PINNED headscale STARTS with the config a
# Tor-mode pki renders, and a worker joins through the shipped relay (mesh control over
# Tor, OPT-IN; docs/MESH-CONTROL-OVER-TOR.md). No stubbed resolver, no hand-edited
# config: the pki stick comes from scripts/gen-provision-keys.sh with NO
# --mesh-control-name (the default every front end produces), and keys-provision's own
# functions render /etc/headscale/config.yaml from it.
#
# WHY. Round 1 stamped hs.<superdomain> as the default control name, which put
# headscale's server_url INSIDE its MagicDNS base_domain; headscale 0.23.0 then refuses
# to start ("server_url cannot contain the base_domain"), so no worker could ever join.
# The offline guard (test-mesh-control-onion.sh) compared strings and stayed green.
#
#   A. KEYS: the pki stick's provision.json carries the DERIVED name
#      hs.hugmesh-control.internal and magic_dns_domain hugmesh.internal.
#   B. keys-provision renders the live config in the pki's network namespace:
#      server_url https://hs.hugmesh-control.internal:7443 (asserted BEFORE headscale
#      starts — a config that fell back to the LAN address would start on any tree),
#      base_domain the stick's, headscale serving TLS itself behind the 7443 passthrough
#      (tls_cert_path set, the certificate names the control name), no oidc block.
#   C. the pinned headscale serves on that config; through the SHIPPED relay's local
#      forward (127.77.0.1:7443 -> 127.0.0.1:8080) a TLS client that trusts only the
#      mesh CA gets /key with the control name as SNI.
#   D. NEGATIVE CONTROL: the same config with round 1's server_url host
#      (hs.hugmesh.internal) exits "server_url cannot contain the base_domain" — this
#      proves the suite would see the blocker. Then cells where keys-provision's own
#      clash predicate (mesh_control_name_clash) must give headscale's verdict.
#   E. a worker (pinned tailscale, TS_FORCE_NOISE_443 + TS_NO_LOGS_NO_SUPPORT, no proxy
#      variable) whose relay.conf keys-provision wrote from a worker stick joins over
#      the LAN path at https://hs.hugmesh-control.internal:7443 and reaches the embedded
#      DERP region through the same name and port.
#
# Throwaway containers on private --internal networks (no route out, no published
# ports), all removed on exit. EXIT 0 all passed; 1 an assertion failed; 2 could not run
# (no docker daemon, an image) — a job FAILURE in CI, never a skip.
# MCHS_ROOT=<tree> runs the suite against another tree (fail-before measurements).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="${MCHS_ROOT:-${REPO}}"
PIN_SRC="${ROOT}/build-x86-host-stage4.sh"
PROV="${ROOT}/specs/etc/keys-provision/provision.sh"
RELAY="${ROOT}/specs/usr/sbin/hugmesh-mesh-control-relay"
GPK="${ROOT}/scripts/gen-provision-keys.sh"
NSI="${MCHS_NETSHOOT_IMAGE:-nicolaka/netshoot@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70}"
ONION="abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion"
NAME="hs.hugmesh-control.internal"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
cannot() { echo "CANNOT RUN: $*"; exit 2; }

for t in docker jq openssl awk python3 keytool ssh-keygen; do command -v "$t" >/dev/null 2>&1 || cannot "$t is required"; done
docker info >/dev/null 2>&1 || cannot "no usable docker daemon"
HS_VER="$(sed -n 's/^HEADSCALE_VERSION="\([0-9.]*\)".*/\1/p' "${PIN_SRC}" | head -1)"
TS_VER="$(sed -n 's/^TAILSCALE_VERSION="\([0-9.]*\)".*/\1/p' "${PIN_SRC}" | head -1)"
[ -n "${HS_VER}" ] && [ -n "${TS_VER}" ] || cannot "could not read the HEADSCALE_VERSION / TAILSCALE_VERSION pins from ${PIN_SRC}"
HS_IMAGE="headscale/headscale:${HS_VER}"
TS_IMAGE="tailscale/tailscale:v${TS_VER}"
echo "== pinned: ${HS_IMAGE} + ${TS_IMAGE} =="
for img in "${HS_IMAGE}" "${TS_IMAGE}" "${NSI}"; do
    docker image inspect "${img}" >/dev/null 2>&1 || docker pull -q "${img}" >/dev/null 2>&1 || cannot "could not pull ${img}"
done

SFX="mchs-$$-${RANDOM}"
NET="${SFX}-lan"
WORK="$(mktemp -d)"; chmod 0755 "${WORK}"
CONTAINERS=()
cleanup() {
    local c
    if [ "${MCHS_KEEP:-0}" = 1 ]; then echo "MCHS_KEEP=1: left ${CONTAINERS[*]} and ${WORK}"; return; fi
    for c in "${CONTAINERS[@]}"; do docker rm -fv "${c}" >/dev/null 2>&1; done
    docker network rm "${NET}" >/dev/null 2>&1
    # headscale and the provisioning container wrote as root; remove it the same way.
    docker run --rm -v "${WORK}:/w" --entrypoint /bin/sh "${TS_IMAGE}" -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1
    rm -rf "${WORK}" 2>/dev/null
}
trap cleanup EXIT
docker network create --internal "${NET}" >/dev/null || cannot "could not create the --internal network"

# hs_wait <container> <seconds> -> "serving" | "ftl:<message>" | "timeout"
hs_wait() {
    local c="$1" lim="$2" i out
    for ((i = 0; i < lim; i++)); do
        out="$(docker logs "${c}" 2>&1)"
        if printf '%s\n' "${out}" | grep -E 'listening and serving HTTP' >/dev/null; then echo serving; return 0; fi
        if printf '%s\n' "${out}" | grep -E ' FTL |Error initializing' >/dev/null; then
            echo "ftl:$(printf '%s\n' "${out}" | grep -E ' FTL |Error initializing' | head -1 | sed 's/.*error="//' | cut -c1-160)"; return 0
        fi
        [ "$(docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null)" = true ] || { sleep 1; continue; }
        sleep 1
    done
    echo timeout
}

# ── A. KEYS ──────────────────────────────────────────────────────────────────
echo "-- A. gen-provision-keys.sh: a Tor-mode pki stick with the DEFAULT control name --"
D="${WORK}/d"; mkdir -p "${D}"
OD="${D}/onion"; mkdir -p -m 0700 "${OD}"; printf '%s\n' "${ONION}" > "${OD}/hostname"
head -c 96 /dev/urandom > "${OD}/hs_ed25519_secret_key"; head -c 64 /dev/urandom > "${OD}/hs_ed25519_public_key"
NONINTERACTIVE=1 BRAND=hugmesh HEADSCALE_PUBLIC_DERP= bash "${GPK}" -r pki -o "${D}/keys-pki" --random --no-device-ssh \
    --pki-ip 192.168.77.10 --mesh-control-transport lan+onion --mesh-control-onion-dir "${OD}" > "${D}/gpk-pki.log" 2>&1 \
    || cannot "gen-provision-keys.sh (pki) failed: $(grep -a ERROR "${D}/gpk-pki.log" | head -2 | tr '\n' ' ')"
NONINTERACTIVE=1 BRAND=hugmesh bash "${GPK}" -r host -o "${D}/keys-w" --random --no-device-ssh --ca-cert "${D}/keys-pki/certs/cluster-ca.crt" \
    --pki-ip 192.168.77.10 --mesh-control-transport lan+onion --mesh-control-onion-dir "${OD}" > "${D}/gpk-w.log" 2>&1 \
    || cannot "gen-provision-keys.sh (worker) failed: $(grep -a ERROR "${D}/gpk-w.log" | head -2 | tr '\n' ' ')"
got="$(jq -r '[.mesh.control_transport, .mesh.control_name, .mesh.magic_dns_domain] | join(" ")' "${D}/keys-pki/provision.json")"
[ "${got}" = "lan+onion ${NAME} hugmesh.internal" ] \
    && ok "the pki stick: transport lan+onion, control name ${NAME} (derived), MagicDNS domain hugmesh.internal" \
    || bad "the pki stick says '${got}', expected 'lan+onion ${NAME} hugmesh.internal'"
grep -E '^\s*base_domain:' "${D}/keys-pki/headscale/config.yaml" >/dev/null || bad "the pki stick's headscale config has no base_domain line"
grep -E '^oidc:' "${D}/keys-pki/headscale/config.yaml" >/dev/null \
    && ok "the stick's headscale config carries an oidc block (keys-provision must remove it in a Tor mode)" \
    || bad "the stick's headscale config has no oidc block — the OIDC-off check below would be vacuous"

# ── B. keys-provision renders the live config ────────────────────────────────
echo "-- B. keys-provision (its own functions) renders /etc/headscale/config.yaml in the pki's namespace --"
{
    echo 'log()  { echo "[keys-provision] $*"; }; warn() { echo "[keys-provision] WARNING: $*"; }'
    echo 'have() { command -v "$1" >/dev/null 2>&1; }'
    echo 'jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }; jqe() { jq -e "$1" "${MANIFEST}" >/dev/null 2>&1; }'
    # The mesh-control resolvers (top of provision.sh), verbatim.
    awk '/^# ── Mesh control over Tor: a stable control name/{f=1} f; f && /^mesh_control_url\(\) \{/{exit}' "${PROV}"
    for fn in resolve_lan_ip resolve_endpoint resolve_control_endpoint node_is_public ipv4_literal resolve_pki_lan_ip \
              resolve_magic_dns_domain provision_certs; do
        sed -n "/^${fn}() {/,/^}/p" "${PROV}"
    done
    sed -n '/^HEADSCALE_CONFIG=/p' "${PROV}"
    # headscale's config stage + the mesh-control node side, verbatim.
    awk '/^# ── headscale DERP relay: offline-first/{f=1} /^provision_headscale\(\) \{/{f=0} f' "${PROV}"
} > "${D}/prov-lib.sh"
for fn in resolve_mesh_control_name mesh_control_active provision_headscale_config provision_headscale_tls \
          provision_mesh_control mesh_control_oidc_off provision_certs; do
    grep -E "^${fn}\(\) \{" "${D}/prov-lib.sh" >/dev/null || bad "${fn} not found in ${PROV}"
done
mkdir -p "${D}/bin"; printf '#!/bin/sh\nexit 0\n' > "${D}/bin/tor"; chmod +x "${D}/bin/tor"
for c in rc-update rc-service hugmesh-tor-reconcile; do printf '#!/bin/sh\nexit 0\n' > "${D}/bin/${c}"; chmod +x "${D}/bin/${c}"; done
cat > "${D}/prov-pki.sh" <<'EOF'
# The pki node: provision_certs, the KEYS config copy, the config stage, OIDC off, and the
# mesh-control step — the order provision_headscale and main use. `tor` is a presence
# stub (only `have tor` reads it: this suite starts no Tor); socat is netshoot's own.
set -uo pipefail
export PATH="/w/bin:${PATH}"
. /w/prov-lib.sh
BASE=/w/keys-pki; MANIFEST="${BASE}/provision.json"
HEADSCALE_PUBLIC_DERP_MARKER=/etc/hugmesh/headscale-public-derp
HEADSCALE_DERP_STUN_MARKER=/etc/hugmesh/headscale-derp-stun
MESH_CONTROL_DIR=/w/pki/mc MESH_CONTROL_TOR_MARKER=/w/pki/tor-marker MESH_CONTROL_TOR_ONLY=/w/pki/tor-only
MESH_CONTROL_HS_DIR=/w/pki/hs-dir MESH_CONTROL_TS_CONF=/w/pki/conf.d-tailscaled MESH_CONTROL_HOSTS=/w/pki/hosts
: > /w/pki/hosts
provision_mesh_control
provision_certs
cp -f "${BASE}/headscale/config.yaml" /etc/headscale/config.yaml
provision_headscale_config /etc/headscale/config.yaml
mesh_control_oidc_off /etc/headscale/config.yaml
# relay.conf is root-only (0600): hand the suite a readable copy and its mode.
cp /w/pki/mc/relay.conf /w/pki/relay.conf.seen && chmod 0644 /w/pki/relay.conf.seen
stat -c %a /w/pki/mc/relay.conf > /w/pki/relay.conf.mode
EOF
PKI="${SFX}-pki"; CONTAINERS+=("${PKI}")
mkdir -p "${D}/pki/etc" "${D}/pki/lib" "${D}/pki/run" "${D}/pki/hm" "${D}/pki/ssl"
printf '%s\n' '{"acls":[{"action":"accept","src":["*"],"dst":["*:*"]}]}' > "${D}/pki/etc/policy.hujson"
# What provision_headscale copies from a stick that carries the Casdoor app secret: a
# config that still has its oidc block then starts (as on a real pki) instead of
# exiting on a missing client_secret_path, so a fail-before shows the real refusal.
echo "mchs-oidc-secret" > "${D}/pki/lib/oidc_client_secret"
docker run -d --name "${PKI}" --network "${NET}" --entrypoint sleep "${NSI}" infinity >/dev/null || cannot "could not start the pki namespace"
PKI_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NET}\").IPAddress}}" "${PKI}")"
# The sticks say 192.168.77.10 for the pki; point both at the address docker gave it.
for s in keys-pki keys-w; do
    jq --arg ip "${PKI_IP}" '.mesh.pki_lan_ip = $ip | (.nodes[] | select(.role == "pki") | .ip) = $ip' "${D}/${s}/provision.json" > "${D}/${s}/p.tmp" \
        && mv "${D}/${s}/p.tmp" "${D}/${s}/provision.json"
done
docker run --rm --network "container:${PKI}" -v "${D}:/w" -v "${D}/pki/etc:/etc/headscale" -v "${D}/pki/lib:/var/lib/headscale" \
    -v "${D}/pki/hm:/etc/hugmesh" -v "${D}/pki/ssl:/etc/ssl/certs" --entrypoint bash "${NSI}" /w/prov-pki.sh > "${D}/prov-pki.log" 2>&1
grep -E 'server_url|TLS|mesh control|OIDC|WARNING' "${D}/prov-pki.log" | sed 's/^/     /' | head -12
CFG="${D}/pki/etc/config.yaml"
SU="$(sed -n 's/^server_url:[[:space:]]*//p' "${CFG}" | head -1 | tr -d "\"'")"
BD="$(sed -n 's/^[[:space:]]*base_domain:[[:space:]]*//p' "${CFG}" | head -1 | tr -d "\"'")"
[ "${SU}" = "https://${NAME}:7443" ] && ok "server_url is the control name on the dial port: ${SU}" \
    || bad "server_url is '${SU}', expected https://${NAME}:7443 (headscale would start on ANY server_url that left the base domain — this is what makes the start below mean something)"
[ "${BD}" = "hugmesh.internal" ] && ok "base_domain is the stick's MagicDNS domain: ${BD}" || bad "base_domain is '${BD}', expected hugmesh.internal"
grep -E '^tls_cert_path: "/var/lib/headscale/tls.crt"$' "${CFG}" >/dev/null \
    && ok "headscale serves TLS itself behind the 7443 passthrough (tls_cert_path set)" \
    || bad "TLS is off: $(grep '^tls_' "${CFG}" | tr '\n' ' ') — the 7443 port was read as a TLS front"
openssl x509 -in "${D}/pki/lib/tls.crt" -noout -ext subjectAltName 2>/dev/null | grep -F "DNS:${NAME}" >/dev/null \
    && ok "the serving certificate names ${NAME}" || bad "the serving certificate does not name ${NAME}"
grep -E '^oidc:' "${CFG}" >/dev/null && bad "the live config still has an oidc block in a Tor mode" \
    || ok "the live config has no oidc block (first sign-in = pre-auth keys)"
expect_conf() { [ "$(grep -v '^#' "$2" 2>/dev/null | paste -sd'|')" = "$3" ] && ok "$1" || bad "$1: $(grep -v '^#' "$2" 2>/dev/null | paste -sd'|')"; }
expect_conf "the pki's relay.conf: the local forward 127.77.0.1:7443 -> 127.0.0.1:8080" "${D}/pki/relay.conf.seen" \
    "TRANSPORT=local|LISTEN=127.77.0.1:7443|LAN=127.0.0.1:8080"
[ "$(cat "${D}/pki/relay.conf.mode" 2>/dev/null)" = 600 ] && ok "the pki's relay.conf is root-only (0600)" || bad "the pki's relay.conf mode is '$(cat "${D}/pki/relay.conf.mode" 2>/dev/null)'"

# ── C. the pinned headscale serves; TLS through the shipped relay's forward ──
echo "-- C. ${HS_IMAGE} on the rendered config --"
HS="${SFX}-hs"; CONTAINERS+=("${HS}")
docker run -d --name "${HS}" --network "container:${PKI}" -v "${D}/pki/etc:/etc/headscale" -v "${D}/pki/lib:/var/lib/headscale" \
    -v "${D}/pki/run:/run/headscale" "${HS_IMAGE}" serve >/dev/null || cannot "could not start headscale"
v="$(hs_wait "${HS}" 120)"
[ "${v}" = serving ] && ok "headscale ${HS_VER} STARTS and serves on the Tor-mode config" \
    || bad "headscale did not start on the Tor-mode config: ${v}"
RL="${SFX}-relay"; CONTAINERS+=("${RL}")
docker run -d --name "${RL}" --network "container:${PKI}" -v "${RELAY}:/usr/sbin/hugmesh-mesh-control-relay:ro" -v "${D}/pki/mc:/mc:ro" \
    -e HUGMESH_MESH_CONTROL_CONF=/mc/relay.conf -e HUGMESH_MESH_CONTROL_STATE=/tmp/mc --entrypoint bash "${NSI}" \
    /usr/sbin/hugmesh-mesh-control-relay listen >/dev/null || bad "the relay did not start"
# The client trusts ONLY the stick's mesh CA, and sends the control name as SNI.
docker cp "${D}/keys-pki/certs/cluster-ca.crt" "${PKI}:/tmp/ca.crt" >/dev/null 2>&1 || bad "could not hand the mesh CA to the pki namespace"
code=""
for i in $(seq 1 30); do
    code="$(docker exec "${PKI}" curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --cacert /tmp/ca.crt \
        --resolve "${NAME}:7443:127.77.0.1" "https://${NAME}:7443/key?v=109" 2>/dev/null)"
    [ "${code}" = 200 ] && break; sleep 1
done
[ "${code}" = 200 ] && ok "https://${NAME}:7443/key answers 200 through the relay's local forward, verified against the mesh CA only" \
    || bad "https://${NAME}:7443/key through the local forward: '${code}' (relay: $(docker logs "${RL}" 2>&1 | tail -1))"

# ── D. negative control + headscale's verdict == keys-provision's predicate ──
echo "-- D. negative control and clash-predicate agreement (pinned headscale decides) --"
. <(awk '/^mesh_control_name_clash\(\) \{/{f=1} f; f && /^}/{exit}' "${PROV}")
declare -F mesh_control_name_clash >/dev/null || { mesh_control_name_clash() { return 1; }; bad "provision.sh has no mesh_control_name_clash"; }
cells=("hs.hugmesh.internal hugmesh.internal" "hs.hugmesh.internal mesh.internal" "hs.acme-control.example acme.example" "ab.cd internal")
idx=0
for c in "${cells[@]}"; do
    set -- ${c}; idx=$((idx + 1))
    cd_="${D}/cell${idx}"; mkdir -p "${cd_}/etc" "${cd_}/lib" "${cd_}/run"
    cp "${D}/pki/etc/policy.hujson" "${cd_}/etc/"
    # The rendered config with ONLY server_url's host and base_domain changed; TLS off so
    # the cell needs no certificate (headscale's check reads server_url, not TLS).
    # No oidc block either, whatever the tree under test left in it: the cell decides
    # one thing, server_url against base_domain.
    sed -e "s|^server_url:.*|server_url: https://$1:7443|" -e "s|^\([[:space:]]*\)base_domain:.*|\1base_domain: $2|" \
        -e 's|^tls_cert_path:.*|tls_cert_path: ""|' -e 's|^tls_key_path:.*|tls_key_path: ""|' "${CFG}" \
        | awk 'skip && /^[^[:space:]#]/ {skip=0} /^oidc:/ {skip=1; next} !skip' > "${cd_}/etc/config.yaml"
    CONTAINERS+=("${SFX}-cell${idx}")
    docker run -d --name "${SFX}-cell${idx}" --network none -v "${cd_}/etc:/etc/headscale" -v "${cd_}/lib:/var/lib/headscale" \
        -v "${cd_}/run:/run/headscale" "${HS_IMAGE}" serve >/dev/null || bad "cell $1/$2 did not start a container"
done
idx=0
for c in "${cells[@]}"; do
    set -- ${c}; idx=$((idx + 1))
    v="$(hs_wait "${SFX}-cell${idx}" 120)"
    if mesh_control_name_clash "$1" 7443 "$2"; then pred=refused; else pred=serving; fi
    case "${v}" in serving) hv=serving ;; ftl:*"server_url cannot contain the base_domain"*) hv=refused ;; *) hv="other(${v})" ;; esac
    if [ "${idx}" = 1 ]; then
        [ "${hv}" = refused ] && ok "NEGATIVE CONTROL: round 1's pairing (https://$1:7443 under $2) -> headscale refuses: ${v#ftl:}" \
            || bad "NEGATIVE CONTROL did not bite: round 1's pairing gave '${v}' — this suite could not see the blocker"
    fi
    [ "${hv}" = "${pred}" ] && ok "verdict agrees for https://$1:7443 under $2: headscale ${hv}, keys-provision ${pred}" \
        || bad "verdict disagrees for https://$1:7443 under $2: headscale ${hv}, keys-provision ${pred}"
done

# ── E. a worker joins through the shipped relay on the LAN path ──────────────
echo "-- E. a worker: keys-provision's relay.conf, the shipped relay + keeper, ${TS_IMAGE} --"
docker exec "${HS}" headscale users create mchs >/dev/null 2>&1
KEY="$(docker exec "${HS}" headscale preauthkeys create -u mchs --reusable -e 1h 2>/dev/null | tail -1)"
[ -n "${KEY}" ] || bad "headscale minted no pre-auth key"
cat > "${D}/prov-w.sh" <<'EOF'
set -uo pipefail
export PATH="/w/bin:${PATH}"
. /w/prov-lib.sh
BASE=/w/keys-w; MANIFEST="${BASE}/provision.json"
MESH_CONTROL_DIR=/w/w/mc MESH_CONTROL_TOR_MARKER=/w/w/tor-marker MESH_CONTROL_TOR_ONLY=/w/w/tor-only
MESH_CONTROL_HS_DIR=/w/w/hs-dir MESH_CONTROL_TS_CONF=/w/w/conf.d-tailscaled MESH_CONTROL_HOSTS=/w/w/hosts
: > /w/w/hosts
provision_mesh_control
provision_certs
resolve_control_endpoint > /w/w/login
cp /w/w/mc/relay.conf /w/w/relay.conf.seen && chmod 0644 /w/w/relay.conf.seen
stat -c %a /w/w/mc/relay.conf > /w/w/relay.conf.mode
EOF
mkdir -p "${D}/w" "${D}/w-ssl"
docker run --rm --network none -v "${D}:/w" -v "${D}/w-ssl:/etc/ssl/certs" --entrypoint bash "${NSI}" /w/prov-w.sh > "${D}/prov-w.log" 2>&1
expect_conf "the worker's relay.conf (7443 -> the pki's 8080 on the LAN, else the onion)" "${D}/w/relay.conf.seen" \
    "TRANSPORT=lan+onion|LISTEN=127.77.0.1:7443|LAN=${PKI_IP}:8080|ONION=${ONION}:7443"
[ "$(cat "${D}/w/login" 2>/dev/null)" = "https://${NAME}:7443" ] && ok "the worker's control endpoint is https://${NAME}:7443" \
    || bad "the worker's control endpoint is '$(cat "${D}/w/login" 2>/dev/null)'"
grep -x 'export TS_NO_LOGS_NO_SUPPORT=true' "${D}/w/conf.d-tailscaled" >/dev/null && grep -x 'export TS_FORCE_NOISE_443=true' "${D}/w/conf.d-tailscaled" >/dev/null \
    && ok "the worker's tailscaled env block: TS_FORCE_NOISE_443 + TS_NO_LOGS_NO_SUPPORT" || bad "tailscaled env block: $(tr '\n' '|' < "${D}/w/conf.d-tailscaled" 2>/dev/null)"
# tailscaled with the env block keys-provision wrote (no proxy variable), the mesh CA
# trusted, the control name in /etc/hosts at 127.77.0.1 — what a node has. The relay and
# its keeper run in tailscaled's network namespace, as on the node.
TSENV=(); while IFS= read -r l; do [[ "${l}" =~ ^export\ ([A-Z0-9_]+=.*)$ ]] && TSENV+=(-e "${BASH_REMATCH[1]}"); done < "${D}/w/conf.d-tailscaled"
cat "${D}/keys-w/certs/cluster-ca.crt" > "${D}/bundle.crt"
docker run --rm --entrypoint cat "${TS_IMAGE}" /etc/ssl/certs/ca-certificates.crt >> "${D}/bundle.crt" 2>/dev/null
TSN="${SFX}-w"; CONTAINERS+=("${TSN}")
docker run -d --name "${TSN}" --network "${NET}" --add-host "${NAME}:127.77.0.1" "${TSENV[@]}" \
    -v "${D}/bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro" \
    --entrypoint tailscaled "${TS_IMAGE}" --tun=userspace-networking --statedir=/var/lib/tailscale >/dev/null || cannot "tailscaled did not start"
WN="${TSN}"
# The relay and the keeper share one state directory (/run/hugmesh/mesh-control on a
# node): the keeper's lan-ok is what sends the relay's connections to the LAN.
mkdir -p "${D}/w-state"; chmod 0777 "${D}/w-state"
for sub in listen keeper; do
    CONTAINERS+=("${WN}-${sub}")
    docker run -d --name "${WN}-${sub}" --network "container:${WN}" -v "${RELAY}:/usr/sbin/hugmesh-mesh-control-relay:ro" -v "${D}/w/mc:/mc:ro" \
        -v "${D}/w-state:/state" -e HUGMESH_MESH_CONTROL_CONF=/mc/relay.conf -e HUGMESH_MESH_CONTROL_STATE=/state \
        -e HUGMESH_MESH_CONTROL_KEEPER_INTERVAL=5 --entrypoint bash "${NSI}" /usr/sbin/hugmesh-mesh-control-relay "${sub}" >/dev/null
done
for i in $(seq 1 60); do
    docker exec "${WN}-keeper" bash /usr/sbin/hugmesh-mesh-control-relay status 2>/dev/null | grep -F 'path now:  LAN' >/dev/null && break; sleep 1
done
docker exec "${WN}-keeper" bash /usr/sbin/hugmesh-mesh-control-relay status 2>/dev/null | grep -F 'path now:  LAN' >/dev/null \
    && ok "the worker's keeper found the pki on the LAN (path now: LAN)" || bad "the keeper never saw the LAN: $(docker logs "${WN}-keeper" 2>&1 | tail -2 | tr '\n' ' ')"
t0="$(date +%s)"
if docker exec "${TSN}" tailscale up --login-server="https://${NAME}:7443" --authkey="${KEY}" --hostname=mchs-w --timeout=120s >/dev/null 2>"${D}/up.err"; then
    ok "the worker joined at https://${NAME}:7443 through its relay in $(( $(date +%s) - t0 )) s"
else bad "the worker did not join: $(tail -2 "${D}/up.err" | tr '\n' ' ')"; fi
for i in $(seq 1 45); do docker logs "${TSN}" 2>&1 | grep -E 'derp-999 connected|derp-999.*connected' >/dev/null && break; sleep 1; done
docker logs "${TSN}" 2>&1 | grep -E 'derp-999 connected|derp-999.*connected' >/dev/null \
    && ok "the worker reached the embedded DERP region (derp-999) on the same name and port" \
    || bad "no 'derp-999 connected' in tailscaled's log: $(docker logs "${TSN}" 2>&1 | grep -i derp | tail -2 | tr '\n' ' ')"
docker logs "${TSN}" 2>&1 | grep -E 'log\.tailscale\.io|bootstrapDNS' >/dev/null \
    && bad "tailscaled tried log.tailscale.io / bootstrap DNS despite TS_NO_LOGS_NO_SUPPORT" \
    || ok "tailscaled made no log-upload or bootstrap-DNS attempt"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
