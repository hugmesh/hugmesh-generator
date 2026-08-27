# Harness contract, not a UI journey — and it runs with the STACK DOWN.
#
# WHY IT EXISTS. A feature that names a persona no seeder creates fails at login
# with a bare 401, which reads like a broken login and is really an identity that
# was never created (the 2026-08-06 e2e-fleet symptom; see
# tests/scripts/test-e2e-persona-catalogue.sh). This scenario resolves the
# `@role:` dimension against BOTH rosters — specs/rbac-roles.ts SYSTEMS_SEED_USERS
# and tests/e2e-extra-personas.sh — and fails loudly on a ghost.
#
# It also exercises the ROLE axis of the matrix end to end offline, which is what
# lets `make stack-e2e-bdd-offline` prove the harness without a mesh.
#
# The Examples below deliberately span BOTH sources: e2e-admin/e2e-mod come from
# the TypeScript catalogue only, alice@gmail.com/e2e-fleet from the shell roster
# only. The two lists DISAGREE today and reconciling them is separate work; this
# scenario asserts only the property features actually depend on — that SOME
# seeder creates the handle.
@harness @layer:casdoor
Feature: Every persona a feature may name is one a seeder actually creates

  Scenario Outline: <role> is seeded @role:<role> @layer:casdoor
    Then the persona named by the role dimension is seeded

    Examples:
      | role              |
      | e2e-admin         |
      | e2e-mod           |
      | e2e-superadmin    |
      | alice@gmail.com   |
      | e2e-fleet         |
