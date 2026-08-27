# MINED FROM: hugmesh-host-shell/src/app/guards/role-home.guard.ts:39-45 —
#             no session -> /login; session.curtailed() -> /login/appeal;
#             otherwise -> /user, for EVERYONE.
#             app.routes.ts:193 — { path: '**', redirectTo: '' }, so every
#             unknown path funnels through that same guard rather than a 404.
#
# THREE BEHAVIOURS, NONE COVERED.
#
#  (a) EVERYONE lands on /user now, deliberately (issue #19). The old role-home
#      mapping made the moderation console an operator's landing page. That is an
#      explicit operator requirement and nothing anywhere protects it, so the
#      next person to "restore" a role-aware home has no failing test to stop
#      them.
#  (b) The wildcard makes a typo'd URL resolve through the front-door decision
#      instead of dead-ending. Signed in it is /user; signed out it is /login —
#      the SAME two answers, which is the property worth pinning.
#  (c) The curtailed short-circuit to /login/appeal. Undrivable: see below.

@layer:ui @env:docker
Feature: The shell's front door resolves one way for everyone

  Scenario Outline: a signed-in <role> lands on the member home, not a console @role:<role> @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/"
    Then the URL matches "/user"

    Examples:
      | role           |
      | e2e-user       |
      | e2e-mod        |
      | e2e-admin      |
      | e2e-superadmin |

  Scenario: an anonymous visitor to the front door is sent to sign in @layer:ui
    When I open the path "/"
    Then the URL matches "/login"

  @role:e2e-user
  Scenario: an unknown path is answered by the same front-door decision, not a 404 @role:e2e-user @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/no-such-console"
    Then the URL matches "/user"

  Scenario: an anonymous visitor to an unknown path is sent to sign in @layer:ui
    When I open the path "/no-such-console"
    Then the URL matches "/login"

  # session.service.ts:154-165 defaults an unreadable status to 'active' — the
  # status gate FAILS OPEN by design. Combined with the seeder modelling a ban as
  # the ABSENCE of roles, session.curtailed() is false for every seeded persona
  # and this branch has no drivable identity at all.
  @role:e2e-banned
  Scenario: a curtailed session is short-circuited to the appeal page @role:e2e-banned @layer:ui
    Given this scenario is PENDING because "session.curtailed() reads an admin-bff account STATUS of suspended|banned, and no seeder sets one — tests/stack/seed-e2e.sh:11 models a ban as the ABSENCE of the platform access roles, so e2e-banned is a plain ROLE_USER whose status is 'active'. session.service.ts:154-165 additionally defaults an unreadable status to 'active' (fail-open), so this branch is unreachable until a status-curtailed persona is seeded."
    Given I am signed in as the persona for this scenario
    When I open the path "/"
    Then the URL matches "/login/appeal"
