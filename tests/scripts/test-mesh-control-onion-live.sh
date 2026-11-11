#!/usr/bin/env bash
# test-mesh-control-onion-live.sh — OPT-IN live proof of mesh control over Tor on the
# REAL Tor network (docs/MESH-CONTROL-OVER-TOR.md). NOT default CI: it publishes one
# THROWAWAY onion (a test headscale with no real users) for a few minutes, mints its
# key with the repo's own gen-provision-keys.sh, and deletes every key afterwards.
#
# What runs is what ships: the control onion key and stick stamping come from
# scripts/gen-provision-keys.sh --mesh-control-onion-mint; every client's relay and
# keeper is specs/usr/sbin/hugmesh-mesh-control-relay with the relay.conf
# keys-provision writes; headscale (the pinned 0.23.0) serves TLS on its own 8080
# listener with server_url https://hs.mesh.internal:8080 — the node design. tailscaled
# (the pinned 1.78.1) carries TS_FORCE_NOISE_443=true and no proxy variable.
#
# CELLS (each prints a measured time):
#   1 off-LAN   lan+onion, LAN address configured but unreachable -> joins over the onion
#   2 LAN       lan+onion on the LAN -> joins over the LAN; a second LAN client; the two
#               go DIRECT on the LAN under the relay
#   3 switch    the LAN client loses the LAN -> control back over the onion (timed);
#               the LAN returns -> back on the LAN (timed)
#   4 keeper    the off-LAN client's Tor loses the internet for 75 s -> the keeper's
#               failures reach NEWNYM_AFTER and it sends NEWNYM; the internet returns ->
#               the onion path recovers (timed). This exercises the keeper's NEWNYM
#               PATH; it cannot summon the measured stuck-rendezvous stall on demand.
#
# Exit 0 = every cell passed; 1 = a cell failed; 2 = cannot run here (docker, the
# pinned images, a Tor image build, or no internet for Tor). HS_ONION_KEEP=1 leaves the
# rig up for a look (keys are still deleted).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HS_IMG="${HS_ONION_HEADSCALE_IMAGE:-headscale/headscale:0.23.0}"
TS_IMG="${HS_ONION_TAILSCALE_IMAGE:-tailscale/tailscale:v1.78.1}"
TOR_IMG="hs-onion-live-tor:local"
PROJ="hs-onion-live"
NAME="hs.mesh.internal"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
skip() { echo "SKIP (exit 2): $*"; exit 2; }
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || skip "no docker"
for i in "${HS_IMG}" "${TS_IMG}"; do docker image inspect "${i}" >/dev/null 2>&1 || docker pull -q "${i}" >/dev/null 2>&1 || skip "image ${i}"; done
W="$(mktemp -d)"; chmod 0755 "${W}"
cleanup() {
    if [ "${HS_ONION_KEEP:-0}" != 1 ]; then
        docker ps -aq --filter "name=^${PROJ}-" | xargs -r docker rm -f >/dev/null 2>&1
        for n in egress srv lan c1 c2 c3; do docker network rm "${PROJ}-${n}" >/dev/null 2>&1; done
    fi
    # keys and TLS are written by containers as other uids: delete through one
    docker run --rm -v "${W}:/w" alpine:3.20 sh -c 'rm -rf /w/*' >/dev/null 2>&1
    rm -rf "${W}"
}
trap cleanup EXIT

# ── images, networks ──────────────────────────────────────────────────────────
mkdir -p "${W}/img"; printf 'FROM alpine:3.20\nRUN apk add --no-cache tor socat bash coreutils\n' > "${W}/img/Dockerfile"
docker build -q -t "${TOR_IMG}" "${W}/img" >/dev/null 2>&1 || skip "could not build the Tor image (no internet?)"
docker network create -o com.docker.network.driver.mtu=1380 "${PROJ}-egress" >/dev/null || skip "network"
for n in srv c1 c2 c3; do docker network create --internal "${PROJ}-${n}" >/dev/null || skip "network ${n}"; done
docker network create --internal --subnet 10.255.0.0/24 "${PROJ}-lan" >/dev/null || skip "network lan (10.255.0.0/24 taken?)"

# ── KEYS: the repo's own mint + stamping ─────────────────────────────────────
OD="${W}/onion"
if command -v tor >/dev/null 2>&1; then tor_env=(); else tor_env=(MESH_CONTROL_TOR_IMAGE="${TOR_IMG}"); fi
env "${tor_env[@]}" NONINTERACTIVE=1 BRAND=hugmesh bash "${REPO}/scripts/gen-provision-keys.sh" --role host --out "${W}/keys-host" \
    --random --pki-ip 10.255.0.10 --mesh-control-transport lan+onion --mesh-control-name "${NAME}" \
    --mesh-control-onion-dir "${OD}" --mesh-control-onion-mint > "${W}/gk.log" 2>&1 \
    || { cat "${W}/gk.log" >&2; skip "gen-provision-keys could not mint (needs tor here or docker)"; }
ONION="$(jq -r .mesh.control_onion "${W}/keys-host/provision.json")"
[[ "${ONION}" =~ ^[a-z2-7]{56}\.onion$ ]] && ok "gen-provision-keys minted and stamped a v3 control onion" || { bad "no onion stamped"; exit 1; }

# ── the pki side: headscale (TLS itself) + the service Tor ───────────────────
mkdir -p "${W}/tls" "${W}/hs/etc" "${W}/hs/lib" "${W}/hs/run" "${W}/tor-srv"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=throwaway mesh CA" \
    -keyout "${W}/tls/ca.key" -out "${W}/tls/ca.crt" >/dev/null 2>&1
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=${NAME}" -keyout "${W}/hs/lib/tls.key" -out "${W}/tls/hs.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "${NAME}" > "${W}/tls/ext"
openssl x509 -req -in "${W}/tls/hs.csr" -CA "${W}/tls/ca.crt" -CAkey "${W}/tls/ca.key" -CAcreateserial -days 1 \
    -extfile "${W}/tls/ext" -out "${W}/hs/lib/tls.crt" >/dev/null 2>&1
docker run --rm --entrypoint cat "${TS_IMG}" /etc/ssl/certs/ca-certificates.crt > "${W}/tls/bundle.crt" && cat "${W}/tls/ca.crt" >> "${W}/tls/bundle.crt"
python3 - "${REPO}/specs/etc/headscale/config.yaml" "${W}/hs/etc/config.yaml" "${NAME}" <<'PY'
import re, sys, yaml
src, dst, name = sys.argv[1:4]
c = yaml.safe_load(open(src))
c["server_url"] = "https://%s:8080" % name
c["listen_addr"] = "0.0.0.0:8080"
c["tls_cert_path"] = "/var/lib/headscale/tls.crt"
c["tls_key_path"] = "/var/lib/headscale/tls.key"
c.pop("oidc", None)
c["policy"] = {"mode": "file", "path": "/etc/headscale/policy.hujson"}
c.setdefault("derp", {}).setdefault("server", {})["private_key_path"] = "/var/lib/headscale/derp_server_private.key"
c["derp"]["server"]["stun_listen_addr"] = "0.0.0.0:3478"
c["database"] = {"type": "sqlite", "sqlite": {"path": "/var/lib/headscale/db.sqlite"}}
c["noise"] = {"private_key_path": "/var/lib/headscale/noise_private.key"}
c["unix_socket"] = "/run/headscale/headscale.sock"
yaml.safe_dump(c, open(dst, "w"))
PY
echo '{"acls":[{"action":"accept","src":["*"],"dst":["*:*"]}]}' > "${W}/hs/etc/policy.hujson"
docker run -d --name "${PROJ}-hs" --network "${PROJ}-srv" -v "${W}/hs/etc:/etc/headscale" -v "${W}/hs/lib:/var/lib/headscale" \
    -v "${W}/hs/run:/run/headscale" "${HS_IMG}" serve >/dev/null || { bad "headscale did not start"; exit 1; }
docker network connect --ip 10.255.0.10 "${PROJ}-lan" "${PROJ}-hs" || { bad "headscale not on the LAN"; exit 1; }
HS_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${PROJ}-srv\").IPAddress}}" "${PROJ}-hs")"
mkdir -p "${W}/tor-srv/hs"; cp "${OD}/hostname" "${OD}/hs_ed25519_secret_key" "${OD}/hs_ed25519_public_key" "${W}/tor-srv/hs/"
printf 'DataDirectory /var/lib/tor/data\nLog notice stdout\nSocksPort 0\nHiddenServiceDir /var/lib/tor/hs\nHiddenServicePort 8080 %s:8080\n' "${HS_IP}" > "${W}/tor-srv/torrc"
docker run -d --name "${PROJ}-tor-srv" --network "${PROJ}-egress" -v "${W}/tor-srv:/var/lib/tor" "${TOR_IMG}" \
    sh -c 'chmod 700 /var/lib/tor/hs; exec tor -f /var/lib/tor/torrc' >/dev/null
docker network connect "${PROJ}-srv" "${PROJ}-tor-srv"
sleep 8
docker exec "${PROJ}-hs" headscale users create live >/dev/null 2>&1
KEY="$(docker exec "${PROJ}-hs" headscale preauthkeys create -u live --reusable -e 2h 2>/dev/null | tail -1)"
[ -n "${KEY}" ] && ok "headscale serves TLS on 8080 and minted a pre-auth key" || { bad "no pre-auth key"; exit 1; }
for i in $(seq 1 90); do docker logs "${PROJ}-tor-srv" 2>&1 | grep 'Bootstrapped 100%' >/dev/null && break; sleep 2; done
docker logs "${PROJ}-tor-srv" 2>&1 | grep 'Bootstrapped 100%' >/dev/null && ok "the service Tor published the control onion" || skip "the service Tor did not bootstrap (no internet?)"
[ "$(docker exec "${PROJ}-tor-srv" cat /var/lib/tor/hs/hostname 2>/dev/null)" = "${ONION}" ] \
    && ok "the service publishes exactly the stamped onion" || bad "service onion != stamped onion"

# ── a client: tailscaled (no proxy) + its own Tor + the SHIPPED relay/keeper ─
# client <label> <net> [lan]   — lan: also attach the LAN network
client() {
    local c="${PROJ}-ts-$1" t="${PROJ}-tor-$1" d="${W}/cli-$1"
    mkdir -p "${d}/data"; chmod 0777 "${d}"
    printf 'DataDirectory /var/lib/tor/data\nLog notice stdout\nSocksPort 0.0.0.0:9050\nSocksPolicy accept *\nControlSocket /var/lib/tor/data/control\nControlSocketsGroupWritable 1\nCookieAuthentication 1\nCookieAuthFileGroupReadable 1\nDataDirectoryGroupReadable 1\n' > "${d}/torrc"
    docker run -d --name "${t}" --network "${PROJ}-egress" -v "${d}:/var/lib/tor" "${TOR_IMG}" sh -c 'exec tor -f /var/lib/tor/torrc' >/dev/null
    docker network connect "${PROJ}-$2" "${t}"
    local tip; tip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${PROJ}-$2\").IPAddress}}" "${t}")"
    docker run -d --name "${c}" --network "${PROJ}-$2" --add-host "${NAME}:127.77.0.1" -e TS_FORCE_NOISE_443=true \
        -v "${W}/tls/bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro" --entrypoint tailscaled "${TS_IMG}" \
        --tun=userspace-networking --statedir=/var/lib/tailscale --no-logs-no-support >/dev/null
    [ "${3:-}" = lan ] && docker network connect "${PROJ}-lan" "${c}"
    printf 'TRANSPORT=lan+onion\nLISTEN=127.77.0.1:8080\nLAN=10.255.0.10:8080\nONION=%s:8080\nSOCKS=%s:9050\nTOR_CONTROL=/tor/data/control\nTOR_COOKIE=/tor/data/control_auth_cookie\n' "${ONION}" "${tip}" > "${d}/relay.conf"
    for sub in listen keeper; do
        docker run -d --name "${c}-${sub}" --network "container:${c}" -v "${d}/relay.conf:/etc/relay.conf:ro" -v "${d}:/tor" \
            -v "${REPO}/specs/usr/sbin/hugmesh-mesh-control-relay:/usr/sbin/hugmesh-mesh-control-relay:ro" \
            -e HUGMESH_MESH_CONTROL_CONF=/etc/relay.conf -e HUGMESH_MESH_CONTROL_STATE=/tor/state \
            "${TOR_IMG}" bash /usr/sbin/hugmesh-mesh-control-relay "${sub}" >/dev/null
    done
}
up() {  # up <label> -> seconds to Running, or "fail"
    local c="${PROJ}-ts-$1" t0 t1
    t0="$(date +%s.%N)"
    docker exec "${c}" tailscale up --login-server="https://${NAME}:8080" --authkey="${KEY}" --hostname="$1" --timeout=240s >/dev/null 2>&1 \
        || { echo fail; return; }
    t1="$(date +%s.%N)"; python3 -c "print(round(${t1}-${t0},1))"
}
path_now() { docker exec "${PROJ}-ts-$1-keeper" bash /usr/sbin/hugmesh-mesh-control-relay status 2>/dev/null | sed -n 's/^path now: *//p'; }
online() { docker exec "${PROJ}-ts-$1" tailscale status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if d.get("BackendState")=="Running" and (d.get("Self") or {}).get("Online") else "no")' 2>/dev/null; }
wait_for() {  # wait_for <seconds> <cmd...>: seconds it took, or "timeout"
    local lim="$1"; shift; local t0; t0="$(date +%s)"
    while [ $(( $(date +%s) - t0 )) -lt "${lim}" ]; do "$@" && { echo $(( $(date +%s) - t0 )); return 0; }; sleep 2; done
    echo timeout; return 1
}
client c1 c1
client c2 c2 lan
client c3 c3 lan
for t in c1 c2 c3; do
    for i in $(seq 1 90); do docker logs "${PROJ}-tor-${t}" 2>&1 | grep 'Bootstrapped 100%' >/dev/null && break; sleep 2; done
done
sleep 25   # the keepers' first rounds (LAN probe, onion warm-up)

# ── cell 1: LAN configured but unreachable -> the onion ──────────────────────
echo "-- cell 1: off-LAN (LAN configured, unreachable) --"
[ "$(path_now c1)" = onion ] && ok "c1's relay chose the onion (its LAN address does not answer)" || bad "c1 path: $(path_now c1)"
s="$(up c1)"; [ "${s}" != fail ] && ok "c1 joined over the onion in ${s}s" || bad "c1 did not join over the onion"
# ── cell 2: on the LAN -> the LAN; two LAN peers go direct ───────────────────
echo "-- cell 2: LAN under the relay --"
[ "$(path_now c2)" = LAN ] && ok "c2's relay chose the LAN" || bad "c2 path: $(path_now c2)"
s="$(up c2)"; [ "${s}" != fail ] && ok "c2 joined over the LAN in ${s}s" || bad "c2 did not join"
s="$(up c3)"; [ "${s}" != fail ] && ok "c3 joined over the LAN in ${s}s" || bad "c3 did not join"
sleep 8
out="$(docker exec "${PROJ}-ts-c2" tailscale ping -c 15 c3 2>&1 | tail -2 | tr '\n' ' ')"
echo "${out}" | grep 'via 10\.255\.0\.' >/dev/null && ok "c2 -> c3 went DIRECT on the LAN: ${out}" || bad "c2 -> c3 not direct: ${out}"
out="$(docker exec "${PROJ}-ts-c1" tailscale ping -c 10 --until-direct=false c3 2>&1 | grep -c 'via DERP')"
[ "${out}" -ge 1 ] && ok "c1 (off-LAN) -> c3 relays via DERP over the onion (${out}/10 pongs)" || bad "c1 -> c3 never relayed"
# ── cell 3: the two-way switch ───────────────────────────────────────────────
echo "-- cell 3: c2 loses the LAN, then gets it back --"
docker network disconnect "${PROJ}-lan" "${PROJ}-ts-c2"
s="$(wait_for 300 sh -c "[ \"\$(docker exec ${PROJ}-ts-c2-keeper bash /usr/sbin/hugmesh-mesh-control-relay status 2>/dev/null | sed -n 's/^path now: *//p')\" = onion ]")"
[ "${s}" != timeout ] && ok "LAN -> onion: the relay switched after ${s}s" || bad "LAN -> onion: the relay never switched"
s="$(wait_for 300 sh -c "docker exec ${PROJ}-ts-c2 tailscale ping -c 1 --until-direct=false c1 2>/dev/null | grep pong >/dev/null")"
[ "${s}" != timeout ] && ok "LAN -> onion: c2 reaches c1 again ${s}s after the switch" || bad "LAN -> onion: c2 never reached c1"
docker network connect "${PROJ}-lan" "${PROJ}-ts-c2"
s="$(wait_for 300 sh -c "[ \"\$(docker exec ${PROJ}-ts-c2-keeper bash /usr/sbin/hugmesh-mesh-control-relay status 2>/dev/null | sed -n 's/^path now: *//p')\" = LAN ]")"
[ "${s}" != timeout ] && ok "onion -> LAN: the relay switched back after ${s}s" || bad "onion -> LAN: never switched back"
# ── cell 4: the keeper's NEWNYM path ─────────────────────────────────────────
echo "-- cell 4: c1's Tor loses the internet for 75 s --"
docker network disconnect "${PROJ}-egress" "${PROJ}-tor-c1"; sleep 75
docker network connect "${PROJ}-egress" "${PROJ}-tor-c1"
docker logs "${PROJ}-ts-c1-keeper" 2>&1 | grep 'sent SIGNAL NEWNYM' >/dev/null && ok "the keeper sent NEWNYM after repeated onion failures" \
    || bad "the keeper never sent NEWNYM: $(docker logs "${PROJ}-ts-c1-keeper" 2>&1 | tail -3 | tr '\n' ' ')"
s="$(wait_for 300 sh -c "docker exec ${PROJ}-ts-c1-keeper cat /tor/state/status 2>/dev/null | grep 'onion=ok' >/dev/null")"
[ "${s}" != timeout ] && ok "the onion path recovered ${s}s after the internet returned" || bad "the onion path never recovered"
s="$(wait_for 300 sh -c "docker exec ${PROJ}-ts-c1 tailscale ping -c 1 --until-direct=false c3 2>/dev/null | grep pong >/dev/null")"
[ "${s}" != timeout ] && ok "c1 reaches c3 again (${s}s after recovery)" || bad "c1 never reached c3 again"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
