#!/usr/bin/env bash
# test-mesh-control-onion.sh — offline guard for mesh control over Tor (OPT-IN,
# default lan; docs/MESH-CONTROL-OVER-TOR.md).
#
#   A. lan changes nothing: gen-provision-keys writes no .mesh.control_* and no onion
#      key; hugmesh-tor-reconcile renders no ControlSocket / control onion; the Studio
#      emits no flag; every builder bake of the relay sits behind a non-lan test.
#   B. keys-provision, run for real against stubs: the resolvers (the stable name ahead
#      of the baked URL and of LAN-first on BOTH sides, explicit overrides still win,
#      a malformed name/onion or a missing tor keeps the node on lan) and
#      provision_mesh_control on a worker and on the pki (the hosts line, relay.conf,
#      the Tor markers, TS_FORCE_NOISE_443 and NO proxy variable for tailscaled, the
#      onion key installed only when its hostname matches, lan cleaning up after).
#   C. hugmesh-mesh-control-relay against a socat stub: config parsing, the upstream
#      choice (fresh lan-ok -> the LAN, else the onion on ONE isolation user; onion
#      transport never the LAN), and the keeper (LAN probe -> lan-ok; NEWNYM with the
#      cookie after repeated onion failures).
#   D. hugmesh-tor-reconcile renders, in a sandbox root: client-only (no hidden service
#      at all) and the pki's control onion.
#   E. gen-provision-keys.sh run for real with a FIXTURE key directory (tor is not on
#      the CI images; the real mint runs in the live test): stamping, the pki-only key,
#      refusals before anything is built.
#   F. builder parity: all ten parse the flag; x86 + rpi5 bake it; eight refuse.
#   G. negative controls: each mutation of a copy of the tree must turn the guard red.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="${REPO}/tests/scripts/test-mesh-control-onion.sh"
ROOT="${MCO_GUARD_ROOT:-${REPO}}"
. "${REPO}/tests/lib/guard-preflight.sh"
guard_require_tools python3 jq awk sed openssl ssh-keygen od

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
expect() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1: want '$2', got '$3'"; fi; }
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PROV="${ROOT}/specs/etc/keys-provision/provision.sh"
RELAY="${ROOT}/specs/usr/sbin/hugmesh-mesh-control-relay"
RECON="${ROOT}/specs/usr/sbin/hugmesh-tor-reconcile"
GENKEYS="${ROOT}/scripts/gen-provision-keys.sh"
ONION="abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion"
ONION2="zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.onion"

# ── shared: a sourceable copy of the provision.sh pieces under test ──────────
fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f {print} f && /^}/ {exit}' "${PROV}"; }
{
    echo 'log()  { echo "[kp] $*"; }'
    echo 'warn() { log "WARNING: $*"; }'
    echo 'jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }'
    echo 'have() { case "$1" in tor) [ "${STUB_TOR:-1}" = 1 ] ;; socat) [ "${STUB_SOCAT:-1}" = 1 ] ;; hugmesh-tor-reconcile) true ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }'
    echo 'resolve_magic_dns_domain() { echo acme.internal; }'
    echo 'resolve_lan_ip() { echo 192.168.9.9; }'
    awk '/^MESH_CONTROL_LOOPBACK=/ || /^MESH_CONTROL_TRANSPORT_BAKED=/' "${PROV}"
    awk '/^MESH_CONTROL_HOSTS_TAG=/,/^HEADSCALE_OIDC_DEFER_MARKER=/' "${PROV}"
    for f in node_is_public ipv4_literal resolve_pki_lan_ip resolve_mesh_control_transport \
             resolve_mesh_control_name resolve_mesh_control_onion resolve_mesh_control_port \
             mesh_control_active mesh_control_url resolve_endpoint resolve_control_endpoint \
             mesh_control_hosts_line mesh_control_tailscaled_env mesh_control_off provision_mesh_control; do
        fn "${f}"
    done
} > "${WORK}/mc.sh"
for f in resolve_mesh_control_transport mesh_control_active provision_mesh_control mesh_control_tailscaled_env; do
    grep -a -E "^${f}\(\) \{" "${WORK}/mc.sh" >/dev/null && ok "provision.sh defines ${f}" || bad "provision.sh has no ${f}"
done
grep -a -E '^[[:space:]]+provision_mesh_control[[:space:]]' "${PROV}" | grep -a -v '()' >/dev/null \
    && awk '/^main\(\) \{/{f=1} f' "${PROV}" | grep -a -E 'provision_mesh_control' | head -1 >/dev/null \
    && [ "$(awk '/^main\(\) \{/{f=1} f && /provision_mesh_control|provision_tailscale$|provision_tailscale /{print NR": "$0}' "${PROV}" | head -1 | grep -c provision_mesh_control)" = 1 ] \
    && ok "main runs provision_mesh_control before provision_tailscale" \
    || bad "main does not run provision_mesh_control ahead of provision_tailscale"
# Sandboxed paths for the step (every one is a seam in provision.sh).
SB="${WORK}/sb"
sbenv() {
    echo "MESH_CONTROL_DIR=${SB}/etc/hugmesh/mesh-control MESH_CONTROL_TOR_MARKER=${SB}/etc/hugmesh/tor/mesh-control"
    echo "MESH_CONTROL_TOR_ONLY=${SB}/etc/hugmesh/tor/mesh-control-only MESH_CONTROL_HS_DIR=${SB}/var/lib/tor/hugmesh-control"
    echo "MESH_CONTROL_TS_CONF=${SB}/etc/conf.d/tailscaled MESH_CONTROL_HOSTS=${SB}/etc/hosts"
    echo "HEADSCALE_OIDC_DEFER_MARKER=${SB}/var/lib/hugmesh/headscale-oidc-deferred MESH_CONTROL_TRANSPORT_BAKED=${SB}/etc/hugmesh/mesh-control-transport"
}
mkdir -p "${WORK}/bin"
for c in rc-update rc-service chown; do printf '#!/bin/sh\necho "%s $*" >> "${STUB_LOG:-/dev/null}"\nexit 0\n' "${c}" > "${WORK}/bin/${c}"; chmod +x "${WORK}/bin/${c}"; done
run_mc() {  # run_mc <manifest-json> <expr...>: evaluate in the sourced copy, sandboxed
    local m="${WORK}/m.json"; printf '%s\n' "$1" > "${m}"; shift
    env $(sbenv) MANIFEST="${m}" BASE="${SB}/keys" STUB_LOG="${WORK}/stub.log" PATH="${WORK}/bin:${PATH}" \
        HUGMESH_RELEASE_STATE_FILE="${WORK}/no-rs" HUGMESH_GO_LIVE_MARKER="${WORK}/no-gl" \
        bash -c '. "$1"; shift; eval "$*"' _ "${WORK}/mc.sh" "$@"
}

# ── A. lan changes nothing ───────────────────────────────────────────────────
echo "-- A. lan (the default) changes nothing --"
LANM='{"mesh":{"endpoint":"","control_onion":"'"${ONION}"'"},"nodes":[{"ip":"10.0.0.10","role":"pki"}]}'
expect "no transport: the worker endpoint is unchanged" "https://10.0.0.10:8080" "$(run_mc "${LANM}" resolve_control_endpoint 2>/dev/null)"
expect "no transport: the pki endpoint is unchanged" "https://192.168.9.9:8080" "$(run_mc "${LANM}" resolve_endpoint 2>/dev/null)"
rm -rf "${SB}"; mkdir -p "${SB}/etc"; printf '127.0.0.1 localhost\n' > "${SB}/etc/hosts"
run_mc "${LANM}" provision_mesh_control >/dev/null 2>&1
[ "$(cat "${SB}/etc/hosts")" = "127.0.0.1 localhost" ] && [ ! -e "${SB}/etc/conf.d/tailscaled" ] && [ ! -e "${SB}/etc/hugmesh" ] \
    && ok "provision_mesh_control on lan writes nothing" || bad "provision_mesh_control on lan wrote something: $(find "${SB}" -type f | tr '\n' ' ')"
if PYTHONPATH="${ROOT}/studio" python3 -I - "${ROOT}/studio" > "${WORK}/py.out" 2>&1 <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from hugmesh_studio.core.config import ImageConfig
for v in ("", "lan"):
    assert "--mesh-control-transport" not in ImageConfig(mode="mesh", role="pki", platform="x86",
                                                          mesh_control_transport=v).to_cli_args()
a = ImageConfig(mode="mesh", role="pki", platform="x86", mesh_control_transport="onion").to_cli_args()
assert a[a.index("--mesh-control-transport") + 1] == "onion"
assert "--mesh-control-transport" not in ImageConfig(mode="mesh", role="pki", platform="jetson",
                                                      mesh_control_transport="onion").to_cli_args()
print("ok")
PY
then ok "Studio: lan emits nothing; a Tor transport emits on x86, never on a builder that refuses it"
else bad "Studio emission: $(tail -2 "${WORK}/py.out" | tr '\n' ' ')"; fi

# ── B. keys-provision, run for real ──────────────────────────────────────────
echo "-- B. keys-provision resolvers + provision_mesh_control --"
W='{"mesh":{"endpoint":"","pki_lan_ip":"192.168.1.10","control_transport":"lan+onion","control_onion":"'"${ONION}"'"},"nodes":[{"ip":"10.0.0.10","role":"pki"}]}'
expect "worker: the stable name ahead of LAN-first" "https://hs.acme.internal:8080" "$(run_mc "${W}" resolve_control_endpoint 2>/dev/null)"
P_='{"headscale":{"enabled":true},"mesh":{"control_transport":"onion","control_onion":"'"${ONION}"'"}}'
expect "pki: server_url is the same stable name" "https://hs.acme.internal:8080" "$(run_mc "${P_}" resolve_endpoint 2>/dev/null)"
expect "an explicit .mesh.endpoint still wins" "https://explicit.example" \
    "$(run_mc '{"mesh":{"endpoint":"https://explicit.example","control_transport":"onion","control_onion":"'"${ONION}"'"}}' resolve_control_endpoint 2>/dev/null)"
expect "a custom control name and port" "https://ctl.acme.internal:9443" \
    "$(run_mc '{"mesh":{"control_transport":"onion","control_name":"CTL.acme.internal","control_port":9443,"control_onion":"'"${ONION}"'"}}' resolve_control_endpoint 2>/dev/null)"
expect "a malformed control name keeps the node on lan" "https://192.168.1.10:8080" \
    "$(run_mc '{"mesh":{"pki_lan_ip":"192.168.1.10","control_transport":"onion","control_name":"x.onion","control_onion":"'"${ONION}"'"}}' resolve_control_endpoint 2>/dev/null)"
expect "a malformed onion keeps the node on lan" "https://192.168.1.10:8080" \
    "$(run_mc '{"mesh":{"pki_lan_ip":"192.168.1.10","control_transport":"onion","control_onion":"bad.onion"}}' resolve_control_endpoint 2>/dev/null)"
expect "no tor on the image keeps the node on lan" "https://192.168.1.10:8080" \
    "$(STUB_TOR=0 run_mc "${W}" resolve_control_endpoint 2>/dev/null)"
expect "a bogus transport keeps the node on lan" "https://192.168.1.10:8080" \
    "$(run_mc '{"mesh":{"pki_lan_ip":"192.168.1.10","control_transport":"tor","control_onion":"'"${ONION}"'"}}' resolve_control_endpoint 2>/dev/null)"
mkdir -p "${SB}/etc/hugmesh"; echo onion > "${SB}/etc/hugmesh/mesh-control-transport"
expect "the builder-baked transport applies when the stick names none" "https://hs.acme.internal:8080" \
    "$(run_mc '{"mesh":{"control_onion":"'"${ONION}"'"}}' resolve_control_endpoint 2>/dev/null)"
# provision_mesh_control on a worker
rm -rf "${SB}"; mkdir -p "${SB}/etc/conf.d"; printf '127.0.0.1 localhost\n' > "${SB}/etc/hosts"
printf 'PORT=41641\nexport HTTPS_PROXY=http://old:1\n' > "${SB}/etc/conf.d/tailscaled"
: > "${WORK}/stub.log"
run_mc "${W}" provision_mesh_control > "${WORK}/w.log" 2>&1
grep -a -x -F "127.77.0.1 hs.acme.internal # hugmesh-mesh-control" "${SB}/etc/hosts" >/dev/null \
    && [ "$(grep -c hugmesh-mesh-control "${SB}/etc/hosts")" = 1 ] && ok "worker: one managed hosts line -> 127.77.0.1" \
    || bad "worker hosts: $(tr '\n' '|' < "${SB}/etc/hosts")"
expect "worker: relay.conf" "TRANSPORT=lan+onion|LISTEN=127.77.0.1:8080|LAN=192.168.1.10:8080|ONION=${ONION}:8080" \
    "$(grep -v '^#' "${SB}/etc/hugmesh/mesh-control/relay.conf" 2>/dev/null | paste -sd'|')"
expect "worker: Tor marker" "client" "$(cat "${SB}/etc/hugmesh/tor/mesh-control" 2>/dev/null)"
[ -e "${SB}/etc/hugmesh/tor/mesh-control-only" ] && ok "worker: tor service not selected -> mesh-control-only (no onion of its own)" \
    || bad "worker: mesh-control-only not written"
grep -a -x 'export TS_FORCE_NOISE_443=true' "${SB}/etc/conf.d/tailscaled" >/dev/null && ok "tailscaled: TS_FORCE_NOISE_443=true" \
    || bad "tailscaled conf.d has no TS_FORCE_NOISE_443"
grep -a -F 'PORT=41641' "${SB}/etc/conf.d/tailscaled" >/dev/null && ok "tailscaled conf.d keeps what was there" || bad "the conf.d rewrite lost an operator line"
grep -a -E '^(export )?(HTTPS?|ALL)_PROXY=' "${SB}/etc/conf.d/tailscaled" | grep -v 'old:1' >/dev/null \
    && bad "a proxy variable was written for tailscaled" || ok "no proxy variable is written for tailscaled"
grep -a -E 'rc-update add hugmesh-mesh-control-relay default' "${WORK}/stub.log" >/dev/null \
    && grep -a -E 'rc-update add hugmesh-mesh-control-keeper default' "${WORK}/stub.log" >/dev/null \
    && grep -a -E 'rc-update add tor default' "${WORK}/stub.log" >/dev/null \
    && ok "worker: relay, keeper and tor linked" || bad "worker links: $(tr '\n' '|' < "${WORK}/stub.log")"
run_mc "${W}" provision_mesh_control >/dev/null 2>&1
[ "$(grep -c hugmesh-mesh-control "${SB}/etc/hosts")" = 1 ] && [ "$(grep -c 'hugmesh-mesh-control (' "${SB}/etc/conf.d/tailscaled")" = 1 ] \
    && ok "a second run is idempotent" || bad "a second run duplicated the managed lines"
run_mc '{"mesh":{"control_transport":"lan"}}' provision_mesh_control >/dev/null 2>&1
! grep -q hugmesh-mesh-control "${SB}/etc/hosts" && ! grep -q TS_FORCE_NOISE_443 "${SB}/etc/conf.d/tailscaled" \
    && [ ! -e "${SB}/etc/hugmesh/mesh-control/relay.conf" ] && ok "back to lan: the hosts line, the env and relay.conf are removed" \
    || bad "back to lan left mesh-control state behind"
# provision_mesh_control on the pki
rm -rf "${SB}"; mkdir -p "${SB}/etc" "${SB}/keys/headscale/control-onion"; printf '127.0.0.1 localhost\n' > "${SB}/etc/hosts"
printf '%s\n' "${ONION}" > "${SB}/keys/headscale/control-onion/hostname"
head -c 96 /dev/urandom > "${SB}/keys/headscale/control-onion/hs_ed25519_secret_key"
run_mc "${P_}" provision_mesh_control > "${WORK}/p.log" 2>&1
[ -s "${SB}/var/lib/tor/hugmesh-control/hs_ed25519_secret_key" ] \
    && [ "$(stat -c %a "${SB}/var/lib/tor/hugmesh-control/hs_ed25519_secret_key")" = 600 ] \
    && [ "$(stat -c %a "${SB}/var/lib/tor/hugmesh-control")" = 700 ] && ok "pki: the control onion key is installed 0600 in a 0700 dir" \
    || bad "pki: key not installed as expected"
expect "pki: Tor marker" "control 8080" "$(cat "${SB}/etc/hugmesh/tor/mesh-control" 2>/dev/null)"
[ ! -e "${SB}/etc/hugmesh/mesh-control/relay.conf" ] && ok "pki: no relay (headscale listens on the control name itself)" || bad "pki got a relay.conf"
rm -rf "${SB}/var"; printf '%s\n' "${ONION2}" > "${SB}/keys/headscale/control-onion/hostname"
run_mc "${P_}" provision_mesh_control > "${WORK}/p2.log" 2>&1
[ ! -e "${SB}/var/lib/tor/hugmesh-control/hs_ed25519_secret_key" ] && grep -a -F 'NOT installed' "${WORK}/p2.log" >/dev/null \
    && ok "pki: a key whose hostname is not the sticks' onion is refused, loudly" || bad "pki installed a mismatched onion key"
# OIDC deferral on the pki
mkdir -p "${SB}/etc/headscale"
grep -a -F '/etc/headscale/config.yaml' "${WORK}/mc.sh" >/dev/null && ok "OIDC deferral reads the live headscale config" || bad "OIDC deferral does not read /etc/headscale/config.yaml"

# ── C. the relay ─────────────────────────────────────────────────────────────
echo "-- C. hugmesh-mesh-control-relay against a socat stub --"
RB="${WORK}/rbin"; mkdir -p "${RB}"
cat > "${RB}/socat" <<'EOF'
#!/bin/bash
echo "socat $*" >> "${SOCAT_LOG}"
for a in "$@"; do case "$a" in
  TCP:*) [ "${STUB_LAN_UP:-0}" = 1 ]; exit $? ;;
  SOCKS4A:*) [ "${STUB_ONION_UP:-0}" = 1 ]; exit $? ;;
  UNIX-CONNECT:*) cat > "${SOCAT_LOG}.ctl"; printf '250 OK\r\n250 OK\r\n'; exit 0 ;;
esac; done
exit 0
EOF
chmod +x "${RB}/socat"
RS="${WORK}/rstate"; mkdir -p "${RS}"
rconf() { printf '%s\n' "$@" > "${WORK}/relay.conf"; }
relay() {  # relay <subcommand>
    : > "${WORK}/socat.log"
    env PATH="${RB}:${PATH}" SOCAT_LOG="${WORK}/socat.log" HUGMESH_MESH_CONTROL_CONF="${WORK}/relay.conf" \
        HUGMESH_MESH_CONTROL_STATE="${RS}" HUGMESH_MESH_CONTROL_KEEPER_ONCE=1 bash "${RELAY}" "$1" </dev/null >"${WORK}/relay.out" 2>&1
}
rconf TRANSPORT=lan+onion LISTEN=127.77.0.1:8080 LAN=192.168.1.10:8080 "ONION=${ONION}:8080"
rm -f "${RS}/lan-ok"; relay upstream
grep -a -F "socat STDIO SOCKS4A:127.0.0.1:${ONION}:8080,socksport=9050,socksuser=hugmesh-control" "${WORK}/socat.log" >/dev/null \
    && ok "no lan-ok: the onion, through Tor SOCKS on the one isolation user" || bad "upstream without lan-ok: $(cat "${WORK}/socat.log")"
touch "${RS}/lan-ok"; relay upstream
grep -a -F "socat STDIO TCP:192.168.1.10:8080,connect-timeout=3" "${WORK}/socat.log" >/dev/null \
    && ok "fresh lan-ok: the pki on the LAN" || bad "upstream with lan-ok: $(cat "${WORK}/socat.log")"
touch -d '5 minutes ago' "${RS}/lan-ok"; relay upstream
grep -a -F "SOCKS4A:" "${WORK}/socat.log" >/dev/null && ok "a stale lan-ok is not trusted (the onion)" || bad "a stale lan-ok was trusted"
rconf TRANSPORT=onion LISTEN=127.77.0.1:8080 LAN=192.168.1.10:8080 "ONION=${ONION}:8080"
touch "${RS}/lan-ok"; relay upstream
grep -a -F "SOCKS4A:" "${WORK}/socat.log" >/dev/null && ok "transport onion never takes the LAN" || bad "transport onion took the LAN"
relay listen
grep -a -F "socat TCP-LISTEN:8080,bind=127.77.0.1,fork,reuseaddr EXEC:/usr/sbin/hugmesh-mesh-control-relay upstream" "${WORK}/socat.log" >/dev/null \
    && ok "listen: socat on 127.77.0.1:8080, one upstream per connection" || bad "listen: $(cat "${WORK}/socat.log")"
for badline in "LAN=evil.example:8080" "ONION=short.onion:8080" "LISTEN=0.0.0.0" "TRANSPORT=lan" "ISOLATION=a b" "EXTRA=1"; do
    rconf TRANSPORT=lan+onion LISTEN=127.77.0.1:8080 "ONION=${ONION}:8080" "${badline}"
    if relay upstream; then bad "relay accepted '${badline}'"; else
        [ ! -s "${WORK}/socat.log" ] && ok "relay refuses '${badline}' before dialling anything" || bad "relay dialled with '${badline}'"; fi
done
rconf TRANSPORT=lan+onion LISTEN=127.77.0.1:8080 LAN=192.168.1.10:8080 "ONION=${ONION}:8080" "TOR_CONTROL=${WORK}/ctl.sock" "TOR_COOKIE=${WORK}/cookie"
printf '0123456789abcdef0123456789abcdef' > "${WORK}/cookie"
rm -f "${RS}/lan-ok"; STUB_LAN_UP=1 STUB_ONION_UP=1 relay keeper
[ -e "${RS}/lan-ok" ] && grep -a -F 'lan=ok onion=ok' "${RS}/status" >/dev/null && ok "keeper: LAN up -> lan-ok; onion warm" || bad "keeper (all up): $(cat "${RS}/status" 2>/dev/null)"
STUB_LAN_UP=0 STUB_ONION_UP=0 relay keeper
[ ! -e "${RS}/lan-ok" ] && ok "keeper: LAN down -> lan-ok removed" || bad "keeper kept lan-ok with the LAN down"
rm -f "${WORK}/socat.log.ctl"
env PATH="${RB}:${PATH}" SOCAT_LOG="${WORK}/socat.log" HUGMESH_MESH_CONTROL_CONF="${WORK}/relay.conf" HUGMESH_MESH_CONTROL_STATE="${RS}" \
    HUGMESH_MESH_CONTROL_KEEPER_INTERVAL=0 HUGMESH_MESH_CONTROL_NEWNYM_AFTER=2 STUB_ONION_UP=0 \
    timeout 5 bash "${RELAY}" keeper >/dev/null 2>&1
grep -a -F "AUTHENTICATE $(od -An -tx1 -v "${WORK}/cookie" | tr -d ' \n')" "${WORK}/socat.log.ctl" >/dev/null 2>&1 \
    && grep -a -F 'SIGNAL NEWNYM' "${WORK}/socat.log.ctl" >/dev/null && ok "keeper: NEWNYM with the hex cookie after repeated onion failures" \
    || bad "keeper never sent an authenticated NEWNYM"

# ── D. hugmesh-tor-reconcile renders ─────────────────────────────────────────
echo "-- D. hugmesh-tor-reconcile with the mesh-control markers --"
render() {  # render <marker|-> <only 0|1>  -> the torrc it writes in a sandbox root
    local r="${WORK}/tr"; rm -rf "${r}"; mkdir -p "${r}/etc/hugmesh/tor" "${r}/var/log" "${r}/etc/tor"
    [ "$1" = "-" ] || printf '%s\n' "$1" > "${r}/etc/hugmesh/tor/mesh-control"
    [ "$2" = 1 ] && : > "${r}/etc/hugmesh/tor/mesh-control-only"
    # A PATH without tor or OpenRC: the reconcile renders and installs the torrc and
    # leaves the daemon alone (a host tor would verify the sandbox paths and refuse).
    if [ ! -d "${WORK}/tbin" ]; then
        mkdir -p "${WORK}/tbin"; printf '#!/bin/sh\nexit 0\n' > "${WORK}/tbin/id"; chmod +x "${WORK}/tbin/id"
        for c in mkdir chown chmod mktemp cat cmp mv rm date tr install cp sleep head basename dirname; do
            t="$(command -v "${c}")" && ln -sf "${t}" "${WORK}/tbin/${c}"
        done
    fi
    PATH="${WORK}/tbin" HUGMESH_TOR_ROOT="${r}" HUGMESH_TOR_WAIT_TRIES=0 "${BASH}" "${RECON}" >/dev/null 2>&1
    cat "${r}/etc/tor/torrc" 2>/dev/null
}
base="$(render - 0)"
echo "${base}" | grep -a -q '^HiddenServiceDir /var/lib/tor/hugmesh-onion$' && ! echo "${base}" | grep -a -q 'ControlSocket\|hugmesh-control' \
    && ok "no marker: the fe-gateway onion as before, no ControlSocket, no control onion" || bad "default render changed: ${base}"
cli="$(render client 1)"
! echo "${cli}" | grep -a -q '^HiddenServiceDir' && echo "${cli}" | grep -a -q '^ControlSocket /var/lib/tor/data/control$' \
    && echo "${cli}" | grep -a -q '^CookieAuthentication 1$' && echo "${cli}" | grep -a -q '^SocksPort 127.0.0.1:9050$' \
    && ok "worker (client, control-only): a SOCKS client + ControlSocket, NO hidden service at all" || bad "client render: ${cli}"
ctl="$(render 'control 8080' 1)"
echo "${ctl}" | grep -a -q '^HiddenServiceDir /var/lib/tor/hugmesh-control$' && echo "${ctl}" | grep -a -q '^HiddenServicePort 8080 127.0.0.1:8080$' \
    && ! echo "${ctl}" | grep -a -q '^HiddenServiceDir /var/lib/tor/hugmesh-onion$' \
    && ok "pki (control, control-only): the control onion -> 127.0.0.1:8080, not the fe-gateway onion" || bad "control render: ${ctl}"
both="$(render 'control 8080' 0)"
echo "${both}" | grep -a -q '^HiddenServiceDir /var/lib/tor/hugmesh-onion$' && echo "${both}" | grep -a -q '^HiddenServiceDir /var/lib/tor/hugmesh-control$' \
    && ok "pki with the tor service selected: both onions" || bad "control + tor service render: ${both}"
junk="$(render 'control 99999' 1)"
! echo "${junk}" | grep -a -q 'hugmesh-control\|ControlSocket' && ok "a malformed marker adds nothing" || bad "malformed marker render: ${junk}"

# ── E. gen-provision-keys with a fixture key dir ─────────────────────────────
echo "-- E. gen-provision-keys.sh (fixture onion dir; the real mint is in the live test) --"
OD="${WORK}/onion"; mkdir -p -m 0700 "${OD}"; printf '%s\n' "${ONION}" > "${OD}/hostname"
head -c 96 /dev/urandom > "${OD}/hs_ed25519_secret_key"; head -c 64 /dev/urandom > "${OD}/hs_ed25519_public_key"
gk() { local out="$1"; shift; NONINTERACTIVE=1 BRAND=hugmesh bash "${GENKEYS}" --out "${out}" --random "$@" > "${out}.log" 2>&1; }
if gk "${WORK}/k-host" --role host --pki-ip 192.168.1.10 --mesh-control-transport lan+onion --mesh-control-onion-dir "${OD}"; then
    expect "worker stick: .mesh.control_*" "lan+onion hs.hugmesh.internal ${ONION}" \
        "$(jq -r '[.mesh.control_transport, .mesh.control_name, .mesh.control_onion] | join(" ")' "${WORK}/k-host/provision.json")"
    [ -z "$(find "${WORK}/k-host" -name 'hs_ed25519_*')" ] && ok "worker stick: no onion key at all" || bad "a worker stick carries onion key material"
else bad "gen-provision-keys host (Tor) failed: $(tail -2 "${WORK}/k-host.log" | tr '\n' ' ')"; fi
if gk "${WORK}/k-pki" --role pki --pki-ip 192.168.1.10 --mesh-control-transport lan+onion --mesh-control-onion-dir "${OD}" --mesh-control-name ctl.acme.internal; then
    cmp -s "${OD}/hs_ed25519_secret_key" "${WORK}/k-pki/headscale/control-onion/hs_ed25519_secret_key" \
        && [ "$(stat -c %a "${WORK}/k-pki/headscale/control-onion/hs_ed25519_secret_key")" = 600 ] \
        && ok "pki stick: the control onion key, 0600" || bad "pki stick: key missing or not 0600"
    expect "pki stick: the custom name" "ctl.acme.internal" "$(jq -r .mesh.control_name "${WORK}/k-pki/provision.json")"
else bad "gen-provision-keys pki (Tor) failed: $(tail -2 "${WORK}/k-pki.log" | tr '\n' ' ')"; fi
if gk "${WORK}/k-lan" --role host --pki-ip 192.168.1.10; then
    expect "lan stick: no .mesh.control_* keys" "0" "$(jq '[.mesh | keys[] | select(startswith("control_"))] | length' "${WORK}/k-lan/provision.json")"
else bad "gen-provision-keys lan failed"; fi
refuse() {  # refuse <label> <args...>
    local l="$1"; shift
    if gk "${WORK}/k-no" "$@"; then bad "accepted: ${l}"
    elif [ -e "${WORK}/k-no" ]; then bad "refused only after building: ${l}"; else ok "refused before anything is built: ${l}"; fi
    rm -rf "${WORK}/k-no"
}
refuse "a Tor transport without --mesh-control-onion-dir" --role host --pki-ip 192.168.1.10 --mesh-control-transport onion
refuse "lan+onion without --pki-ip" --role host --mesh-control-transport lan+onion --mesh-control-onion-dir "${OD}"
refuse "an empty onion dir without the mint consent" --role host --mesh-control-transport onion --mesh-control-onion-dir "${WORK}/empty"
refuse "an .onion as the control name" --role host --mesh-control-transport onion --mesh-control-onion-dir "${OD}" --mesh-control-name "${ONION}"
refuse "an unknown transport" --role host --mesh-control-transport tor
mkdir -p "${WORK}/nohost"; head -c 96 /dev/urandom > "${WORK}/nohost/hs_ed25519_secret_key"
refuse "minting over an existing secret key" --role host --mesh-control-transport onion --mesh-control-onion-dir "${WORK}/nohost" --mesh-control-onion-mint
cp -r "${OD}" "${WORK}/gone"; rm -f "${WORK}/gone/hs_ed25519_secret_key"
gk "${WORK}/k-gone" --role pki --pki-ip 192.168.1.10 --mesh-control-transport onion --mesh-control-onion-dir "${WORK}/gone" \
    && bad "a pki stick was made without the secret key" || ok "a pki stick whose secret key was removed is refused (re-mint, re-make every stick)"
grep -a -F 'find "${OUT_DIR}" -name '"'"'hs_ed25519_secret_key'"'" "${GENKEYS}" >/dev/null && ok "the placement guard looks for an onion secret key on non-pki sticks" \
    || bad "no placement guard for onion keys"

# ── F. builder parity ────────────────────────────────────────────────────────
echo "-- F. --mesh-control-transport on every builder --"
nb=0
for b in "${ROOT}"/build-*-stage4.sh; do
    nb=$((nb + 1)); n="$(basename "${b}")"; miss=""
    grep -a -F -- '--mesh-control-transport) MESH_CONTROL_TRANSPORT="$2"; shift 2 ;;' "${b}" >/dev/null || miss="${miss} parse"
    grep -a -F 'MESH_CONTROL_TRANSPORT="${MESH_CONTROL_TRANSPORT:-lan}"' "${b}" >/dev/null || miss="${miss} default"
    grep -a -E '^ +--mesh-control-transport( |$)' "${b}" >/dev/null || miss="${miss} usage"
    case "${n}" in
        build-x86-host-stage4.sh|build-rpi5-stage4.sh)
            grep -a -F 'echo "${MESH_CONTROL_TRANSPORT}" > "${SYSROOT}/etc/hugmesh/mesh-control-transport"' "${b}" >/dev/null || miss="${miss} bake"
            grep -a -F 'hugmesh-mesh-control-relay hugmesh-mesh-control-keeper' "${b}" >/dev/null || miss="${miss} services"
            grep -a -E '"\$\{MESH_CONTROL_TRANSPORT:-lan\}" != lan \] && ! _tor_node_selected' "${b}" >/dev/null || miss="${miss} tor-package"
            [ -z "${miss}" ] && ok "${n}: parses, documents, bakes the relay and adds tor for a Tor transport" || bad "${n}: incomplete (missing:${miss})" ;;
        *)
            grep -a -E '^    lan\+onion\|onion\) err "--mesh-control-transport .*this builder cannot bake Tor' "${b}" >/dev/null || miss="${miss} refusal"
            [ -z "${miss}" ] && ok "${n}: parses the flag and refuses a Tor transport" || bad "${n}: incomplete (missing:${miss})" ;;
    esac
done
[ "${nb}" -ge 10 ] && ok "all ${nb} builders checked" || bad "only ${nb} builders found (expected 10)"
for f in specs/usr/sbin/hugmesh-mesh-control-relay specs/usr/sbin/hugmesh-headscale-oidc-defer \
         specs/etc/init.d/hugmesh-mesh-control-relay specs/etc/init.d/hugmesh-mesh-control-keeper; do
    [ -x "${ROOT}/${f}" ] && ok "${f} ships executable" || bad "${f} missing or not executable"
done
if grep -a -n -E '(HTTPS?|ALL)_PROXY' "${PROV}" "${RELAY}" | grep -a -v -E '^\S+:[0-9]+:\s*#' | grep -a -v 'no proxy variable' >/dev/null; then
    bad "a proxy variable is set somewhere on the mesh-control path: $(grep -a -n -E '(HTTPS?|ALL)_PROXY' "${PROV}" "${RELAY}" | grep -a -v -E ':\s*#' | head -2 | tr '\n' ' ')"
else ok "no proxy variable anywhere on the mesh-control path (keys-provision, relay)"; fi

# ── G. negative controls ─────────────────────────────────────────────────────
if [ -z "${MCO_GUARD_NO_CONTROLS:-}" ]; then
    echo "-- G. negative controls: each mutation must turn the guard red --"
    mktree() {
        local d="$1" f
        mkdir -p "${d}/specs/etc/keys-provision" "${d}/specs/usr/sbin" "${d}/specs/etc/init.d" "${d}/studio"
        cp -p "${REPO}/specs/etc/keys-provision/provision.sh" "${d}/specs/etc/keys-provision/" || return 1
        for f in hugmesh-mesh-control-relay hugmesh-tor-reconcile hugmesh-headscale-oidc-defer; do cp -p "${REPO}/specs/usr/sbin/${f}" "${d}/specs/usr/sbin/"; done
        for f in hugmesh-mesh-control-relay hugmesh-mesh-control-keeper; do cp -p "${REPO}/specs/etc/init.d/${f}" "${d}/specs/etc/init.d/"; done
        for f in keys-template scripts brands; do cp -rp "${REPO}/${f}" "${d}/${f}" || return 1; done
        cp -p "${REPO}"/build-*-stage4.sh "${d}/"
        ln -s "${REPO}/studio/hugmesh_studio" "${d}/studio/hugmesh_studio"
    }
    child() { MCO_GUARD_ROOT="$1" MCO_GUARD_NO_CONTROLS=1 bash "${SELF}" </dev/null 2>&1; }
    pos="${WORK}/ctl-pos"
    if mktree "${pos}" && child "${pos}" > "${WORK}/ctl-pos.log"; then ok "positive control: an unmutated copy passes"
    else bad "positive control FAILS: $(grep -a FAIL "${WORK}/ctl-pos.log" | head -3 | tr '\n' ' ')"; fi
    rm -rf "${pos}"
    n=0
    control() {
        local d="${WORK}/ctl-$((n+=1))"
        mktree "${d}" || { bad "control '$1': could not build the tree"; return; }
        if ! python3 - "${d}/$2" "$3" "$4" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(p, encoding="utf-8").read()
if t.count(old) < 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(t.replace(old, new, 1))
PY
        then bad "control '$1': anchor not found in $2 (stale)"; rm -rf "${d}"; return; fi
        if child "${d}" > "${d}.log"; then bad "control '$1' did NOT bite"
        else ok "control bites: $1  [red on: $(grep -a 'FAIL' "${d}.log" | head -1 | sed 's/^ *FAIL //' | cut -c1-100)]"; fi
        rm -rf "${d}"
    }
    control "the worker resolver ignores the stable name" specs/etc/keys-provision/provision.sh \
        '    if { [ -z "${ep}" ] || [ "${ep}" = "null" ]; } && mesh_control_active; then
        ep="$(mesh_control_url)"' '    if false; then
        ep="$(mesh_control_url)"'
    control "the pki server_url ignores the stable name" specs/etc/keys-provision/provision.sh \
        'if { [ -z "${ep}" ] || [ "${ep}" = "null" ]; } && mesh_control_active; then ep="$(mesh_control_url)"; fi' ':'
    control "a missing tor is not checked" specs/etc/keys-provision/provision.sh '    if ! have tor; then' '    if false; then'
    control "tailscaled gets an HTTPS_PROXY" specs/etc/keys-provision/provision.sh \
        'export TS_FORCE_NOISE_443=true' 'export TS_FORCE_NOISE_443=true
export HTTPS_PROXY=http://127.0.0.1:9080'
    control "the onion key is installed without the hostname check" specs/etc/keys-provision/provision.sh \
        '            if [ "${got}" != "${onion}" ]; then' '            if false; then'
    control "the relay trusts any lan-ok age" specs/usr/sbin/hugmesh-mesh-control-relay \
        '    [ $((now - m)) -le "${LAN_OK_MAX_AGE}" ]' '    true'
    control "the relay drops the isolation user" specs/usr/sbin/hugmesh-mesh-control-relay \
        ',socksuser=${ISOLATION}"; }' '"; }'
    control "the keeper never sends NEWNYM" specs/usr/sbin/hugmesh-mesh-control-relay \
        '            if [ "${fails}" -ge "${NEWNYM_AFTER}" ]; then newnym; fails=0; fi' '            :'
    control "the reconcile publishes the fe-gateway onion from a client" specs/usr/sbin/hugmesh-tor-reconcile \
        '    ${MC_ONLY} || cat <<EOT' '    cat <<EOT'
    control "gen-provision-keys copies the onion key onto every stick" scripts/gen-provision-keys.sh \
        '    if [ "${ROLE}" = pki ]; then
        mkdir -p "${OUT_DIR}/headscale/control-onion"' '    if true; then
        mkdir -p "${OUT_DIR}/headscale/control-onion"'
    control "gen-provision-keys mints without consent" scripts/gen-provision-keys.sh \
        '        if [ "${MESH_CONTROL_ONION_MINT}" != true ]; then' '        if false; then'
    control "an ARM builder accepts a Tor transport it cannot bake" build-orangepi5-stage4.sh \
        '    lan+onion|onion) err "--mesh-control-transport ${MESH_CONTROL_TRANSPORT}: this builder cannot bake Tor' \
        '    lan+onion|onion) ;; #'
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
