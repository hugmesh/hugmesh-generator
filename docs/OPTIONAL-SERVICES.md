# Optional Services — add/remove by command (akkoma · tuwunel · phpBB · games · owncast · tube · character-studio · character-forge)

## 1. Purpose & scope

The platform splits into two tiers:

- **Architecture (core, always present):** the gateways (pki/be/fe), Casdoor/PKI,
  the federation API + remote-fragment + host shell, and the admin/user/mod
  BFFs + UIs.
- **Optional services (this doc):** **akkoma** (Mastodon-API fediverse server),
  **tuwunel** (Matrix homeserver), **phpbb** (forum), **games** (the
  hugmesh.games portal + its own games-realm Casdoor), **owncast** (HLS
  live-streaming, GPU-gated x86), **tube** (LocalTube YouTube archive, GPU-gated
  x86), **edge-ai** (GPU inference node serving an OpenAI-compatible model API to
  the mesh — DEFAULT-OFF, GPU-gated; auto-selected by the `edge_ai` node role; see
  [EDGE-AI.md](EDGE-AI.md)), **character-studio** (the VN character-studio frontend
  remote — character creator + chat surface mounted at `/character-studio`, ROLE_USER;
  DEFAULT-OFF, admin gate), **character-forge** (the Character Forge 3D character
  maker + XR-chat avatar source — a MULTI-APP slug shaped like phpbb: BFF db + BFF
  api at `/bff/character-forge/**` + frontend remote mounted at `/character-forge`,
  ROLE_USER; DEFAULT-OFF, admin gate; see [XR-CHAT.md](XR-CHAT.md)). (Plus the
  non-user-level optional slugs **egress-vpn**
  / **tor** / **workloadConsole** / **anubis** / **coturn** / **meshbridge**, gated
  by the same registry.)

  **tor** (Tor v3 onion hidden service, DEFAULT-OFF) follows the same node-scoped
  model as egress-vpn (`scope: node`): add with `--with-tor` (x86/Studio/build-menu)
  or by listing `tor` in `OPTIONAL_SERVICES` (rpi5/brand.conf); exclude with
  `--exclude-services tor`. It owns **nodePackages: [net-vpn/tor]** + **nodeServices:
  [tor, hugmesh-tor-reconcile]** (the distro Tor daemon + a reconcile agent) and
  exposes the in-cluster fe-gateway as a v3 `.onion` — INBOUND reach with no public IP
  / DDNS. The v3 onion keypair is minted + persisted OFF-GIT under
  `/var/lib/tor/hugmesh-onion` on first boot; net-vpn/tor is omitted + the services
  unlinked when not selected. See [TOR-HIDDEN-SERVICE.md](TOR-HIDDEN-SERVICE.md).

  **coturn** (TURN/STUN relay for Matrix WebRTC audio/video) is a DEFAULT-OFF,
  **runtime-only** slug (anubis pattern: `apps: []`, no baked Application) that
  lands in `hugmesh-backend` next to tuwunel so they share one TURN secret. When
  off, Matrix calls keep host-only ICE (`iceServers: []`) — byte-identical to
  mainline. See [`docs/COTURN.md`](COTURN.md).

  **meshbridge** (Meshtastic LoRa mesh ↔ Matrix bridge) is a DEFAULT-OFF,
  **runtime-only** slug (the coturn pattern: `apps: []`, no baked Application)
  that lands in `hugmesh-backend` next to tuwunel: it is a Matrix APPSERVICE
  (exclusive `@mesh-.*` user namespace, registered by a PostSync Job via the
  tuwunel admin room) speaking the in-namespace CS API, with radios attached by
  USB-serial, LoRa-WiFi TCP (:4403) or a Meshtastic MQTT-JSON broker. `dependsOn:
  tuwunel` (declared in the installed-services `services.json`, like coturn) —
  the console greys it while the homeserver is off. When off, nothing references
  it — byte-identical to mainline. See
  [`docs/MESHTASTIC-BRIDGE.md`](MESHTASTIC-BRIDGE.md).

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
| `slug` | `akkoma` / `tuwunel` / `phpbb` / `games` / `owncast` / `tube` / `character-studio` / `character-forge` (+ `egress-vpn` / `tor` / `workloadConsole` / `anubis`) |
| `namespace` | the k8s namespace it lands in |
| `apps` | the ArgoCD Application YAMLs it **owns** (pruned on removal) |
| `sharedApps` | apps shared with another slug (e.g. `45-social-ui.yaml`); pruned only when **all** owners are deselected |
| `manifestPath` / `extraManifestPaths` | its `manifests/<dir>` (pruned on removal) |
| `esoFile` | its **per-service** ExternalSecret file (post-split; see §9) |
| `gatewayHost` / `gatewayRouteIds` | its public host + the gateway route ids to drop |
| `routeAccessRows` | the `gateway_route_access` rows it owns (dropped so a matched route to a deleted upstream cannot 502 / stale-grant) |
| `federationModule` | the `federation_modules` registration (federation-api wave) |
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

## 3. Build-time: select services on a USB

### Default-inclusion policy (user 2026-06-17)

| Tier | Slugs | When baked |
|---|---|---|
| **DEFAULT-ON** (the built-in default when no selection is given) | `akkoma`, `tuwunel` (Matrix), `phpbb` | always, unless `EXCLUDE_SERVICES` removes them |
| **DEFAULT-OFF** (must be specifically added) | `games`, `owncast`, `tube`, `character-studio`, `character-forge` — and any future user-level service | only when explicitly selected |
| **FULL-SET** | `OPTIONAL_SERVICES=all` / `--all-services` | every user-level slug — rpi5 **and** x86 builders |

> ⚠ **`games` is DEFAULT-OFF** (it was previously default-on). Add it with
> `--enable-games` / `ENABLE_GAMES=true`, by naming `games` in `OPTIONAL_SERVICES`,
> or via the full set. `owncast`/`tube` are GPU-gated x86 services, also off by default.
> `character-studio` is an admin-gated frontend remote, off by default — add it with
> `--with-character-studio`, by naming `character-studio` in `OPTIONAL_SERVICES`, or via the full set.
> `character-forge` (the 3D character maker + XR-chat avatar source, a phpbb-shaped
> multi-app slug: BFF db + BFF api + UI remote) is likewise off by default — add it
> with `--with-character-forge`, by naming `character-forge` in `OPTIONAL_SERVICES`,
> or via the full set. See [XR-CHAT.md](XR-CHAT.md).

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
tube character-studio character-forge`) right after arg parsing — before `EXCLUDE_SERVICES`, so the subtractive knob
still removes from it (e.g. `--all-services --exclude-services "games"` bakes
everything *except* games). A bare `all` anywhere in the list expands the whole token.

**`EXCLUDE_SERVICES` — the SUBTRACTIVE force-OFF knob.** Applied **last**, after
every positive source is resolved, it removes any user-level slug from the final
selection no matter how it became selected (default / `brand.conf` /
`--optional-services` / `all` / the games opt-in). It is the one-liner that turns OFF
an on-by-default service without re-enumerating the whole positive list; each excluded
slug is then pruned + rendered `installed:"false"` exactly like an unselected one.
**This knob (and the `all` sentinel) is wired identically in `build-rpi5-stage4.sh`
and `build-x86-host-stage4.sh`** (the x86 port mirrors the rpi5 resolution order).
```sh
# brand.conf
EXCLUDE_SERVICES="phpbb tuwunel"        # forum-less + Matrix-less, keep the rest
# or the CLI flag (whitespace/comma separated):
./build-rpi5-stage4.sh --exclude-services "phpbb tuwunel"
./build-rpi5-stage4.sh --all-services --exclude-services "games"   # all-but-games
```
> Precedence summary: `OPTIONAL_SERVICES` (default `akkoma tuwunel phpbb`) is the
> positive allow-list (built-in < brand.conf < `--optional-services`; `all` expands
> to the full set), then the opt-in folds (games; on x86 also edge-ai / tor /
> character-studio / character-forge) fold their slugs in, then **`EXCLUDE_SERVICES` subtracts last**.
>
> **Both builders.** The FULL-SET sentinel (`OPTIONAL_SERVICES=all` /
> `--all-services`) **and** the subtractive `EXCLUDE_SERVICES` / `--exclude-services`
> knob are wired in **`build-rpi5-stage4.sh`** (the canonical cluster-node builder)
> **and `build-x86-host-stage4.sh`** with the same resolution order (built-in
> default respecting env/brand.conf < `all`-sentinel expansion < the opt-in folds <
> the EXCLUDE subtraction LAST). On x86 the subtraction runs after **every** opt-in
> fold (games / edge-ai / tor / character-studio / character-forge / edge-ai-analysis / edge-ai-tts),
> so an excluded slug is force-OFF there too regardless of how it was selected.
> `edge-ai-tts` (Piper TTS + viseme timeline, VN voice) is CPU-only and carries NO
> `edge-ai` dependency — unlike `edge-ai-analysis` its opt-in fold is wired in
> **both** builders, not just x86; see [EDGE-AI.md](EDGE-AI.md#4c-voice-synthesis--tts-api-for-the-mesh-edge-ai-tts).

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

Verify the baked tree (under `…/sysroot/var/lib/hugmesh/cluster`):

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

> **STATUS: build-time prune ✅ SHIPPED · build-time 13a render ✅ SHIPPED ·
> federation `OverrideService` + public `GET /api/federation/capabilities` ✅ SHIPPED ·
> host (hugmesh.net) capabilities consumption + `menu.component` `enabled()`
> greying ✅ SHIPPED · live admin-driven flip 🟡 CODE-COMPLETE, SHIPS DARK (the
> `OptionalService` **CRD + controller** — §7.1; reconciler
> `app.optional-services.reconcile.enabled=false` by default) · hardcoded-app
> cut-over 🚧 CLUSTER-GATED (§10).**
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

These admin-bff seams + the CRD reconcile bridge are described in §7.1 and §10.

## 7.1. The `OptionalService` CRD + controller (the live-flip mechanism)

The runtime desired-state object is a **CRD** (`optionalservices.platform.hugmesh.
systems`, the platform's first CRD — `kind: OptionalService`, `shortName: optsvc`,
namespaced in `devops`), reconciled by a **Lease-gated single-writer controller** in
`hugmesh-admin-bff-api` (`systems.hugmesh.adminbff.optionalservices.
OptionalServiceReconciler`, cloned from the `NodeStorageReconciler` /
`Fabric8NodeStorageConfigMapWriter` precedent). The user chose the CRD over a watched
ConfigMap or a git-committing reconciler: no DB migration, `kubectl`-native, directly
admin-mutatable. It **replaces** the previously-proposed `service_state` Postgres
table.

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
   - **`installed-services` ConfigMap** (`hugmesh-policy`) — a targeted merge-patch
     of the matching greying boolean, keeping the admin console + host greying
     consistent.
3. Each CR's `/status` (`phase`, `installed`, `observedGeneration`, `conditions`) is
   updated so `kubectl get optsvc` shows the effective state.

**Closed slug set (verified against `optional-services.yaml` + the ConfigMap + 13a):**
the CRD enum is the **13 cluster-service slugs** — `akkoma tuwunel phpbb games owncast
tube character-studio character-forge anubis coturn edge-ai edge-ai-analysis edge-ai-tts`. Deliberately
EXCLUDED: `workloadConsole` (ConfigMap boolean but no 13a element — its RBAC is the
hardcoded `apps/14-workload-console-rbac.yaml`; left build-determined) and the NODE
services `egress-vpn`/`tor` (no cluster Application, no ConfigMap boolean — a separate
node-reconcile track). **NOT YET in the enum: `meshbridge`** — it has BOTH a 13a
element AND a ConfigMap boolean (so the manual GitOps flip works today), but adding it
to the CRD requires the operator wave to extend the enum
(`manifests/optional-services-operator/crd-optionalservice.yaml`) + seed CR AND the
controller's built-in OptionalServiceRegistry (separate repo) in lockstep; until then
the live-flip CRD mechanism does not cover it.

**⚠ The `ignoreDifferences` KEYSTONE (the piece the whole mechanism hinges on).**
ArgoCD's automated recurse roots (`app-of-apps.yaml` + `apps/00-app-of-apps-waved.
yaml`, `selfHeal:true`) and the policy app (`apps/16`) would REVERT any live element /
ConfigMap write back to git's inert baseline. So:

- both roots carry `ignoreDifferences` on `argoproj.io ApplicationSet
  optional-services` `jsonPointers:[/spec/generators/0/list/elements]` **+
  `RespectIgnoreDifferences=true`**;
- `apps/16` carries `ignoreDifferences` on the `installed-services` ConfigMap's 12
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

The Workload Console (the `/bff/{admin,superadmin}/workloads/**` pod console inside
the always-present admin-bff) **ships dark behind three INDEPENDENT OFFs**. Each one
alone keeps the console unusable; lighting it is a deliberate, ordered act:

| # | OFF | Owner | Dark behaviour |
|---|-----|-------|----------------|
| 1 | **Generator gate** — `WORKLOAD_CONSOLE_ENABLED=false` (the `app.workload-console.enabled` default) *and* the two `hugmesh-be-gateway` route-access rows pruned | build-time (`workloadConsole` slug) | **the BFF is the wall, not the gateway** (corrected 2026-08-26 — see below): a direct in-cluster call 404s because the BFF's `WorkloadAuthorizationFilter` denies a disabled prefix, and the k8s seam is the fail-closed `NoopWorkloadClient` |
| 2 | **k8s seam** — `WORKLOAD_CONSOLE_K8S_ENABLED=false`, no SA tokens mounted | build-time (same slug) | the fail-closed `NoopWorkloadClient` **503s every call**; no k8s API is ever dialed |
| 3 | **DB master flag + TTL'd grants** — `workload_console_config.admin_enabled` / `dangerous_tier_enabled` default false; every admin needs an active grant lease (~24 h TTL, expiry-swept) | runtime (SUPERADMIN + step-up) | a fully lit-wired cluster still shows **nobody anything** |

> **Why OFF #1's cell no longer says "the gateway 404s the whole prefix".**
> The two route-access rows the slug prunes are on **`hugmesh-be-gateway`**, and that
> gateway declares **no `/bff` route at all** (`apps/20-gateway-be.yaml`) — so pruning
> them never changed a gateway decision for a browser. What a browser actually hits is
> `hugmesh-fe-gateway`, and there:
>
> * `/bff/admin/workloads/**` has **always** been matched by the pre-existing
>   `'/bff/admin/**' -> ROLE_ADMIN` floor, deselected or not. The old wording was
>   already false for the ADMIN half.
> * `/bff/superadmin/workloads/**` is matched by the `'/bff/superadmin/**' ->
>   ROLE_SUPERADMIN` floor added 2026-08-26 (without which every shipped superadmin
>   admin-ui page was a dead end). That floor is deliberately **not** pruned with the
>   slug, because it also carries backing-services / fleet-entitlements /
>   phone-devices / desktop-dials / cloud-backups.
>
> So on a `workloadConsole`-deselected build the console prefix is **matched and
> forwarded** at the front door; what stops it is the **BFF**, not the gateway —
> `WorkloadAuthorizationFilter` denies a disabled prefix, the k8s seam is `Noop`, and
> OFF #3's DB flags are false. Defence-in-depth at deselect is therefore **one layer,
> not two**. An operator who wants the gateway layer back adds the single deny row
> spelled out in `manifests/route-access/initdb/20-schema.sql` beside the floor; note
> that it also darks the shipped `/admin/workloads` page, which is why it is not the
> default. The sibling case — the `games` app-store control plane — **is** denied at
> the fe door unconditionally, because nothing shipped calls it (same file).
> `tests/scripts/test-superadmin-bff-reachability.sh` §13 executes both real builders'
> gate for every slug and fails if a third such surface appears.

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

  **Cross-repo TODO (admin-bff wave):** match the whole argv
  (`String.join(" ", command)`) instead of `command.get(0)`; until then only the bare
  names are reachable. No entry may contain a comma (the env binds as a comma-delimited
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

**✅ SHIPPED (cross-repo waves now landed):**

- **hugmesh-federation-api ✅:** the idempotent changesets
  `023-register-akkoma-module.xml` / `024-register-tuwunel-module.xml` /
  `025-register-games-module.xml` (mirroring `022-register-forum-module.xml`) are in,
  and the **public** `GET /api/federation/capabilities` projection now drives
  logged-out greying (the `…/manifest` endpoint stays `authenticated()` +
  visibility-filtered).
- **hugmesh-gateway ✅:** `CanonicalSeed.java`'s baked route-access floor now
  carries the `games.<GAMES_DOMAIN>` host floor in sync with the rows
  `gate_optional_services` prunes.
- **hugmesh.net (host) ✅:** the host shell consumes install-state at
  bootstrap (HttpClient → the public capabilities endpoint) and `menu.component`'s
  `enabled()` greys out absent services (nav + data-driven home-services cards).

**🟡 CODE-COMPLETE, SHIPS DARK (this wave):**

- **hugmesh-admin-bff-api:** the `OptionalService` **CRD + Lease-gated
  reconcile controller** (§7.1) — the `service_state` Postgres table is **replaced**
  by the CRD (kubectl-native desired-state, no DB migration). The controller is the
  single writer of the 13a element list + the greying ConfigMap, reconciled from the
  CRs. `app.optional-services.reconcile.enabled=false` by default (Noop client +
  writers). Offline-validated: CRD schema (`kubectl --dry-run=client` / kubeconform),
  `kustomize build`, the pure `renderElements`/`renderInstalledServices` transforms +
  the fake-client reconcile composition (JUnit). See the PR for the validated-vs-
  cluster-gated split.
- **hugmesh-generator:** the CRD/RBAC/seed bundle
  (`manifests/optional-services-operator`), its `apps/13d` Application, the
  `ignoreDifferences` keystone on both roots + `apps/16`, and the
  `_opt_render_optionalservice_cr` build seeding.

**🚧 CLUSTER-GATED FOLLOW-UP (cannot be verified without a live cluster):**

- **The cut-over.** Delete the hardcoded `apps/30-akkoma.yaml` /
  `apps/30-tuwunel.yaml` / `apps/30-phpbb.yaml` (+ `apps/38`/`39`/`49-forum-*`) /
  `apps/50-games.yaml` / `apps/52-owncast.yaml` / `apps/53-tube.yaml` /
  `apps/49b-character-studio-ui.yaml` / `apps/{38b,39b}-character-forge-bff-*.yaml` +
  `apps/49c-character-forge-ui.yaml` and let the ApplicationSet own the surviving
  workloads — coordinating the ESO split, route-access rows, stateful-svc scale-to-
  zero, and the `CanonicalSeed.java` gateway floor (§9). THEN set
  `app.optional-services.reconcile.enabled=true` (with the Lease under multi-replica).
  Enabling BEFORE the cut-over double-manages akkoma/tuwunel/phpbb (§7.1).
- **Live keystone verification.** That the fabric8 JSON write lands on the live
  `argoproj.io/v1alpha1 ApplicationSet`, that ArgoCD re-generates/prunes
  `optional-<slug>`, and that `ignoreDifferences` + `RespectIgnoreDifferences=true`
  actually stop selfHeal from reverting the element/ConfigMap writes — all
  offline-unverifiable.

**🔭 NATURAL NEXT WAVE (not in this cut):** a superadmin BFF endpoint
`PUT /bff/superadmin/optional-services/{slug}` (mirroring
`WorkloadSuperadminController`/`GoLiveController` + a step-up gate) that patches the CR
via the fabric8 client admin-bff already holds, and a toggle screen in
`hugmesh-superadmin-service-catalog-ui`. kubectl-first; BFF endpoint + UI later.

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
