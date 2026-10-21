# Per-domain identity provider (issue #47 — `Domain.idp`)

Two DIFFERENT "idp" axes exist. Do not mix them up:

* **Mesh-level IdP** (`--idp casdoor|entra|aws|oidc`, docs/IDENTITY-PROVIDERS.md,
  Studio page `idp.py`): which identity STACK the mesh node itself runs. Its argv is
  frozen, and nothing below changes it.
* **Per-domain IdP** (`Domain.idp: superdomain|own`, PR #71, Studio Domains table):
  WHERE one domain's sign-in lives. `superdomain` (the default; absent means the same,
  byte for byte) uses the mesh's central Casdoor (`manifests/casdoor/`). `own` stands
  up a dedicated Casdoor instance for that domain. This page covers `own`.

## A domain's own EXTERNAL provider (`Domain.idp_settings`, 2026-10-21)

An `own` domain can sign in through its own external provider instead of its own
Casdoor. The row keeps `idp: own` and adds
`idp_settings: {provider, issuer, client_id, jwks}`, with the provider being Entra,
Cognito or OIDC. These follow the same rules as the mesh-level `--idp` (see
docs/IDENTITY-PROVIDERS.md). The JWKS address is derived per provider when it is left
empty.

What changes and what does not:

* **No Casdoor is stood up for it.** The own-Casdoor consumers all ask
  `config.runs_own_casdoor`. These are the compose overlay, its port sequence,
  `own_idp_domains` and `--own-casdoor-domain`.
* **The issuer is still one brand.** The domain's issuer becomes one more
  `<issuer>=<brand id>` pair in `APP_TENANCY_ISSUERS`, and its name one more
  `<domain>=<brand id>` pair in `APP_TENANCY_HOSTS`. These are the same registry
  variables, extended and never renamed. On the local Docker mesh, `LocalStackNode`
  threads the pairs (`LocalMeshBootstrap.external_idp_domains`), and the domain's Tor
  onion opens its own sign-in. The gateways fetch that issuer's keys by OIDC
  discovery, so the provider must be reachable from the stack.
* **An own row never inherits an external mesh provider.** A domain that wants the
  mesh's provider uses `superdomain`. Two brands on one issuer are refused
  (`config.domain_signin_problems`), because `DomainRegistry` maps one issuer to one
  brand.
* **The honest limits are the mesh-level ones.** Native `/bff/login`, MFA step-up and
  role claims stay Casdoor-coupled, so people sign in on the provider's own page. The
  Studio's bring-up warnings say so for each such domain.
* **Cluster lane:** the manifest row carries `idp_settings`. The planned
  `casdoor-domains` element writer must select `idp == "own"` **without** an external
  provider, or it would stand up a Casdoor that nobody uses. That writer is not built
  yet (see Open follow-ups).

## The issuer contract (proven by tests/stack/compose.brand-b.yaml)

* issuer / `origin` = the domain's PUBLISHED URL: `https://id.<clusterDomain>`.
* JWKS for in-cluster consumers = the instance's in-network Service URL
  (`http://casdoor-domain.<nsPrefix>-pki.svc.cluster.local:8000` on the single
  mesh; `http://<brand>-casdoor.<nsPrefix>-pki.svc.cluster.local:8000` on a
  tenant tree).
* Gateways and BFFs stay SHARED. An idp=own domain is ONE MORE PAIR in the frozen
  registry names: `APP_TENANCY_ISSUERS += https://id.<domain>=<slug>` and
  `APP_TENANCY_HOSTS += <domain>=<slug>` (extend, never rename; this is the Makefile
  `STACK_BRAND_B_ENV` spelling). That registry hard-denies cross-brand token replay.
* HARD GATE before any BFF takes the registry pair: its `domain='default'` rows
  must be re-stamped, or the flip silently hides every row. wiki-bff has the re-stamp
  (`RestampTargetEnvironmentPostProcessor`, hugmesh-wiki-bff-api#19): setting
  `APP_TENANCY_ISSUERS` re-stamps on that boot. It is a one-way door; read the
  warning in `manifests/wiki-bff-api/deployment.yaml` first. After that boot, also set
  `SPRING_LIQUIBASE_PARAMETERS_WIKI_RESTAMP_TARGET_DOMAIN=<brand>` and never remove
  it. Without the pin, a later boot with `APP_TENANCY_ISSUERS` removed or grown to a
  second brand (an ArgoCD revert does the first) refuses to start. The pin overrides the derived target: if the two
  variables disagree, wiki-bff does not refuse but silently re-stamps every `default`
  row to the pin's brand. Change them together, in one commit. Check every
  other BFF before it takes a pair. Gateways can take the pair first.

## Lane 1 — single mesh (ApplicationSet)

`specs/cluster/apps/05b-casdoor-domains.yaml` is a goTemplate list-generator
ApplicationSet (selector `idp=="own"`). Its template is `casdoor-<slug>` at
sync-wave "1" (IdP before consumers, the 06-casdoor-games rule), with destination
`<nsPrefix>-pki`. The source is the env-parameterized base
`specs/cluster/manifests/casdoor-domain/` plus per-domain kustomize patches
(origin/org/host/Vault path/MCS levels). It ships with ZERO elements.

Who writes the element list (the 13a-optional-services single-writer model; it is
explicitly NOT a git-committing reconciler, docs/OPTIONAL-SERVICES.md §7.1):

* build time — stage4 builders render the KEYS-manifest `domains[]` (with
  `idp`) into the element list at bake (follow-up, beside
  `_opt_render_installed_services`);
* runtime — planned: an admin-bff `DomainReconciler` (cross-repo, a clone of
  OptionalServiceReconciler, shipping dark) would mirror the #118 domain-registry
  rows. No such class exists on admin-bff `main` (2026-10-07). The registry side
  exists: each signed-export `DomainEntry` carries `idp`, `casdoorOrg`, `nsPrefix`,
  `appsetRegistered` and the MCS pair, and `hugmesh-domain-reconcile` reads `idp`
  as a closed enum (`superdomain|own`).

Both roots (`app-of-apps.yaml`, `00-app-of-apps-waved.yaml`) carry the
`casdoor-domains` ignoreDifferences and the `RespectIgnoreDifferences` keystone.
Without it, selfHeal reverts every runtime write.

MCS allocation: every instance needs TWO cluster-unique categories
(`selinuxLevel`, `selinuxLevelPg`) — docs/SECURITY.md §3. The admin-bff
`domain_registry` writer allocates the pair at insert (`McsCategoryAllocator`;
operator DECISION 29c) under a uniqueness constraint, and exports both values on
the `DomainEntry`. The element writer must carry them into the element. The base's
placeholders s0:c85/s0:c86 are never meant to go live unpatched.

## Lane 2 — tenant set (brand repo)

For federated and full-isolation tenants, the SAME instance renders into the brand
GitOps tree instead: `templates/apps/05-casdoor.yaml.hbs` (Application
`{{BRAND}}-casdoor`, project `{{BRAND}}`, sync-wave "1", destination
`{{NS_PREFIX}}-pki`, source = the pushed `<BRAND>-gitops` repo's
`manifests/casdoor` dir on tailnet Forgejo) plus
`templates/manifests/casdoor/*.yaml.hbs` (org `{{CASDOOR_ORG}}`, origin
`https://id.{{CLUSTER_DOMAIN}}`, ESO remoteRef `{{BRAND}}/casdoor`).

`generate-brand-repos.sh` (and its parity twin
`scripts/tooling/render-handlebars.sh`) render those templates ONLY when the brand
profile carries `IDP=own`. The default render is byte-identical to pre-#47 output. On
a live node, `hugmesh-domain-reconcile` builds `IDP`/`CASDOOR_ORG`/`NS_PREFIX` into
the transient brand profile from the #118 DomainEntry (`idp`, `casdoorOrg`, `nsPrefix`
fields).

## Secrets (Vault/ESO)

The per-domain path is `secret/<slug>/casdoor` (PHASE5-DECISIONS #3: base segment ==
brand slug). It is ONE KV document with `db_password_plain`, `admin_password` and
`app_client_secret`. `gen-cluster-secrets.sh` deliberately does NOT mint it, because
a per-domain path cannot exist before its domain does. The operator writes it when the
domain is created (the planned DomainReconciler would take over this step).
`tests/scripts/eso_seed_contract.py` classifies the base's placeholder
(`hugmesh/casdoor-domain`) under `OPERATOR_SEEDED_PATHS`. Until the path exists, the
instance's pods stay pending on their Secret mounts. That is fail-closed, per-domain
and loud.

## Image CLI: `--domain-idp` (issue #509)

Every stage4 builder (`build-*-stage4.sh`, all ten) takes a repeatable

```
--domain-idp <domain>=own|superdomain
```

* `own` marks the domain as running its own Casdoor; `superdomain` is the explicit
  spelling of the default.
* The vocabulary is the Studio's `DOMAIN_IDP_CHOICES`; `tests/scripts/test-domain-idp-flag.sh`
  pins the two together.
* The domain must be a lowercase DNS name, named once, and may not be the mesh's own
  `--cluster-domain` as `own` (the own domain always uses the superdomain Casdoor,
  the same rule the Studio CLI applies). On x86 client images, where `--domains` is
  meaningful, the name must also be one of the `--domains` elements. The other nine
  builders take no domain list, so they check the name's shape only.
  `--unaffiliated` refuses the flag.
* All ten parse it through `scripts/_domain-idp-lib.sh`, which each builder sources.

What it does: the builders do not write the Studio's `hugmesh-mesh-manifest.json`,
so the choice is recorded in the image, with the manifest's field name, values and
omit-the-default rule, as `/etc/hugmesh/domain-idp`: one `<domain>=own` line per
own-Casdoor domain. The file exists only when at least one domain is `own`, and
`--print-plan` prints `PLAN_DOMAIN_IDP=<own domains>` under the same condition. A
build with no flag, or with only `=superdomain`, is byte-identical to one built
before the flag existed.

Nothing on the image reads `/etc/hugmesh/domain-idp` yet: the build-time writer of
the `casdoor-domains` elements (below) is still open, and this file is the input it
would take.

## Removal runbook (idp flip back / domain deletion)

1. Retire the domain's `APP_TENANCY_ISSUERS`/`APP_TENANCY_HOSTS` pair from the
   gateways (never a registry mapping to a pruned issuer — and never prune a
   live issuer that still has a mapping).
2. Drop the element (or flip its `idp` to `superdomain`) — the selector prunes
   `casdoor-<slug>`; `prune: true` deletes everything except the
   `Prune=false` PVC.
3. MANUAL purges, on purpose not automated: the retained `casdoor-domain-pg-data` PVC
   in `<nsPrefix>-pki`, and the Vault path `secret/<slug>/casdoor`.

## Open follow-ups (tracked, not shipped here)

* stage4 `_domains_render_appset_elements()` build-time bake of the element
  list. The function does not exist yet. The MCS allocator has landed in
  admin-bff.
* admin-bff DomainReconciler (cross-repo). The #118 DomainEntry `idp` field has
  landed; the `appsetRegistered` ack reuse is still open.
* per-domain gateway/BFF registry env threading (build-time + runtime rollout;
  the row-restamp gate above).
* `origin` env-interpolation validation against casbin/casdoor:3.80.0 (the
  documented fallback: ApplicationSet strategic-merge patch of the whole
  app.conf blob).
* kind-local e2e second domain (bootstrap element + seed-vault-kv.sh +
  verify-seeded-identities second-issuer leg).
