# The executable Gherkin form of part (i) of
# tests/e2e/specs/25-rbac-cross-realm-superadmin.spec.ts.
#
# The infra App-Store/console is served by its OWN tailnet-only gateway
# (hugmesh-superadmin-gateway, specs/cluster/apps/22-gateway-superadmin.yaml), and
# EVERY route under that gateway name is ROLE_SUPERADMIN in gateway_route_access.
#
# THE LOAD-BEARING CLAIM IS THE NEGATIVE ONE: ROLE_SUPERADMIN is a DISTINCT TIER,
# not a superset ROLE_ADMIN inherits, so there is NO down-cascade. That is why the
# deny rows below name BARE ROLE-SETS rather than personas — the property is about
# the role, and a bare role-set is the only way to state "holding nothing but this
# role". Personas cannot express it: e2e-admin also carries ROLE_USER.
#
# e2e-superadmin deliberately does NOT carry ROLE_ADMIN in the seed catalogue, so
# an ALLOW on a superadmin route can only come from the superadmin tier and never
# from role bleed.
#
# Runs OFFLINE against the schema.sql oracle. The LIVE probe against a real
# tailnet gateway is NOT ported — see the unit report's honest gaps.
@service:gateway @layer:gateway
Feature: The ROLE_SUPERADMIN tier does not cascade down to admin

  Scenario: the superadmin persona holds its own tier and nothing else @role:e2e-superadmin @layer:casdoor
    Then the persona named by the role dimension is seeded
    And the persona for this scenario holds exactly the roles "ROLE_SUPERADMIN"
    And the persona for this scenario does not derive the games-admin role

  Scenario Outline: the superadmin reaches <probe> (<what>) @role:e2e-superadmin @service:gateway @layer:gateway
    Given the persona for this scenario presents its effective role set
    When the "hugmesh-superadmin-gateway" gateway evaluates the request path "<probe>"
    Then the gateway route-access decision is "ALLOW"

    Examples:
      | probe                                       | what                          |
      | /bff/superadmin/service-store/catalog       | Service Catalog BFF           |
      | /superadmin/service-catalog/remoteEntry.js  | service-catalog-ui remote     |
      | /api/federation/manifest                    | federation manifest/bundles   |

  Scenario Outline: a principal holding only <granted> is DENIED <probe> @service:gateway @layer:gateway
    Given a principal holding only the role "<granted>"
    When the "hugmesh-superadmin-gateway" gateway evaluates the request path "<probe>"
    Then the gateway route-access decision is "DENY"

    Examples:
      | granted          | probe                                       |
      | ROLE_ADMIN       | /bff/superadmin/service-store/catalog       |
      | ROLE_ADMIN       | /superadmin/service-catalog/remoteEntry.js  |
      | ROLE_ADMIN       | /api/federation/manifest                    |
      | ROLE_MOD         | /bff/superadmin/service-store/catalog       |
      | ROLE_MOD         | /superadmin/service-catalog/remoteEntry.js  |
      | ROLE_MOD         | /api/federation/manifest                    |
      | ROLE_GAMES_ADMIN | /bff/superadmin/service-store/catalog       |
      | ROLE_GAMES_ADMIN | /superadmin/service-catalog/remoteEntry.js  |
      | ROLE_GAMES_ADMIN | /api/federation/manifest                    |
      | ROLE_USER        | /bff/superadmin/service-store/catalog       |
      | ROLE_USER        | /superadmin/service-catalog/remoteEntry.js  |
      | ROLE_USER        | /api/federation/manifest                    |

  # The strongest form of the down-cascade: a REAL admin identity's whole
  # effective role-set is denied every superadmin route, not just a bare role.
  Scenario: a concrete admin identity reaches no superadmin route at all @role:e2e-admin @service:gateway @layer:gateway
    Then the persona for this scenario is DENIED every superadmin-gateway route

  # The gateway NAME scopes the decision: the same path is public-floor on one
  # gateway and superadmin-only on the other.
  Scenario: the same federation path is ROLE_USER on the be-gateway and ROLE_SUPERADMIN on the tailnet one @service:gateway @layer:gateway
    Then the gateway NAME scopes "/api/federation/manifest": ROLE_USER reaches it on the be-gateway but not on the superadmin-gateway
