# MINED FROM: specs/cluster/manifests/route-access/initdb/20-schema.sql
#             :514 /login/**  :524 /user/**  :566 /bff/public/announcements/**
#             :573 /bff/public/appeal-contact  :579 /bff/login  :582 /bff/me/**
#             :615 /bff/mod/**  :617 /bff/user/**
#   AGAINST:  tests/e2e/specs/rbac-route-access.ts:37 ("copied 1:1 from
#             manifests/route-access/schema.sql. Keep in lockstep with that file.")
#
# WHY THIS FILE EXISTS. features/rbac/gateway-route-access.feature is the suite's
# only ALLOW/DENY matrix and it covers admin, games and the two homeserver
# surfaces. The IDENTITY tier — the paths every ordinary member uses every time
# they sign in — has no row asserted anywhere: `/user/**` (the user remote),
# `/bff/user/**` (its BFF), `/bff/me/**` (the session view), `/bff/mod/**` (the
# moderation BFF) and the two anonymous `/bff/public/*` rows.
#
# WHAT IT DECIDES AGAINST, AND WHY THAT IS NOT THE SAME FILE. Every existing
# @layer:gateway scenario asks the TS mirror (specs/rbac-route-access.ts). The
# mirror carries 50 rows against the seed's ~150 and has no `allow` column at
# all. Measured, not read: running its own gatewayDecision() over these six
# identity paths returns DENY for every one of them, because the rows are simply
# absent — and an absent row is indistinguishable from a correct default-deny.
# So these scenarios decide against the SEED, through a port of the real
# net.hugmesh.gateway GatewayRouteAccessService.decide(), and the drift itself is
# measured once, at the bottom, by a scenario tagged @fail.

@harness @layer:gateway
Feature: The identity tier of the route-access seed is a governed contract

  # Both halves matter and neither implies the other: the ROW proves the seed
  # still carries the grant, the DECISION proves the grant actually reaches the
  # concrete URL the UI calls once Ant matching and longest-pattern-wins have had
  # their say. A row on /bff/user/** is worth nothing if a longer row shadows it.
  Scenario Outline: <access_role> reaches <path> through the route-access seed @layer:gateway
    Then the route-access seed grants "<access_role>" at "<pattern>" on the fe gateway
    And the route-access seed decides "ALLOW" for a principal holding only "<access_role>" at "<path>"

    Examples:
      | access_role | pattern      | path               |
      | ROLE_USER   | /bff/user/** | /bff/user/profile  |
      | ROLE_USER   | /bff/user/** | /bff/user/sessions |
      | ROLE_USER   | /user/**     | /user              |
      | ROLE_USER   | /user/**     | /user/preferences  |
      | ROLE_USER   | /bff/me/**   | /bff/me            |
      | ROLE_MOD    | /bff/mod/**  | /bff/mod/findings  |
      | ROLE_MOD    | /mod/**      | /mod/console       |

  # The floor is a FLOOR, not a skeleton key: holding it must not reach the tier
  # above. This is the negative half the ALLOW rows above cannot prove.
  Scenario Outline: <access_role> is refused <path> by the route-access seed @layer:gateway
    Then the route-access seed decides "DENY" for a principal holding only "<access_role>" at "<path>"

    Examples:
      | access_role | path                 |
      | ROLE_USER   | /bff/mod/findings    |
      | ROLE_USER   | /mod/console         |
      | ROLE_USER   | /bff/admin/allowlist |
      | ROLE_MOD    | /bff/admin/allowlist |
      | ROLE_MOD    | /admin/usage         |

  # login-ui is served before anyone has a credential. A role-gated row on either
  # of these locks every user out of their own sign-in, and the failure would look
  # like the mesh being down rather than like a policy change.
  Scenario: the login front door is anonymous in the seed @service:login @layer:gateway
    Then the route-access seed grants "PUBLIC" at "/login/**" on the fe gateway
    And the route-access seed grants "PUBLIC" at "/bff/login" on the fe gateway
    And the route-access seed decides "ALLOW" for a principal holding only "ROLE_ANONYMOUS" at "/login/appeal"
    And the route-access seed decides "ALLOW" for a principal holding only "ROLE_ANONYMOUS" at "/bff/login"

  # THE DRIFT ITSELF, measured once. @fail because it is a DEFECT DETECTOR: the
  # mirror is stale today, playwright-bdd maps @fail to test.fail(), and the day
  # someone refreshes specs/rbac-route-access.ts this scenario turns "expected to
  # fail, but passed" and forces the tag off. The mirror is deliberately NOT
  # edited from this branch — several lanes assert against it concurrently.
  @fail
  Scenario: the TS route-access mirror still claims to be the seed copied 1:1 @layer:gateway
    Then the route-access oracle mirrors every fe gateway allow row in the seed
