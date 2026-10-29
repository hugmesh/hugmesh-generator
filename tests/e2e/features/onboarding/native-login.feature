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

  # ── hugmesh-generator#306, Family A ─────────────────────────────────────────
  # The 2026-09-04 full run saw e2e-user's POST /bff/login start answering 401
  # mid-run — with the CORRECT password (the page snapshot and the seed banner
  # agree byte for byte) — and recover on its own eight minutes after the run.
  # The leading hypothesis on the issue is Casdoor's own sign-in throttle (a
  # 15-minute account freeze after a handful of WRONG passwords); what nothing
  # had pinned is the shape a healthy stack must hold: the SAME persona signing
  # in repeatedly, back to back, with the right password is accepted every time.
  # tests/qemu/seed-accounts.sh pre-mints 32 password grants in a row on every
  # seed, so a 401 inside this run is a real regression, never "expected
  # throttling". Every attempt is its own context, exactly as every spec's
  # setup is. Five is enough to see a window open and few enough not to
  # spend the operator's stack on it.
  @issue:generator-306 @env:docker @role:e2e-user
  Scenario: back-to-back native sign-ins for the same persona are all accepted @role:e2e-user @service:login @layer:bff
    When the API client signs in natively 5 times in a row as the persona for this scenario
    Then every native sign-in in that run was accepted
    And the API client session carries the role "user"
