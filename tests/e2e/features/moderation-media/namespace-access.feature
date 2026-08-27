# The executable Gherkin expression of tests/e2e/specs/09-namespace-access.spec.ts.
#
# ─────────────────────────────────────────────────────────────────────────────
# KNOWN-RED — PRODUCT BUG, NOT A FEATURE-FILE BUG.
#
# admin-bff's namespace vocabulary DISAGREES WITH ITS OWN DATABASE. The
# hugmesh -> hugmesh rename updated the Java constant but NOT the Liquibase CHECK
# constraint that mirrors it, so AdminController.grant() passes
# store.isValidNamespace(), issues the INSERT, and Postgres rejects it:
#
#   POST /bff/admin/namespace-access {"namespace":"hugmesh-backend"} -> HTTP 500
#     admin-bff log: [23514] new row for relation "namespace_grant" violates
#     check constraint "ck_namespace_grant_namespace"
#   POST /bff/admin/namespace-access {"namespace":"observability"}   -> HTTP 200
#
# 'observability' is the ONLY value the two lists still share, so FOUR OF THE
# FIVE ADVERTISED NAMESPACES ARE UNGRANTABLE IN PRODUCTION and the UI reports
# nothing — the component awaits bff.grantNamespace() and never re-renders a row.
#
# This scenario is therefore left ASSERTING THE CORRECT BEHAVIOUR and is RED on a
# live stack, exactly as spec 09 is. Do NOT switch it to "observability" and do
# NOT mark it pending: that would hide a real, user-visible product defect behind
# a green suite. The fix is owned by hugmesh-admin-bff-api (a changeset that
# drops and re-adds ck_namespace_grant_namespace over the hugmesh-* names).
#
# The DENIAL half of spec 09 is not repeated here — it is the bob@gmail.com /
# namespaces row of the shared ROLE × PLATFORM outline in
# admin-usage-analytics.feature, because the host gate is identical for both
# admin-ui modules and duplicating it would be two assertions of one property.
# ─────────────────────────────────────────────────────────────────────────────
@service:admin @layer:bff
Feature: Admin namespace grants

  Scenario: an admin grants a registered user access to a namespace @role:admin@hugmesh.net @service:admin @layer:bff
    Given I am signed in as the persona for this scenario
    When I open the admin module "namespaces"
    Then the element with test id "ns-view" is visible
    When I grant the namespace "hugmesh-backend" to "alice@gmail.com"
    Then the namespace grants list shows "alice@gmail.com" holding "hugmesh-backend"
