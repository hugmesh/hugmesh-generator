# Go-Live Wizard — taking a brand from internal-only to publicly live

The **go-live wizard** is the human-facing effector for the release-posture
mechanism that already ships in every image. It provisions the public edge
(tunnel credentials / DNS records / DDNS updater / port-forward checklist),
verifies it, and then — after a typed confirmation — writes the
**`/etc/snapdragon/go-live` marker**. That is all it does.

## The mechanism it drives (and never reimplements)

Every brand builds **internal-only by default** (`RELEASE_STATE=internal`):

* [`specs/usr/sbin/snapdragon-firewall-reconcile`](../specs/usr/sbin/snapdragon-firewall-reconcile)
  — boot oneshot + **60s cron**, fail-closed nftables backstop. Posture is
  PUBLIC iff `/etc/snapdragon/release-state` says `public` **OR**
  `/etc/snapdragon/go-live` exists; otherwise inbound 80/443 from outside the
  tailnet is dropped.
* [`specs/cluster/bootstrap/bootstrap.sh`](../specs/cluster/bootstrap/bootstrap.sh)
  — gates the public ingress / LAN-DNS answer node on the same
  `RELEASE_STATE`.

So **go-live = write the marker; rollback = delete the marker**. The reconcile
agent converges within 60 seconds, no rebuild, no reboot. The wizard only
trips the existing switch after the edge prerequisites pass — the posture
logic itself lives in those two files and NOWHERE in the wizard.

## The four faces of the one engine

| Interface | Entry point |
| --- | --- |
| CLI (the engine itself) | `scripts/go-live.sh --provider … --emit --verify --flip` |
| make | `make go-live PROVIDER=… DOMAIN=… GOLIVE_FLAGS='--emit'` |
| ncurses menu | `make go-live-menu` / `scripts/go-live-menu.sh` |
| Studio GUI / admin web UI | planned follow-ups; they will dispatch the same flags |

Providers are declared once in
[`scripts/golive-providers.conf`](../scripts/golive-providers.conf) — deep-link
URLs, required inputs, emitted artifacts, verify probes. Every front-end reads
that catalog; **a new provider is one new `[section]`, not four code edits**.

## Step flow

0. **Preflight** — `go-live.sh --status` shows release-state, marker, posture.
1. **Pick the exposure model / provider** — `--list`, then `--provider X --info`.
2. **Open the provider's exact pages** — `--links` (add `--open` for the
   browser). Create the tunnel / grab tokens there.
3. **Collect inputs** — the domain autofills from the device bake
   (`/etc/snapdragon/cluster-domain`); tokens come from `--token-file` or a
   masked prompt.
4. **Emit** — `--emit` renders the autofilled artifacts into `out/go-live/`
   (records.csv / zone.db / checklist / DDNS updater) and stores tokens into
   the keys layout.
5. **Verify** — `--verify` probes DNS/HTTP/tunnel health *before* any flip.
6. **Flip** — `--flip` (root, on-device, interactive). Verify runs first
   (`--force` skips it); then you must **type the domain** to confirm. The
   marker is written; reconcile opens 80/443 within 60s.

The hostname set is autofilled to the same reserved set the cloudflared
config maps: apex + `api.` + `matrix.` + `mastodon.` + the `*.<domain>`
wildcard (`specs/cluster/manifests/cloudflared/configmap.yaml`).

## Per-provider walkthroughs

### 1. `cloudflare-tunnel` — flagship (no inbound ports)

The plumbing already ships: `specs/cluster/apps/12-cloudflared.yaml` (ENV=prod
only) consumes `TUNNEL_TOKEN` via ExternalSecrets → Vault
`secret/<brand>/cloudflared`, fed from the keys layout
([`keys-template/cloudflared/README.md`](../keys-template/cloudflared/README.md)).

```sh
scripts/go-live.sh --provider cloudflare-tunnel --links --open   # tunnel page
scripts/go-live.sh --provider cloudflare-tunnel --domain example.org \
    --token-file /run/user/1000/tunnel-token --tunnel-id <UUID> --emit
```

`--emit` writes the token to `keys-template/cloudflared/tunnel-token` (0600,
gitignored) and renders the CNAME record set (`<host> →
<tunnel-id>.cfargotunnel.com`). Add the CNAMEs in the dashboard, **or** use
the one optional thin API driver v1 allows:

```sh
scripts/go-live.sh --provider cloudflare-tunnel --domain example.org \
    --tunnel-id <UUID> --cf-api-token-file /run/user/1000/cf-api-token --create-dns
```

(The API token goes to Cloudflare via a 0600 header file, never argv; the
proxied wildcard is dashboard-only on some plans and is warned about.)

### 2. `registrar-manual` — bring-your-own-domain, NO API

Works with every registrar. Emits `records.csv` + a BIND-style `zone.db`
pointing the host set at `--record-ip` (or at the tunnel CNAME when
`--tunnel-id` is given), plus deep links to the DNS pages of Namecheap /
GoDaddy / Porkbun / Route 53 / Squarespace. Paste, wait for propagation,
`--verify`, flip. Behind CGNAT there is no usable `--record-ip` — use
`cloudflare-tunnel` or `tailscale-funnel` instead.

### 3. `ddns` — DuckDNS / Cloudflare-DDNS (the real thin driver)

For home/dynamic-IP hosts. `--emit` stores the token at
`keys-template/ddns/token` and renders `out/go-live/ddns-update.sh` + a
`cron.d` snippet (5-minute floor, mirroring the `snapdragon-*-reconcile` cron
convention). Install them as
`/usr/local/sbin/snapdragon-ddns-update` + `/etc/cron.d/snapdragon-ddns`.

```sh
scripts/go-live.sh --provider ddns --ddns-service duckdns --ddns-subdomain home \
    --token-file /run/user/1000/duckdns-token --emit
scripts/go-live.sh --provider ddns --ddns-subdomain home --domain example.org --verify
```

`--verify` performs **one real update call** through the emitted script. The
updater reads the token from the keys file at runtime — never argv/cron mail.

### 4. `tailscale-funnel` — public HTTPS with no DNS records at all

`tailscale funnel` publishes the node on its `<node>.<tailnet>.ts.net` name
over Tailscale's edge. **Caveat (surfaced by `--info`)**: Funnel is a
tailscale.com-hosted control-plane feature; the default Snapdragon mesh is
self-hosted **headscale, which does not implement Funnel** — this provider
applies only to nodes joined to Tailscale proper. `--emit` renders the
enable-Funnel checklist; `--verify` runs `tailscale funnel status`.

### 5. `router-manual` — port-forward instructions only

Renders the forward-WAN-80/443-to-the-ingress-node checklist and links to
common router admin pages. **v1 never mutates the router** — no UPnP calls,
no vendor APIs. Pair with `registrar-manual` (static IP) or `ddns` (dynamic).

## Secret hygiene

* Tokens enter via `--token-file` / `--cf-api-token-file` or a **masked TTY
  prompt** — there is deliberately no `--token VALUE` flag (argv leaks via
  `/proc`).
* They are written ONLY to the catalog's `token_dest` keys-layout paths
  (`keys-template/cloudflared/tunnel-token`, `keys-template/ddns/token`,
  `keys-template/cloudflared/api-token`), mode 0600, all gitignored. Never
  committed, never echoed, never logged.
* The menu prompts masked, hands the value over via a 0600 temp file, deletes
  it after the run, and never persists it in its saved options.

## Flipping, and rolling back

```sh
sudo scripts/go-live.sh --domain example.org --flip            # marker only (recommended)
sudo scripts/go-live.sh --domain example.org --flip --persist  # also release-state=public
```

* `--flip` refuses without a real TTY and requires typing the domain —
  **unattended auto-go-live is a v1 non-goal; the human confirm is the
  security boundary.** There is no bypass flag for the confirm (`--force`
  only skips the verify gate).
* **Rollback = delete the marker**: `sudo scripts/go-live.sh --rollback`.
  Reconcile reverts to INTERNAL within 60s. If you flipped with `--persist`,
  roll back with `--rollback --persist` too — otherwise `release-state=public`
  keeps the device public and the engine warns about exactly that.

## Superadmin access note (mesh SSH)

Go-live runs **on the device** (root, `/etc/snapdragon`). If you operate it
over the mesh via SSH, your client machine needs `tag:superadmin` — which is
**force-assigned only via the manual allowlist**
`/etc/snapdragon/registry/superadmin-machines.txt` on the control (pki) node,
then `snapdragon-headscale-forcetags`. That step is deliberately manual
(hardening ref FIX-SERVERTAG) — see
[`docs/SUPERADMIN-MESH-CLIENT.md`](SUPERADMIN-MESH-CLIENT.md) for the exact
procedure. Without it you can still run the wizard from the device's local
console or any other authorized root path.

## v1 non-goals (deliberate)

* No full registrar API drivers (GoDaddy/Namecheap/Route53) — deep-link +
  downloadable files only. The only API code is the thin DDNS updaters and
  the optional Cloudflare CNAME creator.
* No automatic router port-forward/UPnP mutation — instructions only.
* No new public-cert lifecycle beyond what cloudflared/ingress already do;
  we never become a nameserver.
* No unattended/headless auto-go-live.
* No changes to reconcile posture logic — the wizard is purely an effector on
  the existing marker.
