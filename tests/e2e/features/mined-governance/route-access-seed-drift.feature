# WHAT THIS ASSERTS. The central suite's whole offline RBAC tier rests on
# tests/e2e/specs/rbac-route-access.ts, a HAND-COPIED TypeScript mirror of the
# route-access table. Its header says it is "copied 1:1 from
# manifests/route-access/schema.sql". Nothing in this suite has ever checked
# that, and the drift is real and measurable.
#
# MEASURED, NOT INFERRED (2026-08-26, this branch, comment-stripped):
#   * The cited path `manifests/route-access/schema.sql` does NOT exist. The
#     real seed a deployed cluster loads is
#     specs/cluster/manifests/route-access/initdb/20-schema.sql — 150 rows over
#     FOUR gateways, four of them explicit DENY (allow=false).
#   * The mirror carries 50 rows, all allow, over the same four gateway names.
#   * 96 of the seed's 146 allow rows are ABSENT from the mirror.
#   * 0 mirror rows are absent from the seed. The mirror is a strict SUBSET —
#     it under-grants, it does not invent. That direction is the one property
#     worth pinning permanently, and it is pinned below.
#
# WHY A SUBSET STILL MATTERS. gatewayDecision() answers DENY for anything it has
# no row for, so every one of those 96 missing rows is a path where the oracle
# says DENY and production says ALLOW. features/rbac/gateway-route-access.feature
# and features/rbac/superadmin-tier.feature read their expectations from that
# oracle, so a suite-wide "the RBAC posture is locked in" claim is only as good
# as this file.
#
# THIS RUNS OFFLINE. Both sources are files in THIS repository; there is no
# sibling checkout, no stack and no browser in any scenario here, so none of
# them can skip.
@layer:gateway @service:gateway
Feature: The route-access mirror is measured against the seed the cluster loads

  Background:
    Given the cluster route-access seed is loaded
    And the central route-access mirror is loaded

  # The seed's own shape first: if the INSERT form changes under us, every
  # comparison below would silently compare against an empty list.
  Scenario: the cluster seed parses to the rows a gateway loads @layer:gateway
    Then the cluster seed carries 150 route-access rows across 4 gateways
    And the cluster seed carries exactly 4 explicit deny rows

  # THE DIRECTION THAT MATTERS. A mirror row with no seed row behind it is a
  # test asserting a permission production never grants — a green that means
  # nothing. This is the property that must never regress.
  Scenario: the mirror grants nothing the cluster seed does not @layer:gateway
    Then every central mirror row exists in the cluster seed as an allow row
    And every gateway the central mirror names is seeded by the cluster

  # The mirror's row TYPE has three fields and no allow/deny boolean, so
  # deny-wins (GatewayRouteAccessService:218) is not merely untested centrally —
  # it is unrepresentable. Asserting the field list makes that structural, so
  # adding the boolean is what unlocks the internal-plane scenarios.
  Scenario: the mirror has no way to model an explicit deny @layer:gateway
    Then the central mirror cannot express an explicit deny row

  # KNOWN-OPEN. Written against the property that SHOULD hold; skipped with the
  # measured size of the gap until it does. Delete the PENDING line to close it.
  Scenario: the mirror carries every allow row the cluster seed carries @layer:gateway
    Given this scenario is PENDING because "the central mirror is 50 rows; the cluster seed at specs/cluster/manifests/route-access/initdb/20-schema.sql is 150 (146 allow). 96 seeded allow rows are missing from the mirror, including the whole /mod/**, /bff/mod/**, /bff/user/**, /bff/forum/**, /bff/wiki/**, /wiki/**, /owncast/**, /tube/** and /bff/admin/phone-fleet/** families. Every one of them is a path where the central oracle answers DENY and a deployed gateway answers ALLOW. Regenerate the mirror from the seed rather than hand-editing it."
    Then the central mirror carries every allow row the cluster seed carries
