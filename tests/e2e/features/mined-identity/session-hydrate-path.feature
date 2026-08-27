# MINED FROM: hugmesh-user-bff-api SsoAuthController.java:176-183 — GET
#             /bff/session is documented "PermitAll + cookie-authenticated (NO
#             JWT) so the login SPA can hydrate its session straight after login
#             — when the browser holds only the bff_ cookie, not a
#             gateway-minted JWT (which is what /me requires)".
#             tests/stack/gateway-routes/fe/application-routes.yml:270 routes it.
#             specs/cluster/manifests/route-access/initdb/20-schema.sql seeds NO
#             row for it and no /bff/** catch-all (measured with comments
#             stripped: zero hits for '/bff/session' and for "'/bff/**'").
#
# WHY A ROW-LESS PATH IS A CONTRACT AND NOT AN OVERSIGHT. The gateway
# distinguishes three answers, not two (GatewayRouteAccessService.Decision):
# ALLOW, DENY and NO_RULE — and GatewayRouteAccessFilter FORWARDS NO_RULE on the
# coarse authenticated() floor. /bff/session lands in NO_RULE today. That is what
# lets the login SPA hydrate holding only the opaque bff_ cookie. Add a
# role-gated row and every user is locked out of their own sign-in; add a
# `/bff/**` floor and it inherits one by accident.
#
# The suite already USES this endpoint in nine places (specs 15/28/29/30,
# helpers.ts, four step files) to read a session — and nowhere asserts that the
# door it walks through is open by design.

@harness @layer:gateway @service:login
Feature: The cookie-only session hydrate path stays reachable

  Scenario: /bff/session is routed to user-bff at the front door @service:login @layer:gateway
    Then the fe gateway routes "/bff/session" to the "hugmesh-user-bff-api" upstream
    And the fe gateway routes "/bff/session/**" to the "hugmesh-user-bff-api" upstream

  # Deliberately row-less. If it ever needs a row it must be PUBLIC, decided
  # deliberately — never inherited from a floor someone added above it.
  Scenario: /bff/session is deliberately row-less, and no /bff/** floor may shadow it @service:login @layer:gateway
    Then the route-access seed has no fe gateway row for "/bff/session"
    And the route-access seed has no fe gateway row for "/bff/**"
    And the route-access seed decides "NO_RULE" for a principal holding only "ROLE_ANONYMOUS" at "/bff/session"
    And the route-access seed decides "NO_RULE" for a principal holding only "ROLE_USER" at "/bff/session"

  # The contrast that keeps the scenario above from passing vacuously: the
  # SIBLING the login SPA cannot use before it holds a JWT is governed, so
  # "NO_RULE" is a real property of /bff/session and not of the whole prefix.
  Scenario: the JWT-authenticated sibling /bff/me IS governed @service:login @layer:gateway
    Then the route-access seed grants "ROLE_USER" at "/bff/me/**" on the fe gateway
    And the route-access seed decides "DENY" for a principal holding only "ROLE_ANONYMOUS" at "/bff/me"
