# UNGOVERNED is not DENIED — and the difference is the whole posture of the gate.
#
# THE ORACLE USED TO COLLAPSE THEM. gatewayDecision()'s `if (best < 0) return
# 'DENY'` meant "no pattern matched" and "matched but not granted" came back
# identical, and features/rbac/gateway-route-access.feature's DEFAULT-DENY block
# read that as the contract: e2e-admin and e2e-mod both DENY at /infra/logs.
# main taught the oracle NO_RULE, this lane's tripwire fired, and that block now
# says NO_RULE — which is what the tripwire below existed to make happen.
#
# THE GATE DOES NOT. GatewayRouteAccessService.decide() returns a THIRD value,
# NO_RULE, for a path no url_pattern matches, and only Decision.DENY rejects — a
# NO_RULE request continues to the coarse SecurityConfig floor, which for
# /infra/logs is anyExchange().authenticated(). /infra appears NOWHERE in the
# 150-row seed (measured: zero occurrences of the string), so it is ungoverned by
# the table, not refused by it.
#
# WHY IT MATTERS RATHER THAN BEING PEDANTRY. "This path is denied to everyone" and
# "this path has no rule and rides the coarse authenticated floor" are opposite
# security claims, and a suite that reports the first while the mesh does the
# second will keep reporting a closed door after somebody opens one.
#
# RUNS OFFLINE. Both authorities are committed artefacts; the divergence is pinned
# from both sides so the day the oracle grows NO_RULE, the second scenario fails
# and names the follow-up.
@harness @layer:gateway @service:gateway
Feature: An ungoverned path is not the same thing as a denied path

  Scenario: /infra/logs is governed by no route-access row at all @layer:gateway @service:gateway
    Then the route-access seed has no "hugmesh-be-gateway" gateway row matching the request path "/infra/logs"

  Scenario Outline: the seed leaves /infra/logs ungoverned for <role> @role:<role> @layer:gateway @service:gateway
    Given the persona for this scenario presents its effective role set
    When the seeded route-access table is evaluated for the path "/infra/logs" on the "hugmesh-be-gateway" gateway
    Then the seeded route-access decision is "NO_RULE"

    Examples:
      | role      |
      | e2e-admin |
      | e2e-mod   |
      | e2e-user  |

  # WAS THE TRIPWIRE, NOW THE AGREEMENT. The oracle used to answer DENY for these
  # three personas at this path while the seed said NO_RULE; the scenario existed
  # so that the day the oracle learned NO_RULE it would fail and name
  # features/rbac/gateway-route-access.feature's DEFAULT-DENY block as the thing
  # to correct. Both happened at the 2026-08-26 integration, so the two
  # authorities now agree and this asserts the agreement.
  Scenario Outline: the oracle and the seed both report NO_RULE for <role> @role:<role> @layer:gateway @service:gateway
    Then the route-access oracle decides "NO_RULE" for a caller holding "<roles>" at "/infra/logs" on the "hugmesh-be-gateway" gateway

    Examples:
      | role      | roles                 |
      | e2e-admin | ROLE_USER,ROLE_ADMIN  |
      | e2e-mod   | ROLE_USER,ROLE_MOD    |
      | e2e-user  | ROLE_USER             |

  # The contrast that gives NO_RULE its meaning: a GOVERNED path with no grant for
  # this caller really is DENY, and the seed says so at the same gateway.
  Scenario: a governed-but-ungranted path really is denied @role:e2e-user @layer:gateway @service:gateway
    Given the persona for this scenario presents its effective role set
    When the seeded route-access table is evaluated for the path "/api/admin/route-access" on the "hugmesh-be-gateway" gateway
    Then the seeded route-access decision is "DENY"
