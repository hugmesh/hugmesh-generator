# WHAT THIS ASSERTS — the role-coverage gap the 2026-09-18 survey found on the
# /user mount: hugmesh-user-ui mounts ELEVEN sub-views under the host shell's
# `/user` route (hugmesh-host-shell app.routes.ts, userGuard; hugmesh-user-ui
# user.routes.ts: '', profile, cards, blocks, recommend-instance-block,
# self-silence, connected-apps, sessions, preferences, notifications,
# notification-preferences — re-read on origin/main cf2d241, 2026-09-23), and
# the central suite drove only the mount itself: specs/04-five-users.spec.ts
# asserts nav-user is attached and nothing else, and the generative coverage
# lane's `/user` row proves the GATE, not that any sub-view renders.
#
# TWO TIERS:
#   * OFFLINE — the gateway seed's decision on each sub-view's BFF surface, for
#     the plain member the mount is for and for two principals that must NOT
#     reach it: ROLE_MOD alone (e2e-mod holds no ROLE_USER — a moderator is not
#     a member, and the seed's /bff/user/** row is ROLE_USER only) and a bare
#     ROLE_ADMIN. The last is the ROWS-ALONE statement: production's admin
#     bypass in GatewayRouteAccessFilter is a filter short-circuit no row-level
#     oracle can model, and features/mined-governance/superadmin-and-fleet-reach
#     .feature is where that is written down.
#   * LIVE (@env:docker) — the member OPENS every sub-view and its root element
#     renders: a hard GET the fe-gateway routes to the user-ui container, which
#     is the path a bookmark or a reload takes, so a sub-view that only works
#     when reached through the shell's own router is caught. The two http rows
#     prove the deny end at the door for the one surface every sub-view shares
#     the row with.
#
# The root testids are the ones each component renders unconditionally
# (`<name>-view`); preferences.component.html has no such root, so its always-
# rendered fieldset stands in. Every step here is shared vocabulary — nothing
# new is defined for this feature.
#
# NOT COVERED: the sub-views as FUNCTIONS in the generative coverage matrix
# (features/coverage/ is emitted from steps/coverage-catalogue.ts, which is the
# catalogue lane's file). Recorded as a catalogue need, not written by hand.
@layer:ui
Feature: A member's self-service sub-views all render behind the /user mount

  # ── the rows the cluster loads ─────────────────────────────────────────────
  Scenario Outline: a principal holding only <granted> is <decision> at <surface> by the rows alone @layer:gateway
    Given the cluster route-access seed is loaded
    And a principal holding only the role "<granted>"
    When the "hugmesh-fe-gateway" gateway decides "<surface>" from the cluster seed
    Then the seed decision is "<decision>"
    And the deciding url pattern is "/bff/user/**"

    Examples:
      | granted    | surface                              | decision |
      | ROLE_USER  | /bff/user/profile                    | ALLOW    |
      | ROLE_USER  | /bff/user/cards                      | ALLOW    |
      | ROLE_USER  | /bff/user/blocks                     | ALLOW    |
      | ROLE_USER  | /bff/user/recommend-instance-block   | ALLOW    |
      | ROLE_USER  | /bff/user/self-silence               | ALLOW    |
      | ROLE_USER  | /bff/user/connected-clients          | ALLOW    |
      | ROLE_USER  | /bff/user/sessions                   | ALLOW    |
      | ROLE_USER  | /bff/user/preferences                | ALLOW    |
      | ROLE_USER  | /bff/user/notifications              | ALLOW    |
      | ROLE_USER  | /bff/user/notification-preferences   | ALLOW    |
      | ROLE_MOD   | /bff/user/sessions                   | DENY     |
      | ROLE_ADMIN | /bff/user/sessions                   | DENY     |

  # ── the member, in a browser, on the compose mesh ──────────────────────────
  @env:docker @role:e2e-user
  Scenario Outline: the member opens <path> and the <root> view renders @role:e2e-user @env:docker @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "<path>"
    Then the element with test id "<root>" is visible

    Examples:
      | path                            | root                            |
      | /user                           | home-view                       |
      | /user/profile                   | profile-view                    |
      | /user/cards                     | cards-view                      |
      | /user/blocks                    | self-block-view                 |
      | /user/recommend-instance-block  | recommend-instance-block-view   |
      | /user/self-silence              | self-silence-view               |
      | /user/connected-apps            | connected-apps-view             |
      | /user/sessions                  | sessions-view                   |
      | /user/preferences               | prefs-media-poison-fieldset     |
      | /user/notifications             | notifications-view              |
      | /user/notification-preferences  | notification-preferences-view   |

  # ── the deny end, at the door ──────────────────────────────────────────────
  # e2e-mod holds ROLE_MOD and nothing else, so this is the seed's ROLE_USER-only
  # row refusing a real signed-in principal at the gateway (X-Route-Denied), not
  # the BFF refusing an anonymous one.
  @env:docker
  Scenario Outline: <role> is refused the sessions surface at the gateway @role:<role> @env:docker @layer:gateway
    Given an API client signed in as the persona for this scenario
    When the API client GETs "/bff/user/sessions"
    Then the response status is 403
    And the refusal came from the gateway

    Examples:
      | role    |
      | e2e-mod |

  @env:docker
  Scenario: an anonymous client is unauthenticated at the sessions surface @env:docker @layer:gateway
    Given an anonymous API client
    When the API client GETs "/bff/user/sessions"
    Then the response status is 401
