# MINED FROM: hugmesh-login-ui login.component.ts:135-158 —
#             needsScreenReaderName() reveals the field when the display name is
#             not pure printable-ASCII; completeBlocked() disables the submit
#             until a valid ASCII name is entered; completeDescribedBy() adds
#             `hug-register-screen-reader-help` to the submit's aria-describedby
#             while it is blocked for that reason.
#             Markup verified in login.component.html:153-196 — the field is
#             `register-screen-reader-name`, the help `register-screen-reader-
#             help`, and the submit is `login-complete` (NOT `register-complete`,
#             which does not exist).
#   PORTED FROM: hugmesh-login-ui/e2e/features/auth/login-native.feature:52,61,
#             adapted to this suite's vocabulary.
#
# WHY IT IS NOT ALREADY COVERED: features/onboarding/register-gating.feature
# drives the same card and asserts only that `login-complete` is DISABLED with an
# empty name. The a11y rule on top of it — a non-ASCII name reveals a second
# required field and says why — appears nowhere: zero hits for screenReader or
# screen-reader across the whole suite, comments stripped.
#
# The `Given I have registered but not completed onboarding …` step is the one
# register-gating.feature already uses, so both lanes reach this card the same
# way.

@service:login @layer:ui @env:docker
Feature: A non-ASCII display name must carry an ASCII name a screen reader can announce

  @role:frank@gmail.com
  Scenario: an ASCII display name needs no prompt and enables the submit @role:frank@gmail.com @service:login @layer:ui
    Given I have registered but not completed onboarding as the persona for this scenario
    When I type the display name "Rin"
    Then the element with test id "register-screen-reader-name" is not visible
    And the element with test id "login-complete" is not disabled

  @role:frank@gmail.com
  Scenario: a non-ASCII display name reveals the field, blocks the submit and describes why @role:frank@gmail.com @service:login @layer:ui
    Given I have registered but not completed onboarding as the persona for this scenario
    When I type the display name "凛"
    Then the element with test id "register-screen-reader-name" is visible
    And the element with test id "login-complete" is disabled
    And the element with test id "login-complete" is described by "hug-register-screen-reader-help"
    When I type the screen-reader name "Rin"
    Then the element with test id "login-complete" is not disabled

  # A screen-reader name that is itself non-ASCII must not unblock the submit —
  # otherwise the prompt collects a value that announces no better than the one
  # it was asked about (screenReaderNameValid(), login.component.ts:141-144).
  @role:frank@gmail.com
  Scenario: a non-ASCII screen-reader name does not satisfy the prompt @role:frank@gmail.com @service:login @layer:ui
    Given I have registered but not completed onboarding as the persona for this scenario
    When I type the display name "凛"
    And I type the screen-reader name "凛々"
    Then the element with test id "login-complete" is disabled
