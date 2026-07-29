# Tor v3 Hidden Service (onion gateway) — generator-side

Enable the **tor** optional service to expose the in-cluster **fe-gateway** as a v3
**onion (hidden) service**, so users can reach a domain over a `.onion` address via Tor
Browser — **no public IP, no dynamic DNS, no Cloudflare**. This is INBOUND reachability
(the dual of [egress-vpn](EGRESS-VPN.md), which is OUTBOUND egress).

## Model — a node service, gated like egress-vpn

`tor` is a **node-scoped, DEFAULT-OFF** optional service (`scope: node` in
[`specs/cluster/optional-services.yaml`](../specs/cluster/optional-services.yaml)). It is
**not** a cluster Application — it owns no `apps[]`, gateway host, or route-access rows.
Selection drives two NODE-level gates (identical in spirit to egress-vpn):

| When `tor` is …      | net-vpn/tor package | `tor` + `hugmesh-tor-reconcile` services | `tor-onion-marked` NetworkPolicy |
|----------------------|---------------------|---------------------------------------------|----------------------------------|
| **selected**         | added to the image  | linked into the default runlevel            | kept                             |
| **not selected** (default) | absent        | not linked (daemon simply absent)           | pruned by `gate_optional_services` |

It reuses the **distro** Tor daemon (`net-vpn/tor` → `/etc/init.d/tor`, runs as the
`tor:tor` user). We do **not** ship a bespoke Tor runner; we own only the managed
`torrc` and the onion-key custody, via a small reconcile agent.

## Onion-key custody (OFF-GIT — the whole point)

The v3 onion keypair (`hs_ed25519_secret_key` + `hostname`) is **minted in-situ on first
boot** by `/usr/sbin/hugmesh-tor-reconcile` and persisted under
`/var/lib/tor/hugmesh-onion` (`0700` dir / `0600` keys, owned by `tor:tor`). It is
**never** baked into the image, **never** committed to git, and **never** materialised as
a K8s Secret. Because the key persists across reboots, the `.onion` address is **stable**;
because it never leaves the node, the private key is bound to the node that minted it.

The reconcile agent (an OpenRC oneshot ordered `before tor`, plus a 24h cron) is
idempotent: it writes the managed `/etc/tor/torrc`, restarts `tor` (which mints/refreshes
the keypair), and exports the `.onion` hostname to `/var/lib/hugmesh/tor/hostname` for
admin/cluster consumption (the only artefact that leaves the node).

## Routing

The hidden service maps `:443` → the **node-local fe-gateway ingress**. A HOST-level Tor
daemon cannot resolve cluster DNS, so the default upstream is `127.0.0.1:8443`; override
per node by writing one `host:port` line to `/etc/hugmesh/tor/upstream`.

A secondary, **opt-in** capability (`hugmesh.systems/tor-onion=true` label +
`tor-onion-marked` NetworkPolicy) lets a pod egress through the node Tor SOCKS proxy. It
is **inert by default** and additionally requires binding `SocksPort` to the pod network
(a deliberate future enablement) — see the header of
[`manifests/networkpolicy/tor-onion-marked.yaml`](../specs/cluster/manifests/networkpolicy/tor-onion-marked.yaml).

## SELinux

`net-vpn/tor` inherits `USE=selinux` from a SELinux node profile, which pulls the
**upstream** `sec-policy/selinux-tor` module — the Tor daemon runs confined as `tor_t`
with its keypair under `tor_var_lib_t`. The hugmesh reconcile agent has its own
authored module ([`specs/selinux/hugmesh_tor.te`](../specs/selinux/hugmesh_tor.te) /
`.fc`) granting only what it needs (write `torrc`, manage the Tor state dirs, restart the
service). Like the other node modules it is authored-but-not-yet-compiled — see
`docs/selinux-module-loading.md`.

## Enable / disable

- **x86 builder / Studio / build-menu:** `--with-tor` (or the "Tor v3 onion" toggle).
- **rpi5 builder / any node:** add `tor` to `OPTIONAL_SERVICES` (or `brand.conf`).
- **Disable (default):** omit it; `--exclude-services tor` force-removes it.
- **Node-scoped:** no effect on CLIENT/standalone desktop roles (the builders guard on
  `!ROLE_CLIENT`; an accidental `--with-tor` there is a logged no-op).

## Related

- [EGRESS-VPN.md](EGRESS-VPN.md) — the OUTBOUND dual (split-tunnel public egress).
- [OPTIONAL-SERVICES.md](OPTIONAL-SERVICES.md) — the registry + gate model.
