# The executable Gherkin form of tests/e2e/specs/14-rbac-gateway-live.spec.ts —
# the LIVE bridge for the contract locked in features/rbac/gateway-route-access.feature.
#
# ACTIVATION. Every row below is the SAME (persona, gateway, path) triple the
# contract feature asserts offline, but driven through a real gateway with a real
# Casdoor token. It runs only when BOTH:
#   * LIVE_GATEWAY=1          — a gateway that enforces gateway_route_access is up
#   * SYSTEMS_CASDOOR_URL=...  — a real systems Casdoor seeded with the role matrix
#                                (tests/qemu/seed-accounts.sh --roles)
# Otherwise the first step SKIPS WITH A NAMED REASON: the rows stay listed and the
# skip is reported, never silent, and no row fakes a pass. The fe/be/pki gateways
# are README-only today (Phase 8/10), which is exactly why the offline contract
# lane exists alongside this one.
#
# THE EXPECTED DECISION IS NOT WRITTEN DOWN HERE. The step computes it from
# specs/rbac-route-access.ts using the persona's EFFECTIVE roles, so this feature
# and the contract feature cannot drift: change the table and both move together.
# That is also why there is no `decision` column — a hand-copied expectation is
# the drift this design removes.
#
# WHY A BARE 401/403 IS NOT THE ORACLE. Both gateways relay the caller's bearer
# verbatim (no homeserver token exchange has landed), so tuwunel's M_UNKNOWN_TOKEN
# and Mastodon refusing a Casdoor bearer both surface as 401 AFTER the gateway
# ALLOWED the route. An RBAC deny carries X-Route-Denied; a rejected token carries
# WWW-Authenticate: Bearer. Judging status codes alone misread every homeserver
# ALLOW as a deny.
@layer:gateway
Feature: LIVE gateway route-access enforcement

  Scenario Outline: <role> at <gateway> <path> is enforced as the contract says @role:<role> @service:<service> @layer:gateway
    Given a live gateway and a real systems Casdoor are configured
    When the persona for this scenario presents a real Casdoor token to the "<gateway>" gateway at "<path>"
    Then the live gateway enforcement matches the route-access contract

    Examples:
      | role           | service | gateway            | path                          |
      | e2e-admin      | admin   | hugmesh-fe-gateway | /admin/usage                  |
      | e2e-adminonly  | admin   | hugmesh-fe-gateway | /admin/usage                  |
      | e2e-mod        | admin   | hugmesh-fe-gateway | /admin/usage                  |
      | e2e-user       | admin   | hugmesh-fe-gateway | /admin/usage                  |
      | e2e-admin      | admin   | hugmesh-be-gateway | /api/admin/route-access       |
      | e2e-mod        | admin   | hugmesh-be-gateway | /api/admin/route-access       |
      | e2e-user       | admin   | hugmesh-be-gateway | /api/admin/route-access       |
      | e2e-mod        | akkoma  | hugmesh-be-gateway | /api/v1/pleroma/admin/config  |
      | e2e-admin      | akkoma  | hugmesh-be-gateway | /api/v1/pleroma/admin/config  |
      | e2e-user       | akkoma  | hugmesh-be-gateway | /api/v1/pleroma/admin/config  |
      | e2e-mod        | tuwunel | hugmesh-be-gateway | /_matrix/client/v3/sync       |
      | e2e-matrix     | tuwunel | hugmesh-be-gateway | /_matrix/client/v3/sync       |
      | e2e-user       | tuwunel | hugmesh-be-gateway | /_matrix/client/v3/sync       |
      | e2e-mod        | akkoma  | hugmesh-be-gateway | /api/v1/timelines/home        |
      | e2e-mastodon   | akkoma  | hugmesh-be-gateway | /api/v1/timelines/home        |
      | e2e-user       | akkoma  | hugmesh-be-gateway | /api/v1/timelines/home        |
      | e2e-gamesadmin | games   | hugmesh-fe-gateway | /games/admin/sessions         |
      | e2e-gamesonly  | games   | hugmesh-fe-gateway | /games/admin/sessions         |
      | e2e-adminonly  | games   | hugmesh-fe-gateway | /games/admin/sessions         |
      | e2e-mod        | games   | hugmesh-fe-gateway | /games/admin/sessions         |
      | e2e-gamesadmin | games   | hugmesh-fe-gateway | /games/api/admin/role-grants  |
      | e2e-gamesonly  | games   | hugmesh-fe-gateway | /games/api/admin/role-grants  |
      | e2e-adminonly  | games   | hugmesh-fe-gateway | /games/api/admin/role-grants  |
      | e2e-admin      | gateway | hugmesh-be-gateway | /infra/logs                   |
      | e2e-mod        | gateway | hugmesh-be-gateway | /infra/logs                   |
