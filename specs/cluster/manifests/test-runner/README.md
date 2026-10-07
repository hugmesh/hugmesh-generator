# test-runner — the test-generated architecture (ENV=test ONLY)

This bundle is the **runtime test harness** the platform runs against the REAL
in-cluster services. It is forbidden in `ENV=prod`: the prod-hygiene gate
(`scripts/validate-prod-hygiene.sh` + the Kyverno `prod-hygiene` ClusterPolicy)
rejects every component here by its `hugmesh.net/tier: test` label, and
`rewrite_prod_image_tags` (called from `gate_env_apps` in build-x86-host-stage4.sh)
prunes `apps/99-test-runner.yaml`, `apps/00-app-of-apps-waved.yaml` and this whole
directory out of the baked prod tree.

## What it is

```
test-runner/
  namespace-rbac.yaml   ServiceAccount + RBAC: read Deployments/StatefulSets/Pods/
                        Endpoints across fe/be/pki + Nodes + ArgoCD Applications,
                        and create the lean/heavy test Jobs.
  pvc.yaml              test-reports PVC (lean/, heavy/, run-<ts>-<commit>/…),
                        durable, the admin-bff TestReportsController reads it.
  orchestrator.yaml     the trigger Deployment (orchestrator.sh): a control loop
                        that watches readiness and SPAWNS the test Jobs.
  test-job-lean.yaml    the LEAN Job template (rendered by the orchestrator):
                        TIER=LEAN, runs the real-services Playwright suite when
                        fe/be/pki are Ready and x86/heavy is ABSENT.
  test-job-heavy.yaml   the HEAVY Job template: TIER=HEAVY, re-runs the full
                        suite when the amd64 workloads (kafka+clickhouse) attach.
  akkoma-peer.yaml      a SECOND, genuinely-federating akkoma instance + its
                        isolated DB — the external observer for the non-federation
                        proof (specs 19-22). registrations_open, per-run DB reset.
  kustomization.yaml
```

## The two triggers (the heart of the architecture)

The orchestrator (`orchestrator.sh`, a tight `kubectl`/`curl` control loop) is a
single long-lived pod that owns BOTH edges:

1. **LEAN edge** — fires when the *required* (enumerated, NOT "every") Deployments
   (`hugmesh-host-shell` in `hugmesh-frontend`; `hugmesh-admin-bff-api` and
   `hugmesh-federation-api` in `hugmesh-backend`) have
   `availableReplicas == desired` **AND** their ArgoCD Applications (`frontend`,
   `admin-bff-api`, `federation-api`) are `Synced + Healthy` **AND** the seed Jobs
   (`casdoor-init` in `hugmesh-pki`, `akkoma-admin-sync` in `hugmesh-backend`) are
   `Complete` (a positive seed signal). The lists are the `REQUIRED_LEAN`,
   `REQUIRED_APPS` and `REQUIRED_SEED_JOBS` env defaults in `orchestrator.yaml`. On the first all-ready it spawns `test-runner-lean`
   (`TIER=LEAN`). Lean asserts the **x86-absent fallback** (admin-bff usage
   returns the in-memory-fallback marker; no Kafka producer connection).

2. **HEAVY edge** — fires when the **actual amd64 workloads** are up:
   `kafka` + `clickhouse` Deployments have `availableReplicas >= 1` **AND** a
   `Ready kubernetes.io/arch=amd64` Node exists — **NOT** by Application-Synced
   status (which is Synced-but-Pending on a Pi-only cluster). **Edge-debounced**:
   a cooldown + a last-run-id-per-node-generation guard so a NotReady→Ready flap
   does not re-fire. It re-runs the full suite (`TIER=HEAVY`) exercising the
   Kafka/ClickHouse/observability paths.

Both Jobs write JUnit/JSON/summary + sanitized logs to the `test-reports` PVC and
POST per-suite/per-role events to the URL in `SNAP_INGEST_URL`, set in both Job
templates to
`http://hugmesh-admin-bff-api.hugmesh-backend.svc.cluster.local:8080/bff/admin/test-reports/ingest`.
The admin-bff side is `TestReportsController` (`/bff/admin/test-reports`). Its ingest
route is `POST /bff/admin/test-reports/{id}/ingest`, under `hasRole('ADMIN')`, and
admin-bff's own Job template posts to `.../test-reports/${RUN_ID}/ingest` over `:8443`.
The URL in these Job templates has no run id, so it does not match that route, and
the live console stream is not shown to work. The PVC reports are the durable record.

## ArgoCD gating

`apps/00-app-of-apps-waved.yaml` is an alternative sync-waved root (`hugmesh-root-waved`).
The default `app-of-apps.yaml` is `directory.recurse` + automated, which cannot
block. The waved root has no automated sync: an operator syncs it by hand, so a
failing PreSync hook aborts that sync. The only hook that blocks is the prod-hygiene
runtime gate (`apps/00-prod-hygiene.yaml`, PreSync, sync-wave -10). The lean and heavy
Jobs carry no `argocd.argoproj.io/hook` annotation: the orchestrator applies them,
and they end `playwright test ... || true`, so a failing lean run does not block
any wave. See `docs/TEST-ARCHITECTURE.md` for the design.

The harness itself is deployed by `apps/99-test-runner.yaml` (wave 99, ENV=test
only — the build prunes it + this whole bundle for prod). The **prod-hygiene gate**
that keeps it (and the akkoma-peer) out of prod is `apps/00-prod-hygiene.yaml`
(`manifests/prod-hygiene/` — a Kyverno ClusterPolicy + a RUNTIME PreSync hook Job).

## Status — what is implemented

| piece | file | status |
|---|---|---|
| orchestrator (lean+heavy edges) | `orchestrator.yaml` | DONE |
| LEAN Job template | `test-job-lean.yaml` | DONE |
| HEAVY Job template | `test-job-heavy.yaml` | DONE |
| non-federation observer peer | `akkoma-peer.yaml` | DONE (image is the floating `akkoma:stable`) |
| RBAC + PVC + kustomization | `namespace-rbac.yaml` `pvc.yaml` `kustomization.yaml` | DONE |
| heavy-tier ArgoCD app split | `apps/35-analytics-*.yaml` `36-observability.yaml` | DONE (`docs/HEAVY-TIER.md`) |
| runtime prod-hygiene gate | `apps/00-prod-hygiene.yaml` `manifests/prod-hygiene/` | DONE |
| non-federation specs 19-22 | `tests/e2e/specs/19-22-*.spec.ts` | DONE (skip honestly until peer+gate live) |
| scaled-concurrent sweep | `tests/e2e/specs/24-final-e2e-sweep.spec.ts` + `tests/e2e/specs/swarm-driver.ts` | FRAMEWORK + representative scenarios (`docs/FINAL-E2E-SWEEP-MATRIX.md`) |
| custom reporter (role/layer pivot, secret scrub, SSE) | `tests/e2e/reporters/hugmesh-reporter.ts` | DONE |

Documented gaps (intentional, honest): the lean and heavy Jobs use the floating
`registry.hugmesh.net/hugmesh-test-runner:dev`, and `akkoma-peer.yaml` uses
`akkoma:stable`, marked "pin a real tag" in the file. A prod build pins `:dev`
tags to `RELEASE_TAG` but prunes this bundle first, so no test build is pinned.
The live federation/SSE/disabled-UI assertions
activate when the domain-lock gate + role-conditional UI land (the framework
primitives already exist — see the spec-18-style stubs).
