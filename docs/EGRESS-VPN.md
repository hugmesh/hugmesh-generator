# Egress VPN (split-tunnel, fail-closed) — generator-side

Admins + superadmins import provider-downloaded VPN configs (ProtonVPN WireGuard
`.conf` **first-class**; OpenVPN `.ovpn` fallback) that mesh **nodes** use for
**OUTGOING / egress** traffic on PUBLIC-facing flows — coturn UDP audio/video,
made-public services, and (only on explicit assignment) akkoma/matrix federation.
The tailnet control plane + cluster-internal traffic stay **DIRECT** (split-tunnel).

This document is the **generator** (node-image) half: the key-USB delivery, the
node-level OpenRC service + split-tunnel runner, and the optional-services gate.
The control plane (Liquibase + `/bff/admin/egress-vpn` CRUD/assign), the
superadmin UI, and the signed-export reconcile bridge live in their own repos /
PRs.

## Node-level, not a per-pod sidecar

A NEW OpenRC service `/etc/init.d/hugmesh-egress-vpn` (Gentoo OpenRC; nodes are
**-systemd**) brings up ONE `wg-quick` (or `openvpn`) interface per node that
carries the node's public egress. Carrying the policy once per node — rather than
a sidecar per pod — keeps the kill-switch + `ip rule` priorities in one place and
lets the reconcile agent flip a single interface. TCP federation + UDP coturn ride
the one interface, selected by `fwmark`.

## Split-tunnel = `ip rule` PRIORITY + `Table=off`

`/usr/sbin/hugmesh-vpn-runner` owns ALL routing (wg-quick is forced
`Table = off`; OpenVPN runs `--route-noexec`). The VPN table (`176`) holds a
SINGLE forward route, `default dev wg0`:

| prio | rule | table | effect |
|---|---|---|---|
| 10 | `iif tailscale0` | main | tailnet ingress replies stay DIRECT |
| 20 | `from 100.64.0.0/10` | main | tailnet/CGNAT source stays DIRECT |
| 30 | `to 10.244.0.0/16` | main | pod CIDR (cluster-internal) DIRECT |
| 40 | `to 10.96.0.0/12` | main | service CIDR (cluster-internal) DIRECT |
| 100 | `fwmark 0x76` | **176** | ONLY marked public traffic → VPN |

The DIRECT rules (prio 10–40, table `main`) ALWAYS beat the VPN catch-all (prio
100) regardless of `fwmark` — so tailnet + cluster traffic NEVER enters the VPN.
Only packets MARKED `0x76` (set by the reconcile agent / nft for the assigned
public pods) match the prio-100 rule and egress via `wg0`.

## Kill-switch / FAIL-CLOSED

Table 176 also carries a `blackhole default metric 1000` guard. While `wg0` is up,
`default dev wg0` wins; if `wg0` DROPS, the route is withdrawn and marked traffic
hits the blackhole → `EPERM` (**fail closed**) instead of falling through to the
WAN default. A VPN outage therefore takes the PUBLIC egress offline rather than
LEAKING the node's real WAN IP. Tailnet/cluster traffic (higher-priority DIRECT
rules on `main`) is unaffected. The SAME `default dev wg0` + blackhole is installed
on the **IPv6** table 176 (DNS / v6 leak guard) so a v6-capable marked flow cannot
bypass the v4 kill-switch.

> **Residual risk (by design):** fail-closed means a VPN provider outage takes the
> assigned PUBLIC service offline (coturn relay / made-public egress) until the
> tunnel recovers or the assignment is removed. This is the intended trade-off
> over leaking the node WAN IP. Operators monitor via `hugmesh-vpn-runner
> status` / the reconcile agent's reported state.

## Secrets off-git

The `.conf`/`.ovpn` ride the key-USB under `KEYS/vpn/<domain>/` (+ the build-side
`keys-out/vpn/<domain>/`). `provision_vpn()` (in the keys-provision flow) reads
ONLY the node's OWN domain and installs them `0600` root-owned into
`/etc/hugmesh/vpn/`, pointing `active.conf` at the first config (WireGuard wins
over OpenVPN). The runtime UI path instead delivers a config as a K8s Secret via
ESO; Postgres holds only `secret_ref` + metadata. See `keys-template/vpn/README.md`.

## Default-off optional service

The egress VPN is a **default-off** optional service. The OpenRC service + runner
are baked into every node image but are INERT: the service is NOT linked into a
runlevel by the builders, and with no `active.conf` the runner is a no-op (public
egress falls back to the existing Squid egress-proxy / direct). It is enabled by
the optional-services gate (when selected) or flipped on per-assignment by the
signed reconcile agent. The gate prunes `net-vpn/wireguard-tools` +
`net-vpn/openvpn` from images that do not select it.

v1 keeps akkoma/tuwunel HTTP federation on the existing Squid egress-proxy; the
VPN is primarily for coturn UDP + made-public egress, and akkoma/tuwunel egress is
loosened onto the VPN only on an explicit assignment.

## Type-sniff

`active.conf` is type-sniffed at start: an `[Interface]`/`[Peer]` config →
`wg-quick`; a `remote …` / `client` / `dev tun` config → `openvpn`. WireGuard is
first-class.

## Tests

- `tests/egress-vpn/test-provision-vpn.sh` — `provision_vpn()` own-domain-only +
  0600 + cross-tenant DENY + fail-closed no-ops.
- `tests/egress-vpn/test-split-tunnel.sh` — the runner's `ip rule` priorities,
  fwmark catch-all, the v4+v6 `default dev wg0` + blackhole kill-switch, `down`
  teardown, and type-sniff (rootless via a recording fake `ip`; an optional real
  netns smoke runs under root).
