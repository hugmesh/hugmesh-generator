# WHAT THIS ASSERTS — hugmesh-admin-bff-api#80 (split from #3): the role-policy
# read/write surface GET/PUT /bff/admin/mfa/role-policy landed in admin-bff PR
# #61 (RoleMfaPolicyController, @PreAuthorize hasRole('ADMIN'), domain-scoped),
# and NOTHING enforces it yet — RoleMfaPolicyService.requiredForAny has no
# caller, admin-ui has no panel, and the issue says nobody has exercised the two
# endpoints "through a UI or against a live cluster — tests only".
# Re-checked 2026-09-23 on admin-bff origin/main 6dc72d1 (the compose stack's
# admin-bff image is built from that same commit): still no caller of
# requiredForAny outside its own javadoc.
#
# WHAT IS PINNED:
#   * OFFLINE — the gateway seed's decision at the surface: an admin is admitted
#     by the /bff/admin/** ROLE_ADMIN floor (mfa_required by decision 56's
#     blanket flip); a moderator, a member and a pure fleet owner are refused by
#     the rows. A bare ROLE_SUPERADMIN is refused BY THE ROWS ALONE (the filter
#     bypass is what admits it in production; superadmin-and-fleet-reach.feature
#     owns that statement).
#   * LIVE (@env:docker) — the first exercise of the endpoint against a real
#     stack: the admin READS the effective posture (200), and member, moderator
#     and anonymous callers are stopped at the door. No PUT is issued: a
#     role-policy write on the shared compose stack would change what every
#     other lane's admin sessions are gated on, for nothing this issue asks.
#
# WHAT IS NOT WRITTEN, and why: the enforcement itself is PENDING, not @fixme.
# #80 is blocked on two operator decisions (45: which Casdoor principal admin-bff
# uses and who may clear a stamped key; 46: whether SUPERADMIN's policy scope
# stays brand-scoped) and its five remaining boxes do not say WHICH seam refuses
# a role marked `required` or WHAT the refusal looks like. A @fixme must assert
# the correct behaviour so it goes green unmodified when the fix lands; here the
# correct behaviour is undecided, so the step below skips with the reason and
# names the observable that would close it. The survey's sketch of an
# /admin/security/mfa-role-policy console is not asserted either: no such route
# exists in admin.routes.ts and none has been designed.
@service:admin @issue:admin-bff-api-80
Feature: The MFA role policy is readable by admins, refused below them, and its enforcement is still unwired

  # ── the rows the cluster loads ─────────────────────────────────────────────
  Scenario Outline: a principal holding only <granted> is <decision> at the role-policy surface by the rows alone @layer:gateway
    Given the cluster route-access seed is loaded
    And a principal holding only the role "<granted>"
    When the "hugmesh-fe-gateway" gateway decides "/bff/admin/mfa/role-policy" from the cluster seed
    Then the seed decision is "<decision>"
    And the deciding url pattern is "/bff/admin/**"
    And the deciding rule requires MFA

    Examples:
      | granted          | decision |
      | ROLE_ADMIN       | ALLOW    |
      | ROLE_SUPERADMIN  | DENY     |
      | ROLE_MOD         | DENY     |
      | ROLE_USER        | DENY     |
      | ROLE_FLEET_ADMIN | DENY     |

  # ── the endpoint, live, read-only ──────────────────────────────────────────
  @env:docker @role:e2e-admin
  Scenario: an admin reads the effective MFA posture for their brand @role:e2e-admin @env:docker @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client GETs "/bff/admin/mfa/role-policy"
    Then the response status is 200

  @env:docker
  Scenario Outline: <role> is refused the role-policy read at the gateway @role:<role> @env:docker @layer:gateway
    Given an API client signed in as the persona for this scenario
    When the API client GETs "/bff/admin/mfa/role-policy"
    Then the response status is 403
    And the refusal came from the gateway

    Examples:
      | role     |
      | e2e-user |
      | e2e-mod  |

  @env:docker
  Scenario: an anonymous client is unauthenticated at the role-policy read @env:docker @layer:gateway
    Given an anonymous API client
    When the API client GETs "/bff/admin/mfa/role-policy"
    Then the response status is 401

  # ── enforcement ────────────────────────────────────────────────────────────
  @env:docker @role:e2e-admin
  Scenario: PENDING (decisions 45/46) — a role the policy marks required is enforced at the session seam @role:e2e-admin @env:docker @layer:bff
    Given this scenario is PENDING because "hugmesh-admin-bff-api#80: RoleMfaPolicyService.requiredForAny has NO caller (re-measured 2026-09-23 on admin-bff origin/main 6dc72d1), so a role set to 'required' via PUT /bff/admin/mfa/role-policy/{role} changes nothing observable at any seam. Wiring it is blocked on operator decisions 45 (which Casdoor principal admin-bff acts as, and whether a direct clear may remove a key admin-bff stamped) and 46 (RoleMfaPolicyController scopes SUPERADMIN to their own brand, unlike DomainCapabilityAdminController). Neither the seam that will refuse (session mint? the gateway's mfa_required surface? a BFF step-up gate?) nor the refusal's shape is decided, so no correct Then can be written yet. DESIRED, once decided: set ROLE_FLEET_ADMIN to 'required' on a dedicated non-shared stack, sign in as e2e-fleet with no fresh MFA stamp, and assert the decided refusal at the decided seam — then delete this Given."
    Given an API client signed in as the persona for this scenario
    When the API client GETs "/bff/admin/mfa/role-policy"
    Then the response status is 200
