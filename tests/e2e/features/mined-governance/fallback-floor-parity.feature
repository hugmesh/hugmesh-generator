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
# lands, against generator main AFTER decision 28 landed (4764ab4f); the BEFORE
# numbers in brackets are that same tree without the #244 row), then RE-MEASURED
# for decision 80a = B (hugmesh-generator#329; hugmesh-gateway#40, merge f0faca1,
# which adds the three wiki rows to CanonicalSeed.fe()). The 80a figures are
# marked [80a] and were measured by the lane that landed #40 (a port of the step
# at mined-governance.steps.ts, which reproduced 34/66 on the base):
#   * the in-image floor carries 72 rows [80a; 70 before it, 69 before #244] over
#     THREE gateway names (pki/be/fe; pki 3, be 32, fe 37). The cluster seed
#     carries 155 over FOUR as of 2026-09-17 — the superadmin gateway's 9
#     rows have no in-image counterpart at all.
#   * at the fe gateway the cluster seed governs 66 distinct url patterns (it was
#     61 when this file was written and rows have landed since); 31 of them [80a;
#     34 before it, 36 before #244] have NO matching pattern in the in-image floor.
#     That list still includes the ENTIRE moderator plane (/mod/**, /bff/mod/**),
#     the user plane (/bff/user/**), forum, owncast and tube. THREE patterns LEFT
#     the list in 80a — /bff/wiki/**, /bff/wiki/admin/** and
#     /bff/wiki/superadmin/** — and TWO left it in the #244 change before that:
#     /bff/superadmin/** and, because the floor's new `**` covers a
#     representative path under it, /bff/superadmin/games-services/** (put back in
#     the cluster seed by decision 28, landed the same day). See the scenarios.
#   * so on the fallback, an authenticated ROLE_USER at /bff/mod/ban resolves
#     NO_RULE and is FORWARDED. The refusal still happens — mod-bff's own
#     @PreAuthorize("hasAnyRole('MOD','ADMIN')") is the wall — but it happens one
#     layer down, with no X-Route-Denied header and nothing in the gateway log.
#
# THIS IS THE SAME DEFECT CLASS THE DENY ROWS WERE ADDED TO FIX, still open on
# 27 more patterns (31 ungoverned, minus the 4 the divergence Outline below
# names; it was 30 before decision 80a and 34 before the #244 row). The positive scenarios
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
  # ⚠ UPDATED AGAIN — decision 56 (hugmesh-generator#347, operator answer
  # 2026-09-18: "a declared set of privileged rows") closed HALF of the residual
  # the paragraph below used to describe as permanent. What follows is the
  # CURRENT truth, not the original; the struck reasoning is gone rather than
  # marked, because it is no longer merely superseded — it is factually wrong
  # about what the baked floor can carry.
  #
  # CanonicalSeed.r() (hugmesh-gateway) no longer hard-codes mfaRequired=false
  # for EVERY baked row. It stays false by default (D8), EXCEPT for a small,
  # named constant (MFA_REQUIRED_FALLBACK_ROWS) derived from this very file's
  # blanket flip UPDATE — and this fe /bff/superadmin/** row is IN that set (it
  # is the row decision 41 added, and decision 56's own item names it as the
  # "at minimum" entry). So mfa_required=true on this row's fallback copy is no
  # longer Postgres-only: the scenario two below pins it TRUE on BOTH sources.
  #
  # WHAT IS STILL TRUE. Decision 28's mfa_required=true on the cluster seed's
  # games-services DENY row is UNCHANGED — that row is a deny row, and D8's
  # narrowing (decision 56) reaches only rows built by `r()` (ALLOW rows);
  # `deny()` still hard-codes mfaRequired=false, unconditionally, and decision 56
  # was explicitly NOT authorised to mirror the games-services row into the
  # floor at all (recorded on hugmesh-generator#347, decision 56's own text: "do
  # not do it"). So THAT floor still drops on a dual-datastore outage — see the
  # games-services scenarios below, now pinning the MFA half of that residual
  # too, explicitly rather than leaving it to be inferred from an absence.
  Scenario: the superadmin browser door is governed by the cluster seed AND by the fallback floor @layer:gateway
    Given a principal holding only the role "ROLE_USER"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the cluster seed
    Then the seed decision is "DENY"
    And the deciding url pattern is "/bff/superadmin/**"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the in-image floor
    Then the seed decision is "DENY"
    And the deciding url pattern is "/bff/superadmin/**"

  # DECISION 56's closed half, stated positively. Before this decision the
  # second leg here would have read "does not require MFA" — that was the
  # divergence #244/#35 left open. Now both sources agree.
  Scenario: the superadmin browser door requires MFA on both sources @layer:gateway
    Given a principal holding only the role "ROLE_USER"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the cluster seed
    Then the deciding rule requires MFA
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the in-image floor
    Then the deciding rule requires MFA

  # THE be-gateway TWIN of the same declared row (be() carries its OWN
  # /bff/superadmin/** -> ROLE_SUPERADMIN row, pre-dating decision 41; decision
  # 56 declares it too — see MFA_REQUIRED_FALLBACK_ROWS's derivation comment).
  Scenario: the be-gateway superadmin infra console requires MFA on both sources @layer:gateway
    Given a principal holding only the role "ROLE_USER"
    When the "hugmesh-be-gateway" gateway decides "/bff/superadmin/workloads" from the cluster seed
    Then the deciding rule requires MFA
    When the "hugmesh-be-gateway" gateway decides "/bff/superadmin/workloads" from the in-image floor
    Then the deciding rule requires MFA

  # DECISION 56's boundary, stated as a NEGATIVE control. Not every SUPERADMIN
  # surface joined the declared set — pki()'s headscale catch-all did not (its
  # cluster-seed counterpart is mfa_required=false too: the blanket flip only
  # touches /bff/admin and /bff/superadmin patterns, and pki's row is a bare
  # /**). Without this, a future "every privileged row should have it" change
  # could widen the declared set unnoticed.
  Scenario: the pki headscale catch-all does NOT require MFA on either source @layer:gateway
    Given a principal holding only the role "ROLE_USER"
    When the "hugmesh-pki-gateway" gateway decides "/key" from the cluster seed
    Then the deciding rule does not require MFA
    When the "hugmesh-pki-gateway" gateway decides "/key" from the in-image floor
    Then the deciding rule does not require MFA

  # The role that DOES hold a granting row reaches the console from both sources.
  # Without this a future "fix" could satisfy the scenario above by denying
  # everyone — parity on a locked door is not the parity #244 asked for.
  Scenario: the superadmin role reaches the console from both sources @layer:gateway
    Given a principal holding only the role "ROLE_SUPERADMIN"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the cluster seed
    Then the seed decision is "ALLOW"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the in-image floor
    Then the seed decision is "ALLOW"

  # ⚠ THE TWO SOURCES DELIBERATELY DIVERGE HERE, and the divergence is asserted
  # rather than narrated. Carrier commit 63c8952f paired its allow row with a
  # DENY refinement on /bff/superadmin/games-services/** (ROLE_SUPERADMIN,
  # allow=false). #244's ACCEPT (decision 41) is stated WITHOUT it and authorises
  # exactly ONE baked row, so the in-image floor decides this subtree on the
  # platform pattern. The CLUSTER seed got the refinement BACK on 2026-09-17 —
  # operator decision 28 = D (4764ab4f) — with mfa_required pinned TRUE on the
  # row itself, which is why D beat leaving it out: isMfaRequiredSurface() is
  # allow-blind and reads the LONGEST match, so the deny row CARRIES the step-up
  # floor for that subtree instead of stripping it. The baked floor cannot
  # reproduce that (D8: no baked row may be mfa_required=true), so mirroring it
  # would import the wall without the floor. Whether to mirror it is NOT decided
  # by 41 and is recorded on #244, not settled here.
  #
  # WHAT THIS PINS, in both directions: remove decision 28's seed row and the
  # first leg's deciding pattern collapses to /bff/superadmin/** (RED); add a
  # games-services row to CanonicalSeed.fe() and the second leg's pattern grows
  # (RED). The OUTCOME is identical on both legs for a non-privileged principal —
  # that is the parity #244 asked for — while the deciding pattern is not.
  Scenario Outline: the games-services subtree is denied to a plain user by <source>, deciding on <pattern> @layer:gateway
    Given a principal holding only the role "ROLE_USER"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/games-services/catalog" from the <source>
    Then the seed decision is "DENY"
    And the deciding url pattern is "<pattern>"

    Examples:
      | source         | pattern                              |
      | cluster seed   | /bff/superadmin/games-services/**    |
      | in-image floor | /bff/superadmin/**                   |

  # THE PRIVILEGED LEG OF THAT SAME DIVERGENCE, measured rather than assumed.
  # ROLE_SUPERADMIN holds the role named on decision 28's DENY row, so the
  # cluster seed answers explicit-DENY (deny-wins at the longest pattern) while
  # the in-image floor — which has no such row — answers ALLOW from the platform
  # grant. This is INERT for a live request: GatewayRouteAccessFilter
  # short-circuits ROLE_SUPERADMIN before decide() is ever called, so neither
  # answer is what a real superadmin experiences. It is asserted anyway, because
  # it is the ONLY place the two sources give different verdicts for the same
  # principal and path, and a future reader must find it stated, not infer it.
  Scenario: the superadmin verdict on the games-services subtree differs between the two sources @layer:gateway
    Given a principal holding only the role "ROLE_SUPERADMIN"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/games-services/catalog" from the cluster seed
    Then the seed decision is "DENY"
    And the deny came from an explicit deny row
    And the deciding url pattern is "/bff/superadmin/games-services/**"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/games-services/catalog" from the in-image floor
    Then the seed decision is "ALLOW"
    And the deciding url pattern is "/bff/superadmin/**"

  # ⚠ MFA CONVERGES WHERE THE VERDICT DIVERGES — decision 56, added on top of
  # the ALLOW/DENY split two scenarios above (which is UNCHANGED by decision
  # 56: `deny()` still hard-codes mfaRequired=false unconditionally, and
  # decision 56 was explicitly not authorised to bake a games-services row into
  # the floor). Both sides answer "requires MFA" anyway, for TWO UNRELATED
  # reasons pinned separately so nobody mistakes this for one mechanism:
  #   * cluster seed: decision 28's ROW-SCOPED flip on the deny row ITSELF
  #     (isMfaRequiredSurface() is allow-blind — the deny row's own
  #     mfa_required=true carries the floor for this subtree);
  #   * in-image floor: decision 56's declared-set flip on the PLATFORM row
  #     (/bff/superadmin/**) that decides this path in the ABSENCE of any
  #     games-services-specific floor row — the same row the two scenarios
  #     above already pin ALLOW from.
  # A change that only touches one of the two mechanisms (the row-scoped SQL
  # flip, or MFA_REQUIRED_FALLBACK_ROWS) goes red here without touching the
  # ALLOW/DENY scenario above — the two properties are independent and this is
  # where that independence is proven, not assumed.
  Scenario: the games-services subtree requires MFA on both sources, for different reasons @layer:gateway
    Given a principal holding only the role "ROLE_USER"
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/games-services/catalog" from the cluster seed
    Then the deciding rule requires MFA
    When the "hugmesh-fe-gateway" gateway decides "/bff/superadmin/games-services/catalog" from the in-image floor
    Then the deciding rule requires MFA

  # DECISION 80b = B (hugmesh-generator#329) -- the wiki admin-console rows carry
  # the step-up floor on BOTH sources. The cluster seed gets it from the
  # per-service arms of the blanket flip in 20-schema.sql
  # (LIKE '/bff/%/admin/%' / LIKE '/bff/%/superadmin/%'); the in-image floor gets
  # it from the two wiki console rows in MFA_REQUIRED_FALLBACK_ROWS
  # (hugmesh-gateway#40, decision 80a/80b). /bff/wiki/** itself stays false on
  # both. forum and owncast are cluster-seed-only: fe() carries no row for them
  # (it has none at all), so the cluster seed's flip of /bff/forum/admin/** and
  # /bff/owncast/admin/** has no in-image twin to assert here.
  Scenario Outline: the wiki <surface> requires MFA on both sources @layer:gateway
    Given a principal holding only the role "<granted>"
    When the "hugmesh-fe-gateway" gateway decides "<path>" from the cluster seed
    Then the deciding rule requires MFA
    When the "hugmesh-fe-gateway" gateway decides "<path>" from the in-image floor
    Then the deciding rule requires MFA

    Examples:
      | surface            | granted         | path                       |
      | admin console      | ROLE_ADMIN      | /bff/wiki/admin/settings   |
      | superadmin console | ROLE_SUPERADMIN | /bff/wiki/superadmin/users |

  # The negative control for the same decision: the wiki PLATFORM row is not a
  # console and is not flipped on either source, so a future "flip everything
  # under /bff/wiki" widening cannot pass unnoticed.
  Scenario: the wiki content floor does NOT require MFA on either source @layer:gateway
    Given a principal holding only the role "ROLE_WIKI"
    When the "hugmesh-fe-gateway" gateway decides "/bff/wiki/pages" from the cluster seed
    Then the deciding rule does not require MFA
    When the "hugmesh-fe-gateway" gateway decides "/bff/wiki/pages" from the in-image floor
    Then the deciding rule does not require MFA

  # KNOWN-OPEN. The property CanonicalSeed's javadoc claims for itself.
  Scenario: the fallback floor governs every surface the cluster seed governs @layer:gateway
    Given this scenario is PENDING because "31 of the 66 url patterns the cluster seed governs at hugmesh-fe-gateway have NO matching row in the in-image CanonicalSeed floor, so on the datastore-unreachable fallback they resolve NO_RULE and FORWARD on the coarse authenticated() floor. Among them: /mod/**, /bff/mod/**, /bff/user/**, /bff/forum/**, /bff/mesh/**, /bff/owncast/**, /bff/tube/**, /wiki/**, /owncast/**, /tube/**, /user/**, /api-docs/**, /_fragments/**, /character-studio/**, /oauth/**, /social/forum/**, the whole /_matrix/** homeserver surface (including the four r0/v3 login+register rows), /api/v1/**, /api/v2/** and both /bff/password-reset rows. This is the same hole the three /bff/*/internal/** deny rows were added to close, still open on the rest of the surface. Re-measured for decision 80a (hugmesh-gateway#40 added all three wiki rows to CanonicalSeed.fe()): 34 -> 31. THREE patterns LEFT the list: /bff/wiki/**, /bff/wiki/admin/** and /bff/wiki/superadmin/**. Before that, re-measured 2026-09-17 against generator main AFTER decision 28 landed (4764ab4f), with the #244 gateway row in place: 36 -> 34, when /bff/superadmin/** (decision 41) and /bff/superadmin/games-services/** (decision 28, covered by the floor's /bff/superadmin/**) left the list. It was 31 of 61 when this was written and 35 of 65 on 2026-09-10."
    Then every url pattern the cluster seed governs at gateway "hugmesh-fe-gateway" is also governed by the in-image floor
