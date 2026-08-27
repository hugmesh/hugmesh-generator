# The route-access ORACLE reconciled against the route-access SEED.
#
# tests/e2e/specs/rbac-route-access.ts opens by calling itself "the authoritative
# gateway_route_access matrix". It is not. It is a HAND COPY of 50 of the seed's
# 150 rows, made before any gateway existed, and features/rbac/gateway-route-access.feature
# runs 30 assertions against it while uncovered-services.steps.ts reads the SEED
# for a different set of assertions. Two authorities, in one suite, never once
# compared.
#
# THIS FEATURE COMPARES THEM. It is not a lament: three of its scenarios PIN the
# oracle's known, contained divergences so that CLOSING one fails here loudly and
# names the follow-up, exactly as uncovered-services' "no persona holds the access
# role ROLE_WIKI" tripwire does. The measured facts, taken from the two committed
# files rather than quoted:
#
#   oracle 50 rows   seed 150 rows
#   oracle rows with no seed counterpart: 5 — and all 5 are the ROLE_ANONYMOUS
#     rows whose seed counterpart is the SAME (gateway, url_pattern) with the role
#     PUBLIC. The hand copy has not otherwise drifted.
#   per gateway — seed pki 4 / be 60 / fe 77 / superadmin 9
#                 oracle    3 /   33 /   11 /              3
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
  # exactly PUBLIC (GatewayRouteAccessService.isPublic). The oracle's five
  # ROLE_ANONYMOUS rows are therefore a translation, and this scenario is what
  # stops a SIXTH invented role name being added beside them.
  Scenario: PUBLIC is the public role on both sides of the contract @layer:gateway @service:gateway
    Given the route-access seed and the route-access oracle are both loaded
    Then the route-access seed contains no row whose role is "ROLE_ANONYMOUS"
    And the only role the oracle names that the route-access seed never emits is "ROLE_ANONYMOUS"

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

  Scenario: the oracle still cannot express an explicit DENY @layer:gateway @service:gateway
    Given the route-access seed and the route-access oracle are both loaded
    Then the route-access oracle carries no explicit-deny field

  Scenario Outline: the oracle still carries no row for <what> @layer:gateway @service:gateway
    Given the route-access seed and the route-access oracle are both loaded
    Then the route-access oracle carries no fe gateway row for "<pattern>"

    Examples:
      | what                 | pattern           |
      | the shell document   | /index.html       |
      | hashed JS bundles    | /*.js             |
      | hashed CSS bundles   | /*.css            |
      | the import map       | /importmap.json   |
      | the remote entry     | /remoteEntry.json |
      | the favicon          | /favicon.ico      |
      | the static asset tree| /assets/**        |

  # The consequence, stated as a decision rather than as a missing row: the oracle
  # answers DENY for the anonymous SPA shell, which the seed makes PUBLIC. This is
  # why an offline ALLOW/DENY taken from the oracle must never be read as "the
  # front door is open".
  Scenario Outline: the oracle denies an anonymous caller <what>, which the seed grants @layer:gateway @service:gateway
    Then the route-access oracle decides "DENY" for a caller holding "" at "<path>" on the "hugmesh-fe-gateway" gateway

    Examples:
      | what               | path               |
      | the shell document | /index.html        |
      | a hashed bundle    | /main-ABC123DEF.js |
      | the import map     | /importmap.json    |
