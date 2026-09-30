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
# AUDITED, all eleven host-shell guards: NINE are built from roleGuard and land
# correctly. TWO are not — games.guard.ts:25 and games-admin.guard.ts:26 still
# `router.parseUrl('/login')` for a signed-in caller. They are the survivors of
# the 2026-08-14 defect. (A third instance lives in user-mesh-ui mesh.guard.ts:26,
# which cannot be reached: that remote has no mount — see
# mined-identity/mesh-remote-unmounted.feature.)
#
# WHAT THE SUITE HAS TODAY: features/rbac/console-access-matrix.feature's nearest
# scenario asserts only that the page body does not match "moderation queue" —
# it says nothing about WHERE the user lands or what they are told, and a bounce
# to /login satisfies it perfectly. The wiki/tube/owncast features DO assert the
# denied landing, so this file covers only the four mounts they do not:
# /admin, /mod, /games and /games/admin.
#
# NOT PORTED AS WRITTEN: hugmesh-host-shell/e2e/features/role-routing.feature
# :58-71 and role-games.feature:45 assert that a signed-in user refused a console
# is "bounced to /login". For the nine roleGuard mounts that CONTRADICTS
# role-guard.factory.ts:44; for the two games mounts it merely codifies the
# surviving defect. Only the corrected form is ported.
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
#
# The two games mounts are tracked as hugmesh-host-shell#88.

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

  # KNOWN-FAILING until hugmesh-host-shell#88 lands: games.guard.ts:25 and
  # games-admin.guard.ts:26 are the last two hand-rolled parseUrl('/login')
  # denials in the shell (re-checked on host-shell origin/main e6a2dc3,
  # 2026-09-23 — unchanged). Each scenario asserts the CORRECT landing, the one
  # the nine roleGuard mounts already give, so it goes green unmodified the day
  # both guards adopt roleGuard — then remove @fixme and the @issue tag here.
  # Three separate scenarios rather than one outline, deliberately: the special
  # tags are read from a node's OWN tags, and this shape lets each mount be
  # un-fixme'd on its own.
  @fixme @issue:host-shell-88 @role:e2e-mod
  Scenario: a bare moderator refused /games lands on the denied landing, not /login @role:e2e-mod @service:games @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/games"
    Then the URL matches "/home[?]denied="
    And the element with test id "denied-notice" is visible

  @fixme @issue:host-shell-88 @role:e2e-adminonly
  Scenario: an admin without games refused /games/admin lands on the denied landing @role:e2e-adminonly @service:games @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/games/admin"
    Then the URL matches "/home[?]denied="
    And the element with test id "denied-notice" is visible

  @fixme @issue:host-shell-88 @role:e2e-gamesonly
  Scenario: a games member without admin refused /games/admin lands on the denied landing @role:e2e-gamesonly @service:games @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/games/admin"
    Then the URL matches "/home[?]denied="
    And the element with test id "denied-notice" is visible
