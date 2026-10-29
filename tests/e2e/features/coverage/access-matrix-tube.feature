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
# Tube (video) — the ACCESS MATRIX: every seeded persona against every catalogued
# function of this service.
#
# 31 personas x 4 functions = 124 cells.
# 1 of 4 function probe paths are DERIVED from a committed artefact;
# 3 are ASSERTED (no artefact pins them yet) — see the FUNCTIONS entry's
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
@layer:gateway @service:tube @coverage-matrix
Feature: Tube (video) — every persona against every function

  Scenario Outline: <role> is <outcome> at <function> @role:<role> @service:tube
    Then persona "<role>" is "<outcome>" at the "<function>" function
    And the seed decides that at pattern "<pattern>"

    Examples:
      | role                         | function     | outcome | pattern      | source                         |
      | admin@hugmesh.net            | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | admin@hugmesh.net            | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | admin@hugmesh.net            | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | admin@hugmesh.net            | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
      | alice@gmail.com              | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | alice@gmail.com              | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | alice@gmail.com              | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | alice@gmail.com              | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
      | bob@gmail.com                | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | bob@gmail.com                | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | bob@gmail.com                | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | bob@gmail.com                | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
      | carol@gmail.com              | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | carol@gmail.com              | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | carol@gmail.com              | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | carol@gmail.com              | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
      | dave@gmail.com               | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | dave@gmail.com               | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | dave@gmail.com               | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | dave@gmail.com               | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
      | dragoneer                    | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | dragoneer                    | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | dragoneer                    | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | dragoneer                    | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
      | e2e-admin                    | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-banned                   | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | e2e-banned                   | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | e2e-banned                   | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | e2e-banned                   | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
      | e2e-denied                   | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-fleet                    | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | e2e-fleet                    | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | e2e-fleet                    | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | e2e-fleet                    | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
      | e2e-forum                    | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-superadmin               | tube.watch   | refused | /tube/**     | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | tube.list    | refused | /bff/tube/** | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | tube.publish | refused | /bff/tube/** | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | tube.delete  | refused | /bff/tube/** | extra-personas-sh+ts-catalogue |
      | e2e-user                     | tube.watch   | refused | /tube/**     | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | tube.list    | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | tube.publish | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | tube.delete  | refused | /bff/tube/** | seed-accounts-sh+ts-catalogue  |
      | eve@gmail.com                | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | eve@gmail.com                | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | eve@gmail.com                | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | eve@gmail.com                | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
      | frank@gmail.com              | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | frank@gmail.com              | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | frank@gmail.com              | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | frank@gmail.com              | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | rbac-approved@gmail.com      | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | rbac-login-user@gmail.com    | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | rbac-pending@gmail.com       | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | tube.watch   | refused | /tube/**     | extra-personas-sh              |
      | rbac-plain@gmail.com         | tube.list    | refused | /bff/tube/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | tube.publish | refused | /bff/tube/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | tube.delete  | refused | /bff/tube/** | extra-personas-sh              |
