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

| When `tor` is …      | net-vpn/tor package | `tor` + `hugmesh-tor-reconcile` services | `tor-onion-marked` NetworkPolicy (`apps/08b-networkpolicy-tor.yaml`) |
|----------------------|---------------------|---------------------------------------------|----------------------------------|
| **selected** on a cluster-node role | added to the image | **both** linked into the default runlevel | its Application is baked (MANUAL sync) |
| **not selected** (default) | absent        | neither linked (daemon simply absent)       | its Application is pruned by `gate_optional_services`, so the cluster never gets it |
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

### Ingress admission: the onion must be an Ingress host (hugmesh-generator#614)

The fe-gateway Ingress admits the cluster domain (`host: <domain>`,
`extraHosts: ["*.<domain>"]` in [`apps/20-gateway-fe.yaml`](../specs/cluster/apps/20-gateway-fe.yaml)),
and both ingress controllers run with `defaultBackend` disabled. A request whose Host/SNI
is `<x>.onion` and that no Ingress rule names is answered by ingress-nginx's default
server: a **404** with its default certificate, never the gateway.

On a hardware node **`/usr/sbin/hugmesh-tor-ingress-admit`** closes that gap (kind's
equivalent is `make kind-tor`). It runs from the tor cron drop-in every 5 minutes:

1. It reads the onions this node exports: `/var/lib/hugmesh/tor/hostname` and every
   `/var/lib/hugmesh/tor/<slug>.hostname`. Anything that is not a v3 name
   (`^[a-z2-7]{56}\.onion$`) is refused.
2. It writes them onto the fe-gateway ArgoCD Application as helm parameters
   `ingress.onionHosts[0..n]`. The Application's name comes from the baked
   `apps/20-gateway-fe.yaml`, because a non-default brand renames it `<brand>-gateway-fe`.
   Every other parameter is kept as it is. Onions that other nodes admitted are kept. The
   ones this node admitted before and no longer exports are withdrawn; its record is
   `/var/lib/hugmesh/tor-ingress/admitted`. It patches only when the set changes, and it
   puts the read `resourceVersion` in the patch, so a concurrent writer gets a conflict
   instead of losing an entry.
3. ArgoCD re-renders the gateway chart. `ingress.onionHosts` adds one rule per onion to
   the **same** Ingress, with the same backend as the cluster host. So the release state's
   ingress class (`nginx-internal` under `internal`) and the Anubis PoW gate apply to the
   onion exactly as they do to the clearnet name. There is no TLS entry for the onion,
   because no onion SAN exists; the edge's default certificate answers, and Tor Browser
   shows one warning.

With no exported onion, a node that admitted onions before withdraws them, and a node
that never did makes no write at all. `hugmesh-tor-ingress-admit status` prints each
exported onion and whether the live Application admits it. The log is
`/var/log/hugmesh-tor-ingress-admit.log`.

**Where it can run.** The patch needs `/etc/kubernetes/admin.conf`, which kubeadm writes
only on **control-plane** nodes:

| RELEASE_STATE | the edge | where to select tor |
|---|---|---|
| `internal` (default) | `ingress-nginx-internal` on the **pki** node, a control plane | pki (or omnibus). The onion is minted and admitted on the same node. |
| `public` | `ingress-nginx` on the **backend** node, a worker with no `admin.conf` | the **pki** node, with `/etc/hugmesh/tor/upstream` set to `<backend-ip>:443`. The onion is minted and admitted on pki. |

A tor selected on a worker cannot admit its own onions. The agent logs that and does
nothing. A transport for a worker's onions belongs to hugmesh/hugmesh-admin-bff-api#108.

**Durability.** A device applies its baked Application set and has no recursing root
(`specs/cluster/bootstrap/bootstrap.sh`), so nothing re-asserts the Application object and
the runtime parameters stay. An operator re-provision (`KEYS` + `.provision-force`) or
`HUGMESH_GITOPS_ROOT_RECURSE=1` may drop them (a client-side `kubectl apply` of the baked
Application, which carries no parameters, leaves them alone); either way the next cron
run puts them back.

**Orphaned onions.** Only the node that admitted an onion withdraws it. If that node is
rebuilt with a new onion key or retired, its old onion stays an Ingress host: a harmless
Host rule that points at the gateway, which no Tor client can reach any more. Remove it by
hand from the fe-gateway Application's `ingress.onionHosts[i]` parameters.

**What admission does not do.** It does not map the onion Host to a domain. The gateway
does that (hugmesh/hugmesh-gateway#38, landed): until something registers the onion in its
`APP_TENANCY_HOSTS_FILE`, the gateway serves an onion as the **default** domain. The
primary onion therefore reaches the default domain's login page. A per-domain onion
reaches the gateway too, but it serves its own domain only once its
`<onion>=<slug>` line is written; that writer is hugmesh-generator#582.

**Verified offline, not live.** `tests/scripts/test-tor-onion-ingress.sh` renders the
chart as ArgoCD does (`helm template` with the helm parameters). With the hostname file
present, the Ingress admits the onion; without it, the Ingress admits no `.onion` host.
The onion rule routes path `/` (Prefix) with the cluster host's exact backend. It
also drives the agent's `apply` and its real `status` (what the QEMU live leg grades on)
against a stub `kubectl` that, like the real one, refuses a patch without
`--type merge`. No booted node has run it yet: the
live proof is a pki node built `--with-tor`, where Tor Browser at `https://<onion>/`
shows the certificate warning and then the login page.

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
[`manifests/networkpolicy-tor/tor-onion-marked.yaml`](../specs/cluster/manifests/networkpolicy-tor/tor-onion-marked.yaml).
The policy has its own Application,
[`apps/08b-networkpolicy-tor.yaml`](../specs/cluster/apps/08b-networkpolicy-tor.yaml). It
syncs manually, because this is an egress-axis policy, and the build removes it when tor
is not selected. It used to sit in the auto-synced `manifests/networkpolicy`, where git
main shipped it to every cluster whatever the image selected (hugmesh-generator#617).
`tests/scripts/test-optional-netpol-autosync.sh` fails if an optional service's
NetworkPolicy is served from git by an Application every build keeps. It runs the real
build prune and compares the git render with the baked one, and it renders the directory
08b's own `spec.source.path` names.

Two consequences of the manual sync: on a tor build the `networkpolicy-tor` Application
shows OutOfSync until someone syncs it (the 08a precedent). And a tracking cluster that
already carries `tor-onion-marked` from the old auto-synced path loses it at the next
08-networkpolicy prune, and gets it back only when 08b is synced by hand. The policy is
inert either way.

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
- **Offline (runs pre-merge):** `tests/scripts/test-tor-onion-ingress.sh` — the onion's
  Ingress admission (#614), described above; `tests/scripts/test-optional-netpol-autosync.sh`
  — where the tor NetworkPolicy ships (#617).
- **Not yet exercised:** a booted QEMU or hardware node built with tor. The
  `tests/qemu/assertions.sh` tor block (both services linked, `/usr/bin/tor` present,
  exactly one tor process, a v3 hostname exported) has never run against a real guest,
  and the QEMU lane has no tor pass-through yet. The same goes for the boot order (the
  oneshot leaves the start to OpenRC, and the `@reboot` cron exports the first-boot
  hostname) and for the Ingress admission above: on a live control-plane guest the tor
  block also asks `hugmesh-tor-ingress-admit status` whether every exported onion is an
  Ingress host.

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

**Why `:443`, and why https.** The door is `https://<onion>/`, served by the TLS front, for
these measured reasons (hugmesh-generator#628, live onion, 2026-09-24):

- **A secure context.** Chromium does not treat a `.onion` origin as trustworthy. Over
  `http://<onion>/`, `window.isSecureContext` is `false`, the shell's
  `Cross-Origin-Opener-Policy` is ignored ("the URL's origin was untrustworthy"), and any
  `Secure` cookie the page is sent is dropped.
- **Parity with the node.** A baked node publishes its onion on `:443` too (the node contract
  above), so the compose lane, the kind lane and a device are entered the same way.
- **The session cookie.** user-bff marks `bff_session` `Secure` by default
  (`APP_SESSION_COOKIE_SECURE`, default `true` in its `application.yml`). The compose stack sets
  it `false` (`compose.local.yaml`, `hugmesh-user-bff-api`), which is the only reason a sign-in
  over `http://<onion>/` works locally: `POST http://<onion>/bff/login` answered
  `Set-Cookie: bff_session=…; HTTPOnly; SameSite=Lax` with no `Secure`. A mesh with the
  production default would lose the session on the http door.
- **The Anubis gate.** With `ANUBIS=1 TOR=1` the http door is the proof-of-work gate, whose
  cookies needed their own fix to work there (#627, below).

**What is not the reason: CSP `upgrade-insecure-requests`.** Earlier versions of this page
said the gateway's CSP upgrades every subresource of a page entered over http, so the SPA
could not boot over `http://<onion>/`. On the live stack that is false. The SPA documents
(`/`, `/login`) carry host-shell nginx's nonce CSP, which has no `upgrade-insecure-requests`,
on both onion ports; the gateway passes that header through. The gateway's own CSP, which does
end in `upgrade-insecure-requests` (hugmesh-gateway `SecurityConfig`), appears only on
responses the gateway generates itself, such as the anonymous `401` for `/user` or
`/social/matrix`, and those never govern the document. In Chromium through the SOCKS client,
`http://<onion>/` booted the SPA to `/login` with no request upgraded to https. The
2026-09-23 measurement that suggested otherwise used a test server that put the gateway's
CSP on the document itself.

**HSTS on the http door.** `http://<onion>/` does send `Strict-Transport-Security`
(host-shell nginx adds it `always`, and nothing strips it on `:80`; the TLS front strips it on
`:443`). Chromium ignores HSTS received over plain http (RFC 6797 §8.1), so a second http
visit stays http. Tor Browser's handling of it is unmeasured.

The TLS front's certificate is the stack's own (minted for the cluster domain), so Tor
Browser warns once. Whether Tor Browser, which treats `.onion` as a secure context, behaves
differently on the http port is unmeasured.

**What the onion Host resolves to.** The compose stack sets no onion tenancy mapping, so the
gateway maps the onion `Host` to the default domain and the onion serves the default brand.
hugmesh-gateway#38 (closed, PR #39 merged) added the mapping: with `APP_TENANCY_HOSTS_FILE` or
`APP_TENANCY_HOSTS` configured, an unmapped `.onion` fails closed.

**Known residuals.** With `ANUBIS=1 TOR=1` only the onion's `:80` is PoW-gated; `:443` reaches the
TLS front, which forwards to the fe-gateway directly (#586). tor resolves both upstream hostnames
once, when it parses its torrc, so recreating `hugmesh-fe-gateway` or `hugmesh-https-front` with a
new container IP needs `hugmesh-tor` recreated too.

**The Anubis cookie on the http door (#627).** Anubis sets its cookies `Secure; SameSite=None`
by default. On `http://<onion>/` Chromium drops them, returns to `pass-challenge` without them,
and Anubis answers `500` ("Oh noes!"; its log says "user has cookies disabled"), so the gate
could not be passed. `make stack-up ANUBIS=1 TOR=1` therefore exports
`ANUBIS_COOKIE_SECURE='false'` (Makefile `STACK_TOR_ENV`), which `hugmesh-anubis` reads as
`COOKIE_SECURE`: the cookies lose `Secure` and SameSite drops from `None` to `Lax`. Every other
bring-up keeps Anubis's default, and a caller's own `ANUBIS_COOKIE_SECURE` wins. The localhost
door (`:8923`) works either way, because Chromium treats localhost as secure. Not yet exercised
through the real onion: the live check is Chromium via the SOCKS client on `http://<onion>/`
ending on the HugMesh `/login` page rather than "Oh noes!", on a stack brought up with this
change. Tor Browser is a person's check.

The contract is gated offline by `tests/stack/test-tor-flip-wiring.sh` (16 checks, each with a
mutant that must turn it red).

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

**Which domain answers.** hugmesh-gateway#38 (PR #39, merged) makes an unmapped `.onion`
fail CLOSED, but only once onion tenancy is configured: `APP_TENANCY_HOSTS_FILE` is set, or
`APP_TENANCY_HOSTS` maps a named onion. The kind lane sets neither, so the gateway still
maps the kind onion to its default domain (`DomainRegistry.domainForHost`), and that is why
it serves the primary domain. When hugmesh-generator#582's host-map writer sets that file
on kind, the kind onion needs its own `<onion>=default` line, or every request to it gets
a 403.

```bash
make kind-up && make kind-images   # the kind lane itself (unchanged)
make kind-tor                      # host tor + Ingress rule; waits until the onion answers
curl --socks5-hostname 127.0.0.1:9052 -k -I https://$(bash scripts/kind-tor.sh onion)/
make kind-e2e-tor                  # @env:kind @via:onion — tests/e2e/features/platform/tor-onion-kind.feature
make kind-tor-down                 # stop tor, drop the Ingress rule (keys kept)
make kind-tor-check                # OFFLINE guard: tests/scripts/test-kind-tor.sh
```

`make kind-e2e-tor` is `tests/e2e/run.sh --bdd --env kind --via onion`. It reads the onion
and the SOCKS port from the LIVE kind tor (`kind-tor.sh onion` / `socks`) and exports them
as `SNAP_ONION_BASE_URL` and `SNAP_PROXY`. It runs ONLY `@via:onion and @env:kind`
scenarios, and it FAILS unless at least one passed and none skipped. The steps
(`tests/e2e/steps/kind-onion.steps.ts`) build their own proxied browser context with
`onionContext()` from `specs/helpers.ts`, the same seam the compose lane's onion scenario
uses, and never touch the unproxied `page` fixture. They check that `http://<onion>/`
redirects to `https://<onion>/`, sign a persona in, read `/bff/session` over the onion,
and fail on any request, in the page listener or in the HAR, that went to a host other
than the onion. The `@env:kind` base URL stays the local kind door
(`https://hugmesh.net:8443`), because the availability probe in `world.ts` is an
unproxied Node request and could never reach an onion. The scenario has a 10-minute
budget, with up to 12 retries for first contact, because a cold onion descriptor took
118 s to publish on this host.

## Related

- [EGRESS-VPN.md](EGRESS-VPN.md) — the OUTBOUND dual (split-tunnel public egress).
- [OPTIONAL-SERVICES.md](OPTIONAL-SERVICES.md) — the registry + gate model.
