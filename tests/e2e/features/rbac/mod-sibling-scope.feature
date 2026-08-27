# The executable Gherkin form of tests/e2e/specs/16-rbac-mod-sibling-scope.spec.ts.
#
# ROLE_MOD is a SIBLING of ROLE_ADMIN, never a superset. The RBAC model (and the
# schema.sql header) is explicit: a moderator reaches Matrix (PL50) + akkoma/
# Mastodon moderation ONLY, and is DENIED infra, logs, server-admin and every
# hugmesh admin surface (/api/admin/**, /admin/**, /bff/admin/**). Observability
# (uptrace/grafana/clickhouse) has NO external gateway route at all, so
# default-deny keeps a mod off it without a rule of its own.
#
# The ROLE axis is FIXED here — every row is the moderator — so it is a TAG, not
# an Examples column (features/README.md §2a). What varies is the SERVICE and the
# path, so those are columns.
#
# The application-layer half (mod DENIED the BFF admin API) is covered live by
# features/rbac/admin-api-gating.feature. The Matrix UI's kick/power-level
# controls are gated by MATRIX power levels, not the Casdoor ROLE_MOD, so they
# deliberately do NOT stand in for this.
@role:e2e-mod @layer:gateway
Feature: ROLE_MOD reaches moderation and nothing else

  Scenario Outline: the moderator is <decision> at <path> @role:e2e-mod @service:<service> @layer:gateway
    Given the persona for this scenario presents its effective role set
    When the "<gateway>" gateway evaluates the request path "<path>"
    Then the gateway route-access decision is "<decision>"

    # ALLOW — the moderation surfaces a mod MUST reach. /_synapse/** is the
    # host-scoped Synapse-compat catch-all added by commit 0100d3b: it is the
    # GENERAL client surface, not a Matrix-admin row (Matrix admin is enforced by
    # admin-room membership, not an HTTP route), so a mod reaches it as a paired
    # superset like any other homeserver floor row.
    Examples:
      | service | gateway            | path                          | decision |
      | akkoma  | hugmesh-be-gateway | /api/v1/pleroma/admin/config  | ALLOW    |
      | akkoma  | hugmesh-be-gateway | /api/pleroma/admin/users      | ALLOW    |
      | akkoma  | hugmesh-be-gateway | /pleroma/admin/index.html     | ALLOW    |
      | tuwunel | hugmesh-be-gateway | /_matrix/client/v3/sync       | ALLOW    |
      | akkoma  | hugmesh-be-gateway | /api/v1/timelines/home        | ALLOW    |
      | akkoma  | hugmesh-be-gateway | /oauth/token                  | ALLOW    |
      | tuwunel | hugmesh-be-gateway | /_synapse/client/versions     | ALLOW    |

    # DENY — everything outside moderation, including both games-admin surfaces
    # (ROLE_MOD alone is not the derived ROLE_GAMES_ADMIN).
    #
    # THE TWO /infra ROWS ARE NO_RULE, NOT DENY, and they used to say DENY because
    # the oracle collapsed the two. They are ROUTELESS — /infra appears nowhere in
    # the seed — so the table refuses nothing there and the request rides the
    # coarse anyExchange().authenticated() floor. That is still "a moderator does
    # not get infra by way of a route-access grant", which is what this scenario
    # is about; it is NOT "the route-access table shuts the door", which is what
    # DENY claimed. See features/mined-platform-edge/ungoverned-vs-denied.feature.
    Examples:
      | service | gateway            | path                          | decision |
      | admin   | hugmesh-be-gateway | /api/admin/route-access       | DENY     |
      | admin   | hugmesh-fe-gateway | /admin/usage                  | DENY     |
      | admin   | hugmesh-fe-gateway | /bff/admin/allowlist          | DENY     |
      | gateway | hugmesh-be-gateway | /infra/vault/secret           | NO_RULE  |
      | gateway | hugmesh-be-gateway | /infra/logs                   | NO_RULE  |
      | games   | hugmesh-fe-gateway | /games/admin/sessions         | DENY     |
      | games   | hugmesh-be-gateway | /games/api/admin/role-grants  | DENY     |

  # Same path, opposite outcome — which proves the deny is about the ROLE and not
  # about the path, and that admin (a superset of moderation) also reaches the
  # moderation surface the mod is allowed.
  Scenario: the moderator's deny is about the role, not the path @role:e2e-mod @service:admin @layer:gateway
    Given the persona for this scenario presents its effective role set
    When the "hugmesh-be-gateway" gateway evaluates the request path "/api/admin/route-access"
    Then the gateway route-access decision is "DENY"
    And the persona "e2e-admin" is "ALLOW" at "/api/admin/route-access" on the "hugmesh-be-gateway" gateway
    And the persona "e2e-admin" is "ALLOW" at "/api/v1/pleroma/admin/config" on the "hugmesh-be-gateway" gateway
