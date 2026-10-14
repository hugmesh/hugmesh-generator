# Optional Services — add/remove by command (akkoma · tuwunel · phpBB · games · owncast · tube · character-studio · character-forge)

## 1. Purpose & scope

The platform has two tiers:

- **Architecture (core, always present):** the gateways (pki/be/fe), Casdoor/PKI, the
  federation API, remote-fragment and host shell, and the admin, user and mod BFFs and
  UIs.
- **Optional services (this page):**
  - **akkoma** (Mastodon-API fediverse server), **tuwunel** (Matrix homeserver) and
    **phpbb** (forum).
  - **games** (the hugmesh.games portal and its own games-realm Casdoor).
  - **owncast** (HLS live-streaming) and **tube** (LocalTube YouTube archive), both
    GPU-gated x86.
  - **edge-ai** (a GPU inference node serving an OpenAI-compatible model API to the
    mesh; DEFAULT-OFF, GPU-gated, auto-selected by the `edge-ai` node role; see
    [EDGE-AI.md](EDGE-AI.md)).
  - **character-studio** (the VN character-studio frontend remote: character creator and
    chat surface at `/character-studio`, ROLE_USER; DEFAULT-OFF, admin gate).
  - **character-forge** (the 3D character maker and XR-chat avatar source: a MULTI-APP
    slug shaped like phpbb, with a BFF db, a BFF api at `/bff/character-forge/**` and a
    frontend remote at `/character-forge`, ROLE_USER; DEFAULT-OFF, admin gate; see
    [XR-CHAT.md](XR-CHAT.md)).
  - The non-user-level optional slugs **egress-vpn**, **tor**, **workloadConsole**,
    **anubis**, **coturn** and **meshbridge**, gated by the same registry.

  **tor** (Tor v3 onion hidden service, DEFAULT-OFF) is node-scoped like egress-vpn
  (`scope: node`). Add it with `--with-tor` (x86/Studio/build-menu) or by listing `tor`
  in `OPTIONAL_SERVICES` (rpi5/brand.conf). Exclude it with `--exclude-services tor`. It
  owns **nodePackages: [net-vpn/tor]** and **nodeServices: [tor, hugmesh-tor-reconcile]**
  (the distro Tor daemon plus a reconcile agent) and exposes the in-cluster fe-gateway as
  a v3 `.onion`: INBOUND reach with no public IP and no DDNS. The v3 onion keypair is
  minted and persisted OFF-GIT under `/var/lib/tor/hugmesh-onion` on first boot. When tor
  is not selected, net-vpn/tor is omitted and the services are unlinked. See
  [TOR-HIDDEN-SERVICE.md](TOR-HIDDEN-SERVICE.md).

  **coturn** (TURN/STUN relay for Matrix WebRTC audio and video) is a DEFAULT-OFF,
  **runtime-only** slug (the anubis pattern: `apps: []`, no baked Application). It lands
  in `hugmesh-backend` next to tuwunel so they share one TURN secret. When off, Matrix
  calls keep host-only ICE (`iceServers: []`), byte-identical to mainline. See
  [`docs/COTURN.md`](COTURN.md).

  **meshbridge** (Meshtastic LoRa mesh ↔ Matrix bridge) is a DEFAULT-OFF, **runtime-only**
  slug (the coturn pattern: `apps: []`, no baked Application) in `hugmesh-backend` next to
  tuwunel. It is a Matrix APPSERVICE (exclusive `@mesh-.*` user namespace, registered by a
  PostSync Job through the tuwunel admin room) that speaks the in-namespace CS API. Radios
  attach by USB-serial, LoRa-WiFi TCP (:4403) or a Meshtastic MQTT-JSON broker. It has
  `dependsOn: tuwunel` (declared in the installed-services `services.json`, like coturn),
  so the console greys it while the homeserver is off. When off, nothing references it,
  byte-identical to mainline. See [`docs/MESHTASTIC-BRIDGE.md`](MESHTASTIC-BRIDGE.md).

**Registry census.** `specs/cluster/optional-services.yaml` lists 25 slugs:

| Group | Slugs | Default |
|---|---|---|
| user-level, build-time gate | `akkoma`, `tuwunel`, `phpbb` | on |
| user-level, build-time gate | `games`, `owncast`, `tube`, `character-studio`, `character-forge` | off |
| infra, build-time gate | `edge-ai`, `edge-ai-analysis`, `edge-ai-tts`, `workloadConsole`, `headwind`, `attestation-server` | off |
| infra, node-scoped | `egress-vpn`, `tor` | off |
| infra, runtime gate | `coturn`, `meshbridge` (no build gate), `anubis` | off |
| infra, no gate (always deployed) | `metrics-server`, `keda`, `kyverno`, `service-catalog-builder`, `optional-services-operator` (on); `observability` (off) | as listed |

`all` expands to the eight user-level slugs only. Every infra slug is named on its own.

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
| `slug` | one of the 25 slugs in the census above |
| `namespace` | the k8s namespace it lands in |
| `apps` | the ArgoCD Application YAMLs it **owns** (pruned on removal) |
| `sharedApps` | apps shared with another slug (e.g. `45-social-ui.yaml`); pruned only when **all** owners are deselected |
| `manifestPath` / `extraManifestPaths` | its `manifests/<dir>` (pruned on removal) |
| `esoFile` | its **per-service** ExternalSecret file (post-split; see §9) |
| `gatewayHost` / `gatewayRouteIds` | its public host + the gateway route ids to drop |
| `routeAccessRows` | the `gateway_route_access` rows it owns (dropped so a matched route to a deleted upstream cannot 502 / stale-grant) |
| `federationModule` | the `federation_modules` registration (federation-api wave). **Its `slug` is the MODULE slug, which is not always the catalogue slug on the left** — `phpbb`'s module is `forum`, `akkoma`'s is `mastodon`, `tuwunel`'s is `matrix`. The module slug is what the host shell resolves the remote by at runtime and what `tests/stack/seed-e2e.sh` leg 4 UPDATEs, so the changeset's `<column name="slug">` is authoritative and this field mirrors it. `changeset` names the file in `hugmesh-federation-api` that seeds the row; if it has not landed yet the number must still be FREE there. Both facts are re-derived and compared every run by `scripts/validate-federation-module-slugs.sh` (CI job `lint:federation-module-slugs`) |
| `casdoorSeed` | a dedicated Casdoor it owns (games → `casdoor-games`) |
| `deliveryManifestPath` / `deliveryApp` | (node slugs) a SECOND, dark manifest tree + its MANUAL-sync Application that delivers runtime bytes to the node — `egress-vpn` uses it for the secret-projector (`manifests/egress-vpn` + `apps/13e-egress-vpn.yaml`); pruned with the slug like `manifestPath` |
| `secretContract` | (node slugs) the file that OWNS the cross-lane delivery contract. When present, the three fields below are **copies** of it and lose every argument to it |
| `secretNamespace` / `secretLabel` / `secretKey` / `nodeDeliveryLabel` | (node slugs) the cross-lane delivery contract the control-plane/ESO half must satisfy, and the node label that arms the projector — see `docs/EGRESS-VPN.md`. For `egress-vpn` these are COPIES of `specs/cluster/egress-vpn-secret-contract.env` (the contract spans two repos that never build together) and are asserted against it by `tests/egress-vpn/test-secret-contract.sh`; that gate's copy census also fails on any NEW carrier of those values that nothing asserts. `secretKey` shipped as `config` here — unread, unasserted, and wrong — until that census existed. Note the value must stay quoted: `@` cannot start a plain YAML scalar |
| `default` | `akkoma`/`tuwunel`/`phpbb` → `on`; **`games`/`owncast`/`tube`/`character-studio`/`character-forge` → `off` (opt-in; owncast/tube are GPU-gated x86; character-studio is an admin-gated frontend remote; character-forge is an admin-gated multi-app slug — BFF db + BFF api + UI remote)** |

There is also a `gamesDomain` block (the `GAMES_DOMAIN` knob + the
parameterized files) — see §5.

**Rule:** edit `optional-services.yaml`, the generator derives the build-time
prune, the runtime `installed-services` ConfigMap, and (in the federation wave)
the `federation_modules` seed.

## 3.1 Build-time: the `federation_modules` half (menu visibility)

**What was observed (2026-08-26).** A USB built with `--exclude-services akkoma` pruned
akkoma's Application, manifests, gateway routes and route-access rows, and rendered
`installed: "false"` into **both** the installed-services ConfigMap and the
`apps/13a-optional-services.yaml` element. The host shell **still** drew the Mastodon
menu entry and reported `installed=true`.

**Why.** The host shell takes its install-state from the public
`GET /api/federation/capabilities` projection (§10). That projection is built from
`federation_modules` rows, not from the ConfigMap. Every registration is an
**unconditional** Liquibase changeset that seeds `enabled = true`, so the build-time
selection had no say. The `federationModule` field that names each service's module slug
sat in `optional-services.yaml` and **nothing read it**.

**The fix is a post-seed UPDATE, not a changeset.** The registration changesets
(`022`/`023`/`024`/`025`/`031`/`033` and the `character-*` ones) live in the **separate
`hugmesh-federation-api` repo**. The generator cannot add one, and editing an **applied**
changeset breaks Liquibase's checksum on every existing mesh. So the generator renders a
post-seed UPDATE into the GitOps tree it does own:

* `manifests/federation-modules-gate/sql/gate.sql` — one
  `UPDATE federation_modules SET enabled = <bool> WHERE slug = '<module>';` per gated
  module, rewritten by `_opt_render_federation_modules()` from the resolved
  `OPTIONAL_SERVICES`. Committed values are the registry's `default: on|off` baseline, so
  an unrendered tree still says something true.
* `manifests/federation-modules-gate/job.yaml` — an ArgoCD `PostSync` hook Job
  (`hook-delete-policy: BeforeHookCreation`, so a re-rendered gate.sql is applied) that
  runs `psql` as the least-privilege `federation_app` role.
* `apps/29b-federation-modules-gate.yaml` — sync-wave `"3"`, after federation-db (wave 1)
  and hugmesh-federation-api (wave 2, which runs the changelog at boot). Waves cannot
  wait on another pod's startup work, so the SQL `RAISE`s while the table is absent and
  the Job's `backoffLimit` retries.

The local-mesh lane uses the same shape: leg 4 of `tests/stack/seed-e2e.sh` UPDATEs these
rows from the Studio's `HUGMESH_FEDERATION_ENABLE` / `_DISABLE` pair.

> ⚠ **THE BUILD-TIME RENDER IS INERT ON A DEVICE TODAY.** It lands the mechanism and the
> guard, not the fixed behaviour.
>
> `bootstrap.sh` now applies **every baked `apps/*.yaml`** directly, including
> `apps/29b-federation-modules-gate.yaml`. But `apply_baked_app()` rewrites `repoURL` and
> `targetRevision` and **nothing else**.
> `source.path: specs/cluster/manifests/federation-modules-gate` is untouched, so ArgoCD's repo-server
> still clones a **git repo** and kustomize-generates the ConfigMap from the **committed**
> `gate.sql`, never from the USB's rendered copy. A USB built with
> `--exclude-services akkoma` bakes `enabled = false` into
> `${SYSROOT}/var/lib/hugmesh/cluster/...` and the cluster still applies `enabled = true`.
> **The observed bug is not fixed on a device**, UI half included. Closing it needs a
> **pruned source** for `manifests/`, which the keystone deliberately did not attempt
> (see `specs/cluster/README.md`, "What the device syncs"). Leg 4c of the gate suite
> asserts this **both ways**. It asks whether the bootstrap rewrites `path:`/`source:` at
> all, so the sentence cannot quietly become false in either direction.
>
> ⚠ **And even then: UI half only.** Flipping `enabled` hides the **menu entry**. The
> deselected service's Deployment keeps running. The workload half needs the device to
> sync from a **pruned** tree. The *Application set* is pruned now, but each surviving
> Application still pulls `specs/cluster/manifests/<dir>` from the git repo. A green gate
> Job does not mean "only selected services start".

Gate: `tests/federation/test-federation-modules-selection.sh` (sources the real
renderer as **both** stage4 builders resolve it (one shared library, no per-builder copy); asserts post-conditions on the rendered
`gate.sql`, never the renderer's exit code; behavioural legs against a live
federation-db/capabilities endpoint skip **loudly** when no stack is up).

## 3. Build-time: select services on a USB

### Default-inclusion policy (user 2026-06-17)

| Tier | Slugs | When baked |
|---|---|---|
| **DEFAULT-ON** (the built-in default when no selection is given) | `akkoma`, `tuwunel` (Matrix), `phpbb` | always, unless `EXCLUDE_SERVICES` removes them |
| **DEFAULT-OFF** (must be specifically added) | `games`, `owncast`, `tube`, `character-studio`, `character-forge` — and any future user-level service | only when explicitly selected |
| **FULL-SET** | `OPTIONAL_SERVICES=all` / `--all-services` | every user-level slug — rpi5 **and** x86 builders |

> ⚠ **`games` is DEFAULT-OFF** (it was default-on before). Add it with `--enable-games` /
> `ENABLE_GAMES=true`, by naming `games` in `OPTIONAL_SERVICES`, or through the full set.
> `owncast` and `tube` are GPU-gated x86 services, also off by default.
> `character-studio` is an admin-gated frontend remote, off by default. Add it with
> `--with-character-studio`, by naming it in `OPTIONAL_SERVICES`, or through the full set.
> `character-forge` (the 3D character maker and XR-chat avatar source; a phpbb-shaped
> multi-app slug with a BFF db, a BFF api and a UI remote) is also off by default. Add it
> with `--with-character-forge`, by naming it in `OPTIONAL_SERVICES`, or through the full
> set. See [XR-CHAT.md](XR-CHAT.md).

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

**FULL-SET sentinel.** `OPTIONAL_SERVICES=all` (or `--all-services`) expands to **every
user-level slug** (`akkoma tuwunel phpbb games owncast tube character-studio
character-forge`) right after arg parsing, before `EXCLUDE_SERVICES`. The subtractive
knob still removes from it: `--all-services --exclude-services "games"` bakes everything
*except* games. A bare `all` anywhere in the list expands the whole token.

**`EXCLUDE_SERVICES` — the SUBTRACTIVE force-OFF knob.** It runs **last**, after every
positive source is resolved, and removes any user-level slug from the final selection
however that slug got selected (default, `brand.conf`, `--optional-services`, `all`, the
games opt-in). Use it to turn OFF an on-by-default service without listing the whole
positive set. Each excluded slug is pruned and rendered `installed:"false"` like any
unselected one.
```sh
# brand.conf
EXCLUDE_SERVICES="phpbb tuwunel"        # forum-less + Matrix-less, keep the rest
# or the CLI flag (whitespace/comma separated):
./build-rpi5-stage4.sh --exclude-services "phpbb tuwunel"
./build-rpi5-stage4.sh --all-services --exclude-services "games"   # all-but-games
```
> **Resolution order, both builders.** `build-rpi5-stage4.sh` and
> `build-x86-host-stage4.sh` resolve the selection the same way: the built-in default
> (respecting env and `brand.conf`) < `--optional-services` < `all` expansion < the opt-in
> folds < `EXCLUDE_SERVICES` subtracts last. The opt-in folds are games everywhere; on
> x86 also edge-ai, tor, character-studio, character-forge, edge-ai-analysis and
> edge-ai-tts. On x86 the subtraction runs after **every** fold, so an excluded slug is
> force-OFF there however it was selected.
> `edge-ai-tts` (Piper TTS + viseme timeline, VN voice) is CPU-only and has NO `edge-ai`
> dependency. Unlike `edge-ai-analysis`, its opt-in fold is wired in **both** builders;
> see [EDGE-AI.md](EDGE-AI.md#4c-voice-synthesis--tts-api-for-the-mesh-edge-ai-tts).

`gate_optional_services()` lives in one shared library,
`scripts/_optional-services-lib.sh`, sourced by both `build-x86-host-stage4.sh` and
`build-rpi5-stage4.sh` (each builder used to carry its own copy; the copies had
drifted). It prunes, **for each unselected slug**:

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
the surviving selection.

`specs/cluster/bootstrap/bootstrap.sh` applies the **baked** `apps/` tree one file at a
time. A pruned Application is never instantiated, and the *in-file* edits above (dropped
gateway routes and extraHosts) are the bytes that reach the cluster.

> ⚠️ **This was NOT true before 2026-08-26.** `bootstrap.sh` applied one Application,
> `app-of-apps.yaml`, whose source is `path: specs/cluster/apps` +
> `directory.recurse: true` against the **GitOps repo**, and nothing read the baked tree. The build-time
> prune was **inert**: a device built with `--optional-services akkoma` received tuwunel,
> phpbb, games, owncast and tube from `main` anyway. `tests/cluster/test-bootstrap-applies-baked-apps.sh`
> guards this now.

> ⚠️ **What the prune still does NOT cover.** Each surviving Application fetches its own
> `specs/cluster/manifests/<dir>` from the **git repo**. A baked edit *under*
> `manifests/` (the installed-services ConfigMap, `seed-optionalservices.yaml`, the
> route-access SQL) does not reach the cluster. Closing that needs a pruned *source*, not
> another apply; see `specs/cluster/README.md`, "What the device syncs". For live
> add/remove, use the runtime model in §7.

> ⚠️ **`HUGMESH_GITOPS_ROOT_RECURSE=1`** restores the old repo-recursing root, for a
> cluster that deliberately tracks a git branch. It re-creates every pruned Application
> from the repo, so the build-time selection is ignored, loudly.

## 4. Worked example — build a USB without akkoma + phpBB

Goal: a Matrix + games appliance (no Mastodon, no forum), on **both** arches.

```sh
# x86 host (backend-gpu)
sudo ./build-x86-host-stage4.sh --env prod --optional-services "tuwunel games"
# Pi5 backend
sudo ./build-rpi5-stage4.sh     --env prod --optional-services "tuwunel games"
```

Verify the baked tree (under `…/sysroot/var/lib/hugmesh/cluster`):

```sh
ls apps/ | grep -E '30-akkoma|30-phpbb|38-forum|39-forum|49-forum'   # -> empty (pruned)
ls apps/ | grep -E '30-tuwunel|50-games|06-casdoor-games'            # -> present
grep -c 'mastodon-' apps/20-gateway-be.yaml                          # -> 0
grep -c "'/_matrix"  manifests/route-access/initdb/20-schema.sql     # -> > 0 (Matrix kept)
grep -E '^  (akkoma|tuwunel|phpbb|games):' manifests/policy/installed-services-configmap.yaml
#   akkoma: "false"  tuwunel: "true"  phpbb: "false"  games: "true"
```

On the cluster, `argocd app list` shows no `akkoma`/`phpbb`/`forum-*` apps:
`bootstrap.sh` applied only the Application files that survived the prune, so
those were never created (not created-then-pruned).

## 5. Games subdomain (opt-in; subdomain by default when enabled)

Games is **opt-in** (see §3 — off by default; enable with `--enable-games`).
**When games is enabled**, it normally lives at its own TLD, but **by default**
it is served as a **subdomain of the primary domain** — `games.<CLUSTER_DOMAIN>`
(e.g. `games.hugmesh.net`) — until the real `.games` TLD is obtained. One
knob drives it (only consulted when games is selected):

```sh
GAMES_DOMAIN="games.${CLUSTER_DOMAIN}"   # brand.conf default
# or: ./build-*-stage4.sh --games-domain games.acme.example
```

`GAMES_DOMAIN` drives **every** games host, OIDC issuer, and redirect URI.
`parameterize_games_domain()` (both builders, run **before** `rebrand_sysroot`)
rewrites the **host** occurrences of `hugmesh.games` to `${GAMES_DOMAIN}` —
URL-scheme-anchored (only after `//`), so the games-realm
origin/issuer/redirect/website URLs flip while the canonical **image** repo paths
(`hugmesh.games-backend`) are left intact. The parameterized files:

- `manifests/casdoor-games/app-conf-configmap.yaml` — `origin` (the OIDC `iss`);
- `manifests/casdoor-games/init-data-configmap.yaml` — `redirectUris` +
  `websiteUrl`/`homepageUrl`;
- `manifests/casdoor-games/init-job.yaml` — `redirectUris` (`reconcile.py`
  **re-pins** these on every ArgoCD PostSync, so they must be parameterized);
- `manifests/games/deployment.yaml` — `CASDOOR_ISSUER_URI` (the games BFF
  enforces this as the expected `iss`).

Plus the games **public host**: a be-gateway host route `id: games`
(`games.<GAMES_DOMAIN>` → `hugmesh-games:8080`), its ingress `extraHosts`
entry, and the `/games/**` route-access floor — all added in
`apps/20-gateway-be.yaml` + `20-schema.sql`.

**Why this matters:** `rebrand_sysroot` rewrites `hugmesh.net` and
`hugmesh-` but historically **left `.games` untouched**, so on the subdomain
default the public host became `games.<primary>` while Casdoor still minted
`iss=https://id.hugmesh.games` — the iss-strict `JwtIssuerValidator` then
rejected **every** games token and login broke. The parameterization fixes that.

Under the subdomain default, games **rides the existing `*.<primary>`
wildcard** (CoreDNS catch-all in test; cloudflared `*.hugmesh.net` catch +
the existing wildcard cert in prod) — **no new DNS record or cert** is required.

## 6. Games TLD flip (later, when you own `.games`)

Set the knob to the real TLD and rebuild/re-seed:

```sh
GAMES_DOMAIN="hugmesh.games"     # or <brand>.games
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

> **Status**
>
> * **Build-time prune: shipped, and governing a device.** `bootstrap.sh` applies the
>   baked `apps/` tree. Before 2026-08-26 it applied the repo-recursing root and the
>   prune was inert.
> * **Build-time 13a render: shipped, held at `installed:"false"`** for any slug whose
>   hardcoded `apps/30-*`/`50-*` Application still exists. Flipping it would manage one
>   manifest dir twice (§10). `_opt_appset_cutover_done()` in
>   `scripts/_optional-services-lib.sh` is the guard and lifts itself at cut-over.
> * **UI hide/show: shipped end to end.** The federation `OverrideService` kill-switch
>   flips `federation_modules.enabled`/`circuit_state`, the public
>   `GET /api/federation/capabilities` drives logged-out greying, and the host shell
>   greys nav and home cards from that install-state.
> * **Live admin-driven flip: code-complete, ships dark.** The `OptionalService` CRD and
>   controller (§7.1); the reconciler setting `app.optional-services.reconcile.enabled`
>   is `false` by default.
> * **Hardcoded-app cut-over: blocked on a live cluster** (§10).
>
> The build renders each slug's `installed` flag into BOTH the `installed-services`
> ConfigMap **and** the `apps/13a-optional-services.yaml` element
> (`_opt_render_appset_flag`). A deselected slug is pruned from the bootstrap `apps/`
> tree **and** dropped from the 13a list, so a repo-synced ArgoCD cannot re-force it on.
> That is what "no hardcoded `30-*`/`50-*` app forces a service on" means in practice.
> The hardcoded `30-*`/`50-*`/`52-*`/`53-*` Applications stay the build-time *owners* of
> the surviving workloads. Moving *runtime ownership* to the ApplicationSet, so an admin
> can flip a slug on a live cluster, means moving each slug's ownership to the
> ApplicationSet (not simply deleting the hardcoded apps: §10.3 derives why) and enabling
> the §7.1 reconciler. That is the remaining cross-repo step (§10). The build-time
> *exclusion* requirement is fully met today.

ArgoCD syncs from the repo, not the baked copy, so live add/remove uses the **runtime
model**, not baked-file surgery:

- **`manifests/policy/installed-services` ConfigMap** — the per-slug install-state
  (`installed: "true|false"`), rendered from `optional-services.yaml` at build time. It is
  a write-only record: nothing reads it (§10.2). The user-facing greying comes from
  `federation_modules`.
- **`apps/13a-optional-services.yaml`** — a list-generator **ApplicationSet** (modelled on
  `apps/13-service-catalog.yaml`) whose `selector` keeps only `installed: "true"`
  elements. Flip a slug's flag (admin task or GitOps commit) and ArgoCD creates or prunes
  that slug's Application: **one list, no baked-file surgery, no redeploy**.

  > **Cut-over:** while the hardcoded `apps/30-*`/`50-*` Applications exist, the
  > ApplicationSet ships with every element `installed: "false"`, so it creates nothing and
  > cannot duplicate an Application name. The cut-over hands each slug's directory from its
  > hardcoded owner to the ApplicationSet (mirroring the ConfigMap into its `elements`),
  > and it is not a plain delete: one element covers one directory, the generated name
  > differs, and neither side carries a finalizer. §10.3 derives the per-slug matrix and the
  > order for a running cluster. That step makes runtime add/remove fully live.

- **UI hide/show** uses the federation-api `OverrideService` kill-switch
  (`/api/federation/overrides`, ROLE_ADMIN). It flips
  `federation_modules.enabled`/`circuit_state`, so the module disappears from or returns
  to the next manifest render with no redeploy.

The admin-bff seams and the CRD reconcile bridge are in §7.1 and §10.

## 7.1. The `OptionalService` CRD + controller (the live-flip mechanism)

The runtime desired-state object is a **CRD** (`optionalservices.platform.hugmesh.net`,
the platform's first CRD: `kind: OptionalService`, `shortName: optsvc`, namespaced in
`devops`). A **Lease-gated single-writer controller** in `hugmesh-admin-bff-api`
(`net.hugmesh.adminbff.optionalservices.OptionalServiceReconciler`, cloned from the
`NodeStorageReconciler` / `Fabric8NodeStorageConfigMapWriter` precedent) reconciles it.
The user chose a CRD over a watched ConfigMap or a git-committing reconciler: no DB
migration, `kubectl`-native, directly admin-mutatable. It **replaces** the earlier
proposed `service_state` Postgres table.

**Mechanism (Option A — single-writer feeds the ApplicationSet's element list):**

1. An admin/superadmin (or a GitOps commit) sets `spec.enabled` on one
   `OptionalService` — e.g.
   `kubectl -n devops patch optionalservice akkoma --type merge -p '{"spec":{"enabled":true}}'`.
2. The reconciler reads all CRs, then is the **sole writer** of two targets, both
   pure functions of the CR desired-state:
   - **`apps/13a-optional-services.yaml`** — a read-modify-write that flips
     `installed` on the matching inline list-generator **element** (by `slug`); the
     ArgoCD ApplicationSet controller then creates/prunes `optional-<slug>` via the
     `installed:"true"` selector.
   - **`installed-services` ConfigMap** (`hugmesh-policy`) — a targeted merge-patch of
     the matching boolean. Nothing reads that ConfigMap today (§10.2).
3. Each CR's `/status` (`phase`, `installed`, `observedGeneration`, `conditions`) is
   updated so `kubectl get optsvc` shows the effective state.

**Closed slug set (verified against `optional-services.yaml` + the ConfigMap + 13a):**
the CRD enum is the **14 cluster-service slugs** — `akkoma tuwunel phpbb games owncast
tube character-studio character-forge anubis coturn meshbridge edge-ai edge-ai-analysis edge-ai-tts`.
Deliberately EXCLUDED: `workloadConsole`, `headwind` and `attestation-server` (each has a
ConfigMap boolean but no 13a element; admin-bff's registry refuses them as
`NO_APPLICATIONSET_ELEMENT`; `workloadConsole`'s RBAC is the hardcoded
`apps/14-workload-console-rbac.yaml`, left build-determined) and the NODE services
`egress-vpn`/`tor` (no cluster Application, no ConfigMap boolean — a separate
node-reconcile track).

**⚠ The `ignoreDifferences` KEYSTONE (the piece the whole mechanism hinges on).**
ArgoCD's automated recurse roots (`app-of-apps.yaml` + `apps/00-app-of-apps-waved.
yaml`, `selfHeal:true`) and the policy app (`apps/16`) would REVERT any live element /
ConfigMap write back to git's inert baseline. So:

> **Since 2026-08-26 neither root is applied by default** — `bootstrap.sh` applies
> the baked `apps/` tree directly — so on a device the 13a half of this is **moot
> rather than load-bearing**: nothing selfHeals `apps/13a-optional-services.yaml`.
> The `ignoreDifferences` below are KEPT, unchanged: they are still required for a
> cluster run under `HUGMESH_GITOPS_ROOT_RECURSE=1` or pointed at the waved root,
> and removing them would silently re-arm the revert for exactly those clusters.
> The `apps/16` ConfigMap clause is **unaffected** and still load-bearing — the
> policy app is applied from the baked tree like every other child and keeps its
> own `selfHeal`.

- both roots carry `ignoreDifferences` on `argoproj.io ApplicationSet
  optional-services` `jsonPointers:[/spec/generators/0/list/elements]` **+
  `RespectIgnoreDifferences=true`**;
- `apps/16` carries `ignoreDifferences` on the `installed-services` ConfigMap's 14
  controller-owned `/data/<slug>` keys **+ `RespectIgnoreDifferences=true`**;
- `apps/13d-optional-services-operator.yaml` (which deploys the CRD + RBAC + seed CRs)
  carries `ignoreDifferences` on `OptionalService` `/spec/enabled` (+ `reason`,
  `requestedBy`) so an admin's toggle is not selfHeal-reverted.

Git holds the inert baseline; the controller-owned fields are allowed to diverge;
every OTHER field stays fully selfHeal-enforced. Without this keystone the controller
writes and ArgoCD immediately reverts — a no-op.

**SHIPS DARK.** The reconciler defaults `app.optional-services.reconcile.enabled=false`
(Noop client + Noop writers), so nothing is written until a live cluster deliberately
enables it. The stage4 builders seed each per-slug CR's `enabled` from the resolved
`OPTIONAL_SERVICES` (`_opt_render_optionalservice_cr`, alongside
`_opt_render_installed_services`). **Enabling the reconciler requires the §10
cut-over first** — otherwise flipping `akkoma`/etc. to `installed:"true"` makes the
ApplicationSet create `optional-akkoma` that double-manages the same manifests as the
still-present hardcoded `apps/30-akkoma.yaml` (Application `akkoma`).

## 7.2. Workload Console (`workloadConsole`): the three OFFs & the flip order

> **Trying to see stats, or which versions are running?** The three OFFs below are
> **four gates** in practice — the DB master flag and the per-admin grant are separate
> rows in separate tables with separate lifetimes, and flipping only the flag shows an
> operator exactly as much as flipping nothing. Run
> `scripts/workload-console-posture.sh` to see which of the four are open, and read
> [`WORKLOAD-CONSOLE-STATS-AND-VERSIONS.md`](WORKLOAD-CONSOLE-STATS-AND-VERSIONS.md)
> for why the version question has no usable answer today (31 of 31 first-party image
> refs are the moving tag `:main`; the resolved digest is dropped by the projection).

The Workload Console (the `/bff/{admin,superadmin}/workloads/**` pod console inside
the always-present admin-bff) **ships dark behind three INDEPENDENT OFFs**. Each one
alone keeps the console unusable; lighting it is a deliberate, ordered act:

| # | OFF | Owner | Dark behaviour |
|---|-----|-------|----------------|
| 1 | **Generator gate** — `WORKLOAD_CONSOLE_ENABLED=false` (the `app.workload-console.enabled` default) *and* the two `hugmesh-be-gateway` route-access rows pruned | build-time (`workloadConsole` slug) | the BFF's `WorkloadAuthorizationFilter` **404s** the disabled prefix — in-cluster calls included, so there is no gateway-only bypass. Note the pruned rows are **not** what refuses it: a path with no matching `url_pattern` is `NO_RULE` and the gateway filter **forwards** it (see [`ROUTE-ACCESS.md`](ROUTE-ACCESS.md) — *"'No matching row' is NOT a denial. Three verdicts, not two."*). Pruning them **ungoverns** the prefix; the app-side gate is the authority. Which gateway's rows those are matters — see the blockquote below |
| 2 | **k8s seam** — `WORKLOAD_CONSOLE_K8S_ENABLED=false`, no SA tokens mounted | build-time (same slug) | the fail-closed `NoopWorkloadClient` **503s every call**; no k8s API is ever dialed |
| 3 | **DB master flag + TTL'd grants** — `workload_console_config.admin_enabled` / `dangerous_tier_enabled` default false; every admin needs an active grant lease (~24 h TTL, expiry-swept) | runtime (SUPERADMIN + step-up) | a fully lit-wired cluster still shows **nobody anything** |

> **Why OFF #1 does not say "the gateway 404s the whole prefix".** The two route-access
> rows the slug prunes are on **`hugmesh-be-gateway`**, which declares **no `/bff` route
> at all** (`apps/20-gateway-be.yaml`). Pruning them never changed a gateway decision for
> a browser. A browser hits `hugmesh-fe-gateway`, and there:
>
> * `/bff/admin/workloads/**` has **always** matched the pre-existing
>   `'/bff/admin/**' -> ROLE_ADMIN` floor, deselected or not.
> * `/bff/superadmin/workloads/**` matches the `'/bff/superadmin/**' -> ROLE_SUPERADMIN`
>   floor. Without it, every shipped superadmin admin-ui page was a dead end. (That row
>   is `main`'s, landed 2026-09-16 under operator decision 8's ACCEPT, hugmesh-generator#244.
>   The `integrate/superadmin` branch had its own duplicate, dropped in the merge.)
>   The floor is deliberately **not** pruned with the slug, because it also carries
>   backing-services, fleet-entitlements, phone-devices, desktop-dials and cloud-backups.
>
> So on a `workloadConsole`-deselected build the console prefix is **matched and
> forwarded** at the front door. The **BFF** stops it, not the gateway:
> `WorkloadAuthorizationFilter` denies a disabled prefix, the k8s seam is `Noop`, and OFF
> #3's DB flags are false. That is **one layer of defence, not two**. To get the gateway
> layer back, add the single deny row spelled out beside the floor in
> `manifests/route-access/initdb/20-schema.sql`. It also darks the shipped
> `/admin/workloads` page, which is why it is not the default.
>
> ⚠ The `games` app-store control plane is the opposite case. It **is** denied at the fe
> door unconditionally, per operator decision 28 = **D** (hugmesh-generator#347,
> 2026-09-17). Between 2026-09-16 and 2026-09-17 the same `/bff/superadmin/**` floor
> governed it and a `DESELECT_SURVIVORS` entry recorded it. Decision 28 reinstated the
> deny row and deleted that ledger entry in the same commit. Today
> `('hugmesh-fe-gateway', '/bff/superadmin/games-services/**', 'ROLE_SUPERADMIN',
> false)` is in the canonical seed and wins the longest match for the whole subtree on
> **every** build. The `games` slug's gate prunes the fe `/admin/games-services/**` page
> row but not this one, so a games-**deselected** build is walled at the front door and
> not only at the BFF. The row also carries `mfa_required = true`, seeded by a row-scoped
> `UPDATE` in `manifests/route-access/initdb/20-schema.sql`, so walling the subtree does
> **not** lower the privileged step-up floor over it. `isMfaRequiredSurface()` is
> allow-blind and role-blind, and [`MFA-ROLLOUT.md`](MFA-ROLLOUT.md) §5 plus
> `tests/scripts/test-mfa-required-rules.sh` pin both halves.
> `tests/scripts/test-superadmin-bff-reachability.sh` §5b asserts the wall itself, §13
> executes both real builders' gate for every slug and fails if a surface appears that is
> neither walled nor ledgered, and §15 fails if this page and that ledger disagree.

**The deselect-survivor ledger, mirrored.** These are the surfaces an optional slug
prunes that the **fe front door still admits** — each one has a `DESELECT_SURVIVORS`
entry in `tests/scripts/test-superadmin-bff-reachability.sh` naming the walls that are
left. §15 of that gate compares this table with that ledger in **both** directions, so
a row here is a live cross-reference and not prose: a surface that stops surviving must
leave both, and one that starts surviving must appear in both.

<!-- gate:deselect-survivors -->

| slug | url_pattern |
|---|---|
| `workloadConsole` | `/bff/admin/workloads/**` |
| `workloadConsole` | `/bff/superadmin/workloads/**` |

<!-- gate:games-fe-posture value=walled -->

The `games` app-store control plane's posture above is `walled` (an explicit fe DENY
row), the other legal value being `ledgered` (governed by the `/bff/superadmin/**`
floor and recorded in `DESELECT_SURVIVORS`). §15 reads that marker and fails if it
disagrees with the seed, in either direction.

**What the slug owns (all pruned together on deselect, `gate_optional_services`):**
the two-SA RBAC Application (`apps/14-workload-console-rbac.yaml` +
`manifests/workload-console-rbac/`, incl. the two `kubernetes.io/service-account-token`
Secrets in `token-secrets.yaml`), the **admin-bff deployment overlay**
(`manifests/admin-bff-api/workload-console-patch.yaml` + its one kustomization
`- path:` line — the `WORKLOAD_CONSOLE_*` env + both token mounts), and the two
route-access rows. Deselected (the DEFAULT), the admin-bff renders **byte-identical**
to a tree that never had the feature; `tests/workload-console/test-workload-console.sh`
enforces this by **executing each real builder's `workloadConsole)` case body verbatim**
against a sandbox tree (never by re-implementing the prune and grepping that the builder
still mentions it — a grep for the overlay filename or for the
`_opt_drop_kustomize_line "<file>"` call stays green through any change to the prune
*pattern*, which is the only argument that decides whether the kustomization line goes).
The assertion is the effect: the pruned kustomization must still resolve every path it
references, or `kustomize build` fails and the **dark** admin-bff stops rendering at all.

**Token mount contract** (cross-repo, consumed by hugmesh-admin-bff-api's dual
read/mutate clients — `WorkloadConsoleClientConfig`):

```
read SA    workload-console-read    -> /var/run/secrets/workload-console-read/token
mutate SA  workload-console-mutate  -> /var/run/secrets/workload-console-mutate/token
```

Both volumes are `optional: true`. The Secrets come from a *different* ArgoCD
Application (`apps/14`) than the admin-bff (`apps/31`) and neither carries a
sync-wave, so on a freshly-lit cluster the tokens may lag the rollout by a sync.
Optional keeps the **always-present** admin-bff pod starting regardless: the half
whose token is missing simply 503s (the contracted degradation) instead of the pod
hanging in `ContainerCreating`. If the console 503s after step 1, re-check step 2
before assuming a bug — you are most likely just ahead of the RBAC app's sync.

**Curation rules the overlay's two allowlists must obey** (enforced by
`tests/workload-console/test-workload-console.sh`, not by convention):

* **`WORKLOAD_CONSOLE_EXEC_READONLY` is judged by a property, not by a list of banned
  names.** The shipped consumer (`WorkloadConsoleProperties.execReadOnlyAllowed`)
  matches `command.get(0)` against this list, so **a bare command name licenses that
  command with *arbitrary arguments***. The bug class is therefore not "a forbidden
  command got onto the list" but "an allowlisted command has an **argument** that turns
  it into one", and on the images the app tier actually runs
  (`eclipse-temurin:25-jre` = Ubuntu + procps + coreutils) three of the names this list
  has carried were exactly that — three instances of one class, not three special cases:

  | entry  | the argument that breaks the list's own rule | upstream wording |
  |--------|----------------------------------------------|------------------|
  | `ps`   | `ps eww` prints every process's full environment | procps `ps(1)`, OUTPUT MODIFIERS: BSD `e` = *"show the environment after command"* |
  | `date` | `date -f <file>` echoes an unparseable secret back as `date: invalid date '<line>'`; `date -r <file>` is a second path argument | coreutils `date(1)`: *"-f, --file=DATEFILE  like --date; once for each line of DATEFILE"* |
  | `du`   | `du --files0-from=<file>` echoes every name in `<file>` that does not exist back as `du: cannot access '<line>'`; `-X/--exclude-from=FILE` opens a second arbitrary file | GNU coreutils manual, *du invocation*: *"Disallow processing files named on the command line, and instead process those named in file file"* |

  **And the flag is not the argument either.** All three rows above are *option*-driven
  escapes, so an audit that asks only *what can its flags be made to do?* is the same
  one-command-behind list in a different costume. `base64 /var/run/secrets/workload-console-read/token`
  takes **no flag at all** — and neither do `od`, `cksum`, `xxd`, `sum`, `basenc`,
  `b2sum`, `nl` or `rev`. The **operand** half of the argv surface is audited too.
  A reader also does not have to be *legible*: `base64`, `od`, `xxd` and `cksum` hand the
  operator the bytes without ever printing them as themselves, so "does the output contain
  the canary string?" sees none of them. What is forbidden is that the output be a
  **function of the file's bytes, in any encoding**.

  Every remaining entry has been audited against **both** questions — *can any flag of
  this make it read a file, dump an environment, execute something, or write?* and
  *handed a plain file path as an* ***operand***, *does anything it prints change with
  that file's bytes?* `ls` (60 options), `df` (18), `free` (22), `uptime` (6), `id` (10),
  `uname` (11) and `stat` (8) take only enum/size/width/pattern/format values and no
  path-valued or program-running option; `ls`, `df` and `stat` do take a `FILE` operand,
  but their own help never calls it a standard stream and no probe output tracked the
  bytes — they print the **name and the metadata**, never the content. So they ship as
  **bare names**. (`stat` is the pointed case: the rule is not "refuse anything that
  takes a path", which would delete `ls`, `df` and `stat` and leave the console with
  nothing.) `ps` and `date` ship as **exact pinned argv** (`ps -e`, `date -u`) — a pinned
  whole-argv form admits no extra operand at all. `du` is **removed** rather than pinned:
  every useful `du` names a path, and pinning a path is exactly the shape
  `--files0-from=/var/run/secrets/...` arrives in — `df` already covers filesystem usage.
  A pinned form is fail-closed against a first-token matcher: the head `ps` is not an
  element of the list, so `ps` — and `ps eww` with it — is refused outright.

  **That audit is not what guards the list.** A written audit ages the moment a
  coreutils release adds an option, and a hand-list of banned names is always exactly one
  command behind — it is what passed `du` in the same round that removed `ps` and `date`.
  `tests/workload-console/exec_argv_property.py` re-derives the verdict on every run from
  two independent oracles, neither of which contains a command name:

  * the command's **own `--help`** — a bare name is rejected when any documented option
    takes a path-valued argument, is described as dumping an environment, or as running a
    program; when its **synopsis** takes a program positionally; **or when its synopsis
    takes a path-shaped *operand* that the same help documents as a standard stream of
    bytes** (*"With no FILE, or when FILE is -, read standard input"*, *"Print selected
    parts of lines from each FILE to standard output"*). `ls`, `df` and `stat` say no
    such thing about theirs, which is what separates them from `base64` and `cut`;
  * its **live behaviour** — every harvested option *and* the plain positional forms
    (`<cmd> <file>`, `<cmd> -- <file>`, `<cmd> <file> <out>`) are fired on a pty at a
    freshly generated canary file, canary environment and executable marker, and the
    entry fails if any argv prints the file's contents, prints an environment, runs the
    marker, or writes. Because an encoding is still the file, the same argvs are also run
    **differentially**: against four sibling files identical in name-shape, length, mode
    and mtime whose contents run `X, Y, X, Y`. A token present in both `X` runs, absent
    from both `Y` runs, *and* vice versa, is a token the **bytes** decided — that is a
    leak in any alphabet. Identity is deliberately not content: the four files differ in
    path and inode, so anything derived from them falls out of the intersection and
    `ls -l`, `stat` and `df` stay green on their own merits rather than by exemption.
    The `X/Y` interleaving is what makes the leg noise-proof — a drifting value (a clock,
    a pid, `df`'s used blocks) is never equal across two non-adjacent runs *and* absent
    from both of the others.

  An entry whose binary is absent from the runner is a **failure**, not a skip: an
  unprobed entry is an unproven one.

  **Matcher (hugmesh-admin-bff-api#114, merged):** two forms. A one-token bare name
  (`ls`, `uname`, `free`) licenses that command with any arguments (exact head); a
  multi-token pinned entry (`ps -e`, `df -h`, `stat -t`, `date -u`) licenses exactly
  that whole argv. No entry may contain a comma (the env binds as a comma-delimited
  `List<String>`).
* **The port-forward triples are an ALLOWLIST, not a substring denylist.** "App-tier
  BFFs only" means a triple ships only if its namespace is in
  `WORKLOAD_CONSOLE_NAMESPACE_ALLOWLIST`, its workload matches the first-party BFF
  contract `^hugmesh-(<seg>-)*bff-api$`, that workload really exists as a
  Deployment/StatefulSet in the shipped cluster tree in that namespace, and the port is
  one it declares. Screening names for `db`/`postgres`/`cassandra`/`clickhouse`/`kafka`/
  `redis`/`vault`/`casdoor`/`pki` is **not** that rule: `tuwunel` (the Matrix homeserver
  — access tokens + registration token), `akkoma`, `hugmesh-coturn`, `egress-proxy` and
  `hugmesh-media-poisoner` all sit in an allowlisted namespace and contain none of those
  substrings.

**Flip order (light it):**

1. **Select the slug at build** (`OPTIONAL_SERVICES="… workloadConsole"` — it is NOT
   in `all`) and flash/sync. This lands RBAC + token Secrets + route rows + the
   deployment overlay, flipping OFF 1 and OFF 2 together: the admin-bff rolls with
   the env + both tokens and builds the real `Fabric8WorkloadClient`. (The two
   ArgoCD apps sync independently — see the `optional: true` note above.)
2. **Verify the wiring** before granting anyone anything:
   ```sh
   kubectl -n hugmesh-backend get secret workload-console-read-token \
     -o jsonpath='{.data.token}' | head -c 8      # non-empty => token minted
   kubectl -n hugmesh-backend get deploy hugmesh-admin-bff-api \
     -o yaml | grep -c workload-console            # mounts + volumes present
   ```
   The console is STILL dark here (OFF 3): every request 403s/404s at the DB flag.
3. **Flip the DB master flag** (SUPERADMIN + step-up, per domain or the GLOBAL row):
   `PUT /bff/superadmin/workloads/config/{domain}` body
   `{"adminEnabled": true, "dangerousTierEnabled": false}`. Leave
   `dangerousTierEnabled` false until exec/log-stream/mutations are actually needed —
   it is the GLOBAL kill for the dangerous tier and applies even to superadmins.
4. **Issue a TTL'd grant** per admin: `POST /bff/superadmin/workloads/grants` body
   `{"grantee": "...", "targetDomain": "...", "logAccess": false}` (READ_ONLY by
   schema; ~24 h lease; the expiry sweep returns the admin to dark automatically).

**Darken in reverse order:** let grants lapse (or revoke), flip the DB flags back
false, then deselect the slug and rebuild — the gate prunes tokens, overlay, RBAC and
route rows in one stroke. Any single step alone is already sufficient to go dark.

> **Note:** `workloadConsole` is deliberately **excluded** from the §7.1 CRD
> live-flip enum — it stays build-determined (see §7.1's closed slug set).

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
  route-access floor in `CanonicalSeed.java` (**hugmesh-gateway** repo) used as
  the in-memory fallback when Postgres/Cassandra are unreachable. It must match
  the route-access rows pruned here, or the in-image snapshot re-enforces removed
  rows on datastore fallback. The games host floor is now **baked in
  `CanonicalSeed.java`** (✅ shipped, §10); it cannot be GitOps-pruned, so any future
  route-access change still needs a matching gateway image rebuild.
- **cloudflared reserved hostnames (cross-repo / prod):** prod cloudflared
  hardcodes `matrix.`/`mastodon.` reserved hostnames before the `*.<primary>`
  wildcard; a games TLD flip also needs a games hostname entry there.

## 10. Cross-repo: shipped work + the one remaining TODO

**✅ SHIPPED (cross-repo waves landed):**

- **hugmesh-federation-api:** the idempotent changesets
  `023-register-akkoma-module.xml`, `024-register-tuwunel-module.xml` and
  `025-register-games-module.xml` (mirroring `022-register-forum-module.xml`) are in. The
  **public** `GET /api/federation/capabilities` projection drives logged-out greying. The
  `…/manifest` endpoint stays `authenticated()` and visibility-filtered.
- **hugmesh-gateway:** `CanonicalSeed.java`'s baked route-access floor carries the
  `games.<GAMES_DOMAIN>` host floor, in sync with the rows `gate_optional_services`
  prunes.
- **hugmesh.net (host):** the host shell reads install-state at bootstrap (HttpClient to
  the public capabilities endpoint), and `menu.component`'s `enabled()` greys out absent
  services (nav and the data-driven home-services cards).

**🟡 CODE-COMPLETE, SHIPS DARK:**

- **hugmesh-admin-bff-api:** the `OptionalService` **CRD and Lease-gated reconcile
  controller** (§7.1). The CRD replaces the `service_state` Postgres table
  (kubectl-native desired state, no DB migration). The controller is the single writer of
  the 13a element list and the greying ConfigMap, reconciled from the CRs.
  `app.optional-services.reconcile.enabled=false` by default (Noop client and writers).
  Validated offline: the CRD schema (`kubectl --dry-run=client` / kubeconform),
  `kustomize build`, the pure `renderElements`/`renderInstalledServices` transforms and
  the fake-client reconcile composition (JUnit).
- **hugmesh-generator:** the CRD/RBAC/seed bundle (`manifests/optional-services-operator`),
  its `apps/13d` Application, the `ignoreDifferences` keystone on both roots and `apps/16`,
  and the `_opt_render_optionalservice_cr` build seeding.

**🚧 CLUSTER-GATED FOLLOW-UP (needs a live cluster to verify):**

- **The cut-over.** Not "delete the hardcoded apps": see §10.3 for the derived matrix.
  Eight slugs are single-app (akkoma, tuwunel, owncast, tube, character-studio, edge-ai,
  edge-ai-analysis, edge-ai-tts) and could be cut over one at a time; three are multi-app
  (phpbb 4 apps, games 3, character-forge 3) and need a design decision first, because one
  13a element covers ONE manifest directory. An earlier version of this bullet omitted the
  three `edge-ai` apps. Coordinate the ESO split, the route-access rows, stateful-service
  scale-to-zero and the `CanonicalSeed.java` gateway floor (§9). THEN set
  `app.optional-services.reconcile.enabled=true` (with the Lease under multi-replica).
  Enabling it BEFORE the cut-over double-manages akkoma/tuwunel/phpbb (§7.1).
- **Live keystone verification.** Three things cannot be checked offline: that the
  fabric8 JSON write lands on the live `argoproj.io/v1alpha1 ApplicationSet`, that ArgoCD
  re-generates and prunes `optional-<slug>`, and that `ignoreDifferences` +
  `RespectIgnoreDifferences=true` actually stop selfHeal from reverting the element and
  ConfigMap writes.

**✅ THE SUPERADMIN TOGGLE EXISTS (built after this section was first written):**
admin-bff serves `GET /bff/superadmin/optional-services` (the catalogue) and
`PUT /bff/superadmin/optional-services/{slug}` (`{enabled, reason?}`), both
`SUPERADMIN` (`OptionalServiceSuperadminController`). The toggle patches the CR through
the fabric8 client. While the reconciler is dark it answers 503 with `dark:true`; a slug
the reconciler cannot action (`workloadConsole`, `headwind`, `attestation-server`) is a
422 that names the reason. `hugmesh-superadmin-service-catalog-ui` has the screen
(`service-catalog-optional-services.component.ts`).

### 10.1 Turning the reconciler on — the lever, and why it is GitOps-only

Until 2026-08-26 there was **no supported way to enable this feature at all**.
`APP_OPTIONAL_SERVICES_RECONCILE_ENABLED` appeared once in the whole platform, as the
`:false` default of `app.optional-services.reconcile.enabled` in admin-bff's own
`application.yml`. No manifest, builder, `brand.conf` or CLI flag set it, and
`kubectl set env` was **reverted on the next selfHeal pass** because
`apps/31-admin-bff-api.yaml` carries `automated: {prune: true, selfHeal: true}` with no
`ignoreDifferences`. A flag that only a write ArgoCD undoes can set is unreachable, not
opt-in.

**The lever now exists and is a one-line commit.** The flag is DECLARED in
`specs/cluster/manifests/admin-bff-api/deployment.yaml`:

```yaml
- { name: APP_OPTIONAL_SERVICES_RECONCILE_ENABLED, value: "false" }
```

That manifest is the **single source**. Change the value to `"true"`, merge, and let
ArgoCD sync. selfHeal then *enforces* the value instead of fighting it.

**It is deliberately NOT operator-settable at runtime**, and `apps/31` deliberately
has NO `ignoreDifferences`:

- ArgoCD addresses container env by **array index**
  (`/spec/template/spec/containers/0/env/N`); there is no by-name pointer. Such an
  exemption is correct only until someone inserts an env var above it, after which it
  silently exempts a *different* variable — and this container's env carries
  `secretKeyRef`s. Exempting the whole `/env` array un-enforces every variable in the
  pod to make one settable.
- Enabling this is not a routine toggle. It has a hard precondition (below), so it
  wants a reviewed commit and an audit trail. selfHeal reverting an ad-hoc
  `kubectl set env` of this key is **correct behaviour**, not a defect.

The **runtime** surface an operator or superadmin drives is the per-slug
`OptionalService` CRs — and *those* writes ARE exempted from selfHeal, on their own
objects and **by name, not by index** (`apps/16` for the ConfigMap data keys;
`app-of-apps.yaml` + `apps/00-app-of-apps-waved.yaml` for the 13a elements).

**⚠ BLAST RADIUS — why the default is NOT flipped.** On its first lit tick the
reconciler becomes authoritative over the entire closed slug set: a known slug with
**no** CR is reconciled to `false`. The seed CRs ship `akkoma`/`tuwunel`/`phpbb`
`enabled: true` while `apps/30-akkoma.yaml`, `apps/30-tuwunel.yaml` and
`apps/30-phpbb.yaml` are still **hardcoded** Applications — so the first tick makes
the 13a ApplicationSet create `optional-akkoma` / `optional-tuwunel` /
`optional-phpbb`, each double-managing a manifest directory a hardcoded Application
already owns, on every live mesh at once. The hardcoded-app **cut-over is the
precondition for flipping this flag**, not a follow-up to it.

### 10.2 The slug set is DERIVED, and one guard pins all five surfaces

The set was described for months as a "closed 1:1 set". When measured in August 2026 it was **five
different cardinalities at once**: 17 ConfigMap booleans, 14 13a elements, 13 CRD
enum values, 13 seed CRs, 12 Java registry entries. Re-counted on origin/main on 2026-10-07 it is 17, 14,
14, 14 and 14: the three extra ConfigMap booleans are `workloadConsole`, `headwind` and
`attestation-server`, which have no 13a element on purpose. The governable set is

```
G = { slug : has a 13a ApplicationSet element AND an installed-services ConfigMap boolean }
```

— exactly what the reconciler can actuate. `tests/scripts/test-optional-service-slug-closure.sh`
recomputes `G` and requires the CRD enum, the seed CRs, `apps/16`'s
`ignoreDifferences` pointers and admin-bff's `OptionalServiceRegistry` to equal it.
Nothing hard-codes the slugs, so adding one to 13a + the ConfigMap makes the guard
name every surface still missing it. It reads the **sibling `hugmesh-admin-bff-api`
checkout** for the Java leg and exits INCOMPLETE (a FAILURE) without it, because the
worst defect it catches is invisible from inside this repo.

> **⚠ RECORDED, NOT FIXED — the `installed-services` ConfigMap is WRITE-ONLY.**
> A grep for the literal `installed-services` across every `.java/.ts/.py/.go` in the
> org returns exactly one distinct line naming *that* object: `CONFIGMAP_NAME` in the
> writer itself. No Deployment mounts it; no `configMapKeyRef` references it. Half of
> every reconcile pass maintains an artefact with no consumer. What actually drives
> the user-facing greying is the **`federation_modules` table** in the federation
> Postgres, read via `GET /api/federation/capabilities` (§3.1) — which is precisely
> why `manifests/federation-modules-gate/` had to exist. The absence is easy to miss
> because the name collides with a *different*, per-brand ConfigMap
> `hugmesh-installed-services-<domainSlug>` in `hugmesh-backend` that **is** read (by
> `ConfigMapRunningServiceProvider`, for the cloud-backup menu). Do **not** close this
> by inventing a consumer; it is recorded so the next reader does not infer one from
> the writer's existence.

### 10.3 The cut-over, derived: what it needs and why it cannot land dark

`tests/scripts/test-optional-services-cutover-matrix.sh` derives the table below from
`specs/cluster/optional-services.yaml` (`apps:`), `apps/13a-optional-services.yaml` and
`apps/*.yaml`, enforces seven invariants on it, and fails when this block drifts from the
tree. The invariants, each with an isolating negative control in the suite:

* I1 every element path is a non-empty, relative path inside the tree and an existing directory
* I2 every hardcoded owner of an element's directory is one of THAT slug's registry apps
  (no cross-slug ownership)
* I3 every registry app of an element slug exists and parses
* I4 a slug that has registry apps has an owner for the element directory
* I5 the element namespace equals the owner's destination namespace
* I6 no directory is claimed twice: per directory, the hardcoded owners plus the elements
  with `installed:"true"` number at most one, and no two elements name the same directory
  (even when both are `"false"`: flipping either would double-manage it)
* I7 every element slug has a registry entry, and every element carries every key the
  template renders

 Regenerate with
`python3 tests/scripts/optional_services_cutover_matrix.py --root . emit`.

<!-- cutover-matrix:begin (generated; test-optional-services-cutover-matrix.sh pins it) -->
| slug | class | hardcoded owner of the element dir | apps the element does NOT cover (orphaned by a plain delete) | what the generated Application loses |
|---|---|---|---|---|
| akkoma | single-app | `30-akkoma.yaml` | - | name akkoma -> optional-akkoma |
| tuwunel | single-app | `30-tuwunel.yaml` | - | name tuwunel -> optional-tuwunel |
| phpbb | multi-app | `30-phpbb.yaml` | `38-forum-bff-db.yaml`, `39-forum-bff-api.yaml`, `49-forum-ui.yaml` | name phpbb -> optional-phpbb |
| games | multi-app | `50-games.yaml` | `06-casdoor-games.yaml`, `13c-games-instances.yaml` (ApplicationSet) | name hugmesh-games -> optional-games; sync-wave 2 |
| owncast | single-app | `52-owncast.yaml` | - | name hugmesh-owncast -> optional-owncast; sync-wave 2 |
| tube | single-app | `53-tube.yaml` | - | name hugmesh-tube -> optional-tube; sync-wave 2 |
| character-studio | single-app | `49b-character-studio-ui.yaml` | - | name hugmesh-character-studio-ui -> optional-character-studio |
| character-forge | multi-app | `39b-character-forge-bff-api.yaml` | `38b-character-forge-bff-db.yaml`, `49c-character-forge-ui.yaml` | name character-forge-bff-api -> optional-character-forge |
| anubis | runtime-only | none | - | - |
| coturn | runtime-only | none | - | - |
| meshbridge | runtime-only | none | - | - |
| edge-ai | single-app | `54-edge-ai.yaml` | - | name hugmesh-edge-ai -> optional-edge-ai; sync-wave 2 |
| edge-ai-analysis | single-app | `55-edge-ai-analysis.yaml` | - | name hugmesh-edge-ai-analysis -> optional-edge-ai-analysis; sync-wave 3 |
| edge-ai-tts | single-app | `55b-edge-ai-tts.yaml` | - | name hugmesh-edge-ai-tts -> optional-edge-ai-tts; sync-wave 2 |

elements: 14 (single-app 8, multi-app 3, runtime-only 3)
13a template finalizers: none; template sync-wave: none
finalizers on the hardcoded owners: none
<!-- cutover-matrix:end -->

**State on main (re-measured 2026-10-14, origin/main 5f450a48).**

* The build-time prune governs a device: `bootstrap/bootstrap.sh` applies the baked
  `apps/` tree (commit `a08484f8`; `tests/cluster/test-bootstrap-applies-baked-apps.sh`
  48 passed). The 13a element for a selected slug stays `installed:"false"` while a
  hardcoded owner exists (`_opt_appset_cutover_done`,
  `scripts/_optional-services-lib.sh:550`). Every committed element is `"false"`, so the
  ApplicationSet generates nothing for the eleven slugs that have an owner. anubis, coturn
  and meshbridge have no hardcoded app; a prod build renders anubis `"true"`.
* The reconciler is dark (`APP_OPTIONAL_SERVICES_RECONCILE_ENABLED` is `"false"` in
  `manifests/admin-bff-api/deployment.yaml`), so nothing flips an element at runtime.

**Why deleting the owners is not a dark change.** It changes what a cluster that tracks
`main` does the moment it syncs, which is the one thing a dark change must not do.

1. *The Application name changes.* Generated names are `optional-<slug>`; the owners are
   `akkoma`, `hugmesh-games`, `character-forge-bff-api`, and so on. On a cluster whose
   root is the repo-recursing `hugmesh-root` (`app-of-apps.yaml:41`, `prune: true`)
   deleting `apps/30-akkoma.yaml` prunes Application `akkoma`.
2. *No hardcoded owner carries a `resources-finalizer`, and neither does the 13a template*
   (derived above, and `grep -n finalizer specs/cluster/apps/*.yaml` finds only the waved
   root). So, as ArgoCD documents it, the prune orphans the workloads rather than deleting
   them, and 13a, held at `"false"`, creates nothing to adopt them: the services keep
   running but nothing manages them. Setting the element `"true"` in the same git commit
   would not fix this on a cluster where `optional-services` already exists: both roots
   (`app-of-apps.yaml`, `apps/00-app-of-apps-waved.yaml`) ignore
   `/spec/generators/0/list/elements` with `RespectIgnoreDifferences=true` (read from the
   manifests), so a git edit to `installed` should never reach the live object. A git
   `"true"` would take effect only when the ApplicationSet is first created (a fresh
   image). NOT VERIFIED against a live ArgoCD: the orphan-on-prune behaviour with no
   finalizer, and `RespectIgnoreDifferences` holding a live element list back.
3. *The reverse is also true, and is a decision nobody has made.* With no finalizer on the
   template, flipping an element to `"false"` at runtime deletes the Application and leaves
   the pods, Services and PVCs running: "runtime remove" would not remove anything.
   `tests/scripts/test-selected-services-only.sh` check C7 already records exactly this and
   is red on purpose (it is gated post-merge by `lint:selected-services-only-chain`, see
   `PREMERGE_UNGATED`). Adding `resources-finalizer.argocd.argoproj.io` turns C7 green but
   is not harmless: `manifests/akkoma`, `tuwunel`, `forum` (2) and `edge-ai` each ship a bare
   `PersistentVolumeClaim` (no StatefulSet `volumeClaimTemplates`), so a cascade delete
   destroys the data, and so would deleting the ApplicationSet or a bad element write. So
   the finalizer must come with a stateful-data policy (scale to zero and keep the PVC, or
   move the PVCs out of the slug's directory) and with
   `syncPolicy.preserveResourcesOnDeletion` on the ApplicationSet. Not verified against a
   live ArgoCD here.
4. *Images self-switch.* `_opt_appset_cutover_done` lifts itself the moment an owner file is
   gone, so the next image build flips selected slugs to `"true"` and ships a differently
   named Application. For a freshly provisioned device that is clean (nothing to adopt). For
   an already-running cluster it is the live adoption problem, and images are re-provisioned
   rather than upgraded (`specs/cluster/README.md`, "What the device syncs").
5. *One element is one directory.* The multi-app rows above have orphans: delete the
   owner and the orphans keep their hardcoded Applications forever, so a runtime
   "remove phpbb" leaves forum-bff-db, forum-bff-api and forum-ui running. Options, none
   proven offline: a multi-source template (`sources:` from an element list, via
   `templatePatch`), or one element per directory with a `parent` key (which changes the
   slug-closure definition of G in 10.2). 13c `games-instances` is already a second
   ApplicationSet with its own `installed` flag.
6. *Sync waves are dropped* (games, owncast, tube, edge-ai, edge-ai-tts wave 2;
   edge-ai-analysis wave 3). ArgoCD only orders children of one parent, so this matters
   under `hugmesh-root` and not on a baked device, where `bootstrap.sh` applies each file
   independently. Adding a per-element `wave` key is safe for the admin-bff writer
   (`Fabric8OptionalServiceApplicationSetPatcher.applyDesiredToElements` copies every
   other key), but the roots ignore `/spec/generators/0/list/elements`, so a live element
   list would lack the new key while the template (`missingkey=error`) requires it.
   Use `index . "wave"` in the template, never `.wave`. NOT VERIFIED against a live
   ArgoCD: that `index . "wave"` is tolerated under `missingkey=error`.
7. *Name and file consumers break.* Found by `grep -rna` over every owner and orphan file
   name in the matrix (plain `grep` skips a file that holds a NUL byte and reports a miss).
   Functional consumers, which act on a name or file and would change behaviour:
   `scripts/_optional-services-lib.sh` (the per-slug `rm -f` prune),
   `specs/cluster/optional-services.yaml` (`apps:`), `specs/cluster/backing-services.yaml`
   (`apps: [apps/38-forum-bff-db.yaml]`), `build-x86-host-stage4.sh` and
   `build-rpi5-stage4.sh` (`_mgd_pg ... apps/38-forum-bff-db.yaml`, and the IdP prune of
   `06-casdoor-games.yaml`), and the brand templates `templates/apps/39-forum-bff.yaml.hbs`
   and `49-forum-ui.yaml.hbs` (they render the phpbb orphans). Tests that name them:
   `tests/scripts/test-backing-service-endpoints-closure.sh:166-175` (`52-owncast`,
   `53-tube`, `30-phpbb` as the Application that carries a manifest),
   `tests/stack/test-optional-services-exclude.sh`, `tests/stack/test-optional-services-parity.sh`,
   `tests/scripts/test-selected-services-only.sh`, `tests/cluster/test-bootstrap-applies-baked-apps.sh`,
   `tests/scripts/test-idp-builder-functions.sh` and
   `tests/managed-services/test-managed-services-gate.sh`.
   Prose only (a stale mention is not a break, but should move with the cut-over):
   `apps/17-backing-service-endpoints.yaml:91`, `apps/23-headwind.yaml:1,12`,
   `apps/05b-casdoor-domains.yaml`, `apps/06-casdoor-games.yaml`, `apps/30-phpbb.yaml`,
   `apps/30-hugmesh-apis.yaml`, `apps/50-games.yaml`, `bootstrap/bootstrap.sh:131,160`,
   `bootstrap/kind-local/bootstrap-kind.sh:998`, `bootstrap/kind-local/README.md:181`,
   `manifests/admin-bff-api/deployment.yaml:610`, `manifests/forum/network-policy.yaml:22`,
   `manifests/optional-services-operator/seed-optionalservices.yaml:17`,
   `tests/scripts/kind_route_closure.py:68-80`, `docs/EDGE-AI.md`, `docs/XR-CHAT.md`,
   `docs/RESERVED-PREFIXES.md`, `docs/GAMES-APPSTORE.md` and
   `tests/e2e/specs/18-rbac-phase8-10-pending.spec.ts`.
   The kind profiles do not apply any owner (`bootstrap-kind.sh` lists them only in a
   comment), so they are not a consumer.

**Order for an already-running cluster, per single-app slug** (needs a live cluster, not
exercised; each step below assumes the ignoreDifferences behaviour above, which is not
verified against a live ArgoCD):

1. Confirm the old Application is Synced and Healthy and the reconciler is dark; record
   the workload UIDs.
2. Land the git change that deletes the owner. On a `hugmesh-root` cluster the root prunes
   the old Application and the workloads are orphaned. (On a baked-tree device nothing is
   pruned: delete the Application by hand, `kubectl delete application <old>
   --cascade=orphan`. On a root-tracking cluster a hand delete while the file is still in
   git is undone by the root's selfHeal.)
3. Live-patch the ApplicationSet element to `"true"` (`kubectl patch applicationset
   optional-services`). It is the same field the reconciler will own, and selfHeal does not
   revert it for the same ignoreDifferences reason. Do not patch first: that opens a window
   with two owners on one directory, which is what `_opt_appset_cutover_done` exists to
   prevent. The reconciler cannot do this step, because it is dark and is only enabled
   after the cut-over.
4. Wait for `optional-<slug>` to be Synced and Healthy and check the UIDs did not change.

Only after all eleven have moved, and the keystone checks in section 10 have passed, flip
the reconciler.

**What is still open and needs an operator or a live cluster:** the finalizer and
stateful-data decision (3); the multi-app design (5); the adoption order above; the three
keystone checks in section 10. The suite runs post-merge as `lint:optional-services-cutover-matrix` in `.gitlab-ci.yml`;
adding it to `.github/workflows/shell-suites.yml` (the pull_request gate) is an edit under
`.github/` and was not made, which is why `test-guard-integrity.sh` lists it in
`PREMERGE_UNGATED`.

## 11. Verification & rollback

**Verify a build:**
```sh
TREE=…/sysroot/var/lib/hugmesh/cluster
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
