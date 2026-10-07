# Local LAN testing (`ENV=test`) — no public internet, no Cloudflare

The cluster is **fully testable on a LAN before any public address or
Cloudflare**. This is the **default** posture: every build is `--env test` unless
you explicitly ask for `--env prod`. A test image needs **no public internet, no
Cloudflare, no OAuth, no SMTP** — just the platform's native username/password
login (the first-party form → `POST /bff/login` → user-bff → internal Casdoor;
Casdoor itself is never browser-facing), the internal cluster CA, and an in-cluster
wildcard DNS resolver.

## TL;DR

```bash
make local          # builds the whole fleet for the LAN .test domain (hugmesh.test)
```

Then do the **one-time resolver step** below, and browse to
`https://id.hugmesh.test`, `https://hugmesh.test`, etc. from any LAN device.

## The build ENV selector (baked at image creation)

`--env test|prod` is baked into the image (`/etc/hugmesh/env`) and drives:

| | `test` (default) | `prod` |
|---|---|---|
| domain | `<brand>.test` (e.g. `hugmesh.test`) | real domain (e.g. `hugmesh.net`) |
| DNS | in-cluster **wildcard DNS** (`apps/09-lan-dns.yaml`) | public DNS / Cloudflare (`apps/12-cloudflared.yaml`) |
| certs | internal cluster CA (Vault-PKI) | cluster CA **+** ACME/public (additive) |
| OAuth / SMTP / Cloudflare | optional / absent | from the keys USB |
| build banner | quiet | **LOUD announced** (`BUILDING PROD IMAGE for <domain>`) |

The builders **prune** the ENV-irrelevant ArgoCD app from the baked
`/var/lib/hugmesh/cluster/apps` tree, so ArgoCD only ever syncs the right one:

- `ENV=test` removes `apps/12-cloudflared.yaml` (no Cloudflare on a LAN). If the
  domain does not end in `.test`, it also removes `apps/09-lan-dns.yaml`, so the
  LAN resolver cannot hijack a real domain; use `brands/local.conf` for a LAN build.
- `ENV=prod` removes `apps/09-lan-dns.yaml` (public DNS is authoritative).

How to select it:

```bash
make local                                  # ENV=test + brands/local.conf (hugmesh.test)
make prod                                   # ENV=prod, real domain (announced)
make build-all ENV=test BRAND=acme          # any brand, test
./build-x86-host-stage4.sh --env test --config brands/local.conf --role backend-gpu
./scripts/build-all-roles.sh --env test --config brands/local.conf
```

`brands/local.conf` is the dedicated `.test` profile: `CLUSTER_DOMAIN=hugmesh.test`,
`MAIL_PROVIDER=none`, OAuth/Cloudflare off, local-first mesh (empty `HEADSCALE_URL`),
offline Vault.

## The LAN-resolution gap this closes

Cluster **nodes** already resolve each other (provision.sh writes `/etc/hosts`).
But LAN **clients** — your browser, the Playwright e2e runner — are not on the
mesh and have no record for `id.<domain>`, `api.<domain>`, `mastodon.<domain>`,
`matrix.<domain>`, or the apex. Those are the ingress `host:` values; without a
resolver they resolve nowhere.

`apps/09-lan-dns.yaml` deploys a **CoreDNS** resolver (`manifests/lan-dns`) that:

- runs `hostNetwork` pinned to the **backend node** (the same node ingress-nginx
  binds `:80/:443` on), and binds host **`:53` (udp+tcp)**;
- answers **every** name under the brand domain (apex + any subdomain) with that
  backend node's LAN IP — which `bootstrap.sh` injects into the Corefile
  (`__LAN_INGRESS_IP__`), mirroring the headscale-Endpoints IP injection;
- forwards everything else to the node's upstream resolvers, so it is a drop-in
  LAN resolver, not just a stub for the brand zone.

## One-time operator step: point your resolver at the cluster

After the cluster is up (`bootstrap.sh` has run and patched the backend IP into
the resolver), point your **LAN router** or **clients** at the backend node's
IP on port 53. Then every LAN device resolves `*.<domain>` to the cluster.

1. Find the backend node IP (the one your router forwards 80/443 to):

   ```bash
   kubectl get node -l hugmesh.net/backend=true \
     -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
   ```

2. Point clients at it — pick ONE:

   - **Router (best, fleet-wide):** set the LAN DHCP "DNS server" to that IP. Every
     device on the LAN now resolves `*.hugmesh.test` to the cluster.
   - **A single test machine (Linux/macOS):** add it as a nameserver, e.g.
     `echo "nameserver <BACKEND_IP>" | sudo tee /etc/resolv.conf` (or a
     `systemd-resolved` per-link DNS), or for just the brand domain use a
     split-DNS entry pointing `hugmesh.test` at `<BACKEND_IP>`.

3. Verify:

   ```bash
   dig @<BACKEND_IP> id.hugmesh.test +short      # -> the backend node IP
   curl -k https://id.hugmesh.test/               # reaches Casdoor via ingress
   ```

That's it — no `/etc/hosts` edits per host, no public DNS, no Cloudflare. The
e2e runner can target the real brand subdomains once its resolver points here.

## Browsing the mesh from THIS machine

The section above needs a resolver you control. On a workstation with no admin
password you have neither that nor `/etc/hosts`, and four separate things break
at once:

1. every front door routes by **Host header**, so `http://localhost:8443/` 404s
   — the request arrives with the wrong Host, not with no route;
2. the names do not resolve, and the usual fix is a root-only file;
3. the https door pairs a **self-signed certificate** with
   `Strict-Transport-Security`, which Chrome will not let you click through and
   then remembers for a year — including for later, legitimate use of that name;
4. several UIs (argocd-server, casdoor, vault, harbor-portal) have no Ingress at
   all, so there is no door to aim a Host header at.

`make view` solves all four. It serves the doors as **HTTPS on 127.0.0.1** under
a CA it mints locally, and speaks HTTPS upstream with the correct Host header,
rewriting redirects, cookies and CSP host sources so an SSO round trip cannot
escape to a name the browser cannot resolve. Nothing in it needs root.

```bash
make view-trust        # once per workstation, then restart the browser
make view              # serve the host shell; `make view-stop` when done
make view-list         # the domain -> loopback-port map
```

`make view` is **one door: the host shell**, on `https://127.0.0.1:9080/`.
That is deliberate. Every user-facing surface is a federated Angular remote
loaded *through* the shell, so a row of side ports that let you open each
service directly is exactly how a broken federated route stays invisible until
production. When you are debugging the platform rather than using it:

```bash
make view LANE=kind-svc        # ArgoCD, Vault, Casdoor, Harbor
make view VIEW_ARGS='--only harbor-portal'
```

### Why it is https and not plain http

Serving plaintext on loopback is the obvious way to dodge problem 3, and it is
the wrong trade. A plain-http page is a **non-secure context**, so service
workers, WebCrypto, `Secure` cookies and `SameSite=None` all behave differently
than they will in the cluster — the exact class of bug local browsing exists to
catch is the one it would hide. `make view-trust` fixes problem 3 properly.

The CA it installs is **name-constrained** to `localhost`, `127.0.0.0/8` and
`::1`. This is the part worth understanding before you run it: an unconstrained
local CA in a browser trust store can vouch for *any* site on the internet, so
its private key sitting in `out/hugmesh-view/tls/` would be a standing risk to
every domain you browse. Constrained, the worst it can forge is loopback. It
goes into this user's own NSS stores (`~/.pki/nssdb`, each Firefox profile) —
never the system bundle — and `make view-untrust` removes it.

One header is still stripped on the way down: **HSTS**. That is not vestigial.
HSTS is scoped per *host*, not per port, so a single pinned response on
127.0.0.1 would force every other plain-http service on this workstation's
loopback to https for a year. It is the same trap as problem 3, aimed at
localhost.

### The lanes — kind, compose, and an emulated device

`LANE=` picks which set of doors is served. All of them use the same proxy; only
what sits behind it differs.

| `LANE=` | What it serves | How it reaches it |
|---|---|---|
| `kind` *(default)* | the host shell | straight to the kind node's published `:8443`, with `Host: hugmesh.net` |
| `kind-svc` | ArgoCD, Vault, Casdoor, harbor-portal, Harbor's ingress | `kubectl port-forward` onto an **ephemeral** local port, with the proxy in front |
| `compose` | the `tests/stack/compose.local.yaml` front doors | straight to the published `PUBLIC_HOST_PORT` / `PUBLIC_HTTPS_PORT` |
| `device` | a live emulated device's own front door | `ssh -L` through the device's published ssh port |

Three things about that table are worth stating rather than discovering:

- **The port-forward is managed, not fire-and-forget.** It is started, health-checked
  (the tool waits for the port to actually accept, and gives up early if kubectl has
  already exited), recorded, and killed on exit. A *crashed* run's leftover forward is
  the nastier case — it keeps holding its port, so the next run's door silently serves
  the previous run's service — so every `make view` sweeps the last session's children
  first, and says what it swept. It only signals a pid whose `/proc` cmdline still
  matches what was recorded, so a recycled pid is never killed.
- **ArgoCD needs the proxy, not just a port-forward.** `argocd-server` serves TLS on
  443 and 307-redirects http→https on whatever port you hand it, so a bare
  `kubectl port-forward` gives you a redirect loop; the door terminates TLS for it.
- **The compose knobs are honoured.** The compose rows spell their upstreams as
  `${PUBLIC_HOST_PORT:-8088}` / `${PUBLIC_HTTPS_PORT:-8488}`, expanded from the
  environment, so a stack brought up on non-default ports needs no edit here.

The `device` lane is gated on a device actually being up: it reads the keep-alive
registry under `out/qemu-runs/devices/` and refuses, naming what it found, if every
record says `stopped`. `device+https://@gateway` resolves to the running device
carrying the front door. The tunnel argv comes from studio's single web-tunnel author
(`hugmesh_studio.core.emulation.web_tunnel_argv`), so this tool cannot spell a forward
that differs from the one the Studio's own button uses.

> **Verified so far:** the `kind` and `kind-svc` lanes are exercised live. The
> `compose` and `device` lanes are implemented from the compose file's published
> ports and the device registry contract respectively, and are covered by the
> offline gate — but neither has been run against a live stack or a booted device,
> because neither was running when they were written. Treat them as untested.

### If a browser is already stuck on this domain

If you (or an earlier attempt) already clicked through `https://hugmesh.net:8443`
before this tool existed, the browser may have pinned HSTS for the domain — and
because the certificate is self-signed, Chrome then refuses to let you proceed at
all, with no "advanced" escape. The pin outlives the cluster; deleting the kind
cluster does not clear it.

- **Chrome/Chromium:** open `chrome://net-internals/#hsts`, put `hugmesh.net` into
  **"Delete domain security policies"** and delete it. Do the same for any subdomain
  you hit (`registry.hugmesh.net`, …) — `includeSubDomains` means the apex entry is
  usually the one that matters. There is no way to do this from the interstitial.
- **Firefox:** History → Clear Recent History with "Site settings" ticked, or delete
  the site's entry via `about:permissions`; Firefox stores HSTS in
  `SiteSecurityServiceState.txt` in the profile.

Browsing through `make view` cannot cause this: HSTS is stripped from every response
on the way down, precisely so that visiting a door can never pin anything.

### Adding a domain

Append a row to `scripts/hugmesh-view.tsv` — six tab-separated columns
(`name  lane  host  upstream  local_port  path`). Nothing else: `make view-list`
will show it, `make view` will serve it, and any *other* door's redirect to that
hostname is rewritten to its loopback port automatically. A port collision is
one env var (`HUGMESH_VIEW_PORT_<NAME>`), never an edit to the file.

`make view-honesty` is the offline gate for all of the above (no cluster, no
network, no root).

## Going live later (`ENV=prod`)

`make prod` (or `--env prod`) bakes the real domain and **keeps** the cloudflared
go-live app instead of lan-dns. Drop the tunnel token on the keys USB
(`KEYS/cloudflared/tunnel-token`, see `keys-template/cloudflared/README.md`); it
is read-if-present, so an absent token just leaves the tunnel down. The internal
cluster CA keeps working offline in **both** envs — prod only **adds** the public
edge, it never replaces the offline CA.
