# Mesh Repo-Templating — Phase 5 decisions (the FIRST WRITE, tailnet-internal)

Phase 5 makes the rendered tenant repos real on the in-cluster/tailnet Forgejo.
Everything here is TAILNET-INTERNAL; nothing is internet-exposed; every secret is
out-of-band and never committed.

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
  (Ed25519); the publish tail emits `.snapdragon-provenance.json` (+ `.sig`) per tree.
- `specs/usr/sbin/hugmesh-domain-reconcile` — the **writeback** (`ack_generation`)
  is now wired into `main()` (enablement-gated behind `DOMAIN_ACK_URL`).

## Decision #1 — ApplicationSet scoping: PER-TENANT FORGEJO ORG (chosen)
`13d-brand-repos.yaml.hbs` uses `scmProvider.gitea.owner: {{ORG}}` — the tenant's
OWN Forgejo org — so a tenant's discovery can never sweep in another tenant's or
the upstream Snapdragon-Systems repos. A `^{{BRAND}}-` repositoryMatch is kept as
belt-and-suspenders. **The publish tail MUST push to the same org** (`FORGEJO_ORG={{ORG}}`).
- Rejected alternative: shared `Snapdragon-Systems` org + `repositoryMatch: "^<brand>-"`
  only. Cheaper (one org) but a filter typo/regex slip cross-discovers tenants; the
  per-tenant org is a hard boundary, the filter a soft one.
- NOTE: `publish-tenant-set.sh` defaults `FORGEJO_ORG=Snapdragon-Systems` (matches the
  existing working appset out of the box for a single-tenant bring-up). For the
  per-tenant model set `FORGEJO_ORG` / `--org` to the tenant org == the 13d owner.

## Decision #2 — destination namespace + ArgoCD project: PER-TENANT
`13d` parameterizes `destination.namespace: {{NS_PREFIX}}` (the nsPrefix export field
finally gets a template slot — added to `generate-brand-repos.sh`, defaults to the
BRAND slug) and `spec.project: {{BRAND}}` (per-tenant ArgoCD project instead of
`default`) for isolation. The project must pre-exist (ArgoCD fail-closes otherwise).

## Decision #3 — Harbor: PER-TENANT PROJECT via template (recommended path taken)
`harbor-provision-job.yaml.hbs` templates the two literals — `HARBOR_PROJECT={{HARBOR_PROJECT}}`
(already a first-class per-brand var) and `VAULT_KV_BASE={{BRAND}}` (robot secrets land at
`secret/{{BRAND}}/harbor-robots`, ESO "base segment == brand slug" convention) — plus the
ConfigMap/Job names (`{{BRAND}}-harbor-provision*`). The robots are already project-scoped
(`robot$<project>+pull`/`+push`), so with the project templated they auto-become per-tenant
scoped robots — no logic change.

**Per-tenant multiplies cost and RE-INCURS the job's two documented gaps PER TENANT —
DEFERRED prerequisites (recorded, not silently assumed):**
1. `cluster-ca` is still NOT copied into `hugmesh-pki`, so the job skips Vault TLS
   verify (bearer-token-authenticated only). Per tenant this recurs.
2. The Harbor REST shape is pinned to chart 1.16.x — a validate-before-prod scaffold.
3. Per-tenant needs a per-tenant ArgoCD `harbor-provision` Application (03b) name/path
   and, if isolating admin creds, ESO base path — those are DEFERRED (the shared
   Harbor-instance `harbor-admin` credential is reused; only PROJECT+robots+Vault base
   are per-tenant).

**Interim fallback if per-tenant is not activated:** keep the single shared `hugmesh`
project (the non-templated upstream file) and push tenant images under a per-brand
REPOSITORY PREFIX inside it — brands are then NOT registry-isolated until per-project lands.

## Forgejo push auth — the house way (out-of-band, never committed)
- Mint a PAT out-of-band from `snapadmin` (or a dedicated `hugmesh-publisher` machine
  user): `forgejo admin user generate-access-token --username snapadmin --scopes
  write:repository,write:organization`. Store in Vault KV `secret/<brand>/forgejo` prop
  `push_token`.
- Deliver to the publish tail via `FORGEJO_PUSH_TOKEN` (env) or `FORGEJO_PUSH_TOKEN_FILE`
  (a file path, read first-line-only, never sourced/echoed). Fail-closed if unset.
- On the wire: an `Authorization: token <PAT>` HTTP header delivered so it never
  touches any process command line (argv) — **git** via `GIT_CONFIG_COUNT=1 /
  GIT_CONFIG_KEY_0=http.extraHeader / GIT_CONFIG_VALUE_0=…` (child environ, not
  argv; the equivalent of `-c http.extraHeader` without exposing the value to a
  co-located `ps auxww` / `/proc/<pid>/cmdline`), **curl** via `-H @<0600 tmpfile>`
  (the house pattern from `scripts/go-live.sh`). The PAT is therefore never in the
  remote URL, `.git/config`, the reflog, or any argv (review finding #1 fix — the
  original `-c http.extraHeader=…` form leaked it into git's argv). Base URL
  configurable (`FORGEJO_BASE_URL`); default in-cluster svc DNS, set to the tailnet
  host off-cluster.

## Publish target repo name — FULL `<brand>-<repo>` (review finding #3 fix)
The publish tail creates/pushes each tree under its FULL directory name
`<brand>-<repo>` (`$base`), NOT the brand-stripped `<repo>`. The 13d brand-repo
ApplicationSet filters `repositoryMatch: "^<BRAND>-"` (and the default shared
`13-service-catalog` filters `"^hugmesh-"`); a repo named `admin-bff-api` would
match neither `^acme-` nor `^hugmesh-`, so ArgoCD would discover ZERO
Applications and deliverable #2 (auto-discover + sync) would be dead end-to-end.
Pushing as `acme-admin-bff-api` matches `^acme-`. Provenance still records the
logical `tenant.repo=admin-bff-api` / `tenant.brand=acme` (the Forgejo repo name
is a scoping/discovery concern, the provenance repo identity is the code identity).

## Provenance signing key custody — DEFERRED to a live release
Build-host verification signs with a locally-generated TEST Ed25519 keypair and proves
tamper-fails. The REAL production key is out-of-band (key-USB/Vault); the signer identity
(generator vs the #118 export signer that chains to the baked `registry-pub.ed25519`) is a
release-time decision. When `PROVENANCE_SIGNING_KEY` is unset the manifest ships UNSIGNED
(warned) — signing with the real key is deferred.

## Deferred to a live cluster (cannot be proven build-host-only; not faked)
- Actual push to in-cluster/tailnet Forgejo + org/repo creation via Forgejo REST.
- ArgoCD ApplicationSet scmProvider discovering + syncing the pushed repos.
- Harbor per-tenant project + scoped robot creation against live Harbor REST + the
  once-only robot-secret Vault write.
- ESO materializing `forgejo-scm-token` / the push token / `harbor-admin` from Vault.
- admin-bff #118 `/bff/internal/domains/<dom>/reconcile-ack` ingest (endpoint absent).
- Signing provenance with the real out-of-band production key.
- `cluster-ca` copy into `hugmesh-pki` (Vault TLS verify gap in the harbor job).
