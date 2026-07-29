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
| domain | `<brand>.test` (e.g. `hugmesh.test`) | real domain (e.g. `hugmesh.systems`) |
| DNS | in-cluster **wildcard DNS** (`apps/09-lan-dns.yaml`) | public DNS / Cloudflare (`apps/12-cloudflared.yaml`) |
| certs | internal cluster CA (Vault-PKI) | cluster CA **+** ACME/public (additive) |
| OAuth / SMTP / Cloudflare | optional / absent | from the keys USB |
| build banner | quiet | **LOUD announced** (`BUILDING PROD IMAGE for <domain>`) |

The builders **prune** the ENV-irrelevant ArgoCD app from the baked
`/var/lib/hugmesh/cluster/apps` tree, so ArgoCD only ever syncs the right one:

- `ENV=test` removes `apps/12-cloudflared.yaml` (no Cloudflare on a LAN).
- `ENV=prod` removes `apps/09-lan-dns.yaml` (public DNS is authoritative).

How to select it:

```bash
make local                                  # ENV=test + brands/local.conf (hugmesh.test)
make prod                                   # ENV=prod, real domain (announced)
make build-all ENV=test BRAND=acme          # any brand, test
./build-x86-host-stage4.sh --env test --config brands/local.conf --role be+gpu
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
   kubectl get node -l hugmesh.systems/backend=true \
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

## Going live later (`ENV=prod`)

`make prod` (or `--env prod`) bakes the real domain and **keeps** the cloudflared
go-live app instead of lan-dns. Drop the tunnel token on the keys USB
(`KEYS/cloudflared/tunnel-token`, see `keys-template/cloudflared/README.md`); it
is read-if-present, so an absent token just leaves the tunnel down. The internal
cluster CA keeps working offline in **both** envs — prod only **adds** the public
edge, it never replaces the offline CA.
