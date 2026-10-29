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
# login-ui remote — the ACCESS MATRIX: every seeded persona against every catalogued
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
@layer:gateway @service:login @coverage-matrix
Feature: login-ui remote — every persona against every function

  Scenario Outline: <role> is <outcome> at <function> @role:<role> @service:login
    Then persona "<role>" is "<outcome>" at the "<function>" function
    And the seed decides that at pattern "<pattern>"

    Examples:
      | role                         | function               | outcome  | pattern           | source                         |
      | admin@hugmesh.net            | login.form             | admitted | /login/**         | extra-personas-sh              |
      | admin@hugmesh.net            | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | admin@hugmesh.net            | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | admin@hugmesh.net            | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | admin@hugmesh.net            | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | admin@hugmesh.net            | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
      | alice@gmail.com              | login.form             | admitted | /login/**         | extra-personas-sh              |
      | alice@gmail.com              | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | alice@gmail.com              | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | alice@gmail.com              | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | alice@gmail.com              | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | alice@gmail.com              | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
      | bob@gmail.com                | login.form             | admitted | /login/**         | extra-personas-sh              |
      | bob@gmail.com                | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | bob@gmail.com                | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | bob@gmail.com                | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | bob@gmail.com                | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | bob@gmail.com                | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
      | carol@gmail.com              | login.form             | admitted | /login/**         | extra-personas-sh              |
      | carol@gmail.com              | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | carol@gmail.com              | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | carol@gmail.com              | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | carol@gmail.com              | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | carol@gmail.com              | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
      | dave@gmail.com               | login.form             | admitted | /login/**         | extra-personas-sh              |
      | dave@gmail.com               | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | dave@gmail.com               | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | dave@gmail.com               | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | dave@gmail.com               | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | dave@gmail.com               | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
      | dragoneer                    | login.form             | admitted | /login/**         | extra-personas-sh              |
      | dragoneer                    | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | dragoneer                    | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | dragoneer                    | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | dragoneer                    | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | dragoneer                    | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
      | e2e-admin                    | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-admin                    | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-adminonly                | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-banned                   | login.form             | admitted | /login/**         | extra-personas-sh              |
      | e2e-banned                   | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | e2e-banned                   | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | e2e-banned                   | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | e2e-banned                   | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | e2e-banned                   | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
      | e2e-denied                   | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-denied                   | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-fleet                    | login.form             | admitted | /login/**         | extra-personas-sh              |
      | e2e-fleet                    | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | e2e-fleet                    | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | e2e-fleet                    | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | e2e-fleet                    | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | e2e-fleet                    | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
      | e2e-forum                    | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-forum                    | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesadmin               | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-gamesonly                | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon                 | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-domainlocked    | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-mastodon-external-client | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix                   | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-domainlocked      | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-external-client   | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-matrix-groupchat         | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | login.register         | refused  | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | login.provision        | refused  | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | login.register-google  | refused  | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-mod                      | login.register-discord | refused  | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | login.register         | refused  | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | login.provision        | refused  | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | login.register-google  | refused  | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-pending                  | login.register-discord | refused  | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-superadmin               | login.form             | admitted | /login/**         | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | login.register         | refused  | /bff/register/**  | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | login.provision        | refused  | /bff/provision/** | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | login.register-google  | refused  | /bff/register/**  | extra-personas-sh+ts-catalogue |
      | e2e-superadmin               | login.register-discord | refused  | /bff/register/**  | extra-personas-sh+ts-catalogue |
      | e2e-user                     | login.form             | admitted | /login/**         | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | login.native-sign-in   | admitted | /bff/login        | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | login.register         | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | login.provision        | admitted | /bff/provision/** | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | login.register-google  | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | e2e-user                     | login.register-discord | admitted | /bff/register/**  | seed-accounts-sh+ts-catalogue  |
      | eve@gmail.com                | login.form             | admitted | /login/**         | extra-personas-sh              |
      | eve@gmail.com                | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | eve@gmail.com                | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | eve@gmail.com                | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | eve@gmail.com                | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | eve@gmail.com                | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
      | frank@gmail.com              | login.form             | admitted | /login/**         | extra-personas-sh              |
      | frank@gmail.com              | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | frank@gmail.com              | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | frank@gmail.com              | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | frank@gmail.com              | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | frank@gmail.com              | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
      | rbac-approved@gmail.com      | login.form             | admitted | /login/**         | extra-personas-sh              |
      | rbac-approved@gmail.com      | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | rbac-approved@gmail.com      | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | rbac-approved@gmail.com      | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | rbac-approved@gmail.com      | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | rbac-approved@gmail.com      | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
      | rbac-login-user@gmail.com    | login.form             | admitted | /login/**         | extra-personas-sh              |
      | rbac-login-user@gmail.com    | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | rbac-login-user@gmail.com    | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | rbac-login-user@gmail.com    | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | rbac-login-user@gmail.com    | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | rbac-login-user@gmail.com    | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
      | rbac-pending@gmail.com       | login.form             | admitted | /login/**         | extra-personas-sh              |
      | rbac-pending@gmail.com       | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | rbac-pending@gmail.com       | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | rbac-pending@gmail.com       | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | rbac-pending@gmail.com       | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | rbac-pending@gmail.com       | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
      | rbac-plain@gmail.com         | login.form             | admitted | /login/**         | extra-personas-sh              |
      | rbac-plain@gmail.com         | login.native-sign-in   | admitted | /bff/login        | extra-personas-sh              |
      | rbac-plain@gmail.com         | login.register         | admitted | /bff/register/**  | extra-personas-sh              |
      | rbac-plain@gmail.com         | login.provision        | admitted | /bff/provision/** | extra-personas-sh              |
      | rbac-plain@gmail.com         | login.register-google  | admitted | /bff/register/**  | extra-personas-sh              |
      | rbac-plain@gmail.com         | login.register-discord | admitted | /bff/register/**  | extra-personas-sh              |
