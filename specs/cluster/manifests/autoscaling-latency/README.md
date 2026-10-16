# DARK latency/RPS autoscaling (KEDA ScaledObjects)

> **Status: no longer dark.** The Application that syncs this directory,
> [`apps/01c-autoscaling-latency.yaml`](../../apps/01c-autoscaling-latency.yaml), has
> `syncPolicy.automated` armed ("UNDARKENED (2026-06-23)", annotation
> `hugmesh.net/dark: "false"`). ArgoCD applies these ScaledObjects. The headings
> below keep their old wording; read them with this note.

This directory is the **deferred event-driven "2nd pass"** that
[`apps/01b-keda.yaml`](../../apps/01b-keda.yaml) promised. The KEDA operator is
already live. The BFF/UI fleet already has plain `autoscaling/v2` **CPU + memory**
HPAs (`manifests/<svc>/hpa.yaml`), and the gateway chart has one gated by
`autoscaling.enabled: false`. What was missing, and what lives here, is
**request-load (latency / RPS) autoscaling**, which the resource-metrics API cannot
provide. KEDA's `prometheus` trigger compiles a PromQL query down to an
`autoscaling/v2` HPA through KEDA's metrics-apiserver.

## What's here (representative high-traffic edges)

| ScaledObject | Target Deployment | Namespace | min/max | trigger threshold |
|---|---|---|---|---|
| `hugmesh-fe-gateway-latency`   | `hugmesh-fe-gateway`   | `hugmesh-frontend` | 2 / 8 | 50 rps/replica |
| `hugmesh-be-gateway-latency`   | `hugmesh-be-gateway`   | `hugmesh-backend`  | 2 / 8 | 50 rps/replica |
| `hugmesh-admin-bff-api-latency`| `hugmesh-admin-bff-api`| `hugmesh-backend`  | 2 / 6 | 40 rps/replica |
| `hugmesh-user-bff-api-latency` | `hugmesh-user-bff-api` | `hugmesh-backend`  | 2 / 6 | 60 rps/replica |

The metric is `http_server_requests_seconds_count`, the Micrometer/Spring Boot
Actuator server-request counter that every first-party app already emits.
`sum(rate(...[1m]))` is requests per second. A commented p95-**latency** alternative
(`http_server_requests_seconds_bucket` + `histogram_quantile`) sits in
`fe-gateway-scaledobject.yaml`. It needs Actuator histogram buckets enabled.

## Why it is DARK / inert

* **No base or per-service kustomization references this directory.** It is in no
  service's `resources:` list, so a service sync never pulls it in.
* The only consumer is the ArgoCD Application
  [`apps/01c-autoscaling-latency.yaml`](../../apps/01c-autoscaling-latency.yaml).
  It was written as manual-sync (no `syncPolicy.automated{}`), the dark pattern that
  `apps/36-observability.yaml` still uses. It now has
  `automated: { prune: true, selfHeal: true }`, so it syncs by itself.
* Without Prometheus, the floor below keeps it harmless. A manual gate does not.
* **Open conflict.** `manifests/admin-bff-api/kustomization.yaml` and
  `manifests/user-bff-api/kustomization.yaml` still list `hpa.yaml`. The admin and
  user BFF ScaledObjects therefore target Deployments that already have an HPA, and
  KEDA does not co-own such a Deployment (see
  `specs/cluster/bootstrap/kind-local/README.md`). The gateway ScaledObjects do not
  hit this, because the gateway chart's HPA is off.

## Fail-safe (cannot zero or thrash a service)

* `minReplicaCount: 2` on every object (= the existing HPA floor). KEDA never scales
  below it, and `idleReplicaCount` is **unset**, so there is **no scale-to-zero
  path**. If Prometheus is absent or broken, the metric cannot be read and the
  Deployment holds at its floor. It is never dropped.
* `behavior.scaleDown.stabilizationWindowSeconds: 300`, at most 1 pod per 2 min
  scale-in, `cooldownPeriod: 300`, `pollingInterval: 30`. All deliberately slow, to
  prevent thrash.

## Metric source dependency (LIVE-GATED — there is NO Prometheus yet)

The cluster's observability is **Uptrace + an OTel Collector** (OTLP → Uptrace,
`manifests/observability`). **There is no Prometheus server and no Prometheus query
endpoint today.** The triggers point at
`http://prometheus-server.observability.svc.cluster.local:80` as a placeholder.
Before enabling, provide **one** of:

1. **A Prometheus server** that scrapes the Spring Boot Actuator endpoint
   (`/actuator/prometheus`) of the targeted gateways and BFFs, reachable at that
   `serverAddress`; or
2. **An OTel Collector `prometheus` exporter.** Add one to `manifests/observability`
   so the collector serves its OTLP metrics as a scrape target. Then repoint
   `serverAddress` and adjust the metric names to the exported series.

## Enable switch (one line, after prerequisites)

The Application auto-syncs, so `argocd app sync autoscaling-latency` is no longer
the switch. These prerequisites still decide whether the ScaledObjects do anything:

```sh
# 1. Stand up a Prometheus query endpoint (see "Metric source dependency").
# 2. On each service you enable, RETIRE its v2 CPU+memory HPA first
#    (delete manifests/<svc>/hpa.yaml from that service's kustomization) —
#    KEDA refuses to co-own a Deployment that already has an HPA.
```

To hold the Application back again, remove the `syncPolicy.automated` block from
`apps/01c-autoscaling-latency.yaml` and commit.

## Validate locally (no cluster needed)

```sh
kustomize build specs/cluster/manifests/autoscaling-latency   # or: kubectl kustomize <dir>
# CRD schema check (needs the KEDA ScaledObject CRD schema):
kustomize build specs/cluster/manifests/autoscaling-latency \
  | kubeconform -strict -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```
