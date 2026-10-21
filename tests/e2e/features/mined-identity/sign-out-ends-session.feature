# hugmesh-generator#549 — "sign out redirect doesn't seem to work … still have to
# clear cookies each time". POST /bff/sessionOut (the alias host-shell and
# login-ui actually call) fell through the fe route tables to admin-bff's copy,
# which read the token from a header a browser never sends and emitted no
# expiring cookie: a sign-out that answered {"loggedOut":true} having done
# nothing. Fixed 2026-09-18 by three landings —
#   hugmesh-generator#557  both fe route tables send /bff/sessionOut to user-bff
#                          (tests/stack/gateway-routes/fe/application-routes.yml:341,
#                          specs/cluster/apps/20-gateway-fe.yaml:484)
#   hugmesh-user-bff-api#21  SsoAuthController serves it as an alias of
#                          DELETE /bff/session (reads the COOKIE, deletes the row
#                          over /bff/internal/sessions/{token}, expires the cookie)
#                          + a SecurityConfig permitAll so it is reachable at all
#   hugmesh-admin-bff-api#102  the fallback copy now reads the cookie too
#
# WHAT WAS ALREADY PINNED, AND WHAT WAS NOT. features/mined-platform-edge/
# fe-route-tables.feature pins the route SHAPE offline (which upstream the
# literal string reaches). NOTHING drove the behaviour: no scenario signed a
# persona in, called POST /bff/sessionOut and then asked the server whether the
# session still existed. The issue's own "Done when" names the test that catches
# this class of bug — model the server STATEFULLY, 200 while the session lives
# and 401 once logout lands — and records that a test which only asserts "fetch
# was called" passed the broken code. These scenarios are that stateful test,
# through the real front door, for every role tier.
#
# WHY THE ROLE MATRIX IS THE FOUR TIERS AND NOT "every persona". /bff/session and
# /bff/sessionOut carry NO route-access row on either lane (session-hydrate-path
# .feature pins that as a contract: NO_RULE, forwarded on the coarse
# authenticated() floor), so no role grants or denies the path — every
# signed-in principal reaches it, and what differs per tier is only which
# gateway branch the request takes (SUPERADMIN bypass, ADMIN own-domain bypass,
# or decide() for a plain member/mod). One row per branch is the honest matrix;
# the anonymous row is the negative half.
#
# hugmesh-generator#569 / decision 60 rides on the same proof: the BFFs' mirror of
# the positive-swap cache (APP_BFF_EXCHANGE_CACHE_TTL_MS) is pinned to 0 on both
# lanes, so a revoked session must lose its swap IMMEDIATELY — the GET that
# follows the sign-out is issued with no delay on purpose. A 5 s window would
# answer 200 here. The offline pin of the value itself is in
# session-hydrate-path.feature.
@service:login @layer:bff @env:docker
Feature: Signing out ends the session on the server and clears the cookie

  # ── the API-level stateful proof, per tier ─────────────────────────────────
  @issue:generator-549 @issue:generator-569
  Scenario Outline: <role>'s sign-out revokes the session and expires the cookie, with no positive-swap window @role:<role> @service:login @layer:bff
    Given I hold an API session as the persona for this scenario
    And the API client holds a cookie named "bff_session"
    When the API client GETs "/bff/session"
    Then the response status is 200
    When the API client POSTs "/bff/sessionOut"
    Then the response status is 204
    And the response header "Set-Cookie" contains "bff_session="
    And the response header "Set-Cookie" contains "Max-Age=0"
    And the API client holds no cookie named "bff_session"
    When the API client GETs "/bff/session"
    Then the response status is 401

    Examples:
      | role           |
      | e2e-user       |
      | e2e-mod        |
      | e2e-admin      |
      | e2e-superadmin |

  # The alias is NOT a public path: it sits on the coarse authenticated() floor
  # (hugmesh-gateway SecurityConfig PUBLIC_PATHS lists /bff/login and the
  # /bff/public/* reads, never /bff/sessionOut). An anonymous caller is refused
  # at the door — measured 401 through https://localhost:8488 on 2026-09-23 —
  # rather than reaching user-bff's idempotent no-cookie 204. Pinned so that a
  # future "make sign-out public" is a decision somebody makes, not a floor
  # change nobody noticed.
  @issue:generator-549
  Scenario: an anonymous caller is refused the sign-out alias at the door @service:login @layer:gateway
    Given I hold an anonymous API client
    When the API client POSTs "/bff/sessionOut"
    Then the response status is 401

  # ── the operator's own report, driven the way they hit it ──────────────────
  # The redirect half of #549 is asserted from the POST-LOGOUT STATE (the login
  # view is what renders), never from the call — and the cookie half is asked of
  # the browser's own jar, which is what the shell's next hydrate would use.
  @issue:generator-549 @role:e2e-user
  Scenario: a member who signs out through the shell menu lands on the login view with no live session @role:e2e-user @service:login @layer:ui
    Given I am signed in as the persona for this scenario
    And the browser holds an httpOnly cookie named "bff_session" whose value starts with "bff_"
    When I sign out through the profile menu
    Then the element with test id "login-view" is visible
    And the URL matches "/login"
    And a browser GET to "/bff/session" answers 401
    And the browser holds no cookie named "bff_session"
