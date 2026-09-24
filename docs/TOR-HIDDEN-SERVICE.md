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

## Kind lane — a host tor fronting the kind node (`make kind-tor`)

Operator decision 67 = B (hugmesh-generator#577, 2026-09-23): the kind lane gets a Tor
door. The kind node is the stock `kindest/node` image, not a baked stage4 node, so
nothing inside it runs Tor. Instead [`scripts/kind-tor.sh`](../scripts/kind-tor.sh) runs
the distro `tor` binary **on the host, as you** — no sudo, no system service, no
`/etc/tor`, no `User` directive — with a private `DataDirectory` and `HiddenServiceDir`
under the gitignored `tests/stack/.run/kind-tor/`:

| torrc line | what it reaches |
|---|---|
| `HiddenServicePort 443 127.0.0.1:8443` | the kind node's TLS door — `kind-local.yaml` maps ingress-nginx-internal's `:443` to host `:8443`. Same shape as the node contract above. |
| `HiddenServicePort 80 127.0.0.1:8080` | the plain door; kind's fe-gateway Ingress carries `force-ssl-redirect`, so `http://<onion>/` answers `308` to `https://<onion>/`. |
| `SocksPort 127.0.0.1:9052` | the client side for `curl` and the e2e browser. Not 9050, which a system tor or the compose lane's tor client may hold; `KIND_TOR_SOCKS_PORT` overrides, and a busy port is refused rather than shared. |

**Admitting the onion.** ingress-nginx answers a `Host: <onion>` request from its default
server (404) unless an Ingress rule names that host. `make kind-tor` appends ONE helm
parameter, `ingress.extraHosts[N]=<onion>`, to the ArgoCD Application
`hugmesh-gateway-fe` — N being the length of the `extraHosts` list the Application's own
values carry, so `*.hugmesh.net` is kept. The patch is **read-modify-write**:
`bootstrap-kind.sh` merge-patches `spec.source.helm.parameters`, which REPLACES the list
wholesale, so a literal list here would silently drop `ingress.className=nginx-internal`,
`force-ssl-redirect` and `MFA=1`'s `mfa.enabled`. Consequence the other way round: a
`make kind-up` re-run drops the onion rule — `make kind-tor` again restores it, and
`make kind-tor-status` says when it is missing.

**Custody.** The onion keys stay in `tests/stack/.run/kind-tor/hs/` (gitignored, `0700`)
and survive `make kind-tor-down`, so the address is stable across restarts; delete that
directory to mint a new one. `make kind-tor-status` and `scripts/kind-tor.sh onion`
answer only while **this** tor is alive (its pidfile names a live process whose command
line carries this torrc) — a leftover `hostname` file is not a live door.

**Certificate.** The kind Ingress has no TLS block, so `:443` presents ingress-nginx's
default certificate, not one for the onion. Tor Browser shows a certificate warning on
`https://<onion>/`; the e2e run uses `ignoreHTTPSErrors`. The onion address itself
authenticates the service, so this is a warning about the name, not about the channel.

**Which domain answers.** The gateway maps an unmapped `Host` to its default domain
today (`DomainRegistry.domainForHost`), which is why the kind onion serves the primary
domain. hugmesh-gateway#38 makes an unmapped `.onion` fail CLOSED; once it merges, the
kind onion needs a host-map entry as well.

```bash
make kind-up && make kind-images   # the kind lane itself (unchanged)
make kind-tor                      # host tor + Ingress rule; waits until the onion answers
curl --socks5-hostname 127.0.0.1:9052 -k -I https://$(bash scripts/kind-tor.sh onion)/
make kind-e2e-tor                  # @env:kind @via:onion — tests/e2e/features/platform/tor-onion-kind.feature
make kind-tor-down                 # stop tor, drop the Ingress rule (keys kept)
make kind-tor-check                # OFFLINE guard: tests/scripts/test-kind-tor.sh
```

`make kind-e2e-tor` signs a persona in through the onion and fails on any request that
left for a host other than the onion. It needs the browser routed through `SNAP_PROXY`,
which is the compose-lane Tor work's `playwright.config.ts` plumbing (hugmesh-generator#576);
until that lands the scenario FAILS naming it rather than reaching the plain kind door.

## Related

- [EGRESS-VPN.md](EGRESS-VPN.md) — the OUTBOUND dual (split-tunnel public egress).
- [OPTIONAL-SERVICES.md](OPTIONAL-SERVICES.md) — the registry + gate model.
