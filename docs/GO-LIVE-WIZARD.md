# Superadmin go-live wizard

> **Status: v1 consolidated.** One architecture: a shared driver, a provider registry,
> **three front-ends** (CLI, ncurses console menu, Studio GUI wizard) and **all six
> providers implemented end to end**: bring-your-own-domain, cloudflare-tunnel,
> DuckDNS/Cloudflare-DDNS, tailscale-funnel, router-portforward and tor-onion. The two
> server builders **bake** the mechanism on-image, and a **console** menu and a
> **Studio** menu entry surface it. What is still deferred is listed in
> [Deferred](#deferred).
>
> *(This page is the single canonical go-live reference. It absorbed the former
> `docs/GO-LIVE.md`. The superseded #286 engine (`scripts/go-live.sh`,
> `scripts/golive-providers.conf`, `scripts/go-live-menu.sh`) and its doc were removed
> once their wins were ported onto this driver.)*

The go-live wizard is the **human-facing effector of the existing `RELEASE_STATE`
mechanism**. It does *not* reimplement the internal-vs-public posture switch. It
**trips the one that already ships**. It walks a superadmin through provisioning the
public edge (a tunnel token, or DNS records) and then, as one deliberate terminal
action, flips the box live.

---

## How posture actually flips (what the wizard trips, and never reimplements)

The merged `RELEASE_STATE` feature already baked two files onto every image:

| File | Meaning | Default |
| --- | --- | --- |
| `/etc/hugmesh/release-state` | `internal` \| `public` (persistent, baked) | `internal` |
| `/etc/hugmesh/go-live` | live-override **marker**; its mere **existence** forces public | absent |

[`specs/usr/sbin/hugmesh-firewall-reconcile`](../specs/usr/sbin/hugmesh-firewall-reconcile)
(a boot oneshot **+ a 60s cron**, fail-closed) flips the host to **public** when
`release-state=public` **OR** the `go-live` marker exists — **no rebuild, no
reflash**. [`specs/cluster/bootstrap/bootstrap.sh`](../specs/cluster/bootstrap/bootstrap.sh)
gates the public ingress on the same flag.

So **go-live is the inverse of stay-internal**:

```
provision the edge  ──►  write /etc/hugmesh/go-live  ──►  reconcile converges ≤60s  ──►  PUBLIC
                                    (the wizard's ONLY mutation)      (existing agent)
rollback:            ──►  delete /etc/hugmesh/go-live  ──►  reconcile converges ≤60s  ──►  INTERNAL
```

The wizard **never** touches nftables, ingress classes or NetworkPolicies. It writes or
deletes one marker file and lets the existing reconcile agent converge. That is the whole
safety story: the posture switch is one audited, fail-closed mechanism, and the wizard
trips it.

---

## Architecture — one shared driver, thin front-ends

Mirroring how **image-gen** exposes one shared driver behind thin per-interface
UIs:

```
       CLI front-end        ncurses console menu     Studio GUI wizard     web (via reconcile agent)
  hugmesh-go-live-cli   hugmesh-go-live-menu    gui/pages/golive.py        │
              └──────────────┬─────────┴─────────┬─────────┴────────┬───────────┘
                             ▼                                       ▼
                   shared DRIVER: specs/usr/sbin/hugmesh-go-live
                   (context • provider dispatch • the commit/confirm gate)
                             │
                             ▼
             provider REGISTRY: specs/usr/lib/hugmesh/go-live-providers.sh
             (id • label • mechanism • deep-link • what-it-emits • emit fn)
```

Every arrow above lands on the driver **of the machine being flipped**. The CLI and
console menu run on the device itself. The Studio GUI runs the checkout's copy on
the Studio host, so it flips that host only. For an emulated device, Studio calls the
guest's own baked `/usr/sbin/hugmesh-go-live` over `ssh`.

| Piece | Path | Role |
| --- | --- | --- |
| Shared driver | `specs/usr/sbin/hugmesh-go-live` | All logic: reads context, dispatches to a provider's emit, owns the confirmation gate + the marker write. Flag-driven; every front-end calls **only** its subcommands. |
| Provider registry | `specs/usr/lib/hugmesh/go-live-providers.sh` | Sourceable data + per-provider emit functions. The driver never hard-codes a provider — it iterates the registry. |
| CLI front-end | `specs/usr/sbin/hugmesh-go-live-cli` | Thin guided wizard; carries no logic, only calls the driver. Pass-through mode for scripting. |
| Console menu | `specs/usr/sbin/hugmesh-go-live-menu` | Thin ncurses/whiptail console face (plain-numbered fallback when there is no TTY/whiptail). Prompts secrets masked and hands them to the driver only via a 0600 `--token-file`. Pure subcommand dispatch — no wizard logic. |
| Studio GUI | `studio/hugmesh_studio/gui/pages/golive.py` | The 7-page desktop wizard, reachable from the tray's **"Go Live…"** entry or `python -m hugmesh_studio --go-live`. It does **not** reach a device you built or emulated by itself: `studio/hugmesh_studio/core/golive_driver.py` runs the **checkout's** driver (`bash ./specs/usr/sbin/hugmesh-go-live …`) against the **Studio host's own** `/etc/hugmesh`, which flips something real only when the Studio host is itself a HugMesh node (the **This host** target). An emulated device is a separate target that Studio reaches only over `ssh`, calling the guest's own baked driver. See [Go live from an emulated mesh](#go-live-from-an-emulated-mesh). |
| Dev preview | `make go-live` / `make go-live-menu` | Repo-side dry-run of the driver's `plan` (and the console menu), sandboxed away from the host `/etc` via `GL_ETC_HUGMESH`. |

---

## Driver subcommands

```
hugmesh-go-live status                     # posture: release-state + marker + effective
hugmesh-go-live list                       # the provider catalogue (id / mechanism / full|stub)
hugmesh-go-live plan   --provider ID …     # DEFAULT: DRY-RUN — emit artifacts, never flip
hugmesh-go-live commit --provider ID …     # TERMINAL: confirm-gate, then write the marker
hugmesh-go-live rollback                   # delete the marker (→ internal ≤60s)
```

`plan` flags: `--out-dir DIR`, `--ingress-ip IP`, `--ingress-ipv6 IP6`,
`--turn-ip IP`, `--turn-ipv6 IP6`, `--tunnel-cname NAME`, `--domain D` (override the
baked apex), `--ttl N`, `--ddns-subdomain LABEL`, `--ddns-service duckdns|cloudflare`,
`--token-file PATH`, `--keys-dir DIR`.
`commit` flags: `--persist-public` (also bake `release-state=public`, so go-live
survives a marker delete), `-y`/`--yes`. `rollback` flags:
`--revert-release-state`, `-y`/`--yes`.

### Fail-safe design

- **Preview is the default.** `plan` never writes the marker or `release-state`,
  and its artifacts go only into its output dir. It does read the baked context
  under `/etc/hugmesh` (below). Its one write outside the output dir is a token:
  given `--token-file`, the `cloudflare-tunnel` and `duckdns` emits copy it into
  the keys layout, `<keys-dir>/cloudflared/tunnel-token` or `<keys-dir>/ddns/token`
  (mode 0600; `--keys-dir` defaults to `/etc/hugmesh/keys`). It stays there after
  the plan; see [Secret hygiene](#secret-hygiene).
- **Nothing flips without `commit`.** `commit` is the single subcommand that
  writes the marker, and only after a confirmation gate.
- **No silent flips in automation.** On a non-TTY shell `commit`/`rollback`
  refuse unless `-y/--yes` is passed explicitly.
- **Emit errors abort before the marker.** A provider emit failure exits before
  anything is written.
- **Rollback is trivial and always available:** delete one file.

The driver reads brand context from the baked files: apex domain from
`/etc/hugmesh/cluster-domain`, posture from `/etc/hugmesh/release-state`.
The public hostnames it autofills are the apex plus `api.`, `matrix.`,
`mastodon.` — the same set [`specs/cluster/apps/12-cloudflared.yaml`](../specs/cluster/apps/12-cloudflared.yaml)
and the gateway already promise — plus `turn.` **only** on a node carrying
`/etc/hugmesh/coturn-public` (coturn public mode, [`COTURN.md`](COTURN.md) §5).
Without that marker the emitted record sets are byte-identical to before the
knob existed. `turn.` is the one hostname that never rides the HTTP edge: it is
always a direct, unproxied A/AAAA at the relay node (`--turn-ip` /
`--turn-ipv6`, defaulting to the ingress pair), never a tunnel CNAME — TURN is
raw UDP/TCP and a proxied record would advertise a relay that answers nothing.

> **The go-live wizard flips only the public apex — never the Tailscale root
> domain.** Two domains coexist on a mesh and must not be conflated:
>
> - **Public apex** — `cluster_domain` (`/etc/hugmesh/cluster-domain`, e.g.
>   `hugmesh.net`). This is the go-live *target*: the wizard provisions the
>   public edge for it and trips `release-state` `internal → public`.
> - **Tailscale root domain** (formerly "orchestration superdomain", the name
>   Studio and this document used before 2026-09) — `<brand>.internal` (default
>   `hugmesh.internal`), the headscale MagicDNS `base_domain` every mesh node
>   joins. It is **permanently internal**: it carries the tailnet + `kube-api.<superdomain>`
>   control-plane endpoint, is never routable, and is **never** go-live-flipped.
>   It is delivered through the KEYS channel — `scripts/gen-provision-keys.sh`
>   stamps it into `provision.json` `.mesh.magic_dns_domain` (from `SUPERDOMAIN` /
>   `--superdomain`, default `<BRAND>.internal`), which headscale consumes — so no
>   go-live provider, DNS record set, or `RELEASE_STATE` transition ever touches it.
>
> Consequently `generate-brand-repos.sh`'s public + `*.internal` domain rejection
> never sees the superdomain (invariant I7): only the public apex flows into the
> go-live/RELEASE_STATE path.

---

## Providers (prioritised v1 list)

| # | id | Mechanism | v1 | What it emits / does |
| --- | --- | --- | --- | --- |
| 1 | `cloudflare-tunnel` | deeplink | **FULL** | Flagship (no inbound ports). Deep-link to the CF Zero-Trust Tunnels page; guides the tunnel-token drop into `keys-template/cloudflared/`; renders the CNAME record set (`<host> → <tunnel-cname>`) as `records.csv` for manual entry (or for cloudflared to create). No CF API driver by design — DNS mutation stays manual/cloudflared-side. Plumbing already exists (`apps/12-cloudflared.yaml`, `manifests/cloudflared/`, `keys-template/cloudflared/`). |
| 2 | `byo-domain` | files | **FULL** | The no-API baseline that covers everyone — works with **every** registrar. Emits a copy-paste record set, a downloadable BIND zone + CSV (A/AAAA/CNAME to the ingress IP or tunnel CNAME), and registrar DNS deep-links (Cloudflare / Namecheap / GoDaddy / Porkbun / Gandi / Route 53 / Squarespace). Behind CGNAT there is no usable ingress IP — use `cloudflare-tunnel` or `tailscale-funnel` instead. |
| 3 | `duckdns` | ddns | **FULL** | DuckDNS / Cloudflare-DDNS — a **real** thin single-token updater + `cron.d` drop-in (dynamic-IP homes). `plan` stores the token at `keys-template/ddns/token` (0600) and renders `ddns-update.sh` + a cron snippet (5-minute floor, mirroring the `hugmesh-*-reconcile` cron convention); the updater reads the token from the keys file at RUNTIME, never argv/cron mail. |
| 4 | `tailscale-funnel` | funnel | **FULL** | Tailnet-native public HTTPS on the node's `<node>.<tailnet>.ts.net` name — **no public DNS** to mutate. **Caveat:** Funnel is a tailscale.com-hosted control-plane feature; the default HugMesh mesh is self-hosted **headscale, which does not implement Funnel** — this provider applies only to nodes joined to Tailscale proper. Emits the enable-Funnel checklist. |
| 5 | `router-portforward` | instructions | **FULL** | Pure port-forward instructions (forward WAN 80/443 to the ingress node) + deep-links to your gateway / portforward.io. **v1 never mutates the router** — no UPnP, no vendor APIs. Pair with `byo-domain` (static IP) or `duckdns` (dynamic). |
| 6 | `tor-onion` | onion | **FULL** | Reachability with no public DNS, IP or open ports. Reads the `.onion` address the node's own Tor daemon minted (`/var/lib/hugmesh/tor/hostname`, or `GL_ONION_HOSTNAME`) and emits `onion.txt` (plus `domain-onions.txt` when the node serves per-domain onions), `deeplinks.txt` for Tor Browser, and `instructions.txt`. It mints nothing and ignores the go-live marker: the onion is live whenever the `tor` optional service runs. See [`TOR-HIDDEN-SERVICE.md`](TOR-HIDDEN-SERVICE.md). |

All six providers are implemented end-to-end. Each is a **real registry row**
(label, mechanism, deep-link, emit fn `glp_emit_<id>`); the driver never
hard-codes one — it iterates the registry, so a new provider is a single new row
plus its emit function, not a change in any front-end.

### `byo-domain` artifacts

`plan --provider byo-domain --out-dir DIR` writes:

| File | Purpose |
| --- | --- |
| `records.txt` | Aligned, copy-paste record table (host / type / value / TTL). |
| `records.csv` | `name,type,value,ttl,proxied` for spreadsheet / bulk import. |
| `<domain>.zone` | A syntactically-valid BIND zone (SOA + NS + records) — `named-checkzone` parses it; import wholesale or copy individual records. |
| `deeplinks.txt` | Deep-links to the common registrars' DNS pages (Cloudflare, Namecheap, GoDaddy, Porkbun, Gandi, Route 53, …). |
| `instructions.txt` | The step-by-step, including the `commit`/rollback tie-in. |

Record type is chosen from context: an `--ingress-ip` → `A` (+ `AAAA` with
`--ingress-ipv6`); otherwise a `--tunnel-cname` → `CNAME` (apex is annotated
`ALIAS`/ANAME since an apex `CNAME` is illegal per RFC 1912). With neither, the
values are obvious `REPLACE_WITH_INGRESS_IP` placeholders and the driver warns.

---

## End-to-end flow (bring-your-own domain)

```console
# 1. See where you stand.
$ hugmesh-go-live status

# 2. Preview the DNS you need (dry-run — nothing flips).
$ hugmesh-go-live plan --provider byo-domain \
      --ingress-ip 203.0.113.10 --out-dir /var/lib/hugmesh/go-live/out

# 3. Apply records.txt / import <domain>.zone at your registrar; wait for DNS.
$ dig +short api.example.com     # from off-network

# 4. Trip go-live (confirmation gate; writes /etc/hugmesh/go-live).
$ hugmesh-go-live commit --provider byo-domain
#    → PUBLIC within 60s via hugmesh-firewall-reconcile.
#    add --persist-public to also bake release-state=public.

# 5. Roll back anytime (delete the marker; re-closes within 60s).
$ hugmesh-go-live rollback
```

Guided equivalent (interactive TTY): `hugmesh-go-live-cli` walks steps 1–4
with a numbered menu, then double-checks before it calls `commit`.

Repo-side dry-run (never touches the host `/etc`):

```console
$ make go-live PROVIDER=byo-domain DOMAIN=acme.example INGRESS_IP=203.0.113.10
```

You can also preview the on-device **console menu** the same sandboxed way:
`make go-live-menu` (runs `hugmesh-go-live-menu` against a scratch
`GL_ETC_HUGMESH`, so it can never touch the host `/etc/hugmesh`).

---

## Secret hygiene

- Provider tokens enter via `--token-file` (a path) or a **masked TTY prompt** —
  there is deliberately **no** `--token VALUE` flag (argv leaks via `/proc`).
- The console menu prompts masked, hands the value to the driver via a 0600
  temp file, and deletes it right after the run; it never persists a token in
  any saved state.
- Tokens are written ONLY to the keys-layout destinations, mode 0600:
  `<keys-dir>/ddns/token` (DDNS) and `<keys-dir>/cloudflared/tunnel-token`
  (cloudflare-tunnel), where `--keys-dir` defaults to `/etc/hugmesh/keys` on a
  device. `plan` writes them, even though it is a dry run for the posture, and
  nothing deletes them afterwards. Never committed, never echoed, never logged.
  On an emulated mesh that copy lives in the guest and a Save copies it; see
  [What the guest keeps](#what-the-guest-keeps).
- **DDNS input is validated before it is ever rendered into the emitted
  root-cron updater** (ported verbatim from the #286 security fix): the DDNS
  subdomain must be a single lowercase DNS label
  (`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$` — dots and shell metacharacters are
  rejected) and any ingress IP is IPv4/IPv6 shape-checked. This closes the
  command-injection-as-root class before interpolation.

## Superadmin access note (mesh SSH)

Go-live runs **on the device** (root, `/etc/hugmesh`). If you drive it over
the mesh via SSH, your client machine needs `tag:superadmin` — which is
**force-assigned only via the manual allowlist**
`/etc/hugmesh/registry/superadmin-machines.txt` on the control (pki) node,
then `hugmesh-headscale-forcetags`. That step is deliberately manual
(hardening ref FIX-SERVERTAG) — see
[`docs/SUPERADMIN-MESH-CLIENT.md`](SUPERADMIN-MESH-CLIENT.md). Without it you can
still run the wizard from the device's local console or any other authorized
root path.

---

## Go live from an emulated mesh

> **Status: landed, except the proof lane.** The target model, the ssh path and the CLI
> (`hugmesh_studio.core.golive_target`, group FG1) are in the tree. The GUI and TUI faces
> (group FG2) are in the tree too: the wizard's Preflight **Target** picker, the TUI's
> `t`, and the go-live entry on the Mesh emulation page and in `meshemu`. Booting a mesh
> back from its save (group FG5) is in the tree as a CLI and Makefile lane only
> ([below](#persistence-the-posture-is-ephemeral)). The harness proof lane (group FG3)
> has not merged; read [its part](#the-proof-lane-fg3) as the contract it is held to.

A mesh you boot under QEMU from Studio's mesh-emulation page (or `meshemu` in the TUI)
can be taken live, from the Studio GUI and from the CLI, on Linux (X11 and Wayland), on
WSL2 and on native Windows. It is a rehearsal. The posture really flips inside the
guest, but no go-live commit makes an emulated node reachable from outside your
workstation ([below](#what-an-emulated-node-can-really-reach)). The posture lasts only
while the device runs. The guest keeps what you hand it, a provider token included,
and a Save copies that to your host
([Persistence](#persistence-the-posture-is-ephemeral)).

### The target model

Every go-live verb (`status`, `list`, `plan`, `commit`, `rollback`) runs against a
**target**:

| Target | What it is | When it is offered |
| --- | --- | --- |
| **This host** (LOCAL) | The Studio host is itself the node. This is the wizard's behaviour before this section. | Always offered. `commit` is refused unless `/etc/hugmesh/release-state` exists **and** `command -v hugmesh-firewall-reconcile` finds the reconcile agent. Without them the GUI picker still offers the row, because `status` and `plan` preview anywhere; the note under the picker says commit is refused, and why. The Flip step then refuses the commit inline with *this host is not a HugMesh node — pick a device*, and **GO LIVE** stays grey. The TUI's target line says the same, and the CLI's `targets` prints that sentence in the row's status column. |
| **Emulated** | A running keep-alive device record: `qemu_devices.discover_devices(<work>)` for the docker lane, `qemu_windows.running(<work>)` for WHPX. | One row per running emulated **server** device. The mesh's front-door row is preselected. |
| **Remote** (later) | Any ssh-reachable node, through the same code. | Not built yet. |

For an emulated target every go-live verb runs **inside the guest**. The Studio host
runs `ssh` and nothing else of go-live: it never runs the checkout's driver. (On Linux
the commit terminal wraps that `ssh` in `bash -c` only to hold the window open after it
exits.) The guest's own baked `/usr/sbin/hugmesh-go-live` is the authority. `status` and
`list` are read from it, so a guest whose baked driver is older than your checkout still
answers for itself, with its own provider list.

The channel is the emulation harness's own loopback ssh: the per-device key and the
forwarded port on `127.0.0.1` (22300-22399 for the docker lane). It is **not** mesh ssh,
so the `tag:superadmin` allowlist in the [note above](#superadmin-access-note-mesh-ssh)
plays no part.

### The flow

1. **Probe.** One read-only ssh round trip (`ssh … sudo -n sh -c '<probe>'`). It prints
   `command -v hugmesh-go-live`, `/etc/hugmesh/cluster-domain`, `/etc/hugmesh/domains`,
   `/etc/hugmesh/release-state` and the onion hostnames under `/var/lib/hugmesh/tor/`,
   each behind its own sentinel line. It answers two questions: does this guest carry a
   go-live driver at all, and which apex, domains and onions does it already have.
2. **List and status.** `ssh … sudo -n hugmesh-go-live list` and `… status`, with
   `BatchMode=yes`, so they never stop at a prompt.
3. **Plan.** Before any ssh call, Studio refuses what cannot run there (`tailscale-funnel`,
   an ingress IP inside the emulation; see [What is refused](#what-is-refused-and-why)).
   If you gave a token, Studio stages it into the guest over ssh **stdin**:
   `umask 077; t=$(mktemp /run/hugmesh-golive-tok.XXXXXX) && cat >"$t" && echo "$t"`. The
   value never appears on any argv, on the host or in the guest. Studio then runs
   `ssh … sudo -n hugmesh-go-live plan --provider P [--domain D] … --token-file $t --out-dir /var/lib/hugmesh/go-live/out/studio-<UTC stamp>`,
   streamed into the Generate page with the same two `==>` banners as a local plan. It
   never passes `--keys-dir`, so the guest driver uses its own keys layout,
   `/etc/hugmesh/keys`. With no `--domain`, the guest plans for its own baked apex.
   Whatever the plan did, Studio then runs `sudo -n rm -f -- $t` and says so if that
   failed. When the plan exits 0, Studio copies its artifacts back with `ssh … cat` into
   `<work>/golive/<label>/`, replacing the previous plan's files there. **Deleting the
   staged file does not delete the token from the guest:** a `cloudflare-tunnel` or
   `duckdns` plan stores its own copy ([What the guest keeps](#what-the-guest-keeps)).
4. **Commit.** Studio opens a terminal running
   `ssh -i KEY -p PORT <host-key options> -t -o LogLevel=ERROR user@127.0.0.1 'sudo hugmesh-go-live commit --provider P [--domain D] [--persist-public]'`.
   There is **no `-y`**. The guest driver's own confirmation prompt runs on the ssh pty,
   exactly as it would on the device's console.
5. **Rollback.** The same pattern, with `rollback [--revert-release-state]`.
6. **Journal.** The host records what it asked of the device in
   `<work>/golive/<label>.json`: the action (`commit` or `rollback`), the provider, the
   domain, the device's `started_at`, the UTC time, whether it was confirmed, and the
   exit code. It holds no secrets. The GUI writes it when it *launches* the terminal, so
   status says *commit launched from this host*: the answer was typed on the device's
   TTY, and the device's own status says whether it went through. The CLI writes it after
   `ssh` returns. Exit 0 reads *last commit from this host*. A non-zero exit (the device
   refused, you declined its confirm, or ssh failed) changed nothing. It is kept apart,
   under `refused`, beside the last action that did go through, and status says it
   *did NOT go through*.

`commit --persist-public` and `rollback --revert-release-state` behave exactly as on
real hardware, inside the guest. What differs is what the outside world can see (below)
and how long it lasts ([Persistence](#persistence-the-posture-is-ephemeral)).

### What an emulated node can really reach

The emulation harness publishes **only loopback ssh** from the container. Nothing outside
your workstation can open a connection *into* an emulated node. A mechanism could
therefore make the node reachable only if the node itself dials **out**, and on an
emulated mesh only one does: the guest's own Tor publishes its onion from boot, whether
or not you go live, and the driver refuses `commit` for `tor-onion` anyway. The
Cloudflare tunnel would dial out, but on an emulated mesh it never starts (below). So a
go-live commit changes the guest's own posture (the marker and its nft table), which is
what you rehearse, and nothing more.

| Provider | Mechanism | Reachability from an emulated mesh | What the Exposure and Provider steps say |
| --- | --- | --- | --- |
| `tor-onion` | `onion` | **real** (outbound only, from boot, not from go-live) | *can be really reachable (outbound only)* |
| `cloudflare-tunnel` | `deeplink` | **inert** (outbound only by design, but the tunnel does not start) | *can be really reachable (outbound only); but the tunnel token is consumed only by the PROD ExternalSecret, so on an emulated mesh the tunnel will not start* |
| `byo-domain` | `files` | **rehearsal** | *REHEARSAL — the posture flips inside the emulated node, but nothing outside this workstation can reach it; the harness publishes loopback ssh only* |
| `duckdns` | `ddns` | **rehearsal** | the same REHEARSAL sentence |
| `router-portforward` | `instructions` | **rehearsal** | the same REHEARSAL sentence |
| `tailscale-funnel` | `funnel` | **refused** | *not on headscale*, and `plan` and `commit` are refused (see [What is refused](#what-is-refused-and-why)) |

**The cloudflare-tunnel token on an emulated mesh.** The tunnel token is consumed in
exactly one place: the PROD-only `cloudflared-tunnel-token` ExternalSecret
([`specs/cluster/manifests/cloudflared/externalsecret.yaml`](../specs/cluster/manifests/cloudflared/externalsecret.yaml)).
It reads the token from the mesh Vault, which keys-provision fills from the keys USB at
provision time. `plan` storing a token in the guest's keys layout does not put it in
Vault. On an `ENV=test` image (which is what the emulated rpi5 and x86 server images
normally are) the `cloudflared` Application
([`apps/12-cloudflared.yaml`](../specs/cluster/apps/12-cloudflared.yaml)) is pruned
outright. On an `ENV=prod` image with no Vault key, External Secrets never creates the
Secret and the Deployment stays down. **Either way, on an emulated mesh the tunnel does
not start.** The Provider step says so next to the provider. A DuckDNS token is just as
idle there: `plan` only emits the updater and its cron line as files to install by hand.

### Persistence: the posture is ephemeral

A running device's disk is a per-run qcow2 **overlay** over the golden image, and a new
overlay is created on every boot. So the flipped posture **lasts only while the device
runs**. The Flip page shows an EPHEMERAL banner:

> this posture lives on this run's disk only: the next boot starts again from the golden image (in whatever posture it bakes) or from a Save (in the posture it was saved in) — Save the device to keep it; Status reads the posture from the device itself

**Status never infers the posture.** Every face (CLI `status`, the GUI's Preflight,
Verify and Flip panes, the TUI's `s`) reads it from the device in one read-only ssh round
trip, with the same two witnesses the proof lane uses: `hugmesh-go-live status`
(`effective posture:`) and `nft list table inet hugmesh_release_gate` (loaded with the
80/443 drop rule = internal, loaded without it = public, absent or unreadable =
unknown). It prints `device posture now (read <UTC time>): PUBLIC` or `INTERNAL` when
both witnesses agree, and `MIXED` with both values when they do not: while
`hugmesh-firewall-reconcile`'s 60 s cron has not yet caught up, or when one witness
cannot be read (no table loaded is not a lag, and is not called one). When the device
cannot be asked (stopped, no ssh, ssh failed) it prints `unknown (device not
reachable)` and the reason. It never guesses.

The host journal says *when* this host asked: a journal written during an earlier
boot (its `started_at` differs from the running record's) reads *during an earlier
boot*, and says nothing about the posture, because the boot since may have come from
the golden image or from a save taken while the device was public.

A device booted from a **Save mesh** set also says which save and the posture the save
was taken in: *booted from a save taken while PUBLIC (mesh-…, saved …)*. Save mesh
reads each device's posture with the same two witnesses just before it pauses it, and
records it as `golive_posture` in `mesh-save.json`. A set saved before this was
recorded says that its posture was not recorded.

`commit --persist-public` does not change this. It bakes `release-state=public` into the
running overlay, which the next boot discards like everything else (unless the device
was saved first).

#### What the guest keeps

Until the device stops, its overlay holds:

- **The posture:** `/etc/hugmesh/go-live` after a `commit`, and `release-state=public`
  after `commit --persist-public`. The guest driver also logs each plan, commit and rollback
  through `logger`, with the provider and never a token.
- **Every plan's artifacts**, each run in its own
  `/var/lib/hugmesh/go-live/out/studio-<UTC stamp>/`. Studio copies them back but never
  deletes them in the guest, so each plan adds a directory.
- **The provider token, in the guest's keys layout.** `plan` is a dry run for the
  posture, not for the token. Given a `--token-file`, the guest driver's
  `cloudflare-tunnel` and `duckdns` emits copy the token into
  `/etc/hugmesh/keys/cloudflared/tunnel-token` or `/etc/hugmesh/keys/ddns/token` (mode
  0600) and print `token stored -> …`. Studio's `rm -f` removes only the staged
  `/run/hugmesh-golive-tok.*` file, so this copy stays. A later plan with a token
  overwrites it, and nothing ever deletes it. Nothing on an emulated mesh reads it
  ([above](#what-an-emulated-node-can-really-reach)).
- **The staged file, only if deleting it failed.** It lives under `/run`, a tmpfs:
  root-only, in RAM, gone when the device stops, and never on the disk a Save copies.

On the Studio host there is the journal `<work>/golive/<label>.json` and the plan
artifacts copied into `<work>/golive/<label>/`. The artifacts name the token's guest
path and never hold its value: the token-drop guide and the DDNS updater both point at
the file. A token typed into the wizard's masked field sits in a 0600 host temp file
for the length of the run and is deleted afterwards, as on a real node. A token file you
name yourself is read and left where it is.

#### What a Save copies

**Save copy** and **Overwrite save** on a device row, and **Save mesh** for the whole
mesh, copy the device's disk through QEMU (`blockdev-backup sync=full`) into a
standalone qcow2. The copy is crash-consistent, and guest RAM is not in it. So a save
holds whatever the guest's disk held at that moment: the posture files, every
`studio-<UTC stamp>` artifact directory, and **any token a plan stored under
`/etc/hugmesh/keys/`**. It does not hold the staged `/run` file, the host journal or
`<work>/golive/`. A **Save mesh** set also copies each device's KEYS stick payload and
its login keypair beside the disk.

**On an emulated mesh, use a dummy token.** A real one cannot start a tunnel or an
updater there, yet it outlives the staged file, and a Save copies it onto your host. If
a real token went in, delete it in the guest before you save
(`ssh … sudo rm -f /etc/hugmesh/keys/cloudflared/tunnel-token`, or `…/ddns/token`) or
let a restart discard it, and revoke it at the provider. Treat a save of a device you
planned `cloudflare-tunnel` or `duckdns` on with a token like a keys stick.

Booting a mesh **from** a save, so that an emulated mesh can stay live across restarts,
is group FG5. It is a CLI and Makefile lane only: `make mesh-emu-up FROM_SAVE=mesh-<stamp>`
([`tests/qemu/README.md`](../tests/qemu/README.md)). It boots a new overlay over the saved
qcow2 and never writes to the save. A mesh booted that way carries the saved token again.
Studio has no "Boot from save" button: one waits on an operator decision, because it lets
an emulated node stay `public` for a long time. Studio's own start buttons boot the golden
image, so the wizard still says the posture is ephemeral.

### Per OS

| Host | Lane | What works | Commit terminal |
| --- | --- | --- | --- |
| **Linux, X11 or Wayland** | docker lane | Multi-node; any running server row. | The shared `TERMINALS` list, which gains `ptyxis` and `kgx` so a stock GNOME-on-Wayland desktop gets a commit terminal. Egress caveats for the emulated lane appear in the plan output. |
| **WSL2** | the same docker lane, through Docker Desktop | As on Linux. | A Linux terminal emulator if one is installed. Otherwise `cmd.exe /c start wt.exe`, or failing that `cmd.exe /c start`, wrapped around `wsl.exe -d $WSL_DISTRO_NAME -- ssh -t …`. When Windows interop is unavailable, Studio shows the exact `ssh` command to copy. |
| **Native Windows** | WHPX (QEMU for Windows) | **One x86 node only.** The docker lane stays refused there, because it needs `bash`. WHPX targets work because the path is ssh only. | Windows OpenSSH in a `CREATE_NEW_CONSOLE` window, the same way the mesh-emulation page's `_open_native_shell` already opens a WHPX device's shell. |

**Native Windows prerequisite (open, owned by the Windows work).** A WHPX device record
(`qemu_windows`) today carries `ssh_port`, but no `ssh_key` and no `ssh_user`, and its
`ssh_argv` relies on interactive login. A WHPX row becomes a go-live target only once the
record carries both `ssh_key` and `ssh_user`, so the key-based, non-interactive probe,
`list`, `status` and `plan` calls can run. Until then the WHPX row is listed but greyed.

### CLI

```console
# Studio's own CLI. No Qt needed, so the Windows MSI's console binary carries it too.
$ python -m hugmesh_studio.core.golive_target targets  [--work W]
$ python -m hugmesh_studio.core.golive_target probe    --target LABEL [--work W]
$ python -m hugmesh_studio.core.golive_target status   --target LABEL [--work W]
$ python -m hugmesh_studio.core.golive_target list     --target LABEL [--work W]
$ python -m hugmesh_studio.core.golive_target plan     --target LABEL [--work W] --provider P --domain D [--token-file F] …
$ python -m hugmesh_studio.core.golive_target commit   --target LABEL [--work W] --provider P --domain D [--persist-public]
$ python -m hugmesh_studio.core.golive_target rollback --target LABEL [--work W] [--revert-release-state]

# The same verbs through the Studio launcher:
$ hugmesh-studio-cli --go-live-target …
```

For an emulated target, `list` tags every provider with its reachability, and `plan`
prints the same verdict before it runs:
`[reachability] <provider> (<mechanism>) from <label>: <verdict>`. `--token-file` names a
**host** file. Its content goes to the guest over ssh stdin, and the guest stores it as
described [above](#what-the-guest-keeps).

`commit` and `rollback` exec `ssh -t …` in **your** terminal, so the guest driver's prompt
is the one you answer. They refuse to run when stdin is not a TTY, and they journal the
exit code. On **This host** they run the checkout's driver by its absolute path, from the
checkout (`sudo bash <checkout>/specs/usr/sbin/hugmesh-go-live commit …`), and `commit`
is refused off-node. The on-device CLI is unchanged: `hugmesh-go-live-cli` and
`hugmesh-go-live-menu` still work from a device-login shell.

In the GUI, the Preflight page gets a **target picker**, and the mesh-emulation page (and
the TUI's `meshemu` screen) gets a **Go live from this mesh…** action on the front-door
row, which opens the wizard with that target already picked.

### What is refused, and why

| Refused | Why |
| --- | --- |
| A target that is not running, or has no ssh port or key | There is no channel to the device. |
| A row with no go-live driver: client roles, Frite, Jetson, Orange Pi | It is not a go-live server node. Those builders bake no driver, on purpose ([Deferred](#deferred)). |
| `commit` for `tor-onion` | Unchanged and enforced by the guest's driver: the onion is reachable with the host INTERNAL, and the marker would only open public 80/443. |
| `plan` and `commit` for `tailscale-funnel` on an emulated target | Funnel is a feature of Tailscale's hosted control plane. An emulated mesh is coordinated by its own headscale, which does not implement it, so nothing would ever be published. Refused before any ssh call, in the commit command and in the wizard's preflight. **This host** is not refused: a real node may be on a Tailscale-hosted tailnet. |
| A **This host** commit on a host that is not a node | No `/etc/hugmesh/release-state` or no `hugmesh-firewall-reconcile`, so there is nothing to flip. |
| An ingress IP in `10.0.2.0/24` (QEMU slirp) or `10.77.0.0/24` (the emulated mesh's L2) | These are private addresses inside the emulation. No registrar record can point at them. |
| Any automatic `-y` | The TTY confirmation is the security boundary. Studio never adds `-y`/`--yes` and never sets `GL_ASSUME_YES`. |

**Deliberately not built: an inbound relay on the Studio host.** Publishing
`0.0.0.0:80` and `0.0.0.0:443` from the Studio host into the emulation container would make
the rehearsal mechanisms really reachable. It would also expose the operator's own
workstation to the internet. That needs an operator decision first, so it is not built.

### The proof lane (FG3)

A harness lane proves the whole path **without any real publish**. It drives an
**already-running** keep-alive server row, so it needs no new QEMU boot when a device is
up (QEMU runs one at a time on the build host). It:

1. runs `plan` for `byo-domain` with `--domain example.invalid` and
   `--ingress-ip 203.0.113.10` (an RFC 5737 documentation address), and for `tor-onion`;
2. runs `commit` over `ssh -tt` and types `y` on the pty. That is the driver's **real**
   TTY prompt, answered the way a person answers it. It is not `GL_ASSUME_YES`, and it is
   not the "automatic `-y`" refused above;
3. asserts that the guest's nft table shows `public` within 90 s;
4. runs `rollback` and asserts `internal` again within 90 s.

It makes no DNS, Cloudflare, registrar or ACME call.

## v1 non-goals (deliberate)

- No full registrar API drivers (GoDaddy / Namecheap / Route 53) — deep-link +
  downloadable files only. The only API code is the thin DDNS updaters
  (DuckDNS / Cloudflare-DDNS A-record refresh); there is **no** Cloudflare
  tunnel CNAME creator — `cloudflare-tunnel` renders the CNAME `records.csv`
  for manual entry (or for cloudflared to create) and drops the tunnel token.
- No automatic router port-forward / UPnP mutation — instructions only.
- No new public-cert lifecycle beyond what cloudflared/ingress already do; we
  never become a nameserver.
- No unattended / headless auto-go-live — the human confirmation on a TTY is the
  security boundary.
- No changes to reconcile posture logic — the wizard is purely an effector on
  the existing marker.

---

## Deferred

These are **done** and no longer deferred:

- ✅ **ncurses console front-end** — `specs/usr/sbin/hugmesh-go-live-menu`.
- ✅ **Studio GUI wizard** — `studio/hugmesh_studio/gui/pages/golive.py`, on this driver.
- ✅ **All six provider emits** — `byo-domain`, `cloudflare-tunnel`,
  DuckDNS/Cloudflare-DDNS, `tailscale-funnel`, `router-portforward`, `tor-onion`.
- ✅ **On-image baking** — the two go-live server builders (`build-rpi5-stage4.sh`,
  `build-x86-host-stage4.sh`) bake the driver, the registry, the CLI and menu front-ends
  and the web-UI effector (`hugmesh-go-live-reconcile`, enabled as a boot service) into
  the sysroot inside `bake_host_firewall()`, next to firewall-reconcile.
- ✅ **Console and Studio menu entries** — a "Go Live…" tray action in Studio and the
  on-device `hugmesh-go-live-menu` console face.
- ✅ **The web front-end, done differently from the other three.** admin-bff's web
  console (merged, admin-bff-api PR #200) cannot call the driver directly, because it
  runs in a pod and not on the host. It records a signed intent.
  `hugmesh-go-live-reconcile` (see [Web-UI effector](#web-ui-effector-item-6-4-interface-parity)
  below) is the thin host-side piece that turns that intent into the same driver
  `commit`/`rollback` call the other three front-ends make directly.

Still **deferred**, by design:

- **A pre-flip `verify` subcommand** (probe DNS, HTTP, tunnel, DDNS and funnel before
  `commit`). The gate today is preview, then confirm. Automated propagation probes would
  be a new driver subcommand that every front-end then surfaces.
- **Emulated-mesh follow-ups** (see [Go live from an emulated mesh](#go-live-from-an-emulated-mesh)):
  a Studio button to boot a mesh from its save (the CLI and Makefile lane exists; the
  button waits on an operator decision); the **remote** target (any ssh-reachable node);
  and an inbound relay on the Studio host, which waits on an operator decision because it
  exposes the workstation.
- **The other eight builders** (Frite, Jetson, Orange Pi) bake no go-live driver, on
  purpose. They bake neither firewall-reconcile nor release-state, because they are
  clients and appliances, not go-live server nodes.

## Validation

- `bash -n` passes on the driver, the CLI front-end, and the registry lib.
- `tests/go-live/test-go-live-driver.sh` is an offline logic test (no root, no
  network): it asserts `plan` never writes the marker, `byo-domain` emits the
  five artifacts, the emitted zone is well-formed (and `named-checkzone`-clean
  when available), `commit` writes the marker only with an explicit `--yes`, and
  `rollback` removes it.

## Web-UI effector (item 6, 4-interface parity)

The admin-bff-api web console (`GoLiveController`/`GoLiveService`) lets a superadmin
**record** a go-live or rollback intent. The intent is signed and exported the way the
domain-registry bridge is: `GoLiveExportService`, the same `RegistrySigner` bean, the
same Ed25519 and strict-monotonic-generation contract. But admin-bff runs in a
Kubernetes pod and cannot write `/etc/hugmesh/go-live` on the host the way the
CLI, ncurses and Studio front-ends do. **`hugmesh-go-live-reconcile`** closes that gap
(`specs/usr/sbin/`, verify lib `specs/usr/lib/hugmesh/golive-verify.sh`). It is a
boot-oneshot plus 60s-cron agent with the same fetch, verify and apply idiom as
`hugmesh-domain-reconcile`. It fetches the signed export over the same core-provisioned
in-cluster mTLS transport (`node.env`'s `BFF_EXPORT_URL`/`BFF_CLIENT_CERT`/`BFF_CLIENT_KEY`)
and verifies it fail-closed. Then, for THIS node's own cluster domain only, it drives the
canonical `hugmesh-go-live commit`/`rollback` subcommands. It never reimplements
posture-flipping. It calls the driver a human operator would run. It is idempotent: it
invokes the driver only on an actual state transition. It honors the export's
absence-means-no-op contract: a domain with no recorded intent is a converged steady
state, not an implicit rollback.

**Provider-catalog vocabulary: reconciled by identity.** admin-bff-api's
`GoLiveProviderCatalog` (Java) and the shell registry (`GO_LIVE_PROVIDER_IDS` in
`specs/usr/lib/hugmesh/go-live-providers.sh`) once used different keys for the same
provider: Java's `generic-registrar` and the shell's `byo-domain`. Java's row is now
named `byo-domain`, so the two catalogs share the identity, and `map_bff_provider()` in
`hugmesh-go-live-reconcile` is an identity map for it. `generic-registrar` stays there
only as a **legacy alias** (`generic-registrar -> byo-domain`), so pre-rename node
images, cached signed exports and un-re-keyed `go_live_intent` rows still resolve.
Dropping it would strand exactly those. The rename shipped merge-ordered: the
generator and host-agent side merged and was baked into node images FIRST, so every
fielded agent understood `byo-domain` before the BFF started emitting it.

`cloudflare-ddns` is **not** part of this rename and is **not** drift. It is a separate
wizard row backed by the shell `duckdns` driver's `GL_DDNS_SERVICE=cloudflare` leg, which
`map_bff_provider()` collapses to `duckdns` as a driver sub-option (see the tripwire
comment near that function: if `cmd_commit` ever starts reading `GL_DDNS_SERVICE`, that
collapse breaks). Leave it as it is.

**Residual (not closeable here):** no cross-repo CI spans admin-bff-api and this
generator, so nothing asserts that *every* live `GET /bff/admin/go-live/providers`
catalog key maps in the host agent. The in-repo case-(m) guard in
`tests/go-live/test-go-live-reconcile-verify.sh` covers it today, but it HARD-CODES the
BFF key list rather than reading the live catalog, so it can drift from
`GoLiveProviderCatalog` if a future BFF adds a key. A stack-level e2e over both repos
would be the durable guard.

**The applied-ack loop is wired** (companion admin-bff-api change:
`POST /bff/internal/go-live/{intentId}/applied-ack {generation, appliedBy}`, over the same
in-cluster mTLS transport `/export` uses). `ack_intent()` runs from `apply_entry()` both
right after a commit or rollback it drove succeeds AND on an already-converged no-op
cycle. The no-op case is what acks a freshly recorded intent whose target already matches
the host's posture: the driver call is skipped, but the ack still has to fire, because
this may be the row's first cycle. It POSTs to the same base URL as `/export`
(`BFF_URL`, which comes from node.env's `BFF_EXPORT_URL`). Set `GOLIVE_ACK_URL` only to point the
ack at a *different* base. The ack is best-effort: a timeout or non-2xx is logged and
swallowed, because the posture change already succeeded and the endpoint's CAS guard is
idempotent server-side. A converged entry keeps getting re-acked every 60s cycle while it
stays in the export, because no client-side file suppresses it. The BFF's absence
contract bounds the load: a successful ack flips the row to `status=applied`, which drops
it from the *next* signed export, and the re-ack traffic stops by itself. A failing ack
is retried every cycle until it lands. That is the intended self-healing, not a bug.

**Still out of scope**, as for `hugmesh-domain-reconcile`'s own deferred writeback: the
**physical secret path from `plan`'s provider emission to this agent**. The agent never
runs `plan`. Provider artifact emission (DNS records, tunnel tokens) is the web wizard's
own client-side guidance, which the superadmin completes BEFORE recording the intent. The
agent's only job is tripping the marker a recorded intent already authorizes.

Test: `tests/go-live/test-go-live-reconcile-verify.sh`. It runs offline (no root, no
network) and mirrors `test-domain-reconcile-verify.sh`'s verify-side rigor
(genuine, tampered, unsigned, foreign-key and rollback cases, an inline canonical-bytes
reference AND an independent python re-derivation). It adds go-live-specific apply-side
cases against the REAL driver in a sandboxed `GL_ETC_HUGMESH`: commit, rollback, the
absence no-op contract, idempotency, and the two fail-closed defaults gates.
