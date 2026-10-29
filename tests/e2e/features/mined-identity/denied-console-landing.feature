# MINED FROM: hugmesh-host-shell/src/app/guards/role-guard.factory.ts:38-47 —
#             DENIED_PATH = '/home', and a SIGNED-IN caller who lacks the role is
#             sent there carrying ?denied=<attempted path>; :20-27 records why
#             (operator report 2026-08-14, "moderation menu option just redirects
#             to login"): answering an AUTHORIZATION failure with the ANONYMOUS
#             destination tells a user who just signed in that they are not
#             signed in, and it hid the real fault — a stripped Casdoor role
#             membership — by making it present as a session problem.
#             home/denied-notice.component.ts:47-70 carries the testids
#             denied-notice / denied-mismatch / denied-no-role.
#
# AUDITED, all eleven host-shell guards: all are built from roleGuard and land
# on the denied landing. games.guard.ts and games-admin.guard.ts were the last
# two hand-rolled `router.parseUrl('/login')` denials, the survivors of the
# 2026-08-14 defect, until hugmesh-host-shell#88 rebuilt them on the factory.
# (A further instance lives in user-mesh-ui mesh.guard.ts:26, which cannot be
# reached: that remote has no mount — see mined-identity/mesh-remote-unmounted.feature.)
#
# WHAT THE SUITE HAS TODAY: features/rbac/console-access-matrix.feature's nearest
# scenario asserts only that the page body does not match "moderation queue" —
# it says nothing about WHERE the user lands or what they are told, and a bounce
# to /login satisfies it perfectly. The wiki/tube/owncast features DO assert the
# denied landing, so this file covers only the four mounts they do not:
# /admin, /mod, /games and /games/admin.
#
# NOT PORTED AS WRITTEN: hugmesh-host-shell/e2e/features/role-routing.feature
# :58-71 asserts that a signed-in user refused a console is "bounced to /login",
# which CONTRADICTS role-guard.factory.ts:44 (role-games.feature:45 said the same
# for /games until #88 corrected it). Only the corrected form is ported.
#
# THE HARD NAVIGATION, and why these rows could not pass before 2026-09-18.
# `I open the path` is page.goto() — a refresh, a bookmark, a typed URL. Until
# hugmesh-generator#381 (PR #442, merged 2026-09-18) the fe gateway's
# remote-deeplink-to-host-shell route carried only the social/media prefixes,
# so a hard GET of /admin, /mod or /user went STRAIGHT to the bare admin-ui /
# mod-ui / user-ui container: no host shell, no roleGuard, no denied-notice —
# the deny below could never render. tests/stack/gateway-routes/fe/
# application-routes.yml now lists /admin/**,/mod/**,/user/** on that route, so
# the first outline is the live proof of #381 from the user's side (the
# route-table shape itself is pinned offline in
# mined-platform-edge/fe-route-tables.feature). The /user row is the only honest
# one for that mount: e2e-mod is the sole roster persona WITHOUT ROLE_USER.

@layer:ui @env:docker
Feature: A refused console explains itself instead of pretending you are signed out

  @issue:generator-381
  Scenario Outline: <role> deep-linking <path> lands on the denied landing, never /login @role:<role> @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "<path>"
    Then the URL matches "/home[?]denied="
    And the current URL carries a denied query naming "<path>"
    And the element with test id "denied-notice" is visible

    Examples: the three role-home mounts #381 added to the deep-link route
      | role      | path   |
      | e2e-mod   | /admin |
      | e2e-mod   | /user  |
      | e2e-user  | /mod   |
      | e2e-user  | /admin |

  # An ANONYMOUS visitor is a different failure with a different answer: there IS
  # a credential to supply, so /login is correct. Two failures, two destinations —
  # this is what stops the scenario above being "read" as "never send anyone to
  # /login".
  Scenario: an anonymous visitor to a console is still sent to sign in @layer:ui
    When I open the path "/admin"
    Then the URL matches "/login"
    And the element with test id "denied-notice" is not visible

  # The two games mounts. Until hugmesh-host-shell#88 these three carried @fail:
  # games.guard.ts and games-admin.guard.ts were the last two hand-rolled
  # parseUrl('/login') denials in the shell, and the scenarios were expected red.
  # Both guards are now built from roleGuard, so these assert the same landing as
  # the outline above. Kept as three separate scenarios rather than an outline so
  # each persona's row reads (and can be tagged) on its own.
  @role:e2e-mod
  Scenario: a bare moderator refused /games lands on the denied landing, not /login @role:e2e-mod @service:games @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/games"
    Then the URL matches "/home[?]denied="
    And the element with test id "denied-notice" is visible

  @role:e2e-adminonly
  Scenario: an admin without games refused /games/admin lands on the denied landing @role:e2e-adminonly @service:games @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/games/admin"
    Then the URL matches "/home[?]denied="
    And the element with test id "denied-notice" is visible

  @role:e2e-gamesonly
  Scenario: a games member without admin refused /games/admin lands on the denied landing @role:e2e-gamesonly @service:games @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/games/admin"
    Then the URL matches "/home[?]denied="
    And the element with test id "denied-notice" is visible
