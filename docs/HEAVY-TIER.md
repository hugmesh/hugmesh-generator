# Heavy tier — the amd64 datastores + the lean/heavy test split

The Raspberry-Pi backend is the platform's default availability floor. It was never
meant to be the warehouse. The heavy amd64 datastores (Kafka, ClickHouse,
Uptrace/observability) run **only when the x86_64 host is attached**. This page
covers how GitOps expresses that split and how the test architecture detects it.

## The ArgoCD app split (per-bundle, auto-floor + manual-heavy)

The former single `hugmesh-analytics` Application auto-synced (prune+selfHeal) the
whole kafka+clickhouse bundle. On a Pi-only cluster the amd64-pinned pods cannot
schedule, so that app stayed Synced-but-Progressing forever. It is now split into
per-bundle Apps. The manifests were restructured, not deleted:
`manifests/analytics/{discovery,clickhouse,kafka}`.

| app | path | sync | arch | what |
|---|---|---|---|---|
| `hugmesh-analytics-discovery` | `manifests/analytics/discovery` | **AUTO** (prune+selfHeal) | any | the clickhouse/kafka **ClusterIP Services** only — the lightweight floor a Pi-only cluster always satisfies, so `clickhouse:8123` / `kafka:9092` DNS always resolves |
| `hugmesh-analytics-clickhouse` | `manifests/analytics/clickhouse` | **MANUAL** (operator opt-in) | amd64 | the ClickHouse warehouse pod + its 20Gi node-local PV |
| `hugmesh-analytics-kafka` | `manifests/analytics/kafka` | **MANUAL** | amd64 | the KRaft broker pod + its node-local PV |
| `hugmesh-observability` | `manifests/observability` | **MANUAL** | amd64 | Uptrace + its Postgres (depends on ClickHouse) |

MANUAL means the Application has no `syncPolicy.automated` block, so ArgoCD never
auto-syncs or self-heals it. An operator syncs it on purpose
(`argocd app sync hugmesh-analytics-clickhouse`, or the UI Sync button) after
attaching the x86 host and mounting its `hugmesh-local` data disk.

### nodeSelector, NOT a taint

Every heavy pod asks for the x86 host with `nodeSelector: {kubernetes.io/arch:
amd64}`. That is a request on the pod, not a taint on the node, so the shared x86
host stays schedulable for everything else. The split changes *when* the heavy pods
sync. It never changes the node's schedulability.

### Degradation contract

The Services sit in the always-on floor, so the admin BFF always has a name to
resolve. It addresses ClickHouse and Kafka by static cluster DNS; there is no
service-discovery registry. Until the heavy pods attach, usage degrades to the
in-memory fallback (no Kafka producer connection). The test tiers assert exactly
this boundary.

## How the test architecture detects heavy-readiness

The test-runner orchestrator (`manifests/test-runner/orchestrator.yaml`) fires two
edges. The HEAVY edge keys on the readiness of the actual amd64 workloads, not on
the ArgoCD Application status:

* `dep_ready kafka` + `dep_ready clickhouse` — the Deployments'
  `availableReplicas >= desired` (the real pods are up), and
* `amd64_node_ready` — a `Ready kubernetes.io/arch=amd64` Node exists.

It does not check Application `Synced` status. On a Pi-only cluster the manual
heavy apps are `OutOfSync` by design, and even when synced an amd64 app reads
`Synced-but-Progressing` until the pod schedules. Only the workload Ready endpoints
say that the heavy tier can really be exercised.

* **LEAN tier** (`test-job-lean.yaml`, `SNAP_EXPECT_HEAVY=0`) runs once, when the
  required fe/be/pki Deployments are ready, their Applications are Synced+Healthy
  and the seed Jobs are Complete. It is meant for a cluster with x86/heavy absent:
  it asserts the in-memory-fallback usage marker and no Kafka producer connection.
  The orchestrator does not test that the heavy tier is absent before it spawns the
  Job (`lean_ready` in `orchestrator.yaml`).
* **HEAVY tier** (`test-job-heavy.yaml`, `SNAP_EXPECT_HEAVY=1`) re-runs the full
  suite when the heavy edge fires. It asserts the real Kafka+ClickHouse path.

The GitOps split (manual heavy) and the test split (lean/heavy edges) describe one
fact: the heavy amd64 tier is opt-in, and the suite proves both the absent-fallback
and the present-real behaviour.
