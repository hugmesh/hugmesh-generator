# The executable Gherkin form of tests/e2e/specs/12-rbac-gateway-route-access.spec.ts.
#
# WHAT IT ASSERTS. The gateway_route_access CONTRACT (manifests/route-access/
# schema.sql) for the full systems role matrix: each persona's EFFECTIVE role-set
# (granted roles + the derived ROLE_GAMES_ADMIN when it qualifies) is run against
# the authoritative table via specs/rbac-route-access.ts `gatewayDecision`, and the
# expected ALLOW/DENY is asserted at every contractually-interesting URL.
#
# WHY IT IS A CONTRACT AND NOT A LIVE DENY. The fe/be/pki gateways that ENFORCE
# this table are README-only today (Phase 8/10). The oracle encodes schema.sql, so
# the RBAC posture is locked in NOW; features/rbac/live-gateway-enforcement.feature
# is the bridge that hits the running endpoint with the SAME expectations the
# moment LIVE_GATEWAY=1 is set. Both read their expectation from the one oracle,
# so contract and live can never silently diverge.
#
# THIS RUNS OFFLINE. gatewayDecision is a pure function over the route table, so
# every row below executes and passes with the stack DOWN — it is not a collection-
# only scenario.
#
# MATRIX AXES. ROLE and SERVICE both vary here, so both are Examples columns and
# both are repeated in the outline name (Gherkin tags cannot carry placeholders —
# see features/README.md §2b). PLATFORM is deliberately NOT an axis: the route
# table is one artefact shipped identically to rpi5 and x86, and evaluating a pure
# function twice would be a fabricated matrix row, which is exactly what this lane
# exists to avoid.
@layer:gateway
Feature: Gateway route-access ALLOW/DENY across the systems role matrix

  Scenario Outline: <role> is <decision> at <gateway> <path> @role:<role> @service:<service> @layer:gateway
    Given the persona for this scenario presents its effective role set
    When the "<gateway>" gateway evaluates the request path "<path>"
    Then the gateway route-access decision is "<decision>"

    # fe-gateway /admin/** = ROLE_ADMIN. ROLE_MOD is a SIBLING, not a superset.
    Examples:
      | role           | service | gateway            | path                          | decision |
      | e2e-admin      | admin   | hugmesh-fe-gateway | /admin/usage                  | ALLOW    |
      | e2e-adminonly  | admin   | hugmesh-fe-gateway | /admin/usage                  | ALLOW    |
      | e2e-mod        | admin   | hugmesh-fe-gateway | /admin/usage                  | DENY     |
      | e2e-gamesonly  | admin   | hugmesh-fe-gateway | /admin/usage                  | DENY     |
      | e2e-user       | admin   | hugmesh-fe-gateway | /admin/usage                  | DENY     |

    # be-gateway /api/admin/** and fe-gateway /bff/admin/** = ROLE_ADMIN.
    Examples:
      | role           | service | gateway            | path                          | decision |
      | e2e-admin      | admin   | hugmesh-be-gateway | /api/admin/route-access       | ALLOW    |
      | e2e-mod        | admin   | hugmesh-be-gateway | /api/admin/route-access       | DENY     |
      | e2e-user       | admin   | hugmesh-be-gateway | /api/admin/route-access       | DENY     |
      | e2e-admin      | admin   | hugmesh-fe-gateway | /bff/admin/allowlist          | ALLOW    |
      | e2e-mod        | admin   | hugmesh-fe-gateway | /bff/admin/allowlist          | DENY     |

    # akkoma moderation REST = ROLE_MOD, with ROLE_ADMIN as the paired superset.
    Examples:
      | role           | service | gateway            | path                          | decision |
      | e2e-mod        | akkoma  | hugmesh-be-gateway | /api/v1/pleroma/admin/config  | ALLOW    |
      | e2e-admin      | akkoma  | hugmesh-be-gateway | /api/v1/pleroma/admin/config  | ALLOW    |
      | e2e-user       | akkoma  | hugmesh-be-gateway | /api/v1/pleroma/admin/config  | DENY     |

    # PER-PLATFORM ACCESS floor (commit 0100d3b). The broad ROLE_USER homeserver
    # floor was REMOVED: plain ROLE_USER no longer reaches Matrix or Mastodon, and
    # only a ROLE_MATRIX / ROLE_MASTODON holder (or a MOD/ADMIN superset) does.
    Examples:
      | role           | service | gateway            | path                          | decision |
      | e2e-mod        | tuwunel | hugmesh-be-gateway | /_matrix/client/v3/sync       | ALLOW    |
      | e2e-matrix     | tuwunel | hugmesh-be-gateway | /_matrix/client/v3/sync       | ALLOW    |
      | e2e-user       | tuwunel | hugmesh-be-gateway | /_matrix/client/v3/sync       | DENY     |
      | e2e-mod        | akkoma  | hugmesh-be-gateway | /api/v1/timelines/home        | ALLOW    |
      | e2e-mastodon   | akkoma  | hugmesh-be-gateway | /api/v1/timelines/home        | ALLOW    |
      | e2e-user       | akkoma  | hugmesh-be-gateway | /api/v1/timelines/home        | DENY     |

    # THE GAMES-ADMIN GATE. /games/admin/** + /games/api/admin/** are keyed on the
    # DERIVED ROLE_GAMES_ADMIN alone, so neither ROLE_GAMES nor ROLE_ADMIN by
    # itself admits them (default-deny on a single grant).
    Examples:
      | role           | service | gateway            | path                          | decision |
      | e2e-gamesadmin | games   | hugmesh-fe-gateway | /games/admin/sessions         | ALLOW    |
      | e2e-gamesonly  | games   | hugmesh-fe-gateway | /games/admin/sessions         | DENY     |
      | e2e-adminonly  | games   | hugmesh-fe-gateway | /games/admin/sessions         | DENY     |
      | e2e-mod        | games   | hugmesh-fe-gateway | /games/admin/sessions         | DENY     |
      | e2e-gamesadmin | games   | hugmesh-be-gateway | /games/api/admin/role-grants  | ALLOW    |
      | e2e-gamesonly  | games   | hugmesh-be-gateway | /games/api/admin/role-grants  | DENY     |
      | e2e-adminonly  | games   | hugmesh-be-gateway | /games/api/admin/role-grants  | DENY     |

    # NO RULE AT ALL — which is NOT default-deny, and the difference is the whole
    # posture of the gate. /infra appears nowhere in the seed, so
    # GatewayRouteAccessService.decide() answers NO_RULE and
    # GatewayRouteAccessFilter FORWARDS it to the coarse
    # anyExchange().authenticated() floor (docs/ROUTE-ACCESS.md, "No matching row
    # is NOT a denial"). These rows said DENY while the oracle collapsed the two;
    # main taught the oracle NO_RULE on 2026-08-26 and
    # features/mined-platform-edge/ungoverned-vs-denied.feature is the lane that
    # pinned this file as the thing to correct when it did.
    #
    # "Denied to everyone" and "rides the coarse authenticated floor" are opposite
    # security claims. Asserting the first while the mesh does the second keeps
    # reporting a closed door after somebody opens one.
    Examples:
      | role           | service | gateway            | path                          | decision |
      | e2e-admin      | gateway | hugmesh-be-gateway | /infra/logs                   | NO_RULE  |
      | e2e-mod        | gateway | hugmesh-be-gateway | /infra/logs                   | NO_RULE  |

  # The gate PROPERTY itself, not a sample of it: no single granted role reaches
  # the games-admin surfaces; only the derived intersection role does.
  Scenario: ROLE_GAMES_ADMIN is the only key on both games-admin rows @service:games @layer:gateway
    Then no single granted role reaches the games-admin surfaces on either gateway
    And only the derived role "ROLE_GAMES_ADMIN" reaches both games-admin surfaces

  # Catalogue/oracle cross-check: a drift in either the seed catalogue's
  # expectGamesAdmin flag or the intersection rule surfaces here.
  Scenario: every seed persona's derived games-admin flag agrees with its grants @layer:casdoor
    Then every seeded persona derives games-admin exactly when the intersection rule says so
