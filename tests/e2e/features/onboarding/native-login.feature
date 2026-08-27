# Executable Gherkin for tests/e2e/specs/27-native-login.spec.ts.
#
# The login-ui's OWN username/password form is the ONLY login surface. It POSTs
# {username, password} to /bff/login (credentials: include); the user-bff runs
# Casdoor's INTERNAL /api/login + PKCE code-exchange SERVER-SIDE and mints the
# opaque httpOnly `bff_session` cookie whose value is prefixed `bff_`. The browser
# is NEVER redirected to a Casdoor origin and never receives a JWT or access
# token. The deleted Google/Discord social-login testids must be ABSENT.
@service:login @layer:bff
Feature: Native login drives /bff/login and never browser-exposes Casdoor

  # PLATFORM axis. The sign-in surface contract is IDENTICAL on both image
  # targets — the axis here narrows the run to whichever target the operator
  # actually brought up (SNAP_PLATFORM; steps/world.ts skips the other row with a
  # named reason). It is a runner-narrowing axis, NOT a claim that the two
  # platforms behave differently. Unset, both rows run.
  Scenario Outline: the sign-in surface on <platform> offers only the native form @platform:<platform> @service:login @layer:ui
    When I open the path "/login"
    Then the element with test id "login-view" is visible
    And the element with test id "login-username" is visible
    And the element with test id "login-password" is visible
    And the element with test id "login-submit" is visible
    # The removed social-login / OIDC-redirect surfaces. login-ui pins their
    # absence; the suite drove these five testids before they were deleted.
    And the element with test id "login-email" is not visible
    And the element with test id "login-google-register" is not visible
    And the element with test id "login-discord" is not visible
    And the element with test id "login-discord-register" is not visible
    And the element with test id "login-signin" is not visible

    Examples:
      | platform |
      | rpi5     |
      | x86      |

  # e2e-user is a real seeded native account (deterministic e2e password), so the
  # sign-in actually mints a session on a live run rather than asserting over a
  # rejected login. The navigation recorder is armed BEFORE the sign-in step,
  # because that step performs the goto itself (specs/helpers.ts registerOnly()).
  Scenario: POST /bff/login mints an httpOnly opaque session and no Casdoor origin is visited @role:e2e-user @service:login @layer:bff
    Given I am recording every main-frame navigation
    When I sign in through the native login form as the persona for this scenario
    Then the POST to "/bff/login" was accepted
    And the browser holds an httpOnly cookie named "bff_session" whose value starts with "bff_"
    And no main-frame navigation reached a Casdoor origin
