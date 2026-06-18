# HANDOFF — infra finish-list + app-layer resume guide

> ⚠ **SUPERSEDED — historical snapshot (2026-06-06).** Large swaths of the work
> framed below as *PAUSED* / *open PRs to review* / *partial unvalidated
> scaffolds* have since **shipped to `main`**: the mod / user / forum BFFs + UIs,
> `federation-api`, owncast, tube, node-storage, egress-VPN, the games App-Store
> control plane, the notifications in-app MVP, and the superadmin Service Catalog
> (data layer + tailnet gateway + Kaniko builder, PR #110). Treat this document
> as a point-in-time record, **not** the current finish-list. For current state
> see the per-feature docs ([index](README.md)) and `git log`; for what remains
> planned see the Roadmap in [`ARCHITECTURE.md`](ARCHITECTURE.md).

Snapshot of where the snapdragon.systems build stands after the
**image / k8s / networking / security / role** focus pass, and where to pick up
everything else. Dated 2026-06-06.

Audience: whoever continues this. Every "finish-now" item below has a precise
location + recommended fix; items that need a **live cluster** to validate or a
**design decision** are marked so they are not applied blindly.

---

## 0. Naming + branding model (LOCKED — read first)

- **Repos** bake the default `snapdragon` brand: backend APIs = `snapdragon-<thing>-api`,
  role BFFs = `snapdragon-<role>-bff-api` (paired 1:1 with a `snapdragon-<role>-ui`),
  datastores = `<thing>-db` (no `-api`). UIs already follow `snapdragon-<x>-ui`.
- **k8s runtime objects rebrand at build time**: `build-{x86,rpi5}-stage4.sh`
  `rebrand_sysroot()` runs `sed 's|snapdragon-|${BRAND}-|g'` (+ title/domain) over
  the baked tree → `snapdragon-foo` → `fluffypenguin-foo`. So **every app Service
  name MUST be `snapdragon-<thing>-api`** (a bare name won't rebrand). Namespaces
  (`snapdragon-backend` → `<brand>-backend`) give per-brand isolation for the
  short-named datastore/infra services.

## 1. DONE this pass (open PRs — review/merge)

| PR | Repo | What |
|----|------|------|
| #34 | snapdragon-generator | Brand the admin-bff **Service** `admin-bff` → `snapdragon-admin-bff-api` across Service/Deployment/labels/selector/image + fe-gateway `/bff` uri + the **mTLS chain** (ExternalSecret, Vault role `pki_int/issue/snapdragon-admin-bff-api`, CN/alt_names, `pki-init-configmap`, `gen-keystores.sh`). service==mTLS-CN==gateway-uri==PKI-role==keystore==`spring.application.name`, all rebrand together. Casdoor **realm** ids (`svc-admin-bff`, `admin-bff→ROLE_ADMIN_API`) intentionally kept (not DNS). |
| #7 | snapdragon-actions | `@Qualifier` the two `CasdoorClient` beans — fixes a `NoUniqueBeanDefinitionException` that prevented the whole snapdragon-actions pod (two-Casdoor role sync + `/api/registration`) from starting. `./mvnw test` 50/50. |
| #35 | snapdragon-generator | route-access public rows use the `PUBLIC` sentinel, not `ROLE_ANONYMOUS` (the gateway treats only `PUBLIC` as no-JWT; `ROLE_ANONYMOUS` → default-DENY → `/login`, `/.well-known`, `/` 403 for anonymous). |

Earlier-merged this effort: `snapdragon-federation-api` (repo + GitOps deploy), `snapdragon-remote-fragment` (repo + deploy), the org-wide `snapdragon-<thing>-api` rename + reference sweep.

## 2. Invariants CONFIRMED (3-way audit)

- **ROLE_MOD isolation HOLDS** — a MOD cannot reach infra/logs/observability/vault/k8s or any ADMIN-only HTTP surface through any of the 4 layers (Casdoor sibling role w/ no inheritance; route-access seed MOD-scoped to Matrix/Mastodon, `/api/admin/**`=ADMIN-only, default-deny; gateway `INFRA_PATHS`=GAME-MASTER; BFF scoping mod-bff=`/bff/mod/**`, admin-bff=`/bff/admin/**`=ADMIN). No MOD→ADMIN elevation anywhere. Even the stale-fallback fails safe (MOD gets *fewer* surfaces).
- **Two-Casdoor architecture** (systems org `snapdragon` / games org `threewizards`) coherent; one-way `ROLE_GAMES_ADMIN`→games-`admin` sync correct (once PR #7 lets the pod boot).
- **Build / ENV(test|prod) / brand-rebrand** path coherent; **kustomize renders clean** on all manifest dirs.

---

## 3. REMAINING INFRA — finish-now (precise)

### 3.1 admin-bff datastore — `snapdragon-pg` is DANGLING (BLOCKS admin-bff startup) — needs a decision
`snapdragon-admin-bff-api/src/main/resources/application.yml:35,44` default R2DBC **and** Liquibase to `snapdragon-pg.snapdragon-backend.svc.cluster.local:5432/snapdragon` — **no such Service exists** (only `route-access-db` in pki, `federation-db` in backend, casdoor's own pg). The deployment (`manifests/admin-bff-api/deployment.yaml`) overrides only `ROUTE_ACCESS_R2DBC_URL` and sets a **dead** `SPRING_DATASOURCE_URL` (the app reads `spring.r2dbc`/`spring.liquibase`, not `spring.datasource`). → admin-bff fails Liquibase at boot.
- **Recommended fix (A):** create `manifests/admin-bff-db/` (copy `manifests/federation-db/`, rename to `admin-bff-db`, DB/USER `adminbff`) + `apps/NN-admin-bff-db.yaml` (sync-wave before admin-bff) + in the admin-bff deployment set `SPRING_R2DBC_URL`/`SPRING_LIQUIBASE_URL` → `admin-bff-db.snapdragon-backend...` and **delete** the dead `SPRING_DATASOURCE_URL`. Mirrors how federation solved the identical dangling-`snapdragon-pg` default.
- **Alt (B):** point admin-bff at the existing `route-access-db` (`application.yml` says "a single R2DBC handle backs everything incl `gateway_route_access`"). Risk: `gateway_route_access` is created by route-access-db's initdb `schema.sql` **and** would be touched by admin-bff Liquibase — resolve schema ownership first. Prefer (A).

### 3.2 PKI: `vault-token` per-namespace + `vault/cluster-ca` (BLOCKS keystore-enabled gateways) — security
- Each per-service mTLS `VaultDynamicSecret` reads a `vault-token` Secret **in its own namespace** (`manifests/external-secrets/pki-externalsecrets.yaml:36,74,112,150,188`), but `specs/etc/keys-provision/provision.sh:~1035` creates `vault-token` only in the `external-secrets` ns. → the `<svc>-mtls` Secrets never materialize → gateway `build-keystore` initContainers fail → gateways with `keystore.enabled: true` don't start. **Fix:** in `provision.sh` `provision_vault()`, also create `vault-token` in `snapdragon-pki`, `snapdragon-backend`, `snapdragon-frontend` (every ns with a generator).
- `manifests/vault-pki/pki-init-job.yaml:61` mounts `cluster-ca` (cert+key, `optional: true`) but `provision.sh` never creates the `vault/cluster-ca` Secret from the USB CA → Vault **self-generates a DEV root** (`pki-init-configmap.yaml:56-60`), so Vault-issued (gateway) certs do **not** chain to the USB truststore the other Java services trust → mTLS trust fails. **Fix:** in `provision.sh`, create `vault/cluster-ca` (`tls.crt`/`tls.key`) from `certs/cluster-ca.{crt,key}` on the pki USB.

### 3.3 DB passwords from ESO, not git — security
`manifests/federation-db/deployment.yaml:48` + `manifests/federation-api/deployment.yaml:69,76` hardcode the literal `federation`. **Fix:** add a `federation-db-auth` ExternalSecret + Vault key (mirror the casdoor-db ESO pattern in `secretstore.yaml`) and switch both to `secretKeyRef`. Apply the same when creating `admin-bff-db` (3.1).

### 3.4 metrics-server (remote-fragment HPA is inert) — k8s
No metrics-server anywhere → `manifests/remote-fragment/hpa.yaml` can't scale (runs at the `replicas:2` floor). **Fix:** add `apps/NN-metrics-server.yaml` ArgoCD app sourcing the metrics-server Helm chart (`https://kubernetes-sigs.github.io/metrics-server/`) at a low/early wave; on bare-metal add arg `--kubelet-insecure-tls`.

### 3.5 NetworkPolicy activation + gaps — security, NEEDS LIVE VALIDATION
- `apps/08-networkpolicy.yaml` ships **manual** sync — the tier isolation is **inert** until `argocd app sync networkpolicy`. Flip to `automated` **after** validating the flows on a live cluster (blind-applying could block legitimate traffic).
- Add an **observability** NetworkPolicy (none today) — but it must ALLOW trace/metric ingestion from every tier + dashboard ingress; do not blind default-deny (would break uptrace/grafana). Validate live.
- Later hardening: egress default-deny per tier; per-port micro-seg (route-access-db:5432, federation-db:5432 only from their clients).

### 3.6 Gateway issuer-URI mismatch — auth, NEEDS VERIFICATION
Gateway chart `charts/snapdragon-gateway/values.yaml:29` validates JWT against `http://casdoor.snapdragon-pki.svc.cluster.local:8000`, but Casdoor `origin` (`manifests/casdoor/app-conf-configmap.yaml:39`) issues `iss=https://id.snapdragon.systems`. If the gateway image doesn't normalize the issuer, **all gateway JWT validation rejects** → auth dead at the primary ingress. **Verify** with the gateway image; if real, set the gateway `casdoor.issuerUri` to `https://id.snapdragon.systems` (ensure JWKS reachable in-cluster) or confirm in-image normalization.

### 3.7 Smaller, lower-risk
- **mTLS not mounted** on admin-bff-api / federation-api / actions / remote-fragment (certs/roles provisioned but unused → plaintext intra-cluster). Roll the keystore mount across the charts/manifests.
- **casdoor-games github provider** lacks the `REPLACE_WITH_*` skip-guard that `casdoor/init-job.yaml` has (`casdoor-games/init-job.yaml:90-115`) → would seed a broken provider. Add the guard.
- **GAME-MASTER infra-gate role not seeded** — gateway `INFRA_PATHS` requires `hasRole(GAME-MASTER)` but `casdoor/init-data-configmap.yaml` seeds no such role. Decide: seed `GAME-MASTER`, or switch the infra gate to `ROLE_ADMIN`.
- **gateway `CanonicalSeed.java`** (snapdragon-gateway repo) baked fallback is stale vs `schema.sql` (missing federation/_fragments/MOD/games rows); only bites in a dual-DB outage (fails safe). Resync.
- **rebrand seds** miss `snapdragon.games` + the `/snapdragon/` image-registry group (`build-*-stage4.sh`); only affects a non-snapdragon rebrand (self-flagged).
- **wave consistency** (optional): `route-access-db` before the gateways (all wave 0 today).
- **local-path** StorageClass is bootstrap-applied (not GitOps) — drift won't self-heal (by design; document).

### 3.8 New role services — cluster wiring (do when their app code is finished, §4.1)
`snapdragon-mod-bff-api` / `snapdragon-user-bff-api` will each need: a deployment+service (mirror `manifests/admin-bff-api`, **branded** Service name), fe-gateway routes `/bff/mod/**` + `/bff/user/**`, route-access rows (`/bff/mod/**`=ROLE_MOD+ADMIN, `/bff/user/**`=ROLE_USER) in `schema.sql` + `CanonicalSeed`, mTLS identity (gen-keystores + pki role + ESO). No Casdoor client app (resource servers).

---

## 4. PAUSED — app-layer (resume guide; full design in the assistant memory `snapdragon-ui-standard.md`)

### 4.1 Per-role BFF-APIs (code)
`snapdragon-mod-bff-api` + `snapdragon-user-bff-api` repos currently hold **partial, unvalidated** scaffolds (a flaked run left ~9–10 files, "wip"/"first commit"). **Restart clean** from the `snapdragon-admin-bff-api` template: reactive WebFlux+R2DBC+Liquibase+Casdoor-JWT+springdoc+native; each a JWT WebClient client of `snapdragon-federation-api`. user-bff-api adds the **home-guide-dismissed** preference. Scope = the role-scoped moderation/blocking/profile/cards plan in memory. External Matrix(tuwunel)/Mastodon(akkoma) admin calls are stubbed+documented.

### 4.2 Per-role UIs + host shell + federation UX
- `snapdragon-mod-ui` / `snapdragon-user-ui` (paired with their bff-api; `snapdragon-admin-ui` exists).
- **Host shell** (`snapdragon.systems`): authgate → **universal nav** (`Home | Mastodon | Matrix | …profile (+admin/mod)`) → **swappable content outlet** (default = role home remote; Mastodon/Matrix swap to those remotes). Home defaults to a role-tailored **welcome/getting-started guide** (dismiss-once via user-bff-api). Profile + own-component menus + special-area modules (moderation, monitoring, OpenAPI viewer) are **federated modules shipped by the role remote**, not the host.
- **mastodon-ui / matrix-ui role-responsive**: user self-actions→user-bff-api, mod→mod-bff-api, admin→admin-bff-api (conditional on JWT role claims).
- Host manifest-driven `main.ts` (federation manifest from `snapdragon-federation-api` via gateway), `<username>.snapdragon.systems` vanity subdomains + public/internal visibility.

### 4.3 Federation app features
Kill-switch read-path (`federation_override` scope role|user applied to the manifest read), moderation appeal/recommendation chain wiring, unified Matrix/Mastodon blocking, S3/MinIO bundle storage (federation `S3BundleStorage` is a 501 stub), multi-file zip bundle pipeline.

### 4.4 Phase 3b + tests
ng-openapi-gen typed clients + RxJS datastore pattern + OpenAPI→docs/LaTeX/diagrams pipeline (reuse snapdragon.games). Comprehensive role e2e across all roles/features.

---

## 5. Order to resume
1. Merge the open infra PRs (#34, #7, #35).
2. Finish §3.1 (admin-bff-db) + §3.2 (PKI provision) + §3.6 (issuer verify) — these gate a **bootable, authenticating, mTLS** cluster.
3. §3.3–§3.5, §3.7 hardening (validate netpol live).
4. App-layer §4 in the build order above (BFF-APIs → UIs → host shell → federation UX → Phase 3b → e2e), then §3.8 wire the new services.
