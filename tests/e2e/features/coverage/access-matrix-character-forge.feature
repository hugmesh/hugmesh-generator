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
# Character forge (3D) — the ACCESS MATRIX: every seeded persona against every catalogued
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
@layer:gateway @service:character-forge @coverage-matrix
Feature: Character forge (3D) — every persona against every function

  Scenario Outline: <role> is <outcome> at <function> @role:<role> @service:character-forge
    Then persona "<role>" is "<outcome>" at the "<function>" function
    And the seed decides that at pattern "<pattern>"

    Examples:
      | role                         | function               | outcome  | pattern                 | source                         |
      | admin@hugmesh.net            | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | admin@hugmesh.net            | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | admin@hugmesh.net            | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | admin@hugmesh.net            | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | alice@gmail.com              | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | alice@gmail.com              | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | alice@gmail.com              | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | alice@gmail.com              | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | bob@gmail.com                | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | bob@gmail.com                | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | bob@gmail.com                | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | bob@gmail.com                | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | carol@gmail.com              | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | carol@gmail.com              | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | carol@gmail.com              | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | carol@gmail.com              | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | dave@gmail.com               | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | dave@gmail.com               | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | dave@gmail.com               | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | dave@gmail.com               | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | dragoneer                    | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | dragoneer                    | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | dragoneer                    | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | dragoneer                    | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | e2e-admin                    | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-banned                   | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | e2e-banned                   | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | e2e-banned                   | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | e2e-banned                   | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | e2e-denied                   | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-fleet                    | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | e2e-fleet                    | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | e2e-fleet                    | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | e2e-fleet                    | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | e2e-forum                    | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | character-forge.open   | refused  | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | character-forge.create | refused  | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | character-forge.save   | refused  | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | character-forge.export | refused  | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | character-forge.open   | refused  | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | character-forge.create | refused  | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | character-forge.save   | refused  | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | character-forge.export | refused  | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-superadmin               | character-forge.open   | refused  | /character-forge/**     | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | character-forge.create | refused  | /bff/character-forge/** | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | character-forge.save   | refused  | /bff/character-forge/** | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | character-forge.export | refused  | /bff/character-forge/** | extra-personas-sh+ts-catalogue |
      | e2e-suspended                | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | e2e-suspended                | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | e2e-suspended                | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | e2e-suspended                | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | e2e-user                     | character-forge.open   | admitted | /character-forge/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | character-forge.create | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | character-forge.save   | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | character-forge.export | admitted | /bff/character-forge/** | seed-accounts-sh+ts-catalogue  |
      | eve@gmail.com                | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | eve@gmail.com                | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | eve@gmail.com                | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | eve@gmail.com                | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | frank@gmail.com              | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | frank@gmail.com              | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | frank@gmail.com              | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | frank@gmail.com              | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | rbac-approved@gmail.com      | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | rbac-login-user@gmail.com    | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | rbac-pending@gmail.com       | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | character-forge.open   | admitted | /character-forge/**     | extra-personas-sh              |
      | rbac-plain@gmail.com         | character-forge.create | admitted | /bff/character-forge/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | character-forge.save   | admitted | /bff/character-forge/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | character-forge.export | admitted | /bff/character-forge/** | extra-personas-sh              |
