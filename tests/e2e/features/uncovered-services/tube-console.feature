# The Tube (LocalTube) console — the first e2e coverage this service has EVER
# had.
#
# Unlike Owncast, Tube's DEFAULT view is reachable by an admin: '' redirects to
# 'my' behind tubeReadGuard = canUse() = ROLE_TUBE | admin | superadmin. So the
# whole console — the user view plus both management views — renders for the
# seeded admin personas, and all three nav entries are assertable.
#
# The member journey is still absent for the same reason as wiki and owncast:
# nothing seeds ROLE_TUBE (access-role-roster.feature asserts it). What that
# costs here is narrow — an admin sees a superset of the member's console — so
# the coverage below is close to complete rather than a stand-in.
@service:tube @layer:ui
Feature: The Tube console opens for admins with its user and management views

  Scenario Outline: <role> opens the Tube console and lands on the personal queue view @role:<role> @service:tube @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/tube"
    Then the URL matches "/tube/my"
    And the level 1 heading "Tube" is visible
    And the element with test id "tube-nav-my" is visible

    Examples:
      | role           |
      | e2e-admin      |
      | e2e-superadmin |

  # TUBE_MANAGE = admin | superadmin, gating BOTH the access console and the
  # per-user storage budgets. Asserted together because they share one predicate
  # and a regression would drop both.
  @role:e2e-admin
  Scenario: a platform admin is offered the tube access and storage-budget consoles @layer:ui @role:e2e-admin @service:tube
    Given I am signed in as the persona for this scenario
    When I open the path "/tube"
    Then the element with test id "tube-nav-access" is visible
    And the element with test id "tube-nav-budgets" is visible

  Scenario Outline: <role> is refused the Tube console @role:<role> @service:tube @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/tube"
    Then the URL matches "/home[?]denied="
    And the URL matches "denied=.*tube"

    Examples:
      | role     |
      | e2e-user |
      | e2e-mod  |
