# MINED FROM: specs/cluster/manifests/route-access/initdb/20-schema.sql:566,573
#             (PUBLIC rows for /bff/public/announcements/** and the EXACT path
#             /bff/public/appeal-contact)
#   AGAINST:  hugmesh-login-ui/src/app/login.routes.ts:44-50 and
#             appeal-contact.service.ts:37-43, which BOTH still carry a written
#             "GATEWAY DEPENDENCY (honest gap)" warning that the PUBLIC floor
#             "currently allowlists ONLY /bff/public/announcements/**, so an
#             anonymous /bff/public/appeal-contact fetch may 401 at the gateway
#             until a PUBLIC row is added for it".
#
# THE WARNING IS STALE — the row exists (:573). That is the small finding. The
# large one is that nothing pins it: a blocked principal has no usable session by
# construction, so if this row is ever dropped the appeal page degrades to
# {email: null} EXACTLY AS DESIGNED, shows "couldn't load the address", and the
# only people who can see the regression are the people who can no longer
# complain about it.
#
# The seed grants an EXACT path, not a prefix. That is also deliberate and also
# worth pinning: /bff/public/** would open every future sibling anonymously.

@harness @layer:gateway @service:login
Feature: A blocked principal can still reach a real appeal address

  Scenario: the appeal-contact resolver is anonymous at exactly one path @service:login @layer:gateway
    Then the route-access seed grants "PUBLIC" at "/bff/public/appeal-contact" on the fe gateway
    And the route-access seed has no fe gateway row for "/bff/public/**"
    And the route-access seed decides "ALLOW" for a principal holding only "ROLE_ANONYMOUS" at "/bff/public/appeal-contact"

  # The sibling contrast. A future /bff/public/accounts is UNGOVERNED, so the
  # gateway forwards it on the authenticated() floor and an anonymous caller is
  # 401'd by Spring Security rather than admitted — a materially different
  # answer from the PUBLIC row above, and the reason the exact-path row is not
  # widened to a prefix.
  Scenario: an anonymous caller is not admitted to the resolver's siblings @service:login @layer:gateway
    Then the route-access seed decides "NO_RULE" for a principal holding only "ROLE_ANONYMOUS" at "/bff/public/accounts"

  Scenario: the public login announcements banner is anonymous too @service:login @layer:gateway
    Then the route-access seed grants "PUBLIC" at "/bff/public/announcements/**" on the fe gateway
    And the route-access seed decides "ALLOW" for a principal holding only "ROLE_ANONYMOUS" at "/bff/public/announcements/current"

  # The appeal PAGE itself is served by the login remote, so it needs the
  # /login/** PUBLIC row as much as the resolver needs its own. Both halves or
  # neither: a reachable address on an unreachable page is not an appeal route.
  Scenario: the appeal page is reachable without a session @service:login @layer:gateway
    Then the route-access seed grants "PUBLIC" at "/login/**" on the fe gateway
    And the route-access seed decides "ALLOW" for a principal holding only "ROLE_ANONYMOUS" at "/login/appeal"
