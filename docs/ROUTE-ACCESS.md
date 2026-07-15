# Per-gateway role→URL external access control

Admins control, **per gateway**, which Casdoor roles/users may reach which URLs
from outside the gateway (i.e. from the VPN/cloud). This is the
`snapdragon-id-gateway` Postgres-backed-routes pattern, minus the random
per-app URL generation — just role-based external access locking to the
already-known services.

## Data model (Postgres + Cassandra cache)

- **Source of truth:** Postgres table `gateway_route_access`
  ([20-schema.sql](../specs/cluster/manifests/route-access/initdb/20-schema.sql)) —
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
   `allow` rule; otherwise 403. Casdoor's own login UI is **never** exposed through
   a gateway; the only unauthenticated login surface is the native `POST /bff/login`
   (permitAll at the BFF, seeded open so an anonymous browser can sign in), alongside
   the public `/api/auth`,`/login`,`/api/registration` paths seeded as `ROLE_USER`.

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

## ✅ Implemented, ships dark — MFA-required gating (Casdoor MFA)

Implemented (admin-bff Liquibase 150-band) but **ships dark**: the
`gateway_route_access.mfa_required` column lets a route demand a satisfied
multi-factor challenge, enforced **fail-closed** at the gateway. In
`snapdragon-gateway`, `GatewayRouteAccessFilter` carries a real D8 privileged-MFA
floor gated by its own sub-flag `app.mfa.enforce-privileged-floor` (default
`false` — byte-identical legacy chain until an operator flips it), backed by
`GatewayRouteAccessService`'s `mfa_required`/`MFA_SATISFIED` decision logic. The
factor state arrives as `amr`/`acr → MFA_SATISFIED` (or, in the opaque-session
world, a `mfa_satisfied` flag stamped into the `bff_session`), and the same
machinery backs several real **step-up** gate classes in `admin-bff-api`
(covering sudo / SSH-via-UI / remote-install / image-gen / cloud-backups /
workload-console ops). Per-role defaults: superadmin/admin required, mod
relaxable, user optional.
