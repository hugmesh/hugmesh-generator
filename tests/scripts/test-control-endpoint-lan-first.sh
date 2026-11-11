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
#   F. negative controls: each mutation of a copy of the tree must turn A-E red.
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
    for f in node_is_public ipv4_literal resolve_pki_lan_ip resolve_control_endpoint; do
        fn "${f}"
    done
} > "${WORK}/rce.sh"
for f in node_is_public ipv4_literal resolve_pki_lan_ip resolve_control_endpoint; do
    grep -a -E "^${f}\(\) \{" "${WORK}/rce.sh" >/dev/null \
        && ok "provision.sh defines ${f}" || bad "provision.sh has no ${f}"
done
# The baked URL file is a literal path in the resolver; point the extracted copy at a
# scratch file. A renamed path makes the sed a no-op and the baked-URL cases go red.
grep -a -F '/etc/hugmesh/headscale-url' "${WORK}/rce.sh" >/dev/null \
    && ok "resolve_control_endpoint reads the baked /etc/hugmesh/headscale-url" \
    || bad "resolve_control_endpoint no longer reads /etc/hugmesh/headscale-url"
sed -i "s#/etc/hugmesh/headscale-url#${WORK}/baked-url#g" "${WORK}/rce.sh"

BAKED="https://headscale.brand.example"
# rce <manifest-json> <baked|-> <release-state|-> <go-live marker 0|1>  -> stdout of the resolver
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
expect() {  # expect <label> <want> <got>
    if [ "$3" = "$2" ]; then ok "$1 -> ${2:-<empty>}"; else bad "$1: want '${2:-<empty>}', got '$3'"; fi
}
NODES='"nodes":[{"name":"p","ip":"10.0.0.10","role":"pki"},{"name":"w","ip":"10.0.0.30","role":"host"}]'
LAN="{\"mesh\":{\"endpoint\":\"\",\"pki_lan_ip\":\"192.168.7.20\"},${NODES}}"
expect "before go-live (no release-state file), confirmed pki address beats the baked public URL" \
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
    control "gen-provision-keys lets the tailnet range through" scripts/gen-provision-keys.sh \
        'if [ "${_o1}" -eq 10 ] ||' 'if [ "${_o1}" -eq 100 ] || [ "${_o1}" -eq 10 ] ||'
    control "gen-provision-keys forgets the .mesh key" scripts/gen-provision-keys.sh \
        'd.setdefault("mesh", {})["pki_lan_ip"] = ip' 'pass'
    control "the Studio forgets to pass --pki-ip" studio/hugmesh_studio/core/worklist_driver.py \
        '*pki_lan.genkeys_args(base), ' ''
    control "the Studio accepts a public address" studio/hugmesh_studio/core/pki_lan.py \
        '    if not any(ip in n for n in _PRIVATE):' '    if False:'
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
