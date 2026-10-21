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
# fe/be/pki gateway route-access — the ACCESS MATRIX: every seeded persona against every catalogued
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
@layer:gateway @service:gateway @coverage-matrix
Feature: fe/be/pki gateway route-access — every persona against every function

  Scenario Outline: <role> is <outcome> at <function> @role:<role> @service:gateway
    Then persona "<role>" is "<outcome>" at the "<function>" function
    And the seed decides that at pattern "<pattern>"

    Examples:
      | role                         | function                        | outcome  | pattern                      | source                         |
      | admin@hugmesh.net            | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | admin@hugmesh.net            | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | admin@hugmesh.net            | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | admin@hugmesh.net            | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | admin@hugmesh.net            | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | admin@hugmesh.net            | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | alice@gmail.com              | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | alice@gmail.com              | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | alice@gmail.com              | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | alice@gmail.com              | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | alice@gmail.com              | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | alice@gmail.com              | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | bob@gmail.com                | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | bob@gmail.com                | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | bob@gmail.com                | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | bob@gmail.com                | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | bob@gmail.com                | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | bob@gmail.com                | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | carol@gmail.com              | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | carol@gmail.com              | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | carol@gmail.com              | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | carol@gmail.com              | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | carol@gmail.com              | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | carol@gmail.com              | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | dave@gmail.com               | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | dave@gmail.com               | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | dave@gmail.com               | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | dave@gmail.com               | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | dave@gmail.com               | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | dave@gmail.com               | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | dragoneer                    | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | dragoneer                    | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | dragoneer                    | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | dragoneer                    | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | dragoneer                    | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | dragoneer                    | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | e2e-admin                    | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-banned                   | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | e2e-banned                   | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | e2e-banned                   | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | e2e-banned                   | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | e2e-banned                   | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | e2e-banned                   | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | e2e-denied                   | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-fleet                    | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | e2e-fleet                    | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | e2e-fleet                    | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | e2e-fleet                    | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | e2e-fleet                    | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | e2e-fleet                    | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | e2e-forum                    | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | gateway.session                 | refused  | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | gateway.federation-manifest     | refused  | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | gateway.session                 | refused  | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | gateway.federation-manifest     | refused  | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | e2e-superadmin               | gateway.front-door              | admitted | /                            | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | gateway.session                 | refused  | /bff/me/**                   | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | gateway.federation-manifest     | refused  | /api/federation/manifest     | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh+ts-catalogue |
      | e2e-suspended                | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | e2e-suspended                | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | e2e-suspended                | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | e2e-suspended                | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | e2e-suspended                | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | e2e-suspended                | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | e2e-user                     | gateway.front-door              | admitted | /                            | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | gateway.host-shell-importmap    | admitted | /importmap.json              | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | gateway.session                 | admitted | /bff/me/**                   | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | gateway.federation-manifest     | admitted | /api/federation/manifest     | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | gateway.federation-capabilities | admitted | /api/federation/capabilities | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | gateway.internal-refused        | refused  | /bff/internal/**             | seed-accounts-sh+ts-catalogue  |
      | eve@gmail.com                | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | eve@gmail.com                | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | eve@gmail.com                | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | eve@gmail.com                | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | eve@gmail.com                | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | eve@gmail.com                | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | frank@gmail.com              | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | frank@gmail.com              | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | frank@gmail.com              | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | frank@gmail.com              | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | frank@gmail.com              | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | frank@gmail.com              | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | rbac-approved@gmail.com      | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | rbac-approved@gmail.com      | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | rbac-approved@gmail.com      | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | rbac-approved@gmail.com      | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | rbac-approved@gmail.com      | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | rbac-approved@gmail.com      | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | rbac-login-user@gmail.com    | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | rbac-login-user@gmail.com    | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | rbac-login-user@gmail.com    | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | rbac-login-user@gmail.com    | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | rbac-login-user@gmail.com    | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | rbac-login-user@gmail.com    | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | rbac-pending@gmail.com       | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | rbac-pending@gmail.com       | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | rbac-pending@gmail.com       | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | rbac-pending@gmail.com       | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | rbac-pending@gmail.com       | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | rbac-pending@gmail.com       | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
      | rbac-plain@gmail.com         | gateway.front-door              | admitted | /                            | extra-personas-sh              |
      | rbac-plain@gmail.com         | gateway.host-shell-importmap    | admitted | /importmap.json              | extra-personas-sh              |
      | rbac-plain@gmail.com         | gateway.session                 | admitted | /bff/me/**                   | extra-personas-sh              |
      | rbac-plain@gmail.com         | gateway.federation-manifest     | admitted | /api/federation/manifest     | extra-personas-sh              |
      | rbac-plain@gmail.com         | gateway.federation-capabilities | admitted | /api/federation/capabilities | extra-personas-sh              |
      | rbac-plain@gmail.com         | gateway.internal-refused        | refused  | /bff/internal/**             | extra-personas-sh              |
