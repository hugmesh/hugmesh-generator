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
# Forum (phpBB) — the ACCESS MATRIX: every seeded persona against every catalogued
# function of this service.
#
# 32 personas x 6 functions = 192 cells.
# 6 of 6 function probe paths are DERIVED from a committed artefact;
# 0 are ASSERTED (no artefact pins them yet) — see the FUNCTIONS entry's
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
@layer:gateway @service:phpbb @coverage-matrix
Feature: Forum (phpBB) — every persona against every function

  Scenario Outline: <role> is <outcome> at <function> @role:<role> @service:phpbb
    Then persona "<role>" is "<outcome>" at the "<function>" function
    And the seed decides that at pattern "<pattern>"

    Examples:
      | role                         | function         | outcome  | pattern                  | source                         |
      | admin@hugmesh.net            | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | admin@hugmesh.net            | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | admin@hugmesh.net            | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | admin@hugmesh.net            | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | admin@hugmesh.net            | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | admin@hugmesh.net            | phpbb.administer | admitted | /bff/forum/admin/**      | extra-personas-sh              |
      | alice@gmail.com              | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | alice@gmail.com              | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | alice@gmail.com              | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | alice@gmail.com              | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | alice@gmail.com              | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | alice@gmail.com              | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
      | bob@gmail.com                | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | bob@gmail.com                | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | bob@gmail.com                | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | bob@gmail.com                | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | bob@gmail.com                | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | bob@gmail.com                | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
      | carol@gmail.com              | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | carol@gmail.com              | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | carol@gmail.com              | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | carol@gmail.com              | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | carol@gmail.com              | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | carol@gmail.com              | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
      | dave@gmail.com               | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | dave@gmail.com               | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | dave@gmail.com               | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | dave@gmail.com               | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | dave@gmail.com               | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | dave@gmail.com               | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
      | dragoneer                    | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | dragoneer                    | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | dragoneer                    | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | dragoneer                    | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | dragoneer                    | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | dragoneer                    | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
      | e2e-admin                    | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | phpbb.administer | admitted | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | phpbb.administer | admitted | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-banned                   | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | e2e-banned                   | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | e2e-banned                   | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | e2e-banned                   | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | e2e-banned                   | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | e2e-banned                   | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
      | e2e-denied                   | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | phpbb.administer | refused  | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-fleet                    | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | e2e-fleet                    | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | e2e-fleet                    | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | e2e-fleet                    | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | e2e-fleet                    | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | e2e-fleet                    | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
      | e2e-forum                    | phpbb.open-ui    | admitted | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | phpbb.read-topic | admitted | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | phpbb.post-topic | admitted | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | phpbb.reply      | admitted | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | phpbb.administer | refused  | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | phpbb.administer | admitted | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | phpbb.administer | refused  | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | phpbb.administer | refused  | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | phpbb.administer | refused  | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | phpbb.administer | refused  | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | phpbb.administer | refused  | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | phpbb.administer | refused  | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | phpbb.administer | refused  | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | phpbb.administer | refused  | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | phpbb.administer | refused  | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | phpbb.administer | refused  | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-superadmin               | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh+ts-catalogue |
      | e2e-suspended                | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | e2e-suspended                | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | e2e-suspended                | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | e2e-suspended                | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | e2e-suspended                | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | e2e-suspended                | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
      | e2e-user                     | phpbb.open-ui    | refused  | /social/forum/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | phpbb.read-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | phpbb.post-topic | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | phpbb.reply      | refused  | /bff/forum/**            | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | phpbb.moderate   | refused  | /bff/forum/moderation/** | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | phpbb.administer | refused  | /bff/forum/admin/**      | seed-accounts-sh+ts-catalogue  |
      | eve@gmail.com                | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | eve@gmail.com                | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | eve@gmail.com                | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | eve@gmail.com                | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | eve@gmail.com                | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | eve@gmail.com                | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
      | frank@gmail.com              | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | frank@gmail.com              | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | frank@gmail.com              | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | frank@gmail.com              | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | frank@gmail.com              | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | frank@gmail.com              | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
      | rbac-approved@gmail.com      | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | rbac-approved@gmail.com      | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | rbac-approved@gmail.com      | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | rbac-approved@gmail.com      | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | rbac-approved@gmail.com      | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
      | rbac-login-user@gmail.com    | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | rbac-login-user@gmail.com    | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | rbac-login-user@gmail.com    | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | rbac-login-user@gmail.com    | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | rbac-login-user@gmail.com    | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
      | rbac-pending@gmail.com       | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | rbac-pending@gmail.com       | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | rbac-pending@gmail.com       | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | rbac-pending@gmail.com       | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | rbac-pending@gmail.com       | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
      | rbac-plain@gmail.com         | phpbb.open-ui    | refused  | /social/forum/**         | extra-personas-sh              |
      | rbac-plain@gmail.com         | phpbb.read-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | rbac-plain@gmail.com         | phpbb.post-topic | refused  | /bff/forum/**            | extra-personas-sh              |
      | rbac-plain@gmail.com         | phpbb.reply      | refused  | /bff/forum/**            | extra-personas-sh              |
      | rbac-plain@gmail.com         | phpbb.moderate   | refused  | /bff/forum/moderation/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | phpbb.administer | refused  | /bff/forum/admin/**      | extra-personas-sh              |
