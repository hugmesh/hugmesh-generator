# Superadmin go-live wizard

> **Status: v1 FOUNDATION.** This PR ships the shared driver, the provider
> registry, a CLI front-end, and the fully-implemented **bring-your-own-domain**
> provider. The other providers are selectable **stubs**, and the
> **ncurses / Studio / web** front-ends are **deferred** to later passes (see
> [Deferred](#deferred)).

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
| `/etc/snapdragon/release-state` | `internal` \| `public` (persistent, baked) | `internal` |
| `/etc/snapdragon/go-live` | live-override **marker**; its mere **existence** forces public | absent |

[`specs/usr/sbin/snapdragon-firewall-reconcile`](../specs/usr/sbin/snapdragon-firewall-reconcile)
(a boot oneshot **+ a 60s cron**, fail-closed) flips the host to **public** when
`release-state=public` **OR** the `go-live` marker exists — **no rebuild, no
reflash**. [`specs/cluster/bootstrap/bootstrap.sh`](../specs/cluster/bootstrap/bootstrap.sh)
gates the public ingress on the same flag.

So **go-live is the inverse of stay-internal**:

```
provision the edge  ──►  write /etc/snapdragon/go-live  ──►  reconcile converges ≤60s  ──►  PUBLIC
                                    (the wizard's ONLY mutation)      (existing agent)
rollback:            ──►  delete /etc/snapdragon/go-live  ──►  reconcile converges ≤60s  ──►  INTERNAL
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
        CLI front-end          ncurses (DEFERRED)   Studio (DEFERRED)   web (DEFERRED)
   snapdragon-go-live-cli              │                   │                 │
              └──────────────┬─────────┴─────────┬─────────┴────────┬────────┘
                             ▼                                       ▼
                   shared DRIVER: specs/usr/sbin/snapdragon-go-live
                   (context • provider dispatch • the commit/confirm gate)
                             │
                             ▼
             provider REGISTRY: specs/usr/lib/snapdragon/go-live-providers.sh
             (id • label • mechanism • deep-link • what-it-emits • emit fn)
```

| Piece | Path | Role |
| --- | --- | --- |
| Shared driver | `specs/usr/sbin/snapdragon-go-live` | All logic: reads context, dispatches to a provider's emit, owns the confirmation gate + the marker write. Flag-driven; every front-end calls **only** its subcommands. |
| Provider registry | `specs/usr/lib/snapdragon/go-live-providers.sh` | Sourceable data + per-provider emit functions. The driver never hard-codes a provider — it iterates the registry. |
| CLI front-end | `specs/usr/sbin/snapdragon-go-live-cli` | Thin guided wizard; carries no logic, only calls the driver. Pass-through mode for scripting. |
| Dev preview | `make go-live` | Repo-side dry-run of the driver's `plan`, sandboxed away from the host `/etc`. |

---

## Driver subcommands

```
snapdragon-go-live status                     # posture: release-state + marker + effective
snapdragon-go-live list                       # the provider catalogue (id / mechanism / full|stub)
snapdragon-go-live plan   --provider ID …     # DEFAULT: DRY-RUN — emit artifacts, never flip
snapdragon-go-live commit --provider ID …     # TERMINAL: confirm-gate, then write the marker
snapdragon-go-live rollback                   # delete the marker (→ internal ≤60s)
```

`plan` flags: `--out-dir DIR`, `--ingress-ip IP`, `--ingress-ipv6 IP6`,
`--tunnel-cname NAME`, `--domain D` (override the baked apex), `--ttl N`.
`commit` flags: `--persist-public` (also bake `release-state=public`, so go-live
survives a marker delete), `-y`/`--yes`. `rollback` flags:
`--revert-release-state`, `-y`/`--yes`.

### Fail-safe design

- **Preview is the default.** `plan` only writes into its output dir; it never
  reads or writes `/etc/snapdragon`.
- **Nothing flips without `commit`.** `commit` is the single subcommand that
  writes the marker, and only after a confirmation gate.
- **No silent flips in automation.** On a non-TTY shell `commit`/`rollback`
  refuse unless `-y/--yes` is passed explicitly.
- **Emit errors abort before the marker.** A provider emit failure exits before
  anything is written.
- **Rollback is trivial and always available:** delete one file.

The driver reads brand context from the baked files: apex domain from
`/etc/snapdragon/cluster-domain`, posture from `/etc/snapdragon/release-state`.
The public hostnames it autofills are the apex plus `api.`, `matrix.`,
`mastodon.` — the same set [`specs/cluster/apps/12-cloudflared.yaml`](../specs/cluster/apps/12-cloudflared.yaml)
and the gateway already promise.

---

## Providers (prioritised v1 list)

| # | id | Mechanism | v1 | What it emits / does |
| --- | --- | --- | --- | --- |
| 1 | `cloudflare-tunnel` | deeplink | **stub** | Flagship. Deep-link to the CF Zero-Trust Tunnels page; guide the tunnel-token drop into `keys-template/cloudflared/`; autofill apex + `api./matrix./mastodon.`. Plumbing already exists (`apps/12-cloudflared.yaml`, `manifests/cloudflared/`, `keys-template/cloudflared/`). |
| 2 | `byo-domain` | files | **FULL** | The no-API baseline that covers everyone. Emits a copy-paste record set, a downloadable BIND zone + CSV (A/AAAA/CNAME to the ingress IP or tunnel CNAME), and registrar DNS deep-links. |
| 3 | `duckdns` | ddns | **stub** | DuckDNS / Cloudflare-DDNS — a real thin single-token updater + cron drop-in (dynamic-IP homes). |
| 4 | `tailscale-funnel` | funnel | **stub** | Tailnet-native public exposure; **no public DNS** to mutate. |
| 5 | `router-portforward` | instructions | **stub** | Pure instructions + deep-links to the gateway/portforward.io; **no mutation**. |

Only `byo-domain` is implemented end-to-end in v1. The stubs are **real registry
rows** (label, mechanism, deep-link) whose emit writes a clearly-marked
`STUB-<id>.txt` with a TODO pointing back here — so the framework is exercised
uniformly and every provider is visible and selectable.

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
$ snapdragon-go-live status

# 2. Preview the DNS you need (dry-run — nothing flips).
$ snapdragon-go-live plan --provider byo-domain \
      --ingress-ip 203.0.113.10 --out-dir /var/lib/snapdragon/go-live/out

# 3. Apply records.txt / import <domain>.zone at your registrar; wait for DNS.
$ dig +short api.example.com     # from off-network

# 4. Trip go-live (confirmation gate; writes /etc/snapdragon/go-live).
$ snapdragon-go-live commit --provider byo-domain
#    → PUBLIC within 60s via snapdragon-firewall-reconcile.
#    add --persist-public to also bake release-state=public.

# 5. Roll back anytime (delete the marker; re-closes within 60s).
$ snapdragon-go-live rollback
```

Guided equivalent (interactive TTY): `snapdragon-go-live-cli` walks steps 1–4
with a numbered menu, then double-checks before it calls `commit`.

Repo-side dry-run (never touches the host `/etc`):

```console
$ make go-live PROVIDER=byo-domain DOMAIN=acme.example INGRESS_IP=203.0.113.10
```

---

## Deferred

Explicitly **not** in this foundation, by design:

- **ncurses / Studio / web front-ends.** Only the CLI front-end ships now. Each
  future UI is a thin caller of the same driver subcommands — no wizard logic
  moves into a front-end.
- **Real provider drivers for #1, #3, #4, #5.** Only `byo-domain` is
  implemented. Each stub's emit records the exact follow-up: implement
  `glp_emit_<id>` in the registry lib. Per the design, only **DuckDNS /
  Cloudflare-DDNS** (#3) warrant a real thin API driver; the rest stay
  deep-link + downloadable-files + autofill.
- **On-image baking + a Studio/console menu entry.** The scripts live under
  `specs/usr/{sbin,lib}/…` in the house style, ready to be copied into the
  sysroot by the builders, but wiring the bake + a menu item is a follow-up.

## Validation

- `bash -n` passes on the driver, the CLI front-end, and the registry lib.
- `tests/go-live/test-go-live-driver.sh` is an offline logic test (no root, no
  network): it asserts `plan` never writes the marker, `byo-domain` emits the
  five artifacts, the emitted zone is well-formed (and `named-checkzone`-clean
  when available), `commit` writes the marker only with an explicit `--yes`, and
  `rollback` removes it.
