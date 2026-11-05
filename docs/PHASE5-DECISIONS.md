# Mesh Repo-Templating — Phase 5 decisions (the FIRST WRITE, tailnet-internal)

Recorded 2026-07-09 (first commit of this file).

Phase 5 makes the rendered tenant repos real on the in-cluster/tailnet Forgejo.
Everything here is tailnet-internal. Nothing is exposed to the internet. Every
secret is out-of-band and never committed.

## Deliverables
- `scripts/publish-tenant-set.sh` — the **publish tail**. Pushes each
  `out/<brand>-<repo>/` render-tenant-set tree to tailnet-internal Forgejo.
  Idempotent, fail-closed, fast-forward-only. Replaces the old GitLab manual echo.
- `templates/apps/13d-brand-repos.yaml.hbs` — the **brand-repo ApplicationSet**
  (the missing "PR7"), cloned from `specs/cluster/apps/13-service-catalog.yaml`
  (Forgejo scmProvider) and parameterized for multi-tenant scoping.
- `specs/cluster/manifests/harbor/harbor-provision-job.yaml.hbs` — the
  **per-tenant Harbor** provisioning template ({{HARBOR_PROJECT}} / {{BRAND}}).
- `scripts/provenance.sh` — **signed provenance** manifest writer/signer/verifier
  (Ed25519); the publish tail emits `.hugmesh-provenance.json` (+ `.sig`) per tree.
- `specs/usr/sbin/hugmesh-domain-reconcile` — the **writeback** (`ack_generation`)
  is now wired into `main()` (enablement-gated behind `DOMAIN_ACK_URL`).

## Decision #1 — ApplicationSet scoping: PER-TENANT FORGEJO ORG (chosen)
`13d-brand-repos.yaml.hbs` uses `scmProvider.gitea.owner: {{ORG}}` — the tenant's
own Forgejo org — so a tenant's discovery can never sweep in another tenant's or the
upstream hugmesh repos. A `^{{BRAND}}-` repositoryMatch stays as belt-and-suspenders.
**The publish tail must push to the same org** (`FORGEJO_ORG={{ORG}}`).
- Rejected alternative: a shared `hugmesh` org with `repositoryMatch: "^<brand>-"`
  only. It is cheaper (one org), but a filter typo or regex slip cross-discovers
  tenants. The per-tenant org is a hard boundary; the filter is a soft one.
- Note: `publish-tenant-set.sh` defaults `FORGEJO_ORG=hugmesh`, which matches the
  existing working appset out of the box for a single-tenant bring-up. For the
  per-tenant model set `FORGEJO_ORG` / `--org` to the tenant org, equal to the 13d
  owner.

## Decision #2 — destination namespace + ArgoCD project: PER-TENANT
`13d` parameterizes `destination.namespace: {{NS_PREFIX}}` (the nsPrefix export field
finally gets a template slot, added to `generate-brand-repos.sh`; it defaults to the
BRAND slug) and `spec.project: {{BRAND}}` (a per-tenant ArgoCD project instead of
`default`) for isolation. The project must already exist; ArgoCD fail-closes
otherwise.

## Decision #3 — Harbor: PER-TENANT PROJECT via template (recommended path taken)
`harbor-provision-job.yaml.hbs` templates the two literals —
`HARBOR_PROJECT={{HARBOR_PROJECT}}` (already a first-class per-brand var) and
`VAULT_KV_BASE={{BRAND}}` (robot secrets land at `secret/{{BRAND}}/harbor-robots`,
the ESO "base segment == brand slug" convention) — plus the ConfigMap/Job names
(`{{BRAND}}-harbor-provision*`). The robots are already project-scoped
(`robot$<project>+pull` / `+push`), so with the project templated they become
per-tenant scoped robots with no logic change.

**Per-tenant multiplies cost and brings back the job's two documented gaps, once per
tenant. These prerequisites are deferred and recorded, not silently assumed:**
1. `cluster-ca` is still not copied into `hugmesh-pki`, so the job skips Vault TLS
   verify (bearer-token-authenticated only). Per tenant this recurs.
2. The Harbor REST shape is pinned to chart 1.16.x — a validate-before-prod scaffold.
3. Per-tenant needs a per-tenant ArgoCD `harbor-provision` Application (03b) name
   and path and, if isolating admin creds, an ESO base path. Both are deferred: the
   shared Harbor-instance `harbor-admin` credential is reused, and only the project,
   robots and Vault base are per-tenant.

**Interim fallback if per-tenant is not activated:** keep the single shared `hugmesh`
project (the non-templated upstream file) and push tenant images under a per-brand
repository prefix inside it. Brands are then not registry-isolated until per-project
lands.

## Forgejo push auth — the house way (out-of-band, never committed)
- Mint a PAT out-of-band from `snapadmin` (or a dedicated `hugmesh-publisher` machine
  user): `forgejo admin user generate-access-token --username snapadmin --scopes
  write:repository,write:organization`. Store it in Vault KV `secret/<brand>/forgejo`
  prop `push_token`.
- Deliver it to the publish tail via `FORGEJO_PUSH_TOKEN` (env) or
  `FORGEJO_PUSH_TOKEN_FILE` (a file path, read first-line-only, never sourced or
  echoed). Fail-closed if unset.
- On the wire: an `Authorization: token <PAT>` HTTP header, delivered so it never
  touches any process command line (argv). **git** uses `GIT_CONFIG_COUNT=1 /
  GIT_CONFIG_KEY_0=http.extraHeader / GIT_CONFIG_VALUE_0=…` (child environ, not argv;
  the equivalent of `-c http.extraHeader` without exposing the value to a co-located
  `ps auxww` / `/proc/<pid>/cmdline`). **curl** uses `-H @<0600 tmpfile>` (the house
  pattern, ported from the removed `scripts/go-live.sh` into
  `specs/usr/lib/hugmesh/go-live-providers.sh`). The PAT is
  therefore never in the remote URL, `.git/config`, the reflog, or any argv (review
  finding #1 fix — the original `-c http.extraHeader=…` form leaked it into git's
  argv). The base URL is configurable (`FORGEJO_BASE_URL`); the default is in-cluster
  service DNS, and off-cluster you set it to the tailnet host.

## Publish target repo name — FULL `<brand>-<repo>` (review finding #3 fix)
The publish tail creates and pushes each tree under its full directory name
`<brand>-<repo>` (`$base`), not the brand-stripped `<repo>`. The 13d brand-repo
ApplicationSet filters `repositoryMatch: "^<BRAND>-"` (and the default shared
`13-service-catalog` filters `"^hugmesh-"`). A repo named `admin-bff-api` would
match neither `^acme-` nor `^hugmesh-`, so ArgoCD would discover zero Applications
and deliverable #2 (auto-discover + sync) would be dead end to end. Pushing as
`acme-admin-bff-api` matches `^acme-`. Provenance still records the logical
`tenant.repo=admin-bff-api` / `tenant.brand=acme`: the Forgejo repo name is a
scoping and discovery concern, and the provenance repo identity is the code
identity.

## Provenance signing key custody — DEFERRED to a live release
Build-host verification signs with a locally generated TEST Ed25519 keypair and
proves tamper-fails. The real production key is out-of-band (key-USB/Vault). Which
identity signs (the generator, or the #118 export signer that chains to the baked
`registry-pub.ed25519`) is a release-time decision. When `PROVENANCE_SIGNING_KEY` is
unset the manifest ships UNSIGNED (with a warning); signing with the real key is
deferred.

## Deferred to a live cluster (cannot be proven build-host-only; not faked)
- Actual push to in-cluster/tailnet Forgejo, and org/repo creation via Forgejo REST.
- ArgoCD ApplicationSet scmProvider discovering and syncing the pushed repos.
- Harbor per-tenant project and scoped robot creation against live Harbor REST, and
  the once-only robot-secret Vault write.
- ESO materializing `forgejo-scm-token` / the push token / `harbor-admin` from Vault.
- admin-bff #118 `/bff/internal/domains/<dom>/reconcile-ack` ingest (endpoint absent).
- Signing provenance with the real out-of-band production key.
- `cluster-ca` copy into `hugmesh-pki` (the Vault TLS verify gap in the harbor job).
