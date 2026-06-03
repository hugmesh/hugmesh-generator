# Per-gateway role→URL external access control

Admins control, **per gateway**, which Casdoor roles/users may reach which URLs
from outside the gateway (i.e. from the VPN/cloud). This is the
`snapdragon-id-gateway` Postgres-backed-routes pattern, minus the random
per-app URL generation — just role-based external access locking to the
already-known services.

## Data model (Postgres + Cassandra cache)

- **Source of truth:** Postgres table `gateway_route_access`
  ([schema.sql](../specs/cluster/manifests/route-access/schema.sql)) —
  `(gateway, url_pattern, role, casdoor_user?, allow)`.
- **Cache:** each gateway caches its rows in **Cassandra** and refreshes on a
  tick (same mechanism as the gateways' existing revocation-list / URL-registry
  caches), so an admin change propagates within one refresh interval.
- **Roles owned by Casdoor:** `role` references a Casdoor role; `casdoor_user`
  optionally pins a specific Casdoor user. The gateway already converts the
  Casdoor JWT claims to Spring authorities (`ROLE_*`).

## Enforcement (in each snapdragon-*-gateway)

On every request the gateway:
1. loads its access rules (Cassandra cache, backed by Postgres at boot),
2. matches the request path against `url_pattern` for **its** gateway,
3. **allows only if** the caller's Casdoor roles (or pinned user) match an
   `allow` rule; otherwise 403. No external login is exposed; the public
   `/api/auth`,`/login`,`/api/registration` paths are seeded as `ROLE_USER`.

Each gateway is pointed at the store via `ROUTE_ACCESS_R2DBC_URL`
(set in `apps/20-gateway-*.yaml`).

## Admin API + UI

- **admin-api** (Spring, backend namespace, behind the gateway): CRUD on
  `gateway_route_access` (`GET/POST/PUT/DELETE /api/admin/route-access`),
  reaching Casdoor for role/user lookups through the snapdragon-pki gateway
  (JWT) — never calling Casdoor directly except for OAuth2 grants.
- **admin-ui** (`snapdragon-admin-ui`, ROLE_ADMIN only): a "Gateway access"
  view to list/add/remove `(gateway, url_pattern, role/user, allow)` rules.
- For the integration stack, the mock BFF exposes `/bff/admin/route-access`
  CRUD and the admin UI renders the table (see tests).

## Status

Schema + contract + gateway wiring (`ROUTE_ACCESS_R2DBC_URL`) are here. The
enforcing filter (Spring Cloud Gateway `ResourceAccessFilter` reading
Postgres→Cassandra) lives in `snapdragon-gateway`, the CRUD endpoints in the
Spring admin-api, and the management view in `snapdragon-admin-ui` — to be
implemented against this schema.
