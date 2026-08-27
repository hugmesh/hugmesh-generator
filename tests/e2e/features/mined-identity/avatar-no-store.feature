# MINED FROM: hugmesh-user-bff-api ProfileController.java:126-153 (asImageResponse)
#             and its component test ProfileControllerAvatarTest
#             .avatarBody_isServedNoStore_neverBrowserCacheable.
#
# THE DEFECT THIS PINS, in the controller's own Javadoc: "/bff/user/profile/
# avatar/body is the SAME URL for every user — the owner comes from the JWT
# subject, never the path — and the browser HTTP cache is keyed by URL alone: it
# neither varies on the session cookie nor is emptied by sign-out. A five-minute
# freshness window therefore served the PREVIOUS user's avatar, with no request
# ever leaving the browser, after a sign-out or an account switch" (operator
# report 2026-08-19, "need to clear cache every time after log out").
#
# WHY IT IS WORTH AN E2E SCENARIO ON TOP OF THE COMPONENT TEST: the component
# test asserts the headers the CONTROLLER builds. What reaches a browser is what
# the GATEWAY forwards, and a gateway that rewrites or drops Cache-Control
# re-opens the exact hole with the controller test still green. Only an
# end-to-end read through the front door can see that.
#
# The suite has zero occurrences of "no-store" today (measured, comments
# stripped).

@layer:bff @env:docker
Feature: Identity-bearing bytes are never left in a browser cache across a sign-out

  @role:e2e-user
  Scenario: my avatar body is served no-store with hardened sniffing headers @role:e2e-user @layer:bff
    Given an API client signed in as the persona for this scenario
    And I have uploaded a 1x1 PNG avatar through the API client
    When the API client GETs "/bff/user/profile/avatar/body"
    Then the response status is 200
    And the response header "Cache-Control" contains "no-store"
    And the response header "X-Content-Type-Options" is "nosniff"
    And the response header "Content-Security-Policy" is "default-src 'none'"

  # The property the headers exist to protect, driven rather than asserted about:
  # two identities read the SAME URL and must not be handed the same bytes. Two
  # independent API contexts stand in for the sign-out — they share no cookie
  # jar, so this proves the SERVER scopes on the token; the browser-cache half is
  # what the no-store header above pins.
  @role:e2e-user
  Scenario: the same avatar URL serves different bytes to two identities @role:e2e-user @layer:bff
    Given an API client signed in as the persona for this scenario
    And I have uploaded a 1x1 PNG avatar through the API client
    When the API client GETs "/bff/user/profile/avatar/body"
    Then the response status is 200
    And the API client remembers this response body as "first-identity"
    Given an API client signed in as the seeded persona "e2e-mod"
    And I have uploaded a distinct 1x1 GIF avatar through the API client
    When the API client GETs "/bff/user/profile/avatar/body"
    Then the response status is 200
    And the API client remembers this response body as "second-identity"
    And the remembered response bodies "first-identity" and "second-identity" differ

  # The magic-byte gate behind the picker. ImageSniffer.java:10,21-32 deliberately
  # reports null for SVG ("an XML/script vector, deliberately NOT treated as a
  # cloakable raster"), so an SVG must be refused with NO upload attempted —
  # exactly the sanitized-part precedent the character-studio lane already
  # follows.
  @role:e2e-user
  Scenario: an SVG avatar is refused by the magic-byte gate, not stored @role:e2e-user @layer:bff
    Given an API client signed in as the persona for this scenario
    When I upload an SVG as my avatar through the API client
    Then the response status is 400
