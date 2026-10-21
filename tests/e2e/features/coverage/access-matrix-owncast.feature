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
# Owncast live streaming — the ACCESS MATRIX: every seeded persona against every catalogued
# function of this service.
#
# 32 personas x 4 functions = 128 cells.
# 2 of 4 function probe paths are DERIVED from a committed artefact;
# 2 are ASSERTED (no artefact pins them yet) — see the FUNCTIONS entry's
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
@layer:gateway @service:owncast @coverage-matrix
Feature: Owncast live streaming — every persona against every function

  Scenario Outline: <role> is <outcome> at <function> @role:<role> @service:owncast
    Then persona "<role>" is "<outcome>" at the "<function>" function
    And the seed decides that at pattern "<pattern>"

    Examples:
      | role                         | function           | outcome  | pattern               | source                         |
      | admin@hugmesh.net            | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | admin@hugmesh.net            | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | admin@hugmesh.net            | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | admin@hugmesh.net            | owncast.administer | admitted | /bff/owncast/admin/** | extra-personas-sh              |
      | alice@gmail.com              | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | alice@gmail.com              | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | alice@gmail.com              | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | alice@gmail.com              | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
      | bob@gmail.com                | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | bob@gmail.com                | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | bob@gmail.com                | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | bob@gmail.com                | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
      | carol@gmail.com              | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | carol@gmail.com              | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | carol@gmail.com              | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | carol@gmail.com              | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
      | dave@gmail.com               | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | dave@gmail.com               | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | dave@gmail.com               | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | dave@gmail.com               | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
      | dragoneer                    | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | dragoneer                    | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | dragoneer                    | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | dragoneer                    | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
      | e2e-admin                    | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | owncast.administer | admitted | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | owncast.administer | admitted | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-banned                   | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | e2e-banned                   | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | e2e-banned                   | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | e2e-banned                   | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
      | e2e-denied                   | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | owncast.administer | refused  | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-fleet                    | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | e2e-fleet                    | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | e2e-fleet                    | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | e2e-fleet                    | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
      | e2e-forum                    | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | owncast.administer | refused  | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | owncast.administer | admitted | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | owncast.administer | refused  | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | owncast.administer | refused  | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | owncast.administer | refused  | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | owncast.administer | refused  | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | owncast.administer | refused  | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | owncast.administer | refused  | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | owncast.administer | refused  | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | owncast.administer | refused  | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | owncast.administer | refused  | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | owncast.administer | refused  | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-superadmin               | owncast.watch      | refused  | /owncast/**           | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh+ts-catalogue |
      | e2e-suspended                | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | e2e-suspended                | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | e2e-suspended                | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | e2e-suspended                | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
      | e2e-user                     | owncast.watch      | refused  | /owncast/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | owncast.publish    | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | owncast.chat       | refused  | /bff/owncast/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | owncast.administer | refused  | /bff/owncast/admin/** | seed-accounts-sh+ts-catalogue  |
      | eve@gmail.com                | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | eve@gmail.com                | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | eve@gmail.com                | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | eve@gmail.com                | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
      | frank@gmail.com              | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | frank@gmail.com              | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | frank@gmail.com              | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | frank@gmail.com              | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | rbac-approved@gmail.com      | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | rbac-approved@gmail.com      | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | rbac-approved@gmail.com      | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | rbac-login-user@gmail.com    | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | rbac-login-user@gmail.com    | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | rbac-login-user@gmail.com    | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | rbac-pending@gmail.com       | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | rbac-pending@gmail.com       | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | rbac-pending@gmail.com       | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | owncast.watch      | refused  | /owncast/**           | extra-personas-sh              |
      | rbac-plain@gmail.com         | owncast.publish    | refused  | /bff/owncast/**       | extra-personas-sh              |
      | rbac-plain@gmail.com         | owncast.chat       | refused  | /bff/owncast/**       | extra-personas-sh              |
      | rbac-plain@gmail.com         | owncast.administer | refused  | /bff/owncast/admin/** | extra-personas-sh              |
