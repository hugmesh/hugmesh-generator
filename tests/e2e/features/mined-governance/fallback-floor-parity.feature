# WHAT THIS ASSERTS. A gateway loads route-access rows from Postgres/Cassandra.
# When neither datastore answers it falls back to CanonicalSeed.java, baked into
# the image. That class exists so the gate is "never silently fail-open" — its
# own words — and it carries the three /bff/*/internal/** deny rows for exactly
# that reason, with a comment explaining that WITHOUT them "decide() returns
# NO_RULE and the gateway FORWARDS on the coarse authenticated() floor — i.e.
# the datastore-unreachable fallback was WEAKER than the Postgres rules".
#
# MEASURED (2026-09-17, comment-stripped, both files parsed, with the gateway
# sibling at hugmesh-gateway main @ 13f1651d PLUS the #244 fe row this change
# lands; the BEFORE numbers in brackets are that same tree without it):
#   * the in-image floor carries 70 rows [69] over THREE gateway names (pki/be/
#     fe). The cluster seed carries 154 over FOUR — the superadmin gateway's 9
#     rows have no in-image counterpart at all.
#   * at the fe gateway the cluster seed governs 65 distinct url patterns (it was
#     61 when this file was written and rows have landed since); 34 of them [35]
#     have NO matching pattern in the in-image floor. That list still includes the
#     ENTIRE moderator plane (/mod/**, /bff/mod/**), the user plane
#     (/bff/user/**), forum, wiki, owncast and tube. /bff/superadmin/** LEFT the
#     list in this change — see the scenario below.
#   * so on the fallback, an authenticated ROLE_USER at /bff/mod/ban resolves
#     NO_RULE and is FORWARDED. The refusal still happens — mod-bff's own
#     @PreAuthorize("hasAnyRole('MOD','ADMIN')") is the wall — but it happens one
#     layer down, with no X-Route-Denied header and nothing in the gateway log.
#
# THIS IS THE SAME DEFECT CLASS THE DENY ROWS WERE ADDED TO FIX, still open on
# 30 more patterns (34 ungoverned, minus the 4 the divergence Outline below
# names; it was 31 before /bff/superadmin/** was closed). The positive scenarios
# below assert the measured divergence so it is visible in the feature text; the
# parity property itself is written out and PENDING with the count.
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

  # ✅ THIS SCENARIO INVERTED TWICE, and both inversions are the point.
  #
  # ROUND 1 it read "an fe path no seed governs forwards from BOTH sources, by
  # design", asserting NO_RULE on both legs, on the premise that the fe gateway
  # never fronts the superadmin BFF. That premise was already wrong —
  # apps/20-gateway-fe.yaml routes Path=/bff/** to admin-bff, so the browser DID
  # reach it; what refused a non-superadmin was admin-bff app-side, with no
  # X-Route-Denied header.
  #
  # ROUND 2 (#244 ACCEPT, cluster half) added the row to the Postgres seed only.
  # This scenario then asserted the DIVERGENCE — DENY from the seed, NO_RULE from
  # the in-image floor — and named itself as the thing to update "the day
  # hugmesh-gateway's CanonicalSeed.fe() gains the lockstep row".
  #
  # ROUND 3 is that day (decision 41, 2026-09-17). CanonicalSeed.fe() now carries
  # r(FE, "/bff/superadmin/**", "ROLE_SUPERADMIN"), so the two sources AGREE and
  # this scenario is a PARITY assertion. It is the half of a two-repo change:
  # hugmesh-gateway lands the seed row, this file moves with it, and neither PR
  # is complete without the other.
  #
  # WHY IT IS STILL HERE RATHER THAN DELETED. It is the ONE surface where the
  # whole file's defect class was closed, so it is the regression guard for it:
  # revert the gateway row and the second leg goes back to NO_RULE and this goes
  # RED, naming the file that moved.
  #
  # WHAT IS STILL TRUE AFTER IT. The MFA floor does NOT come with the baked row.
  # mfa_required=true is written only by the cluster seed's flip UPDATE onto the
  # POSTGRES copy (the baked floor is mfa_required=false by design, D8, so a
  # fallback can never lock out a privileged surface on the bare floor). So on a
  # dual-datastore outage the superadmin door is role-gated and header-emitting
  # again, but NOT step-up gated. That residual is stated here, asserted in
  # hugmesh-gateway's own suite, and is not something this file can measure.
  Scenario: the superadmin browser door is governed by the cluster seed AND by the fallback floor @layer:gateway
    Given a principal holding only the role "ROLE_USER"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the cluster seed
    Then the seed decision is "DENY"
    And the deciding url pattern is "/bff/superadmin/**"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the in-image floor
    Then the seed decision is "DENY"
    And the deciding url pattern is "/bff/superadmin/**"

  # The role that DOES hold a granting row reaches the console from both sources.
  # Without this a future "fix" could satisfy the scenario above by denying
  # everyone — parity on a locked door is not the parity #244 asked for.
  Scenario: the superadmin role reaches the console from both sources @layer:gateway
    Given a principal holding only the role "ROLE_SUPERADMIN"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the cluster seed
    Then the seed decision is "ALLOW"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the in-image floor
    Then the seed decision is "ALLOW"

  # THE ONE PLACE THE CARRIER COMMIT DIFFERED, pinned so it cannot drift back in.
  # 63c8952f paired its allow row with a DENY refinement on
  # /bff/superadmin/games-services/** (ROLE_SUPERADMIN, allow=false). #244's
  # ACCEPT is stated WITHOUT it and BOTH sources omit it, so the games-services
  # subtree must decide on the SAME /bff/superadmin/** pattern as its siblings.
  # If the refinement ever reappears in either source, the deciding pattern on
  # that leg becomes the longer one and this goes RED — which matters because the
  # refinement denies nobody (privileged principals bypass decide(), a
  # non-privileged one is already governed-but-ungranted) while, with
  # mfa_required left false on it, it would STRIP the MFA floor from exactly that
  # subtree.
  Scenario Outline: the games-services subtree decides on the platform pattern in <source> @layer:gateway
    Given a principal holding only the role "ROLE_USER"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/games-services/catalog" from the <source>
    Then the seed decision is "DENY"
    And the deciding url pattern is "/bff/superadmin/**"

    Examples:
      | source        |
      | cluster seed  |
      | in-image floor |

  # KNOWN-OPEN. The property CanonicalSeed's javadoc claims for itself.
  Scenario: the fallback floor governs every surface the cluster seed governs @layer:gateway
    Given this scenario is PENDING because "34 of the 65 url patterns the cluster seed governs at hugmesh-fe-gateway have NO matching row in the in-image CanonicalSeed floor, so on the datastore-unreachable fallback they resolve NO_RULE and FORWARD on the coarse authenticated() floor. Among them: /mod/**, /bff/mod/**, /bff/user/**, /bff/forum/**, /bff/wiki/**, /bff/wiki/superadmin/**, /bff/mesh/**, /bff/owncast/**, /bff/tube/**, /wiki/**, /owncast/**, /tube/**, /user/**, /api-docs/**, /_fragments/**, /character-studio/** and /bff/password-reset/request. This is the same hole the three /bff/*/internal/** deny rows were added to close, still open on the rest of the surface. Re-measured 2026-09-17 with the #244 gateway row in place: 35 -> 34, because /bff/superadmin/** LEFT the list (decision 41) — it is the FIRST pattern this property has ever recovered, and the only one. It was 31 of 61 when this was written and 35 of 65 on 2026-09-10."
    Then every url pattern the cluster seed governs at gateway "hugmesh-fe-gateway" is also governed by the in-image floor
