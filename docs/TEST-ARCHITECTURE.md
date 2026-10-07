# Test architecture — the runtime e2e harness, the gates, and the wave wiring

This is the map of the **generated test architecture**: how the platform tests
itself against the REAL in-cluster services, and how the prod-hygiene + (in test)
seed/lean gates BLOCK a sync rather than silently passing.

## The pieces

```
specs/cluster/
  apps/
    00-prod-hygiene.yaml          Kyverno prod-hygiene ClusterPolicy + the RUNTIME
                                  PreSync HOOK Job (BLOCKS the wave on a violation)
    00-app-of-apps-waved.yaml     ALTERNATIVE explicit-waved root that makes the
                                  blocking hook realizable (vs the default recurse root)
    35-analytics-discovery.yaml   AUTO-sync floor (Services)            ┐ heavy-tier
    35-analytics-clickhouse.yaml  MANUAL heavy amd64 datastore          │ split
    35-analytics-kafka.yaml       MANUAL heavy amd64 datastore          │ (docs/
    36-observability.yaml         MANUAL heavy amd64 (Uptrace)          ┘ HEAVY-TIER.md)
    99-test-runner.yaml           ENV=test e2e harness app (pruned for prod)
  manifests/
    prod-hygiene/                 ClusterPolicy + PreSync hook Job + the runtime
                                  script (scripts/validate-prod-hygiene.sh mirror)
    test-runner/                  orchestrator + lean/heavy Job templates +
                                  akkoma-peer (non-federation observer) + RBAC + PVC
    analytics/{discovery,clickhouse,kafka}   the split heavy bundle
scripts/validate-prod-hygiene.sh  --static (CI/build) + --runtime (in-cluster)
tests/e2e/                        Playwright suite (specs 01-35) + the swarm driver
tests/qemu/seed-accounts.sh       --roles (role matrix) + --swarm N (the population)
```

## The two test tiers (lean always, heavy when x86 attaches)

The test-runner **orchestrator** (`manifests/test-runner/orchestrator.yaml`) is a
single long-lived kubectl/curl control loop owning two readiness edges:

* **LEAN edge** — required fe/be/pki Deployments ready + their ArgoCD Applications
  Synced+Healthy + the seed Jobs Complete → spawn `test-job-lean` (`SNAP_EXPECT_HEAVY=0`,
  asserts the x86-absent in-memory-fallback usage path).
* **HEAVY edge** — the **ACTUAL amd64 workloads** (kafka+clickhouse Deployments
  with `availableReplicas` at or above `spec.replicas`; the script header says `>=1`,
  the `dep_ready` function compares against the desired count) + a Ready
  `arch=amd64` Node — **NOT** ArgoCD
  Application-Synced (which is Synced-but-Pending on a Pi-only cluster) → spawn
  `test-job-heavy` (`SNAP_EXPECT_HEAVY=1`, asserts the REAL Kafka+ClickHouse path).
  Edge-debounced (cooldown + node-generation token) so a NotReady→Ready flap does
  not re-fire.

Both write JUnit/JSON/`summary.json{perRole,perLayer}` to the `test-reports` PVC
(secrets scrubbed by the custom reporter + a sed pass) and POST live events to the
admin-bff ingest endpoint for the console. See `manifests/test-runner/README.md`.

## The prod-hygiene gate (runtime, blocking)

`scripts/validate-prod-hygiene.sh` has two modes:

* `--static` — the CI lint + the build (`rewrite_prod_image_tags`) scan the BAKED
  prod tree for the test-runner wave, any `tier:test` resource, a Vault `server
  -dev`, and floating `:dev`/`*-dev` first-party images. The build HARD-FAILS on a
  survivor; it excludes the gate's own `manifests/prod-hygiene/` bundle (which
  necessarily contains the detection patterns).
* `--runtime` — the AUTHORITATIVE leg. The PreSync hook Job reads LIVE cluster
  signals (a static grep MISSES a templated/conditional dev server): no RUNNING
  `tier:test` pod (the MOCK ActivityPub peer / harness), no RUNNING Vault `-dev`
  arg + dev seal-status, no RUNNING `:dev`/`*-dev` image, and every seam-bearing
  service's live `seam-real`/health endpoint reports REAL (an un-flipped no-op
  STUB-SEAM answers `stub`/`disabled` and FAILS the gate).

### Why a HOOK (the app-of-apps restructuring)

The default root (`specs/cluster/app-of-apps.yaml`) is `directory.recurse` +
automated prune/selfHeal — a topology that **cannot block a wave** (ArgoCD just
keeps every child app continuously in sync; there is no haltable phase). So the
blocking gate is an **ArgoCD PreSync HOOK Job** (`manifests/prod-hygiene/job.yaml`,
hook sync-wave `-10`): a non-zero exit FAILS the PreSync phase, which ABORTS the
sync, so the dependent waves never apply.

`apps/00-app-of-apps-waved.yaml` is the **alternative explicit-waved root** that
makes this meaningful end-to-end: it is **non-automated** (synced deliberately) so
the hook's block is observable rather than retried-past, and honors the per-app
`sync-wave` annotations (kyverno `-1`, prod-hygiene `-2`, services `0…`,
test-runner `99`).

> **Restructuring note / honesty:** the default recurse root and the waved root
> are **mutually exclusive bootstrap targets** — you point the bootstrap at ONE.
> If both were applied, the recurse root would also manage the waved root. The
> waved root therefore ships as an opt-in topology (the build prunes it from the
> baked prod tree; the operator assembles the prod root). The default root remains
> the shipped topology; the waved root is how you turn the blocking gate on.

## RBAC role e2e (✅ cross-realm matrix present, offline; ⏳ live probe pending)

- ✅ **Present:** per-realm login (`specs/15-rbac-per-realm-login.spec.ts`), cross-realm
  **superadmin** (`specs/25-rbac-cross-realm-superadmin.spec.ts`), the full
  cross-realm authz matrix **systems × games × forum**
  (`specs/26-rbac-cross-realm-matrix.spec.ts`: allow, deny isolation, superadmin
  reach and the per-domain least-privilege cascade, for each realm pair), plus the
  route-access / admin-API gating + mod-sibling-scope + user/pending specs (12–18).
- ⏳ **Remaining:** spec 26's contract assertions run against the decision oracle
  with no cluster; its live token-grant probe is skipped unless `LIVE_GATEWAY=1`
  and real per-realm Casdoors (systems `hugmesh` / games `threewizards`) are up, and
  the spec's own header says live validation waits on a kernel-fixed x86 image.

## The non-federation proof (domain-lock)

`manifests/test-runner/akkoma-peer.yaml` is a TEST-ONLY second, genuinely-
federating ActivityPub instance (`peer.test`, reset per run). Specs 19-22 post on
the local instance and OBSERVE the peer: a domain-locked user's toot/boost/
announcement must NOT reach it (the akkoma `ForceLocalForUsers` MRF + the egress
backstop force local), while a NON-locked control user's MUST (the positive
control / the clock). All four SKIP honestly when the peer is absent or the
domain-lock gate is dark — they never fake a pass. See `docs/DOMAIN-LOCK.md`.

## The scaled-concurrent final sweep

`tests/e2e/specs/24-final-e2e-sweep.spec.ts` + `swarm-driver.ts` drive the
procedural population (120 users + 4 mods + 2 admins) acting simultaneously
(pre-minted JWTs avoid serializing at Casdoor; a concurrency invariant FAILS a
silently-serial run), asserting every enacted control at EACH layer + per-role SSE
messaging + disabled-UI helptext. The authoritative full matrix is
`docs/FINAL-E2E-SWEEP-MATRIX.md` (WIRED vs DOC per row — sampled, never silently
truncated).
