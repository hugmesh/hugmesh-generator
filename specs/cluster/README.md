# HugMesh cluster GitOps payload

This tree is baked into every image at `/var/lib/hugmesh/cluster`. Everything
sits **behind hugmesh.net** via the per-namespace Spring Cloud Gateways.

## What the device syncs

**Read this before changing anything in `apps/`.** This section replaces the
claim that used to sit here — "the single source of truth ArgoCD syncs from" —
which was **false for `apps/`** until 2026-08-26, and false in the direction that
mattered.

`bootstrap/bootstrap.sh` used to apply exactly one Application,
`app-of-apps.yaml`, whose source is `repoURL: …/hugmesh-generator.git`,
`targetRevision: main`, `path: specs/cluster/apps`, `directory.recurse: true`.
So ArgoCD instantiated **`specs/cluster/apps` as it exists on GitHub `main`** and
never read the baked tree at all. Every build-time gate that edits `apps/` —
`gate_optional_services()` and `gate_env_apps()` in `build-rpi5-stage4.sh` /
`build-x86-host-stage4.sh` — was therefore **inert on a real device**: an image
built with `--optional-services akkoma` still received tuwunel, phpbb, games,
owncast and tube.

What is true now, and exactly how far it goes:

| Layer | Source on a real device | Gated at build time? |
|---|---|---|
| `apps/*.yaml` (the **Application set**) | the **baked tree**, `kubectl apply`d one file at a time by `bootstrap/bootstrap.sh` | **yes** — a pruned file is never applied, and in-file edits (dropped gateway routes/extraHosts, baked domains) are the bytes that reach the cluster |
| `manifests/<dir>/**` (each Application's **content**) | still the **git repo**, fetched by ArgoCD from each Application's own `repoURL`/`path` | **no** — a baked edit under `manifests/` (installed-services ConfigMap, `seed-optionalservices.yaml`, route-access SQL) still does **not** reach the cluster |
| `charts/`, `namespaces/`, `manifests/local-path` | applied directly by `bootstrap.sh` from the baked tree | n/a |

Closing the second row needs a **pruned source**, not another apply: an
in-cluster read-only git server over the baked tree, the shape
`bootstrap/kind-local/gitops-repo-server.yaml` already implements for kind. That
is deliberately **not** done here — on a device it adds a network dependency
(`apk add git-daemon` at pod start) to an offline-first mesh.

Consequences of applying `apps/` directly, taken deliberately:

* **No app-of-apps prune.** A file removed in a later image is not retro-deleted
  from a running cluster. Within one image the baked tree is immutable, so there
  is nothing to prune; across images the operator re-provisions.
* **No app-of-apps selfHeal of the Application objects.** Every child Application
  keeps its own `syncPolicy.automated {prune, selfHeal}`, so all **workloads**
  still self-heal; only the Application object stops being re-asserted.
  **The re-assert path is OPERATOR-INITIATED, not automatic** — corrected
  2026-08-26 after review; the sentence that used to sit here ("`bootstrap.sh` is
  idempotent and `keys-provision` re-runs it") described a loop that does not
  exist. `bootstrap.sh` is idempotent, but its **only** caller in this tree is
  `provision_hugmesh()` in `specs/etc/keys-provision/provision.sh`, and
  `keys-provision`'s `main()` short-circuits on the `/var/lib/keys-provision/done`
  marker: after first boot it re-runs **only** with the KEYS USB inserted **and**
  `.provision-force` on that media (or `KEYS_FORCE=1`). There is no timer, no
  periodic unit, and no boot-time re-run. **Residual exposure, stated plainly:**
  an Application OBJECT deleted or edited on a live cluster (`kubectl delete
  application akkoma`, a hand-edit of its spec) **stays that way** until an
  operator re-provisions from the KEYS USB. The workloads under a *surviving*
  Application still self-heal; a *deleted* Application does not come back. If
  continuous re-assert is wanted, the cheap shape is an OpenRC oneshot/timer that
  re-runs `bootstrap.sh` — deliberately **not** done here, and a separate unit.
* **No cross-Application sync-wave ordering** (ArgoCD enforces waves only among
  children of a common parent). Every hook Job here is idempotent/retrying, so
  the set converges in a few reconcile loops — the same trade
  `bootstrap/kind-local/bootstrap-kind.sh` documents for its curated subset.
* The root's `ignoreDifferences` keystone (the admin-bff
  `OptionalServiceReconciler`'s single-writer claim on the `optional-services`
  ApplicationSet element list) becomes **moot** rather than lost: with no root
  selfHealing `apps/13a-optional-services.yaml`, nothing reverts the runtime write.

`HUGMESH_GITOPS_ROOT_RECURSE=1` restores the old repo-recursing root for a
cluster that genuinely wants to track a git branch. It prints, out loud, that it
ignores every build-time prune.

`apps/00-app-of-apps-waved.yaml` is the **alternative** waved/hook-gated root and
carries the same repo-recursing source, so `bootstrap.sh` skips it by name when
applying the baked set — point a bootstrap at it deliberately, never as a
rider.

Guarded by `tests/cluster/test-bootstrap-applies-baked-apps.sh`, which drives the
real `bootstrap.sh` under a stub `kubectl` and asserts on the **resolved source**
of everything applied. A test that merely asserts the pruned sysroot lacks
`30-tuwunel.yaml` would have been green through this whole bug.

## Build ENV: test (LAN) vs prod (public)

Images are baked for one of two environments (`--env test|prod`, default
**test**; written to `/etc/hugmesh/env`):

- **test** (LAN-first, default — `make local` / `brands/local.conf` =
  `hugmesh.test`): an in-cluster **wildcard DNS** resolver (`apps/09-lan-dns.yaml`
  + `manifests/lan-dns`) answers `*.<domain>` for LAN clients, so a browser or
  the e2e runner resolves `id.`/`api.`/`matrix.`/`mastodon.`/apex to the backend
  ingress node — **no public internet, Cloudflare, OAuth, or SMTP required**.
  Point your router/clients' DNS at the backend node once; see
  [`docs/LOCAL-TESTING.md`](../../docs/LOCAL-TESTING.md).
- **prod**: bakes the real public domain. A **Cloudflare Tunnel**
  (`apps/12-cloudflared.yaml` + `manifests/cloudflared`) maps the public names to
  the gateways, with creds read-if-present from the keys USB. The LAN wildcard-DNS
  app is pruned (public DNS is authoritative).

The builders prune the ENV-irrelevant app from the baked tree (test prunes
cloudflared; prod prunes lan-dns), so ArgoCD only ever sees the right one.
Internal cluster-CA TLS (Vault-PKI) is the default issuer in **both** envs; prod
merely **adds** Cloudflare/ACME on top.

## Topology

| Namespace | Runs on | Front door | Contents |
|---|---|---|---|
| `hugmesh-pki` | pki Pi (control-plane) | `hugmesh-pki-gateway` (`id.hugmesh.net`) | Casdoor (Google + admin login), Cassandra, headscale/auth |
| `hugmesh-backend` | backend Pis | `hugmesh-be-gateway` (`api.` / `matrix.` / `mastodon.`) | tuwunel (Matrix), Akkoma (fediverse), Spring APIs (incl. `hugmesh-federation-api` module-federation registry at `/api/federation/**`), DBs |
| `hugmesh-frontend` | frontend Pis | `hugmesh-fe-gateway` (`hugmesh.net`) | hugmesh.net Angular host + social-ui micro-frontends + remote-fragment fleet (DB-hosted federation fragment bundles at `/_fragments/**`) |
| `hugmesh-games` | x86_64 GPU worker | (internal) | hugmesh.games (Mesa/Vulkan via `/dev/dri`) |
| `argocd` | x86_64 worker | (internal) | ArgoCD GitOps engine |

The Kubernetes control plane is the **pki Pi**; the x86_64 host joins as a GPU
worker and is where ArgoCD + games are scheduled (via node labels).

## The gateway pattern (`charts/hugmesh-gateway`)

One Helm chart, deployed three times. Each release runs the same
`hugmesh/gateway` image differentiated by `SPRING_APPLICATION_NAME`
(`hugmesh-pki/be/fe-gateway`), validates the **internal Casdoor JWT**, and
appends `External-*` identity headers to downstream requests. Public paths
(`/api/auth`, `/api/login`, `/api/registration`) allow Google-federated sign-up;
everything else requires authentication. The gateway exposes **no external
login UI** — login is internal to Casdoor. Routes per release are rendered into
an `application-routes.yml` ConfigMap and loaded via
`SPRING_CONFIG_ADDITIONAL_LOCATION`.

## Vanity subdomains (`<username>.hugmesh.net`)

A user serves their **public** profile at `https://<username>.hugmesh.net`.
End-to-end the request path is:

```
<username>.hugmesh.net
   │  wildcard DNS  (manifests/lan-dns answers the whole brand zone in test;
   │                 Cloudflare wildcard + manifests/cloudflared in prod)
   ▼
backend ingress  (ingress-nginx)
   │  admitted because apps/20-gateway-fe.yaml ingress.extraHosts includes
   │  "*.hugmesh.net"
   ▼
hugmesh-fe-gateway   (charts/hugmesh-gateway, fe release)
   │  Host=*.hugmesh.net route (apps/20-gateway-fe.yaml, id: vanity-subdomain)
   │  SetPath=/api/federation/vanity, Host header preserved, forwarded DIRECT to
   │  federation-api (NOT via be-gateway — see "direct hop" below)
   ▼
hugmesh-federation-api   (GET /api/federation/vanity, public read / permitAll)
   resolves the username (= first DNS label of the preserved Host) to the user's
   PUBLIC profile-fragment descriptor (slug profile-<username>, kind=fragment,
   visibility=public) — or 404 if no such public fragment exists.
```

### Routing precedence (the load-bearing detail)

Spring Cloud Gateway matches routes **first-in-declared-order**, so ordering in
`apps/20-gateway-fe.yaml` is the whole game:

1. **Reserved service subdomains** (`id. api. matrix. mastodon. scale.
   headscale.`) are fronted by the **be-gateway**/pki-gateway ingresses +
   cloudflared and **never reach the fe-gateway**, so the wildcard route cannot
   capture them. The cloudflared `*.<domain>` rule in `manifests/cloudflared` is
   likewise ordered **after** the explicit reserved hostnames (cloudflared is
   first-match-top-down) and **before** the 404 catch-all. Defence-in-depth:
   federation-api's `VanityController` also refuses those reserved first-labels.
2. **The apex** `hugmesh.net` is **not** matched by `Host=*.<domain>` (the
   `*` requires ≥1 label), so it falls through to the `frontend-host` `Path=/**`
   catch-all (the Angular host front page).
3. **`<username>.<domain>`** matches the `vanity-subdomain` route, which is
   declared **after** the apex/path routes and **before** `frontend-host`, so a
   vanity host with no special path resolves to the profile instead of the front
   page.

**Username extraction:** the gateway does **not** parse the username. It preserves
the `Host` header and `SetPath`s to `/api/federation/vanity` (no `{username}`),
and federation-api's `VanityController.resolveByHost` takes the **first DNS label**
of the `Host` header as the username. (The canonical, tested contract is the path
form `GET /api/federation/vanity/{username}`; the host form rides on it.)

**Direct hop (no be-gateway):** the resolve is a **public read** — it *is* the
public profile, no JWT — and federation-api `permitAll`s `GET
/api/federation/vanity/**`. Routing via the be-gateway would interpose its auth
chain and 401 the anonymous request, so the wildcard route targets
`hugmesh-federation-api` directly.

### Cross-service flow: PUBLISH → RESOLVE → SERVE

This generator pass wires the **RESOLVE + routing** half. The full lifecycle and
its honest deferrals:

| Stage | What happens | Status |
|---|---|---|
| **Opt-in / source of truth** | A user sets `user_profile.visibility=public` + `vanity_subdomain_enabled=true` in **user-bff-api**. These two flags are the upstream gate that *governs whether the profile is published public*. | Exists (user-bff-api). |
| **PUBLISH** | On that save, user-bff-api must (1) publish the profile-fragment bundle and (2) upsert a **federation_modules** row `slug=profile-<username>, kind=fragment, owner_user_id=<username>, visibility=public, content_hash=…` in federation-api. The federation manifest + the vanity resolve read **only** from `federation_modules`. | **DEFERRED.** `ProfileService.save` persists the flags but makes **no** federation call; `FederationApiClient.PUT /api/federation/bundles/{slug}` writes only a `user_modules` row, not a `federation_modules` row (that registration is currently ROLE_ADMIN via `ModuleRegistryController`). Recommended follow-up: an **owner-scoped self-publish** endpoint in federation (e.g. owner-gated `PUT /api/federation/vanity/{username}`) rather than widening admin CRUD. Documented in the federation-api README. |
| **RESOLVE** | fe-gateway `Host=*.<domain>` route → federation-api `GET /api/federation/vanity` returns the public fragment descriptor (`slug`, `remoteEntryUrl`, `exposedModule`, `contentHash`, the `/_fragments/<slug>/<hash>/` static path) iff `visibility=public` (+ enabled + circuit closed); else 404. **Public-only is double-enforced** (DB finder filters `visibility=public`, and the service re-asserts), so an internal/disabled/kill-switched fragment can never leak. | **Implemented this pass** (federation-api PR) + the routing here. |
| **SERVE** | The `hugmesh-remote-fragment` fleet (apps/41-remote-fragment.yaml) already syncs every `kind=fragment` module in the manifest to `/_fragments/<slug>/<contentHash>/` and nginx-serves it; the fe-gateway already routes `/_fragments/**`. So the fragment bytes are served **once its `federation_modules` row exists** (i.e. once PUBLISH runs). | Substrate **exists**; the vanity **host shell page** (the Angular shell that `loadRemoteModule`s the fragment's `remoteEntry.json` and renders the profile under the bare vanity host) is a **frontend follow-up**, not built this pass. |

### Gate: source of truth

- **user-bff-api** (`visibility=public` + `vanity_subdomain_enabled=true`) is the
  **upstream** gate — it decides whether the profile gets published as a public
  `federation_modules` row.
- **federation-api** is the **last-line** gate — it serves the resolve **only**
  when `federation_modules.visibility='public'` (never internal). Both gates must
  agree; federation is public-only by construction.

### Honest cross-service deferral — shared gateway `PUBLIC_PATHS` (a THIRD repo)

The shared gateway image (`hugmesh-gateway` repo) ends every security chain
with `anyExchange().authenticated()` and permits only a hardcoded `PUBLIC_PATHS`
allowlist (`/api/auth`, `/api/registration`, `/api/login`, the
login/registration/banned remotes). `/api/federation/vanity/**` is **not** in it,
so the fe-gateway pod would itself **401** the anonymous vanity request before
proxying. **To make the public vanity host actually reachable,
`/api/federation/vanity/**` (or a `Host=*.<domain>` public rule) must be added to
the gateway `PUBLIC_PATHS` in the `hugmesh-gateway` repo** — out of scope for
this generator/federation-api pass, documented as a deferral here, inline in
`apps/20-gateway-fe.yaml`, and in the federation-api README. The generator side
(wildcard DNS already in place, fe-gateway ingress wildcard host, the ordered
`Host=*.<domain>` route to federation-api, the cloudflared wildcard rule) is
complete and renders clean.

## AI-cloak / media poisoning (`manifests/media-poisoner`, OPTIONAL x86/GPU)

`hugmesh-media-poisoner` is the **optional** x86/GPU heavy-tier worker that
applies an AI-cloak / poison perturbation to image bytes **before** the homeserver
ingests them (*poison-before-ingest*). It is the compute half of the design; the
policy decision, the round-trip survival gate, and all honest UI copy live in
`hugmesh-user-bff-api`. The worker source skeleton (a small FastAPI service +
Dockerfile) ships under `manifests/media-poisoner/worker/`.

* **Flow.** The UI uploads to the BFF media-proxy (`/bff/user/media/upload`), not
  direct-to-homeserver. The BFF holds the bytes, calls the worker
  (`POST /poison`), then does the **real** homeserver upload of the poisoned bytes
  via the existing `akkoma-proxy` / `tuwunel-proxy` mTLS proxies. The worker
  **never** mounts the homeserver RWO PVCs (`akkoma-uploads` / `tuwunel-data` are
  `ReadWriteOnce`, already mounted by the homeserver pod) — it is pure
  byte-in/byte-out.
* **Scheduling.** Clones the `hugmesh-games` contract verbatim
  (`nodeSelector` `kubernetes.io/arch: amd64` + `hugmesh.net/compute: gpu`,
  vendor-agnostic GPU via the `/dev/dri` hostPath). The ArgoCD app
  (`apps/51-media-poisoner.yaml`) is **MANUAL** (no `automated:` block) so an
  operator opts in only on a GPU-equipped cluster.
* **Lean fallback.** On a Pi5-only cluster the pod stays `Pending`, its
  `ClusterIP:8080` Service has **no Ready endpoints**, and the BFF's `/health`
  capability probe reports the heavy tier **absent** → `MEDIA_POISONING_FALLBACK_MODE`
  (default `warn_before_post`). Pure k8s protocol-probe availability — no
  Eureka/Config/Task. The `MEDIA_POISONING_*` env on the user-bff-api Deployment
  points at the worker Service and ships **disabled** (`MEDIA_POISONING_ENABLED=false`)
  until the BFF media-proxy is verified end-to-end.
* **Honesty + license.** Best-effort training-set hygiene, **not** a guarantee
  (removable by re-encode/downscale; already-federated copies and personal-client
  uploads are uncloseable). The shipped backend is a lean CPU perturbation; the GPU
  path uses the **open PyTorch reference** (PGD vs the Stable-Diffusion VAE/encoder),
  **never** the non-commercial SAND Lab Glaze/Nightshade binaries. The full
  Glaze/Nightshade integration is a documented follow-up in
  `manifests/media-poisoner/worker/README.md`.

## Layout

```
cluster/
├── app-of-apps.yaml        root ArgoCD Application (recurses apps/)
├── apps/                   one ArgoCD Application per workload
├── charts/hugmesh-gateway/   the gateway Helm chart (pki/be/fe)
├── manifests/              in-repo kustomize manifests (casdoor, apis, frontend, social-ui, games, media-poisoner)
├── namespaces/namespaces.yaml
└── bootstrap/bootstrap.sh  installs ArgoCD + applies the root app
```

## Bootstrapping

Automatic on the pki node when `provision.json` has
`hugmesh.gitops.enabled=true` **and** `kubernetes.bootstrap=true` (so the
control plane exists first). Otherwise run by hand after `kubeadm init`:

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf \
     /var/lib/hugmesh/cluster/bootstrap/bootstrap.sh
```

Point ArgoCD at your own GitOps fork by exporting `HUGMESH_GITOPS_REPO` /
`HUGMESH_GITOPS_REV` before bootstrapping (the per-app `repoURL`s in
`apps/*.yaml` should then be edited to match).

## Secrets (Vault + USB)

Secrets are **not** committed here. They are generated by
[`scripts/gen-cluster-secrets.sh`](../../scripts/gen-cluster-secrets.sh) and
pushed to **HashiCorp Vault** (KV v2, mount `secret/`, base path `hugmesh/` —
the base segment is the brand slug). The **External Secrets Operator**
materializes the k8s Secrets the workloads already reference, via a
ClusterSecretStore **`hugmesh-vault`** (provider `vault`, token auth from the
`vault-token` Secret in `external-secrets`) and one ExternalSecret each
(refresh `1h`):

| Vault path (`secret/<brand>/…`) | → k8s Secret | Namespace |
|---|---|---|
| `casdoor` (`google_client_id`/`google_client_secret`) | `casdoor-google` (`clientId`/`clientSecret`) | `hugmesh-pki` |
| `casdoor` (`db_password_plain`) | `casdoor-db` (`username`=`casdoor`/`password`) | `hugmesh-pki` |
| `clickhouse` (`password`) | `clickhouse-auth` (`password`) | `hugmesh-backend`, `observability` |
| `uptrace` (`pg_password`/`project_token`) | `uptrace-auth` (`pg-password`/`project-token`) | `observability` |
| `harbor-robots` (`pull_name`/`pull_secret`) | `harbor-registry` (`.dockerconfigjson`) | `hugmesh-backend`, `hugmesh-frontend`, `hugmesh-games` |
| `harbor-robots` (`pull_name`/`pull_secret`) | `hugmesh-registry-pull` (`.dockerconfigjson`) — same cred, **different Secret name**: the Harbor chart is released into this namespace and already owns `harbor-registry` (its own `REGISTRY_HTTP_SECRET`, template `registry/registry-secret.yaml`) | `hugmesh-pki` |
| `harbor-robots` (`push_name`/`push_secret`) | `image-builder-registry` (`.dockerconfigjson`, **push**) | `hugmesh-image-builds` (opt-in) |
| `casdoor-apps` (`fragment-sync`) | `fragment-sync-casdoor` (`clientId`=`app-fragment-sync`/`clientSecret`) | `hugmesh-frontend` |

The same materialized Secrets are also written to the KEYS stick at
`vault/secrets.json` (with `vault/token` for online sync), so `keys-provision`
can create them offline — **Vault first, USB fallback** — when Vault is
unreachable. The workload manifests keep their existing `secretKeyRef` usage
unchanged.

## Notes / TODO before production

- First-party images now pull from the in-cluster **Harbor** registry (see
  `apps/03a-harbor.yaml`; GitLab's own bundled registry no longer serves this)
  (`registry.hugmesh.net/hugmesh/<repo>:main`, set per app via kustomize
  `images:`) with the ESO-materialized `harbor-registry` imagePullSecret (renamed
  from `gitlab-registry`). This is now AUTOMATED, not an operator-pasted token: the
  `harbor-provision` PostSync Job (`apps/03b-harbor-provision.yaml` +
  `manifests/harbor/harbor-provision-job.yaml`) creates the Harbor project and a
  project-scoped **pull-only** robot account via Harbor's REST API and writes its
  one-time-revealed secret to Vault `hugmesh/harbor-robots`
  (`pull_name`/`pull_secret`) — Harbor never lets you re-read a robot secret once
  minted, so that Job captures it immediately. That Job **owns**
  `hugmesh/harbor-robots`: `scripts/gen-cluster-secrets.sh` does not write the
  path at all by default (a `vault kv put` REPLACES the KV-v2 document, and the
  Job skips on Harbor state, so a clobber there is permanent and silent — it
  shipped, and every imagePullSecret carried a dead token). `GITLAB_REGISTRY_TOKEN`
  remains only as a manual-override escape hatch for local/offline testing, and
  it now `kv patch`es in just the half it was given. Guarded by
  `tests/scripts/test-harbor-robots-ownership.sh`. Any app without a source repo
  yet stays `:dev` until built.
- The always-on in-cluster Kaniko build pipeline (`manifests/image-builder`, synced by
  `apps/60-image-builder.yaml`) PUSHES with a SEPARATE
  credential: the SAME `harbor-provision` Job also mints a project-scoped
  **push-only** robot account and writes it to Vault `hugmesh/harbor-robots`
  (`push_name`/`push_secret`). ESO materializes it as the `image-builder-registry`
  `.dockerconfigjson` the Kaniko Job mounts. It is distinct from the pull-scoped
  robot account above so the runtime pull secret can never push.
- Casdoor uses an `emptyDir` and the all-in-one image — switch to a PVC + an
  external DB, and seed the Google provider (`casdoor-google` Secret) + the
  gateway OAuth2 client.
- Cassandra references an upstream chart; Akkoma + tuwunel are raw manifests
  (no official charts) — pin image tags and supply DB/secret values.
- `hugmesh-federation-api` (the module-federation registry / manifest + bundles API
  upstream of `admin-bff` and the `remote-fragment` sync fleet) stores fragment
  bundle bytes on a **filesystem RWO PVC** (`federation-bundles`, 5Gi), so it runs
  **single-replica** with `strategy: Recreate`. PRODUCTION: set
  `APP_BUNDLES_STORAGE=s3` + the `APP_BUNDLES_S3_*` env (MinIO/S3) and drop the PVC
  to run multi-replica; the `remote-fragment` fleet is already the scalable serving
  layer. Its DB (`federation-db`, Postgres in `hugmesh-backend`) uses the same
  DEV placeholder password as `route-access-db` — move it to a Vault/ESO
  `federation-db-auth` Secret + `secretKeyRef` for production.
- Secrets are never committed here — they flow from Vault via ESO (or the USB
  KEYS fallback); see **Secrets (Vault + USB)** above.
