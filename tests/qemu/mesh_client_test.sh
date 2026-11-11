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
#   C. assert_mesh_client: joined + tailnet address + a LIVE map session (Self.Online,
#      and a control node's own headscale listing it online), a fleet worker must see
#      AND ping a peer, every advertised route is some netmap node's primary route
#      (the only grant of the product ACL), a control node with no peers yet is a
#      SKIP, not a pass; an ICMP probe through the filter is recorded, never counted.
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
# status: prints $TS_JSON, or $TS_JSON_LATE from the $TS_LATE_AT-th status call on
# (a peer that reaches the netmap while the control node waits). headscale: prints
# $HS_JSON (the control node's registry). sleep: instant, counted in $SLEEP_LOG.
cat > "${STUB}/tailscale" <<'EOF'
#!/bin/bash
case "$1" in
    status) n=0; [ -n "${TS_COUNT:-}" ] && { n="$(cat "${TS_COUNT}" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "${n}" > "${TS_COUNT}"; }
            if [ -n "${TS_JSON_LATE:-}" ] && [ "${n}" -ge "${TS_LATE_AT:-999}" ]; then printf '%s\n' "${TS_JSON_LATE}"; else printf '%s\n' "${TS_JSON}"; fi ;;
    ip)     printf '%s\n' "${TS_IP}" ;;
    ping)   case " $* " in
                *" --icmp "*) [ "${TS_ICMP_PONG:-no}" = yes ] && echo "pong from peer (icmp) in 3ms" || { echo "timeout"; false; } ;;
                *)            [ "${TS_PONG:-yes}" = yes ] && echo "pong from peer (${3:-?}) via 10.87.72.11:41641 in 2ms" || { echo "timeout"; false; } ;;
            esac ;;
esac
EOF
printf '#!/bin/bash\nexit "${RC_TS:-0}"\n' > "${STUB}/rc-service"
printf '#!/bin/bash\n[ -n "${SLEEP_LOG:-}" ] && echo "sleep $*" >> "${SLEEP_LOG}"\n:\n' > "${STUB}/sleep"
printf '#!/bin/bash\nprintf "%%s\\n" "${HS_JSON:-[]}"\n' > "${STUB}/headscale"
chmod +x "${STUB}"/*
RUN_JSON='{"BackendState":"Running","Self":{"HostName":"self","Online":true},"Peer":{}}'
PEER_JSON='{"BackendState":"Running","Self":{"HostName":"self","Online":true},"Peer":{"nodekey:a":{"HostName":"hugmesh-pki-qemu","TailscaleIPs":["100.64.0.1","fd7a::1"]}}}'
WPEER_JSON='{"BackendState":"Running","Self":{"HostName":"self","Online":true},"Peer":{"nodekey:b":{"HostName":"hugmesh-backend-qemu","TailscaleIPs":["100.64.0.2","fd7a::2"]}}}'
# headscale's JSON omits a false "online" (protobuf), so an offline node has no key at all.
HS_SELF="[{\"name\":\"$(hostname)\",\"given_name\":\"$(hostname)\",\"online\":true,\"ip_addresses\":[\"100.64.0.1\"]}]"
HS_FLEET="[{\"name\":\"$(hostname)\",\"given_name\":\"$(hostname)\",\"online\":true,\"ip_addresses\":[\"100.64.0.1\"]},{\"name\":\"hugmesh-backend-qemu\",\"given_name\":\"hugmesh-backend-qemu\",\"online\":true,\"ip_addresses\":[\"100.64.0.2\"]}]"
# mesh() runs inside a $(...) capture, so its sleep log is a FIXED path the caller reads.
SLEEP_LOG="${WORK}/sleep.log"; TS_COUNT="${WORK}/tscount"
mesh() {  # WANT KEY JSON IP [PONG] [RC]   (env: HS_JSON PEER_WAIT TS_JSON_LATE TS_LATE_AT ROUTES ICMP_PONG)
    : > "${SLEEP_LOG}"; : > "${TS_COUNT}"
    FIXTURE_ROOT="${FX}" _ts_want="$1" _ts_src="KEYS manifest" _ts_key="$2" TS_JSON="$3" TS_IP="$4" TS_PONG="${5:-yes}" RC_TS="${6:-0}" \
        _ts_routes="${ROUTES:-}" TS_ICMP_PONG="${ICMP_PONG:-no}" \
        HS_JSON="${HS_JSON:-${HS_SELF}}" HUGMESH_ASSERT_PEER_WAIT="${PEER_WAIT:-0}" TS_JSON_LATE="${TS_JSON_LATE:-}" TS_LATE_AT="${TS_LATE_AT:-999}" \
        SLEEP_LOG="${SLEEP_LOG}" TS_COUNT="${TS_COUNT}" PATH="${STUB}:${PATH}" bash -c 'set -u; . "$1"' _ "${MLIB}" 2>&1
}
o="$(mesh true preauth "${RUN_JSON}" 100.64.0.1)"
printf '%s' "${o}" | grep -F 'PASS  mesh join — tailscale is Running' >/dev/null && printf '%s' "${o}" | grep -F 'tailnet address 100.64.0.1' >/dev/null \
    && printf '%s' "${o}" | grep -F 'SKIP  mesh peers — no fleet node has registered' >/dev/null && printf '%s' "${o}" | grep -F 'RESULT: 5 passed, 0 failed' >/dev/null \
    && printf '%s' "${o}" | grep -F 'PASS  mesh session — this control node' >/dev/null \
    && _ok "C1 a self-joined control node with nothing else registered: Running + 100.x address + live session (own and headscale's view) PASS, no peers yet is a SKIP" || _bad "C1: ${o}"
[ "$(grep -c . "${SLEEP_LOG}")" -eq 0 ] && _ok "C1 ...and with no HUGMESH_ASSERT_PEER_WAIT budget it does not wait" || _bad "C1 waited $(grep -c . "${SLEEP_LOG}") time(s) with no budget"
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
# C9-C12 — a CONTROL node is graded against its own headscale registry (2026-11-04:
# it SKIPped "none yet" for ever, re-run after the worker had joined included).
o="$(HS_JSON="${HS_FLEET}" mesh true preauth "${RUN_JSON}" 100.64.0.1)"
printf '%s' "${o}" | grep -F 'FAIL  mesh peers — hugmesh-backend-qemu registered on this control node' >/dev/null && printf '%s' "${o}" | grep -F 'none is in its netmap after 0s' >/dev/null \
    && _ok "C9 a worker registered on the control node's headscale but absent from its netmap -> FAIL (names the node and what to look at)" || _bad "C9: ${o}"
o="$(HS_JSON="${HS_FLEET}" mesh true preauth "${WPEER_JSON}" 100.64.0.1)"
printf '%s' "${o}" | grep -F 'PASS  mesh peers — reaches hugmesh-backend-qemu (100.64.0.2)' >/dev/null \
    && _ok "C10 the registered worker in the netmap and answering ping -> PASS (the control node graded after its fleet joined)" || _bad "C10: ${o}"
o="$(HS_JSON="${HS_FLEET}" PEER_WAIT=30 TS_JSON_LATE="${WPEER_JSON}" TS_LATE_AT=6 mesh true preauth "${RUN_JSON}" 100.64.0.1)"
printf '%s' "${o}" | grep -F 'PASS  mesh peers — reaches hugmesh-backend-qemu (100.64.0.2)' >/dev/null && [ "$(grep -c -x 'sleep 10' "${SLEEP_LOG}")" -eq 2 ] \
    && _ok "C11 with a budget the control node WAITS (10 s polls) for the worker to reach its netmap, then grades it: PASS after 2 polls" || _bad "C11: sleeps=$(grep -c . "${SLEEP_LOG}") :: ${o}"
o="$(HS_JSON="${HS_FLEET}" PEER_WAIT=25 mesh true preauth "${RUN_JSON}" 100.64.0.1)"
printf '%s' "${o}" | grep -F 'FAIL  mesh peers — hugmesh-backend-qemu registered' >/dev/null && printf '%s' "${o}" | grep -F 'after 30s' >/dev/null && [ "$(grep -c -x 'sleep 10' "${SLEEP_LOG}")" -eq 3 ] \
    && _ok "C12 the wait is BOUNDED by HUGMESH_ASSERT_PEER_WAIT (25 -> 3 polls) and ends in the FAIL, not a SKIP, when the worker stays out of the netmap" || _bad "C12: sleeps=$(grep -c . "${SLEEP_LOG}") :: ${o}"
o="$(PEER_WAIT=15 mesh true preauth "${RUN_JSON}" 100.64.0.1)"
printf '%s' "${o}" | grep -F 'SKIP  mesh peers — no fleet node has registered' >/dev/null && printf '%s' "${o}" | grep -F 'within 20s' >/dev/null \
    && _ok "C12 ...and with nothing registered after the budget it is still a SKIP that says how long it waited" || _bad "C12 skip-after-wait: ${o}"
o="$(HS_JSON="${HS_FLEET}" PEER_WAIT=30 mesh true authkey "${RUN_JSON}" 100.64.0.2)"
printf '%s' "${o}" | grep -F 'FAIL  mesh peers — joined with a fleet key but sees NO peer' >/dev/null && [ "$(grep -c . "${SLEEP_LOG}")" -eq 0 ] \
    && _ok "C12 a WORKER never waits on the registry (its control node joined first by construction)" || _bad "C12 worker waited: ${o}"

# C13-C15 — the node's own MAP SESSION (proof B, 2026-11-04: the control node read
# BackendState Running and held 100.64.0.1 for six minutes while its tailscaled could
# not poll headscale; Self.Online was false, headscale listed it online=null, and the
# worker's netmap stayed empty). Running + an address must not be enough.
DEAD_JSON='{"BackendState":"Running","Self":{"HostName":"self","Online":false},"Peer":{}}'
o="$(mesh true preauth "${DEAD_JSON}" 100.64.0.1)"
printf '%s' "${o}" | grep -F 'PASS  mesh join — tailscale is Running' >/dev/null \
    && printf '%s' "${o}" | grep -F "FAIL  mesh session — Self.Online is 'false' after 60s" >/dev/null \
    && [ "$(grep -c -x 'sleep 5' "${SLEEP_LOG}")" -eq 12 ] \
    && _ok "C13 Running + 100.x address but Self.Online=false -> FAIL after a BOUNDED wait (12 x 5 s)" || _bad "C13: sleeps=$(grep -c . "${SLEEP_LOG}") :: ${o}"
o="$(TS_JSON_LATE="${RUN_JSON}" TS_LATE_AT=4 mesh true preauth "${DEAD_JSON}" 100.64.0.1)"
printf '%s' "${o}" | grep -F "PASS  mesh session — this node's map session is live" >/dev/null && [ "$(grep -c -x 'sleep 5' "${SLEEP_LOG}")" -eq 2 ] \
    && _ok "C14 a session that comes back within the window (the regain) PASSES after 2 polls" || _bad "C14: sleeps=$(grep -c . "${SLEEP_LOG}") :: ${o}"
HS_OFF="[{\"name\":\"$(hostname)\",\"given_name\":\"$(hostname)\",\"ip_addresses\":[\"100.64.0.1\"]}]"
o="$(HS_JSON="${HS_OFF}" mesh true preauth "${RUN_JSON}" 100.64.0.1)"
printf '%s' "${o}" | grep -F 'FAIL  mesh session — this control node'"'"'s own headscale lists it online=false' >/dev/null \
    && _ok "C15 a control node its own headscale does not list online (the proof-B online=null) -> FAIL" || _bad "C15: ${o}"
o="$(HS_JSON='[]' mesh true preauth "${RUN_JSON}" 100.64.0.1)"
printf '%s' "${o}" | grep -F 'lists it online=unregistered' >/dev/null \
    && _ok "C15 ...and one missing from its own registry says 'unregistered', not a pass" || _bad "C15 unregistered: ${o}"
o="$(mesh true authkey "${PEER_JSON}" 100.64.0.2)"
! printf '%s' "${o}" | grep -F 'own headscale' >/dev/null \
    && _ok "C15 a WORKER is never asked about a headscale it does not run" || _bad "C15 worker asked headscale: ${o}"

# C16 — what the product ACL GRANTS (tag:hugmesh -> 10.244.0.0/16:*, 10.96.0.0/12:*,
# bootstrap and rendered policy alike): every advertised route is a PRIMARY route of
# some node in the netmap, this one or a peer.
MR="10.244.0.0/16,10.96.0.0/12"
RPEER_JSON='{"BackendState":"Running","Self":{"HostName":"self","Online":true},"Peer":{"nodekey:a":{"HostName":"hugmesh-pki-qemu","TailscaleIPs":["100.64.0.1"],"PrimaryRoutes":["10.244.0.0/16","10.96.0.0/12"]}}}'
o="$(ROUTES="${MR}" mesh true authkey "${RPEER_JSON}" 100.64.0.2)"
printf '%s' "${o}" | grep -F 'PASS  mesh routes — 10.244.0.0/16 is served on the tailnet by hugmesh-pki-qemu' >/dev/null \
    && printf '%s' "${o}" | grep -F 'PASS  mesh routes — 10.96.0.0/12 is served on the tailnet by hugmesh-pki-qemu' >/dev/null \
    && printf '%s' "${o}" | grep -F ', 0 failed' >/dev/null \
    && _ok "C16 a worker whose control peer is primary for both mesh routes -> one PASS per route, naming the carrier" || _bad "C16: ${o}"
RSELF_JSON='{"BackendState":"Running","Self":{"HostName":"hugmesh-pki-qemu","Online":true,"PrimaryRoutes":["10.244.0.0/16","10.96.0.0/12"]},"Peer":{}}'
o="$(ROUTES="${MR}" mesh true preauth "${RSELF_JSON}" 100.64.0.1)"
[ "$(printf '%s' "${o}" | grep -c -F 'PASS  mesh routes — ')" -eq 2 ] \
    && _ok "C16 a control node that is itself the primary (no fleet yet) -> both routes PASS" || _bad "C16 self-primary: ${o}"
RHALF_JSON='{"BackendState":"Running","Self":{"HostName":"self","Online":true},"Peer":{"nodekey:a":{"HostName":"hugmesh-pki-qemu","TailscaleIPs":["100.64.0.1"],"PrimaryRoutes":["10.244.0.0/16"]}}}'
o="$(ROUTES="${MR}" mesh true authkey "${RHALF_JSON}" 100.64.0.2)"
printf '%s' "${o}" | grep -F 'FAIL  mesh routes — no node in this netmap serves 10.96.0.0/12' >/dev/null \
    && printf '%s' "${o}" | grep -F 'PASS  mesh routes — 10.244.0.0/16' >/dev/null \
    && _ok "C16 a route no node serves (unapproved, or its advertiser offline) -> FAIL names that route" || _bad "C16 half: ${o}"
o="$(ROUTES="${MR}" mesh true authkey "${PEER_JSON}" 100.64.0.2)"
[ "$(printf '%s' "${o}" | grep -c -F 'FAIL  mesh routes — no node in this netmap serves')" -eq 2 ] \
    && _ok "C16 a peer in the netmap that carries no route -> both routes FAIL (a disco pong is not what the ACL grants)" || _bad "C16 no-routes: ${o}"
o="$(mesh true authkey "${RPEER_JSON}" 100.64.0.2)"
! printf '%s' "${o}" | grep -F 'mesh routes' >/dev/null \
    && _ok "C16 a node that advertises no routes (a client) gets no route grade" || _bad "C16 client graded: ${o}"
# C17 — the ICMP probe THROUGH the packet filter is recorded, never counted.
o="$(mesh true authkey "${PEER_JSON}" 100.64.0.2)"
printf '%s' "${o}" | grep -F 'INFO  mesh peers — ICMP through the packet filter to 100.64.0.1: no pong (expected' >/dev/null \
    && printf '%s' "${o}" | grep -F ', 0 failed' >/dev/null \
    && _ok "C17 ICMP filtered by the product ACL -> an INFO line, not a FAIL" || _bad "C17: ${o}"
o1="$(mesh true authkey "${PEER_JSON}" 100.64.0.2 | grep -F 'RESULT')"; o2="$(ICMP_PONG=yes mesh true authkey "${PEER_JSON}" 100.64.0.2)"
printf '%s' "${o2}" | grep -F 'ICMP through the packet filter to 100.64.0.1: pong (the ACL admits' >/dev/null \
    && [ "$(printf '%s' "${o2}" | grep -F 'RESULT')" = "${o1}" ] \
    && _ok "C17 ...and an ICMP pong changes no count either way" || _bad "C17 pong: ${o1} vs ${o2}"

# C18 — _ts_routes is read from the manifest's own --advertise-routes (the line in
# assertions.sh, executed against the payload docker-entrypoint.sh writes).
RLINES="$(grep -E '^ *_ts_routes="\$\(jq|^ *\[\[ "\$\{_ts_routes\}"' "${ASSERT}")"
[ "$(printf '%s\n' "${RLINES}" | grep -c .)" -eq 2 ] || { echo "could not extract the _ts_routes lines from ${ASSERT}" >&2; exit 2; }
troutes() { _hs_m="$1" bash -c 'set -u; '"${RLINES}"'; printf "%s" "${_ts_routes}"'; }
payload backend false "" "" "" 0
[ "$(troutes "${KS}/provision.json")" = "10.244.0.0/16,10.96.0.0/12" ] \
    && _ok "C18 a cluster node's manifest -> _ts_routes is its --advertise-routes" || _bad "C18 cluster: '$(troutes "${KS}/provision.json")'"
payload desktop false "" "" "" 0
[ "$(troutes "${KS}/provision.json")" = "" ] \
    && _ok "C18 a desktop client's manifest (accept-routes only) -> no routes to grade" || _bad "C18 desktop: '$(troutes "${KS}/provision.json")'"
printf '{"tailscale":{"up_args":"--advertise-routes=10.0.0.0/8;reboot --ssh"}}' > "${WORK}/evil.json"
[ "$(troutes "${WORK}/evil.json")" = "" ] \
    && _ok "C18 a route list with anything but address characters is dropped" || _bad "C18 evil: '$(troutes "${WORK}/evil.json")'"

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
# D4 — the control row of a rendezvous fleet gets a peer-wait budget streamed AHEAD of
# assertions.sh (sudo bash -s drops the environment); every other row gets 0.
n_g="$(grep -n -F 'if [ "${HS_ENABLED}" = true ] && [ -n "${MESH_RENDEZVOUS}" ]; then ASSERT_PEER_WAIT="${ASSERT_PEER_WAIT_FLEET:-600}"; fi' "${ENTRY}" | cut -d: -f1)"
n_s="$(grep -n -F "< <(printf 'HUGMESH_ASSERT_PEER_WAIT=%s\\n' \"\${ASSERT_PEER_WAIT}\"; cat \"\${QEMU_DIR}/../../scripts/_roles-lib.sh\" \"\${QEMU_DIR}/assertions.sh\")" "${ENTRY}" | cut -d: -f1)"
[ -n "${n_g}" ] && [ -n "${n_s}" ] && [ "${n_g}" -lt "${n_s}" ] && grep -F 'ASSERT_PEER_WAIT=0' "${ENTRY}" >/dev/null \
    && _ok "D4 docker-entrypoint.sh streams HUGMESH_ASSERT_PEER_WAIT (600 s for a rendezvous control row, else 0) as the first line of the assertion script" \
    || _bad "D4 peer-wait prelude: gate line ${n_g:-none}, stream line ${n_s:-none}"

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
# provision_tailscale checks every non-loopback login server's scheme
# (control_url_tls_migrate); its curl is stubbed per test (CURL_ANSWER, below).
extract "${PROV}" control_url_tls_migrate "${PLIB}"
extract "${PROV}" headscale_url_parts "${PLIB}"
grep -F 'provision_network() {' "${PLIB}" >/dev/null || { echo "could not extract provision_network" >&2; exit 2; }
PSTUB="${WORK}/pstub"; mkdir -p "${PSTUB}"
# nmcli: logs argv; `general status` fails when NM_DOWN=1.
printf '#!/bin/bash\necho "nmcli $*" >> "${CALLS}"\n[ "$1 $2" = "general status" ] && [ "${NM_DOWN:-0}" = 1 ] && exit 8\nexit 0\n' > "${PSTUB}/nmcli"
printf '#!/bin/bash\necho "tailscale $*" >> "${CALLS}"\nexit 0\n' > "${PSTUB}/tailscale"
printf '#!/bin/bash\n:\n' > "${PSTUB}/tailscaled"
for t in rc-update rc-service sleep; do printf '#!/bin/bash\n:\n' > "${PSTUB}/${t}"; done
# curl: what the control server answers. CURL_ANSWER=none (default): nothing answers
# (000); tls: a verified HTTPS answer; untrusted: HTTPS only with -k; plain: http only.
cat > "${PSTUB}/curl" <<'EOF'
#!/bin/bash
k=0; url=""
for a in "$@"; do case "$a" in -k) k=1 ;; http://*|https://*) url="$a" ;; esac; done
code=000
case "${CURL_ANSWER:-none}:${url%%://*}:${k}" in
    tls:https:*|untrusted:https:1|plain:http:*) code=200 ;;
esac
printf '%s' "${code}"
[ "${code}" = 000 ] && exit 7
exit 0
EOF
chmod +x "${PSTUB}"/*
prov() {  # FUNC MANIFEST-JSON -> CALLS file content; BASE + NMROOT in the sandbox
    local d; d="${WORK}/prov-$RANDOM"; mkdir -p "${d}/keys/network" "${d}/keys/tailscale" "${d}/root"
    printf '%s\n' "$2" > "${d}/keys/provision.json"
    printf '[connection]\nid=mesh0\ntype=ethernet\nautoconnect=true\n' > "${d}/keys/network/mesh0.nmconnection"
    printf '[connection]\nid=spare\ntype=ethernet\nautoconnect=false\n' > "${d}/keys/network/spare.nmconnection"
    printf 'tskey-fixture-0123\n' > "${d}/keys/tailscale/authkey"
    CALLS="${d}/calls"; : > "${CALLS}"
    POUT="$(CALLS="${CALLS}" NM_DOWN="${NM_DOWN:-0}" CURL_ANSWER="${CURL_ANSWER:-none}" BASE="${d}/keys" MANIFEST="${d}/keys/provision.json" NMROOT="${d}/root" \
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
# E3b — the old http:// default against a control server that now serves HTTPS
# (headscale's default since 2026-11-10): migrated when the certificate verifies,
# migrated AND loudly flagged when it does not, kept when the server is still plain.
CURL_ANSWER=tls prov provision_tailscale "${TSM}"
case " $(grep '^tailscale up ' "${CALLS}") " in *" --login-server https://10.77.0.13:8080 "*) _ok "E3b an http://<pki>:8080 stick logs in at https://<pki>:8080 once the server's certificate verifies" ;; *) _bad "E3b no migration: $(grep '^tailscale up ' "${CALLS}") :: ${POUT}" ;; esac
CURL_ANSWER=untrusted prov provision_tailscale "${TSM}"
case " $(grep '^tailscale up ' "${CALLS}") " in *" --login-server https://10.77.0.13:8080 "*)
    printf '%s' "${POUT}" | grep -F 'does NOT trust' >/dev/null && _ok "E3b ...and an untrusted certificate is said loudly (the mesh CA is missing from the stick)" \
        || _bad "E3b untrusted certificate not flagged: ${POUT}" ;;
    *) _bad "E3b untrusted: $(grep '^tailscale up ' "${CALLS}")" ;; esac
CURL_ANSWER=plain prov provision_tailscale "${TSM}"
case " $(grep '^tailscale up ' "${CALLS}") " in *" --login-server http://10.77.0.13:8080 "*) _ok "E3b ...and a server still on plain http keeps the http:// URL" ;; *) _bad "E3b plain: $(grep '^tailscale up ' "${CALLS}")" ;; esac
prov provision_tailscale "$(printf '%s' "${TSM}" | jq -c '.tailscale.up_timeout="45s"')"
case " $(grep '^tailscale up ' "${CALLS}") " in *" --timeout 45s "*) _ok "E4 .tailscale.up_timeout overrides the bound" ;; *) _bad "E4 up_timeout ignored: $(grep '^tailscale up ' "${CALLS}")" ;; esac
prov provision_tailscale "$(printf '%s' "${TSM}" | jq -c '.tailscale.up_timeout="1d;reboot"')"
case " $(grep '^tailscale up ' "${CALLS}") " in *" --timeout 120s "*) _ok "E4 a malformed up_timeout falls back to 120s (never reaches the argv)" ;; *) _bad "E4 malformed up_timeout: $(grep '^tailscale up ' "${CALLS}")" ;; esac
prov provision_tailscale "$(printf '%s' "${TSM}" | jq -c '.tailscale.up_args="--accept-routes --timeout=30s"')"
[ "$(grep '^tailscale up ' "${CALLS}" | grep -o -- '--timeout' | wc -l)" -eq 1 ] \
    && _ok "E4 an explicit --timeout in up_args wins (no second --timeout)" || _bad "E4 duplicate timeout: $(grep '^tailscale up ' "${CALLS}")"

# ═══ E5/E6. the CONTROL node's own client: loopback login, session kept across the ═══
# ═══ headscale restart publish_cp_dns_record makes (2026-11-04 proof run)         ═══
# tailscale 1.78.1 + headscale 0.23.0 on http://10.77.0.13:8080: the restart left the
# pki node's own client "forcing port 443 dial due to recent noise dial" for six
# minutes (35x PollNetMap deadline, Online=false). tailscale's controlhttp never
# starts the plaintext dial once 443 is forced, EXCEPT for a login server on
# 127.0.0.1/localhost (controlclient/noise.go leaves httpsPort empty there). So the
# control node logs its own client in over loopback, at headscale's listen port, and
# after the restart checks the session and restarts tailscaled if it is gone.
echo "══ E5/E6. provision.sh: the control node's own client (loopback login; regain after the restart) ══"
CLIB="${WORK}/ctl.sh"
{
    echo 'log()  { echo "LOG $*"; }; warn() { echo "WARN $*"; }; have() { command -v "$1" >/dev/null 2>&1; }'
    echo 'jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }'
    echo 'resolve_endpoint() { echo "http://10.77.0.13:8080"; }; resolve_control_endpoint() { echo "http://10.77.0.13:8080"; }'
    echo 'publish_cp_dns_record() { echo "publish_cp_dns_record" >> "${CALLS}"; rc-service headscale restart; }'
    echo 'provision_headscale_policy_sync() { echo "provision_headscale_policy_sync" >> "${CALLS}"; }'
} > "${CLIB}"
sed -n '/^HEADSCALE_CONFIG=/p' "${PROV}" >> "${CLIB}"
extract "${PROV}" control_self_login_server "${CLIB}"
extract "${PROV}" control_client_regain "${CLIB}"
extract "${PROV}" provision_tailscale "${CLIB}"
extract "${PROV}" control_url_tls_migrate "${CLIB}"
extract "${PROV}" headscale_url_parts "${CLIB}"
CSTUB="${WORK}/cstub"; mkdir -p "${CSTUB}"
# tailscale: logs argv; `status --json` answers Online per TS_ONLINE: true | false |
# after-restart (true only once CALLS records a tailscaled restart).
cat > "${CSTUB}/tailscale" <<'EOF'
#!/bin/bash
echo "tailscale $*" >> "${CALLS}"
if [ "$1" = status ]; then
    on=false
    case "${TS_ONLINE:-false}" in
        true) on=true ;;
        after-restart) grep -F -x 'rc-service tailscaled restart' "${CALLS}" >/dev/null && on=true ;;
    esac
    printf '{"BackendState":"Running","Self":{"Online":%s}}\n' "${on}"
fi
exit 0
EOF
printf '#!/bin/bash\necho "rc-service $*" >> "${CALLS}"\nexit 0\n' > "${CSTUB}/rc-service"
printf '#!/bin/bash\necho "headscale $*" >> "${CALLS}"\nexit "${HS_RC:-0}"\n' > "${CSTUB}/headscale"
for t in rc-update sleep tailscaled; do printf '#!/bin/bash\n:\n' > "${CSTUB}/${t}"; done
cp "${PSTUB}/curl" "${CSTUB}/curl"   # nothing answers (CURL_ANSWER unset): URLs stay as written
chmod +x "${CSTUB}"/*
cprov() {  # FUNC MANIFEST-JSON [HEADSCALE-CONFIG-TEXT] -> CALLS + POUT
    local d; d="${WORK}/cprov-$RANDOM"; mkdir -p "${d}/keys/tailscale" "${d}/etc/headscale"
    printf '%s\n' "$2" > "${d}/keys/provision.json"
    printf 'tskey-fixture-0123\n' > "${d}/keys/tailscale/authkey"
    [ -n "${3-}" ] && printf '%s\n' "$3" > "${d}/etc/headscale/config.yaml"
    CALLS="${d}/calls"; : > "${CALLS}"
    POUT="$(CALLS="${CALLS}" BASE="${d}/keys" MANIFEST="${d}/keys/provision.json" HEADSCALE_CONFIG="${d}/etc/headscale/config.yaml" \
            TS_ONLINE="${TS_ONLINE:-true}" HS_RC="${HS_RC:-0}" \
            PATH="${CSTUB}:${PATH}" bash -c 'set -u; . "$1"; mkdir() { command mkdir "$@" 2>/dev/null || true; }; "$2"' _ "${CLIB}" "$1" 2>&1)"
}
CTL='{"tailscale":{"enabled":true,"authkey_file":"tailscale/authkey","up_args":"--advertise-tags=tag:hugmesh,tag:pki --accept-routes"},"headscale":{"enabled":true,"server_url":"http://10.77.0.13:8080"}}'
cprov provision_tailscale "${CTL}" $'server_url: http://10.77.0.13:8080\nlisten_addr: 0.0.0.0:8080\n'
up="$(grep '^tailscale up ' "${CALLS}")"
case " ${up} " in
    *" --login-server http://127.0.0.1:8080 "*) _ok "E5 the control node's OWN client logs in over loopback (http://127.0.0.1:8080), not the address the fleet dials" ;;
    *) _bad "E5 control node login server: '${up}'" ;;
esac
cprov provision_tailscale "${CTL}" $'listen_addr: "0.0.0.0:9090"\n'
case " $(grep '^tailscale up ' "${CALLS}") " in *" --login-server http://127.0.0.1:9090 "*) _ok "E5 ...at the port headscale's listen_addr names (9090)" ;; *) _bad "E5 listen_addr port ignored: $(grep '^tailscale up ' "${CALLS}")" ;; esac
cprov provision_tailscale "${CTL}"
case " $(grep '^tailscale up ' "${CALLS}") " in *" --login-server http://127.0.0.1:8080 "*) _ok "E5 ...and 8080 when no config.yaml is readable" ;; *) _bad "E5 no-config fallback: $(grep '^tailscale up ' "${CALLS}")" ;; esac
cprov provision_tailscale "${CTL}" $'server_url: https://10.77.0.13:8080\nlisten_addr: 0.0.0.0:8080\ntls_cert_path: "/var/lib/headscale/tls.crt"\n'
case " $(grep '^tailscale up ' "${CALLS}") " in *" --login-server https://127.0.0.1:8080 "*) _ok "E5 ...over https://127.0.0.1 when headscale serves TLS itself (its certificate names loopback)" ;; *) _bad "E5 TLS loopback: $(grep '^tailscale up ' "${CALLS}")" ;; esac
cprov provision_tailscale "${CTL}" $'server_url: https://hs.example.test:8080\nlisten_addr: 0.0.0.0:8080\ntls_cert_path: /etc/headscale/own.crt\n'
case " $(grep '^tailscale up ' "${CALLS}") " in *" --login-server https://hs.example.test:8080 "*) _ok "E5 ...and at the server_url when the config names an operator's own certificate" ;; *) _bad "E5 operator cert: $(grep '^tailscale up ' "${CALLS}")" ;; esac
cprov provision_tailscale "$(printf '%s' "${CTL}" | jq -c '.tailscale.login_server="http://mesh.example:8080"')"
case " $(grep '^tailscale up ' "${CALLS}") " in *" --login-server http://mesh.example:8080 "*) _ok "E5 an explicit .tailscale.login_server still wins on the control node" ;; *) _bad "E5 explicit login_server lost: $(grep '^tailscale up ' "${CALLS}")" ;; esac
cprov provision_tailscale "$(printf '%s' "${CTL}" | jq -c '.headscale.enabled=false')"
case " $(grep '^tailscale up ' "${CALLS}") " in *" --login-server http://10.77.0.13:8080 "*) _ok "E5 a WORKER still dials the control node's address (resolve_control_endpoint), never loopback" ;; *) _bad "E5 worker login server: $(grep '^tailscale up ' "${CALLS}")" ;; esac
# E6 — order and regain. With the session kept (Online true): publish -> headscale
# restart -> headscale answers -> status checked -> no tailscaled restart.
TS_ONLINE=true cprov provision_tailscale "${CTL}" $'listen_addr: 0.0.0.0:8080\n'
n_pub="$(grep -n -x 'publish_cp_dns_record' "${CALLS}" | cut -d: -f1)"
n_hs="$(grep -n -x 'rc-service headscale restart' "${CALLS}" | cut -d: -f1)"
n_ls="$(grep -n -x 'headscale nodes list' "${CALLS}" | head -1 | cut -d: -f1)"
n_st="$(grep -n -x 'tailscale status --json' "${CALLS}" | head -1 | cut -d: -f1)"
if [ -n "${n_pub}" ] && [ -n "${n_hs}" ] && [ -n "${n_ls}" ] && [ -n "${n_st}" ] && [ "${n_pub}" -lt "${n_hs}" ] && [ "${n_hs}" -lt "${n_ls}" ] && [ "${n_ls}" -lt "${n_st}" ] \
   && ! grep -F -x 'rc-service tailscaled restart' "${CALLS}" >/dev/null && printf '%s' "${POUT}" | grep -F 'mesh client is Online after the headscale restart' >/dev/null; then
    _ok "E6 after the CP-record headscale restart the control node waits for headscale, checks its own session, and leaves an Online client alone"
else
    _bad "E6 kept-session order (pub ${n_pub:-none} < hs-restart ${n_hs:-none} < nodes-list ${n_ls:-none} < status ${n_st:-none}): $(tr '\n' ';' < "${CALLS}") :: ${POUT}"
fi
TS_ONLINE=after-restart cprov provision_tailscale "${CTL}" $'listen_addr: 0.0.0.0:8080\n'
n_hs="$(grep -n -x 'rc-service headscale restart' "${CALLS}" | cut -d: -f1)"
n_tr="$(grep -n -x 'rc-service tailscaled restart' "${CALLS}" | cut -d: -f1)"
if [ -n "${n_hs}" ] && [ -n "${n_tr}" ] && [ "${n_hs}" -lt "${n_tr}" ] \
   && printf '%s' "${POUT}" | grep -F 'NOT online' >/dev/null && printf '%s' "${POUT}" | grep -F 'mesh client is Online after the tailscaled restart' >/dev/null; then
    _ok "E6 a session lost to the restart (Online false) -> tailscaled is restarted after headscale, and the regained session is logged"
else
    _bad "E6 lost-session regain (hs-restart ${n_hs:-none}, ts-restart ${n_tr:-none}): $(tr '\n' ';' < "${CALLS}") :: ${POUT}"
fi
n_before="$(grep -c -x 'tailscale status --json' "${CALLS}")"
[ "${n_before}" -ge 21 ] && _ok "E6 the Online check is polled (${n_before} status reads across both windows), not a one-shot" || _bad "E6 only ${n_before} status read(s)"
TS_ONLINE=false cprov provision_tailscale "${CTL}" $'listen_addr: 0.0.0.0:8080\n'
[ "$(grep -c -x 'rc-service tailscaled restart' "${CALLS}")" -eq 1 ] && printf '%s' "${POUT}" | grep -F 'still not online after the tailscaled restart' >/dev/null \
    && _ok "E6 a session that never comes back: ONE tailscaled restart, then a warning that names it (bounded, never a loop)" \
    || _bad "E6 never-online: restarts=$(grep -c -x 'rc-service tailscaled restart' "${CALLS}") :: ${POUT}"
HS_RC=1 TS_ONLINE=true cprov provision_tailscale "${CTL}" $'listen_addr: 0.0.0.0:8080\n'
printf '%s' "${POUT}" | grep -F 'headscale did not answer within 60s' >/dev/null && grep -F -x 'tailscale status --json' "${CALLS}" >/dev/null \
    && _ok "E6 headscale never answering is bounded (30 tries) and the client is still checked" || _bad "E6 headscale-down bound: ${POUT}"

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

# ═══════ G. mesh routes are APPROVED on the control node (peers exist only through them) ═══════
# headscale 0.23 lists a node in a peer's netmap only through an ENABLED route
# (CanAccess); the product's policy names no node address. The proof run's worker
# saw peers=0. provision.sh's backfill called `headscale nodes approve-routes`,
# which 0.23.0 does not have (0.25 added it). gen-headscale-policy.sh now approves
# every advertised-but-not-enabled mesh route of a tag:hugmesh node on every tick,
# with the CLI the running headscale has, and provision.sh calls it.
echo "══ G. gen-headscale-policy.sh approve_mesh_routes (0.23 routes table; 0.25 node routes) ══"
GEN="${REPO}/specs/usr/sbin/gen-headscale-policy.sh"
GLIB="${WORK}/routes.sh"
{
    echo 'log()  { echo "LOG $*"; }; warn() { echo "WARN $*"; }; have() { command -v "$1" >/dev/null 2>&1; }'
    sed -n '/^MESH_ROUTES=/p' "${GEN}"
} > "${GLIB}"
extract "${GEN}" approve_mesh_routes "${GLIB}"
GSTUB="${WORK}/gstub"; mkdir -p "${GSTUB}"
cat > "${GSTUB}/headscale" <<'EOF'
#!/bin/bash
echo "headscale $*" >> "${CALLS}"
case "$*" in
    "nodes list -o json")  printf '%s\n' "${NODES_JSON}" ;;
    "routes list -o json") [ "${HS_NO_ROUTES:-0}" = 1 ] && exit 1; printf '%s\n' "${ROUTES_JSON}" ;;
    "routes enable -r "*)  [ "${ENABLE_FAIL:-}" = "$4" ] && exit 1 ;;
esac
exit 0
EOF
chmod +x "${GSTUB}/headscale"
NODES_JSON='[{"id":1,"name":"hugmesh-pki-qemu","given_name":"hugmesh-pki-qemu","valid_tags":["tag:hugmesh","tag:pki"],"forced_tags":[]},
 {"id":2,"name":"hugmesh-backend-qemu","given_name":"hugmesh-backend-qemu","valid_tags":[],"forced_tags":["tag:hugmesh","tag:be"]},
 {"id":3,"name":"rogue","given_name":"rogue","valid_tags":[],"forced_tags":[]}]'
ROUTES_JSON='[{"id":"11","node":{"id":1,"given_name":"hugmesh-pki-qemu"},"prefix":"10.244.0.0/16","advertised":true,"enabled":false},
 {"id":"12","node":{"id":1,"given_name":"hugmesh-pki-qemu"},"prefix":"10.96.0.0/12","advertised":true,"enabled":true},
 {"id":"13","node":{"id":2,"given_name":"hugmesh-backend-qemu"},"prefix":"10.244.0.0/16","advertised":true,"enabled":false},
 {"id":"14","node":{"id":2,"given_name":"hugmesh-backend-qemu"},"prefix":"192.168.5.0/24","advertised":true,"enabled":false},
 {"id":"15","node":{"id":3,"given_name":"rogue"},"prefix":"10.244.0.0/16","advertised":true,"enabled":false},
 {"id":"16","node":{"id":2,"given_name":"hugmesh-backend-qemu"},"prefix":"10.96.0.0/12","advertised":false,"enabled":false}]'
groutes() {  # -> CALLS + GOUT
    CALLS="${WORK}/gcalls"; : > "${CALLS}"
    GOUT="$(CALLS="${CALLS}" NODES_JSON="${NODES_JSON}" ROUTES_JSON="${ROUTES_JSON}" HS_NO_ROUTES="${HS_NO_ROUTES:-0}" ENABLE_FAIL="${ENABLE_FAIL:-}" \
            PATH="${GSTUB}:${PATH}" bash -c 'set -u; . "$1"; approve_mesh_routes' _ "${GLIB}" 2>&1)"
}
groutes
en="$(grep '^headscale routes enable -r ' "${CALLS}" | awk '{print $5}' | sort | tr '\n' ' ')"
[ "${en}" = "11 13 " ] && _ok "G1 0.23: exactly the advertised, not-enabled MESH routes of tag:hugmesh nodes are enabled (11 pki 10.244/16, 13 backend 10.244/16); an enabled one, a non-mesh prefix, an untagged node and a withdrawn route are left alone" \
    || _bad "G1 enabled '${en}' (want '11 13 '): $(tr '\n' ';' < "${CALLS}") :: ${GOUT}"
printf '%s' "${GOUT}" | grep -F 'approved mesh route 10.244.0.0/16 for hugmesh-backend-qemu (route 13)' >/dev/null && _ok "G1 ...and each approval is logged with prefix, node and route id" || _bad "G1 log: ${GOUT}"
! grep -F 'approve-routes' "${CALLS}" >/dev/null && _ok "G1 ...never calling the 0.25 'nodes approve-routes' on a headscale that has a routes table" || _bad "G1 called approve-routes on 0.23: $(tr '\n' ';' < "${CALLS}")"
ENABLE_FAIL=11 groutes
printf '%s' "${GOUT}" | grep -F 'WARN could not enable route 11' >/dev/null && grep -F 'routes enable -r 13' "${CALLS}" >/dev/null \
    && _ok "G1 a route headscale will not enable is warned about and the rest are still enabled" || _bad "G1 enable failure: ${GOUT} :: $(tr '\n' ';' < "${CALLS}")"
HS_NO_ROUTES=1 groutes
ap="$(grep '^headscale nodes approve-routes -i ' "${CALLS}" | awk '{print $5}' | sort | tr '\n' ' ')"
[ "${ap}" = "1 2 " ] && grep -F -- '-r 10.244.0.0/16,10.96.0.0/12' "${CALLS}" >/dev/null && ! grep -F 'routes enable' "${CALLS}" >/dev/null \
    && _ok "G2 0.25+ (no routes table): 'nodes approve-routes' for the tag:hugmesh nodes only (1, 2; never the untagged 3), with the mesh CIDRs" \
    || _bad "G2 approve-routes ids '${ap}' (want '1 2 '): $(tr '\n' ';' < "${CALLS}")"
# G3 — wired: every renderer tick approves BEFORE the export gate (_init's fail-closed
# exit), `--approve-routes` is a standalone entry, and provision.sh runs it after the
# control node's own join (and no longer calls the 0.25-only subcommand itself).
n_ap="$(grep -n -x '    approve_mesh_routes' "${GEN}" | head -1 | cut -d: -f1)"
n_in="$(grep -n -F '    _init || exit 0' "${GEN}" | head -1 | cut -d: -f1)"
[ -n "${n_ap}" ] && [ -n "${n_in}" ] && [ "${n_ap}" -lt "${n_in}" ] && grep -F -- '--approve-routes) approve_mesh_routes; exit 0' "${GEN}" >/dev/null \
    && _ok "G3 gen-headscale-policy.sh: approve_mesh_routes runs every tick BEFORE the fail-closed export gate (line ${n_ap} < ${n_in}); --approve-routes is a standalone entry" \
    || _bad "G3 renderer wiring: approve line ${n_ap:-none}, _init line ${n_in:-none}"
n_rg="$(grep -n -x '        control_client_regain' "${PROV}" | head -1 | cut -d: -f1)"
n_ar="$(grep -n -x '        approve_mesh_routes_now' "${PROV}" | head -1 | cut -d: -f1)"
[ -n "${n_rg}" ] && [ -n "${n_ar}" ] && [ "${n_ar}" -eq $((n_rg + 1)) ] && grep -F -- '/usr/sbin/gen-headscale-policy.sh --approve-routes' "${PROV}" >/dev/null \
    && ! grep -F 'headscale nodes approve-routes' "${PROV}" >/dev/null \
    && _ok "G3 provision.sh: the control node approves routes right after its own join is regained, through the renderer, and never calls the 0.25-only subcommand itself" \
    || _bad "G3 provision wiring: regain ${n_rg:-none}, approve ${n_ar:-none}, direct approve-routes: $(grep -c 'headscale nodes approve-routes' "${PROV}")"

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]
