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
the daemon through the linked `tor` service. `hugmesh-tor-reconcile` is an OpenRC oneshot
ordered `before tor`, plus a cron drop-in with an `@reboot` entry (after a 90 s delay) and a
daily one. It never execs tor itself, and it converges whatever state it finds:

| tor is …                       | cron, or `/usr/sbin/hugmesh-tor-reconcile` run directly | the OpenRC service — at boot, or `rc-service hugmesh-tor-reconcile restart` (`RC_SVCNAME=hugmesh-tor-reconcile`) |
|--------------------------------|--------------------|-----------------------------------------------------|
| running, torrc unchanged        | nothing | nothing |
| running, torrc changed          | `rc-service tor reload` (SIGHUP; falls back to `kill -HUP` on `/run/tor/tor.pid`) | the same reload |
| crashed (OpenRC status 32)      | `rc-service tor restart` | nothing — left to the cron |
| stopped                         | `rc-service tor start` | nothing — OpenRC starts tor right after the oneshot |

**Why the boot oneshot never starts tor.** Because the oneshot is `before tor`, OpenRC
records tor as `iafter hugmesh-tor-reconcile`. A `rc-service tor start` issued from
inside the oneshot's `start()` would make that child `openrc-run` wait on the oneshot's
own exclusive lock. It would print "waiting for hugmesh-tor-reconcile" until the 60 s
`WAIT_TIMEOUT` and only then start tor, on every boot. (This comes from reading the
OpenRC source, `librc-depend.c` and `openrc-run.c`; it has not been seen on a guest.) It
would also be redundant, since `tor` is linked into the runlevel. So at boot the sequence
is:
1. The oneshot writes the directories and the verified torrc. It exports any hostname that
   is already minted, which is every boot after the first.
2. OpenRC starts tor, reading that torrc. This is the only daemon.
3. The cron's `@reboot` run (no `RC_SVCNAME`) finds tor running and the torrc unchanged,
   waits for the first-boot keypair and exports it.

The daily run re-asserts all of this. It also starts a tor that an admin stopped by hand,
so to keep tor down, deselect it or remove the cron drop-in. A healthy tor is never
restarted. The candidate torrc is verified with `tor --verify-config -f <candidate>`
**before** it replaces `/etc/tor/torrc`, and it is installed (mode 0644, so tor can
re-read it as `tor:tor` on SIGHUP) only when it differs. A config that fails verification
never touches the running one, and no candidate file is left in `/etc/tor`.

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
:443**, answered by the node's `hostNetwork` ingress edge. No onion SAN is minted anywhere,
so the certificate never carries the `.onion` name and Tor Browser shows a certificate
warning once per visitor. The Tor circuit itself is end-to-end encrypted, and the `.onion`
address authenticates the service. (The **compose** lane's onion is different; see
`tests/stack/tor/`. It is not what a node publishes.)

A HOST-level Tor daemon cannot resolve cluster DNS, so the default upstream is
**`127.0.0.1:443`**. That is correct only on the one node that runs the ingress edge, and
which node that is depends on the image's `RELEASE_STATE` (baked at
`/etc/hugmesh/release-state`):

| RELEASE_STATE | the `:443` listener | where the default upstream is right |
|---|---|---|
| `internal` (the **default**) | the builders prune `apps/10-ingress-nginx.yaml`; `ingress-nginx-internal` ([`apps/11-ingress-nginx-internal.yaml`](../specs/cluster/apps/11-ingress-nginx-internal.yaml)) runs `hostNetwork` on the `hugmesh.net/pki` node | the **pki** node (and omnibus) |
| `public` | `ingress-nginx` ([`apps/10-ingress-nginx.yaml`](../specs/cluster/apps/10-ingress-nginx.yaml)) runs `hostNetwork` on the `hugmesh.net/backend` node | the **backend** node (and omnibus) |

Every other node binds nothing on :443. Point it at the edge node by writing one
`host:port` line to `/etc/hugmesh/tor/upstream`. Leading and trailing whitespace is
trimmed. Anything that is not a plain `host:port` is refused and the default kept,
including a value with whitespace inside it, because the value is written verbatim into
the torrc. A host tor fronting a **kind** node uses kind's port map, `127.0.0.1:8443`
([`kind-local.yaml`](../specs/cluster/bootstrap/kind-local/kind-local.yaml)).
Today nothing writes `/etc/hugmesh/tor/upstream` for you (hugmesh/hugmesh-admin-bff-api#108).

### Known gap: the onion reaches the edge, not the login page (hugmesh-generator#614)

The fe-gateway Ingress admits only the cluster domain: `host: <domain>` and
`extraHosts: ["*.<domain>"]` in [`apps/20-gateway-fe.yaml`](../specs/cluster/apps/20-gateway-fe.yaml).
Both ingress controllers run with `defaultBackend` disabled. So a request whose Host/SNI is
`<x>.onion` is answered by ingress-nginx's default server, with a **404** and its default
certificate. It never reaches the gateway. On a hardware node nothing admits the minted
onion as an Ingress host yet. The kind lane does it at runtime with `make kind-tor`. Until
#614 lands, a node's onion proves the Tor path (circuit, key custody, torrc, edge) but does
not serve the mesh. Once it lands, the gateway still has to map the onion Host to a domain
(hugmesh/hugmesh-gateway#38). This gap is inferred from the manifests; no booted node has
shown it yet.

### Per-domain onions (decision 68 = A)

`tor` is the one per-domain infra slug: each non-comment line of
`/etc/hugmesh/tor/domains` names a domain slug (`[a-z0-9][a-z0-9-]{0,62}`; whitespace
around it is trimmed, and a line with whitespace or a dot inside is refused), and each gets
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
  and the QEMU lane has no tor pass-through yet. The same goes for the boot order (the
  oneshot leaves the start to OpenRC, and the `@reboot` cron exports the first-boot
  hostname) and for the known gap above.

## The local docker mesh (`make stack-up TOR=1`)

The compose stack has its own, single-container analogue of the node service
(`tests/stack/tor/`, compose profile `tor`). Everything below is compose-lane only — the kind
lane has no Tor door (hugmesh-generator#577) — and it is one onion for the whole mesh, not one
per domain (#582).

| Piece | What it is |
|---|---|
| `hugmesh-tor` | Serves the v3 onion. **`:443` → `hugmesh-https-front:8443`** (the stack's TLS front, `TOR_ONION_TLS_UPSTREAM`) and **`:80` → `hugmesh-fe-gateway:8080`** (`TOR_ONION_UPSTREAM`). Key in the `tor-onion-keys` volume, so the address survives `make stack-halt` and restarts; `make stack-down` drops the volume and the next up mints a **new** onion. |
| `hugmesh-tor-client` | A Tor SOCKS5 client on **`127.0.0.1:${TOR_SOCKS_HOST_PORT:-9050}`** (loopback only — never an open proxy for the LAN). The e2e lane's browser dials the onion through it. |
| `tests/stack/tor-onion/hostname` | The **public** hostname, copied out for the Studio and `make stack-onion`. Removed when `hugmesh-tor` starts and again when it stops or dies (#581), so it exists only while that onion is being served. |

```sh
make stack-up TOR=1          # + ANUBIS=1: the onion's :80 goes through the PoW gate
make stack-onion             # https://<56 chars>.onion/  (refuses a stale or malformed readout)
make stack-seed
make stack-e2e-tor           # the @via:onion sign-in, THROUGH Tor (tests/e2e/run.sh --via onion)
make stack-tor-mechanism-check   # host-tor mechanism proof: no docker, needs the public Tor network
```

**Why `:443`, and why https.** The gateway sends `Content-Security-Policy: … upgrade-insecure-requests`
on every response. Measured on 2026-09-23 against a live onion with Playwright's Chromium: a page
entered over `http://<onion>/` had its same-origin script upgraded to `https://<onion>/` and,
with only `:80` published, the script failed (`ERR_SOCKS_CONNECTION_FAILED`) and the SPA never
booted; with `:443` published but the page still entered over http, the upgraded `fetch()` became
cross-origin and failed (`ERR_FAILED`); entered over `https://<onion>/`, script and fetch both
succeeded. So the door is `https://<onion>/`, served by the TLS front. Its certificate is the
stack's own (minted for the cluster domain), so Tor Browser warns once. Whether Tor Browser —
which treats `.onion` as a secure context — behaves differently on the http port is unmeasured.

**What the onion Host resolves to.** The gateway maps an unknown `Host` to the default domain,
so the onion serves the default brand (hugmesh-gateway#38 tracks an explicit onion mapping).

**Known residuals.** With `ANUBIS=1 TOR=1` only the onion's `:80` is PoW-gated; `:443` reaches the
TLS front, which forwards to the fe-gateway directly (#586). tor resolves both upstream hostnames
once, when it parses its torrc, so recreating `hugmesh-fe-gateway` or `hugmesh-https-front` with a
new container IP needs `hugmesh-tor` recreated too.

The contract is gated offline by `tests/stack/test-tor-flip-wiring.sh` (15 checks, each with a
mutant that must turn it red).

## Related

- [EGRESS-VPN.md](EGRESS-VPN.md) — the OUTBOUND dual (split-tunnel public egress).
- [OPTIONAL-SERVICES.md](OPTIONAL-SERVICES.md) — the registry + gate model.
