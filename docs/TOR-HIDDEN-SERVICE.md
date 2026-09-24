# Tor v3 Hidden Service (onion gateway) — generator-side

Enable the **tor** optional service to expose the in-cluster **fe-gateway** as a v3
**onion (hidden) service**, so users can reach a domain over a `.onion` address via Tor
Browser — **no public IP, no dynamic DNS, no Cloudflare**. This is INBOUND reachability
(the dual of [egress-vpn](EGRESS-VPN.md), which is OUTBOUND egress).

## Model — a node service, gated like egress-vpn

`tor` is a **node-scoped, DEFAULT-OFF** optional service (`scope: node` in
[`specs/cluster/optional-services.yaml`](../specs/cluster/optional-services.yaml)). It is
**not** a cluster Application — it owns no `apps[]`, gateway host, or route-access rows.
Selection drives two NODE-level gates in both image builders (identical in spirit to
egress-vpn), and both gates call one predicate, `_tor_node_selected` = *tor selected
**and** a cluster-node role*:

| When `tor` is …      | net-vpn/tor package | `tor` + `hugmesh-tor-reconcile` services | `tor-onion-marked` NetworkPolicy |
|----------------------|---------------------|---------------------------------------------|----------------------------------|
| **selected** on a cluster-node role | added to the image | **both** linked into the default runlevel | kept |
| **not selected** (default) | absent        | neither linked (daemon simply absent)       | pruned by `gate_optional_services` |
| selected on a CLIENT / standalone / unaffiliated desktop | absent | neither linked | n/a (no cluster tree) — the selection is **dropped with a warning** right after the role is resolved |

Both builders' `--print-plan` states the outcome as `PLAN_TOR_ONION` — `off`, or
`on packages=net-vpn/tor services=tor hugmesh-tor-reconcile` — computed from the same
predicate and arrays the gates use. The package and service lists must equal the tor
entry's `nodePackages` / `nodeServices`; `tests/scripts/test-tor-node-contract.sh`
enforces that.

It reuses the **distro** Tor daemon (`net-vpn/tor` → `/etc/init.d/tor`, runs as the
`tor:tor` user). We do **not** ship a bespoke Tor runner; we own only the managed
`torrc` and the onion-key custody, via a small reconcile agent.

**Two owners, one daemon (decision 70 = B on hugmesh-generator#347).** OpenRC supervises
the daemon through the linked `tor` service; `hugmesh-tor-reconcile` (an OpenRC oneshot
ordered `before tor`, plus a 24h cron) never execs tor itself and converges whatever
state it finds:

| tor is …                       | the reconcile does |
|--------------------------------|--------------------|
| running, torrc unchanged        | nothing (the daily cron is a no-op) |
| running, torrc changed          | `rc-service tor reload` (SIGHUP; falls back to `kill -HUP` on `/run/tor/tor.pid`) |
| crashed (OpenRC status 32)      | `rc-service tor restart` |
| stopped                         | `rc-service tor start` |

It never restarts a healthy tor, so the boot-time race between OpenRC's own `tor`
start and the oneshot cannot produce a second daemon or a flapping onion. The candidate
torrc is verified with `tor --verify-config -f <candidate>` **before** it replaces
`/etc/tor/torrc`, and is installed only when it differs — a config that fails
verification never touches the running one.

**Where the agent is baked.** Every rpi5 image, and every x86 image **except
`--unaffiliated`** (the x86 bake sits inside the `if ! ${UNAFFILIATED}` platform block).
It is inert unless the gates above link it.

## Onion-key custody (OFF-GIT — the whole point)

The v3 onion keypair (`hs_ed25519_secret_key` + `hostname`) is **minted in-situ on first
boot** by the distro Tor daemon, into the `HiddenServiceDir` the reconcile agent
prepares: `/var/lib/tor/hugmesh-onion` for the mesh's primary onion, and
`/var/lib/tor/hugmesh-onion.d/<slug>` for each Tor domain (`0700` dir / `0600` keys,
owned by `tor:tor`). It is **never** baked into the image, **never** committed to git,
and **never** materialised as a K8s Secret. Because the key persists across reboots, the
`.onion` address is **stable**; because it never leaves the node, the private key is
bound to the node that minted it.

The agent exports each `.onion` hostname — the only artefacts that leave the node — to
`/var/lib/hugmesh/tor/hostname` (primary) and `/var/lib/hugmesh/tor/<slug>.hostname`
(each Tor domain). Today the one reader on the node is the Go-Live `tor-onion` plan
(`specs/usr/lib/hugmesh/go-live-providers.sh`); an admin-bff status endpoint that reads
them is tracked separately.

## Routing

Every onion publishes `HiddenServicePort 443` → an upstream, i.e. **HTTPS on the onion's
:443**, answered by the fe-gateway ingress with the **cluster domain's certificate**. No
onion SAN is minted anywhere, so Tor Browser shows a certificate warning once per visitor;
the Tor circuit itself is end-to-end encrypted and the `.onion` address authenticates the
service. (The **compose** lane's onion is different — plain HTTP on :80, see
`tests/stack/tor/` — and is not what a node publishes.)

A HOST-level Tor daemon cannot resolve cluster DNS, so the default upstream is the edge
that actually binds on hardware: **`127.0.0.1:443`** — ingress-nginx runs `hostNetwork`
:80/:443 on the node labelled `hugmesh.net/backend=true`
([`apps/10-ingress-nginx.yaml`](../specs/cluster/apps/10-ingress-nginx.yaml)). Any other
node binds nothing on :443: point it at the backend node by writing one `host:port`
line to `/etc/hugmesh/tor/upstream` (anything that is not a plain `host:port` is
refused and the default kept, because the value is written verbatim into the torrc).
A host tor fronting a **kind** node uses kind's port map, `127.0.0.1:8443`
([`kind-local.yaml`](../specs/cluster/bootstrap/kind-local/kind-local.yaml)).
Today nothing writes `/etc/hugmesh/tor/upstream` for you.

### Per-domain onions (decision 68 = A)

`tor` is the one per-domain infra slug: each non-comment line of
`/etc/hugmesh/tor/domains` names a domain slug (`[a-z0-9][a-z0-9-]{0,62}`), and each gets
its **own** `HiddenService` stanza fronting the **same** upstream; the gateway tells the
domains apart by the onion `Host` header. The primary onion does not depend on the file.
Removing a slug drops its stanza and its exported hostname but **never** its keypair, so
re-adding it brings back the same address. Nothing in the image build writes
`/etc/hugmesh/tor/domains` yet — the Studio/builder side that bakes it from the mesh's
Tor domains is separate work.

A secondary, **opt-in** capability (`hugmesh.net/tor-onion=true` label +
`tor-onion-marked` NetworkPolicy) lets a pod egress through the node Tor SOCKS proxy. It
is **inert by default** and additionally requires binding `SocksPort` to the pod network
(a deliberate future enablement) — see the header of
[`manifests/networkpolicy/tor-onion-marked.yaml`](../specs/cluster/manifests/networkpolicy/tor-onion-marked.yaml).

## SELinux

`net-vpn/tor` inherits `USE=selinux` from a SELinux node profile, which pulls the
**upstream** `sec-policy/selinux-tor` module — the Tor daemon runs confined as `tor_t`
with its keypair under `tor_var_lib_t`. The hugmesh reconcile agent has its own
authored module ([`specs/selinux/hugmesh_tor.te`](../specs/selinux/hugmesh_tor.te) /
`.fc`) granting only what it needs (write `torrc`, manage the Tor state dirs, start /
reload the service). Like the other node modules it is authored-but-not-yet-compiled — see
`docs/selinux-module-loading.md`.

## Enable / disable

- **x86 builder / Studio / build-menu:** `--with-tor` (or the "Tor v3 onion" toggle).
- **rpi5 builder / any node:** add `tor` to `OPTIONAL_SERVICES` (or `brand.conf`).
- **Disable (default):** omit it; `--exclude-services tor` force-removes it.
- **Node-scoped:** no effect on CLIENT/standalone/unaffiliated desktop roles. Both builders
  drop the selection with a warning once the role is known (`--with-tor`,
  `--optional-services tor` and `brand.conf` alike), and every tor gate calls
  `_tor_node_selected`, which also requires a cluster-node role. Before
  hugmesh-generator#583 the x86 check ran before the role was resolved and never fired,
  so `--with-tor --role desktop` emerged `net-vpn/tor` on a desktop.

## What is verified, and what is not

- **Offline (runs pre-merge):** `tests/scripts/test-tor-node-contract.sh` — the reconcile
  agent's convergence against stubbed `rc-service` / pidfile states, both builders'
  `PLAN_TOR_ONION` across node and client roles, the real rpi5 package resolver and the
  real x86 gate lines executed in a sandbox, the registry ↔ builder ↔ agent agreement,
  the Go-Live card's :443/https text, and the `tests/qemu/assertions.sh` tor block against
  fixture root filesystems.
- **Not yet exercised:** a booted QEMU or hardware node built with tor. The
  `tests/qemu/assertions.sh` tor block (both services linked, `/usr/bin/tor` present,
  exactly one tor process, a v3 hostname exported) has never run against a real guest,
  and the QEMU lane has no tor pass-through yet.

## Related

- [EGRESS-VPN.md](EGRESS-VPN.md) — the OUTBOUND dual (split-tunnel public egress).
- [OPTIONAL-SERVICES.md](OPTIONAL-SERVICES.md) — the registry + gate model.
