# Test architecture — the runtime e2e harness, the gates, and the wave wiring

This is the map of the generated test architecture. The platform tests itself
against the real in-cluster services, and the prod-hygiene gate (plus, in test, the
seed and lean gates) blocks a sync instead of passing silently. A gate that cannot
fail is a decoration.

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

The test-runner **orchestrator** (`manifests/test-runner/orchestrator.yaml`) is one
long-lived kubectl/curl control loop that owns two readiness edges:

* **LEAN edge** — the required fe/be/pki Deployments are ready, their ArgoCD
  Applications are Synced+Healthy and the seed Jobs are Complete. It then spawns
  `test-job-lean` (`SNAP_EXPECT_HEAVY=0`), which asserts the in-memory-fallback usage
  path of an x86-absent cluster.
* **HEAVY edge** — the actual amd64 workloads are up (kafka+clickhouse Deployments
  with `availableReplicas` at or above `spec.replicas`; the script header says `>=1`,
  but the `dep_ready` function compares against the desired count) and a Ready
  `arch=amd64` Node exists. It does **not** wait for the ArgoCD Application to be
  Synced, which on a Pi-only cluster stays Synced-but-Pending. It then spawns
  `test-job-heavy` (`SNAP_EXPECT_HEAVY=1`), which asserts the real Kafka+ClickHouse
  path. The edge is debounced (cooldown + node-generation token) so a
  NotReady→Ready flap does not re-fire it.

Both write JUnit/JSON/`summary.json{perRole,perLayer}` to the `test-reports` PVC
(secrets scrubbed by the custom reporter and a sed pass) and POST live events to the
admin-bff ingest endpoint for the console. See `manifests/test-runner/README.md`.

## The prod-hygiene gate (runtime, blocking)

`scripts/validate-prod-hygiene.sh` has two modes:

* `--static` — the CI lint and the build (`rewrite_prod_image_tags`) scan the baked
  prod tree for the test-runner wave, any `tier:test` resource, a Vault `server
  -dev`, and floating `:dev`/`*-dev` first-party images. The build hard-fails on a
  survivor. The scan excludes the gate's own `manifests/prod-hygiene/` bundle, which
  necessarily contains the detection patterns.
* `--runtime` — the authoritative leg. The PreSync hook Job reads live cluster
  signals, because a static grep misses a templated or conditional dev server. It
  fails the gate on: a running `tier:test` pod (the mock ActivityPub peer or
  harness), a running Vault `-dev` arg or dev seal-status, a running `:dev`/`*-dev`
  image, or any seam-bearing service whose live `seam-real`/health endpoint does not
  report real (an un-flipped no-op STUB-SEAM answers `stub`/`disabled`).

### Why a HOOK (the app-of-apps restructuring)

The default root (`specs/cluster/app-of-apps.yaml`) is `directory.recurse` with
automated prune/selfHeal. That topology **cannot block a wave**: ArgoCD keeps every
child app continuously in sync, and there is no phase to halt. So the blocking gate
is an **ArgoCD PreSync hook Job** (`manifests/prod-hygiene/job.yaml`, hook sync-wave
`-10`). A non-zero exit fails the PreSync phase, which aborts the sync, so the
dependent waves never apply.

`apps/00-app-of-apps-waved.yaml` is the **alternative explicit-waved root** that makes
this work end to end. It is non-automated (synced deliberately), so the hook's block is
observable instead of retried past, and it honors the per-app `sync-wave` annotations
(kyverno `-1`, prod-hygiene `-2`, services `0…`, test-runner `99`).

> **Restructuring note:** the default recurse root and the waved root are mutually
> exclusive bootstrap targets. You point the bootstrap at one. If both were applied,
> the recurse root would also manage the waved root. The waved root therefore ships as
> an opt-in topology: the build prunes it from the baked prod tree and the operator
> assembles the prod root. The default root remains the shipped topology; the waved
> root is how you turn the blocking gate on.

## RBAC role e2e (✅ cross-realm matrix present, offline; ⏳ live probe pending)

- ✅ **Present:** per-realm login (`tests/e2e/specs/15-rbac-per-realm-login.spec.ts`), cross-realm
  **superadmin** (`tests/e2e/specs/25-rbac-cross-realm-superadmin.spec.ts`), the full
  cross-realm authz matrix **systems × games × forum**
  (`tests/e2e/specs/26-rbac-cross-realm-matrix.spec.ts`: allow, deny isolation, superadmin
  reach and the per-domain least-privilege cascade, for each realm pair), plus the
  route-access / admin-API gating + mod-sibling-scope + user/pending specs (12–18).
- ⏳ **Remaining:** spec 26's contract assertions run against the decision oracle with
  no cluster. Its live token-grant probe is skipped unless `LIVE_GATEWAY=1` and real
  per-realm Casdoors (systems `hugmesh` / games `threewizards`) are up, and the spec's
  own header says live validation waits on a kernel-fixed x86 image.

## The non-federation proof (domain-lock)

`manifests/test-runner/akkoma-peer.yaml` is a test-only second ActivityPub instance
that does federate (`peer.test`, reset per run). Specs 19-22 post on the local
instance and watch the peer. A domain-locked user's toot, boost or announcement must
not reach it (the akkoma `ForceLocalForUsers` MRF and the egress backstop force
local). A non-locked control user's must (the positive control, the clock). All four
skip honestly when the peer is absent or the domain-lock gate is dark; they never
fake a pass. See `docs/DOMAIN-LOCK.md`.

## The scaled-concurrent final sweep

`tests/e2e/specs/24-final-e2e-sweep.spec.ts` + `swarm-driver.ts` drive the procedural
population (120 users + 4 mods + 2 admins) acting simultaneously. Pre-minted JWTs
avoid serializing at Casdoor, and a concurrency invariant fails a silently serial run.
The sweep asserts every enacted control at each layer, plus per-role SSE messaging and
disabled-UI helptext. The authoritative full matrix is `docs/FINAL-E2E-SWEEP-MATRIX.md`
(WIRED vs DOC per row, sampled, never silently truncated).
