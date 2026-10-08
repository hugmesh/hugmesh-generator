# Games App Store (games-services control plane)

A per-domain catalog of dockerized FOSS game servers. A **superadmin** curates a GLOBAL
catalog and offers servers to specific domains. Per-domain **games-services admins** enable
offers and create and run instances. **Runners** (mods) start and stop instances. The control
plane lives in `hugmesh-admin-bff-api`. The operator UI is a federated remote in
`hugmesh-admin-ui` at `/admin/games-services`. The player-facing server browser
(`hugmesh.games`) is **out of scope** here.

This document covers the GENERATOR side: roles, sync Jobs, ApplicationSet, isolation, port
exposure, degrade. The data model, endpoints and reconciler live in the admin-bff repo.

## Rides the `games` slug

The app store needs the games namespace, so it is an **add-on of the `games` optional
slug**, not a slug of its own. Deselect `games` (or flip it off at runtime) and the
WHOLE app-store control plane is pruned; see "Degrade" below. The `games` entry in
`optional-services.yaml` carries the app-store apps, manifests and routes. The `games` install
flag in the `installed-services` ConfigMap drives the `games-services` capability greyout
(`dependsOn: games`). It does not drive the 13c ApplicationSet: that element ships
`installed: "false"` and no script in this repo flips it (see below).

## Roles (Casdoor, systems org)

These roles live in the main (systems) Casdoor, org `hugmesh`, not in the separate games realm. Seeded in `manifests/casdoor/init-data-configmap.yaml` (empty and non-nested):

| Role | Meaning | Materialized by |
|------|---------|-----------------|
| `ROLE_GAMES_SERVICES` | base app-store access | SUPERADMIN grant |
| `ROLE_GAMES_SERVICES_ADMIN` | `= ROLE_GAMES_SERVICES ∩ (ROLE_ADMIN ∪ ROLE_MOD)`; catalog-enable + create/run | `games-services-admin-sync` Job |
| `ROLE_GAMES_SERVICES_RUNNER` | `= ROLE_GAMES_SERVICES ∩ ROLE_MOD`; mod-delegated run/stop | `games-services-runner-sync` Job |

Casdoor role nesting is UNION, not intersection, so two Jobs reconcile the AND
(`manifests/casdoor/games-services-{admin,runner}-sync-job.yaml`, clones of
`games-admin-sync`). Each writes EXACTLY the verified intersection into its derived role
(idempotent, default-deny prune). Each route surface keys on a single derived role, which
gives the required AND at the gateway (any single input role is default-deny).

## ApplicationSet + isolation

- `apps/13c-games-instances.yaml` — owns the `games-instances` base (namespace + isolation).
  Its one element is `installed: "false"` (ships dark; the file header says a later change
  flips it, and no script in this repo does). admin-bff is the SINGLE writer of the
  per-domain ConfigMaps `games-instances-<domain>`, and only when
  `games-services.reconciler.enabled=true` (default false). They land in
  `hugmesh-games` (`games-services.reconciler.namespace`). ArgoCD is apply-only. The Lease +
  `propagation_state` are the SOLE coordination. Nothing in this repo reads those
  ConfigMaps yet: the Deployment/Service/PVC in `podsecurity.yaml` is a `replicas: 0`
  template, and no renderer turns the ConfigMaps into live instances.
- `manifests/games-instances/` — the dedicated `hugmesh-games-instances` namespace with
  **enforced restricted PodSecurity** and a **default-deny ingress+egress NetworkPolicy**
  (narrow allows: be-gateway to the instance HTTP console, and DNS egress; nothing else). It
  also holds a restrictive securityContext exemplar (runAsNonRoot, drop ALL caps, no privesc,
  seccomp RuntimeDefault, readOnlyRootFS) and a per-instance RWO world-save PVC on
  `hugmesh-local`.

## Port exposure

- **HTTP consoles** — be-gateway path-routes `/games/servers/**` (console paths are
  `/games/servers/<slug>/<name>/`) to Service `games-instances-console` in
  `hugmesh-games-instances` (route `games-servers-console` in `apps/20-gateway-be.yaml`).
  The route-access DB admits `ROLE_GAMES_SERVICES`, plus `ROLE_ADMIN` and `ROLE_MOD` as
  supersets. No manifest in `manifests/games-instances/` defines that Service. Spring Cloud
  Gateway is L7-only.
- **Raw L4 game protocols** — a per-instance **NodePort** from a reserved pool (admin-bff
  `NodePortAllocator`, default 31000–31099). The reserved sub-pool bounds games' share of the
  finite cluster-wide 30000–32767 range. Allocation fails closed on exhaustion.
- **RCON/admin** — tailnet-only ClusterIP. Never routed. Never in the `/connection` response
  (`GET /bff/games-services/instances/{id}/connection`).

## Degrade (games down)

When `games` is not selected, the `games)` case of `gate_optional_services()`
(`scripts/_optional-services-lib.sh`, called by the stage4 builders) prunes:
`apps/13c-games-instances.yaml`, `manifests/games-instances/`, the two
`games-services-*-sync-job.yaml` (and their `casdoor/kustomization.yaml` lines), the
`games-servers-console` gateway route, and the `games-services` route-access rows (be + fe).
`_opt_render_installed_services` sets the `games` install flag to `"false"` (in the
ConfigMap and in the 13a element), so the operator UI greys out (`dependsOn: games`). It does
not touch the 13c element.

## Security residuals (not blocking)

- **Arbitrary-container exec** is the core risk. Four things contain it: superadmin-only
  curation; server-side digest-pin (the catalog accepts only `repo@sha256:<64 hex>` refs and
  rejects tag-only ones); the enforced restricted PodSecurity; the default-deny NetworkPolicy.
  **cosign signature verification**, a **CVE scan** of curated images, and **gVisor/Kata**
  runtime isolation are layered residuals.
- **NodePort exhaustion + L4 exposure** — the range is finite and cluster-wide. NodePort
  traffic is not subject to pod NetworkPolicy source-filtering, so cross-domain isolation of
  in-flight game packets is weaker than the control plane.
- **World-save HA** — the per-instance PVC is RWO and node-pinned (no live-migration of saves).
