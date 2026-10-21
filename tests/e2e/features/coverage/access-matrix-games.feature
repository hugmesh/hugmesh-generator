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
# Games platform — the ACCESS MATRIX: every seeded persona against every catalogued
# function of this service.
#
# 32 personas x 6 functions = 192 cells.
# 5 of 6 function probe paths are DERIVED from a committed artefact;
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
@layer:gateway @service:games @coverage-matrix
Feature: Games platform — every persona against every function

  Scenario Outline: <role> is <outcome> at <function> @role:<role> @service:games
    Then persona "<role>" is "<outcome>" at the "<function>" function
    And the seed decides that at pattern "<pattern>"

    Examples:
      | role                         | function                 | outcome  | pattern                  | source                         |
      | admin@hugmesh.net            | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | admin@hugmesh.net            | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | admin@hugmesh.net            | games.instance-lifecycle | admitted | /games/**                | extra-personas-sh              |
      | admin@hugmesh.net            | games.server-fleet       | admitted | /games/servers/**        | extra-personas-sh              |
      | admin@hugmesh.net            | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | admin@hugmesh.net            | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | alice@gmail.com              | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | alice@gmail.com              | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | alice@gmail.com              | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | alice@gmail.com              | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | alice@gmail.com              | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | alice@gmail.com              | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | bob@gmail.com                | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | bob@gmail.com                | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | bob@gmail.com                | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | bob@gmail.com                | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | bob@gmail.com                | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | bob@gmail.com                | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | carol@gmail.com              | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | carol@gmail.com              | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | carol@gmail.com              | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | carol@gmail.com              | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | carol@gmail.com              | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | carol@gmail.com              | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | dave@gmail.com               | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | dave@gmail.com               | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | dave@gmail.com               | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | dave@gmail.com               | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | dave@gmail.com               | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | dave@gmail.com               | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | dragoneer                    | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | dragoneer                    | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | dragoneer                    | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | dragoneer                    | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | dragoneer                    | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | dragoneer                    | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | e2e-admin                    | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | games.instance-lifecycle | admitted | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | games.server-fleet       | admitted | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | games.instance-lifecycle | admitted | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | games.server-fleet       | admitted | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-banned                   | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | e2e-banned                   | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | e2e-banned                   | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | e2e-banned                   | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | e2e-banned                   | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | e2e-banned                   | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | e2e-denied                   | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | games.instance-lifecycle | refused  | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | games.server-fleet       | refused  | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-fleet                    | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | e2e-fleet                    | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | e2e-fleet                    | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | e2e-fleet                    | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | e2e-fleet                    | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | e2e-fleet                    | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | e2e-forum                    | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | games.instance-lifecycle | refused  | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | games.server-fleet       | refused  | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | games.instance-lifecycle | admitted | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | games.server-fleet       | admitted | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | games.admin-console      | admitted | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | games.instance-lifecycle | admitted | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | games.server-fleet       | refused  | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | games.instance-lifecycle | refused  | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | games.server-fleet       | refused  | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | games.instance-lifecycle | refused  | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | games.server-fleet       | refused  | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | games.instance-lifecycle | refused  | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | games.server-fleet       | refused  | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | games.instance-lifecycle | refused  | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | games.server-fleet       | refused  | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | games.instance-lifecycle | refused  | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | games.server-fleet       | refused  | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | games.instance-lifecycle | refused  | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | games.server-fleet       | refused  | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | games.instance-lifecycle | refused  | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | games.server-fleet       | refused  | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | games.instance-lifecycle | admitted | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | games.server-fleet       | admitted | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | games.instance-lifecycle | refused  | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | games.server-fleet       | refused  | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | e2e-superadmin               | games.list               | refused  | (none — default deny)    | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | games.launch             | refused  | (none — default deny)    | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh+ts-catalogue |
      | e2e-suspended                | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | e2e-suspended                | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | e2e-suspended                | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | e2e-suspended                | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | e2e-suspended                | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | e2e-suspended                | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | e2e-user                     | games.list               | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | games.launch             | refused  | (none — default deny)    | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | games.instance-lifecycle | refused  | /games/**                | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | games.server-fleet       | refused  | /games/servers/**        | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | games.admin-console      | refused  | /games/admin/**          | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | games.services-runner    | refused  | /admin/games-services/** | seed-accounts-sh+ts-catalogue  |
      | eve@gmail.com                | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | eve@gmail.com                | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | eve@gmail.com                | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | eve@gmail.com                | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | eve@gmail.com                | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | eve@gmail.com                | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | frank@gmail.com              | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | frank@gmail.com              | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | frank@gmail.com              | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | frank@gmail.com              | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | frank@gmail.com              | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | frank@gmail.com              | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | rbac-approved@gmail.com      | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | rbac-approved@gmail.com      | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | rbac-approved@gmail.com      | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | rbac-approved@gmail.com      | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | rbac-approved@gmail.com      | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | rbac-login-user@gmail.com    | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | rbac-login-user@gmail.com    | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | rbac-login-user@gmail.com    | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | rbac-login-user@gmail.com    | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | rbac-login-user@gmail.com    | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | rbac-pending@gmail.com       | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | rbac-pending@gmail.com       | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | rbac-pending@gmail.com       | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | rbac-pending@gmail.com       | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | rbac-pending@gmail.com       | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | games.list               | refused  | (none — default deny)    | extra-personas-sh              |
      | rbac-plain@gmail.com         | games.launch             | refused  | (none — default deny)    | extra-personas-sh              |
      | rbac-plain@gmail.com         | games.instance-lifecycle | refused  | /games/**                | extra-personas-sh              |
      | rbac-plain@gmail.com         | games.server-fleet       | refused  | /games/servers/**        | extra-personas-sh              |
      | rbac-plain@gmail.com         | games.admin-console      | refused  | /games/admin/**          | extra-personas-sh              |
      | rbac-plain@gmail.com         | games.services-runner    | refused  | /admin/games-services/** | extra-personas-sh              |
