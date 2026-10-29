# The games FUNCTION surface — what the `games` remote really offers, and the
# honest gap that remains.
#
# games-console.feature drives the two host-shell mounts and the derived
# ROLE_GAMES_ADMIN "AND". This feature covers the REST of what the word "games"
# implies, split along the line the backend draws:
#
#   * the games MEMBER + ADMIN screens (2026-10-28): the `games` native-federation
#     remote (hugmesh-games/games-ui) mounted at /games and /games/admin, talking
#     to the games BFF (hugmesh-games/backend) through the fe-gateway's
#     /games/api/** route. Catalog, launch/play, admin overview, live sessions,
#     session logs, per-game access rules and settings — these EXIST now, with
#     a container in tests/stack/compose.games.yaml (`games` profile) and fe
#     routes games-ui / games-bff, and the scenarios below drive them;
#
#   * the games APP-STORE control plane (games-services: server INSTANCES offered
#     per domain, their lifecycle, their HTTP consoles, the operator UI at
#     /admin/games-services). That is a DIFFERENT surface — /bff/games-services/**
#     on the be gateway, ROLE_GAMES_SERVICES* roles no seeder mints — and it still
#     has NO client in this mesh. Its four scenarios stay PENDING, and their reasons
#     no longer claim "there is no games micro-frontend": there is one, it just
#     is not an app-store client.
#
# THAT IS WHY THE FIRST SCENARIO BELOW IS A `grep` THAT MUST SUCCEED. It used to
# be a grep that had to FAIL ("no hugmesh-games-ui in the compose stack"), the
# measurement that kept the app-store pendings non-vacuous. The container now
# exists, so the same measurement is inverted: the games profile file MUST define
# the remote, and the include comment in compose.local.yaml MUST name it — a
# transcript of the search finding both is the evidence the member screens are
# wired, and it goes red the day somebody removes the service.
@service:games @layer:ui
Feature: What the games mounts really offer, and the four app-store functions with no client

  # ── the measurement that makes the member screens' existence a fact ───────
  @function:catalogue @interface:cli @layer:ui
  Scenario: the committed compose stack defines the games micro-frontend behind the games profile @function:catalogue @interface:cli @layer:ui @service:games
    When I run the shell command "grep -c '^  hugmesh-games-ui:' tests/stack/compose.games.yaml"
    Then the command succeeded
    And the evidence manifest holds a "transcript" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  # The negative control for the same search: the service lives in the profile
  # file, NOT in compose.local.yaml's always-on service list — a games member
  # screen that came up on a plain `make stack-up` (no GAMES=1) would be the
  # wasm bundles' 333M sibling clone becoming a hard dependency of every stack.
  @function:catalogue @interface:cli @layer:ui
  Scenario: the games micro-frontend is NOT an always-on service of the core stack @function:catalogue @interface:cli @layer:ui @service:games
    When I run the shell command "grep -c '^  hugmesh-games-ui:' tests/stack/compose.local.yaml"
    Then the command failed
    And the command exit code was 1
    And the evidence manifest holds a "transcript" artefact for this scenario

  # ── entry: the member catalog's contract (M1) ─────────────────────────────
  # One card per playable game, ONE badge each ('Plays here' / 'Opens in a new
  # tab' / 'Not available on this deployment'), and a play control. chess is a
  # web-native bundle on every deployment that ships the wasm-fragment tier.
  @function:entry @env:docker
  Scenario Outline: <role> sees the catalog with a playable card and its badge @role:<role> @function:entry @service:games @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/games"
    Then the element with test id "games-catalog" is visible
    And the element with test id "games-card-chess" is visible
    And the element with test id "games-badge-chess" is visible
    And the element with test id "games-play-chess" is visible

    Examples:
      | role           |
      | e2e-gamesonly  |
      | e2e-gamesadmin |
      | e2e-admin      |

  # ── admin: the derived mount's console contract (A0–A5) ──────────────────
  # The admin shell is a tab bar of RELATIVE child links; each tab is a real
  # screen against a real backend endpoint (overview: /games/api/admin/stats +
  # /sessions; live: /admin/multiplayer-sessions; logs: /session-logs/admin;
  # access: /admin/games/<slug>/access; settings: /admin/debug-mode).
  @function:admin @env:docker
  Scenario Outline: <role> reaches every games-admin tab @role:<role> @function:admin @service:games @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/games/admin"
    Then the element with test id "games-admin-shell" is visible
    And the element with test id "games-admin-overview" is visible
    When I open the path "/games/admin/sessions"
    Then the element with test id "games-admin-live" is visible
    When I open the path "/games/admin/logs"
    Then the element with test id "games-admin-logs" is visible
    When I open the path "/games/admin/access"
    Then the element with test id "games-admin-access" is visible
    When I open the path "/games/admin/settings"
    Then the element with test id "games-admin-settings" is visible

    Examples:
      | role           |
      | e2e-gamesadmin |
      | e2e-superadmin |

  # ── THE THREE ENVIRONMENTS, on the lightest surface in the domain ─────────
  #
  # The operator asked for evidence in docker, local devops and QEMU. The games
  # entry point is still the right place to spend that, but it is no longer
  # free: since 2026-10-28 it is the `games` remote, which needs the games
  # profile (compose), the games slug (kind — manifests/games-ui, with the
  # cluster BFF still on the games realm, see apps/20-gateway-fe.yaml) or a
  # games-selected image (qemu). Each row availability-probes its own door and,
  # when nothing answers, SKIPS naming the exact command to bring that
  # environment up. kind and qemu cannot be available at once on this host: the
  # kind node and a QEMU launcher both publish host port :8443 and only one can
  # hold it (the compose stack's door is PUBLIC_HTTPS_PORT, default 8488, so it
  # sits beside either — unless it is published on :8443 too).
  @function:entry @role:e2e-gamesadmin
  Scenario Outline: the games catalog renders in the <env> environment @role:e2e-gamesadmin @function:entry @service:games @layer:ui @env:<env>
    Given I am signed in as the persona for this scenario
    When I open the path "/games"
    Then the element with test id "games-catalog" is visible

    Examples:
      | env    |
      | docker |
      | kind   |
      | qemu   |

  # ── the four APP-STORE functions with no client ───────────────────────────
  #
  # No @role: tag on any of them, deliberately: the roles these need
  # (ROLE_GAMES_SERVICES, ROLE_GAMES_SERVICES_ADMIN, ROLE_GAMES_SERVICES_RUNNER)
  # are minted by no seeder, and steps/dimensions.ts validates @role: in the
  # Before hook — before a PENDING step could skip — so naming a fictional handle
  # would turn an honest pending into a hard error.
  @function:catalogue
  Scenario: a games-services member lists the server instances offered to their domain @function:catalogue @service:games @layer:ui
    Given this scenario is PENDING because "the games app-store control plane has a seeded route-access row (/bff/games-services/catalog/** = ROLE_GAMES_SERVICES on the be gateway) and NO client: the `games` remote mounted at /games lists the games MEMBER catalog from /games/api/games, not the app-store's per-domain server offers, and no persona holds ROLE_GAMES_SERVICES. This is waiting on a BUILD (an app-store client), not on a seeder line"
    And I am signed in as the persona for this scenario
    When I open the path "/admin/games-services"
    Then the element with test id "games-services-catalog" is visible

  @function:launch
  Scenario: a games-services admin creates, runs and stops a game server instance @function:launch @service:games @layer:ui
    Given this scenario is PENDING because "the instance lifecycle is a control-plane API (/bff/games-services/instances/** = ROLE_GAMES_SERVICES_ADMIN | ROLE_GAMES_SERVICES_RUNNER, be gateway) with no mounted client, and neither role is minted by any seeder. A games MEMBER launching a title in the `games` remote (POST /games/api/games/<slug>/launch, games-console.feature) is a different function on a different row. The RUNNER half is the mod-delegated run/stop tier and needs its own scenario once a client exists"
    And I am signed in as the persona for this scenario
    When I open the path "/admin/games-services"
    Then the element with test id "games-instance-create" is visible

  @function:instance-console
  Scenario: a games member opens a running instance's HTTP console @function:instance-console @service:games @layer:ui
    Given this scenario is PENDING because "there is nothing to open: an instance console (/games/servers/** = ROLE_GAMES_SERVICES | ROLE_ADMIN | ROLE_MOD, be gateway) only exists once games/launch has started a server instance, and games/launch has no mounted client. NOTE this row DOES name a seeded audience — the admins and the mod hold ROLE_ADMIN/ROLE_MOD — so the gate is open and the surface is empty, which is a different failure from every other pending here"
    And I am signed in as the persona for this scenario
    When I open the path "/games/servers/demo"
    Then the element with test id "games-instance-console" is visible

  @function:operator-ui
  Scenario: an operator curates the games app-store from the admin console @function:operator-ui @service:games @layer:ui
    Given this scenario is PENDING because "the admin-ui federated remote at /admin/games-services is not part of the seeded local stack, and no persona holds ROLE_GAMES_SERVICES_ADMIN or ROLE_GAMES_SERVICES_RUNNER. This is the one app-store surface on the FE gateway; the rest of the control plane is be-gateway. The games admin console at /games/admin (A5 Settings) lists this and the other portal-only surfaces as 'managed in the standalone games portal'"
    And I am signed in as the persona for this scenario
    When I open the path "/admin/games-services"
    Then the element with test id "games-services-catalog" is visible
