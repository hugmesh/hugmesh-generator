# The executable Gherkin form of the still-PENDING half of
# tests/e2e/specs/18-rbac-phase8-10-pending.spec.ts.
#
# READ THIS BEFORE ADDING TO IT. Every scenario here is FULLY WIRED — real steps,
# real assertions, real personas — and gated behind one Given that SKIPS WITH A
# NAMED REASON because the surface does not exist in the host shell yet. Set
# SNAP_PHASE8_SURFACES=1 once it lands and they run as written. Nothing below
# asserts expect(true).toBe(true), and nothing skips silently.
#
# WHAT SPEC 18 LISTED THAT IS NO LONGER PENDING, so is NOT duplicated here:
#   * "host shell shows admin nav for ROLE_ADMIN, hides it for ROLE_USER" and
#     "…a ROLE_MOD moderation entry-point only for moderators" — both surfaces
#     LANDED and are asserted for real by features/rbac/console-access-matrix.feature.
#     Restating them as pending would understate the coverage that exists.
#
# WHAT IS STILL PENDING AND IS NOT HERE: the svc-* machine identities
# (svc-pki-gateway / svc-be-gateway / svc-fe-gateway / svc-api / svc-admin-bff).
# No seeder creates them, so '@role:svc-api' is not a legal dimension value and a
# scenario naming one would fail resolution before it could skip. Seeding them is
# the prerequisite, and it is reported as a gap rather than faked with a tag the
# harness would reject.
@layer:ui
Feature: PENDING Phase 8/10 role-conditional surfaces

  # Plain ROLE_GAMES grants a games ENTRY-POINT, not games ADMIN — the two rows
  # for e2e-gamesonly and e2e-gamesadmin are both "visible" for that reason.
  Scenario Outline: <role> <visibility> the games entry-point @role:<role> @service:games @layer:ui
    Given the Phase 8-10 surface "host-shell ROLE_GAMES entry-point" has landed
    And I am signed in as the persona for this scenario
    Then the element with test id "nav-games" <visibility>

    Examples:
      | role           | visibility     |
      | e2e-gamesonly  | is visible     |
      | e2e-gamesadmin | is visible     |
      | e2e-user       | is not visible |
      | e2e-mod        | is not visible |

  # The UI-layer form of the games-admin gate. Its gateway-layer twin is asserted
  # offline today by features/rbac/gateway-route-access.feature and live by
  # features/rbac/live-gateway-enforcement.feature, so this row adds the RENDER
  # half and nothing else.
  Scenario Outline: <role> <visibility> the games-admin console at its own route @role:<role> @service:games @layer:ui
    Given the Phase 8-10 surface "systems-host /games/admin mount" has landed
    And I am signed in as the persona for this scenario
    When I open the path "/games/admin/sessions"
    Then the element with test id "games-admin-console" <visibility>

    Examples:
      | role           | visibility     |
      | e2e-gamesadmin | is visible     |
      | e2e-gamesonly  | is not visible |
      | e2e-adminonly  | is not visible |
