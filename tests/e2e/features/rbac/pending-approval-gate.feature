# The executable Gherkin form of the LIVE half of
# tests/e2e/specs/17-rbac-user-and-pending.spec.ts — the two-stage registration
# gate, driven through the real login-ui against a running stack.
#
# THREE STATES, THREE SCENARIOS:
#   * an identity NO seeder ever provisioned      -> native sign-in is refused
#   * provisioned but registration INCOMPLETE     -> stuck on the complete card
#   * registration COMPLETE                       -> a plain member, nav unlocked
#
# WHY THE PENDING USER IS PROVEN LOCKED BY ABSENCE. A provisioned-but-incomplete
# sign-in never reaches the host shell — login-ui keeps the caller on its own
# "Complete registration" card, so there is no nav-matrix/nav-mastodon to click.
# Direct navigation to matrix-ui's raw gateway path renders matrix-view for NO
# caller (generator#297, live-verified), so probing it would assert nothing; specs
# 02/03 dropped that check for the same reason and this feature does not
# reintroduce it.
#
# e2e-pending / rbac-pending-gmail-com / e2e-banned are DELIBERATELY left
# un-onboarded. Their gated state IS the thing under test; never "fix" them.
@service:login @layer:ui
Feature: The two-stage registration gate

  # No @role: tag: this identity is deliberately absent from BOTH rosters, so it
  # is not a legal dimension value. The step asserts that absence first — if a
  # seeder ever creates the handle the scenario fails loudly instead of passing
  # for the wrong reason.
  Scenario: an identity nobody provisioned is refused native sign-in @service:login @layer:ui
    When the unprovisioned identity "rbac-pending-uninvited@gmail.com" attempts native sign-in
    Then the element with test id "login-error" contains the text "Sign-in failed"

  Scenario: an invited but incomplete member is held on the complete-registration card @role:rbac-pending@gmail.com @service:login @layer:ui
    Given I have registered but not completed onboarding as the persona for this scenario
    Then the element with test id "complete-view" is visible
    And the element with test id "register-display-name" is visible
    And the element with test id "login-complete" is disabled
    And my session registration is not complete

  Scenario: completing registration turns the identity into a plain member with nav @role:rbac-approved@gmail.com @service:login @layer:ui
    Given I am signed in as the persona for this scenario
    Then my session registration is complete
    And my session holds the role "user"
    And the shell offers Matrix unlocked
