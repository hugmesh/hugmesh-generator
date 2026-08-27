# Character Studio (2D) and Character Forge (3D) — the first e2e coverage either
# remote has ever had as a ROUTE OF ITS OWN.
#
# Character Forge was reachable in exactly one existing spec (32), and only
# sideways: through the Matrix chat3d join menu, never at /character-forge.
# Character Studio had nothing at all. Both are mounted in the host shell behind
# registeredGuard — any FULLY REGISTERED identity, no per-service role — which
# makes them the two services in this domain the ordinary seeded roster can drive
# as their real audience rather than as an admin standing in for one.
#
# DEPTH, HONESTLY. These scenarios prove the route resolves, the remote is
# fetched and mounted under the host shell, and the editor chrome renders. They
# do NOT drive the WebGL/engine surface: the forge's 3D engine reports through
# cf-engine-loading / cf-engine-absent / cf-engine-error, and asserting a
# headless-Chromium GPU path would be asserting the harness, not the product.
# Deeper flows (part picking, export, avatar upload) belong in a follow-up that
# can be checked against a live stack.
#
# alice@gmail.com is deliberately in the Examples: it is an EMAIL-shaped persona
# handle, and the '@' and '.' in it are exactly what the reporter's @role: tag
# parser used to swallow (every email persona collapsed to its local part until
# the harness unit fixed it). A matrix row that exercises the parser is cheaper
# than a test for the parser.
@layer:ui
Feature: The character remotes mount under the host shell for any registered member

  Scenario Outline: <role> opens Character Studio and the layered editor mounts @role:<role> @service:character-studio @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/character-studio"
    Then the URL matches "/character-studio"
    And the level 1 heading "Character Studio" is visible
    And the element with test id "cs-status" is visible

    Examples:
      | role            |
      | e2e-user        |
      | alice@gmail.com |

  Scenario Outline: <role> opens Character Forge and the forge header mounts @role:<role> @service:character-forge @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/character-forge"
    Then the URL matches "/character-forge"
    And the level 1 heading "Character Forge" is visible
    And the element with test id "cf-header" is visible
    And the element with test id "cf-status" is visible

    Examples:
      | role            |
      | e2e-user        |
      | alice@gmail.com |

  # The anonymous floor. Both remotes are behind an authgate, so a visitor with
  # no session is sent to the native sign-in form — NOT shown an empty shell,
  # which is what a missing guard would produce and what an "is the page there"
  # assertion would happily accept.
  @service:character-studio @layer:ui
  Scenario: an anonymous visitor is sent to native sign-in from Character Studio @layer:ui @service:character-studio
    When I open the path "/character-studio"
    Then the URL matches "/login"
    And the element with test id "login-username" is visible

  @service:character-forge @layer:ui
  Scenario: an anonymous visitor is sent to native sign-in from Character Forge @layer:ui @service:character-forge
    When I open the path "/character-forge"
    Then the URL matches "/login"
    And the element with test id "login-username" is visible
