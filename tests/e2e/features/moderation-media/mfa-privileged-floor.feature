# The executable Gherkin expression of tests/e2e/specs/29-mfa-privileged-floor.spec.ts
# — gateway MFA enforcement over the seeded mfa_required rows.
#
# WIRE SHAPE, read from the source rather than assumed. GatewayRouteAccessFilter
# has ONE reject(): 403 + `X-Route-Denied: <gateway>:<path>` + an empty body,
# shared by the floor deny and the role deny. There is NO floor-specific marker,
# so the two are INDISTINGUISHABLE on the wire; the only observable difference is
# BEHAVIOURAL, and this feature proves both directions. Its cold-start sibling is
# the one distinct shape: 503 + `Retry-After: 5` (privileged principals, floor
# only) — the `When I request the governed path` step rides that out.
#
# THREE POSTURES, SELECTED NOT SKIPPED. The OFF-posture block and the per-row
# block are EXACT COMPLEMENTS: `the gateway MFA leg is OFF` skips when
# APP_MFA_ENABLED is not false, `... is ON` skips when it is. Exactly one of them
# runs on any stack, whichever posture it holds, so a forgotten export cannot
# leave a stack with no coverage. Only the MFA_FLOOR gate can, mirroring spec
# 14's LIVE_GATEWAY gate, and it says so by name.
@service:admin @layer:gateway
Feature: Gateway MFA enforcement and the privileged floor

  # ── the generator itself: NO STACK, NO NETWORK ────────────────────────────
  # Runs offline, so a failing challenge downstream can never be blamed on our
  # own code generation. Appendix B's secret is ASCII "12345678901234567890";
  # the published codes are 8-digit and the platform is DIGITS=6 (auth-core
  # TotpService), so each expectation is the low 6 digits.
  @harness
  Scenario Outline: RFC 6238 SHA-1 vector T=<t> reproduces at DIGITS=6 @layer:casdoor
    Then the RFC 6238 SHA-1 vector at T=<t> yields the six digits "<code>"

    Examples:
      | t           | code   |
      | 59          | 287082 |
      | 1111111109  | 081804 |
      | 1111111111  | 050471 |
      | 1234567890  | 005924 |
      | 2000000000  | 279037 |
      | 20000000000 | 353130 |

  @harness
  Scenario: a garbled base32 secret throws instead of hashing garbage @layer:casdoor
    Then a non-base32 TOTP secret throws instead of hashing garbage

  # ── CLUSTER-DEFAULT OFF posture (APP_MFA_ENABLED=false) ───────────────────
  # This is the posture every cluster the generator produces actually ships, and
  # before spec 29 grew this block it had NO e2e coverage whatsoever (confirmed
  # live on kind 2026-08-20: "2 passed, 5 skipped", and the two that passed were
  # the stack-free TOTP vectors). Turning a guard off has two ways to go wrong:
  # the flag does not reach the gateway so the stack silently ENFORCES, or
  # turning MFA off also drops the ROLE wall on the same rows and the privileged
  # plane opens to anyone. Both are asserted below.

  # e2e-fleet is the ONE principal among the 9 seeded mfa_required rows that
  # decide() can gate at all — privileged roles short-circuit before decide().
  Scenario: with MFA off the mfa_required column is inert for a pure fleet admin @role:e2e-fleet @service:admin @layer:gateway
    Given the gateway MFA leg is OFF on this stack
    And I hold an API session as the persona for this scenario
    Then my session carries a fleet role and not admin
    When I request the governed path "/bff/admin/phone-fleet/e2e-mfa-probe"
    Then the gateway did not reject the request
    And the gateway verdict is not "DENIED"
    And the gateway verdict is not "UNAUTHENTICATED"

  # The direction that matters most: decide() reads `allow` and `mfa_required`
  # off the SAME row and gates only the second on mfaEnabled. A change that gated
  # the first as well would turn the cluster default into an open admin plane.
  Scenario: MFA off does NOT open the privileged plane to a plain user @role:e2e-user @service:admin @layer:gateway
    Given the gateway MFA leg is OFF on this stack
    And I hold an API session as the persona for this scenario
    Then my session is non-privileged
    When I request the governed path "/bff/admin/usage"
    Then the gateway verdict is "DENIED"
    And the gateway route-access reject names the path "/bff/admin/usage"
    And the gateway reject carries no body

  # MFA-ROLLOUT.md §2's "quiet cluster": an operator who never enrolled anything
  # still works normally. Its live negative control is the FLOOR block below, not
  # a mutation — below the floor there is NO route on which the gateway denies an
  # admin, which is why this asserts the GATEWAY's verdict rather than a 200.
  Scenario: an un-enrolled admin reaches the mfa_required blanket and is never challenged @role:e2e-admin @service:admin @layer:gateway
    Given the gateway MFA leg is OFF on this stack
    And I hold an API session as the persona for this scenario
    Then my session carries the admin role
    When I request the governed path "/bff/admin/usage"
    Then the gateway verdict is "PASSED"
    And no layer redirected me to the MFA challenge

  # ── compose-DEFAULT per-row gate (APP_MFA_ENABLED=true, floor off) ────────
  # PLATFORM AXIS. The route-access seed (specs/cluster/manifests/route-access/
  # initdb/20-schema.sql) and the gateway that reads it ship on BOTH image
  # targets, so this contract must hold on each; SNAP_PLATFORM narrows the run to
  # the target actually brought up, and the other row is skipped BY NAME.
  Scenario Outline: a pure fleet admin without a fresh stamp is denied phone-fleet on <platform> @role:e2e-fleet @platform:<platform> @service:admin @layer:gateway
    Given the gateway MFA leg is ON on this stack
    And I hold an API session as the persona for this scenario
    Then my session carries a fleet role and not admin
    When I request the governed path "/bff/admin/phone-fleet/e2e-mfa-probe"
    Then the gateway verdict is "DENIED"
    And the gateway route-access reject names the path "/bff/admin/phone-fleet/e2e-mfa-probe"
    And the gateway reject carries no body
    When I request the governed path "/bff/session"
    Then the gateway verdict is "PASSED"

    Examples:
      | platform |
      | rpi5     |
      | x86      |

  # §3.1's small print — "do not read a quiet cluster after step 6 as evidence
  # that admin MFA works". At floor OFF the admin bypass runs BEFORE decide(), so
  # the same admin on the same blanket PASSES; the floor block below is the other
  # half of the sentence. This is why the fleet leg cannot stand in for admin
  # coverage, and it is deliberately pinned to the floor-OFF case only.
  Scenario: at floor OFF an admin reaches the mfa_required blanket without a second factor @role:e2e-admin @service:admin @layer:gateway
    Given the gateway MFA leg is ON on this stack
    And I hold an API session as the persona for this scenario
    Then my session carries the admin role
    When I request the governed path "/bff/admin/usage"
    Then the gateway verdict is "PASSED"

  # ── the PRIVILEGED FLOOR (MFA_FLOOR=1 stacks only) ────────────────────────

  # leg (a). An ENROLLED factor alone must not satisfy the floor: this is a fresh
  # session with no challenge on it, so even on a stack where an earlier run
  # enrolled TOTP for e2e-admin there is no fresh stamp and the floor must bite.
  Scenario: with the floor on, an admin without a FRESH factor is denied the admin plane @role:e2e-admin @service:admin @layer:gateway
    Given the privileged MFA floor is enabled on this stack
    And I hold an API session as the persona for this scenario
    Then my session carries the admin role
    When I request the governed path "/bff/admin/usage"
    Then the gateway verdict is "DENIED"
    And the gateway route-access reject names the path "/bff/admin/usage"
    And the gateway reject carries no body

  # leg (d), the other direction. A plain user's deny on the SAME route is a ROLE
  # deny, and no amount of MFA freshness moves it. Its wire shape is
  # BYTE-IDENTICAL to the floor deny above because reject() is shared — asserted
  # here so that if a floor-specific marker is ever added, this feature and
  # docs/MFA-ROLLOUT.md §3.1 have to be updated together rather than drifting.
  Scenario: with the floor on, a plain user's deny on the same route is a ROLE deny of identical shape @role:e2e-user @service:admin @layer:gateway
    Given the privileged MFA floor is enabled on this stack
    And I hold an API session as the persona for this scenario
    Then my session is non-privileged
    When I request the governed path "/bff/admin/usage"
    Then the gateway verdict is "DENIED"
    And the gateway route-access reject names the path "/bff/admin/usage"
    And the gateway reject carries no body

  # leg (c). The floor is PER-ROW, not a blanket MFA wall on privileged
  # principals: /bff/mod/** is governed ROLE_ADMIN but sits OUTSIDE the
  # /bff/admin + /bff/superadmin prefixes the seed's UPDATE covers. Asserted as
  # "the gateway did not reject" rather than 200, because /bff/mod/findings 500s
  # on the stock compose stack (federation findings backend dark) and a 500 is
  # not an auth verdict.
  Scenario: with the floor on, an un-stamped admin still reaches a NON-mfa_required governed surface @role:e2e-admin @service:admin @layer:gateway
    Given the privileged MFA floor is enabled on this stack
    And I hold an API session as the persona for this scenario
    Then my session carries the admin role
    When I request the governed path "/bff/mod/findings?status=held"
    Then the gateway verdict is "PASSED"

  Scenario: with the floor on, an ungoverned surface is untouched for a plain user @role:e2e-user @service:admin @layer:gateway
    Given the privileged MFA floor is enabled on this stack
    And I hold an API session as the persona for this scenario
    When I request the governed path "/bff/session"
    Then the gateway verdict is "PASSED"

  # ── leg (b): the enroll + step-up flip, and the evidence that has NEVER been
  # produced. Spec 29 calls shot(page,'29-mfa-enroll-recovery') and
  # shot(page,'29-mfa-challenge-done'); MEASURED 2026-08-26, neither PNG exists
  # in tests/e2e/screenshots/ (38 tracked files, none of them a 29-*). The floor
  # lane has therefore never run to completion on any stack, so the browser-driven
  # enroll/challenge flip is stated here as PENDING rather than as a passing
  # scenario nobody has ever seen pass. When a MFA_FLOOR=1 stack exists, replace
  # the PENDING step with the real drive and the assertions below become live.
  @pending
  Scenario: TOTP enrollment through the shipped wizard yields display-once recovery codes @role:e2e-admin @service:login @layer:ui
    Given this scenario is PENDING because "spec 29's shot(page,'29-mfa-enroll-recovery') has NEVER produced a PNG: tests/e2e/screenshots/ holds 38 tracked images and not one 29-* among them (measured 2026-08-26). The enroll leg only runs on a floor-enabled stack (make stack-up MFA_FLOOR=1) AND needs the admin-bff MFA surface lit (APP_CASDOOR_MFA_ENABLED=true plus APP_MFA_FACTOR_KEY) — without both, login-ui renders the terminal mfa-dark step instead of the display-once secret. Nobody has stood that stack up, so this is stated as unproven rather than asserted as passing."
    When I open the path "/login/mfa/enroll"
    Then the element with test id "mfa-enroll-view" is visible
    And the element with test id "mfa-dark" is not visible
    And the element with test id "mfa-recovery-codes" is visible

  @pending
  Scenario: a fresh TOTP step-up flips the SAME admin route from DENIED to PASSED @role:e2e-admin @service:login @layer:ui
    Given this scenario is PENDING because "spec 29's shot(page,'29-mfa-challenge-done') has NEVER produced a PNG either (same measurement). This is the flip that gives the whole floor its meaning — identical principal, identical route, factor freshness the ONLY changed input — and it depends on the enroll scenario above, so it inherits the same unmet preconditions: a MFA_FLOOR=1 stack with a lit admin-bff MFA surface. Asserting it green today would claim a proof nobody has ever run."
    When I open the path "/login/mfa/challenge"
    Then the element with test id "mfa-challenge-view" is visible
    And the element with test id "mfa-challenge-dark" is not visible
