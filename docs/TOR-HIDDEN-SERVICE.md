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
`.fc`) granting only what it needs (write `torrc`, manage the Tor state dirs, restart the
service). Like the other node modules it is authored-but-not-yet-compiled — see
`docs/selinux-module-loading.md`.

## Enable / disable

- **x86 builder / Studio / build-menu:** `--with-tor` (or the "Tor v3 onion" toggle).
- **rpi5 builder / any node:** add `tor` to `OPTIONAL_SERVICES` (or `brand.conf`).
- **Disable (default):** omit it; `--exclude-services tor` force-removes it.
- **Node-scoped:** no effect on CLIENT/standalone desktop roles (the builders guard on
  `!ROLE_CLIENT`; an accidental `--with-tor` there is a logged no-op).

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

The contract is gated offline by `tests/stack/test-tor-flip-wiring.sh` (13 checks, each with a
mutant that must turn it red).

## Related

- [EGRESS-VPN.md](EGRESS-VPN.md) — the OUTBOUND dual (split-tunnel public egress).
- [OPTIONAL-SERVICES.md](OPTIONAL-SERVICES.md) — the registry + gate model.
