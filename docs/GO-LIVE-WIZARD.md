# Superadmin go-live wizard

> **Status: v1 CONSOLIDATED.** One architecture. This ships the shared driver,
> the provider registry, **three front-ends** (CLI, ncurses console menu, and the
> Studio GUI wizard), and **all five providers implemented end-to-end** —
> bring-your-own-domain, cloudflare-tunnel, DuckDNS/Cloudflare-DDNS,
> tailscale-funnel, and router-portforward. The mechanism is **baked on-image**
> by the two server builders and surfaced from a **console** and a **Studio**
> menu entry. What remains genuinely deferred is listed in
> [Deferred](#deferred).
>
> *(This doc is the single canonical go-live reference. It absorbed the former
> `docs/GO-LIVE.md` — the superseded #286 engine (`scripts/go-live.sh`,
> `scripts/golive-providers.conf`, `scripts/go-live-menu.sh`) and its doc were
> removed once their wins were ported onto this driver.)*

The go-live wizard is the **human-facing effector of the existing
`RELEASE_STATE` mechanism**. It does *not* reimplement the internal-vs-public
posture switch — it **trips the one that already ships**. Its job is to walk a
superadmin through provisioning the public edge (a tunnel token, or DNS records)
and then, as a single deliberate terminal action, flip the box live.

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

The wizard **never** touches nftables, ingress classes, or NetworkPolicies. It
writes (or deletes) one marker file and lets the existing reconcile agent do the
convergence. That is the whole safety story: the posture switch is one, audited,
fail-closed mechanism; the wizard is just a friendly way to trip it.

---

## Architecture — one shared driver, thin front-ends

Mirroring how **image-gen** exposes one shared driver behind thin per-interface
UIs:

```
       CLI front-end        ncurses console menu     Studio GUI wizard     web (DEFERRED)
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
`--tunnel-cname NAME`, `--domain D` (override the baked apex), `--ttl N`.
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
and the gateway already promise.

> **The go-live wizard flips only the public apex — never the orchestration
> superdomain.** Two domains coexist on a mesh and must not be conflated:
>
> - **Public apex** — `cluster_domain` (`/etc/hugmesh/cluster-domain`, e.g.
>   `hugmesh.systems`). This is the go-live *target*: the wizard provisions the
>   public edge for it and trips `release-state` `internal → public`.
> - **Orchestration superdomain** — `<brand>.internal` (default
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

All five providers are implemented end-to-end. Each is a **real registry row**
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

Now consolidated onto one architecture; the following are **DONE** and no longer
deferred:

- ✅ **ncurses console front-end** — `specs/usr/sbin/hugmesh-go-live-menu`.
- ✅ **Studio GUI wizard** — `gui/pages/golive.py`, repointed onto this driver.
- ✅ **All five provider emits** — `byo-domain`, `cloudflare-tunnel`,
  DuckDNS/Cloudflare-DDNS, `tailscale-funnel`, `router-portforward`.
- ✅ **On-image baking** — the two go-live server builders
  (`build-rpi5-stage4.sh`, `build-x86-host-stage4.sh`) bake the driver, the
  registry, and the CLI/menu front-ends into the sysroot inside
  `bake_host_firewall()`, right beside firewall-reconcile.
- ✅ **Console + Studio menu entries** — a "Go Live…" tray action in Studio and
  the on-device `hugmesh-go-live-menu` console face.

Still genuinely **deferred**, by design:

- **A pre-flip `verify` subcommand** (probe DNS/HTTP/tunnel/DDNS/funnel before
  `commit`). The gate today is preview-then-confirm; automated propagation
  probes are a follow-up driver subcommand every front-end would then surface.
- ✅ **The web front-end — DONE differently than the other three.** admin-bff's
  web console (already merged, admin-bff-api PR #200) doesn't call the driver
  directly like CLI/console/Studio do (it structurally can't — it runs in a
  pod, not on the host); it records a signed intent, and
  `hugmesh-go-live-reconcile` (see [Web-UI effector](#web-ui-effector-item-6-4-interface-parity)
  below) is the thin host-side piece that turns that intent into the same
  driver `commit`/`rollback` call the other three front-ends make directly.
- **On-image bake for the 4 desktop/appliance builders is intentionally
  omitted** — they bake neither firewall-reconcile nor release-state (they are
  clients/appliances, not go-live server nodes), so they legitimately ship
  without the wizard.

## Validation

- `bash -n` passes on the driver, the CLI front-end, and the registry lib.
- `tests/go-live/test-go-live-driver.sh` is an offline logic test (no root, no
  network): it asserts `plan` never writes the marker, `byo-domain` emits the
  five artifacts, the emitted zone is well-formed (and `named-checkzone`-clean
  when available), `commit` writes the marker only with an explicit `--yes`, and
  `rollback` removes it.

## Web-UI effector (item 6, 4-interface parity)

The admin-bff-api web console (`GoLiveController`/`GoLiveService`) lets a
superadmin **record** a go-live/rollback intent, signed and exported the same
way the domain-registry bridge is (`GoLiveExportService`, the same
`RegistrySigner` bean, the same Ed25519 + strict-monotonic-generation
contract). But admin-bff runs inside a Kubernetes pod — it structurally cannot
write `/etc/hugmesh/go-live` on the physical/VM host the way the
CLI/ncurses/Studio front-ends do directly. That gap is closed by
**`hugmesh-go-live-reconcile`** (`specs/usr/sbin/`, verify lib
`specs/usr/lib/hugmesh/golive-verify.sh`): a boot-oneshot + 60s-cron agent,
the same fetch/verify/apply idiom as `hugmesh-domain-reconcile`, that fetches
the signed export over the SAME core-provisioned in-cluster mTLS transport
(`node.env`'s `BFF_EXPORT_URL`/`BFF_CLIENT_CERT`/`BFF_CLIENT_KEY`), verifies it
fail-closed, and — for THIS node's own cluster domain only — drives the
canonical `hugmesh-go-live commit`/`rollback` subcommands. It never
reimplements posture-flipping; it only ever calls the same driver a human
operator would run. Idempotent (only invokes the driver on an actual state
transition) and honors the export's absence-means-no-op contract (a domain with
no recorded intent is a converged steady state, not an implicit rollback).

**Provider-catalog vocabulary — RECONCILED BY IDENTITY (was a drift):**
admin-bff-api's `GoLiveProviderCatalog` (Java) and the shell provider registry
(`specs/usr/lib/hugmesh/go-live-providers.sh` `GO_LIVE_PROVIDER_IDS`) were
originally written with a drifted key for the same provider — Java's
`generic-registrar` vs the shell's `byo-domain`. That drift is now closed by
**renaming Java's `generic-registrar` row to `byo-domain`** so the two catalogs
share the identity, and `map_bff_provider()` in `hugmesh-go-live-reconcile`
is now an IDENTITY map for it. `generic-registrar` is RETAINED there only as a
**legacy alias** (`generic-registrar -> byo-domain`) so pre-rename node images,
cached signed exports, and any un-re-keyed `go_live_intent` rows still resolve;
it is not deleted (dropping it would strand exactly those pre-rename artifacts —
the fleet-skew case the rollout order guards against). The BFF rename ships
merge-ordered: the generator/host-agent side (this repo) merges and BAKES into
node images FIRST, so every fielded agent already understands `byo-domain`
before the BFF starts emitting it.

`cloudflare-ddns` is **NOT** part of this rename and is **NOT** drift: it is a
deliberate separate wizard row backed by the shell `duckdns` driver's
`GL_DDNS_SERVICE=cloudflare` leg, which `map_bff_provider()` collapses to
`duckdns` as a driver-SUBOPTION (see the tripwire comment near that function —
if `cmd_commit` ever starts reading `GL_DDNS_SERVICE`, that collapse assumption
breaks). Leave it as-is.

**Residual (flagged, not closeable here — see the platform TODO queue):** there
is no cross-repo CI spanning admin-bff-api and this generator, so nothing
automatically asserts that *every* live `GET /bff/admin/go-live/providers`
catalog key maps in the host agent. The in-repo case-(m) guard in
`tests/go-live/test-go-live-reconcile-verify.sh` covers this today but HARD-CODES
the BFF key list rather than reading the live catalog, so it can silently drift
from `GoLiveProviderCatalog` if a future BFF adds a key. The durable guard would
be a stack-level e2e over both repos.

**The applied-ack loop is now WIRED** (companion admin-bff-api change: `POST
/bff/internal/go-live/{intentId}/applied-ack {generation, appliedBy}`, over
the same in-cluster mTLS transport `/export` uses). `ack_intent()` is called
from `apply_entry()` both right after a commit/rollback it actually drove
succeeds AND on an already-converged no-op cycle (the latter is what actually
acks a freshly-recorded intent whose target already matches the host's
current posture — the driver call is skipped as a no-op, but the ack still
needs to fire since this may be the row's first-ever cycle). It defaults to
POSTing at the same base URL as `/export` (`BFF_URL`/node.env's
`BFF_EXPORT_URL`); `GOLIVE_ACK_URL` only needs setting to point the ack at a
*different* base. It is best-effort: any failure (timeout, non-2xx) is logged
and swallowed — the posture change already succeeded regardless, and the
endpoint's CAS guard is idempotent server-side. This DOES mean a converged
entry keeps getting re-acked every 60s cycle for as long as it remains in the
export (no client-side tracking file suppresses this) — the thing that
actually bounds the load is the BFF's own absence contract: a successful ack
flips the row to `status=applied` server-side, which removes it from the
*next* signed export, so this node simply stops seeing the entry and the
re-ack traffic self-terminates. A failing ack is retried every cycle until it
lands, which is the desired self-healing behavior, not a bug.

**Still deliberately out of scope, matching this codebase's precedent for the
identical shape of gap (`hugmesh-domain-reconcile`'s own deferred
writeback):**
- **On-image baking.** This PR ships the agent + verify lib + init.d/cron
  files but does not add the `cp`/`chmod` lines to the stage4 builders — those
  lines land immediately after wherever the driver itself
  (`hugmesh-go-live`/`-cli`/`-menu`) gets baked, to avoid a redundant edit
  to the same builder-script region as that in-flight work.
- **The physical secret path from `plan`'s provider emission to this agent.**
  This agent never runs `plan` — provider artifact emission (DNS records,
  tunnel tokens) is the web wizard's own client-side guidance, completed by
  the superadmin BEFORE recording the intent; this agent's sole job is
  tripping the marker a recorded intent already authorizes.

Test: `tests/go-live/test-go-live-reconcile-verify.sh` — offline (no root, no
network), mirrors `test-domain-reconcile-verify.sh`'s verify-side rigor
(genuine/tampered/unsigned/foreign-key/rollback cases, an inline canonical-bytes
reference AND an independent python re-derivation) plus go-live-specific
apply-side cases against the REAL driver in a sandboxed `GL_ETC_HUGMESH`
(commit, rollback, the absence no-op contract, idempotency, and the two
fail-closed defaults gates).
