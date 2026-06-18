# Optional Services — add/remove by command (akkoma · tuwunel · phpBB · games · owncast · tube)

## 1. Purpose & scope

The platform splits into two tiers:

- **Architecture (core, always present):** the gateways (pki/be/fe), Casdoor/PKI,
  the federation API + remote-fragment + host shell, and the admin/user/mod
  BFFs + UIs.
- **Optional services (this doc):** **akkoma** (Mastodon-API fediverse server),
  **tuwunel** (Matrix homeserver), **phpbb** (forum), **games** (the
  snapdragon.games portal + its own games-realm Casdoor), **owncast** (HLS
  live-streaming, GPU-gated x86), **tube** (LocalTube YouTube archive, GPU-gated
  x86). (Plus the non-user-level optional slugs **egress-vpn** / **workloadConsole**
  / **anubis**, gated by the same registry.)

The optional services are **add/remove-by-command on any generated USB image**,
**identically on Pi5 (arm64) and x86 (amd64)** — the gate operates on the
arch-agnostic `specs/cluster` GitOps tree that both stage4 builders bake. The
federation architecture **works with any or all optional services omitted**: a
minimal install is just the architecture tier, and the host shell / federation
manifest / home cards / gateway / admin console **degrade gracefully** (greyed
out, never 500/502) rather than hard-failing.

The **single source of truth** is [`specs/cluster/optional-services.yaml`](../specs/cluster/optional-services.yaml).
Edit that one file; the generator derives everything else.

## 2. The source-of-truth file

`specs/cluster/optional-services.yaml` is the one list that names the installed
set (today "presence of a YAML in `apps/` IS the decision" via app-of-apps
`recurse:true` + `prune:true`, but nothing enumerates the *optional* set — this
registry is that missing list). Each service entry carries:

| field | meaning |
|---|---|
| `slug` | `akkoma` / `tuwunel` / `phpbb` / `games` / `owncast` / `tube` (+ `egress-vpn` / `workloadConsole` / `anubis`) |
| `namespace` | the k8s namespace it lands in |
| `apps` | the ArgoCD Application YAMLs it **owns** (pruned on removal) |
| `sharedApps` | apps shared with another slug (e.g. `45-social-ui.yaml`); pruned only when **all** owners are deselected |
| `manifestPath` / `extraManifestPaths` | its `manifests/<dir>` (pruned on removal) |
| `esoFile` | its **per-service** ExternalSecret file (post-split; see §9) |
| `gatewayHost` / `gatewayRouteIds` | its public host + the gateway route ids to drop |
| `routeAccessRows` | the `gateway_route_access` rows it owns (dropped so a matched route to a deleted upstream cannot 502 / stale-grant) |
| `federationModule` | the `federation_modules` registration (federation-api wave) |
| `casdoorSeed` | a dedicated Casdoor it owns (games → `casdoor-games`) |
| `default` | `akkoma`/`tuwunel`/`phpbb` → `on`; **`games`/`owncast`/`tube` → `off` (opt-in; owncast/tube are GPU-gated x86)** |

There is also a `gamesDomain` block (the `GAMES_DOMAIN` knob + the
parameterized files) — see §5.

**Rule:** edit `optional-services.yaml`, the generator derives the build-time
prune, the runtime `installed-services` ConfigMap, and (in the federation wave)
the `federation_modules` seed.

## 3. Build-time: select services on a USB

### Default-inclusion policy (user 2026-06-17)

| Tier | Slugs | When baked |
|---|---|---|
| **DEFAULT-ON** (the built-in default when no selection is given) | `akkoma`, `tuwunel` (Matrix), `phpbb` | always, unless `EXCLUDE_SERVICES` removes them |
| **DEFAULT-OFF** (must be specifically added) | `games`, `owncast`, `tube` — and any future user-level service | only when explicitly selected |
| **FULL-SET** | `OPTIONAL_SERVICES=all` / `--all-services` | every user-level slug — **rpi5 builder only today** (see caveat below) |

> ⚠ **`games` is DEFAULT-OFF** (it was previously default-on). Add it with
> `--enable-games` / `ENABLE_GAMES=true`, by naming `games` in `OPTIONAL_SERVICES`,
> or via the full set. `owncast`/`tube` are GPU-gated x86 services, also off by default.

Two inputs, in precedence order **built-in default (`akkoma tuwunel phpbb`;
games/owncast/tube OFF) < `brand.conf` < `--optional-services` CLI flag**:

- **`brand.conf`** knob (sourced by both builders):
  ```sh
  OPTIONAL_SERVICES="akkoma games"      # forum-less + Matrix-less appliance, WITH games
  ENABLE_GAMES=true                     # or keep the default list and just add games
  OPTIONAL_SERVICES="all"               # the FULL set (every user-level slug)
  ```
- **CLI flag** (overrides `brand.conf`):
  ```sh
  ./build-rpi5-stage4.sh      --optional-services "akkoma games"   # explicit list incl games
  ./build-rpi5-stage4.sh      --enable-games                       # default list + games subdomain
  ./build-rpi5-stage4.sh      --all-services                       # every user-level slug
  ./build-rpi5-stage4.sh      --optional-services all              # same thing, explicit sentinel
  ```

**FULL-SET sentinel.** `OPTIONAL_SERVICES=all` (and the equivalent `--all-services`
CLI flag) expands to **every user-level slug** (`akkoma tuwunel phpbb games owncast
tube`) right after arg parsing — before `EXCLUDE_SERVICES`, so the subtractive knob
still removes from it (e.g. `--all-services --exclude-services "games"` bakes
everything *except* games). A bare `all` anywhere in the list expands the whole token.

**`EXCLUDE_SERVICES` — the SUBTRACTIVE force-OFF knob.** Applied **last**, after
every positive source is resolved, it removes any user-level slug from the final
selection no matter how it became selected (default / `brand.conf` /
`--optional-services` / `all` / the games opt-in). It is the one-liner that turns OFF
an on-by-default service without re-enumerating the whole positive list; each excluded
slug is then pruned + rendered `installed:"false"` exactly like an unselected one.
**This knob (like the `all` sentinel) is wired in `build-rpi5-stage4.sh` only today;
the x86 builder does not yet honor it — see the rpi5-only caveat below.**
```sh
# brand.conf
EXCLUDE_SERVICES="phpbb tuwunel"        # forum-less + Matrix-less, keep the rest
# or the CLI flag (whitespace/comma separated):
./build-rpi5-stage4.sh --exclude-services "phpbb tuwunel"
./build-rpi5-stage4.sh --all-services --exclude-services "games"   # all-but-games
```
> Precedence summary: `OPTIONAL_SERVICES` (default `akkoma tuwunel phpbb`) is the
> positive allow-list (built-in < brand.conf < `--optional-services`; `all` expands
> to the full set), then the games opt-in folds `games` in, then **`EXCLUDE_SERVICES`
> subtracts last**.
>
> ⚠ **rpi5-only today.** The FULL-SET sentinel (`OPTIONAL_SERVICES=all` /
> `--all-services`) **and** the subtractive `EXCLUDE_SERVICES` / `--exclude-services`
> knob are wired in **`build-rpi5-stage4.sh`** (the canonical cluster-node builder)
> only. The x86 builder (`build-x86-host-stage4.sh`, a protected client-image area)
> currently supports just `--optional-services` + the `--enable-games` / `ENABLE_GAMES`
> opt-in (its `OPTIONAL_SERVICES` default is the fixed `akkoma tuwunel phpbb` list with
> no `all`-sentinel expansion and no exclude pass). Bringing the FULL-SET sentinel +
> the subtractive knob to x86 is an **owed follow-up** in that protected file.

`gate_optional_services()` (in **both** `build-x86-host-stage4.sh` and
`build-rpi5-stage4.sh`, authored per-script and anchored to the
`cp -r "${SHARED_SPECS}/cluster"` line) prunes, **for each unselected slug**:

- its owned `apps/*.yaml` (e.g. `30-akkoma.yaml`; phpbb also drops
  `38-forum-bff-db`/`39-forum-bff-api`/`49-forum-ui`; games also drops
  `06-casdoor-games.yaml`/`13c-games-instances.yaml`; **owncast → `52-owncast.yaml`;
  tube → `53-tube.yaml`**);
- its `manifests/<dir>` (games also drops `manifests/casdoor-games` +
  `manifests/games-instances`; **owncast → `manifests/owncast`; tube →
  `manifests/tube` + its standalone `tube-externalsecrets.yaml`**);
- its **per-service ESO file** (`akkoma-externalsecrets.yaml` /
  `tuwunel-externalsecrets.yaml`) **and** that line in the external-secrets
  `kustomization.yaml`;
- its gateway **host routes** in `apps/20-gateway-{be,fe}.yaml` (block-deleted by
  route id);
- its **route-access rows** in `manifests/route-access/initdb/20-schema.sql`
  (the trailing comma is repaired if the last `VALUES` row was removed);
- the shared `45-social-ui.yaml` only when **both** homeservers are deselected.

It then re-renders `manifests/policy/installed-services-configmap.yaml` to match
the surviving selection. ArgoCD's `recurse:true`+`prune:true` then never
instantiates a removed Application.

> ⚠️ **Runtime caveat:** build-time `rm -f` only stops the **one-time bootstrap
> seed**. The live cluster's ArgoCD root app syncs `apps/` from the **gitops
> repo**, not the baked copy, so on a cluster pointed at the upstream repo a
> pruned Application would be re-created. Build-time prune truly removes a
> workload only when the build targets a gitops repo/branch that **also** lacks
> it. For live add/remove use the runtime model in §7.

## 4. Worked example — build a USB without akkoma + phpBB

Goal: a Matrix + games appliance (no Mastodon, no forum), on **both** arches.

```sh
# x86 host (be+gpu)
sudo ./build-x86-host-stage4.sh --env prod --optional-services "tuwunel games"
# Pi5 backend
sudo ./build-rpi5-stage4.sh     --env prod --optional-services "tuwunel games"
```

Verify the baked tree (under `…/sysroot/var/lib/snapdragon/cluster`):

```sh
ls apps/ | grep -E '30-akkoma|30-phpbb|38-forum|39-forum|49-forum'   # -> empty (pruned)
ls apps/ | grep -E '30-tuwunel|50-games|06-casdoor-games'            # -> present
grep -c 'mastodon-' apps/20-gateway-be.yaml                          # -> 0
grep -c "'/_matrix"  manifests/route-access/initdb/20-schema.sql     # -> > 0 (Matrix kept)
grep -E '^  (akkoma|tuwunel|phpbb|games):' manifests/policy/installed-services-configmap.yaml
#   akkoma: "false"  tuwunel: "true"  phpbb: "false"  games: "true"
```

On the cluster, `argocd app list` shows no `akkoma`/`phpbb`/`forum-*` apps;
`recurse:true`+`prune:true` never instantiated them.

## 5. Games subdomain (opt-in; subdomain by default when enabled)

Games is **opt-in** (see §3 — off by default; enable with `--enable-games`).
**When games is enabled**, it normally lives at its own TLD, but **by default**
it is served as a **subdomain of the primary domain** — `games.<CLUSTER_DOMAIN>`
(e.g. `games.snapdragon.systems`) — until the real `.games` TLD is obtained. One
knob drives it (only consulted when games is selected):

```sh
GAMES_DOMAIN="games.${CLUSTER_DOMAIN}"   # brand.conf default
# or: ./build-*-stage4.sh --games-domain games.acme.example
```

`GAMES_DOMAIN` drives **every** games host, OIDC issuer, and redirect URI.
`parameterize_games_domain()` (both builders, run **before** `rebrand_sysroot`)
rewrites the **host** occurrences of `snapdragon.games` to `${GAMES_DOMAIN}` —
URL-scheme-anchored (only after `//`), so the games-realm
origin/issuer/redirect/website URLs flip while the canonical **image** repo paths
(`snapdragon.games-backend`) are left intact. The parameterized files:

- `manifests/casdoor-games/app-conf-configmap.yaml` — `origin` (the OIDC `iss`);
- `manifests/casdoor-games/init-data-configmap.yaml` — `redirectUris` +
  `websiteUrl`/`homepageUrl`;
- `manifests/casdoor-games/init-job.yaml` — `redirectUris` (`reconcile.py`
  **re-pins** these on every ArgoCD PostSync, so they must be parameterized);
- `manifests/games/deployment.yaml` — `CASDOOR_ISSUER_URI` (the games BFF
  enforces this as the expected `iss`).

Plus the games **public host**: a be-gateway host route `id: games`
(`games.<GAMES_DOMAIN>` → `snapdragon-games:8080`), its ingress `extraHosts`
entry, and the `/games/**` route-access floor — all added in
`apps/20-gateway-be.yaml` + `20-schema.sql`.

**Why this matters:** `rebrand_sysroot` rewrites `snapdragon.systems` and
`snapdragon-` but historically **left `.games` untouched**, so on the subdomain
default the public host became `games.<primary>` while Casdoor still minted
`iss=https://id.snapdragon.games` — the iss-strict `JwtIssuerValidator` then
rejected **every** games token and login broke. The parameterization fixes that.

Under the subdomain default, games **rides the existing `*.<primary>`
wildcard** (CoreDNS catch-all in test; cloudflared `*.snapdragon.systems` catch +
the existing wildcard cert in prod) — **no new DNS record or cert** is required.

## 6. Games TLD flip (later, when you own `.games`)

Set the knob to the real TLD and rebuild/re-seed:

```sh
GAMES_DOMAIN="snapdragon.games"     # or <brand>.games
```

Everything (issuer, redirects, website, the gateway host + extraHost) follows.
The **new infrastructure** required **only at the flip** (it leaves the
`*.<primary>` wildcard):

1. a real `<brand>.games` **DNS zone** + a `*.<brand>.games` wildcard record;
2. **cloudflared** hostname entries for `<brand>.games` + `id.<brand>.games`
   (before the `*.<primary>` wildcard);
3. **public TLS** for the new apex (the `*.<primary>` cert no longer covers it);
4. Casdoor `redirectUris` re-seed — automatic via the idempotent
   `casdoor-games` init-job on the next ArgoCD sync.

Internal mTLS / `svc.cluster.local` SANs are unaffected.

## 7. Runtime add/remove on a LIVE cluster

> **STATUS: build-time prune ✅ SHIPPED · build-time 13a render ✅ SHIPPED ·
> federation `OverrideService` + public `GET /api/federation/capabilities` ✅ SHIPPED ·
> host (snapdragon.systems) capabilities consumption + `menu.component` `enabled()`
> greying ✅ SHIPPED · live admin-driven flip 🚧 PENDING (the admin-bff
> `ApplicationSet` cut-over + `service_state` effector — the one remaining step).**
> The UI hide/show path is now LIVE end-to-end: the federation-api `OverrideService`
> kill-switch flips `federation_modules.enabled`/`circuit_state`, the public
> capabilities endpoint drives logged-out greying, and the host shell consumes that
> install-state to grey out nav + home cards. What remains is migrating *runtime
> ownership* of the surviving Applications to the ApplicationSet so an admin can flip
> a slug on a live cluster (the admin-bff `TasksController`/`ArgoController` +
> `service_state` reconcile + the cut-over in §10).
> The build now renders each slug's `installed` flag into BOTH the
> `installed-services` ConfigMap **and** the `apps/13a-optional-services.yaml`
> element (`_opt_render_appset_flag`), so the 13a generator selector agrees with the
> build-time selection: a deselected slug is pruned from the bootstrap `apps/` tree
> **and** dropped from the 13a list, so a repo-synced ArgoCD can never re-force a
> deselected service on — this is what "no hardcoded `30-*`/`50-*` app forces a
> service on" means in practice. The hardcoded `30-*`/`50-*`/`52-*`/`53-*`
> Applications remain the build-time *owners* of the surviving (selected) workloads;
> migrating *runtime ownership* to the ApplicationSet so an **admin can flip a slug on
> a live cluster** (delete the hardcoded apps, wire the admin-bff `TasksController` /
> `ArgoController` + a `service_state` reconcile) is the remaining cross-repo step
> (§10). The build-time *exclusion* requirement is fully satisfied today.

Because ArgoCD syncs from the repo (not the baked copy), live add/remove uses the
**runtime model**, not baked-file surgery:

- **`manifests/policy/installed-services` ConfigMap** — the per-slug install-state
  (`installed: "true|false"`), rendered from `optional-services.yaml` at build
  time. It is also the public-safe install-state the admin console + the host's
  greying-out predicate read.
- **`apps/13a-optional-services.yaml`** — a list-generator **ApplicationSet**
  (modelled on `apps/13-service-catalog.yaml`) whose `selector` keeps only
  `installed: "true"` elements. Flip a slug's flag (admin task / GitOps commit)
  and ArgoCD prune/creates that slug's Application — **one list, no baked-file
  surgery, no redeploy**.

  > **Cut-over:** while the hardcoded `apps/30-*`/`50-*` Applications still
  > exist, the ApplicationSet is scaffolded with every element `installed:
  > "false"` (it creates nothing) to avoid duplicate-named Applications. The
  > cut-over — delete the four hardcoded apps and let the ApplicationSet own them
  > (mirroring the ConfigMap into its `elements`) — is the follow-up that makes
  > runtime add/remove fully live.

- **UI hide/show** uses the federation-api `OverrideService` kill-switch
  (`/api/federation/overrides`, ROLE_ADMIN), which flips
  `federation_modules.enabled`/`circuit_state` so the module vanishes/reappears
  in the next manifest render with no redeploy.

These admin-bff `TasksController` / `ArgoController` seams + the `service_state`
reconcile bridge are **separate cross-repo waves** (see §10).

## 8. Graceful-degradation expectations

When a service is **absent**, a user sees:

- **Nav:** a **greyed-out, disabled nav button** (`aria-disabled`, roving-tabindex
  skip) instead of a dead link — the host menu's `enabled()` predicate reads
  install-state.
- **Home:** a **disabled service card with helptext** (data-driven home-services
  cards) instead of a broken tile.
- **No 502:** the gateway route to the absent upstream was **removed**, so there
  is no matched-but-dead route. (A leftover **route** → 502; a leftover **role
  row** → stale 403 — `gate_optional_services` removes **both**.)
- **Manifest:** the federation manifest simply **omits** the remote (empty
  `remotes:[]` is valid; the read path never hard-fails).

## 9. Consistency & gotchas

- **Dual authority** (ArgoCD presence vs `federation_modules` rows) is reconciled
  at **build** by rendering both from `optional-services.yaml`; at **runtime** by
  the `installed-services` ConfigMap + ApplicationSet (§7) plus the federation
  `OverrideService`. Build-time pruning alone leaves runtime toggles and GitOps
  presence able to drift — adopt the runtime model for live changes.
- **Shared ESO split (highest-risk coupling):** the former
  `homeserver-proxy-externalsecrets.yaml` coupled akkoma + tuwunel in one file,
  owned by the `external-secrets-config` Application (`apps/04`), **not** the
  per-homeserver `30-*` apps. It is now **split** into
  `akkoma-externalsecrets.yaml` + `tuwunel-externalsecrets.yaml` so removing one
  homeserver never orphans the other's mTLS-proxy + admin-token half.
- **CanonicalSeed.java floor (cross-repo):** the gateway image bakes a
  route-access floor in `CanonicalSeed.java` (**snapdragon-gateway** repo) used as
  the in-memory fallback when Postgres/Cassandra are unreachable. It must match
  the route-access rows pruned here, or the in-image snapshot re-enforces removed
  rows on datastore fallback. The games host floor is now **baked in
  `CanonicalSeed.java`** (✅ shipped, §10); it cannot be GitOps-pruned, so any future
  route-access change still needs a matching gateway image rebuild.
- **cloudflared reserved hostnames (cross-repo / prod):** prod cloudflared
  hardcodes `matrix.`/`mastodon.` reserved hostnames before the `*.<primary>`
  wildcard; a games TLD flip also needs a games hostname entry there.

## 10. Cross-repo: shipped work + the one remaining TODO

**✅ SHIPPED (cross-repo waves now landed):**

- **snapdragon-federation-api ✅:** the idempotent changesets
  `023-register-akkoma-module.xml` / `024-register-tuwunel-module.xml` /
  `025-register-games-module.xml` (mirroring `022-register-forum-module.xml`) are in,
  and the **public** `GET /api/federation/capabilities` projection now drives
  logged-out greying (the `…/manifest` endpoint stays `authenticated()` +
  visibility-filtered).
- **snapdragon-gateway ✅:** `CanonicalSeed.java`'s baked route-access floor now
  carries the `games.<GAMES_DOMAIN>` host floor in sync with the rows
  `gate_optional_services` prunes.
- **snapdragon.systems (host) ✅:** the host shell consumes install-state at
  bootstrap (HttpClient → the public capabilities endpoint) and `menu.component`'s
  `enabled()` greys out absent services (nav + data-driven home-services cards).

**🚧 REMAINING TODO (the only open cross-repo step):**

- **snapdragon-admin-bff-api:** implement the `TasksController` /
  `ArgoController` seams + a `service_state` desired-state table + leader-gated
  reconcile effector (reuse the SuspensionService/DomainLockService pattern) for
  live add/remove; complete the ApplicationSet cut-over (§7) — delete the four
  hardcoded `30-*`/`50-*` Applications and let the ApplicationSet own the surviving
  workloads so an admin can flip a slug on a live cluster.

## 11. Verification & rollback

**Verify a build:**
```sh
TREE=…/sysroot/var/lib/snapdragon/cluster
ls "$TREE/apps/"                                           # pruned apps gone
grep -E '^  (akkoma|tuwunel|phpbb|games):' "$TREE/manifests/policy/installed-services-configmap.yaml"
bash scripts/validate-reserved-prefixes.sh                # games host/extraHost reserved + consistent
bash scripts/validate-prod-hygiene.sh --static "$TREE"    # ENV=prod baked tree (no :dev / test harness)
```

**Verify on a live cluster:**
```sh
argocd app list | grep -E 'akkoma|tuwunel|phpbb|forum|games'   # only the installed ones
curl -fsS https://games.<GAMES_DOMAIN>/                        # games host resolves (no 502)
# a games login round-trip succeeds (iss matches GAMES_DOMAIN)
```

**Rollback** (re-add a service): set `OPTIONAL_SERVICES` to include the slug (or
flip its `installed` flag in the ConfigMap / ApplicationSet element) and rebuild
or re-sync. Because every change is derived from `optional-services.yaml`, the
re-add restores the apps + gateway routes + route-access rows + ESO half together.
