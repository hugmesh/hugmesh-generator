# The games FUNCTION surface — and the largest honest gap in this domain.
#
# games-console.feature drives the two host-shell mounts and the derived
# ROLE_GAMES_ADMIN "AND". Everything the word "games" implies BEYOND those two
# mounts — list the catalogue, launch a title, drive an instance's lifecycle, open
# a running instance's console, curate the app-store — has NO CLIENT IN THIS MESH.
# The route-access seed carries the rows for all of it (four surfaces, five roles),
# the gates are ready, and there is nothing behind them: the host shell serves
# /games and /games/admin as GUARDED LOCAL PLACEHOLDERS that render an honest TODO,
# and tests/stack/compose.local.yaml defines no games micro-frontend container at
# all. The games portal itself lives in a separate deployment (hugmesh-games),
# federated in nowhere.
#
# THAT IS WHY THE FIRST SCENARIO BELOW IS A `grep` THAT MUST FAIL. A pending
# scenario saying "there is no games UI" is a claim; a transcript of the search
# coming back empty is a measurement, and it goes red the day somebody adds the
# container — which is the day the four pending scenarios become writable.
#
# The two mounts that DO exist are extended here rather than re-driven: the
# console feature asserts the placeholder message, this one asserts the rest of
# the placeholder's contract — the TODO badge, the name of the remote that is
# supposed to arrive, and the way back out. A placeholder that lies about which
# remote it is waiting for is worse than a 404.
@service:games @layer:ui
Feature: What the games mounts really offer, and the five functions with no client

  # ── the measurement that makes the pendings below non-vacuous ─────────────
  @function:catalogue @interface:cli @layer:ui
  Scenario: the committed compose stack defines NO games micro-frontend to mount @function:catalogue @interface:cli @layer:ui @service:games
    When I run the shell command "grep -c hugmesh-games-ui tests/stack/compose.local.yaml"
    Then the command failed
    And the command exit code was 1
    And the evidence manifest holds a "transcript" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  # The positive control for the same search. Without it, a typo in the pattern
  # above would make the negative pass for the wrong reason and read as evidence.
  @function:catalogue @interface:cli @layer:ui
  Scenario: the same search really does find the UIs that ARE in the stack @function:catalogue @interface:cli @layer:ui @service:games
    When I run the shell command "grep -c hugmesh-character-studio-ui tests/stack/compose.local.yaml"
    Then the command succeeded
    And the evidence manifest holds a "transcript" artefact for this scenario

  # ── entry: the placeholder's full contract ────────────────────────────────
  @function:entry @env:docker
  Scenario Outline: <role> is told which remote the games mount is waiting for @role:<role> @function:entry @service:games @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/games"
    Then the element with test id "games-todo-badge" is visible
    And the element with test id "games-future-remote" is visible
    And the element with test id "games-back" is visible

    Examples:
      | role           |
      | e2e-gamesonly  |
      | e2e-gamesadmin |
      | e2e-admin      |

  # ── admin: the derived mount's placeholder contract ───────────────────────
  @function:admin @env:docker
  Scenario Outline: <role> reaches the games-admin placeholder and is told the same @role:<role> @function:admin @service:games @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/games/admin"
    Then the element with test id "games-admin-todo-badge" is visible
    And the element with test id "games-admin-future-remote" is visible
    And the element with test id "games-admin-back" is visible

    Examples:
      | role           |
      | e2e-gamesadmin |
      | e2e-superadmin |

  # ── THE THREE ENVIRONMENTS, on the lightest surface in the domain ─────────
  #
  # The operator asked for evidence in docker, local devops and QEMU. The games
  # entry point is the right place to spend that: it is served by the host shell
  # itself, so it needs no optional service enabled, no seeded per-service role
  # and no backend — if a mesh serves anything at all it serves this. Each row
  # availability-probes its own door and, when nothing answers, SKIPS naming the
  # exact command to bring that environment up. kind and qemu cannot be available
  # at once on this host: the kind node and a QEMU launcher both publish host port
  # :8443 and only one can hold it (the compose stack's door is PUBLIC_HTTPS_PORT,
  # default 8488, so it sits beside either — unless it is published on :8443 too).
  @function:entry @role:e2e-gamesadmin
  Scenario Outline: the games entry point renders in the <env> environment @role:e2e-gamesadmin @function:entry @service:games @layer:ui @env:<env>
    Given I am signed in as the persona for this scenario
    When I open the path "/games"
    Then the level 1 heading "Games" is visible
    And the element with test id "games-placeholder-message" is visible

    Examples:
      | env    |
      | docker |
      | kind   |
      | qemu   |

  # ── the five functions with no client ─────────────────────────────────────
  #
  # No @role: tag on any of them, deliberately: the roles these need
  # (ROLE_GAMES_SERVICES, ROLE_GAMES_SERVICES_ADMIN, ROLE_GAMES_SERVICES_RUNNER)
  # are minted by no seeder, and steps/dimensions.ts validates @role: in the
  # Before hook — before a PENDING step could skip — so naming a fictional handle
  # would turn an honest pending into a hard error.
  @function:catalogue
  Scenario: a games member lists the titles offered to their domain @function:catalogue @service:games @layer:ui
    Given this scenario is PENDING because "the games app-store control plane has a seeded route-access row (/bff/games-services/catalog/** = ROLE_GAMES_SERVICES on the be gateway) and NO client: no games micro-frontend is defined in tests/stack/compose.local.yaml, the host shell serves /games as a TODO placeholder, and no persona holds ROLE_GAMES_SERVICES. This is waiting on a BUILD, not on a seeder line"
    And I am signed in as the persona for this scenario
    When I open the path "/games"
    Then the element with test id "games-catalogue" is visible

  @function:launch
  Scenario: a games-services admin creates, runs and stops a game instance @function:launch @service:games @layer:ui
    Given this scenario is PENDING because "the instance lifecycle is a control-plane API (/bff/games-services/instances/** = ROLE_GAMES_SERVICES_ADMIN | ROLE_GAMES_SERVICES_RUNNER, be gateway) with no mounted client, and neither role is minted by any seeder. The RUNNER half is the mod-delegated run/stop tier and needs its own scenario once a client exists"
    And I am signed in as the persona for this scenario
    When I open the path "/games"
    Then the element with test id "games-instance-create" is visible

  @function:instance-console
  Scenario: a games member opens a running instance's HTTP console @function:instance-console @service:games @layer:ui
    Given this scenario is PENDING because "there is nothing to open: an instance console (/games/servers/** = ROLE_GAMES_SERVICES | ROLE_ADMIN | ROLE_MOD, be gateway) only exists once games/launch has started an instance, and games/launch has no mounted client. NOTE this row DOES name a seeded audience — the admins and the mod hold ROLE_ADMIN/ROLE_MOD — so the gate is open and the surface is empty, which is a different failure from every other pending here"
    And I am signed in as the persona for this scenario
    When I open the path "/games/servers/demo"
    Then the element with test id "games-instance-console" is visible

  @function:operator-ui
  Scenario: an operator curates the games app-store from the admin console @function:operator-ui @service:games @layer:ui
    Given this scenario is PENDING because "the admin-ui federated remote at /admin/games-services is not part of the seeded local stack, and no persona holds ROLE_GAMES_SERVICES_ADMIN or ROLE_GAMES_SERVICES_RUNNER. This is the one app-store surface on the FE gateway; the rest of the control plane is be-gateway"
    And I am signed in as the persona for this scenario
    When I open the path "/admin/games-services"
    Then the element with test id "games-services-catalog" is visible
