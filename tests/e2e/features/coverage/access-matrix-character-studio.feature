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
# Character studio (2D editor) — the ACCESS MATRIX: every seeded persona against every catalogued
# function of this service.
#
# 32 personas x 4 functions = 128 cells.
# 3 of 4 function probe paths are DERIVED from a committed artefact;
# 1 are ASSERTED (no artefact pins them yet) — see the FUNCTIONS entry's
# `source` field, which the function-catalogue feature pins row by row.
#
# COLUMNS
#   role     the persona handle, from the union of the three seeding rosters
#   function the catalogued function id (steps/coverage-catalogue.ts FUNCTIONS)
#   outcome  what the COMMITTED gateway_route_access seed decides for that
#            persona's effective role-set — admitted | refused
#   pattern  the url_pattern that won the most-specific match, or
#            "(none — default deny)" when the seed governs no pattern at all
#   source   which seeding lanes create this persona. The three rosters DISAGREE;
#            the disagreement is shown here rather than resolved behind the scenes.
@layer:gateway @service:character-studio @coverage-matrix
Feature: Character studio (2D editor) — every persona against every function

  Scenario Outline: <role> is <outcome> at <function> @role:<role> @service:character-studio
    Then persona "<role>" is "<outcome>" at the "<function>" function
    And the seed decides that at pattern "<pattern>"

    Examples:
      | role                         | function                | outcome  | pattern              | source                         |
      | admin@hugmesh.net            | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | admin@hugmesh.net            | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | admin@hugmesh.net            | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | admin@hugmesh.net            | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | alice@gmail.com              | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | alice@gmail.com              | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | alice@gmail.com              | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | alice@gmail.com              | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | bob@gmail.com                | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | bob@gmail.com                | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | bob@gmail.com                | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | bob@gmail.com                | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | carol@gmail.com              | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | carol@gmail.com              | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | carol@gmail.com              | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | carol@gmail.com              | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | dave@gmail.com               | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | dave@gmail.com               | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | dave@gmail.com               | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | dave@gmail.com               | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | dragoneer                    | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | dragoneer                    | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | dragoneer                    | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | dragoneer                    | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | e2e-admin                    | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-banned                   | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | e2e-banned                   | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | e2e-banned                   | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | e2e-banned                   | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | e2e-denied                   | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-fleet                    | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | e2e-fleet                    | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | e2e-fleet                    | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | e2e-fleet                    | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | e2e-forum                    | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | character-studio.open   | refused  | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | character-studio.create | refused  | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | character-studio.save   | refused  | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | character-studio.export | refused  | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | character-studio.open   | refused  | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | character-studio.create | refused  | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | character-studio.save   | refused  | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | character-studio.export | refused  | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-superadmin               | character-studio.open   | refused  | /character-studio/** | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | character-studio.create | refused  | /bff/user/**         | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | character-studio.save   | refused  | /bff/user/**         | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | character-studio.export | refused  | /bff/user/**         | extra-personas-sh+ts-catalogue |
      | e2e-suspended                | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | e2e-suspended                | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | e2e-suspended                | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | e2e-suspended                | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | e2e-user                     | character-studio.open   | admitted | /character-studio/** | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | character-studio.create | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | character-studio.save   | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | character-studio.export | admitted | /bff/user/**         | seed-accounts-sh+ts-catalogue  |
      | eve@gmail.com                | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | eve@gmail.com                | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | eve@gmail.com                | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | eve@gmail.com                | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | frank@gmail.com              | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | frank@gmail.com              | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | frank@gmail.com              | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | frank@gmail.com              | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | rbac-approved@gmail.com      | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | rbac-approved@gmail.com      | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | rbac-approved@gmail.com      | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | rbac-login-user@gmail.com    | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | rbac-login-user@gmail.com    | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | rbac-login-user@gmail.com    | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | rbac-pending@gmail.com       | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | rbac-pending@gmail.com       | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | rbac-pending@gmail.com       | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
      | rbac-plain@gmail.com         | character-studio.open   | admitted | /character-studio/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | character-studio.create | admitted | /bff/user/**         | extra-personas-sh              |
      | rbac-plain@gmail.com         | character-studio.save   | admitted | /bff/user/**         | extra-personas-sh              |
      | rbac-plain@gmail.com         | character-studio.export | admitted | /bff/user/**         | extra-personas-sh              |
