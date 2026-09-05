# The front door. This feature is the executable Gherkin expression of
# tests/e2e/specs/01-frontpage.spec.ts — the same assertions, driven through the
# same helpers, so the two cannot disagree about what the front page must do.
#
# `''` has no component of its own: roleHomeGuard is a pure authgate that always
# returns a UrlTree (app.routes.ts). Anonymous -> /login; otherwise -> the
# signed-in user's role-home remote. There is no marketing splash any more, so
# the front door IS the native sign-in form. The h1 reads exactly "HugMesh" —
# one word — and asserting it is the cheapest proof the host shell actually
# BOOTSTRAPPED, as opposed to serving index.html and dying.
#
# LOGIN-PAGE CHROME GATE (hugmesh-host-shell issue #19, PR #21, 2026-08-19):
# while the login remote is on screen and nobody is signed in, the host shell
# unmounts the WHOLE menubar — Home and Sign-in included. The first scenario
# asserts that gate (nav-home is the entry the bar renders in every session
# state; nav-login is the entry this feature used to expect). The second is the
# POSITIVE control: signed in and navigated in-app off the home page (which
# swaps the bar for service cards), the same testids resolve and the bar is
# back — minus Sign in, which is session-gated on its own.
@service:login @layer:ui
Feature: Front door over the generated TLS certs

  # PLATFORM axis. The front-door contract is identical on both image targets;
  # the runner narrows to the one it actually brought up with SNAP_PLATFORM
  # (see steps/world.ts). Unset, both rows run.
  Scenario Outline: the front page gates anonymous visitors to native sign-in on <platform> @platform:<platform> @service:login @layer:ui
    When I open the path "/"
    Then the URL matches "/login"
    And the level 1 heading "HugMesh" is visible
    And the element with test id "login-view" is visible
    And the element with test id "login-username" is visible
    And the element with test id "nav-home" is not visible
    And the element with test id "nav-login" is not visible

    Examples:
      | platform |
      | rpi5     |
      | x86      |

  # The returning-user chain (POST /bff/login -> hydrate -> provision -> hard nav
  # -> host shell cold boot) lands a member on /user, the signed-in HOME, where
  # the shell renders the service CARDS instead of the bar. Following a card is
  # a client-side navigation to a non-home, non-login route — the state in which
  # the bar renders. A deep link would not do: page.goto('/social/matrix') on the
  # compose stack does not boot the host shell at all (measured 2026-09-05).
  Scenario: the menubar is gated on the login page only — signed in and off the home page it is back, minus Sign in @role:e2e-user @service:login @layer:ui
    When I sign in through the native login form as the persona for this scenario
    Then the POST to "/bff/login" was accepted
    And the element with test id "nav-user" is attached
    And the element with test id "home-services-nav" is visible
    When I click the element with test id "home-card-nav-matrix"
    Then the URL matches "/social/matrix"
    And the element with test id "nav-home" is visible
    And the element with test id "nav-login" is not visible
