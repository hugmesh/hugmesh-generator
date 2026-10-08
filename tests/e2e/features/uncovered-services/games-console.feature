# The games mounts, driven — not just asserted as strings in a route table.
#
# Until now `games` appeared in tests/e2e only as gateway ROUTE CONTRACT rows
# (specs 12/13/14): a decision oracle was asked whether a role-set would be
# admitted at /games/admin/**, and nothing ever opened the page. Both mounts are
# reachable NOW, though, because the host shell serves them itself: there is no
# games UI repo yet, so /games and /games/admin are GUARDED LOCAL PLACEHOLDERS
# that render an honest TODO instead of a silent 404 (the same precedent /mod
# used before hugmesh-mod-ui landed). A placeholder behind a real guard is still
# a real authorization boundary, and that boundary is what these scenarios drive.
#
# THE GATE IS AN "AND", AND THAT IS THE WHOLE POINT. /games/admin is keyed on the
# DERIVED composite ROLE_GAMES_ADMIN = ROLE_GAMES INTERSECT (ROLE_ADMIN UNION
# ROLE_MOD), materialised by the games-admin-sync job. A bare ROLE_GAMES
# (e2e-gamesonly) and a bare ROLE_ADMIN (e2e-adminonly) each hold exactly one
# half and must BOTH be refused — the two negatives are what prove the AND, and
# a single-role pass would be the defect.
#
# A REFUSAL LANDS WHERE EVERY OTHER CONSOLE'S DOES. gamesGuard/gamesAdminGuard
# were the two host-shell guards NOT built on role-guard.factory: they sent a
# SIGNED-IN but unauthorized identity to /login rather than to
# /home?denied=<path> like every other console does (see wiki-console.feature).
# Telling a user who just signed in that they are not signed in is the exact
# 2026-08-14 operator report; hugmesh-host-shell#88 rebuilt both guards on the
# factory, so the refused scenarios below assert the denied landing and the
# notice that names the refused console, never /login.
@service:games @layer:ui
Feature: The games entry point and the derived games-admin mount

  Scenario Outline: <role> reaches the games entry point @role:<role> @service:games @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/games"
    Then the URL matches "/games"
    And the level 1 heading "Games" is visible
    And the element with test id "games-placeholder-message" is visible
    And the element with test id "games-todo-badge" is visible

    Examples:
      | role            |
      | e2e-gamesonly   |
      | e2e-gamesadmin  |
      | e2e-admin       |

  Scenario Outline: <role> holds both halves and reaches the games-admin mount @role:<role> @service:games @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/games/admin"
    Then the URL matches "/games/admin"
    And the level 1 heading "Games admin" is visible
    And the element with test id "games-admin-placeholder-message" is visible

    Examples:
      | role           |
      | e2e-gamesadmin |
      | e2e-superadmin |

  Scenario Outline: <role> holds only one half of the games-admin AND and is refused @role:<role> @service:games @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/games/admin"
    Then the element with test id "games-admin-placeholder-message" is not visible
    And the URL matches "/home[?]denied="
    And the element with test id "denied-notice" is visible

    Examples:
      | role          |
      | e2e-gamesonly |
      | e2e-adminonly |
      | e2e-user      |

  # A bare moderator holds neither half of the games ENTRY-POINT gate either
  # (gamesGuard is ROLE_GAMES | admin | superadmin — a mod without ROLE_GAMES is
  # not admitted), which is the cascade this pins.
  @role:e2e-mod
  Scenario: a bare moderator is refused the games entry point @layer:ui @role:e2e-mod @service:games
    Given I am signed in as the persona for this scenario
    When I open the path "/games"
    Then the element with test id "games-placeholder-message" is not visible
    And the URL matches "/home[?]denied="
    And the element with test id "denied-notice" is visible
