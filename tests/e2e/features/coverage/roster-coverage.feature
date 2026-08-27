# ─────────────────────────────────────────────────────────────────────────────
# GENERATED FILE — DO NOT EDIT BY HAND.
#
# Emitted by tests/e2e/tools/emit-coverage-matrix.ts from three catalogues:
#   personas   specs/rbac-roles.ts SYSTEMS_SEED_USERS
#              + tests/e2e-extra-personas.sh
#              + tests/qemu/seed-accounts.sh SYSTEMS_ROLE_USERS
#   services   tests/e2e/steps/dimensions.ts SERVICES
#   functions  tests/e2e/steps/coverage-catalogue.ts FUNCTIONS
#
# Regenerate with:  bash tests/e2e/gen-coverage-matrix.sh
# The drift guard tests/scripts/test-e2e-coverage-matrix.sh re-emits into a
# scratch dir and DIFFS against these files, so an edit here — or a catalogue
# change that was never re-emitted — turns the guard RED.
# ─────────────────────────────────────────────────────────────────────────────
#
# THE PERSONA ROSTER, reconciled across THREE DISAGREEING SOURCES.
#
#   17  specs/rbac-roles.ts SYSTEMS_SEED_USERS
#   15  tests/e2e-extra-personas.sh
#   16  tests/qemu/seed-accounts.sh SYSTEMS_ROLE_USERS
#    0  seeded by all three
#   31  union — the roster the access matrices iterate
#
# The disagreement is REPRESENTED, not resolved: the `lanes` column names which
# seeders create each handle. Resolving it means changing what a seeder seeds,
# which is a production change and not this lane's to make. What this lane CAN
# do is stop the divergence growing silently — every handle, its lanes and its
# EFFECTIVE role-set (granted roles + the derived ROLE_GAMES_ADMIN composite,
# emptied when the two-stage registration gate is uncleared) are pinned here.
@layer:casdoor @coverage-matrix
Feature: The persona roster the coverage matrix iterates

  Scenario Outline: <role> is seeded by <lanes> and presents <effective_roles> @role:<role>
    Then the persona "<role>" is seeded by exactly the lanes "<lanes>"
    And the persona "<role>" presents the effective roles "<effective_roles>"
    And the persona "<role>" registration-complete flag is "<registration_complete>"

    Examples:
      | role                         | lanes                          | effective_roles                                       | registration_complete |
      | admin@hugmesh.net            | extra-personas-sh              | ROLE_ADMIN,ROLE_USER                                  | true                  |
      | alice@gmail.com              | extra-personas-sh              | ROLE_USER                                             | true                  |
      | bob@gmail.com                | extra-personas-sh              | ROLE_USER                                             | true                  |
      | carol@gmail.com              | extra-personas-sh              | ROLE_USER                                             | true                  |
      | dave@gmail.com               | extra-personas-sh              | ROLE_USER                                             | true                  |
      | dragoneer                    | extra-personas-sh              | ROLE_USER                                             | true                  |
      | e2e-admin                    | seed-accounts-sh+ts-catalogue  | ROLE_ADMIN,ROLE_USER                                  | true                  |
      | e2e-adminonly                | seed-accounts-sh+ts-catalogue  | ROLE_ADMIN,ROLE_USER                                  | true                  |
      | e2e-banned                   | extra-personas-sh              | ROLE_USER                                             | true                  |
      | e2e-denied                   | seed-accounts-sh+ts-catalogue  | ROLE_USER                                             | true                  |
      | e2e-fleet                    | extra-personas-sh              | ROLE_FLEET_ADMIN,ROLE_USER                            | true                  |
      | e2e-forum                    | seed-accounts-sh+ts-catalogue  | ROLE_FORUM,ROLE_USER                                  | true                  |
      | e2e-gamesadmin               | seed-accounts-sh+ts-catalogue  | ROLE_ADMIN,ROLE_GAMES,ROLE_GAMES_ADMIN,ROLE_USER      | true                  |
      | e2e-gamesonly                | seed-accounts-sh+ts-catalogue  | ROLE_GAMES,ROLE_USER                                  | true                  |
      | e2e-mastodon                 | seed-accounts-sh+ts-catalogue  | ROLE_MASTODON,ROLE_USER                               | true                  |
      | e2e-mastodon-domainlocked    | seed-accounts-sh+ts-catalogue  | ROLE_MASTODON,ROLE_MASTODON_DOMAINLOCKED,ROLE_USER    | true                  |
      | e2e-mastodon-external-client | seed-accounts-sh+ts-catalogue  | ROLE_MASTODON,ROLE_MASTODON_EXTERNAL_CLIENT,ROLE_USER | true                  |
      | e2e-matrix                   | seed-accounts-sh+ts-catalogue  | ROLE_MATRIX,ROLE_USER                                 | true                  |
      | e2e-matrix-domainlocked      | seed-accounts-sh+ts-catalogue  | ROLE_MATRIX,ROLE_MATRIX_DOMAINLOCKED,ROLE_USER        | true                  |
      | e2e-matrix-external-client   | seed-accounts-sh+ts-catalogue  | ROLE_MATRIX,ROLE_MATRIX_EXTERNAL_CLIENT,ROLE_USER     | true                  |
      | e2e-matrix-groupchat         | seed-accounts-sh+ts-catalogue  | ROLE_MATRIX,ROLE_USER                                 | true                  |
      | e2e-mod                      | seed-accounts-sh+ts-catalogue  | ROLE_MOD                                              | true                  |
      | e2e-pending                  | seed-accounts-sh+ts-catalogue  | (none)                                                | false                 |
      | e2e-superadmin               | extra-personas-sh+ts-catalogue | ROLE_SUPERADMIN                                       | true                  |
      | e2e-user                     | seed-accounts-sh+ts-catalogue  | ROLE_USER                                             | true                  |
      | eve@gmail.com                | extra-personas-sh              | ROLE_USER                                             | true                  |
      | frank@gmail.com              | extra-personas-sh              | ROLE_USER                                             | true                  |
      | rbac-approved@gmail.com      | extra-personas-sh              | ROLE_USER                                             | true                  |
      | rbac-login-user@gmail.com    | extra-personas-sh              | ROLE_USER                                             | true                  |
      | rbac-pending@gmail.com       | extra-personas-sh              | ROLE_USER                                             | true                  |
      | rbac-plain@gmail.com         | extra-personas-sh              | ROLE_USER                                             | true                  |

  # The composite ROLE_GAMES_ADMIN is NEVER granted directly: the sync job
  # materialises it as ROLE_GAMES INTERSECT (ROLE_ADMIN UNION ROLE_MOD). This
  # catalogue computes it from that rule; specs/rbac-roles.ts declares it per
  # user in `expectGamesAdmin`. Two independent statements of the same fact, so
  # they can be checked against each other.
  Scenario: the derived games-admin composite agrees with the declared expectation
    Then the derived games-admin composite agrees with every declared expectation
