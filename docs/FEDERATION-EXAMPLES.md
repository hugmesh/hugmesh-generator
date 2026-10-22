# Federation examples — the module-federation walkthrough

An end-to-end tour of HugMesh **native-federation** using the four runnable
**example codebases** the mesh repo-templating machinery ships as archetypes.
Read [`MESH-TEMPLATING.md`](MESH-TEMPLATING.md) first for the render engine +
guardrails; this doc is the *runtime* side — how a **host shell** discovers and
mounts **remotes** at runtime, and the full surface you touch to add one.

The worked example is a `hello` remote mounted into a host shell, plus the
`remote-fragment` pod that serves published bundles a tenant does not build. All
four example codebases live under `templates/archetypes/<name>/_skeleton/` and
render from their skeleton when the Tier-2 base is unpullable (two-tier
fallback), so you can instantiate the whole trio with no base clone.

---

## 1. The example trio (+ remote-fragment)

| Archetype | Role | Example codebase | Builds with |
|-----------|------|------------------|-------------|
| `spring-bff` | The **API** a remote calls (`GET /api/<slug>/hello`, actuator health, Casdoor OAuth2 resource server) | `templates/archetypes/spring-bff/_skeleton/` | `mvn -o package` |
| `angular-mfe` | A native-federation **REMOTE**: exposes `./routes`, mounted by the host | `templates/archetypes/angular-mfe/_skeleton/` | `npm ci && npm run build` |
| `angular-host` | The native-federation **HOST shell**: the fe-gateway `/**` catch-all; consumes remotes | `templates/archetypes/angular-host/_skeleton/` | `npm ci && npm run build` |
| `remote-fragment` | Runtime **federation-bundle delivery** pod (Spring-Native sync sidecar + static nginx) that serves PUBLISHED remotes a tenant does not build | real base repo (no runnable skeleton) | Maven (base repo) |

Render the trio for a brand (skeleton fallback, no base clones needed):

```
# spring-bff API — app_slug MUST be [a-z0-9]+ (it is the Java package segment
# systems.hugmesh.<app_slug>; package names cannot contain '-')
scripts/render-repo-tree.sh brands/<brand>.conf --enable-repo-tree \
  --archetype spring-bff --repo hello-bff-api --set APP_SLUG=hello --out-dir out

# angular-mfe REMOTE — app_slug = npm segment / ng target / remote name
scripts/render-repo-tree.sh brands/<brand>.conf --enable-repo-tree \
  --archetype angular-mfe --repo hello-ui \
  --set APP_SLUG=hello --set TITLE_WORD=Hello --out-dir out

# angular-host HOST shell — HOST_NAME is derived from BRAND (<brand>-host); the
# static floor + menu wire the one example remote by its app_slug
scripts/render-repo-tree.sh brands/<brand>.conf --enable-repo-tree \
  --archetype angular-host --repo host-shell \
  --set APP_SLUG=hello --set TITLE_WORD=Hello --out-dir out
```

Or drive the whole tenant set from a brand YAML — `brands/example.yaml` carries
commented `installed: false` rows for all four; uncomment and:

```
node scripts/tooling/render-tenant-set.js brands/example.yaml --out-dir out
```

The `remote-fragment` archetype is base-required — the real
`hugmesh-remote-fragment` repo **is** the example codebase (a minimal fake
sync sidecar would be a non-functional lie). Point `REMOTE_FRAGMENT_BASE_DIR` at
a clone to render it; otherwise its `_skeleton/` emits a pointer README.

---

## 2. How the host discovers remotes — dynamic manifest, static floor

The host shell resolves every remote's `remoteEntry.json` **before** Angular
bootstraps (`initFederation` must map `name -> remoteEntry URL` first). The
example host's `src/app/federation/federation-bootstrap.ts` implements the
**dynamic-first, static-floor** contract (carried whole from the
host-shell exemplar):

1. **Dynamic first.** Fetch `GET /api/federation/manifest` (federation-api,
   `federation_modules` table) with `credentials: 'include'` — pre-DI, so it is
   a raw `fetch`, not `HttpClient`. The gateway exchanges the same-origin session
   cookie for the upstream bearer **server-side**, so an authenticated reload
   gets its role/visibility-scoped manifest while a logged-out first load fetches
   anonymously.
2. **Static floor (union, not replace).** On dynamic success, hand
   `initFederation` the **union** `{ ...staticFloor, ...dynamic }` — the baked
   `src/assets/federation.manifest.json` floor first, the DB overlay overriding
   matching slugs and ADDING new ones. A successful DB read is therefore never
   strictly worse than the static build, and the DB can add remotes **without a
   host redeploy**.
3. **Fallback.** On ANY failure — the **401 an anonymous pre-login caller gets**
   from the `authenticated()` endpoint, or network/5xx/parse/empty — return the
   bundled static manifest URL string so the shell **always boots** (never a
   white screen).

Role gating is done by the per-route **guards** (`adminGuard`/`userGuard`/…) +
BFF authz, **not** by manifest presence — so unioning the public entry-URL map is
not an authz weakening. The example host wires its one remote through the
`REMOTE_ROUTES` table in `src/app/app.routes.ts`:

```ts
export const REMOTE_ROUTES: readonly RemoteRouteSpec[] = [
  { path: 'hello', remoteName: 'hello', exposed: './routes', routesConst: 'ROUTES' },
];
```

`remoteName` must match the remote's `federation.config.js` `name`; `exposed`
must match its `exposes` key; `routesConst` must match the exported routes
constant (the skeleton pair is `./routes` → `ROUTES`; fleet remotes use per-repo
consts like `USER_ROUTES`). Renaming either side breaks the mount.

---

## 3. The full registration surface for a new remote (8 places)

Adding a remote to a live mesh touches eight places. The example trio exercises
1–3; 4–8 are the platform integration a real optional service completes.

1. **Repo scaffold.** A new `angular-mfe` repo exposing `./routes` (this
   archetype's example codebase) + its `spring-bff` API. `federation.config.js`
   `name` = the slug; `exposes: { './routes': './src/app/<slug>.routes.ts' }`.

2. **Static floor.** Add the slug → `remoteEntry.json` URL to the host's
   `src/assets/federation.manifest.json` (and the prod split when present) so the
   remote resolves even before the DB row exists.

3. **Host `REMOTE_ROUTES` + guard.** One `REMOTE_ROUTES` row (§2), plus a
   `canActivate` guard when the remote is role-gated (defence-in-depth **above**
   the BFF's own authz, never a substitute).

4. **Menu / launcher cards.** One `NavEntry` in the host menu keyed off the
   capabilities projection (`GET /api/federation/capabilities`, `permitAll`) so
   an uninstalled service renders **greyed with a reason**, never a dead link
   (the example host's `capabilities.stub.ts` is the shape of that service).

5. **`federation_modules` changeset + descriptor + `optional-services.yaml`.**
   The registry row is a **Liquibase changeset in `hugmesh-federation-api`**
   (`src/main/resources/db/changelog/NNN-register-<slug>-module.xml`, appended to
   `db.changelog-master.xml`) — the generator does **not** own the federation DB
   schema. The generator records the metadata in two places instead:
   `specs/cluster/optional-services.yaml`
   (`federationModule: { slug, mountAt, requiresRole, changeset }`) and, for a
   top-level console, a
   `manifests/<slug>/register-<slug>.descriptor.yaml`
   (`kind: FederationModuleRegistration`) that the federation-api wave reads. The
   row's columns: `slug, display_name, kind (remote-shell), remote_entry_url,
   exposed_module (./routes), version, visibility (public|internal), enabled,
   circuit_state, metadata ({requiresRole, mountAt})`.

6. **fe-gateway route with `StripPrefix`.** Each remote is its own nginx pod
   serving `index.html` / `remoteEntry.json` at **its own** webroot, so the
   gateway path must be stripped back to that root or `GET
   /<slug>/remoteEntry.json` forwards literally to a container that only has
   `/remoteEntry.json` and nginx's SPA `try_files` silently serves `index.html`
   (wrong content-type, wrong content — the remote never loads). In
   `specs/cluster/apps/20-gateway-fe.yaml`:

   ```yaml
   - id: hello-ui
     uri: http://hugmesh-hello-ui.hugmesh-frontend.svc.cluster.local:80
     path: /hello/**
     filters:
       - StripPrefix=1     # /social/matrix/** uses StripPrefix=2 (two path segments)
   ```

7. **Route-access rows.** The role floor for the remote's gateway paths lives in
   `gateway_route_access` (`manifests/route-access/initdb/20-schema.sql`): a
   `(gateway=…-fe-gateway, url_pattern=/hello/**, role=ROLE_USER, allow=true)`
   row. The gateway denies unless the caller's Casdoor roles match an `allow`
   rule; a per-brand `domain` scope keeps a brand-Y grant from ever reaching a
   brand-X caller.

8. **k8s + ArgoCD.** The remote's `deploy/` (Deployment/Service/nginx) + its
   catalog descriptor (`hugmesh-deploy.yaml`), discovered by the brand-repo
   ApplicationSet (`13d`) and, for optional services, gated by the
   optional-services operator (`13a`/`13d`) which prunes the whole
   `manifests/<slug>/` dir when the slug is deselected.

---

## 4. How the superadmin wizard + admin-bff drive it

The manual 8-place walk above is what the **superadmin Service Catalog** console
automates. That console is itself a federated remote —
`hugmesh-superadmin-service-catalog-ui` exposing `./ServiceCatalog`,
registered `kind: remote-shell, visibility: internal, requiresRole: SUPERADMIN`
(withheld from the public manifest, reachable only over the tailnet
superadmin-gateway — `apps/22-gateway-superadmin.yaml`).

It calls the admin-bff service-catalog endpoints (`servicecatalog` package):

- `/bff/superadmin/service-store` — the catalog console effector
  (`ServiceCatalogEffectorController`) + curation / deployment / app-profile
  controllers (`ServiceCurationController`, `ServiceDeploymentController`,
  `AppProfileController`).
- **Scaffold + build.** `KanikoBuildLauncher` builds a remote's image from its
  repo (with hard allowlists on `repoUrl`/`path`/`targetRevision`, validated
  before the manifest is parsed).
- **Federate.** `AddServiceEffector` creates the ArgoCD Application that
  registers the descriptor repo (**ships dark**), then the federation-api
  Liquibase row (place 5) enables the slug and the host picks it up on the next
  dynamic-manifest read — no host redeploy (place 2 is the floor).

So the wizard collapses places 1, 5, 6, 7, 8 into one console action; the host's
dynamic-first resolution (§2) makes the newly-enabled remote appear at runtime,
and the capabilities projection (place 4) flips the menu entry from greyed to
live.

---

## 5. ⚠ Version-skew warning

The federation share surface is `singleton: true, strictVersion: true,
requiredVersion: 'auto'` (`federation-base.js`, one source of truth for host +
remotes). **Every remote's Angular major MUST match the host's**, or the shared
singleton fails to wire at runtime (`"shared is not a function"` / a hard mount
failure — exactly the skew the `hugmesh-host-shell` host notes against its
older-major remotes). The example codebases all pin the **same Angular majors as
`hugmesh-user-ui`** (`^22`) for this reason.

When bumping Angular majors, bump **host-first, remotes in the same wave**; a
remote built a major ahead of (or behind) the host will not mount. This is why
the archetype `_identity.env` drift oracle + the shared `federation-base.js`
class-A file exist: the federation contract is asserted byte-identical across the
class so a silent per-remote drift can't slip a mismatched share surface into one
bundle.
