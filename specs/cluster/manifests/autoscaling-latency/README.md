# DARK latency/RPS autoscaling (KEDA ScaledObjects)

This directory is the **deferred event-driven "2nd pass"** that
[`apps/01b-keda.yaml`](../../apps/01b-keda.yaml) promised. KEDA the operator is
already installed and live; the BFF/UI fleet already has plain `autoscaling/v2`
**CPU + memory** HPAs (`manifests/<svc>/hpa.yaml`) and the gateway chart has a
CPU+memory HPA gated `autoscaling.enabled: false`. What was missing — and what
lives here — is **request-load (latency / RPS) autoscaling**, which the
resource-metrics API cannot provide. KEDA's `prometheus` trigger compiles a
PromQL query down to an `autoscaling/v2` HPA via KEDA's metrics-apiserver.

## What's here (representative high-traffic edges)

| ScaledObject | Target Deployment | Namespace | min/max | trigger threshold |
|---|---|---|---|---|
| `hugmesh-fe-gateway-latency`   | `hugmesh-fe-gateway`   | `hugmesh-frontend` | 2 / 8 | 50 rps/replica |
| `hugmesh-be-gateway-latency`   | `hugmesh-be-gateway`   | `hugmesh-backend`  | 2 / 8 | 50 rps/replica |
| `hugmesh-admin-bff-api-latency`| `hugmesh-admin-bff-api`| `hugmesh-backend`  | 2 / 6 | 40 rps/replica |
| `hugmesh-user-bff-api-latency` | `hugmesh-user-bff-api` | `hugmesh-backend`  | 2 / 6 | 60 rps/replica |

The metric is `http_server_requests_seconds_count` — the Micrometer/Spring Boot
Actuator server-request counter every first-party app already emits;
`sum(rate(...[1m]))` is requests-per-second. A commented p95-**latency**
alternative (`http_server_requests_seconds_bucket` + `histogram_quantile`) is in
`fe-gateway-scaledobject.yaml`; it needs Actuator histogram buckets enabled.

## Why it is DARK / inert

* **No base or per-service kustomization references this directory.** It is not in
  any service's `resources:` list, so a normal sync never pulls it in.
* The only consumer is the **manual-sync** ArgoCD Application
  [`apps/01c-autoscaling-latency.yaml`](../../apps/01c-autoscaling-latency.yaml),
  which has **no `syncPolicy.automated{}`**. Under the `recurse: true` root it is
  *created* but stays **Out-Of-Sync** and applies nothing — the same dark pattern
  as `apps/36-observability.yaml`.

## Fail-safe (cannot zero or thrash a service)

* `minReplicaCount: 2` on every object (= the existing HPA floor). KEDA never
  scales below it, and `idleReplicaCount` is **unset**, so there is **no
  scale-to-zero path at all**. An absent/broken Prometheus = the metric can't be
  read = the Deployment holds at its floor; it is never dropped.
* `behavior.scaleDown.stabilizationWindowSeconds: 300` + ≤ 1 pod / 2 min scale-in,
  `cooldownPeriod: 300`, `pollingInterval: 30` — deliberately slow, no thrash.

## Metric source dependency (LIVE-GATED — there is NO Prometheus yet)

The cluster's observability is **Uptrace + an OTel Collector** (OTLP → Uptrace,
`manifests/observability`). **There is no Prometheus server and no Prometheus
query endpoint today.** The triggers point at
`http://prometheus-server.observability.svc.cluster.local:80` as a placeholder.
Before enabling, provide **one** of:

1. **A Prometheus server** scraping the Spring Boot Actuator endpoint
   (`/actuator/prometheus`) of the targeted gateways/BFFs, reachable at that
   `serverAddress`; or
2. **An OTel Collector `prometheus` exporter** (add one to
   `manifests/observability` so the collector serves its OTLP metrics as a scrape
   target), then repoint `serverAddress` + adjust metric names to the exported
   series.

## Enable switch (one line, after prerequisites)

```sh
# 1. Stand up a Prometheus query endpoint (see "Metric source dependency").
# 2. On each service you enable, RETIRE its v2 CPU+memory HPA first
#    (delete manifests/<svc>/hpa.yaml from that service's kustomization) —
#    KEDA refuses to co-own a Deployment that already has an HPA.
# 3. Flip it on:
argocd app sync autoscaling-latency
```

To make it permanent, add a `syncPolicy.automated: { prune: true, selfHeal: true }`
block to `apps/01c-autoscaling-latency.yaml` and commit.

## Validate locally (no cluster needed)

```sh
kustomize build specs/cluster/manifests/autoscaling-latency
# CRD schema check (needs the KEDA ScaledObject CRD schema):
kustomize build specs/cluster/manifests/autoscaling-latency \
  | kubeconform -strict -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```
