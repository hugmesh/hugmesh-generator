# THE ROSTER RECONCILIATION, MADE EXECUTABLE — stack-free, @harness.
#
# The brief for this unit said "rbac-roles.ts (17 roles) vs the shell roster (32
# personas) DISAGREE and reconciling them is real work, not a detail". Measured,
# the shape is this — there are THREE static rosters, not two:
#
#   A  tests/e2e/specs/rbac-roles.ts   SYSTEMS_SEED_USERS   17 handles  (TypeScript)
#   B  tests/qemu/seed-accounts.sh     SYSTEMS_ROLE_USERS   16 handles  (shell, the
#                                                                       BASE matrix:
#                                                                       A minus the
#                                                                       superadmin)
#   C  tests/e2e-extra-personas.sh     E2E_EXTRA_PERSONAS   15 handles  (shell, the
#                                                                       EXTRAS, incl.
#                                                                       the superadmin)
#
#   union(A, B, C) = 31 distinct handles; A ∩ C = {e2e-superadmin} only.
#   The "32" in the brief is B+C counted as tests/stack/seed-e2e.sh assembles it
#   (BASE_SPECS + EXTRA_SPECS) with the superadmin counted on both sides.
#
# THE DISCREPANCY NAMED, NOT PAPERED OVER. steps/dimensions.ts personaSource()
# reads only A and C, so it labels the 16 base handles 'ts-catalogue' — which
# READS as "no shell seeder creates this", and that is FALSE:
# tests/stack/seed-e2e.sh reconstructs B by running `seed-accounts.sh --roles`
# and seeds BASE_SPECS + EXTRA_SPECS through one render. So 'ts-catalogue' means
# "declared in the TypeScript catalogue and seeded via the BASE matrix", not
# "missing from the shell lane".
#
# Rather than silently pick a side, every row below declares BOTH facts and both
# are asserted:
#   * the label personaSource() gives it today (so a future reconciliation makes
#     these rows go red and get UPDATED, not deleted); and
#   * that a shell seeder — base matrix OR extras — really does create it, which
#     is the property a feature naming the handle actually depends on. A handle
#     that only ever existed in TypeScript 401s at login with a bare "invalid
#     credentials" that reads like a broken login (the 2026-08-06 e2e-fleet
#     symptom).
#
# This is also the ROLE axis of the operator's matrix exercised end to end
# OFFLINE: 31 rows, one per persona the suite may ever sign in as.
@harness @layer:casdoor
Feature: Every persona the suite may name is created by a seeder that actually runs

  Scenario Outline: <role> is seeded, catalogued as <source> @role:<role> @layer:casdoor
    Then the persona named by the role dimension is seeded
    And the persona is catalogued as coming from the "<source>" roster
    And a shell seeder really does create the persona

    Examples: the TypeScript catalogue (A) — seeded through seed-accounts.sh's BASE matrix (B)
      | role                         | source       |
      | e2e-admin                    | ts-catalogue |
      | e2e-adminonly                | ts-catalogue |
      | e2e-denied                   | ts-catalogue |
      | e2e-forum                    | ts-catalogue |
      | e2e-gamesadmin               | ts-catalogue |
      | e2e-gamesonly                | ts-catalogue |
      | e2e-mastodon                 | ts-catalogue |
      | e2e-mastodon-domainlocked    | ts-catalogue |
      | e2e-mastodon-external-client | ts-catalogue |
      | e2e-matrix                   | ts-catalogue |
      | e2e-matrix-domainlocked      | ts-catalogue |
      | e2e-matrix-external-client   | ts-catalogue |
      | e2e-matrix-groupchat         | ts-catalogue |
      | e2e-mod                      | ts-catalogue |
      | e2e-pending                  | ts-catalogue |
      | e2e-user                     | ts-catalogue |

    Examples: the shell extras (C) — the ad-hoc UI personas and the fleet/banned pair
      | role                     | source       |
      | admin@hugmesh.net        | shell-roster |
      | alice@gmail.com          | shell-roster |
      | bob@gmail.com            | shell-roster |
      | carol@gmail.com          | shell-roster |
      | dave@gmail.com           | shell-roster |
      | eve@gmail.com            | shell-roster |
      | frank@gmail.com          | shell-roster |
      | dragoneer                | shell-roster |
      | e2e-banned               | shell-roster |
      | e2e-suspended            | shell-roster |
      | e2e-fleet                | shell-roster |
      | rbac-plain@gmail.com     | shell-roster |
      | rbac-login-user@gmail.com| shell-roster |
      | rbac-pending@gmail.com   | shell-roster |
      | rbac-approved@gmail.com  | shell-roster |

    # The ONLY handle both rosters carry. Its login name is not fixed: a
    # studio-bootstrapped mesh mints CASDOOR_SUPERADMIN_USERNAME and both
    # rosters read it, so this row follows whatever the operator minted.
    Examples: in both (A ∩ C)
      | role           | source |
      | e2e-superadmin | both   |
