# MINED FROM: specs/cluster/manifests/route-access/initdb/20-schema.sql:618-644
#             (the SERVICE-ONLY INTERNAL INGEST block and its three allow=false
#             rows), against tests/e2e/specs/rbac-route-access.ts:30-35 — whose
#             RouteRule interface has gateway/urlPattern/role and NO `allow`
#             field, so these rows are UNMODELLABLE by the mirror every other
#             @layer:gateway scenario asks.
#   BACKED BY: hugmesh-user-bff-api RawApiDenyOwnerScopedIdorTest,
#             "POST /bff/user/internal/notifications: ROLE_USER is FORBIDDEN
#             (ROLE_SERVICE only)" — the app-side wall. This feature is the
#             FRONT-DOOR wall, which is a different wall and fails differently.
#
# WHY IT MATTERS, in the seed's own words (:625-640): `/bff/**` is Ant-matched,
# so a `**` floor SUBSUMES every deeper path under it. Without these rows the
# DECIDING (longest-matching) rule for an internal path is the tier floor above
# it — any ROLE_USER would reach user-bff's `/bff/user/internal/**`, which is the
# mesh-device registry and the PENDING->ACTIVE character-moderation flip.
#
# AN ABSENT ROW IS NOT A DENY. That is the whole subtlety here and the reason
# there is a separate step for it: a scenario asserting only that a row EXISTS
# stays green when someone flips allow=false to allow=true.

@harness @layer:gateway
Feature: The service-only internal ingest surfaces are explicitly denied at the front door

  Scenario Outline: <pattern> is an EXPLICIT deny row, not merely an absent one @layer:gateway
    Then the route-access seed DENIES "ROLE_USER" at "<pattern>" on the fe gateway

    Examples:
      | pattern               |
      | /bff/user/internal/** |
      | /bff/mesh/internal/** |
      | /bff/internal/**      |

  # Longest-pattern-wins is what makes the deny row effective, and it is the leg
  # a row-existence assertion cannot see. /bff/user/** (17 chars) grants;
  # /bff/user/internal/** (21) denies; the deny must be the DECIDING rule.
  Scenario: the internal ingest deny outranks the /bff/user/** authenticated floor @layer:gateway
    Then the route-access seed grants "ROLE_USER" at "/bff/user/**" on the fe gateway
    And the route-access seed DENIES "ROLE_USER" at "/bff/user/internal/**" on the fe gateway
    And the route-access seed decides "ALLOW" for a principal holding only "ROLE_USER" at "/bff/user/profile"
    And the route-access seed decides "DENY" for a principal holding only "ROLE_USER" at "/bff/user/internal/mesh-devices"

  Scenario: the mesh bridge-sync ingest is denied beneath the ROLE_MESH floor @layer:gateway
    Then the route-access seed grants "ROLE_MESH" at "/bff/mesh/**" on the fe gateway
    And the route-access seed DENIES "ROLE_USER" at "/bff/mesh/internal/**" on the fe gateway
    And the route-access seed decides "ALLOW" for a principal holding only "ROLE_MESH" at "/bff/mesh/devices"
    And the route-access seed decides "DENY" for a principal holding only "ROLE_MESH" at "/bff/mesh/internal/bridge-sync"
    And the route-access seed decides "DENY" for a principal holding only "ROLE_USER" at "/bff/mesh/internal/bridge-sync"

  # admin-bff's own SecurityConfig permitAll()s this prefix — its
  # InternalTokenWebFilter is the only app-side wall and is inert while
  # app.internal.token is unset. The gateway row is therefore load-bearing on its
  # own, not defence-in-depth.
  Scenario: the admin-bff internal API is denied to every authenticated member @layer:gateway
    Then the route-access seed DENIES "ROLE_USER" at "/bff/internal/**" on the fe gateway
    And the route-access seed decides "DENY" for a principal holding only "ROLE_USER" at "/bff/internal/accounts"
    And the route-access seed decides "DENY" for a principal holding only "ROLE_ADMIN" at "/bff/internal/accounts"
