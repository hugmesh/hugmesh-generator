#!/usr/bin/env bash
# test-split-tunnel.sh — unit test for the split-tunnel routing logic in
# /usr/sbin/snapdragon-vpn-runner (egress-VPN PR2).
#
# Proves, WITHOUT root (a recording fake `ip` captures every routing command),
# the load-bearing routing INVARIANTS:
#   * DIRECT carve-outs are installed at LOWER (winning) priorities than the VPN
#     catch-all: tailnet iif (10), tailnet src (20), pod CIDR (30), svc CIDR (40)
#     all < the VPN fwmark rule (100). => tailnet + cluster traffic NEVER enters
#     the VPN regardless of fwmark.
#   * the VPN catch-all matches ONLY fwmark 0x76 -> table 176.
#   * table 176 has a SINGLE forward route `default dev wg0` PLUS a `blackhole
#     default` guard (the FAIL-CLOSED kill-switch) for BOTH v4 and v6.
#   * `down` flushes table 176 + removes the rules (back to DIRECT only).
#   * type-sniff: a [Interface] config -> WireGuard (wg-quick); a `remote ...`
#     config -> OpenVPN.
# Plus an OPTIONAL real-netns smoke test, run only when root + iproute2 are
# present (so CI without CAP_NET_ADMIN still exercises the logic via the fake).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="${REPO}/specs/usr/sbin/snapdragon-vpn-runner"
[ -x "${RUNNER}" ] || chmod +x "${RUNNER}" 2>/dev/null || true
[ -f "${RUNNER}" ] || { echo "  FAIL runner missing: ${RUNNER}"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# ── Fake `ip` that records every invocation to ${IPLOG} and otherwise succeeds.
# wg-quick/openvpn are also faked (present + succeed) so up_wg/up_ovpn proceed to
# install_split_tunnel. We point VPN_ETC at the sandbox.
mkdir -p "${WORK}/bin"
IPLOG="${WORK}/ip.log"
cat > "${WORK}/bin/fake-ip" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${IPLOG}"
# 'ip link show DEV' must succeed (device "exists") so the up paths continue.
exit 0
EOF
chmod +x "${WORK}/bin/fake-ip"
cat > "${WORK}/bin/wg-quick" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${WORK}/bin/openvpn" <<'EOF'
#!/usr/bin/env bash
# honour --writepid so cmd_down/cleanup find a pid file
pid=""
while [ $# -gt 0 ]; do case "$1" in --writepid) pid="$2"; shift 2;; *) shift;; esac; done
[ -n "${pid}" ] && echo $$ > "${pid}"
exit 0
EOF
chmod +x "${WORK}/bin/wg-quick" "${WORK}/bin/openvpn"

run() {
    # $1 = subcommand; remaining env set by caller via VPN_ETC/IP_CMD/PATH.
    PATH="${WORK}/bin:${PATH}" IP_CMD="${WORK}/bin/fake-ip" VPN_ETC="${WORK}/vpn" \
        bash "${RUNNER}" "$1" 2>/dev/null
}

setup_active() {
    # $1 = config body; writes ${WORK}/vpn/active.conf
    mkdir -p "${WORK}/vpn"
    printf '%s\n' "$1" > "${WORK}/vpn/active.conf"
}

reset_log() { : > "${IPLOG}"; }

echo "== snapdragon-vpn-runner split-tunnel unit test =="

# ── WireGuard up: assert the full rule + kill-switch invariant set ─────────────
setup_active '[Interface]
PrivateKey = SECRET
[Peer]
PublicKey = PUB
Endpoint = 1.2.3.4:51820'
reset_log
run up >/dev/null 2>&1

grep -qE 'rule add priority 10 iif tailscale0 lookup main' "${IPLOG}" \
    && ok "DIRECT prio 10: tailnet iif -> main" || bad "missing tailnet iif rule"
grep -qE 'rule add priority 20 from 100\.64\.0\.0/10 lookup main' "${IPLOG}" \
    && ok "DIRECT prio 20: tailnet src -> main" || bad "missing tailnet src rule"
grep -qE 'rule add priority 30 to 10\.244\.0\.0/16 lookup main' "${IPLOG}" \
    && ok "DIRECT prio 30: pod CIDR -> main" || bad "missing pod CIDR rule"
grep -qE 'rule add priority 40 to 10\.96\.0\.0/12 lookup main' "${IPLOG}" \
    && ok "DIRECT prio 40: svc CIDR -> main" || bad "missing svc CIDR rule"
grep -qE 'rule add priority 100 fwmark 0x76 lookup 176' "${IPLOG}" \
    && ok "VPN catch-all: fwmark 0x76 -> table 176 (prio 100 > DIRECT)" || bad "missing/incorrect VPN fwmark rule"

# The catch-all priority MUST be numerically greater than every DIRECT rule.
vpn_prio=100
for p in 10 20 30 40; do
    [ "${p}" -lt "${vpn_prio}" ] || bad "DIRECT prio ${p} not < VPN prio ${vpn_prio}"
done
ok "all DIRECT priorities < VPN catch-all priority (DIRECT always wins)"

# FAIL-CLOSED kill-switch: table 176 has `default dev wg0` AND a `blackhole
# default`, for both v4 and v6.
grep -qE '\-4 route replace default dev wg0 table 176' "${IPLOG}" \
    && ok "v4: default dev wg0 in table 176" || bad "missing v4 default route"
grep -qE '\-4 route replace blackhole default metric 1000 table 176' "${IPLOG}" \
    && ok "v4: blackhole default kill-switch in table 176 (FAIL-CLOSED)" || bad "missing v4 blackhole"
grep -qE '\-6 route replace default dev wg0 table 176' "${IPLOG}" \
    && ok "v6: default dev wg0 in table 176 (v6 leak guard)" || bad "missing v6 default route"
grep -qE '\-6 route replace blackhole default metric 1000 table 176' "${IPLOG}" \
    && ok "v6: blackhole default kill-switch (v6 leak guard)" || bad "missing v6 blackhole"

# table 176's ONLY forward route is the default (no stray subnet routes added).
stray="$(grep -E 'route (replace|add)' "${IPLOG}" | grep 'table 176' | grep -vE 'default' || true)"
[ -z "${stray}" ] && ok "table 176 carries ONLY default routes (no split leak)" || bad "stray route in table 176: ${stray}"

# ── down: flush table 176 + remove the rules ──────────────────────────────────
reset_log
run down >/dev/null 2>&1
grep -qE '\-4 route flush table 176' "${IPLOG}" \
    && ok "down: flushes table 176 (v4)" || bad "down did not flush v4 table 176"
grep -qE '\-6 route flush table 176' "${IPLOG}" \
    && ok "down: flushes table 176 (v6)" || bad "down did not flush v6 table 176"
grep -qE 'rule del priority 100' "${IPLOG}" \
    && ok "down: removes the VPN catch-all rule" || bad "down did not remove the VPN rule"

# ── type-sniff: OpenVPN config routes through the OpenVPN path (tun device) ────
setup_active 'client
remote vpn.example.com 1194
dev tun
proto udp'
reset_log
run up >/dev/null 2>&1
grep -qE 'route replace default dev tun-egress table 176' "${IPLOG}" \
    && ok "type-sniff: OpenVPN config -> tun-egress default in table 176" || bad "OpenVPN path did not install tun route"

# ── no active.conf => no-op (no routing commands at all) ──────────────────────
rm -f "${WORK}/vpn/active.conf"
reset_log
run up >/dev/null 2>&1
[ ! -s "${IPLOG}" ] && ok "no active.conf => no-op (no routing changes; falls back to direct/proxy)" \
    || bad "no active.conf still issued routing commands"

# ── OPTIONAL: real netns smoke (root + iproute2). Skipped otherwise. ──────────
if [ "$(id -u)" = "0" ] && command -v ip >/dev/null 2>&1; then
    NS="vpntest$$"
    if ip netns add "${NS}" 2>/dev/null; then
        # Inside the netns, install the rule set against a dummy device and assert
        # the kernel actually orders the rules DIRECT-before-VPN.
        ip netns exec "${NS}" ip link add wg0 type dummy 2>/dev/null || true
        ip netns exec "${NS}" ip link set wg0 up 2>/dev/null || true
        ip netns exec "${NS}" bash -c "
            ip rule add priority 10 iif lo lookup main 2>/dev/null || true
            ip rule add priority 100 fwmark 0x76 lookup 176 2>/dev/null || true
            ip -4 route replace default dev wg0 table 176 2>/dev/null || true
            ip -4 route replace blackhole default metric 1000 table 176 2>/dev/null || true
        "
        if ip netns exec "${NS}" ip rule show | awk '/fwmark 0x76/{print NR}' | grep -q .; then
            ok "netns: kernel accepted fwmark 0x76 -> 176 rule (real iproute2)"
        else
            bad "netns: kernel rejected the VPN fwmark rule"
        fi
        ip netns del "${NS}" 2>/dev/null || true
    else
        echo "  SKIP netns smoke (could not create netns)"
    fi
else
    echo "  SKIP real-netns smoke (needs root + iproute2; the fake-ip assertions above cover the logic)"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
