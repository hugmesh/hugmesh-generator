# hugmesh-generator#480 — the cluster fe route table's `/bff/me/**` -> user-bff
# entry swallowed admin-bff's self-service BAN-APPEAL surface
# (AccountAppealUserController, @RequestMapping("/bff/me/appeal"): POST files
# your own appeal, GET reads your own history). user-bff has no such mapping,
# so through a cluster front door a curtailed member's appeal was a 404 — on
# the one surface whose caller is, by definition, least able to route around
# a failure. Fixed by #558 (08652ea3, 2026-09-18): an exact-path
# `hugmesh-admin-bff-api-me-appeal` route declared ABOVE `/bff/me/**` on the
# cluster table. Compose was never affected: its user-bff entry is an
# exact-path list, so /bff/me/appeal falls to the /bff/** admin-bff catch-all.
#
# WHAT WAS PINNED, AND WHAT WAS NOT. fe-route-tables.feature pins the route
# SHAPE on both tables, offline. The issue's own "Not settled live" caveat and
# its land comment both say what remains: one GET and one POST to
# /bff/me/appeal THROUGH THE REAL FRONT DOOR carrying a valid bff_ session,
# reaching AccountAppealUserController rather than a 404. Nobody has done that.
#
# WHY GET AND NOT POST. The controller resolves the caller from the durable
# session first (store.sessionOf — the cookie SessionCookieWebFilter bridges
# into the Authorization header), and BOTH verbs share that resolver, so a GET
# that answers the caller's own history (200, a JSON array) proves the same
# routing + identity chain a POST would — without filing an appeal row into
# the operator's Account appeals inbox on every run. hugmesh-generator#311's
# manual plan uses that inbox as its P6 baseline (`[]`), so a POST here would
# quietly break the human test it exists beside. The POST is left to that plan.
#
# WHY NOT ONLY A CURTAILED PERSONA. The survey that planned this file gated it
# on "a suspended/curtailed persona, which no seeder creates". That is true —
# and it is also not what the routing defect needs: #311's plan (step 10)
# files both appeals BEFORE the ban, as an ordinary active member, precisely
# because the gateway 401s a banned session everywhere. An ACTIVE member's
# GET is therefore the honest live probe of #480; the curtailed leg stays
# PENDING in blocked-signin-appeal.feature with its seeder gap named.
#
# THE ROLE MATRIX. /bff/me/** is a ROLE_USER row (20-schema.sql:629), so every
# ROLE_USER holder reaches it; SUPERADMIN and ADMIN reach it on their gateway
# bypasses; a ROLE_MOD-only persona is denied at the door with X-Route-Denied
# (never reaching admin-bff); anonymous is refused by the floor. e2e-banned is
# in the allowed set on purpose — seeded as a bare ROLE_USER, it is the
# post-ban persona whose appeal history a person will want to read first.
@service:admin @layer:bff
Feature: The ban-appeal surface is reachable behind /bff/me on both lanes

  @issue:generator-480
  Scenario Outline: <role> reads their own appeal history through /bff/me/appeal on the <env> lane @role:<role> @env:<env> @service:admin @layer:bff
    Given I hold an API session as the persona for this scenario
    When the API client GETs "/bff/me/appeal"
    Then the response status is 200
    And the response body is a JSON array
    And the response carries no header "X-Route-Denied"

    Examples:
      | role           | env    |
      | e2e-user       | docker |
      | e2e-banned     | docker |
      | e2e-admin      | docker |
      | e2e-superadmin | docker |
      | e2e-user       | kind   |
      | e2e-banned     | kind   |
      | e2e-admin      | kind   |
      | e2e-superadmin | kind   |

  @issue:generator-480
  Scenario Outline: <role> is refused /bff/me/appeal at the door on the <env> lane @role:<role> @env:<env> @service:admin @layer:gateway
    Given I hold an API session as the persona for this scenario
    When the API client GETs "/bff/me/appeal"
    Then the response status is 403
    And the response header "X-Route-Denied" contains "/bff/me/appeal"

    Examples:
      | role    | env    |
      | e2e-mod | docker |
      | e2e-mod | kind   |

  @issue:generator-480
  Scenario Outline: an anonymous caller is refused /bff/me/appeal on the <env> lane @env:<env> @service:admin @layer:gateway
    Given I hold an anonymous API client
    When the API client GETs "/bff/me/appeal"
    Then the response status is 401

    Examples:
      | env    |
      | docker |
      | kind   |
