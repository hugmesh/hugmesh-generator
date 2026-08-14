#!/bin/sh
# Fail-closed VPN client for the local mesh's egress-vpn profile — WireGuard
# (wg-quick .conf) or OpenVPN (.ovpn), sniffed from the mounted conf's content.
# * refuses to start without a real conf (build-x86-host-stage4.sh:4052, translated):
#   attached services then never start, so nothing falls back to direct;
# * WireGuard lane: strips DNS= — docker's embedded 127.0.0.11 must keep resolving
#   compose service names for attached containers (external lookups therefore
#   resolve via the HOST resolver: a documented metadata leak this lane accepts,
#   unlike the node lane); strips Table= and keeps wg-quick's DEFAULT routing:
#   AllowedIPs 0.0.0.0/0 policy-routes every non-local packet into wg0, so
#   compose-network traffic stays DIRECT and a dead tunnel DROPS egress;
# * OpenVPN lane: routes alone leak when the daemon dies (they die with it), so
#   fail-closed is an iptables kill-switch: OUTPUT defaults to DROP, allowing only
#   lo, the RFC1918 compose networks, the conf's own `remote` endpoints (resolved
#   once, up-front) and tun+. A dead tunnel therefore DROPS egress exactly like
#   the WireGuard lane.
set -eu
SRC=/etc/wireguard/wg0.conf
[ -s "$SRC" ] || { echo "[egress-vpn] ERROR: no VPN conf at $SRC — pass EGRESS_VPN_CONF=<ABSOLUTE path to a provider wg-quick .conf or OpenVPN .ovpn>. EGRESS_VPN=1 without it is refused (fail-closed)." >&2; exit 1; }

if grep -q '^\[Interface\]' "$SRC"; then
    # ── WireGuard (wg-quick .conf) ───────────────────────────────────────────
    mkdir -p /run/wg
    grep -viE '^[[:space:]]*(DNS|Table)[[:space:]]*=' "$SRC" > /run/wg/wg0.conf
    wg-quick up /run/wg/wg0.conf
    echo "[egress-vpn] wg0 up (wireguard) — attached services egress via the tunnel (fail-closed)"
    trap 'wg-quick down /run/wg/wg0.conf' TERM INT
    sleep infinity &
    wait $!
elif grep -qiE '^[[:space:]]*(client|remote[[:space:]])' "$SRC"; then
    # ── OpenVPN (.ovpn) ──────────────────────────────────────────────────────
    # Kill-switch BEFORE the daemon starts, so there is no direct-egress window.
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -o 'tun+' -j ACCEPT
    for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        iptables -A OUTPUT -d "$net" -j ACCEPT      # compose-internal traffic stays direct
    done
    # the conf's own endpoints — the only non-VPN external destinations allowed
    grep -iE '^[[:space:]]*remote[[:space:]]' "$SRC" | while read -r _ host port proto _rest; do
        port="${port:-1194}"
        for ip in $(getent ahostsv4 "$host" | awk '{print $1}' | sort -u); do
            case "${proto:-udp}" in
                *tcp*) iptables -A OUTPUT -p tcp -d "$ip" --dport "$port" -j ACCEPT ;;
                *)     iptables -A OUTPUT -p udp -d "$ip" --dport "$port" -j ACCEPT ;;
            esac
            echo "[egress-vpn] kill-switch: allowing endpoint $ip:$port/${proto:-udp}"
        done
    done
    iptables -P OUTPUT DROP
    echo "[egress-vpn] kill-switch armed (OUTPUT drops by default) — starting openvpn"
    # foreground; container dies with the daemon and restarts (unless-stopped),
    # kill-switch re-arming on every start. --pull-filter keeps provider-pushed
    # DNS from clobbering docker's embedded resolver (same reason as the wg lane).
    exec openvpn --config "$SRC" --pull-filter ignore "dhcp-option DNS"
else
    echo "[egress-vpn] ERROR: $SRC is neither a wg-quick .conf ([Interface] missing) nor an OpenVPN .ovpn (no client/remote directive)" >&2
    exit 1
fi
