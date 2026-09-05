# Executable Gherkin for tests/e2e/specs/04-five-users.spec.ts.
#
# WHAT THE SPEC ACTUALLY DOES. Five invite-handle identities each complete BOTH
# registration stages through the UI (native sign-in, then the display-name +
# "Complete registration" card), and the resulting session hydrates
# registrationComplete:true from GET /bff/session. "Matrix/Mastodon are unlocked"
# is then proven the only way the browser can prove it — by REACHING BOTH
# SURFACES from the host nav. The browser holds no Matrix/Mastodon token at all;
# the user-bff's hsproxy injects the server-held one.
#
# The spec runs all five in ONE test with a fresh BrowserContext per user and a
# 240s budget. As Gherkin they are five scenarios, one per Examples row, which is
# the same isolation (Playwright gives each scenario its own context) with
# per-persona reporting and a per-persona screenshot chain.
#
# A TENSION WORTH NAMING RATHER THAN SMOOTHING OVER. specs/helpers.ts
# platformPersonas() documents that commit 0100d3b removed the broad ROLE_USER
# homeserver floor, so these ROLE_USER-only invite handles are DENIED the
# homeserver BACKEND by design and spec 17 asserts exactly that deny. Spec 04
# nonetheless asserts they reach the matrix-view / mastodon-view MFEs. Both are
# true: the fe-gateway serves the micro-frontends to a plain member (spec 17's
# own USER_ALLOWED list contains /social/matrix/room and /social/mastodon/feed);
# it is the be-gateway C-S / REST calls behind them that need the platform role.
# This feature expresses spec 04 as written; it does NOT quietly grant these
# personas ROLE_MATRIX to make a fuller claim true.
@service:login @layer:ui
Feature: Five invited users complete both registration stages and reach their surfaces

  Scenario Outline: <role> completes registration and reaches Matrix and Mastodon from the host nav @role:<role> @service:login @layer:ui
    Given I am signed in as the persona for this scenario
    Then my session registration is complete
    And my session provider is "password"
    # Sign-in lands on the signed-in HOME, where the shell renders the service
    # entries as CARDS (home-card-nav-matrix), not the menubar (nav-matrix) — the
    # step opens whichever form is on screen. Once on /social/matrix the menubar
    # is back, so Mastodon is a plain nav-mastodon click.
    When I open Matrix from the social nav
    Then the element with test id "matrix-view" is visible
    When I click the element with test id "nav-mastodon"
    Then the element with test id "mastodon-view" is visible

    Examples:
      | role            |
      | alice@gmail.com |
      | bob@gmail.com   |
      | carol@gmail.com |
      | dave@gmail.com  |
      | eve@gmail.com   |

  # The RETURNING-user leg. alice was fully onboarded above, so signing in through
  # our own username/password form takes the returning branch: POST /bff/login ->
  # hydrate -> provision matrix + mastodon (sequential) -> hard nav -> host shell
  # cold boot. nav-user is asserted ATTACHED, never visible: its label span is
  # empty by design in the opaque-cookie model and has zero rendered size.
  Scenario: a returning user signs in through the native login form @role:alice@gmail.com @service:login @layer:ui
    When I sign in through the native login form as the persona for this scenario
    Then the POST to "/bff/login" was accepted
    And the element with test id "nav-user" is attached
    And the shell offers Matrix unlocked
