# Heavy tier — the amd64 datastores + the lean/heavy test split

The platform's **default availability floor is the Raspberry-Pi backend**; the
heavy amd64 datastores (Kafka, ClickHouse, Uptrace/observability) run **only when
the x86_64 host is attached**. This document covers how that split is expressed in
GitOps and how the test architecture detects it.

## The ArgoCD app split (per-bundle, auto-floor + manual-heavy)

The former single `snapdragon-analytics` Application auto-synced (prune+selfHeal)
the **whole** kafka+clickhouse bundle. On a Pi-only cluster the amd64-pinned pods
are unschedulable, so that app churned **Synced-but-Progressing forever**. It is
now split into per-bundle Apps (the manifests were **restructured, not deleted** —
`manifests/analytics/{discovery,clickhouse,kafka}`):

| app | path | sync | arch | what |
|---|---|---|---|---|
| `snapdragon-analytics-discovery` | `manifests/analytics/discovery` | **AUTO** (prune+selfHeal) | any | the clickhouse/kafka **ClusterIP Services** only — the lightweight floor a Pi-only cluster always satisfies, so `clickhouse:8123` / `kafka:9092` DNS always resolves |
| `snapdragon-analytics-clickhouse` | `manifests/analytics/clickhouse` | **MANUAL** (operator opt-in) | amd64 | the ClickHouse warehouse pod + its 20Gi node-local PV |
| `snapdragon-analytics-kafka` | `manifests/analytics/kafka` | **MANUAL** | amd64 | the KRaft broker pod + its node-local PV |
| `snapdragon-observability` | `manifests/observability` | **MANUAL** | amd64 | Uptrace + its Postgres (depends on ClickHouse) |

**MANUAL** = the Application has **no `syncPolicy.automated` block**, so ArgoCD
never auto-syncs or self-heals it. An operator syncs it deliberately
(`argocd app sync snapdragon-analytics-clickhouse`, or the UI Sync button) **after**
attaching the x86 host and mounting its `snapdragon-local` data disk.

### nodeSelector, NOT a taint

Every heavy pod requests the x86 host with `nodeSelector: {kubernetes.io/arch:
amd64}`. This is a **request on the pod**, not a **taint on the node** — the shared
x86 host stays schedulable for everything else. The split changes *when* the heavy
pods sync, never the node's schedulability.

### Degradation contract

Because the Services are in the always-on floor, the admin BFF (which addresses
ClickHouse/Kafka by **static cluster DNS** — there is no service-discovery
registry) always has a name to resolve. Until the heavy pods attach, usage
**degrades to the in-memory fallback** (no Kafka producer connection). This is
exactly the boundary the test tiers assert (below).

## How the test architecture detects heavy-readiness

The test-runner orchestrator (`manifests/test-runner/orchestrator.yaml`) fires two
edges. The **HEAVY** edge is keyed on the **ACTUAL amd64 workloads' readiness**,
NOT on the ArgoCD Application status:

* `dep_ready kafka` + `dep_ready clickhouse` — the Deployments'
  `availableReplicas >= desired` (the real pods are up), AND
* `amd64_node_ready` — a `Ready kubernetes.io/arch=amd64` Node exists.

It deliberately does **not** check Application `Synced` status: on a Pi-only
cluster the manual heavy apps are `OutOfSync`/un-synced by design, and even when
synced an amd64 app is `Synced-but-Progressing` until the pod actually schedules.
Reading the **workload Ready endpoints** is the only signal that means "the heavy
tier is genuinely exercisable".

* **LEAN tier** (`test-job-lean.yaml`, `SNAP_EXPECT_HEAVY=0`) runs when fe/be/pki
  are ready and **x86/heavy is ABSENT** — it asserts the in-memory-fallback usage
  marker + no Kafka producer connection.
* **HEAVY tier** (`test-job-heavy.yaml`, `SNAP_EXPECT_HEAVY=1`) re-runs the full
  suite when the heavy edge fires — it asserts the REAL Kafka+ClickHouse path.

So the GitOps split (manual heavy) and the test split (lean/heavy edges) are two
views of the same fact: **the heavy amd64 tier is opt-in, and the suite proves
both the absent-fallback and the present-real behaviours.**
