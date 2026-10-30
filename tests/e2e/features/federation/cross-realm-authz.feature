# CROSS-REALM ROLE AUTHZ — the executable form of the exported-oracle half of
# tests/e2e/specs/26-rbac-cross-realm-matrix.spec.ts.
#
# "Realm" here is an IDENTITY realm, not the Matrix homeserver:
#   SYSTEMS  org "hugmesh", issuer id.hugmesh.net, native roles ROLE_*.
#   GAMES    org "threewizards", issuer id.hugmesh.games — an INDEPENDENT Casdoor
#            whose native roles are lowercase ('player','admin'). A games token
#            carries NO systems ROLE_*, and the games NAMESPACE surfaces on the
#            systems gateways (/games/admin/**, /games/api/admin/**) are gated on
#            the DERIVED systems ROLE_GAMES_ADMIN, never on a games-realm token.
#
# Every decision below is taken by the SHARED oracle (specs/rbac-route-access.ts,
# the mirror of manifests/route-access/20-schema.sql) that specs 12-18/25/26
# already consume — nothing is re-tabulated in the Gherkin lane, because a second
# copy of the route table is precisely the drift this suite exists to prevent.
#
# RUNS OFFLINE. No stack, no cluster: the claim is about the decision contract, and
# the live token-grant probe is spec 14/25's job (LIVE_GATEWAY=1, pending a
# kernel-fixed x86 image).
@layer:gateway
Feature: Cross-realm role authz — systems, games and superadmin tiers stay isolated

  Scenario Outline: the <gateway> answers <decision> for <role> at "<path>" @role:<role> @layer:gateway
    Then the route-access oracle decides "<decision>" for this persona at "<path>" on gateway "<gateway>"

    Examples: the games-namespace AND-gate — neither half alone earns ROLE_GAMES_ADMIN
      | role           | gateway            | decision | path                         |
      | e2e-gamesadmin | hugmesh-fe-gateway | ALLOW    | /games/admin/sessions        |
      | e2e-gamesadmin | hugmesh-fe-gateway | ALLOW    | /games/api/admin/role-grants |
      | e2e-gamesonly  | hugmesh-fe-gateway | DENY     | /games/admin/sessions        |
      | e2e-gamesonly  | hugmesh-fe-gateway | DENY     | /games/api/admin/role-grants |
      | e2e-adminonly  | hugmesh-fe-gateway | DENY     | /games/admin/sessions        |
      | e2e-adminonly  | hugmesh-fe-gateway | DENY     | /games/api/admin/role-grants |

    Examples: own-realm positive controls — each tier reaches its own resources
      | role      | gateway            | decision | path                           |
      | e2e-admin | hugmesh-fe-gateway | ALLOW    | /admin/usage                   |
      | e2e-mod   | hugmesh-be-gateway | ALLOW    | /api/v1/pleroma/admin/statuses |
      | e2e-user  | hugmesh-fe-gateway | ALLOW    | /social/matrix/room            |

    Examples: the games-admin surfaces are not reachable from the plain admin tier
      | role      | gateway            | decision | path                         |
      | e2e-admin | hugmesh-fe-gateway | DENY     | /games/admin/sessions        |
      | e2e-mod   | hugmesh-fe-gateway | DENY     | /games/api/admin/role-grants |

  Scenario: the systems and games realms are minted by distinct issuers @layer:casdoor
    Then the systems realm issuer differs from the games realm issuer

  Scenario: neither realm's seeded roles bleed into the other @layer:casdoor
    Then no seeded games-realm identity carries a systems ROLE_ prefix
    And no seeded systems identity carries a games-native role

  # ISSUER ISOLATION, the generic deny. If a systems gateway ever wrongly trusted a
  # games token, THESE are the roles it would see — and every systems, games-
  # namespace and superadmin surface must still refuse them. A generic deny, never
  # a 404-vs-403 existence leak.
  Scenario Outline: a games-realm identity is refused "<path>" on <gateway> @layer:gateway
    Then every seeded games-realm identity is denied "<path>" on gateway "<gateway>"

    Examples:
      | path                                  | gateway                    |
      | /admin/usage                          | hugmesh-fe-gateway         |
      | /api/v1/pleroma/admin/statuses        | hugmesh-be-gateway         |
      | /api/v1/timelines/home                | hugmesh-be-gateway         |
      | /_matrix/client/v3/sync               | hugmesh-be-gateway         |
      | /games/admin/sessions                 | hugmesh-fe-gateway         |
      | /games/api/admin/role-grants          | hugmesh-fe-gateway         |
      | /bff/superadmin/service-store/catalog | hugmesh-superadmin-gateway |

  # ROLE_SUPERADMIN reaches the tailnet-only cross-realm infra surface, and a
  # concrete ADMIN does not: the superadmin tier is its own tier, with NO
  # down-cascade for admin to inherit.
  Scenario Outline: the superadmin reaches "<probe>" and a concrete admin does not @role:e2e-superadmin @layer:gateway
    Then the route-access oracle decides "ALLOW" for this persona at "<probe>" on gateway "hugmesh-superadmin-gateway"
    And persona "e2e-admin" is denied "<probe>" on gateway "hugmesh-superadmin-gateway"

    Examples:
      | probe                                      |
      | /bff/superadmin/service-store/catalog      |
      | /superadmin/service-catalog/remoteEntry.js |
      | /api/federation/manifest                   |

  # …and the reach is EXACTLY that surface, not a universal superset: a bare
  # ROLE_SUPERADMIN holds no ROLE_USER on the public floor.
  Scenario: the superadmin tier grants no public user floor @role:e2e-superadmin @layer:gateway
    Then the effective roles of this persona are exactly "ROLE_SUPERADMIN"
    And the route-access oracle decides "DENY" for this persona at "/api/v1/timelines/home" on gateway "hugmesh-be-gateway"
