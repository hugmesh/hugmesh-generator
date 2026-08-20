# Per-domain identity provider (issue #47 — `Domain.idp`)

Two DIFFERENT "idp" axes exist; do not conflate them:

* **Mesh-level IdP** (`--idp casdoor|entra|aws|oidc`, docs/IDENTITY-PROVIDERS.md,
  Studio page `idp.py`): what identity STACK the mesh node itself runs. Frozen
  argv; unchanged by everything below.
* **Per-domain IdP** (`Domain.idp: superdomain|own`, PR #71, Studio Domains
  table): WHERE one domain's sign-in lives. `superdomain` (default, absent ==
  today's behavior byte-for-byte) rides the mesh's central Casdoor
  (`manifests/casdoor/`); `own` stands up a dedicated Casdoor instance for that
  domain. This document covers `own`.

## The issuer contract (proven by tests/stack/compose.brand-b.yaml)

* issuer / `origin` = the domain's PUBLISHED URL: `https://id.<clusterDomain>`.
* JWKS for in-cluster consumers = the instance's in-network Service URL
  (`http://casdoor-domain.<nsPrefix>-pki.svc.cluster.local:8000` on the single
  mesh; `http://<brand>-casdoor.<nsPrefix>-pki.svc.cluster.local:8000` on a
  tenant tree).
* Gateways/BFFs stay SHARED: an idp=own domain is ONE MORE PAIR in the frozen
  registry names — `APP_TENANCY_ISSUERS += https://id.<domain>=<slug>` and
  `APP_TENANCY_HOSTS += <domain>=<slug>` (extend, never rename — the
  Makefile `STACK_BRAND_B_ENV` spelling). Cross-brand token replay is
  hard-denied by that registry.
* HARD GATE before any BFF takes the registry pair: its `domain='default'`
  row-restamp migration must land first (the in-manifest warning at
  manifests/wiki-bff-api/deployment.yaml — flipping the registry on existing
  data silently hides every row). Gateways can take the pair first.

## Lane 1 — single mesh (ApplicationSet)

`specs/cluster/apps/05b-casdoor-domains.yaml`: a goTemplate list-generator
ApplicationSet (selector `idp=="own"`), template `casdoor-<slug>` at sync-wave
"1" (IdP before consumers — the 06-casdoor-games rule), destination
`<nsPrefix>-pki`, source = the env-parameterized base
`specs/cluster/manifests/casdoor-domain/` with per-domain kustomize patches
(origin/org/host/Vault path/MCS levels). Ships with ZERO elements.

Writers of the element list (the 13a-optional-services single-writer model —
explicitly NOT a git-committing reconciler, docs/OPTIONAL-SERVICES.md §7.1):

* build time — stage4 builders render the KEYS-manifest `domains[]` (with
  `idp`) into the element list at bake (follow-up, beside
  `_opt_render_installed_services`);
* runtime — the admin-bff DomainReconciler (cross-repo, clone of
  OptionalServiceReconciler, ships dark) mirrors the #118 domain-registry rows.

Both roots (`app-of-apps.yaml`, `00-app-of-apps-waved.yaml`) carry the
`casdoor-domains` ignoreDifferences + `RespectIgnoreDifferences` keystone;
without it selfHeal reverts every runtime write.

MCS allocation: every instance needs TWO cluster-unique categories
(`selinuxLevel`, `selinuxLevelPg`) — docs/SECURITY.md §3. The element writer
owns the allocation (deterministic per-slug from a reserved range is the
planned rule; the base's placeholders s0:c85/s0:c86 are never meant to go live
unpatched).

## Lane 2 — tenant set (brand repo)

For federated / full-isolation tenants the SAME instance renders into the brand
GitOps tree instead: `templates/apps/05-casdoor.yaml.hbs` (Application
`{{BRAND}}-casdoor`, project `{{BRAND}}`, sync-wave "1", destination
`{{NS_PREFIX}}-pki`, source = the pushed `<BRAND>-gitops` repo's
`manifests/casdoor` dir on tailnet Forgejo) plus
`templates/manifests/casdoor/*.yaml.hbs` (org `{{CASDOOR_ORG}}`, origin
`https://id.{{CLUSTER_DOMAIN}}`, ESO remoteRef `{{BRAND}}/casdoor`).

`generate-brand-repos.sh` (and its parity twin
`scripts/tooling/render-handlebars.sh`) render those templates ONLY when the
brand profile carries `IDP=own` — the default render is byte-identical to
pre-#47 output. On a live node, `hugmesh-domain-reconcile` synthesizes
`IDP`/`CASDOOR_ORG`/`NS_PREFIX` into the transient brand profile from the #118
DomainEntry (`idp`, `casdoorOrg`, `nsPrefix` fields).

## Secrets (Vault/ESO)

Per-domain path = `secret/<slug>/casdoor` (PHASE5-DECISIONS #3: base segment ==
brand slug), ONE KV document with `db_password_plain`, `admin_password`,
`app_client_secret`. Deliberately NOT minted by `gen-cluster-secrets.sh` (a
per-domain path cannot exist before the domain does): it is written at
domain-creation time by the operator / the DomainReconciler lane, and
`tests/scripts/eso_seed_contract.py` classifies the base's placeholder
(`hugmesh/casdoor-domain`) under `OPERATOR_SEEDED_PATHS`. Until the path is
written the instance's pods stay pending on their Secret mounts — fail-closed,
per-domain, loud.

## Removal runbook (idp flip back / domain deletion)

1. Retire the domain's `APP_TENANCY_ISSUERS`/`APP_TENANCY_HOSTS` pair from the
   gateways (never a registry mapping to a pruned issuer — and never prune a
   live issuer that still has a mapping).
2. Drop the element (or flip its `idp` to `superdomain`) — the selector prunes
   `casdoor-<slug>`; `prune: true` deletes everything except the
   `Prune=false` PVC.
3. MANUAL purges, deliberately not automated: the retained
   `casdoor-domain-pg-data` PVC in `<nsPrefix>-pki`, and the Vault path
   `secret/<slug>/casdoor`.

## Open follow-ups (tracked, not shipped here)

* stage4 `_domains_render_appset_elements()` build-time bake of the element
  list (+ the deterministic MCS allocator).
* admin-bff DomainReconciler (cross-repo) + the #118 DomainEntry `idp` field and
  `appsetRegistered` ack reuse.
* per-domain gateway/BFF registry env threading (build-time + runtime rollout;
  the wiki-bff row-restamp gate above).
* `origin` env-interpolation validation against casbin/casdoor:3.80.0 (the
  documented fallback: ApplicationSet strategic-merge patch of the whole
  app.conf blob).
* kind-local e2e second domain (bootstrap element + seed-vault-kv.sh +
  verify-seeded-identities second-issuer leg).
