# The front-door route contract for the services that had ZERO driven coverage.
#
# WHAT THIS PROVES, and why it is not decoration. Four committed artefacts have
# to agree before a service is reachable at all:
#
#   tests/stack/gateway-routes/fe/application-routes.yml   the ROUTE
#   specs/cluster/manifests/route-access/initdb/20-schema.sql   the GATE
#   specs/cluster/optional-services.yaml                   the MOUNT
#   specs/cluster/manifests/<svc>/deployment.yaml          the PLACEMENT
#
# Nothing in tests/e2e checked that they agree. The failure mode is documented in
# this repo's own prose (tests/stack/seed-e2e.sh): a service "runs as containers
# and is INVISIBLE in the host shell's menu — running-but-unreachable, which is
# precisely the failure the catalogue was written to prevent". A route without a
# gate row is a 403 for everybody (the gateway is default-deny); a gate row
# without a route is a 404 that renders as a blank page an assertion will happily
# pass against.
#
# These scenarios run with the STACK DOWN — they read the committed files. That
# is deliberate: it is the half of this domain's coverage that stays true on a
# laptop with no mesh, and it is what makes the driven-UI features below
# meaningful rather than the only thing here.
@harness @layer:gateway
Feature: Every uncovered service is routed, gated and mounted consistently

  # ── the UI mount ──────────────────────────────────────────────────────────
  # StripPrefix=1 on every one of these: the remote is built with
  # --base-href=/<slug>/ so the browser asks for /<slug>/main.js, and stripping
  # the one segment maps that onto the container webroot nginx serves. Without
  # BOTH the base-href and the strip the bundles resolve at the origin root and
  # 404 — Angular never boots and the page is blank.
  Scenario Outline: the <service> UI mount is routed at the front door @service:<service> @layer:gateway
    Then the fe gateway routes "<pattern>" to the "<upstream>" upstream
    And the fe gateway route for "<pattern>" to the "<upstream>" upstream strips 1 path segment
    And html navigations for "<pattern>" reach the host shell before the "<upstream>" upstream

    Examples:
      | service          | pattern              | upstream                       |
      | wiki             | /wiki/**             | hugmesh-wiki-ui                |
      | owncast          | /owncast/**          | hugmesh-owncast-ui             |
      | tube             | /tube/**             | hugmesh-tube-ui                |
      | character-studio | /character-studio/** | hugmesh-character-studio-ui    |
      | character-forge  | /character-forge/**  | hugmesh-character-forge-ui     |

  # phpBB is the ODD ONE OUT and has burned this repo once already. It is a
  # server-rendered app, not a shell remote, mounted at /social/phpbb — and the
  # route DELIBERATELY strips TWO segments because the hugmesh-forum-api image
  # installs phpBB with script_path=/. An earlier revision correctly had NO
  # StripPrefix for a since-replaced image; with the real image that produced a
  # themed phpBB 404 on every URL while the index page still rendered — a failure
  # that looks fine on first load. Pinning the count is what catches the swap.
  # NOTE: /social/phpbb is deliberately ABSENT from the deep-link route's pattern
  # list — phpBB is a server-rendered app, not a shell remote, and MUST keep
  # serving its own HTML. That absence is why this scenario asserts only the
  # strip, while every remote above also asserts the deep-link hop.
  @service:phpbb @layer:gateway
  Scenario: the phpBB forum strips its two-segment mount before the upstream @layer:gateway @service:phpbb
    Then the fe gateway routes "/social/phpbb/**" to the "phpbb" upstream
    And the fe gateway route for "/social/phpbb/**" to the "phpbb" upstream strips 2 path segments

  # The forum MICRO-FRONTEND (hugmesh-forum-ui) is a different surface from the
  # phpBB pod above and is the one the host shell mounts.
  @service:phpbb @layer:gateway
  Scenario: the forum micro-frontend is routed as a path remote, not a subdomain @layer:gateway @service:phpbb
    Then the fe gateway routes "/social/forum/**" to the "hugmesh-forum-ui" upstream
    And the fe gateway route for "/social/forum/**" to the "hugmesh-forum-ui" upstream strips 2 path segments
    And html navigations for "/social/forum/**" reach the host shell before the "hugmesh-forum-ui" upstream

  # ── the BFF prefix ────────────────────────────────────────────────────────
  # Each of these is a SIBLING prefix that must precede the /bff/** admin
  # catch-all (Spring Cloud Gateway matches in declared order). A sibling that
  # slips below the catch-all silently reaches the ADMIN BFF instead, which
  # answers 403 rather than 404 — a permission bug wearing a routing bug's face.
  Scenario Outline: the <service> BFF prefix is routed to its own service @service:<service> @layer:bff
    Then the fe gateway routes "<pattern>" to the "<upstream>" upstream

    Examples:
      | service         | pattern                  | upstream                            |
      | wiki            | /bff/wiki/**             | hugmesh-wiki-bff-api                |
      | owncast         | /bff/owncast/**          | hugmesh-owncast-bff-api             |
      | tube            | /bff/tube/**             | hugmesh-tube-bff-api                |
      | character-forge | /bff/character-forge/**  | hugmesh-character-forge-bff-api     |
      | phpbb           | /bff/forum/**            | hugmesh-forum-bff-api               |

  # character-studio has NO dedicated BFF — it talks to the always-present
  # /bff/** routes. Asserted as an ABSENCE so that adding one is a deliberate act
  # rather than something this domain's coverage quietly stops describing.
  @service:character-studio @layer:bff
  Scenario: character-studio carries no BFF route of its own @layer:bff @service:character-studio
    Then the route-access seed has no fe gateway row for "/bff/character-studio/**"

  # ── the access gate ───────────────────────────────────────────────────────
  Scenario Outline: the <service> UI mount is gated by <access_role> @service:<service> @layer:gateway
    Then the route-access seed grants "<access_role>" at "<pattern>" on the fe gateway

    Examples:
      | service          | pattern              | access_role   |
      | wiki             | /wiki/**             | ROLE_WIKI     |
      | owncast          | /owncast/**          | ROLE_OWNCAST  |
      | tube             | /tube/**             | ROLE_TUBE     |
      | character-studio | /character-studio/** | ROLE_USER     |
      | character-forge  | /character-forge/**  | ROLE_USER     |
      | phpbb            | /social/forum/**     | ROLE_FORUM    |
      | games            | /games/admin/**      | ROLE_GAMES_ADMIN |

  Scenario Outline: the <service> BFF prefix is gated by <access_role> @service:<service> @layer:bff
    Then the route-access seed grants "<access_role>" at "<pattern>" on the fe gateway

    Examples:
      | service         | pattern                 | access_role  |
      | wiki            | /bff/wiki/**            | ROLE_WIKI    |
      | owncast         | /bff/owncast/**         | ROLE_OWNCAST |
      | tube            | /bff/tube/**            | ROLE_TUBE    |
      | character-forge | /bff/character-forge/** | ROLE_USER    |
      | phpbb           | /bff/forum/**           | ROLE_FORUM   |

  # The phpBB POD itself is backend-only and isolated in the hugmesh-forum
  # namespace: it deliberately has NO route-access row. Pinning the absence stops
  # somebody "fixing" the missing row and silently opening the pod.
  @service:phpbb @layer:gateway
  Scenario: the phpBB pod itself is contractually row-less in route-access @layer:gateway @service:phpbb
    Then the route-access seed has no fe gateway row for "/social/phpbb/**"

  # The games ADMIN gate is the composite ROLE_GAMES_ADMIN only — the AND of
  # games and (admin|mod), materialised by derive-games-admin.sh on compose and
  # the games-admin-sync job on the cluster. A single input role is default-deny,
  # which is why there is no ROLE_GAMES row and no ROLE_ADMIN row at the two
  # ADMIN patterns (the admin HTML path and the admin API path).
  @service:games @layer:gateway
  Scenario: the games admin mount and admin API are keyed on the derived composite role alone @layer:gateway @service:games
    Then the route-access seed grants "ROLE_GAMES_ADMIN" at "/games/admin/**" on the fe gateway
    And the route-access seed grants "ROLE_GAMES_ADMIN" at "/games/api/admin/**" on the fe gateway

  # The games MEMBER surface (2026-10-28): the `games` federation remote's bytes
  # and member HTML live under /games/** and its API under /games/api/**, both
  # proxied by the fe gateway (routes games-ui / games-bff). Until this round the
  # fe side had NO /games/** row at all — /games was a host-shell placeholder the
  # gateway never proxied, and the absence was pinned here. Now a games member
  # (ROLE_GAMES) must reach both, with admins as a paired superset. A platform mod
  # without ROLE_GAMES is not a games member, so ROLE_MOD has no row here.
  @service:games @layer:gateway
  Scenario: a games member reaches the games remote and its member API through the browser door @layer:gateway @service:games
    Then the route-access seed grants "ROLE_GAMES" at "/games/**" on the fe gateway
    And the route-access seed grants "ROLE_ADMIN" at "/games/**" on the fe gateway
    And the route-access seed grants "ROLE_GAMES" at "/games/api/**" on the fe gateway
    And the route-access seed grants "ROLE_ADMIN" at "/games/api/**" on the fe gateway
    And the fe gateway routes "/games/api/**" to the "hugmesh-games-bff" upstream
    And the fe gateway routes "/games/**" to the "hugmesh-games-ui" upstream
    And the fe gateway route for "/games/api/**" to the "hugmesh-games-bff" upstream strips 1 path segment
    And the fe gateway route for "/games/**" to the "hugmesh-games-ui" upstream strips 1 path segment
    And html navigations for "/games/**" reach the host shell before the "hugmesh-games-ui" upstream
