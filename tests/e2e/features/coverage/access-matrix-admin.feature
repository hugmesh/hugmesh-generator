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
# admin-ui remote — the ACCESS MATRIX: every seeded persona against every catalogued
# function of this service.
#
# 31 personas x 6 functions = 186 cells.
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
@layer:gateway @service:admin @coverage-matrix
Feature: admin-ui remote — every persona against every function

  Scenario Outline: <role> is <outcome> at <function> @role:<role> @service:admin
    Then persona "<role>" is "<outcome>" at the "<function>" function
    And the seed decides that at pattern "<pattern>"

    Examples:
      | role                         | function                 | outcome  | pattern                        | source                         |
      | admin@hugmesh.net            | admin.console            | admitted | /admin/**                      | extra-personas-sh              |
      | admin@hugmesh.net            | admin.allowlist          | admitted | /bff/admin/**                  | extra-personas-sh              |
      | admin@hugmesh.net            | admin.phone-fleet        | admitted | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | admin@hugmesh.net            | admin.api-docs           | admitted | /api-docs/**                   | extra-personas-sh              |
      | admin@hugmesh.net            | admin.moderation-console | admitted | /mod/**                        | extra-personas-sh              |
      | admin@hugmesh.net            | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
      | alice@gmail.com              | admin.console            | refused  | /admin/**                      | extra-personas-sh              |
      | alice@gmail.com              | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh              |
      | alice@gmail.com              | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | alice@gmail.com              | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh              |
      | alice@gmail.com              | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh              |
      | alice@gmail.com              | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
      | bob@gmail.com                | admin.console            | refused  | /admin/**                      | extra-personas-sh              |
      | bob@gmail.com                | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh              |
      | bob@gmail.com                | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | bob@gmail.com                | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh              |
      | bob@gmail.com                | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh              |
      | bob@gmail.com                | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
      | carol@gmail.com              | admin.console            | refused  | /admin/**                      | extra-personas-sh              |
      | carol@gmail.com              | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh              |
      | carol@gmail.com              | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | carol@gmail.com              | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh              |
      | carol@gmail.com              | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh              |
      | carol@gmail.com              | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
      | dave@gmail.com               | admin.console            | refused  | /admin/**                      | extra-personas-sh              |
      | dave@gmail.com               | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh              |
      | dave@gmail.com               | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | dave@gmail.com               | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh              |
      | dave@gmail.com               | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh              |
      | dave@gmail.com               | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
      | dragoneer                    | admin.console            | refused  | /admin/**                      | extra-personas-sh              |
      | dragoneer                    | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh              |
      | dragoneer                    | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | dragoneer                    | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh              |
      | dragoneer                    | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh              |
      | dragoneer                    | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
      | e2e-admin                    | admin.console            | admitted | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | admin.allowlist          | admitted | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | admin.phone-fleet        | admitted | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | admin.api-docs           | admitted | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | admin.moderation-console | admitted | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | admin.console            | admitted | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | admin.allowlist          | admitted | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | admin.phone-fleet        | admitted | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | admin.api-docs           | admitted | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | admin.moderation-console | admitted | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-banned                   | admin.console            | refused  | /admin/**                      | extra-personas-sh              |
      | e2e-banned                   | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh              |
      | e2e-banned                   | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | e2e-banned                   | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh              |
      | e2e-banned                   | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh              |
      | e2e-banned                   | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
      | e2e-denied                   | admin.console            | refused  | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | admin.allowlist          | refused  | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | admin.api-docs           | refused  | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | admin.moderation-console | refused  | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-fleet                    | admin.console            | refused  | /admin/**                      | extra-personas-sh              |
      | e2e-fleet                    | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh              |
      | e2e-fleet                    | admin.phone-fleet        | admitted | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | e2e-fleet                    | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh              |
      | e2e-fleet                    | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh              |
      | e2e-fleet                    | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
      | e2e-forum                    | admin.console            | refused  | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | admin.allowlist          | refused  | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | admin.api-docs           | refused  | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | admin.moderation-console | refused  | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | admin.console            | admitted | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | admin.allowlist          | admitted | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | admin.phone-fleet        | admitted | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | admin.api-docs           | admitted | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | admin.moderation-console | admitted | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | admin.console            | refused  | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | admin.allowlist          | refused  | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | admin.api-docs           | refused  | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | admin.moderation-console | refused  | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | admin.console            | refused  | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | admin.allowlist          | refused  | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | admin.api-docs           | refused  | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | admin.moderation-console | refused  | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | admin.console            | refused  | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | admin.allowlist          | refused  | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | admin.api-docs           | refused  | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | admin.moderation-console | refused  | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | admin.console            | refused  | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | admin.allowlist          | refused  | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | admin.api-docs           | refused  | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | admin.moderation-console | refused  | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | admin.console            | refused  | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | admin.allowlist          | refused  | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | admin.api-docs           | refused  | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | admin.moderation-console | refused  | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | admin.console            | refused  | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | admin.allowlist          | refused  | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | admin.api-docs           | refused  | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | admin.moderation-console | refused  | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | admin.console            | refused  | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | admin.allowlist          | refused  | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | admin.api-docs           | refused  | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | admin.moderation-console | refused  | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | admin.console            | refused  | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | admin.allowlist          | refused  | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | admin.api-docs           | refused  | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | admin.moderation-console | refused  | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | admin.console            | refused  | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | admin.allowlist          | refused  | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | admin.api-docs           | refused  | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | admin.moderation-console | admitted | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | admin.console            | refused  | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | admin.allowlist          | refused  | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | admin.api-docs           | refused  | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | admin.moderation-console | refused  | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | e2e-superadmin               | admin.console            | refused  | /admin/**                      | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | admin.phone-fleet        | admitted | /bff/admin/phone-fleet/**      | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | admin.superadmin-catalog | admitted | /superadmin/service-catalog/** | extra-personas-sh+ts-catalogue |
      | e2e-user                     | admin.console            | refused  | /admin/**                      | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | admin.allowlist          | refused  | /bff/admin/**                  | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | admin.api-docs           | refused  | /api-docs/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | admin.moderation-console | refused  | /mod/**                        | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | seed-accounts-sh+ts-catalogue  |
      | eve@gmail.com                | admin.console            | refused  | /admin/**                      | extra-personas-sh              |
      | eve@gmail.com                | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh              |
      | eve@gmail.com                | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | eve@gmail.com                | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh              |
      | eve@gmail.com                | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh              |
      | eve@gmail.com                | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
      | frank@gmail.com              | admin.console            | refused  | /admin/**                      | extra-personas-sh              |
      | frank@gmail.com              | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh              |
      | frank@gmail.com              | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | frank@gmail.com              | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh              |
      | frank@gmail.com              | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh              |
      | frank@gmail.com              | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | admin.console            | refused  | /admin/**                      | extra-personas-sh              |
      | rbac-approved@gmail.com      | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh              |
      | rbac-approved@gmail.com      | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | rbac-approved@gmail.com      | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh              |
      | rbac-approved@gmail.com      | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh              |
      | rbac-approved@gmail.com      | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | admin.console            | refused  | /admin/**                      | extra-personas-sh              |
      | rbac-login-user@gmail.com    | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh              |
      | rbac-login-user@gmail.com    | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | rbac-login-user@gmail.com    | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh              |
      | rbac-login-user@gmail.com    | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh              |
      | rbac-login-user@gmail.com    | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | admin.console            | refused  | /admin/**                      | extra-personas-sh              |
      | rbac-pending@gmail.com       | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh              |
      | rbac-pending@gmail.com       | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | rbac-pending@gmail.com       | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh              |
      | rbac-pending@gmail.com       | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh              |
      | rbac-pending@gmail.com       | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | admin.console            | refused  | /admin/**                      | extra-personas-sh              |
      | rbac-plain@gmail.com         | admin.allowlist          | refused  | /bff/admin/**                  | extra-personas-sh              |
      | rbac-plain@gmail.com         | admin.phone-fleet        | refused  | /bff/admin/phone-fleet/**      | extra-personas-sh              |
      | rbac-plain@gmail.com         | admin.api-docs           | refused  | /api-docs/**                   | extra-personas-sh              |
      | rbac-plain@gmail.com         | admin.moderation-console | refused  | /mod/**                        | extra-personas-sh              |
      | rbac-plain@gmail.com         | admin.superadmin-catalog | refused  | /superadmin/service-catalog/** | extra-personas-sh              |
