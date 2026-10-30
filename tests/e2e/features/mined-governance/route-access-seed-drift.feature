# WHAT THIS ASSERTS. The central suite's whole offline RBAC tier rests on
# tests/e2e/specs/rbac-route-access.ts. It used to be a HAND-COPIED TypeScript
# mirror whose header claimed it was "copied 1:1 from
# manifests/route-access/schema.sql" — a path that did not exist — and nothing in
# this suite had ever checked the claim. The drift was real and measurable.
#
# MEASURED WHEN THIS LANE WAS WRITTEN (2026-08-26, comment-stripped): the seed a
# deployed cluster loads is specs/cluster/manifests/route-access/initdb/20-schema.sql
# — then 150 rows over FOUR gateways, four of them explicit DENY. The mirror
# carried 50 rows, all allow. 96 of the seed's 146 allow rows were ABSENT, so 96
# paths answered DENY through the oracle and ALLOW in production. Nothing the
# mirror carried was invented: it under-granted, it did not lie.
#
# RE-MEASURED AT THE INTEGRATION (same week, by execution): the gap is CLOSED.
# specs/rbac-route-access.ts re-exports specs/rbac-route-access.seed.ts, which
# scripts/gen-route-access-oracle.py GENERATES from that same SQL and
# tests/scripts/test-route-access-oracle.sh gates. Seed 152 rows / 4 gateways /
# 4 explicit DENY; mirror 152 rows; allow rows missing from the mirror: ZERO;
# RouteRule now carries `allow`, so deny-wins is representable centrally.
#
# THE LANE DOES NOT GO AWAY WITH THE GAP. Every scenario below still asserts the
# property, not the gap: a regenerated mirror that falls behind the seed again
# fails here, in this lane, rather than being noticed by the six spec files that
# read the oracle.
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
  #
  # ⚠ THE COUNT IS A LIVE NUMBER, NOT A CONSTANT. It read 152 and was RED on
  # main before this change: #329's /bff/wiki/superadmin/** row landed without
  # touching it (152 -> 153, a pre-existing failure I did not cause), and #244's
  # ACCEPT row takes it to 154. Re-measure rather than guess when it fails again:
  #     python3 scripts/gen-route-access-oracle.py && head -16 \
  #       tests/e2e/specs/rbac-route-access.seed.ts
  # The generated header prints the total and the per-gateway split. This
  # scenario exists to make a row landing VISIBLE here rather than absorbed, so a
  # bump is the correct fix; deleting the number is not.
  # Re-measured 2026-10-15: main already read 155 here (the scenario still said 154),
  # and the two tube ADMIN rows (/bff/tube/admin/access/**, /bff/tube/admin/storage-budget/**)
  # take it to 157: be 60, fe 84, pki 4, superadmin 9. The deny count was ALSO stale on
  # main (4, measured 5 since decision 28 = D put the fe games-services deny row back);
  # the new rows are allow rows, so 5 is main's number, not this change's.
  # Re-measured 2026-10-29 after merging main 2b13b2f9 (#824 added the fe /games rows): main
  # reads 162 (be 60, fe 89, pki 4, superadmin 9) while this line still said 154 there;
  # with the two tube rows it is 164 (fe 91). Deny rows: still 5.
  Scenario: the cluster seed parses to the rows a gateway loads @layer:gateway
    Then the cluster seed carries 164 route-access rows across 4 gateways
    And the cluster seed carries exactly 5 explicit deny rows

  # THE DIRECTION THAT MATTERS. A mirror row with no seed row behind it is a
  # test asserting a permission production never grants — a green that means
  # nothing. This is the property that must never regress.
  Scenario: the mirror grants nothing the cluster seed does not @layer:gateway
    Then every central mirror row exists in the cluster seed as an allow row
    And every gateway the central mirror names is seeded by the cluster

  # The mirror's row TYPE had three fields and no allow/deny boolean, so deny-wins
  # (GatewayRouteAccessService:218) was not merely untested centrally — it was
  # unrepresentable, and this scenario asserted the field list so that ADDING the
  # boolean would fail here and name the follow-up. The boolean was added. The
  # assertion is now the positive one it was holding the place for: the mirror
  # models every explicit deny the seed carries, row for row.
  Scenario: the mirror models every explicit deny the cluster seed carries @layer:gateway
    Then the central mirror models every explicit deny row the cluster seed carries

  # WAS KNOWN-OPEN, NOW CLOSED. It shipped PENDING with the measured size of the
  # gap — "96 seeded allow rows are missing from the mirror ... Regenerate the
  # mirror from the seed rather than hand-editing it" — and the instruction was
  # to delete the PENDING line when that happened. It happened:
  # scripts/gen-route-access-oracle.py regenerates the mirror from this very seed.
  # MEASURED at the integration: zero missing allow rows.
  Scenario: the mirror carries every allow row the cluster seed carries @layer:gateway
    Then the central mirror carries every allow row the cluster seed carries
