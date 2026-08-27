# WHAT THIS ASSERTS. Two admin-plane contracts the central suite states nowhere.
#
# 1. THE SUPERADMIN CASCADE IS A METHOD-SECURITY FACT, NOT A GATEWAY ONE.
#    features/rbac/superadmin-tier.feature opens by declaring ROLE_SUPERADMIN a
#    "DISTINCT TIER ... there is NO down-cascade". That is true OF THE GATEWAY
#    LAYER — measured: not one row in the cluster seed grants SUPERADMIN a
#    pattern already granted to ADMIN. It is false of the BFFs: admin-bff,
#    mod-bff, forum-bff, wiki-bff and user-bff each declare
#    RoleHierarchyImpl "ROLE_SUPERADMIN > ROLE_ADMIN / ROLE_MOD / ROLE_USER", so
#    @PreAuthorize("hasAnyRole('MOD','ADMIN')") DOES admit a pure superadmin.
#    Both statements are correct about their own layer; the suite asserted only
#    one of them, which is how a reader ends up believing the wrong thing about
#    the other.
#
#    MEASURED ANOMALY, pinned in the `wired` column below rather than buried in a
#    comment: FOUR of the five configs also bind the hierarchy to a
#    MethodSecurityExpressionHandler, and four of them carry a javadoc saying why
#    ("a bare RoleHierarchy bean is NOT auto-applied to @PreAuthorize in the
#    reactive method-security path"). hugmesh-user-bff-api declares the bean,
#    enables @EnableReactiveMethodSecurity, carries 73 @PreAuthorize sites — and
#    binds NO expression handler. By its four siblings' own stated rule the
#    hierarchy is INERT there, so a pure ROLE_SUPERADMIN does not satisfy
#    user-bff's hasRole('USER') gates.
#
# 2. THE APPEAL DECIDE CAS. Comment-stripped, the central suite has zero hits for
#    'appeal'. Deciding an account appeal is the most consequential admin
#    reversal in M2 (an APPROVE clears the appellant's PROFILE suspension BEFORE
#    the row flips) and its contract is unusual: a losing racer gets 200
#    {"decided":0} — never a 409, and NOT distinguishable from a winner by
#    status. That is the OPPOSITE convention from the concurrent-edit surfaces in
#    the component repos, which refuse a save onto a row a rival deleted. One
#    suite should not hold two silent answers to "what does losing a race look
#    like"; writing both down is how the operator gets to choose.
#
# NEEDS the five *-bff-api checkouts beside this repo (source read only).
@service:admin @layer:bff
Feature: The SUPERADMIN cascade lives in method security, and an appeal decision is a no-op-tolerant CAS

  Scenario Outline: <repo> declares the SUPERADMIN hierarchy, and wiring it into method security is "<wired>" @layer:bff
    Given the security configuration of "<repo>" is loaded
    Then it declares the role hierarchy edges "ROLE_SUPERADMIN > ROLE_ADMIN, ROLE_SUPERADMIN > ROLE_MOD, ROLE_SUPERADMIN > ROLE_USER"
    And it declares no "ROLE_ADMIN > ROLE_MOD" edge
    And reactive method security is enabled and the hierarchy is wired into it: "<wired>"

    # `wired` is MEASURED, not aspirational. The one "no" is the finding: see the
    # header. Changing it to "yes" is the fix, and this row is what proves it.
    Examples:
      | repo                  | wired |
      | hugmesh-admin-bff-api | yes   |
      | hugmesh-mod-bff-api   | yes   |
      | hugmesh-forum-bff-api | yes   |
      | hugmesh-wiki-bff-api  | yes   |
      | hugmesh-user-bff-api  | no    |

  # The other half of the same fact, at the layer the central suite DOES assert.
  Scenario: the gateway layer grants SUPERADMIN nothing by cascade @layer:gateway
    Given the cluster route-access seed is loaded
    Then no cluster seed row grants "ROLE_SUPERADMIN" on the exact pattern "/bff/admin/**" at gateway "hugmesh-fe-gateway"
    And no cluster seed row grants "ROLE_SUPERADMIN" on the exact pattern "/api/admin/**" at gateway "hugmesh-be-gateway"

  # ── the appeal decide CAS ──────────────────────────────────────────────────
  Scenario: deciding an appeal reports the CAS row count and never a conflict @layer:bff
    Then deciding an account appeal answers "{decided:n, status:s}" on a no-op rather than a conflict

  # A MOD cannot decide at all — the appeal surface is ADMIN|SUPERADMIN, and the
  # hierarchy above is what makes the SUPERADMIN half work without its own row.
  Scenario: deciding an appeal is an admin-tier reversal, not a moderator one @layer:bff
    Then deciding an account appeal is gated to exactly the roles "ADMIN, SUPERADMIN"
