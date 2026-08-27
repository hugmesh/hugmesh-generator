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
@service:login @layer:ui
Feature: Front door over the generated TLS certs

  # PLATFORM axis. The front-door contract is identical on both image targets;
  # the runner narrows to the one it actually brought up with SNAP_PLATFORM
  # (see steps/world.ts). Unset, both rows run.
  Scenario Outline: the front page gates anonymous visitors to native sign-in on <platform> @platform:<platform> @service:login @layer:ui
    When I open the path "/"
    Then the URL matches "/login"
    And the level 1 heading "HugMesh" is visible
    And the element with test id "nav-login" is visible
    And the element with test id "login-view" is visible
    And the element with test id "login-username" is visible

    Examples:
      | platform |
      | rpi5     |
      | x86      |
