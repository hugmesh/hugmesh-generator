# test-runner — the test-generated architecture (ENV=test ONLY)

This bundle is the **runtime test harness** the platform runs against the REAL
in-cluster services. It is forbidden in `ENV=prod`: the prod-hygiene gate
(`scripts/validate-prod-hygiene.sh` + the Kyverno `prod-hygiene` ClusterPolicy)
rejects every component here by its `snapdragon.systems/tier: test` label, and
`gate_env_apps` (build-x86-host-stage4.sh) prunes `apps/99-test-runner.yaml` +
this whole directory out of the baked prod tree.

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

1. **LEAN edge** — fires when the *required* (enumerated, NOT "every") workloads
   in `snapdragon-frontend` + `-backend` + `-pki` have
   `availableReplicas == desired` **AND** their ArgoCD Applications are
   `Synced + Healthy` **AND** the seed/admin-sync Jobs are `Complete` (a positive
   seed signal). On the first all-ready it spawns `test-runner-lean`
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
POST per-suite/per-role events to the admin-bff ingest endpoint
(`/bff/admin/test-reports/ingest`, internal) so the admin-ui console streams live
and the report list is durable. (The admin-bff side is PR #23 on
snapdragon-admin-bff-api — the test-reports console backend.)

## ArgoCD gating

`apps/00-app-of-apps-waved.yaml` is the explicit, sync-waved app-of-apps that
makes "ArgoCD runs all tests before apps proceed" realizable (the default
`app-of-apps.yaml` is `directory.recurse` + automated, which cannot block). The
seed + lean-test gate runs as a **blocking PreSync/PostSync hook** wave-ordered
before the dependent app waves; a failing lean run blocks the next wave and
records a FAILED run-id surfaced in the console (it never silently passes). See
`docs/TEST-ARCHITECTURE.md` for the restructuring rationale.
