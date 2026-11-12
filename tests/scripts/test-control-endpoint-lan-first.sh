#!/usr/bin/env bash
# test-control-endpoint-lan-first.sh — guard for the LAN-first control endpoint.
#
# A worker's first boot happens before go-live, so no public name answers yet. Its
# keys-provision used to dial the baked public HEADSCALE_URL ahead of the pki node's
# LAN address, and a LAN-first mesh (no public DNS, IP or port-forward) never reached
# its control plane. Now, BEFORE go-live, a worker dials the pki node's CONFIRMED LAN
# address (provision.json .mesh.pki_lan_ip, stamped by gen-provision-keys.sh
# --pki-ip; the Studio requires it, with a static IP or a DHCP reservation behind
# it), and the pki node admits its headscale port from the RFC1918 ranges through
# an ENV=prod firewalld that otherwise drops it. This guard holds that line:
#
#   A. keys-provision resolve_control_endpoint, run for real: the precedence before
#      and after go-live (both go-live spellings), explicit overrides, the template
#      example never outranking the baked URL, malformed values never interpolated,
#      stdout carrying only the URL.
#      A2. "after go-live" is a fact about the MESH, and a worker's own image cannot
#      know it (release-state is the node's posture, internal by default and absent
#      on most images; the marker arrives only after the join). So the resolver ASKS:
#      the baked URL wins as soon as it answers as a control server, on any image, on
#      or off the pki LAN; the LAN address holds while it does not. Run against a
#      stub network (curl, sleep, tailscale on PATH): a live mesh, a captive portal,
#      a parked name, an unverifiable certificate, a late uplink, a late pki, nothing
#      at all, and the shape of the question itself (never -k, bounded, no redirect).
#   B. keys-provision headscale_lan_control_marker, run for real.
#   C. hugmesh-coturn-firewall against nft/firewall-cmd stubs: the marker admits
#      EXACTLY one rich rule per RFC1918 range for that port and nothing else; a
#      changed port, a removed or a malformed marker takes ours back out; a foreign
#      rich rule is never touched; the nftables table gains nothing.
#   D. gen-provision-keys.sh --pki-ip, run for real: stamped on worker and pki
#      sticks, the env spelling, refusals BEFORE any output is built, the warning
#      without it. The Studio's rule (studio/hugmesh_studio/core/pki_lan.py) and the
#      script's refusal agree on a table of values.
#   E. Studio wiring: the field, the keys argv, the Fleet env, both faces.
#   F. negative controls: each mutation of a copy of the tree must turn A-G red.
#   G. every image can ask: all ten builders install the same keys-provision, start
#      from a Gentoo stage3 (which carries curl) and request net-misc/curl in their
#      base packages.list, behind the requested-atom completeness gate.
#
# Offline, no docker.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="${REPO}/tests/scripts/test-control-endpoint-lan-first.sh"
ROOT="${LANFIRST_GUARD_ROOT:-${REPO}}"
. "${REPO}/tests/lib/guard-preflight.sh"
guard_require_tools python3 jq awk sed openssl ssh-keygen

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PROV="${ROOT}/specs/etc/keys-provision/provision.sh"
FW="${ROOT}/specs/usr/sbin/hugmesh-coturn-firewall"
GENKEYS="${ROOT}/scripts/gen-provision-keys.sh"

# ── A. resolve_control_endpoint ──────────────────────────────────────────────
echo "-- A. keys-provision resolve_control_endpoint (run for real) --"
fn() {  # fn <name>: print one top-level function of provision.sh
    awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f {print} f && /^}/ {exit}' "${PROV}"
}
{
    echo 'log()  { echo "[keys-provision] $*"; }'
    echo 'warn() { log "WARNING: $*"; }'
    echo 'jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }'
    echo 'have() { command -v "$1" >/dev/null 2>&1; }'
    echo 'resolve_magic_dns_domain() { echo headnet.internal; }'
    for f in node_is_public ipv4_literal resolve_pki_lan_ip resolve_mesh_control_transport resolve_mesh_control_name \
             resolve_mesh_control_onion resolve_mesh_control_port mesh_control_active mesh_control_url \
             resolve_control_endpoint; do
        fn "${f}"
    done
} > "${WORK}/rce.sh"
for f in node_is_public ipv4_literal resolve_pki_lan_ip resolve_control_endpoint; do
    grep -a -E "^${f}\(\) \{" "${WORK}/rce.sh" >/dev/null \
        && ok "provision.sh defines ${f}" || bad "provision.sh has no ${f}"
done
RCE_FNS="node_is_public ipv4_literal resolve_pki_lan_ip control_probe_capver control_server_answers
control_probe_wait_seconds control_endpoint_mesh_is_live resolve_control_endpoint"
{
    echo 'log()  { echo "[keys-provision] $*"; }'
    echo 'warn() { log "WARNING: $*"; }'
    # NET_MISSING names tools this "image" does not carry (a host cannot un-install curl).
    echo 'have() { case " ${NET_MISSING:-} " in *" $1 "*) return 1 ;; esac; command -v "$1" >/dev/null 2>&1; }'
    echo 'jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }'
    for f in ${RCE_FNS}; do
        fn "${f}"
    done
} > "${WORK}/rce.sh"
for f in ${RCE_FNS}; do
    grep -a -E "^${f}\(\) \{" "${WORK}/rce.sh" >/dev/null \
        && ok "provision.sh defines ${f}" || bad "provision.sh has no ${f}"
done
# The stub network. The resolver's questions go to ${NET}/curl, which answers from
# ${NET_WORLD}: one "<url-prefix> <how>" per line, first match wins, and a URL no
# line names does not resolve (curl rc 6). <how>:
#   key      a control server: headscale's /key body (what 0.23.0 sends for v >= 39)
#   key@N    nothing accepts the connection (rc 7) until this prefix was asked N times
#   html     HTTP 200 with a captive portal's page
#   json     HTTP 200 with JSON that is not a control server's key
#   badkey   a .publicKey that is not a Noise machine key
#   empty    HTTP 200 and no body (what headscale sends when v < 39)
#   big      HTTP 200 with 200 KiB of body
#   rc:N     curl exits N (6 no DNS, 7 refused, 22 HTTP error, 28 timeout, 60 TLS)
# Every question is appended to ${NET_LOG}. ${NET}/sleep returns at once and counts.
NET="${WORK}/net"; mkdir -p "${NET}"
cat > "${NET}/curl" <<'EOF'
#!/bin/bash
url="${*: -1}"
printf '%s\n' "$*" >> "${NET_LOG}"
KEY='{"legacyPublicKey":"mkey:0000000000000000000000000000000000000000000000000000000000000000","publicKey":"mkey:57b7f8463bd3551893eaab0efe205faaa1cccc8981370429a0389b9db296a011"}'
while read -r prefix how; do
    [ -n "${prefix}" ] || continue
    case "${url}" in "${prefix}"*) ;; *) continue ;; esac
    case "${how}" in
        key)    printf '%s\n' "${KEY}"; exit 0 ;;
        key@*)  [ "$(grep -a -c -F -- " ${prefix}" "${NET_LOG}")" -ge "${how#key@}" ] || exit 7
                printf '%s\n' "${KEY}"; exit 0 ;;
        html)   echo '<html><body>Sign in to this network</body></html>'; exit 0 ;;
        json)   echo '{"status":"pass"}'; exit 0 ;;
        badkey) echo '{"publicKey":"mkey:not-a-key"}'; exit 0 ;;
        empty)  exit 0 ;;
        big)    head -c 204800 /dev/zero | tr '\0' 'x'; exit 0 ;;
        rc:*)   exit "${how#rc:}" ;;
    esac
done < "${NET_WORLD}"
exit 6
EOF
printf '#!/bin/bash\necho "sleep $*" >> "${NET_LOG}.sleep"\nexit 0\n' > "${NET}/sleep"
# tailscale: `version --json` with .cap = ${NET_TS_CAP}; unset = a client that cannot say.
printf '#!/bin/bash\n[ -n "${NET_TS_CAP:-}" ] || exit 1\nprintf %%s "{\\"cap\\": ${NET_TS_CAP}}"\n' > "${NET}/tailscale"
chmod +x "${NET}/curl" "${NET}/sleep" "${NET}/tailscale"
# The baked URL file is a literal path in the resolver; point the extracted copy at a
# scratch file. A renamed path makes the sed a no-op and the baked-URL cases go red.
grep -a -F '/etc/hugmesh/headscale-url' "${WORK}/rce.sh" >/dev/null \
    && ok "resolve_control_endpoint reads the baked /etc/hugmesh/headscale-url" \
    || bad "resolve_control_endpoint no longer reads /etc/hugmesh/headscale-url"
sed -i "s#/etc/hugmesh/headscale-url#${WORK}/baked-url#g" "${WORK}/rce.sh"

BAKED="https://headscale.brand.example"
# rce <manifest-json> <baked|-> <release-state|-> <go-live marker 0|1>  -> stdout of the resolver
LANURL="http://192.168.7.20:8080"
# Before go-live, as a worker on the pki LAN sees it: the pki answers and the public
# name does not resolve. The world of every case that names none.
WORLD_BEFORE="${LANURL} key"
# rce <manifest-json> <baked|-> <release-state|-> <go-live marker 0|1> [world]  -> stdout of the resolver
rce() {
    local m="${WORK}/m.json" rs="${WORK}/release-state" gl="${WORK}/go-live"
    printf '%s\n' "$1" > "${m}"
    rm -f "${WORK}/baked-url" "${rs}" "${gl}"
    [ "$2" = "-" ] || printf '%s\n' "$2" > "${WORK}/baked-url"
    [ "$3" = "-" ] || printf '%s\n' "$3" > "${rs}"
    [ "$4" = 1 ] && : > "${gl}"
    MANIFEST="${m}" HUGMESH_RELEASE_STATE_FILE="${rs}" HUGMESH_GO_LIVE_MARKER="${gl}" \
        bash -c '. "$1"; resolve_control_endpoint' _ "${WORK}/rce.sh" 2>"${WORK}/rce.err"
}
    : > "${WORK}/net.log"; : > "${WORK}/net.log.sleep"
    printf '%s\n' "${5-${WORLD_BEFORE}}" > "${WORK}/net.world"
    PATH="${NET}:${PATH}" NET_WORLD="${WORK}/net.world" NET_LOG="${WORK}/net.log" \
        MANIFEST="${m}" HUGMESH_RELEASE_STATE_FILE="${rs}" HUGMESH_GO_LIVE_MARKER="${gl}" \
        bash -c '. "$1"; resolve_control_endpoint' _ "${WORK}/rce.sh" 2>"${WORK}/rce.err"
}
asked()  { grep -a -c -F -- "$1" "${WORK}/net.log"; }            # how often a URL (or a flag) was asked
rounds() { grep -a -c -F -- " ${BAKED}/key" "${WORK}/net.log"; }  # one baked question per round
slept()  { grep -a -c . "${WORK}/net.log.sleep"; }
said()   { grep -a -F -- "$1" "${WORK}/rce.err" >/dev/null; }     # a line of the resolver's log
expect() {  # expect <label> <want> <got>
    if [ "$3" = "$2" ]; then ok "$1 -> ${2:-<empty>}"; else bad "$1: want '${2:-<empty>}', got '$3'"; fi
}
NODES='"nodes":[{"name":"p","ip":"10.0.0.10","role":"pki"},{"name":"w","ip":"10.0.0.30","role":"host"}]'
LAN="{\"mesh\":{\"endpoint\":\"\",\"pki_lan_ip\":\"192.168.7.20\"},${NODES}}"
expect "before go-live (no release-state file), confirmed pki address beats the baked public URL" \
    "https://192.168.7.20:8080" "$(rce "${LAN}" "${BAKED}" - 0)"
grep -a -F 'before go-live' "${WORK}/rce.err" >/dev/null \
    && ok "the LAN choice is logged (to stderr, not the value)" || bad "the LAN choice is not logged on stderr"
expect "release-state=internal is before go-live" "https://192.168.7.20:8080" "$(rce "${LAN}" "${BAKED}" internal 0)"
expect "release-state=public: the baked URL wins again" "${BAKED}" "$(rce "${LAN}" "${BAKED}" public 0)"
expect "go-live marker present: the baked URL wins again" "${BAKED}" "$(rce "${LAN}" "${BAKED}" internal 1)"
expect "past go-live with NO baked URL falls to the .nodes[] pki row" "https://192.168.7.20:8080" \
    "http://192.168.7.20:8080" "$(rce "${LAN}" "${BAKED}" - 0)"
grep -a -F 'before go-live' "${WORK}/rce.err" >/dev/null \
    && ok "the LAN choice is logged (to stderr, not the value)" || bad "the LAN choice is not logged on stderr"
expect "release-state=internal is before go-live" "http://192.168.7.20:8080" "$(rce "${LAN}" "${BAKED}" internal 0)"
expect "release-state=public: the baked URL wins again" "${BAKED}" "$(rce "${LAN}" "${BAKED}" public 0)"
expect "go-live marker present: the baked URL wins again" "${BAKED}" "$(rce "${LAN}" "${BAKED}" internal 1)"
expect "past go-live with NO baked URL falls to the .nodes[] pki row" "http://192.168.7.20:8080" \
    "$(rce "{\"mesh\":{\"pki_lan_ip\":\"192.168.7.20\"},\"nodes\":[{\"ip\":\"192.168.7.20\",\"role\":\"pki\"}]}" - public 0)"
expect ".mesh.endpoint outranks the LAN address" "https://override.example" \
    "$(rce "{\"mesh\":{\"endpoint\":\"https://override.example\",\"pki_lan_ip\":\"192.168.7.20\"},${NODES}}" "${BAKED}" - 0)"
expect ".headscale.server_url outranks everything" "https://explicit.example" \
    "$(rce "{\"headscale\":{\"server_url\":\"https://explicit.example\"},\"mesh\":{\"endpoint\":\"https://override.example\",\"pki_lan_ip\":\"192.168.7.20\"},${NODES}}" "${BAKED}" - 0)"
expect "no confirmed address: the template example row does NOT outrank the baked URL" "${BAKED}" \
    "$(rce "{\"mesh\":{\"endpoint\":\"\"},${NODES}}" "${BAKED}" - 0)"
expect "no confirmed address, nothing baked: the .nodes[] pki row" "https://10.0.0.10:8080" \
    "$(rce "{\"mesh\":{\"endpoint\":\"\"},${NODES}}" - - 0)"
expect "an IPv6 .nodes[] pki row is bracketed" "https://[fd00::10]:8080" \
expect "no confirmed address, nothing baked: the .nodes[] pki row" "http://10.0.0.10:8080" \
    "$(rce "{\"mesh\":{\"endpoint\":\"\"},${NODES}}" - - 0)"
expect "an IPv6 .nodes[] pki row is bracketed" "http://[fd00::10]:8080" \
    "$(rce '{"nodes":[{"ip":"fd00::10","role":"pki"}]}' - - 0)"
for evil in '10.0.0.1\n10.6.6.6' '10.0.0.300' 'evil.example' '10.0.0.1:443' '10.0.0.1 x' '10.0.0.1/x'; do
    expect "malformed .mesh.pki_lan_ip ${evil} is ignored (baked URL)" "${BAKED}" \
        "$(rce "{\"mesh\":{\"pki_lan_ip\":\"${evil}\"},${NODES}}" "${BAKED}" - 0)"
done
expect "a malformed .nodes[] pki row is never interpolated" "" \
    "$(rce '{"nodes":[{"ip":"10.0.0.1/evil#","role":"pki"}]}' - - 0)"
out="$(rce "${LAN}" "${BAKED}" - 0)"
[ "$(printf '%s' "${out}" | wc -l)" -eq 0 ] && [[ "${out}" != *"["* ]] \
    && ok "stdout is the URL alone (one line, no log text)" || bad "stdout carries more than the URL: '${out}'"

# ── A2. the mesh is live when its baked URL answers ──────────────────────────
echo "-- A2. \"after go-live\" is asked of the network, not read off the image --"
WORLD_LIVE_OFFLAN="${BAKED} key
${LANURL} rc:7"
WORLD_LIVE_ONLAN="${BAKED} key
${LANURL} key"
# The reviewer's worker: the mesh is live, the image was built internal, no marker,
# and the pki LAN is out of reach. It dialled the LAN address and never joined.
expect "mesh live, image internal, no marker, OFF the pki LAN: the baked URL" \
    "${BAKED}" "$(rce "${LAN}" "${BAKED}" internal 0 "${WORLD_LIVE_OFFLAN}")"
said 'correction' && ok "the correction is logged (stderr)" || bad "the live-mesh correction is not logged"
[ "$(asked " ${LANURL}")" -eq 0 ] && ok "a worker of a live mesh never contacts the pki LAN address" \
    || bad "a live mesh's worker still asked the pki LAN address ($(asked " ${LANURL}")x)"
expect "mesh live, an image with NO release-state file (desktop, appliance, Jetson): the baked URL" \
    "${BAKED}" "$(rce "${LAN}" "${BAKED}" - 0 "${WORLD_LIVE_OFFLAN}")"
expect "mesh live, worker ON the pki LAN (both answer): the baked URL wins" \
    "${BAKED}" "$(rce "${LAN}" "${BAKED}" internal 0 "${WORLD_LIVE_ONLAN}")"
[ "$(asked " ${LANURL}")" -eq 0 ] && ok "when both answer, the LAN address is not even asked" \
    || bad "the LAN address was asked although the baked URL answered"
out="$(rce "${LAN}" "${BAKED}" internal 0 "${WORLD_LIVE_OFFLAN}")"
[ "$(printf '%s' "${out}" | wc -l)" -eq 0 ] && [[ "${out}" != *"["* ]] \
    && ok "live: stdout is still the URL alone" || bad "live: stdout carries more than the URL: '${out}'"
HB="http://scale.acme.example:8080"
expect "an http:// baked URL that answers as a control server is live too" "${HB}" \
    "$(rce "${LAN}" "${HB}" internal 0 "${HB} key")"

# Before go-live the baked URL does not answer as a control server, whatever else does.
expect "before go-live: the public name does not resolve, the pki answers" "${LANURL}" \
    "$(rce "${LAN}" "${BAKED}" internal 0 "${WORLD_BEFORE}")"
said 'confirmed' && said 'its name does not resolve' && ok "the log says why the baked URL lost (no DNS)" \
    || bad "no reason logged for the baked URL: $(tail -1 "${WORK}/rce.err")"
[ "$(rounds)" -eq 1 ] && [ "$(slept)" -eq 0 ] && ok "the usual first boot asks one round and never sleeps" \
    || bad "the usual first boot took $(rounds) round(s), $(slept) sleep(s)"
for how in rc:28 rc:7 rc:22 rc:60 html json badkey empty big; do
    expect "before go-live: the baked URL answers '${how}', not as a control server: the LAN address holds" "${LANURL}" \
        "$(rce "${LAN}" "${BAKED}" internal 0 "${BAKED} ${how}
${WORLD_BEFORE}")"
    case "${how}" in
        rc:28) said 'no answer within 4s' || bad "a timeout is not named in the log" ;;
        rc:60) said 'TLS certificate does not verify' || bad "an unverifiable certificate is not named in the log" ;;
        html)  said 'not as a control server' || bad "a captive portal's page is not named in the log" ;;
    esac
done
expect "a baked value that is not an http(s) URL is never asked" "${LANURL}" \
    "$(rce "${LAN}" "file:///etc/hostname" internal 0 "file:///etc/hostname key
${WORLD_BEFORE}")"
[ "$(asked 'file://')" -eq 0 ] && ok "…curl never sees it" || bad "curl was handed a file:// URL"

# Waiting. One question asked before the uplink is up would pin the wrong answer.
expect "a late uplink (the baked URL answers on the 3rd round): waited for, the baked URL" "${BAKED}" \
    "$(rce "${LAN}" "${BAKED}" internal 0 "${BAKED} key@3
${LANURL} rc:7")"
[ "$(rounds)" -eq 3 ] && [ "$(slept)" -eq 2 ] && ok "three rounds, two sleeps" \
    || bad "late uplink: $(rounds) round(s), $(slept) sleep(s)"
[ "$(grep -a -c -F 'asking again' "${WORK}/rce.err")" -eq 1 ] && ok "the wait is announced once" \
    || bad "the wait is announced $(grep -a -c -F 'asking again' "${WORK}/rce.err") times"
expect "a late pki before go-live (the LAN address answers on the 3rd round): the pki LAN address" "${LANURL}" \
    "$(rce "${LAN}" "${BAKED}" internal 0 "${LANURL} key@3")"
[ "$(rounds)" -eq 3 ] && ok "…after three rounds" || bad "late pki: $(rounds) round(s)"
NOWAIT="{\"mesh\":{\"pki_lan_ip\":\"192.168.7.20\",\"control_probe_wait\":0},${NODES}}"
expect "nothing answers and no wait is asked for: the pki LAN address (before go-live is the default)" "${LANURL}" \
    "$(rce "${NOWAIT}" "${BAKED}" internal 0 "")"
said 'WARNING' && said 'neither the baked HEADSCALE_URL' && said '.provision-force' \
    && ok "…with a WARNING that names both and says what to do" || bad "no WARNING when nothing answers"
[ "$(rounds)" -eq 1 ] && [ "$(slept)" -eq 0 ] && ok "…in one round" || bad "wait 0: $(rounds) round(s), $(slept) sleep(s)"
TWOSEC="{\"mesh\":{\"pki_lan_ip\":\"192.168.7.20\",\"control_probe_wait\":\"2s\"},${NODES}}"
t0="${SECONDS}"
expect "nothing ever answers: the wait ends (2 s asked for) with the pki LAN address" "${LANURL}" \
    "$(rce "${TWOSEC}" "${BAKED}" internal 0 "")"
[ "$((SECONDS - t0))" -le 20 ] && [ "$(rounds)" -ge 2 ] && ok "…bounded: $(rounds) rounds in $((SECONDS - t0)) s" \
    || bad "the wait is not bounded as asked: $(rounds) round(s) in $((SECONDS - t0)) s"
cpw() {  # cpw <json value of .mesh.control_probe_wait>  -> seconds
    printf '%s\n' "{\"mesh\":{\"control_probe_wait\":$1}}" > "${WORK}/w.json"
    MANIFEST="${WORK}/w.json" bash -c '. "$1"; control_probe_wait_seconds' _ "${WORK}/rce.sh" 2>/dev/null
}
for pair in 'null=45' '0=0' '30=30' '"30s"=30' '600=600' '601=45' '"abc"=45' '-1=45' '1.5=45' '"5m"=45'; do
    expect ".mesh.control_probe_wait ${pair%%=*}" "${pair##*=}" "$(cpw "${pair%%=*}")"
done

# The question itself: what `tailscale up` asks first, verified, bounded, no detour.
NET_TS_CAP=123 rce "${LAN}" "${BAKED}" internal 0 "${WORLD_BEFORE}" >/dev/null
q=" $(grep -a -F -- " ${BAKED}/key" "${WORK}/net.log" | head -1) "
ql=" $(grep -a -F -- " ${LANURL}/key" "${WORK}/net.log" | head -1) "
[[ "${q}" == *" ${BAKED}/key?v=123 " ]] \
    && ok "the question is the client's own first request: GET <url>/key?v=<its capability version>" \
    || bad "the baked URL was not asked for /key?v=123:${q}"
[[ "${q}" == *" --max-time 4 "* && "${q}" == *" --connect-timeout 4 "* && "${ql}" == *" --max-time 3 "* ]] \
    && ok "bounded: 4 s for the baked URL, 3 s for the LAN address" || bad "the questions are not bounded:${q}|${ql}"
[[ "${q}" != *" -k "* && "${q}" != *" --insecure "* && "${ql}" != *" -k "* && "${ql}" != *" --insecure "* ]] \
    && ok "certificates are verified (never -k)" || bad "a question carries -k/--insecure:${q}|${ql}"
[[ "${q}" != *" -L "* && "${q}" != *" --location "* && "${q}" == *" --max-redirs 0 "* ]] \
    && ok "no redirect is followed" || bad "a redirect could be followed:${q}"
[[ "${q}" == *" --proto =http,https "* ]] && ok "http(s) only" || bad "the protocol is not restricted:${q}"
rce "${LAN}" "${BAKED}" internal 0 "${WORLD_BEFORE}" >/dev/null
[ "$(asked " ${BAKED}/key?v=109")" -eq 1 ] && ok "a client that cannot say its capability version: v=109 (tailscale 1.78.1)" \
    || bad "no v=109 fallback: $(head -1 "${WORK}/net.log")"

# What cannot be asked, and what need not be.
expect "an image with no curl cannot ask: the pki LAN address" "${LANURL}" \
    "$(NET_MISSING=curl rce "${LAN}" "${BAKED}" internal 0 "${WORLD_LIVE_OFFLAN}")"
said 'no curl on this image' && [ "$(asked '/key')" -eq 0 ] && ok "…and it says so, loudly, having asked nothing" \
    || bad "no curl: not announced, or something was asked anyway"
expect "an image with no \`timeout\` still asks (curl's own bound)" "${BAKED}" \
    "$(NET_MISSING=timeout rce "${LAN}" "${BAKED}" internal 0 "${WORLD_LIVE_OFFLAN}")"
expect "nothing baked: the pki LAN address" "${LANURL}" "$(rce "${LAN}" - internal 0 "")"
[ "$(asked '/key')" -eq 0 ] && ok "…at once, nothing asked (there is nothing to prefer)" || bad "nothing baked, yet $(asked '/key') question(s)"
expect "the baked URL IS the pki LAN URL: nothing to ask" "${LANURL}" "$(rce "${LAN}" "${LANURL}/" internal 0 "")"
[ "$(asked '/key')" -eq 0 ] && ok "…and nothing is asked" || bad "baked == LAN, yet $(asked '/key') question(s)"
for spec in "public 0 release-state=public" "internal 1 the go-live marker"; do
    read -r past_rs past_mk past_why <<<"${spec}"
    expect "a node past go-live itself (${past_why}): the baked URL, as before" "${BAKED}" \
        "$(rce "${LAN}" "${BAKED}" "${past_rs}" "${past_mk}" "${WORLD_BEFORE}")"
    [ "$(asked '/key')" -eq 0 ] && ok "…asking nothing (${past_why})" \
        || bad "a node past go-live asked $(asked '/key') question(s) (${past_why})"
done
rce "{\"mesh\":{\"endpoint\":\"https://override.example\",\"pki_lan_ip\":\"192.168.7.20\"},${NODES}}" "${BAKED}" - 0 "${WORLD_LIVE_ONLAN}" >/dev/null
[ "$(asked '/key')" -eq 0 ] && ok "an explicit .mesh.endpoint asks nothing" || bad "an explicit .mesh.endpoint still asked"

# The caller: a worker's tailscale login_server defaults to resolve_control_endpoint.
awk '/^provision_tailscale\(\) \{/{f=1} f; f&&/^}/{exit}' "${PROV}" > "${WORK}/pt.sh"
grep -a -E 'login="\$\(resolve_control_endpoint\)"' "${WORK}/pt.sh" >/dev/null \
    && ok "provision_tailscale defaults a worker's login_server to resolve_control_endpoint" \
    || bad "provision_tailscale no longer uses resolve_control_endpoint for a worker"

# ── B. headscale_lan_control_marker ──────────────────────────────────────────
echo "-- B. keys-provision headscale_lan_control_marker (run for real) --"
{
    echo 'log()  { :; }'; echo 'warn() { :; }'
    awk '/^HEADSCALE_LAN_CONTROL_MARKER=/{print}' "${PROV}"
    fn headscale_lan_control_marker
} > "${WORK}/hlm.sh"
grep -a -E '^headscale_lan_control_marker\(\) \{' "${WORK}/hlm.sh" >/dev/null \
    && ok "provision.sh defines headscale_lan_control_marker" || bad "provision.sh has no headscale_lan_control_marker"
awk '/^provision_headscale\(\) \{/{f=1} f; f&&/^}/{exit}' "${PROV}" > "${WORK}/ph.sh"
grep -a -E '^[[:space:]]+headscale_lan_control_marker /etc/headscale/config\.yaml' "${WORK}/ph.sh" >/dev/null \
    && ok "provision_headscale writes the marker from /etc/headscale/config.yaml" \
    || bad "provision_headscale never writes the LAN control marker"
grep -a -F 'rm -f "${HEADSCALE_LAN_CONTROL_MARKER}"' "${WORK}/ph.sh" >/dev/null \
    && ok "a node with headscale disabled drops the marker" || bad "the headscale-disabled path leaves a stale marker"
hlm() {  # hlm <listen_addr line or ->  -> marker content or <none>
    local cfg="${WORK}/hs.yaml" mk="${WORK}/hs-lan"
    rm -f "${mk}"
    { echo "server_url: http://127.0.0.1:8080"; [ "$1" = "-" ] || echo "$1"; } > "${cfg}"
    HEADSCALE_LAN_CONTROL_MARKER="${mk}" bash -c '. "$1"; headscale_lan_control_marker "$2"' _ "${WORK}/hlm.sh" "${cfg}"
    [ -f "${mk}" ] && cat "${mk}" || echo "<none>"
}
expect "listen_addr 0.0.0.0:8080" "8080" "$(hlm 'listen_addr: 0.0.0.0:8080')"
expect "listen_addr quoted, another port" "9443" "$(hlm 'listen_addr: "0.0.0.0:9443"')"
expect "no listen_addr: headscale's default 8080" "8080" "$(hlm -)"
expect "loopback-only listen_addr admits nothing" "<none>" "$(hlm 'listen_addr: 127.0.0.1:8080')"
expect "a listen_addr with no port admits nothing" "<none>" "$(hlm 'listen_addr: 0.0.0.0:http')"
expect "the shipped node config admits its port" "8080" \
    "$(cp "${ROOT}/specs/etc/headscale/config.yaml" "${WORK}/hs.yaml"; rm -f "${WORK}/hs-lan"
       HEADSCALE_LAN_CONTROL_MARKER="${WORK}/hs-lan" bash -c '. "$1"; headscale_lan_control_marker "$2"' _ "${WORK}/hlm.sh" "${WORK}/hs.yaml"
       cat "${WORK}/hs-lan" 2>/dev/null || echo "<none>")"

# ── C. the node firewall ─────────────────────────────────────────────────────
echo "-- C. hugmesh-coturn-firewall: the headscale LAN control carve-out --"
FWT="${WORK}/fw"; mkdir -p "${FWT}"
cat > "${FWT}/nft" <<'EOF'
#!/bin/bash
case "$1" in -f) cp "$2" "${NFT_CAPTURE:-/dev/null}"; exit 0 ;; list) exit 0 ;; esac
exit 0
EOF
# firewall-cmd stub: a runtime rich-rule set in ${FW_RULES} (one rule per line).
cat > "${FWT}/firewall-cmd" <<'EOF'
#!/bin/bash
case "$1" in --state) exit 0 ;; --get-default-zone) echo drop; exit 0 ;; esac
for a in "$@"; do case "$a" in
  --list-rich-rules) cat "${FW_RULES}" 2>/dev/null; exit 0 ;;
  --query-rich-rule=*) grep -qxF -- "${a#--query-rich-rule=}" "${FW_RULES}" 2>/dev/null; exit $? ;;
  --add-rich-rule=*) printf '%s\n' "${a#--add-rich-rule=}" >> "${FW_RULES}"; echo "ADDRICH ${a#--add-rich-rule=}" >> "${FW_LOG}"; exit 0 ;;
  --remove-rich-rule=*) grep -vxF -- "${a#--remove-rich-rule=}" "${FW_RULES}" > "${FW_RULES}.n"; mv "${FW_RULES}.n" "${FW_RULES}"; echo "RMRICH ${a#--remove-rich-rule=}" >> "${FW_LOG}"; exit 0 ;;
  --remove-rich-rule=*) [ -z "${FW_RM_FAIL:-}" ] || exit 1; grep -vxF -- "${a#--remove-rich-rule=}" "${FW_RULES}" > "${FW_RULES}.n"; mv "${FW_RULES}.n" "${FW_RULES}"; echo "RMRICH ${a#--remove-rich-rule=}" >> "${FW_LOG}"; exit 0 ;;
  --query-port=*) exit 1 ;;
  --add-port=*) echo "ADDPORT ${a#--add-port=}" >> "${FW_LOG}"; exit 0 ;;
esac; done
exit 0
EOF
chmod +x "${FWT}/nft" "${FWT}/firewall-cmd"
rule() { printf 'rule family="ipv4" source address="%s" port port="%s" protocol="tcp" accept' "$1" "$2"; }
FOREIGN='rule family="ipv4" source address="203.0.113.0/24" service name="ssh" accept'
printf '%s\n' "${FOREIGN}" > "${FWT}/rules"
fwrun() {  # fwrun <marker content|-> <tag>
    rm -f "${FWT}/marker"; [ "$1" = "-" ] || printf '%s\n' "$1" > "${FWT}/marker"
    : > "${FWT}/log"
    PATH="${FWT}:${PATH}" FW_RULES="${FWT}/rules" FW_LOG="${FWT}/log" NFT_CAPTURE="${FWT}/$2.nft" \
        HUGMESH_COTURN_PUBLIC_MARKER="${FWT}/no-coturn" HUGMESH_HEADSCALE_LAN_MARKER="${FWT}/marker" \
        HUGMESH_HEADSCALE_STUN_MARKER="${FWT}/no-stun" HUGMESH_HEADSCALE_STUN_FW_STATE="${FWT}/stun-state" \
        HUGMESH_HEADSCALE_LAN_FW_STATE="${FWT}/run/headscale-lan-control.fw" \
        HUGMESH_FIREWALL_HEALTH_DIR="${FWT}/health" bash "${FW}" > "${FWT}/$2.out" 2>&1
}
want_set() {  # want_set <port>: the exact expected rule set (+ the foreign rule)
    { printf '%s\n' "${FOREIGN}"; for s in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do rule "${s}" "$1"; echo; done; } | sort
}
fwrun 8080 m8080
[ "$(sort "${FWT}/rules")" = "$(want_set 8080)" ] \
    && ok "marker 8080 admits exactly 8080/tcp from 10/8, 172.16/12 and 192.168/16 (the foreign rule kept)" \
    || bad "marker 8080 rule set is wrong: $(tr '\n' '|' < "${FWT}/rules")"
grep -a -E 'ADDPORT' "${FWT}/log" >/dev/null && bad "marker 8080 also opened a plain port (any source)" \
    || ok "no plain --add-port (no admission from every source)"
grep -a -E '8080' "${FWT}/m8080.nft" >/dev/null && bad "the nftables backstop gained an 8080 rule" \
    || ok "the nftables backstop is unchanged by the carve-out"
grep -a -F 'headscale-lan=8080' "${FWT}/m8080.out" >/dev/null && ok "the applied line names the port" \
    || bad "the applied line does not name headscale-lan=8080"
cp "${FWT}/rules" "${FWT}/rules.before"; fwrun 8080 again
cmp -s "${FWT}/rules" "${FWT}/rules.before" && ! grep -a -E 'ADDRICH|RMRICH' "${FWT}/log" >/dev/null \
    && ok "a second run is idempotent (no add, no remove)" || bad "a second run changed the rule set"
fwrun 9443 m9443
[ "$(sort "${FWT}/rules")" = "$(want_set 9443)" ] \
    && ok "a changed port replaces the old rules" || bad "port change left: $(tr '\n' '|' < "${FWT}/rules")"
fwrun 'abc' bad1
[ "$(sort "${FWT}/rules")" = "${FOREIGN}" ] \
    && ok "a malformed marker admits nothing and takes ours back out" || bad "malformed marker left: $(tr '\n' '|' < "${FWT}/rules")"
fwrun 9443 m9443b; fwrun - gone
[ "$(sort "${FWT}/rules")" = "${FOREIGN}" ] \
    && ok "no marker: ours removed, the foreign rule untouched" || bad "marker removal left: $(tr '\n' '|' < "${FWT}/rules")"
fwrun 70000 bad2
[ "$(sort "${FWT}/rules")" = "${FOREIGN}" ] && ok "an out-of-range port admits nothing" || bad "port 70000 admitted something"
# Only what this script wrote is ever taken back. An operator's rich rule of the
# carve-out's exact shape on another port (the reviewer's repro: 22/tcp from
# 192.168/16), and one on the SAME port written before this script admitted anything,
# both survive every run, marker or not.
OP22="$(rule 192.168.0.0/16 22)"; OP8080="$(rule 10.0.0.0/8 8080)"
rm -f "${FWT}/run/headscale-lan-control.fw"
printf '%s\n' "${FOREIGN}" "${OP22}" "${OP8080}" > "${FWT}/rules"
fwrun - op-nomarker
[ "$(sort "${FWT}/rules")" = "$(printf '%s\n' "${FOREIGN}" "${OP22}" "${OP8080}" | sort)" ] && ! grep -a -F 'RMRICH' "${FWT}/log" >/dev/null \
    && ok "no marker, nothing recorded: an operator's same-shape rules (22/tcp, and 8080/tcp from 10/8) are not touched" \
    || bad "an operator's same-shape rule was removed with no marker: $(tr '\n' '|' < "${FWT}/log")"
fwrun 9443 op-9443
[ "$(sort "${FWT}/rules")" = "$( { want_set 9443; printf '%s\n' "${OP22}" "${OP8080}"; } | sort)" ] \
    && ok "marker 9443: ours admitted, the operator's 22 and 8080 rules kept" || bad "marker 9443 with operator rules: $(tr '\n' '|' < "${FWT}/rules")"
[ "$(cat "${FWT}/run/headscale-lan-control.fw" 2>/dev/null)" = "9443" ] && ok "the admitted port is recorded (9443)" \
    || bad "the admitted port is not recorded: '$(cat "${FWT}/run/headscale-lan-control.fw" 2>/dev/null)'"
fwrun - op-gone
[ "$(sort "${FWT}/rules")" = "$(printf '%s\n' "${FOREIGN}" "${OP22}" "${OP8080}" | sort)" ] \
    && ok "marker gone: ours (9443) taken back, the operator's rules still there" || bad "marker gone with operator rules: $(tr '\n' '|' < "${FWT}/rules")"
[ ! -e "${FWT}/run/headscale-lan-control.fw" ] && ok "nothing admitted: the record is gone" || bad "the record outlived the rules"
# A removal that fails keeps its port recorded, so a later run still takes it back.
printf '%s\n' "${FOREIGN}" > "${FWT}/rules"; rm -f "${FWT}/run/headscale-lan-control.fw"
fwrun 8080 rf-1
FW_RM_FAIL=1 fwrun 9443 rf-2
[ "$(tr ' ' '\n' < "${FWT}/run/headscale-lan-control.fw" | sort | tr '\n' ' ')" = "8080 9443 " ] \
    && ok "a failed removal keeps the old port (8080) recorded next to the new one (9443)" \
    || bad "a failed removal lost the old port: '$(cat "${FWT}/run/headscale-lan-control.fw" 2>/dev/null)'"
fwrun 9443 rf-3
[ "$(sort "${FWT}/rules")" = "$(want_set 9443)" ] && [ "$(cat "${FWT}/run/headscale-lan-control.fw")" = "9443" ] \
    && ok "…and the next run takes 8080 back" || bad "after a failed removal: $(tr '\n' '|' < "${FWT}/rules")"
printf '%s\n' "${FOREIGN}" > "${FWT}/rules"; rm -f "${FWT}/run/headscale-lan-control.fw"

# ── D. gen-provision-keys.sh --pki-ip ────────────────────────────────────────
echo "-- D. gen-provision-keys.sh --pki-ip (run for real) --"
gk() {  # gk <out> <args...>
    local out="$1"; shift
    NONINTERACTIVE=1 BRAND=hugmesh bash "${GENKEYS}" --out "${out}" --random "$@" > "${out}.log" 2>&1
}
if gk "${WORK}/k-host" --role host --pki-ip 192.168.007.020; then
    j="$(jq -c '[.mesh.pki_lan_ip, ([.nodes[] | select(.role=="pki") | .ip])]' "${WORK}/k-host/provision.json")"
    expect "worker stick: .mesh.pki_lan_ip + the pki .nodes[] row (canonicalised)" '["192.168.7.20",["192.168.7.20"]]' "${j}"
else
    bad "gen-provision-keys --role host --pki-ip failed: $(tail -2 "${WORK}/k-host.log" | tr '\n' ' ')"
fi
if PKI_LAN_IP=10.20.30.40 gk "${WORK}/k-env" --role backend; then
    expect "the env spelling PKI_LAN_IP" "10.20.30.40" "$(jq -r '.mesh.pki_lan_ip' "${WORK}/k-env/provision.json")"
else
    bad "gen-provision-keys with PKI_LAN_IP failed: $(tail -2 "${WORK}/k-env.log" | tr '\n' ' ')"
fi
if gk "${WORK}/k-pki" --role pki --pki-ip 172.16.5.5; then
    expect "pki stick carries it too (its /etc/hosts rows)" "172.16.5.5" \
        "$(jq -r '[.mesh.pki_lan_ip, (.nodes[] | select(.role=="pki") | .ip)] | unique | join(",")' "${WORK}/k-pki/provision.json")"
else
    bad "gen-provision-keys --role pki --pki-ip failed: $(tail -2 "${WORK}/k-pki.log" | tr '\n' ' ')"
fi
if gk "${WORK}/k-none" --role host; then
    expect "without --pki-ip no .mesh.pki_lan_ip is written" "null" "$(jq -r '.mesh.pki_lan_ip' "${WORK}/k-none/provision.json")"
    grep -a -F 'WARNING: no --pki-ip' "${WORK}/k-none.log" >/dev/null \
        && ok "without --pki-ip the run warns" || bad "without --pki-ip the run is silent"
else
    bad "gen-provision-keys --role host (no --pki-ip) failed"
fi
for v in 100.64.0.1 8.8.8.8 127.0.0.1 169.254.1.1 10.0.0.256 hs.local '10.0.0.1;id' 172.32.0.1 ' 10.0.0.1'; do
    if gk "${WORK}/k-bad" --role host --pki-ip "${v}"; then
        bad "--pki-ip '${v}' was accepted"
    elif [ -e "${WORK}/k-bad" ]; then
        bad "--pki-ip '${v}' was refused only after the output was built"
    else
        ok "--pki-ip '${v}' refused before anything is built"
    fi
    rm -rf "${WORK}/k-bad"
done
# The Studio's rule and the script's refusal agree (one table, both judges).
awk '/^# --pki-ip: checked BEFORE anything is built/{f=1} f; f&&/^fi$/{exit}' "${GENKEYS}" > "${WORK}/pki-check.sh"
[ -s "${WORK}/pki-check.sh" ] && ok "gen-provision-keys.sh has the --pki-ip check block" || bad "gen-provision-keys.sh has no --pki-ip check block"
VALUES=(10.0.0.1 10.255.255.254 172.16.0.1 172.31.255.254 172.15.0.1 172.32.0.1 192.168.1.1 192.169.1.1
        100.64.0.1 8.8.8.8 127.0.0.1 0.0.0.0 10.0.0.256 10.0.0 10.0.0.1.2 hs.local 10.0.0.1x 010.000.000.001)
if [ -f "${ROOT}/studio/hugmesh_studio/core/pki_lan.py" ]; then
    for v in "${VALUES[@]}"; do
        if PKI_LAN_IP="${v}" bash -c 'set -u; . "$1" >/dev/null 2>&1' _ "${WORK}/pki-check.sh"; then sh_ok=accept; else sh_ok=refuse; fi
        py_ok="$(PYTHONPATH="${ROOT}/studio" python3 -I -c 'import sys
sys.path.insert(0, sys.argv[2])
from hugmesh_studio.core import pki_lan
print("refuse" if pki_lan.ip_error(sys.argv[1]) else "accept")' "${v}" "${ROOT}/studio" 2>&1)"
        [ "${sh_ok}" = "${py_ok}" ] && ok "parity ${v}: both ${sh_ok}" || bad "parity ${v}: gen-provision-keys ${sh_ok}, Studio ${py_ok}"
    done
else
    bad "studio/hugmesh_studio/core/pki_lan.py is missing"
fi

# ── E. Studio wiring ─────────────────────────────────────────────────────────
echo "-- E. Studio wiring --"
S="${ROOT}/studio/hugmesh_studio"
chk() {  # chk <label> <file> <fixed string>
    grep -a -F -- "$3" "$2" >/dev/null 2>&1 && ok "$1" || bad "$1 (no '$3' in ${2#"${ROOT}/"})"
}
chk "ImageConfig has pki_lan_ip" "${S}/core/config.py" 'pki_lan_ip: str = ""'
chk "ImageConfig has pki_lan_ip_fixed" "${S}/core/config.py" 'pki_lan_ip_fixed: bool = False'
chk "the image route's keys step passes --pki-ip" "${S}/core/worklist_driver.py" '*pki_lan.genkeys_args(base)'
chk "the image route's preflight refuses without it" "${S}/core/worklist_driver.py" 'pki_lan.problem(self.worklist.base)'
chk "the Fleet route hands PKI_LAN_IP to build-all-roles.sh" "${S}/core/fleet.py" '("PKI_LAN_IP", pki_lan.canonical(self.pki_lan_ip))'
chk "the Fleet preflight refuses without it" "${S}/core/fleet.py" 'pki_lan.problem(cfg)'
chk "the GUI Network page has the row" "${S}/gui/pages/network.py" 'pki_lan.LABEL_IP, self.pki_lan_ip'
chk "the GUI Fleet page has the row" "${S}/gui/pages/fleet.py" 'pki_lan.LABEL_IP, self.pki_lan_ip'
chk "the TUI Network step has the row" "${S}/tui/network_step.py" 'pki_lan.LABEL_IP'
chk "the TUI Build screen says the build will refuse" "${S}/tui/journey.py" 'pki_lan.problem(cfg)'
if PYTHONPATH="${ROOT}/studio" python3 -I - "${ROOT}/studio" > "${WORK}/py.out" 2>&1 <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from hugmesh_studio.core import pki_lan
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.fleet import FleetConfig
m = ImageConfig(mode="mesh")
assert pki_lan.problem(m).startswith("PKI LAN Address is required"), pki_lan.problem(m)
m.pki_lan_ip = "192.168.1.10"
assert "confirm it is fixed" in pki_lan.problem(m), pki_lan.problem(m)
m.pki_lan_ip_fixed = True
assert pki_lan.problem(m) == "", pki_lan.problem(m)
assert pki_lan.genkeys_args(m) == ["--pki-ip", "192.168.1.10"]
assert pki_lan.problem(ImageConfig(mode="standalone")) == ""
assert pki_lan.genkeys_args(ImageConfig(mode="cloud", pki_lan_ip="192.168.1.10")) == []
try:
    ImageConfig(mode="mesh", pki_lan_ip="hs.local").validate_identity()
    raise SystemExit("validate_identity accepted hs.local")
except ValueError:
    pass
assert "--pki-ip" not in " ".join(ImageConfig(mode="mesh", role="pki", pki_lan_ip="192.168.1.10",
                                              pki_lan_ip_fixed=True).to_cli_args())
f = FleetConfig(pki_lan_ip="192.168.001.010", pki_lan_ip_fixed=True)
assert f.to_env().get("PKI_LAN_IP") == "192.168.1.10", f.to_env()
print("ok")
PY
then ok "core rule: mesh requires it, confirmed; other modes do not; never a builder argv; Fleet env canonical"
else bad "core rule: $(tail -3 "${WORK}/py.out" | tr '\n' ' ')"; fi

# ── F. negative controls ─────────────────────────────────────────────────────
if [ -z "${LANFIRST_GUARD_NO_CONTROLS:-}" ]; then
    echo "-- F. negative controls: each mutation must turn the guard red --"
    mktree() {  # mktree <dir> [studio]: a copy of what A-E read; the Studio package is
        # linked, not copied, unless the control mutates it
        local d="$1" f
# ── G. every image can ask ───────────────────────────────────────────────────
# A2 holds only where the resolver and its tool exist. Every builder copies the SAME
# specs/etc/keys-provision/provision.sh onto its image, and every image's sysroot
# starts as a Gentoo stage3, which carries net-misc/curl (measured on the two seeds
# the builders extract: stage3-arm64-openrc and stage3-amd64-hardened-openrc, both
# 2026-11-08, curl 8.23.0). So that this does not rest on what a stage3 happens to
# contain, every platform's base packages.list also REQUESTS curl, which puts it
# behind the requested-atom completeness gate each builder already runs.
echo "-- G. every image carries the resolver and the tool it asks with --"
n_builders=0
for b in "${ROOT}"/build-*-stage4.sh; do
    [ -f "${b}" ] || continue
    bn="$(basename "${b}")"
    # the shared engine, installed as /usr/sbin/keys-provision (the spacing differs per builder)
    grep -a -E '^cp "\$\{SHARED_SPECS\}/etc/keys-provision/provision\.sh" +"\$\{SYSROOT\}/usr/sbin/keys-provision"' "${b}" >/dev/null \
        || continue
    n_builders=$((n_builders + 1))
    sd="$(sed -n 's/^SPECS_DIR="\${SCRIPT_DIR}\/\([A-Za-z0-9_-]*\)".*/\1/p' "${b}" | head -1)"
    lst="${ROOT}/${sd}/portage/packages.list"
    if [ -n "${sd}" ] && [ -f "${lst}" ]; then
        grep -a -x -F 'net-misc/curl' "${lst}" >/dev/null \
            && ok "${bn}: ${sd}/portage/packages.list requests net-misc/curl" \
            || bad "${bn}: ${sd}/portage/packages.list does not request net-misc/curl (keys-provision could not ask whether the mesh is live)"
    else
        bad "${bn}: no SPECS_DIR/portage/packages.list found (SPECS_DIR='${sd}')"
    fi
    # read into the requested set of EVERY role: the cross builders' mapfile, x86's PKG_LISTS
    { grep -a -F "grep -v '^\s*#' \"\${SPECS_DIR}/portage/packages.list\"" "${b}" \
        || grep -a -F 'PKG_LISTS=("${SPECS_DIR}/portage/packages.list")' "${b}"; } >/dev/null \
        && ok "${bn} reads that list into the requested set of every role" \
        || bad "${bn} no longer reads \${SPECS_DIR}/portage/packages.list into its requested set"
    # the cross builders call the shared gate; x86 carries its own inside the chroot script
    grep -a -E '^requested_atom_gate "\$\{SYSROOT\}"|^printf .* \$\{PKGS\} > /tmp/hugmesh-requested-atoms\.txt$' "${b}" >/dev/null \
        && ok "${bn} runs the requested-atom completeness gate" || bad "${bn} runs no requested-atom completeness gate"
    grep -a -E '^SEED_STAGE3_URL="https://distfiles\.gentoo\.org/releases/[a-z0-9]+/autobuilds/latest-stage3-[a-z0-9-]+\.txt"' "${b}" >/dev/null \
        && ok "${bn} seeds its sysroot from a Gentoo stage3" || bad "${bn} no longer seeds from a Gentoo stage3 (is curl still on the image?)"
done
[ "${n_builders}" -ge 10 ] && ok "all ${n_builders} builders that install keys-provision were checked (the ten platforms)" \
    || bad "only ${n_builders} builder(s) install keys-provision the known way — expected the ten platforms"

# ── F. negative controls ─────────────────────────────────────────────────────
if [ -z "${LANFIRST_GUARD_NO_CONTROLS:-}" ]; then
    echo "-- F. negative controls: each mutation must turn the guard red --"
    mktree() {  # mktree <dir> [file the control mutates]: a copy of what A-G read. The
        # Studio package, the builders and the package lists are linked, not copied,
        # except the one the control mutates.
        local d="$1" mut="${2:-}" f
        mkdir -p "${d}/specs/etc/keys-provision" "${d}/specs/usr/sbin" "${d}/specs/etc/headscale" "${d}/studio"
        for f in specs/etc/keys-provision/provision.sh specs/usr/sbin/hugmesh-coturn-firewall \
                 specs/etc/headscale/config.yaml; do
            cp -p "${REPO}/${f}" "${d}/${f}" || return 1
        done
        # gen-provision-keys reads its template, libs and brand profiles from its own tree
        for f in keys-template scripts brands; do cp -rp "${REPO}/${f}" "${d}/${f}" || return 1; done
        if [ "${2:-}" = studio ]; then
            cp -rp "${REPO}/studio/hugmesh_studio" "${d}/studio/hugmesh_studio" || return 1
        else
            ln -s "${REPO}/studio/hugmesh_studio" "${d}/studio/hugmesh_studio" || return 1
        fi
        case "${mut}" in
            studio/*) cp -rp "${REPO}/studio/hugmesh_studio" "${d}/studio/hugmesh_studio" || return 1 ;;
            *)        ln -s "${REPO}/studio/hugmesh_studio" "${d}/studio/hugmesh_studio" || return 1 ;;
        esac
        for f in "${REPO}"/build-*-stage4.sh "${REPO}"/specs-*/portage/packages.list; do
            [ -f "${f}" ] || continue
            f="${f#"${REPO}/"}"
            mkdir -p "${d}/$(dirname "${f}")"
            if [ "${f}" = "${mut}" ]; then cp -p "${REPO}/${f}" "${d}/${f}" || return 1
            else ln -s "${REPO}/${f}" "${d}/${f}" || return 1; fi
        done
    }
    child() { LANFIRST_GUARD_ROOT="$1" LANFIRST_GUARD_NO_CONTROLS=1 bash "${SELF}" </dev/null 2>&1; }
    pos="${WORK}/ctl-pos"
    if mktree "${pos}" && child "${pos}" > "${WORK}/ctl-pos.log"; then
        ok "positive control: an unmutated copy of the tree passes"
    else
        bad "positive control: an unmutated copy FAILS (the controls below would prove nothing): $(grep -a FAIL "${WORK}/ctl-pos.log" | head -3 | tr '\n' ' ')"
    fi
    n=0
    control() {  # control <label> <file> <old> <new>
        local d="${WORK}/ctl-$((n+=1))"
        mktree "${d}" "$(case "$2" in studio/*) echo studio ;; esac)" \
        mktree "${d}" "$2" \
            || { bad "control '$1': could not build the tree"; return; }
        if ! python3 - "${d}/$2" "$3" "$4" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(p, encoding="utf-8").read()
if t.count(old) < 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(t.replace(old, new, 1))
PY
        then bad "control '$1': mutation anchor not found in $2 (the control is stale)"; return; fi
        if child "${d}" > "${d}.log"; then
            bad "control '$1' did NOT bite (the guard stayed green)"
        else
            ok "control bites: $1  [red on: $(grep -a 'FAIL' "${d}.log" | head -1 | sed 's/^ *FAIL //' | cut -c1-110)]"
        fi
        rm -rf "${d}"
    }
    control "the old precedence (baked URL before the LAN address)" specs/etc/keys-provision/provision.sh \
        'if [ -z "${ep}" ] || [ "${ep}" = "null" ]; then
        local lan_ip; lan_ip="$(resolve_pki_lan_ip)"' 'if false; then
        local lan_ip; lan_ip="$(resolve_pki_lan_ip)"'
    control "go-live no longer consulted" specs/etc/keys-provision/provision.sh \
        '            if node_is_public; then' '            if false; then'
    control "the go-live marker is ignored" specs/etc/keys-provision/provision.sh \
        '    [ -e "${marker}" ] && return 0' '    :'
    control "the pki LAN address is not shape-checked" specs/etc/keys-provision/provision.sh \
        '    if ipv4_literal "${ip}"; then
        echo "${ip}"' '    if true; then
        echo "${ip}"'
    control "the LAN choice logs to stdout" specs/etc/keys-provision/provision.sh \
        'not the baked HEADSCALE_URL" >&2' 'not the baked HEADSCALE_URL"'
    control "provision_headscale stops writing the marker" specs/etc/keys-provision/provision.sh \
        '    headscale_lan_control_marker /etc/headscale/config.yaml' '    : headscale_lan_control_marker'
    control "the firewall admits from every source" specs/usr/sbin/hugmesh-coturn-firewall \
        'HS_LAN_SOURCES="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"' 'HS_LAN_SOURCES="0.0.0.0/0"'
    control "the firewall never removes a stale rule" specs/usr/sbin/hugmesh-coturn-firewall \
        '            firewall-cmd --zone="${ZONE}" --remove-rich-rule="${r}" >/dev/null 2>&1 \' '            true \'
    control "the firewall accepts a malformed marker" specs/usr/sbin/hugmesh-coturn-firewall \
        'if [[ "${_hs_lan}" =~ ^[0-9]{1,5}$ ]] && [ "${_hs_lan}" -ge 1 ] && [ "${_hs_lan}" -le 65535 ]; then' 'if [ -n "${_hs_lan}" ]; then'
        '                    firewall-cmd --zone="${ZONE}" --remove-rich-rule="${r}" >/dev/null 2>&1 && continue' '                    continue'
    control "the firewall accepts a malformed marker" specs/usr/sbin/hugmesh-coturn-firewall \
        'if [[ "${_hs_lan}" =~ ^[0-9]{1,5}$ ]] && [ "${_hs_lan}" -ge 1 ] && [ "${_hs_lan}" -le 65535 ]; then' 'if [ -n "${_hs_lan}" ]; then'
    control "the firewall takes back rules of its shape on ANY port (an operator's 22/tcp)" specs/usr/sbin/hugmesh-coturn-firewall \
        '[ "${r}" = "$(hs_lan_rule "${src}" "${p}")" ] || continue' \
        '[[ "${r}" == *"${src}"* ]] || continue'
    control "the firewall forgets a port whose removal failed" specs/usr/sbin/hugmesh-coturn-firewall \
        '*) HS_LAN_RECORD="${HS_LAN_RECORD} ${p}" ;; esac' '*) : ;; esac'
    control "gen-provision-keys lets the tailnet range through" scripts/gen-provision-keys.sh \
        'if [ "${_o1}" -eq 10 ] ||' 'if [ "${_o1}" -eq 100 ] || [ "${_o1}" -eq 10 ] ||'
    control "gen-provision-keys forgets the .mesh key" scripts/gen-provision-keys.sh \
        'd.setdefault("mesh", {})["pki_lan_ip"] = ip' 'pass'
    control "the Studio forgets to pass --pki-ip" studio/hugmesh_studio/core/worklist_driver.py \
        '*pki_lan.genkeys_args(base),' ''
    control "the Studio accepts a public address" studio/hugmesh_studio/core/pki_lan.py \
        '    if not any(ip in n for n in _PRIVATE):' '    if False:'
        '*pki_lan.genkeys_args(base), ' ''
    control "the Studio accepts a public address" studio/hugmesh_studio/core/pki_lan.py \
        '    if not any(ip in n for n in _PRIVATE):' '    if False:'
    # A2: the mesh-live question.
    control "the network is never asked (a live mesh's fresh worker dials the LAN address)" specs/etc/keys-provision/provision.sh \
        '                if control_endpoint_mesh_is_live "${ep}"; then ep=""; fi' '                if false; then ep=""; fi'
    control "any answer counts as a control server (a captive portal reads as go-live)" specs/etc/keys-provision/provision.sh \
        "    if printf '%s' \"\${body}\" | jq -e" "    if true || printf '%s' \"\${body}\" | jq -e"
    control "curl's exit status is ignored (the log no longer says why the baked URL lost)" specs/etc/keys-provision/provision.sh \
        '    if [ "${rc}" -ne 0 ]; then
        case "${rc}" in' '    if false; then
        case "${rc}" in'
    control "certificate checking is switched off (-k)" specs/etc/keys-provision/provision.sh \
        '    local cmd=(curl -sS -f ' '    local cmd=(curl -k -sS -f '
    control "redirects are followed" specs/etc/keys-provision/provision.sh \
        '--max-redirs 0 ' '-L --max-redirs 5 '
    control "the LAN address wins when both answer" specs/etc/keys-provision/provision.sh \
        '        if control_server_answers "${baked}" 4; then' \
        '        if ! control_server_answers "${lan}" 3 && control_server_answers "${baked}" 4; then'
    control "one question only (a late uplink pins the LAN address for good)" specs/etc/keys-provision/provision.sh \
        '        [ "${SECONDS}" -lt "${deadline}" ] || break' '        break'
    control "nothing answers -> the baked URL (a LAN-first mesh whose pki boots late never joins)" specs/etc/keys-provision/provision.sh \
        '(.mesh.endpoint)" >&2
    return 1' '(.mesh.endpoint)" >&2
    return 0'
    control "the question is not what tailscale asks (no capability version)" specs/etc/keys-provision/provision.sh \
        '"${url}/key?v=$(control_probe_capver)")' '"${url}/health")'
    control "the live-mesh correction logs to stdout" specs/etc/keys-provision/provision.sh \
        'not the pki LAN address ${lan}" >&2' 'not the pki LAN address ${lan}"'
    # G: every image can ask.
    control "a platform stops requesting curl" specs-orangepi-zero3/portage/packages.list \
        'net-misc/curl
' '# net-misc/curl
'
    control "a builder stops reading its base packages.list" build-jetson-stage4.sh \
        '"${SPECS_DIR}/portage/packages.list" | grep' '"${SPECS_DIR}/portage/packages-k8s.list" | grep'
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
