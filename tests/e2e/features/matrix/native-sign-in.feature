# Executable form of tests/e2e/specs/07-discord.spec.ts.
#
# The file is still called "discord" for history only: the Google/Discord social-
# login registration surface was REMOVED from login-ui, and the ONLY sign-in surface
# is our native username/password form. "dragoneer" is just a native username, and
# `provider` on the session is always 'password' now — asserting that is what would
# catch a social-login path quietly coming back.
#
# The second scenario deliberately stops at the RENDERED Matrix view. dragoneer holds
# ROLE_USER, which reaches /social/matrix/** on the fe-gateway but NOT the homeserver
# backend behind it (see platform-access-wall.feature) — so "the shell routes me to
# Matrix" and "I can use Matrix" are different claims, and only the first is made here.
@layer:ui
Feature: Native sign-in is the only door into the social shell

  @service:login
  Scenario: a username no admin provisioned is refused at the native form
    When an unprovisioned username "rando" attempts native sign-in
    Then the native sign-in error reports a failed sign-in

  @role:dragoneer @service:login
  Scenario: a provisioned user signs in natively and the shell routes them to Matrix
    Given I am signed in as the persona for this scenario
    Then my session was minted by the native password provider
    And my session registration is complete
    When I open Matrix from the social nav
    Then the element with test id "matrix-view" is visible
