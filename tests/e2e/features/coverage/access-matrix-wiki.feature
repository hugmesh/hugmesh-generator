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
# Wiki — the ACCESS MATRIX: every seeded persona against every catalogued
# function of this service.
#
# 31 personas x 4 functions = 124 cells.
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
@layer:gateway @service:wiki @coverage-matrix
Feature: Wiki — every persona against every function

  Scenario Outline: <role> is <outcome> at <function> @role:<role> @service:wiki
    Then persona "<role>" is "<outcome>" at the "<function>" function
    And the seed decides that at pattern "<pattern>"

    Examples:
      | role                         | function        | outcome  | pattern            | source                         |
      | admin@hugmesh.net            | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | admin@hugmesh.net            | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | admin@hugmesh.net            | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | admin@hugmesh.net            | wiki.administer | admitted | /bff/wiki/admin/** | extra-personas-sh              |
      | alice@gmail.com              | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | alice@gmail.com              | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | alice@gmail.com              | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | alice@gmail.com              | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh              |
      | bob@gmail.com                | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | bob@gmail.com                | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | bob@gmail.com                | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | bob@gmail.com                | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh              |
      | carol@gmail.com              | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | carol@gmail.com              | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | carol@gmail.com              | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | carol@gmail.com              | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh              |
      | dave@gmail.com               | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | dave@gmail.com               | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | dave@gmail.com               | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | dave@gmail.com               | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh              |
      | dragoneer                    | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | dragoneer                    | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | dragoneer                    | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | dragoneer                    | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh              |
      | e2e-admin                    | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | wiki.administer | admitted | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | wiki.administer | admitted | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-banned                   | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | e2e-banned                   | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | e2e-banned                   | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | e2e-banned                   | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh              |
      | e2e-denied                   | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | wiki.administer | refused  | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-fleet                    | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | e2e-fleet                    | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | e2e-fleet                    | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | e2e-fleet                    | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh              |
      | e2e-forum                    | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | wiki.administer | refused  | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | wiki.administer | admitted | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | wiki.administer | refused  | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | wiki.administer | refused  | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | wiki.administer | refused  | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | wiki.administer | refused  | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | wiki.administer | refused  | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | wiki.administer | refused  | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | wiki.administer | refused  | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | wiki.administer | refused  | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | wiki.administer | refused  | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | wiki.administer | refused  | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | e2e-superadmin               | wiki.read       | refused  | /wiki/**           | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh+ts-catalogue |
      | e2e-user                     | wiki.read       | refused  | /wiki/**           | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | wiki.edit       | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | wiki.history    | refused  | /bff/wiki/**       | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | wiki.administer | refused  | /bff/wiki/admin/** | seed-accounts-sh+ts-catalogue  |
      | eve@gmail.com                | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | eve@gmail.com                | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | eve@gmail.com                | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | eve@gmail.com                | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh              |
      | frank@gmail.com              | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | frank@gmail.com              | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | frank@gmail.com              | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | frank@gmail.com              | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | rbac-approved@gmail.com      | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | rbac-approved@gmail.com      | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | rbac-approved@gmail.com      | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | rbac-login-user@gmail.com    | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | rbac-login-user@gmail.com    | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | rbac-login-user@gmail.com    | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | rbac-pending@gmail.com       | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | rbac-pending@gmail.com       | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | rbac-pending@gmail.com       | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | wiki.read       | refused  | /wiki/**           | extra-personas-sh              |
      | rbac-plain@gmail.com         | wiki.edit       | refused  | /bff/wiki/**       | extra-personas-sh              |
      | rbac-plain@gmail.com         | wiki.history    | refused  | /bff/wiki/**       | extra-personas-sh              |
      | rbac-plain@gmail.com         | wiki.administer | refused  | /bff/wiki/admin/** | extra-personas-sh              |
