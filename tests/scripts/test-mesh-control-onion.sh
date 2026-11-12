#!/usr/bin/env bash
# test-mesh-control-onion.sh — offline guard for mesh control over Tor (OPT-IN,
# default lan; docs/MESH-CONTROL-OVER-TOR.md).
#
#   A. lan changes nothing: gen-provision-keys writes no .mesh.control_* and no onion
#      key; hugmesh-tor-reconcile renders no ControlSocket / control onion; the Studio
#      emits no flag; every builder bake of the relay sits behind a non-lan test.
#   B. keys-provision, run for real against stubs (the MagicDNS domain comes from the
#      manifest through the REAL resolve_magic_dns_domain, never a stub):
#        * the control name: default hs.<first label>-control.<rest>, never inside the
#          MagicDNS domain (headscale 0.23.0 refuses a server_url that CONTAINS it —
#          measured; tests/scripts/test-mesh-control-headscale-start.sh starts it);
#        * the control port 7443 (never headscale's own 8080);
#        * the resolvers on BOTH sides, explicit overrides still winning;
#        * Tor only FAILS CLOSED: no tor / socat / onion / valid name -> no endpoint
#          and provision_tailscale never runs `tailscale up` (lan+onion degrades to
#          lan, loudly);
#        * provision_mesh_control on a worker and on the pki (the hosts line, relay.conf
#          0600 incl. the pki's local forward, the Tor markers, TS_FORCE_NOISE_443 +
#          TS_NO_LOGS_NO_SUPPORT and NO proxy variable for tailscaled, the onion key
#          installed only when its hostname matches, lan cleaning up after);
#        * headscale runs WITHOUT OIDC in a Tor mode; the TLS passthrough exception.
#   C. hugmesh-mesh-control-relay against a socat stub: config parsing, the upstream
#      choice (fresh lan-ok -> the LAN, else the onion on ONE isolation user; onion
#      transport never the LAN; local always headscale), the keeper (LAN probe ->
#      lan-ok; NEWNYM with the cookie after repeated onion failures), and no log line
#      carrying the whole onion address.
#   D. hugmesh-tor-reconcile renders, in a sandbox root: client-only (no hidden service
#      at all) and the pki's control onion (7443 -> headscale's 8080).
#   E. gen-provision-keys.sh run for real with a FIXTURE key directory (tor is not on
#      the CI images; the real mint runs in the live test): stamping, the derived name,
#      the pki-only key, refusals before anything is built (a name inside the
#      superdomain among them), and the mint against a stub tor that dies on SIGTERM.
#      build-all-roles' secret removal on positive evidence only.
#   F. builder parity: all ten parse the flag; x86 + rpi5 bake it; eight refuse; the
#      bash / Python name derivations agree.
#   G. negative controls: each mutation of a copy of the tree must turn the guard red.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="${REPO}/tests/scripts/test-mesh-control-onion.sh"
ROOT="${MCO_GUARD_ROOT:-${REPO}}"
. "${REPO}/tests/lib/guard-preflight.sh"
guard_require_tools python3 jq awk sed openssl ssh-keygen od cmp

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
BAR="${ROOT}/scripts/build-all-roles.sh"
ONION="abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion"
ONION2="zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.onion"
URL="https://hs.acme-control.internal:7443"   # the derived control URL for acme.internal

# ── shared: a sourceable copy of the provision.sh pieces under test ──────────
# One function, verbatim (a one-line definition ends on its own line).
fn() { awk -v n="$1" '!f && $0 ~ "^"n"\\(\\) \\{" {f=1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next} f {print} f && /^}/ {exit}' "${PROV}"; }
{
    echo 'log()  { echo "[kp] $*"; }'
    echo 'warn() { log "WARNING: $*"; }'
    echo 'jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }'
    echo 'have() { case "$1" in tor) [ "${STUB_TOR:-1}" = 1 ] ;; socat) [ "${STUB_SOCAT:-1}" = 1 ] ;; hugmesh-tor-reconcile|tailscaled|tailscale) true ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }'
    echo 'resolve_lan_ip() { echo 192.168.9.9; }'
    awk '/^MESH_CONTROL_[A-Z_]+=/' "${PROV}"
    for f in node_is_public ipv4_literal resolve_pki_lan_ip resolve_magic_dns_domain resolve_mesh_control_transport \
             mesh_control_default_name mesh_control_name_clash resolve_mesh_control_port resolve_mesh_control_name \
             resolve_mesh_control_onion mesh_control_onion_short mesh_control_active mesh_control_blocked mesh_control_url \
             resolve_endpoint resolve_control_endpoint mesh_control_hosts_line mesh_control_tailscaled_env mesh_control_off \
             mesh_control_oidc_off provision_mesh_control headscale_listen_port mesh_control_tls_passthrough provision_tailscale; do
        fn "${f}"
    done
} > "${WORK}/mc.sh"
for f in resolve_mesh_control_transport mesh_control_default_name mesh_control_name_clash mesh_control_active \
         mesh_control_blocked provision_mesh_control mesh_control_tailscaled_env mesh_control_oidc_off \
         mesh_control_tls_passthrough provision_tailscale resolve_magic_dns_domain; do
    grep -a -E "^${f}\(\) \{" "${WORK}/mc.sh" >/dev/null && ok "provision.sh defines ${f}" || bad "provision.sh has no ${f}"
done
grep -a -E '^[[:space:]]+provision_mesh_control[[:space:]]' "${PROV}" | grep -a -v '()' >/dev/null \
    && [ "$(awk '/^main\(\) \{/{f=1} f && /provision_mesh_control|provision_tailscale$|provision_tailscale /{print NR": "$0}' "${PROV}" | head -1 | grep -c provision_mesh_control)" = 1 ] \
    && ok "main runs provision_mesh_control before provision_tailscale" \
    || bad "main does not run provision_mesh_control ahead of provision_tailscale"
# Sandboxed paths for the step (every one is a seam in provision.sh).
SB="${WORK}/sb"
sbenv() {
    echo "MESH_CONTROL_DIR=${SB}/etc/hugmesh/mesh-control MESH_CONTROL_TOR_MARKER=${SB}/etc/hugmesh/tor/mesh-control"
    echo "MESH_CONTROL_TOR_ONLY=${SB}/etc/hugmesh/tor/mesh-control-only MESH_CONTROL_HS_DIR=${SB}/var/lib/tor/hugmesh-control"
    echo "MESH_CONTROL_TS_CONF=${SB}/etc/conf.d/tailscaled MESH_CONTROL_HOSTS=${SB}/etc/hosts"
    echo "MESH_CONTROL_TRANSPORT_BAKED=${SB}/etc/hugmesh/mesh-control-transport"
}
mkdir -p "${WORK}/bin"
for c in rc-update rc-service chown tailscale; do printf '#!/bin/sh\necho "%s $*" >> "${STUB_LOG:-/dev/null}"\nexit 0\n' "${c}" > "${WORK}/bin/${c}"; chmod +x "${WORK}/bin/${c}"; done
run_mc() {  # run_mc <manifest-json> <expr...>: evaluate in the sourced copy, sandboxed
    local m="${WORK}/m.json"; printf '%s\n' "$1" > "${m}"; shift
    env $(sbenv) MANIFEST="${m}" BASE="${SB}/keys" STUB_LOG="${WORK}/stub.log" PATH="${WORK}/bin:${PATH}" \
        HUGMESH_RELEASE_STATE_FILE="${WORK}/no-rs" HUGMESH_GO_LIVE_MARKER="${WORK}/no-gl" \
        bash -c '. "$1"; shift; eval "$*"' _ "${WORK}/mc.sh" "$@"
}

# ── A. lan changes nothing ───────────────────────────────────────────────────
echo "-- A. lan (the default) changes nothing --"
LANM='{"mesh":{"magic_dns_domain":"acme.internal","endpoint":"","control_onion":"'"${ONION}"'"},"nodes":[{"ip":"10.0.0.10","role":"pki"}]}'
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
echo "-- B. keys-provision resolvers + provision_mesh_control + provision_tailscale --"
W='{"mesh":{"magic_dns_domain":"acme.internal","endpoint":"","pki_lan_ip":"192.168.1.10","control_transport":"lan+onion","control_onion":"'"${ONION}"'"},"nodes":[{"ip":"10.0.0.10","role":"pki"}]}'
WO='{"mesh":{"magic_dns_domain":"acme.internal","endpoint":"","pki_lan_ip":"192.168.1.10","control_transport":"onion","control_onion":"'"${ONION}"'"},"nodes":[{"ip":"10.0.0.10","role":"pki"}]}'
expect "worker: the stable name (derived OUTSIDE the MagicDNS domain, port 7443) ahead of LAN-first" "${URL}" "$(run_mc "${W}" resolve_control_endpoint 2>/dev/null)"
P_='{"headscale":{"enabled":true},"mesh":{"magic_dns_domain":"acme.internal","control_transport":"onion","control_onion":"'"${ONION}"'"}}'
expect "pki: server_url is the same stable name" "${URL}" "$(run_mc "${P_}" resolve_endpoint 2>/dev/null)"
for sd in hugmesh.internal acme.example a.b.c mesh.internal; do
    n="$(run_mc '{"mesh":{"magic_dns_domain":"'"${sd}"'"}}' mesh_control_default_name "${sd}" 2>/dev/null)"
    if run_mc '{}' mesh_control_name_clash "${n}" 7443 "${sd}" >/dev/null 2>&1; then bad "the default name ${n} for ${sd} clashes"
    else ok "the default name for ${sd} is ${n}, outside it"; fi
done
expect "the derivation: hugmesh.internal -> hs.hugmesh-control.internal" "hs.hugmesh-control.internal" \
    "$(run_mc '{}' mesh_control_default_name hugmesh.internal 2>/dev/null)"
# the clash predicate is headscale 0.23.0's: a SUBSTRING of the URL (measured on the pinned image)
for c in "hs.hugmesh.internal hugmesh.internal clash" "hs.hugmesh.internal mesh.internal clash" "hs.internalx.lan internal clash" \
         "hugmesh.internal hugmesh.internal clash" "hs.hugmesh-control.internal hugmesh.internal ok" "ab.cd internal ok"; do
    set -- ${c}
    if run_mc '{}' mesh_control_name_clash "$1" 7443 "$2" >/dev/null 2>&1; then got=clash; else got=ok; fi
    expect "clash predicate: $1 under $2" "$3" "${got}"
done
expect "an explicit .mesh.endpoint still wins" "https://explicit.example" \
    "$(run_mc '{"mesh":{"magic_dns_domain":"acme.internal","endpoint":"https://explicit.example","control_transport":"onion","control_onion":"'"${ONION}"'"}}' resolve_control_endpoint 2>/dev/null)"
expect "a custom control name and port" "https://ctl.acme-ops.example:9443" \
    "$(run_mc '{"mesh":{"magic_dns_domain":"acme.internal","control_transport":"onion","control_name":"CTL.acme-ops.example","control_port":9443,"control_onion":"'"${ONION}"'"}}' resolve_control_endpoint 2>/dev/null)"
expect "control_port 8080 (headscale's own) is refused -> 7443" "${URL}" \
    "$(run_mc '{"mesh":{"magic_dns_domain":"acme.internal","control_transport":"onion","control_port":8080,"control_onion":"'"${ONION}"'"}}' resolve_control_endpoint 2>/dev/null)"
# lan+onion degrades to lan, loudly
expect "lan+onion: a control name INSIDE the MagicDNS domain keeps the node on lan" "https://192.168.1.10:8080" \
    "$(run_mc '{"mesh":{"magic_dns_domain":"acme.internal","pki_lan_ip":"192.168.1.10","control_transport":"lan+onion","control_name":"hs.acme.internal","control_onion":"'"${ONION}"'"}}' resolve_control_endpoint 2>/dev/null)"
run_mc '{"mesh":{"magic_dns_domain":"acme.internal","control_transport":"lan+onion","control_name":"hs.acme.internal","control_onion":"'"${ONION}"'"}}' resolve_mesh_control_name > "${WORK}/clash.out" 2>&1
grep -a -F "contains the MagicDNS domain 'acme.internal'" "${WORK}/clash.out" >/dev/null \
    && ok "the refusal says why (a sentence naming the MagicDNS domain)" || bad "the clash refusal gave no reason: $(cat "${WORK}/clash.out")"
expect "lan+onion: no tor keeps the node on lan" "https://192.168.1.10:8080" "$(STUB_TOR=0 run_mc "${W}" resolve_control_endpoint 2>/dev/null)"
expect "lan+onion: no socat keeps the node on lan" "https://192.168.1.10:8080" "$(STUB_SOCAT=0 run_mc "${W}" resolve_control_endpoint 2>/dev/null)"
expect "a bogus transport keeps the node on lan" "https://192.168.1.10:8080" \
    "$(run_mc '{"mesh":{"magic_dns_domain":"acme.internal","pki_lan_ip":"192.168.1.10","control_transport":"tor","control_onion":"'"${ONION}"'"}}' resolve_control_endpoint 2>/dev/null)"
# Tor only FAILS CLOSED — every reason
expect "Tor only, no tor: NO endpoint (not the LAN)" "" "$(STUB_TOR=0 run_mc "${WO}" resolve_control_endpoint 2>/dev/null)"
expect "Tor only, no socat: NO endpoint" "" "$(STUB_SOCAT=0 run_mc "${WO}" resolve_control_endpoint 2>/dev/null)"
expect "Tor only, a malformed onion: NO endpoint" "" \
    "$(run_mc '{"mesh":{"magic_dns_domain":"acme.internal","pki_lan_ip":"192.168.1.10","control_transport":"onion","control_onion":"bad.onion"},"nodes":[{"ip":"10.0.0.10","role":"pki"}]}' resolve_control_endpoint 2>/dev/null)"
expect "Tor only, a malformed name: NO endpoint" "" \
    "$(run_mc '{"mesh":{"magic_dns_domain":"acme.internal","pki_lan_ip":"192.168.1.10","control_transport":"onion","control_name":"x.onion","control_onion":"'"${ONION}"'"},"nodes":[{"ip":"10.0.0.10","role":"pki"}]}' resolve_control_endpoint 2>/dev/null)"
expect "Tor only, a name inside the MagicDNS domain: NO endpoint" "" \
    "$(run_mc '{"mesh":{"magic_dns_domain":"acme.internal","pki_lan_ip":"192.168.1.10","control_transport":"onion","control_name":"hs.acme.internal","control_onion":"'"${ONION}"'"},"nodes":[{"ip":"10.0.0.10","role":"pki"}]}' resolve_control_endpoint 2>/dev/null)"
expect "Tor only, no tor, but an explicit .mesh.endpoint: the operator's override wins" "https://explicit.example" \
    "$(STUB_TOR=0 run_mc '{"mesh":{"magic_dns_domain":"acme.internal","endpoint":"https://explicit.example","control_transport":"onion","control_onion":"'"${ONION}"'"}}' resolve_control_endpoint 2>/dev/null)"
mkdir -p "${SB}/etc/hugmesh"; echo onion > "${SB}/etc/hugmesh/mesh-control-transport"
expect "the builder-baked transport applies when the stick names none" "${URL}" \
    "$(run_mc '{"mesh":{"magic_dns_domain":"acme.internal","control_onion":"'"${ONION}"'"}}' resolve_control_endpoint 2>/dev/null)"
# provision_tailscale — run for real: never `tailscale up` when Tor only cannot run
ts_run() {  # ts_run <manifest-json> [VAR=value...]: one real provision_tailscale run -> stub.log, ts.out
    printf '%s\n' "$1" > "${WORK}/m.json"; shift
    rm -rf "${SB}"; mkdir -p "${SB}/keys/tailscale"; echo "tskey-test" > "${SB}/keys/tailscale/authkey"; : > "${WORK}/stub.log"
    env $(sbenv) BASE="${SB}/keys" STUB_LOG="${WORK}/stub.log" PATH="${WORK}/bin:${PATH}" \
        HUGMESH_RELEASE_STATE_FILE="${WORK}/no-rs" HUGMESH_GO_LIVE_MARKER="${WORK}/no-gl" MANIFEST="${WORK}/m.json" "$@" \
        bash -c '. "$1"
            sleep() { :; }; control_url_tls_migrate() { CONTROL_URL="$1"; }; resolve_ssh_user() { echo admin; }
            control_self_login_server() { echo https://127.0.0.1:8080; }
            provision_tailscale' _ "${WORK}/mc.sh" > "${WORK}/ts.out" 2>&1
}
TSW='{"tailscale":{"enabled":true},"mesh":{"magic_dns_domain":"acme.internal","pki_lan_ip":"192.168.1.10","control_transport":"onion","control_onion":"'"${ONION}"'"},"nodes":[{"ip":"10.0.0.10","role":"pki"}]}'
TSWL='{"tailscale":{"enabled":true},"mesh":{"magic_dns_domain":"acme.internal","pki_lan_ip":"192.168.1.10","control_transport":"lan+onion","control_onion":"'"${ONION}"'"},"nodes":[{"ip":"10.0.0.10","role":"pki"}]}'
ts_run "${TSW}" STUB_TOR=0
if ! grep -a -E '^tailscale up' "${WORK}/stub.log" >/dev/null && grep -a -x 'rc-update del tailscaled default' "${WORK}/stub.log" >/dev/null \
   && grep -a -F 'tailscaled is STOPPED' "${WORK}/ts.out" >/dev/null; then
    ok "provision_tailscale, Tor only without tor: NO 'tailscale up' at all, tailscaled stopped + out of the runlevel, and it says so"
else bad "provision_tailscale (Tor only, no tor) dialled or did not say so: $(tr '\n' '|' < "${WORK}/stub.log") / $(grep -a WARNING "${WORK}/ts.out" | head -2 | tr '\n' ' ')"; fi
ts_run "${TSW}"
grep -a -x -F "tailscale up --authkey tskey-test --timeout 120s --login-server ${URL} --ssh" "${WORK}/stub.log" >/dev/null \
    && ok "provision_tailscale, Tor only with tor + socat: 'tailscale up' on the control name" \
    || bad "provision_tailscale (Tor only, active): $(tr '\n' '|' < "${WORK}/stub.log")"
ts_run '{"tailscale":{"enabled":true,"login_server":"https://explicit.example"},"mesh":{"magic_dns_domain":"acme.internal","control_transport":"onion","control_onion":"'"${ONION}"'"}}' STUB_TOR=0
grep -a -F -- "--login-server https://explicit.example" "${WORK}/stub.log" >/dev/null \
    && ok "provision_tailscale, Tor only without tor but an explicit .tailscale.login_server: the operator's override runs" \
    || bad "an explicit login_server was blocked: $(tr '\n' '|' < "${WORK}/stub.log")"
ts_run "${TSWL}" STUB_TOR=0
grep -a -F -- "--login-server https://192.168.1.10:8080" "${WORK}/stub.log" >/dev/null \
    && ok "provision_tailscale, lan+onion without tor: degrades to the LAN (loudly), as documented" \
    || bad "lan+onion without tor: $(tr '\n' '|' < "${WORK}/stub.log")"
# provision_mesh_control on a worker
rm -rf "${SB}"; mkdir -p "${SB}/etc/conf.d"; printf '127.0.0.1 localhost\n' > "${SB}/etc/hosts"
printf 'PORT=41641\nexport HTTPS_PROXY=http://old:1\n' > "${SB}/etc/conf.d/tailscaled"
: > "${WORK}/stub.log"
run_mc "${W}" provision_mesh_control > "${WORK}/w.log" 2>&1
grep -a -x -F "127.77.0.1 hs.acme-control.internal # hugmesh-mesh-control" "${SB}/etc/hosts" >/dev/null \
    && [ "$(grep -c hugmesh-mesh-control "${SB}/etc/hosts")" = 1 ] && ok "worker: one managed hosts line -> 127.77.0.1" \
    || bad "worker hosts: $(tr '\n' '|' < "${SB}/etc/hosts")"
expect "worker: relay.conf (dial port 7443; the LAN upstream is headscale's 8080)" \
    "TRANSPORT=lan+onion|LISTEN=127.77.0.1:7443|LAN=192.168.1.10:8080|ONION=${ONION}:7443" \
    "$(grep -v '^#' "${SB}/etc/hugmesh/mesh-control/relay.conf" 2>/dev/null | paste -sd'|')"
expect "worker: relay.conf is root-only (0600)" "600" "$(stat -c %a "${SB}/etc/hugmesh/mesh-control/relay.conf" 2>/dev/null)"
expect "worker: Tor marker" "client" "$(cat "${SB}/etc/hugmesh/tor/mesh-control" 2>/dev/null)"
[ -e "${SB}/etc/hugmesh/tor/mesh-control-only" ] && ok "worker: tor service not selected -> mesh-control-only (no onion of its own)" \
    || bad "worker: mesh-control-only not written"
grep -a -x 'export TS_FORCE_NOISE_443=true' "${SB}/etc/conf.d/tailscaled" >/dev/null && ok "tailscaled: TS_FORCE_NOISE_443=true" \
    || bad "tailscaled conf.d has no TS_FORCE_NOISE_443"
grep -a -x 'export TS_NO_LOGS_NO_SUPPORT=true' "${SB}/etc/conf.d/tailscaled" >/dev/null \
    && ok "tailscaled: TS_NO_LOGS_NO_SUPPORT=true (no log upload, no bootstrap-DNS dials outside Tor)" \
    || bad "tailscaled conf.d has no TS_NO_LOGS_NO_SUPPORT"
grep -a -x 'rc_need="hugmesh-mesh-control-relay"' "${SB}/etc/conf.d/tailscaled" >/dev/null \
    && ok "tailscaled needs the relay (no control dial with nothing listening -> no clearnet bootstrap DNS)" \
    || bad "tailscaled conf.d does not make tailscaled need the relay"
grep -a -F 'PORT=41641' "${SB}/etc/conf.d/tailscaled" >/dev/null && ok "tailscaled conf.d keeps what was there" || bad "the conf.d rewrite lost an operator line"
grep -a -E '^(export )?(HTTPS?|ALL)_PROXY=' "${SB}/etc/conf.d/tailscaled" | grep -v 'old:1' >/dev/null \
    && bad "a proxy variable was written for tailscaled" || ok "no proxy variable is written for tailscaled"
grep -a -E 'rc-update add hugmesh-mesh-control-relay default' "${WORK}/stub.log" >/dev/null \
    && grep -a -E 'rc-update add hugmesh-mesh-control-keeper default' "${WORK}/stub.log" >/dev/null \
    && grep -a -E 'rc-update add tor default' "${WORK}/stub.log" >/dev/null \
    && ok "worker: relay, keeper and tor linked" || bad "worker links: $(tr '\n' '|' < "${WORK}/stub.log")"
grep -a -F "${ONION%.onion}" "${WORK}/w.log" >/dev/null && bad "keys-provision logged the whole onion address" \
    || ok "keys-provision never logs the whole onion address"
run_mc "${W}" provision_mesh_control >/dev/null 2>&1
[ "$(grep -c hugmesh-mesh-control "${SB}/etc/hosts")" = 1 ] && [ "$(grep -c 'hugmesh-mesh-control (' "${SB}/etc/conf.d/tailscaled")" = 1 ] \
    && ok "a second run is idempotent" || bad "a second run duplicated the managed lines"
run_mc '{"mesh":{"control_transport":"lan"}}' provision_mesh_control >/dev/null 2>&1
! grep -q hugmesh-mesh-control "${SB}/etc/hosts" && ! grep -q TS_FORCE_NOISE_443 "${SB}/etc/conf.d/tailscaled" \
    && [ ! -e "${SB}/etc/hugmesh/mesh-control/relay.conf" ] && ok "back to lan: the hosts line, the env and relay.conf are removed" \
    || bad "back to lan left mesh-control state behind"
# Tor only, blocked: nothing configured, but tailscaled keeps its no-log block
rm -rf "${SB}"; mkdir -p "${SB}/etc"; printf '127.0.0.1 localhost\n' > "${SB}/etc/hosts"
STUB_TOR=0 run_mc "${WO}" provision_mesh_control > "${WORK}/blk.log" 2>&1
[ "$(cat "${SB}/etc/hosts")" = "127.0.0.1 localhost" ] && [ ! -e "${SB}/etc/hugmesh/mesh-control/relay.conf" ] \
    && grep -a -x 'export TS_NO_LOGS_NO_SUPPORT=true' "${SB}/etc/conf.d/tailscaled" >/dev/null 2>&1 \
    && ! grep -a -q '^rc_need=' "${SB}/etc/conf.d/tailscaled" && grep -a -q '^# <<< hugmesh-mesh-control' "${SB}/etc/conf.d/tailscaled" \
    && ok "Tor only, blocked: no hosts line, no relay, tailscaled keeps no-log-upload (and no rc_need on a relay that is not there)" \
    || bad "Tor only, blocked: $(find "${SB}" -type f | tr '\n' ' ')"
# provision_mesh_control on the pki
rm -rf "${SB}"; mkdir -p "${SB}/etc" "${SB}/keys/headscale/control-onion"; printf '127.0.0.1 localhost\n' > "${SB}/etc/hosts"
printf '%s\n' "${ONION}" > "${SB}/keys/headscale/control-onion/hostname"
head -c 96 /dev/urandom > "${SB}/keys/headscale/control-onion/hs_ed25519_secret_key"
: > "${WORK}/stub.log"
run_mc "${P_}" provision_mesh_control > "${WORK}/p.log" 2>&1
grep -a -F "${ONION%.onion}" "${WORK}/p.log" >/dev/null && bad "keys-provision logged the whole onion address on the pki" \
    || ok "keys-provision on the pki logs only the onion's first 8 characters"
[ -s "${SB}/var/lib/tor/hugmesh-control/hs_ed25519_secret_key" ] \
    && [ "$(stat -c %a "${SB}/var/lib/tor/hugmesh-control/hs_ed25519_secret_key")" = 600 ] \
    && [ "$(stat -c %a "${SB}/var/lib/tor/hugmesh-control")" = 700 ] && ok "pki: the control onion key is installed 0600 in a 0700 dir" \
    || bad "pki: key not installed as expected"
expect "pki: Tor marker (the onion's 7443 -> headscale's own 8080)" "control 7443 8080" "$(cat "${SB}/etc/hugmesh/tor/mesh-control" 2>/dev/null)"
expect "pki: relay.conf is the LOCAL forward 127.77.0.1:7443 -> headscale 127.0.0.1:8080" \
    "TRANSPORT=local|LISTEN=127.77.0.1:7443|LAN=127.0.0.1:8080" \
    "$(grep -v '^#' "${SB}/etc/hugmesh/mesh-control/relay.conf" 2>/dev/null | paste -sd'|')"
grep -a -E 'rc-update add hugmesh-mesh-control-relay default' "${WORK}/stub.log" >/dev/null \
    && ! grep -a -E 'hugmesh-mesh-control-keeper' "${WORK}/stub.log" >/dev/null \
    && ok "pki: the relay (forward) is linked, the keeper is not" || bad "pki links: $(tr '\n' '|' < "${WORK}/stub.log")"
rm -rf "${SB}/var"; printf '%s\n' "${ONION2}" > "${SB}/keys/headscale/control-onion/hostname"
run_mc "${P_}" provision_mesh_control > "${WORK}/p2.log" 2>&1
[ ! -e "${SB}/var/lib/tor/hugmesh-control/hs_ed25519_secret_key" ] && grep -a -F 'NOT installed' "${WORK}/p2.log" >/dev/null \
    && ok "pki: a key whose hostname is not the sticks' onion is refused, loudly" || bad "pki installed a mismatched onion key"
# The TLS passthrough: the pki's headscale serves TLS itself behind the 7443 forward
expect "TLS passthrough: the control name on 7443" "yes" "$(run_mc "${P_}" 'mesh_control_tls_passthrough hs.acme-control.internal 7443 && echo yes || echo no' 2>/dev/null)"
expect "TLS passthrough: not another port" "no" "$(run_mc "${P_}" 'mesh_control_tls_passthrough hs.acme-control.internal 443 && echo yes || echo no' 2>/dev/null)"
expect "TLS passthrough: not on lan" "no" "$(run_mc '{"headscale":{"enabled":true},"mesh":{"magic_dns_domain":"acme.internal"}}' 'mesh_control_tls_passthrough hs.acme-control.internal 7443 && echo yes || echo no' 2>/dev/null)"
grep -a -F '! mesh_control_tls_passthrough "${host}" "${port}"' "${PROV}" >/dev/null \
    && ok "provision_headscale_tls keeps headscale's own TLS behind the control relay" \
    || bad "provision_headscale_tls has no passthrough exception (headscale would go plain HTTP behind 7443)"
# OIDC: OFF in a Tor mode, run for real against a config like the KEYS one
awk '/^provision_headscale\(\) \{/{f=1} f; f&&/^}/{exit}' "${PROV}" > "${WORK}/ph.sh"
awk '/mesh_control_oidc_off \/etc\/headscale\/config.yaml/{b=NR} /provision_headscale_config \/etc\/headscale\/config.yaml/{c=NR} END{exit !(c && b && b > c)}' "${WORK}/ph.sh" \
    && ok "provision_headscale removes OIDC AFTER the KEYS config is installed" \
    || bad "provision_headscale does not call mesh_control_oidc_off after installing the config"
printf 'server_url: x\noidc:\n  only_start_if_oidc_is_available: false\n  # a comment\n  issuer: "http://casdoor.hugmesh-pki.svc.cluster.local:8000"\n  client_id: a\n\n# next section\nlog:\n  level: info\n' > "${WORK}/hs-oidc.yaml"
cp "${WORK}/hs-oidc.yaml" "${WORK}/hs-oidc-lan.yaml"; cp "${WORK}/hs-oidc.yaml" "${WORK}/hs-oidc-worker.yaml"
run_mc "${P_}" mesh_control_oidc_off "${WORK}/hs-oidc.yaml" > "${WORK}/oidc.log" 2>&1
! grep -a -E '^oidc:|issuer:|client_id:' "${WORK}/hs-oidc.yaml" >/dev/null && grep -a -x 'log:' "${WORK}/hs-oidc.yaml" >/dev/null \
    && grep -a -x '  level: info' "${WORK}/hs-oidc.yaml" >/dev/null && grep -a -x 'server_url: x' "${WORK}/hs-oidc.yaml" >/dev/null \
    && ok "pki + Tor: the oidc block is removed, everything else kept (pre-auth keys only)" \
    || bad "the oidc block was not removed cleanly: $(tr '\n' '|' < "${WORK}/hs-oidc.yaml")"
run_mc '{"headscale":{"enabled":true},"mesh":{"control_transport":"lan"}}' mesh_control_oidc_off "${WORK}/hs-oidc-lan.yaml" >/dev/null 2>&1
cmp -s "${WORK}/hs-oidc-lan.yaml" "${WORK}/hs-oidc-worker.yaml" && ok "lan: the oidc block stays (OIDC as today)" || bad "lan lost its oidc block"
for f in "${ROOT}/specs/usr/sbin/hugmesh-headscale-oidc-defer" "${ROOT}/specs/etc/cron.d/hugmesh-headscale-oidc-defer"; do
    [ ! -e "${f}" ] && ok "no OIDC switch-on job ships (${f#"${ROOT}"/})" || bad "${f#"${ROOT}"/} still ships (it would switch OIDC on with a redirect Casdoor does not register)"
done

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
rconf TRANSPORT=lan+onion LISTEN=127.77.0.1:7443 LAN=192.168.1.10:8080 "ONION=${ONION}:7443"
rm -f "${RS}/lan-ok"; relay upstream
grep -a -F "socat STDIO SOCKS4A:127.0.0.1:${ONION}:7443,socksport=9050,socksuser=hugmesh-control" "${WORK}/socat.log" >/dev/null \
    && ok "no lan-ok: the onion, through Tor SOCKS on the one isolation user" || bad "upstream without lan-ok: $(cat "${WORK}/socat.log")"
touch "${RS}/lan-ok"; relay upstream
grep -a -F "socat STDIO TCP:192.168.1.10:8080,connect-timeout=3" "${WORK}/socat.log" >/dev/null \
    && ok "fresh lan-ok: the pki on the LAN (headscale's 8080)" || bad "upstream with lan-ok: $(cat "${WORK}/socat.log")"
touch -d '5 minutes ago' "${RS}/lan-ok"; relay upstream
grep -a -F "SOCKS4A:" "${WORK}/socat.log" >/dev/null && ok "a stale lan-ok is not trusted (the onion)" || bad "a stale lan-ok was trusted"
rconf TRANSPORT=onion LISTEN=127.77.0.1:7443 LAN=192.168.1.10:8080 "ONION=${ONION}:7443"
touch "${RS}/lan-ok"; relay upstream
grep -a -F "SOCKS4A:" "${WORK}/socat.log" >/dev/null && ok "transport onion never takes the LAN" || bad "transport onion took the LAN"
relay listen
grep -a -F "socat TCP-LISTEN:7443,bind=127.77.0.1,fork,reuseaddr EXEC:/usr/sbin/hugmesh-mesh-control-relay upstream" "${WORK}/socat.log" >/dev/null \
    && ok "listen: socat on 127.77.0.1:7443, one upstream per connection" || bad "listen: $(cat "${WORK}/socat.log")"
grep -a -F "${ONION%.onion}" "${WORK}/relay.out" >/dev/null && bad "the relay logged the whole onion address: $(head -1 "${WORK}/relay.out")" \
    || ok "the relay's log line carries only the onion's first 8 characters"
relay status
grep -a -F "${ONION%.onion}" "${WORK}/relay.out" >/dev/null && bad "status printed the whole onion address" || ok "status prints only the onion's first 8 characters"
# the pki's local forward
rconf TRANSPORT=local LISTEN=127.77.0.1:7443 LAN=127.0.0.1:8080
rm -f "${RS}/lan-ok"; relay upstream
grep -a -F "socat STDIO TCP:127.0.0.1:8080,connect-timeout=3" "${WORK}/socat.log" >/dev/null && ! grep -a -F SOCKS4A "${WORK}/socat.log" >/dev/null \
    && ok "local (the pki): always headscale's own listener, never Tor, no lan-ok needed" || bad "local upstream: $(cat "${WORK}/socat.log")"
relay keeper
[ ! -s "${WORK}/socat.log" ] && ok "local: the keeper dials nothing" || bad "local keeper dialled: $(cat "${WORK}/socat.log")"
for badline in "LAN=evil.example:8080" "ONION=short.onion:7443" "LISTEN=0.0.0.0" "TRANSPORT=lan" "ISOLATION=a b" "EXTRA=1"; do
    rconf TRANSPORT=lan+onion LISTEN=127.77.0.1:7443 "ONION=${ONION}:7443" "${badline}"
    if relay upstream; then bad "relay accepted '${badline}'"; else
        [ ! -s "${WORK}/socat.log" ] && ok "relay refuses '${badline}' before dialling anything" || bad "relay dialled with '${badline}'"; fi
done
rconf TRANSPORT=local LISTEN=127.77.0.1:7443
if relay upstream; then bad "relay accepted TRANSPORT=local with no LAN"; else
    [ ! -s "${WORK}/socat.log" ] && ok "relay refuses TRANSPORT=local without headscale's address" || bad "local without LAN dialled"; fi
rconf TRANSPORT=lan+onion LISTEN=127.77.0.1:7443 LAN=192.168.1.10:8080 "ONION=${ONION}:7443" "TOR_CONTROL=${WORK}/ctl.sock" "TOR_COOKIE=${WORK}/cookie"
printf '0123456789abcdef0123456789abcdef' > "${WORK}/cookie"
rm -f "${RS}/lan-ok"; STUB_LAN_UP=1 STUB_ONION_UP=1 relay keeper
[ -e "${RS}/lan-ok" ] && grep -a -F 'lan=ok onion=ok' "${RS}/status" >/dev/null && ok "keeper: LAN up -> lan-ok; onion warm" || bad "keeper (all up): $(cat "${RS}/status" 2>/dev/null)"
STUB_LAN_UP=0 STUB_ONION_UP=0 relay keeper
[ ! -e "${RS}/lan-ok" ] && ok "keeper: LAN down -> lan-ok removed" || bad "keeper kept lan-ok with the LAN down"
rm -f "${WORK}/socat.log.ctl"
# The keeper loops forever: run it in the background and stop it once NEWNYM was sent
# (bounded at 60 s — a fixed 5 s window flaked on a loaded host).
env PATH="${RB}:${PATH}" SOCAT_LOG="${WORK}/socat.log" HUGMESH_MESH_CONTROL_CONF="${WORK}/relay.conf" HUGMESH_MESH_CONTROL_STATE="${RS}" \
    HUGMESH_MESH_CONTROL_KEEPER_INTERVAL=0 HUGMESH_MESH_CONTROL_NEWNYM_AFTER=2 STUB_ONION_UP=0 \
    timeout 60 bash "${RELAY}" keeper >/dev/null 2>&1 &
kp=$!
for _ in $(seq 1 300); do grep -a -q 'SIGNAL NEWNYM' "${WORK}/socat.log.ctl" 2>/dev/null && break; kill -0 "${kp}" 2>/dev/null || break; sleep 0.2; done
kill "${kp}" 2>/dev/null; wait "${kp}" 2>/dev/null
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
ctl="$(render 'control 7443 8080' 1)"
echo "${ctl}" | grep -a -q '^HiddenServiceDir /var/lib/tor/hugmesh-control$' && echo "${ctl}" | grep -a -q '^HiddenServicePort 7443 127.0.0.1:8080$' \
    && ! echo "${ctl}" | grep -a -q '^HiddenServiceDir /var/lib/tor/hugmesh-onion$' \
    && ok "pki (control, control-only): the control onion's 7443 -> headscale 127.0.0.1:8080, not the fe-gateway onion" || bad "control render: ${ctl}"
one="$(render 'control 9443' 1)"
echo "${one}" | grep -a -q '^HiddenServicePort 9443 127.0.0.1:9443$' && ok "a one-port marker maps the port onto itself" || bad "one-port render: ${one}"
both="$(render 'control 7443 8080' 0)"
echo "${both}" | grep -a -q '^HiddenServiceDir /var/lib/tor/hugmesh-onion$' && echo "${both}" | grep -a -q '^HiddenServiceDir /var/lib/tor/hugmesh-control$' \
    && ok "pki with the tor service selected: both onions" || bad "control + tor service render: ${both}"
for m in 'control 99999' 'control 7443 99999' 'control 7443 8080 1'; do
    junk="$(render "${m}" 1)"
    ! echo "${junk}" | grep -a -q 'hugmesh-control\|ControlSocket' && ok "a malformed marker ('${m}') adds nothing" || bad "malformed marker render ('${m}'): ${junk}"
done

# ── E. gen-provision-keys with a fixture key dir ─────────────────────────────
echo "-- E. gen-provision-keys.sh (fixture onion dir; the real mint is in the live test) --"
OD="${WORK}/onion"; mkdir -p -m 0700 "${OD}"; printf '%s\n' "${ONION}" > "${OD}/hostname"
head -c 96 /dev/urandom > "${OD}/hs_ed25519_secret_key"; head -c 64 /dev/urandom > "${OD}/hs_ed25519_public_key"
gk() { local out="$1"; shift; NONINTERACTIVE=1 BRAND=hugmesh bash "${GENKEYS}" --out "${out}" --random "$@" > "${out}.log" 2>&1; }
if gk "${WORK}/k-host" --role host --pki-ip 192.168.1.10 --mesh-control-transport lan+onion --mesh-control-onion-dir "${OD}"; then
    expect "worker stick: .mesh.control_* with the DERIVED name outside the superdomain" "lan+onion hs.hugmesh-control.internal ${ONION} hugmesh.internal" \
        "$(jq -r '[.mesh.control_transport, .mesh.control_name, .mesh.control_onion, .mesh.magic_dns_domain] | join(" ")' "${WORK}/k-host/provision.json")"
    [ -z "$(find "${WORK}/k-host" -name 'hs_ed25519_*')" ] && ok "worker stick: no onion key at all" || bad "a worker stick carries onion key material"
    grep -a -F "${ONION%.onion}" "${WORK}/k-host.log" >/dev/null && bad "gen-provision-keys printed the whole onion address" \
        || ok "gen-provision-keys prints only the onion's first 8 characters"
else bad "gen-provision-keys host (Tor) failed: $(tail -2 "${WORK}/k-host.log" | tr '\n' ' ')"; fi
if gk "${WORK}/k-pki" --role pki --pki-ip 192.168.1.10 --mesh-control-transport lan+onion --mesh-control-onion-dir "${OD}" --mesh-control-name ctl.acme-ops.example; then
    cmp -s "${OD}/hs_ed25519_secret_key" "${WORK}/k-pki/headscale/control-onion/hs_ed25519_secret_key" \
        && [ "$(stat -c %a "${WORK}/k-pki/headscale/control-onion/hs_ed25519_secret_key")" = 600 ] \
        && ok "pki stick: the control onion key, 0600" || bad "pki stick: key missing or not 0600"
    expect "pki stick: the custom name" "ctl.acme-ops.example" "$(jq -r .mesh.control_name "${WORK}/k-pki/provision.json")"
else bad "gen-provision-keys pki (Tor) failed: $(tail -2 "${WORK}/k-pki.log" | tr '\n' ' ')"; fi
if gk "${WORK}/k-lan" --role host --pki-ip 192.168.1.10; then
    expect "lan stick: no .mesh.control_* keys" "0" "$(jq '[.mesh | keys[] | select(startswith("control_"))] | length' "${WORK}/k-lan/provision.json")"
else bad "gen-provision-keys lan failed"; fi
# parity: the name gen-provision-keys stamps == keys-provision's == the Studio's
for sd in hugmesh.internal acme.example a.b.c; do
    if gk "${WORK}/k-sd" --role host --superdomain "${sd}" --mesh-control-transport onion --mesh-control-onion-dir "${OD}"; then
        g="$(jq -r .mesh.control_name "${WORK}/k-sd/provision.json")"
        b="$(run_mc '{}' mesh_control_default_name "${sd}" 2>/dev/null)"
        p="$(PYTHONPATH="${ROOT}/studio" python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from hugmesh_studio.core.mesh_control import control_name; print(control_name(sys.argv[2]))' "${ROOT}/studio" "${sd}" 2>&1)"
        [ "${g}" = "${b}" ] && [ "${g}" = "${p}" ] && ok "one derivation for ${sd}: ${g} (gen-provision-keys = keys-provision = Studio)" \
            || bad "the derivations disagree for ${sd}: gen-provision-keys '${g}', keys-provision '${b}', Studio '${p}'"
    else bad "gen-provision-keys --superdomain ${sd} failed: $(grep -a ERROR "${WORK}/k-sd.log" | head -1)"; fi
    rm -rf "${WORK}/k-sd" "${WORK}/k-sd.log"
done
refuse() {  # refuse <label> <reason (fixed string the refusal must give)> <args...>
    local l="$1" why="$2"; shift 2
    # The REASON is asserted, not just a non-zero exit: on a host without tor a run that
    # skipped the consent check still fails (it cannot mint), for a different reason.
    if gk "${WORK}/k-no" "$@"; then bad "accepted: ${l}"
    elif [ -e "${WORK}/k-no" ]; then bad "refused only after building: ${l}"
    elif ! grep -a -F -- "${why}" "${WORK}/k-no.log" >/dev/null; then bad "refused for another reason: ${l} ($(grep -a ERROR "${WORK}/k-no.log" | head -1))"
    else ok "refused before anything is built: ${l}"; fi
    rm -rf "${WORK}/k-no" "${WORK}/k-no.log"
}
refuse "a Tor transport without --mesh-control-onion-dir" "needs --mesh-control-onion-dir" --role host --pki-ip 192.168.1.10 --mesh-control-transport onion
refuse "lan+onion without --pki-ip" "lan+onion needs --pki-ip" --role host --mesh-control-transport lan+onion --mesh-control-onion-dir "${OD}"
refuse "an empty onion dir without the mint consent" "Pass --mesh-control-onion-mint" --role host --mesh-control-transport onion --mesh-control-onion-dir "${WORK}/empty"
refuse "an .onion as the control name" "is not a dotted DNS name" --role host --mesh-control-transport onion --mesh-control-onion-dir "${OD}" --mesh-control-name "${ONION}"
refuse "a control name INSIDE the superdomain (hs.hugmesh.internal)" "contains the superdomain 'hugmesh.internal', and headscale refuses to start" \
    --role host --mesh-control-transport onion --mesh-control-onion-dir "${OD}" --mesh-control-name hs.hugmesh.internal
refuse "a control name containing the superdomain as a SUBSTRING (hs.hugmesh.internal under mesh.internal)" "contains the superdomain 'mesh.internal'" \
    --role host --superdomain mesh.internal --mesh-control-transport onion --mesh-control-onion-dir "${OD}" --mesh-control-name hs.hugmesh.internal
refuse "a superdomain whose DERIVED name still contains it (control.internal)" "the default control name 'hs.control-control.internal' still contains the superdomain" \
    --role host --superdomain control.internal --mesh-control-transport onion --mesh-control-onion-dir "${OD}"
refuse "an unknown transport" "must be lan, lan+onion or onion" --role host --mesh-control-transport tor
mkdir -p "${WORK}/nohost"; head -c 96 /dev/urandom > "${WORK}/nohost/hs_ed25519_secret_key"
refuse "minting over an existing secret key" "refusing to mint over it" --role host --mesh-control-transport onion --mesh-control-onion-dir "${WORK}/nohost" --mesh-control-onion-mint
cp -r "${OD}" "${WORK}/gone"; rm -f "${WORK}/gone/hs_ed25519_secret_key"
gk "${WORK}/k-gone" --role pki --pki-ip 192.168.1.10 --mesh-control-transport onion --mesh-control-onion-dir "${WORK}/gone" \
    && bad "a pki stick was made without the secret key" || ok "a pki stick whose secret key was removed is refused (re-mint, re-make every stick)"
grep -a -F 'find "${OUT_DIR}" -name '"'"'hs_ed25519_secret_key'"'" "${GENKEYS}" >/dev/null && ok "the placement guard looks for an onion secret key on non-pki sticks" \
    || bad "no placement guard for onion keys"
# The mint against a stub tor that writes the key and then DIES ON SIGTERM (exit 143),
# as real tor does when the signal lands before its handlers are installed: the run
# must succeed on the files, not abort on tor's status.
TB="${WORK}/torbin"; mkdir -p "${TB}"
cat > "${TB}/tor" <<EOF
#!/bin/bash
d=""; while [ \$# -gt 0 ]; do [ "\$1" = --HiddenServiceDir ] && d="\$2"; shift; done
[ -n "\${d}" ] || exit 1
head -c 96 /dev/urandom > "\${d}/hs_ed25519_secret_key"; head -c 64 /dev/urandom > "\${d}/hs_ed25519_public_key"
printf '%s\n' "${ONION2}" > "\${d}/hostname"
echo \$\$ > "${WORK}/stub-tor.pid"     # exec keeps the PID
exec sleep 60
EOF
chmod +x "${TB}/tor"
if PATH="${TB}:${PATH}" gk "${WORK}/k-mint" --role host --mesh-control-transport onion --mesh-control-onion-dir "${WORK}/mint" --mesh-control-onion-mint; then
    expect "the mint survives tor's exit 143 and stamps the minted onion" "${ONION2}" "$(jq -r .mesh.control_onion "${WORK}/k-mint/provision.json")"
else bad "the mint aborted on tor's exit status (rc $?): $(tail -2 "${WORK}/k-mint.log" | tr '\n' ' ')"; fi
if [ ! -s "${WORK}/stub-tor.pid" ]; then bad "the stub tor never ran (no pid file)"
elif kill -0 "$(cat "${WORK}/stub-tor.pid")" 2>/dev/null; then bad "the stub tor was left running"; kill "$(cat "${WORK}/stub-tor.pid")" 2>/dev/null
else ok "the minting tor is stopped and reaped"; fi
# build-all-roles: the secret leaves this computer only on positive evidence
awk '/^mesh_control_forget_secret\(\) \{/{f=1} f; f&&/^}/{exit}' "${BAR}" > "${WORK}/forget.sh"
if grep -a -q '^mesh_control_forget_secret() {' "${WORK}/forget.sh"; then
    forget() {  # forget <case> [SKIP_KEYS] -> "kept" | "removed"
        local wd="${WORK}/bar-$1" d="${WORK}/bar-$1/mesh-control-onion"
        rm -rf "${wd}"; mkdir -p "${d}"; printf '%s\n' "${ONION}" > "${d}/hostname"; printf 'SECRET-%s' "$1" > "${d}/hs_ed25519_secret_key"
        case "$1" in
            held)  mkdir -p "${wd}/keys-pki/headscale/control-onion"; cp "${d}/hs_ed25519_secret_key" "${wd}/keys-pki/headscale/control-onion/" ;;
            other) mkdir -p "${wd}/keys-pki/headscale/control-onion"; printf 'OTHER' > "${wd}/keys-pki/headscale/control-onion/hs_ed25519_secret_key" ;;
            skip)  mkdir -p "${wd}/keys-pki/headscale/control-onion"; cp "${d}/hs_ed25519_secret_key" "${wd}/keys-pki/headscale/control-onion/" ;;
        esac
        WORK_DIR="${wd}" MESH_CONTROL_ONION_DIR="${d}" SKIP_KEYS="${2:-0}" bash -c '. "$1"; KEYS_FAILED=(); mesh_control_forget_secret' _ "${WORK}/forget.sh" >/dev/null 2>&1
        [ -e "${d}/hs_ed25519_secret_key" ] && echo kept || echo removed
    }
    expect "build-all-roles: no stick holds the key (the pki keys run failed) -> kept" kept "$(forget none)"
    expect "build-all-roles: a stick holds a DIFFERENT key -> kept" kept "$(forget other)"
    expect "build-all-roles: SKIP_KEYS=1 -> kept" kept "$(forget skip 1)"
    expect "build-all-roles: the pki stick holds an identical copy -> removed" removed "$(forget held)"
else bad "build-all-roles has no mesh_control_forget_secret (the secret is removed without evidence)"; fi

# ── F. builder parity ────────────────────────────────────────────────────────
echo "-- F. --mesh-control-transport on every builder --"
nb=0
for b in "${ROOT}"/build-*-stage4.sh; do
    nb=$((nb + 1)); n="$(basename "${b}")"; miss=""
    grep -a -F -- '--mesh-control-transport) MESH_CONTROL_TRANSPORT="$2"; shift 2 ;;' "${b}" >/dev/null || miss="${miss} parse"
    grep -a -F 'MESH_CONTROL_TRANSPORT="${MESH_CONTROL_TRANSPORT:-lan}"' "${b}" >/dev/null || miss="${miss} default"
    grep -a -E '^ +--mesh-control-transport( |$)' "${b}" >/dev/null || miss="${miss} usage"
    grep -a -F 'hugmesh-headscale-oidc-defer' "${b}" >/dev/null && miss="${miss} oidc-defer-still-baked"
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
for f in specs/usr/sbin/hugmesh-mesh-control-relay specs/etc/init.d/hugmesh-mesh-control-relay specs/etc/init.d/hugmesh-mesh-control-keeper; do
    [ -x "${ROOT}/${f}" ] && ok "${f} ships executable" || bad "${f} missing or not executable"
done
if grep -a -n -E '(HTTPS?|ALL)_PROXY' "${PROV}" "${RELAY}" | grep -a -v -E '^\S+:[0-9]+:\s*#' | grep -a -v 'no proxy variable' >/dev/null; then
    bad "a proxy variable is set somewhere on the mesh-control path: $(grep -a -n -E '(HTTPS?|ALL)_PROXY' "${PROV}" "${RELAY}" | grep -a -v -E ':\s*#' | head -2 | tr '\n' ' ')"
else ok "no proxy variable anywhere on the mesh-control path (keys-provision, relay)"; fi
# the Studio refuses a superdomain the control name cannot be derived from
if PYTHONPATH="${ROOT}/studio" python3 -I - "${ROOT}/studio" > "${WORK}/py2.out" 2>&1 <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from hugmesh_studio.core import mesh_control as m
from hugmesh_studio.core.config import ImageConfig
bad = ImageConfig(mode="mesh", superdomain="control.internal", mesh_control_transport="onion")
assert "headscale refuses to start" in m.name_problem(bad), m.name_problem(bad)
assert m.name_problem(ImageConfig(mode="mesh", superdomain="hugmesh.internal", mesh_control_transport="onion")) == ""
assert m.name_problem(ImageConfig(mode="mesh", superdomain="control.internal")) == ""     # lan: nothing
assert m.CONTROL_PORT == 7443
print("ok")
PY
then ok "Studio: a Tor transport with a superdomain the control name cannot leave is refused with a sentence"
else bad "Studio name_problem: $(tail -2 "${WORK}/py2.out" | tr '\n' ' ')"; fi

# ── G. negative controls ─────────────────────────────────────────────────────
if [ -z "${MCO_GUARD_NO_CONTROLS:-}" ]; then
    echo "-- G. negative controls: each mutation must turn the guard red --"
    mktree() {
        local d="$1" f
        mkdir -p "${d}/specs/etc/keys-provision" "${d}/specs/usr/sbin" "${d}/specs/etc/init.d" "${d}/specs/etc/cron.d" "${d}/studio"
        cp -p "${REPO}/specs/etc/keys-provision/provision.sh" "${d}/specs/etc/keys-provision/" || return 1
        for f in hugmesh-mesh-control-relay hugmesh-tor-reconcile; do cp -p "${REPO}/specs/usr/sbin/${f}" "${d}/specs/usr/sbin/"; done
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
    CTLS="${WORK}/controls"; mkdir -p "${CTLS}"; n=0
    control() {  # control <label> <file> <old> <new> — queued; run as a bounded parallel pool below
        n=$((n + 1)); printf '%s\0%s\0%s\0%s\0' "$1" "$2" "$3" "$4" > "${CTLS}/${n}.spec"
    }
    run_control() {  # run_control <n>
        local spec="${CTLS}/$1.spec" d="${WORK}/ctl-$1" label file old new
        { IFS= read -r -d '' label; IFS= read -r -d '' file; IFS= read -r -d '' old; IFS= read -r -d '' new; } < "${spec}"
        mktree "${d}" || { echo "FAIL control '${label}': could not build the tree" > "${CTLS}/$1.res"; return; }
        if ! python3 - "${d}/${file}" "${old}" "${new}" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(p, encoding="utf-8").read()
if t.count(old) < 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(t.replace(old, new, 1))
PY
        then echo "FAIL control '${label}': anchor not found in ${file} (stale)" > "${CTLS}/$1.res"; rm -rf "${d}"; return; fi
        if child "${d}" > "${d}.log"; then echo "FAIL control '${label}' did NOT bite" > "${CTLS}/$1.res"
        else echo "PASS control bites: ${label}  [red on: $(grep -a 'FAIL' "${d}.log" | head -1 | sed 's/^ *FAIL //' | cut -c1-100)]" > "${CTLS}/$1.res"; fi
        rm -rf "${d}" "${d}.log"
    }
    control "the worker resolver ignores the stable name" specs/etc/keys-provision/provision.sh \
        '    if { [ -z "${ep}" ] || [ "${ep}" = "null" ]; } && mesh_control_active; then
        ep="$(mesh_control_url)"' '    if false; then
        ep="$(mesh_control_url)"'
    control "the pki server_url ignores the stable name" specs/etc/keys-provision/provision.sh \
        'if { [ -z "${ep}" ] || [ "${ep}" = "null" ]; } && mesh_control_active; then ep="$(mesh_control_url)"; fi' ':'
    control "the default control name is hs.<superdomain> again (inside base_domain)" specs/etc/keys-provision/provision.sh \
        'echo "hs.${sd%%.*}-control.${sd#*.}"' 'echo "hs.${sd}"'
    control "keys-provision accepts a control name inside the MagicDNS domain" specs/etc/keys-provision/provision.sh \
        '    [ -n "$3" ] && [[ "https://$1:$2" == *"$3"* ]]' '    false'
    control "the clash check is a label suffix, not headscale's substring" specs/etc/keys-provision/provision.sh \
        '    [ -n "$3" ] && [[ "https://$1:$2" == *"$3"* ]]' '    [ -n "$3" ] && { [ "$1" = "$3" ] || [[ "$1" == *".$3" ]]; }'
    control "the control port is headscale's own 8080 again" specs/etc/keys-provision/provision.sh \
        'MESH_CONTROL_PORT_DEFAULT=7443' 'MESH_CONTROL_PORT_DEFAULT=8080'
    control "a missing tor is not checked" specs/etc/keys-provision/provision.sh '    if ! have tor; then' '    if false; then'
    control "Tor only falls back to the LAN (fails open)" specs/etc/keys-provision/provision.sh \
        '    [ "$(resolve_mesh_control_transport 2>/dev/null)" = onion ] || return 1' '    return 1'
    control "provision_tailscale runs tailscale up although Tor only cannot run" specs/etc/keys-provision/provision.sh \
        '            rc-update del tailscaled default 2>/dev/null || true
            return 0' '            rc-update del tailscaled default 2>/dev/null || true'
    control "headscale keeps OIDC in a Tor mode" specs/etc/keys-provision/provision.sh \
        '    mesh_control_oidc_off /etc/headscale/config.yaml' '    : mesh_control_oidc_off'
    control "provision_headscale_tls turns TLS off behind the control relay" specs/etc/keys-provision/provision.sh \
        ' && ! mesh_control_tls_passthrough "${host}" "${port}"; then' '; then'
    control "tailscaled uploads its logs (no TS_NO_LOGS_NO_SUPPORT)" specs/etc/keys-provision/provision.sh \
        'export TS_NO_LOGS_NO_SUPPORT=true' '# (removed)'
    control "tailscaled may start without the relay" specs/etc/keys-provision/provision.sh \
        'rc_need="hugmesh-mesh-control-relay"' '# (removed)'
    control "tailscaled gets an HTTPS_PROXY" specs/etc/keys-provision/provision.sh \
        'export TS_FORCE_NOISE_443=true' 'export TS_FORCE_NOISE_443=true
export HTTPS_PROXY=http://127.0.0.1:9080'
    control "the onion key is installed without the hostname check" specs/etc/keys-provision/provision.sh \
        '            if [ "${got}" != "${onion}" ]; then' '            if false; then'
    control "the pki gets no local forward to headscale" specs/etc/keys-provision/provision.sh \
        '            echo "TRANSPORT=local"' '            echo "TRANSPORT=onion"'
    control "keys-provision logs the whole onion" specs/etc/keys-provision/provision.sh \
        "mesh_control_onion_short() { printf '%s…' \"\${1:0:8}\"; }" "mesh_control_onion_short() { printf '%s' \"\${1}\"; }"
    control "the relay trusts any lan-ok age" specs/usr/sbin/hugmesh-mesh-control-relay \
        '    [ $((now - m)) -le "${LAN_OK_MAX_AGE}" ]' '    true'
    control "the relay drops the isolation user" specs/usr/sbin/hugmesh-mesh-control-relay \
        ',socksuser=${ISOLATION}"; }' '"; }'
    control "the relay's local transport dials the onion" specs/usr/sbin/hugmesh-mesh-control-relay \
        '    if [ "${TRANSPORT}" = local ]; then
        exec socat STDIO "TCP:${LAN},connect-timeout=3"' '    if false; then
        exec socat STDIO "TCP:${LAN},connect-timeout=3"'
    control "the relay logs the whole onion" specs/usr/sbin/hugmesh-mesh-control-relay \
        "printf '%s…' \"\${ONION:0:8}\"" "printf '%s' \"\${ONION}\""
    control "the keeper never sends NEWNYM" specs/usr/sbin/hugmesh-mesh-control-relay \
        '            if [ "${fails}" -ge "${NEWNYM_AFTER}" ]; then newnym; fails=0; fi' '            :'
    control "the reconcile publishes the fe-gateway onion from a client" specs/usr/sbin/hugmesh-tor-reconcile \
        '    ${MC_ONLY} || cat <<EOT' '    cat <<EOT'
    control "the reconcile maps the control port onto itself (nothing listens on 7443)" specs/usr/sbin/hugmesh-tor-reconcile \
        'HiddenServicePort ${MC_PORT} 127.0.0.1:${MC_TARGET}' 'HiddenServicePort ${MC_PORT} 127.0.0.1:${MC_PORT}'
    control "gen-provision-keys copies the onion key onto every stick" scripts/gen-provision-keys.sh \
        '    if [ "${ROLE}" = pki ]; then
        mkdir -p "${OUT_DIR}/headscale/control-onion"' '    if true; then
        mkdir -p "${OUT_DIR}/headscale/control-onion"'
    control "gen-provision-keys mints without consent" scripts/gen-provision-keys.sh \
        '        if [ "${MESH_CONTROL_ONION_MINT}" != true ]; then' '        if false; then'
    control "gen-provision-keys derives hs.<superdomain> again" scripts/gen-provision-keys.sh \
        'MESH_CONTROL_NAME="hs.${_mc_sd%%.*}-control.${_mc_sd#*.}"' 'MESH_CONTROL_NAME="hs.${_mc_sd}"'
    control "gen-provision-keys accepts a control name inside the superdomain" scripts/gen-provision-keys.sh \
        '    if [[ "https://${MESH_CONTROL_NAME}:${MESH_CONTROL_PORT}" == *"${_mc_sd}"* ]]; then' '    if false; then'
    control "the mint aborts on tor's exit status" scripts/gen-provision-keys.sh \
        '        wait "${_mc_pid}" 2>/dev/null || true' '        wait "${_mc_pid}" 2>/dev/null'
    control "build-all-roles removes the secret without evidence" scripts/build-all-roles.sh \
        '        if [ -f "${k}" ] && cmp -s "${k}" "${d}/hs_ed25519_secret_key"; then' '        if true; then'
    control "an ARM builder accepts a Tor transport it cannot bake" build-orangepi5-stage4.sh \
        '    lan+onion|onion) err "--mesh-control-transport ${MESH_CONTROL_TRANSPORT}: this builder cannot bake Tor' \
        '    lan+onion|onion) ;; #'
    # A bounded parallel pool: each control re-runs this whole suite on its own copy.
    jobs_max="$(nproc 2>/dev/null || echo 2)"; [ "${jobs_max}" -gt 6 ] && jobs_max=6
    i=0
    while [ "${i}" -lt "${n}" ]; do
        i=$((i + 1)); run_control "${i}" &
        while [ "$(jobs -rp | wc -l)" -ge "${jobs_max}" ]; do wait -n 2>/dev/null || true; done
    done
    wait
    for i in $(seq 1 "${n}"); do
        r="$(cat "${CTLS}/${i}.res" 2>/dev/null)"
        case "${r}" in
            PASS*) ok "${r#PASS }" ;;
            "")    bad "control ${i} produced no result" ;;
            *)     bad "${r#FAIL }" ;;
        esac
    done
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
