#!/usr/bin/env bash
# mesh_client_test.sh — the emulated mesh CLIENT: payload, grading, fleet order.
#
# WHAT BROKE (QEMU device run 2026-11-01, rpi5 pki/backend/frontend, all three):
#   FAIL role <r>: /usr/sbin/tailscaled is installed but tailscaled is MISSING from
#        the default runlevel — a mesh client that never starts
# The IMAGE was right (debugfs on the golden: tailscaled IS in
# /etc/runlevels/default). docker-entrypoint.sh wrote "tailscale": {"enabled":
# false} into every KEYS manifest, which no product stick does, and
# provision_tailscale() honours that by rc-update del'ing tailscaled at first boot.
# So the harness removed the client and then graded the image for its absence —
# and no emulated mesh could ever form, because nothing carried a key either.
#
# Pinned here, every leg EXECUTED (sections sed/awk-extracted from the real files,
# stubs on PATH, nothing boots):
#   A. the KEYS payload docker-entrypoint.sh writes: tailscale on, product tags +
#      routes; a control row declares a REUSABLE preauth key (#514) and, on a shared
#      L2, its mesh address as server_url; a worker on a fleet rendezvous copies the
#      control node's key (0600) and login_server, rejects a malformed one, and
#      gives up after MESH_JOIN_WAIT. Also: no payload generator that grades the
#      mesh client hardcodes tailscale off again.
#   B. assert_role_topology follows the manifest: tailscale.enabled=false makes the
#      unlinked client a SKIP; asked-for (or unknown) and unlinked stays a FAIL.
#   C. assert_mesh_client: joined + tailnet address, a fleet worker must see AND
#      ping a peer, a control node with no peers yet is a SKIP, not a pass.
#   D. run-qemu-docker.sh boots control roles FIRST on a shared L2 (the workers wait
#      on their key), and orders exactly as before without one.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
ENTRY="${HERE}/docker-entrypoint.sh"
ASSERT="${HERE}/assertions.sh"
RUNNER="${HERE}/run-qemu-docker.sh"
# shellcheck source=../lib/guard-preflight.sh
. "${REPO}/tests/lib/guard-preflight.sh"
guard_require_tools jq awk sed install stat
PASS=0; FAIL=0
_ok()  { echo "  ok   $*"; PASS=$((PASS+1)); }
_bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/meshclient.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# ═══════════════════════════ A. the KEYS payload ══════════════════════════════
echo "══ A. docker-entrypoint.sh's KEYS payload (executed) ══"
# From the mesh-client block's first line through the provision.json heredoc's EOF.
awk '/^TS_TAGS="tag:hugmesh"$/ {on=1}
     on {print}
     on && /^cat > "\$\{KEYS_SRC\}\/provision.json" <<EOF$/ {h=1}
     on && h && /^EOF$/ {exit}' "${ENTRY}" > "${WORK}/payload.sh"
grep -F '"tailscale": {' "${WORK}/payload.sh" >/dev/null \
    || { echo "could not extract the payload block from ${ENTRY}" >&2; exit 2; }
# payload ROLE HS_ENABLED MESH_NET MESH_IP RENDEZVOUS WAIT -> KEYS dir in ${KS}, log in ${PLOG}
payload() {
    KS="${WORK}/keys-$1-$RANDOM"; mkdir -p "${KS}"
    PLOG="$(ROLE="$1" HS_ENABLED="$2" MESH_NET="$3" MESH_IP="$4" MESH_RENDEZVOUS="$5" MESH_JOIN_WAIT="$6" \
            KEYS_SRC="${KS}" K8S_ROLE=worker timeout 30 bash -c '
        set -uo pipefail
        step(){ echo "STEP $*"; }; info(){ echo "INFO $*"; }; warn(){ echo "WARN $*"; }; die(){ echo "DIE $*"; exit 9; }
        . "$1"' _ "${WORK}/payload.sh" 2>&1)"
    PRC=$?
}
pj() { jq -r "$1" "${KS}/provision.json" 2>/dev/null; }

payload pki true "" "" "" 0
[ "${PRC}" -eq 0 ] && jq -e . "${KS}/provision.json" >/dev/null 2>&1 \
    && _ok "A1 pki payload is valid JSON" || _bad "A1 pki payload invalid (rc=${PRC}): ${PLOG}"
[ "$(pj '.tailscale.enabled')" = true ] && _ok "A1 tailscale.enabled=true (as every product stick; false makes provision_tailscale unlink the client)" \
    || _bad "A1 tailscale.enabled is '$(pj '.tailscale.enabled')' — keys-provision will rc-update del tailscaled"
[ "$(pj '.headscale.preauthkeys[0].reusable')" = true ] && [ "$(pj '.headscale.preauthkeys[0].user')" = hugmesh ] \
    && [ "$(pj '.headscale.users | index("hugmesh") != null')" = true ] \
    && _ok "A1 control row declares user hugmesh + ONE REUSABLE preauth key (#514: the self-join consumes a single-use key)" \
    || _bad "A1 control preauth declaration: $(pj -c '.headscale')"
[ "$(pj '.headscale.server_url // "none"')" = none ] && _ok "A1 no shared L2 -> no server_url override (resolve_endpoint picks the node's own address)" \
    || _bad "A1 server_url set without a mesh: $(pj '.headscale.server_url')"
case "$(pj '.tailscale.up_args')" in
    *"--advertise-tags=tag:hugmesh,tag:pki "*"--advertise-routes=10.244.0.0/16,10.96.0.0/12"*) _ok "A1 up_args carry the product's pki tags and pod/service routes" ;;
    *) _bad "A1 up_args: $(pj '.tailscale.up_args')" ;;
esac

payload pki true "239.1.2.3:4000" "10.87.72.11" "" 0
[ "$(pj '.headscale.server_url')" = "http://10.87.72.11:8080" ] \
    && _ok "A2 on a shared L2 the control node's server_url is its MESH address (the SLIRP 10.0.2.15 is unreachable to peers)" \
    || _bad "A2 server_url on a mesh: '$(pj '.headscale.server_url')'"

RV="${WORK}/rv-good"; mkdir -p "${RV}"; printf 'k3yABCdef0123_-x\n' > "${RV}/authkey"; printf 'http://10.87.72.11:8080\n' > "${RV}/login_server"
payload backend false "239.1.2.3:4000" "10.87.72.12" "${RV}" 5
if [ -f "${KS}/tailscale/authkey" ] && cmp -s "${RV}/authkey" "${KS}/tailscale/authkey" \
   && [ "$(stat -c %a "${KS}/tailscale/authkey")" = 600 ]; then
    _ok "A3 a fleet worker copies the control node's key onto its stick, 0600"
else
    _bad "A3 worker authkey not copied (or wrong mode): $(ls -l "${KS}/tailscale" 2>&1)"
fi
[ "$(pj '.tailscale.login_server')" = "http://10.87.72.11:8080" ] && _ok "A3 ...and the control node's login_server" \
    || _bad "A3 login_server '$(pj '.tailscale.login_server')'"
printf '%s' "${PLOG}" | grep -F 'k3yABCdef0123' >/dev/null && _bad "A3 the key appeared in the log" || _ok "A3 the key never appears in the log"
case "$(pj '.tailscale.up_args')" in *"tag:hugmesh,tag:be "*) _ok "A3 backend up_args carry tag:be" ;; *) _bad "A3 backend up_args: $(pj '.tailscale.up_args')" ;; esac
[ "$(pj '.headscale.enabled')" = false ] && [ "$(pj '.headscale.preauthkeys // "none"')" = none ] \
    && _ok "A3 a worker declares no headscale preauth keys" || _bad "A3 worker headscale block: $(pj -c '.headscale')"

# A3b — the real ordering: the worker's stick is written BEFORE the control node has
# published, so the key must be picked up when it appears mid-wait (one poll, ~5s).
RVL="${WORK}/rv-late"; mkdir -p "${RVL}"
( sleep 2; printf 'lateKEY0123456789\n' > "${RVL}/authkey"; printf 'http://10.87.72.11:8080\n' > "${RVL}/login_server" ) &
payload backend false "239.1.2.3:4000" "10.87.72.12" "${RVL}" 20
wait
[ -f "${KS}/tailscale/authkey" ] && cmp -s "${RVL}/authkey" "${KS}/tailscale/authkey" \
    && _ok "A3b a key published WHILE the worker waits is picked up (the worker does not give up at its first look)" \
    || _bad "A3b a key that appeared mid-wait was not used: ${PLOG}"

RV2="${WORK}/rv-empty"; mkdir -p "${RV2}"
payload frontend false "239.1.2.3:4000" "10.87.72.13" "${RV2}" 0
[ ! -e "${KS}/tailscale/authkey" ] && [ "$(pj '.tailscale.login_server')" = "" ] \
    && printf '%s' "${PLOG}" | grep -F 'no mesh key appeared' >/dev/null \
    && _ok "A4 no key within MESH_JOIN_WAIT -> boots unjoined and SAYS so (never a stale or empty key)" \
    || _bad "A4 empty rendezvous: authkey=$(ls "${KS}/tailscale" 2>&1) login='$(pj '.tailscale.login_server')' log=${PLOG}"

RV3="${WORK}/rv-bad"; mkdir -p "${RV3}"; printf 'k3y\n' > "${RV3}/authkey"; printf 'http://evil;rm -rf /:8080\n' > "${RV3}/login_server"
payload backend false "239.1.2.3:4000" "10.87.72.12" "${RV3}" 5
[ ! -e "${KS}/tailscale/authkey" ] && [ "$(pj '.tailscale.login_server')" = "" ] && jq -e . "${KS}/provision.json" >/dev/null 2>&1 \
    && _ok "A5 a malformed login_server is refused (and its key not used); the payload stays valid JSON" \
    || _bad "A5 malformed login_server accepted: '$(pj '.tailscale.login_server')'"

payload backend false "" "" "" 0
[ ! -e "${KS}/tailscale/authkey" ] && ! printf '%s' "${PLOG}" | grep -F 'Waiting' >/dev/null \
    && _ok "A6 no fleet -> no wait and no key (a worker alone boots its client unjoined)" \
    || _bad "A6 single worker: ${PLOG}"

# A7 — no payload generator that runs assertions.sh hardcodes the client OFF again.
# Comments stripped first, so a comment quoting the old line cannot satisfy it.
for g in docker-entrypoint.sh run-qemu-test.sh; do
    l="$(sed 's/[[:space:]]*#.*$//' "${HERE}/${g}" | grep '"tailscale": *{ *"enabled":' | head -1)"
    case "${l}" in
        *'"enabled": true'*) _ok "A7 ${g}: tailscale.enabled is true in the payload it writes" ;;
        "") _bad "A7 ${g}: no tailscale payload line found" ;;
        *)  _bad "A7 ${g}: tailscale payload is '${l}' — keys-provision will unlink the image's mesh client" ;;
    esac
done

# ═══════════════════ B. assert_role_topology follows the manifest ══════════════
echo "══ B. the tailscaled runlevel grade follows tailscale.enabled ══"
extract() { sed -n "/^$2() {/,/^}/p" "$1" >> "$3"; grep "^$2() {" "$3" >/dev/null || { echo "could not extract $2 from $1" >&2; exit 2; }; }
LIB="${WORK}/topo.sh"
cat > "${LIB}" <<'HDR'
PASS=0; FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP  $*"; }
HDR
cat "${REPO}/scripts/_roles-lib.sh" >> "${LIB}"
extract "${ASSERT}" _rl_has "${LIB}"; extract "${ASSERT}" _rl_dangling "${LIB}"; extract "${ASSERT}" assert_role_topology "${LIB}"
echo 'assert_role_topology "${FIXTURE_ROOT}"' >> "${LIB}"
FX="${WORK}/fx-backend"
mkdir -p "${FX}/etc/hugmesh" "${FX}/etc/runlevels/default" "${FX}/etc/init.d" "${FX}/usr/sbin"
echo backend > "${FX}/etc/hugmesh/role"; printf '#!/bin/sh\n' > "${FX}/usr/sbin/tailscaled"; chmod +x "${FX}/usr/sbin/tailscaled"
topo() { FIXTURE_ROOT="${FX}" _ts_want="$1" _ts_src="KEYS manifest" _hs_want=false _hs_src="KEYS manifest" bash -c 'set -u; . "$1"' _ "${LIB}" 2>&1 | grep -F 'tailscaled'; }
o="$(topo false)"
printf '%s' "${o}" | grep -F 'SKIP' | grep -F 'tailscale.enabled=false' >/dev/null && ! printf '%s' "${o}" | grep -F 'FAIL' >/dev/null \
    && _ok "B1 manifest said tailscale off -> the unlinked client is a SKIP (provision_tailscale unlinked it by design), not a FAIL" \
    || _bad "B1 manifest off: ${o}"
o="$(topo true)"
printf '%s' "${o}" | grep -F 'FAIL' | grep -F 'MISSING from the default runlevel' >/dev/null \
    && _ok "B2 manifest asked for the client and it is unlinked -> still a FAIL" || _bad "B2 manifest on: ${o}"
o="$(topo unknown)"
printf '%s' "${o}" | grep -F 'FAIL' | grep -F 'MISSING from the default runlevel' >/dev/null \
    && _ok "B3 no manifest intent -> the unlinked client stays a FAIL (unknown is not an excuse)" || _bad "B3 unknown: ${o}"

# ════════════════════════ C. assert_mesh_client ═══════════════════════════════
echo "══ C. assert_mesh_client against stubbed tailscale / rc-service ══"
MLIB="${WORK}/mesh.sh"
head -4 "${LIB}" > "${MLIB}"
extract "${ASSERT}" assert_mesh_client "${MLIB}"
echo 'assert_mesh_client "${FIXTURE_ROOT}"; echo "RESULT: ${PASS} passed, ${FAIL} failed"' >> "${MLIB}"
STUB="${WORK}/stub"; mkdir -p "${STUB}"
# tailscale: `status --json` prints $TS_JSON; `ip -4` prints $TS_IP; `ping` prints a
# pong unless TS_PONG=no. rc-service exits $RC_TS. sleep is instant.
cat > "${STUB}/tailscale" <<'EOF'
#!/bin/bash
case "$1" in
    status) printf '%s\n' "${TS_JSON}" ;;
    ip)     printf '%s\n' "${TS_IP}" ;;
    ping)   [ "${TS_PONG:-yes}" = yes ] && echo "pong from peer (${3:-?}) via 10.87.72.11:41641 in 2ms" || { echo "timeout"; false; } ;;
esac
EOF
printf '#!/bin/bash\nexit "${RC_TS:-0}"\n' > "${STUB}/rc-service"
printf '#!/bin/bash\n:\n' > "${STUB}/sleep"
chmod +x "${STUB}"/*
RUN_JSON='{"BackendState":"Running","Peer":{}}'
PEER_JSON='{"BackendState":"Running","Peer":{"nodekey:a":{"HostName":"hugmesh-pki-qemu","TailscaleIPs":["100.64.0.1","fd7a::1"]}}}'
mesh() {  # WANT KEY JSON IP [PONG] [RC]
    FIXTURE_ROOT="${FX}" _ts_want="$1" _ts_src="KEYS manifest" _ts_key="$2" TS_JSON="$3" TS_IP="$4" TS_PONG="${5:-yes}" RC_TS="${6:-0}" \
        PATH="${STUB}:${PATH}" bash -c 'set -u; . "$1"' _ "${MLIB}" 2>&1
}
o="$(mesh true preauth "${RUN_JSON}" 100.64.0.1)"
printf '%s' "${o}" | grep -F 'PASS  mesh join — tailscale is Running' >/dev/null && printf '%s' "${o}" | grep -F 'tailnet address 100.64.0.1' >/dev/null \
    && printf '%s' "${o}" | grep -F 'SKIP  mesh peers — none yet' >/dev/null && printf '%s' "${o}" | grep -F 'RESULT: 3 passed, 0 failed' >/dev/null \
    && _ok "C1 a self-joined control node: Running + 100.x address PASS, no peers yet is a SKIP" || _bad "C1: ${o}"
o="$(mesh true authkey "${PEER_JSON}" 100.64.0.2)"
printf '%s' "${o}" | grep -F 'PASS  mesh peers — reaches hugmesh-pki-qemu (100.64.0.1)' >/dev/null && printf '%s' "${o}" | grep -F ', 0 failed' >/dev/null \
    && _ok "C2 a fleet worker that sees and pings its control node PASSES (the mesh formed)" || _bad "C2: ${o}"
o="$(mesh true authkey "${RUN_JSON}" 100.64.0.2)"
printf '%s' "${o}" | grep -F 'FAIL  mesh peers — joined with a fleet key but sees NO peer' >/dev/null \
    && _ok "C3 a fleet worker with no peer FAILS (a joined-but-alone node is not a mesh)" || _bad "C3: ${o}"
o="$(mesh true authkey "${PEER_JSON}" 100.64.0.2 no)"
printf '%s' "${o}" | grep -F 'FAIL  mesh peers — hugmesh-pki-qemu (100.64.0.1) is in the netmap but does not answer' >/dev/null \
    && _ok "C4 a peer in the netmap that never pongs FAILS" || _bad "C4: ${o}"
o="$(mesh true authkey '{"BackendState":"NeedsLogin"}' "")"
printf '%s' "${o}" | grep -F "FAIL  mesh join — tailscale BackendState is 'NeedsLogin'" >/dev/null && printf '%s' "${o}" | grep -F 'FAIL  mesh join — no tailnet' >/dev/null \
    && _ok "C5 a key on the stick but not Running / no 100.x address FAILS both" || _bad "C5: ${o}"
o="$(mesh true none "${RUN_JSON}" "")"
printf '%s' "${o}" | grep -F 'SKIP  mesh join — the KEYS stick carries no auth key' >/dev/null && printf '%s' "${o}" | grep -F 'RESULT: 1 passed, 0 failed' >/dev/null \
    && _ok "C6 no key at all -> the service is graded, the join is a SKIP (never a pass)" || _bad "C6: ${o}"
o="$(mesh false authkey "${PEER_JSON}" 100.64.0.2)"
printf '%s' "${o}" | grep -F 'SKIP  mesh client — not asked for' >/dev/null && printf '%s' "${o}" | grep -F 'RESULT: 0 passed, 0 failed' >/dev/null \
    && _ok "C7 tailscale not asked for -> one SKIP, nothing graded" || _bad "C7: ${o}"
o="$(mesh true preauth "${RUN_JSON}" 100.64.0.1 yes 3)"
printf '%s' "${o}" | grep -F 'FAIL  tailscaled service NOT started' >/dev/null \
    && _ok "C8 asked for but the service is down -> FAIL" || _bad "C8: ${o}"

# ═════════════════════ D. fleet boot order on a shared L2 ═════════════════════
echo "══ D. run-qemu-docker.sh boots control roles first on a shared L2 ══"
RLIB="${WORK}/rank.sh"
cat "${REPO}/scripts/_roles-lib.sh" > "${RLIB}"
extract "${RUNNER}" platform_rank "${RLIB}"; extract "${RUNNER}" row_rank "${RLIB}"
order() {  # MESH_NET -> the role order the runner's sort produces for rpi5 {backend,frontend,pki} + x86 pki
    MESH_NET="$1" bash -c '
        . "$1"
        for r in "rpi5 backend" "rpi5 frontend" "rpi5 pki" "x86 pki" "x86 backend"; do
            set -- $r; printf "%s|%s|%s\n" "$(row_rank "$1" "$2")" "$1" "$2"
        done | sort -t"|" -k1,1n -k2,2 -k3,3 | cut -d"|" -f2,3 | tr "\n" " "' _ "${RLIB}"
}
o="$(order "")"
[ "${o}" = "rpi5|backend rpi5|frontend rpi5|pki x86|backend x86|pki " ] \
    && _ok "D1 without --mesh-net the order is exactly the old one (${o})" || _bad "D1 order changed without a mesh: ${o}"
o="$(order "239.1.2.3:4000")"
[ "${o}" = "rpi5|pki rpi5|backend rpi5|frontend x86|pki x86|backend " ] \
    && _ok "D2 on a shared L2 each platform's control role boots first (${o})" || _bad "D2 mesh order: ${o}"
# D3 — the rendezvous: a control row clears the previous key BEFORE its container
# starts, every mesh row is told where it is, and the publisher renames login_server
# LAST (a reader keys on both files).
sec="$(sed -n '/^start_device_row() {/,/^}/p' "${RUNNER}")"
n_rm="$(printf '%s\n' "${sec}" | grep -n -F 'rm -f "${WORK}/${MESH_RENDEZVOUS_REL}/authkey"' | head -1 | cut -d: -f1)"
n_run="$(printf '%s\n' "${sec}" | grep -n -F '"$(docker run -d' | head -1 | cut -d: -f1)"
[ -n "${n_rm}" ] && [ -n "${n_run}" ] && [ "${n_rm}" -lt "${n_run}" ] \
    && printf '%s\n' "${sec}" | grep -F 'mesh_args+=(-e MESH_RENDEZVOUS=' >/dev/null \
    && _ok "D3 a control row clears the fleet's stale key before its container starts; every mesh row gets MESH_RENDEZVOUS" \
    || _bad "D3 rendezvous wiring in start_device_row (rm line ${n_rm:-none}, docker run line ${n_run:-none})"
n_k="$(grep -n -F 'mv -f "${MESH_RENDEZVOUS}/.authkey.part" "${MESH_RENDEZVOUS}/authkey"' "${ENTRY}" | cut -d: -f1)"
n_l="$(grep -n -F 'mv -f "${MESH_RENDEZVOUS}/.login_server.part" "${MESH_RENDEZVOUS}/login_server"' "${ENTRY}" | cut -d: -f1)"
[ -n "${n_k}" ] && [ -n "${n_l}" ] && [ "${n_k}" -lt "${n_l}" ] \
    && _ok "D3 the control side publishes authkey then login_server (atomic renames, reader keys on both)" \
    || _bad "D3 publish order: authkey line ${n_k:-none}, login_server line ${n_l:-none}"

# ═══════════════ E. provision.sh: the join cannot hang the boot ═════════════════
echo "══ E. provision.sh: KEYS network profiles go live, tailscale up is bounded ══"
PROV="${REPO}/specs/etc/keys-provision/provision.sh"
PLIB="${WORK}/prov.sh"
{
    echo 'log()  { echo "LOG $*"; }; warn() { echo "WARN $*"; }; have() { command -v "$1" >/dev/null 2>&1; }'
    echo 'jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }'
} > "${PLIB}"
# provision_network writes /etc/NetworkManager — re-rooted into the sandbox here.
sed -n '/^provision_network() {/,/^}/p' "${PROV}" | sed "s|/etc/NetworkManager|\${NMROOT}/etc/NetworkManager|g; s|/etc/conf.d|\${NMROOT}/etc/conf.d|g" >> "${PLIB}"
extract "${PROV}" nm_apply_profiles "${PLIB}"
extract "${PROV}" provision_tailscale "${PLIB}"
grep -F 'provision_network() {' "${PLIB}" >/dev/null || { echo "could not extract provision_network" >&2; exit 2; }
PSTUB="${WORK}/pstub"; mkdir -p "${PSTUB}"
# nmcli: logs argv; `general status` fails when NM_DOWN=1.
printf '#!/bin/bash\necho "nmcli $*" >> "${CALLS}"\n[ "$1 $2" = "general status" ] && [ "${NM_DOWN:-0}" = 1 ] && exit 8\nexit 0\n' > "${PSTUB}/nmcli"
printf '#!/bin/bash\necho "tailscale $*" >> "${CALLS}"\nexit 0\n' > "${PSTUB}/tailscale"
printf '#!/bin/bash\n:\n' > "${PSTUB}/tailscaled"
for t in rc-update rc-service sleep; do printf '#!/bin/bash\n:\n' > "${PSTUB}/${t}"; done
chmod +x "${PSTUB}"/*
prov() {  # FUNC MANIFEST-JSON -> CALLS file content; BASE + NMROOT in the sandbox
    local d; d="${WORK}/prov-$RANDOM"; mkdir -p "${d}/keys/network" "${d}/keys/tailscale" "${d}/root"
    printf '%s\n' "$2" > "${d}/keys/provision.json"
    printf '[connection]\nid=mesh0\ntype=ethernet\nautoconnect=true\n' > "${d}/keys/network/mesh0.nmconnection"
    printf '[connection]\nid=spare\ntype=ethernet\nautoconnect=false\n' > "${d}/keys/network/spare.nmconnection"
    printf 'tskey-fixture-0123\n' > "${d}/keys/tailscale/authkey"
    CALLS="${d}/calls"; : > "${CALLS}"
    POUT="$(CALLS="${CALLS}" NM_DOWN="${NM_DOWN:-0}" BASE="${d}/keys" MANIFEST="${d}/keys/provision.json" NMROOT="${d}/root" \
            PATH="${PSTUB}:${PATH}" bash -c 'set -u; . "$1"; mkdir() { command mkdir "$@" 2>/dev/null || true; }; "$2"' _ "${PLIB}" "$1" 2>&1)"
}
prov provision_network '{}'
c="$(cat "${CALLS}")"
n_r="$(printf '%s\n' "${c}" | grep -n -x 'nmcli connection reload' | cut -d: -f1)"
n_u="$(printf '%s\n' "${c}" | grep -n -x 'nmcli --wait 20 connection up id mesh0' | cut -d: -f1)"
[ -n "${n_r}" ] && [ -n "${n_u}" ] && [ "${n_r}" -lt "${n_u}" ] \
    && _ok "E1 a KEYS-supplied profile is made LIVE this boot: nmcli reload, then a bounded 'connection up' (NM does not watch keyfiles)" \
    || _bad "E1 profiles not applied: $(printf '%s' "${c}" | tr '\n' ';') :: ${POUT}"
printf '%s\n' "${c}" | grep -F 'up id spare' >/dev/null && _bad "E1 an autoconnect=false profile was forced up" \
    || _ok "E1 ...but a profile that opts out of autoconnect is only staged"
NM_DOWN=1 prov provision_network '{}'
printf '%s' "$(cat "${CALLS}")" | grep -F 'connection' >/dev/null && _bad "E2 NM not running but nmcli reload/up was attempted" \
    || _ok "E2 NetworkManager not running -> no reload/up attempted (nothing to stall)"
TSM='{"tailscale":{"enabled":true,"authkey_file":"tailscale/authkey","login_server":"http://10.77.0.13:8080","up_args":"--accept-routes"},"headscale":{"enabled":false}}'
prov provision_tailscale "${TSM}"
up="$(grep '^tailscale up ' "${CALLS}")"
case " ${up} " in
    *" --timeout 120s "*) _ok "E3 'tailscale up' is BOUNDED by default (--timeout 120s): an unreachable control server can no longer freeze keys-provision before sshd" ;;
    *) _bad "E3 tailscale up has no default timeout: '${up}'" ;;
esac
case " ${up} " in *" --login-server http://10.77.0.13:8080 "*) _ok "E3 ...and still joins the manifest's login server" ;; *) _bad "E3 login server lost: '${up}'" ;; esac
prov provision_tailscale "$(printf '%s' "${TSM}" | jq -c '.tailscale.up_timeout="45s"')"
case " $(grep '^tailscale up ' "${CALLS}") " in *" --timeout 45s "*) _ok "E4 .tailscale.up_timeout overrides the bound" ;; *) _bad "E4 up_timeout ignored: $(grep '^tailscale up ' "${CALLS}")" ;; esac
prov provision_tailscale "$(printf '%s' "${TSM}" | jq -c '.tailscale.up_timeout="1d;reboot"')"
case " $(grep '^tailscale up ' "${CALLS}") " in *" --timeout 120s "*) _ok "E4 a malformed up_timeout falls back to 120s (never reaches the argv)" ;; *) _bad "E4 malformed up_timeout: $(grep '^tailscale up ' "${CALLS}")" ;; esac
prov provision_tailscale "$(printf '%s' "${TSM}" | jq -c '.tailscale.up_args="--accept-routes --timeout=30s"')"
[ "$(grep '^tailscale up ' "${CALLS}" | grep -o -- '--timeout' | wc -l)" -eq 1 ] \
    && _ok "E4 an explicit --timeout in up_args wins (no second --timeout)" || _bad "E4 duplicate timeout: $(grep '^tailscale up ' "${CALLS}")"

# ═══════ F. NetworkManager must hand over `net` on a slow boot (cluster nodes) ═══════
echo "══ F. NetworkManager INACTIVE_TIMEOUT (builders) + the in-guest NM grade ══"
for b in build-rpi5-stage4.sh build-x86-host-stage4.sh; do
    f="${REPO}/${b}"
    n_w="$(grep -n -F "'INACTIVE_TIMEOUT=60' > \"\${SYSROOT}/etc/conf.d/NetworkManager\"" "${f}" | head -1 | cut -d: -f1)"
    # the LAST emerge command line of the builder (cross or native chroot)
    n_e="$(grep -n -E '^[[:space:]]*(if ! )?(cross_emerge|emerge) --' "${f}" | tail -1 | cut -d: -f1)"
    n_p="$(grep -n -F 'banner "Packaging stage4 tarball"' "${f}" | cut -d: -f1)"
    n_g="$(awk -v w="${n_w:-0}" 'NR<w && /^if ! \$\{ROLE_CLIENT\}; then$/ {l=NR} END{print l+0}' "${f}")"
    if [ -n "${n_w}" ] && [ -n "${n_p}" ] && [ "${n_w}" -lt "${n_p}" ] && [ "${n_w}" -gt "${n_e:-0}" ] && [ "${n_g}" -gt 0 ] && [ $((n_w - n_g)) -le 8 ]; then
        _ok "F1 ${b}: cluster nodes get INACTIVE_TIMEOUT=60, written after the payload emerge (line ${n_w} > ${n_e:-?}) and before packaging"
    else
        _bad "F1 ${b}: NetworkManager conf.d write missing, before the emerge that would overwrite it, or not cluster-gated (write ${n_w:-none}, emerge ${n_e:-none}, pack ${n_p:-none}, gate ${n_g})"
    fi
done
NLIB="${WORK}/nm.sh"
head -4 "${LIB}" > "${NLIB}"
sed -n '/^echo "-- network --"$/,/^echo "-- kubernetes stack --"$/p' "${ASSERT}" | sed '$d' \
    | sed 's|/etc/runlevels/default/NetworkManager|${FIXTURE_ROOT}/etc/runlevels/default/NetworkManager|g' >> "${NLIB}"
grep -F 'NetworkManager is INACTIVE' "${NLIB}" >/dev/null || { echo "could not extract the network section" >&2; exit 2; }
mkdir -p "${FX}/etc/runlevels/default"; ln -sf /etc/init.d/NetworkManager "${FX}/etc/runlevels/default/NetworkManager"
printf '#!/bin/bash\necho " * status: ${NM_STATE}"\n' > "${STUB}/rc-service"; printf '#!/bin/bash\necho connected\n' > "${STUB}/nmcli"; chmod +x "${STUB}/rc-service" "${STUB}/nmcli"
nmgrade() { FIXTURE_ROOT="${FX}" NM_STATE="$1" PATH="${STUB}:${PATH}" bash -c 'set -u; . "$1"' _ "${NLIB}" 2>&1; }
nmgrade started | grep -F 'PASS  NetworkManager service is started' >/dev/null && _ok "F2 NM started -> PASS" || _bad "F2 NM started: $(nmgrade started)"
nmgrade inactive | grep -F 'FAIL  NetworkManager is INACTIVE' >/dev/null && _ok "F2 NM inactive (the silent need-net cascade) -> FAIL" || _bad "F2 NM inactive: $(nmgrade inactive)"

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]
