# WHAT THIS ASSERTS. The service-to-service ingest subtree — admin-bff's
# /bff/internal/**, user-bff's /bff/user/internal/**, mesh-bff's
# /bff/mesh/internal/** — is closed to every human principal by an EXPLICIT
# DENY row (allow=false), not by absence from the table.
#
# WHY THE DISTINCTION IS THE WHOLE SCENARIO. The fe route table sends
# /bff/user/**, /bff/mesh/** and a /bff/** catch-all at their BFFs, and Ant
# `**` matching routes the internal receivers beneath them. With no row, an
# internal path is NO_RULE, and NO_RULE FORWARDS on the coarse authenticated()
# floor — so every logged-in ROLE_USER reached them. The deny rows close that.
# A DEFAULT deny would not: it evaporates the moment anyone adds an allow row at
# the same pattern, while an explicit deny WINS over one (deny-wins,
# GatewayRouteAccessService:218).
#
# WHY IT WAS UNCOVERED. Comment-stripped, the central suite has zero hits for
# 'bff/internal', 'ROLE_SERVICE', 'explicitDeny' or 'deny-wins' anywhere in
# specs/, features/ or steps/. It could not have had them: the mirror's RouteRule
# type carries no allow/deny field (see route-access-seed-drift.feature).
#
# THE APPLICATION LAYER IS THE SECOND WALL and it is deliberately ROLE_SERVICE —
# NOT ADMIN and NOT SUPERADMIN, because both are human-reachable. That half needs
# the hugmesh-admin-bff-api checkout and says so if it is absent.
@layer:gateway @service:gateway
Feature: The internal service-to-service plane is explicitly denied, not merely ungoverned

  Background:
    Given the cluster route-access seed is loaded

  Scenario Outline: the seed carries an explicit deny on <pattern> @layer:gateway
    Then the cluster seed carries an explicit deny row on "<pattern>" at gateway "hugmesh-fe-gateway"

    Examples:
      | pattern                  |
      | /bff/internal/**         |
      | /bff/user/internal/**    |
      | /bff/mesh/internal/**    |

  # The decision, not just the row. Each of these is DENY *and* the deny is the
  # explicit kind — the second assertion is the one the mirror cannot make.
  Scenario Outline: a <granted> principal is explicitly DENIED <path> @layer:gateway
    Given a principal holding only the role "<granted>"
    When the "hugmesh-fe-gateway" gateway decides "<path>" from the cluster seed
    Then the seed decision is "DENY"
    And the deny came from an explicit deny row
    And the deciding url pattern is "<pattern>"

    Examples:
      | granted   | path                            | pattern               |
      | ROLE_USER | /bff/internal/sessions          | /bff/internal/**      |
      | ROLE_USER | /bff/internal/session/exchange  | /bff/internal/**      |
      | ROLE_USER | /bff/user/internal/moderation   | /bff/user/internal/** |
      | ROLE_USER | /bff/mesh/internal/bridge-sync  | /bff/mesh/internal/** |

  # THE HONEST LIMIT OF THE ROW, recorded rather than glossed. The deny rows are
  # keyed on ROLE_USER, so a principal who is not a ROLE_USER (an ADMIN token
  # without the floor role) is refused here by the governed-but-ungranted DEFAULT
  # instead. That is still DENY, and it is still correct — but it is a WEAKER
  # denial, and CanonicalSeed's own note says ADMIN and SUPERADMIN short-circuit
  # in the filter BEFORE decide() is consulted at all. The app-layer SERVICE
  # floor below is what actually stops them.
  Scenario: an admin is denied the internal plane by default, not by the deny row @layer:gateway
    Given a principal holding only the role "ROLE_ADMIN"
    When the "hugmesh-fe-gateway" gateway decides "/bff/internal/sessions" from the cluster seed
    Then the seed decision is "DENY"
    And the deciding url pattern is "/bff/internal/**"

  # The second wall. SERVICE is reachable by NO human role — the hierarchy has
  # no edge into it, so not even SUPERADMIN inherits it.
  Scenario: admin-bff floors the internal subtree at ROLE_SERVICE and admits no human role @service:admin @layer:bff
    Given the security configuration of "hugmesh-admin-bff-api" is loaded
    Then the path "/bff/internal/**" requires exactly the role "SERVICE"
    And no declared hierarchy edge grants "ROLE_SERVICE"
