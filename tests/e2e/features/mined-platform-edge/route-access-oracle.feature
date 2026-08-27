# The route-access ORACLE reconciled against the route-access SEED.
#
# tests/e2e/specs/rbac-route-access.ts opens by calling itself "the authoritative
# gateway_route_access matrix". When this lane was written it was NOT: it was a
# HAND COPY of 50 of the seed's 150 rows, made before any gateway existed, while
# features/rbac/gateway-route-access.feature ran 30 assertions against it and
# uncovered-services.steps.ts read the SEED for a different set. Two authorities,
# in one suite, never once compared. The measured gap then:
#
#   oracle 50 rows   seed 150 rows
#   per gateway — seed pki 4 / be 60 / fe 77 / superadmin 9
#                 oracle    3 /   33 /   11 /              3
#
# EVERY TRIPWIRE BELOW HAS SINCE FIRED, which is the outcome they were planted
# for. main replaced the hand copy with specs/rbac-route-access.seed.ts, GENERATED
# from that same SQL by scripts/gen-route-access-oracle.py and gated by
# tests/scripts/test-route-access-oracle.sh. RE-MEASURED at the integration, by
# execution:
#
#   oracle 152 rows   seed 152 rows            (per gateway, identical on all four)
#   oracle rows with no seed counterpart: 0
#   roles the oracle names that the seed never emits: NONE — the five
#     ROLE_ANONYMOUS translations are gone, because nothing is translated any more
#   RouteRule carries `allow`, so the seed's four explicit DENY rows are in it
#   the fe SPA-shell rows (/index.html, /*.js, /*.css, /importmap.json,
#     /remoteEntry.json, /favicon.ico, /assets/**) are all present and PUBLIC
#
# So the scenarios below assert the AGREEMENT rather than the gap. That is not a
# weaker lane: a regenerated oracle that falls behind the seed again fails here.
#
# RUNS OFFLINE. Both authorities are committed artefacts; nothing here needs a mesh.
@harness @layer:gateway @service:gateway
Feature: The route-access oracle is reconciled against the route-access seed

  # The property that keeps the hand copy honest. Not "the two are equal" — the
  # oracle is openly a subset — but "every row it DOES carry is a real row".
  Scenario: every oracle row is a real seeded row @layer:gateway @service:gateway
    Given the route-access seed and the route-access oracle are both loaded
    Then every oracle row is a seeded row once "ROLE_ANONYMOUS" is read as "PUBLIC"
    And the route-access oracle carries no more rows than the seed on any gateway

  # ROLE_ANONYMOUS IS NOT THE PUBLIC ROLE. The seed emits that string zero times;
  # the gateway admits an unauthenticated caller only on a row whose role is
  # exactly PUBLIC (GatewayRouteAccessService.isPublic). The hand-copied oracle
  # carried five ROLE_ANONYMOUS rows — a translation — and this scenario stopped a
  # SIXTH invented role name being added beside them.
  #
  # The generated oracle translates NOTHING, so the assertion tightens from "one
  # known translation" to "no invented role at all". Measured: zero.
  Scenario: PUBLIC is the public role on both sides of the contract @layer:gateway @service:gateway
    Given the route-access seed and the route-access oracle are both loaded
    Then the route-access seed contains no row whose role is "ROLE_ANONYMOUS"
    And the route-access oracle names no role the route-access seed never emits

  # The five translated rows, named individually so a reader can see the whole set
  # rather than a count.
  Scenario Outline: the oracle's <what> row is seeded PUBLIC on the <gateway> gateway @layer:gateway @service:gateway
    Then the route-access seed grants "PUBLIC" at "<pattern>" on the "<gateway>" gateway

    Examples:
      | what              | gateway                | pattern         |
      | front page        | hugmesh-fe-gateway     | /               |
      | login mount       | hugmesh-fe-gateway     | /login/**       |
      | login BFF         | hugmesh-fe-gateway     | /bff/login      |
      | pki login mount   | hugmesh-pki-gateway    | /login/**       |
      | OIDC discovery    | hugmesh-pki-gateway    | /.well-known/** |

  # ── TRIPWIRES. Each of the three below asserts a LIMITATION of the oracle that
  # is true today. Each failure message says what to do when it stops being true;
  # a green run here means the offline oracle lane still cannot describe the thing
  # named, and the seed-side scenarios in this domain are the ones that can.

  Scenario: the oracle expresses the seed's explicit DENY rows @layer:gateway @service:gateway
    Given the route-access seed and the route-access oracle are both loaded
    Then the route-access oracle carries every explicit-deny row the seed carries

  Scenario Outline: the oracle carries the seed's PUBLIC row for <what> @layer:gateway @service:gateway
    Given the route-access seed and the route-access oracle are both loaded
    Then the route-access oracle carries the fe gateway row for "<pattern>" that the seed grants PUBLIC

    Examples:
      | what                 | pattern           |
      | the shell document   | /index.html       |
      | hashed JS bundles    | /*.js             |
      | hashed CSS bundles   | /*.css            |
      | the import map       | /importmap.json   |
      | the remote entry     | /remoteEntry.json |
      | the favicon          | /favicon.ico      |
      | the static asset tree| /assets/**        |

  # The consequence, stated as a decision rather than as a row count. The oracle
  # used to answer DENY for the anonymous SPA shell that the seed makes PUBLIC —
  # two of the three paths below because the row was simply missing, and
  # /main-ABC123DEF.js because '/*.js' was read as a literal by a matcher with no
  # single-segment glob. Both are fixed, so the oracle now ADMITS all three, and
  # this scenario is what fails if either regresses.
  Scenario Outline: the oracle admits an anonymous caller <what>, exactly as the seed grants @layer:gateway @service:gateway
    Then the route-access oracle decides "ALLOW" for a caller holding "" at "<path>" on the "hugmesh-fe-gateway" gateway

    Examples:
      | what               | path               |
      | the shell document | /index.html        |
      | a hashed bundle    | /main-ABC123DEF.js |
      | the import map     | /importmap.json    |
