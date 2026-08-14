# hugmesh-egress-vpn — minimal VPN CLIENT netns for the LOCAL docker mesh.
# Local translation of the x86 --egress-vpn FILE lane (build-x86-host-stage4.sh:4044-4101),
# scoped to opted-in containers: services attached via
# network_mode: "service:hugmesh-egress-vpn" get ALL their public egress via the
# tunnel, fail-closed. The entrypoint sniffs the mounted conf's CONTENT:
# * wg-quick .conf — kernel WireGuard from the HOST (Linux >= 5.6): no SYS_MODULE,
#   no /dev/net/tun needed;
# * OpenVPN .ovpn — userspace tun (compose grants NET_ADMIN + /dev/net/tun) behind
#   an iptables kill-switch, so a dead daemon DROPS egress instead of leaking.
FROM alpine:3.20
RUN apk add --no-cache wireguard-tools iproute2 openvpn iptables
COPY entrypoint.sh /usr/local/bin/hugmesh-egress-vpn-entrypoint
RUN chmod +x /usr/local/bin/hugmesh-egress-vpn-entrypoint
ENTRYPOINT ["/usr/local/bin/hugmesh-egress-vpn-entrypoint"]
