# Per-gateway role→URL external access control

Admins control, per gateway, which Casdoor roles and users may reach which URLs from
outside the gateway (that is, from the VPN or cloud). This is the `hugmesh-id-gateway`
Postgres-backed-routes pattern, minus the random per-app URL generation: role-based
external access locking for the already-known services.

## Data model (Postgres + Cassandra cache)

- **Source of truth:** Postgres table `gateway_route_access`
  ([20-schema.sql](../specs/cluster/manifests/route-access/initdb/20-schema.sql)) —
  `(gateway, url_pattern, role, casdoor_user?, allow)`.
- **Cache:** each gateway selects only its own rows from Postgres at startup and on
  every refresh tick (`app.route-access.refresh-interval-ms`, default 5000), so an
  admin change propagates within one refresh interval. After each successful load it
  mirrors the rows into **Cassandra** (`hugmesh_gateway.gateway_route_access`). If
  Postgres is briefly unreachable it enforces the last Cassandra snapshot. With
  neither configured (unit tests, minimal dev) it uses the in-memory canonical seed,
  so enforcement is never silently absent.
- **Roles owned by Casdoor:** `role` references a Casdoor role; `casdoor_user`
  optionally pins a specific Casdoor user. The gateway already converts the Casdoor
  JWT claims to Spring authorities (`ROLE_*`).

## Enforcement (in each hugmesh-*-gateway)

On every request the gateway:
1. loads its access rules (Postgres is the source, Cassandra the mirror and fallback),
2. matches the request path against `url_pattern` for **its** gateway, taking the
   **longest** matching pattern (`GatewayRouteAccessService.decide()` compares
   `url_pattern.length()`),
3. among the rows at that winning pattern, applies **deny-wins**: a satisfied
   `allow = false` row returns 403 whatever allow rows sit beside it, and a
   `role = PUBLIC` allow row admits with no Casdoor check at all.

Casdoor's own login UI is never exposed through a gateway. The only unauthenticated
login surface is the native `POST /bff/login` (permitAll at the BFF, seeded `PUBLIC`
on the fe-gateway so an anonymous browser can sign in). Beside it, `/login/**` is
seeded `PUBLIC` on the fe and pki gateways, and `/api/auth/**` is seeded `ROLE_USER`
on the pki gateway as a public-floor row. The gateway's resource-server layer also
lets `/api/auth`, `/api/registration` and `/api/login` through unauthenticated
(`SecurityConfig` `PUBLIC_PATHS`).

### ⚠ "No matching row" is NOT a denial. Three verdicts, not two.

This section used to say the gateway "**allows only if** … otherwise 403". That was
wrong, and the error cost real time. `Decision` has **three** values:

| situation | verdict | what the filter does |
|---|---|---|
| a matching row the caller satisfies | `ALLOW` | forward |
| a matching row the caller does **not** satisfy, or a satisfied `allow=false` row | `DENY` | **403** + `X-Route-Denied: <gateway>:<path>` |
| **no matching `url_pattern` at all** | `NO_RULE` | **forward** — the path is simply not governed here |

`GatewayRouteAccessService.decide()` returns `Decision.NO_RULE` for an unmatched path,
and `GatewayRouteAccessFilter` rejects only on `== Decision.DENY`. Its class javadoc
says: *"ALLOW / NO_RULE → forward. NO_RULE means the path isn't governed by any rule
at this gateway, so the coarse SecurityConfig gate (already passed) is the
authority."*

Two consequences, both of which have bitten:

* **A routed path with no governing row is reachable, not walled.** There is no
  `/bff/**` floor row on `hugmesh-fe-gateway` today, so any `/bff/<unnamed>` subpath
  is `NO_RULE` and forwards to admin-bff, whose own `SecurityConfig` is the only
  authority left. Do not read "not in the seed" as "denied".
* **A test oracle that collapses `NO_RULE` into `DENY` manufactures confidence.**
  `tests/e2e/specs/rbac-route-access.ts` did exactly that. Its hand-copied table had
  drifted to 11 of the seed's 77 fe rows (the seed now has 82), so it answered `DENY`
  for every `/bff/user/**` profile and password path the real gateway `ALLOW`s, and
  six RBAC spec files asserted against it and stayed green. That table is now
  generated from `20-schema.sql` by `scripts/gen-route-access-oracle.py`, gated by
  `tests/scripts/test-route-access-oracle.sh`, and the oracle returns the third
  verdict.

Each gateway is pointed at the store via `ROUTE_ACCESS_R2DBC_URL` (set in
`apps/20-gateway-*.yaml`).

## Admin API + UI

- **admin-bff-api** (Spring, backend namespace, behind the gateway): list, add and
  delete on `gateway_route_access` — `GET`, `POST` and `DELETE
  /bff/admin/route-access` in `AdminController`, `ROLE_ADMIN` only, domain-scoped,
  with no `PUT`. It persists to Postgres with a best-effort Cassandra mirror. Ordinary
  Casdoor JWT traffic goes through the hugmesh-pki gateway (`PKI_GATEWAY_BASE`). The
  Casdoor admin write API (add-user, update-role) is a direct call to
  `CASDOOR_ADMIN_BASE_URL`, and it ships dark (`casdoor.admin.enabled=false`).
- **admin-ui** (`hugmesh-admin-ui`, ROLE_ADMIN only): a "Gateway access" view (nav
  label "Route access"; `route-access.component`) to list, add and remove
  `(gateway, url_pattern, role/user, allow)` rules.
- For the integration stack, the mock BFF exposes `/bff/admin/route-access` CRUD and
  the admin UI renders the table (see tests).

## Status

Implemented. The schema is `20-schema.sql`. Each gateway reads it through
`ROUTE_ACCESS_R2DBC_URL` (set in `apps/20-gateway-{fe,be,pki}.yaml`). The enforcing
filter is `GatewayRouteAccessFilter`, with `GatewayRouteAccessService`, in
`hugmesh-gateway`. The `/bff/admin/route-access` endpoints are in
`hugmesh-admin-bff-api`, and the management view is in `hugmesh-admin-ui`.

## ✅ Implemented, ships dark — MFA-required gating (Casdoor MFA)

Implemented (admin-bff Liquibase 150-band) but ships dark. The
`gateway_route_access.mfa_required` column lets a route demand a satisfied
multi-factor challenge, enforced fail-closed at the gateway. In `hugmesh-gateway`,
`GatewayRouteAccessFilter` carries a real D8 privileged-MFA floor behind its own
sub-flag `app.mfa.enforce-privileged-floor` (default `false`: the legacy chain stays
byte-identical until an operator flips it). `GatewayRouteAccessService`'s
`mfa_required`/`MFA_SATISFIED` decision logic backs it. The factor state arrives as
`amr`/`acr → MFA_SATISFIED` or, in the opaque-session world, as a `mfa_satisfied` flag
stamped into the `bff_session`. The same machinery backs several real **step-up**
gate classes in `admin-bff-api` (sudo, SSH-via-UI, remote-install, image-gen,
cloud-backups and workload-console ops). Per-role defaults: superadmin and admin
required, mod relaxable, user optional.
