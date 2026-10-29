# The games mounts, driven — not just asserted as strings in a route table.
#
# Until 2026-10-28 `games` had no client in this mesh: /games and /games/admin
# were GUARDED LOCAL PLACEHOLDERS the host shell rendered itself (an honest TODO
# badge instead of a silent 404). The games member + games admin screens round
# replaced both with the REAL `games` native-federation remote
# (hugmesh-games/games-ui): the host mounts its GAMES_ROUTES at /games (M1
# catalog, M2 play) behind gamesGuard and its GAMES_ADMIN_ROUTES at /games/admin
# (A0 shell with Overview / Live sessions / Session logs / Access / Settings)
# behind gamesAdminGuard; the remote talks ONLY to the games BFF through the
# fe-gateway's /games/api/** route. The scenarios below drive those screens with
# the testids the cross-repo contract fixes (games-catalog, games-card-<slug>,
# games-play-frame, games-admin-shell, games-admin-overview, …).
#
# WHAT A GREEN RUN NEEDS: the compose `games` profile (make stack-up GAMES=1,
# tests/stack/compose.games.yaml) — the remote, the BFF, its Postgres and the
# keyspace one-shot resolve only under that profile. Without it the fe routes
# games-ui / games-bff answer 503 and the shell mounts nothing at /games, so the
# @env:docker rows below fail honestly rather than skip. The mock lane's tracked
# tests/stack/.uidist still renders the old placeholder and cannot pass these.
#
# THE GATE IS AN "AND", AND THAT IS THE WHOLE POINT. /games/admin is keyed on the
# DERIVED composite ROLE_GAMES_ADMIN = ROLE_GAMES INTERSECT (ROLE_ADMIN UNION
# ROLE_MOD), materialised by tests/stack/derive-games-admin.sh on compose and
# the games-admin-sync job on the cluster. A bare ROLE_GAMES (e2e-gamesonly) and
# a bare ROLE_ADMIN (e2e-adminonly) each hold exactly one half and must BOTH be
# refused — the two negatives are what prove the AND, and a single-role pass
# would be the defect.
#
# A REFUSAL LANDS WHERE EVERY OTHER CONSOLE'S DOES. gamesGuard/gamesAdminGuard
# were the two host-shell guards NOT built on role-guard.factory: they sent a
# SIGNED-IN but unauthorized identity to /login rather than to
# /home?denied=<path> like every other console does (see wiki-console.feature).
# Telling a user who just signed in that they are not signed in is the exact
# 2026-08-14 operator report; hugmesh-host-shell#88 rebuilt both guards on the
# factory, so the refused scenarios below assert the denied landing and the
# notice that names the refused console, never /login.
#
# e2e-admin / e2e-adminonly reach the ENTRY POINT: gamesGuard admits
# games||admin||superadmin, and since this round the shell's Games card agrees
# with the guard (hasRole('games') := isGames()||isAdmin()||isSuperadmin()).
@service:games @layer:ui
Feature: The games member screens and the derived games-admin mount

  Scenario Outline: <role> reaches the games catalog @role:<role> @service:games @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/games"
    Then the URL matches "/games"
    And the element with test id "games-catalog" is visible
    And the element with test id "games-card-chess" is visible

    Examples:
      | role            |
      | e2e-gamesonly   |
      | e2e-gamesadmin  |
      | e2e-admin       |
      | e2e-adminonly   |

  # M2: a 'Plays here' bundle renders inside the shell as a same-origin iframe of
  # the wasm-fragment tier; the launch (POST /games/api/games/chess/launch) rides
  # the fe /games/api/** row every games member holds.
  @role:e2e-gamesonly
  Scenario: a games member launches a web-native game inside the shell @layer:ui @role:e2e-gamesonly @service:games @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/games/play/chess"
    Then the URL matches "/games/play/chess"
    And the element with test id "games-play" is visible
    And the element with test id "games-play-frame" is visible
    And the element with test id "games-play-back" is visible

  Scenario Outline: <role> holds both halves and reaches the games-admin console @role:<role> @service:games @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/games/admin"
    Then the URL matches "/games/admin"
    And the element with test id "games-admin-shell" is visible
    And the element with test id "games-admin-overview" is visible

    Examples:
      | role           |
      | e2e-gamesadmin |
      | e2e-superadmin |

  Scenario Outline: <role> holds only one half of the games-admin AND and is refused @role:<role> @service:games @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/games/admin"
    Then the element with test id "games-admin-shell" is not visible
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
    Then the element with test id "games-catalog" is not visible
    And the URL matches "/home[?]denied="
    And the element with test id "denied-notice" is visible
