# WHAT THIS ASSERTS. A gateway loads route-access rows from Postgres/Cassandra.
# When neither datastore answers it falls back to CanonicalSeed.java, baked into
# the image. That class exists so the gate is "never silently fail-open" — its
# own words — and it carries the three /bff/*/internal/** deny rows for exactly
# that reason, with a comment explaining that WITHOUT them "decide() returns
# NO_RULE and the gateway FORWARDS on the coarse authenticated() floor — i.e.
# the datastore-unreachable fallback was WEAKER than the Postgres rules".
#
# MEASURED (2026-08-26, comment-stripped, both files parsed):
#   * the in-image floor carries 67 rows over THREE gateway names (pki/be/fe).
#     The cluster seed carries 150 over FOUR — the superadmin gateway's 9 rows
#     have no in-image counterpart at all.
#   * at the fe gateway the cluster seed governs 61 distinct url patterns; 31 of
#     them have NO matching pattern in the in-image floor. That list includes
#     the ENTIRE moderator plane (/mod/**, /bff/mod/**), the user plane
#     (/bff/user/**), forum, wiki, owncast and tube.
#   * so on the fallback, an authenticated ROLE_USER at /bff/mod/ban resolves
#     NO_RULE and is FORWARDED. The refusal still happens — mod-bff's own
#     @PreAuthorize("hasAnyRole('MOD','ADMIN')") is the wall — but it happens one
#     layer down, with no X-Route-Denied header and nothing in the gateway log.
#
# THIS IS THE SAME DEFECT CLASS THE DENY ROWS WERE ADDED TO FIX, still open on
# 31 more patterns. The positive scenarios below assert the measured divergence
# so it is visible in the feature text; the parity property itself is written out
# and PENDING with the count.
#
# NEEDS the hugmesh-gateway checkout beside this repo (source read only — no
# build, no stack). Absent, every scenario here SKIPS naming the path searched.
@layer:gateway @service:gateway
Feature: The in-image fail-closed floor is measured against the cluster seed

  Background:
    Given the cluster route-access seed is loaded
    And the in-image gateway fail-closed floor is loaded

  Scenario: the in-image floor covers only the three canonical gateway tiers @layer:gateway
    Then the in-image floor seeds exactly the gateways "hugmesh-pki-gateway, hugmesh-be-gateway, hugmesh-fe-gateway"

  # The three deny rows the class was extended for. These DO agree across both
  # sources, and that agreement is what the rest of this file is measured against.
  Scenario Outline: the floor and the cluster seed agree that <path> is explicitly denied @layer:gateway
    Given a principal holding only the role "ROLE_USER"
    When the "hugmesh-fe-gateway" gateway decides "<path>" from the in-image floor
    Then the seed decision is "DENY"
    And the deny came from an explicit deny row
    When the "hugmesh-fe-gateway" gateway decides "<path>" from the cluster seed
    Then the seed decision is "DENY"
    And the deny came from an explicit deny row

    Examples:
      | path                           |
      | /bff/internal/sessions         |
      | /bff/user/internal/moderation  |
      | /bff/mesh/internal/bridge-sync |

  # THE DIVERGENCE, stated positively so it executes green and stays visible.
  # Same principal, same path, two sources, two different outcomes — and NO_RULE
  # is not a refusal, it is a forward.
  Scenario Outline: <path> is governed by the cluster seed and UNGOVERNED by the fallback floor @layer:gateway
    Given a principal holding only the role "<granted>"
    When the "hugmesh-fe-gateway" gateway decides "<path>" from the cluster seed
    Then the seed decision is "DENY"
    And the deciding url pattern is "<pattern>"
    When the "hugmesh-fe-gateway" gateway decides "<path>" from the in-image floor
    Then the seed decision is "NO_RULE"

    # The granted role is chosen per row to be one the CLUSTER seed refuses at
    # that pattern — otherwise the first Then would pass for the wrong reason and
    # the NO_RULE below would look like a harmless difference.
    Examples:
      | granted   | path             | pattern      |
      | ROLE_USER | /mod/console     | /mod/**      |
      | ROLE_USER | /bff/mod/ban     | /bff/mod/**  |
      | ROLE_MOD  | /bff/user/blocks | /bff/user/** |
      | ROLE_USER | /wiki/home       | /wiki/**     |

  # A path that is ungoverned in BOTH — the fe gateway never fronts the
  # superadmin BFF (that lives on the be and superadmin gateways), so this one
  # forwards by design rather than by omission. Included so the NO_RULE outcome
  # above is not read as "always a bug".
  Scenario: an fe path no seed governs forwards from both sources, by design @layer:gateway
    Given a principal holding only the role "ROLE_USER"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the cluster seed
    Then the seed decision is "NO_RULE"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the in-image floor
    Then the seed decision is "NO_RULE"

  # KNOWN-OPEN. The property CanonicalSeed's javadoc claims for itself.
  Scenario: the fallback floor governs every surface the cluster seed governs @layer:gateway
    Given this scenario is PENDING because "31 of the 61 url patterns the cluster seed governs at hugmesh-fe-gateway have NO matching row in the in-image CanonicalSeed floor, so on the datastore-unreachable fallback they resolve NO_RULE and FORWARD on the coarse authenticated() floor. Among them: /mod/**, /bff/mod/**, /bff/user/**, /bff/forum/**, /bff/wiki/**, /bff/mesh/**, /bff/owncast/**, /bff/tube/**, /wiki/**, /owncast/**, /tube/**, /user/**, /api-docs/**, /_fragments/**, /character-studio/**. This is the same hole the three /bff/*/internal/** deny rows were added to close, still open on the rest of the surface."
    Then every url pattern the cluster seed governs at gateway "hugmesh-fe-gateway" is also governed by the in-image floor
