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

| Piece | Path | Role |
| --- | --- | --- |
| Shared driver | `specs/usr/sbin/hugmesh-go-live` | All logic: reads context, dispatches to a provider's emit, owns the confirmation gate + the marker write. Flag-driven; every front-end calls **only** its subcommands. |
| Provider registry | `specs/usr/lib/hugmesh/go-live-providers.sh` | Sourceable data + per-provider emit functions. The driver never hard-codes a provider — it iterates the registry. |
| CLI front-end | `specs/usr/sbin/hugmesh-go-live-cli` | Thin guided wizard; carries no logic, only calls the driver. Pass-through mode for scripting. |
| Console menu | `specs/usr/sbin/hugmesh-go-live-menu` | Thin ncurses/whiptail console face (plain-numbered fallback when there is no TTY/whiptail). Prompts secrets masked and hands them to the driver only via a 0600 `--token-file`. Pure subcommand dispatch — no wizard logic. |
| Studio GUI | `studio/hugmesh_studio/gui/pages/golive.py` | The 7-page desktop wizard, reachable from the tray's **"Go Live…"** entry or `python -m hugmesh_studio --go-live`. Its `core/golive_driver.py` shells out to the same driver subcommands. |
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

- **Preview is the default.** `plan` only writes into its output dir; it never
  reads or writes `/etc/hugmesh`.
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
- Tokens are written ONLY to the keys-layout destinations, mode 0600, all
  gitignored — `keys-template/ddns/token` (DDNS) and
  `keys-template/cloudflared/tunnel-token` (cloudflare-tunnel).
  Never committed, never echoed, never logged.
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
- ✅ **Studio GUI wizard** — `gui/pages/golive.py`, on this driver.
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
