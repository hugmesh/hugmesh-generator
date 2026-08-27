# The fe FRONT DOOR, in both of its committed tables.
#
# The same front door is written twice: tests/stack/gateway-routes/fe/application-routes.yml
# (compose, Spring Cloud Gateway `predicates: - Path=`) and
# specs/cluster/apps/20-gateway-fe.yaml (kind + production, the chart's flat
# `path:`). uncovered-services.steps.ts pins FE_ROUTES_YML to the COMPOSE table
# alone, so no test has ever read the cluster one — which is how a route present
# in one and absent from the other stays invisible.
#
# THE FAILURE CLASS THIS FEATURE GUARDS is recorded verbatim in the cluster table
# itself (20-gateway-fe.yaml, the EXTERNAL CLIENT PROTOCOL SURFACES block): "with
# no /_matrix or /api/v1 route on the FRONT DOOR, both paths fell through to the
# `frontend-host` /** catch-all and the Angular shell answered its own index.html
# — GET https://localhost:8488/_matrix/client/versions -> 200 text/html". That is
# the purest form of the blank-page class: a 200, a body, a content-type that is
# wrong for the caller, and no error anywhere. It was fixed twice by hand, once
# per table, and guarded neither time.
#
# RUNS OFFLINE — every artefact read here is committed.
@harness @layer:gateway @service:gateway
Feature: The fe route tables put every protocol and asset prefix ahead of the SPA catch-all

  Scenario Outline: <prefix> is claimed by a real route before the catch-all in both tables @service:<service> @layer:gateway
    Then the "compose" fe gateway claims "<prefix>" before the "frontend-host" catch-all
    And the "cluster" fe gateway claims "<prefix>" before the "frontend-host" catch-all

    Examples:
      | service | prefix                     |
      | tuwunel | /_matrix/client/versions   |
      | tuwunel | /.well-known/matrix/client |
      | akkoma  | /api/v1/instance           |
      | akkoma  | /oauth/authorize           |
      | gateway | /_fragments/index.json     |
      | gateway | /bff/session               |

  Scenario: the SPA catch-all is declared last in both tables @layer:gateway @service:gateway
    Then "frontend-host" is the final route in the "compose" fe gateway table
    And "frontend-host" is the final route in the "cluster" fe gateway table

  # ── THE DEEP-LINK HOP ──────────────────────────────────────────────────────
  # Every shell-mounted remote path is served by TWO routes, and the first of them
  # exists so a REFRESH or a shared link reaches the host shell rather than the
  # bare remote. The shell injects its CSP nonce with a sub_filter inside its own
  # `location /` block, so this route must forward the path VERBATIM: rewriting it
  # moves the request out of that block, the shell still answers 200, the policy
  # still demands a nonce, and no script tag carries one.
  #
  # uncovered-services/route-contract.feature already asserts that this route
  # exists, is declared first, and carries the Accept predicate. It does NOT
  # assert the absence of a rewriting filter, and it covers /social/forum/** but
  # neither of the two social remotes.
  Scenario: the deep-link route forwards the path verbatim @layer:gateway @service:gateway
    Then the fe gateway route "remote-deeplink-to-host-shell" declares no path-rewriting filter

  Scenario Outline: html navigations for <pattern> reach the shell before <upstream> @service:<service> @layer:gateway
    Then html navigations for "<pattern>" reach the host shell before the "<upstream>" upstream
    And the fe gateway deep-link route is scoped to html navigations only for "<pattern>"

    Examples:
      | service | pattern             | upstream            |
      | tuwunel | /social/matrix/**   | hugmesh-matrix-ui   |
      | akkoma  | /social/mastodon/** | hugmesh-mastodon-ui |

  # Absences that are DECISIONS, not omissions — each for a different reason, all
  # three recorded in the route table's own comment block.
  Scenario: server-rendered and non-colliding prefixes stay off the deep-link route @layer:gateway @service:gateway
    Then the fe gateway deep-link route does not claim "/social/phpbb/**"
    And the fe gateway deep-link route does not claim "/api-docs/**"
    And the fe gateway deep-link route does not claim "/admin/**"

  # ── THE MESH BFF ───────────────────────────────────────────────────────────
  # /bff/mesh/** exists ONLY in the cluster table, so nothing in this suite has
  # ever read it. A sibling prefix that slips below the /bff/** admin catch-all
  # does not 404 — it reaches the ADMIN bff, which answers 403 for an identity it
  # has never heard of: a routing bug wearing a permission bug's face.
  Scenario: the mesh BFF prefix is routed ahead of the /bff/** admin catch-all @layer:bff
    Then the cluster fe gateway routes "/bff/mesh/**" to the "hugmesh-mesh-bff-api" upstream
    And the cluster fe gateway declares "/bff/mesh/**" before "/bff/**"
    And the route-access seed grants "ROLE_MESH" at "/bff/mesh/**" on the "hugmesh-fe-gateway" gateway

  Scenario Outline: <pattern> is declared before the /bff/** admin catch-all @service:<service> @layer:bff
    Then the cluster fe gateway declares "<pattern>" before "/bff/**"

    Examples:
      | service         | pattern                 |
      | wiki            | /bff/wiki/**            |
      | phpbb           | /bff/forum/**           |
      | character-forge | /bff/character-forge/** |

  # ── THE FRAGMENT FLEET ─────────────────────────────────────────────────────
  # A route to a live host on a dead port is not a 404. The gateway 5xxes or
  # hangs, the shell's loadRemoteModule rejects, and the fragment region renders
  # EMPTY inside an otherwise healthy page.
  Scenario: the fragment prefix is routed and gated at the front door @layer:gateway @service:gateway
    Then the fe gateway routes "/_fragments/**" to the "hugmesh-remote-fragment" upstream
    And the cluster fe gateway routes "/_fragments/**" to the "hugmesh-remote-fragment" upstream
    And the route-access seed grants "ROLE_USER" at "/_fragments/**" on the "hugmesh-fe-gateway" gateway

  Scenario Outline: the <table> fragment route targets the web listener, not the sync sidecar @layer:gateway @service:gateway
    Then the "<table>" fe gateway route for "/_fragments/**" targets a port the remote-fragment web listener serves

    Examples:
      | table   |
      | cluster |
      | compose |
