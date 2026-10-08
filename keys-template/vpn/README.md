# Egress VPN — provider configs (key-USB custody, per-domain, secrets-off-git)

This directory holds the **VPN configs downloaded from the provider**. The mesh
NODES use them for **OUTGOING / egress** traffic on PUBLIC-facing flows: coturn
audio/video UDP, made-public services, and, only when explicitly assigned,
akkoma/matrix federation. The tailnet control plane and cluster-internal traffic
stay **DIRECT** (split-tunnel); see `docs/EGRESS-VPN.md`.

An admin or superadmin drops the `.conf` they downloaded from their VPN provider
onto the physical key-USB, OUT-OF-BAND. `provision_vpn()` (in
`specs/etc/keys-provision/provision.sh`) installs it at first boot. It installs
**only the node's OWN domain's** configs, mode **0600**, root-owned.

> **NEVER commit a real VPN config here.** A `.conf` or `.ovpn` carries the private
> WireGuard key (or the OpenVPN auth), which is a secret. The tree below ships with
> `.gitkeep` placeholders ONLY. The operator drops the brand's real configs onto the
> key-USB. `scripts/gen-provision-keys.sh` copies them from `--vpn-src`. It never
> generates them, because only the VPN provider can.

## Layout

```
KEYS/
└── vpn/
    └── <domain>/                     one directory PER BRAND DOMAIN (tenant)
        ├── <name>.conf               ProtonVPN WireGuard config (FIRST-CLASS)
        └── <name>.ovpn               OpenVPN config (fallback)
```

- `<domain>` is the **brand / tenant domain**: `provision.json` `.egress_vpn.domain`
  if set, else `.hugmesh.cluster_domain` (the node's own residency).
  `provision_vpn()` reads ONLY `KEYS/vpn/<own-domain>/` and never installs a config
  from another domain's directory. This is per-tenant isolation as defence in
  depth; the runtime BFF/ESO path enforces the same domain scope.
- A domain may hold several `.conf`/`.ovpn` files (for example one per provider
  region or per public service). At provision time **all** of the own-domain
  configs are staged 0600 under `/etc/hugmesh/vpn/<name>.conf` or `<name>.ovpn`.
  `active.conf` is pointed at the first one if it does not exist yet (a WireGuard
  `.conf` wins over an `.ovpn`). The signed reconcile (`hugmesh-vpn-reconcile`) or
  the runtime UI path re-points `active.conf` later. The OpenRC service
  (`hugmesh-egress-vpn`) reads the symlinked `/etc/hugmesh/vpn/active.conf`.
- **Type detection.** The runner (`hugmesh-vpn-runner`) sniffs the CONTENT of
  `active.conf` at start. `[Interface]` / `[Peer]` sections mean WireGuard
  (`wg-quick`). `remote` / `client` / `dev tun` / `proto` lines mean OpenVPN. The
  `.ovpn` extension is only a fallback.

## Files (per `<domain>/`)

- **`*.conf`** — a ProtonVPN (or any WireGuard) `wg-quick` config. FIRST-CLASS.
  It carries `[Interface] PrivateKey=...` and `[Peer] PublicKey=... Endpoint=...`.
  The node sets `Table=off` and installs its own split-tunnel `ip rule`s. The
  runner does NOT trust the config's `AllowedIPs`/`Table` for routing. It carries
  only the catch-all `default dev wg0` on table 176, used only by packets marked
  `0x76`. **Secret — 0600, never on git.**

- **`*.ovpn`** — an OpenVPN config (the fallback when a provider has no
  WireGuard). It carries the remote and inline certs/keys (or references
  `secrets/` siblings). **Secret — 0600, never on git.**

## Build / staging flow (`keys-out/vpn/<domain>/`)

`scripts/gen-provision-keys.sh` stages each role's USB into `keys-out/`, the
build-side mirror of the KEYS partition. The VPN configs land at
`keys-out/vpn/<domain>/`, mirroring `KEYS/vpn/<domain>/` exactly. They are copied
from `--vpn-src DIR` (never generated). `--vpn-domain` (else `CLUSTER_DOMAIN`)
names the domain. `build-all-roles.sh` calls `gen-provision-keys.sh` once per role
(writing `keys-<role>` folders) but passes no `--vpn-src`; set `VPN_SRC` (and
`VPN_DOMAIN`) in the environment to stage configs that way. The configs are
secrets, so `.gitignore` skips `keys-out/`. Only the `.gitkeep` placeholder tree
under `keys-template/vpn/` is tracked.

## Fail-closed posture

- A node whose own domain has **no** `KEYS/vpn/<domain>/` directory (or an empty
  one) installs nothing and leaves the egress-VPN OpenRC service **stopped**
  (default-off optional service). Public flows then use the existing Squid
  egress-proxy (v1 keeps akkoma/tuwunel HTTP there). coturn UDP egresses direct
  until a config is assigned.
- When the service IS active, the split-tunnel kill-switch (`hugmesh-vpn-runner`)
  makes a `wg0`-down state **fail closed** for the VPN catch-all (table 176 has
  only `default dev wg0` plus a blackhole guard). A VPN outage takes the *public*
  egress offline instead of leaking the node's real WAN IP. Tailnet/cluster
  traffic is unaffected, because higher-priority DIRECT `ip rule`s on table main
  cover it.
