# Egress VPN — provider configs (key-USB custody, per-domain, secrets-off-git)

This directory carries the **provider-downloaded VPN configs** the mesh NODES use
for **OUTGOING / egress** traffic on PUBLIC-facing flows (coturn audio/video UDP,
made-public services, and — only on explicit assignment — akkoma/matrix
federation). The tailnet control plane + cluster-internal traffic stay **DIRECT**
(split-tunnel); see `docs/EGRESS-VPN.md`.

It is populated OUT-OF-BAND onto the physical key-USB (an admin/superadmin drops
the `.conf` they downloaded from their VPN provider) and consumed at first boot by
`provision_vpn()` (in `specs/etc/keys-provision/provision.sh`), which installs
**only the node's OWN domain's** configs, mode **0600**, root-owned.

> **NEVER commit a real VPN config here.** A `.conf`/`.ovpn` carries the private
> WireGuard key (or OpenVPN auth) — a secret. The tree below ships with
> `.gitkeep` placeholders ONLY. The operator drops the brand's actual configs onto
> the key-USB; `scripts/gen-provision-keys.sh` copies them from `--keys-src` (it
> never generates them — only the VPN provider can).

## Layout

```
KEYS/
└── vpn/
    └── <domain>/                     one directory PER BRAND DOMAIN (tenant)
        ├── <name>.conf               ProtonVPN WireGuard config (FIRST-CLASS)
        └── <name>.ovpn               OpenVPN config (fallback)
```

- `<domain>` is the **brand / tenant domain** (matches `provision.json`
  `.hugmesh.cluster_domain` — the node's own residency). `provision_vpn()`
  reads ONLY `KEYS/vpn/<own-domain>/`; a config under another domain's directory is
  **never** installed on this node (per-tenant isolation, defence-in-depth — the
  runtime BFF/ESO path enforces the same domain scope).
- Multiple `.conf`/`.ovpn` files per domain are allowed (e.g. one per provider
  region / per public service). The first verified Layer-B reconcile (PR5) or the
  runtime UI path selects which one is `active.conf`. At provision time **all** of
  the own-domain configs are staged 0600 under `/etc/hugmesh/vpn/<name>.conf`;
  the OpenRC service (`hugmesh-egress-vpn`, PR2) reads the symlinked
  `/etc/hugmesh/vpn/active.conf`.
- **Type detection**: a `.conf` is treated as WireGuard (`[Interface]` /
  `[Peer]` sections, `wg-quick`); a `.ovpn` is treated as OpenVPN. The runner
  type-sniffs the active file at start (PR2).

## Files (per `<domain>/`)

- **`*.conf`** — a ProtonVPN (or any WireGuard) `wg-quick` config. FIRST-CLASS.
  Carries `[Interface] PrivateKey=...` + `[Peer] PublicKey=... Endpoint=...`. The
  node sets `Table=off` and installs its own split-tunnel `ip rule`s (the runner
  does NOT trust the config's `AllowedIPs`/`Table` for routing — it carries only the
  catch-all `default dev wg0` on table 176). **Secret — 0600, never on git.**

- **`*.ovpn`** — an OpenVPN config (fallback when a provider has no WireGuard).
  Carries the remote + inline certs/keys (or references `secrets/` siblings).
  **Secret — 0600, never on git.**

## Build / staging flow (`keys-out/vpn/<domain>/`)

`scripts/gen-provision-keys.sh` stages each role's USB into `keys-out/` (the
build-side mirror of the KEYS partition). The VPN configs land at
`keys-out/vpn/<domain>/` exactly mirroring `KEYS/vpn/<domain>/`, copied from
`--keys-src` (never generated). `build-all-roles.sh` then writes them onto each
role's `keys-<role>` folder next to the ISO. Because the configs are secrets, the
`keys-out/` tree is `.gitignore`d (see `keys-out/vpn/README.md`); only the
`.gitkeep` placeholder tree under `keys-template/vpn/` is tracked.

## Fail-closed posture

- A node whose own domain has **no** `KEYS/vpn/<domain>/` directory (or an empty
  one) installs nothing and leaves the egress-VPN OpenRC service **stopped**
  (default-off optional service). Public flows then use the existing Squid
  egress-proxy (v1 keeps akkoma/tuwunel HTTP there); coturn UDP simply egresses
  direct until a config is assigned.
- When the service IS active, the split-tunnel kill-switch (PR2) makes a
  `wg0`-down state **fail closed** for the VPN catch-all (table 176 has only
  `default dev wg0` + a blackhole guard) — a VPN outage takes the *public* egress
  offline rather than leaking the node's real WAN IP. Tailnet/cluster traffic is
  unaffected (higher-priority DIRECT `ip rule`s on table main).
